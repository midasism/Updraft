# Homebrew 账本滞后展示修复实施计划

日期：2026-09-16
设计文档：`docs/plans/2026-09-16-brew-ledger-design.md`
分支：`feat/brew-ledger`

## 目标

列表行不再出现 `6.17.0 → 6.17.0` 这种自相矛盾的写法。Homebrew 条目的升级起点改为
brew 账本记录的版本，并在账本与磁盘实际不一致时如实附注。

## 任务

### Task 1 — `BrewOutdatedCask` 与解析

**文件**：`Sources/AppUpdaterKit/Core/BrewService.swift`

- 新增 `public struct BrewOutdatedCask { installedVersion: String?; latestVersion: String }`。
- 把内联在 `runOutdated` 里的 JSON 解析抽成 `static func parseOutdated(_ stdout: String) -> [String: BrewOutdatedCask]?`，
  与既有的 `parseCaskInfo` 对称，好让纯解析能被断言。
- `outdatedCasks(scopedTo:)` 与 `runOutdated` 的返回类型改为 `[String: BrewOutdatedCask]?`。
- 兼容 `casks` 与 `formulae` 两个分支（当前实现两个都处理，都要跟着改）。

**验收**：`grep -rn "outdatedCasks" Sources` 只剩调用方需要改的两处。

### Task 2 — `ReleaseInfo` 加账本字段与两个纯函数

**文件**：`Sources/AppUpdaterKit/Models/ReleaseInfo.swift`

- 加 `public var ledgerVersion: String?`，init 参数追加在**末尾**（现有调用点全是位置参数，加末尾不用改）。
- `upgradeFrom(actualVersion:)` / `hasStaleLedger(actualVersion:)` 按设计文档 5.5。
- `hasStaleLedger` 用 `Version` 比较，不用字符串相等（设计文档 5.4）。

**验收**：`ReleaseInfo(version: "6.17.0")` 仍能编译（默认参数不破坏既有调用）。

### Task 3 — `CheckEngine` 接上账本

**文件**：`Sources/AppUpdaterKit/Core/CheckEngine.swift`

- `BrewOutdatedSource` typealias 改为 `@Sendable ([String]) async -> [String: BrewOutdatedCask]?`。
- 第 79–83 行的分支改用新结构：`ReleaseInfo(version: entry.latestVersion, ledgerVersion: entry.installedVersion)`。
- `upToDate` 分支不动（它已经用 `app.currentVersion`，本来就说的是磁盘真实版本）。

### Task 4 — 列表行口径

**文件**：`Sources/AppUpdaterKit/Models/UpdateResult.swift`

`detailText` 的 `.updateAvailable` 分支：

```swift
let from = release.upgradeFrom(actualVersion: app.currentVersion)
parts.append("\(from) → \(release.version)")
if release.hasStaleLedger(actualVersion: app.currentVersion),
   let actual = app.currentVersion {
    parts.append("brew 记录滞后，实际已装 \(actual)")
}
```

顺序按设计文档 6.1：来源徽标 → 版本 → 附注 → 体积。

### Task 5 — `UpgradeJob.Item` 包一层

**文件**：`Sources/AppUpdaterKit/Models/UpgradeJob.swift`

加两个计算属性，让 UI 侧不必重复传 `app.currentVersion`：

```swift
public var fromVersion: String { release.upgradeFrom(actualVersion: app.currentVersion) }
public var hasStaleLedger: Bool { release.hasStaleLedger(actualVersion: app.currentVersion) }
```

**注意**：该文件依赖 `Installer.Plan`（AppKit），进不了 `swiftc` 直编的纯逻辑子集，
本机只能靠 `swift build` 确认编译，断言交给 CI。

### Task 6 — Store 与面板接上同一口径

**文件**：`Sources/AppUpdaterKit/UI/UpdateStore.swift`、`Sources/AppUpdaterKit/UI/UpgradeSheet.swift`

- `UpdateStore`：`runBrew` 与 `runJob` 的 `default` 分支里 `fromVersion:` 改 `item.fromVersion`。
- `UpgradeSheet`：`confirmListView` 与 `runningView` 里的
  `"\(item.app.currentVersion ?? "?") → \(item.release.version)"` 改 `"\(item.fromVersion) → \(item.release.version)"`。
- `confirmListView` 里模仿既有 `unverified` 的写法，给滞后条目汇总一条 `warningBox`（文案见设计文档 6.2）。

### Task 7 — 截图通道加 `ledger` 模式

**文件**：`Sources/AppUpdaterKit/CLI/SnapshotRunner.swift`、`Sources/AppUpdaterKit/UI/UpdateStore.swift`

- `UpdateStore` 加 internal 方法 `loadSynthetic(updates:lastChecked:)`，供截图通道注入合成的检查结果。
  真实状态依赖某台机器「碰巧账本滞后」，一旦账本被修正就再也复现不了。
