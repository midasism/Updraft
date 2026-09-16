import XCTest
@testable import UpdraftKit

/// 记录"被探测过哪些应用"的线程安全日志。
///
/// 增量策略的核心承诺就是"只查变更过的那个"，所以这组测试必须能精确断言探测范围，
/// 而不是靠计时或日志推断。
private final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ name: String) {
        lock.lock()
        storage.append(name)
        lock.unlock()
    }

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int { names.count }
}

/// 只记账、不发网络请求的假探针。
private struct StubProbe: UpdateProbing {
    let log: ProbeLog
    let answer: @Sendable (AppInfo) -> UpdateResult

    func probe(_ app: AppInfo) async -> UpdateResult {
        log.record(app.name)
        return answer(app)
    }
}

/// 记录 brew 查询范围的盒子。
private final class TokenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []

    func record(_ tokens: [String]) {
        lock.lock()
        storage.append(tokens.sorted())
        lock.unlock()
    }

    var queries: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class CheckEngineScopeTests: XCTestCase {
    private func makeApp(_ name: String, source: AppSource, version: String = "1.0.0", bundleID: String? = nil) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: bundleID ?? "com.example.\(name)",
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            currentVersion: version,
            buildVersion: nil,
            source: source
        )
    }

    private func engine(
        probeLog: ProbeLog,
        tokenLog: TokenLog,
        outdated: [String: BrewOutdatedCask]? = [:],
        answer: @escaping @Sendable (AppInfo) -> UpdateResult = { _ in .upToDate(latest: "9.9") }
    ) -> CheckEngine {
        let probe = StubProbe(log: probeLog, answer: answer)
        return CheckEngine(
            sparkleProbe: probe,
            electronProbe: probe,
            masProbe: probe,
            gitHubProbe: probe,
            brewOutdated: { tokens in
                tokenLog.record(tokens)
                return outdated
            },
            concurrency: 4
        )
    }

    private var sparkle: AppSource { .sparkle(feedURL: URL(string: "https://example.com/appcast.xml")) }

    // MARK: - 检查范围就是入参

    func testOnlyTheGivenAppsAreProbed() async {
        let log = ProbeLog()
        let tokenLog = TokenLog()
        let all = [makeApp("IINA", source: sparkle), makeApp("Bob", source: sparkle), makeApp("Vox", source: .electron(feedURL: nil))]

        _ = await engine(probeLog: log, tokenLog: tokenLog).check(apps: [all[0]])

        XCTAssertEqual(log.names, ["IINA"], "传进来的范围之外一个都不该被探测")
    }

    func testFullCheckProbesEveryDetectableApp() async {
        let log = ProbeLog()
        let tokenLog = TokenLog()
        let all = [makeApp("IINA", source: sparkle), makeApp("Bob", source: sparkle), makeApp("Vox", source: .electron(feedURL: nil))]

        _ = await engine(probeLog: log, tokenLog: tokenLog).check(apps: all)

        XCTAssertEqual(Set(log.names), ["IINA", "Bob", "Vox"])
    }

    /// 返回结果必须覆盖每一个入参应用，否则增量合并会丢行。
    func testResultCoversEveryInputApp() async {
        let log = ProbeLog()
        let tokenLog = TokenLog()
        let all = [
            makeApp("IINA", source: sparkle),
            makeApp("Bob", source: sparkle),
            makeApp("Xcode", source: .appStore),
            makeApp("Zed", source: .githubRelease),
            makeApp("Steam", source: .unsupported(reason: "Steam 客户端内更新")),
            makeApp("ngrok", source: .homebrewCask(token: "ngrok"))
        ]

        let results = await engine(
            probeLog: log,
            tokenLog: tokenLog,
            outdated: ["ngrok": BrewOutdatedCask(installedVersion: "3.0.0", latestVersion: "3.1.0")]
        ).check(apps: all)

        XCTAssertEqual(Set(results.map(\.app.name)), Set(all.map(\.name)))
        // v0.3.6 起 App Store 走 iTunes Lookup，v0.3.7 起 GitHub 白名单走 Release 查询，
        // 所以这里是 4 而不是 2。断言点名而不只数个数：`unsupported` 与 brew 这两类
        // **不该**发请求这件事才是这条用例真正要守的，数个数看不出是谁多发了一次。
        XCTAssertEqual(Set(log.names), ["IINA", "Bob", "Xcode", "Zed"], "unsupported 与 brew 都不该发请求")
    }

    // MARK: - brew 查询收窄

    func testBrewQueryIsScopedToTheGivenAppsTokens() async {
        let log = ProbeLog()
        let tokenLog = TokenLog()
        let apps = [
            makeApp("Tabularis", source: .homebrewCask(token: "tabularis")),
            makeApp("Mac Mouse Fix", source: .homebrewCask(token: "mac-mouse-fix")),
            makeApp("IINA", source: sparkle)
        ]

        _ = await engine(probeLog: log, tokenLog: tokenLog).check(apps: [apps[0]])

        XCTAssertEqual(tokenLog.queries, [["tabularis"]], "只该比对这一个 cask，不该顺手比全表")
    }

    func testUnscopedCheckQueriesEveryBrewTokenInRange() async {
        let log = ProbeLog()
        let tokenLog = TokenLog()
        let apps = [
            makeApp("Tabularis", source: .homebrewCask(token: "tabularis")),
            makeApp("ngrok", source: .homebrewCask(token: "ngrok"))
        ]

        _ = await engine(probeLog: log, tokenLog: tokenLog).check(apps: apps)

        XCTAssertEqual(tokenLog.queries, [["ngrok", "tabularis"]])
    }

    func testNoBrewQueryWhenNoCaskInRange() async {
        let log = ProbeLog()
        let tokenLog = TokenLog()

        _ = await engine(probeLog: log, tokenLog: tokenLog).check(apps: [makeApp("IINA", source: sparkle)])

        XCTAssertTrue(tokenLog.queries.isEmpty, "没有 cask 就不该调 brew")
    }

    /// 问不到就如实说问不到。报"已是最新"比报错版本号更隐蔽。
    func testUnavailableBrewIsReportedAsFailureNotUpToDate() async {
        let log = ProbeLog()
        let tokenLog = TokenLog()

        let results = await engine(probeLog: log, tokenLog: tokenLog, outdated: nil)
            .check(apps: [makeApp("ngrok", source: .homebrewCask(token: "ngrok"))])

        guard case .failed(let reason) = results.first?.result else {
            return XCTFail("brew 不可用时应报检查失败，而不是已是最新")
        }
        XCTAssertTrue(reason.contains("Homebrew"))
    }
}

