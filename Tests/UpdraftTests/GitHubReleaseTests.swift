import XCTest
@testable import UpdraftKit

// MARK: - 假缝与夹具

/// 按顺序回放响应体的假缝（与 MASLookupTests 里的 FakeHTTP 同款，但独立定义，互不干扰）。
private actor GitHubFakeHTTP: HTTPFetching {
    private let bodies: [Data]
    private var index = 0
    private var requestedURLs: [URL] = []

    init(bodies: [String]) {
        precondition(!bodies.isEmpty, "至少要有一个响应体")
        self.bodies = bodies.map { Data($0.utf8) }
    }

    var requested: [URL] { requestedURLs }

    func data(from url: URL) async throws -> Data {
        let body = bodies[min(index, bodies.count - 1)]
        index += 1
        requestedURLs.append(url)
        return body
    }
}

/// 固定状态码的假缝，用来断言 403/404 被分类成不同的结果形态。
private struct GitHubStatusHTTP: HTTPFetching {
    let code: Int
    func data(from url: URL) async throws -> Data {
        throw HTTPError.statusCode(code)
    }
}

/// 取自真实响应的形状（AltTab）：assets 里混着 `.dmg`/`.zip`/源码包，只认前两个。
private let altTabRelease = """
{
  "url": "https://api.github.com/repos/lwouis/alt-tab-macos/releases/1",
  "tag_name": "v11.6.1",
  "html_url": "https://github.com/lwouis/alt-tab-macos/releases/tag/v11.6.1",
  "prerelease": false,
  "draft": false,
  "body": "## Highlights\\r\\n- fix: something",
  "assets": [
    { "name": "AltTab-v11.6.1.dmg", "size": 11429431 },
    { "name": "AltTab-v11.6.1.zip", "size": 12831292 },
    { "name": "source.code.tar.gz", "size": 340000 }
  ]
}
"""

/// Insomnia 的 tag 是 `包名@版本` 形态——`Version` 归一不了它，必须在探针里剥。
private let insomniaRelease = """
{
  "tag_name": "core@13.2.0",
  "html_url": "https://github.com/Kong/insomnia/releases/tag/core%4013.2.0",
  "assets": [
    { "name": "Insomnia-13.2.0.dmg", "size": 105000000 },
    { "name": "insomnia-13.2.0.arm64.rpm", "size": 99000000 }
  ]
}
"""

private func ghApp(
    _ name: String = "AltTab",
    bundleID: String? = "com.lwouis.alt-tab-macos",
    version: String? = "11.4.3",
    build: String? = "11.4.3"
) -> AppInfo {
    AppInfo(
        name: name,
        bundleID: bundleID,
        path: URL(fileURLWithPath: "/Applications/\(name).app"),
        currentVersion: version,
        buildVersion: build,
        source: .githubRelease
    )
}

// MARK: - tag 归一

final class GitHubTagNormalizationTests: XCTestCase {
    func testStripsVPrefix() {
        XCTAssertEqual(GitHubReleaseProbe.version(fromTag: "v11.6.1"), "11.6.1")
        XCTAssertEqual(GitHubReleaseProbe.version(fromTag: "V2.5.2"), "2.5.2")
    }

    func testStripsPackageAtPrefix() {
        // Insomnia：`core@13.2.0`。⚠️ 这条是防回归断言——`Version` 会把 `core@13.2.0`
        // 解析成 [0, 2, 0]，不剥前缀的话 13.0.2 → 13.2.0 会被判成"本地更新"。
        XCTAssertEqual(GitHubReleaseProbe.version(fromTag: "core@13.2.0"), "13.2.0")
    }

    func testKeepsPlainVersion() {
        XCTAssertEqual(GitHubReleaseProbe.version(fromTag: "26.2.0"), "26.2.0")
        XCTAssertEqual(GitHubReleaseProbe.version(fromTag: "  v0.8.98  "), "0.8.98")
    }

    func testKeepsPrereleaseSuffixForVersionToCompare() {
        // 后缀不剥，交给 `Version` 按预发布规则比较。
        XCTAssertEqual(GitHubReleaseProbe.version(fromTag: "v2.1.0-beta.2"), "2.1.0-beta.2")
    }

    func testUnnormalizableTagsYieldNil() {
        XCTAssertNil(GitHubReleaseProbe.version(fromTag: "release-1.2.3"))
        XCTAssertNil(GitHubReleaseProbe.version(fromTag: ""))
        XCTAssertNil(GitHubReleaseProbe.version(fromTag: "   "))
        XCTAssertNil(GitHubReleaseProbe.version(fromTag: "v"))
        XCTAssertNil(GitHubReleaseProbe.version(fromTag: "@"))
        XCTAssertNil(GitHubReleaseProbe.version(fromTag: "latest"))
    }
}

