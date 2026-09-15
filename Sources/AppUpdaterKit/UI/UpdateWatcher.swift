import AppKit
import Combine
import Foundation

/// 每日定时检查的运行时编排。
///
/// 只回答「什么时候查」：分钟级轮询 + 系统唤醒监听，到点把决定权交给 `CheckPlanner`，
/// 触发时调用注入的 `fire`（装配层把它接到 `UpdateStore.check()`）——
/// **怎么查永远是 CheckEngine 那一条路**，这里没有也不该有第二套探测逻辑。
///
/// 「错过的时段恢复后补查」不是特殊分支：唤醒/冷启动后的第一次轮询看到的
/// 就是「时刻已过且今天没查」，按普通到点处理，实际在唤醒后一个轮询周期内（秒级）触发。
@MainActor
final class UpdateWatcher: ObservableObject {
    /// 轮询周期。到点触发的最迟延迟 = 一个周期；30 秒对「每日检查」足够准。
    private static let tickInterval: TimeInterval = 30

    private let planner: CheckPlanner
    /// 强持有：装配关系是 AppModel → watcher → store，无环。
    /// 曾经用 weak，结果测试里局部构造的 store 在返回后就被释放、tick 静默失效——
    /// weak 在这里换不来任何安全性，只换来一个坑。
    private let store: UpdateStore
    private let settings: AppSettings
    private let fire: () async -> Void

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var settingsCancellable: AnyCancellable?
    /// 上次自己触发检查的时刻。今天触发过就不再触发，兜住「检查在跑、lastChecked 还没落定」的窗口。
    private var lastTriggered: Date?

    init(
        store: UpdateStore,
        settings: AppSettings,
        planner: CheckPlanner = CheckPlanner(),
        fire: @escaping () async -> Void
    ) {
        self.store = store
        self.settings = settings
        self.planner = planner
        self.fire = fire
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            // 计时器挂在主 RunLoop 上，回调一定在主线程。
            MainActor.assumeIsolated {
                self?.tick()
            }
        }

        // 设置一变立刻重估：关掉定时开关后最迟一个周期内不再触发，通常即时。
        settingsCancellable = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }

        // 合盖/系统睡眠恢复后立即轮询一次——错过的时段在这里接住。
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }

        // 冷启动也先轮询一次：关机错过当天时段的，启动后立即补查。
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        settingsCancellable?.cancel()
        settingsCancellable = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// 一次判定。`now` 可注入，调度与当日去重的测试不依赖真实时间。
    func tick(now: Date = Date()) {
        guard !store.isCheckBlocked else { return }
        guard planner.isDue(
            schedule: settings.schedule,
            lastSatisfied: store.lastCheckStartedAt,
            lastTriggered: lastTriggered,
            now: now
        ) else { return }

        lastTriggered = now
        Task { @MainActor [weak self, fire] in
            guard let self else { return }
            // tick 返回到 fire 真正开跑之间，用户可能刚好开始安装。此时把本次触发撤回，
            // 不吃掉今天的机会；安装结束后下一拍会重试。
            guard !self.store.isCheckBlocked else {
                if self.lastTriggered == now { self.lastTriggered = nil }
                return
            }
            await fire()
        }
    }
}
