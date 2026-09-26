import Foundation

/// 本应用自己的更新检测。
///
/// 走 GitHub Releases 的公开接口，不占版本库、不需要 token。相比给自家产品也塞一份
/// appcast，这条路的好处是**发版就是打 tag**——已经在跑的发布流水线一个字都不用改。
public struct SelfUpdateChecker: Sendable {
    private let client: HTTPClient
    private let cache: SelfUpdateCache?

    public init(client: HTTPClient = HTTPClient(), cache: SelfUpdateCache? = SelfUpdateCache()) {
        self.client = client
        self.cache = cache
    }

    /// 查一次最新版本。
    ///
    /// - Parameter force: 为 false 时，距上次检查不足节流窗口就直接用缓存，
    ///   免得每次启动都去敲 GitHub 的门（未认证接口每小时只有 60 次）。
    public func check(currentVersion: String, force: Bool = false) async -> SelfUpdateResult {
        if !force, let cached = cache?.load(currentVersion: currentVersion) {
            return cached.result
        }

        let result = await fetch(currentVersion: currentVersion)

        // 失败不落盘：一次网络抖动不该让用户接下来几小时都看不到新版本。
        if case .failed = result {} else {
            cache?.save(SelfUpdateCache.Entry(result: result, currentVersion: currentVersion, checkedAt: Date()))
        }
        return result
    }

    private func fetch(currentVersion: String) async -> SelfUpdateResult {
        do {
            let data = try await client.data(from: SelfIdentity.releasesAPI)
            return Self.parseRelease(data, currentVersion: currentVersion)
        } catch {
            if let httpError = error as? HTTPError, case .statusCode(403) = httpError {
                return .failed(reason: "GitHub 接口触发频率限制，稍后再试")
            }
            if let httpError = error as? HTTPError, case .statusCode(404) = httpError {
                return .failed(reason: "仓库还没有发布过正式 Release")
            }
            return .failed(reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - 解析

    /// 把 `/releases/latest` 的响应体解析成检测结果。
    ///
    /// 独立成静态方法是为了能在不联网的前提下把返回值的各种形状都测一遍——
    /// 这段逻辑的全部风险都在"字段缺失或长得不一样"上。
    static func parseRelease(_ data: Data, currentVersion: String) -> SelfUpdateResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed(reason: "GitHub 返回内容无法解析")
        }
        guard let tag = json["tag_name"] as? String, !tag.isEmpty else {
            return .failed(reason: "Release 里没有版本标签")
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        guard VersionComparison.isNewer(
            latest: .init(shortVersion: latest, buildVersion: nil),
            than: .init(shortVersion: currentVersion, buildVersion: nil)
        ) else {
            return .upToDate(current: currentVersion, latest: latest)
        }

        let assets = (json["assets"] as? [[String: Any]]) ?? []
        guard let asset = pickAsset(from: assets) else {
            return .failed(reason: "Release v\(latest) 里没有可用的安装包")
        }

        return .available(SelfUpdateRelease(
            version: latest,
            tag: tag,
            assetName: asset.name,
            downloadURL: asset.url,
            packageKind: PackageKind(url: asset.url),
            size: asset.size,
            releaseNotesURL: (json["html_url"] as? String).flatMap(URL.init(string:)),
            publishedAt: (json["published_at"] as? String).flatMap(parseISO8601),
            // 校验和与签名按"资产名 + 后缀"的约定找，找不到就是 nil，绝不猜地址。
            checksumURL: assetURL(named: "SHA256SUMS.txt", in: assets),
            apiDigest: asset.digest,
            signatureURL: assetURL(named: "\(asset.name).ed25519", in: assets)
        ))
    }

    struct Asset {
        let name: String
        let url: URL
        let size: Int64?
        let digest: String?
    }

    /// 挑安装包：**zip 优先**，其次 dmg。
    ///
    /// 与 `ElectronProbe.pickAsset` 的偏好正好相反是有原因的：那条路是"给用户装别人家应用"，
    /// dmg 有拖拽安装窗口，体验更好；这条路的包要由本进程自己拆开替换自己，
    /// zip 少一次 `hdiutil` 挂载与卸载，出错的面就小一圈。而两个包的内容是一致的。
    static func pickAsset(from assets: [[String: Any]]) -> Asset? {
        let candidates: [Asset] = assets.compactMap { asset in
            guard let name = asset["name"] as? String,
                  let rawURL = asset["browser_download_url"] as? String,
                  let url = URL(string: rawURL) else { return nil }
            let lower = name.lowercased()
            guard lower.hasSuffix(".zip") || lower.hasSuffix(".dmg") else { return nil }
            return Asset(
                name: name,
                url: url,
                size: (asset["size"] as? NSNumber)?.int64Value,
                digest: asset["digest"] as? String
            )
        }
        guard !candidates.isEmpty else { return nil }

        let zips = candidates.filter { $0.name.lowercased().hasSuffix(".zip") }
        let pool = zips.isEmpty ? candidates : zips

        #if arch(arm64)
        let archHint = "arm64"
        #else
        let archHint = "x64"
        #endif
        // 包名里带架构后缀时挑对的那一个；都没写就按顺序取第一个。
        return pool.first { $0.name.lowercased().contains(archHint) } ?? pool[0]
    }

    private static func assetURL(named name: String, in assets: [[String: Any]]) -> URL? {
        for asset in assets where (asset["name"] as? String) == name {
            if let raw = asset["browser_download_url"] as? String { return URL(string: raw) }
        }
        return nil
    }

    /// 解析 `shasum -a 256` 的输出。行格式是 `<64 位十六进制><空白><文件名>`，
    /// 文件名可能带 `dist/` 之类的前缀（早期产物），所以按 basename 归一。
    static func parseChecksums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let digest = String(parts[0]).lowercased()
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { continue }
            // 文件名里可能有空格（虽然我们没有），所以把剩下的部分原样拼回去。
            let name = parts.dropFirst().joined(separator: " ")
            result[(name as NSString).lastPathComponent] = digest
        }
        return result
    }
}

