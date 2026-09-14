import Darwin
import XCTest
@testable import AppUpdaterKit

/// 只放行第一个调用者的闩。给"谁先回来用谁"的竞速用。
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// 给可能永久挂起的操作套一道硬上限，超时返回 nil。
///
/// 回归测试自己不能变成新的挂起点：如果 `ProcessRunner` 又退回"等一个永远等不到的退出事件"，
/// 直接 `await` 会把整个测试套件卡死，连失败信息都看不到。所以用竞速代替直接等待。
private func race<T: Sendable>(
    hardDeadline seconds: Double,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = OnceFlag()
        Task {
            let value = await operation()
            if once.claim() { continuation.resume(returning: value) }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            if once.claim() { continuation.resume(returning: nil) }
        }
    }
}

/// 子进程执行的回归测试。
///
/// 守的是一个真实发生过的挂起：批量升级卡在"应用替换"十几分钟不动，进程树里却一个子进程都没有。
/// 根因是 `Process.waitUntilExit()` 在"先读到管道 EOF、再去等退出"这个顺序下有竞态——
/// EOF 已经意味着子进程死了，这时才去等它退出，退出事件可能已被 Foundation 内部消费掉。
/// 它是间歇性的：同一个 `ditto` 路径在流程前面几秒就跑完了，偏偏在换包那一步挂住。
///
/// 所以这里既测正常路径，也测"它必须会回来"。
final class ProcessRunnerTests: XCTestCase {
    private let echo = "/bin/echo"
    private let shell = "/bin/sh"

    // MARK: - 正常路径

