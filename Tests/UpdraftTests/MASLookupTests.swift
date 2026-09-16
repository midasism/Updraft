import XCTest
@testable import UpdraftKit

/// 假网络缝：按序回放预设响应体，用完后重复最后一个；同时记录请求过的 URL，
/// 好断言 bundle ID 到底是怎么拼进去的。不发任何真实请求。
///
/// 用 `actor` 而不是 `class + NSLock`：`NSLock.lock()` 在 async 上下文里
/// 已经标了 unavailable（Swift 6 语言模式下是错误），而它的替代写法在测试里
/// 只会更绕。actor 天然是 `Sendable`，也天然是 async-safe 的。
private actor FakeHTTP: HTTPFetching {
    private let bodies: [Data]
    private var index = 0
    private var requestedURLs: [URL] = []

    init(bodies: [String]) {
        // 空数组会让 `min(index, count - 1)` 越界，这里直接堵死。
        precondition(!bodies.isEmpty, "至少要有一个响应体")
        self.bodies = bodies.map { Data($0.utf8) }
    }

    init(body: String) { self.init(bodies: [body]) }

    var requested: [URL] { requestedURLs }

    func data(from url: URL) async throws -> Data {
        let body = bodies[min(index, bodies.count - 1)]
        index += 1
        requestedURLs.append(url)
        return body
    }
}

/// 一定抛错的假缝，用来断言错误被映射成 `.failed` 而不是被吞掉。
private struct ThrowingHTTP: HTTPFetching {
    func data(from url: URL) async throws -> Data { throw HTTPError.statusCode(500) }
}

/// 取自真实响应的形状：`fileSizeBytes` 是**字符串**，`resultCount` 是数字。
private let magnetResponse = """
{
 "resultCount":1,
 "results": [
  {
   "bundleId": "com.crowdcafe.windowmagnet",
   "version": "3.0.7",
   "trackViewUrl": "https://apps.apple.com/cn/app/magnet/id441258766?mt=12",
   "fileSizeBytes": "14207939"
  }
 ]
}
"""

/// 接口对「查不到」返回的是 HTTP 200 + 空数组，**不是** 404。
private let emptyResponse = """
{
 "resultCount":0,
 "results": []
}
"""

private func makeApp(
    _ name: String = "Magnet",
    bundleID: String? = "com.crowdcafe.windowmagnet",
    version: String? = "2.14.0",
    build: String? = "134"
) -> AppInfo {
    AppInfo(
        name: name,
        bundleID: bundleID,
        path: URL(fileURLWithPath: "/Applications/\(name).app"),
        currentVersion: version,
        buildVersion: build,
        source: .appStore
    )
}

private func queryValue(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == name }?
        .value
}

final class MASLookupParsingTests: XCTestCase {
    func testParsesVersionSizeAndStoreURL() throws {
        let result = try XCTUnwrap(MASLookupResult.parse(Data(magnetResponse.utf8)))
        XCTAssertEqual(result.version, "3.0.7")
        XCTAssertEqual(result.bundleID, "com.crowdcafe.windowmagnet")
        XCTAssertEqual(result.size, 14_207_939)
        XCTAssertEqual(result.trackViewURL?.host, "apps.apple.com")
    }

    func testEmptyResultsYieldNil() {
        XCTAssertNil(MASLookupResult.parse(Data(emptyResponse.utf8)))
    }

