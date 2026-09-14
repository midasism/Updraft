import AppKit
import Foundation

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
            emit(.verifyingSignature, app.canVerifySignature ? "正在用应用公布的公钥校验…" : "该应用未公布公钥，跳过")
            let signature = SignatureVerifier.verify(
                fileAt: packageURL,
                signatureBase64: release.edSignature,
                publicKeyBase64: app.publicEDKey
            )
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
                    bundleID: bundleID
                )
                report.backupPath = backupURL
            } catch {
                throw InstallError.backupFailed(error.localizedDescription)
            }

            // ── 阶段六：退出运行中的 App ──
            let wasRunning = Self.isRunning(bundleID: bundleID)
            if wasRunning {
                emit(.quitting, "正在请求 \(app.name) 退出…")
                try await quit(bundleID: bundleID, appName: app.name)
            }

            // ── 阶段七：原子换包 ──
            // 这一步内部有两件事：把新包拷进目标目录、再用两次 rename 换名。
            // 界面只能看到同一行文本，所以细节文本要一路透出去。
            emit(.replacing, "正在替换 \(app.path.lastPathComponent)…")
            let displaced: URL
            do {
                displaced = try await swapIn(newApp: stagedApp, at: app.path) { detail in
                    emit(.replacing, detail)
                }
            } catch {
                throw InstallError.swapFailed(error.localizedDescription)
            }

            // 从这一行起，磁盘上的 App 已经是新的了。之后任何失败都必须回滚。
            do {
                await Self.stripQuarantine(app.path)
                emit(.verifyingInstall, "正在验证新版本…")
                try await verifyInstalled(path: app.path, bundleID: bundleID, expectedVersion: stagedVersion)
            } catch {
                Self.restore(displaced: displaced, to: app.path)
                report.rolledBack = true
                report.error = "\(error.localizedDescription)（已回滚到 \(app.currentVersion ?? "旧版本")）"
                return report
            }

            try? FileManager.default.removeItem(at: displaced)
            report.installedPath = app.path

            // ── 收尾：重新打开 + 清理旧备份 ──
            if wasRunning {
                emit(.relaunching, "正在重新打开 \(app.name)…")
                report.relaunched = await Self.launch(app.path)
            }
            backups.prune(bundleID: bundleID)
        } catch {
            report.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    // MARK: - 校验

    /// 返回新包实际的版本号（以包内 `Info.plist` 为准，而不是 appcast 的宣称）。
    private func validate(
        stagedApp: URL,
        target: AppInfo,
        advertisedVersion: String,
        signature: SignatureVerifier.Outcome,
        warnings: inout [String]
    ) async throws -> String {
        guard let bundleID = target.bundleID else {
            throw InstallError.validationFailed("目标应用没有 Bundle ID")
        }
        guard let stagedBundleID = Self.bundleIdentifier(of: stagedApp), stagedBundleID == bundleID else {
            throw InstallError.validationFailed(
                "安装包的 Bundle ID 是 \(Self.bundleIdentifier(of: stagedApp) ?? "空")，与目标应用 \(bundleID) 不一致"
            )
        }

        let stagedVersion = Self.plistValue("CFBundleShortVersionString", in: stagedApp) ?? advertisedVersion
        if let current = target.currentVersion, !current.isEmpty {
            guard Version(stagedVersion) > Version(current) else {
                throw InstallError.validationFailed("安装包版本 \(stagedVersion) 不高于当前版本 \(current)")
            }
        }
        if Version(stagedVersion) != Version(advertisedVersion) {
            warnings.append("包内版本 \(stagedVersion) 与更新源宣称的 \(advertisedVersion) 不一致")
        }

        // 代码签名：先严格，严格不过再退到普通校验。
        let strict = await Self.verifyCodeSignature(stagedApp, deep: true)
        if !strict.ok {
            let plain = await Self.verifyCodeSignature(stagedApp, deep: false)
            guard plain.ok else {
                throw InstallError.validationFailed("代码签名无效：\(strict.detail)")
            }
            warnings.append("严格代码签名校验未通过，已退到普通校验（包完整性仍然有效）")
        }

        // 签名主体一致性：换了个开发者签名是要拦下来的事。
        let previous = await Self.signingIdentity(of: target.path)
        let incoming = await Self.signingIdentity(of: stagedApp)

        if let oldTeam = previous.teamID, !oldTeam.isEmpty, incoming.teamID != oldTeam {
            if signature.isVerified {
                warnings.append("签名主体由 \(oldTeam) 变为 \(incoming.teamID ?? "无")，但开发者签名校验已通过")
            } else {
                throw InstallError.validationFailed(
                    "签名主体发生变化（\(oldTeam) → \(incoming.teamID ?? "无")），且无法校验开发者签名"
                )
            }
        } else if previous.teamID == nil, let oldAuthority = previous.authority,
                  let newAuthority = incoming.authority, oldAuthority != newAuthority {
            if signature.isVerified {
                warnings.append("签名证书由「\(oldAuthority)」变为「\(newAuthority)」")
            } else {
                throw InstallError.validationFailed(
                    "签名证书发生变化（\(oldAuthority) → \(newAuthority)），且无法校验开发者签名"
                )
            }
        }

        return stagedVersion
    }

    struct SignatureCheck {
        let ok: Bool
        let detail: String
    }

    static func verifyCodeSignature(_ app: URL, deep: Bool) async -> SignatureCheck {
        var arguments = ["--verify"]
        if deep { arguments.append("--deep") }
        arguments.append("--strict")
        arguments.append(app.path)

        let result = await ProcessRunner.run(executable: "/usr/bin/codesign", arguments: arguments)
        let output = result.stderr.isEmpty ? result.stdout : result.stderr
        return SignatureCheck(
            ok: result.succeeded,
            detail: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    struct SigningIdentity: Sendable {
        var identifier: String?
        var teamID: String?
        var authority: String?
    }

    static func signingIdentity(of app: URL) async -> SigningIdentity {
        let result = await ProcessRunner.run(
            executable: "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=2", app.path]
        )
        let text = result.stderr.isEmpty ? result.stdout : result.stderr

        var identity = SigningIdentity()
        for line in text.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Identifier=") {
                identity.identifier = String(line.dropFirst("Identifier=".count))
            } else if line.hasPrefix("TeamIdentifier=") {
                let value = String(line.dropFirst("TeamIdentifier=".count))
                identity.teamID = value == "not set" ? nil : value
            } else if line.hasPrefix("Authority="), identity.authority == nil {
                identity.authority = String(line.dropFirst("Authority=".count))
            }
        }
        return identity
    }

    private func verifyInstalled(path: URL, bundleID: String, expectedVersion: String) async throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw InstallError.validationFailed("替换后目标路径不存在")
        }
        guard Self.bundleIdentifier(of: path) == bundleID else {
            throw InstallError.validationFailed("替换后的 Bundle ID 不正确")
        }
        let version = Self.plistValue("CFBundleShortVersionString", in: path)
        guard let version, Version(version) >= Version(expectedVersion) else {
            throw InstallError.validationFailed("替换后的版本号是 \(version ?? "空")，低于预期")
        }
        let check = await Self.verifyCodeSignature(path, deep: false)
        guard check.ok else {
            throw InstallError.validationFailed("替换后的包代码签名无效：\(check.detail)")
        }
    }

    // MARK: - 换包与回滚

    /// 原子换包。返回被换下来的旧包路径（尚未删除，供回滚使用）。
    ///
    /// `onProgress` 只传细节文本，用于让界面能区分"在干活"与"卡死了"。
    private func swapIn(
        newApp: URL,
        at target: URL,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        let stem = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        let token = UUID().uuidString.prefix(8)

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

        do {
            try fm.moveItem(at: target, to: displaced)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        do {
            try fm.moveItem(at: staging, to: target)
        } catch {
            // 新包就位失败，立刻把旧包搬回去，让用户至少还有能用的 App。
            try? fm.moveItem(at: displaced, to: target)
            try? fm.removeItem(at: staging)
            throw error
        }

        return displaced
    }

    /// 换包之后的失败回滚。
    static func restore(displaced: URL, to target: URL) {
        let fm = FileManager.default
        let broken = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).broken-\(UUID().uuidString.prefix(8))")

        try? fm.moveItem(at: target, to: broken)
        try? fm.moveItem(at: displaced, to: target)
        try? fm.removeItem(at: broken)
    }

    /// 去掉隔离属性。下载来的包一旦带上 `com.apple.quarantine`，首次启动会被
    /// Gatekeeper 拦下来问东问西，装完就顺手清掉。
    static func stripQuarantine(_ app: URL) async {
        _ = await ProcessRunner.run(
            executable: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", app.path]
        )
    }

    // MARK: - 运行中的应用

    static func isRunning(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return !runningApplications(bundleID: bundleID).isEmpty
    }

    private static func runningApplications(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    /// 让应用优雅退出。宁可中止升级，也不强杀——强杀会丢掉用户没保存的东西。
    private func quit(bundleID: String, appName: String, timeout: TimeInterval = 12) async throws {
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

    static func launch(_ app: URL) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.open(app)
        }
    }

    // MARK: - 文件系统小工具

    /// 工作目录名以 PID 开头，`cleanStaleWorkspaces` 据此判断这个目录的主人还在不在。
    static func makeWorkspace() throws -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("AppUpdater", isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// 一个 `.app` 包在磁盘上实际占用的字节数。
    static func directorySize(_ url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        ) else {
            return nil
        }

        var total: Int64 = 0
        var sawAnything = false
        for case let entry as URL in enumerator {
            let values = try? entry.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true else { continue }
            sawAnything = true
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return sawAnything ? total : nil
    }

    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - 崩溃/强杀后的恢复

/// 换包流程横跨三个文件系统操作（新包落位 → 旧包改名 → 新包就位），
/// 中间任何一刻进程被强杀，`/Applications` 里就会留下隐藏的中间态文件。
/// 这里负责在下一次启动时把它们收拾干净——并且在最坏的情况下把应用救回来。
public struct RecoveryReport: Sendable {
    /// 从中间态里抢救回来的应用。
    public var rescuedApps: [String] = []
    /// 清掉的残留文件。
    public var removedArtifacts: [String] = []
    /// 需要人工处理的情况。绝不自作主张删除。
    public var needsAttention: [String] = []

    public var isEmpty: Bool {
        rescuedApps.isEmpty && removedArtifacts.isEmpty && needsAttention.isEmpty
    }

    public var summary: String {
        var parts: [String] = []
        if !rescuedApps.isEmpty {
            parts.append("已恢复 \(rescuedApps.joined(separator: "、"))")
        }
        if !removedArtifacts.isEmpty {
            parts.append("清理了 \(removedArtifacts.count) 个残留文件")
        }
        parts.append(contentsOf: needsAttention)
        return parts.joined(separator: "；")
    }
}

extension Installer {
    /// 换包中间态文件名的结构。
    enum ArtifactKind {
        /// `.<名字>.<token>.new.app` —— 待就位的新包。
        case incoming
        /// `.<名字>.<token>.old.app` —— 被换下来的旧包，回滚的唯一依据。
        case displaced
        /// `.<名字>.app.broken-<token>` —— 回滚过程中被挪开的坏包。
        case broken
    }

    /// 解析隐藏的中间态文件名，顺便挡住所有无关的隐藏文件。
    static func classifyArtifact(_ name: String) -> (stem: String, kind: ArtifactKind)? {
        // `._Foo` 是 AppleDouble 伴生文件，不是我们造的中间态。
        guard name.hasPrefix("."), !name.hasPrefix("._") else { return nil }
        let body = String(name.dropFirst())
        guard !body.isEmpty else { return nil }

        for (suffix, kind) in [(".new.app", ArtifactKind.incoming), (".old.app", ArtifactKind.displaced)] {
            guard body.hasSuffix(suffix) else { continue }
            let head = String(body.dropLast(suffix.count))     // 形如 "Rectangle.38144E15"
            let pieces = head.split(separator: ".")
            guard pieces.count >= 2, let token = pieces.last, isArtifactToken(token) else { return nil }
            let stem = pieces.dropLast().joined(separator: ".")
            return stem.isEmpty ? nil : (stem, kind)
        }

        if let marker = body.range(of: ".app.broken-") {
            let stem = String(body[body.startIndex..<marker.lowerBound])
            let token = String(body[marker.upperBound...])
            guard !stem.isEmpty, isArtifactToken(Substring(token)) else { return nil }
            return (stem, .broken)
        }

        return nil
    }

    /// 换包时用的 token 是 `UUID().uuidString` 的前 8 位。
    private static func isArtifactToken(_ value: Substring) -> Bool {
        value.count == 8 && value.allSatisfy(\.isHexDigit)
    }

    /// 一个 `.app` 是否完整可用：Info.plist 能读、Bundle ID 在、可执行文件在。
    static func isHealthyBundle(_ app: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        let contents = app.appendingPathComponent("Contents")
        guard let bundleID = plistValue("CFBundleIdentifier", in: app), !bundleID.isEmpty,
              let executable = plistValue("CFBundleExecutable", in: app), !executable.isEmpty else {
            return false
        }
        return FileManager.default.isExecutableFile(
            atPath: contents.appendingPathComponent("MacOS/\(executable)").path
        )
    }

    /// 扫描应用目录，清理（必要时抢救）上一次被中断的安装残留。
    ///
    /// 关键判断：**目标应用是否完好**。
    /// - 目标完好 → 中间态文件都是冗余的，删掉。
    /// - 目标缺失/损坏，但有 `.old.app` → 说明崩溃恰好落在"旧包已挪走、新包未就位"之间，
    ///   把旧包搬回去，用户至少还有能用的应用。
    /// - 目标缺失又没有可用的旧包 → 什么都不删，原样保留并报告，交给人判断。
    @discardableResult
    public static func recoverInterruptedInstalls(
        in roots: [URL] = AppScanner.defaultSearchPaths
    ) -> RecoveryReport {
        let fm = FileManager.default
        var report = RecoveryReport()

        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }

            var grouped: [String: [URL]] = [:]
            for entry in entries {
                guard let parsed = classifyArtifact(entry.lastPathComponent) else { continue }
                grouped[parsed.stem, default: []].append(entry)
            }

            for (stem, artifacts) in grouped {
                let target = root.appendingPathComponent("\(stem).app", isDirectory: true)

                if !isHealthyBundle(target) {
                    let rescueSource = artifacts.first {
                        classifyArtifact($0.lastPathComponent)?.kind == .displaced && isHealthyBundle($0)
                    }

                    guard let rescueSource else {
                        report.needsAttention.append(
                            "\(target.path) 缺失或损坏，残留文件已保留待人工确认：" +
                            artifacts.map(\.lastPathComponent).joined(separator: "、")
                        )
                        continue
                    }

                    if fm.fileExists(atPath: target.path) {
                        try? fm.removeItem(at: target)
                    }
                    if (try? fm.moveItem(at: rescueSource, to: target)) != nil {
                        report.rescuedApps.append(stem)
                    } else {
                        report.needsAttention.append(
                            "\(target.path) 恢复失败，旧版仍保留在 \(rescueSource.path)"
                        )
                        continue
                    }

                    for artifact in artifacts where artifact != rescueSource {
                        if (try? fm.removeItem(at: artifact)) != nil {
                            report.removedArtifacts.append(artifact.lastPathComponent)
                        }
                    }
                    continue
                }

                for artifact in artifacts {
                    if (try? fm.removeItem(at: artifact)) != nil {
                        report.removedArtifacts.append(artifact.lastPathComponent)
                    }
                }
            }
        }

        return report
    }

    /// 清理上次运行留下的工作目录（下载缓存、解包目录）。
    ///
    /// 目录名以创建它的进程 PID 开头：PID 还活着就跳过，因此可以放心地在
    /// 每次安装开始时顺手清一遍，不会误删正在干活的那个。
    @discardableResult
    public static func cleanStaleWorkspaces() -> Int {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
        let workRoot = base.appendingPathComponent("AppUpdater/work", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: workRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for entry in entries {
            let name = entry.lastPathComponent
            if let dash = name.firstIndex(of: "-"),
               let pid = pid_t(name[name.startIndex..<dash]),
               pid != ProcessInfo.processInfo.processIdentifier,
               kill(pid, 0) == 0 {
                continue    // 那个进程还在跑，别动它的目录
            }
            if (try? fm.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}

/// 进度回调限流器。下载进度每秒可能触发上千次，直接转发会把主线程冲垮。
private final class Throttle: @unchecked Sendable {
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
