import XCTest
@testable import UpdraftKit

/// 取消升级的行为。
///
/// 起因是一个真实缺口：批量升级卡住时，界面上既没有取消按钮，Esc 又被
/// `.interactiveDismissDisabled` 挡住，"关闭"也被运行态挡掉，用户被锁在一个不动的进度条前面出不去。
///
/// 修法刻意**不是**"立即中断"——原子换包被打断会留下"旧包已挪走、新包未就位"的中间态，
/// 比多等几秒糟糕得多。语义是"当前这一项做完就停"，所以它必须在模型层被固定下来，
/// 而不是靠界面上的文案自我约束。
final class UpgradeCancellationTests: XCTestCase {
    private func makeApp(_ name: String) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: "com.example.\(name)",
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            currentVersion: "1.0",
            buildVersion: nil,
            source: .sparkle(feedURL: nil)
        )
    }

    private func makeItem(_ name: String, automated: Bool = true) -> UpgradeJob.Item {
        let app = makeApp(name)
        let action: InstallAction = automated ? .replaceBundle : .openDownload
        let plan = automated
            ? Installer().makePlan(app: app, release: ReleaseInfo(version: "2.0"))
            : nil
        return UpgradeJob.Item(
            app: app,
            release: ReleaseInfo(version: "2.0"),
            action: action,
            plan: plan
        )
    }

    private func cancelledOutcome(_ name: String) -> UpgradeJob.Outcome {
        UpgradeJob.Outcome(
            id: name,
            appName: name,
            fromVersion: "1.0",
            toVersion: "2.0",
            succeeded: false,
            summary: "已取消，未执行",
            backupPath: nil,
            rolledBack: false,
            warnings: [],
            log: "",
            cancelled: true
        )
    }

    // MARK: - 收尾补齐（cancelRemaining）

    /// 取消之后，从 `index` 起没做过的条目要如实变成"已跳过"，并为每条补一份结果。
    /// 静默消失比失败更糟：用户在结果页上看不出"哪些没做"。
    func testCancelRemainingSkipsEverythingFromTheIndexOn() {
        var job = UpgradeJob(items: [makeItem("A"), makeItem("B"), makeItem("C")])

        let produced = job.cancelRemaining(from: 1)

        XCTAssertEqual(produced.count, 2)
        XCTAssertTrue(produced.allSatisfy(\.cancelled), "取消必须和失败分开记，否则界面上会穿成橙色警告")
        XCTAssertTrue(produced.allSatisfy { !$0.succeeded })
        XCTAssertEqual(job.items[0].state, .pending, "还没轮到的那一项不该被动")
        XCTAssertEqual(job.items[1].state, .skipped("已取消"))
        XCTAssertEqual(job.items[2].state, .skipped("已取消"))
    }

    /// 已经出结果的条目不能再补一份"已取消"，否则同一个应用会出现两条结果。
    func testCancelRemainingLeavesAlreadyFinishedItemsUntouched() {
        var job = UpgradeJob(items: [makeItem("A"), makeItem("B"), makeItem("C")])
        job.items[1].state = .succeeded

        let produced = job.cancelRemaining(from: 1)

        XCTAssertEqual(produced.count, 1, "已成终态的条目不该再被补结果")
        XCTAssertEqual(produced.first?.appName, "C")
        XCTAssertEqual(job.items[1].state, .succeeded)
    }

    func testCancelRemainingPastTheEndIsHarmless() {
        var job = UpgradeJob(items: [makeItem("A")])

        XCTAssertTrue(job.cancelRemaining(from: 1).isEmpty, "取消落在末尾之后不该多造结果")
        XCTAssertTrue(job.cancelRemaining(from: 99).isEmpty)
        XCTAssertEqual(job.items[0].state, .pending)
    }

    func testCancelRemainingOnEmptyJobIsHarmless() {
        var job = UpgradeJob(items: [])
        XCTAssertTrue(job.cancelRemaining(from: 0).isEmpty)
    }

    /// 补出来的结果要带够版本信息，结果页才渲染得出来。
    func testCancelledOutcomeCarriesEnoughToRender() {
        var job = UpgradeJob(items: [makeItem("A")])
        let outcome = job.cancelRemaining(from: 0).first

        XCTAssertEqual(outcome?.id, job.items[0].id)
        XCTAssertEqual(outcome?.fromVersion, "1.0")
        XCTAssertEqual(outcome?.toVersion, "2.0")
        XCTAssertEqual(outcome?.summary, "已取消，未执行")
        XCTAssertEqual(outcome?.backupPath, nil)
    }

    // MARK: - 计数

    /// 取消不该被算成"失败需要重试"。
    func testCancelledItemsAreNotCountedAsFailures() {
        var job = UpgradeJob(items: [makeItem("A"), makeItem("B")])
        job.outcomes = [
            UpgradeJob.Outcome(
                id: "A", appName: "A", fromVersion: "1.0", toVersion: "2.0",
                succeeded: true, summary: "", backupPath: nil, rolledBack: false,
                warnings: [], log: ""
            ),
            cancelledOutcome("B")
        ]

        XCTAssertEqual(job.succeededCount, 1)
        XCTAssertEqual(job.failedCount, 0, "取消不是失败")
        XCTAssertEqual(job.cancelledCount, 1)
    }

    /// 反过来，真正的失败仍然要算失败——别把两类混成一种。
    func testFailureStillCountsAsFailure() {
        var job = UpgradeJob(items: [makeItem("A")])
        job.outcomes = [
            UpgradeJob.Outcome(
                id: "A", appName: "A", fromVersion: "1.0", toVersion: "2.0",
                succeeded: false, summary: "校验失败", backupPath: nil,
                rolledBack: true, warnings: [], log: ""
            )
        ]

        XCTAssertEqual(job.failedCount, 1)
        XCTAssertEqual(job.cancelledCount, 0)
    }

    func testMixedOutcomesTallyCorrectly() {
        var job = UpgradeJob(items: [makeItem("A"), makeItem("B"), makeItem("C")])
        job.outcomes = [
            UpgradeJob.Outcome(
                id: "A", appName: "A", fromVersion: "1.0", toVersion: "2.0",
                succeeded: true, summary: "", backupPath: nil, rolledBack: false,
                warnings: [], log: ""
            ),
            UpgradeJob.Outcome(
                id: "B", appName: "B", fromVersion: "1.0", toVersion: "2.0",
                succeeded: false, summary: "下载失败", backupPath: nil, rolledBack: false,
                warnings: [], log: ""
            ),
            cancelledOutcome("C")
        ]

        XCTAssertEqual(job.succeededCount, 1)
        XCTAssertEqual(job.failedCount, 1)
        XCTAssertEqual(job.cancelledCount, 1)
    }

    // MARK: - UpdateStore 上的取消入口

    @MainActor
    private func makeStore() -> UpdateStore {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("CancelStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
        // 用临时缓存文件，绝不碰用户真实的 ~/Library/Application Support/Updraft。
        return UpdateStore(engine: CheckEngine(), cache: StateCache(fileURL: file))
    }

    @MainActor
    private func makeRunningJob(_ names: [String]) -> UpgradeJob {
        var job = UpgradeJob(items: names.map { makeItem($0) })
        job.isRunning = true
        return job
    }

    /// 取消是**请求**而不是打断：当前这一项照常做完，之后才停。
    @MainActor
    func testCancelRequestsStopWithoutInterruptingTheRunningItem() {
        let store = makeStore()
        store.job = makeRunningJob(["A", "B"])

        store.cancelJob()

        XCTAssertEqual(store.job?.cancelRequested, true)
        XCTAssertEqual(store.job?.isRunning, true, "原子换包被打断会留下半成品，取消只在条目边界生效")
        XCTAssertEqual(store.job?.isFinished, false)
        XCTAssertEqual(store.job?.currentIndex, 0, "取消不该把进度往后推")
    }

    @MainActor
    func testCancelIsIgnoredWhenNothingIsRunning() {
        let store = makeStore()
        var job = UpgradeJob(items: [makeItem("A")])
        job.isRunning = false
        store.job = job

        store.cancelJob()

        XCTAssertEqual(store.job?.cancelRequested, false, "没在跑就没有可取消的东西")
    }

    @MainActor
    func testCancelIsIgnoredWithoutAJob() {
        let store = makeStore()
        store.cancelJob()
        XCTAssertNil(store.job)
    }

    @MainActor
    func testCancelIsIdempotent() {
        let store = makeStore()
        store.job = makeRunningJob(["A", "B"])

        store.cancelJob()
        store.cancelJob()

        XCTAssertEqual(store.job?.cancelRequested, true)
        XCTAssertEqual(store.job?.isRunning, true)
    }

    /// 用户报的那个缺口：卡住时面板关不掉、也退不出去。
    /// 运行中继续挡掉"关闭"（否则结果丢了），但取消必须随时可达。
    @MainActor
    func testRunningJobCannotBeDismissedButCanBeCancelled() {
        let store = makeStore()
        store.job = makeRunningJob(["A"])

        store.dismissJob()
        XCTAssertNotNil(store.job, "运行中直接关掉面板会把正在进行的结果丢掉")

        store.cancelJob()
        XCTAssertEqual(store.job?.cancelRequested, true, "既然关不掉，就必须给用户一个走得出去的口子")
    }

    @MainActor
    func testFinishedJobCanBeDismissed() {
        let store = makeStore()
        var job = UpgradeJob(items: [makeItem("A")])
        job.isRunning = false
        job.isFinished = true
        store.job = job

        store.dismissJob()

        XCTAssertNil(store.job)
    }

    /// `cancelRemaining` 与 store 的收尾要能接上：把取消之后的账算对。
    @MainActor
    func testCancelRemainingThroughJobProducesCancelledOutcomes() {
        var job = makeRunningJob(["A", "B", "C"])
        job.currentIndex = 1
        job.items[0].state = .succeeded

        let produced = job.cancelRemaining(from: 1)
        job.outcomes.append(contentsOf: produced)

        XCTAssertEqual(job.outcomes.count, 2)
        XCTAssertEqual(job.cancelledCount, 2)
        XCTAssertEqual(job.failedCount, 0)
        XCTAssertEqual(job.items[1].state, .skipped("已取消"))
        XCTAssertEqual(job.items[2].state, .skipped("已取消"))
        XCTAssertEqual(job.items[0].state, .succeeded)
    }
}
