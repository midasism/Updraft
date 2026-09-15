import XCTest
@testable import AppUpdaterKit

/// Homebrew 索引读取的降级与文案。
///
/// 状态文案与 JSON 解析是纯逻辑，直接断言；真机降级行为走 `brewPath()` 缝注入假命令。
final class BrewServiceTests: XCTestCase {
    // MARK: - 状态文案

    func testOKStatusHasNoNotice() {
        XCTAssertNil(BrewIndexStatus.ok.notice)
    }

    func testBrewNotFoundNotice() {
        XCTAssertEqual(BrewIndexStatus.brewNotFound.notice, "未找到 Homebrew")
    }

    func testListFailedNoticeCarriesFirstStderrLine() {
        let status = BrewIndexStatus.listFailed(stderr: "Error: boom\nsecond line")
        XCTAssertEqual(status.notice, "Homebrew 索引读取失败：Error: boom")
    }

    func testListFailedNoticeWithoutStderr() {
        let status = BrewIndexStatus.listFailed(stderr: "")
        XCTAssertEqual(status.notice, "Homebrew 索引读取失败")
    }

    func testPartialNoticeListsSkippedTokens() {
        let status = BrewIndexStatus.partial(skipped: ["reasonix", "fuse-t-sshfs"], stderr: "")
        XCTAssertEqual(status.notice, "reasonix、fuse-t-sshfs 无法读取，已跳过")
    }

    func testPartialNoticeCollapsesLongList() {
        let status = BrewIndexStatus.partial(skipped: ["a", "b", "c", "d", "e"], stderr: "")
        XCTAssertEqual(status.notice, "a、b、c 等 5 个 无法读取，已跳过")
    }

    // MARK: - JSON 解析

    func testParseCaskInfoExtractsCasks() throws {
        let json = """
        {"casks":[{"token":"mos","installed":["4.2.0"]}],"formulae":[]}
        """
        let casks = try XCTUnwrap(BrewService.parseCaskInfo(json))
        XCTAssertEqual(casks.count, 1)
        XCTAssertEqual(casks[0]["token"] as? String, "mos")
    }

    func testParseCaskInfoRejectsGarbage() {
        XCTAssertNil(BrewService.parseCaskInfo("Error: something broke"))
        XCTAssertNil(BrewService.parseCaskInfo(""))
    }

    // MARK: - 降级（真机集成）

    func testLoadIndexSurvivesBrokenCasks() async throws {
        // 需要 brew 环境才有意义；CI 或没装 Homebrew 的机器上直接跳过。
        guard BrewService.brewPath() != nil else { throw XCTSkip("本机未安装 Homebrew") }

        let outcome = await BrewService.loadIndex()

        // 无论批量查询成败，索引都必须拿到——这正是本次修复的意义。
        let index = try XCTUnwrap(outcome.index, "索引不应再因为个别坏 cask 整体失败")
        XCTAssertFalse(index.installedTokens.isEmpty)

        switch outcome.status {
        case .ok:
            // 环境干净，无需断言。
            break
        case .partial(let skipped, _):
            XCTAssertFalse(skipped.isEmpty)
            // 跳过的 token 确实装过，必须留在 installedTokens 里。
            for token in skipped {
                XCTAssertTrue(index.installedTokens.contains(token), "\(token) 被跳过但应仍在已装列表")
            }
        case .brewNotFound, .listFailed:
            XCTFail("本机 brew 可用，不该报 \(outcome.status)")
        }
    }
}
