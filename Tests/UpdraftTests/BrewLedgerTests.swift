import XCTest
@testable import UpdraftKit

/// Homebrew「账本滞后」的判定与展示。
///
/// 背景：brew 判断一个 cask 是否过期，比的是 **Caskroom 账本**（安装时写下的版本目录名）
/// 与 tap 里的最新版本，**而不是磁盘上 `.app` 包的真实版本**。应用被自己的内建更新器
/// 升过之后账本会滞后，于是 brew 报「过期」而实际已是最新。
///
/// 界面原先的左值取自 `Info.plist`（磁盘真实值）、右值取自 tap（最新值），
/// 两者恰好相同时就拼出 `6.17.0 → 6.17.0` 这种自相矛盾的写法——两个数字一模一样
/// 却挂在「可更新」组里，看起来像版本号算错了。
///
/// 这组用例守住三件事：账本被一路带到界面、左值改用账本、账本正常时显示逐字不变。
final class BrewLedgerTests: XCTestCase {
    // MARK: - 测试夹具

    private func makeApp(
        source: AppSource,
        current: String?,
        name: String = "Proxyman"
    ) -> AppInfo {
        AppInfo(
            name: name,
            bundleID: "com.example.\(name)",
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            currentVersion: current,
            buildVersion: nil,
            source: source
        )
    }

    private func makeUpdate(source: AppSource, current: String?, result: UpdateResult) -> AppUpdate {
        AppUpdate(app: makeApp(source: source, current: current), result: result)
    }

    private var brew: AppSource { .homebrewCask(token: "proxyman") }
    private var sparkle: AppSource { .sparkle(feedURL: nil) }

    // MARK: - 解析：账本与最新版本必须一起取

    func testParseOutdatedReadsBothTheLedgerAndTheLatestVersion() throws {
        let json = """
        {"casks":[{"name":"proxyman","installed_versions":["6.12.0,61200"],"current_version":"6.17.0,61700"}],
         "formulae":[]}
        """
        let parsed = try XCTUnwrap(BrewService.parseOutdated(json))

        XCTAssertEqual(parsed["proxyman"]?.installedVersion, "6.12.0", "账本版本要剥掉逗号后的构建号")
        XCTAssertEqual(parsed["proxyman"]?.latestVersion, "6.17.0")
    }

    func testParseOutdatedReadsTheFormulaInstalledShape() throws {
        // formula 的 installed 是 [{"version": "..."}]，与 cask 的 ["..."] 形状不同，两种都要认。
        let json = """
        {"formulae":[{"name":"ngrok","installed":[{"version":"3.0.0"}],"current_version":"3.1.0"}]}
        """
        let parsed = try XCTUnwrap(BrewService.parseOutdated(json))

        XCTAssertEqual(parsed["ngrok"]?.installedVersion, "3.0.0")
        XCTAssertEqual(parsed["ngrok"]?.latestVersion, "3.1.0")
    }

    func testParseOutdatedToleratesAMissingLedgerField() throws {
        let json = """
        {"casks":[{"name":"bare","current_version":"2.0"}]}
        """
        let parsed = try XCTUnwrap(BrewService.parseOutdated(json))

        XCTAssertNil(parsed["bare"]?.installedVersion, "字段缺失时不该编一个版本号出来")
        XCTAssertEqual(parsed["bare"]?.latestVersion, "2.0")
    }

    func testParseOutdatedFallsBackWhenTheLatestVersionIsMissing() throws {
        let json = """
        {"casks":[{"name":"weird","installed_versions":["1.0"]}]}
        """
        let parsed = try XCTUnwrap(BrewService.parseOutdated(json))

        XCTAssertEqual(parsed["weird"]?.latestVersion, "新版本")
        XCTAssertEqual(parsed["weird"]?.installedVersion, "1.0")
    }

    func testParseOutdatedRejectsGarbage() {
        XCTAssertNil(BrewService.parseOutdated("Error: something broke"))
        XCTAssertNil(BrewService.parseOutdated(""))
    }

    // MARK: - 升级起点

