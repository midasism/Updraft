import CryptoKit
import XCTest
@testable import AppUpdaterKit

/// GitHub Release 解析 + 自更新检测。
final class SelfUpdateCheckerTests: XCTestCase {
    /// 取自 https://api.github.com/repos/midasism/Updraft/releases/latest 的真实结构。
    private let releaseJSON = """
    {
      "tag_name": "v0.2.1",
      "html_url": "https://github.com/midasism/Updraft/releases/tag/v0.2.1",
      "published_at": "2026-09-14T12:53:12Z",
      "assets": [
        {
          "name": "SHA256SUMS.txt",
          "browser_download_url": "https://github.com/midasism/Updraft/releases/download/v0.2.1/SHA256SUMS.txt",
          "size": 180
        },
        {
          "name": "Updraft-0.2.1-macOS.dmg",
          "browser_download_url": "https://github.com/midasism/Updraft/releases/download/v0.2.1/Updraft-0.2.1-macOS.dmg",
          "size": 1642447,
          "digest": "sha256:9fb6b4d1bbf1240d2052e14c4562f1ccbc8192138602c733b16d3b859f46ff4f"
        },
        {
          "name": "Updraft-0.2.1-macOS.zip",
          "browser_download_url": "https://github.com/midasism/Updraft/releases/download/v0.2.1/Updraft-0.2.1-macOS.zip",
          "size": 1104320,
          "digest": "sha256:c3fa21752d9e6e11a9e66dc4848c869f2c12953660dfccc8816c468dc32ad06b"
        }
      ]
    }
    """

    private func parse(_ json: String? = nil, current: String) -> SelfUpdateResult {
        SelfUpdateChecker.parseRelease(Data((json ?? releaseJSON).utf8), currentVersion: current)
    }

    func testDetectsAvailableUpdateAndStripsVPrefix() {
        guard case .available(let release) = parse(current: "0.2.0") else {
            return XCTFail("应该检测到新版本")
        }
        XCTAssertEqual(release.version, "0.2.1")
        XCTAssertEqual(release.tag, "v0.2.1")
        XCTAssertEqual(release.releaseNotesURL?.absoluteString, "https://github.com/midasism/Updraft/releases/tag/v0.2.1")
        XCTAssertEqual(release.checksumURL?.lastPathComponent, "SHA256SUMS.txt")
        XCTAssertEqual(release.apiDigest?.hasPrefix("sha256:"), true)
        XCTAssertNotNil(release.publishedAt)
    }

    /// 自家产品优先用 zip：它要自己拆开替换自己，少一次 dmg 挂载就少一圈出错的面。
    func testPrefersZipOverDmg() {
        guard case .available(let release) = parse(current: "0.2.0") else {
            return XCTFail("应该检测到新版本")
        }
        XCTAssertEqual(release.assetName, "Updraft-0.2.1-macOS.zip")
        XCTAssertEqual(release.packageKind, .zip)
        XCTAssertEqual(release.size, 1_104_320)
    }

    func testSameVersionIsUpToDate() {
        guard case .upToDate(let current, let latest) = parse(current: "0.2.1") else {
            return XCTFail("同版本应当是已是最新")
        }
        XCTAssertEqual(current, "0.2.1")
        XCTAssertEqual(latest, "0.2.1")
    }

    /// 本地版本比线上还新（开发中）时不能报"有更新"，否则会诱导用户降级。
    func testLocalVersionAheadIsUpToDate() {
        guard case .upToDate = parse(current: "0.3.0") else {
            return XCTFail("本地版本更高时不该报有新版本")
        }
    }

    func testTagWithoutVPrefixIsAccepted() {
        let json = releaseJSON.replacingOccurrences(of: "\"v0.2.1\"", with: "\"0.3.5\"")
        guard case .available(let release) = parse(json, current: "0.2.0") else {
            return XCTFail("没有 v 前缀的 tag 也要能解析")
        }
        XCTAssertEqual(release.version, "0.3.5")
    }

    func testMissingTagIsReportedNotGuessed() {
        let json = releaseJSON.replacingOccurrences(of: "\"tag_name\": \"v0.2.1\",", with: "")
        guard case .failed(let reason) = parse(json, current: "0.2.0") else {
            return XCTFail("缺 tag 应当报失败")
        }
        XCTAssertTrue(reason.contains("版本标签"))
    }

    func testMalformedJSONIsReported() {
        guard case .failed = parse("{ not json", current: "0.2.0") else {
            return XCTFail("畸形 JSON 应当报失败")
        }
    }

    /// 有新版本但没有任何安装包：不能报"已是最新"，也不能拿一个猜的地址去下载。
    func testReleaseWithoutInstallableAssetFails() {
        let json = releaseJSON.replacingOccurrences(of: "-macOS.dmg", with: ".pkg")
            .replacingOccurrences(of: "-macOS.zip", with: ".pkg")
        guard case .failed(let reason) = parse(json, current: "0.2.0") else {
            return XCTFail("没有可用安装包时应当报失败")
        }
        XCTAssertTrue(reason.contains("没有可用的安装包"))
    }

    func testFallbackToDmgWhenZipMissing() {
        let json = releaseJSON.replacingOccurrences(of: "Updraft-0.2.1-macOS.zip", with: "Updraft-0.2.1-macOS.txt")
        guard case .available(let release) = parse(json, current: "0.2.0") else {
            return XCTFail("只有 dmg 时也应当能更新")
        }
        XCTAssertEqual(release.packageKind, .dmg)
    }

