import Combine
import Foundation

/// 应用设置：菜单栏图标开关、定时检查开关/时刻、系统通知开关。UserDefaults 固定 suite 持久化。
///
/// 固定 suite（而不是 `standard`）的理由和 StateCache 固定路径相同：这个工具既能以
/// `.app` 包跑、也能裸跑可执行文件（swift run / 直调二进制），`standard` 在两种形态下
/// 是两个不同的域，设置会互相看不见。
///
/// ⚠️ suite 名**不能等于自己的 bundle id**：macOS 会让 `UserDefaults(suiteName:)` 直接
/// 返回 nil（详见 `SelfUpdateIdentity.settingsSuiteName`）。历史版本正是踩在这里——
/// 读值走 nil 回退默认、写值走 `.standard`，表现成「设置改了不生效、重启回默认」。
@MainActor
public final class AppSettings: ObservableObject {
    /// 刻意与 bundle id 错开，理由见 `SelfUpdateIdentity.settingsSuiteName`。
    ///
    /// `nonisolated`：它是纯常量，而 `resolveStore` 的默认参数在非 MainActor 上下文求值
    /// （少了它会报 "main actor-isolated static property can not be referenced from a
    /// nonisolated context"）。测试也能从非 MainActor 的用例里直接读。
    public nonisolated static let suiteName = SelfUpdateIdentity.settingsSuiteName

    private enum Key {
        static let menuBarIconVisible = "menubar.icon.visible"
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

    /// 屏幕顶部菜单栏图标是否常驻。默认开——它同时是「看一眼还剩几个可更新」和
    /// 「隐藏主窗口后的入口」，不该默认收起来。关掉后**只影响这个图标**：
    /// 定时检查、通知、⌘Q 语义都不变（调度跟应用生命周期走，不挂在 NSStatusItem 上）。
    @Published public var menuBarIconVisible: Bool {
        didSet { defaults.set(menuBarIconVisible, forKey: Key.menuBarIconVisible) }
    }

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
        // 先定下**真正落盘的那个 store**，再拿它读值。读和写必须走同一个 store——
        // 早先这里读的是 `store`（未回退的 optional），写的是 `store ?? .standard`，
        // 于是 suite 被系统拒掉时两边错位：「存得进、读不回」。
        let resolved = Self.resolveStore(injected: defaults)
        self.defaults = resolved

        menuBarIconVisible = Self.boolValue(in: resolved, key: Key.menuBarIconVisible) ?? true
        scheduledCheckEnabled = Self.boolValue(in: resolved, key: Key.scheduledEnabled) ?? true
        scheduledCheckHour = min(max(Self.intValue(in: resolved, key: Key.scheduledHour) ?? Self.defaultHour, 0), 23)
        scheduledCheckMinute = min(max(Self.intValue(in: resolved, key: Key.scheduledMinute) ?? Self.defaultMinute, 0), 59)
        notificationsEnabled = Self.boolValue(in: resolved, key: Key.notificationsEnabled) ?? true
    }

    /// 解析出真正落盘的 store。抽成单独的纯函数是为了能被测——`UserDefaults(suiteName:)`
    /// 返回 nil 那条路（suite 名撞了 bundle id）只在真机上出现，进程内造不出来，
    /// 所以把「造 suite」这一步做成可注入的。
    ///
    /// 退路是 `.standard`：`.app` 形态下它与固定 suite 指向同一个 plist，裸跑形态下
    /// suite 本身可用、走不到这里。
    static func resolveStore(
        injected: UserDefaults? = nil,
        suiteName: String = AppSettings.suiteName,
        suiteFactory: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) -> UserDefaults {
        injected ?? suiteFactory(suiteName) ?? .standard
    }

    // MARK: - 值解析

    /// suite 里的值不一定是我们自己写进去的：`defaults` 命令行与手改 plist 都可能把数字
    /// 存成字符串（实测 `defaults write dom key 7` 读回来是 NSTaggedPointerString "7"，
    /// `as? Int` 直接落空、静默回退默认值）。两类都收，越界在上一层钳制。
    private static func intValue(in store: UserDefaults?, key: String) -> Int? {
        guard let value = store?.object(forKey: key) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func boolValue(in store: UserDefaults?, key: String) -> Bool? {
        guard let value = store?.object(forKey: key) else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
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
