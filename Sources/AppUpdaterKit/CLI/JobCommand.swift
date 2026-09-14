import Foundation

/// 走界面状态源完成一次真实升级，`AppUpdater --job "<名称>"` 触发。
///
/// 与 `--install` 的区别很关键：`--install` 走的是命令行自己那一套编排，
/// **碰不到升级收尾**；`--job` 走的是 `UpdateStore` 的状态机——也就是窗口里点
/// 「升级」真正会执行的代码路径，升级收尾的增量刷新就在这条路径上。
/// 因此只有它能验证"收尾不再整机重扫"这件事。
///
/// 会真实下载、校验、备份并替换 `/Applications` 里的应用包，不是预演。
@MainActor
public enum JobCommand {
    private final class Box: @unchecked Sendable {
        var code: Int32 = 1
        var done = false
    }

    public static func run(appName: String) -> Int32 {
        let box = Box()
        Task { @MainActor in
            box.code = await perform(appName: appName)
            box.done = true
        }

        let deadline = Date().addingTimeInterval(1800)
        while !box.done, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard box.done else {
            FileHandle.standardError.write(Data("任务超时（30 分钟）\n".utf8))
            return 1
        }
        return box.code
    }

    private static func perform(appName: String) async -> Int32 {
        let store = UpdateStore()
        store.runStartupRecovery()
        if let notice = store.recoveryNotice {
            print("→ ⚠︎ \(notice)")
        }

        print("→ 全量检查（作为增量刷新的基线）…")
        var started = Date()
        await store.check()
        let fullCheck = Date().timeIntervalSince(started)
        print(String(format: "  全量 %.2f 秒，共 %d 项", fullCheck, store.updates.count))

        let candidates = store.updates(in: .updateAvailable)
        guard let target = candidates.first(where: {
            $0.app.name.localizedCaseInsensitiveCompare(appName) == .orderedSame
        }) else {
            print("没有找到名为 \(appName) 的可更新应用。可更新项：")
            for item in candidates { print("  · \(item.app.name) — \(item.detailText)") }
            return 1
        }

        print("")
        print("→ 通过界面状态源升级 \(target.app.name)")
        print("  \(target.detailText)  [\(target.installAction.buttonTitle)]")

        store.requestUpgrade(target)
        guard let prepared = store.job else {
            print("  这个条目不需要（也不能）由本工具自动完成")
            return 1
        }
        print("  任务：\(prepared.title)")

        started = Date()
        let ticker = startProgressTicker(store: store)

        print("")
        await store.runJob()

        ticker.cancel()
        let jobSeconds = Date().timeIntervalSince(started)

        print("")
        print("════════ 升级结果 ════════")
        for outcome in store.job?.outcomes ?? [] {
            print("  \(outcome.succeeded ? "✔" : "✘") \(outcome.appName)  \(outcome.fromVersion ?? "?") → \(outcome.toVersion)")
            print("    \(outcome.summary)")
            if let backup = outcome.backupPath { print("    备份：\(abbreviate(backup))") }
            if outcome.rolledBack { print("    已回滚到升级前的版本") }
            for warning in outcome.warnings { print("    ⚠︎ \(warning)") }
        }
        print(String(format: "  任务耗时 %.2f 秒（含下载与换包）", jobSeconds))

        print("")
        print("════════ 升级收尾（本次改动的重点） ════════")
        guard let stat = store.lastRefresh else {
            print("  ✘ 没有发生增量刷新——收尾路径可能已被改回整机重扫")
            return 1
        }
        let saved = fullCheck / max(stat.seconds, 0.001)
        print("  重新检查 \(stat.targets) 项，列表共 \(stat.listSize) 项，未涉及的 \(stat.listSize - stat.targets) 项保持原样")
        if stat.missing > 0 { print("  ⚠︎ 其中 \(stat.missing) 项的包已不在原路径") }
        print(String(format: "  收尾耗时 %.2f 秒（全量基准 %.2f 秒，相差约 %.0f 倍）", stat.seconds, fullCheck, saved))
        print("  刚刚升级的条目：")
        for item in store.updates(in: .updateAvailable).filter({ $0.app.name == target.app.name })
            + store.updates(in: .upToDate).filter({ $0.app.name == target.app.name }) {
            print("    · \(item.app.name) — \(item.detailText)")
        }
        return store.job?.outcomes.allSatisfy(\.succeeded) == true ? 0 : 1
    }

    /// 升级过程中把最新一行进度打到终端，否则一次 100 MB 的下载会长时间没有输出。
    private static func startProgressTicker(store: UpdateStore) -> Task<Void, Never> {
        Task { @MainActor in
            var lastLine = ""
            while !Task.isCancelled {
                let line = store.job?.runningLog
                    .split(separator: "\n")
                    .last
                    .map(String.init) ?? ""
                if !line.isEmpty, line != lastLine {
                    lastLine = line
                    print("    \(line)")
                }
                guard (try? await Task.sleep(nanoseconds: 400_000_000)) != nil else { break }
            }
        }
    }

    private static func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}
