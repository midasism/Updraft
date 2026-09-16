import XCTest
@testable import UpdraftKit

final class AppcastTests: XCTestCase {
    /// 取自 https://www.iina.io/appcast.xml 的真实结构。
    private let iinaXML = """
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
        <channel>
            <title>IINA</title>
            <item>
                <title>1.4.4</title>
                <pubDate>Thu, 18 Jun 2026 23:14:53 -0400</pubDate>
                <sparkle:version>168</sparkle:version>
                <sparkle:shortVersionString>1.4.4</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>10.15</sparkle:minimumSystemVersion>
                <enclosure url="https://dl-portal.iina.io/IINA.v1.4.4.dmg" length="109301417"
                    type="application/octet-stream" sparkle:edSignature="abc==" />
            </item>
            <item>
                <title>1.3.5</title>
                <sparkle:version>160</sparkle:version>
                <sparkle:shortVersionString>1.3.5</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>10.13</sparkle:minimumSystemVersion>
                <enclosure url="https://dl-portal.iina.io/IINA.v1.3.5.dmg" length="100000000" />
            </item>
        </channel>
    </rss>
    """

    func testParsesChannelTitleAndItems() {
        let appcast = AppcastParser.parse(iinaXML)
        XCTAssertEqual(appcast.channelTitle, "IINA")
        XCTAssertEqual(appcast.items.count, 2)
    }

    func testPicksHighestBuildNumberNotDocumentOrder() {
        let appcast = AppcastParser.parse(iinaXML)
        let latest = appcast.latestItem()
        XCTAssertEqual(latest?.shortVersion, "1.4.4")
        XCTAssertEqual(latest?.buildVersion, "168")
        XCTAssertEqual(latest?.size, 109_301_417)
        XCTAssertEqual(latest?.downloadURL?.absoluteString, "https://dl-portal.iina.io/IINA.v1.4.4.dmg")
    }

    func testRejectsItemRequiringNewerSystem() {
        // 把最新版的最低系统要求抬到本机之上，应当退回次新版本。
        let xml = iinaXML.replacingOccurrences(of: "<sparkle:minimumSystemVersion>10.15</sparkle:minimumSystemVersion>",
                                               with: "<sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>")
        let appcast = AppcastParser.parse(xml)
        let latest = appcast.latestItem()
        XCTAssertEqual(latest?.shortVersion, "1.3.5")
    }

