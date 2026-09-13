import Foundation

/// 检查编排：把一批应用分派到各自的探针，并汇总结果。
///
/// 铁律：任何单个应用失败都只影响它自己。窗口永远不该因为一个 404 而变空。
public struct CheckEngine: Sendable {
    private let sparkleProbe: SparkleProbe
    private let electronProbe: ElectronProbe
    private let concurrency: Int

    public init(client: HTTPClient = HTTPClient(), concurrency: Int = 8) {
        sparkleProbe = SparkleProbe(client: client)
        electronProbe = ElectronProbe(client: client)
        self.concurrency = max(1, concurrency)
    }

    public func check(
        apps: [AppInfo],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [AppUpdate] {
        var results: [AppUpdate] = []
        var pending: [AppInfo] = []

        let needsBrewCheck = apps.contains { if case .homebrewCask = $0.source { return true } else { return false } }
        let outdated = needsBrewCheck ? await BrewService.outdatedCasks() : [:]

        for app in apps {
            switch app.source {
            case .homebrewCask(let token):
                if let latest = outdated[token] {
                    results.append(AppUpdate(app: app, result: .updateAvailable(ReleaseInfo(version: latest))))
                } else {
                    results.append(AppUpdate(app: app, result: .upToDate(latest: app.currentVersion ?? "—")))
                }

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
        updates.sorted { left, right in
            if left.group != right.group { return left.group.rawValue < right.group.rawValue }
            return left.app.name.localizedStandardCompare(right.app.name) == .orderedAscending
        }
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