    func testUpgradeFromPrefersTheLedger() {
        // 账本才是 brew 真正会拿来比对的"已安装版本"，界面写 `A → B` 要按它来。
        let release = ReleaseInfo(version: "6.17.0", ledgerVersion: "6.12.0")
        XCTAssertEqual(release.upgradeFrom(actualVersion: "6.17.0"), "6.12.0")
    }

    func testUpgradeFromFallsBackToTheDiskVersion() {
        let release = ReleaseInfo(version: "2.0.9")
        XCTAssertEqual(release.upgradeFrom(actualVersion: "1.8.4"), "1.8.4")
    }

    func testUpgradeFromWithoutEitherYieldsPlaceholder() {
        XCTAssertEqual(ReleaseInfo(version: "1.0").upgradeFrom(actualVersion: nil), "?")
    }

    // MARK: - 账本是否滞后

    func testStaleLedgerIsReportedWhenItDisagreesWithTheDisk() {
        let release = ReleaseInfo(version: "6.17.0", ledgerVersion: "6.12.0")
        XCTAssertTrue(release.hasStaleLedger(actualVersion: "6.17.0"))
    }

    func testLedgerMatchingTheDiskIsNotStale() {
        let release = ReleaseInfo(version: "3.6.0", ledgerVersion: "3.5.14")
        XCTAssertFalse(release.hasStaleLedger(actualVersion: "3.5.14"))
    }

    func testTrailingZeroDifferenceIsNotStale() {
        // `1.0` 与 `1.0.0` 是同一个版本，只是写法不同。用字符串相等判会把这种
        // 写法差异误报成「账本滞后」——那是假警报，比不提示更糟。
        let release = ReleaseInfo(version: "1.1.0", ledgerVersion: "1.0")
        XCTAssertFalse(release.hasStaleLedger(actualVersion: "1.0.0"))
    }

    func testMissingLedgerIsNotStale() {
        // 非 Homebrew 来源的 ReleaseInfo 根本没有账本，不该被标成滞后。
        let release = ReleaseInfo(version: "2.0.9")
        XCTAssertFalse(release.hasStaleLedger(actualVersion: "1.8.4"))
    }

    func testMissingActualVersionIsNotStale() {
        // 拿不到磁盘版本就没有比对基础。宁可不说，也不猜一个"滞后"出来。
        let release = ReleaseInfo(version: "6.17.0", ledgerVersion: "6.12.0")
        XCTAssertFalse(release.hasStaleLedger(actualVersion: nil))
    }

    // MARK: - 列表行副标题

    func testDetailTextNamesTheStaleLedger() {
        let update = makeUpdate(
            source: brew,
            current: "6.17.0",
            result: .updateAvailable(ReleaseInfo(version: "6.17.0", ledgerVersion: "6.12.0"))
        )

        XCTAssertEqual(update.detailText, "Homebrew · 6.12.0 → 6.17.0 · brew 记录滞后，实际已装 6.17.0")
        // 修复前这里渲染成 `6.17.0 → 6.17.0`，正是用户报上来的那一幕。
        XCTAssertFalse(update.detailText.contains("6.17.0 → 6.17.0"))
    }

    func testDetailTextKeepsTheSizeAfterTheLedgerNote() {
        let update = makeUpdate(
            source: brew,
            current: "6.17.0",
            result: .updateAvailable(ReleaseInfo(
                version: "6.17.0", size: 41_943_040, ledgerVersion: "6.12.0"
            ))
        )

        XCTAssertTrue(
            update.detailText.hasPrefix("Homebrew · 6.12.0 → 6.17.0 · brew 记录滞后，实际已装 6.17.0 · "),
            "体积信息要排在附注之后：\(update.detailText)"
        )
    }

    func testDetailTextIsUnchangedWhenTheLedgerMatchesTheDisk() {
        // 回归：账本正常的 Homebrew 条目，显示必须与改动前逐字一致。
        let update = makeUpdate(
            source: brew,
            current: "3.5.14",
            result: .updateAvailable(ReleaseInfo(version: "3.6.0", ledgerVersion: "3.5.14"))
        )

        XCTAssertEqual(update.detailText, "Homebrew · 3.5.14 → 3.6.0")
    }

