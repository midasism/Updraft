import Foundation
import UserNotifications

/// 通知点击后要去哪。应用更新开主窗口，自更新直达确认页。
public enum NotificationRoute: String {
    case updates = "updraft.updates-available"
    case selfUpdate = "updraft.self-update-available"
}

/// 通知与否的判定，拆成纯函数便于单测。
public enum NotificationPolicy {
    /// 有可更新应用 && 通知开关开着 && 主窗口不可见（用户正看着结果时再弹通知纯属打扰）。
    public static func shouldNotify(
        updateCount: Int,
        notificationsEnabled: Bool,
        mainWindowVisible: Bool
    ) -> Bool {
        updateCount > 0 && notificationsEnabled && !mainWindowVisible
    }
}

/// 系统通知的收发。权限被拒时不打扰：静默跳过，更新状态照旧反映在菜单栏图标上。
///
/// 裸可执行文件（无 bundle）拿不到 UNUserNotificationCenter（一碰就崩），
/// 所以每个入口都先探一下进程有没有 bundle identifier——swift run 的开发形态下
/// 通知功能整体退化为 no-op，菜单栏与主窗口不受影响。
@MainActor
final class UpdateNotifier {
    /// 用户在设置里打开通知开关时同步请求授权，让系统弹窗出现在用户动作的上下文里，
    /// 而不是深夜定时检查时突然弹一个。
    func requestAuthorizationIfNeeded() async {
        guard isNotificationCapable else { return }
        _ = await granted(requestingIfNeeded: true)
    }

    /// 「发现 N 个应用可更新」。`sample` 是列表里前几个名字，让通知自带信息量。
    func notifyUpdates(count: Int, sample: [String]) async {
        // 发通知时不再请求授权：深夜定时检查弹系统权限框是打扰。
        // 授权只在启动（用户刚打开应用）和打开通知开关时请求。
        guard isNotificationCapable, await granted(requestingIfNeeded: false) else { return }

        let content = UNMutableNotificationContent()
        content.title = "发现 \(count) 个应用可更新"
        if sample.isEmpty {
            content.body = "点按打开主窗口查看。"
        } else {
            let suffix = count > sample.count ? " 等" : ""
            content.body = "\(sample.joined(separator: "、"))\(suffix)有新版本。"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: NotificationRoute.updates.rawValue,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// 自更新可用的专用通知。点击后由 `.selfUpdate` 路由直达自更新确认页。
    func notifySelfUpdate(from: String, to: String) async {
        guard isNotificationCapable, await granted(requestingIfNeeded: false) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Updraft 有新版本"
        content.body = "\(from) → \(to)，点按查看详情。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: NotificationRoute.selfUpdate.rawValue,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private var isNotificationCapable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func granted(requestingIfNeeded: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            // 被拒就不打扰，也不反复请求。
            return false
        case .notDetermined:
            guard requestingIfNeeded else { return false }
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }
}
