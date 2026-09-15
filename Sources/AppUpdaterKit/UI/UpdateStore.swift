import AppKit
import Foundation

/// 界面唯一状态源。所有网络、进程与文件操作的结果都收敛到这里。
@MainActor
public final class UpdateStore: ObservableObject {
    @Published public private(set) var updates: [AppUpdate] = []
    @Published public private(set) var isChecking = false
    /// 正在做增量刷新。与 `isChecking`（全量扫描）区分开：前者只重查少数几个应用，
    /// 界面上的文案与按钮禁用都该按这个区别来。
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastChecked: Date?
    @Published public private(set) var statusMessage = ""
    /// Homebrew 索引的读取状态。`nil` 表示一切正常；否则界面上要展示这条提示。
    @Published public private(set) var brewNotice: String?

    /// 当前展示的是上一次的缓存结果（冷启动时先渲染，再后台刷新）。
    @Published public private(set) var isShowingCachedResult = false

    /// 当前升级任务。非 nil 时弹出任务面板。
    @Published public var job: UpgradeJob?

    /// 最近一次增量刷新的规模与耗时。
    ///
    /// 界面上不展示，但"升级收尾只重查了 1 项"这句话必须是可测量的——
    /// 真机验证、日志和回归都靠它，而不是靠读代码相信。
    public struct RefreshStat: Sendable {
        /// 本次被重新检查的条目数。
        public let targets: Int
        /// 刷新完成时列表的总条目数。
        public let listSize: Int
        /// 其中包已不在原路径、只能如实上报的条目数。
        public let missing: Int
        public let seconds: Double
    }

    @Published public private(set) var lastRefresh: RefreshStat?

    /// 上次运行被中断留下的残留被处理过，需要让用户知道。
    @Published public private(set) var recoveryNotice: String?

    /// 本工具自更新。不混进主应用列表，单独一条状态。
    @Published public private(set) var selfStatus: SelfUpdateStatus?
    @Published public private(set) var isCheckingSelf = false
    @Published public var isSelfUpdatePresented = false
    @Published public private(set) var selfInstallProgress: Installer.Progress?
    @Published public private(set) var selfInstallReport: Installer.Report?
    @Published public private(set) var isInstallingSelf = false

    private let cache: StateCache
    /// 检查引擎。全量扫描与增量刷新共用同一个——两条路径都不该有第二套探测逻辑。
    private let engine: CheckEngine
    private let installer = Installer()
    private let backups = BackupStore()
    private var didRunRecovery = false
    private var selfCheckTask: Task<SelfUpdateStatus, Never>?

    /// 上一次全量检查用过的 brew 索引。
    ///
    /// 索引只在 brew 安装/卸载 cask 时才会变，而升级应用不会——所以增量刷新直接复用它，
    /// 省掉 `brew list` + `brew info --json=v2` 这一整轮（cask 多的时候是最贵的一笔）。
    private var caskIndex: BrewCaskIndex?
    private var lastFullCheckAt: Date?
    /// 上一次全量检查开始的时刻：每日去重按它归属哪一天，不按跨午夜后的完成时间。
    public private(set) var lastCheckStartedAt: Date?

    public convenience init() {
        self.init(engine: CheckEngine(), cache: StateCache())
    }

    /// 供测试注入假探针与临时缓存文件用。
    init(engine: CheckEngine, cache: StateCache) {
        self.engine = engine
        self.cache = cache

        if let snapshot = cache.load() {
            updates = SelfUpdateIdentity.excludingSelf(snapshot.updates)
            // 增量刷新会把 savedAt 推到现在，但只有部分条目真的被重查过；
            // 所以"上次检查"取全量时间，取不到（旧版缓存）才退回 savedAt。
            lastFullCheckAt = snapshot.lastFullCheckAt ?? snapshot.savedAt
            lastChecked = lastFullCheckAt
            // 旧版缓存没有 startedAt，只能退回完成时间；写下一次全量检查后会自动补齐。
            lastCheckStartedAt = snapshot.lastFullCheckStartedAt ?? lastFullCheckAt
            isShowingCachedResult = true
        }
    }

    /// 全量扫描或增量刷新是否正在进行。两者都会改 `updates`，不能并发。
    public var isBusy: Bool { isChecking || isRefreshing }

