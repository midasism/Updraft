import Foundation

/// 旧版本备份仓库。
///
/// 布局：`Backups/<Bundle ID>/<时间戳>-<版本>/<应用名>.app`
///
/// 时间戳用 `yyyyMMdd-HHmmss`，字典序即时间序，清理时不必解析日期。
/// 每个应用只保留最近 `keep` 份（默认 1 份）——IINA 一个包就 104 MB，
/// 无限留存很快就会变成磁盘黑洞。
public struct BackupStore: Sendable {
    /// 默认保留的备份份数。
    public static let defaultKeepCount = 1

    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            self.root = base
                .appendingPathComponent("AppUpdater", isDirectory: true)
                .appendingPathComponent("Backups", isDirectory: true)
        }
    }

    /// 目录名用的 Bundle ID。Bundle ID 里可能有 `/`（极少见），做一次清洗。
    static func sanitized(_ identifier: String) -> String {
        let cleaned = identifier.replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// 备份一个 `.app`，返回备份后的路径。
    @discardableResult
    public func backup(
        appAt url: URL,
        name: String,
        version: String?,
        bundleID: String,
        date: Date = Date()
    ) async throws -> URL {
        let fm = FileManager.default
        let folderName = "\(Self.timestamp(date))-\(sanitizedVersion(version))"
        let container = root
            .appendingPathComponent(Self.sanitized(bundleID), isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)

        try fm.createDirectory(at: container, withIntermediateDirectories: true)

        let destination = container.appendingPathComponent("\(name).app", isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        // ditto 而不是 copyItem：要连同符号链接、扩展属性、ACL 一起搬，否则备份出来的包
        // 可能因为签名校验不通过而变成废品。
        let result = await ProcessRunner.run(
            executable: "/usr/bin/ditto",
            arguments: [url.path, destination.path],
            timeout: ProcessRunner.largeCopyTimeout
        )
        guard result.succeeded else {
            try? fm.removeItem(at: container)
            throw BackupError.copyFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        return destination
    }

    /// 只保留最近 `keep` 份备份，更早的删掉。
    @discardableResult
    public func prune(bundleID: String, keeping keep: Int = BackupStore.defaultKeepCount) -> [URL] {
        let fm = FileManager.default
        let container = root.appendingPathComponent(Self.sanitized(bundleID), isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // 目录名以时间戳开头，倒序即"新 → 旧"。
        let ordered = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        var removed: [URL] = []
        for stale in ordered.dropFirst(max(0, keep)) {
            if (try? fm.removeItem(at: stale)) != nil {
                removed.append(stale)
            }
        }
        return removed
    }

    /// 所有应用占用的备份总大小，界面提示用。
    ///
    /// 注意它是**同步**的，会遍历整棵备份树。备份动辄上 G、几万个文件，
    /// 这个调用不适合放在主线程上（界面里请走 `UpdateStore.refreshBackupUsage()`）。
    public func totalSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// 清空全部备份的结果。
    public struct ClearReport: Sendable, Equatable {
        /// 实际删掉的顶层条目数（通常等于备份过的应用数）。
        public let removed: Int
        /// 清理前量到的总占用，即这次释放掉的字节数。
        public let freedBytes: Int64

        public init(removed: Int, freedBytes: Int64) {
            self.removed = removed
            self.freedBytes = freedBytes
        }
    }

    /// 删掉全部备份，保留 `root` 目录本身。返回删了多少、释放了多少。
    ///
    /// **这个函数由界面上的一个按钮直接触发，没有撤销。** 所以两件事都做了收窄：
    /// 只删 `root` 的**直接子项**（不做任何递归推断），以及进门先过一道
    /// `isSafeToClear` 护栏。路径推断错一次就是不可逆的数据丢失，宁可这里多写三行。
    @discardableResult
    public func clearAll() -> ClearReport {
        let fm = FileManager.default
        guard isSafeToClear else { return ClearReport(removed: 0, freedBytes: 0) }

        let freed = totalSize()
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return ClearReport(removed: 0, freedBytes: 0)
        }

        var removed = 0
        for entry in entries where (try? fm.removeItem(at: entry)) != nil {
            removed += 1
        }
        return ClearReport(removed: removed, freedBytes: freed)
    }

    /// 护栏：拒绝明显不该被清空的目标。
    ///
    /// 挡掉根目录与家目录，以及层级过浅的路径（`/tmp` 这种），不要求目录名必须叫
    /// `Backups`——测试注入的临时目录另有其名，按名字判会把测试一起挡掉。
    var isSafeToClear: Bool {
        let path = root.standardizedFileURL.path
        guard path != "/" else { return false }
        guard path != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path else { return false }
        return URL(fileURLWithPath: path).pathComponents.count >= 3
    }

    private func sanitizedVersion(_ version: String?) -> String {
        guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else {
            return "未知版本"
        }
        return version.replacingOccurrences(of: "/", with: "_")
    }

    public enum BackupError: LocalizedError {
        case copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .copyFailed(let message): return "备份失败：\(message)"
            }
        }
    }
}
