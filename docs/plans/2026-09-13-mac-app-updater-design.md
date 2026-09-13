# AppUpdater 设计文档

日期：2026-09-13
状态：已确认，v0.1 范围内实施

## 一、要解决的问题

macOS 上没有统一的 App 更新入口。App Store 管一批，Homebrew 管一批，手动下载装的各有各的更新器，剩下的一堆压根不告诉你有没有新版。

本机实测：`/Applications` 下 119 个应用，其中

| 更新机制 | 数量 | 能否自动检测 |
|---|---|---|
| Sparkle（含内嵌框架） | 32 | 能 |
| Electron（有 app-update.yml） | 15 | 能 |
| App Store（有 _MASReceipt） | 28 | v0.2 |
| Microsoft AutoUpdate | 4 | v0.2 |
| Homebrew cask | 4 | 能 |
| 专有更新器 / 无公开接口 | 44 | 否，只能标记 |

**v0.1 目标：把 51 个可自动检测的应用的更新状态，一次性摆在一个窗口里，并让能一键升的直接升完。**

## 二、关键假设与已验证事实

以下均在实施前实测通过，不是纸面推断：

1. `brew outdated --cask --greedy` 可用，实测报出 `ngrok`、`tabularis` 待更新。
2. Sparkle appcast 可拉取可解析。实测 IINA：本机 `1.3.5`，线上 `1.4.4`，enclosure 提供 dmg 直链 `https://dl-portal.iina.io/IINA.v1.4.4.dmg`（109 MB）与 EdDSA 签名。
3. Sparkle 的 `SUFeedURL` 存在 `Contents/Info.plist`；少数应用（AltTab、Bob 等）只内嵌 `Sparkle.framework` 而不带该键，需降级处理。
4. Electron 应用的 `Contents/Resources/app-update.yml` 暴露更新源（多数为 GitHub Releases 或 S3）。
5. Swift 6.3.2 工具链与 Xcode 就绪，可用 SwiftPM 构建 SwiftUI 可执行程序并手工组装 `.app`。

## 三、v0.1 范围内做的与不做的

### 做

1. 独立窗口 App，Dock 可见，⌘Tab 可切换，⌘W 关窗不退出。
2. 启动后自动检查一次，工具栏提供「重新检查」手动触发。
3. 检测覆盖 Sparkle 32 + Electron 15 + Homebrew cask 4 = 51 个应用。
4. 三档分组列表（可更新 / 已是最新 / 无法自动检测）+ 三个统计卡片。
5. 更新动作两条路：
   - Homebrew cask → 调 `brew upgrade --cask`，流式显示输出日志。
   - Sparkle / Electron → 在浏览器打开安装包直链，用户自行完成安装。
6. 检查结果缓存到 `~/Library/Application Support/AppUpdater/state.json`，冷启动先渲染缓存再后台刷新。

### 不做（留给 v0.2）

- 自动挂载 dmg 并替换 `/Applications` 下的 App 包。
- 每日定时后台检查与系统通知。
- 菜单栏图标常驻。
- App Store 应用接入（需引入 `mas` 或走 iTunes Lookup API）。
- 真实应用图标提取（v0.1 用首字母色块）。

**v0.1 的安全边界：全过程不写入 `/Applications`，不修改任何被检查的应用。** 最坏情况是版本号显示有误。

## 四、架构

单进程、四层，检测逻辑与 UI 完全解耦。

```
AppUpdaterApp (SwiftUI 入口)
  └─ UpdateStore (@MainActor, ObservableObject)  ← 唯一状态源
       ├─ AppScanner        扫描 /Applications 与 ~/Applications
       ├─ AppClassifier     读 Info.plist 归类
       ├─ [Probe]           并发探针，统一协议
       ├─ StateCache        结果落盘 / 读取
       └─ HomebrewUpdater   执行升级并回传日志
```

### 4.1 数据模型

```swift
struct AppInfo {
    let name: String            // CFBundleDisplayName 或文件名
    let bundleID: String?
    let path: URL               // .app 路径
    let currentVersion: String? // CFBundleShortVersionString
    let buildVersion: String?   // CFBundleVersion
    let source: AppSource       // 分类结果
}

enum AppSource {
    case homebrewCask(token: String)   // brew token，如 "ngrok"
    case sparkle(feedURL: URL, embedded: Bool)
    case electron(feedURL: URL)
    case appStore
    case microsoftAutoUpdate
    case proprietary                   // Adobe / 游戏 / JetBrains 等
    case unknown
}

enum UpdateResult {
    case upToDate(latest: String)
    case updateAvailable(latest: String, downloadURL: URL?, releaseNotes: URL?, size: Int64?)
    case unsupported(reason: String)   // 无法自动检测
    case failed(reason: String)        // 网络/解析失败，可重试
}

struct AppUpdate {
    let app: AppInfo
    let result: UpdateResult
    let checkedAt: Date
}
```

### 4.2 探针协议

```swift
protocol UpdateProbe: Sendable {
    var source: AppSource { get }
    func probe(_ app: AppInfo) async -> UpdateResult
}
```

