import AppKit
import SwiftUI
import UserNotifications

public struct UpdraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    public init() {}

    public var body: some Scene {
        WindowGroup("Updraft", id: "main") {
            MainWindowRoot(model: model)
        }
        .defaultSize(width: 820, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("检查 Updraft 更新…") {
                    model.store.presentSelfUpdate()
                    Task { await model.store.checkSelfUpdate() }
                }
            }
        }

        // 独立小窗口而不是 sheet：菜单栏触发的场景里主窗口可能是关着的，设置要能独立到达。
        WindowGroup("设置", id: "settings") {
            SettingsSceneRoot(model: model)
        }
        .windowResizability(.contentSize)

        menuBarBase
    }

    private var menuBarBase: some Scene {
        MenuBarExtra {
            MenuBarExtraRoot(model: model)
        } label: {
            menuLabel
        }
        .menuBarExtraStyle(.menu)
    }

    /// 待更新数量徽标走「图标旁数字」而不是系统的 Scene.badge：后者 macOS 14+ 才有，
    /// 而 SceneBuilder 不支持 `if #available`（没有 buildLimitedAvailability），
    /// 分不了支。图标+数字在 13/14/15 上行为一致，读起来也是一个徽标。
    @ViewBuilder
    private var menuLabel: some View {
        if model.store.updateCount > 0 {
            Label("\(model.store.updateCount)", systemImage: "arrow.triangle.2.circlepath")
        } else {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
    }
}

/// 设置窗口的装配壳。
///
/// 存在的理由只有一个：`SettingsView` 本身只观察 `AppSettings`，看不见 `UpdateStore`。
/// 而备份占用与清理状态都在 store 上——少了这层，清理完界面不会重画
/// （`@Published` 改了，但没有任何视图订阅它）。
///
/// 也让 `SettingsView` 保持「只吃值」：截图通道要用合成数字渲染同一张页面，
/// 不必为了画一张图去碰真实的备份目录。
struct SettingsSceneRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsView(
            settings: model.settings,
            onNotificationsEnabled: {
                model.requestNotificationAuthorization()
            },
            backups: BackupPanelState(
                bytes: model.store.backupUsage,
                isBusy: model.store.isClearingBackups
            ),
            onRefreshBackups: {
                Task { await model.store.refreshBackupUsage() }
            },
            onClearBackups: {
                Task { await model.store.clearBackups() }
            }
        )
    }
}

/// 菜单栏下拉的装配壳：每次打开菜单时刷新 openWindow，主窗口从未出现过也能开窗。
struct MenuBarExtraRoot: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        MenuBarContent(
            status: model.menuBarStatus(),
            actions: .init(
                checkNow: { model.checkNowFromMenuBar() },
                openMain: {
                    model.capture(openWindow: openWindow)
                    model.openMainWindow()
                },
                openSettings: {
                    model.capture(openWindow: openWindow)
                    model.openSettings()
                },
                quit: {
                    guard !model.store.isInstallingSelf, model.store.job?.isRunning != true else { return }
                    NSApp.terminate(nil)
                }
            )
        )
    }
}

/// 主窗口的装配壳：捕获 openWindow（菜单栏与通知点击开窗都靠它）并启动模型。
struct MainWindowRoot: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        ContentView(store: model.store, openSettings: { model.openSettings() })
            .onAppear { model.capture(openWindow: openWindow) }
            .task { model.start() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var shared: AppDelegate?
    var canTerminate: (() -> Bool)?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        canTerminate?() == false ? .terminateCancel : .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 以 SwiftPM 直接跑可执行文件时没有 bundle，需要手动把进程提升为前台应用。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 通知代理要尽早设置：冷启动前后送达的通知才点得动。
        // 裸可执行文件（无 bundle）不能碰 UNUserNotificationCenter，跳过。
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关掉窗口不退出，⌘Q 才退出——菜单栏常驻与定时检查都依赖这条。
        false
    }

    // MARK: - 通知代理

    /// 应用在前台也让通知以横幅出现（菜单栏触发的检查经常发生在没有窗口时）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// 点通知 → 打开主窗口；自更新通知走专用路由并直达确认页。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = NotificationRoute(rawValue: response.notification.request.identifier)
        DispatchQueue.main.async {
            NotificationRouter.shared.openApp?(route ?? .updates)
        }
        completionHandler()
    }
}