/// 增量刷新：只重读变更过的包、只探这些应用，并把结果并回全量列表。
final class IncrementalRefreshTests: XCTestCase {
    private var root: URL!
    private var probeLog: ProbeLog!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncrementalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        probeLog = ProbeLog()
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    @discardableResult
    private func makeApp(_ name: String, bundleID: String? = nil, version: String, extra: [String: Any] = [:]) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleID ?? "com.example.\(name)",
            "CFBundleShortVersionString": version,
            "CFBundleDisplayName": name
        ]
        plist.merge(extra) { _, new in new }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func update(_ path: URL, name: String, bundleID: String, version: String, source: AppSource) -> AppUpdate {
        AppUpdate(
            app: AppInfo(
                name: name,
                bundleID: bundleID,
                path: path,
                currentVersion: version,
                buildVersion: nil,
                source: source
            ),
            result: .updateAvailable(ReleaseInfo(version: "9.9"))
        )
    }

    private func checker(answer: @escaping @Sendable (AppInfo) -> UpdateResult = { _ in .upToDate(latest: "9.9") }) -> IncrementalChecker {
        let probe = StubProbe(log: probeLog, answer: answer)
        let engine = CheckEngine(
            sparkleProbe: probe,
            electronProbe: probe,
            masProbe: probe,
            gitHubProbe: probe,
            brewOutdated: { _ in [:] },
            concurrency: 4
        )
        return IncrementalChecker(scanner: AppScanner(), engine: engine)
    }

    private var sparkle: AppSource { .sparkle(feedURL: URL(string: "https://example.com/appcast.xml")) }

    // MARK: - 只动该动的

    func testRefreshProbesOnlyTheTargets() async throws {
        let a = try makeApp("IINA", version: "1.3.5")
        let b = try makeApp("Bob", version: "1.9.2")
        let c = try makeApp("Vox", version: "3.0.0")

        let list = [
            update(a, name: "IINA", bundleID: "com.example.IINA", version: "1.3.5", source: sparkle),
            update(b, name: "Bob", bundleID: "com.example.Bob", version: "1.9.2", source: sparkle),
            update(c, name: "Vox", bundleID: "com.example.Vox", version: "3.0.0", source: sparkle)
        ]

        let report = await checker().refresh(targets: [list[0]], caskIndex: nil)

        XCTAssertEqual(probeLog.names, ["IINA"], "其余两个应用一个都不该被探测")
        XCTAssertEqual(report.refreshed.count, 1)
        XCTAssertTrue(report.missing.isEmpty)
    }

    func testRefreshPicksUpTheVersionThatIsActuallyOnDisk() async throws {
        let path = try makeApp("AlDente", version: "1.34.0")
        let stale = update(path, name: "AlDente", bundleID: "com.example.AlDente", version: "1.34.0", source: sparkle)

        // 模拟"刚刚换包完成"：盘上的版本已经变了。
        try makeApp("AlDente", version: "1.39.2")

        let report = await checker().refresh(targets: [stale], caskIndex: nil)

        XCTAssertEqual(report.refreshed.first?.app.currentVersion, "1.39.2", "新版号必须从磁盘读，不能沿用旧条目")
        XCTAssertEqual(report.refreshed.first?.result, .upToDate(latest: "9.9"))
    }

    func testBundleGoneIsReportedNotSilentlyDropped() async throws {
        let path = try makeApp("Ghost", version: "1.0.0")
        let target = update(path, name: "Ghost", bundleID: "com.example.Ghost", version: "1.0.0", source: sparkle)
        try FileManager.default.removeItem(at: path)

        let report = await checker().refresh(targets: [target], caskIndex: nil)

        XCTAssertTrue(report.refreshed.isEmpty)
        XCTAssertEqual(report.missing.count, 1)
        guard case .failed(let reason) = report.missing.first?.result else {
            return XCTFail("包没了必须如实上报")
        }
        XCTAssertTrue(reason.contains("不在原路径"))
        XCTAssertEqual(probeLog.count, 0, "包都不在了就不该再发请求")
    }

    func testUnsupportedSourceIsNotProbed() async throws {
        let path = try makeApp("Steam", version: "1.0.0")
        let target = AppUpdate(
            app: AppInfo(
                name: "Steam",
                bundleID: "com.example.Steam",
                path: path,
                currentVersion: "1.0.0",
                buildVersion: nil,
                source: .unsupported(reason: "Steam 客户端内更新")
            ),
            result: .updateAvailable(ReleaseInfo(version: "2.0"))
        )

        let report = await checker().refresh(targets: [target], caskIndex: nil)

        XCTAssertEqual(probeLog.count, 0, "不支持自动检测的来源不该走进网络探测")
        XCTAssertEqual(report.refreshed.count, 1)
        XCTAssertEqual(report.refreshed.first?.group, .unsupported)
    }

    // MARK: - 分类沿用

    func testSourceIsCarriedOverWhenNoBrewIndexIsAvailable() async throws {
        let path = try makeApp("Tabularis", version: "1.0.0")
        let target = update(path, name: "Tabularis", bundleID: "com.example.Tabularis",
                            version: "1.0.0", source: .homebrewCask(token: "tabularis"))

        let report = await checker().refresh(targets: [target], caskIndex: nil)

        XCTAssertEqual(report.reusedSourceCount, 1)
        guard case .homebrewCask(let token) = report.refreshed.first?.app.source else {
            return XCTFail("没有索引时必须沿用上一次的 Homebrew 判定，而不是降级成未知来源")
        }
        XCTAssertEqual(token, "tabularis")
    }

    func testSourceIsNotCarriedOverWhenTheBundleIdentityChanged() async throws {
        // 路径上蹲的已经是另一个应用了，旧结论对它没有意义。
        let path = try makeApp("Squatter", bundleID: "com.example.Squatter", version: "1.0.0")
        let target = update(path, name: "Tabularis", bundleID: "com.example.Tabularis",
                            version: "1.0.0", source: .homebrewCask(token: "tabularis"))

        let report = await checker().refresh(targets: [target], caskIndex: nil)

        XCTAssertEqual(report.reusedSourceCount, 0)
        guard case .unsupported = report.refreshed.first?.app.source else {
            return XCTFail("Bundle ID 变了就不该沿用旧来源")
        }
    }

    func testFreshIndexReclassifiesFromDisk() async throws {
        let path = try makeApp("Tabularis", version: "1.0.0")
        let target = update(path, name: "Tabularis", bundleID: "com.example.Tabularis",
                            version: "1.0.0", source: .unsupported(reason: "未识别到公开的更新接口"))
        let index = BrewCaskIndex(appNameToToken: ["tabularis": "tabularis"],
                                  installedTokens: ["tabularis"], binaryOnlyTokens: [:])

        let report = await checker().refresh(targets: [target], caskIndex: index)

        XCTAssertEqual(report.reusedSourceCount, 0, "有索引时不需要兜底")
        guard case .homebrewCask(let token) = report.refreshed.first?.app.source else {
            return XCTFail("有索引就该按索引重新判定")
        }
        XCTAssertEqual(token, "tabularis")
    }

    // MARK: - 合并

    func testMergeKeepsUntouchedEntriesIntact() async throws {
        let a = try makeApp("IINA", version: "1.3.5")
        let b = try makeApp("Bob", version: "1.9.2")
        let c = try makeApp("Vox", version: "3.0.0")

        let list = [
            update(a, name: "IINA", bundleID: "com.example.IINA", version: "1.3.5", source: sparkle),
            update(b, name: "Bob", bundleID: "com.example.Bob", version: "1.9.2", source: sparkle),
            update(c, name: "Vox", bundleID: "com.example.Vox", version: "3.0.0", source: sparkle)
        ]

        let report = await checker(answer: { _ in .upToDate(latest: "1.4.4") }).refresh(targets: [list[0]], caskIndex: nil)
        let merged = IncrementalChecker.merge(report.all, into: list)

        XCTAssertEqual(merged.count, 3, "不该丢掉没被碰过的条目")
        XCTAssertEqual(merged.first { $0.app.name == "IINA" }?.result, .upToDate(latest: "1.4.4"))
        XCTAssertEqual(merged.first { $0.app.name == "Bob" }?.result, .updateAvailable(ReleaseInfo(version: "9.9")))
        XCTAssertEqual(merged.first { $0.app.name == "Vox" }?.result, .updateAvailable(ReleaseInfo(version: "9.9")))
    }

    func testMergeSortsByGroupThenName() {
        func item(_ name: String, _ result: UpdateResult) -> AppUpdate {
            AppUpdate(
                app: AppInfo(name: name, bundleID: nil,
                             path: URL(fileURLWithPath: "/Applications/\(name).app"),
                             currentVersion: "1.0", buildVersion: nil, source: .appStore),
                result: result
            )
        }

        let merged = IncrementalChecker.merge(
            [item("Aurora", .upToDate(latest: "1.0"))],
            into: [item("Zoom", .updateAvailable(ReleaseInfo(version: "2.0")))]
        )

        XCTAssertEqual(merged.map(\.app.name), ["Zoom", "Aurora"], "先按分组（可更新在前），再按名称")
    }

    func testMergeWithNoChangesReturnsTheOriginalList() {
        let list = [AppUpdate(
            app: AppInfo(name: "IINA", bundleID: nil,
                         path: URL(fileURLWithPath: "/Applications/IINA.app"),
                         currentVersion: "1.0", buildVersion: nil, source: .appStore),
            result: .upToDate(latest: "1.0")
        )]
        XCTAssertEqual(IncrementalChecker.merge([], into: list).map(\.app.name), ["IINA"])
    }
}

