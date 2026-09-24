import AppKit
import Foundation
import OSLog

/// 一键升级的执行器。
///
/// 这是整个工具里唯一会写入 `/Applications` 的地方，因此流程被刻意拆成
/// 「先证明、再动手、留退路」三段：
///
/// 1. **先证明** —— 下载 → EdDSA 签名校验 → 解包 → 确认包身份（Bundle ID、版本、
///    代码签名、签名主体一致）。任何一条不过就地中止，此时磁盘上什么都没变。
/// 2. **再动手** —— 备份旧包 → 优雅退出运行中的 App → 在同一卷上用 `rename` 原子换包。
/// 3. **留退路** —— 换包之后的每一步失败都触发回滚，把旧包原样搬回去。
///
/// 换包用「同卷 rename」而不是「删除 + 拷贝」：rename 是原子的，不存在"App 被删到一半
/// 掉电导致它消失"的窗口。旧包在换包瞬间被改名而不是删除，所以回滚只是一次 rename。
public struct Installer: Sendable {
    /// 安装流程的阶段，界面按顺序打勾。
    public enum Phase: String, Sendable, CaseIterable, Codable {
        case recovering
        case downloading
        case verifyingSignature
        case extracting
        case validating
        case backingUp
        case quitting
        case replacing
        case verifyingInstall
        case relaunching

        public var title: String {
            switch self {
            case .recovering: return "检查上次中断的残留"
            case .downloading: return "下载安装包"
            case .verifyingSignature: return "校验开发者签名"
            case .extracting: return "解包"
            case .validating: return "确认包身份"
            case .backingUp: return "备份旧版本"
            case .quitting: return "退出正在运行的应用"
            case .replacing: return "替换应用"
            case .verifyingInstall: return "验证安装结果"
            case .relaunching: return "重新打开应用"
            }
        }
    }

    public struct Progress: Sendable {
        public let phase: Phase
        public let detail: String
        /// 0…1，未知时为 nil。
        public let fraction: Double?

        public init(phase: Phase, detail: String, fraction: Double? = nil) {
            self.phase = phase
            self.detail = detail
            self.fraction = fraction
        }
    }

    public struct Report: Sendable {
        public var appName: String
        public var bundleID: String
        public var fromVersion: String?
        public var toVersion: String
        public var signature: SignatureVerifier.Outcome
        public var backupPath: URL?
        public var installedPath: URL?
        public var relaunched: Bool = false
        public var rolledBack: Bool = false
        public var warnings: [String] = []
        public var error: String?

        public var succeeded: Bool { error == nil }
    }

    public enum InstallError: LocalizedError {
        case notInstallable(String)
        case downloadFailed(String)
        case signatureRejected(String)
        case extractionFailed(String)
        case bundleNotFound(String)
        case validationFailed(String)
        case backupFailed(String)
        case appWontQuit(String)
        case swapFailed(String)
        case insufficientSpace(String)

        public var errorDescription: String? {
            switch self {
            case .notInstallable(let reason): return reason
            case .downloadFailed(let reason): return "下载失败：\(reason)"
            case .signatureRejected(let reason): return "签名校验未通过：\(reason)"
            case .extractionFailed(let reason): return "解包失败：\(reason)"
            case .bundleNotFound(let reason): return reason
            case .validationFailed(let reason): return "安装包校验未通过：\(reason)"
            case .backupFailed(let reason): return reason
            case .appWontQuit(let reason): return reason
            case .swapFailed(let reason): return "替换失败：\(reason)"
            case .insufficientSpace(let reason): return reason
            }
        }
    }

    private let downloader: PackageDownloader
    private let backups: BackupStore

    public init(downloader: PackageDownloader = PackageDownloader(), backups: BackupStore = BackupStore()) {
        self.downloader = downloader
        self.backups = backups
    }

    /// 安装行为开关。默认值保持给其他应用升级；自更新走 `selfUpdate(...)`。
    public struct InstallOptions: Sendable {
        public var manifestBytes: Data?
        public var manifestSignature: String?
        public var publicKeyOverride: String?
        /// 自更新时不能先把自己退出，否则换包走不到。
        public var skipQuit: Bool
        /// 自更新时由新实例启动时再清 `.old`，当前进程可能还住在被改名的包里。
        public var keepDisplaced: Bool
        public var alwaysRelaunch: Bool

        public static let standard = InstallOptions(
            manifestBytes: nil,
            manifestSignature: nil,
            publicKeyOverride: nil,
            skipQuit: false,
            keepDisplaced: false,
            alwaysRelaunch: false
        )

