import Foundation

/// 一个应用的更新来源。分类结果决定了后续用哪个探针去查、以及能不能一键升级。
public enum AppSource: Hashable, Codable, Sendable {
    /// 由 Homebrew 管理，`token` 是 cask 名（如 `tabularis`）。这是唯一能做到全自动升级的一类。
    case homebrewCask(token: String)
    /// Sparkle 框架。`feedURL` 为 nil 表示应用内嵌了 Sparkle 但 feed 地址在代码里硬编码，无法读取。
    case sparkle(feedURL: URL?)
    /// Electron 应用，从 `app-update.yml` 拿到更新源。
    case electron(feedURL: URL?)
    /// App Store 安装（含 `_MASReceipt` 收据）。v0.3.6 起可查版本，但不能由本工具安装。
    case appStore
    /// Microsoft AutoUpdate 管理的应用。v0.1 只标记不检测。
    case microsoftAutoUpdate
    /// 开源应用，版本查 GitHub Release 白名单（`GitHubReleaseCatalog`）。v0.3.7 起可查版本，
    /// 但 GitHub 的包没有本工具的签名清单，不能由本工具安装。
    case githubRelease
    /// 能识别但没有可用的公开更新接口，`reason` 会展示给用户。
    case unsupported(reason: String)
}

public extension AppSource {
    /// 列表行上显示的来源徽标。
    var badge: String {
        switch self {
        case .homebrewCask: return "Homebrew"
        case .sparkle: return "Sparkle"
        case .electron: return "Electron"
        case .appStore: return "App Store"
        case .microsoftAutoUpdate: return "Microsoft"
        case .githubRelease: return "GitHub"
        case .unsupported: return "未知来源"
        }
    }

    /// v0.1 中该来源能否自动查出最新版本。
    var isAutoDetectable: Bool {
        switch self {
        case .homebrewCask:
            return true
        case .electron:
            // app-update.yml 就在包内，检查时现读，因此必定可查。
            return true
        case .sparkle(let feedURL):
            return feedURL != nil
        case .appStore:
            // v0.3.6 起走 iTunes Lookup 查版本。**只是查得到**，仍然装不了也升不了——
            // 安装按钮停在 `.openDownload`（打开 App Store 页面），由系统负责真正的更新。
            return true
        case .githubRelease:
            // v0.3.7 起走 GitHub Release 查版本。同样只查不装——
            // 安装按钮停在 `.openDownload`（打开 Release 页面），装包是用户自己的事。
            return true
        case .microsoftAutoUpdate, .unsupported:
            return false
        }
    }

    /// 该来源对应的探针标识，用于并发分组。
    var probeKey: String? {
        switch self {
        case .homebrewCask: return "brew"
        case .sparkle: return "sparkle"
        case .electron: return "electron"
        case .githubRelease: return "github"
        case .appStore, .microsoftAutoUpdate, .unsupported: return nil
        }
    }
}
