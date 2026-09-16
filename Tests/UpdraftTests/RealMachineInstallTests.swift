import XCTest
@testable import UpdraftKit

/// 真机端到端：拿本机真实的 GB 级应用包跑真实的 `ditto`。
///
/// 默认跳过，只有显式打开才跑：
///
/// ```
/// UPDRAFT_REAL_MACHINE=1 swift test --disable-sandbox --filter RealMachineInstallTests
/// ```
///
/// 之所以要留着它：单元测试里那些几十 KB 的假包证明不了"1 GB 级拷贝不会挂在子进程等待里"，
/// 而这次踩到的正是这个坑——同一条 `ditto` 路径在流程前面几秒就跑完了，偏偏在换包那一步永久挂住。
/// 但它要搬几个 GB，不该拖慢日常回归，所以默认关掉、需要时重跑。
final class RealMachineInstallTests: XCTestCase {
    private static let enabled = ProcessInfo.processInfo.environment["UPDRAFT_REAL_MACHINE"] == "1"

    /// 挑本机真实存在的大包，从大到小试。找不到就跳过，不硬编码某个必须存在的应用。
    private static let candidates = [
        "/Applications/Microsoft Edge.app",
        "/Applications/Cherry Studio.app",
        "/Applications/IINA.app"
    ]

    private var root: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.enabled, "设置 UPDRAFT_REAL_MACHINE=1 才跑真机用例")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealMachine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// 数一遍目录里的条目（不跟随符号链接，所以 Electron 包的 `Versions/Current` 不会成环）。
    private func entryCount(at url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return 0
        }
        var count = 0
        for case let _ as URL in enumerator { count += 1 }
        return count
    }

    /// 反复做真实的大包备份拷贝，每一次都必须在合理时间内返回，且内容完整。
    ///
    /// 这里走的是和升级流程里一模一样的调用链：`BackupStore` → `ProcessRunner.run` → `/usr/bin/ditto`。
    func testLargeDittoCopyReturnsPromptlyEveryTime() async throws {
        let source = Self.candidates
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }

        guard let source else {
            throw XCTSkip("本机没有可用于真机验证的大体积应用包")
        }

        let name = source.deletingPathExtension().lastPathComponent
        let expectedEntries = entryCount(at: source)
        XCTAssertGreaterThan(expectedEntries, 0, "\(source.path) 里一个文件都没有，没法用来验证拷贝")

        let backupsRoot = root.appendingPathComponent("Backups")
        let store = BackupStore(root: backupsRoot)
        let rounds = 3

        for round in 0..<rounds {
            let started = Date()
            let copied = try await store.backup(
                appAt: source,
                name: name,
                version: "e2e-\(round)",
                bundleID: "real.machine.\(name)"
            )
            let elapsed = Date().timeIntervalSince(started)

            XCTAssertTrue(
                FileManager.default.fileExists(atPath: copied.path),
                "第 \(round + 1) 次拷贝没产出结果"
            )
            XCTAssertEqual(
                entryCount(at: copied), expectedEntries,
                "第 \(round + 1) 次拷贝的条目数与源不一致，拷贝不完整"
            )
            XCTAssertLessThan(
                elapsed, 300,
                "第 \(round + 1) 次拷贝 \(name) 花了 \(Int(elapsed)) 秒——像是又挂在等子进程退出了"
            )

            // 每轮收工清掉，别把临时目录撑爆。
            try? FileManager.default.removeItem(at: backupsRoot)
        }
    }
}
