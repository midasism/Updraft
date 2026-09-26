import CryptoKit
import Foundation

/// 把本应用升级到新版本的执行器。
///
/// 与 `Installer`（给别人家应用升级）的区别只有一处，但那处决定了整个设计：
/// **目标就是正在运行的自己**。所以换包那一步必须交给独立进程，本进程只负责
/// 把一切准备到"两次改名就能完成"的状态，然后退出。
///
/// 分段的含义与 `Installer` 保持一致——"先证明、再动手、留退路"：
///
/// 1. **先证明** —— 下载 → 校验和 → Ed25519 签名 → 解包 → 确认包身份。
///    这一段全程只在自己进程与缓存目录里活动，任何一步不过就地中止，
///    `/Applications` 里一个字节都没变。
/// 2. **再动手** —— 备份旧包 → 把新包预置到目标同目录（同卷，保证 rename 原子）。
/// 3. **交出去** —— 写助手脚本并启动，本进程退出，剩下的两次改名由助手完成。
public struct SelfUpdater: Sendable {
    /// 安装流程的阶段，界面按顺序打勾。
    public enum Phase: String, Sendable, CaseIterable {
        case recovering
        case downloading
        case verifyingChecksum
        case verifyingSignature
        case extracting
        case validating
        case backingUp
        case staging
        case handingOff

