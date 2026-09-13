import AppKit
import Foundation

/// 界面唯一状态源。所有网络、进程与文件操作的结果都收敛到这里。
@MainActor
public final class UpdateStore: ObservableObject {
    @Published public private(set) var updates: [AppUpdate] = []
    @Published public private(set) var isChecking = false
    @Published public private(set) var lastChecked: Date?
    @Published public private(set) var statusMessage = ""
    @Published public private(set) var brewAvailable = true

    /// 当前展示的是上一次的缓存结果（冷启动时先渲染，再后台刷新）。
    @Published public private(set) var isShowingCachedResult = false

    /// 当前升级任务。非 nil 时弹出任务面板。
    @Published public var job: UpgradeJob?

    /// 上次运行被中断留下的残留被处理过，需要让用户知道。
    @Published public private(set) var recoveryNotice: String?

    private let cache = StateCache()
    private let installer = Installer()
    private let backups = BackupStore()
    private var didRunRecovery = false

    public init() {
        if let snapshot = cache.load() {
            updates = snapshot.updates
            lastChecked = snapshot.savedAt
            isShowingCachedResult = true
        }
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
        guard !report.isEmpty else { return }
        recoveryNotice = report.summary
    }

    public func dismissRecoveryNotice() {
        recoveryNotice = nil
    }

    public func check() async {
        guard !isChecking else { return }
        isChecking = true
        statusMessage = "正在读取 Homebrew 索引…"
        isShowingCachedResult = false

        let index = await BrewService.loadIndex()
        brewAvailable = index != nil

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

        let engine = CheckEngine()
        let results = await engine.check(apps: apps) { [weak self] done, total in
            Task { @MainActor in
                guard let self else { return }
                self.statusMessage = "正在查询更新… \(done)/\(total)"
            }
        }

        updates = results
        lastChecked = Date()
        statusMessage = ""
        isChecking = false
        cache.save(.init(updates: results, savedAt: Date()))
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
    public func runJob() async {
        guard var working = job, !working.isRunning else { return }
        working.isRunning = true
        job = working

        for index in working.items.indices {
            guard var current = job, current.isRunning, index < current.items.count else { return }
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

        guard var finished = job else { return }
        finished.isRunning = false
        finished.isFinished = true
        job = finished

        // 升完了立刻重新检查一遍，让数字反映真实状态。
        await check()
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
