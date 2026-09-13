import Foundation

/// `Contents/Resources/app-update.yml` 的解析结果。
public struct ElectronFeed: Equatable, Sendable {
    public enum Provider: Equatable, Sendable {
        case gitHub(owner: String, repo: String)
        case generic(baseURL: URL, channel: String)
        /// 能认出来但不支持查询。
        case other(String)
    }

    public var provider: Provider
    public var channel: String

    /// 手写解析即可：这个文件是扁平的 `key: value`，为它引一个 YAML 依赖不划算。
    public static func parse(_ yaml: String) -> ElectronFeed? {
        var values: [String: String] = [:]
        for line in yaml.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }

        let channel = values["channel"] ?? "latest"
        guard let rawProvider = values["provider"]?.lowercased(), !rawProvider.isEmpty else {
            // 连 provider 都没有，这个文件对我们没有意义。
            return nil
        }

        switch rawProvider {
        case "github":
            guard let owner = values["owner"], let repo = values["repo"],
                  !owner.isEmpty, !repo.isEmpty else { return nil }
            return ElectronFeed(provider: .gitHub(owner: owner, repo: repo), channel: channel)

        case "generic":
            // 本机实测有应用把 url 填成空串或内网地址，只能如实降级为不支持。
            guard let raw = values["url"]?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else { return nil }
            return ElectronFeed(provider: .generic(baseURL: url, channel: channel), channel: channel)

        default:
            // s3 / spaces 之类只有 bucket、region，拼不出可访问的地址，不猜。
            return ElectronFeed(provider: .other(rawProvider), channel: channel)
        }
    }
}

/// Electron 应用更新探测。覆盖本机 15 个应用。
public struct ElectronProbe: Sendable {
    private let client: HTTPClient

    public init(client: HTTPClient = HTTPClient()) {
        self.client = client
    }

    public func probe(_ app: AppInfo) async -> UpdateResult {
        let ymlURL = app.path.appendingPathComponent("Contents/Resources/app-update.yml")
        guard let yaml = try? String(contentsOf: ymlURL, encoding: .utf8) else {
            return .unsupported(reason: "读不到 app-update.yml")
        }
        guard let feed = ElectronFeed.parse(yaml) else {
            return .unsupported(reason: "app-update.yml 里没有可用更新源")
        }

        switch feed.provider {
        case .gitHub(let owner, let repo):
            return await probeGitHub(app: app, owner: owner, repo: repo)
        case .generic(let baseURL, let channel):
            return await probeGeneric(app: app, baseURL: baseURL, channel: channel)
        case .other(let name):
            return .unsupported(reason: "Electron 更新源 \(name) 没有可用的公开地址")
        }
    }

    private func probeGitHub(app: AppInfo, owner: String, repo: String) async -> UpdateResult {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            return .failed(reason: "更新源地址非法")
        }

        do {
            let data = try await client.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed(reason: "GitHub 返回内容无法解析")
            }

            guard let tag = json["tag_name"] as? String else {
                return .failed(reason: "该仓库没有正式 Release")
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

            let assets = (json["assets"] as? [[String: Any]]) ?? []
            let asset = Self.pickAsset(from: assets)

            let isNewer = VersionComparison.isNewer(
                latest: .init(shortVersion: latest, buildVersion: nil),
                than: .init(shortVersion: app.currentVersion, buildVersion: nil)
            )

            if isNewer {
                return .updateAvailable(
                    latest: latest,
                    downloadURL: asset?.url,
                    releaseNotesURL: (json["html_url"] as? String).flatMap(URL.init(string:)),
                    downloadSize: asset?.size
                )
            }
            return .upToDate(latest: latest)
        } catch {
            if let httpError = error as? HTTPError, case .statusCode(403) = httpError {
                return .failed(reason: "GitHub 接口触发频率限制")
            }
            if let httpError = error as? HTTPError, case .statusCode(404) = httpError {
                return .unsupported(reason: "仓库不存在或没有 Release")
            }
            return .failed(reason: SparkleProbe.describe(error))
        }
    }

    private func probeGeneric(app: AppInfo, baseURL: URL, channel: String) async -> UpdateResult {
        let fileName = "\(channel)-mac.yml"
        let url = baseURL.appendingPathComponent(fileName)

        do {
            let text = try await client.string(from: url)
            guard let version = Self.yamlValue("version", in: text) else {
                return .failed(reason: "\(fileName) 里没有版本号")
            }

            var downloadURL: URL?
            if let path = Self.yamlValue("path", in: text) {
                downloadURL = URL(string: path, relativeTo: baseURL)?.absoluteURL
            }
            if downloadURL == nil {
                downloadURL = Self.firstFileURL(in: text, relativeTo: baseURL)
            }

            let size = Self.firstFileSize(in: text)

            let isNewer = VersionComparison.isNewer(
                latest: .init(shortVersion: version, buildVersion: nil),
                than: .init(shortVersion: app.currentVersion, buildVersion: nil)
            )

            if isNewer {
                return .updateAvailable(
                    latest: version,
                    downloadURL: downloadURL,
                    releaseNotesURL: nil,
                    downloadSize: size
                )
            }
            return .upToDate(latest: version)
        } catch {
            if let httpError = error as? HTTPError, case .statusCode(404) = httpError {
                return .unsupported(reason: "更新源上没有 \(fileName)")
            }
            return .failed(reason: SparkleProbe.describe(error))
        }
    }

    // MARK: - 解析与挑选

    struct Asset {
        let url: URL
        let size: Int64?
    }

    /// 优先 dmg（给人装的），其次 zip（Squirrel.Mac 用的），再按本机架构挑。
    static func pickAsset(from assets: [[String: Any]]) -> Asset? {
        let candidates: [(name: String, url: String, size: Int64?)] = assets.compactMap { asset in
            guard let name = asset["name"] as? String,
                  let rawURL = asset["browser_download_url"] as? String,
                  name.hasSuffix(".dmg") || name.hasSuffix(".zip") else { return nil }
            let size = (asset["size"] as? NSNumber)?.int64Value
            return (name, rawURL, size)
        }

        var pool = candidates.filter { $0.name.hasSuffix(".dmg") }
        if pool.isEmpty { pool = candidates }
        guard !pool.isEmpty else { return nil }

        #if arch(arm64)
        let archHint = "arm64"
        #else
        let archHint = "x64"
        #endif

        let preferred = pool.first { $0.name.lowercased().contains(archHint) } ?? pool[0]
        guard let url = URL(string: preferred.url) else { return nil }
        return Asset(url: url, size: preferred.size)
    }

    static func yamlValue(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            let value = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func firstFileURL(in text: String, relativeTo base: URL) -> URL? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- url:") else { continue }
            let value = trimmed.dropFirst("- url:".count).trimmingCharacters(in: .whitespaces)
            return URL(string: value, relativeTo: base)?.absoluteURL
        }
        return nil
    }

    static func firstFileSize(in text: String) -> Int64? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("size:") else { continue }
            let value = trimmed.dropFirst("size:".count).trimmingCharacters(in: .whitespaces)
            if let size = Int64(value) { return size }
        }
        return nil
    }
}
