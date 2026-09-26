import Foundation

/// 换包交接：把"应用退出之后才做的那几步"交给一个独立进程。
///
/// ## 为什么必须是独立进程
///
/// 正在运行的进程没法把自己脚下的包换掉。`.app` 目录在 `rename` 之后，老进程还活着，
/// 但它加载的代码、要读的资源都还指着旧 inode——换完没法安全地继续跑，更没法自己重启。
/// 所以这里分工如下：
///
/// ```
/// 应用（还活着）        下载 → 校验校验和 → 校验签名 → 解包 → 确认身份 → 备份 → 预置新包
///                        ↓ 写出脚本并启动它
///                        ↓ 退出
/// 助手（独立 sh 进程）   等应用真的退出 → 改走旧包 → 新包就位 → 复核 → 打开 → 清理旧包
/// ```
///
/// 用 `sh` 而不是"把本应用自己复制一份再带着参数启动"：`sh`、`mv`、`open`、`xattr`
/// 都不在要替换的那个 bundle 里。换成自家二进制的话，它脚下的包正被换掉，
/// 后续任何一次动态加载都可能失败——这是一条没必要走的钢丝。
///
/// ## 失败可回溯
///
/// 助手跑在应用已经退出之后，出了问题没人能弹窗。所以它把结果写进状态文件，
/// 下次启动读出来告诉用户。没有这份文件，用户看到的就是"点了更新，应用关了，
/// 再打开还是旧版本"——而真相只有助手知道。
public struct SelfUpdateHandoff: Sendable {
    /// 目标 `.app`（也就是当前运行的自己）。
    public let target: URL
    /// 换包用的随机 token。同时决定预置包与旧包的隐藏文件名。
    public let token: String

    private let root: URL

    public init(target: URL, token: String? = nil, root: URL? = nil) {
        self.target = target
        self.token = token ?? String(UUID().uuidString.prefix(8))
        if let root {
            self.root = root
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            self.root = base.appendingPathComponent("AppUpdater", isDirectory: true)
        }
    }

    // MARK: - 路径

    /// 隐藏的新包暂存位置。
    ///
    /// **必须和目标在同一个目录里**——跨卷 `rename` 会退化成拷贝，就失去了原子性。
    /// 命名遵循 `.<名字>.<8位十六进制>.new.app`：这个形状同时被
    /// `Installer.classifyArtifact` 认作中间态，所以助手万一被强杀，
    /// 应用下次启动时的残留清理能接管，不需要第二套恢复逻辑。
    public var staged: URL { sibling(".\(stem).\(token).new.app") }

    /// 被换下来的旧包。回滚的唯一依据，所以在这个位置上是**改名**而不是删除。
    public var displaced: URL { sibling(".\(stem).\(token).old.app") }

    public var statusFile: URL { root.appendingPathComponent("self-update-status.txt") }
    public var scriptFile: URL { root.appendingPathComponent("self-update-\(token).sh") }
    public var logFile: URL { root.appendingPathComponent("self-update-\(token).log") }

    private var stem: String { target.deletingPathExtension().lastPathComponent }

    private func sibling(_ name: String) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - 状态

    /// 应用在启动助手之前先写一条"进行中"。
    ///
    /// 万一应用在启动助手之前就崩了，磁盘上至少有这条记录，用户不至于面对一个
    /// 完全无解释的"什么都没发生"。
    public func markHandedOff(from: String?, to: String, backupPath: URL?) throws {
        try write(status: SelfUpdateStatus(
            outcome: .inProgress,
            fromVersion: from,
            toVersion: to,
            message: "正在等待应用退出，随后完成替换…",
            backupPath: backupPath?.path,
            at: Date()
        ))
    }

    /// 读出上次交接的结果，并把状态文件清掉——它只该被消费一次。
    public static func consumeStatus(root: URL? = nil) -> SelfUpdateStatus? {
        let handoff = SelfUpdateHandoff(target: URL(fileURLWithPath: "/dev/null"), root: root)
        guard let text = try? String(contentsOf: handoff.statusFile, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: handoff.statusFile)
        return SelfUpdateStatus.parse(text)
    }

