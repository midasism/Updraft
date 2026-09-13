import Foundation

/// 走 Sparkle appcast 的应用更新探测。覆盖本机 32 个应用。
public struct SparkleProbe: Sendable {
    private let client: HTTPClient

    public init(client: HTTPClient = HTTPClient()) {
        self.client = client
    }

    public func probe(_ app: AppInfo) async -> UpdateResult {
        guard case .sparkle(let feedURL?) = app.source else {
            return .unsupported(reason: "没有可用的 appcast 地址")
        }

        do {
            let xml = try await client.string(from: feedURL)
            let appcast = AppcastParser.parse(xml)

            guard let latest = appcast.latestItem(), let latestVersion = latest.displayVersion else {
                return .failed(reason: "appcast 里没有版本条目")
            }

            let isNewer = VersionComparison.isNewer(
                latest: .init(shortVersion: latestVersion, buildVersion: latest.buildVersion),
                than: .init(shortVersion: app.currentVersion, buildVersion: app.buildVersion)
            )

            if isNewer {
                // 兜底：万一解析器将来又把增量补丁当成正式包，这里必须拦下来。
                // `.delta` 是二进制差分补丁，必须由 Sparkle 拿着旧包应用，单独下载永远装不上。
                if latest.downloadURL?.pathExtension.lowercased() == "delta" {
                    return .failed(reason: "更新源只提供了增量补丁，没有完整安装包")
                }

                return .updateAvailable(ReleaseInfo(
                    version: latestVersion,
                    downloadURL: latest.downloadURL,
                    size: latest.size,
                    edSignature: latest.edSignature,
                    releaseNotesURL: latest.releaseNotesURL
                ))
            }
            return .upToDate(latest: latestVersion)
        } catch {
            return .failed(reason: Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        if let httpError = error as? HTTPError {
            return httpError.errorDescription ?? "请求失败"
        }
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorTimedOut: return "请求超时"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "域名解析失败"
        case NSURLErrorNotConnectedToInternet: return "网络不可用"
        default: return nsError.localizedDescription
        }
    }
}
