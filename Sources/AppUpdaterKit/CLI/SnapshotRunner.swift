import AppKit
import SwiftUI

/// 把真实的界面离屏渲染成 PNG，`AppUpdater --snapshot <路径>` 触发。
///
/// 走的是视图自己绘制（`cacheDisplay`），不经过窗口服务器截图，
/// 因此不需要「屏幕录制」权限，可以放进自动化流程里做界面回归对比。
@MainActor
public enum SnapshotRunner {
    public enum Mode: String {
        /// 主窗口。
        case main
        /// 单个应用的升级确认面板。
        case confirm
        /// 批量升级的确认面板。
        case batch
        /// 运行中的面板。**合成状态**，不查网络，专门用来回答一个问题：
        /// 升级卡住的时候，用户面前到底有没有"取消"这个出口。
        case running
        /// 收尾页（成功 + 失败 + 已取消混排）。验证"已取消"没有穿成失败的马甲。
        case cancelled
        /// 菜单栏下拉内容。**合成状态**：菜单栏要在「不打开主窗口也能看状态」的场景下留痕，
        /// 而菜单内容是值类型快照（MenuBarStatus），合成即确定。
        case menubar
        /// 设置窗口。**合成状态**（临时 suite 的设置对象），不持久化、不触发授权。
        case settings
        /// 设置窗口里「清理备份」的就地确认态。**合成状态**：先把数字钉死，才能确认
        /// 确认按钮出现后那一行没有把说明文字挤变形、也没有把按钮裁出画布。
        /// 这是清理动作最后一道人工闸门，值得留一张图。
        case settingsConfirm = "settings-confirm"
        /// 主窗口在「Homebrew 账本滞后于磁盘」下的样子。**合成状态**：这个界面状态要求
        /// 机器上某个 cask 恰好被应用自带的更新器升过而 brew 记录没跟上，账本一被修正
        /// 就再也复现不了；合成即确定，重跑必然得到同一张图。
        case ledger
    }

    private final class Flag {
        var value = false
        var jobPrepared = false
    }

    public static func run(
        outputPath: String,
        mode: Mode = .main,
        size: NSSize? = nil,
        /// 初始筛选词。只有截图通道用，生产路径走默认空值。
        query: String = ""
    ) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let canvas = size ?? defaultCanvas(for: mode)

        // 菜单栏与设置是纯合成视图，不走检查流程，渲染结果完全确定。
        if let syntheticRoot = syntheticRoot(for: mode) {
            return render(syntheticRoot, canvas: canvas, outputPath: outputPath)
        }

        // 账本滞后态：数据是编好的，同样不查网络、不扫本机。它要借 ContentView 渲染，
        // 所以不能走上面那条纯合成视图的支路，但也不需要等任何检查。
        if mode == .ledger {
            let store = UpdateStore()
            store.loadSynthetic(updates: makeSyntheticLedgerUpdates())
            return render(AnyView(ContentView(store: store)), canvas: canvas, outputPath: outputPath)
        }

        let store = UpdateStore()
        let flag = Flag()

        if let synthetic = syntheticJob(for: mode) {
            // 合成状态：不查网络、不扫本机应用，渲染结果完全确定。
            // 这两个截图要能随时重跑并给出同样的结果，而它们的重点本来就是
            // "用户在卡住时看到什么"，与真实有哪些应用可升级无关。
            store.job = synthetic
            flag.jobPrepared = true
            flag.value = true
        } else {
            Task { @MainActor in
                await store.check()
                prepareJob(store: store, mode: mode, flag: flag)
                flag.value = true
            }
        }

        let deadline = Date().addingTimeInterval(120)
        while !flag.value, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard flag.value else {
            FileHandle.standardError.write(Data("检查超时，未生成截图\n".utf8))
            return 1
        }

        let root: AnyView
        switch mode {
        case .main:
            root = AnyView(ContentView(store: store, initialQuery: query))
        case .confirm, .batch, .running, .cancelled:
            if flag.jobPrepared {
                root = AnyView(UpgradeSheet(store: store))
            } else {
                FileHandle.standardError.write(Data("没有找到可自动升级的条目，退回主窗口截图\n".utf8))
                root = AnyView(ContentView(store: store))
            }
        case .menubar, .settings, .settingsConfirm, .ledger:
            // 上面 syntheticRoot / ledger 分支已接住，不会走到这里。
            root = AnyView(EmptyView())
        }

