import Combine
import Foundation

/// 应用设置：定时检查开关/时刻、系统通知开关。UserDefaults 固定 suite 持久化。
///
/// 固定 suite（与打包脚本的 BUNDLE_ID 一致）而不是 `standard`，理由和 StateCache
/// 固定路径相同：这个工具既能以 `.app` 包跑、也能裸跑可执行文件（swift run / 直调二进制），
/// `standard` 在两种形态下是两个不同的域，设置会互相看不见。
@MainActor
public final class AppSettings: ObservableObject {
    /// 与 `scripts/build-app.sh` 的 BUNDLE_ID 保持一致；.app 形态下与 standard 同域。
    public static let suiteName = "com.local.appupdater"

    private enum Key {
        static let scheduledEnabled = "check.schedule.enabled"
        static let scheduledHour = "check.schedule.hour"
        static let scheduledMinute = "check.schedule.minute"
        static let notificationsEnabled = "notifications.enabled"
    }

    /// 默认开启、每天 10:00 检查——这个功能的意义就是「后台自动盯着」，
    /// 装完默认生效；打扰与否交给通知开关和系统权限。
    private static let defaultHour = 10
    private static let defaultMinute = 0

    private let defaults: UserDefaults

    @Published public var scheduledCheckEnabled: Bool {
        didSet { defaults.set(scheduledCheckEnabled, forKey: Key.scheduledEnabled) }
    }

    @Published public var scheduledCheckHour: Int {
        didSet { defaults.set(scheduledCheckHour, forKey: Key.scheduledHour) }
    }

    @Published public var scheduledCheckMinute: Int {
        didSet { defaults.set(scheduledCheckMinute, forKey: Key.scheduledMinute) }
    }

    @Published public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    /// - Parameter defaults: 注入临时 suite 供测试与截图通道用；默认持久化到固定 suite。
    public init(defaults: UserDefaults? = nil) {
        let store = defaults ?? UserDefaults(suiteName: Self.suiteName)
        self.defaults = store ?? .standard

        // 读取时钳制：手改 plist 写出界（hour=25 之类）不该让调度器拿到非法时刻。
        scheduledCheckEnabled = store?.object(forKey: Key.scheduledEnabled) as? Bool ?? true
        scheduledCheckHour = (store?.object(forKey: Key.scheduledHour) as? Int)
            .map { min(max($0, 0), 23) } ?? Self.defaultHour
        scheduledCheckMinute = (store?.object(forKey: Key.scheduledMinute) as? Int)
            .map { min(max($0, 0), 59) } ?? Self.defaultMinute
        notificationsEnabled = store?.object(forKey: Key.notificationsEnabled) as? Bool ?? true
    }

    /// 给调度器用的快照。
    public var schedule: CheckSchedule {
        CheckSchedule(isEnabled: scheduledCheckEnabled, hour: scheduledCheckHour, minute: scheduledCheckMinute)
    }

    /// 菜单栏里的「定时检查：每天 10:00 / 已关闭」。
    public var scheduleText: String {
        guard scheduledCheckEnabled else { return "定时检查：已关闭" }
        return "定时检查：每天 \(String(format: "%02d:%02d", scheduledCheckHour, scheduledCheckMinute))"
    }
}
