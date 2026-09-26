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

    /// 非 nil 表示这条的最新版本已被用户忽略（值为被忽略的版本号）。
    ///
    /// 展示层的投影：真实来源是 `IgnoredVersions` 的记录文件，每次结果进入列表前
    /// 由 `UpdateStore` 重算，冷启动回放缓存时也会重新套用。所以它可以放心地
    /// 随快照一起落盘——哪怕与记录短暂不一致，下一次套用就会修正。
    public var ignoredVersion: String?

    public var id: String { app.id }

    public init(app: AppInfo, result: UpdateResult, checkedAt: Date = Date(), ignoredVersion: String? = nil) {
        self.app = app
        self.result = result
        self.checkedAt = checkedAt
        self.ignoredVersion = ignoredVersion
    }

    /// 列表排序：先按分组的展示顺序，再按名称。
    ///
    /// 全量检查与增量刷新共用同一个比较器——两条路径各写一份的话，
    /// 一次局部刷新就会让列表顺序莫名其妙地变一下。
    public static func listOrder(_ left: AppUpdate, _ right: AppUpdate) -> Bool {
        if left.group != right.group {
            let leftRank = UpdateGroup.displayOrder.firstIndex(of: left.group) ?? .max
            let rightRank = UpdateGroup.displayOrder.firstIndex(of: right.group) ?? .max
            return leftRank < rightRank
        }
        return left.app.name.localizedStandardCompare(right.app.name) == .orderedAscending
    }

    /// 检查结果换了，应用本身没变（只是又探了一次）。
    ///
    /// `ignoredVersion` 不沿用：重新探测意味着结果要重新过一遍忽略判定，
    /// 旧的抑制状态对新结果没有意义。
    public func replacing(result: UpdateResult, at date: Date = Date()) -> AppUpdate {
        AppUpdate(app: app, result: result, checkedAt: date)
    }

    /// 列表分组。
    public var group: UpdateGroup {
        // 被抑制的条目本质仍是「有更新但用户不要」，从「可更新」里摘出来单独成组。
        if ignoredVersion != nil, case .updateAvailable = result { return .ignored }
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
            if let ignored = ignoredVersion {
                // 正常情况下 ignored == release.version（出现更高版本时记录已被清除）。
                parts.append("已忽略 \(ignored)")
                if release.version != ignored {
                    parts.append("最新 \(release.version)")
                }
            } else {
                parts.append("\(current) → \(release.version)")
                if let size = release.size, size > 0 {
                    parts.append(Self.formatBytes(size))
                }
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
    /// rawValue 追加在末尾：更动既有 case 的编号会让旧持久化数据解码错乱。
    case ignored

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .updateAvailable: return "可更新"
        case .upToDate: return "已是最新"
        case .unsupported: return "无法自动检测"
        case .ignored: return "已忽略"
        }
    }

    /// 列表分组的展示顺序。与 `rawValue` 解耦——编号要为解码稳定性保持追加，
    /// 排版顺序则按用户关注度排：要处理的在前，纯记录性的垫底。
    public static let displayOrder: [UpdateGroup] = [
        .updateAvailable, .ignored, .upToDate, .unsupported
    ]
}