    /// 当前是否禁止开始新的检查。
    ///
    /// 安装期间扫描会读到换包中间态；若它一直跑到升级收尾，`refreshTouchedApps()` 又会因
    /// `isBusy` 拒绝增量刷新，最终可能把安装前结论写成最终缓存。检查和任何安装必须互斥。
    public var isCheckBlocked: Bool {
        isBusy || job?.isRunning == true || isInstallingSelf
    }

    // MARK: - 派生数据

    public func updates(in group: UpdateGroup) -> [AppUpdate] {
        updates.filter { $0.group == group }
    }

    public var updateCount: Int { updates(in: .updateAvailable).count }
    public var upToDateCount: Int { updates(in: .upToDate).count }
    public var unsupportedCount: Int { updates(in: .unsupported).count }

    /// 能由本工具自己走完安装的条目数，决定「全部升级」按钮是否出现。
    public var automatedUpdateCount: Int {
        updates(in: .updateAvailable).filter { $0.installAction.isAutomated }.count
    }

    public var lastCheckedText: String {
        guard let lastChecked else { return "尚未检查" }
        let elapsed = Date().timeIntervalSince(lastChecked)
        if elapsed < 60 { return "刚刚检查" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前检查" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600)) 小时前检查" }
        return "\(Int(elapsed / 86_400)) 天前检查"
    }

    /// 备份占用的磁盘空间说明。
    public func backupUsageText() -> String {
        let size = backups.totalSize()
        guard size > 0 else { return "暂无备份" }
        return AppUpdate.formatBytes(size)
    }

    // MARK: - 检查

    public func checkIfNeeded() async {
        runStartupRecovery()
        // 自更新与主应用检查互不依赖，并行跑；等两边都收尾后再让上层启动定时器，
        // 避免冷启动检查与「错过时段补查」同时抢跑。
        async let selfUpdate: Void = checkSelfUpdate()
        if updates.isEmpty { await check() }
        _ = await selfUpdate
    }

    /// 启动时收拾上一次的残局。
    ///
    /// 换包流程中间被强杀（比如强制退出、断电）会在 `/Applications` 里留下隐藏的
    /// 中间态文件；最坏情况下应用本身停在一个不完整的状态里。这件事必须在用户
    /// 打开窗口时就被发现并告知，而不是悄悄留着。
    public func runStartupRecovery() {
        guard !didRunRecovery else { return }
        didRunRecovery = true

        Installer.cleanStaleWorkspaces()
        let report = Installer.recoverInterruptedInstalls()
        guard !report.isEmpty else { return }
        recoveryNotice = report.summary
    }

    public func dismissRecoveryNotice() {
        recoveryNotice = nil
    }

    public func check() async {
        guard !isCheckBlocked else { return }
        let startedAt = Date()
        isChecking = true
        statusMessage = "正在读取 Homebrew 索引…"
        isShowingCachedResult = false

        let outcome = await BrewService.loadIndex()
        brewNotice = outcome.status.notice
        let index = outcome.index
        caskIndex = index

        statusMessage = "正在扫描应用…"
        let scanned = await Task.detached { AppScanner().scan() }.value
        let classifier = AppClassifier(caskIndex: index)
        var apps = SelfUpdateIdentity.excludingSelf(scanned.map { classifier.classify($0) })

        // 纯命令行 cask（如 ngrok）没有 .app 包，扫描不到，单独补成一条。
        if let index {
            let knownTokens = Set(apps.compactMap { app -> String? in
                if case .homebrewCask(let token) = app.source { return token }
                return nil
            })
            for (token, version) in index.binaryOnlyTokens where !knownTokens.contains(token) {
                apps.append(.commandLineCask(token: token, installedVersion: version))
            }
        }

        let detectable = apps.filter { $0.source.isAutoDetectable }.count
        statusMessage = "正在查询 \(detectable) 个应用的更新…"

        let results = await engine.check(apps: apps) { [weak self] done, total in
            Task { @MainActor in
                guard let self else { return }
                self.statusMessage = "正在查询更新… \(done)/\(total)"
            }
        }

        updates = results
        lastChecked = Date()
        lastFullCheckAt = lastChecked
        lastCheckStartedAt = startedAt
        statusMessage = ""
        isChecking = false
        saveCache()
    }

