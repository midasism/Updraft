import Foundation

/// 检查更新用到的所有网络请求都走这里，统一超时与 User-Agent。
public struct HTTPClient: Sendable {
    public let session: URLSession

    public init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpAdditionalHeaders = ["User-Agent": "AppUpdater/0.1 (macOS)"]
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

    public func string(from url: URL) async throws -> String {
        let data = try await self.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HTTPError.notUTF8
        }
        return text
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
