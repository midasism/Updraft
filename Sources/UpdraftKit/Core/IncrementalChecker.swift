import Foundation

/// 一次增量刷新的结果。
public struct IncrementalRefreshReport: Sendable {
    /// 重新读包 + 重新探测过的条目，可以直接覆盖同名旧条目。
    public let refreshed: [AppUpdate]
    /// 目标应用已不在原路径（被删掉、被挪走）。如实上报，不静默丢行。
    public let missing: [AppUpdate]
    /// 因拿不到 brew 索引而复用了上一次分类结果的条目数。
    public let reusedSourceCount: Int

    public init(refreshed: [AppUpdate], missing: [AppUpdate], reusedSourceCount: Int) {
        self.refreshed = refreshed
        self.missing = missing
        self.reusedSourceCount = reusedSourceCount
    }

    /// 需要写回列表的全部条目。
    public var all: [AppUpdate] { refreshed + missing }

    public var isEmpty: Bool { all.isEmpty }
}

/// 增量检查：只重读、重探"发生过变更"的应用，既不做目录扫描也不重建 brew 索引。
///
/// 一次全量检查有三笔开销：
///
///   1. 重建 brew cask 索引（`brew list` + `brew info --json=v2`，cask 多时最贵）
///   2. 遍历 `/Applications` + `~/Applications`，逐个读 Info.plist
///   3. 对每个可探测应用发一次网络请求（Sparkle 拉 appcast、Electron 查 Release）
///
/// 升级完一个应用之后，第 1、2 笔的答案不会因为这次升级而改变——重做纯属让用户干等；
/// 第 3 笔里也只有那个应用的结果真的变了，其余几十个的答案是白问的。
/// 这里把它们替换成"只重读变更过的那一个包 + 只探它一个"。
public struct IncrementalChecker: Sendable {
    private let scanner: AppScanner
    private let engine: CheckEngine

    public init(scanner: AppScanner = AppScanner(), engine: CheckEngine = CheckEngine()) {
        self.scanner = scanner
        self.engine = engine
    }

    /// - Parameters:
    ///   - targets: 发生变更的条目（来自上一次的检查结果）。
    ///   - caskIndex: 上一次全量检查用过的 brew 索引。传 `nil` 表示索引不可用，
    ///     此时分类沿用 `targets` 里原有的来源，而不是从零猜一遍。
    ///   - onProgress: 只统计被重新探测的部分。
    public func refresh(
        targets: [AppUpdate],
        caskIndex: BrewCaskIndex?,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> IncrementalRefreshReport {
        guard !targets.isEmpty else {
            return IncrementalRefreshReport(refreshed: [], missing: [], reusedSourceCount: 0)
        }

        let classifier = AppClassifier(caskIndex: caskIndex)
        var fresh: [AppUpdate] = []
        var missing: [AppUpdate] = []
        var reused = 0

        for target in targets {
            guard let scanned = scanner.inspect(bundleAt: target.app.path) else {
                // 包没了就是没了。留在列表里并说明原因，比悄悄删掉一行诚实。
                missing.append(target.replacing(result: .failed(reason: "应用包已不在原路径，可能被移动或删除")))
                continue
            }

            let fallback = caskIndex == nil ? trustedSource(for: target, scanned: scanned) : nil
            if fallback != nil { reused += 1 }

            let app = classifier.classify(scanned, trustedFallback: fallback)
            fresh.append(AppUpdate(app: app, result: target.result))
        }

        // 网络探测只针对重新读到的这些包，并且只探这些：范围就是入参，不会再扩散。
        let probed = await engine.check(apps: fresh.map(\.app), onProgress: onProgress)
        let byID = Dictionary(probed.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        let refreshed = fresh.map { item in
            // 正常不会走到 else：引擎对每个入参应用都会给一条结果。
            byID[item.id] ?? item.replacing(result: .failed(reason: "未取得检查结果"))
        }

        return IncrementalRefreshReport(refreshed: refreshed, missing: missing, reusedSourceCount: reused)
    }

    /// 什么时候可以沿用上一次的来源判定。
    ///
    /// 两个条件都得满足：调用方没拿到 brew 索引（拿到就不需要兜底，照着索引重新判定更准），
    /// 并且 Bundle ID 没变——变了说明这个路径上蹲的已经是另一个应用，旧结论对它没有意义。
    private func trustedSource(for target: AppUpdate, scanned: ScannedApp) -> AppSource? {
        guard let bundleID = scanned.bundleID, bundleID == target.app.bundleID else { return nil }
        return target.app.source
    }

    /// 把增量结果并回全量列表。
    ///
    /// 没有出现在 `refreshed` / `missing` 里的条目一律原样保留——它们没有因为
    /// 别的应用升级而失去可信度，没有任何理由被重查或清空。
    public static func merge(_ changed: [AppUpdate], into existing: [AppUpdate]) -> [AppUpdate] {
        guard !changed.isEmpty else { return existing }

        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for update in changed {
            byID[update.id] = update
        }
        return byID.values.sorted(by: AppUpdate.listOrder)
    }
}
