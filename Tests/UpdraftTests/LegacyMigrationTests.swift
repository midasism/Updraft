import XCTest
@testable import UpdraftKit

/// 改名（AppUpdater → Updraft）之后的兼容与迁移。
///
/// 这一套守的是三类事：
/// 1. 老 Bundle ID / 老目录名**仍然被认作自己**，不会作为第三方应用冒出来；
/// 2. 老数据（备份、状态、设置）搬得过来，且**只搬一次**、不覆盖已有值；
/// 3. 自更新换包时旧目录名被规范成 `Updraft.app`。
///
/// 全部在临时目录与随机 suite 上跑，绝不碰用户真实的
/// `~/Library/Application Support/Updraft` 与 `com.local.updraft.settings`。
final class LegacyMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdraftLegacyMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 身份

    func testIdentityUsesUpdraftNames() {
        XCTAssertEqual(SelfUpdateIdentity.bundleID, "com.local.updraft")
        XCTAssertEqual(SelfUpdateIdentity.appFileName, "Updraft.app")
        XCTAssertEqual(SelfUpdateIdentity.supportDirectoryName, "Updraft")
        XCTAssertEqual(SelfUpdateIdentity.displayName, "Updraft")
    }

    func testLegacyBundleIDStillCountsAsSelf() {
        XCTAssertTrue(SelfUpdateIdentity.isSelf(bundleID: SelfUpdateIdentity.bundleID))
        XCTAssertTrue(SelfUpdateIdentity.isSelf(bundleID: SelfUpdateIdentity.Legacy.bundleID))
        XCTAssertFalse(SelfUpdateIdentity.isSelf(bundleID: "com.example.other"))
        XCTAssertFalse(SelfUpdateIdentity.isSelf(bundleID: nil))
    }

    /// 老版本装在 `/Applications/AppUpdater.app`，Bundle ID 是旧的。
    /// 认不出它，它就会以一个「可以升级的第三方应用」的身份混进主列表。
    func testLegacyInstalledAppIsExcludedFromMainList() {
        let legacy = AppInfo(
            name: "Updraft",
            bundleID: SelfUpdateIdentity.Legacy.bundleID,
            path: URL(fileURLWithPath: "/Applications/AppUpdater.app"),
            currentVersion: "0.3.3",
            buildVersion: "9",
            source: .unsupported(reason: "本工具自更新"),
            publicEDKey: SelfUpdateIdentity.publicEDKey
        )
        XCTAssertTrue(SelfUpdateIdentity.isSelf(legacy))
        XCTAssertTrue(SelfUpdateIdentity.excludingSelf([legacy]).isEmpty)
    }

    // MARK: - 换包目标改名

    func testCanonicalTargetRenamesLegacyBundle() throws {
        let legacy = root.appendingPathComponent("AppUpdater.app", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

        let canonical = SelfUpdateIdentity.canonicalTargetURL(for: legacy)
        XCTAssertEqual(canonical.lastPathComponent, "Updraft.app")
        // 必须留在同一个目录：跨卷的 move 不是原子的，而换包依赖同卷 rename。
        XCTAssertEqual(canonical.deletingLastPathComponent().path, root.path)
    }

    func testCanonicalTargetLeavesUpdraftBundleAlone() throws {
        let current = root.appendingPathComponent("Updraft.app", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        XCTAssertEqual(SelfUpdateIdentity.canonicalTargetURL(for: current), current)
    }

    /// 新名字被别人占着的时候不许赌：宁可留着旧目录名，也不能覆盖别的东西。
    func testCanonicalTargetFallsBackWhenNameIsTaken() throws {
        let legacy = root.appendingPathComponent("AppUpdater.app", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Updraft.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(SelfUpdateIdentity.canonicalTargetURL(for: legacy), legacy)
    }

    // MARK: - 目录迁移

    func testMigratesLegacySupportDirectory() throws {
        let from = root.appendingPathComponent("AppUpdater", isDirectory: true)
        let to = root.appendingPathComponent("Updraft", isDirectory: true)
        try FileManager.default.createDirectory(
            at: from.appendingPathComponent("Backups"),
            withIntermediateDirectories: true
        )
        try Data("state".utf8).write(to: from.appendingPathComponent("state-v2.json"))

        XCTAssertTrue(LegacyMigration.migrateDirectory(from: from, to: to))
        XCTAssertFalse(FileManager.default.fileExists(atPath: from.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: to.appendingPathComponent("state-v2.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: to.appendingPathComponent("Backups").path))
    }

    func testDirectoryMigrationIsIdempotent() throws {
        let from = root.appendingPathComponent("AppUpdater", isDirectory: true)
        let to = root.appendingPathComponent("Updraft", isDirectory: true)
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)

        XCTAssertTrue(LegacyMigration.migrateDirectory(from: from, to: to))
        XCTAssertFalse(LegacyMigration.migrateDirectory(from: from, to: to))
    }

    /// 新目录已经在了就当没看见——合并两份目录里的备份只会更糟，
    /// 留着老目录让用户自己判断。
    func testDirectoryMigrationRefusesToMerge() throws {
        let from = root.appendingPathComponent("AppUpdater", isDirectory: true)
        let to = root.appendingPathComponent("Updraft", isDirectory: true)
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)

        XCTAssertFalse(LegacyMigration.migrateDirectory(from: from, to: to))
        XCTAssertTrue(FileManager.default.fileExists(atPath: from.path))
    }

    // MARK: - 设置迁移

    func testMigratesDefaultsWithoutOverwritingExistingValues() throws {
        let legacySuite = "\(SelfUpdateIdentity.bundleID).legacy-test.\(UUID().uuidString)"
        let newSuite = "\(SelfUpdateIdentity.bundleID).new-test.\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: legacySuite)
            UserDefaults().removePersistentDomain(forName: newSuite)
        }

        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacySuite))
        let current = try XCTUnwrap(UserDefaults(suiteName: newSuite))
        legacy.set(true, forKey: "check.schedule.enabled")
        legacy.set(7, forKey: "check.schedule.hour")
        legacy.set(30, forKey: "check.schedule.minute")
        // 新 suite 里已经有的值优先级更高
        current.set(false, forKey: "notifications.enabled")

        XCTAssertTrue(LegacyMigration.migrateDefaults(from: legacySuite, to: newSuite))
        XCTAssertTrue(current.bool(forKey: "check.schedule.enabled"))
        XCTAssertEqual(current.integer(forKey: "check.schedule.hour"), 7)
        XCTAssertEqual(current.integer(forKey: "check.schedule.minute"), 30)
        XCTAssertFalse(current.bool(forKey: "notifications.enabled"))
        XCTAssertTrue(current.bool(forKey: LegacyMigration.completedKey))
    }

    func testDefaultsMigrationRunsOnce() throws {
        let legacySuite = "\(SelfUpdateIdentity.bundleID).legacy-once.\(UUID().uuidString)"
        let newSuite = "\(SelfUpdateIdentity.bundleID).new-once.\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: legacySuite)
            UserDefaults().removePersistentDomain(forName: newSuite)
        }

        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacySuite))
        legacy.set(9, forKey: "check.schedule.hour")

        XCTAssertTrue(LegacyMigration.migrateDefaults(from: legacySuite, to: newSuite))
        XCTAssertFalse(LegacyMigration.migrateDefaults(from: legacySuite, to: newSuite))
    }

    /// 只搬老域**自己的**键。
    ///
    /// 用 `dictionaryRepresentation()` 会把 NSGlobalDomain 的六十多个系统键（语言、
    /// 触控板手势…）一起端上来——实测同一份 suite 是 64 个键 vs 我们自己的 2 个。
    /// 这条按「落盘的键集合」断言，顺带证明搬过去的确实只有该域的东西。
    func testDefaultsMigrationCopiesOnlyTheLegacyDomain() throws {
        let legacySuite = "\(SelfUpdateIdentity.bundleID).legacy-scoped.\(UUID().uuidString)"
        let newSuite = "\(SelfUpdateIdentity.bundleID).new-scoped.\(UUID().uuidString)"
        defer {
            UserDefaults().removePersistentDomain(forName: legacySuite)
            UserDefaults().removePersistentDomain(forName: newSuite)
        }

        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacySuite))
        legacy.set(7, forKey: "check.schedule.hour")
        legacy.set(30, forKey: "check.schedule.minute")

        XCTAssertTrue(LegacyMigration.migrateDefaults(from: legacySuite, to: newSuite))

        let landed = UserDefaults.standard.persistentDomain(forName: newSuite) ?? [:]
        XCTAssertEqual(
            landed.keys.sorted(),
            ["check.schedule.hour", "check.schedule.minute", LegacyMigration.completedKey].sorted()
        )
    }

    /// 老域压根不存在时不许崩，也不许每次启动都重扫一遍。
    func testDefaultsMigrationStillMarksCompleteWhenLegacyDomainIsAbsent() throws {
        let absent = "\(SelfUpdateIdentity.bundleID).legacy-absent.\(UUID().uuidString)"
        let newSuite = "\(SelfUpdateIdentity.bundleID).new-absent.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: newSuite) }

        XCTAssertFalse(LegacyMigration.migrateDefaults(from: absent, to: newSuite), "没搬到东西就不该报成功")
        XCTAssertTrue(
            try XCTUnwrap(UserDefaults(suiteName: newSuite)).bool(forKey: LegacyMigration.completedKey),
            "标记还是要打上，否则每次启动都白扫一遍"
        )
        XCTAssertFalse(LegacyMigration.migrateDefaults(from: absent, to: newSuite))
    }
}