    // MARK: - 增量刷新

    /// 只重新检查 `ids` 指定的应用，不做全量扫描。
    ///
    /// 升级完一个应用之后调它，替代过去的"整机重扫一遍"：
    /// 不重建 brew 索引、不遍历 `/Applications`、不对其余几十个应用再发一轮请求。
    /// 本机实测全量约 10 秒，增量通常在 1 秒内结束。
    ///
    /// 没被点到的条目一律保持原样——它们没有任何理由因为别的应用升级而失去可信度。
    ///
    /// - Returns: `false` 表示当前正忙（全量扫描或另一次刷新在跑），调用方应稍后再试。
    @discardableResult
    public func refresh(ids: Set<String>) async -> Bool {
        guard !isBusy else { return false }

        let targets = updates.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return true }

        isRefreshing = true
        // 复用上一次全量检查的索引；没有（冷启动走缓存、或本机没装 Homebrew）就交给
        // IncrementalChecker 沿用旧来源判定，绝不为了这一刻再去跑一遍 brew info。
        let index = caskIndex
        statusMessage = targets.count == 1
            ? "正在更新 \(targets[0].app.name) 的检查结果…"
            : "正在更新 \(targets.count) 个应用的检查结果…"

        let started = Date()
        let report = await IncrementalChecker(engine: engine).refresh(targets: targets, caskIndex: index) { done, total in
            // 只有一个应用时进度条没有意义，保持上面那句"正在更新 X"更好读。
            guard total > 1 else { return }
            Task { @MainActor [weak self] in
                // 进度回调是异步投递的，收尾之后才轮到也是可能的；此时不该再往回写状态。
                guard let self, self.isRefreshing else { return }
                self.statusMessage = "正在重新检查… \(done)/\(total)"
            }
        }

