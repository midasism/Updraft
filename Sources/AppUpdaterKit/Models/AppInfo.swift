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

    public var id: String { path.path }

    public init(
        name: String,
        bundleID: String?,
        path: URL,
        currentVersion: String?,
        buildVersion: String?,
        source: AppSource
    ) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.currentVersion = currentVersion
        self.buildVersion = buildVersion
        self.source = source
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
