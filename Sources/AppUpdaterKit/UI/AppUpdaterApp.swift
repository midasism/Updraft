import AppKit
import SwiftUI

public struct AppUpdaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UpdateStore()

    public init() {}

    public var body: some Scene {
        WindowGroup("App 更新") {
            ContentView(store: store)
                .task { await store.checkIfNeeded() }
        }
        .defaultSize(width: 820, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 以 SwiftPM 直接跑可执行文件时没有 bundle，需要手动把进程提升为前台应用。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关掉窗口不退出，⌘Q 才退出。
        false
    }
}
