import Foundation
import OSLog

/// 网络读取缝。生产走 `HTTPClient`，测试注入 stub，探针不直接碰 `URLSession`。
public protocol HTTPFetching: Sendable {
    func data(from url: URL) async throws -> Data

    /// 带状态码与响应头的读取。`data(from:)` 会把非 2xx 当错误抛掉，而 **304 是正常分支**
    /// （GitHub 条件请求的"没变化"），需要它的调用方走这里。
    ///
    /// - Parameters:
    ///   - headers: 附加请求头（如 `If-None-Match`）。实现方必须原样带上。
    /// - Returns: 原始状态码 + 响应体 + `ETag`。**不抛非 2xx**——状态码由调用方解释。
    func response(from url: URL, headers: [String: String]) async throws -> HTTPResponse
}

public extension HTTPFetching {
    /// 默认实现：走 `data(from:)`，状态码恒为 200、无响应头。
    ///
    /// 不关心状态码的测试桩可以完全不实现这个方法；要测 304 / ETag 的桩必须自己覆写，
    /// 否则会拿到"假 200"——这正是需要覆写的信号。
    func response(from url: URL, headers: [String: String]) async throws -> HTTPResponse {
        let data = try await self.data(from: url)
        return HTTPResponse(data: data, statusCode: 200, etag: nil)
    }

    func string(from url: URL) async throws -> String {
        let data = try await self.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HTTPError.notUTF8
        }
        return text
    }
}

/// `response(from:headers:)` 的返回值。
public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    /// 响应头里的 `ETag`（大小写不敏感查找）。条件请求的凭据，存下来供下次 `If-None-Match`。
    public let etag: String?

    public init(data: Data, statusCode: Int, etag: String?) {
        self.data = data
        self.statusCode = statusCode
        self.etag = etag
    }
}

/// 检查更新用到的所有网络请求都走这里，统一超时与 User-Agent。
///
/// ## 为什么默认用 `shared` 而不是各自新建会话
///
/// `URLSession` 有一条硬性约定：**要么让它自己失效，要么显式 `invalidateAndCancel()`**，
/// 否则它会一直持有自己的连接池与 delegate 队列。而 `HTTPClient` 是 struct，没有 `deinit`
/// 这个生命周期钩子——"用完自动释放"这条路根本不存在。
///
/// 于是"每次都 `HTTPClient()`"就变成了"每次自检都多留一份连接池"。单次泄漏量很小，
/// `leaks` 也读不出来（2026-09-16 实测确实是 0 leaks），但它没有上限：自检每天至少一次，
/// 一年下来就是几百份。修法不是给 struct 硬加析构，而是**别重复创建**。
///
/// 顺带的好处：全量检查要为几十个应用发 appcast 请求，共用一个会话才能复用连接。
/// 自定义超时（测试、离线场景）仍然可以自己 `HTTPClient(timeout:)` 造一个新的。
public struct HTTPClient: HTTPFetching, Sendable {
    /// 进程内共享的检查用会话。所有默认参数都指向它——新增探测入口时也请用它，
    /// 别再写 `HTTPClient()`。
    public static let shared = HTTPClient()

    public let session: URLSession

    public init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpAdditionalHeaders = ["User-Agent": SelfUpdateIdentity.userAgent]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Log.net.error("HTTP \(http.statusCode) — \(url.absoluteString)")
            throw HTTPError.statusCode(http.statusCode)
        }
        return data
    }

    public func response(from url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // 304 是条件请求的正常分支，不能当错误抛——调用方拿原始状态码自己解释。
        let (data, raw) = try await session.data(for: request)
        let http = raw as? HTTPURLResponse
        return HTTPResponse(
            data: data,
            statusCode: http?.statusCode ?? 200,
            etag: Self.headerValue("ETag", in: http?.allHeaderFields)
        )
    }

    /// `allHeaderFields` 的键大小写不保证，按名字不敏感查找。
    static func headerValue(_ name: String, in fields: [AnyHashable: Any]?) -> String? {
        guard let fields else { return nil }
        for (key, value) in fields where (key as? String)?.lowercased() == name.lowercased() {
            return value as? String
        }
        return nil
    }
}

public enum HTTPError: LocalizedError {
    case statusCode(Int)
    case notUTF8

    public var errorDescription: String? {
        switch self {
        case .statusCode(let code): return "HTTP \(code)"
        case .notUTF8: return "响应不是 UTF-8 文本"
        }
    }
}