    func testFallsBackToRSSItemTitleWhenShortVersionMissing() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <item>
              <title>2.5.0</title>
              <enclosure url="https://example.com/a.zip" length="1234" />
            </item>
          </channel>
        </rss>
        """
        let appcast = AppcastParser.parse(xml)
        XCTAssertEqual(appcast.latestItem()?.displayVersion, "2.5.0")
    }

    func testMalformedXMLYieldsNoItems() {
        let appcast = AppcastParser.parse("<rss><channel><item>")
        XCTAssertTrue(appcast.items.isEmpty)
        XCTAssertNil(appcast.latestItem())
    }

    func testEmptyFeedYieldsNoItems() {
        XCTAssertNil(AppcastParser.parse("").latestItem())
    }
}

final class ElectronFeedTests: XCTestCase {
    func testParsesGitHubProvider() {
        let yaml = """
        provider: github
        owner: some-org
        repo: some-app
        updaterCacheDirName: some-app-updater
        """
        let feed = ElectronFeed.parse(yaml)
        XCTAssertEqual(feed?.provider, .gitHub(owner: "some-org", repo: "some-app"))
        XCTAssertEqual(feed?.channel, "latest")
    }

    func testParsesGenericProviderWithQuotedURL() {
        let yaml = """
        provider: generic
        url: "https://updates.example.com/app"
        channel: stable
        """
        let feed = ElectronFeed.parse(yaml)
        XCTAssertEqual(feed?.provider, .generic(baseURL: URL(string: "https://updates.example.com/app")!, channel: "stable"))
        XCTAssertEqual(feed?.channel, "stable")
    }

    func testUnknownProviderIsReportedNotGuessed() {
        let feed = ElectronFeed.parse("provider: spaces\nurl: https://x.example.com\n")
        XCTAssertEqual(feed?.provider, .other("spaces"))
    }

    func testS3ProviderWithoutURLIsNotGuessed() {
        // 本机 LM Studio 的实际情况：只有 bucket，拼不出可访问地址。
        let feed = ElectronFeed.parse("provider: s3\nbucket: lmstudio-updaters\nupdaterCacheDirName: lm-studio\n")
        XCTAssertEqual(feed?.provider, .other("s3"))
    }

    func testNotionStyleChannelBecomesFileName() {
        // Notion 用的是 channel: arm64，对应文件是 arm64-mac.yml。
        let yaml = "provider: generic\nurl: 'https://desktop-release.notion-static.com'\nchannel: arm64\n"
        let feed = ElectronFeed.parse(yaml)
        XCTAssertEqual(feed?.channel, "arm64")
        XCTAssertEqual(feed?.provider, .generic(baseURL: URL(string: "https://desktop-release.notion-static.com")!, channel: "arm64"))
    }

    func testEmptyOrRelativeURLYieldsNil() {
        // 本机实测：aDrive / QQ 的 url 是空串，不能当成有效更新源。
        XCTAssertNil(ElectronFeed.parse("provider: generic\nurl: ''\n"))
        XCTAssertNil(ElectronFeed.parse("provider: generic\nurl: not-a-url\n"))
    }

    func testMissingKeysReturnNil() {
        XCTAssertNil(ElectronFeed.parse("provider: github\nowner: only-owner\n"))
        XCTAssertNil(ElectronFeed.parse(""))
        XCTAssertNil(ElectronFeed.parse("owner: someone\nrepo: something\n"))
    }

    func testPicksDmgOverZipAndMatchesArchitecture() {
        let assets: [[String: Any]] = [
            ["name": "App-1.0.0-mac.zip", "browser_download_url": "https://x/App-mac.zip", "size": 10],
            ["name": "App-1.0.0-x64.dmg", "browser_download_url": "https://x/App-x64.dmg", "size": 20],
            ["name": "App-1.0.0-arm64.dmg", "browser_download_url": "https://x/App-arm64.dmg", "size": 30]
        ]
        let asset = ElectronProbe.pickAsset(from: assets)
        #if arch(arm64)
        XCTAssertEqual(asset?.url.absoluteString, "https://x/App-arm64.dmg")
        XCTAssertEqual(asset?.size, 30)
        #else
        XCTAssertEqual(asset?.url.absoluteString, "https://x/App-x64.dmg")
        #endif
    }

    func testPickAssetReturnsNilWhenNoInstallerPresent() {
        let assets: [[String: Any]] = [["name": "App-src.tar.gz", "browser_download_url": "https://x/a.tar.gz"]]
        XCTAssertNil(ElectronProbe.pickAsset(from: assets))
    }

    func testGenericFeedParsingHelpers() {
        let text = """
        version: 1.2.3
        files:
          - url: App-1.2.3-arm64.zip
            sha512: abc
            size: 4567
        path: App-1.2.3-arm64.zip
        """
        XCTAssertEqual(ElectronProbe.yamlValue("version", in: text), "1.2.3")
        XCTAssertEqual(ElectronProbe.yamlValue("path", in: text), "App-1.2.3-arm64.zip")
        XCTAssertEqual(ElectronProbe.firstFileSize(in: text), 4567)
        XCTAssertEqual(
            ElectronProbe.firstFileURL(in: text, relativeTo: URL(string: "https://updates.example.com/app/")!)?.absoluteString,
            "https://updates.example.com/app/App-1.2.3-arm64.zip"
        )
    }
}
