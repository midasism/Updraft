import Foundation

/// Homebrew cask 索引：把"应用"和"cask token"对应起来。
public struct BrewCaskIndex: Sendable {
    /// 小写的 app 文件名（去掉 .app）→ cask token。例：`easy move+resize` → `easy-move+resize`
    public let appNameToToken: [String: String]
    /// 已安装的全部 token。
    public let installedTokens: [String]
    /// 只提供命令行工具、没有 .app 产物的 cask → 已安装版本。例：`ngrok`
    public let binaryOnlyTokens: [String: String]

    public init(
        appNameToToken: [String: String],
        installedTokens: [String],
        binaryOnlyTokens: [String: String]
    ) {
        self.appNameToToken = appNameToToken
        self.installedTokens = installedTokens
        self.binaryOnlyTokens = binaryOnlyTokens
    }

    /// 按 `tabularis.app` 这种文件名查 token。
    public func token(forAppFileName fileName: String) -> String? {
        var key = fileName.lowercased()
        if key.hasSuffix(".app") { key.removeLast(4) }
        return appNameToToken[key]
    }
}

/// Homebrew 索引读到什么程度。界面与 CLI 的提示文案都从这里取，
/// 保证两处说的是同一句话，不会各自发挥。
public enum BrewIndexStatus: Sendable, Equatable {
    /// 全部读取成功。
    case ok
    /// 本机没有可用的 brew 可执行文件。
    case brewNotFound
    /// `brew list --cask` 失败，Homebrew 本身出了问题，cask 体系整体不可用。
    case listFailed(stderr: String)
    /// 批量读取失败后降级成逐个查询，部分 cask 仍然读不了（例如 tap 不受信任、
    /// cask 定义损坏）。其余索引不受影响，`index` 依旧可用。
    case partial(skipped: [String], stderr: String)

    /// 给界面看的一句话说明；一切正常时为 `nil`。
    public var notice: String? {
        switch self {
        case .ok:
            return nil
        case .brewNotFound:
            return "未找到 Homebrew"
        case .listFailed(let stderr):
            return "Homebrew 索引读取失败" + (Self.failureSuffix(stderr) ?? "")
        case .partial(let skipped, let stderr):
            guard !skipped.isEmpty else { return "Homebrew 索引读取失败" + (Self.failureSuffix(stderr) ?? "") }
            let shown = skipped.prefix(3).joined(separator: "、")
            let more = skipped.count > 3 ? " 等 \(skipped.count) 个" : ""
            return "\(shown)\(more) 无法读取，已跳过"
        }
    }

    /// stderr 的第一行非空内容。brew 的报错就藏在里面，界面上至少要露出这一行。
    private static func failureSuffix(_ stderr: String) -> String? {
        let line = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line.map { "：\($0)" }
    }
}

/// 索引读取的结果。`index` 为 `nil` 表示整个 cask 体系不可用；
/// 不为 `nil` 时即便有被跳过的 cask，读到的部分依然可信。
public struct BrewIndexOutcome: Sendable {
    public let index: BrewCaskIndex?
    public let status: BrewIndexStatus

    public init(index: BrewCaskIndex?, status: BrewIndexStatus) {
        self.index = index
        self.status = status
    }
}

/// `brew outdated` 对一个 cask（或 formula）的判定。
///
/// 两个版本号是一次调用里一起给的，必须一起记：`brew outdated` 认为「过期」，
/// 比的是 **Caskroom 账本**里的已安装版本与 tap 里的最新版本。而界面原先只抄了后者，
/// 左值另从 `.app` 包内 `Info.plist` 取——应用被自己的更新器升过之后，
/// 账本会滞后于磁盘，两边就拼出 `6.17.0 → 6.17.0` 这种自相矛盾的写法。
public struct BrewOutdatedCask: Sendable, Equatable {
    /// Caskroom 账本记录的已安装版本。`nil` 表示这条记录里没给。
    public let installedVersion: String?
    /// tap 里的最新版本。
    public let latestVersion: String

    public init(installedVersion: String?, latestVersion: String) {
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
    }
}

