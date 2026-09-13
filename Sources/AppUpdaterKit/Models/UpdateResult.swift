import Foundation

/// 单个应用的检查结果。
public enum UpdateResult: Equatable, Codable, Sendable {
    case upToDate(latest: String)
    case updateAvailable(ReleaseInfo)
    case unsupported(reason: String)
    case failed(reason: String)

    public var release: ReleaseInfo? {
        guard case .updateAvailable(let release) = self else { return nil }
        return release
    }
}

/// 点下「更新」按钮之后会发生什么。界面据此选按钮文案，用户点之前就知道后果。
public enum InstallAction: Equatable, Sendable {
    /// 交给 Homebrew，能真正一键升完。
    case homebrew(token: String)
    /// 下载安装包 → 校验签名 → 备份 → 替换 App 包。
    case replaceBundle
    /// `.pkg` 需要管理员密码，只能打开系统安装器。
    case openInstaller
    /// 只打开下载页 / 更新说明。
    case openDownload
    /// 没有可用的自动动作。
    case manual

    /// 是否由本工具自己完成安装。
    public var isAutomated: Bool {
        switch self {
        case .homebrew, .replaceBundle: return true
        case .openInstaller, .openDownload, .manual: return false
        }
    }

    public var buttonTitle: String {
        switch self {
        case .homebrew, .replaceBundle: return "升级"
        case .openInstaller: return "打开安装器"
        case .openDownload: return "下载"
        case .manual: return "—"
        }
    }
}

/// 检查结果 + 对应的应用，UI 直接消费这个类型。
public struct AppUpdate: Identifiable, Equatable, Codable, Sendable {
    public let app: AppInfo
    public var result: UpdateResult
    public var checkedAt: Date

    public var id: String { app.id }

    public init(app: AppInfo, result: UpdateResult, checkedAt: Date = Date()) {
        self.app = app
        self.result = result
        self.checkedAt = checkedAt
    }

    /// 列表分组。
    public var group: UpdateGroup {
        switch result {
        case .updateAvailable: return .updateAvailable
        case .upToDate: return .upToDate
        case .unsupported, .failed: return .unsupported
        }
    }

    /// 点按钮之后会发生什么。
    ///
    /// 判定偏保守：任何一环拿不到确凿依据就降级为「只打开下载页」，
    /// 绝不在信息不全的情况下往 `/Applications` 里写文件。
    public var installAction: InstallAction {
        guard case .updateAvailable(let release) = result else { return .manual }

        switch app.source {
        case .homebrewCask(let token):
            return .homebrew(token: token)

        case .sparkle, .electron:
            guard release.downloadURL != nil else {
                return release.releaseNotesURL != nil ? .openDownload : .manual
            }
            // 没有 Bundle ID 就无法确认下载到的包到底是不是这个应用，不能自动替换。
            guard app.bundleID != nil else { return .openDownload }
            // 必须是可写入的应用目录里的 .app 包。
            guard Self.isReplaceable(app.path) else { return .openDownload }

            switch release.packageKind {
            case .dmg, .zip: return .replaceBundle
            case .pkg: return .openInstaller
            case .unknown: return .openDownload
            }
        case .appStore, .microsoftAutoUpdate, .unsupported:
            return release.downloadURL != nil ? .openDownload : .manual
        }
    }

    /// 只有 `/Applications` 与 `~/Applications` 里的 `.app` 才允许被本工具替换。
    ///
    /// 允许放在子目录里（有人喜欢把 `/Applications` 分文件夹整理），
    /// 但不允许嵌在另一个 `.app` 内部——那种情况下的"替换"语义是不清楚的。
    public static func isReplaceable(_ path: URL) -> Bool {
        guard path.pathExtension == "app" else { return false }
        let standardized = path.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let allowed = ["/Applications/", "\(home)/Applications/"]
        guard let root = allowed.first(where: { standardized.hasPrefix($0) }) else { return false }
        return !standardized.dropFirst(root.count).contains(".app/")
    }

    /// 行内副标题：`Sparkle · 1.3.5 → 1.4.4 · 109 MB`
    public var detailText: String {
        var parts: [String] = [app.source.badge]

        switch result {
        case .updateAvailable(let release):
            let current = app.currentVersion ?? "?"
            parts.append("\(current) → \(release.version)")
            if let size = release.size, size > 0 {
                parts.append(Self.formatBytes(size))
            }
        case .upToDate:
            parts.append("已是最新 \(app.currentVersion ?? "")")
        case .unsupported(let reason):
            parts.append(reason)
        case .failed(let reason):
            parts.append("检查失败 · \(reason)")
        }

        return parts.joined(separator: " · ")
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

public enum UpdateGroup: Int, CaseIterable, Codable, Sendable, Identifiable {
    case updateAvailable
    case upToDate
    case unsupported

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .updateAvailable: return "可更新"
        case .upToDate: return "已是最新"
        case .unsupported: return "无法自动检测"
        }
    }
}