// MARK: - 响应解析

final class GitHubReleaseParsingTests: XCTestCase {
    func testParsesTagVersionURLAndLargestMacAsset() throws {
        let result = try XCTUnwrap(GitHubReleaseInfo.parse(Data(altTabRelease.utf8)))
        XCTAssertEqual(result.tagName, "v11.6.1")
        XCTAssertEqual(result.version, "11.6.1")
        XCTAssertEqual(result.htmlURL?.host, "github.com")
        // zip 比 dmg 大，源码包不算 macOS 安装包。
        XCTAssertEqual(result.macAssetSize, 12_831_292)
    }

    func testParsesPackageAtTag() throws {
        let result = try XCTUnwrap(GitHubReleaseInfo.parse(Data(insomniaRelease.utf8)))
        XCTAssertEqual(result.version, "13.2.0")
        // `.rpm` 不算 macOS 安装包，体积只取 dmg。
        XCTAssertEqual(result.macAssetSize, 105_000_000)
    }

    func testMissingTagNameYieldsNil() {
        let body = #"{"html_url": "https://github.com/x/y"}"#
        XCTAssertNil(GitHubReleaseInfo.parse(Data(body.utf8)))
    }

    func testUnnormalizableTagNameYieldsNil() {
        let body = #"{"tag_name": "release-1.2.3", "html_url": "https://github.com/x/y"}"#
        XCTAssertNil(GitHubReleaseInfo.parse(Data(body.utf8)))
    }

    func testMalformedBodyYieldsNil() {
        XCTAssertNil(GitHubReleaseInfo.parse(Data("not json".utf8)))
        XCTAssertNil(GitHubReleaseInfo.parse(Data()))
    }

    func testNoAssetsYieldsNilSize() {
        let body = #"{"tag_name": "v1.0.0", "html_url": "https://github.com/x/y", "assets": []}"#
        let result = GitHubReleaseInfo.parse(Data(body.utf8))
        XCTAssertEqual(result?.macAssetSize, nil)
    }
}

// MARK: - 探针行为

final class GitHubProbeTests: XCTestCase {
    func testUpdateAvailableStripsVFromDisplayedVersion() async {
        let http = GitHubFakeHTTP(bodies: [altTabRelease])
        let result = await GitHubReleaseProbe(client: http).probe(ghApp())

        guard case .updateAvailable(let release) = result else {
            return XCTFail("11.4.3 → v11.6.1 应判可更新，实际 \(result)")
        }
        // 展示层不要 `v` 前缀：`0.8.91 → 0.8.98` 而不是 `0.8.91 → v0.8.98`。
        XCTAssertEqual(release.version, "11.6.1")
        XCTAssertEqual(release.downloadURL?.host, "github.com")
        XCTAssertEqual(release.size, 12_831_292)
        let urls = await http.requested
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.absoluteString,
                       "https://api.github.com/repos/lwouis/alt-tab-macos/releases/latest")
    }

    func testUpToDateIgnoresVPrefixMismatch() async {
        // Zed：本地 1.19.2，远端 v1.19.2。写法不同，版本相同。
        let http = GitHubFakeHTTP(bodies: [altTabRelease])
        let result = await GitHubReleaseProbe(client: http).probe(ghApp(version: "11.6.1"))
        XCTAssertEqual(result, .upToDate(latest: "11.6.1"))
    }

    func testLocalNewerDoesNotInduceDowngrade() async {
        let http = GitHubFakeHTTP(bodies: [altTabRelease])
        let result = await GitHubReleaseProbe(client: http).probe(ghApp(version: "12.0.0"))
        XCTAssertEqual(result, .upToDate(latest: "11.6.1"))
    }

    func testPackageAtTagStillDetectsUpdate() async {
        // Insomnia：13.0.2 → core@13.2.0。不剥 @ 前缀的话这里会静默判成"已最新"。
        let http = GitHubFakeHTTP(bodies: [insomniaRelease])
        let result = await GitHubReleaseProbe(client: http)
            .probe(ghApp("Insomnia", bundleID: "com.insomnia.app", version: "13.0.2"))
        guard case .updateAvailable(let release) = result else {
            return XCTFail("Insomnia 13.0.2 → 13.2.0 应判可更新，实际 \(result)")
        }
        XCTAssertEqual(release.version, "13.2.0")
    }

    func testUnknownLocalVersionDoesNotReportUpdate() async {
        let http = GitHubFakeHTTP(bodies: [altTabRelease])
        let result = await GitHubReleaseProbe(client: http).probe(ghApp(version: nil))
        XCTAssertEqual(result, .upToDate(latest: "11.6.1"))
    }

    func testBuildVersionIsNeverCompared() async {
        // Zed/FlClash 的本地构建号是时间戳/日期形态，GitHub 响应里没有对应字段。
        // 本地 build 故意给个大数，same short version 必须仍是"已最新"。
        let http = GitHubFakeHTTP(bodies: [altTabRelease])
        let result = await GitHubReleaseProbe(client: http).probe(ghApp(version: "11.6.1", build: "20260909"))
        XCTAssertEqual(result, .upToDate(latest: "11.6.1"))
    }

    func testAppWithoutBundleIDIsUnsupported() async {
        let http = GitHubFakeHTTP(bodies: [altTabRelease])
        let result = await GitHubReleaseProbe(client: http).probe(ghApp(bundleID: nil))
        XCTAssertEqual(result, .unsupported(reason: "没有 Bundle ID，无法查询 GitHub Release"))
    }

    func testAppOutsideCatalogIsUnsupported() async {
        let http = GitHubFakeHTTP(bodies: [altTabRelease])
        let result = await GitHubReleaseProbe(client: http)
            .probe(ghApp("Mystery", bundleID: "com.example.mystery"))
        XCTAssertEqual(result, .unsupported(reason: "不在 GitHub Release 白名单内"))
        let urls = await http.requested
        XCTAssertTrue(urls.isEmpty, "白名单外的应用不应发任何请求")
    }

    func testRateLimitBecomesFailedWithExplicitReason() async {
        let result = await GitHubReleaseProbe(client: GitHubStatusHTTP(code: 403)).probe(ghApp())
        guard case .failed(let reason) = result else { return XCTFail("403 应是 failed，实际 \(result)") }
        XCTAssertTrue(reason.contains("限额"), "403 的文案要点名限额：\(reason)")
    }

    func testMissingRepoBecomesUnsupportedWithRepoName() async {
        let result = await GitHubReleaseProbe(client: GitHubStatusHTTP(code: 404)).probe(ghApp())
        guard case .unsupported(let reason) = result else { return XCTFail("404 应是 unsupported，实际 \(result)") }
        XCTAssertTrue(reason.contains("lwouis/alt-tab-macos"), "理由里要带 owner/repo：\(reason)")
    }

    func testOtherHTTPStatusBecomesFailed() async {
        let result = await GitHubReleaseProbe(client: GitHubStatusHTTP(code: 500)).probe(ghApp())
        XCTAssertEqual(result, .failed(reason: "HTTP 500"))
    }

    func testUnparseableBodyBecomesUnsupported() async {
        let http = GitHubFakeHTTP(bodies: ["not json"])
        let result = await GitHubReleaseProbe(client: http).probe(ghApp())
        XCTAssertEqual(result, .unsupported(reason: "GitHub Release 响应里没有可辨认的版本号"))
    }
}

