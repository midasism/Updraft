# 忽略当前应用版本 · 设计方案

> 2026-09-26 · 状态：已确认并实现（一期只覆盖应用列表，自身更新暂不覆盖）
>
> 需求：当检测到的最新版本与已忽略的版本相同时，不再触发刷新或更新提示；
> 仅当出现高于该被忽略版本的新版本时，才重新提示。

## 1. 作用范围

| 路径 | 是否生效 | 说明 |
|---|---|---|
| 全量检查 `UpdateStore.check()` | 生效 | 探测照常进行，结果在判定层被过滤；这也是发现更高新版本、清除忽略记录的主要时机 |
| 增量刷新 `UpdateStore.refresh(ids:)` | 生效 | 升级收尾的自动刷新**跳过**被抑制条目（见 §4）；`force: true` 强制探测 |
| 冷启动渲染缓存 | 生效 | 过滤在回放缓存后立即重新套用，启动瞬间也不闪提示 |
| 「全部升级」 | 生效 | 被忽略条目不计入 `updateCount` / `automatedUpdateCount`，不参与批量升级 |
| 自身更新（Updraft 自己） | **暂不覆盖** | 用户决策：一期只做应用列表，self-update 保持现状 |

覆盖所有探测通道（Homebrew cask / Sparkle / Electron）——忽略记录挂在应用上，
与"最新版本是从哪个源探来的"无关。

## 2. 存储

**独立 JSON 文件**：`~/Library/Application Support/AppUpdater/ignored-versions.json`
（与 `state-v2.json` 同目录，GUI 与 headless CLI 共享同一份）。

为什么不放进 `StateCache`：state-v2.json 是**检查结果缓存**，本项目的惯例是换数据
形状就换文件名（v0.2 注释）；而忽略记录是**用户决策**，不能跟着缓存一起被丢弃或重置。

记录结构：

```json
{
  "records": {
    "<appKey>": { "version": "1.4.4", "ignoredAt": "2026-09-26T10:00:00Z" }
  }
}
```

**appKey 的选取顺序**：`bundleID` → cask token（纯命令行工具，无 bundleID）→ 包路径。
Bundle ID 优先，因为应用升级后版本必然变化、路径也可能变，只有 bundleID 稳定。

## 3. 判断逻辑

### 3.1 版本比较规则

复用现有 `Version` / `VersionComparison`，**不做字符串比较**：

- `1.0` 与 `1.0.0`、`v1.2.3` 与 `1.2.3` 视为同一版本（数字段补齐比较）；
- 带后缀（`2.1.0-beta.2`）视为更早的预发布版——忽略正式版后，同版本号的 beta 不会突然又弹出来；
- 已知边界：**仅构建号变化、版本号不变的重新发布**（如重新签名重发）不会被视为新版本。
  用户在界面上看到的就是版本号，与"忽略这个版本"的直觉一致。

### 3.2 判定顺序（每次拿到探测结果后执行）

```
latest = 探测到的最新版本, ignored = 记录中的被忽略版本, installed = 本机当前版本

1. installed >= ignored        → 清除记录，按常规逻辑展示（用户已自己升上去了）
2. latest >  ignored           → 清除记录，正常提示更新（出现了更高的新版本）
3. latest <= ignored           → 抑制：条目移入「已忽略」分组，不提示、不计数
4. 无记录                      → 常规逻辑
```

### 3.3 忽略记录的失效条件

| 条件 | 行为 |
|---|---|
| 出现高于被忽略版本的更新 | 自动清除，恢复提示 |
| 本机版本 ≥ 被忽略版本 | 自动清除 |
| 用户手动「取消忽略」 | 立即清除 |
| 应用被卸载 / 扫描不到 | **保留**（重装回来不重复弹已拒绝过的版本） |
| 时间到期 | **不设时间失效**。忽略的语义是"忽略这个版本"，天然失效于出现更高版本；时间失效会让用户莫名再次收到同一个提示。`ignoredAt` 仅为将来的管理界面留口子 |

