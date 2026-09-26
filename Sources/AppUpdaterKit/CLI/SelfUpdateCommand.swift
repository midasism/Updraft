import Foundation

/// 命令行自身更新入口。
///
///     AppUpdater --self-check       查有没有新版本，并打印预检结果（不下载、不写入）
///     AppUpdater --self-update      走完整链路：下载 → 校验 → 备份 → 预置 → 交接 → 退出
///
/// 存在的意义与 `--install` 一样：把"应用内自更新真的能用"变成可复现的命令行输出。
/// 自更新的特殊性在于**换包发生在本进程退出之后**，所以 `--self-update` 的正常结局
/// 就是"打印到交接那一步，然后进程结束"——退出本身就是流程的一部分，
/// 助手在等这个 PID 消失。
public enum SelfUpdateCommand {
    public static func check() async -> Int32 {
        guard let current = SelfIdentity.currentVersion else {
            print("✘ 当前不是从 .app 包里运行的，读不到自身版本号。")
            print("  请先安装：scripts/build-app.sh && open dist/AppUpdater.app")
            return 1
        }

        print("→ 本应用 AppUpdater")
        print("  当前版本  \(current)")
        print("  安装位置  \(SelfIdentity.installedBundle.map(\.path) ?? "（不是 .app 包）")")
        print("  仓库      \(SelfIdentity.repositorySlug)")
        print("  公钥      \(SelfIdentity.publicEDKey == nil ? "未公布（无法做密码学校验）" : "已公布")")
        print("→ 查询 GitHub Releases…")

        let result = await SelfUpdateChecker().check(currentVersion: current, force: true)

        switch result {
        case .upToDate(_, let latest):
            print("  最新版本  \(latest)")
            print("")
            print("  ✔ 已是最新")
            return 0

        case .failed(let reason):
            print("")
            print("  ✘ 检查失败：\(reason)")
            print("    发布页面：\(SelfIdentity.releasePage.absoluteString)")
            return 1

        case .available(let release):
            print("  最新版本  \(release.version)（\(release.tag)）")
            print("")
            print("  ✔ 有新版本")

            let updater = SelfUpdater()
            do {
                let plan = try updater.makePlan(release: release)
                printPlan(plan)
                print("")
                print("  可原地更新：\(plan.target.path)")
                print("  执行：\(Bundle.main.executablePath ?? "AppUpdater") --self-update")
                return 0
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("  安装包    \(release.assetName)"
                      + (release.size.map { " · \(AppUpdate.formatBytes($0))" } ?? ""))
                print("  下载来源  \(release.sourceHost ?? "未知")")
                print("  发布说明  \(release.releaseNotesURL?.absoluteString ?? SelfIdentity.releasePage.absoluteString)")
                print("")
                print("  ⚠︎ 无法在应用内更新：\(reason)")
                print("    请到发布页面手动下载：\(SelfIdentity.releasePage.absoluteString)")
                return 2
            }
        }
    }

    /// 真实执行。成功时返回 0，随后调用方 `exit` —— 这正是助手在等的那件事。
    public static func run() async -> Int32 {
        guard let current = SelfIdentity.currentVersion else {
            print("✘ 当前不是从 .app 包里运行的，无法原地替换自己。")
            return 1
        }

        print("→ 查询最新版本…")
        let result = await SelfUpdateChecker().check(currentVersion: current, force: true)

        switch result {
        case .upToDate(_, let latest):
            print("  当前 \(current) 已是最新（最新 \(latest)）。")
            return 0
        case .failed(let reason):
            print("  ✘ 检查失败：\(reason)")
            print("    发布页面：\(SelfIdentity.releasePage.absoluteString)")
            return 1
        case .available(let release):
            return await install(release: release)
        }
    }

    private static func install(release: SelfUpdateRelease) async -> Int32 {
        let updater = SelfUpdater()

        print("")
        print("───────────────────────────────────────────────")
        do {
            printPlan(try updater.makePlan(release: release))
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("  ⚠︎ 无法在应用内更新：\(reason)")
            print("    请到发布页面手动下载：\(SelfIdentity.releasePage.absoluteString)")
            return 2
        }

        print("")
        print("→ 开始执行（下载 → 校验 → 备份 → 预置 → 交接）")

        let report = await updater.install(release: release) { progress in
            let fraction = progress.fraction.map { String(format: " %.0f%%", $0 * 100) } ?? ""
            FileHandle.standardOutput.write(
                Data("  [\(progress.phase.title)] \(progress.detail)\(fraction)\n".utf8)
            )
        }

        print("")
        if let error = report.error {
            print("  ✘ 更新失败：\(error)")
            print("    磁盘上的应用没有被改动。")
            if let backup = report.backupPath {
                print("    备份：\(abbreviate(backup))")
            }
            return 1
        }

        guard report.awaitingRelaunch else {
            print("  ✘ 更新没有进入交接阶段。")
            return 1
        }

        print("  ✔ \(report.fromVersion ?? "?") → \(report.toVersion) 已校验并预置完成")
        print("    完整性：\(report.checksum.summary)")
        print("    签名：  \(report.signature.summary)")
        if let backup = report.backupPath {
            print("    备份：  \(abbreviate(backup))")
        }
        for warning in report.warnings {
            print("    ⚠︎ \(warning)")
        }
        print("")
        print("═══════════════════════════════════════════════")
        print("已交接给更新助手。本进程即将退出——这是流程的一部分，")
        print("助手正在等它消失，随后完成最后两次改名并重新打开应用。")
        print("结果会写到下次启动的界面上；也可以看日志：")
        print("  ~/Library/Application Support/AppUpdater/self-update-*.log")
        return 0
    }

    private static func printPlan(_ plan: SelfUpdater.Plan) {
        print("  应用      AppUpdater（\(SelfIdentity.bundleIdentifier)）")
        print("  版本      \(plan.currentVersion) → \(plan.release.version)")
        print("  安装包    \(plan.release.assetName) · \(plan.release.packageKind.displayName)"
              + (plan.release.size.map { " · \(AppUpdate.formatBytes($0))" } ?? ""))
        print("  下载来源  \(plan.release.sourceHost ?? "未知")")
        print("  完整校验  \(plan.checksumSource)")
        print("  签名校验  \(plan.signature)")
        print("  目标位置  \(plan.target.path)")
        print("  备份到    \(abbreviate(plan.backupLocation))")
        print("  发布说明  \(plan.release.releaseNotesURL?.absoluteString ?? SelfIdentity.releasePage.absoluteString)")
        for warning in plan.warnings {
            print("  ⚠︎ \(warning)")
        }
    }

    private static func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}
