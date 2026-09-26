import Foundation

/// 本应用自己的身份。
///
/// 集中在一处，是为了不让 `com.local.appupdater` 这个字面量散落到检测、替换、
/// 排除自身这三个互不相干的地方——它一改，三个地方都得跟着改。
public enum SelfIdentity {
    /// 与 `scripts/build-app.sh` 里的 `BUNDLE_ID` 必须一致。
    public static let bundleIdentifier = "com.local.appupdater"
    /// 界面与可执行文件叫 AppUpdater，仓库叫 Updraft。
    public static let repositorySlug = "midasism/Updraft"
    /// 最新 Release 页面，人工兜底用。
    public static let releasePage = URL(string: "https://github.com/midasism/Updraft/releases/latest")!
    /// 最新 Release 的 API 地址。走公开接口，不需要 token。
    public static let releasesAPI = URL(string: "https://api.github.com/repos/midasism/Updraft/releases/latest")!

    /// 当前运行的版本号（`Bundle.main` 的 `CFBundleShortVersionString`）。
    ///
    /// 从源码直接跑（`swift run`）时没有 bundle，拿不到版本号——这时自更新整条链路
    /// 都应该降级为「打开 Release 页面」，而不是拿一个猜的版本号去比对。
    public static var currentVersion: String? {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    /// 当前运行的应用包路径。不是 `.app` 就返回 nil。
    public static var installedBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url.standardizedFileURL : nil
    }

    /// 本应用公布的 Ed25519 公钥（`SUPublicEDKey`）。
    ///
    /// 与 Sparkle 应用用的是同一个键名和同一种算法，所以校验逻辑可以直接复用——
    /// 我们不过是自己更新的"上游"，用的还是同一套规矩。
    public static var publicEDKey: String? {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    }