新增一种更新来源 = 新增一个探针文件 + 在分类器里加一条判定，不改动其他任何代码。这是为 v0.2 接入 App Store 和 Chrome 私有更新接口预留的扩展点。

三种探针实现：

| 探针 | 输入 | 输出 |
|---|---|---|
| `SparkleProbe` | `SUFeedURL` | GET appcast.xml，取 `<item>` 中 `sparkle:shortVersionString` 最大者，比对 `CFBundleShortVersionString`；同时取 enclosure 的 url 与 length |
| `ElectronProbe` | `app-update.yml` | 解析 `provider` / `owner` / `repo` / `url`，GitHub 走 Releases API 取 `tag_name`，S3 走 `latest-mac.yml` |
| `BrewProbe` | 全量 cask 列表 | 一次 `brew outdated --cask --greedy --json=v2` 拿到全部，避免逐个调用 |

`BrewProbe` 是一次调用覆盖所有 cask 的批处理探针，不能按 app 粒度调用——逐个 `brew info` 会慢到无法接受。

### 4.3 版本比对

不能直接字符串比较，也不能用纯 `SemVer`：

- Sparkle 的 `sparkle:version` 与 `CFBundleVersion` 是**递增整数**，最可靠。
- 若整数不可用，退化为 `CFBundleShortVersionString` 的点分数字比较（`1.4.4 > 1.3.5`）。
- 处理混合格式（`1.0` vs `1.0.0`）、带后缀（`2.1.0-beta`）时，只比较前若干段数字，后缀不计入。

规则：先比 build 整数，回退到点分数字；任一为空则判为 `failed`，绝不猜测。

### 4.4 并发与性能

- 32 个 Sparkle + 15 个 Electron 需发网络请求。用 `withTaskGroup` 限流 8 并发。
- 单请求超时 10 秒，整体检查目标 15 秒内完成。
- 探针失败只影响单个应用，记为 `failed`，不中断整轮。
- 冷启动先读缓存渲染，后台静默刷新后 diff 更新 UI。

### 4.5 UI 结构

```
AppUpdaterApp
  └─ ContentView
       ├─ HeaderView        标题 + 上次检查时间 + 重新检查按钮
       ├─ StatsRow          三个统计卡片
       └─ AppListView
            ├─ Section「可更新」    行内有更新按钮
            ├─ Section「已是最新」
            └─ Section「无法自动检测」
```

行组件 `AppRowView` 展示：图标色块、名称、来源徽标、`旧版本 → 新版本`、包大小、动作按钮。

按钮语义区分明确：Homebrew 行是「升级」（真能升完），Sparkle 行是「下载」（打开直链）。

## 五、错误处理

| 场景 | 行为 |
|---|---|
| 单个 appcast 超时 | 该应用标记 `failed`，行内显示「检查失败 · 重试」 |
| appcast XML 解析失败 | 同上，不抛全局错误 |
| 应用无 `CFBundleShortVersionString` | 标记 `unsupported` |
| 内嵌 Sparkle 但无 `SUFeedURL` | 标记 `unsupported`，不臆测 feed 地址 |
| `brew` 未安装或不在 PATH | 整块 cask 检测禁用并提示，其余功能正常 |
| brew 升级失败 | 保留完整 stderr 输出，可复制 |
| 网络完全不可用 | 展示缓存结果 + 明确的「离线，以下为上次结果」提示 |

原则：**任何局部失败都不能让整个窗口变成空的。** 能显示多少显示多少。

## 六、测试策略

- **纯逻辑单测**：版本比对（含边界：相等、递增整数 vs 点分、空值、后缀）、appcast XML 解析、`app-update.yml` 解析。用真实抓取的 XML 片段做 fixture。
- **扫描器测试**：对临时构造的伪 `.app` 目录树断言分类结果。
- **探针测试**：注入 stub HTTP 客户端，覆盖 200 / 404 / 超时 / 畸形 XML 四条路径。
- **端到端**：在本机真实运行，核对检测出的可更新应用与 `brew outdated`、各应用 appcast 的人工核对结果是否一致。

## 七、交付形态

SwiftPM 可执行目标，由 `scripts/build-app.sh` 组装为 `AppUpdater.app`：

```
AppUpdater.app/Contents/
  ├─ Info.plist          (CFBundleIdentifier / CFBundleName / LSMinimumSystemVersion)
  ├─ MacOS/AppUpdater    编译产物
  └─ Resources/          图标等待补
```

不依赖 Xcode 工程文件，`swift build -c release` 即可产出。首次运行因未签名需要右键打开，或 `xattr -d com.apple.quarantine`。

## 八、v0.2 路线

1. Sparkle 应用自动安装：下载 → 校验 EdDSA 签名 → 检查 App 是否运行 → 备份旧版到废纸篓 → 替换 → 去隔离属性 → 重开。
2. 每日定时检查 + 系统通知 + 菜单栏徽标。
3. App Store 应用接入。
4. Chrome / Edge 私有更新接口、JetBrains Toolbox 等专有源的针对性适配。
