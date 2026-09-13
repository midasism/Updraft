import AppKit
import SwiftUI

/// 把真实的 ContentView 离屏渲染成 PNG，`AppUpdater --snapshot <路径>` 触发。
///
/// 走的是视图自己绘制（`cacheDisplay`），不经过窗口服务器截图，
/// 因此不需要「屏幕录制」权限，可以放进自动化流程里做界面回归对比。
@MainActor
public enum SnapshotRunner {
    private final class Flag {
        var value = false
    }

    public static func run(outputPath: String, size: NSSize = NSSize(width: 880, height: 660)) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let store = UpdateStore()
        let flag = Flag()
        Task { @MainActor in
            await store.check()
            flag.value = true
        }

        let deadline = Date().addingTimeInterval(90)
        while !flag.value, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard flag.value else {
            FileHandle.standardError.write(Data("检查超时，未生成截图\n".utf8))
            return 1
        }

        let hosting = NSHostingView(rootView: ContentView(store: store))
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
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
}