    func testCapturesStdoutAndZeroExit() async {
        let result = await ProcessRunner.run(executable: echo, arguments: ["hello", "updraft"], timeout: 10)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "hello updraft"
        )
    }

    /// 非零退出必须如实报失败。安装器不能"有输出就算成功"。
    func testNonZeroExitIsReportedAsFailure() async {
        let result = await ProcessRunner.run(executable: "/usr/bin/false", arguments: [], timeout: 10)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.timedOut)
    }

    func testUnlaunchableExecutableIsReportedAsFailure() async {
        let missing = "/usr/bin/definitely-not-here-\(UUID().uuidString)"
        let result = await ProcessRunner.run(executable: missing, arguments: [], timeout: 10)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.contains("无法启动进程"), "启动失败也要有可读的说明，实际：\(result.stderr)")
    }

    /// 输出是慢慢来的：管道 EOF 明显晚于子进程启动。这条覆盖"先等 EOF、再取状态"的时序。
    func testSlowOutputIsFullyCaptured() async {
        let result = await ProcessRunner.run(
            executable: shell,
            arguments: ["-c", "echo first; sleep 0.4; echo second"],
            timeout: 20
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("first"))
        XCTAssertTrue(result.stdout.contains("second"), "EOF 之后的尾巴不能被丢掉")
    }

    // MARK: - 管道排空

    /// stdout 与 stderr 必须被**并发**排空。写满管道缓冲区（macOS 上 64 KB）后子进程会阻塞在
    /// `write` 上，只读一条管道就会死锁——这是这类封装最常见的坑。
    func testLargeOutputOnBothPipesDoesNotDeadlock() async {
        let script = """
        i=0
        while [ $i -lt 8000 ]; do
          echo "stdout line $i"
          echo "stderr line $i" >&2
          i=$((i+1))
        done
        """
        let executable = shell
        let result = await race(hardDeadline: 90) {
            await ProcessRunner.run(executable: executable, arguments: ["-c", script], timeout: 60)
        }

        guard let result else {
            return XCTFail("大输出场景挂住了：两条管道没有被并发排空")
        }
        XCTAssertTrue(result.succeeded)
        XCTAssertGreaterThan(result.stdout.count, 100_000, "stdout 应当完整读回来")
        XCTAssertGreaterThan(result.stderr.count, 100_000, "stderr 应当完整读回来")
    }

    // MARK: - 超时

    /// 超时必须真的把子进程掐掉并如实报超时，而不是一直等下去。
    func testTimeoutTerminatesLongRunningCommand() async {
        let started = Date()
        let result = await race(hardDeadline: 40) {
            await ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 1)
        }

        guard let result else {
            return XCTFail("超时路径没有返回，说明超时监控本身失效了")
        }
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded, "超时不能被当成成功——那会把半个包留在磁盘上")
        XCTAssertTrue(result.stderr.contains("强制终止"), "实际：\(result.stderr)")
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 30,
            "报超时后应当很快返回，不该陪着子进程睡满 30 秒"
        )
    }

    /// 超时之后子进程必须真的没了，不能留下孤儿。
    ///
    /// 用 `exec` 把 shell 自身替换成 `sleep`，这样 PID 文件里记的就是最终那个进程的 PID，
    /// 断言的是"这一个"进程，而不是去 `pgrep` 撞运气匹配系统上别的同名进程。
    func testTimedOutProcessIsActuallyGone() async {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunner-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let script = "echo $$ > \(pidFile.path); exec sleep 30"
        let result = await race(hardDeadline: 40) {
            await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script], timeout: 1)
        }

        guard let result else { return XCTFail("超时路径没有返回") }
        XCTAssertTrue(result.timedOut, "这条用例的前提是它超时")

        let recorded = (try? String(contentsOf: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recorded, let pid = pid_t(recorded) else {
            return XCTFail("没能读到子进程 PID，实际内容：\(String(describing: try? String(contentsOf: pidFile, encoding: .utf8)))")
        }

        // 给它一点点时间让信号走完，然后确认这个 PID 已经不存在。
        var gone = false
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { gone = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(gone, "超时后 PID \(pid) 仍然存在，说明子进程没被真正终止")
    }

    // MARK: - 挂起回归

    /// **核心回归测试。**
    ///
    /// 旧实现在这里会永远不返回，而在真机上这就是"升级卡住不动"。
    /// 连跑多次是刻意的：那个竞态本来就是间歇性的，跑一次很容易蒙混过关。
    func testRepeatedRunsAlwaysReturn() async {
        let rounds = 25
        let started = Date()

        for round in 0..<rounds {
            let result = await race(hardDeadline: 20) {
                await ProcessRunner.run(executable: "/bin/echo", arguments: ["round \(round)"], timeout: 5)
            }
            guard let result else {
                return XCTFail("第 \(round + 1)/\(rounds) 次执行没有返回——子进程等待又挂住了")
            }
            XCTAssertTrue(result.succeeded, "第 \(round + 1) 次失败：\(result.stderr)")
            XCTAssertEqual(
                result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                "round \(round)"
            )
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(started), 60,
            "\(rounds) 次短命令不该花这么久，慢成这样说明每次都在等超时"
        )
    }

    /// 连续执行不同形态的命令：有输出的、没输出的、失败的。
    /// 混着跑更接近真实安装流程（ditto / hdiutil / codesign / xattr 交替）。
    func testMixedCommandSequenceAllReturn() async {
        let commands: [(String, [String], Int32)] = [
            ("/bin/echo", ["a"], 0),
            ("/usr/bin/true", [], 0),
            ("/usr/bin/false", [], 1),
            ("/bin/sh", ["-c", "exit 3"], 3),
            ("/bin/echo", ["b"], 0)
        ]

        for (index, command) in commands.enumerated() {
            let (executable, arguments, expected) = command
            let result = await race(hardDeadline: 20) {
                await ProcessRunner.run(executable: executable, arguments: arguments, timeout: 5)
            }
            guard let result else {
                return XCTFail("第 \(index + 1) 条命令（\(executable)）没有返回")
            }
            XCTAssertEqual(result.exitCode, expected, "\(executable) 的退出码不对")
        }
    }
}