    /// 这个路径能不能被自己原地替换。
    ///
    /// 比 `AppUpdate.isReplaceable` 宽一点：不限定必须在 `/Applications` 下——
    /// 开发时从 `dist/AppUpdater.app` 跑起来也要能验证整条链路。但仍然挡住三类
    /// 绝不能碰的目标：
    /// - `/System` 下的（系统自有）；
    /// - `/Volumes` 下的（多半是从 dmg 里直接运行的，那是只读卷）；
    /// - 嵌在另一个 `.app` 内部的（"替换"的语义不成立）。
    public static func canReplace(_ path: URL) -> Bool {
        guard path.pathExtension == "app" else { return false }
        let standardized = path.standardizedFileURL.path
        guard standardized.hasPrefix("/") else { return false }
        for forbidden in ["/System/", "/Volumes/"] where standardized.hasPrefix(forbidden) {
            return false
        }
        if standardized.dropFirst().contains(".app/") { return false }
        return FileManager.default.isWritableFile(atPath: path.deletingLastPathComponent().path)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// 从 GitHub Release 里挑出来的一个自更新版本。
public struct SelfUpdateRelease: Equatable, Sendable {
    /// 去掉 `v` 前缀的版本号，如 `0.3.0`。
    public var version: String
    /// 原始 tag，如 `v0.3.0`。
    public var tag: String
    public var assetName: String
    public var downloadURL: URL
    public var packageKind: PackageKind
    public var size: Int64?
    /// Release 页面地址，确认框里给用户"先看一眼再决定"的出路。
    public var releaseNotesURL: URL?
    public var publishedAt: Date?
    /// `SHA256SUMS.txt` 的地址。
    public var checksumURL: URL?
    /// GitHub API 自带的资产摘要（形如 `sha256:abc…`）。校验和文件拿不到时的兜底。
    public var apiDigest: String?
    /// Ed25519 签名文件的地址（`<包名>.ed25519`），没配签名密钥时为 nil。
    public var signatureURL: URL?

    public init(
        version: String,
        tag: String,
        assetName: String,
        downloadURL: URL,
        packageKind: PackageKind,
        size: Int64? = nil,
        releaseNotesURL: URL? = nil,
        publishedAt: Date? = nil,
        checksumURL: URL? = nil,
        apiDigest: String? = nil,
        signatureURL: URL? = nil
    ) {
        self.version = version
        self.tag = tag
        self.assetName = assetName
        self.downloadURL = downloadURL
        self.packageKind = packageKind
        self.size = size
        self.releaseNotesURL = releaseNotesURL
        self.publishedAt = publishedAt
        self.checksumURL = checksumURL
        self.apiDigest = apiDigest
        self.signatureURL = signatureURL
    }

    public var sourceHost: String? { downloadURL.host }
}

/// 自更新检测的三态结果。
///
/// 与 `UpdateResult` 同构，但刻意不复用：那个是"别人家应用"的模型，
/// 混进来会让人以为本应用也是列表里的一条。
public enum SelfUpdateResult: Equatable, Sendable {
    case upToDate(current: String, latest: String)
    case available(SelfUpdateRelease)
    case failed(reason: String)

    public var release: SelfUpdateRelease? {
        guard case .available(let release) = self else { return nil }
        return release
    }
}

/// 安装包完整性校验结果。
///
/// 三态而非布尔值：「没有校验和可对」和「校验和对不上」是两件完全不同的事，
/// 前者如实标"未校验"，后者必须中止。
public enum ChecksumOutcome: Equatable, Sendable {
    case verified(source: String)
    case skipped(reason: String)
    case failed(reason: String)

    public var isVerified: Bool { if case .verified = self { return true } else { return false } }

    public var isFailure: Bool { if case .failed = self { return true } else { return false } }

    public var summary: String {
        switch self {
        case .verified(let source): return "校验和一致（\(source)）"
        case .skipped(let reason): return "未校验 · \(reason)"
        case .failed(let reason): return "校验和不一致 · \(reason)"
        }
    }
}

/// 自更新助手回写的执行结果。
///
/// 换包那几步发生在本进程已经退出之后，所以结果只能落到磁盘上等下次启动来读。
/// 没有这份文件，用户看到的就是"点了更新，应用关了，再打开还是旧版本"——
/// 而真相只有助手知道。
public struct SelfUpdateStatus: Equatable, Sendable {
    public enum Outcome: String, Sendable {
        case inProgress
        case succeeded
        case failed
    }

    public var outcome: Outcome
    public var fromVersion: String?
    public var toVersion: String
    public var message: String
    public var backupPath: String?
    public var at: Date?

    public init(
        outcome: Outcome,
        fromVersion: String?,
        toVersion: String,
        message: String,
        backupPath: String? = nil,
        at: Date? = nil
    ) {
        self.outcome = outcome
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.message = message
        self.backupPath = backupPath
        self.at = at
    }

    // MARK: - 落盘格式

    /// 刻意用 `key=value` 的行格式而不是 JSON。
    ///
    /// 写这份文件的是一个 `sh` 脚本，在 shell 里拼 JSON 要处理引号与反斜杠转义，
    /// 一旦漏了就写出坏文件——而这份文件恰恰是"换包失败"时唯一的证据来源。
    /// 行格式只需保证值里没有换行，成本低得多。
    public func serialized() -> String {
        var lines = [
            "outcome=\(outcome.rawValue)",
            "fromVersion=\(Self.singleLine(fromVersion ?? ""))",
            "toVersion=\(Self.singleLine(toVersion))",
            "message=\(Self.singleLine(message))",
            "backupPath=\(Self.singleLine(backupPath ?? ""))"
        ]
        if let at {
            lines.append("at=\(Int(at.timeIntervalSince1970))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parse(_ text: String) -> SelfUpdateStatus? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            fields[key] = value
        }
        guard let raw = fields["outcome"], let outcome = Outcome(rawValue: raw) else { return nil }
        guard let toVersion = fields["toVersion"] else { return nil }

        return SelfUpdateStatus(
            outcome: outcome,
            fromVersion: fields["fromVersion"].flatMap { $0.isEmpty ? nil : $0 },
            toVersion: toVersion,
            message: fields["message"] ?? "",
            backupPath: fields["backupPath"].flatMap { $0.isEmpty ? nil : $0 },
            at: fields["at"].flatMap(Int.init).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    /// 值里出现换行会把行格式撑坏。改写成一个空格，而不是静默截断。
    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
