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
    @Published public private(set) var brewAvailable = true

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

    /// 本应用自身的更新检测结果。nil 表示还没查过。
    ///
    /// 刻意不塞进 `updates` 列表：本应用的更新要"先退出再换包"，与列表里那一套
    /// 一键升级的流程不同源，混在一起会让两条路径的边界变糊。
    @Published public private(set) var selfUpdate: SelfUpdateResult?

    /// 自身更新面板的状态。nil 表示面板关闭。
    @Published public var selfSheet: SelfUpdateSheetState?

    /// 上一次自更新交接的结果（升级成功 / 失败原因），启动时读出来告知用户。
    @Published public private(set) var selfUpdateStatus: SelfUpdateStatus?

    private let cache: StateCache
    /// 检查引擎。全量扫描与增量刷新共用同一个——两条路径都不该有第二套探测逻辑。
    private let engine: CheckEngine
    private let installer = Installer()
    private let backups = BackupStore()
    private var didRunRecovery = false

    /// 「忽略这个版本」的记录。用户决策，独立于检查结果缓存持久化。
    private var ignoredVersions: IgnoredVersions

    private let selfChecker = SelfUpdateChecker()
    private let selfUpdater = SelfUpdater()
    private var didCheckSelf = false

    /// 上一次全量检查用过的 brew 索引。
    ///
    /// 索引只在 brew 安装/卸载 cask 时才会变，而升级应用不会——所以增量刷新直接复用它，
    /// 省掉 `brew list` + `brew info --json=v2` 这一整轮（cask 多的时候是最贵的一笔）。
    private var caskIndex: BrewCaskIndex?
    private var lastFullCheckAt: Date?

    public convenience init() {
        self.init(
            engine: CheckEngine(),
            cache: StateCache(),
            ignored: IgnoredVersions(fileURL: IgnoredVersions.defaultFileURL)
        )
    }

    /// 供测试注入假探针与临时缓存文件用。
    /// `ignored` 缺省为纯内存空记录，测试因此不会读到开发机自己的忽略文件。
    init(engine: CheckEngine, cache: StateCache, ignored: IgnoredVersions? = nil) {
        self.engine = engine
        self.cache = cache
        self.ignoredVersions = ignored ?? IgnoredVersions()

        if let snapshot = cache.load() {
            updates = snapshot.updates
            // 增量刷新会把 savedAt 推到现在，但只有部分条目真的被重查过；
            // 所以"上次检查"取全量时间，取不到（旧版缓存）才退回 savedAt。
            lastFullCheckAt = snapshot.lastFullCheckAt ?? snapshot.savedAt
            lastChecked = lastFullCheckAt
            isShowingCachedResult = true
            // 缓存里的结果不知道记录文件后来发生过什么（比如用户在另一台机器上
            // 升级了应用、上游发了新版本），回放后立刻重新套用一遍忽略判定。
            applyIgnoredVersions()
        }
    }

    /// 全量扫描或增量刷新是否正在进行。两者都会改 `updates`，不能并发。
    public var isBusy: Bool { isChecking || isRefreshing }

    // MARK: - 派生数据

    public func updates(in group: UpdateGroup) -> [AppUpdate] {
        updates.filter { $0.group == group }
    }

    public var updateCount: Int { updates(in: .updateAvailable).count }
    public var upToDateCount: Int { updates(in: .upToDate).count }
    public var unsupportedCount: Int { updates(in: .unsupported).count }
    public var ignoredCount: Int { updates(in: .ignored).count }

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

    // MARK: - 本应用自身的更新

    /// 启动时查一次自己的新版本。有缓存就不打网络。
    public func checkSelfIfNeeded() async {
        guard !didCheckSelf else { return }
        didCheckSelf = true
        await checkSelfUpdate(force: false)
    }

    /// 查自己有没有新版本。菜单里手动触发时传 `force: true` 绕过节流。
    public func checkSelfUpdate(force: Bool) async {
        guard let current = SelfIdentity.currentVersion else {
            // 从源码直接跑（`swift run`）没有 bundle，读不到版本号。如实说明，
            // 而不是拿一个猜的版本号去比对——那会得出"已是最新"这种假结论。
            selfUpdate = .failed(reason: "当前不是从 .app 包里运行的，无法判断自身版本")
            return
        }
        selfUpdate = await selfChecker.check(currentVersion: current, force: force)
    }

    /// 点「更新到 x.y.z」。
    ///
    /// 能原地替换就进确认面板；不能（没装在应用目录、从只读卷运行、拿不到版本号）
    /// 就退到 Release 页面——文案上必须说清是"打不开更新"而不是"没有更新"。
    public func requestSelfUpdate() {
        guard let release = selfUpdate?.release else {
            openReleasePage()
            return
        }
        do {
            selfSheet = .confirming(try selfUpdater.makePlan(release: release))
        } catch {
            selfSheet = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public var isSelfUpdating: Bool {
        if case .running = selfSheet { return true }
        return false
    }

    /// 确认面板上点「立即更新」。
    public func runSelfUpdate() async {
        guard case .confirming(let plan) = selfSheet else { return }
        selfSheet = .running(phase: .recovering, detail: "准备中…", fraction: nil)

        let report = await selfUpdater.install(release: plan.release) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.isSelfUpdating else { return }
                self.selfSheet = .running(
                    phase: progress.phase,
                    detail: progress.detail,
                    fraction: progress.fraction
                )
            }
        }

        if let error = report.error {
            selfSheet = .failed(error)
            return
        }
        guard report.awaitingRelaunch else {
            selfSheet = .failed("更新没有进入交接阶段，请重试")
            return
        }

        selfSheet = .handedOff(from: report.fromVersion, to: report.toVersion)
        // 这一步之前，所有会写磁盘的动作都做完了，助手也已经跑起来在等本进程消失。
        // 留一点时间把"即将退出"显示出来，然后干净退出——进程不退出，整次更新就卡住。
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        NSApp.terminate(nil)
        // 兜底：万一有窗口拦下了终止请求，助手会一直等到 60 秒超时才放弃。
        // 这里没有任何未保存的状态可丢，直接结束进程比让整次更新白跑划算。
        exit(0)
    }

    public func dismissSelfSheet() {
        guard !isSelfUpdating else { return }
        selfSheet = nil
    }

    /// 菜单里「检查更新…」的入口：把当前检测结果原样摊开。
    ///
    /// 与横幅上那个按钮的区别在于**已是最新时也要有反馈**——手动点了一下什么都没发生，
    /// 用户会以为功能坏了。调用方应当先 `checkSelfUpdate(force: true)`。
    public func presentSelfUpdateSheet() {
        switch selfUpdate {
        case .available:
            requestSelfUpdate()
        case .upToDate(let current, let latest):
            selfSheet = .upToDate(current: current, latest: latest)
        case .failed(let reason):
            selfSheet = .failed(reason)
        case nil:
            selfSheet = .failed("还没有拿到版本信息，请稍后重试")
        }
    }

    public func openReleasePage() {
        NSWorkspace.shared.open(selfUpdate?.release?.releaseNotesURL ?? SelfIdentity.releasePage)
    }

    /// 仅供界面离屏快照注入一个合成的检测结果。
    ///
    /// 真实路径上 `selfUpdate` 只由 `checkSelfUpdate` 写入；这个方法存在的理由是
    /// 顶部横幅的排版需要一个确定的输入才能被截出来——靠真网络去撞一个"恰好有新版本"
    /// 的时机，是没法做回归的。
    func injectSelfUpdateForSnapshot(_ result: SelfUpdateResult?) {
        selfUpdate = result
    }

    // MARK: - 忽略版本

    /// 「忽略这个版本 1.4.4」。记录落盘，条目当场移入「已忽略」分组。
    public func ignoreVersion(of update: AppUpdate) {
        guard let release = update.result.release else { return }
        ignoredVersions.ignore(app: update.app, version: release.version)
        ignoredVersions.save()
        applyIgnoredVersions()
    }

    /// 「取消忽略」。移除记录并恢复提示；不重新探测——release 信息是刚才才探到的，
    /// 仍然可信，用户点一下就该立刻看到结果回到「可更新」。
    public func unignoreVersion(of update: AppUpdate) {
        ignoredVersions.remove(app: update.app)
        ignoredVersions.save()
        applyIgnoredVersions()
    }

    /// 把忽略记录套用到当前列表上：该抑制的抑制，该清除的清除。
    ///
    /// 这是唯一的判定收口——全量检查、增量刷新、冷启动回放缓存、用户增删记录
    /// 四条路都经过这里，保证界面上看到的抑制状态与记录文件永远是一套真相。
    private func applyIgnoredVersions() {
        var recordsChanged = false

        updates = updates.map { update in
            guard case .updateAvailable(let release) = update.result else { return update }

            switch ignoredVersions.decide(app: update.app, latestVersion: release.version) {
            case .noRecord:
                guard update.ignoredVersion != nil else { return update }
                var cleared = update
                cleared.ignoredVersion = nil
                return cleared

            case .suppress(let version):
                guard update.ignoredVersion != version else { return update }
                var suppressed = update
                suppressed.ignoredVersion = version
                return suppressed

            case .clear:
                recordsChanged = true
                ignoredVersions.remove(app: update.app)
                var cleared = update
                cleared.ignoredVersion = nil
                return cleared
            }
        }

        if recordsChanged {
            ignoredVersions.save()
        }
        saveCache()
    }

    // MARK: - 检查

    public func checkIfNeeded() async {
        runStartupRecovery()
        if updates.isEmpty { await check() }
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
        if !report.isEmpty {
            recoveryNotice = report.summary
        }

        // 自身更新的交接结果只能落到磁盘上——换包那几步发生在本进程的上一个化身
        // 已经退出之后。这里读一次并消费掉，否则每次启动都会重播一遍。
        SelfUpdateHandoff.cleanUpArtifacts()
        if let status = SelfUpdateHandoff.consumeStatus() {
            selfUpdateStatus = Self.resolve(status)
        }
    }

    /// 助手没来得及回写就退出的极端情况：包已经换了，只是结果没落盘。
    ///
    /// 判据是"当前版本已经等于它要换成的版本"——这比信任一条写着"进行中"的记录准确。
    private static func resolve(_ status: SelfUpdateStatus) -> SelfUpdateStatus? {
        guard status.outcome == .inProgress else { return status }
        guard SelfIdentity.currentVersion == status.toVersion else { return status }
        return SelfUpdateStatus(
            outcome: .succeeded,
            fromVersion: status.fromVersion,
            toVersion: status.toVersion,
            message: "已升级到 \(status.toVersion)",
            backupPath: status.backupPath,
            at: status.at
        )
    }

    public func dismissSelfUpdateStatus() {
        selfUpdateStatus = nil
    }

    public func dismissRecoveryNotice() {
        recoveryNotice = nil
    }

    public func check() async {
        guard !isBusy else { return }
        isChecking = true
        statusMessage = "正在读取 Homebrew 索引…"
        isShowingCachedResult = false

        let index = await BrewService.loadIndex()
        brewAvailable = index != nil
        caskIndex = index

        statusMessage = "正在扫描应用…"
        let scanned = await Task.detached { AppScanner().scan() }.value
        let classifier = AppClassifier(caskIndex: index)
        var apps = scanned.map { classifier.classify($0) }

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
        statusMessage = ""
        isChecking = false
        // 全量检查是发现「出现了高于被忽略版本的新版本」的主要时机，
        // 忽略记录在这里到期清除。收尾的 saveCache 由套用逻辑一并完成。
        applyIgnoredVersions()
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
    /// - Parameters:
    ///   - ids: 要重查的应用 id（`AppUpdate.id`，即包路径）。
    ///   - force: 强制探测，被忽略的条目也不例外。升级收尾的自动刷新传 `false`
    ///     （默认）——上游版本不会因为本机升级了别的应用而改变，被抑制的条目
    ///     重问一轮是白问；将来若给行内加手动「刷新」动作，应传 `true`，
    ///     这样用户才能靠它主动发现高于被忽略版本的新版本。
    /// - Returns: `false` 表示当前正忙（全量扫描或另一次刷新在跑），调用方应稍后再试。
    @discardableResult
    public func refresh(ids: Set<String>, force: Bool = false) async -> Bool {
        guard !isBusy else { return false }

        var targets = updates.filter { ids.contains($0.id) }
        if !force {
            targets.removeAll { $0.ignoredVersion != nil }
        }
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
        applyIgnoredVersions()
        return true
    }

    private func saveCache() {
        cache.save(.init(updates: updates, savedAt: Date(), lastFullCheckAt: lastFullCheckAt))
    }

    // MARK: - 升级任务的编排

    /// 单个应用的升级。只有能自动完成的动作才建任务，其余走 `openDownload`。
    public func requestUpgrade(_ update: AppUpdate) {
        guard job?.isRunning != true else { return }
        // 被忽略的条目不该再走升级：界面不提供按钮，这里兜一道，防程序化误调。
        guard update.ignoredVersion == nil else { return }
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
}

/// 自身更新面板的状态。各态对应面板上完全不同的内容与出口。
public enum SelfUpdateSheetState: Equatable, Sendable, Identifiable {
    /// 动手之前，把所有要发生的事摊开。
    case confirming(SelfUpdater.Plan)
    /// 正在下载/校验/预置。
    case running(phase: SelfUpdater.Phase, detail: String, fraction: Double?)
    /// 交接完成，应用即将退出。此时**已经没有什么可取消的了**——助手已经在跑。
    case handedOff(from: String?, to: String)
    /// 已经是最新。手动检查时必须给这个反馈，否则点了没反应像是坏了。
    case upToDate(current: String, latest: String)
    /// 走不下去，如实说原因，并给一条通往 Release 页面的退路。
    case failed(String)

    /// 所有状态的 id 都是同一个常量。
    ///
    /// 面板是"一整个"而不是"好几个"：状态从确认态走到执行态时，`sheet(item:)`
    /// 若看到 id 变了就会先收起来再弹一次，用户会看到闪一下。共用 id 只更新内容。
    public var id: String { "self-update" }

    public var isConfirming: Bool { if case .confirming = self { return true } else { return false } }
}

