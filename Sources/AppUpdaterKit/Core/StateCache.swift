import Foundation

/// 检查结果落盘，冷启动先渲染缓存再后台刷新。
public struct StateCache: Sendable {
    public struct Snapshot: Codable, Sendable {
        public let updates: [AppUpdate]
        /// 这份快照的写入时间。增量刷新也会更新它，因此它**不等于**"上次全量检查"。
        public let savedAt: Date
        /// 上一次**全量**检查的时间。
        ///
        /// 增量刷新只重查了少数几个条目，其余条目仍然是全量那一刻的结论；
        /// 拿 `savedAt` 去当"上次检查"对着没查过的应用撒谎。
        public let lastFullCheckAt: Date?

        public init(updates: [AppUpdate], savedAt: Date, lastFullCheckAt: Date? = nil) {
            self.updates = updates
            self.savedAt = savedAt
            self.lastFullCheckAt = lastFullCheckAt
        }
    }

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("AppUpdater", isDirectory: true)
                // v0.2 换了 UpdateResult 的形状，换文件名而不是让旧缓存解码失败再兜底，
                // 免得旧缓存被当成"检查结果为空"。
                .appendingPathComponent("state-v2.json")
        }
    }

    public func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    public func save(_ snapshot: Snapshot) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