// MARK: - 白名单

final class GitHubCatalogTests: XCTestCase {
    /// 2026-09-16 实测过 `releases/latest` 全部命中的六条映射。**加新条目时来这里补断言。**
    func testKnownEntriesArePresent() {
        let expected: [String: String] = [
            "com.lwouis.alt-tab-macos": "lwouis/alt-tab-macos",
            "io.github.clash-verge-rev.clash-verge-rev": "clash-verge-rev/clash-verge-rev",
            "org.jkiss.dbeaver.core.product": "dbeaver/dbeaver",
            "com.follow.clash": "chen08209/FlClash",
            "com.insomnia.app": "Kong/insomnia",
            "dev.zed.Zed": "zed-industries/zed",
        ]
        for (bundleID, repo) in expected {
            XCTAssertEqual(GitHubReleaseCatalog.repo(forBundleID: bundleID), repo, bundleID)
        }
    }

    func testEveryEntryIsWellFormed() {
        for bundleID in ["com.lwouis.alt-tab-macos", "io.github.clash-verge-rev.clash-verge-rev",
                         "org.jkiss.dbeaver.core.product", "com.follow.clash",
                         "com.insomnia.app", "dev.zed.Zed"] {
            guard let repo = GitHubReleaseCatalog.repo(forBundleID: bundleID) else {
                return XCTFail("白名单缺了 \(bundleID)")
            }
            let parts = repo.split(separator: "/")
            XCTAssertEqual(parts.count, 2, "\(repo) 必须是 owner/repo 形态")
            XCTAssertTrue(parts.allSatisfy { !$0.isEmpty }, "\(repo) 有空段")
            let url = GitHubReleaseCatalog.latestReleaseURL(bundleID: bundleID)
            XCTAssertEqual(url?.scheme, "https")
            XCTAssertEqual(url?.host, "api.github.com")
            XCTAssertEqual(url?.path, "/repos/\(repo)/releases/latest")
        }
    }

    func testUnknownBundleIDYieldsNil() {
        XCTAssertNil(GitHubReleaseCatalog.repo(forBundleID: "com.example.unknown"))
        XCTAssertFalse(GitHubReleaseCatalog.contains(bundleID: "com.example.unknown"))
        XCTAssertNil(GitHubReleaseCatalog.latestReleaseURL(bundleID: "com.example.unknown"))
    }
}

