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

    /// 量好的备份占用字节数。`nil` 表示还没量过（界面显示「正在统计…」）。
    ///
    /// 刻意不提供"直接读一下"的同步入口：`BackupStore.totalSize()` 是整树遍历，
    /// 备份动辄上 G、几万个文件，放在主线程上会把界面钉住。
    @Published public private(set) var backupUsage: Int64?
    /// 正在清理备份。要真删几万个文件，界面得能表示"在做事"，也得防重复点。
    @Published public private(set) var isClearingBackups = false

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

    public var lastCheckedText: String {
        guard let lastChecked else { return "尚未检查" }
        let elapsed = Date().timeIntervalSince(lastChecked)
        if elapsed < 60 { return "刚刚检查" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前检查" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600)) 小时前检查" }
        return "\(Int(elapsed / 86_400)) 天前检查"
    }

    /// 备份占用的文案。**纯函数**——真正去量它的是 `refreshBackupUsage()`。
    ///
    /// 做成 `nonisolated static` 有两个理由：能被断言（`backupUsage` 是 `private(set)`，
    /// 测试里造不出那个状态），以及让人没法从这个名字里顺手把 IO 引回主线程。
    public nonisolated static func backupUsageText(bytes: Int64?) -> String {
        guard let bytes else { return "正在统计…" }
        guard bytes > 0 else { return "暂无备份" }
        return AppUpdate.formatBytes(bytes)
    }

    /// 量一次备份占用。整树遍历放到主线程之外。
    public func refreshBackupUsage() async {
        let store = backups
        backupUsage = await Task.detached { store.totalSize() }.value
    }

    /// 清空全部备份。
    ///
    /// **没有撤销**：调这个之前，界面必须已经问过用户了（见 `SettingsView` 的两步确认）。
    /// 这里只负责做事和把量到的占用更新掉。
    @discardableResult
    public func clearBackups() async -> BackupStore.ClearReport {
        guard !isClearingBackups else { return BackupStore.ClearReport(removed: 0, freedBytes: 0) }
        isClearingBackups = true
        let store = backups
        let report = await Task.detached { store.clearAll() }.value
        // 清理后重新量：清完是 0 还是剩了点（删不掉的条目），界面要如实反映，
        // 不能直接把 0 写上去。
        backupUsage = await Task.detached { store.totalSize() }.value
        isClearingBackups = false
        return report
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

    /// 截图通道专用：直接塞一份合成结果，跳过扫描与网络。
    ///
    /// 有些界面状态只在特定机器上碰得到——比如「Homebrew 账本滞后于磁盘」，
    /// 要求那台机器上的某个 cask 恰好被应用自带的更新器升过、而 brew 的记录没跟上。
    /// 一旦账本被修正，真实截图就再也复现不了。截图要能随时重跑并给出同一张图，
    /// 就不能依赖当时那台机器碰巧是什么状态。**不写缓存**，免得污染真实结果。
    func loadSynthetic(updates: [AppUpdate]) {
        let now = Date()
        self.updates = updates
        lastChecked = now
        lastFullCheckAt = now
        lastCheckStartedAt = now
        isShowingCachedResult = false
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

    /// 全部升级：把能自动完成的条目合成一个任务，顺序执行。
    ///
    /// - Parameter visible: 界面当前筛出来的那批。传 nil 表示没有筛选，对全量生效。
    ///   搜索框有词时必须传它——否则用户筛出 1 个再点「升级这 1 个」，
    ///   结果升的是全量二十几个，而他一个都没看见。
    public func requestUpgradeAll(visible: [AppUpdate]? = nil) {
        guard job?.isRunning != true else { return }
        // 守卫判的是 compactMap 之后的结果，而不是它之前的 `candidates`。两者当前
        // 等价（见 automatedCandidates 的说明），但判前者这层就没法被绕过：将来谁
        // 给 InstallAction 加一个 isAutomated 却生成不出 item 的情形，这里会安静地
        // 什么都不做，而不是弹出一个空的升级面板。
        let items = Self.automatedCandidates(in: visible ?? updates).compactMap { makeItem(from: $0) }
        guard !items.isEmpty else { return }
        job = UpgradeJob(items: items)
    }

    /// 从一批条目里挑出本工具能自己走完安装的那些。
    ///
    /// 抽成静态纯函数是为了能被断言：`updates` 是 `private(set)`，且填充它要跑真实
    /// 扫描，测试里造不出来。而「只升传进来的这批」恰恰是最需要守住的边界，
    /// 不能只靠读代码相信。
    ///
    /// `nonisolated` 不是随手加的：这函数只碰自己的入参，不读任何 actor 状态。少了它，
    /// 非 MainActor 的调用方（XCTest 用例、CLI）就没法同步调它，只能加 `await` 或者
    /// 把谓词再抄一遍——两条路都比这行注解糟。
    ///
    /// 返回值全部是 `.updateAvailable`（`installAction` 只在这种情况下才不是 `.manual`），
    /// 所以 `makeItem` 目前不会丢掉其中任何一条。
    public nonisolated static func automatedCandidates(in updates: [AppUpdate]) -> [AppUpdate] {
        updates.filter { $0.installAction.isAutomated }
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
                    fromVersion: item.fromVersion,
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
            fromVersion: item.fromVersion,
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

    /// 下载 → 验签 → 换自己 → 拉起新实例 → 收起面板 → 退出当前进程。
    /// 最后两步不能颠倒，也不能省：新版本没拉起来就不退出（见下）。
    public func installSelfUpdate() async {
        guard !isInstallingSelf else { return }
        guard case .updateAvailable(let release) = selfStatus else { return }
        guard let target = SelfUpdateIdentity.installTargetURL(), AppUpdate.isReplaceable(target) else {
            selfInstallReport = failureReport("找不到可替换的 Updraft.app（需要装在 /Applications 或 ~/Applications）")
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

        guard report.succeeded else { return }

        // 新版本没拉起来就别退出：留在旧进程里至少还有得用，结果页会写明"没能自动打开新版本"。
        guard report.relaunched else { return }

        // 退出之前**必须先收起面板**：sheet 还挂着时 `NSApp.terminate` 是空操作
        // （模态会话把它吞了，既不问 delegate 也不退出），这就是"升级完不自动退出、
        // 得手动关闭才行"的根因。详见 SelfQuit 里的对照表。
        isSelfUpdatePresented = false
        SelfQuit.schedule()
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
