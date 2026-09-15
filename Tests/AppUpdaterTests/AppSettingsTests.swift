import XCTest
@testable import AppUpdaterKit

/// 设置的持久化：临时 suite 进出，不碰真实用户设置。
@MainActor
final class AppSettingsTests: XCTestCase {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "appsettings-tests-\(UUID().uuidString)"
    }

    override func tearDown() {
        // 不用 removePersistentDomain：它的参数标签在不同 SDK 代际间变过
        // （forSuiteName → forName），直接删 plist 文件最稳。
        removeSuite(suiteName)
        suiteName = nil
        super.tearDown()
    }

    private func removeSuite(_ name: String?) {
        guard let name else { return }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    func testFreshDefaults() {
        let settings = AppSettings(defaults: freshDefaults())
        XCTAssertTrue(settings.scheduledCheckEnabled, "默认开启——这个功能的意义就是后台自动盯着")
        XCTAssertEqual(settings.scheduledCheckHour, 10)
        XCTAssertEqual(settings.scheduledCheckMinute, 0)
        XCTAssertTrue(settings.notificationsEnabled)
        XCTAssertEqual(settings.schedule, CheckSchedule(isEnabled: true, hour: 10, minute: 0))
    }

    func testWritesPersistAcrossInstances() {
        let first = AppSettings(defaults: freshDefaults())
        first.scheduledCheckEnabled = false
        first.scheduledCheckHour = 14
        first.scheduledCheckMinute = 30
        first.notificationsEnabled = false

        // 「重启后仍生效」：新实例（同一个 suite）要读回同样的值。
        let second = AppSettings(defaults: freshDefaults())
        XCTAssertFalse(second.scheduledCheckEnabled)
        XCTAssertEqual(second.scheduledCheckHour, 14)
        XCTAssertEqual(second.scheduledCheckMinute, 30)
        XCTAssertFalse(second.notificationsEnabled)
        XCTAssertEqual(second.scheduleText, "定时检查：已关闭")
    }

    func testOutOfBoundsValuesAreClampedOnRead() {
        // 手改 plist 写出界的时刻不能进调度器。
        let defaults = freshDefaults()
        defaults.set(25, forKey: "check.schedule.hour")
        defaults.set(70, forKey: "check.schedule.minute")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.scheduledCheckHour, 23)
        XCTAssertEqual(settings.scheduledCheckMinute, 59)

        defaults.set(-3, forKey: "check.schedule.hour")
        defaults.set(-1, forKey: "check.schedule.minute")
        XCTAssertEqual(AppSettings(defaults: defaults).scheduledCheckHour, 0)
        XCTAssertEqual(AppSettings(defaults: defaults).scheduledCheckMinute, 0)
    }

    func testScheduleText() {
        let settings = AppSettings(defaults: freshDefaults())
        XCTAssertEqual(settings.scheduleText, "定时检查：每天 10:00")

        settings.scheduledCheckHour = 9
        settings.scheduledCheckMinute = 5
        XCTAssertEqual(settings.scheduleText, "定时检查：每天 09:05")
    }
}
