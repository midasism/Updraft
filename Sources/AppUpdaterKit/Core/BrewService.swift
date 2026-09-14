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
    public static func loadIndex() async -> BrewCaskIndex? {
        guard let brew = brewPath() else { return nil }

        let listResult = await ProcessRunner.run(executable: brew, arguments: ["list", "--cask"])
        guard listResult.exitCode == 0 else { return nil }

        let tokens = listResult.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            return BrewCaskIndex(appNameToToken: [:], installedTokens: [], binaryOnlyTokens: [:])
        }

        let infoResult = await ProcessRunner.run(
            executable: brew,
            arguments: ["info", "--cask", "--json=v2"] + tokens
        )
        guard infoResult.exitCode == 0,
              let data = infoResult.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else {
            return nil
        }

        var appNameToToken: [String: String] = [:]
        var binaryOnly: [String: String] = [:]

        for cask in casks {
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

        return BrewCaskIndex(
            appNameToToken: appNameToToken,
            installedTokens: tokens,
            binaryOnlyTokens: binaryOnly
        )
    }

    // MARK: - 检测

    /// 一次调用拿到待更新 cask。逐个 `brew info` 会慢到不可接受，必须批处理。
    ///
    /// - Parameter scopedTo: 只比对这些 token。增量检查只关心刚动过的那几个 cask，
    ///   没必要每次都比一遍全表。收窄后 brew 若报错（例如 token 刚被卸载），
    ///   自动退回全量查询——宁可多花一次调用，也不能因为局部失败而漏报更新。
    /// - Returns: token → 最新版本号。`nil` 表示没找到 Homebrew（问不了），
    ///   与"问了，没有过期项"（空字典）是两回事，调用方必须分开处理。
    public static func outdatedCasks(scopedTo tokens: [String]? = nil) async -> [String: String]? {
        guard let brew = brewPath() else { return nil }

        if let tokens, !tokens.isEmpty, let scoped = await runOutdated(brew: brew, only: tokens) {
            return scoped
        }

        return await runOutdated(brew: brew, only: nil)
    }

    private static func runOutdated(brew: String, only tokens: [String]?) async -> [String: String]? {
        var arguments = ["outdated", "--cask", "--greedy", "--json=v2"]
        if let tokens { arguments.append(contentsOf: tokens) }

        let result = await ProcessRunner.run(executable: brew, arguments: arguments)
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var outdated: [String: String] = [:]

        if let casks = root["casks"] as? [[String: Any]] {
            for cask in casks {
                guard let name = cask["name"] as? String else { continue }
                let latest = normalizedVersion(cask["current_version"]) ?? "新版本"
                outdated[name] = latest
            }
        } else if let formulas = root["formulae"] as? [[String: Any]] {
            for formula in formulas {
                guard let name = formula["name"] as? String else { continue }
                outdated[name] = normalizedVersion(formula["current_version"]) ?? "新版本"
            }
        }

        return outdated
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
