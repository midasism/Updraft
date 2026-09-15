import AppKit
import Combine
import SwiftUI

/// 通知点击 → 界面动作 的转交点。
///
/// 通知代理（AppDelegate）与 SwiftUI 装配之间没有天然的引用通道，
/// 走这个小路由：模型启动时注册处理闭包，AppDelegate 只负责把点击事件递过来。
@MainActor
final class NotificationRouter {
    static let shared = NotificationRouter()
    var openApp: ((NotificationRoute) -> Void)?
}

/// 装配根：把状态源、设置、调度与通知拼在一起，给 Scene 层一个入口。
///
/// 职责刻意收窄——「什么时候查」归 `UpdateWatcher`，「查什么」归 `UpdateStore`（其探测
/// 永远是 `CheckEngine`），「要不要通知」归 `NotificationPolicy`，这里只做接线和窗口路由。
@MainActor
public final class AppModel: ObservableObject {
    public let store: UpdateStore
    public let settings: AppSettings
    /// lazy：初始化闭包要捕获 self（接 runCheck），必须在其余属性就绪之后才求值。
    lazy private(set) var watcher: UpdateWatcher = {
        UpdateWatcher(store: store, settings: settings) { [weak self] in
            await self?.runCheck()
        }
    }()
    private let notifier = UpdateNotifier()
    private var didStart = false
    private var bag: Set<AnyCancellable> = []
    /// 从主窗口环境里捕获的 openWindow 动作，菜单栏与通知点击都靠它开窗。
    private var openWindowAction: OpenWindowAction?

    public convenience init() {
        self.init(store: UpdateStore(), settings: AppSettings())
    }

    /// 供测试注入假探针与临时缓存/设置用。
    init(store: UpdateStore, settings: AppSettings) {
        self.store = store
        self.settings = settings

        // 把子对象的变化转发出去：Scene 级的徽标、菜单栏标签都依赖这个刷新。
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)

        NotificationRouter.shared.openApp = { [weak self] route in
            self?.openMainWindow(route: route)
        }
    }

    /// 启动：先跑原有的恢复/冷启动检查，再启动定时器。
    ///
    /// 这个顺序避免冷启动无缓存时「checkIfNeeded 全量检查」与调度器的补查同时抢跑；
    /// 有缓存时 checkIfNeeded 只检查 Updraft 自身，随后 watcher 第一拍仍会立即接住错过的时段。
    /// 幂等——窗口重开不会重复启动。
    func start() {
        guard !didStart else { return }
        didStart = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.store.checkIfNeeded()
            self.watcher.start()
        }
    }

    // MARK: - 检查入口

    /// 菜单栏「立即检查」：与主窗口「重新检查」同一条路径（store.check → CheckEngine），
    /// 差别只在收尾——窗口看不见时用系统通知把结果递出去。
    func checkNowFromMenuBar() {
        guard !store.isBusy else { return }
        Task { await runCheck() }
    }

    private func runCheck() async {
        // 每日/菜单栏检查同时覆盖「应用更新」与「Updraft 自更新」；两者独立失败、互不清空。
        // 主应用检查仍然原封不动走 UpdateStore.check → CheckEngine，没有另写探测逻辑。
        async let apps: Void = store.check()
        async let selfUpdate: Void = store.checkSelfUpdate()
        _ = await (apps, selfUpdate)
        await notifyAfterCheck()
    }

    private func notifyAfterCheck() async {
        if NotificationPolicy.shouldNotify(
            updateCount: store.updateCount,
            notificationsEnabled: settings.notificationsEnabled,
            mainWindowVisible: mainWindowVisible
        ) {
            let names = Array(store.updates(in: .updateAvailable).prefix(3).map(\.app.name))
            await notifier.notifyUpdates(count: store.updateCount, sample: names)
        }

        if case .updateAvailable(let release) = store.selfStatus,
           NotificationPolicy.shouldNotify(
               updateCount: 1,
               notificationsEnabled: settings.notificationsEnabled,
               mainWindowVisible: mainWindowVisible
           ) {
            await notifier.notifySelfUpdate(
                from: SelfUpdateIdentity.currentShortVersion ?? "未知",
                to: release.version
            )
        }
    }

    /// 主窗口是否在用户眼前。找的是 WindowGroup 的标题； SwiftUI 窗口没有稳定的
    /// identifier 可查，标题是这里唯一可靠的锚点。
    var mainWindowVisible: Bool {
        NSApp.windows.contains {
            $0.title == "App 更新" && $0.isVisible && !$0.isMiniaturized
        }
    }

    // MARK: - 窗口路由

    /// 从主窗口的 SwiftUI 环境里捕获 openWindow（onAppear 时调用）。
    /// 冷启动状态恢复成「窗口关闭」的极端情况下，菜单栏打开一次也会补上。
    func capture(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    /// 打开（或聚焦）主窗口。通知点击、菜单栏动作共用。
    /// 自更新通知先把确认页状态置上，再开窗；应用已经退出时系统默认开的主窗口也会读到它。
    func openMainWindow(route: NotificationRoute? = nil) {
        if route == .selfUpdate {
            store.presentSelfUpdate()
        }
        openWindowAction?(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 打开设置窗口（⌘, / 菜单栏 / 主窗口齿轮三个入口共用）。
    func openSettings() {
        openWindowAction?(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 设置里打开通知开关时请求授权，让系统弹窗出现在用户动作的上下文里。
    func requestNotificationAuthorization() {
        Task { await notifier.requestAuthorizationIfNeeded() }
    }

    // MARK: - 菜单栏状态

    /// 菜单栏下拉要显示的状态快照。独立成值类型，截图通道可以用合成数据渲染。
    func menuBarStatus() -> MenuBarStatus {
        MenuBarStatus(
            isChecking: store.isChecking,
            updateCount: store.updateCount,
            hasResult: !store.updates.isEmpty,
            lastCheckedText: store.lastCheckedText,
            scheduleText: settings.scheduleText
        )
    }
}
