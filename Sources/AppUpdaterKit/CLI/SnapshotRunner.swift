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
    }

    private final class Flag {
        var value = false
        var jobPrepared = false
    }

    public static func run(
        outputPath: String,
        mode: Mode = .main,
        size: NSSize? = nil
    ) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let canvas = size ?? defaultCanvas(for: mode)

        // 菜单栏与设置是纯合成视图，不走检查流程，渲染结果完全确定。
        if let syntheticRoot = syntheticRoot(for: mode) {
            return render(syntheticRoot, canvas: canvas, outputPath: outputPath)
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
            root = AnyView(ContentView(store: store))
        case .confirm, .batch, .running, .cancelled:
            if flag.jobPrepared {
                root = AnyView(UpgradeSheet(store: store))
            } else {
                FileHandle.standardError.write(Data("没有找到可自动升级的条目，退回主窗口截图\n".utf8))
                root = AnyView(ContentView(store: store))
            }
        case .menubar, .settings:
            // 上面 syntheticRoot 已接住，不会走到这里。
            root = AnyView(EmptyView())
        }

        return render(root, canvas: canvas, outputPath: outputPath)
    }

    private static func defaultCanvas(for mode: Mode) -> NSSize {
        switch mode {
        case .main: NSSize(width: 880, height: 660)
        case .menubar: NSSize(width: 300, height: 330)
        case .settings: NSSize(width: 460, height: 320)
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
                    .padding(10)
                    .frame(width: 300, height: 440, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
        case .settings:
            let defaults = UserDefaults(suiteName: "updraft-snapshot-settings")
            let settings = AppSettings(defaults: defaults)
            settings.scheduledCheckEnabled = true
            settings.scheduledCheckHour = 10
            settings.scheduledCheckMinute = 0
            // 与 menubar 同一理由：显式定高，防止 NSHostingView 自收缩后居中裁切。
            return AnyView(
                SettingsView(settings: settings)
                    .frame(width: 440, height: 360, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
        case .main, .confirm, .batch, .running, .cancelled:
            return nil
        }
    }

    /// 造一个升级任务，把面板推到确认态。
    private static func prepareJob(store: UpdateStore, mode: Mode, flag: Flag) {
        switch mode {
        case .main, .running, .cancelled, .menubar, .settings:
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
        case .main, .confirm, .batch, .menubar, .settings:
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
