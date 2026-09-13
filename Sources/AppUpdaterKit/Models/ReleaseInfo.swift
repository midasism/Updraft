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

    public init(
        version: String,
        downloadURL: URL? = nil,
        size: Int64? = nil,
        edSignature: String? = nil,
        releaseNotesURL: URL? = nil
    ) {
        self.version = version
        self.downloadURL = downloadURL
        self.size = size
        self.edSignature = edSignature
        self.releaseNotesURL = releaseNotesURL
    }

    public var packageKind: PackageKind { PackageKind(url: downloadURL) }

    /// 下载来源域名，确认框里给用户看的。
    public var sourceHost: String? { downloadURL?.host }
}
