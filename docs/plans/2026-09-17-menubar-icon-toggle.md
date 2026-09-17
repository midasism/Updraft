# 实施计划：菜单栏图标可关闭（设置里决定是否展示）

日期：2026-09-17 ｜ 分支：`feat/menubar-icon-toggle` ｜ 起点：main `f705bfb`（v0.3.7）

## 一、需求

设置里加一个开关，决定要不要在屏幕顶部（菜单栏）展示 Updraft 的小图标。默认展示——
它同时是「一眼看到还剩几个可更新」和「关掉主窗口后的入口」，不该默认收起来。

## 二、方案

`MenuBarExtra` 有 `init(isInserted:)`（macOS 13.0+，与本包最低版本一致），直接用它：

- `AppSettings` 新增 `menuBarIconVisible`（键 `menubar.icon.visible`，默认 `true`）；
- `UpdraftApp.menuBarBase` 把计算属性给出的 `Binding<Bool>` 交给 `isInserted`；
- `SettingsView` 新增「菜单栏」一节（放在最前），开关 + 一行回程说明。

**没有**改的地方也是决定的一部分：

| 不改 | 理由 |
|---|---|
| 调度器 / 通知 | 它们跟 `NSApplication` 生命周期走，不挂在 `NSStatusItem` 上。关图标不动后台检查 |
| 退出语义（⌘Q、关窗不退出） | 与图标无关；应用仍是 `.regular`，Dock 图标在，回程不缺 |
| Dock 点击重开主窗口 | 没动 `applicationShouldHandleReopen`：SwiftUI 自己会重开 WindowGroup，我们再插一手有「开出第二个主窗口」的风险，而收益只是省一次 ⌘, |

### 回程怎么走（关掉图标之后）

1. Dock 图标 → 主窗口（SwiftUI 对 `WindowGroup` 的默认 reopen 行为）；
2. 应用激活时按 ⌘,（`CommandGroup(replacing: .appSettings)` 一直在）→ 设置窗口；
3. 设置页那一行说明就是把这两条路写出来，没指望用户自己想。

## 三、一个必须记住的坑：`isInserted` 的绑定会**写得回**，`@Published` 会**死循环**

这是本次唯一的真风险，实测出来的。

### 现象

同构最小工程（`/tmp/probe-menubar`，`@StateObject` + `Binding` + `MenuBarExtra(isInserted:)`，
每 2 秒翻一次开关）第一次跑：切换后**所有计时器停摆**——挂在主 RunLoop 上的 `Timer` 停了，
连挂在全局队列的 `DispatchSourceTimer` 也打不出第二行。`kill -0` 说进程活着。

### 定位

| 手段 | 结果 |
|---|---|
| `/usr/bin/sample <pid> 2` | 主线程 1083 个采样**全在同一处**：`AppGraph.updateGraph → graphDidChange → AppDelegate.scenesDidChange(phaseChanged:) → makeMainMenu → … → ViewRendererHost.updateViewGraph` |
| 后台看门狗（只写文件、不碰主线程） | 主线程卡住期间照样每秒落一行：`gets=40585 sets=20291 lastSet=false`，**约 7000 次/秒**，且写回的值一直是「当前值」 |

判定：不是死锁，是**活锁**。SwiftUI 每次更新场景图都会把 `isInserted` 的当前值**原样写回**绑定；
`@Published` 对「写同一个值」照样发 `objectWillChange`（判定在 `willSet`，写在 `didSet` 里拦不住），
于是 `写回 → App 体重算 → 再写回` 自我维持，主线程再也不回 RunLoop。

### 修法

绑定 setter 里「值没变就不写」：

```swift
set: { visible in
    guard model.settings.menuBarIconVisible != visible else { return }
    model.settings.menuBarIconVisible = visible
}
```

同工程复测：绑定 get/set 计数从 **40585 / 20291** 落到 **13 / 10**，行程表恢复，
状态项按预期拔插。`UpdraftApp` 里那三行的注释写的就是这件事，**别当冗余判断删掉**。

