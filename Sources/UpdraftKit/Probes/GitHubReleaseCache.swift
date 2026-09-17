import Foundation

/// 一条 GitHub API 缓存：条件请求的凭据 + 裁剪后的响应体 + 取得时间。
///
/// `body` 存的是**裁剪后**的 JSON（只留 `tag_name` / `html_url` / assets 的
/// `name`/`size`/`browser_download_url`——两个探针都只解析这些字段），真实响应 30-60KB，
/// 裁完只剩几 KB。字段裁剪是有意的耦合：谁要在缓存里多放一个字段，就得先想清楚
/// 哪个探针要用它。
public struct GitHubReleaseCacheEntry: Codable, Equatable, Sendable {
    public let url: URL
    /// 条件请求凭据。个别 200 响应可能没有 ETag——照样缓存 body，只是下次只能全量拉。
    public var etag: String?
    public var body: Data
    /// 取得（或 304 重验证）的时刻，TTL 以此为准。
    public var savedAt: Date

    public init(url: URL, etag: String?, body: Data, savedAt: Date) {
        self.url = url
        self.etag = etag
        self.body = body
        self.savedAt = savedAt
    }
}

/// 缓存存储缝。生产是磁盘文件，测试塞内存/临时文件。
public protocol GitHubReleaseCacheStoring: Sendable {
    func entry(for url: URL) async -> GitHubReleaseCacheEntry?
    func save(_ entry: GitHubReleaseCacheEntry) async
    /// 只刷新 `savedAt`（304 重验证后重启 TTL），body 与 etag 保持不变。
    func touch(url: URL, at date: Date) async
}

/// 磁盘缓存。探针在任务组里并发跑，文件读写必须串行——所以是 actor。
///
/// 文件损坏**当无缓存**处理，绝不抛出：缓存故障不能升级成检查失败。
public actor GitHubReleaseCacheStore: GitHubReleaseCacheStoring {
    /// 进程内共享。CLI 与常驻 app 各自是一个进程，同文件互不感知——
    /// 交叉写入是"后写覆盖"，缓存语义下无害。
    public static let shared = GitHubReleaseCacheStore()

    private let fileURL: URL
    private var entries: [String: GitHubReleaseCacheEntry] = [:]
    private var loaded = false

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent(SelfUpdateIdentity.supportDirectoryName, isDirectory: true)
                .appendingPathComponent("github-cache-v1.json")
        }
    }

    public func entry(for url: URL) async -> GitHubReleaseCacheEntry? {
        loadIfNeeded()
        return entries[url.absoluteString]
    }

    public func save(_ entry: GitHubReleaseCacheEntry) async {
        loadIfNeeded()
        entries[entry.url.absoluteString] = entry
        persist()
    }

    public func touch(url: URL, at date: Date) async {
        loadIfNeeded()
        guard var entry = entries[url.absoluteString] else { return }
        entry.savedAt = date
        entries[url.absoluteString] = entry
        persist()
    }

    /// 懒加载一次。解码失败按空缓存处理，并且**不再反复读**那个坏文件。
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        // ⚠️ 解码策略必须与 persist() 的 `.iso8601` 配对——漏了这行，跨进程
        // （CLI 第二次跑）所有日期都解不出来，整个字典解码失败，磁盘缓存形同虚设，
        // 而且进程内一切正常、毫无报错。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([String: GitHubReleaseCacheEntry].self, from: data) {
            entries = decoded
        }
    }

    private func persist() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// GitHub API 的共享客户端：TTL 门 + ETag 条件重验证。
///
/// `ElectronProbe` 与 `GitHubReleaseProbe` 的 GitHub 请求都走这里——限额是按 IP 共享的，
/// 客户端也得是共享的才管得住。
///
/// **2026-09-16 实测（决定了这个设计的形状）**：未登录场景下，条件请求返回的 304
/// **同样消耗限额**（50 → 49 → 48 的对照实验），GitHub 文档里"条件请求不计数"在
/// 未鉴权时不成立。所以光有 ETag 省不了限额——**TTL 内不发请求**才是唯一手段；
/// ETag 的角色是过期后的重验证（省带宽 + 304 时确认未变并重启 TTL）。
public struct GitHubAPIClient: Sendable {
    /// 与限额窗口同量级：一小时内无论检查多少次，GitHub 请求只有第一批。
    public static let defaultTTL: TimeInterval = 3600

    public static let shared = GitHubAPIClient()

    private let http: HTTPFetching
    private let store: any GitHubReleaseCacheStoring
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        http: HTTPFetching = HTTPClient.shared,
        store: any GitHubReleaseCacheStoring = GitHubReleaseCacheStore.shared,
        ttl: TimeInterval = GitHubAPIClient.defaultTTL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.store = store
        self.ttl = ttl
        self.now = now
    }

    /// 取一个 GitHub API JSON 端点。命中 TTL 直接回缓存（零请求）；
    /// 过期则条件重验证（304 / 200 语义见上）。
    public func get(_ url: URL) async throws -> Data {
        let entry = await store.entry(for: url)
        if let entry, now().timeIntervalSince(entry.savedAt) < ttl {
            return entry.body
        }

        var headers: [String: String] = [:]
        if let etag = entry?.etag, !etag.isEmpty {
            headers["If-None-Match"] = etag
        }
        let response = try await http.response(from: url, headers: headers)

        switch response.statusCode {
        case 200:
            guard let body = Self.slim(response.data) else {
                // 没有 tag_name 的响应（"该仓库没有正式 Release"之类）不缓存，原样交回；
                // 探针按现状解释它，下次照常重查——这种响应本来就小。
                return response.data
            }
            await store.save(GitHubReleaseCacheEntry(
                url: url,
                etag: response.etag,
                body: body,
                savedAt: now()
            ))
            return body

        case 304:
            // 304 的前提是缓存的 ETag 还有效，缓存却不在只可能是文件被手改——如实报错。
            guard let entry else { throw HTTPError.statusCode(304) }
            await store.touch(url: url, at: now())
            return entry.body

        case let code:
            throw HTTPError.statusCode(code)
        }
    }

    /// 裁剪响应体：只留两个探针都用到的字段。没有 `tag_name` 时返回 `nil`（不缓存）。
    static func slim(_ data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = root["tag_name"] as? String, !tagName.isEmpty else {
            return nil
        }
        let assets = ((root["assets"] as? [[String: Any]]) ?? []).map { asset -> [String: Any] in
            [
                "name": asset["name"] as? String ?? "",
                "size": asset["size"] ?? 0,
                "browser_download_url": asset["browser_download_url"] as? String ?? ""
            ]
        }
        let slimmed: [String: Any] = [
            "tag_name": tagName,
            "html_url": root["html_url"] as? String ?? "",
            "assets": assets
        ]
        return try? JSONSerialization.data(withJSONObject: slimmed)
    }
}