        updates = IncrementalChecker.merge(report.all, into: updates)
        lastRefresh = RefreshStat(
            targets: targets.count,
            listSize: updates.count,
            missing: report.missing.count,
            seconds: Date().timeIntervalSince(started)
        )
        statusMessage = ""
        isRefreshing = false
        saveCache()
        return true
    }

    private func saveCache() {
        cache.save(.init(
            updates: updates,
            savedAt: Date(),
            lastFullCheckAt: lastFullCheckAt,
            lastFullCheckStartedAt: lastCheckStartedAt
        ))
    }

    // MARK: - 升级任务的编排

    /// 单个应用的升级。只有能自动完成的动作才建任务，其余走 `openDownload`。
    public func requestUpgrade(_ update: AppUpdate) {
        guard job?.isRunning != true else { return }
        guard let item = makeItem(from: update), item.isAutomated else {
            openDownload(for: update)
            return
        }
        job = UpgradeJob(items: [item])
    }

    /// 全部升级：把所有能自动完成的条目合成一个任务，顺序执行。
    public func requestUpgradeAll() {
        guard job?.isRunning != true else { return }
        let items = updates(in: .updateAvailable)
            .compactMap { makeItem(from: $0) }
            .filter(\.isAutomated)
        guard !items.isEmpty else { return }
        job = UpgradeJob(items: items)
    }

    private func makeItem(from update: AppUpdate) -> UpgradeJob.Item? {
        guard let release = update.result.release else { return nil }
        let action = update.installAction
        guard action != .manual else { return nil }
        let plan = action == .replaceBundle ? installer.makePlan(app: update.app, release: release) : nil
        return UpgradeJob.Item(app: update.app, release: release, action: action, plan: plan)
    }

    /// 开始执行任务。串行跑完所有条目，单个失败不影响后续。
    ///
    /// 取消的语义是「当前这一项做完就停」：只在条目边界检查取消标志。
    /// 中途打断原子换包会留下"旧包已挪走、新包未就位"的中间态，不值得为省几秒钟去冒。
    public func runJob() async {
        guard var working = job, !working.isRunning else { return }
        working.isRunning = true
        job = working

        var cancelledAt: Int?

        for index in working.items.indices {
            guard var current = job, current.isRunning, index < current.items.count else { return }

            if current.cancelRequested {
                cancelledAt = index
                break
            }

            current.currentIndex = index
            current.phase = nil
            current.runningLog = ""
            current.items[index].state = .running
            job = current

            let item = current.items[index]
            let outcome: UpgradeJob.Outcome

            switch item.action {
            case .homebrew(let token):
                outcome = await runBrew(item: item, token: token)
            case .replaceBundle:
                outcome = await runInstall(item: item)
            default:
                outcome = UpgradeJob.Outcome(
                    id: item.id,
                    appName: item.app.name,
                    fromVersion: item.app.currentVersion,
                    toVersion: item.release.version,
                    succeeded: false,
                    summary: "需要手动完成（\(item.action.buttonTitle)）",
                    backupPath: nil,
                    rolledBack: false,
                    warnings: [],
                    log: ""
                )
            }

            guard var updated = job else { return }
            updated.outcomes.append(outcome)
            updated.items[index].state = outcome.succeeded ? .succeeded : .failed(outcome.summary)
            updated.phase = nil
            job = updated
        }

        finish(cancellingFrom: cancelledAt)
        await refreshTouchedApps()
    }

    /// 请求取消。
    ///
    /// 不做"立即中断"：原子换包被打断的话，目标应用会停在"旧包已挪走、新包未就位"
    /// 的中间态，比多等几秒糟糕得多。置位之后面板会明确显示「将在当前应用完成后停止」，
    /// 用户不必再盯着一个看起来不动的进度条。
    public func cancelJob() {
        guard var working = job, working.isRunning, !working.cancelRequested else { return }
        working.cancelRequested = true
        job = working
    }

    /// 收尾：把还没处理的条目按「已取消」补齐，然后把任务置为已结束。
    private func finish(cancellingFrom index: Int?) {
        guard var working = job else { return }
        if let index {
            working.outcomes.append(contentsOf: working.cancelRemaining(from: index))
        }
        working.isRunning = false
        working.isFinished = true
        working.phase = nil
        job = working
    }

    /// 只重查刚刚动过的那些应用，而不是整机重扫一遍。
    ///
    /// 这里过去是 `await check()`：重建 brew 索引 + 遍历 /Applications + 对四十多个
    /// 应用重新发一轮网络请求，用户只能干等；结果里真正会变的往往只有刚才升级的那一个，
    /// 其余几十条的答案是白问的。
    private func refreshTouchedApps() async {
        guard let job else { return }
        await refresh(ids: Set(job.items.map(\.app.id)))
    }

    /// 关闭任务面板。结果会保留到下次打开。
    public func dismissJob() {
        guard job?.isRunning != true else { return }
        job = nil
    }

    private func runBrew(item: UpgradeJob.Item, token: String) async -> UpgradeJob.Outcome {
        var log = "$ brew upgrade --cask \(token)\n\n"
        job?.runningLog = log

        var succeeded = false
        for await chunk in BrewService.upgradeStream(token: token) {
            log += chunk
            job?.runningLog = log
        }
        // ProcessRunner.stream 在结束时补一行退出状态，据此判断结果。
        succeeded = log.contains("✔ 完成")

        return UpgradeJob.Outcome(
            id: item.id,
            appName: item.app.name,
            fromVersion: item.app.currentVersion,
            toVersion: item.release.version,
            succeeded: succeeded,
            summary: succeeded ? "已升级到 \(item.release.version)" : "brew 升级失败",
            backupPath: nil,
            rolledBack: false,
            warnings: [],
            log: log
        )
    }

    private func runInstall(item: UpgradeJob.Item) async -> UpgradeJob.Outcome {
        var log = ""
        let report = await installer.install(app: item.app, release: item.release) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, var working = self.job else { return }
                working.phase = progress
                let line = "\(progress.phase.title) — \(progress.detail)"
                working.runningLog = working.runningLog.isEmpty ? line : working.runningLog + "\n" + line
                self.job = working
            }
        }

        log = job?.runningLog ?? ""

        if let error = report.error {
            return UpgradeJob.Outcome(
                id: item.id,
                appName: item.app.name,
                fromVersion: report.fromVersion,
                toVersion: report.toVersion,
                succeeded: false,
                summary: error,
                backupPath: report.backupPath,
                rolledBack: report.rolledBack,
                warnings: report.warnings,
                log: log
            )
        }

        return UpgradeJob.Outcome(
            id: item.id,
            appName: item.app.name,
            fromVersion: report.fromVersion,
            toVersion: report.toVersion,
            succeeded: true,
            summary: "已升级到 \(report.toVersion) · \(report.signature.summary)",
            backupPath: report.backupPath,
            rolledBack: false,
            warnings: report.warnings,
            log: log
        )
    }

    // MARK: - 跳转类动作

    public func openDownload(for update: AppUpdate) {
        guard let release = update.result.release else { return }
        switch update.installAction {
        case .openInstaller:
            // .pkg 需要管理员密码，交给系统安装器，我们把下载好的包交到它手上。
            if let url = release.downloadURL {
                NSWorkspace.shared.open(url)
            } else if let notes = release.releaseNotesURL {
                NSWorkspace.shared.open(notes)
            }
        default:
            if let url = release.downloadURL {
                NSWorkspace.shared.open(url)
            } else if let notes = release.releaseNotesURL {
                NSWorkspace.shared.open(notes)
            }
        }
    }

    public func reveal(_ app: AppInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([app.path])
    }

    public func revealBackup(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func openReleaseNotes(_ update: AppUpdate) {
        guard let url = update.result.release?.releaseNotesURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 本工具自更新

    /// 查 GitHub Releases。失败只记在 `selfStatus` 里，不影响主列表。
    public func checkSelfUpdate() async {
        guard !isInstallingSelf else { return }
        if let selfCheckTask {
            selfStatus = await selfCheckTask.value
            return
        }

        isCheckingSelf = true
        let task = Task { await SelfUpdateChecker().check() }
        selfCheckTask = task
        let status = await task.value
        selfCheckTask = nil
        selfStatus = status
        isCheckingSelf = false
    }

    public func presentSelfUpdate() {
        isSelfUpdatePresented = true
        selfInstallProgress = nil
        selfInstallReport = nil
        if selfStatus == nil, !isCheckingSelf {
            Task { await checkSelfUpdate() }
        }
    }

    public func dismissSelfUpdate() {
        guard !isInstallingSelf else { return }
        isSelfUpdatePresented = false
    }

    /// 下载 → 验签 → 换自己 → 拉起新实例。成功后由界面退出当前进程。
    public func installSelfUpdate() async {
        guard !isInstallingSelf else { return }
        guard case .updateAvailable(let release) = selfStatus else { return }
        guard let target = SelfUpdateIdentity.installTargetURL(), AppUpdate.isReplaceable(target) else {
            selfInstallReport = failureReport("找不到可替换的 AppUpdater.app（需要装在 /Applications 或 ~/Applications）")
            return
        }

        isInstallingSelf = true
        selfInstallProgress = nil
        selfInstallReport = nil

        let current = SelfUpdateIdentity.currentShortVersion
            ?? Installer.plistValue("CFBundleShortVersionString", in: target)
        let app = SelfUpdateIdentity.makeAppInfo(at: target, version: current)
        let report = await installer.install(
            app: app,
            release: release.releaseInfo,
            options: .selfUpdate(
                manifestBytes: release.manifestBytes,
                manifestSignature: release.manifestSignature,
                publicKey: SelfUpdateIdentity.publicEDKey
            )
        ) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.selfInstallProgress = progress
            }
        }

        selfInstallReport = report
        isInstallingSelf = false

        if report.succeeded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.terminate(nil)
            }
        }
    }

    public func selfUpdatePlan() -> Installer.Plan? {
        guard case .updateAvailable(let release) = selfStatus,
              let target = SelfUpdateIdentity.installTargetURL() else { return nil }
        let current = SelfUpdateIdentity.currentShortVersion
            ?? Installer.plistValue("CFBundleShortVersionString", in: target)
        let app = SelfUpdateIdentity.makeAppInfo(at: target, version: current)
        return installer.makePlan(app: app, release: release.releaseInfo)
    }

    private func failureReport(_ reason: String) -> Installer.Report {
        var report = Installer.Report(
            appName: SelfUpdateIdentity.displayName,
            bundleID: SelfUpdateIdentity.bundleID,
            fromVersion: SelfUpdateIdentity.currentShortVersion,
            toVersion: selfStatus?.release?.version ?? "",
            signature: .skipped(reason: "尚未校验")
        )
        report.error = reason
        return report
    }
}