/// 单包重读本身的行为。
final class BundleInspectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InspectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testInspectReadsASingleBundleWithoutScanningTheDirectory() throws {
        let target = root.appendingPathComponent("Target.app", isDirectory: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.Target", "CFBundleShortVersionString": "2.1.0"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: target.appendingPathComponent("Contents/Info.plist"))

        // 同目录里再放一个包，单包重读不该看见它。
        let neighbour = root.appendingPathComponent("Neighbour.app", isDirectory: true)
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)

        let scanner = AppScanner(searchPaths: [root])
        let scanned = try XCTUnwrap(scanner.inspect(bundleAt: target))

        XCTAssertEqual(scanned.bundleID, "com.example.Target")
        XCTAssertEqual(scanned.currentVersion, "2.1.0")
        XCTAssertNotEqual(scanned.name, "Neighbour")
    }

    func testInspectReturnsNilForPathsThatAreNotAppBundles() throws {
        let scanner = AppScanner(searchPaths: [root])
        let missing = root.appendingPathComponent("Nope.app", isDirectory: true)
        XCTAssertNil(scanner.inspect(bundleAt: missing), "包不存在必须返回 nil，而不是伪造空条目")

        try FileManager.default.createDirectory(at: root.appendingPathComponent("Plain", isDirectory: true), withIntermediateDirectories: true)
        XCTAssertNil(scanner.inspect(bundleAt: root.appendingPathComponent("Plain")), "非 .app 目录不算包")

        let file = root.appendingPathComponent("loose.app")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        XCTAssertNil(scanner.inspect(bundleAt: file), "同名文件不算包")
    }

    func testTrustedFallbackIsIgnoredWhenAnIndexIsPresent() throws {
        let scanned = ScannedApp(
            name: "Tabularis", bundleID: "com.example.Tabularis",
            path: URL(fileURLWithPath: "/Applications/Tabularis.app"),
            currentVersion: "1.0", buildVersion: nil,
            feedURLString: nil, publicEDKey: nil,
            hasMASReceipt: false, hasEmbeddedSparkle: false, appUpdateYML: nil
        )
        let index = BrewCaskIndex(appNameToToken: [:], installedTokens: [], binaryOnlyTokens: [:])

        let app = AppClassifier(caskIndex: index).classify(scanned, trustedFallback: .homebrewCask(token: "tabularis"))

        guard case .unsupported = app.source else {
            return XCTFail("有索引时判定是完整的，不该被兜底覆盖")
        }
    }
}

