import AppKit
import SwiftUI

public struct AppUpdaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UpdateStore()

    public init() {}

    public var body: some Scene {
        WindowGroup("App 更新") {
            ContentView(store: store)
                .task {
                    // 自身更新与列表检查并行：前者只发一个 API 请求，不该排在整机扫描后面。
                    async let selfCheck: Void = store.checkSelfIfNeeded()
                    async let listCheck: Void = store.checkIfNeeded()
                    _ = await (selfCheck, listCheck)
                }
        }
        .defaultSize(width: 820, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // 放进应用菜单（「关于」下面），不在窗口里再占一个按钮——
            // 自身更新是低频动作，藏在菜单里符合 macOS 的习惯。
            CommandGroup(after: .appInfo) {
                Divider()
                Button("检查更新…") {
                    Task {
                        await store.checkSelfUpdate(force: true)
                        store.presentSelfUpdateSheet()
                    }
                }
                Button("打开 Updraft 发布页面") {
                    store.openReleasePage()
                }
            }
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