/// 封装所有 `brew` 调用。GUI 进程的 PATH 通常不含 Homebrew，因此所有调用都显式带上补齐后的环境变量。
public enum BrewService {
    public static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + extra
        // 检查更新的场景下不需要 brew 自己再去做自更新与清理，省掉几十秒。
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        return env
    }

    // MARK: - 索引

    /// 一次性读出所有已安装 cask 及其 .app 产物，供分类器建立映射。
    ///
    /// 批量 `brew info` 是原子性的：只要有一个 cask 加载失败（tap 不受信任、
    /// cask 定义损坏都很常见），整批就以非零退出、不输出任何 JSON。所以批量失败
    /// 时降级为逐个查询——坏的那几个跳过，其余的索引必须保住。
    /// 一个无关的坏 cask 不该让整个 Homebrew 功能瘫痪。
    public static func loadIndex() async -> BrewIndexOutcome {
        guard let brew = brewPath() else {
            return BrewIndexOutcome(index: nil, status: .brewNotFound)
        }

        let listResult = await ProcessRunner.run(
            executable: brew,
            arguments: ["list", "--cask"],
            environment: environment()
        )
        guard listResult.exitCode == 0 else {
            return BrewIndexOutcome(index: nil, status: .listFailed(stderr: listResult.stderr))
        }

        let tokens = listResult.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            return BrewIndexOutcome(
                index: BrewCaskIndex(appNameToToken: [:], installedTokens: [], binaryOnlyTokens: [:]),
                status: .ok
            )
        }

        let info = await loadCaskInfo(brew: brew, tokens: tokens)

        var appNameToToken: [String: String] = [:]
        var binaryOnly: [String: String] = [:]

        for cask in info.casks {
            guard let token = cask["token"] as? String else { continue }
            let installedVersion = normalizedVersion(cask["installed"])

            var appFileNames: [String] = []
            var hasBinary = false
            for artifact in (cask["artifacts"] as? [Any]) ?? [] {
                guard let dict = artifact as? [String: Any] else { continue }
                if let apps = dict["app"] as? [String] { appFileNames.append(contentsOf: apps) }
                if dict["binary"] != nil { hasBinary = true }
            }

            if appFileNames.isEmpty {
                if hasBinary { binaryOnly[token] = installedVersion ?? "—" }
                continue
            }

            for fileName in appFileNames {
                var key = fileName.lowercased()
                if key.hasSuffix(".app") { key.removeLast(4) }
                appNameToToken[key] = token
            }
        }

        let index = BrewCaskIndex(
            appNameToToken: appNameToToken,
            installedTokens: tokens,
            binaryOnlyTokens: binaryOnly
        )

        // 有跳过项时索引要如实反映：跳过的 token 仍在 installedTokens 里（确实装了），
        // 但调用方需要知道这部分没查到详情，而不是当成"没有"。
        let status: BrewIndexStatus
        if info.skipped.isEmpty {
            status = .ok
        } else {
            status = .partial(skipped: info.skipped, stderr: info.stderr)
        }
        return BrewIndexOutcome(index: index, status: status)
    }

    private struct CaskInfoBatch {
        var casks: [[String: Any]] = []
        var skipped: [String] = []
        var stderr: String = ""
    }

    /// 先整批查；批量失败（哪怕只有一个坏 cask）再逐个查，坏的记入 `skipped`。
    private static func loadCaskInfo(brew: String, tokens: [String]) async -> CaskInfoBatch {
        let batchResult = await ProcessRunner.run(
            executable: brew,
            arguments: ["info", "--cask", "--json=v2"] + tokens,
            environment: environment()
        )

        if batchResult.exitCode == 0,
           let casks = parseCaskInfo(batchResult.stdout) {
            return CaskInfoBatch(casks: casks)
        }

        var batch = CaskInfoBatch()
        batch.stderr = batchResult.stderr
        // 逐个查询的并发别开太大：每次都是一个完整的 brew 进程，冷启动要几百毫秒。
        for chunk in tokens.chunked(into: 4) {
            await withTaskGroup(of: (String, [[String: Any]]?, String).self) { group in
                for token in chunk {
                    group.addTask {
                        let result = await ProcessRunner.run(
                            executable: brew,
                            arguments: ["info", "--cask", "--json=v2", token],
                            environment: environment()
                        )
                        if result.exitCode == 0, let parsed = parseCaskInfo(result.stdout), !parsed.isEmpty {
                            return (token, parsed, "")
                        }
                        return (token, nil, result.stderr)
                    }
                }
                for await (token, parsed, stderr) in group {
                    if let parsed {
                        batch.casks.append(contentsOf: parsed)
                    } else {
                        batch.skipped.append(token)
                        if batch.stderr.isEmpty { batch.stderr = stderr }
                    }
                }
            }
        }
        return batch
    }

    /// `brew info --json=v2` 的 stdout → cask 数组。解析失败返回 `nil`。
    static func parseCaskInfo(_ stdout: String) -> [[String: Any]]? {
        guard let data = stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else {
            return nil
        }
        return casks
    }

    // MARK: - 检测

    /// 一次调用拿到待更新 cask。逐个 `brew info` 会慢到不可接受，必须批处理。
    ///
    /// - Parameter scopedTo: 只比对这些 token。增量检查只关心刚动过的那几个 cask，
    ///   没必要每次都比一遍全表。收窄后 brew 若报错（例如 token 刚被卸载），
    ///   自动退回全量查询——宁可多花一次调用，也不能因为局部失败而漏报更新。
    /// - Returns: token → 判定结果（账本版本 + 最新版本）。`nil` 表示没找到 Homebrew（问不了），
    ///   与"问了，没有过期项"（空字典）是两回事，调用方必须分开处理。
    public static func outdatedCasks(scopedTo tokens: [String]? = nil) async -> [String: BrewOutdatedCask]? {
        guard let brew = brewPath() else { return nil }

        if let tokens, !tokens.isEmpty, let scoped = await runOutdated(brew: brew, only: tokens) {
            return scoped
        }

        return await runOutdated(brew: brew, only: nil)
    }

    private static func runOutdated(brew: String, only tokens: [String]?) async -> [String: BrewOutdatedCask]? {
        var arguments = ["outdated", "--cask", "--greedy", "--json=v2"]
        if let tokens { arguments.append(contentsOf: tokens) }

        let result = await ProcessRunner.run(
            executable: brew,
            arguments: arguments,
            environment: environment()
        )
        guard result.exitCode == 0 else { return nil }
        return parseOutdated(result.stdout)
    }

    /// `brew outdated --json=v2` 的 stdout → token 判定表。解析失败返回 `nil`。
    ///
    /// `installed_versions` 与 `current_version` 必须一起取：只留后者就答不出
    /// 「brew 以为装的是哪一版」，而那正是它报过期的依据。
    static func parseOutdated(_ stdout: String) -> [String: BrewOutdatedCask]? {
        guard let data = stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // cask 与 formula 的字段名一致，解析逻辑共用一份，免得将来只改一边。
        func collect(_ entries: [[String: Any]], installedKey: String) -> [String: BrewOutdatedCask] {
            var collected: [String: BrewOutdatedCask] = [:]
            for entry in entries {
                guard let name = entry["name"] as? String else { continue }
                collected[name] = BrewOutdatedCask(
                    installedVersion: installedVersion(from: entry, key: installedKey),
                    latestVersion: normalizedVersion(entry["current_version"]) ?? "新版本"
                )
            }
            return collected
        }

        if let casks = root["casks"] as? [[String: Any]] {
            return collect(casks, installedKey: "installed_versions")
        }
        if let formulae = root["formulae"] as? [[String: Any]] {
            return collect(formulae, installedKey: "installed")
        }
        return [:]
    }

    /// 账本字段在两种产物上形状不同，这里都认：
    /// cask 的 `installed_versions` 是 `["6.12.0,61200"]`，
    /// formula 的 `installed` 是 `[{"version": "1.2.3"}]`。
    static func installedVersion(from entry: [String: Any], key: String) -> String? {
        if let flat = normalizedVersion(entry[key]) { return flat }
        guard let list = entry[key] as? [[String: Any]] else { return nil }
        return normalizedVersion(list.first?["version"])
    }

    // MARK: - 升级

    /// 流式执行 `brew upgrade --cask <token>`，逐块回传输出。
    public static func upgradeStream(token: String) -> AsyncStream<String> {
        guard let brew = brewPath() else {
            return AsyncStream { continuation in
                continuation.yield("找不到 brew，无法执行升级。\n")
                continuation.finish()
            }
        }
        return ProcessRunner.stream(
            executable: brew,
            arguments: ["upgrade", "--cask", token],
            environment: environment()
        )
    }

    // MARK: - 工具

    /// brew 的版本串会带 revision 后缀（`3.39.11,dy27whJwwmb,a`），只保留第一个逗号前的部分。
    static func normalizedVersion(_ value: Any?) -> String? {
        let raw: String?
        if let string = value as? String {
            raw = string
        } else if let array = value as? [String] {
            raw = array.first
        } else {
            raw = nil
        }

        guard let raw, !raw.isEmpty else { return nil }
        return raw.split(separator: ",").first.map(String.init) ?? raw
    }
}
