import Foundation

/// 检查编排：把一批应用分派到各自的探针，并汇总结果。
///
/// 铁律：任何单个应用失败都只影响它自己。窗口永远不该因为一个 404 而变空。
///
/// 这个类型本身不做任何目录扫描，也不重建 brew 索引——那些是调用方的事。
/// 因此同一个引擎既能跑全量（`UpdateStore.check` 传进全部应用），
/// 也能跑增量（只传变更过的那几个），两者只有入参规模不同，没有第二套逻辑。
public struct CheckEngine: Sendable {
    /// brew 查询缝。返回 `nil` 表示"没找到 Homebrew，问不了"，
    /// 与"问了，没有过期项"（空字典）是两回事，不能混为一谈。
    public typealias BrewOutdatedSource = @Sendable (_ tokens: [String]) async -> [String: String]?

    private let sparkleProbe: any UpdateProbing
    private let electronProbe: any UpdateProbing
    private let brewOutdated: BrewOutdatedSource
    private let concurrency: Int

    public init(client: HTTPClient = HTTPClient(), concurrency: Int = 8) {
        self.init(
            sparkleProbe: SparkleProbe(client: client),
            electronProbe: ElectronProbe(client: client),
            concurrency: concurrency
        )
    }

    /// 供测试注入假探针 / 假 brew 用。
    init(
        sparkleProbe: any UpdateProbing,
        electronProbe: any UpdateProbing,
        brewOutdated: @escaping BrewOutdatedSource = { await BrewService.outdatedCasks(scopedTo: $0) },
        concurrency: Int = 8
    ) {
        self.sparkleProbe = sparkleProbe
        self.electronProbe = electronProbe
        self.brewOutdated = brewOutdated
        self.concurrency = max(1, concurrency)
    }

    /// 检查给定的应用。
    ///
    /// `apps` 就是检查范围：传全部就是全量检查，传子集就是增量检查。
    /// brew 侧同样会收窄到这批应用涉及的 cask token 上，不会顺手比一遍全表。
    public func check(
        apps: [AppInfo],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [AppUpdate] {
        var results: [AppUpdate] = []
        var pending: [AppInfo] = []
        var brewTokens: [String] = []

        for app in apps {
            switch app.source {
            case .homebrewCask(let token):
                brewTokens.append(token)
            case .sparkle, .electron:
                pending.append(app)
            case .appStore:
                results.append(AppUpdate(app: app, result: .unsupported(reason: "App Store 管理，需在 App Store 内更新")))
            case .microsoftAutoUpdate:
                results.append(AppUpdate(app: app, result: .unsupported(reason: "由 Microsoft AutoUpdate 管理")))
            case .unsupported(let reason):
                results.append(AppUpdate(app: app, result: .unsupported(reason: reason)))
            }
        }

        // 一次批量调用拿到所有待更新 cask。逐个 `brew info` 会慢到不可接受。
        let outdated = brewTokens.isEmpty ? [:] : await brewOutdated(brewTokens)
        let brewAvailable = !brewTokens.isEmpty ? outdated != nil : true

        for app in apps {
            guard case .homebrewCask(let token) = app.source else { continue }
            // 问不到就如实说问不到。报"已是最新"比报错版本号更隐蔽，也更危险。
            guard brewAvailable else {
                results.append(AppUpdate(app: app, result: .failed(reason: "未找到 Homebrew，无法确认是否过期")))
                continue
            }
            if let latest = outdated?[token] {
                results.append(AppUpdate(app: app, result: .updateAvailable(ReleaseInfo(version: latest))))
            } else {
                results.append(AppUpdate(app: app, result: .upToDate(latest: app.currentVersion ?? "—")))
            }
        }

        let total = pending.count
        guard total > 0 else {
            onProgress?(0, 0)
            return sorted(results)
        }

        var done = 0
        for batch in pending.chunked(into: concurrency) {
            await withTaskGroup(of: AppUpdate.self) { group in
                for app in batch {
                    group.addTask { await probe(app) }
                }
                for await update in group {
                    results.append(update)
                    done += 1
                    onProgress?(done, total)
                }
            }
        }

        return sorted(results)
    }

    private func probe(_ app: AppInfo) async -> AppUpdate {
        let result: UpdateResult
        switch app.source {
        case .sparkle:
            result = await sparkleProbe.probe(app)
        case .electron:
            result = await electronProbe.probe(app)
        default:
            result = .unsupported(reason: "该来源无需网络探测")
        }
        return AppUpdate(app: app, result: result)
    }

    private func sorted(_ updates: [AppUpdate]) -> [AppUpdate] {
        updates.sorted(by: AppUpdate.listOrder)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
