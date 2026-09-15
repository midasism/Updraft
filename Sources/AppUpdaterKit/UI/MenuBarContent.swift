import AppKit
import SwiftUI

/// 菜单栏下拉的状态快照（值类型，截图通道可注入合成数据）。
struct MenuBarStatus: Equatable {
    var isChecking = false
    var isInstalling = false
    var updateCount = 0
    var hasResult = false
    var lastCheckedText = "尚未检查"
    var scheduleText = ""
}

/// 菜单栏下拉内容。`.menu` 风格下渲染为原生菜单：`Text` 是置灰的说明行，
/// `Button` 是普通菜单项。动作走闭包注入，视图本身不持有模型——截图与测试可以传桩。
struct MenuBarContent: View {
    let status: MenuBarStatus
    let actions: Actions

    struct Actions {
        let checkNow: () -> Void
        let openMain: () -> Void
        let openSettings: () -> Void
        let quit: () -> Void
    }

    var body: some View {
        Text(headline)
        Text(status.lastCheckedText)
        if !status.scheduleText.isEmpty {
            Text(status.scheduleText)
        }
        Divider()
        Button(checkTitle) { actions.checkNow() }
            .disabled(status.isChecking || status.isInstalling)
        Button("打开主窗口") { actions.openMain() }
        Button("设置…") { actions.openSettings() }
        Divider()
        Button("退出 Updraft") { actions.quit() }
            .disabled(status.isInstalling)
    }

    private var checkTitle: String {
        if status.isInstalling { return "安装中，暂不检查" }
        return status.isChecking ? "正在检查…" : "立即检查"
    }

    private var headline: String {
        if status.isChecking { return "正在检查更新…" }
        if !status.hasResult { return "尚未检查" }
        return status.updateCount > 0 ? "\(status.updateCount) 个应用可更新" : "全部应用已是最新"
    }
}