    func testDetailTextForNonBrewSourcesHasNoLedgerNote() {
        // 回归：Sparkle / Electron 两条链路的显示口径不动。
        let update = makeUpdate(
            source: sparkle,
            current: "1.8.4",
            result: .updateAvailable(ReleaseInfo(version: "2.0.9"))
        )

        XCTAssertEqual(update.detailText, "Sparkle · 1.8.4 → 2.0.9")
    }

    // MARK: - 升级条目

    func testJobItemUsesTheLedgerAsItsFromVersion() {
        let item = UpgradeJob.Item(
            app: makeApp(source: brew, current: "6.17.0"),
            release: ReleaseInfo(version: "6.17.0", ledgerVersion: "6.12.0"),
            action: .homebrew(token: "proxyman"),
            plan: nil
        )

        XCTAssertEqual(item.fromVersion, "6.12.0")
        XCTAssertTrue(item.hasStaleLedger)
    }

    func testJobItemWithoutALedgerKeepsTheDiskVersion() {
        let item = UpgradeJob.Item(
            app: makeApp(source: sparkle, current: "1.8.4"),
            release: ReleaseInfo(version: "2.0.9"),
            action: .replaceBundle,
            plan: nil
        )

        XCTAssertEqual(item.fromVersion, "1.8.4")
        XCTAssertFalse(item.hasStaleLedger)
    }

    func testCancelledOutcomeCarriesTheLedgerVersion() {
        // 取消收尾也要走同一口径，否则结果页会突然换回磁盘版本。
        var job = UpgradeJob(items: [
            UpgradeJob.Item(
                app: makeApp(source: brew, current: "6.17.0"),
                release: ReleaseInfo(version: "6.17.0", ledgerVersion: "6.12.0"),
                action: .homebrew(token: "proxyman"),
                plan: nil
            )
        ])

        let outcomes = job.cancelRemaining(from: 0)

        XCTAssertEqual(outcomes.first?.fromVersion, "6.12.0")
    }

    // MARK: - 引擎接线

    func testEngineCarriesTheLedgerIntoTheRelease() async throws {
        let engine = CheckEngine(
            sparkleProbe: SilentProbe(),
            electronProbe: SilentProbe(),
            masProbe: SilentProbe(),
            brewOutdated: { _ in
                ["proxyman": BrewOutdatedCask(installedVersion: "6.12.0", latestVersion: "6.17.0")]
            }
        )

        let results = await engine.check(apps: [makeApp(source: brew, current: "6.17.0")])

        let release = try XCTUnwrap(results.first?.result.release)
        XCTAssertEqual(release.version, "6.17.0")
        XCTAssertEqual(release.ledgerVersion, "6.12.0", "账本必须一路带到界面，否则左值只能退回磁盘版本")
        XCTAssertEqual(results.first?.detailText, "Homebrew · 6.12.0 → 6.17.0 · brew 记录滞后，实际已装 6.17.0")
    }

    func testEngineWithoutBrewLedgerStillReportsAnUpdate() async throws {
        // 账本字段缺失（老版本 brew、或被跳过的 cask）时不能丢条目，只是退回归属磁盘版本的写法。
        let engine = CheckEngine(
            sparkleProbe: SilentProbe(),
            electronProbe: SilentProbe(),
            masProbe: SilentProbe(),
            brewOutdated: { _ in
                ["proxyman": BrewOutdatedCask(installedVersion: nil, latestVersion: "6.17.0")]
            }
        )

        let results = await engine.check(apps: [makeApp(source: brew, current: "6.12.0")])

        XCTAssertEqual(results.first?.detailText, "Homebrew · 6.12.0 → 6.17.0")
    }
}

/// 不记账、不发请求的假探针：这组用例只关心 brew 那条支路。
private struct SilentProbe: UpdateProbing {
    func probe(_ app: AppInfo) async -> UpdateResult { .upToDate(latest: "9.9") }
}
