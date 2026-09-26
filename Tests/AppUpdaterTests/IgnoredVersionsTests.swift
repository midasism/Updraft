import XCTest
@testable import AppUpdaterKit

/// 「忽略这个版本」：记录的判定、持久化，以及在 UpdateStore 各条路径上的行为。
final class IgnoredVersionsTests: XCTestCase {

    private var root: URL!
    private var probeLog: ProbeLog!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IgnoredTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        probeLog = ProbeLog()
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 判定

    private func makeApp(version: String) -> AppInfo {
        AppInfo(
            name: "AlDente",
            bundleID: "com.example.AlDente",
            path: URL(fileURLWithPath: "/Applications/AlDente.app"),
            currentVersion: version,
            buildVersion: nil,
            source: .sparkle(feedURL: URL(string: "https://example.com/appcast.xml")!)
        )
    }

    func testNoRecordMeansNoSuppression() {
        let ignored = IgnoredVersions()
        XCTAssertEqual(
            ignored.decide(app: makeApp(version: "1.3.0"), latestVersion: "1.4.4"),
            .noRecord
        )
    }

    func testSameVersionIsSuppressed() {
        var ignored = IgnoredVersions()
        ignored.ignore(app: makeApp(version: "1.3.0"), version: "1.4.4")
        XCTAssertEqual(
            ignored.decide(app: makeApp(version: "1.3.0"), latestVersion: "1.4.4"),
            .suppress(version: "1.4.4")
        )
    }

    func testVersionEquivalence() {
        // 点分语义比较：补零、去 v 前缀之后是同一版本，不能靠字符串相等。
        var ignored = IgnoredVersions()
        let app = makeApp(version: "1.3.0")

        ignored.ignore(app: app, version: "1.4.0")
        XCTAssertEqual(ignored.decide(app: app, latestVersion: "v1.4"), .suppress(version: "1.4.0"))

        ignored.ignore(app: app, version: "1.4")
        XCTAssertEqual(ignored.decide(app: app, latestVersion: "1.4.0.0"), .suppress(version: "1.4"))
    }

    func testNewerVersionClearsTheRecord() {
        var ignored = IgnoredVersions()
        let app = makeApp(version: "1.3.0")
        ignored.ignore(app: app, version: "1.4.4")
        XCTAssertEqual(ignored.decide(app: app, latestVersion: "1.5.0"), .clear)
        // 上游回滚/降版同样是"不高于被忽略版本"，继续抑制。
        XCTAssertEqual(ignored.decide(app: app, latestVersion: "1.4.3"), .suppress(version: "1.4.4"))
    }

    func testPrereleaseOfIgnoredVersionIsAlsoSuppressed() {
        var ignored = IgnoredVersions()
        let app = makeApp(version: "2.0.0")
        ignored.ignore(app: app, version: "2.1.0")
        // 2.1.0-beta.2 比 2.1.0 更早，不高于被忽略版本 → 继续抑制。
        XCTAssertEqual(ignored.decide(app: app, latestVersion: "2.1.0-beta.2"), .suppress(version: "2.1.0"))
    }

    func testInstalledBeyondIgnoredClearsTheRecord() {
        var ignored = IgnoredVersions()
        // 用户手动把应用升到了 1.4.4（等于被忽略版本），记录失去意义。
        XCTAssertEqual(
            ignored.decide(app: makeApp(version: "1.4.4"), latestVersion: "1.4.4"),
            .clear
        )
    }

    // MARK: - 键与持久化

    func testBundleIDTakesPriorityOverCaskToken() {
        let app = AppInfo(
            name: "Foo",
            bundleID: "com.example.Foo",
            path: URL(fileURLWithPath: "/Applications/Foo.app"),
            currentVersion: "1.0",
            buildVersion: nil,
            source: .homebrewCask(token: "foo")
        )
        XCTAssertEqual(IgnoredVersions.key(for: app), "bundle:com.example.Foo")
    }

