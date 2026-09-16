import Foundation

/// `itunes.apple.com/lookup` 对单个 bundle ID 的查询结果。
///
/// 只留真正用得上的四个字段。响应里还有一大堆（图标、截图、分级、价格），
/// 这个工具一个都不需要——App Store 的安装与更新由系统负责，我们只负责
/// 回答"有没有新版本"这一个问题。
public struct MASLookupResult: Equatable, Sendable {
    public let bundleID: String
    /// 营销版本号（`CFBundleShortVersionString` 的口径），例如 `4.1.13`。
    public let version: String
    /// App Store 页面地址。这是**页面**不是安装包，所以 `PackageKind` 会是 `.unknown`。
    public let trackViewURL: URL?
    public let size: Int64?

    public init(bundleID: String, version: String, trackViewURL: URL?, size: Int64?) {
        self.bundleID = bundleID
        self.version = version
        self.trackViewURL = trackViewURL
        self.size = size
    }

    /// 解析响应体。`resultCount == 0`（应用不在该商店区）与畸形 JSON 都返回 `nil`。
    ///
    /// 注意接口对"查不到"返回的是 **HTTP 200 + 空数组**，不是 404。
    /// 调用方不能靠状态码判断，只能看这里有没有值。
    public static func parse(_ data: Data) -> MASLookupResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first,
              let version = first["version"] as? String,
              !version.isEmpty else {
            return nil
        }

        return MASLookupResult(
            bundleID: (first["bundleId"] as? String) ?? "",
            version: version,
            trackViewURL: (first["trackViewUrl"] as? String).flatMap(URL.init(string:)),
            size: size(from: first["fileSizeBytes"])
        )
    }

    /// `fileSizeBytes` 在响应里是**字符串**（`"13270176"`）。数字形态也一并认，
    /// 免得哪天接口改成数字就静默少一个尺寸。
    private static func size(from value: Any?) -> Int64? {
        if let text = value as? String { return Int64(text) }
        if let number = value as? NSNumber { return number.int64Value }
        return nil
    }
}

/// App Store 版本探测。
///
/// 走公开的 iTunes Lookup 接口：免费、无鉴权、无频率限制（单次检查最多十几个请求）。
/// 只能查到**版本号**，装不了也升不了——App Store 的包由系统与 `macappstore://` 体系管理，
/// 本工具不参与下载，`InstallAction` 会停在 `.openDownload`（打开 App Store 页面）。
public struct MASProbe: Sendable {
    private let client: HTTPFetching

    public init(client: HTTPFetching = HTTPClient.shared) {
        self.client = client
    }

    public func probe(_ app: AppInfo) async -> UpdateResult {
        guard let bundleID = app.bundleID, !bundleID.isEmpty else {
            return .unsupported(reason: "没有 Bundle ID，无法查询 App Store")
        }

        do {
            // 先用中国区商店。查不到再去掉 country 试一次——应用可能没在 CN 上架，
            // 或者用户本就不在国内。
            if let result = try await result(bundleID: bundleID, country: "cn") {
                return verdict(for: app, latest: result)
            }
            if let result = try await result(bundleID: bundleID, country: nil) {
                return verdict(for: app, latest: result)
            }
            // 有 `_MASReceipt` 却查不到，通常是已下架或已从商店区移除。如实说，不猜版本。
            return .unsupported(reason: "App Store 上查不到该应用")
        } catch {
            return .failed(reason: SparkleProbe.describe(error))
        }
    }

    private func result(bundleID: String, country: String?) async throws -> MASLookupResult? {
        // 固定 https 基址下构造失败不可能发生，这里保守返回 `nil` 而不是强解包。
        guard let url = Self.lookupURL(bundleID: bundleID, country: country) else { return nil }
        let data = try await client.data(from: url)
        return MASLookupResult.parse(data)
    }

    private func verdict(for app: AppInfo, latest: MASLookupResult) -> UpdateResult {
        // ⚠️ `buildVersion` 两边都必须传 `nil`。
        //
        // lookup 的响应里**没有** `bundleVersion` 字段，只有营销版本号 `version`。
        // 而本地 `CFBundleVersion` 常是 `255`、`58012001` 这种整数——
        // `VersionComparison` 一旦发现两边构建号都能解析成整数就会优先比构建号，
        // 那就成了"拿本地构建号去比一个不存在的对方构建号"，纯属错配。
        let isNewer = VersionComparison.isNewer(
            latest: .init(shortVersion: latest.version, buildVersion: nil),
            than: .init(shortVersion: app.currentVersion, buildVersion: nil)
        )

        guard isNewer else { return .upToDate(latest: latest.version) }

        return .updateAvailable(ReleaseInfo(
            version: latest.version,
            // App Store 页面链接。按钮会因此变成「下载」，点开是商店页而不是直接下包——
            // 这正是 `.appStore` 该有的行为。
            downloadURL: latest.trackViewURL,
            size: latest.size,
            releaseNotesURL: latest.trackViewURL
        ))
    }

    /// `bundleID` **原样拼进 query**，不做任何剥离。
    ///
    /// 2026-09-16 实测（别再想着加归一逻辑）：
    ///
    ///     bundleId=5ZSL2CJU2T.com.dingtalk.mac  →  resultCount 1   ← 带 team 前缀，原样命中
    ///     bundleId=com.dingtalk.mac             →  resultCount 0   ← 剥掉前缀反而查不到
    ///
    /// 而且剥前缀有**误匹配风险**：别的开发者可能注册了同名的反向域名，
    /// 剥完就可能查到另一个应用上去。宁可查不到，也不能查错。
    static func lookupURL(bundleID: String, country: String?) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        var items = [URLQueryItem(name: "bundleId", value: bundleID)]
        if let country, !country.isEmpty {
            items.append(URLQueryItem(name: "country", value: country))
        }
        components?.queryItems = items
        return components?.url
    }
}
