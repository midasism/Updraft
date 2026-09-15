import Foundation

/// 增量刷新入口。
///
///     AppUpdater --refresh "AlDente"     只重查这一个应用
///     AppUpdater --refresh-all           重查缓存里全部可探测的条目
///
/// 存在的意义和 `--check` 一样：把"增量刷新真的只动了变更过的应用"变成可复现的
/// 命令行输出与计时，而不是只能靠打开窗口体会。
///
/// 注意它**刻意不重建 brew 索引**——那正是要被省掉的那笔开销之一。代价是分类只能
/// 沿用上一次全量检查的结论（`caskIndex: nil` 会走 `trustedFallback` 分支）。
/// 对一个刚刚升级过的应用来说"它归谁管"本来就没变，这个结论是可靠的。
public enum RefreshCommand {
    public static func run(appNames: [String]) async -> Int32 {
        let cache = StateCache()
        guard let snapshot = cache.load(), !snapshot.updates.isEmpty else {
            print("没有可用的检查结果缓存。先跑一次全量：AppUpdater --check")
            return 1
        }
        let cached = SelfUpdateIdentity.excludingSelf(snapshot.updates)

        let targets: [AppUpdate]
        if appNames.isEmpty {
            targets = cached.filter { $0.app.source.isAutoDetectable }
        } else {
            let unknown = appNames.filter { name in
                !cached.contains { $0.app.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
            }
            guard unknown.isEmpty else {
                print("列表里没有这些应用：\(unknown.joined(separator: "、"))")
                print("可用的条目：")
                for update in cached.prefix(40) {
                    print("  · \(update.app.name)")
                }
                return 1
            }
            targets = cached.filter { update in
                appNames.contains { update.app.name.localizedCaseInsensitiveCompare($0) == .orderedSame }
            }
        }

        guard !targets.isEmpty else {
            print("没有需要重新检查的条目。")
            return 0
        }

        print("→ 增量刷新 \(targets.count) 项（列表共 \(cached.count) 项）")
        print("  不遍历应用目录、不重建 brew 索引、不触碰其余 \(cached.count - targets.count) 项")
        for update in targets {
            print("    · \(update.app.name)  \(update.detailText)")
        }

        let started = Date()
        let report = await IncrementalChecker().refresh(targets: targets, caskIndex: nil)
        let elapsed = Date().timeIntervalSince(started)

        print("")
        print("════════ 刷新结果 ════════")
        for item in report.all.sorted(by: AppUpdate.listOrder) {
            print("  · \(item.app.name) — \(item.detailText)")
        }
        if report.reusedSourceCount > 0 {
            print("  沿用上一次的分类结果 \(report.reusedSourceCount) 项（本次未读 brew 索引）")
        }
        for item in report.missing {
            print("  ⚠︎ \(item.app.name)：应用包已不在原路径，可能被移动或删除")
        }
        print(String(format: "本次重新读包并探测 %d 个，耗时 %.2f 秒", report.refreshed.count, elapsed))

        let merged = IncrementalChecker.merge(report.all, into: cached)
        cache.save(.init(
            updates: merged,
            savedAt: Date(),
            lastFullCheckAt: snapshot.lastFullCheckAt,
            lastFullCheckStartedAt: snapshot.lastFullCheckStartedAt
        ))
        print("→ 已并回缓存（\(merged.count) 项），未涉及的条目保持不变")
        return 0
    }
}
