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

    @Published public var upgradingToken: String?
    @Published public var logText = ""
    @Published public var isShowingLog = false

    private let cache = StateCache()

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

    public var lastCheckedText: String {
        guard let lastChecked else { return "尚未检查" }
        let elapsed = Date().timeIntervalSince(lastChecked)
        if elapsed < 60 { return "刚刚检查" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前检查" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600)) 小时前检查" }
        return "\(Int(elapsed / 86_400)) 天前检查"
    }

    // MARK: - 检查

    public func checkIfNeeded() async {
        if updates.isEmpty { await check() }
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

    // MARK: - 更新动作

    public func canUpgrade(_ update: AppUpdate) -> Bool {
        if case .homebrewCask = update.app.source { return true }
        return false
    }

    public func upgrade(_ update: AppUpdate) async {
        guard case .homebrewCask(let token) = update.app.source else { return }
        guard upgradingToken == nil else { return }

        upgradingToken = token
        logText = "$ brew upgrade --cask \(token)\n\n"
        isShowingLog = true

        for await chunk in BrewService.upgradeStream(token: token) {
            logText += chunk
        }

        upgradingToken = nil
        await check()
    }

    public func openDownload(for update: AppUpdate) {
        guard case .updateAvailable(_, let downloadURL, let releaseNotesURL, _) = update.result else { return }
        if let downloadURL {
            NSWorkspace.shared.open(downloadURL)
        } else if let releaseNotesURL {
            NSWorkspace.shared.open(releaseNotesURL)
        }
    }

    public func reveal(_ app: AppInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([app.path])
    }
}