- `SnapshotRunner.Mode` 加 `case ledger`，在 `syntheticRoot` 之前处理（它要用 store，不是纯合成视图），
  在 `run` 里走「造 store → loadSynthetic → 渲染 ContentView」这条支路，**跳过 `store.check()`**。
- 合成数据：Proxyman（账本 `6.12.0` → `6.17.0`，实际 `6.17.0`）、
  Wireshark（账本 `4.6.4` → `4.6.8`，实际 `4.6.8`），外加一条正常的 Sparkle 升级做对照。

### Task 8 — 验证

| 手段 | 命令 |
|---|---|
| 编译 | `swift build --disable-sandbox`（Debug + Release） |
| 纯逻辑断言驱动 | `swiftc` 直编 `ReleaseInfo` + 4 个 Models 文件 + `/tmp/harness.swift` |
| 打包 | `scripts/build-app.sh` |
| 截图 | `--snapshot --mode ledger`、`--snapshot --mode main` |

### Task 9 — 文档

- `README.md`：功能清单补一句账本口径；命令表补 `--mode ledger`；补截图。
- 本文档回填实施记录。

## 风险

| 风险 | 应对 |
|---|---|
| `parseOutdated` 改动漏掉 formulae 分支 | Task 1 明确要求两个分支都改；用例覆盖 formulae |
| `ReleaseInfo` 加字段破坏缓存反序列化 | 可选字段走 `decodeIfPresent`，旧缓存缺 key 是安全的 |
| `--mode ledger` 与 `--query` 的组合 | ledger 模式忽略 `query`，在计划里写死，不做组合 |
| 主列表副标题变长导致截断 | 实测约 353pt，760pt 窗口下可用约 534pt；截图复核 |

## 实施记录（2026-09-16）

全部落地。改动文件：

| 文件 | 改动 |
|---|---|
| `Core/BrewService.swift` | 新增 `BrewOutdatedCask`；抽出 `parseOutdated` / `installedVersion(from:key:)` |
| `Models/ReleaseInfo.swift` | 新增 `ledgerVersion` 字段与 `upgradeFrom` / `hasStaleLedger` 两个纯函数 |
| `Core/CheckEngine.swift` | `BrewOutdatedSource` 换类型；构造 `ReleaseInfo` 时带上账本 |
| `Models/UpdateResult.swift` | `detailText` 改用 `upgradeFrom` + 账本滞后附注 |
| `Models/UpgradeJob.swift` | `Item.fromVersion` / `Item.hasStaleLedger`；`cancelRemaining` 换口径 |
| `UI/UpdateStore.swift` | 两处 `Outcome.fromVersion` 换口径；新增 `loadSynthetic(updates:)` |
| `UI/UpgradeSheet.swift` | 确认清单与执行态换口径；新增账本滞后提示框 |
| `CLI/SnapshotRunner.swift` | 新增 `Mode.ledger` 与 `makeSyntheticLedgerUpdates()` |
| `Tests/AppUpdaterTests/BrewLedgerTests.swift` | 新增 19 个用例 |
| `Tests/AppUpdaterTests/IncrementalRefreshTests.swift` | 假 brew 的返回类型跟着改 |

### 验证实况

| 手段 | 结果 |
|---|---|
| `swift build --disable-sandbox` | ✅ Debug |
| `swiftc` 断言驱动（纯逻辑子集 + `CheckEngine`） | ✅ **27 项断言全绿**，退出码 0 |
| `--snapshot --mode ledger` | ✅ Proxyman `6.12.0 → 6.17.0 · brew 记录滞后，实际已装 6.17.0`；iTerm2 对照行无附注 |
| `--snapshot --mode main`（真机 92 个应用） | ✅ 真机两条账本滞后如实呈现，卡片仍是 4 / 17 / 71 |
| `--snapshot --mode batch` | ✅ 确认清单的账本滞后提示框 |

### 与计划的两处偏离

1. **纯逻辑子集比预期大。** 计划里说 `UpgradeJob` 进不了 `swiftc` 直编（依赖 `Installer.Plan`），
   这条没错；但 `CheckEngine` 的全部依赖（探针、HTTPClient、Appcast）实测都是 Foundation-only，
   于是 `CheckEngine` 也能进子集——引擎接线那一环因此也拿到了本机断言，只剩 `UpgradeJob.Item`
   的两条和 `cancelRemaining` 一条交给 CI。
2. **合成样本从 4 条加到 6 条。** 计划里是「两条账本滞后 + 一条正常升级对照」。
   实际渲染时只有 4 条会把「已是最新」卡片留成 0，截图看着不像真的；补了两条 `upToDate`。
   另外 Cherry Studio 一开始没给 `downloadURL`，渲染成了「—」而不是升级按钮，补上地址。

### 本机端到端确认（不是单测）

修复前后的同一个界面：`Proxyman` 从 `6.17.0 → 6.17.0` 变成
`6.12.0 → 6.17.0 · brew 记录滞后，实际已装 6.17.0`，并且**这一行仍然留在「可更新」组里**
（设计文档 5.3 的决定）。真机两条（`Proxyman` / `Wireshark`）都符合预期。
