# 自更新后不退出、不重启的修复设计文档

日期：2026-09-16
分支：`fix/self-update-quit-and-relaunch`
涉及代码：`Core/Installer.swift`、`UI/UpdateStore.swift`、`UI/SelfUpdateSheet.swift`、`UI/SelfQuit.swift`（新增）

## 一、要解决的问题

v0.3.1 的真机反馈：自更新把新版本换上去之后，面板停在「已升级到 0.3.1 · 签名校验通过 ·
即将打开新版本并退出当前窗口」，**旧进程不退出**，**新版本也没起来**。用户只能手动关掉才算完。

用户原话：「更新 0.3.1 下载完没有自动退出重启，得手动关闭才行」。

## 二、真机证据

更新发生在 2026-09-16 10:59:41（备份目录的时间戳），排查时进程还在跑。

| 证据 | 取值 | 说明 |
|---|---|---|
| 备份目录 | `Backups/com.local.appupdater/20260916-105941-0.3.0/` | 目录名里的版本取自**运行中进程**的 `Info.plist` |
| 备份包内 `CFBundleShortVersionString` | `0.3.1` | 取自**磁盘上**被换下来的那个包 |
| 更新完 40 分钟后仍在跑的进程 | `/Applications/AppUpdater.app/Contents/MacOS/AppUpdater` | 换包成功，进程却没走 |
| `/Applications/.AppUpdater.*.old.app` | 不存在 | 旧包已被清理 |
| `~/Library/Caches/AppUpdater/work` 时间戳 | 11:01 | 11:01 有新实例启动过（启动恢复会清中间态） |

前两行合起来是关键：**换包那一刻，磁盘上已经是 0.3.1，而跑着的进程还是 0.3.0**。
也就是说上一次自更新（装 0.3.1 的那次）同样没退出，于是这个 0.3.0 进程后来又把自己当成
「该升级」，把 0.3.1 又装了一遍。同一个 bug 至少踩过两次。

> 本机沙箱里 `ps` 不可用（`operation not permitted`），进程排查用 `pgrep`，时间线靠文件时间戳。

## 三、根因

两个独立的缺陷，第二个被第一个掩盖着。

### 3.1 面板（sheet）挂着时 `NSApp.terminate` 是空操作

用与 Updraft 同构的最小工程（SwiftUI `WindowGroup` + `sheet` + `MenuBarExtra`）做四组对照：

| 场景 | `NSApp.terminate(nil)` 的结果 |
|---|---|
| 没有 sheet | 正常退出：`applicationShouldTerminate` 被问到 → `applicationWillTerminate` → 进程结束 |
| **sheet 挂着** | 调用后 **14 毫秒返回，delegate 压根没被问**，进程继续跑 |
| 先把 sheet 收起来再退出 | 正常退出 |
| sheet 挂着直接 `exit(0)` | 正常退出 |

原实现：

```swift
selfInstallReport = report
isInstallingSelf = false
if report.succeeded {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
}
```

而 `SelfUpdateSheet` 在成功态是**一直挂着的**（footer 只剩一个「关闭」按钮）。
于是这一行等于什么都没做——这解释了所有现象，也解释了为什么"手动关闭"看起来是有效的：
手动关掉面板恰好先结束了模态会话，之后的 ⌘Q 才正常。

截图里那个不起眼的细节也吻合：footer 只剩「关闭」，说明代码确实走到了成功分支并把
report 设上了，只是退出请求被模态会话吞了。

### 3.2 同 bundle id 已在运行时，`NSWorkspace.open` 不会开新实例

`Installer.launch` 原本是 `MainActor.run { NSWorkspace.shared.open(app) }`。自替换的场景里
**本进程还活着**，同 bundle id 的实例对 LaunchServices 来说"已经在运行"，`open` 只是把它激活。
三种拉法的实测对照（探针工程，运行中进程调用）：

| 方式 | 返回值 | 进程数 |
|---|---|---|
| `NSWorkspace.shared.open` | `true` | **1**（新实例没起来） |
| `NSWorkspace.openApplication(createsNewApplicationInstance: true)` | 回调无错 | 2 ✔ |
| `/usr/bin/open -n` | exitCode `0` | 2 ✔ |

所以 `report.relaunched = true` 是**假的成功**：它只表示 LaunchServices 收下了请求。
「自动打开新版本」这一半其实一直是坏的，只是被 3.1 掩盖着——旧进程不退出，用户看到的
只有旧窗口，自然不会察觉"新版本也没起来"。

## 四、范围

### 做

- 成功收尾改成：**先收面板 → 优雅退出 → 兜底强退**。
- 拉起新版本改用能强开新实例的方式。
- 新版本没拉起来时**不退出**，并在面板上如实说明。
- 补一条断言，把「必须带 `-n`」钉住。

