# Homebrew 账本滞后导致的"假更新"展示修复设计文档

日期：2026-09-16
状态：已确认，进入实施计划阶段

## 一、要解决的问题

主列表出现过这样一条：

```
Proxyman
Homebrew · 6.17.0 → 6.17.0                    [升级]
Wireshark
Homebrew · 4.6.8 → 4.6.8                      [升级]
```

左右两边是同一个版本号，却挂在「可更新」组里，还带着一个升级按钮。用户的第一反应是
「这工具算错版本号了」。

它没算错，只是**两个数字来自两个不同的数据源**，而这两个源在这台机器上已经对不上了。

## 二、真机证据

2026-09-16 实测：

| cask | Caskroom 账本 | tap 里最新 | `/Applications` 里的真实版本 |
|---|---|---|---|
| `proxyman` | `6.12.0,61200` | `6.17.0` | **6.17.0** |
| `wireshark-app` | `4.6.4` | `4.6.8` | **4.6.8** |

`Proxyman.app` 的目录时间是 09-07 16:05，`Wireshark.app` 是 08-13 02:22——两个包都被换过了。
而 `brew upgrade` 会**同时**改名 Caskroom 下的版本目录，这两次显然不是 brew 干的，
是这两个应用**各自的内建更新器**升的。Homebrew 只是记了个旧账。

同时 `brew outdated --cask --greedy` 报 7 个过期 cask，而界面只列了 4 条：
差的 5 个里，3 个（Another Redis Desktop Manager / BLEUnlock / Cling）的 `.app` 在
`/Applications` 与 `~/Applications` 都找不到，另 2 个（fuse-t、macfuse）只含 pkg。
这是同一件事的另一面：**brew 的账本和磁盘实际状态已经不止一处对不上。**

## 三、根因

### 3.1 两个数据源

| 界面上的值 | 来源 | 取值 |
|---|---|---|
| 左值（当前版本） | `AppScanner` 读 `.app` 内 `Info.plist` 的 `CFBundleShortVersionString` | 磁盘真实值 `6.17.0` |
| 右值（最新版本） | `BrewService.runOutdated` 取 `brew outdated --json=v2` 的 `current_version` | tap 最新 `6.17.0` |
| 是否列为可更新 | `CheckEngine` 只看 token 在不在 `outdated` 字典里 | brew 拿账本 `6.12.0` 比 tap `6.17.0`，报过期 |

`CheckEngine.swift:79` 完全信任 brew 的判定，**从不比对两边版本号**。
于是左值是磁盘真实值、右值是 tap 最新值，两者恰好都是 `6.17.0`，界面就渲染成 `6.17.0 → 6.17.0`。

### 3.2 这不是 bug，是信息缺失

brew 的判断在它自己的世界里永远是对的：它比的就是账本与 tap。问题在于
**我们只把 tap 那一半抄了过来，把账本那一半扔了**——而账本恰恰是解释「为什么它会出现在这里」的关键。

`brew outdated --json=v2` 的返回里两个值都有，现在是白扔一个。

## 四、范围

### 做

1. `brew outdated` 的 `installed_versions` 一并读进来，存进 `ReleaseInfo.ledgerVersion`。
2. Homebrew 条目的左值改用**账本版本**——那才是 brew 执行升级时的真实起点。
3. 账本与磁盘实际不一致时，行内附注「brew 记录滞后，实际已装 X」。
4. 升级确认面板用同一套口径，并对滞后条目给出明确提示（点下去会重装一遍、顺带修正账本）。
5. 升级结果里的 `fromVersion` 也统一走同一口径。
6. 截图通道加 `--mode ledger`，让这个界面状态能重跑、可复现。
7. README 补说明。

### 不做

- **不隐藏这类条目**，也不给它换一个「不是更新」的分组。理由见 5.3。
- 不读 `Caskroom/<version>/.metadata` 之类的内部记录，只认 JSON 的公开字段。
- 不去猜「账本为什么旧」（应用自更新 / 手动替换 / 迁移），只如实陈述两个数不一样。
- 不动 Sparkle / Electron 两条链路的显示口径。
- 不做「一键修正 brew 记录」（`brew upgrade --cask` 本身就会修正，不必另造动作）。

## 五、关键决策

### 5.1 左值改用账本，而不是把账本塞进附注

另一种写法是保持左值为磁盘真实版本（`6.17.0`），附注里补一句「brew 记录的是 6.12.0」。
那样主信息仍然是 `6.17.0 → 6.17.0`，**用户第一眼看到的还是那句自相矛盾的话**，
得读完成附注才能明白。附注不该承担修正主信息的职责。

行内 `A → B` 的语义本来就是「这次操作从 A 走到 B」。brew 会从账本记录的 `6.12.0` 开始重装，
并把它记成 `6.17.0`——所以 `6.12.0 → 6.17.0` 才是对**这次操作**的准确描述。
磁盘真实版本改由附注陈述，它在那个位置是补充信息而不是主语。

### 5.2 附注用陈述句，不用警告词

「brew 记录滞后，实际已装 6.17.0」——只说事实。用「警告」或叹号会显得像出错，
但这个状态本身完全正常：用户用应用自带的更新器升级是最常见的操作路径，
真正出问题的只是 brew 的账本。

### 5.3 保留在「可更新」组，不做隐藏

隐藏它有两个后果：

1. **brew 账本永远修不回来。** `brew upgrade --cask` 会重装并更新 Caskroom 记录，
   是唯一能把这个不一致消掉的动作。藏起来，用户就再也没机会知道。
