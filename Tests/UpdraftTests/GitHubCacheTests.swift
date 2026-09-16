import XCTest
@testable import UpdraftKit

// 缓存语义专项测试。探针行为（tag 归一、状态码分类等）由 `GitHubReleaseTests` 覆盖；
// 这里的用例只回答一个问题：**同样的 GitHub 请求，第二次还要不要发出去。**

// MARK: - 假缝与夹具

/// 可拨动的时钟。真实 `Date()` 没法让 TTL 过期，所有用例都注入它。
private final class CacheClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
}

/// 按 `response(from:headers:)` 走的录像假缝：按顺序回放状态码/ETag/响应体，
/// 并记下每个请求带没带 `If-None-Match`——那是条件重验证的核心凭据。
private actor RecordingHTTP: HTTPFetching {
    struct Call: Equatable {
        let url: URL
        let ifNoneMatch: String?
    }

    struct Step {
        let statusCode: Int
        let etag: String?
        let body: String

        init(_ statusCode: Int, etag: String? = nil, _ body: String) {
            self.statusCode = statusCode
            self.etag = etag
            self.body = body
        }
    }

    private(set) var calls: [Call] = []
    private let steps: [Step]
    private var index = 0

    init(steps: [Step]) { self.steps = steps }

    /// 缓存客户端必须走 `response(from:headers:)`；走到这里说明缝接错了。
    func data(from url: URL) async throws -> Data {
        preconditionFailure("GitHubAPIClient 必须走 response(from:headers:)")
    }

    func response(from url: URL, headers: [String: String]) async throws -> HTTPResponse {
        let step = steps[min(index, steps.count - 1)]
        index += 1
        calls.append(Call(url: url, ifNoneMatch: headers["If-None-Match"]))
        return HTTPResponse(data: Data(step.body.utf8), statusCode: step.statusCode, etag: step.etag)
    }
}

private func releaseBody(tag: String) -> String {
    """
    {"tag_name": "\(tag)", \
    "html_url": "https://github.com/lwouis/alt-tab-macos/releases/tag/\(tag)", \
    "assets": [{"name": "AltTab-\(tag).zip", "size": 100}]}
    """
}

private let cacheURL = URL(string: "https://api.github.com/repos/lwouis/alt-tab-macos/releases/latest")!

private func makeStore(file: URL? = nil) -> (GitHubReleaseCacheStore, URL) {
    let cacheFile = file ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("gh-cache-\(UUID().uuidString).json")
    return (GitHubReleaseCacheStore(fileURL: cacheFile), cacheFile)
}

private func makeClient(
    _ http: HTTPFetching,
    clock: CacheClock,
    ttl: TimeInterval = GitHubAPIClient.defaultTTL,
    file: URL? = nil
) -> GitHubAPIClient {
    let (store, _) = makeStore(file: file)
    return GitHubAPIClient(http: http, store: store, ttl: ttl, now: { clock.date })
}

// MARK: - TTL 门