### 不做

- 不改 `Installer` 的换包、验签、回滚逻辑。
- 不动 CLI 的 `runAndWait`（信号量堵主线程那件事，见第八节）。
- 不引入独立的重启守护进程（`wait-then-open` 小脚本）：代价是"失败无声"，
  而自更新最怕的就是失败无声，见 5.5。

## 五、关键决策

### 5.1 退出顺序：先收面板，再优雅退出

```swift
isSelfUpdatePresented = false     // 结束模态会话，否则下面的 terminate 无效
SelfQuit.schedule()               // 0.6s 后 NSApp.terminate，再 1.0s 兜底 exit(0)
```

不写成"直接 `exit(0)`"是有意的：优雅退出会问 delegate、走 `applicationWillTerminate`、
正常收尾。只有当优雅退出没生效时，兜底才动手。

### 5.2 兜底为什么必须有，而且为什么是 `exit(0)`

升级已经落盘了。留一个赖着不走的旧进程代价很大：用户以为没升级、菜单栏多出一个图标、
下次启动的还是旧版本。相比之下少保存一次窗口状态无所谓——所以宽限期一过就强退。

`exit(0)` 而不是 `_exit(0)`：与 `main.swift` 里 CLI 的退出写法一致，也保留 atexit 收尾。
它挂在全局队列上，主线程就算被什么卡住，这条照跑。

### 5.3 拉起新版本用 `/usr/bin/open -n`

两个候选都能用（见 3.2 的对照表），选 `open` 的理由：

- 不依赖 AppKit 主线程。`MainActor.run` 那层包装正是 CLI 自更新死锁的成因
  （未合并分支 `fix/cli-self-update-relaunch-deadlock` 的结论）；换掉之后这个坑连根拔掉。
- 退出码是真信号：拉不起来会返回非零，界面能把"已升级但没能自动打开"如实说出来，
  而 `NSWorkspace.open` 在这种情况下也返回 `true`。

### 5.4 新版本没拉起来就不退出（fail closed）

```swift
guard report.succeeded else { return }
guard report.relaunched else { return }   // 面板停在"请手动打开新版本"
```

宁可让用户看到一个说明了原因的面板，也不要退到一个空桌面上去。
这也符合安装器一贯的 fail-closed：不确定就不动手。

### 5.5 为什么不用「等本进程退出再 open」的小脚本

写一个 detach 的 `/bin/sh` 等自己死了再 `open` 新版本，能消掉新旧实例并存的那 1 秒。
没选它有两个原因：

1. 那 1 秒里没有任何用户可感知的问题（旧窗口本来就在消失过程中）；
2. 脚本跑在进程外，**它失败没有任何人知道**——自更新最不该有的就是"失败无声"。

## 六、界面与文案

| 状态 | 面板文案 |
|---|---|
| 成功且已拉起新版本 | 副标题「已升级，即将打开新版本」；正文「即将打开新版本并退出当前窗口。」 |
| 成功但没拉起 | 副标题「已升级，请手动打开新版本」；正文「新版本没能自动打开，请手动打开；确认无误后可以退出当前窗口。」 |

第二行的价值在于：它把 3.2 那种"假成功"变成屏幕上看得见的一句话，而不是让用户对着
一个不再响应的面板猜。

## 七、测试策略

- **能断言的**：`Installer.relaunchCommand(for:)` 是纯函数，断言「可执行文件是 `/usr/bin/open`」
  与「参数是 `["-n", path]`」。这条测试守的正是踩过的坑——谁改回 `NSWorkspace.open`，它就会红。
- **断言不了的**：`NSApp.terminate` 与模态会话的关系是 AppKit 生命周期行为，
  单元测试证明不了。按本仓库的既有约定（真机替换与 SwiftUI 行为必须真人跑），
  这两条靠**本机端到端跑一次自更新**确认，见实施计划的「本机端到端确认」。

## 八、已知残留与后续

- **CLI `--self-install`**：未合并分支 `fix/cli-self-update-relaunch-deadlock` 里改 `Installer.launch`
  的那一半，已被本次修改覆盖（同样去掉了主线程依赖）；剩下 `main.swift` 用 RunLoop 取代信号量
  的那一半仍需单独处理，且要重新验证。
- **面板没有截图通道**：`--snapshot` 至今没有自更新面板的模式，而这次的 bug 恰恰长在面板上。
  建议后续补一个模式，让"成功 / 没能自动打开 / 失败"三态可留痕可重跑。
- **新旧实例并存约 1 秒**：这段窗口里新实例的启动恢复会删掉旧实例正在运行的 `.old` 包。
  macOS 允许删除正在运行的包（按 inode 引用），实操无碍，但记录在案。
