import Foundation

/// 命令行安装入口。
///
/// 存在的意义和 `--check` 一样：把"一键升级真的能用"变成可复现的命令行输出，
/// 而不是只能靠打开窗口手点。也是真机验证与自动化回归的唯一通路。
///
///     AppUpdater --install "AlDente"      执行一次真实升级
///     AppUpdater --plan "AlDente"         只打印预检结果，不下载不安装
///     AppUpdater --install-all            升级所有可自动完成的条目
///     AppUpdater --recover                清理上一次被中断的安装残留
public enum InstallCommand {
    /// 清理（必要时抢救）上一次被中断的安装残留。
    public static func recover() -> Int32 {
        let cleaned = Installer.cleanStaleWorkspaces()
        let report = Installer.recoverInterruptedInstalls()

        print("→ 清理缓存工作目录：\(cleaned) 个")
        if report.isEmpty {
            print("→ 应用目录里没有残留 ✅")
            return 0
        }

        if !report.rescuedApps.isEmpty {
            print("→ 已恢复被中断安装影响的应用：\(report.rescuedApps.joined(separator: "、"))")
        }
        if !report.removedArtifacts.isEmpty {
            print("→ 清理残留文件 \(report.removedArtifacts.count) 个：")
            for name in report.removedArtifacts {
                print("    · \(name)")
            }
        }
        for message in report.needsAttention {
            print("→ ⚠︎ \(message)")
        }
        return report.needsAttention.isEmpty ? 0 : 1
    }
    public static func run(appName: String, dryRun: Bool) async -> Int32 {
        let context = await prepare()
        guard let match = context.updates.first(where: {
            $0.app.name.localizedCaseInsensitiveCompare(appName) == .orderedSame
        }) else {
            print("没有找到名为 \(appName) 的应用。可用的可更新项：")
            for update in context.updates where update.group == .updateAvailable {
                print("  · \(update.app.name)")
            }
            return 1
        }
        return await execute([match], dryRun: dryRun)
    }

    public static func runAll(dryRun: Bool) async -> Int32 {
        let context = await prepare()
        let candidates = context.updates.filter { $0.group == .updateAvailable && $0.installAction.isAutomated }
        guard !candidates.isEmpty else {
            print("没有可自动升级的条目。")
            return 0
        }
        print("")
        print("可自动升级 \(candidates.count) 项：")
        for update in candidates {
            print("  · \(update.app.name) — \(update.detailText)  [\(update.installAction.buttonTitle)]")
        }
        return await execute(candidates, dryRun: dryRun)
    }

    // MARK: - 内部

    private struct Context {
        var updates: [AppUpdate]
    }

    private static func prepare() async -> Context {
        print("→ 扫描并查询更新状态…")
        let outcome = await BrewService.loadIndex()
        if let notice = outcome.status.notice {
            print("  ⚠︎ \(notice)")
        }
        let index = outcome.index
        let scanned = await Task.detached { AppScanner().scan() }.value
        let classifier = AppClassifier(caskIndex: index)
        var apps = SelfUpdateIdentity.excludingSelf(scanned.map { classifier.classify($0) })

        if let index {
            let known = Set(apps.compactMap { app -> String? in
                if case .homebrewCask(let token) = app.source { return token }
                return nil
            })
            for (token, version) in index.binaryOnlyTokens where !known.contains(token) {
                apps.append(.commandLineCask(token: token, installedVersion: version))
            }
        }

        let updates = await CheckEngine().check(apps: apps) { done, total in
            FileHandle.standardError.write(Data("  进度 \(done)/\(total)\r".utf8))
        }
        FileHandle.standardError.write(Data("\n".utf8))
        return Context(updates: updates)
    }

    private static func execute(_ targets: [AppUpdate], dryRun: Bool) async -> Int32 {
        let installer = Installer()
        var failures = 0

        for (index, update) in targets.enumerated() {
            print("")
            print("───────────────────────────────────────────────")
            print("[\(index + 1)/\(targets.count)] \(update.app.name) — \(update.detailText)")

            let action = update.installAction
            guard let release = update.result.release else {
                print("  跳过：没有可用的版本信息")
                failures += 1
                continue
            }

            switch action {
            case .homebrew(let token):
                if dryRun {
                    print("  预演：会执行 brew upgrade --cask \(token)")
                    continue
                }
                print("  $ brew upgrade --cask \(token)")
                var succeeded = false
                for await chunk in BrewService.upgradeStream(token: token) {
                    FileHandle.standardOutput.write(Data(chunk.utf8))
                    if chunk.contains("✔ 完成") { succeeded = true }
                }
                if !succeeded { failures += 1 }

            case .replaceBundle:
                let plan = installer.makePlan(app: update.app, release: release)
                printPlan(plan)

                if dryRun {
                    print("  预演：不下载、不安装")
                    continue
                }

                print("")
                let report = await installer.install(app: update.app, release: release) { progress in
                    let detail = progress.detail
                    FileHandle.standardOutput.write(Data("  [\(progress.phase.title)] \(detail)\n".utf8))
                }
                printReport(report)
                if !report.succeeded { failures += 1 }

            case .openInstaller, .openDownload, .manual:
                print("  跳过：需要手动完成（\(action.buttonTitle)）")
            }
        }

        print("")
        print("═══════════════════════════════════════════════")
        print(failures == 0
            ? "全部完成：\(targets.count) 项"
            : "完成 \(targets.count - failures) 项，失败 \(failures) 项")
        return failures == 0 ? 0 : 1
    }

    static func printPlan(_ plan: Installer.Plan) {
        print("  应用      \(plan.appName)  (\(plan.bundleID))")
        print("  版本      \(plan.fromVersion ?? "未知") → \(plan.toVersion)")
        print("  安装包    \(plan.packageKind.displayName)" + (plan.downloadSize.map { " · \(AppUpdate.formatBytes($0))" } ?? ""))
        print("  来源      \(plan.sourceHost ?? "未知")")
        print("  签名      \(plan.signature.description)")
        print("  备份到    \(abbreviate(plan.backupLocation))")
        print("  运行状态  \(plan.isAppRunning ? "正在运行，升级前会先退出" : "未运行")")
        for warning in plan.warnings {
            print("  ⚠︎ \(warning)")
        }
    }

    static func printReport(_ report: Installer.Report) {
        print("")
        if report.succeeded {
            print("  ✔ \(report.appName) 已升级：\(report.fromVersion ?? "?") → \(report.toVersion)")
            print("    签名：\(report.signature.summary)")
            if let backup = report.backupPath {
                print("    备份：\(abbreviate(backup))")
            }
            if report.relaunched {
                print("    已重新打开")
            }
            for warning in report.warnings {
                print("    ⚠︎ \(warning)")
            }
        } else {
            print("  ✘ \(report.appName) 升级失败：\(report.error ?? "未知原因")")
            if report.rolledBack {
                print("    已回滚到升级前的版本")
            }
            if let backup = report.backupPath {
                print("    备份仍在：\(abbreviate(backup))")
            }
            for warning in report.warnings {
                print("    ⚠︎ \(warning)")
            }
        }
    }

    private static func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}
