import Foundation
import OSLog

/// 子进程执行封装。
///
/// 四个容易踩的坑在这里处理掉了：
/// 1. stdout / stderr 必须并发读取，否则管道缓冲区写满后子进程会阻塞在 `write` 上。
/// 2. 累计缓冲区用一个带锁的盒子，避免跨线程改同一个 `var`。
/// 3. **绝不调用 `Process.waitUntilExit()`**（原因见下）。
/// 4. 每个子进程都有超时：超时先 SIGTERM、再 SIGKILL，然后如实报失败。
///
/// ## 为什么不能用 `Process.waitUntilExit()`
///
/// 它在 macOS 上会**永久挂起**，而且是在子进程已经正常退出的情况下挂。
/// 2026-09-14 在本机（macOS 26.6.2 / arm64）抓到过活体栈：
///
/// ```
/// closure #3 in closure #1 in static ProcessRunner.run(...)   ← 我们自己的代码
///   -[NSConcreteTask waitUntilExit]  (Foundation)
///     _CFRunLoopRunSpecificWithOptions → __CFRunLoopRun → __CFRunLoopServiceMachPort → mach_msg2_trap
/// ```
///
/// 它不是自旋，而是挂在 run loop 里等一个再也等不到的退出事件；同一时刻
/// `pgrep -P <pid>` 一个子进程都没有。根因是**调用顺序本身有竞态**：先等管道读到 EOF
/// （而 EOF 已经意味着子进程死了），这时才去等它退出，退出事件可能已被 Foundation
/// 内部的监视机制消费掉，于是永远等不到。
///
/// 真机表现：升级卡在某一阶段不动、进程树里没有子进程、日志最后一行毫无异常；
/// 又因为当时没有任何超时，一次挂起就把整批任务永久定住。
///
/// 所以这里用三条互相独立的路径拿状态，任何一条先到都算数：
/// - `terminationHandler`：**必须在 `run()` 之前**设好，作为主路径；
/// - 自持 `waitpid(WNOHANG)`：管道 EOF 之后自己收尸兜底，拿到就用我们自己的状态，
///   `ECHILD` 表示已被 Foundation 回收，转回主路径，**绝不循环重试**；
/// - 整体超时 + 强杀：任何情况下都有出口。
///
/// 三条路都没拿到状态时按失败处理（fail closed）——安装器不能把"不知道"当成功。
public enum ProcessRunner {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        /// 是否因为超时被强制结束。此时 `exitCode` 没有意义。
        public let timedOut: Bool

        public var succeeded: Bool { exitCode == 0 && !timedOut }

        public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
        }
    }

    /// 默认超时。`codesign` / `xattr` / `hdiutil` 都在秒级完成，2 分钟足够。
    public static let defaultTimeout: TimeInterval = 120
    /// 拷贝整个 `.app` 包用的超时。APFS 上走 clonefile 通常一两秒，
    /// 但换到别的卷、或被系统逐文件扫描时会慢得多，所以给足以分钟计的上限。
    public static let largeCopyTimeout: TimeInterval = 600

    /// 发出终止信号后留给子进程收尾的时间，超过就 SIGKILL。
    private static let terminationGrace: TimeInterval = 3
    /// 管道已关闭却还没拿到退出码时，再等一会儿主路径回调，之后按失败处理。
    private static let statusGrace: TimeInterval = 5
    /// 轮询间隔。
    private static let pollInterval: useconds_t = 20_000

    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = ProcessRunner.defaultTimeout
    ) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let outBox = DataBox()
            let errBox = DataBox()
            let readers = DispatchGroup()

            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                outBox.set((try? outPipe.fileHandleForReading.readToEnd()) ?? Data())
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errBox.set((try? errPipe.fileHandleForReading.readToEnd()) ?? Data())
                readers.leave()
            }

            let reported = ReportedStatus()
            process.terminationHandler = { finished in
                reported.record(finished.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                // 启动失败时父进程侧的管道写端还开着，读线程会一直阻塞在 `readToEnd()` 上。
                // 关掉写端让它们读到 EOF 收工，免得每失败一次就漏两个线程。
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                Log.process.error("进程启动失败: \(executable) \(arguments.joined(separator: " ")) — \(error.localizedDescription)")
                continuation.resume(returning: Result(
                    exitCode: -1,
                    stdout: "",
                    stderr: "无法启动进程：\(error.localizedDescription)"
                ))
                return
            }

            // 唯一的等待者，也是唯一的 resume 出口。
            supervise(
                pid: process.processIdentifier,
                readers: readers,
                reported: reported,
                timeout: timeout
            ) { outcome in
                let captured = String(decoding: errBox.value, as: UTF8.self)
                let stderr = outcome.notice.map { captured.isEmpty ? $0 : captured + "\n" + $0 } ?? captured
                continuation.resume(returning: Result(
                    exitCode: outcome.exitCode,
                    stdout: String(decoding: outBox.value, as: UTF8.self),
                    stderr: stderr,
                    timedOut: outcome.timedOut
                ))
            }
        }
    }

    /// 流式执行，用于 `brew upgrade` 这类需要实时看日志的场景。stderr 也合并进同一条流。
    ///
    /// 注意它同样**没有**用 `waitUntilExit()`：退出状态由 `terminationHandler` 给出。
    public static func stream(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                continuation.yield(.output(String(decoding: data, as: UTF8.self)))
            }

            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                // 收尾：把管道里剩下的读完。
                let tail = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                if !tail.isEmpty {
                    continuation.yield(.output(String(decoding: tail, as: UTF8.self)))
                }
                continuation.yield(.finished(exitCode: finished.terminationStatus))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.yield(.output("无法启动进程：\(error.localizedDescription)\n"))
                continuation.yield(.finished(exitCode: -1))
                continuation.finish()
            }
        }
    }
}