// MARK: - 分类与安全边界

final class GitHubClassifierTests: XCTestCase {
    private func scanned(
        bundleID: String?,
        name: String = "AltTab",
        hasEmbeddedSparkle: Bool = false,
        appUpdateYML: URL? = nil
    ) -> ScannedApp {
        ScannedApp(
            name: name,
            bundleID: bundleID,
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            currentVersion: "1.0",
            buildVersion: nil,
            feedURLString: nil,
            publicEDKey: nil,
            hasMASReceipt: false,
            hasEmbeddedSparkle: hasEmbeddedSparkle,
            appUpdateYML: appUpdateYML
        )
    }

    func testSourceProperties() {
        XCTAssertEqual(AppSource.githubRelease.badge, "GitHub")
        XCTAssertTrue(AppSource.githubRelease.isAutoDetectable)
        XCTAssertEqual(AppSource.githubRelease.probeKey, "github")
    }

    func testInstallActionStaysOpenDownload() {
        // 红线：GitHub 的包没有我们的 Ed25519 清单，绝不能走 `.replaceBundle`。
        let app = ghApp()
        let update = AppUpdate(app: app, result: .updateAvailable(ReleaseInfo(
            version: "11.6.1",
            downloadURL: URL(string: "https://github.com/lwouis/alt-tab-macos/releases/tag/v11.6.1")
        )))
        XCTAssertEqual(update.installAction, .openDownload)
        XCTAssertFalse(update.installAction.isAutomated)
    }

    func testEmbeddedSparkleWithCatalogHitGoesToGitHub() {
        // AltTab：内嵌 Sparkle 但 feed 硬编码，白名单接住它。
        let app = AppClassifier(caskIndex: nil).classify(
            scanned(bundleID: "com.lwouis.alt-tab-macos", hasEmbeddedSparkle: true))
        XCTAssertEqual(app.source, .githubRelease)
    }

    func testEmbeddedSparkleWithoutCatalogKeepsOriginalReason() {
        let app = AppClassifier(caskIndex: nil).classify(
            scanned(bundleID: "com.example.hardcoded", hasEmbeddedSparkle: true))
        XCTAssertEqual(app.source, .unsupported(reason: "内嵌 Sparkle 但更新源在程序内硬编码"))
    }

    func testCatalogFallbackCatchesPlainUnsupportedApps() {
        // Insomnia：没有任何可识别的更新接口，纯靠白名单兜底。
        let app = AppClassifier(caskIndex: nil).classify(
            scanned(bundleID: "com.insomnia.app", name: "Insomnia"))
        XCTAssertEqual(app.source, .githubRelease)
    }

    func testElectronOwnChannelWinsOverCatalog() {
        // 自带 app-update.yml 的 Electron 应用不该被白名单抢走。
        let yml = URL(fileURLWithPath: "/Applications/Insomnia.app/Contents/Resources/app-update.yml")
        let app = AppClassifier(caskIndex: nil).classify(
            scanned(bundleID: "com.insomnia.app", name: "Insomnia", appUpdateYML: yml))
        XCTAssertEqual(app.source, .electron(feedURL: nil))
    }

    func testNonCatalogPlainAppStaysUnsupported() {
        let app = AppClassifier(caskIndex: nil).classify(
            scanned(bundleID: "com.example.nobody", name: "Nobody"))
        XCTAssertEqual(app.source, .unsupported(reason: "未识别到公开的更新接口"))
    }

    func testCheckEngineRoutesGitHubReleaseToGitHubProbe() async {
        // 端到端：引擎必须把 `.githubRelease` 送到 GitHub 探针，且不惊动 Sparkle。
        actor Recorder: UpdateProbing {
            let label: String
            private(set) var names: [String] = []
            init(label: String) { self.label = label }
            func probe(_ app: AppInfo) async -> UpdateResult {
                names.append(app.name)
                return .upToDate(latest: "0.0.0")
            }
        }
        let sparkle = Recorder(label: "sparkle")
        let github = Recorder(label: "github")
        let engine = CheckEngine(
            sparkleProbe: sparkle,
            electronProbe: sparkle,
            masProbe: sparkle,
            gitHubProbe: github
        )
        let updates = await engine.check(apps: [ghApp()])
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.result, .upToDate(latest: "0.0.0"))
        let githubNames = await github.names
        let sparkleNames = await sparkle.names
        XCTAssertEqual(githubNames, ["AltTab"], ".githubRelease 必须走 GitHub 探针")
        XCTAssertTrue(sparkleNames.isEmpty, "不该惊动 Sparkle/Electron/MAS 探针")
    }
}
