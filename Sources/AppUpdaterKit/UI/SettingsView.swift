import SwiftUI

/// 设置窗口内容：定时检查开关 + 时刻、通知开关。
///
/// 不用 `Form`：离屏截图的 `NSHostingView` 会把 Form 的标签列裁出画布，
/// 真窗口里也偏挤。改成和主窗口同一套 VStack，改完即写回 `AppSettings`，没有「保存」按钮。
/// 打开通知开关时请求一次系统授权，让弹窗出现在用户动作的上下文里。
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// 打开通知开关时触发授权请求；默认 nil（截图通道用合成设置，不需要真授权）。
    var onNotificationsEnabled: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("定时检查") {
                Toggle("每日定时检查", isOn: $settings.scheduledCheckEnabled)
                if settings.scheduledCheckEnabled {
                    HStack {
                        Text("检查时间")
                        Spacer(minLength: 12)
                        DatePicker(
                            "",
                            selection: timeBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .frame(width: 96)
                    }
                    Text("到点在后台自动检查；错过时段（合盖、关机）恢复后补查一次；当天已查过不再重复。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            section("通知") {
                Toggle("更新通知", isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) { enabled in
                        if enabled { onNotificationsEnabled?() }
                    }
                if settings.notificationsEnabled {
                    Text("发现可更新应用时发系统通知，点按打开主窗口。权限被拒后不再打扰，状态仍显示在菜单栏图标上。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    /// DatePicker 要 Date，设置里存的是时分两个整数，进出各转一次。
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: settings.scheduledCheckHour,
                    minute: settings.scheduledCheckMinute,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { picked in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
                if let hour = parts.hour { settings.scheduledCheckHour = hour }
                if let minute = parts.minute { settings.scheduledCheckMinute = minute }
            }
        )
    }
}