// MARK: - 等待

private extension ProcessRunner {
    struct Outcome {
        var exitCode: Int32
        var timedOut: Bool = false
        /// 需要补进 stderr 的说明（超时、状态未知）。
        var notice: String?
    }

    /// 唯一的等待者。刻意写成轮询而不是 `DispatchGroup.wait` + `waitUntilExit`：
    /// 只有这样才能同时盯着超时，也只有这样才能在"状态拿不到"时兜底退出。
    static func supervise(
        pid: pid_t,
        readers: DispatchGroup,
        reported: ReportedStatus,
        timeout: TimeInterval,
        completion: @escaping (Outcome) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)

            // ── 第一步：等两条管道读到 EOF。写端全部关闭意味着子进程已经结束。
            while readers.wait(timeout: .now()) != .success {
                if Date() >= deadline {
                    completion(terminate(pid: pid, reported: reported, timeout: timeout))
                    return
                }
                usleep(pollInterval)
            }

            // ── 第二步：管道已关闭，这时才去取退出状态。
            let statusDeadline = Date().addingTimeInterval(statusGrace)
            while Date() < statusDeadline {
                if let status = reported.status {
                    completion(Outcome(exitCode: status))
                    return
                }
                if let status = reapIfExited(pid: pid) {
                    completion(Outcome(exitCode: status))
                    return
                }
                usleep(pollInterval)
            }

            if let status = reported.status {
                completion(Outcome(exitCode: status))
                return
            }

            // 三条路都没拿到：管道已关说明进程确实结束了，但退出码没了。
            // 安装器不能把"不知道"当成功，所以按失败处理。
            Log.process.fault("进程 \(pid) 退出状态未知（管道已关闭，但三条路径均未获取到退出码）")
            completion(Outcome(
                exitCode: -1,
                notice: "无法确认子进程的退出状态（管道已关闭，但未收到退出码）"
            ))
        }
    }

    /// 自己收尸。返回退出码；进程还在跑或已被 Foundation 回收时返回 nil。
    ///
    /// `ECHILD` 说明 Foundation 的监视机制已经把它收走了，此时直接返回 nil
    /// 交给主路径 —— **绝不能在 `ECHILD` 上循环重试 `waitpid`**，那会变成死循环。
    static func reapIfExited(pid: pid_t) -> Int32? {
        var raw: Int32 = 0
        let reaped = waitpid(pid, &raw, WNOHANG)
        if reaped == pid { return exitCode(fromWaitStatus: raw) }
        return nil
    }

    /// 先礼后兵：SIGTERM → 宽限期 → SIGKILL。全程用 `kill` 而不是 `Process.terminate()`，
    /// 免得又绕回 Foundation 的等待机制。
    ///
    /// 宽限期里不是单纯判存活，而是"顺手收尸"：子进程收到 SIGTERM 后会变成僵尸，
    /// 僵尸对 `kill(pid, 0)` 仍然有响应，只判存活的话每次都要白等满 3 秒。
    /// 因此这里同时盯着两条路，任意一条拿到状态就立刻进入结果构造。
    static func terminate(pid: pid_t, reported: ReportedStatus, timeout: TimeInterval) -> Outcome {
        Log.process.warning("进程 \(pid) 超过 \(Int(timeout))s 未退出，发送 SIGTERM")
        kill(pid, SIGTERM)
        var exitCode = waitForStatus(pid: pid, reported: reported, deadline: Date().addingTimeInterval(terminationGrace))

        if exitCode == nil {
            // 宽限期内没走，说明它不理会 SIGTERM。
            Log.process.warning("进程 \(pid) 不响应 SIGTERM，发送 SIGKILL")
            kill(pid, SIGKILL)
            exitCode = waitForStatus(pid: pid, reported: reported, deadline: Date().addingTimeInterval(1))
        }

        return Outcome(
            exitCode: exitCode ?? -1,
            timedOut: true,
            notice: "命令超过 \(Int(timeout)) 秒仍未结束，已强制终止"
        )
    }

    /// 在 `deadline` 之前反复尝试拿退出状态：主路径（`terminationHandler`）优先，
    /// 拿不到就自己 `waitpid` 收尸。返回 nil 表示期限内始终没有结论。
    private static func waitForStatus(pid: pid_t, reported: ReportedStatus, deadline: Date) -> Int32? {
        while Date() < deadline {
            if let status = reported.status { return status }
            if let status = reapIfExited(pid: pid) { return status }
            usleep(50_000)
        }
        return reported.status ?? reapIfExited(pid: pid)
    }

    /// 把 `waitpid` 的原始状态字拆成命令行约定：正常退出取退出码，被信号打断取 128+信号。
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        if status & 0x7F == 0 { return (status >> 8) & 0xFF }
        return 128 + (status & 0x7F)
    }
}

// MARK: - 跨线程盒子

/// 主路径（`terminationHandler`）回报的退出码，只认第一个。
private final class ReportedStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int32?

    func record(_ status: Int32) {
        lock.lock()
        if storage == nil { storage = status }
        lock.unlock()
    }

    var status: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 跨线程写读的字节缓冲。
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
