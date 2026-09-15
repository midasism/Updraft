import Foundation

/// 无界面自检入口，`AppUpdater --check` 触发。
///
/// 存在的意义是把"真的能查出更新"这件事变成可验证的命令行输出，
/// 而不是只能靠打开窗口肉眼看。
public enum HeadlessCheck {
    public static func run() async {
        let started = Date()

        print("→ 读取 Homebrew 索引…")
        let outcome = await BrewService.loadIndex()
        let index = outcome.index
        switch outcome.status {
        case .ok:
            print("  已安装 cask \(index?.installedTokens.count ?? 0) 个，其中纯命令行工具 \(index?.binaryOnlyTokens.count ?? 0) 个")
        case .brewNotFound:
            print("  ⚠︎ 未找到 Homebrew，cask 类检测已跳过")
        case .listFailed(let stderr):
            print("  ⚠︎ Homebrew 索引读取失败，cask 类检测已跳过")
            printBrewError(stderr)
        case .partial(let skipped, let stderr):
            print("  已安装 cask \(index?.installedTokens.count ?? 0) 个，其中纯命令行工具 \(index?.binaryOnlyTokens.count ?? 0) 个")
            print("  ⚠︎ \(skipped.count) 个 cask 读取失败已跳过：\(skipped.joined(separator: "、"))")
            printBrewError(stderr)
        }

        print("→ 扫描应用…")
        let scanned = await Task.detached { AppScanner().scan() }.value
        let classifier = AppClassifier(caskIndex: index)
        var apps = SelfUpdateIdentity.excludingSelf(scanned.map { classifier.classify($0) })

        if let index {
            let knownTokens = Set(apps.compactMap { app -> String? in
                if case .homebrewCask(let token) = app.source { return token }
                return nil
            })
            for (token, version) in index.binaryOnlyTokens where !knownTokens.contains(token) {
                apps.append(.commandLineCask(token: token, installedVersion: version))
            }
        }

        let bySource = Dictionary(grouping: apps, by: { $0.source.badge })
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
        print("  共 \(apps.count) 项：" + bySource.map { "\($0.key) \($0.value)" }.joined(separator: " / "))

        let detectable = apps.filter { $0.source.isAutoDetectable }.count
        print("→ 查询 \(detectable) 项更新…")

        let engine = CheckEngine()
        let results = await engine.check(apps: apps) { done, total in
            FileHandle.standardError.write(Data("  进度 \(done)/\(total)\r".utf8))
        }
        FileHandle.standardError.write(Data("\n".utf8))

        print("")
        print("════════ 结果 ════════")

        let grouped = Dictionary(grouping: results, by: \.group)
        // 失败项在分组上归入"无法自动检测"，这里单独数一遍，避免两处数字对不上。
        let failureCount = results.filter { if case .failed = $0.result { return true } else { return false } }.count

        for group in UpdateGroup.allCases {
            let items = (grouped[group] ?? []).sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
            var header = "【\(group.title)】\(items.count) 项"
            if group == .unsupported, failureCount > 0 {
                header += "（其中 \(failureCount) 项是网络或解析失败）"
            }
            print("")
            print(header)
            for update in items {
                if group == .unsupported {
                    // 不支持的那一大坨只在失败时逐条列出，其余折叠。
                    guard case .failed = update.result else { continue }
                }
                print("  · \(update.app.name) — \(update.detailText)")
            }
            if group == .unsupported, items.count > failureCount {
                print("  …（其余 \(items.count - failureCount) 项无可用的公开更新接口，已折叠）")
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print("")
        print(String(format: "耗时 %.1f 秒", elapsed))
    }

    /// brew 的报错首行往往一句话就说清了原因，打印出来省得用户瞎猜。
    private static func printBrewError(_ stderr: String) {
        let line = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let line {
            print("    ↳ \(line)")
        }
    }
}