/// 状态源这一层：升级收尾走的是增量刷新，而不是整机重扫。
///
/// 这组测试用假探针直接观察"被探测了哪些应用"，因此如果有人把收尾改回 `check()`，
/// 断言会立刻发现范围扩散到整份列表。
final class UpdateStoreRefreshTests: XCTestCase {
    /// 定成整秒：缓存往返用的是 ISO8601，带小数的日期会被截断，Equatable 就比不平了。
    private let fullCheckTime = Date(timeIntervalSince1970: 1_000_000)

    private var root: URL!
    private var probeLog: ProbeLog!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        probeLog = ProbeLog()
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    @discardableResult
    private func makeApp(_ name: String, version: String) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.\(name)",
            "CFBundleShortVersionString": version,
            "CFBundleDisplayName": name
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func makeRow(_ path: URL, name: String, version: String) -> AppUpdate {
        AppUpdate(
            app: AppInfo(
                name: name,
                bundleID: "com.example.\(name)",
                path: path,
                currentVersion: version,
                buildVersion: nil,
                source: .sparkle(feedURL: URL(string: "https://example.com/appcast.xml"))
            ),
            result: .updateAvailable(ReleaseInfo(version: "9.9")),
            checkedAt: fullCheckTime
        )
    }

    private func makeEngine(answer: @escaping @Sendable (AppInfo) -> UpdateResult = { _ in .upToDate(latest: "1.0") }) -> CheckEngine {
        let probe = StubProbe(log: probeLog, answer: answer)
        return CheckEngine(
            sparkleProbe: probe,
            electronProbe: probe,
            masProbe: probe,
            gitHubProbe: probe,
            brewOutdated: { _ in [:] },
            concurrency: 4
        )
    }

