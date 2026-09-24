import SwiftUI

/// 设置页里「备份」那一节要的全部状态。
///
/// 抽成值类型而不是把 `UpdateStore` 直接传进来：截图通道需要渲染一张带确定数字的
/// 设置页，而它没有、也不该有一个真去遍历备份目录的 store。
struct BackupPanelState: Equatable {
    /// 已量到的占用字节数；`nil` 表示还没量过。
    var bytes: Int64?
    /// 正在清理。
    var isBusy: Bool = false

    static let unknown = BackupPanelState(bytes: nil)
}

/// 设置窗口内容：菜单栏图标开关、定时检查开关 + 时刻、通知开关、备份占用与清理。
///
/// 不用 `Form`：离屏截图的 `NSHostingView` 会把 Form 的标签列裁出画布，
/// 真窗口里也偏挤。改成和主窗口同一套 VStack，改完即写回 `AppSettings`，没有「保存」按钮。
/// 打开通知开关时请求一次系统授权，让弹窗出现在用户动作的上下文里。
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// 打开通知开关时触发授权请求；默认 nil（截图通道用合成设置，不需要真授权）。
    var onNotificationsEnabled: (() -> Void)?
    /// 备份占用与清理状态。
    var backups: BackupPanelState = .unknown
    /// 窗口出现时请上层去量一次占用（量一次要遍历整棵树，不能在视图里同步做）。
    var onRefreshBackups: (() -> Void)?
    /// 用户确认清理后回调。
    var onClearBackups: (() -> Void)?

    /// 清理是两步：先点「清理备份…」，按钮就地换成确认与取消。
    ///
    /// 刻意**不用** `confirmationDialog`/`alert`：一是不值得为这一个动作引入模态，
    /// 二是本项目已经踩过「模态面板挂着时 `NSApp.terminate` 是空操作」这个坑
    /// （见 `SelfQuit` 的对照表）——用户开着确认框去退出应用却退不掉，比多点一下糟得多。
    /// 就地确认还能被截图通道复现（`--mode settings-confirm`）。
    @State private var confirmingClear: Bool

    init(
        settings: AppSettings,
        onNotificationsEnabled: (() -> Void)? = nil,
        backups: BackupPanelState = .unknown,
        onRefreshBackups: (() -> Void)? = nil,
        onClearBackups: (() -> Void)? = nil,
        confirmingClear: Bool = false
    ) {
        self.settings = settings
        self.onNotificationsEnabled = onNotificationsEnabled
        self.backups = backups
        self.onRefreshBackups = onRefreshBackups
        self.onClearBackups = onClearBackups
        _confirmingClear = State(initialValue: confirmingClear)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("菜单栏") {
                Toggle("显示菜单栏图标", isOn: $settings.menuBarIconVisible)
                Text("图标旁的数字是待更新数，点开就能「立即检查」。关掉后屏幕顶部不再有它——回程是从 Dock 图标打开主窗口，或按 ⌘, 打开本页。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !settings.menuBarIconVisible && !settings.notificationsEnabled {
                    // 两个出口都关掉时后台照跑，但用户将看不到任何迹象——这句话是那次
                    // 「查了跟没查一样」的唯一提示。只在这里组合判断，不改开关本身的行为。
                    Text("图标与通知都关着：定时检查照常跑，但结果不会有任何提示。")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

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

            Divider()

            section("备份") {
                HStack {
                    Text("旧版本备份")
                    Spacer(minLength: 12)
                    Text(UpdateStore.backupUsageText(bytes: backups.bytes))
                        .foregroundStyle(.secondary)
                }
                Text("换包前会把旧版本整包备份到这里；每个应用只保留最近 1 份。清理后无法恢复。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if backups.isBusy {
                    Text("正在清理…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if confirmingClear {
                    HStack(spacing: 10) {
                        Button("确认清理，无法恢复") {
                            confirmingClear = false
                            onClearBackups?()
                        }
                        Button("取消") { confirmingClear = false }
                    }
                    .font(.system(size: 12))
                } else {
                    Button("清理备份…") { confirmingClear = true }
                        .disabled(!hasBackups)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { onRefreshBackups?() }
    }

    /// 没有备份可清时不给点——省掉一次「点了没反应」的困惑。
    private var hasBackups: Bool { (backups.bytes ?? 0) > 0 }

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
