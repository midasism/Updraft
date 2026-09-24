import AppKit
import Foundation

/// 原子换包、回滚与应用生命周期管理。
extension Installer {
    func swapIn(
        newApp: URL,
        at target: URL,
        displacing existing: URL? = nil,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        let stem = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        let token = UUID().uuidString.prefix(8)
        let superseded = existing ?? target

        // 放在同一个目录里，保证和目标是同一个卷 —— 只有同卷 rename 才是原子的。
        let staging = directory.appendingPathComponent(".\(stem).\(token).new.\(ext)", isDirectory: true)
        let displaced = directory.appendingPathComponent(".\(stem).\(token).old.\(ext)", isDirectory: true)

        // 拷贝可能持续很久（1 GB 级的包），期间每 3 秒报一次已用时间。
        // 没有这个心跳，界面上"正在拷贝"与"已经卡死"完全无法区分。
        let destinationDescription = directory.path
        onProgress("正在把新包复制到 \(destinationDescription)…")
        let heartbeat = Task {
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                elapsed += 3
                onProgress("正在把新包复制到 \(destinationDescription)… 已用 \(elapsed) 秒")
            }
        }
        defer { heartbeat.cancel() }

        let copy = await ProcessRunner.run(
            executable: "/usr/bin/ditto",
            arguments: [newApp.path, staging.path],
            timeout: ProcessRunner.largeCopyTimeout
        )
        heartbeat.cancel()

        guard copy.succeeded else {
            // ditto 失败或超时会留下半个 1 GB 的目录。必须当场清掉：它带 `.` 前缀，
            // 在 Finder 里天然不可见，留着就是一块磁盘黑洞（真机上曾留下 1.06 GB）。
            try? fm.removeItem(at: staging)
            throw InstallError.swapFailed(copy.stderr.isEmpty ? copy.stdout : copy.stderr)
        }

        onProgress("新包已就位，正在换名…")

        // 目标可能还不存在（改名场景），那就没有"旧包让位"这一步；存在才挪。
        if fm.fileExists(atPath: superseded.path) {
            do {
                try fm.moveItem(at: superseded, to: displaced)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }

        do {
            try fm.moveItem(at: staging, to: target)
        } catch {
            // 新包就位失败，立刻把旧包搬回去，让用户至少还有能用的 App。
            try? fm.moveItem(at: displaced, to: superseded)
            try? fm.removeItem(at: staging)
            throw error
        }

        return displaced
    }

    static func restore(displaced: URL, to target: URL) {
        let fm = FileManager.default

        // 目标本来就不存在（改名且旧包已被清理），没有旧包可回滚，把坏包清掉即可。
        guard fm.fileExists(atPath: displaced.path) else {
            try? fm.removeItem(at: target)
            return
        }

        let broken = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).broken-\(UUID().uuidString.prefix(8))")

        try? fm.moveItem(at: target, to: broken)
        try? fm.moveItem(at: displaced, to: target)
        try? fm.removeItem(at: broken)
    }

    static func stripQuarantine(_ app: URL) async {
        _ = await ProcessRunner.run(
            executable: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", app.path]
        )
    }

    static func isRunning(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return !runningApplications(bundleID: bundleID).isEmpty
    }

    static func runningApplications(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    func quit(bundleID: String, appName: String, timeout: TimeInterval = 12) async throws {
        let running = Self.runningApplications(bundleID: bundleID)
        guard !running.isEmpty else { return }

        let deadline = Date().addingTimeInterval(timeout)

        // 先礼：走正常的退出流程，应用有机会保存状态或自己询问用户。
        for application in running {
            _ = application.terminate()
        }

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Self.runningApplications(bundleID: bundleID).isEmpty { return }
        }

        throw InstallError.appWontQuit(
            "\(appName) 没有在 \(Int(timeout)) 秒内退出，可能弹出了保存提示。请手动退出后重试。"
        )
    }

    static func relaunchCommand(for app: URL) -> (executable: String, arguments: [String]) {
        ("/usr/bin/open", ["-n", app.path])
    }

    static func launch(_ app: URL) async -> Bool {
        let command = relaunchCommand(for: app)
        let result = await ProcessRunner.run(executable: command.executable, arguments: command.arguments)
        return result.succeeded
    }
}

/// 进度回调限流器。下载进度每秒可能触发上千次，直接转发会把主线程冲垮。
internal final class Throttle: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var last = Date.distantPast

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func shouldEmit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Date().timeIntervalSince(last) > interval else { return false }
        last = Date()
        return true
    }
}