final class GitHubCacheTTLTests: XCTestCase {
    func testFreshEntryAnswersWithoutAnyRequest() async throws {
        let clock = CacheClock()
        let http = RecordingHTTP(steps: [.init(200, etag: #""v1""#, releaseBody(tag: "v11.6.1"))])
        let client = makeClient(http, clock: clock)

        let first = try await client.get(cacheURL)
        let second = try await client.get(cacheURL)

        XCTAssertEqual(first, second, "TTL 内的两次读取必须拿到同一份 body")
        let calls = await http.calls
        XCTAssertEqual(calls.count, 1, "第二次读取是 TTL 命中，绝不能发请求")
    }

    func testExpiredEntryGoesBackToNetwork() async throws {
        let clock = CacheClock()
        let http = RecordingHTTP(steps: [
            .init(200, etag: #""v1""#, releaseBody(tag: "v11.6.1")),
            .init(200, etag: #""v2""#, releaseBody(tag: "v11.7.0")),
        ])
        let client = makeClient(http, clock: clock)

        _ = try await client.get(cacheURL)
        clock.date += GitHubAPIClient.defaultTTL + 1
        let refreshed = try await client.get(cacheURL)

        XCTAssertTrue(String(data: refreshed, encoding: .utf8)!.contains("v11.7.0"),
                      "过期后必须重新拿到远端新 body")
        let calls = await http.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testExactTTLBoundaryIsExpired() async throws {
        // 边界语义（实现用严格小于）：恰好等于 TTL 就算过期，回去重验证。
        let clock = CacheClock()
        let http = RecordingHTTP(steps: [
            .init(200, etag: #""v1""#, releaseBody(tag: "v11.6.1")),
            .init(304, ""),
        ])
        let client = makeClient(http, clock: clock)

        _ = try await client.get(cacheURL)
        clock.date += GitHubAPIClient.defaultTTL
        _ = try await client.get(cacheURL)

        let calls = await http.calls
        XCTAssertEqual(calls.count, 2, "恰好到 TTL 边界应判过期并发条件请求")
        XCTAssertEqual(calls[1].ifNoneMatch, #""v1""#)
    }
}

// MARK: - ETag 条件重验证

final class GitHubCacheRevalidationTests: XCTestCase {
    func testExpiredEntrySendsIfNoneMatchAnd304RestartsTTL() async throws {
        let clock = CacheClock()
        let http = RecordingHTTP(steps: [
            .init(200, etag: #""abc123""#, releaseBody(tag: "v11.6.1")),
            .init(304, ""),
        ])
        let client = makeClient(http, clock: clock)

        let original = try await client.get(cacheURL)
        clock.date += GitHubAPIClient.defaultTTL + 1
        let revalidated = try await client.get(cacheURL)

        // 304 的语义：远端没变，交回缓存的 body。
        XCTAssertEqual(revalidated, original, "304 必须交回缓存 body，而不是 304 的空响应体")
        var calls = await http.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].ifNoneMatch, #""abc123""#, "重验证必须带上第一次存下的 ETag")

        // 304 触发 touch → TTL 从此刻重启，接下来一小时内零请求。
        clock.date += GitHubAPIClient.defaultTTL - 60
        _ = try await client.get(cacheURL)
        calls = await http.calls
        XCTAssertEqual(calls.count, 2, "304 之后 TTL 已重启，不该再发请求")
    }

    func test200AfterExpiryReplacesBodyAndETag() async throws {
        let clock = CacheClock()
        let http = RecordingHTTP(steps: [
            .init(200, etag: #""old""#, releaseBody(tag: "v11.6.1")),
            .init(200, etag: #""new""#, releaseBody(tag: "v11.7.0")),
        ])
        let client = makeClient(http, clock: clock)

        _ = try await client.get(cacheURL)
        clock.date += GitHubAPIClient.defaultTTL + 1
        let refreshed = try await client.get(cacheURL)
        XCTAssertTrue(String(data: refreshed, encoding: .utf8)!.contains("v11.7.0"))

        // 新 ETag 必须顶掉旧的：下次重验证带的是 "new"。
        clock.date += GitHubAPIClient.defaultTTL + 1
        _ = try await client.get(cacheURL)
        let calls = await http.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[2].ifNoneMatch, #""new""#, "200 换 body 时必须连 ETag 一起换")
    }

    func testEntryWithoutETagRevalidatesWithFullRequest() async throws {
        // 个别 200 没有 ETag：照样缓存 body，但下次只能全量拉（没有 If-None-Match）。
        let clock = CacheClock()
        let http = RecordingHTTP(steps: [
            .init(200, etag: nil, releaseBody(tag: "v11.6.1")),
            .init(200, etag: nil, releaseBody(tag: "v11.6.1")),
        ])
        let client = makeClient(http, clock: clock)

        _ = try await client.get(cacheURL)
        clock.date += GitHubAPIClient.defaultTTL + 1
        _ = try await client.get(cacheURL)

        let calls = await http.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertNil(calls[1].ifNoneMatch, "没有存过 ETag 就不能发 If-None-Match")
    }

    func test304WithoutCachedEntryThrows() async throws {
        // 正常路径不可能出现：没有 entry 就不会带 If-None-Match，也就不会拿到 304。
        // 真出现只可能是缓存文件被手改/清掉后 ETag 还残留在别处——如实报错，别假装成功。
        let clock = CacheClock()
        let http = RecordingHTTP(steps: [.init(304, "")])
        let client = makeClient(http, clock: clock)

        do {
            _ = try await client.get(cacheURL)
            XCTFail("无缓存却收到 304，应当报错")
        } catch let error as HTTPError {
            guard case .statusCode(304) = error else {
                return XCTFail("应当是 HTTP 304，实际 \(error)")
            }
        }
    }
}

// MARK: - 磁盘持久化

final class GitHubCachePersistenceTests: XCTestCase {
    func testEntrySurvivesAcrossStoreInstances() async throws {
        // 跨进程持久化的核心断言：写实例销毁后，新实例从同一个文件读回来。
        // （曾因编码 `.iso8601` / 解码默认策略不配对而全盘失效，且进程内毫无征兆。）
        let clock = CacheClock()
        let (store, file) = makeStore()
        let writer = GitHubAPIClient(
            http: RecordingHTTP(steps: [.init(200, etag: #""v1""#, releaseBody(tag: "v11.6.1"))]),
            store: store, ttl: .infinity, now: { clock.date })
        _ = try await writer.get(cacheURL)

        let (reloadedStore, _) = makeStore(file: file)
        let entry = await reloadedStore.entry(for: cacheURL)
        XCTAssertNotNil(entry, "新实例必须能从磁盘读回缓存")
        XCTAssertEqual(entry?.etag, #""v1""#)
        XCTAssertEqual(String(data: entry?.body ?? Data(), encoding: .utf8)?.contains("v11.6.1"), true)
    }

    func testCorruptFileIsTreatedAsNoCacheAndRecovers() async throws {
        let (store, file) = makeStore()
        try Data("not json at all".utf8).write(to: file)

        let clock = CacheClock()
        let http = RecordingHTTP(steps: [
            .init(200, etag: #""v1""#, releaseBody(tag: "v11.6.1")),
            .init(200, etag: #""v1""#, releaseBody(tag: "v11.6.1")),
        ])
        let client = GitHubAPIClient(http: http, store: store, ttl: GitHubAPIClient.defaultTTL, now: { clock.date })

        // 坏文件 → 当无缓存 → 照常发请求，绝不把缓存故障升级成检查失败。
        let body = try await client.get(cacheURL)
        XCTAssertTrue(String(data: body, encoding: .utf8)!.contains("v11.6.1"))
        var calls = await http.calls
        XCTAssertEqual(calls.count, 1)

        // 这次写入已落盘：同实例 TTL 内命中（in-memory），且文件已自愈成合法 JSON。
        // （解码策略必须与 persist 的 .iso8601 配对——正是本分支修掉的那类错误。）
        _ = try await client.get(cacheURL)
        calls = await http.calls
        XCTAssertEqual(calls.count, 1, "恢复写入后 TTL 内应该命中")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNotNil(try? decoder.decode([String: GitHubReleaseCacheEntry].self, from: Data(contentsOf: file)),
                        "写回的缓存文件必须是合法 JSON")
    }

    func testResponseWithoutTagNameIsNotCached() async throws {
        // 没有 tag_name 的响应（该仓库没有正式 Release）不缓存：这种状态会变（发了首个 Release），
        // 而且响应本来就小，不值得为它引入"缓存了过期判断依据"的复杂度。
        let clock = CacheClock()
        let http = RecordingHTTP(steps: [.init(200, etag: #""v1""#, #"{"html_url": "https://github.com/x/y"}"#)])
        let client = makeClient(http, clock: clock)

        _ = try await client.get(cacheURL)
        _ = try await client.get(cacheURL)

        let calls = await http.calls
        XCTAssertEqual(calls.count, 2, "没缓存成就要再查一次")
    }
}

// MARK: - 响应裁剪

final class GitHubCacheSlimTests: XCTestCase {
    func testSlimKeepsOnlyFieldsBothProbesNeed() throws {
        let raw = """
        {
          "tag_name": "v11.6.1",
          "html_url": "https://github.com/lwouis/alt-tab-macos/releases/tag/v11.6.1",
          "body": "## Highlights\\r\\n- fix: something",
          "prerelease": false,
          "draft": false,
          "author": { "login": "lwouis" },
          "assets": [
            {
              "name": "AltTab-v11.6.1.zip",
              "size": 12831292,
              "browser_download_url": "https://github.com/lwouis/alt-tab-macos/releases/download/v11.6.1/AltTab-v11.6.1.zip",
              "content_type": "application/zip",
              "download_count": 42
            }
          ]
        }
        """
        let slimmed = try XCTUnwrap(GitHubAPIClient.slim(Data(raw.utf8)))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: slimmed) as? [String: Any])

        XCTAssertEqual(Set(root.keys), ["tag_name", "html_url", "assets"],
                       "真响应 30-60KB，裁完只留两个探针都用到的字段")
        let assets = try XCTUnwrap(root["assets"] as? [[String: Any]])
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(Set(assets[0].keys), ["name", "size", "browser_download_url"])
        XCTAssertEqual(assets[0]["name"] as? String, "AltTab-v11.6.1.zip")
        XCTAssertEqual(assets[0]["size"] as? Int, 12_831_292)
    }

    func testSlimSurvivesMissingOptionalFields() throws {
        // 只要有 tag_name 就能裁；html_url/assets 缺了用空值补位。
        let slimmed = try XCTUnwrap(GitHubAPIClient.slim(Data(#"{"tag_name": "v1.0.0"}"#.utf8)))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: slimmed) as? [String: Any])
        XCTAssertEqual(root["tag_name"] as? String, "v1.0.0")
        XCTAssertEqual(root["html_url"] as? String, "")
        XCTAssertEqual((root["assets"] as? [[String: Any]])?.count, 0)
    }

    func testSlimReturnsNilWithoutTagName() {
        XCTAssertNil(GitHubAPIClient.slim(Data(#"{"html_url": "https://github.com/x/y"}"#.utf8)))
        XCTAssertNil(GitHubAPIClient.slim(Data("not json".utf8)))
        XCTAssertNil(GitHubAPIClient.slim(Data(#"{"tag_name": ""}"#.utf8)), "空 tag_name 与没有等价")
    }
}

// MARK: - 探针 × 缓存联动

final class GitHubCacheProbeTests: XCTestCase {
    func testSecondProbeWithinTTLDoesZeroRequests() async throws {
        // 端到端：同一客户端喂两个探针实例（对应 ElectronProbe + GitHubReleaseProbe
        // 共享 GitHubAPIClient 的生产形态），第二次探测必须零请求。
        let clock = CacheClock()
        let http = RecordingHTTP(steps: [.init(200, etag: #""v1""#, releaseBody(tag: "v11.6.1"))])
        let (store, _) = makeStore()
        let gitHub = GitHubAPIClient(http: http, store: store, ttl: GitHubAPIClient.defaultTTL, now: { clock.date })

        let app = AppInfo(
            name: "AltTab",
            bundleID: "com.lwouis.alt-tab-macos",
            path: URL(fileURLWithPath: "/Applications/AltTab.app"),
            currentVersion: "11.4.3",
            buildVersion: nil,
            source: .githubRelease
        )
        let first = await GitHubReleaseProbe(gitHub: gitHub).probe(app)
        let second = await GitHubReleaseProbe(gitHub: gitHub).probe(app)

        XCTAssertEqual(first, second, "缓存命中必须给出与首查一致的结果")
        let calls = await http.calls
        XCTAssertEqual(calls.count, 1, "两次探测共用一条缓存，只允许一次请求")
    }
}
