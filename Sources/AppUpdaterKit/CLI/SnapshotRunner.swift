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

        let canvas = size ?? (mode == .main ? NSSize(width: 880, height: 660) : NSSize(width: 600, height: 540))

        let store = UpdateStore()
        let flag = Flag()
        Task { @MainActor in
            await store.check()
            prepareJob(store: store, mode: mode, flag: flag)
            flag.value = true
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
        case .confirm, .batch:
            if flag.jobPrepared {
                root = AnyView(UpgradeSheet(store: store))
            } else {
                FileHandle.standardError.write(Data("没有找到可自动升级的条目，退回主窗口截图\n".utf8))
                root = AnyView(ContentView(store: store))
            }
        }

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

    /// 造一个升级任务，把面板推到确认态。
    private static func prepareJob(store: UpdateStore, mode: Mode, flag: Flag) {
        switch mode {
        case .main:
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
}