    /// `SHA256SUMS.txt` 与 `.ed25519` 都不是安装包，绝不能被挑进来。
    func testChecksumAndSignatureAssetsAreNeverPickedAsPackages() {
        let assets: [[String: Any]] = [
            ["name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt"],
            ["name": "Updraft-0.2.1-macOS.zip.ed25519", "browser_download_url": "https://example.com/x.ed25519"]
        ]
        XCTAssertNil(SelfUpdateChecker.pickAsset(from: assets))
    }

    func testArchitectureSuffixIsMatchedWhenPresent() {
        let assets: [[String: Any]] = [
            ["name": "Updraft-0.3.0-macOS-x64.zip", "browser_download_url": "https://example.com/x64.zip"],
            ["name": "Updraft-0.3.0-macOS-arm64.zip", "browser_download_url": "https://example.com/arm64.zip"]
        ]
        let picked = SelfUpdateChecker.pickAsset(from: assets)
        #if arch(arm64)
        XCTAssertEqual(picked?.name, "Updraft-0.3.0-macOS-arm64.zip")
        #else
        XCTAssertEqual(picked?.name, "Updraft-0.3.0-macOS-x64.zip")
        #endif
    }

    // MARK: - 校验和文件

    func testParsesChecksumsWithBareNames() {
        let text = """
        9fb6b4d1bbf1240d2052e14c4562f1ccbc8192138602c733b16d3b859f46ff4f  Updraft-0.2.1-macOS.dmg
        c3fa21752d9e6e11a9e66dc4848c869f2c12953660dfccc8816c468dc32ad06b  Updraft-0.2.1-macOS.zip
        """
        let sums = SelfUpdateChecker.parseChecksums(text)
        XCTAssertEqual(sums.count, 2)
        XCTAssertEqual(sums["Updraft-0.2.1-macOS.zip"],
                       "c3fa21752d9e6e11a9e66dc4848c869f2c12953660dfccc8816c468dc32ad06b")
    }

    /// 早期产物里的文件名叫 `dist/xxx`，用户手算时对不上；按 basename 归一才一致。
    func testParsesChecksumsWithDirectoryPrefix() {
        let text = "c3fa21752d9e6e11a9e66dc4848c869f2c12953660dfccc8816c468dc32ad06b  dist/Updraft-0.2.1-macOS.zip"
        let sums = SelfUpdateChecker.parseChecksums(text)
        XCTAssertNotNil(sums["Updraft-0.2.1-macOS.zip"])
    }

    func testIgnoresCommentsAndMalformedLines() {
        let text = """
        # 校验和文件

        这不是一行校验和
        abcdef  too-short.txt
        c3fa21752d9e6e11a9e66dc4848c869f2c12953660dfccc8816c468dc32ad06b  good.zip
        """
        let sums = SelfUpdateChecker.parseChecksums(text)
        XCTAssertEqual(sums, ["good.zip": "c3fa21752d9e6e11a9e66dc4848c869f2c12953660dfccc8816c468dc32ad06b"])
    }

    // MARK: - 缓存节流

    func testCacheRoundTripsAnAvailableRelease() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-update-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let cache = SelfUpdateCache(fileURL: file)
        guard case .available(let original) = SelfUpdateChecker.parseRelease(
            Data(releaseJSON.utf8), currentVersion: "0.2.0"
        ) else {
            return XCTFail("前置条件：应当解析出新版本")
        }

        let now = Date()
        cache.save(.init(result: .available(original), currentVersion: "0.2.0", checkedAt: now))

        let loaded = cache.load(now: now.addingTimeInterval(60))
        guard case .available(let restored) = loaded?.result else {
            return XCTFail("应当读回一条可更新的缓存")
        }
        XCTAssertEqual(restored.version, original.version)
        XCTAssertEqual(restored.assetName, original.assetName)
        XCTAssertEqual(restored.downloadURL, original.downloadURL)
        XCTAssertEqual(restored.checksumURL, original.checksumURL)
        XCTAssertEqual(restored.size, original.size)
    }

    /// 过期就该作废，否则用户会一直看到同一个旧答案。
    func testCacheExpiresAfterThrottleWindow() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-update-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let cache = SelfUpdateCache(fileURL: file)
        let now = Date()
        cache.save(.init(
            result: .upToDate(current: "0.2.1", latest: "0.2.1"),
            currentVersion: "0.2.1",
            checkedAt: now
        ))

        XCTAssertNotNil(cache.load(now: now.addingTimeInterval(60)))
        XCTAssertNil(cache.load(now: now.addingTimeInterval(SelfUpdateCache.throttle + 1)))
    }

    /// 失败不落盘：一次网络抖动不该让用户接下来几小时都看不到新版本。
    func testFailuresAreNotCached() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-update-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let cache = SelfUpdateCache(fileURL: file)
        cache.save(.init(result: .failed(reason: "网络超时"), currentVersion: "0.2.1", checkedAt: Date()))
        XCTAssertNil(cache.load())
    }

    /// 换了版本号就不能复用旧结论——刚升完级的那个实例读旧缓存会得出错误答案。
    func testCacheIsIgnoredWhenCurrentVersionDiffers() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-update-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let cache = SelfUpdateCache(fileURL: file)
        cache.save(.init(
            result: .upToDate(current: "0.2.0", latest: "0.2.1"),
            currentVersion: "0.2.0",
            checkedAt: Date()
        ))

        XCTAssertNotNil(cache.load(currentVersion: "0.2.0"))
        XCTAssertNil(cache.load(currentVersion: "0.2.1"))
    }
}
