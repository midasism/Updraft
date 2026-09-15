import Foundation

/// 自更新检查的三态。失败如实报原因，绝不猜一个版本号。
public enum SelfUpdateStatus: Equatable, Sendable {
    case updateAvailable(SelfRelease)
    case upToDate(latest: String)
    case failed(reason: String)

    public var release: SelfRelease? {
        guard case .updateAvailable(let release) = self else { return nil }
        return release
    }
}

/// GitHub Release 上属于 Updraft 自己的那一版。
public struct SelfRelease: Equatable, Sendable {
    public var version: String
    public var downloadURL: URL
    public var size: Int64?
    public var sha256: String?
    public var manifestBytes: Data?
    public var manifestSignature: String?
    public var releaseNotesURL: URL?

    public init(
        version: String,
        downloadURL: URL,
        size: Int64? = nil,
        sha256: String? = nil,
        manifestBytes: Data? = nil,
        manifestSignature: String? = nil,
        releaseNotesURL: URL? = nil
    ) {
        self.version = version
        self.downloadURL = downloadURL
        self.size = size
        self.sha256 = sha256
        self.manifestBytes = manifestBytes
        self.manifestSignature = manifestSignature
        self.releaseNotesURL = releaseNotesURL
    }

    public var releaseInfo: ReleaseInfo {
        ReleaseInfo(
            version: version,
            downloadURL: downloadURL,
            size: size,
            edSignature: manifestSignature,
            releaseNotesURL: releaseNotesURL
        )
    }

    public var canVerifySignature: Bool {
        manifestBytes != nil && manifestSignature != nil && SelfUpdateIdentity.publicEDKey.isEmpty == false
    }
}

/// 读 GitHub Releases API，把 tag 和本机 `CFBundleShortVersionString` 比对。
///
/// 检测不认识 UI：这个类型只返回三态，界面自己决定怎么展示。
public struct SelfUpdateChecker: Sendable {
    private let client: any HTTPFetching
    private let latestURL: URL

    public init(client: any HTTPFetching = HTTPClient(), latestURL: URL = SelfUpdateIdentity.releasesLatestURL) {
        self.client = client
        self.latestURL = latestURL
    }

    public func check(currentVersion: String? = SelfUpdateIdentity.currentShortVersion) async -> SelfUpdateStatus {
        let current = currentVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !current.isEmpty else {
            return .failed(reason: "无法读取本机版本号")
        }

        do {
            let data = try await client.data(from: latestURL)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed(reason: "GitHub 返回内容无法解析")
            }
            return await interpret(json: json, currentVersion: current)
        } catch {
            return .failed(reason: Self.describe(error))
        }
    }

    private func interpret(json: [String: Any], currentVersion: String) async -> SelfUpdateStatus {
        guard let tag = json["tag_name"] as? String, !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(reason: "该仓库没有正式 Release")
        }
        let latest = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag

        let isNewer = VersionComparison.isNewer(
            latest: .init(shortVersion: latest, buildVersion: nil),
            than: .init(shortVersion: currentVersion, buildVersion: nil)
        )
        if !isNewer {
            return .upToDate(latest: latest)
        }

        let assets = (json["assets"] as? [[String: Any]]) ?? []
        guard let zip = Self.pickZip(from: assets) else {
            return .failed(reason: "Release 里没有 zip 安装包")
        }

        let notes = (json["html_url"] as? String).flatMap(URL.init(string:))
        var release = SelfRelease(
            version: latest,
            downloadURL: zip.url,
            size: zip.size,
            releaseNotesURL: notes
        )

        if let manifestAsset = Self.asset(named: "update.json", in: assets) {
            if let bytes = try? await client.data(from: manifestAsset.url) {
                release.manifestBytes = bytes
                release.sha256 = SelfUpdateManifest.parse(bytes)?.sha256
            }
        }
        if let sigAsset = Self.asset(named: "update.json.sig", in: assets),
           let sigData = try? await client.data(from: sigAsset.url) {
            release.manifestSignature = SelfUpdateManifest.signatureString(from: sigData)
        }

        return .updateAvailable(release)
    }

    struct Asset {
        let url: URL
        let size: Int64?
    }

    /// 只要自更新用的 zip：`Updraft-x.y.z-macOS.zip`，不要 dmg、不要源码包。
    static func pickZip(from assets: [[String: Any]]) -> Asset? {
        let zips: [(name: String, url: URL, size: Int64?)] = assets.compactMap { asset in
            guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".zip"),
                  let raw = asset["browser_download_url"] as? String, let url = URL(string: raw) else {
                return nil
            }
            if name.lowercased().contains("source") { return nil }
            let size = (asset["size"] as? NSNumber)?.int64Value
            return (name, url, size)
        }
        guard !zips.isEmpty else { return nil }

        let preferred = zips.first { $0.name.lowercased().hasPrefix("updraft-") && $0.name.lowercased().contains("macos") }
            ?? zips.first { $0.name.lowercased().hasPrefix("updraft-") }
            ?? zips[0]
        return Asset(url: preferred.url, size: preferred.size)
    }

    static func asset(named fileName: String, in assets: [[String: Any]]) -> Asset? {
        for asset in assets {
            guard let name = asset["name"] as? String, name == fileName,
                  let raw = asset["browser_download_url"] as? String, let url = URL(string: raw) else {
                continue
            }
            return Asset(url: url, size: (asset["size"] as? NSNumber)?.int64Value)
        }
        return nil
    }

    static func describe(_ error: Error) -> String {
        if let httpError = error as? HTTPError {
            if case .statusCode(403) = httpError {
                return "GitHub 接口触发频率限制"
            }
            if case .statusCode(404) = httpError {
                return "GitHub 返回 404，没有可用的 Release"
            }
            return httpError.errorDescription ?? "请求失败"
        }
        return SparkleProbe.describe(error)
    }
}