    func testCommandLineCaskFallsBackToToken() {
        let app = AppInfo.commandLineCask(token: "ngrok", installedVersion: "3.0")
        XCTAssertEqual(IgnoredVersions.key(for: app), "cask:ngrok")
    }

    func testPersistsAcrossInstances() throws {
        let fileURL = root.appendingPathComponent("ignored.json")
        let app = makeApp(version: "1.3.0")

        var writer = IgnoredVersions(fileURL: fileURL)
        writer.ignore(app: app, version: "1.4.4")
        writer.save()

        let reader = IgnoredVersions(fileURL: fileURL)
        XCTAssertEqual(
            reader.decide(app: app, latestVersion: "1.4.4"),
            .suppress(version: "1.4.4")
        )
    }

    func testCorruptFileStartsEmptyInsteadOfFailing() throws {
        let fileURL = root.appendingPathComponent("broken.json")
        try Data("not json at all".utf8).write(to: fileURL)

        let ignored = IgnoredVersions(fileURL: fileURL)
        XCTAssertEqual(
            ignored.decide(app: makeApp(version: "1.0"), latestVersion: "2.0"),
            .noRecord
        )
    }

    // MARK: - UpdateStore 集成

    private let fullCheckTime = Date(timeIntervalSince1970: 1_000_000)

