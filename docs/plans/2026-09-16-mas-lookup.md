# App Store 版本检测实施计划（P0-1）

日期：2026-09-16
设计文档：`docs/plans/2026-09-16-detection-coverage-design.md`（第 2.3 / 4 节）
分支：`feat/mas-lookup`

## 目标

`.appStore` 来源从「只标记不检测」改为真检测。本机 18 个 MAS 应用全部能查出最新版本，
其中 9 个确实有更新被漏掉（Magnet `2.14.0 → 3.0.7`、PDF Expert `3.10.5 → 3.13.3`、
微信 `4.1.11 → 4.1.13`、腾讯会议 `3.45.3 → 3.46.1` 等）。

界面预期变化：可更新 `1 → 10`，无法自动检测 `71 → 53`。

## 前置实测结论（写代码前已验完，别再猜）

| 结论 | 证据 |
|---|---|
| **不做 bundle ID 归一** | `bundleId=5ZSL2CJU2T.com.dingtalk.mac` → `resultCount 1`；`bundleId=com.dingtalk.mac` → `resultCount 0`。剥前缀反而查不到，且有误匹配风险 |
| **只能比 `version` 字段** | lookup 响应里**没有 `bundleVersion`**，只有 `version`（营销版本号） |
| **「查不到」是 HTTP 200 + 空数组** | `resultCount: 0, results: []`，不是 404。不能用状态码判断 |
| **`country=cn` 够用** | 本机 18/18 全部命中，包括 DingTalk |
| **有没有 `_MASReceipt` 与能不能查到无关** | Zed / Cursor 的 bundleId 查出来都是 `resultCount 0`——它们本来就不在 App Store，也本来就没有 receipt |

## 任务

### Task 1 — `MASProbe`

**新文件**：`Sources/UpdraftKit/Probes/MASProbe.swift`

```swift
public struct MASProbe: Sendable {
    private let client: HTTPFetching
    public init(client: HTTPFetching = HTTPClient.shared)
    public func probe(_ app: AppInfo) async -> UpdateResult
}
```

要点：

- 没有 `bundleID` 直接 `.unsupported(reason: "没有 Bundle ID，无法查询 App Store")`。
- URL 拼装抽成 `static func lookupURL(bundleID:country:) -> URL?`，好让单测断言
  「bundleID 原样保留」——这是防回归的关键断言（一旦有人又加剥前缀逻辑，这条会红）。
- 请求 `country=cn`；`resultCount == 0` 时**去掉 country 再试一次**（CN 商店没有的应用）。
  两次都空 → `.unsupported(reason: "App Store 上查不到该应用")`。
- 解析抽成 `static func parse(_ data: Data) -> MASLookupResult?`，纯函数、可单测。
  取 `results.first` 的 `version` / `trackViewUrl` / `fileSizeBytes` / `releaseNotes`。
- 版本比较：`VersionComparison.isNewer(latest: .init(shortVersion: version, buildVersion: nil),
  than: .init(shortVersion: app.currentVersion, buildVersion: nil))`
  —— ⚠️ **`buildVersion` 两边都传 `nil`**（见前置结论第 2 条）。
  本地构建号是 `255` / `58012001` 这种整数，对方没有可比字段，不能拿它去比。
- `ReleaseInfo` 映射：
  - `version` ← lookup 的 `version`
  - `size` ← `fileSizeBytes`（字符串，解析成 `Int64`）
  - `downloadURL` ← `trackViewUrl`（App Store 页面链接，让按钮有地方可点）
  - `releaseNotesURL` ← `trackViewUrl`
  - `edSignature` 保持 `nil`——App Store 的包由系统校验，本工具不参与下载
- 错误映射照 `SparkleProbe.describe(error)` 的既有做法复用，不另造一套文案。

### Task 2 — 接进 `CheckEngine`

**文件**：`Sources/UpdraftKit/Core/CheckEngine.swift`

- 新增 `private let masProbe: any UpdateProbing`。
- 公开 init 传 `MASProbe(client: client)`。
- 内部 init 加 `masProbe: any UpdateProbing` —— **不给默认值**。
  理由：给了默认值就是真探针，测试里带 `.appStore` 的用例会真的发网络请求。
  无默认值能逼着每个测试调用点显式声明，编译期拦住这类回归。
