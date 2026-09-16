import XCTest
@testable import UpdraftKit

/// 搜索匹配规则的边界。纯逻辑，不碰 GUI 与网络。
final class AppSearchTests: XCTestCase {
    private func update(_ name: String, bundleID: String? = nil) -> AppUpdate {
        let app = AppInfo(
            name: name,
            bundleID: bundleID,
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            currentVersion: "1.0",
            buildVersion: nil,
            source: .sparkle(feedURL: nil)
        )
        return AppUpdate(app: app, result: .upToDate(latest: "1.0"))
    }

    private lazy var sample: [AppUpdate] = [
        update("Cherry Studio", bundleID: "com.kangfenmao.CherryStudio"),
        update("IINA", bundleID: "com.colliderli.iina"),
        update("微信", bundleID: "com.tencent.xinWeChat"),
        update("ngrok")
    ]

    private func names(_ updates: [AppUpdate]) -> [String] { updates.map(\.app.name) }

    func testEmptyQueryReturnsEverything() {
        XCTAssertEqual(
            names(AppSearch.filter(sample, query: "")),
            names(sample),
            "空词是「不筛选」，不是「筛掉全部」"
        )
    }

    func testWhitespaceOnlyQueryReturnsEverything() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "   ")), names(sample))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "  iina  ")), ["IINA"])
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "CHERRY")), ["Cherry Studio"])
    }

    func testBundleIDIsSearchable() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "com.colliderli")), ["IINA"])
    }

    func testEntriesWithoutBundleIDDoNotCrash() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "ngrok")), ["ngrok"])
        XCTAssertTrue(AppSearch.filter(sample, query: "com.").count < sample.count, "缺 Bundle ID 的条目不该因为拿不到字段就全命中")
    }

    func testEveryTokenMustMatch() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "ch stu")), ["Cherry Studio"])
        XCTAssertTrue(AppSearch.filter(sample, query: "ch zzz").isEmpty)
    }

    func testTokensMayMatchDifferentFields() {
        XCTAssertEqual(
            names(AppSearch.filter(sample, query: "cherry com.kangfenmao")),
            ["Cherry Studio"]
        )
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(AppSearch.filter(sample, query: "不存在的词").isEmpty)
    }

    func testChineseNameIsSearchable() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "微信")), ["微信"])
    }

    func testFilteringPreservesOrder() {
        let zebra = update("Zebra", bundleID: "com.z")
        let apple = update("Apple", bundleID: "com.a")
        XCTAssertEqual(
            names(AppSearch.filter([zebra, apple], query: "a")),
            ["Zebra", "Apple"],
            "过滤不改顺序，排序只由 AppUpdate.listOrder 定义"
        )
    }

    func testTokenizeCollapsesWhitespace() {
        XCTAssertEqual(AppSearch.tokenize("  ch \t stu \n"), ["ch", "stu"])
        XCTAssertTrue(AppSearch.tokenize("   ").isEmpty)
    }
}