    private func write(status: SelfUpdateStatus) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try status.serialized().write(to: statusFile, atomically: true, encoding: .utf8)
    }

    // MARK: - 助手脚本

    /// 生成助手脚本。全部变量在生成时写死——脚本从 stdin 读不到任何东西
    /// （后台启动时 stdin 是 `/dev/null`），这是让它可复现的关键。
    func script(executableName: String, from: String?, to: String, backupPath: URL?) -> String {
        let quoted = { (path: String) -> String in "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let displayFrom = from.flatMap { $0.isEmpty ? nil : $0 } ?? "未知版本"

        return #"""
        #!/bin/sh
        # AppUpdater 自更新助手。由应用在退出前生成并启动，只做一件事：
        # 等应用真的退出，然后把已经校验过的 #RAWFROM# 换成 #RAWTO#。
        #
        # 这里刻意不做任何下载、校验、解包——那些都在应用还活着的时候做完了。
        # 助手手里只剩两个已经落盘、身份确认过的目录，以及两次改名。
        #
        # 变量一律写 ${NAME} 而不是 $NAME：这个脚本里到处是中文字符，
        # 而 macOS 的 sh 会把紧跟其后的全角括号当成变量名的一部分
        # （`$FROM）` 会被读成变量 `FROM）`），配 `set -u` 就是当场退出。
        set -u

        PID=#PID#
        TARGET=#TARGET#
        STAGED=#STAGED#
        DISPLACED=#DISPLACED#
        STATUS=#STATUS#
        LOG=#LOG#
        EXECUTABLE=#EXECUTABLE#
        FROM=#FROM#
        TO=#TO#
        BACKUP=#BACKUP#

        # 自己接管输出。应用马上就退出了，继承来的管道会跟着一起没。
        exec >> "${LOG}" 2>&1

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 助手启动：pid=${PID} 目标=${TARGET}"

        status() {
          # $1 = outcome, $2 = message
          {
            printf 'outcome=%s\n' "$1"
            printf 'fromVersion=%s\n' "${FROM}"
            printf 'toVersion=%s\n' "${TO}"
            printf 'message=%s\n' "$2"
            printf 'backupPath=%s\n' "${BACKUP}"
            printf 'at=%s\n' "$(date +%s)"
          } > "${STATUS}.tmp" 2>/dev/null && mv -f "${STATUS}.tmp" "${STATUS}" 2>/dev/null
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1: $2"
          return 0
        }

        # 判断应用是否还在跑。
        #
        # `kill -0` 对僵尸进程同样返回成功——它已经死了，只是还没被父进程收尸。
        # 只认 kill -0 的话，那种情况下会白等满 60 秒然后放弃整次更新。
        # `ps` 拿不到状态时按"还在跑"处理（fail safe）：宁可多等一会儿，
        # 也不能在应用还活着的时候去动它的包。
        still_running() {
          kill -0 "${PID}" 2>/dev/null || return 1
          state=$(ps -o state= -p "${PID}" 2>/dev/null | tr -d ' ')
          if [ -n "${state}" ]; then
            case "${state}" in Z*) return 1 ;; esac
          fi
          return 0
        }

        # 放弃这次更新时，把预置好的那份新包一并清掉。
        #
        # 不清的话，用户会在应用旁边看到一个隐藏的 `.AppUpdater.<token>.new.app`——
        # 那是一份完整的新版本拷贝，而这次更新压根没发生。真机验证时踩到过：
        # 更新被拒之后，目标旁边静静躺着一份几十 MB 的副本。
        #
        # 只在目标完好的时候删。目标不在，说明已经进了换包中途，那时候该由启动时的
        # 残留恢复来接管——在这里多删一个文件，可能删掉的是唯一一份完好的包。
        #
        # 定义在所有出口之前：下面每一条放弃的分支都要用它。
        discard_staged() {
          if [ -d "${TARGET}" ]; then
            rm -rf "${STAGED}" 2>/dev/null
          fi
          return 0
        }

        # 等应用退出。最多 60 秒——真等到超时说明它卡住了，此时放弃比硬来安全。
        ticks=0
        while still_running; do
          ticks=$((ticks + 1))
          if [ "${ticks}" -gt 200 ]; then
            status failed "应用没有在 60 秒内退出，本次更新放弃；当前仍是 ${FROM}"
            discard_staged
            exit 10
          fi
          sleep 0.3
        done

        # 这个包是否正在被某个进程使用。
        #
        # 刻意不用 `pgrep -x AppUpdater`：那会误伤"另一份副本在跑"这种完全正常的情形
        # （开发机上有 dist/ 和 /Applications 两份并存是常事），一上来就报"已被重新打开"。
        # 要问的是「**这一个**包在用吗」，所以按路径匹配。
        #
        # 两个独立探针任一命中就当作在用；探测本身出错时也按在用处理（fail safe）——
        # 宁可这次不升级，也不能把运行中的实例脚下的包抽走。
        bundle_in_use() {
          lsof -- "${TARGET}/Contents/MacOS/${EXECUTABLE}" 2>/dev/null | grep -q . && return 0
          pgrep -f -- "${TARGET}/Contents/MacOS/" >/dev/null 2>&1
          code=$?
          case "${code}" in
            0) return 0 ;;
            1) return 1 ;;
            *) return 0 ;;
          esac
        }

        if bundle_in_use; then
          status failed "还有实例正在运行这一个 AppUpdater（${TARGET}），本次更新放弃；请先退出它再重试。当前仍是 ${FROM}"
          discard_staged
          exit 14
        fi

        # 两次改名都是原子的：中间任何一刻掉电，磁盘上要么是完整的旧包，要么是完整的新包。
        if ! mv "${TARGET}" "${DISPLACED}"; then
          status failed "无法移走旧版本，本次更新放弃；当前仍是 ${FROM}"
          discard_staged
          exit 11
        fi

        if ! mv "${STAGED}" "${TARGET}"; then
          mv "${DISPLACED}" "${TARGET}" 2>/dev/null
          status failed "新版本落位失败，已把旧版本放回原位（${FROM}）"
          discard_staged
          exit 12
        fi

        # 复核：可执行文件在位才算换成功。放在 open 之前，避免去启动一个半成品。
        if [ ! -x "${TARGET}/Contents/MacOS/${EXECUTABLE}" ]; then
          rm -rf "${TARGET}"
          mv "${DISPLACED}" "${TARGET}" 2>/dev/null
          open "${TARGET}" 2>/dev/null
          status failed "新版本包不完整，已回滚到 ${FROM}"
          exit 13
        fi

        # 下载来的包会带隔离属性，不清掉首次启动会被 Gatekeeper 拦下来问东问西。
        xattr -dr com.apple.quarantine "${TARGET}" 2>/dev/null

        # 结果先落盘，再启动应用。反过来的话，新实例会读到"进行中"——
        # 而那一刻替换其实已经完成了。
        status succeeded "已升级到 ${TO}"
        open "${TARGET}" 2>/dev/null

        # 旧包已经备份过一份在 BackupStore 里，这个隐藏目录没必要继续占着。
        rm -rf "${DISPLACED}" 2>/dev/null
        exit 0
        """#
        .replacingOccurrences(of: "#PID#", with: String(ProcessInfo.processInfo.processIdentifier))
        .replacingOccurrences(of: "#TARGET#", with: quoted(target.path))
        .replacingOccurrences(of: "#STAGED#", with: quoted(staged.path))
        .replacingOccurrences(of: "#DISPLACED#", with: quoted(displaced.path))
        .replacingOccurrences(of: "#STATUS#", with: quoted(statusFile.path))
        .replacingOccurrences(of: "#LOG#", with: quoted(logFile.path))
        .replacingOccurrences(of: "#EXECUTABLE#", with: quoted(executableName))
        .replacingOccurrences(of: "#FROM#", with: quoted(displayFrom))
        .replacingOccurrences(of: "#TO#", with: quoted(to))
        .replacingOccurrences(of: "#BACKUP#", with: quoted(backupPath?.path ?? ""))
        .replacingOccurrences(of: "#RAWFROM#", with: displayFrom)
        .replacingOccurrences(of: "#RAWTO#", with: to)
    }

    /// 写出脚本并启动它。返回脚本路径，供调用方记日志。
    @discardableResult
    public func launch(executableName: String, from: String?, to: String, backupPath: URL?) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        try script(executableName: executableName, from: from, to: to, backupPath: backupPath)
            .write(to: scriptFile, atomically: true, encoding: .utf8)
        try? "".write(to: logFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptFile.path]
        // 三路都接到 /dev/null：脚本自己在第一行就把输出重定向到日志文件了，
        // 不需要继承我们这个即将消失的进程的任何 fd。
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        return scriptFile
    }

    // MARK: - 清理

    /// 清掉历史交接留下的脚本与日志。
    ///
    /// 保留最近一份日志：用户报"更新完就不对劲"的时候，那是唯一的现场。
    /// 脚本是一次性的，全部删除。
    public static func cleanUpArtifacts(root: URL? = nil, keepingLogs: Int = 1) {
        let handoff = SelfUpdateHandoff(target: URL(fileURLWithPath: "/dev/null"), root: root)
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: handoff.root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix("self-update-") {
            if entry.pathExtension == "sh" {
                try? fileManager.removeItem(at: entry)
            }
        }

        // 按**修改时间**排，不是按文件名。
        //
        // 文件名里的那一段是随机 token（`self-update-FA012F27.log`），按名字排等于随机
        // 留一份——最该留的恰恰是刚跑完那次。真机上验证时看到的就是这个：新一轮的日志
        // 排在了旧日志后面，被当成"过期"删掉了。
        let logs = entries
            .filter { $0.lastPathComponent.hasPrefix("self-update-") && $0.pathExtension == "log" }
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
        for stale in logs.dropFirst(max(0, keepingLogs)) {
            try? fileManager.removeItem(at: stale)
        }
    }

    /// 文件的修改时间。读不到就按"最旧"处理——这个函数的职责是别让日志无限堆积，
    /// 拿不到时间时保留数量上限，比留下一个来历不明的文件更要紧。
    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
