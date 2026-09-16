import AppKit
import Foundation

/// 自更新成功后，把自己这个进程送走。
///
/// ## 为什么不能只写一行 `NSApp.terminate(nil)`
///
/// **面板（sheet）还挂着时，`NSApp.terminate` 是空操作。** 2026-09-16 用与 Updraft 同构的
/// 最小工程（SwiftUI `WindowGroup` + `sheet` + `MenuBarExtra`）做了四组对照：
///
/// | 场景 | `NSApp.terminate(nil)` 的结果 |
/// |---|---|
/// | 没有 sheet | 正常退出：`applicationShouldTerminate` 被问到 → `applicationWillTerminate` → 进程结束 |
/// | **sheet 挂着** | 调用后 14 毫秒返回，**delegate 压根没被问**，进程继续跑 |
/// | 先把 sheet 收起来再退出 | 正常退出 |
/// | sheet 挂着直接 `exit(0)` | 正常退出 |
///
/// 真机后果就是「升级明明成功了，旧进程却赖着不走」——用户只能手动关。而手动关掉恰好
/// 先收起了面板，所以手动操作反而是"正常"的。这正是 v0.3.1 收到的那条反馈。
///
/// ## 所以这里做三步
///
/// 1. **先收起面板**（调用方负责）：让模态会话结束，后续的退出请求才有效；
/// 2. **宽限期后走优雅退出**：`NSApp.terminate` 会问 delegate、会走 `applicationWillTerminate`、
///    正常保存窗口状态；
/// 3. **再宽限一小会儿还活着，就 `exit(0)` 兜底**。
///
/// 第 3 步不是"以防万一"的装饰。升级已经落盘了，一个赖着不走的旧进程代价很大：用户以为
/// 没升级、菜单栏多出一个图标、下次启动的还是旧版本。相比之下少保存一次窗口状态无所谓。
enum SelfQuit {
    /// 发出优雅退出请求前的等待：给界面一次机会把「已升级」这一帧画出来。
    static let settleDelay: TimeInterval = 0.6
    /// 优雅退出之后的额外宽限。AppKit 正常退出在毫秒级完成，1 秒已经很宽裕。
    static let forceExitDelay: TimeInterval = 1.0

    /// 请求退出当前进程。
    ///
    /// 不参数化时间、也不做单元测试：这两步走的都是 AppKit 的生命周期行为，
    /// 断言不了（真实结论只能靠真机跑一遍自更新）。这里的价值在注释里的那张对照表。
    static func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
            NSApp.terminate(nil)
        }
        // 兜底放全局队列：主线程哪怕被什么卡住，这条照跑。
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + settleDelay + forceExitDelay) {
            exit(0)
        }
    }
}
