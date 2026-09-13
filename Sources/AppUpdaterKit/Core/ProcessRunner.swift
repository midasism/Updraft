import Foundation

/// 子进程执行封装。
///
/// 两个容易踩的坑在这里处理掉了：
/// 1. stdout / stderr 必须并发读取，否则管道缓冲区写满后 `waitUntilExit` 会死锁。
/// 2. 累计缓冲区用一个带锁的盒子，避免跨线程改同一个 `var`。
public enum ProcessRunner {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public var succeeded: Bool { exitCode == 0 }
    }

    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
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
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                outBox.set((try? outPipe.fileHandleForReading.readToEnd()) ?? Data())
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errBox.set((try? errPipe.fileHandleForReading.readToEnd()) ?? Data())
                group.leave()
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: Result(
                    exitCode: -1,
                    stdout: "",
                    stderr: "无法启动进程：\(error.localizedDescription)"
                ))
                return
            }

            group.notify(queue: .global()) {
                process.waitUntilExit()
                continuation.resume(returning: Result(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: outBox.value, as: UTF8.self),
                    stderr: String(decoding: errBox.value, as: UTF8.self)
                ))
            }
        }
    }

    /// 流式执行，用于 `brew upgrade` 这类需要实时看日志的场景。stderr 也合并进同一条流。
    public static func stream(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> AsyncStream<String> {
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
                continuation.yield(String(decoding: data, as: UTF8.self))
            }

            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                // 收尾：把管道里剩下的读完，再补一行退出状态。
                let tail = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                if !tail.isEmpty {
                    continuation.yield(String(decoding: tail, as: UTF8.self))
                }
                continuation.yield(finished.terminationStatus == 0
                    ? "\n✔ 完成\n"
                    : "\n✘ 进程退出码 \(finished.terminationStatus)\n")
                continuation.finish()
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.yield("无法启动进程：\(error.localizedDescription)\n")
                continuation.finish()
            }
        }
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