- `check` 的事件分发里 `.appStore` 从「直接产出 unsupported」改为 `pending.append(app)`。
- `probe(_:)` 加 `case .appStore: await masProbe.probe(app)`。

### Task 3 — 放开 `isAutoDetectable`

**文件**：`Sources/UpdraftKit/Models/AppSource.swift`

- `isAutoDetectable` 的 `.appStore` 改 `true`。`.microsoftAutoUpdate` 与 `.unsupported` 不动。
- `probeKey` **不动**（`"mas"` 不是必需——`probeKey` 目前全仓没有调用方）。
- `installAction` **不动**：`.appStore` 已有分支返回 `.openDownload`（`UpdateResult.swift:109-110`），
  正是我们要的行为——跳 App Store 页，绝不走 `replaceBundle`。
  这是安全底线：App Store 的包是 `macappstore://` 体系管理的，本工具不能往 `/Applications` 里换。

### Task 4 — 测试调用点

**文件**：`Tests/UpdraftTests/BrewLedgerTests.swift`（233、251）、
`Tests/UpdraftTests/IncrementalRefreshTests.swift`（75、236、536）

五个 `CheckEngine(...)` 调用点补 `masProbe:`，传各自已有的假探针
（`SilentProbe()` / 那个 `probe` 变量）。

**验收**：`grep -rn "CheckEngine(" Tests/` 每一处都带 `masProbe:`。

### Task 5 — 单元测试

**新文件**：`Tests/UpdraftTests/MASLookupTests.swift`

照 `ProbeParsingTests` 的风格，只测纯函数（不发网络）：

| 用例 | 断言 |
|---|---|
| 正常响应 | 解析出 version / size / trackViewUrl |
| 空结果 | `resultCount: 0` → `parse` 返回 `nil`，不崩 |
| 畸形 JSON | 返回 `nil` |
| bundleID 原样保留 | 带 team 前缀的 ID 拼出的 URL query 里是原样字符串 |
| 版本方向 | `Magnet 2.14.0` vs `3.0.7` → 有更新；`4.1.13` vs `4.1.11` → 无（防反向） |
| 不比构建号 | 本地 `buildVersion: "255"`、latest 无构建号时，仍按 shortVersion 判定 |
| `isAutoDetectable` | `.appStore` 现在为 `true` |
| `installAction` | `.appStore` + 有 downloadURL → `.openDownload`（**不是** `.replaceBundle`） |

**加一个假 HTTP 的端到端用例**（照既有 `HTTPFetching` 注入模式）：
喂一段真实形状的 lookup JSON，断言 `MASProbe.probe` 产出 `.updateAvailable`，
且 `release.packageKind == .unknown`（`trackViewUrl` 没有扩展名，不会误判成 dmg）。

### Task 6 — 验收

1. `swift build --disable-sandbox` —— **不接管道**（管道退出码取自 `tail`，会假绿）。
2. 本机真机跑全量：`NSUnbufferedIO=YES .build/debug/Updraft --check`，
   核对「可更新」≥ 10，并对着设计文档 2.3 节那 9 条点名核对。
3. 界面上确认 MAS 条目的按钮是「下载」而不是「升级」——**这条必须肉眼过一遍**，
   单元测试证明不了 SwiftUI 按钮行为。
4. README 功能清单同步（`.appStore` 从「只标记」改成「可查版本」）。

## 不做什么

- ❌ 不剥 bundle ID 前缀（见前置结论）
- ❌ 不动 `AppClassifier` 的判定顺序
- ❌ 不让 `.appStore` 走 `replaceBundle`
- ❌ 不动 `probeKey`、不动 `.microsoftAutoUpdate`
- ❌ 不碰 GitHub 映射表（那是 P0-2，另开分支）

## 风险

| 风险 | 处理 |
|---|---|
| `itunes.apple.com` 限流或改协议 | 单次检查 18 个请求，量很小；失败按 `.failed` 如实报，不猜 |
| 应用不在 CN 商店 | 去掉 country 兜底重试一次 |
| `trackViewUrl` 被当成下载链接 | 用「按钮文案必须是下载不是升级」+ 单测断言 `packageKind` 兜住 |
| 测试意外走真网络 | 内部 init 的 `masProbe` 无默认值，编译期强制显式注入 |