        public static func selfUpdate(
            manifestBytes: Data?,
            manifestSignature: String?,
            publicKey: String
        ) -> InstallOptions {
            InstallOptions(
                manifestBytes: manifestBytes,
                manifestSignature: manifestSignature,
                publicKeyOverride: publicKey,
                skipQuit: true,
                keepDisplaced: true,
                alwaysRelaunch: true
            )
        }
    }

    // MARK: - 预检：确认框要展示的信息

    /// 该应用公布公钥与否，决定了"能不能做密码学校验"。
    public enum SignatureAvailability: Sendable, Equatable {
        case willVerify
        case cannotVerify(String)

        public var description: String {
            switch self {
            case .willVerify: return "下载后校验开发者签名（Ed25519）"
            case .cannotVerify(let reason): return "无法校验开发者签名 · \(reason)"
            }
        }
    }

    /// 点「升级」之前展示给用户的全部事实。
    public struct Plan: Sendable {
        public var appName: String
        public var bundleID: String
        public var fromVersion: String?
        public var toVersion: String
        public var packageKind: PackageKind
        public var downloadSize: Int64?
        public var sourceHost: String?
        public var signature: SignatureAvailability
        public var targetPath: URL
        public var backupLocation: URL
        public var isAppRunning: Bool
        public var warnings: [String]
    }

    public func makePlan(app: AppInfo, release: ReleaseInfo) -> Plan {
        var warnings: [String] = []

        let signature: SignatureAvailability = app.canVerifySignature
            ? .willVerify
            : .cannotVerify("该应用未在 Info.plist 里公布公钥")

        if release.edSignature == nil {
            warnings.append("更新源没有提供签名，只能依赖代码签名与包身份校验")
        }
        if !app.canVerifySignature {
            warnings.append("该应用未公布签名公钥，无法确认安装包是否出自官方")
        }
        // 增量补丁的体积会明显小于完整包。这里拿现有 App 包做参照：
        // 一个完整安装包（压缩后）通常不会比它要替换的包小太多，
        // 而 AlDente 那种「完整包 12.2 MB、补丁 2.3 MB」的差距会被这条拦下来。
        if let size = release.size, size > 0 {
            if size < 150_000 {
                warnings.append("安装包体积异常偏小（\(AppUpdate.formatBytes(size))），可能不是完整包")
            } else if let installed = Self.directorySize(app.path), installed > 0,
                      Double(size) < Double(installed) * 0.3 {
                warnings.append(
                    "安装包只有 \(AppUpdate.formatBytes(size))，远小于现有应用包（\(AppUpdate.formatBytes(installed))），可能不是完整包"
                )
            }
        }

        let container = backups.root
            .appendingPathComponent(BackupStore.sanitized(app.bundleID ?? "unknown"), isDirectory: true)

        return Plan(
            appName: app.name,
            bundleID: app.bundleID ?? "未知",
            fromVersion: app.currentVersion,
            toVersion: release.version,
            packageKind: release.packageKind,
            downloadSize: release.size,
            sourceHost: release.sourceHost,
            signature: signature,
            targetPath: app.path,
            backupLocation: container,
            isAppRunning: Self.isRunning(bundleID: app.bundleID),
            warnings: warnings
        )
    }

    // MARK: - 执行

