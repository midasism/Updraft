import Foundation

/// 扫描到的一个应用（或一个由 Homebrew 管理的命令行工具）。
public struct AppInfo: Identifiable, Hashable, Codable, Sendable {
    /// 展示用名称。
    public let name: String
    public let bundleID: String?
    /// `.app` 包的绝对路径；命令行工具指向 Caskroom 里的目录。
    public let path: URL
    public let currentVersion: String?
    public let buildVersion: String?
    public let source: AppSource
    /// `Info.plist` 里的 `SUPublicEDKey`：Sparkle 的 Ed25519 公钥（base64）。
    /// 有它才能在下载后验证安装包确实出自该应用的开发者；没有就只能标为「未校验」。
    public let publicEDKey: String?

    public var id: String { path.path }

    public init(
        name: String,
        bundleID: String?,
        path: URL,
        currentVersion: String?,
        buildVersion: String?,
        source: AppSource,
        publicEDKey: String? = nil
    ) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.currentVersion = currentVersion
        self.buildVersion = buildVersion
        self.source = source
        self.publicEDKey = publicEDKey
    }

    /// 该应用是否公布了签名公钥，即「下载后能不能做密码学校验」。
    public var canVerifySignature: Bool {
        guard let publicEDKey else { return false }
        return !publicEDKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 用于首字母色块的字符。
    public var initial: String {
        guard let first = name.first else { return "?" }
        if first.isNumber { return String(first) }
        return String(first).uppercased()
    }

    /// 为一个纯命令行 cask 构造占位条目（如 ngrok，没有 .app 包）。
    public static func commandLineCask(token: String, installedVersion: String?) -> AppInfo {
        AppInfo(
            name: token,
            bundleID: nil,
            path: URL(fileURLWithPath: "/opt/homebrew/Caskroom/\(token)"),
            currentVersion: installedVersion,
            buildVersion: nil,
            source: .homebrewCask(token: token)
        )
    }
}