private let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private func parseISO8601(_ value: String) -> Date? {
    iso8601Formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

/// 自更新检查结果的落盘缓存。
///
/// 存在的唯一理由是**节流**：GitHub 未认证接口每小时 60 次，
/// 而本应用每次启动都会查一次。没有缓存的话，一天开关二十次窗口就可能把额度耗光，
/// 之后所有检查都会变成"触发频率限制"——那才是真的查不出更新。
public struct SelfUpdateCache: Sendable {
    /// 缓存有效期。发版是低频事件，3 小时足够新鲜；菜单里的「检查更新」和 CLI 都会强制刷新。
    public static let throttle: TimeInterval = 3 * 3600

    public struct Entry: Sendable {
        public let result: SelfUpdateResult
        public let currentVersion: String
        public let checkedAt: Date

        public init(result: SelfUpdateResult, currentVersion: String, checkedAt: Date) {
            self.result = result
            self.currentVersion = currentVersion
            self.checkedAt = checkedAt
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
                .appendingPathComponent("self-update.json")
        }
    }

    /// 读到一份仍在有效期内、且对得上当前版本的缓存才返回。
    ///
    /// - Parameter currentVersion: 传了就顺手校验版本是否一致。刚升完级的那个实例
    ///   拿 0.3.0 去读 0.2.1 写下的"有新版本 0.3.0"缓存，是会得出错误结论的。
    public func load(currentVersion: String? = nil, now: Date = Date()) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checkedAt = (raw["checkedAt"] as? NSNumber)?.doubleValue,
              let storedVersion = raw["currentVersion"] as? String,
              let version = raw["version"] as? String,
              let result = Self.decode(raw, fallbackVersion: version) else {
            return nil
        }
        if let currentVersion, storedVersion != currentVersion { return nil }

        let date = Date(timeIntervalSince1970: checkedAt)
        guard now.timeIntervalSince(date) < Self.throttle, now >= date else { return nil }
        return Entry(result: result, currentVersion: storedVersion, checkedAt: date)
    }

    public func save(_ entry: Entry) {
        var payload: [String: Any] = [
            "checkedAt": entry.checkedAt.timeIntervalSince1970,
            "currentVersion": entry.currentVersion
        ]
        switch entry.result {
        case .upToDate(let current, let latest):
            payload["outcome"] = "upToDate"
            payload["version"] = latest
            payload["current"] = current
        case .available(let release):
            payload["outcome"] = "available"
            payload["version"] = release.version
            payload["tag"] = release.tag
            payload["assetName"] = release.assetName
            payload["downloadURL"] = release.downloadURL.absoluteString
            payload["size"] = release.size
            if let notes = release.releaseNotesURL { payload["releaseNotesURL"] = notes.absoluteString }
            if let checksum = release.checksumURL { payload["checksumURL"] = checksum.absoluteString }
            if let signature = release.signatureURL { payload["signatureURL"] = signature.absoluteString }
            if let digest = release.apiDigest { payload["apiDigest"] = digest }
            if let published = release.publishedAt { payload["publishedAt"] = published.timeIntervalSince1970 }
        case .failed:
            return
        }

        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func decode(_ raw: [String: Any], fallbackVersion: String) -> SelfUpdateResult? {
        switch raw["outcome"] as? String {
        case "upToDate":
            return .upToDate(current: raw["current"] as? String ?? "", latest: fallbackVersion)
        case "available":
            guard let tag = raw["tag"] as? String,
                  let assetName = raw["assetName"] as? String,
                  let download = (raw["downloadURL"] as? String).flatMap(URL.init(string:)) else {
                return nil
            }
            return .available(SelfUpdateRelease(
                version: fallbackVersion,
                tag: tag,
                assetName: assetName,
                downloadURL: download,
                packageKind: PackageKind(url: download),
                size: (raw["size"] as? NSNumber)?.int64Value,
                releaseNotesURL: (raw["releaseNotesURL"] as? String).flatMap(URL.init(string:)),
                publishedAt: (raw["publishedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                checksumURL: (raw["checksumURL"] as? String).flatMap(URL.init(string:)),
                apiDigest: raw["apiDigest"] as? String,
                signatureURL: (raw["signatureURL"] as? String).flatMap(URL.init(string:))
            ))
        default:
            return nil
        }
    }
}