    public func install(
        app: AppInfo,
        release: ReleaseInfo,
        options: InstallOptions = .standard,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async -> Report {
        var report = Report(
            appName: app.name,
            bundleID: app.bundleID ?? "",
            fromVersion: app.currentVersion,
            toVersion: release.version,
            signature: .skipped(reason: "尚未校验")
        )

        @Sendable func emit(_ phase: Phase, _ detail: String, fraction: Double? = nil) {
            onProgress(Progress(phase: phase, detail: detail, fraction: fraction))
        }

        guard let bundleID = app.bundleID, !bundleID.isEmpty else {
            report.error = InstallError.notInstallable("无法确认应用的 Bundle ID，不能自动替换").errorDescription
            return report
        }
        guard let downloadURL = release.downloadURL else {
            report.error = InstallError.notInstallable("更新源没有提供安装包地址").errorDescription
            return report
        }
        guard release.packageKind.isAutoInstallable else {
            report.error = InstallError.notInstallable("\(release.packageKind.displayName)需要手动安装").errorDescription
            return report
        }
        guard AppUpdate.isReplaceable(app.path), FileManager.default.isWritableFile(atPath: app.path.deletingLastPathComponent().path) else {
            report.error = InstallError.notInstallable("\(app.path.path) 不在可自动替换的位置").errorDescription
            return report
        }

        Log.install.info("开始安装 \(app.name) \(app.currentVersion ?? "?") → \(release.version)")

        // 自更新时目标可能还叫旧名字（`/Applications/AppUpdater.app`）。把替换落到
        // `Updraft.app` 上，顺手完成改名——老用户点一次「升级」就行，不必删了重装。
        let target = SelfUpdateIdentity.isSelf(bundleID: bundleID)
            ? SelfUpdateIdentity.canonicalTargetURL(for: app.path)
            : app.path
        // 磁盘上那个包的**真实**身份。自更新时 `app.bundleID` 是我们自己填的新 ID，
        // 而旧版本装出来的包还是 `com.local.appupdater`——备份与「是否在运行」
        // 都得看磁盘上真实的那个，否则备份目录会串、运行中的旧实例也认不出来。
        let diskBundleID = Self.bundleIdentifier(of: app.path) ?? bundleID

        var workspace: URL?
        do {
            // ── 阶段零：收拾上次的残局 ──
            // 上一次若被强杀，可能留下 `.old.app` 这类隐藏中间态文件；极其罕见的情况下
            // 应用本身还停在"旧包已挪走、新包未就位"的状态，这里会把它救回来。
            emit(.recovering, "检查上次中断留下的残留…")
            Self.cleanStaleWorkspaces()
            let recovery = Self.recoverInterruptedInstalls()
            if !recovery.isEmpty {
                emit(.recovering, recovery.summary)
            }

            // ── 阶段零：准备 ──
            let sizeHint = release.size ?? 0
            let required = sizeHint * 3 + 300_000_000
            if let available = Self.availableBytes(at: app.path.deletingLastPathComponent()), available < required {
                throw InstallError.insufficientSpace(
                    "磁盘空间不足：需要约 \(AppUpdate.formatBytes(required))，当前可用 \(AppUpdate.formatBytes(available))"
                )
            }

            let work = try Self.makeWorkspace()
            workspace = work

            // ── 阶段一：下载 ──
            let packageURL = work.appendingPathComponent("package.\(release.packageKind.rawValue)")
            emit(.downloading, "连接 \(release.sourceHost ?? "更新源")…")
            let throttle = Throttle(interval: 0.1)
            try await downloader.download(from: downloadURL, to: packageURL) { received, total in
                // 进度回调很密集，节流到每 100ms 一次，避免把主线程冲垮。
                guard received == total || throttle.shouldEmit() else { return }
                let fraction = total > 0 ? Double(received) / Double(total) : nil
                let text = total > 0
                    ? "\(AppUpdate.formatBytes(received)) / \(AppUpdate.formatBytes(total))"
                    : AppUpdate.formatBytes(received)
                emit(.downloading, text, fraction: fraction)
            }

            let downloadedSize = Self.fileSize(packageURL) ?? 0
            emit(.downloading, "已下载 \(AppUpdate.formatBytes(downloadedSize))", fraction: 1)

            // 尺寸兜底：appcast 声明了大小却只下到零头，说明拿到的东西不对。
            if let expected = release.size, expected > 0, downloadedSize < expected / 2 {
                throw InstallError.downloadFailed(
                    "下载不完整：声明 \(AppUpdate.formatBytes(expected))，实际只有 \(AppUpdate.formatBytes(downloadedSize))"
                )
            }

            // ── 阶段二：签名校验（动手之前最后一道闸） ──
            let signature: SignatureVerifier.Outcome
            if options.publicKeyOverride != nil || options.manifestBytes != nil || options.manifestSignature != nil {
                emit(.verifyingSignature, "正在校验签名清单与安装包校验和…")
                signature = SelfUpdateVerifier.verifyDownloadedZip(
                    zip: packageURL,
                    manifestBytes: options.manifestBytes,
                    manifestSignature: options.manifestSignature,
                    publicKey: options.publicKeyOverride ?? app.publicEDKey
                )
            } else {
                emit(.verifyingSignature, app.canVerifySignature ? "正在用应用公布的公钥校验…" : "该应用未公布公钥，跳过")
                signature = SignatureVerifier.verify(
                    fileAt: packageURL,
                    signatureBase64: release.edSignature,
                    publicKeyBase64: app.publicEDKey
                )
            }
            report.signature = signature
            if case .failed(let reason) = signature {
                throw InstallError.signatureRejected(reason)
            }

            // ── 阶段三：解包 ──
            emit(.extracting, "正在解包 \(release.packageKind.displayName)…")
            let stagedApp = try await stageApp(
                package: packageURL,
                kind: release.packageKind,
                bundleID: bundleID,
                in: work
            )

            // ── 阶段四：确认包身份 ──
            emit(.validating, "正在确认包身份…")
            let stagedVersion = try await validate(
                stagedApp: stagedApp,
                target: app,
                advertisedVersion: release.version,
                signature: signature,
                warnings: &report.warnings
            )

            // ── 阶段五：备份 ──
            emit(.backingUp, "正在备份 \(app.currentVersion ?? "当前版本")…")
            do {
                let backupURL = try await backups.backup(
                    appAt: app.path,
                    name: app.name,
                    version: app.currentVersion,
                    bundleID: diskBundleID
                )
                report.backupPath = backupURL
            } catch {
                throw InstallError.backupFailed(error.localizedDescription)
            }

            // ── 阶段六：退出运行中的 App ──
            // 自更新跳过：当前进程就是目标，先退出换包就做不成。
            let wasRunning = Self.isRunning(bundleID: diskBundleID)
            if wasRunning, !options.skipQuit {
                emit(.quitting, "正在请求 \(app.name) 退出…")
                try await quit(bundleID: diskBundleID, appName: app.name)
            }

            // ── 阶段七：原子换包 ──
            // 这一步内部有两件事：把新包拷进目标目录、再用两次 rename 换名。
            // 界面只能看到同一行文本，所以细节文本要一路透出去。
            emit(.replacing, "正在替换 \(target.lastPathComponent)…")
            let displaced: URL
            do {
                displaced = try await swapIn(newApp: stagedApp, at: target, displacing: app.path) { detail in
                    emit(.replacing, detail)
                }
            } catch {
                throw InstallError.swapFailed(error.localizedDescription)
            }

            // 从这一行起，磁盘上的 App 已经是新的了。之后任何失败都必须回滚。
            do {
                await Self.stripQuarantine(target)
                emit(.verifyingInstall, "正在验证新版本…")
                try await verifyInstalled(path: target, bundleID: bundleID, expectedVersion: stagedVersion)
            } catch {
                Self.restore(displaced: displaced, to: target)
                report.rolledBack = true
                report.error = "\(error.localizedDescription)（已回滚到 \(app.currentVersion ?? "旧版本")）"
                Log.install.warning("安装 \(app.name) 后验证失败，已回滚: \(error.localizedDescription)")
                return report
            }

            if !options.keepDisplaced {
                try? FileManager.default.removeItem(at: displaced)
            }
            report.installedPath = target

            // ── 收尾：重新打开 + 清理旧备份 ──
            // 自更新总是拉起新实例，由它在下次启动时清 `.old`。注意此刻**本进程还活着**
            // （skipQuit），所以这一步必须用能强开新实例的方式，见 `relaunchCommand`。
            if wasRunning || options.alwaysRelaunch {
                emit(.relaunching, "正在重新打开 \(app.name)…")
                report.relaunched = await Self.launch(target)
            }
            backups.prune(bundleID: diskBundleID)
        } catch {
            report.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.install.error("安装 \(app.name) 失败: \(report.error ?? "")")
        }

        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
        return report
    }

    // MARK: - 解包

    private func stageApp(package: URL, kind: PackageKind, bundleID: String, in workspace: URL) async throws -> URL {
        let staging = workspace.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        switch kind {
        case .dmg:
            let mountPoint = workspace.appendingPathComponent("mnt", isDirectory: true)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            return try await withMounted(package: package, mountPoint: mountPoint) { volume in
                try await self.copyApp(from: volume, into: staging, bundleID: bundleID)
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
                throw InstallError.extractionFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            return try await copyApp(from: unpacked, into: staging, bundleID: bundleID)

        default:
            throw InstallError.notInstallable("\(kind.displayName)需要手动安装")
        }
    }

    /// 挂载 → 执行 → 无论如何都卸载。`defer` 不能 await，所以用这份包装。
    private func withMounted<T>(
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
            throw InstallError.extractionFailed("挂载磁盘映像失败：\(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // 从 attach 输出里取设备名（形如 /dev/disk4s1），卸载时优先用它，比挂载点更可靠。
        let device = Self.attachedDevice(in: attach.stdout)

        do {
            let value = try await body(mountPoint)
            await Self.detach(device: device, mountPoint: mountPoint)
            return value
        } catch {
            await Self.detach(device: device, mountPoint: mountPoint)
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
    private func copyApp(from root: URL, into staging: URL, bundleID: String) async throws -> URL {
        guard let found = Self.findAppBundle(in: root, matching: bundleID) else {
            throw InstallError.bundleNotFound("安装包里没有找到 \(bundleID)，可能不是完整的应用包")
        }

        let destination = staging.appendingPathComponent(found.lastPathComponent, isDirectory: true)
        let result = await ProcessRunner.run(
            executable: "/usr/bin/ditto",
            arguments: [found.path, destination.path],
            timeout: ProcessRunner.largeCopyTimeout
        )
        guard result.succeeded else {
            throw InstallError.extractionFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
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
                    if Self.bundleIdentifier(of: entry) == bundleID { return entry }
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