## 四、验证实况（本机，2026-09-17）

本机只有 CLT（`swift test` 不可用），走四层证据，逐层往「真」上靠。

### 1. 同构最小工程的对照实验（机制层，权威）

`/tmp/probe-menubar/Probe.app`（`swiftc -parse-as-library` + 手搓 Info.plist）。
判据取自窗口服务器：状态项是 **layer 25** 的窗口，`kCGWindowIsOnscreen` 才代表真的画出来了
（拔掉后窗口壳还在，只是 `x=0` + offscreen——**只数个数会把「拔掉了」误判成「还在」**）。

| 场景 | 结果 |
|---|---|
| 启动即显示 + 不切换（对照） | `onscreen=yes 33x24@x810`，持续 9 秒稳定 |
| 启动即隐藏 + 不切换 | `onscreen=no 33x24@x0`，持续 9 秒稳定 → **图标从没出现过** |
| 每 2 秒来回切 | onscreen 跟着翻转（日志有一拍延迟，属渲染时机，不是机制问题） |
| 无 guard 版 | 活锁，主线程停在 `makeMainMenu`，计时器全停 |
| 有 guard 版 | 计数落到个位数，翻转正常 |

### 2. 设置键的读写断言（真模块 `.o` 直编驱动）

```
✔ 默认展示菜单栏图标
✔ 关掉后落盘到 menubar.icon.visible
✔ 新实例读回 false（重启后仍生效）
✔ 关图标不动调度与通知开关
✔ 调度文案未受影响
✔ 字符串 "true" 也认
✔ NSNumber 1 也认
```

### 3. 真产物端到端（权威）

`swift build --disable-sandbox` 出的二进制手搓成 `/tmp/UpdraftE2E/Updraft.app`（bundle id 与正式包一致），
**不碰 `/Applications`**。同一份产物跑两次，用窗口服务器数 `owner=Updraft` 的 L25 窗口：

| 启动参数 | 窗口服务器看到 |
|---|---|
| `-menubar.icon.visible NO` | 本实例 `onscreen=no 32x24@x0`；用户正在跑的实例（pid 88305）`onscreen=yes 32x24@x843` 不受影响 |
| 不带参数 | 本实例 `onscreen=yes 32x24@x811`，两个实例都 onscreen |

两次都确认进程存活（没活锁）。`-menubar.icon.visible` 走的是 `NSArgumentDomain`，
**只覆盖读取、不落盘**，所以没动用户真实设置。副产品：两次运行的 `state-v2.json` 与
`github-cache-v1.json` mtime 都停在 10:00（不是 10:2x），即**没有写共享状态**。

测试实例跑完即杀，`/Applications/Updraft.app`（pid 88305）全程未被触碰。

### 4. 截图通道（排版层）

新增 `--mode settings-icon-off`，并把 `settings` 画布从 484×460 抬到 484×580（多了一节）：

```bash
$AU --snapshot /tmp/settings.png            --mode settings
$AU --snapshot /tmp/icon-off.png            --mode settings-icon-off
$AU --snapshot /tmp/settings-confirm.png    --mode settings-confirm
```

三张都确认「备份」那一节和底部按钮完整在画布内（截短会把它裁掉一半——这个坑踩过）。

## 五、风险与未验证

| 项 | 状态 |
|---|---|
| 关掉图标后「查了跟没查一样」 | 设置页在「图标 + 通知」同时关掉时会多一行橙色提示；`--mode settings-icon-off` 留了一张图 |
| 「值没变就不写」挡掉 SwiftUI 的合法写回 | 只有与当前值相同的写回会被吞；本工具没有任何 UI 入口能触发 `isInserted` 的合法写入 |
| 真机点开关的**实时**拔插 | **只在上面的同构工程里验过**（真产物 E2E 验的是「启动即隐藏」）。要真人点一次设置页的开关确认 |
| 关掉图标后从 Dock / ⌘, 回到设置 | 同上，需要真人点一次 |