2. **与 brew 自己的认知继续分裂。** 用户在终端跑 `brew outdated` 会看到它，
   在 App 更新里看不到，两边永远说法不同。

点下去的实际后果是「重新下载并安装同一个版本」——**有效但多余**。
这类操作的正确处理是如实告知代价、把选择权交给用户，而不是替他决定。

### 5.4 「同版本」的判定用 `Version` 而非字符串相等

`1.0` 与 `1.0.0` 是同版本，字符串不等。直接用 `!=` 会把这种写法差异误报成「账本滞后」。
复用已有的 `Version`（`Core/Version.swift`，已把 `1.0` 与 `1.0.0` 视为相等）。

两边都解析不出数字串（理论上不会发生，因为 `normalizedVersion` 已剥掉逗号后缀）时
`Version` 会双双退化成 `[0]` 而判为相等——这会让一个真的不一致被漏报，
但漏报只是少一句附注，主信息（账本 → 最新）依然正确。**宁可少说，不可说错。**

### 5.5 判定写成 `ReleaseInfo` 上的纯函数，不散在视图里

列表行、确认面板、执行结果三处都要用同一个口径。抄三遍必然有一天只改一处。
两个纯函数放在 `Models/ReleaseInfo.swift`（不依赖 AppKit，能进 `swiftc` 直编的纯逻辑子集）：

```swift
public func upgradeFrom(actualVersion: String?) -> String   // 本次升级的起点
public func hasStaleLedger(actualVersion: String?) -> Bool  // 账本与磁盘是否不一致
```

`UpgradeJob.Item` 上再包一层同名的计算属性，让 UI 侧不必重复传参。

### 5.6 附注文案为什么带 `brew` 字样

「记录滞后，实际已装 6.17.0」孤立看指代不明——谁记录的？带上来源名，
在批量升级面板里（多个应用并排）才不会读成「磁盘上装了两个版本」。

## 六、界面与文案

### 6.1 主列表行（`AppUpdate.detailText`）

| 情形 | 副标题 |
|---|---|
| 账本正常 / 非 brew 来源 | `Homebrew · 6.17.0 → 6.17.0` → 不变，`Homebrew · 4.6.4 → 4.6.8` |
| 账本滞后 | `Homebrew · 6.12.0 → 6.17.0 · brew 记录滞后，实际已装 6.17.0` |

实测最宽的一行约 353pt，主列表 760pt 最小宽度下可用约 534pt，放得下，不触发截断。

### 6.2 升级确认面板（`UpgradeSheet`）

条目行的版本沿用同一口径；滞后条目在确认列表下方汇总一条提示：

```
Proxyman：Homebrew 记录的是 6.12.0，磁盘上实际已是 6.17.0（应用自己的更新器升过）。
继续会重新安装 6.17.0 并修正记录。
```

### 6.3 截图留痕

新增 `--snapshot --mode ledger`：合成一份固定结果直接塞进 store，
包含两条账本滞后（Proxyman / Wireshark）与一条正常升级作为对照。
**不查网络、不扫本机**，重跑必然得到同一张图——这台机器上的账本一旦被修正，
真实截图就再也复现不了这个状态了。

## 七、测试策略

纯逻辑层（`Tests/AppUpdaterTests/BrewLedgerTests.swift`，新增）：

| 用例 | 断言 |
|---|---|
| `upgradeFrom` 有账本 | 返回账本值，忽略传入的实际版本 |
| `upgradeFrom` 无账本 | 退回实际版本 |
| `upgradeFrom` 两者皆无 | 返回 `?` |
| `hasStaleLedger` 账本 == 实际 | `false` |
| `hasStaleLedger` 账本 != 实际 | `true` |
| `hasStaleLedger` `1.0` vs `1.0.0` | `false`（同版本，不算滞后） |
| `hasStaleLedger` 账本为 `nil` | `false`（非 brew 来源不该被标） |
| `hasStaleLedger` 实际为 `nil` | `false`（没有比对基础，不猜） |
| `parseOutdated` 正常 JSON | 同时解出 `installedVersion` 与 `latestVersion` |
| `parseOutdated` 逗号后缀 | `6.17.0,61700` → `6.17.0` |
| `parseOutdated` 垃圾输入 / 空串 | `nil` |
| `parseOutdated` formulae 分支 | 同样解出两个值 |
| `detailText` 账本滞后 | 含 `brew 记录滞后`，左值为账本值，**不含** `6.17.0 → 6.17.0` |
| `detailText` 账本正常 | 与改动前逐字一致（回归） |
| `UpgradeJob.Item.fromVersion` | 有账本取账本，无账本取 `app.currentVersion` |
| `CheckEngine` 注入假 brew | 生成的 `ReleaseInfo.ledgerVersion` 非空 |

界面上限（截图 + 真机）：`--mode main` 与新增 `--mode ledger` 各出一张图；
确认面板的提示文案需要真机点一次才看得到完整排版。

**并行验证**：本机没有 Xcode，`swift test` 跑不了。按既有做法，
先 `swiftc` 直编纯逻辑子集 + 自写断言驱动看红绿，XCTest 用例交给 CI（`macos-latest`）。
`ReleaseInfo` 与 `UpgradeJob` 都在纯逻辑子集里（`AppInfo`/`AppSource`/`ReleaseInfo`/`UpdateResult`），
`UpgradeJob` 依赖 `Installer.Plan`（AppKit）进不去——因此 `Item.fromVersion` 这条靠 CI。