        public var title: String {
            switch self {
            case .recovering: return "检查上次中断的残留"
            case .downloading: return "下载新版本"
            case .verifyingChecksum: return "校验安装包完整性"
            case .verifyingSignature: return "校验开发者签名"
            case .extracting: return "解包并确认身份"
            case .validating: return "校验代码签名"
            case .backingUp: return "备份当前版本"
            case .staging: return "预置新版本"
            case .handingOff: return "交接给更新助手"
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
        public var fromVersion: String?
        public var toVersion: String
        public var backupPath: URL?
        public var checksum: ChecksumOutcome = .skipped(reason: "尚未校验")
        public var signature: SignatureVerifier.Outcome = .skipped(reason: "尚未校验")
        /// 一切就绪、应用即将退出并把控制权交给助手。
        public var awaitingRelaunch = false
        public var warnings: [String] = []
        public var error: String?

        public var succeeded: Bool { error == nil }
    }

    /// 预检失败的原因。与"运行中失败"分开：这一类在用户点确认之前就能说清楚。
    public enum Precondition: LocalizedError {
        case notRunningFromBundle
        case cannotReplace(String)
        case insufficientSpace(String)

        public var errorDescription: String? {
            switch self {
            case .notRunningFromBundle:
                return "当前不是从 .app 包里运行的，无法原地替换。请先安装到「应用程序」文件夹。"
            case .cannotReplace(let path):
                return "\(path) 不在可原地替换的位置，无法自动更新。"
            case .insufficientSpace(let detail):
                return detail
            }
        }
    }

    /// 点「立即更新」之前展示给用户的全部事实。
    public struct Plan: Sendable, Equatable {
        public var currentVersion: String
        public var release: SelfUpdateRelease
        public var target: URL
        public var backupLocation: URL
        /// 校验和来源描述，拿不到就是"未提供"。
        public var checksumSource: String
        public var signature: String
        public var warnings: [String]
    }

    private let downloader: PackageDownloader
    private let backups: BackupStore
    private let client: HTTPClient

    public init(
        downloader: PackageDownloader = PackageDownloader(),
        backups: BackupStore = BackupStore(),
        client: HTTPClient = HTTPClient()
    ) {
        self.downloader = downloader
        self.backups = backups
        self.client = client
    }

    // MARK: - 预检

    /// 这个版本现在能不能升。不能就抛出具体原因，界面照原样展示。
    public func makePlan(release: SelfUpdateRelease) throws -> Plan {
        guard let bundle = SelfIdentity.installedBundle else {
            throw Precondition.notRunningFromBundle
        }
        guard SelfIdentity.canReplace(bundle) else {
            throw Precondition.cannotReplace(bundle.path)
        }
        let current = SelfIdentity.currentVersion ?? "未知"

        // 磁盘要求：下载的包 + 解包副本 + 预置副本。三者都要同时存在。
        let sizeHint = release.size ?? 0
        let required = sizeHint * 3 + 300_000_000
        if let available = Installer.availableBytes(at: bundle.deletingLastPathComponent()),
           available < required {
            throw Precondition.insufficientSpace(
                "磁盘空间不足：需要约 \(AppUpdate.formatBytes(required))，当前可用 \(AppUpdate.formatBytes(available))"
            )
        }

        var warnings: [String] = []
        if release.checksumURL == nil && release.apiDigest == nil {
            warnings.append("该 Release 没有提供校验和，只能依赖代码签名与包身份校验")
        }
        if SelfIdentity.publicEDKey == nil {
            warnings.append("本应用没有公布签名公钥，无法确认安装包是否出自官方")
        } else if release.signatureURL == nil {
            warnings.append("该 Release 没有附带签名文件，本次跳过密码学校验")
        }

        return Plan(
            currentVersion: current,
            release: release,
            target: bundle,
            backupLocation: backups.root
                .appendingPathComponent(BackupStore.sanitized(SelfIdentity.bundleIdentifier), isDirectory: true),
            checksumSource: release.checksumURL != nil
                ? "SHA256SUMS.txt"
                : (release.apiDigest != nil ? "GitHub 接口提供的摘要" : "未提供"),
            signature: SelfIdentity.publicEDKey == nil ? "未公布公钥，无法校验" : "Ed25519 签名",
            warnings: warnings
        )
    }

    // MARK: - 执行

    /// 走完整条链路，成功时返回一个"即将退出"的报告。
    ///
    /// **这个方法返回之后不代表已经升级完成**——真正换包发生在助手进程里。
    /// 调用方拿到 `awaitingRelaunch == true` 就该提示用户并退出应用。
    public func install(
        release: SelfUpdateRelease,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async -> Report {
        var report = Report(fromVersion: SelfIdentity.currentVersion, toVersion: release.version)

        @Sendable func emit(_ phase: Phase, _ detail: String, fraction: Double? = nil) {
            onProgress(Progress(phase: phase, detail: detail, fraction: fraction))
        }

        let plan: Plan
        do {
            plan = try makePlan(release: release)
        } catch {
            report.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return report
        }

        // 助手需要知道新包的可执行文件名——它是"包是否完整"的复核依据。
        guard let executable = PackageExtractor.plistValue("CFBundleExecutable", in: plan.target), !executable.isEmpty else {
            report.error = "读不到当前应用的 CFBundleExecutable，无法安全替换"
            return report
        }

        let handoff = SelfUpdateHandoff(target: plan.target)
        var workspace: URL?

        do {
            // ── 阶段零：收拾上次的残局 ──
            emit(.recovering, "清理上次中断留下的残留…")
            Installer.cleanStaleWorkspaces()
            let recovery = Installer.recoverInterruptedInstalls()
            if !recovery.isEmpty {
                report.warnings.append(recovery.summary)
            }
            SelfUpdateHandoff.cleanUpArtifacts()
            if FileManager.default.fileExists(atPath: handoff.staged.path) {
                // 上一次预置了一半就被强杀。目标是完好的，这份冗余副本直接清掉重来。
                try? FileManager.default.removeItem(at: handoff.staged)
            }

            let work = try Installer.makeWorkspace()
            workspace = work

            // ── 阶段一：下载 ──
            let packageURL = work.appendingPathComponent("package.\(release.packageKind.rawValue)")
            emit(.downloading, "连接 \(release.sourceHost ?? "更新源")…")
            let throttle = Throttle(interval: 0.1)
            try await downloader.download(from: release.downloadURL, to: packageURL) { received, total in
                guard received == total || throttle.shouldEmit() else { return }
                let fraction = total > 0 ? Double(received) / Double(total) : nil
                let text = total > 0
                    ? "\(AppUpdate.formatBytes(received)) / \(AppUpdate.formatBytes(total))"
                    : AppUpdate.formatBytes(received)
                emit(.downloading, text, fraction: fraction)
            }
            emit(.downloading, "已下载 \(AppUpdate.formatBytes(Installer.fileSize(packageURL) ?? 0))", fraction: 1)

            // ── 阶段二：校验和 ──
            emit(.verifyingChecksum, "正在核对安装包完整性…")
            let checksum = await verifyChecksum(of: packageURL, release: release)
            report.checksum = checksum
            if case .failed(let reason) = checksum {
                throw SelfUpdateError.checksumRejected(reason)
            }

            // ── 阶段三：签名 ──
            let signature = await verifySignature(of: packageURL, release: release)
            report.signature = signature
            if case .failed(let reason) = signature {
                throw SelfUpdateError.signatureRejected(reason)
            }

            // ── 阶段四：解包 ──
            emit(.extracting, "正在解包 \(release.packageKind.displayName)…")
            let stagedApp = try await PackageExtractor.stageApp(
                package: packageURL,
                kind: release.packageKind,
                bundleID: SelfIdentity.bundleIdentifier,
                in: work
            )

            // ── 阶段五：确认包身份 + 代码签名 ──
            emit(.validating, "正在确认包身份…")
            let newVersion = try await validate(stagedApp: stagedApp, advertised: release.version, warnings: &report.warnings)

            // ── 阶段六：备份 ──
            emit(.backingUp, "正在备份当前版本 \(report.fromVersion ?? "")…")
            do {
                report.backupPath = try await backups.backup(
                    appAt: plan.target,
                    name: plan.target.deletingPathExtension().lastPathComponent,
                    version: report.fromVersion,
                    bundleID: SelfIdentity.bundleIdentifier
                )
            } catch {
                throw SelfUpdateError.backupFailed(error.localizedDescription)
            }

            // ── 阶段七：预置新包（同卷，保证助手那两次 rename 是原子的）──
            emit(.staging, "正在把新版本复制到 \(plan.target.deletingLastPathComponent().path)…")
            let copy = await ProcessRunner.run(
                executable: "/usr/bin/ditto",
                arguments: [stagedApp.path, handoff.staged.path],
                timeout: ProcessRunner.largeCopyTimeout
            )
            guard copy.succeeded else {
                throw SelfUpdateError.stagingFailed(copy.stderr.isEmpty ? copy.stdout : copy.stderr)
            }

            // ── 阶段八：交接 ──
            emit(.handingOff, "正在启动更新助手…")
            try handoff.markHandedOff(from: report.fromVersion, to: newVersion, backupPath: report.backupPath)
            do {
                try handoff.launch(
                    executableName: executable,
                    from: report.fromVersion,
                    to: newVersion,
                    backupPath: report.backupPath
                )
            } catch {
                try? FileManager.default.removeItem(at: handoff.staged)
                throw SelfUpdateError.handoffFailed(error.localizedDescription)
            }

            report.awaitingRelaunch = true
            backups.prune(bundleID: SelfIdentity.bundleIdentifier)
        } catch {
            report.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
        return report
    }

    // MARK: - 校验

    public enum SelfUpdateError: LocalizedError {
        case checksumRejected(String)
        case signatureRejected(String)
        case validationFailed(String)
        case backupFailed(String)
        case stagingFailed(String)
        case handoffFailed(String)
        case downloadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .checksumRejected(let reason): return "完整性校验未通过：\(reason)"
            case .signatureRejected(let reason): return "签名校验未通过：\(reason)"
            case .validationFailed(let reason): return "安装包校验未通过：\(reason)"
            case .backupFailed(let reason): return "备份失败：\(reason)"
            case .stagingFailed(let reason): return "预置新版本失败：\(reason)"
            case .handoffFailed(let reason): return "启动更新助手失败：\(reason)"
            case .downloadFailed(let reason): return "下载失败：\(reason)"
            }
        }
    }

    /// 校验和。优先对 Release 里的 `SHA256SUMS.txt`，拿不到才退回 API 自带的摘要。
    ///
    /// 用校验和文件而不是只用 API 摘要有两个原因：一是这条路径和 README 里那条
    /// `curl | sh` 安装命令**验的是同一个值**，两个入口的信任依据不该分叉；
    /// 二是摘要文件里是裸文件名，用户可以自己下载下来手算一遍复核。
    func verifyChecksum(of package: URL, release: SelfUpdateRelease) async -> ChecksumOutcome {
        guard let actual = SelfUpdater.sha256Hex(ofFileAt: package) else {
            return .skipped(reason: "安装包无法读取，跳过完整性校验")
        }
        var sumsText: String?
        if let checksumURL = release.checksumURL {
            sumsText = try? await client.string(from: checksumURL)
        }
        return SelfUpdater.evaluateChecksum(actual: actual, release: release, sumsText: sumsText)
    }

    /// 校验和的判定逻辑，不含网络。
    ///
    /// 与取数据的部分分开，是为了能把四种结局（一致 / 不一致 / 文件里没有这一行 / 压根没提供）
    /// 都测到——这些分支恰恰是"网络一切正常"时最不容易被发现的那部分。
    static func evaluateChecksum(actual: String, release: SelfUpdateRelease, sumsText: String?) -> ChecksumOutcome {
        // 1. 首选 Release 里的 SHA256SUMS.txt：它和 README 里那条 `curl | sh`
        //    安装命令验的是同一个值，两个入口的信任依据不该分叉。
        if let sumsText {
            let sums = SelfUpdateChecker.parseChecksums(sumsText)
            if let expected = sums[release.assetName] {
                return expected == actual
                    ? .verified(source: "SHA256SUMS.txt")
                    : .failed(reason: "与 SHA256SUMS.txt 记录的摘要不一致")
            }
            // 摘要文件在，却没有这个包对应的行：继续往下试 API 摘要，别急着下结论。
        }

        // 2. 退回 GitHub API 自带的摘要。2025 年起这个字段才有，所以是兜底而不是主路径。
        if let digest = release.apiDigest?.lowercased(), digest.hasPrefix("sha256:") {
            let expected = String(digest.dropFirst("sha256:".count))
            return expected == actual
                ? .verified(source: "GitHub 接口摘要")
                : .failed(reason: "与 GitHub 记录的摘要不一致")
        }

        return .skipped(reason: sumsText != nil
            ? "SHA256SUMS.txt 里没有 \(release.assetName)，接口也没提供摘要"
            : "该 Release 未提供校验和")
    }

    /// Ed25519 签名。没有公钥或没有签名文件就是"未校验"，不是失败——
    /// 但**有签名却对不上**必须中止。
    func verifySignature(of package: URL, release: SelfUpdateRelease) async -> SignatureVerifier.Outcome {
        guard let publicKey = SelfIdentity.publicEDKey else {
            return .skipped(reason: "本应用未公布签名公钥")
        }
        guard let signatureURL = release.signatureURL else {
            return .skipped(reason: "该 Release 未附带签名文件")
        }
        guard let signature = try? await client.string(from: signatureURL) else {
            return .skipped(reason: "签名文件下载失败")
        }
        return SignatureVerifier.verify(
            fileAt: package,
            signatureBase64: signature,
            publicKeyBase64: publicKey
        )
    }

    /// 确认解包出来的确实是"比当前版本更新的、同一个应用的、签名有效的包"。
    ///
    /// - Returns: 新包内 `Info.plist` 声明的版本号（以包内为准，不是 Release 的宣称）。
    private func validate(stagedApp: URL, advertised: String, warnings: inout [String]) async throws -> String {
        guard let stagedBundleID = PackageExtractor.bundleIdentifier(of: stagedApp),
              stagedBundleID == SelfIdentity.bundleIdentifier else {
            throw SelfUpdateError.validationFailed(
                "安装包的 Bundle ID 是 \(PackageExtractor.bundleIdentifier(of: stagedApp) ?? "空")，不是本应用"
            )
        }

        let stagedVersion = PackageExtractor.plistValue("CFBundleShortVersionString", in: stagedApp) ?? advertised
        if let current = SelfIdentity.currentVersion, !current.isEmpty {
            guard Version(stagedVersion) > Version(current) else {
                throw SelfUpdateError.validationFailed("安装包版本 \(stagedVersion) 不高于当前版本 \(current)")
            }
        }
        if Version(stagedVersion) != Version(advertised) {
            warnings.append("包内版本 \(stagedVersion) 与 Release 宣称的 \(advertised) 不一致")
        }

        guard let bundle = SelfIdentity.installedBundle else {
            throw SelfUpdateError.validationFailed("当前运行位置不是 .app 包")
        }

        // 代码签名：先严格，严格不过退普通（Electron 之外的包一般都能过严格模式）。
        let strict = await Installer.verifyCodeSignature(stagedApp, deep: true)
        if !strict.ok {
            let plain = await Installer.verifyCodeSignature(stagedApp, deep: false)
            guard plain.ok else {
                throw SelfUpdateError.validationFailed("代码签名无效：\(strict.detail)")
            }
            warnings.append("严格代码签名校验未通过，已退到普通校验（包完整性仍然有效）")
        }

        // 签名主体一致性：换了个开发者签名要拦下来。
        let previous = await Installer.signingIdentity(of: bundle)
        let incoming = await Installer.signingIdentity(of: stagedApp)
        if let oldTeam = previous.teamID, !oldTeam.isEmpty, incoming.teamID != oldTeam {
            throw SelfUpdateError.validationFailed("签名主体发生变化（\(oldTeam) → \(incoming.teamID ?? "无")）")
        }

        return stagedVersion
    }

    /// 文件的 SHA-256，十六进制小写。
    static func sha256Hex(ofFileAt url: URL) -> String? {
        // 用 `.mappedIfSafe` 映射而不是整个读进内存——本应用的包不大，
        // 但这段代码没有任何理由对体积做假设。
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 进度回调限流器。与 `Installer` 里那份同构——下载进度每秒可能触发上千次。
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
