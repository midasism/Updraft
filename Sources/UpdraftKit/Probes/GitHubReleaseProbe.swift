import Foundation

/// GitHub `/releases/latest` 对单个仓库的查询结果。
///
/// 只留用得上的四个字段。响应里还有 body、author、上千条 asset 明细，
/// 这个工具只需要回答"有没有新版本"，加上一个给确认页看的下载体积。
public struct GitHubReleaseInfo: Equatable, Sendable {
    /// 原始 tag（如 `v0.8.98`、`core@13.2.0`）。仅存档，比较与展示都用 `version`。
    public let tagName: String
    /// 归一后的版本号（`0.8.98`、`13.2.0`）。归一失败时不会有这个值。
    public let version: String
    /// Release 页面地址。按钮会停在「下载」，点开是这一页而不是直接下包。
    public let htmlURL: URL?
    /// assets 里最大的 `.dmg`/`.zip` 体积；没有 macOS 安装包时为 `nil`（界面就不显示体积）。
    public let macAssetSize: Int64?

    public init(tagName: String, version: String, htmlURL: URL?, macAssetSize: Int64?) {
        self.tagName = tagName
        self.version = version
        self.htmlURL = htmlURL
        self.macAssetSize = macAssetSize
    }

    /// 解析响应体。没有 `tag_name` 或 tag 归一不出版本号时返回 `nil`。
    ///
    /// 注意 GitHub 的 release body 里**可能带裸控制字符**（2026-09-16 在 6 个仓库里全遇到了），
    /// 严格的 JSON 解析器会挂；`JSONSerialization` 对此宽容，但别换成第三方严格解析器。
    public static func parse(_ data: Data) -> GitHubReleaseInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              !tag.isEmpty,
              let version = GitHubReleaseProbe.version(fromTag: tag) else {
            return nil
        }

        return GitHubReleaseInfo(
            tagName: tag,
            version: version,
            htmlURL: (root["html_url"] as? String).flatMap(URL.init(string:)),
            macAssetSize: largestMacAssetSize(root["assets"] as? [[String: Any]] ?? [])
        )
    }

    /// assets 里最大的 macOS 安装包体积。`.dmg`/`.zip` 之外的一概不认——
    /// `.sha256`、`.sig`、`.AppImage` 这类要么不是安装包要么不是给 macOS 的。
    private static func largestMacAssetSize(_ assets: [[String: Any]]) -> Int64? {
        let sizes = assets.compactMap { asset -> Int64? in
            guard let name = asset["name"] as? String,
                  name.lowercased().hasSuffix(".dmg") || name.lowercased().hasSuffix(".zip"),
                  let number = asset["size"] as? NSNumber else { return nil }
            return number.int64Value
        }
        return sizes.max()
    }
}

/// GitHub Release 版本探测。
///
/// 走公开的 `api.github.com/repos/<owner>/<repo>/releases/latest`：免费、无鉴权
/// （未登录限额 60 次/小时，本工具每轮最多几个请求，够用）。
/// 仓库范围由 `GitHubReleaseCatalog` 白名单决定，表里没有的应用不会走到这里。
///
/// 与 App Store 同一条红线：**只查不装**。GitHub 的包没有本工具的 Ed25519 清单，
/// `Installer` 三道校验的第一道就过不去，`InstallAction` 停在 `.openDownload`（打开 Release 页）。
public struct GitHubReleaseProbe: Sendable {
    private let client: HTTPFetching

    public init(client: HTTPFetching = HTTPClient.shared) {
        self.client = client
    }

    public func probe(_ app: AppInfo) async -> UpdateResult {
        guard let bundleID = app.bundleID, !bundleID.isEmpty else {
            return .unsupported(reason: "没有 Bundle ID，无法查询 GitHub Release")
        }
        guard let repo = GitHubReleaseCatalog.repo(forBundleID: bundleID) else {
            // 分类器不该把白名单外的应用送到这里；真到了只能如实说。
            return .unsupported(reason: "不在 GitHub Release 白名单内")
        }
        guard let url = GitHubReleaseCatalog.latestReleaseURL(bundleID: bundleID) else {
            return .unsupported(reason: "无法构造 GitHub API 地址")
        }

        let data: Data
        do {
            data = try await client.data(from: url)
        } catch {
            // 403 在 GitHub 这里几乎只有一种含义：未鉴权限额（60 次/小时）。
            // 如实说出来，别让它混进笼统的"HTTP 403"里让人摸不着头脑。
            if let httpError = error as? HTTPError, case .statusCode(let code) = httpError {
                if code == 403 {
                    return .failed(reason: "GitHub API 限额（未登录每小时 60 次），稍后再试")
                }
                if code == 404 {
                    return .unsupported(reason: "GitHub 仓库不存在或已改名（\(repo)）")
                }
            }
            return .failed(reason: SparkleProbe.describe(error))
        }

        guard let info = GitHubReleaseInfo.parse(data) else {
            return .unsupported(reason: "GitHub Release 响应里没有可辨认的版本号")
        }

        // ⚠️ `buildVersion` 两边都必须传 `nil`。
        //
        // GitHub 响应里没有构建号；而本地 `CFBundleVersion` 在这类应用里是时间戳/日期
        // （Zed `20260909.162449`、FlClash `2025122201`），拿它跟"不存在"比就是错配。
        // 与 MASProbe 同一条约束。
        let isNewer = VersionComparison.isNewer(
            latest: .init(shortVersion: info.version, buildVersion: nil),
            than: .init(shortVersion: app.currentVersion, buildVersion: nil)
        )

        guard isNewer else { return .upToDate(latest: info.version) }

        return .updateAvailable(ReleaseInfo(
            version: info.version,
            // Release 页面链接。按钮因此是「下载」而不是「升级」——我们不装 GitHub 的包。
            downloadURL: info.htmlURL,
            size: info.macAssetSize,
            releaseNotesURL: info.htmlURL
        ))
    }

    /// tag → 版本号归一。**探针里做，不能指望 `Version`**：
    ///
    /// - `v0.8.98`  → `0.8.98`。`Version` 虽然自己会剥 `v`，但归一后的值还要上界面，
    ///   别让 `0.8.91 → v0.8.98` 这种写法露出去。
    /// - `core@13.2.0` → `13.2.0`。⚠️ 这一步必须在探针里做：`Version` 会把 `core@13.2.0`
    ///   解析成 `[0, 2, 0]`，跟 `13.0.2` 一比反而判成"本地更新"——Insomnia 会被静默漏掉
    ///   （2026-09-16 实测确认过这条路径）。
    /// - `release-1.2.3` 之类剥不出版本号的 → `nil`。宁可少报，不可错报。
    static func version(fromTag tag: String) -> String? {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        // `包名@版本` 形态：取最后一段 `@` 之后的才是版本号。
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        if let first = text.first, first == "v" || first == "V" {
            text = String(text.dropFirst())
        }
        // 剥完必须以数字开头才算归一成功。空串、纯字母 tag 都在这里被拦下。
        guard let first = text.first, first.isNumber else { return nil }
        return text
    }
}