    private func makeBundle(_ name: String, version: String) throws -> URL {
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

    private func makeRow(_ path: URL, name: String, version: String, release: String) -> AppUpdate {
        AppUpdate(
            app: AppInfo(
                name: name,
                bundleID: "com.example.\(name)",
                path: path,
                currentVersion: version,
                buildVersion: nil,
                source: .sparkle(feedURL: URL(string: "https://example.com/appcast.xml"))
            ),
            result: .updateAvailable(ReleaseInfo(version: release)),
            checkedAt: fullCheckTime
        )
    }

    private func makeEngine() -> CheckEngine {
        let probe = StubProbe(log: probeLog, answer: { _ in .upToDate(latest: "1.0") })
        return CheckEngine(
            sparkleProbe: probe,
            electronProbe: probe,
            brewOutdated: { _ in [:] },
            concurrency: 4
        )
    }

    @MainActor
    private func makeStore(rows: [AppUpdate]) -> (UpdateStore, StateCache, URL) {
        let cacheURL = root.appendingPathComponent("state.json")
        let ignoredURL = root.appendingPathComponent("ignored.json")
        let cache = StateCache(fileURL: cacheURL)
        cache.save(.init(updates: rows, savedAt: fullCheckTime, lastFullCheckAt: fullCheckTime))
        let store = UpdateStore(
            engine: makeEngine(),
            cache: cache,
            ignored: IgnoredVersions(fileURL: ignoredURL)
        )
        return (store, cache, ignoredURL)
    }

    @MainActor
    func testIgnoreMovesRowIntoIgnoredGroupAndExcludesItFromCounts() async throws {
        let a = try makeBundle("IINA", version: "1.3.0")
        let (store, _, _) = makeStore(rows: [makeRow(a, name: "IINA", version: "1.3.0", release: "1.4.4")])

        let row = try XCTUnwrap(store.updates.first)
        XCTAssertEqual(row.group, .updateAvailable)
        XCTAssertEqual(store.updateCount, 1)

        store.ignoreVersion(of: row)

        XCTAssertEqual(store.updates.first?.group, .ignored)
        XCTAssertEqual(store.updates.first?.ignoredVersion, "1.4.4")
        XCTAssertEqual(store.updateCount, 0, "被忽略的条目不能再进「可更新」计数")
        XCTAssertEqual(store.automatedUpdateCount, 0, "「全部升级」绝不能带上被忽略的条目")
        XCTAssertEqual(store.ignoredCount, 1)
    }

    @MainActor
    func testIgnoredRecordSurvivesColdStartReplay() async throws {
        let a = try makeBundle("IINA", version: "1.3.0")
        let (store, _, ignoredURL) = makeStore(rows: [makeRow(a, name: "IINA", version: "1.3.0", release: "1.4.4")])
        store.ignoreVersion(of: try XCTUnwrap(store.updates.first))

        // 冷启动：同一路径重新构造，缓存回放后抑制状态必须还在——
        // 否则启动那一瞬间"可更新"的提示会闪出来。
        let cache = StateCache(fileURL: root.appendingPathComponent("state.json"))
        let reborn = UpdateStore(
            engine: makeEngine(),
            cache: cache,
            ignored: IgnoredVersions(fileURL: ignoredURL)
        )
        XCTAssertEqual(reborn.updates.first?.group, .ignored)
        XCTAssertEqual(reborn.updates.first?.ignoredVersion, "1.4.4")
    }

    @MainActor
    func testNewerReleaseAutoClearsTheRecordOnReplay() throws {
        let a = try makeBundle("IINA", version: "1.3.0")
        let (store, _, ignoredURL) = makeStore(rows: [makeRow(a, name: "IINA", version: "1.3.0", release: "1.4.4")])
        store.ignoreVersion(of: try XCTUnwrap(store.updates.first))

        // 上游出了 1.5.0：手动把缓存里的结果换成新版本，模拟下一次全量检查之后的状态。
        let cacheURL = root.appendingPathComponent("state.json")
        let cache = StateCache(fileURL: cacheURL)
        var fresh = makeRow(a, name: "IINA", version: "1.3.0", release: "1.5.0")
        fresh.checkedAt = Date()
        cache.save(.init(updates: [fresh], savedAt: Date(), lastFullCheckAt: Date()))

        _ = UpdateStore(
            engine: makeEngine(),
            cache: cache,
            ignored: IgnoredVersions(fileURL: ignoredURL)
        )
        // 回放时判定为 .clear：记录被删除、条目回到「可更新」。
        let record = IgnoredVersions(fileURL: ignoredURL)
        XCTAssertEqual(
            record.decide(app: fresh.app, latestVersion: "1.5.0"),
            .noRecord,
            "出现更高版本后忽略记录应被清除"
        )
    }

    @MainActor
    func testUnignoreRestoresTheRowImmediately() async throws {
        let a = try makeBundle("IINA", version: "1.3.0")
        let (store, _, _) = makeStore(rows: [makeRow(a, name: "IINA", version: "1.3.0", release: "1.4.4")])
        let row = try XCTUnwrap(store.updates.first)

        store.ignoreVersion(of: row)
        XCTAssertEqual(store.updates.first?.group, .ignored)

        store.unignoreVersion(of: row)
        XCTAssertEqual(store.updates.first?.group, .updateAvailable, "取消忽略要立刻生效，不需要重新探测")
        XCTAssertEqual(store.updates.first?.ignoredVersion, nil)
        XCTAssertEqual(store.updateCount, 1)
    }

    @MainActor
    func testAutomaticRefreshSkipsSuppressedRowsButForceDoesNot() async throws {
        let a = try makeBundle("IINA", version: "1.3.0")
        let (store, _, _) = makeStore(rows: [makeRow(a, name: "IINA", version: "1.3.0", release: "1.4.4")])
        store.ignoreVersion(of: try XCTUnwrap(store.updates.first))

        // 自动刷新（升级收尾）：被抑制的条目不重问——上游版本不会因为本机升级别的应用而变。
        _ = await store.refresh(ids: [a.path])
        XCTAssertTrue(probeLog.names.isEmpty, "被忽略条目不该被自动刷新重问")

        // 强制刷新：用户主动要求时才重新探测。
        _ = await store.refresh(ids: [a.path], force: true)
        XCTAssertEqual(probeLog.names, ["IINA"])
    }
}