## 4. 不同检测场景下的预期行为

| 场景 | 行为 |
|---|---|
| 全量检查，latest == 忽略版本 | 探测照常发出（不探测无法知道有没有更高版本），结果被判定层归入「已忽略」，不提示 |
| 全量检查，latest > 忽略版本 | 正常进「可更新」，忽略记录自动清除 |
| 全量检查，latest < 忽略版本（上游回滚/降版） | 同样抑制 |
| 升级收尾的增量刷新 | 被抑制条目**跳过重新探测**——上游版本不会因为本机升级了别的应用而改变，重问是白问（与 `IncrementalChecker` 的既有哲学一致） |
| 用户对某条手动「刷新」 | 强制探测一次；发现更高版本则恢复提示并清记录 |
| 探测失败 | 照常显示检查失败，忽略记录不动 |
| 忽略动作本身 | 立即重算分组 + 落盘，行当场从「可更新」移入「已忽略」 |

## 5. UI

- 入口：应用行的「…」菜单新增「忽略这个版本 1.4.4」；
- 新增「已忽略」分组（排在「可更新」之后、「已是最新」之前），
  分组内条目副标题显示"已忽略 1.4.4"，提供「取消忽略」；
- `UpdateGroup` 新增 `.ignored` case（`rawValue = 3` 追加在末尾，旧缓存解码不受影响）。

## 6. 实现落点（已完成）

1. `Core/IgnoredVersions.swift`（新增）：记录模型 + 文件读写 + 判定。
   `IgnoredVersions()`（不带 fileURL）为纯内存空实例供测试注入；生产走
   `IgnoredVersions(fileURL: IgnoredVersions.defaultFileURL)`——注意这与
   `StateCache` 的「nil 即默认磁盘路径」语义不同，注释里已标明。
2. `UpdateStore`：注入、`applyIgnoredVersions()` 作为唯一判定收口
   （check / refresh / 冷启动回放 / 增删记录四条路共用）、`ignoreVersion(of:)` /
   `unignoreVersion(of:)` 动作、`refresh(ids:force:)` 默认跳过被抑制条目、
   `requestUpgrade` 对被忽略条目兜底拒绝。
3. `UpdateGroup` 新增 `.ignored`（rawValue 追加在末尾保证旧数据解码稳定）+
   `displayOrder`（展示顺序与 rawValue 解耦）；`AppUpdate` 新增
   `ignoredVersion` 投影字段（Codable 可选，旧缓存 JSON 缺键解码为 nil）。
4. UI：`AppRowView` 右键菜单「忽略这个版本 x.y.z / 取消忽略」、已忽略行的
   图标与副标题样式、升级按钮对被忽略条目隐藏；`ContentView` 新增「已忽略」
   统计卡，分组按 `displayOrder` 渲染。
5. 测试 `IgnoredVersionsTests`：版本相等边界（`1.4` vs `1.4.0.0`、v 前缀、预发布后缀）、
   判定四分支、键优先级、持久化往返、坏文件兜底、冷启动回放、更高版本自动清除、
   自动刷新跳过 vs 强制探测。测试基建 `ProbeLog` / `StubProbe` 由 private 改 internal
   供复用。

## 7. 已知边界与遗留

- 仅构建号变化、版本号不变的重新发布不会重新触发提示（§3.1，视为符合直觉）。
- headless CLI（`--check` / install）不读取忽略记录：忽略是 GUI 的用户决策，
  CLI 按原始探测结果如实上报；但 CLI 消费缓存时能看到 `ignoredVersion` 投影，
  install 候选会自然排除被忽略条目。
- 一期未覆盖自身更新；如需支持，`SelfUpdateChecker.check` 在返回 `.available`
  前查同一记录文件即可。
- **编译与测试尚未跑通**：本机 Xcode 许可协议未同意，`swift build` 被挡。
  需先执行 `sudo xcodebuild -license accept`，再跑 `swift build && swift test`。
