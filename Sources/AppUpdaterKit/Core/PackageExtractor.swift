import Foundation

/// 安装包解包器：把 dmg / zip 里那个真正的 `.app` 取出来，放到调用方指定的暂存目录。
///
/// 从 `Installer` 里抽出来单独成型的理由很直接——**应用给自己升级用的是同一种包**。
/// 一份解包逻辑两处实现的话，`.delta` 陷阱、符号链接、挂载点卸载这些坑各踩一遍，
/// 迟早会有一边漏掉。
public enum PackageExtractor {
    public enum ExtractionError: LocalizedError {
        case mountFailed(String)
        case extractionFailed(String)
        case bundleNotFound(String)
        case unsupportedKind(String)

        public var errorDescription: String? {
            switch self {
            case .mountFailed(let reason): return "解包失败：挂载磁盘映像失败 \(reason)"
            case .extractionFailed(let reason): return "解包失败：\(reason)"
            case .bundleNotFound(let reason): return reason
            case .unsupportedKind(let kind): return "\(kind)需要手动安装"
            }
        }
    }

    /// 解出一个 `.app` 并搬进 `workspace/staged/`，返回它在暂存目录里的路径。
    public static func stageApp(
        package: URL,
        kind: PackageKind,
        bundleID: String,
        in workspace: URL
    ) async throws -> URL {
        let staging = workspace.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        switch kind {
        case .dmg:
            let mountPoint = workspace.appendingPathComponent("mnt", isDirectory: true)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            return try await withMounted(package: package, mountPoint: mountPoint) { volume in
                try await copyApp(from: volume, into: staging, bundleID: bundleID)
            }

        case .zip:
            let unpacked = workspace.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            let result = await ProcessRunner.run(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", package.path, unpacked.path],
                timeout: ProcessRunner.largeCopyTimeout
            )
            guard result.succeeded else {
                throw ExtractionError.extractionFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            return try await copyApp(from: unpacked, into: staging, bundleID: bundleID)

        default:
            throw ExtractionError.unsupportedKind(kind.displayName)
        }
    }

    /// 挂载 → 执行 → 无论如何都卸载。`defer` 不能 await，所以用这份包装。
    private static func withMounted<T>(
        package: URL,
        mountPoint: URL,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let attach = await ProcessRunner.run(
            executable: "/usr/bin/hdiutil",
            arguments: [
                "attach", "-nobrowse", "-noautoopen", "-readonly",
                "-mountpoint", mountPoint.path, package.path
            ]
        )
        guard attach.succeeded else {
            let message = attach.stderr.isEmpty ? attach.stdout : attach.stderr
            throw ExtractionError.mountFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 从 attach 输出里取设备名（形如 /dev/disk4s1），卸载时优先用它，比挂载点更可靠。
        let device = attachedDevice(in: attach.stdout)

        do {
            let value = try await body(mountPoint)
            await detach(device: device, mountPoint: mountPoint)
            return value
        } catch {
            await detach(device: device, mountPoint: mountPoint)
            throw error
        }
    }

    /// 从 `hdiutil attach` 的输出里取设备名（形如 `/dev/disk4`）。
    ///
    /// 注意输出用**空格**对齐而不是制表符，所以不能按 `\t` 切分——
    /// 按制表符切会拿到带尾随空格的整行，设备名匹配不上，卸载就只能退回挂载点路径。
    static func attachedDevice(in output: String) -> String? {
        for line in output.split(separator: "\n") {
            let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            guard let first, first.hasPrefix("/dev/disk") else { continue }
            return String(first)
        }
        return nil
    }

    private static func detach(device: String?, mountPoint: URL) async {
        if let device {
            let result = await ProcessRunner.run(executable: "/usr/bin/hdiutil", arguments: ["detach", device])
            if result.succeeded { return }
        }
        let plain = await ProcessRunner.run(executable: "/usr/bin/hdiutil", arguments: ["detach", mountPoint.path])
        if plain.succeeded { return }
        _ = await ProcessRunner.run(executable: "/usr/bin/hdiutil", arguments: ["detach", "-force", mountPoint.path])
    }

    /// 在解包出来的目录里找到目标 `.app` 并搬到 staging。
    private static func copyApp(from root: URL, into staging: URL, bundleID: String) async throws -> URL {
        guard let found = findAppBundle(in: root, matching: bundleID) else {
            throw ExtractionError.bundleNotFound("安装包里没有找到 \(bundleID)，可能不是完整的应用包")
        }

        let destination = staging.appendingPathComponent(found.lastPathComponent, isDirectory: true)
        let result = await ProcessRunner.run(
            executable: "/usr/bin/ditto",
            arguments: [found.path, destination.path],
            timeout: ProcessRunner.largeCopyTimeout
        )
        guard result.succeeded else {
            throw ExtractionError.extractionFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return destination
    }

    /// 广度优先找 `.app`：优先 Bundle ID 完全匹配的那个，其次退回"目录里只有一个 .app"。
    ///
    /// 必须跳过符号链接——很多 dmg 里放了一个指向 `/Applications` 的快捷方式，
    /// 顺着它走会匹配到本机已装的自己，那就荒唐了。
    static func findAppBundle(in root: URL, matching bundleID: String, maxDepth: Int = 3) -> URL? {
        let fm = FileManager.default
        var queue: [(URL, Int)] = [(root, 0)]
        var fallback: [URL] = []

        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            guard depth <= maxDepth else { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                guard values?.isDirectory == true else { continue }

                if entry.pathExtension == "app" {
                    fallback.append(entry)
                    if bundleIdentifier(of: entry) == bundleID { return entry }
                } else if depth < maxDepth {
                    queue.append((entry, depth + 1))
                }
            }
        }

        return fallback.count == 1 ? fallback[0] : nil
    }

    static func bundleIdentifier(of app: URL) -> String? {
        plistValue("CFBundleIdentifier", in: app)
    }

    static func plistValue(_ key: String, in app: URL) -> String? {
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = raw as? [String: Any],
              let value = dictionary[key] else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