    func testMalformedJSONYieldsNil() {
        XCTAssertNil(MASLookupResult.parse(Data("not json".utf8)))
        XCTAssertNil(MASLookupResult.parse(Data()))
        XCTAssertNil(MASLookupResult.parse(Data(#"{"results": []}"#.utf8)))
    }

    /// 缺 `version` 的条目答不出「有没有新版本」，当成查不到。
    func testResultWithoutVersionYieldsNil() {
        XCTAssertNil(MASLookupResult.parse(Data(#"{"resultCount":1,"results":[{"bundleId":"x"}]}"#.utf8)))
    }

    /// 没有 `trackViewUrl` 也要能解析出版本，只是没有可点的链接。
    func testMissingStoreURLStillParses() throws {
        let result = try XCTUnwrap(MASLookupResult.parse(
            Data(#"{"resultCount":1,"results":[{"bundleId":"x","version":"2.0"}]}"#.utf8)
        ))
        XCTAssertEqual(result.version, "2.0")
        XCTAssertNil(result.trackViewURL)
        XCTAssertNil(result.size)
    }

    /// `fileSizeBytes` 数字形态也认，免得接口哪天改了静默少一个尺寸。
    func testAcceptsNumericFileSizeToo() throws {
        let result = try XCTUnwrap(MASLookupResult.parse(
            Data(#"{"resultCount":1,"results":[{"bundleId":"x","version":"2.0","fileSizeBytes":12345}]}"#.utf8)
        ))
        XCTAssertEqual(result.size, 12_345)
    }
}

final class MASLookupURLTests: XCTestCase {
    /// 防回归的关键断言：一旦有人又往查询里加「剥掉 team 前缀」的归一逻辑，这条会红。
    ///
    /// 2026-09-16 实测：`5ZSL2CJU2T.com.dingtalk.mac` 原样命中；剥掉前缀的
    /// `com.dingtalk.mac` 反而 0 条。而且剥前缀可能撞上另一个开发者的同名反向域名。
    func testBundleIDIsSentVerbatimWithoutStripping() throws {
        let url = try XCTUnwrap(MASProbe.lookupURL(bundleID: "5ZSL2CJU2T.com.dingtalk.mac", country: "cn"))
        XCTAssertEqual(queryValue(url, "bundleId"), "5ZSL2CJU2T.com.dingtalk.mac")
    }

    func testCountryIsOptional() throws {
        let withCountry = try XCTUnwrap(MASProbe.lookupURL(bundleID: "com.a.b", country: "cn"))
        XCTAssertEqual(queryValue(withCountry, "country"), "cn")

        let without = try XCTUnwrap(MASProbe.lookupURL(bundleID: "com.a.b", country: nil))
        XCTAssertNil(queryValue(without, "country"), "不带 country 时不该出现这个参数")
        XCTAssertEqual(queryValue(without, "bundleId"), "com.a.b")
    }

    /// 空串 country 等同于不带，不能拼出一个 `country=` 的空参数。
    func testEmptyCountryIsOmitted() throws {
        let url = try XCTUnwrap(MASProbe.lookupURL(bundleID: "com.a.b", country: ""))
        XCTAssertEqual(url.query, "bundleId=com.a.b")
    }

    func testEndpointIsThePublicLookupAPI() throws {
        let url = try XCTUnwrap(MASProbe.lookupURL(bundleID: "com.a.b", country: "cn"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "itunes.apple.com")
        XCTAssertEqual(url.path, "/lookup")
    }
}

final class MASProbeTests: XCTestCase {
    func testReportsUpdateWhenStoreIsNewer() async {
        let result = await MASProbe(client: FakeHTTP(body: magnetResponse)).probe(makeApp())

        guard case .updateAvailable(let release) = result else {
            return XCTFail("Magnet 2.14.0 → 3.0.7 应判为可更新，实际是 \(result)")
        }
        XCTAssertEqual(release.version, "3.0.7")
        XCTAssertEqual(release.size, 14_207_939)
        XCTAssertEqual(release.downloadURL?.host, "apps.apple.com")
        // 商店页链接没有安装包扩展名，不该被当成分发包。
        XCTAssertEqual(release.packageKind, .unknown)
    }

    func testOnlyOneRequestIsNeededWhenCNStorefrontAnswers() async {
        let http = FakeHTTP(body: magnetResponse)
        _ = await MASProbe(client: http).probe(makeApp())
        let urls = await http.requested
        XCTAssertEqual(urls.count, 1, "CN 商店命中就不该再问第二次")
    }

    /// Bob 的真实情况：本地 1.20.0、商店 1.20.0，而本地构建号是 255。
    /// 构建号绝不能参与比较——lookup 的响应里根本没有对方构建号。
    func testEqualVersionIsUpToDateDespiteLocalBuildNumber() async {
        let body = #"{"resultCount":1,"results":[{"bundleId":"com.hezongyidev.Bob","version":"1.20.0"}]}"#
        let result = await MASProbe(client: FakeHTTP(body: body))
            .probe(makeApp("Bob", bundleID: "com.hezongyidev.Bob", version: "1.20.0", build: "255"))
        XCTAssertEqual(result, .upToDate(latest: "1.20.0"))
    }

    /// 本地比商店新时不能报「可更新」——那是在让用户降级。
    func testLocalAheadOfStoreIsNotAnUpdate() async {
        let body = #"{"resultCount":1,"results":[{"bundleId":"com.tencent.xinWeChat","version":"4.1.13"}]}"#
        let result = await MASProbe(client: FakeHTTP(body: body))
            .probe(makeApp("WeChat", bundleID: "com.tencent.xinWeChat", version: "4.1.20"))
        XCTAssertEqual(result, .upToDate(latest: "4.1.13"))
    }

    func testVersionWithVPrefixIsStillCompared() async {
        let body = #"{"resultCount":1,"results":[{"bundleId":"x","version":"v2.0"}]}"#
        let result = await MASProbe(client: FakeHTTP(body: body))
            .probe(makeApp("X", bundleID: "x", version: "1.9.9"))
        guard case .updateAvailable(let release) = result else {
            return XCTFail("1.9.9 → v2.0 应判为可更新，实际是 \(result)")
        }
        XCTAssertEqual(release.version, "v2.0")
    }

    /// 本地拿不到版本号时不猜——`isNewer` 两边都缺就返回 false，宁可说「已是最新」也不虚报更新。
    func testUnknownLocalVersionDoesNotFabricateAnUpdate() async {
        let result = await MASProbe(client: FakeHTTP(body: magnetResponse))
            .probe(makeApp("Magnet", version: nil))
        XCTAssertEqual(result, .upToDate(latest: "3.0.7"))
    }

    /// CN 商店查空时去掉 country 再试一次——应用可能没在国内上架。
    func testFallsBackToStorefrontWithoutCountry() async {
        let http = FakeHTTP(bodies: [emptyResponse, magnetResponse])
        let result = await MASProbe(client: http).probe(makeApp())

        guard case .updateAvailable = result else {
            return XCTFail("第二次查询命中后应判为可更新，实际是 \(result)")
        }

        let urls = await http.requested
        XCTAssertEqual(urls.count, 2, "应当恰好请求两次")
        XCTAssertEqual(queryValue(urls[0], "country"), "cn")
        XCTAssertNil(queryValue(urls[1], "country"))
    }

    /// 两次都查空说明应用已下架或不在该商店区。如实说不支持，不猜版本、不报错。
    func testBothStorefrontsEmptyIsUnsupported() async {
        let http = FakeHTTP(body: emptyResponse)
        let result = await MASProbe(client: http).probe(makeApp())

        guard case .unsupported(let reason) = result else {
            return XCTFail("应判为不支持，实际是 \(result)")
        }
        XCTAssertTrue(reason.contains("查不到"), "理由要说清是查不到，实际：\(reason)")
        let urls = await http.requested
        XCTAssertEqual(urls.count, 2)
    }

    func testMissingBundleIDIsUnsupportedWithoutAnyRequest() async {
        let http = FakeHTTP(body: magnetResponse)
        let result = await MASProbe(client: http).probe(makeApp("NoID", bundleID: nil))

        guard case .unsupported(let reason) = result else {
            return XCTFail("没有 Bundle ID 应判为不支持，实际是 \(result)")
        }
        XCTAssertTrue(reason.contains("Bundle ID"))
        let urls = await http.requested
        XCTAssertTrue(urls.isEmpty, "没有 ID 就不该发请求")
    }

    /// 网络失败要如实报失败，不能伪装成「查不到」或「已是最新」。
    func testNetworkFailureIsReportedAsFailed() async {
        let result = await MASProbe(client: ThrowingHTTP()).probe(makeApp())
        guard case .failed(let reason) = result else {
            return XCTFail("应判为失败，实际是 \(result)")
        }
        XCTAssertEqual(reason, "HTTP 500")
    }
}

/// `.appStore` 从「只标记」改成「可检测」之后，安全边界必须仍在原地。
final class AppStoreSafetyTests: XCTestCase {
    func testAppStoreSourceIsNowAutoDetectable() {
        XCTAssertTrue(AppSource.appStore.isAutoDetectable)
    }

    func testOtherSourcesKeepTheirDetectability() {
        XCTAssertTrue(AppSource.homebrewCask(token: "x").isAutoDetectable)
        XCTAssertTrue(AppSource.electron(feedURL: nil).isAutoDetectable)
        XCTAssertTrue(AppSource.sparkle(feedURL: URL(string: "https://a/b.xml")!).isAutoDetectable)
        XCTAssertFalse(AppSource.sparkle(feedURL: nil).isAutoDetectable)
        XCTAssertFalse(AppSource.microsoftAutoUpdate.isAutoDetectable)
        XCTAssertFalse(AppSource.unsupported(reason: "私有更新器").isAutoDetectable)
    }

    /// 安全底线：能查版本 ≠ 能装。App Store 的包由系统与 `macappstore://` 管理，
    /// 本工具绝不能往 `/Applications` 里换。
    func testAppStoreInstallActionNeverReplacesTheBundle() {
        let update = AppUpdate(
            app: makeApp(),
            result: .updateAvailable(ReleaseInfo(
                version: "3.0.7",
                downloadURL: URL(string: "https://apps.apple.com/cn/app/magnet/id441258766?mt=12")
            ))
        )
        XCTAssertEqual(update.installAction, .openDownload)
        XCTAssertFalse(update.installAction.isAutomated)
    }

    func testAppStoreWithoutStoreURLFallsBackToManual() {
        let update = AppUpdate(
            app: makeApp(),
            result: .updateAvailable(ReleaseInfo(version: "3.0.7", downloadURL: nil))
        )
        XCTAssertEqual(update.installAction, .manual)
    }

    func testDetailTextNamesTheAppStoreSource() {
        let update = AppUpdate(app: makeApp(), result: .updateAvailable(ReleaseInfo(version: "3.0.7")))
        XCTAssertTrue(update.detailText.contains("App Store"))
        XCTAssertTrue(update.detailText.contains("2.14.0 → 3.0.7"))
        XCTAssertEqual(update.app.initial, "M")
    }
}
