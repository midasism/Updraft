import Foundation

/// 安装包类型。决定了能不能自动安装。
public enum PackageKind: String, Codable, Sendable, Equatable {
    case dmg
    case zip
    case pkg
    case unknown

    public init(url: URL?) {
        guard let ext = url?.pathExtension.lowercased(), !ext.isEmpty else {
            self = .unknown
            return
        }
        self = PackageKind(rawValue: ext) ?? .unknown
    }

    /// 本工具能否自己走完安装。`.pkg` 需要管理员密码，只能交给系统安装器。
    public var isAutoInstallable: Bool {
        switch self {
        case .dmg, .zip: return true
        case .pkg, .unknown: return false
        }
    }

    public var displayName: String {
        switch self {
        case .dmg: return "磁盘映像"
        case .zip: return "压缩包"
        case .pkg: return "安装器"
        case .unknown: return "未知格式"
        }
    }
}

/// 一个可更新的新版本。
///
/// 这里刻意把 `edSignature` 带上：它是下载完成后做密码学校验的唯一依据，
/// 缺失时只能降级为「未校验」并在界面上如实说明。
public struct ReleaseInfo: Equatable, Codable, Sendable {
    public var version: String
    public var downloadURL: URL?
    public var size: Int64?
    /// Sparkle EdDSA（Ed25519）签名，base64 编码，由 appcast 的 `sparkle:edSignature` 提供。
    public var edSignature: String?
    public var releaseNotesURL: URL?
    /// 包管理器账本里记录的"已安装版本"。只有 Homebrew 来源有值。
    ///
    /// brew 判断一个 cask 是否过期，比的是 **Caskroom 账本**（安装时写下的版本目录名）
    /// 与 tap 里的最新版本，**而不是磁盘上 `.app` 包的真实版本**。应用被自己的内建
    /// 更新器升过之后账本会滞后，于是 brew 报「过期」而实际已是最新。
    /// 记下这个值，界面才能说清这次升级的起点究竟在哪，而不是把它和 tap 的最新版本
    /// 拼成一句 `6.17.0 → 6.17.0` 的自相矛盾。
    public var ledgerVersion: String?

    public init(
        version: String,
        downloadURL: URL? = nil,
        size: Int64? = nil,
        edSignature: String? = nil,
        releaseNotesURL: URL? = nil,
        ledgerVersion: String? = nil
    ) {
        self.version = version
        self.downloadURL = downloadURL
        self.size = size
        self.edSignature = edSignature
        self.releaseNotesURL = releaseNotesURL
        self.ledgerVersion = ledgerVersion
    }

    /// 这次升级的起点版本。
    ///
    /// 账本存在时以账本为准——那才是包管理器真正会拿来比对的"已安装版本"，
    /// 界面上写的 `A → B` 才准确描述了它接下来会做什么。账本缺失（非 Homebrew 来源、
    /// 或这条记录里没给）时退回磁盘上的实际版本。
    public func upgradeFrom(actualVersion: String?) -> String {
        ledgerVersion ?? actualVersion ?? "?"
    }

    /// 账本记录的版本与磁盘上的真实版本是否已经对不上。
    ///
    /// 拿不到任何一边就不判——没有比对基础时宁可不说，也不猜。
    ///
    /// 用 `Version` 比较而不是字符串相等：`1.0` 与 `1.0.0` 是同一个版本，
    /// 只因为写法不同就报"账本滞后"是假警报。
    public func hasStaleLedger(actualVersion: String?) -> Bool {
        guard let ledgerVersion, let actualVersion else { return false }
        if ledgerVersion == actualVersion { return false }
        return Version(ledgerVersion) != Version(actualVersion)
    }

    public var packageKind: PackageKind { PackageKind(url: downloadURL) }

    /// 下载来源域名，确认框里给用户看的。
    public var sourceHost: String? { downloadURL?.host }
}
