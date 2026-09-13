import Foundation

/// 单个应用的检查结果。
public enum UpdateResult: Equatable, Codable, Sendable {
    case upToDate(latest: String)
    case updateAvailable(latest: String, downloadURL: URL?, releaseNotesURL: URL?, downloadSize: Int64?)
    case unsupported(reason: String)
    case failed(reason: String)
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

    /// 行内副标题：`Sparkle · 1.3.5 → 1.4.4 · 109 MB`
    public var detailText: String {
        var parts: [String] = [app.source.badge]

        switch result {
        case .updateAvailable(let latest, _, _, let size):
            let current = app.currentVersion ?? "?"
            parts.append("\(current) → \(latest)")
            if let size, size > 0 {
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