    @MainActor
    private func makeStore(rows: [AppUpdate], engine: CheckEngine) -> (UpdateStore, StateCache) {
        let cache = StateCache(fileURL: root.appendingPathComponent("state.json"))
        cache.save(.init(updates: rows, savedAt: fullCheckTime, lastFullCheckAt: fullCheckTime))
        return (UpdateStore(engine: engine, cache: cache), cache)
    }

    // MARK: - 只重查变更过的那一个

    @MainActor
    func testRefreshAfterAnUpgradeOnlyRechecksTheTouchedApp() async throws {
        let a = try makeApp("IINA", version: "1.4.4")
        let b = try makeApp("Bob", version: "1.9.2")
        let c = try makeApp("Vox", version: "3.0.0")
        let rows = [
            makeRow(a, name: "IINA", version: "1.4.4"),
            makeRow(b, name: "Bob", version: "1.9.2"),
            makeRow(c, name: "Vox", version: "3.0.0")
        ]

        let (store, cache) = makeStore(rows: rows, engine: makeEngine())
        XCTAssertEqual(store.updates.count, 3)

        let finished = await store.refresh(ids: [a.path])

        XCTAssertTrue(finished)
        XCTAssertEqual(probeLog.names, ["IINA"], "升级收尾绝不能退化成整机重扫")
        XCTAssertFalse(store.isChecking, "增量刷新不该表现成一次全量扫描")
        XCTAssertFalse(store.isRefreshing)
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(store.statusMessage.isEmpty)

        // 没被碰过的两行原样保留。
        XCTAssertEqual(store.updates.count, 3)
        XCTAssertEqual(
            store.updates.first { $0.app.name == "Bob" }?.result,
            .updateAvailable(ReleaseInfo(version: "9.9"))
        )

        // 缓存被并回、写盘，且"上次全量检查"没有被增量刷新顶掉。
        let reloaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(reloaded.updates.count, 3)
        XCTAssertEqual(reloaded.lastFullCheckAt, fullCheckTime)
        XCTAssertGreaterThan(reloaded.savedAt, fullCheckTime)
        XCTAssertEqual(store.lastChecked, fullCheckTime, "列表整体仍然是全量那一刻的结论")

        // "只重查了 1 项"必须能被读出来，而不是只能靠读代码相信。
        let stat = try XCTUnwrap(store.lastRefresh)
        XCTAssertEqual(stat.targets, 1)
        XCTAssertEqual(stat.listSize, 3)
        XCTAssertEqual(stat.missing, 0)
    }

