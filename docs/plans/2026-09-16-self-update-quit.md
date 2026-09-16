# 自更新后不退出、不重启的修复实施计划

日期：2026-09-16
设计文档：`docs/plans/2026-09-16-self-update-quit-design.md`
分支：`fix/self-update-quit-and-relaunch`

## 目标

自更新成功后，旧进程自己退出、新版本自己起来。用户不需要"手动关闭"这一步。

## 任务

### Task 1 — `Installer` 换成能强开新实例的拉起方式

**文件**：`Sources/AppUpdaterKit/Core/Installer.swift`

- 新增纯函数 `static func relaunchCommand(for app: URL) -> (executable: String, arguments: [String])`，
  返回 `("/usr/bin/open", ["-n", app.path])`。
- `launch(_:)` 改为走 `ProcessRunner.run` 执行它，返回值仍表示"是否拉起来了"。
- 注释里写清为什么必须带 `-n`（同 bundle id 在跑时 `NSWorkspace.open` 只做激活，实测返回 true 却没启进程）。

**验收**：`grep -rn "NSWorkspace.shared.open" Sources` 只剩非"拉起应用"的用法。

### Task 2 — `SelfQuit`：先收面板，再优雅退出，最后兜底强退

**文件**：`Sources/AppUpdaterKit/UI/SelfQuit.swift`（新增）

- `schedule()`：0.6 秒后 `NSApp.terminate(nil)`；再过 1.0 秒仍活着就 `exit(0)`（挂在全局队列上）。
- 注释里保留四组对照表（本次排查的实测数据），说明为什么不能只写一行 `terminate`。

### Task 3 — `UpdateStore.installSelfUpdate` 收尾改造

**文件**：`Sources/AppUpdaterKit/UI/UpdateStore.swift`

- 成功后：`isSelfUpdatePresented = false` → `SelfQuit.schedule()`。
- 新增前卫：`report.relaunched == false` 时不退出（fail closed），面板停在"请手动打开"。
- 顺手把 `installSelfUpdate` 的文档注释改成完整顺序（下载 → 验签 → 换自己 → 拉起新实例 → 收面板 → 退出）。

### Task 4 — 面板文案

**文件**：`Sources/AppUpdaterKit/UI/SelfUpdateSheet.swift`

- `subtitle` 与 `resultView` 区分「已拉起新版本」与「没能自动打开」两种成功态。

### Task 5 — 断言

**文件**：`Tests/AppUpdaterTests/SelfUpdateTests.swift`

- `testRelaunchForcesNewInstanceInsteadOfActivatingRunningOne`：断言可执行文件与参数，
  守的是"不许改回 `NSWorkspace.open`"这条。

### Task 6 — 文档

设计文档 + 本实施计划。

## 本机验证实况（2026-09-16）

本机只有 Command Line Tools（`swift test` 不可用），验证走三条路。

### 1. 同构最小工程的对照实验（定根因）

`/tmp/probe2`：SwiftUI `WindowGroup` + `sheet` + `MenuBarExtra`，复刻 `installSelfUpdate` 的收尾几行。

| 模式 | `NSApp.terminate(nil)` | 结论 |
|---|---|---|
| `plain`（无 sheet） | delegate 被问到 → `applicationWillTerminate` → 进程结束 | 正常 |
| `sheet`（面板挂着） | 14ms 返回，**delegate 没被问**，进程继续跑 | **复现** |
| `sheet-then-dismiss` | 正常退出 | 先收面板是对的 |
| `exit`（面板挂着直接 `exit(0)`） | 正常退出 | 兜底这条路可行 |

`/tmp/probe`（AppKit）另跑三组拉起方式的对照：`NSWorkspace.open` 进程数 1（**没起来**）、
`NSWorkspace.openApplication(createsNewApplicationInstance:)` 进程数 2、`/usr/bin/open -n` 进程数 2。

### 2. 纯函数断言（真模块）

`swift build --disable-sandbox` 后用 `.build/debug/AppUpdaterKit.build/*.o` 直编驱动：

```
relaunchCommand
  ✓ 可执行文件是 /usr/bin/open
  ✓ 参数是 ["-n", app.path]（-n 保证强开新实例）
带空格的路径不能被拆开
  ✓ 空格路径原样作为一个参数
全部通过
```

### 3. 本机端到端跑一次真实自更新（权威）

用 `VERSION=0.3.0 BUILD_NUMBER=99 scripts/build-app.sh` 造一个 0.3.0，装到 `~/Applications/AppUpdater.app`
（**不动用户 `/Applications` 里那个**），临时加两处探针（启动标记 + 退出时间线，验完已回退，
`git diff` 确认为空）后运行，走真实代码路径 `presentSelfUpdate → checkSelfUpdate → installSelfUpdate`，
下载并安装的是 GitHub 上真实的 v0.3.1。

第一次运行：

```
启动标记: pid=12730 version=0.3.0 at=03:17:56Z
退出时间线:
  03:18:12 已安排退出：settle=0.6s 后 NSApp.terminate，再 1.0s 兜底 exit(0)
  03:18:13 发出 NSApp.terminate(nil)
磁盘版本: 0.3.1           ← 换包成功
进程: 12730 已消失，12753 起来（同一路径、新 pid）   ← 自动退出 + 自动重启
```

时间线里**没有**出现"兜底 `exit(0)` 触发"那一行 → 走的是**优雅退出**，兜底没用上（0.6 秒足够把
面板收干净）。前一次未加仪表的运行结果一致：旧进程消失、新进程起来、`.old` 被新实例的启动恢复清掉。

现场清理：测试实例已 kill、`~/Applications/AppUpdater.app` 已删、被 prune 掉的用户备份目录
（`Backups/com.local.appupdater/20260916-105941-0.3.0`）与 `state-v2.json` 已还原，
`/Applications/AppUpdater.app` 未被动过（仍是 0.3.1，用户进程 7564 仍在跑）。

## 风险

| 风险 | 处置 |
|---|---|
| 新旧实例并存约 1 秒 | 已实测无副作用（`.old` 在旧进程退出后由新实例的启动恢复清理）；记录在设计文档第八节 |
| 兜底 `exit(0)` 会跳过 AppKit 收尾 | 只在优雅退出没生效时才走；升级已落盘，强退的代价远小于留一个旧进程 |
| 面板收起耗时随机器不同 | 兜底独立计时，不依赖面板收完；实测 0.6 秒足够 |
| `report.relaunched` 为假时界面停住 | 这是有意的 fail closed，文案已说明"请手动打开" |

## 实施记录（2026-09-16）

### 验证实况

- `swift build --disable-sandbox` 通过。
- 纯函数断言通过（上表）。
- 本机端到端自更新跑通两次，第二次带退出时间线，确认走的是优雅退出。
- 本机跑不了 `swift test`，XCTest 由 CI 权威验证（新增 1 条用例）。

### 与计划的偏离

- 计划里 `SelfQuit` 想过参数化时间以便单测，落地时去掉了：这两步是 AppKit 生命周期行为，
  参数化只能测"调度器会不会按时调闭包"，测不到真正关心的那件事。改为靠真机端到端确认，
  与本仓库既有的"真机替换与 SwiftUI 行为必须真人跑"约定一致。