        return render(root, canvas: canvas, outputPath: outputPath)
    }

    private static func defaultCanvas(for mode: Mode) -> NSSize {
        switch mode {
        case .main, .ledger: NSSize(width: 880, height: 660)
        case .menubar: NSSize(width: 280, height: 220)
        // 高度按设置页实际内容量给：三节（定时检查 / 通知 / 备份）。截短了会把
        // 备份那一节裁掉一半，而截图的意义就是"看得见"。
        case .settings, .settingsConfirm: NSSize(width: 484, height: 460)
        default: NSSize(width: 600, height: 540)
        }
    }

    /// 合成视图通道：渲染 + 写 PNG。与真实检查通道共用同一段绘制代码。
    private static func render(_ root: AnyView, canvas: NSSize, outputPath: String) -> Int32 {
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: canvas)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: canvas),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "App 更新"
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)

        // 给 SwiftUI 几帧时间把 List 的内容铺出来，否则截到的是空壳。
        for _ in 0..<25 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("无法创建位图\n".utf8))
            return 1
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
            return 1
        }
        do {
            try data.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            FileHandle.standardError.write(Data("写入失败：\(error)\n".utf8))
            return 1
        }
        print("已生成 \(outputPath)（\(rep.pixelsWide)×\(rep.pixelsHigh)）")
        return 0
    }

    /// 菜单栏与设置的合成视图：状态与动作全是编好的值，重跑必然得到同一张图。
    private static func syntheticRoot(for mode: Mode) -> AnyView? {
        switch mode {
        case .menubar:
            // 名字取自本机真实会升级的包，截图看起来才像真的（与 makeSyntheticJob 同一理由）。
            let status = MenuBarStatus(
                isChecking: false,
                updateCount: 3,
                hasResult: true,
                lastCheckedText: "5 分钟前检查",
                scheduleText: "定时检查：每天 10:00"
            )
            let actions = MenuBarContent.Actions(
                checkNow: {},
                openMain: {},
                openSettings: {},
                quit: {}
            )
            // 显式定高：NSHostingView 会按自测的内在尺寸收缩，比内容实际高度小时
            // 居中裁切会把顶部几行裁掉；给定高度并把内容顶对齐，裁切不再发生。
            return AnyView(
                MenuBarContent(status: status, actions: actions)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(width: 280, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
        case .settings, .settingsConfirm:
            let defaults = UserDefaults(suiteName: "updraft-snapshot-settings")
            let settings = AppSettings(defaults: defaults)
            settings.scheduledCheckEnabled = true
            settings.scheduledCheckHour = 10
            settings.scheduledCheckMinute = 0
            settings.notificationsEnabled = true
            // 数字是钉死的：截图要能重跑并给出同一张图，所以不去量真实的备份目录。
            return AnyView(
                SettingsView(
                    settings: settings,
                    backups: BackupPanelState(bytes: 1_830_000_000),
                    confirmingClear: mode == .settingsConfirm
                )
                .background(Color(nsColor: .windowBackgroundColor))
            )
        case .main, .confirm, .batch, .running, .cancelled, .ledger:
            return nil
        }
    }

    /// 造一个升级任务，把面板推到确认态。
    private static func prepareJob(store: UpdateStore, mode: Mode, flag: Flag) {
        switch mode {
        case .main, .running, .cancelled, .menubar, .settings, .settingsConfirm, .ledger:
            break
        case .confirm:
            if let update = store.updates(in: .updateAvailable)
                .first(where: { $0.installAction == .replaceBundle }) {
                store.requestUpgrade(update)
                flag.jobPrepared = store.job != nil
            }
        case .batch:
            store.requestUpgradeAll()
            flag.jobPrepared = store.job != nil
        }
    }

    /// 造一个完全确定的升级任务，用来渲染"卡住 / 取消"相关的界面。
    private static func syntheticJob(for mode: Mode) -> UpgradeJob? {
        switch mode {
        case .main, .confirm, .batch, .menubar, .settings, .settingsConfirm, .ledger:
            return nil

        case .running:
            var job = makeSyntheticJob()
            job.isRunning = true
            job.currentIndex = 1
            job.items[0].state = .succeeded
            job.items[1].state = .running
            job.phase = Installer.Progress(
                phase: .replacing,
                detail: "正在把新包复制到 /Applications… 已用 6 秒"
            )
            job.runningLog = """
            [1/3] Cherry Studio 1.8.4 → 2.0.9
              ✔ 校验开发者签名
              ✔ 备份旧版本 → ~/Library/Application Support/AppUpdater/Backups
              ✔ 退出正在运行的应用
              ✔ 替换应用 — 新包已就位，正在换名…

            [2/3] IINA 1.3.5 → 1.4.4
              正在替换应用 — 正在把新包复制到 /Applications… 已用 6 秒
            """
            return job

        case .cancelled:
            var job = makeSyntheticJob()
            job.isFinished = true
            job.currentIndex = 1
            job.items[0].state = .succeeded
            job.items[1].state = .failed("下载失败：连接超时")
            job.items[2].state = .skipped("已取消")
            job.outcomes = [
                UpgradeJob.Outcome(
                    id: job.items[0].id,
                    appName: "Cherry Studio",
                    fromVersion: "1.8.4",
                    toVersion: "2.0.9",
                    succeeded: true,
                    summary: "已升级到 2.0.9 · Ed25519 签名校验通过",
                    backupPath: nil,
                    rolledBack: false,
                    warnings: [],
                    log: ""
                ),
                UpgradeJob.Outcome(
                    id: job.items[1].id,
                    appName: "IINA",
                    fromVersion: "1.3.5",
                    toVersion: "1.4.4",
                    succeeded: false,
                    summary: "下载失败：连接超时",
                    backupPath: nil,
                    rolledBack: false,
                    warnings: [],
                    log: ""
                ),
                UpgradeJob.Outcome(
                    id: job.items[2].id,
                    appName: "Mac Mouse Fix",
                    fromVersion: "3.0.0",
                    toVersion: "3.0.1",
                    succeeded: false,
                    summary: "已取消，未执行",
                    backupPath: nil,
                    rolledBack: false,
                    warnings: [],
                    log: "",
                    cancelled: true
                )
            ]
            return job
        }
    }

    /// 账本滞后态的固定样本。
    ///
    /// 名字与版本都取自本机 2026-09-16 实测的真实状态（`Proxyman` 账本 `6.12.0` 而磁盘已是
    /// `6.17.0`；`Wireshark` 账本 `4.6.4` 而磁盘已是 `4.6.8`），截图看起来才像真的。
    /// 对照关系是刻意排的：前两条是账本滞后，第三条 `iTerm2` 是同样走 Homebrew、
    /// 但账本一致的正常升级，第四条是 Sparkle 升级——四行并排才看得出附注只加在该加的地方。
    private static func makeSyntheticLedgerUpdates() -> [AppUpdate] {
        func entry(
            _ name: String,
            bundleID: String,
            source: AppSource,
            current: String,
            result: UpdateResult
        ) -> AppUpdate {
            AppUpdate(
                app: AppInfo(
                    name: name,
                    bundleID: bundleID,
                    path: URL(fileURLWithPath: "/Applications/\(name).app"),
                    currentVersion: current,
                    buildVersion: nil,
                    source: source
                ),
                result: result
            )
        }

        return [
            entry(
                "Proxyman", bundleID: "com.proxyman.NSProxy",
                source: .homebrewCask(token: "proxyman"), current: "6.17.0",
                result: .updateAvailable(ReleaseInfo(
                    version: "6.17.0", size: 41_943_040, ledgerVersion: "6.12.0"
                ))
            ),
            entry(
                "Wireshark", bundleID: "org.wireshark.Wireshark",
                source: .homebrewCask(token: "wireshark-app"), current: "4.6.8",
                result: .updateAvailable(ReleaseInfo(
                    version: "4.6.8", size: 78_118_912, ledgerVersion: "4.6.4"
                ))
            ),
            entry(
                "iTerm2", bundleID: "com.googlecode.iterm2",
                source: .homebrewCask(token: "iterm2"), current: "3.5.14",
                result: .updateAvailable(ReleaseInfo(
                    version: "3.6.0", size: 31_457_280, ledgerVersion: "3.5.14"
                ))
            ),
            entry(
                "Cherry Studio", bundleID: "com.kangfenmao.CherryStudio",
                source: .sparkle(feedURL: nil), current: "1.8.4",
                // 带上安装包地址，这一行才会渲染成正常的「升级」按钮而不是「—」。
                result: .updateAvailable(ReleaseInfo(
                    version: "2.0.9",
                    downloadURL: URL(string: "https://example.com/Cherry-Studio-2.0.9-arm64.dmg"),
                    size: 390_070_272
                ))
            ),
            entry(
                "Battery Buddy", bundleID: "com.mohamedbakhouche.BatteryBuddy",
                source: .sparkle(feedURL: nil), current: "1.0.4",
                result: .upToDate(latest: "1.0.4")
            ),
            entry(
                "IINA", bundleID: "com.colliderli.iina",
                source: .sparkle(feedURL: nil), current: "1.4.4",
                result: .upToDate(latest: "1.4.4")
            )
        ].sorted(by: AppUpdate.listOrder)
    }

    /// 三个固定的应用条目。名字取自本机真实会升级的包，截图看起来才像真的。
    private static func makeSyntheticJob() -> UpgradeJob {
        let specs: [(name: String, bundleID: String, from: String, to: String)] = [
            ("Cherry Studio", "com.kangfenmao.CherryStudio", "1.8.4", "2.0.9"),
            ("IINA", "com.colliderli.iina", "1.3.5", "1.4.4"),
            ("Mac Mouse Fix", "com.nuebling.mac-mouse-fix", "3.0.0", "3.0.1")
        ]
        return UpgradeJob(items: specs.map { spec in
            let app = AppInfo(
                name: spec.name,
                bundleID: spec.bundleID,
                path: URL(fileURLWithPath: "/Applications/\(spec.name).app"),
                currentVersion: spec.from,
                buildVersion: nil,
                source: .sparkle(feedURL: nil)
            )
            return UpgradeJob.Item(
                app: app,
                release: ReleaseInfo(version: spec.to),
                action: .replaceBundle,
                plan: nil
            )
        })
    }
}