    @MainActor
    func testRefreshUsesTheVersionThatIsNowOnDisk() async throws {
        let a = try makeApp("AlDente", version: "1.39.2")
        let rows = [makeRow(a, name: "AlDente", version: "1.34.0")]

        let (store, _) = makeStore(rows: rows, engine: makeEngine(answer: { _ in .upToDate(latest: "1.39.2") }))
        _ = await store.refresh(ids: [a.path])

        XCTAssertEqual(store.updates.first?.app.currentVersion, "1.39.2")
        XCTAssertEqual(store.updates.first?.result, .upToDate(latest: "1.39.2"))
    }

    @MainActor
    func testRefreshWithNoMatchingTargetIsANoOp() async throws {
        let a = try makeApp("IINA", version: "1.4.4")
        let rows = [makeRow(a, name: "IINA", version: "1.4.4")]

        let (store, _) = makeStore(rows: rows, engine: makeEngine())
        let finished = await store.refresh(ids: ["/Applications/DoesNotExist.app"])

        XCTAssertTrue(finished)
        XCTAssertEqual(probeLog.count, 0)
        XCTAssertEqual(store.updates, rows)
    }

    @MainActor
    func testRefreshHandlesABatchWithoutTouchingTheRest() async throws {
        let a = try makeApp("IINA", version: "1.4.4")
        let b = try makeApp("Bob", version: "1.9.2")
        let c = try makeApp("Vox", version: "3.0.0")
        let rows = [
            makeRow(a, name: "IINA", version: "1.4.4"),
            makeRow(b, name: "Bob", version: "1.9.2"),
            makeRow(c, name: "Vox", version: "3.0.0")
        ]

        let (store, _) = makeStore(rows: rows, engine: makeEngine())
        _ = await store.refresh(ids: [a.path, b.path])

        XCTAssertEqual(Set(probeLog.names), ["IINA", "Bob"], "批量升级也只该重查动过的那几个")
        XCTAssertEqual(store.updates.count, 3)
    }

    @MainActor
    func testExpiredBundleIsKeptAndExplained() async throws {
        let a = try makeApp("Ghost", version: "1.0.0")
        let rows = [makeRow(a, name: "Ghost", version: "1.0.0")]
        try FileManager.default.removeItem(at: a)

        let (store, _) = makeStore(rows: rows, engine: makeEngine())
        _ = await store.refresh(ids: [a.path])

        XCTAssertEqual(store.updates.count, 1, "包没了也不能静默丢掉这一行")
        guard case .failed(let reason) = store.updates.first?.result else {
            return XCTFail("应如实标成检查失败")
        }
        XCTAssertTrue(reason.contains("不在原路径"))
    }
}
