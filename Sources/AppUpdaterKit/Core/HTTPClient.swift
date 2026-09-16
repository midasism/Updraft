import Foundation

/// 网络读取缝。生产走 `HTTPClient`，测试注入 stub，探针不直接碰 `URLSession`。
public protocol HTTPFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

extension HTTPFetching {
    public func string(from url: URL) async throws -> String {
        let data = try await self.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HTTPError.notUTF8
        }
        return text
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
        configuration.httpAdditionalHeaders = ["User-Agent": "AppUpdater/0.3 (macOS)"]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.statusCode(http.statusCode)
        }
        return data
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
