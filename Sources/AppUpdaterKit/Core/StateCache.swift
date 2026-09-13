import Foundation

/// 检查结果落盘，冷启动先渲染缓存再后台刷新。
public struct StateCache: Sendable {
    public struct Snapshot: Codable, Sendable {
        public let updates: [AppUpdate]
        public let savedAt: Date
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
