import Foundation

/// 「忽略这个版本」的记录存储与判定。
///
/// 记录是**用户决策**，不是检查结果缓存——所以独立成文件，不进 `StateCache`：
/// state-v2.json 换数据形状时按项目惯例直接换文件名丢弃，忽略记录不能跟着丢。
///
/// 判定语义是「忽略的是版本，不是应用」：
///
///   1. 本机版本 ≥ 被忽略版本        → 记录失效（用户已经自己升上去了）
///   2. 探测到的最新版本 > 被忽略版本 → 记录失效（出现了更高的新版本，恢复提示）
///   3. 探测到的最新版本 ≤ 被忽略版本 → 抑制：不提示、不进「可更新」
///   4. 无记录                       → 常规逻辑
///
/// **不设时间失效**：记录天然失效于出现更高版本；按时间过期只会让用户莫名再次
/// 收到同一个已拒绝版本的提示。`ignoredAt` 仅为将来的管理界面留口子。
///
/// 注意：`IgnoredVersions()`（不带 fileURL）是**纯内存实例，启动为空且不落盘**，
/// 供测试注入；生产入口用 `IgnoredVersions(fileURL: IgnoredVersions.defaultFileURL)`。
/// 这与 `StateCache` 的「nil 即默认磁盘路径」语义不同，别混用。
public struct IgnoredVersions: Sendable {

    public struct Record: Codable, Sendable, Equatable {
        /// 被忽略的最新版本号（探测时的 `release.version` 原文）。
        public var version: String
        public var ignoredAt: Date

        public init(version: String, ignoredAt: Date = Date()) {
            self.version = version
            self.ignoredAt = ignoredAt
        }
    }

    /// 快照外壳：包一层字典而不是直接存字典，将来加字段时老文件还能解码。
    private struct FileFormat: Codable {
        var records: [String: Record] = [:]
    }

    private enum DecisionKey {
        case bundle(String)
        case cask(String)
        case path(String)
    }

    private var records: [String: Record]
    private let fileURL: URL?

    /// 生产环境使用的默认路径，与 state-v2.json 同目录（GUI 与 headless CLI 共享）。
    public static var defaultFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("AppUpdater", isDirectory: true)
            .appendingPathComponent("ignored-versions.json")
    }

    /// - Parameter fileURL: 记录文件路径。传 `nil` 表示纯内存实例（空启动、不落盘），供测试用。
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            records = [:]
            return
        }
        records = (try? JSONDecoder().decode(FileFormat.self, from: data))?.records ?? [:]
        // 解码失败就当空记录处理：一份坏文件不该让用户的所有忽略悄悄失效成「重新提示」，
        // 也不该让整个检查流程挂掉。下一次 ignore/unignore 会用干净的字典覆盖它。
    }

    /// 判定入口。只在 `result == .updateAvailable` 时需要调用。
    ///
    /// 比较一律走 `Version` 的点分语义而不是字符串相等：`1.0` 与 `1.0.0`、
    /// `v1.2.3` 与 `1.2.3` 是同一版本；带后缀的预发布版视为更早。
    /// 已知边界：仅构建号变化、版本号不变的重新发布不会被视为新版本——
    /// 用户在界面上看到的就是版本号，这与「忽略这个版本」的直觉一致。
    public func decide(app: AppInfo, latestVersion: String) -> Decision {
        guard let record = records[Self.key(for: app)] else { return .noRecord }
        let ignored = Version(record.version)

        // 用户自己把应用升到了不低于被忽略版本的地方，记录失去意义。
        if let installed = app.currentVersion, !installed.isEmpty,
           Version(installed) >= ignored {
            return .clear
        }

        // 出现了更高的新版本，忽略记录到期，恢复提示。
        if Version(latestVersion) > ignored {
            return .clear
        }

        return .suppress(version: record.version)
    }

    public enum Decision: Equatable, Sendable {
        /// 无记录，常规展示。
        case noRecord
        /// 最新版本不高于被忽略版本：抑制提示，条目归入「已忽略」。
        case suppress(version: String)
        /// 记录已失效，调用方应移除记录并常规展示。
        case clear
    }

    /// 新增/更新一条忽略记录。重复忽略同一应用时以新版本为准。
    public mutating func ignore(app: AppInfo, version: String) {
        records[Self.key(for: app)] = Record(version: version)
    }

    /// 移除一条记录（用户手动「取消忽略」，或判定为 `.clear` 后由调用方移除）。
    public mutating func remove(app: AppInfo) {
        records.removeValue(forKey: Self.key(for: app))
    }

    public func save() {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(FileFormat(records: records)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 忽略记录的键。Bundle ID 优先：应用升级后版本必然变、路径也可能变，只有它稳定；
    /// 纯命令行 cask 没有 bundleID，退到 cask token；再退到包路径。
    public static func key(for app: AppInfo) -> String {
        if let bundleID = app.bundleID, !bundleID.isEmpty {
            return "bundle:" + bundleID
        }
        if case .homebrewCask(let token) = app.source {
            return "cask:" + token
        }
        return "path:" + app.path.path
    }
}
