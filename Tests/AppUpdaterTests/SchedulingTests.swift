import XCTest
@testable import AppUpdaterKit

/// 定时检查的判定逻辑：全部用注入的日历与合成时刻，不依赖真实时间、不真等。
final class SchedulingTests: XCTestCase {
    /// 固定时区日历：夏令时跳变不会让合成日期在不同机器上漂移。
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }

    private var planner: CheckPlanner { CheckPlanner(calendar: calendar) }

    /// 默认计划：每天 10:00。
    private let schedule = CheckSchedule(isEnabled: true, hour: 10, minute: 0)

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - 到点判定

    func testNotDueBeforeScheduledTimeWhenYesterdayWasChecked() {
        let lastChecked = date(2026, 9, 14, 10, 5)
        let now = date(2026, 9, 15, 9, 59)
        XCTAssertFalse(planner.isDue(schedule: schedule, lastSatisfied: lastChecked, lastTriggered: nil, now: now))
    }

    func testNotDueBeforeTodayScheduleWhenYesterdayWasCheckedEarly() {
        let lastChecked = date(2026, 9, 14, 8, 0)
        let now = date(2026, 9, 15, 8, 0)
        XCTAssertFalse(
            planner.isDue(schedule: schedule, lastSatisfied: lastChecked, lastTriggered: nil, now: now),
            "昨天已经手动检查过，今天计划时刻前不应把昨天的 occurrence 当成漏查"
        )
    }

    func testDueBeforeTodayScheduleWhenPreviousDayWasMissed() {
        // 周一整天睡过去，周二 08:00（今天 10:00 尚未到）醒来，也要补周一 10:00 那次。
        let lastChecked = date(2026, 9, 13, 20, 0)
        let now = date(2026, 9, 15, 8, 0)
        XCTAssertTrue(planner.isDue(schedule: schedule, lastSatisfied: lastChecked, lastTriggered: nil, now: now))
    }

    func testDueExactlyAtScheduledTime() {
        let now = date(2026, 9, 15, 10, 0)
        XCTAssertTrue(planner.isDue(schedule: schedule, lastSatisfied: nil, lastTriggered: nil, now: now))
    }

    func testDueAfterScheduledTimeWhenNeverChecked() {
        // 错过时段（合盖/关机睡过去了）也走这条：时刻已过 + 今天没查 = 该补查。
        let now = date(2026, 9, 15, 20, 30)
        XCTAssertTrue(planner.isDue(schedule: schedule, lastSatisfied: nil, lastTriggered: nil, now: now))
    }

    func testNotDueWhenAlreadyCheckedToday() {
        // 早上手动查过（或启动查过），到点不再重复——「当天已查过不重查」。
        let lastChecked = date(2026, 9, 15, 8, 0)
        let now = date(2026, 9, 15, 10, 0)
        XCTAssertFalse(planner.isDue(schedule: schedule, lastSatisfied: lastChecked, lastTriggered: nil, now: now))
    }

    func testNotDueWhenCheckedLaterTodayAfterMissedSlot() {
        // 补查已经跑过一次（比如唤醒后 10:05 查的），同一晚些时候的轮询不能再触发。
        let lastChecked = date(2026, 9, 15, 10, 5)
        let now = date(2026, 9, 15, 22, 0)
        XCTAssertFalse(planner.isDue(schedule: schedule, lastSatisfied: lastChecked, lastTriggered: nil, now: now))
    }

    func testDueWhenLastCheckedYesterday() {
        let lastChecked = date(2026, 9, 14, 23, 0)
        let now = date(2026, 9, 15, 10, 0)
        XCTAssertTrue(planner.isDue(schedule: schedule, lastSatisfied: lastChecked, lastTriggered: nil, now: now))
    }

    func testNotDueWhenDisabled() {
        let off = CheckSchedule(isEnabled: false, hour: 10, minute: 0)
        let now = date(2026, 9, 15, 12, 0)
        XCTAssertFalse(planner.isDue(schedule: off, lastSatisfied: nil, lastTriggered: nil, now: now))
    }

    func testNotDueWhenAlreadyTriggeredToday() {
        // 兜「检查在跑、lastChecked 还没落定」的窗口：调度器自己触发过就不再触发。
        let lastTriggered = date(2026, 9, 15, 10, 0)
        let now = date(2026, 9, 15, 10, 1)
        XCTAssertFalse(planner.isDue(schedule: schedule, lastSatisfied: nil, lastTriggered: lastTriggered, now: now))
    }

    func testMidnightBoundaryIsNotSameDay() {
        let lateNight = date(2026, 9, 15, 23, 59)
        let earlyMorning = date(2026, 9, 16, 0, 1)
        XCTAssertFalse(planner.isSameDay(lateNight, as: earlyMorning))
        XCTAssertTrue(planner.isDue(schedule: schedule, lastSatisfied: lateNight, lastTriggered: nil, now: earlyMorning.addingTimeInterval(10 * 3600)))
    }

    func testCheckStartingBeforeMidnightDoesNotSuppressNextDayOccurrence() {
        let started = date(2026, 9, 15, 23, 59)
        let nextOccurrence = date(2026, 9, 16, 23, 59)
        XCTAssertTrue(
            planner.isDue(schedule: schedule, lastSatisfied: started, lastTriggered: nil, now: nextOccurrence),
            "每日去重必须按检查开始归属日，不能被跨午夜后的完成时间压掉"
        )
    }

    // MARK: - 下一次时刻

    func testNextOccurrenceIsTodayWhenStillAhead() {
        let now = date(2026, 9, 15, 8, 0)
        XCTAssertEqual(planner.nextOccurrence(after: now, schedule: schedule), date(2026, 9, 15, 10, 0))
    }

    func testNextOccurrenceIsTomorrowWhenAlreadyPassed() {
        let now = date(2026, 9, 15, 11, 0)
        XCTAssertEqual(planner.nextOccurrence(after: now, schedule: schedule), date(2026, 9, 16, 10, 0))
    }

    // MARK: - 运行时轮询（注入时钟，fire 只记账不发请求）

    private final class FireLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(Date)] = []

        func record(_ date: Date) {
            lock.lock()
            storage.append(date)
            lock.unlock()
        }

        var dates: [Date] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        var count: Int { dates.count }
    }

    @MainActor
    private func makeWatcher(
        lastSatisfied: Date?,
        planner: CheckPlanner,
        settings: AppSettings,
        fired: FireLog
    ) -> UpdateWatcher {
        let cache = StateCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-\(UUID().uuidString).json"))
        if let lastSatisfied {
            cache.save(.init(
                updates: [],
                savedAt: lastSatisfied,
                lastFullCheckAt: lastSatisfied,
                lastFullCheckStartedAt: lastSatisfied
            ))
        }
        // fire 被替换成记账闭包，store 的引擎永远不会被调用——这里只测「什么时候触发」。
        let store = UpdateStore(engine: CheckEngine(), cache: cache)
        XCTAssertEqual(store.lastChecked.map { calendar.startOfDay(for: $0) },
                       lastSatisfied.map { calendar.startOfDay(for: $0) },
                       "前置条件：缓存里的 lastFullCheckAt 要能变成 store.lastChecked")
        return UpdateWatcher(store: store, settings: settings, planner: planner, fire: {
            fired.record(Date.distantPast) // 记账用的固定值，断言次数而不是时刻
        })
    }

    @MainActor
    private func makeSettings(enabled: Bool, hour: Int = 10, minute: Int = 0) -> AppSettings {
        let name = "scheduling-tests-\(UUID().uuidString)"
        settingsSuites.append(name)
        let settings = AppSettings(defaults: UserDefaults(suiteName: name))
        settings.scheduledCheckEnabled = enabled
        settings.scheduledCheckHour = hour
        settings.scheduledCheckMinute = minute
        settings.notificationsEnabled = false
        return settings
    }

    private var settingsSuites: [String] = []

    override func tearDown() {
        // 与 AppSettingsTests 同一理由：直接删 plist，绕开 removePersistentDomain 的标签差异。
        for name in settingsSuites {
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(name).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        settingsSuites = []
        super.tearDown()
    }

    /// tick 触发的 fire 走 `Task {}` 异步派发；让主执行者空转两拍，把排队的 fire 跑完再断言。
    /// 测试与 fire 闭包都在主执行者上，FIFO，两拍足够确定性。
    private func drainMainActor() async {
        await Task.yield()
        await Task.yield()
    }

    @MainActor
    func testTickBeforeTimeDoesNotFireWhenYesterdayWasChecked() async {
        let fired = FireLog()
        let watcher = makeWatcher(
            lastSatisfied: date(2026, 9, 14, 10, 5),
            planner: planner,
            settings: makeSettings(enabled: true),
            fired: fired
        )
        watcher.tick(now: date(2026, 9, 15, 9, 0))
        watcher.tick(now: date(2026, 9, 15, 9, 59))
        await drainMainActor()
        XCTAssertEqual(fired.count, 0)
    }

    @MainActor
    func testTickFiresOncePerDay() async {
        let fired = FireLog()
        let watcher = makeWatcher(lastSatisfied: nil, planner: planner, settings: makeSettings(enabled: true), fired: fired)
        // 到点触发一次；之后一整天反复轮询（模拟 30 秒一拍）都不能再触发。
        watcher.tick(now: date(2026, 9, 15, 10, 0))
        await drainMainActor()
        for minute in 1...60 {
            watcher.tick(now: date(2026, 9, 15, 10, minute))
        }
        watcher.tick(now: date(2026, 9, 15, 23, 59))
        await drainMainActor()
        XCTAssertEqual(fired.count, 1, "同一天内不得重复触发")
    }

    @MainActor
    func testTickFiresAgainNextDay() async {
        let fired = FireLog()
        let watcher = makeWatcher(lastSatisfied: nil, planner: planner, settings: makeSettings(enabled: true), fired: fired)
        watcher.tick(now: date(2026, 9, 15, 10, 0))
        await drainMainActor()
        watcher.tick(now: date(2026, 9, 16, 9, 59))
        await drainMainActor()
        XCTAssertEqual(fired.count, 1)
        watcher.tick(now: date(2026, 9, 16, 10, 0))
        await drainMainActor()
        XCTAssertEqual(fired.count, 2, "第二天到点要重新触发")
    }

    @MainActor
    func testTickSkipsWhenAlreadyCheckedToday() async {
        let fired = FireLog()
        // 缓存里今天 8 点查过——到点不该再查。
        let watcher = makeWatcher(lastSatisfied: date(2026, 9, 15, 8, 0), planner: planner, settings: makeSettings(enabled: true), fired: fired)
        watcher.tick(now: date(2026, 9, 15, 10, 0))
        await drainMainActor()
        XCTAssertEqual(fired.count, 0)
    }

    @MainActor
    func testTickCatchesPreviousDayBeforeTodaySchedule() async {
        let fired = FireLog()
        let watcher = makeWatcher(
            lastSatisfied: date(2026, 9, 13, 20, 0),
            planner: planner,
            settings: makeSettings(enabled: true),
            fired: fired
        )
        watcher.tick(now: date(2026, 9, 15, 8, 0))
        await drainMainActor()
        XCTAssertEqual(fired.count, 1, "跨日睡眠错过的 occurrence 要在唤醒第一拍补查")
    }

    @MainActor
    func testTickCatchUpAfterMissedSlot() async {
        let fired = FireLog()
        // 昨天查过；今天 10 点在睡眠中错过，20 点唤醒——第一次轮询就该补查。
        let watcher = makeWatcher(lastSatisfied: date(2026, 9, 14, 23, 0), planner: planner, settings: makeSettings(enabled: true), fired: fired)
        watcher.tick(now: date(2026, 9, 15, 20, 0))
        await drainMainActor()
        XCTAssertEqual(fired.count, 1)
    }

    @MainActor
    func testTickDefersDuringInstallationThenRetries() async {
        let fired = FireLog()
        let cache = StateCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-install-\(UUID().uuidString).json"))
        let store = UpdateStore(engine: CheckEngine(), cache: cache)
        let settings = makeSettings(enabled: true)
        let watcher = UpdateWatcher(store: store, settings: settings, planner: planner, fire: {
            fired.record(Date.distantPast)
        })

        let app = AppInfo(
            name: "Test App",
            bundleID: "com.example.test",
            path: URL(fileURLWithPath: "/Applications/Test App.app"),
            currentVersion: "1.0",
            buildVersion: nil,
            source: .unsupported(reason: "test")
        )
        var job = UpgradeJob(items: [
            .init(app: app, release: ReleaseInfo(version: "2.0"), action: .replaceBundle, plan: nil)
        ])
        job.isRunning = true
        store.job = job

        watcher.tick(now: date(2026, 9, 15, 10, 0))
        await drainMainActor()
        XCTAssertEqual(fired.count, 0, "安装期间不能扫描换包中间态")

        job.isRunning = false
        store.job = job
        watcher.tick(now: date(2026, 9, 15, 10, 1))
        await drainMainActor()
        XCTAssertEqual(fired.count, 1, "被安装挡住的触发不能算已完成，结束后要重试")
    }

    @MainActor
    func testTickDoesNotFireWhenDisabled() async {
        let fired = FireLog()
        let watcher = makeWatcher(lastSatisfied: nil, planner: planner, settings: makeSettings(enabled: false), fired: fired)
        watcher.tick(now: date(2026, 9, 15, 12, 0))
        await drainMainActor()
        XCTAssertEqual(fired.count, 0)
    }

    // MARK: - 通知判定

    func testNotificationPolicy() {
        XCTAssertTrue(NotificationPolicy.shouldNotify(updateCount: 3, notificationsEnabled: true, mainWindowVisible: false))
        XCTAssertFalse(NotificationPolicy.shouldNotify(updateCount: 0, notificationsEnabled: true, mainWindowVisible: false), "无更新不发通知")
        XCTAssertFalse(NotificationPolicy.shouldNotify(updateCount: 3, notificationsEnabled: false, mainWindowVisible: false), "开关关了不打扰")
        XCTAssertFalse(NotificationPolicy.shouldNotify(updateCount: 3, notificationsEnabled: true, mainWindowVisible: true), "用户正看着结果，再弹是打扰")
    }
}
