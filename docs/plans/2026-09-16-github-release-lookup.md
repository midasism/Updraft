# P0-2 实施计划：开源应用走 GitHub Release 查最新版本

日期：2026-09-16 ｜ 分支：`feat/github-release-lookup` ｜ 前置：P0-1（PR #14，v0.3.6 已发布）

## 一、目标

检测覆盖率分析的 ④ 类：**开源项目，有公开 GitHub Release，但本工具不认**。
预计可更新 **+3**（FlClash、AltTab、Insomnia），无法自动检测 **53 → 47**。

## 二、前置实测（2026-09-16，全部真接口验证）

| 应用 | bundleID | 本地 | `releases/latest` tag | 判定 |
|---|---|---|---|---|
| AltTab | `com.lwouis.alt-tab-macos` | 11.4.3 | `v11.6.1` | **有更新** |
| Insomnia | `com.insomnia.app` | 13.0.2 | `core@13.2.0` | **有更新**（归一后 13.0.2 → 13.2.0）|
| FlClash | `com.follow.clash` | 0.8.91 | `v0.8.98` | **有更新** |
| Clash Verge | `io.github.clash-verge-rev.clash-verge-rev` | 2.5.2 | `v2.5.2` | 已最新 |
| DBeaver Community | `org.jkiss.dbeaver.core.product` | 26.2.0 | `26.2.0` | 已最新 |
| Zed | `dev.zed.Zed` | 1.19.2 | `v1.19.2` | 已最新 |

实测要点：

1. **`/releases/latest` 自动排除 draft 与 prerelease**，6 个仓库全部命中，无需自己过滤。
2. **tag 格式三种并存**：无前缀（`26.2.0`）、`v` 前缀（`v0.8.98`）、**`包名@版本`（`core@13.2.0`）**。
3. Insomnia 是设计文档没料到的新情况：`Version("core@13.2.0")` 会把 `core@13` 段解析成 0，
   跟 `13.0.2` 一比反而判成"本地更新"——**`@` 归一必须放在探针里**，否则 Insomnia 被静默漏掉。
4. 响应体里 release body 含**裸控制字符**，严格 JSON 解析会挂（Python `strict=False` 可复现）；
   Swift `JSONSerialization` 对此宽容，但要写进测试当护栏。
5. 本地 `buildVersion` 不可信：Zed 是时间戳（`20260909.162449`）、FlClash 是日期（`2025122201`），
   GitHub 响应里也没有对应字段——**两边 build 都传 `nil`，只比 version**（与 MASProbe 同款约束）。

## 三、设计决策

1. **新增 `AppSource.githubRelease`**。徽标 `GitHub`，`isAutoDetectable = true`，`probeKey = "github"`。
   编译器会逼着补全 `AppSource` 三个属性、`CheckEngine` 两处、`installAction` 一处的穷举 switch。
2. **映射表是静态白名单**（`Core/GitHubReleaseCatalog.swift`）：`bundleID → owner/repo`，手工维护，
   与设计文档 2.5 的结论一致——没有任何可靠途径从包内自动推出 owner/repo（`io.github.*` 反推只对部分项目成立）。
   表里没有的应用行为完全不变（仍是 `unsupported`）。
3. **分类器插入两个点**：
   - 内嵌 Sparkle 但 feed 硬编码（AltTab 这类）**且** bundleID 命中白名单 → `githubRelease`；
     未命中 → 保持原 unsupported 理由（"内嵌 Sparkle 但更新源在程序内硬编码"）。
   - Electron（`app-update.yml`）**之后**、Microsoft 判定**之前**加兜底：命中白名单 → `githubRelease`。
     应用自带的更新通道永远优先——它比 GitHub 更懂自己的版本节奏。
4. **版本归一放在探针**（`GitHubReleaseProbe.version(fromTag:)`）：
   取最后一个 `@` 之后 → 剥 `v`/`V` 前缀 → **首字符必须是数字，否则返回 nil**（视为查不到，宁可少报不误报）。
   归一后的版本同时用于比较与展示（`0.8.91 → 0.8.98`，不带 `v`）。
5. **只查不装**：`InstallAction` 走 `openDownload`（打开 Release 页），**不做 `.replaceBundle`**。
   理由：GitHub 上的包没有我们的 Ed25519 清单，`Installer` 三道校验的第一道就过不去；
   自动替换第三方应用的签名校验面是另一个量级的事，本期不碰。这与 App Store 的取舍一致。
6. **错误分类**：`HTTP 403` → `failed`（"GitHub API 限额（未登录每小时 60 次），稍后再试"——
   未鉴权限额是这条链路最可能的失败）；`HTTP 404` → `unsupported`（仓库不存在或已改名，映射表过期）；
   其余网络错误 → `failed`（复用 `SparkleProbe.describe`）。6 个应用一轮 6 个请求，远够用。
7. **体积展示**：取 assets 里最大的 `.dmg`/`.zip` 的 size，没有就不显示——与 brew/MAS 行为一致。

## 四、任务

| # | 任务 | 验收 |
|---|---|---|
| 1 | `Core/GitHubReleaseCatalog.swift`：6 条映射 + URL 构造 | 纯函数，无 IO |
| 2 | `Probes/GitHubReleaseProbe.swift`：`GitHubReleaseInfo.parse` + `version(fromTag:)` + `probe` | 归一/解析/错误分类全覆盖 |
| 3 | `AppSource` 加 case + 三个属性；`installAction` 加 case | 编译器穷举 |
| 4 | `AppClassifier` 两个插入点 | 分类测试覆盖 sparkle/electron/兜底三路 |
| 5 | `CheckEngine` 接 `gitHubProbe`（内部 init **不给默认值**，照抄 masProbe 的理由） | 假探针注入，测试不碰网 |
| 6 | 测试 + 本机验证 + README | harness 全绿；真机 `--check` 可更新 10 → 13 |

## 五、风险

| 风险 | 对策 |
|---|---|
| tag 格式再出幺蛾子（如 `release-1.2.3`） | 归一失败返回 nil → `unsupported`，绝不错报"可更新" |
| GitHub 限流导致整批 failed | 只影响白名单内 6 个；403 单独成因，文案可辨认 |
| 映射表过期（仓库改名/归档） | 404 → `unsupported`，理由里带 owner/repo 方便定位 |
| state-v2.json 里旧分类（`unsupported`）反序列化 | `AppSource` 只加 case 不改名，旧值照常解码；全量检查会重写为新分类 |
| 与增量刷新的兼容 | `IncrementalRefreshTests` 现有断言（探测集合）会多一类来源，按新行为改断言并注明 |
