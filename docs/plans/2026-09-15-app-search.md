# App 搜索功能实施计划

> **For implementer:** Use TDD throughout. Write failing test first. Watch it fail. Then implement.

**Goal:** 在主窗口加一个搜索框，按名称与 Bundle ID 实时过滤三档分组列表，并让「全部升级」收窄为「只升筛出来的」。

**Architecture:** 匹配逻辑做成独立纯函数 `AppSearch`（`Models/`），不进 `UpdateStore`、不进视图。筛选词由 `ContentView` 的 `@State` 持有，视图把过滤结果作为参数传给 store 的批量升级入口——store 始终不知道「搜索」存在。三张统计卡片保持全量口径，只有列表与批量按钮走筛选口径。

**Tech Stack:** Swift 5.9 / SwiftUI (macOS 13+) / SwiftPM，零第三方依赖。

**设计文档：** [`docs/plans/2026-09-15-app-search-design.md`](2026-09-15-app-search-design.md)

---

## 环境前提（先读这条）

**本机没有完整 Xcode，只有 Command Line Tools**，因此 `swift test` 会报 `no such module 'XCTest'`。分工如下：

| 验证手段 | 本机 | CI (`macos-latest`) |
|---|---|---|
| `swift build --disable-sandbox` | ✅ 可用 | ✅ |
| `swift test --disable-sandbox` | ❌ 缺 Xcode | ✅ 权威 |
| `swiftc` 直编纯逻辑 + 断言驱动 | ✅ 可用（Task 1 用） | — |
| `--snapshot` 离屏渲染 PNG | ✅ 可用（实测 17 秒出图） | — |

**所以：仓库里的 XCTest 用例照写（CI 跑），Task 1 另配一个 `swiftc` 断言驱动在本机看红绿。** 两者是同一组断言的两种写法——装好 Xcode 后驱动即可删除。

---

## Task 1: AppSearch 纯匹配器

**Files:**
- Create: `Sources/AppUpdaterKit/Models/AppSearch.swift`
- Test: `Tests/AppUpdaterTests/AppSearchTests.swift`
- 临时驱动: `/tmp/AppSearchCheck.swift`（不进仓库）

### Step 1: 写断言驱动，看它失败

先建 `/tmp/AppSearchCheck.swift`（现在 `AppSearch` 还不存在，这一步必定编译失败——这就是红）：

```swift
import Foundation

var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ✔ \(label)")
    } else {
        failures.append(label)
        print("  ✘ \(label)")
    }
}

func update(_ name: String, bundleID: String? = nil) -> AppUpdate {
    let app = AppInfo(
        name: name,
        bundleID: bundleID,
        path: URL(fileURLWithPath: "/Applications/\(name).app"),
        currentVersion: "1.0",
        buildVersion: nil,
        source: .sparkle(feedURL: nil)
    )
    return AppUpdate(app: app, result: .upToDate(latest: "1.0"))
}

let sample = [
    update("Cherry Studio", bundleID: "com.kangfenmao.CherryStudio"),
    update("IINA", bundleID: "com.colliderli.iina"),
    update("微信", bundleID: "com.tencent.xinWeChat"),
    update("ngrok")
]

func names(_ updates: [AppUpdate]) -> [String] { updates.map(\.app.name) }

@main
struct Check {
    static func main() {
        print("AppSearch 断言：")

        check(names(AppSearch.filter(sample, query: "")) == names(sample), "空词返回全量而不是空")
        check(names(AppSearch.filter(sample, query: "   ")) == names(sample), "纯空白词返回全量")
        check(names(AppSearch.filter(sample, query: "  iina  ")) == ["IINA"], "首尾空白被裁掉")
        check(names(AppSearch.filter(sample, query: "CHERRY")) == ["Cherry Studio"], "大小写不敏感")
        check(names(AppSearch.filter(sample, query: "com.colliderli")) == ["IINA"], "Bundle ID 可命中")
        check(names(AppSearch.filter(sample, query: "ngrok")) == ["ngrok"], "bundleID 为 nil 不崩")
        check(names(AppSearch.filter(sample, query: "ch stu")) == ["Cherry Studio"], "多词 AND 正例")
        check(AppSearch.filter(sample, query: "ch zzz").isEmpty, "多词 AND 反例")
        check(names(AppSearch.filter(sample, query: "cherry com.kangfenmao")) == ["Cherry Studio"], "token 可分别命中不同字段")
        check(AppSearch.filter(sample, query: "不存在的词").isEmpty, "零命中返回空数组")
        check(names(AppSearch.filter(sample, query: "微信")) == ["微信"], "中文名可命中")

        let zebra = update("Zebra", bundleID: "com.z")
        let apple = update("Apple", bundleID: "com.a")
        check(names(AppSearch.filter([zebra, apple], query: "a")) == ["Zebra", "Apple"], "过滤不改顺序")

        if failures.isEmpty {
            print("全部通过")
            exit(0)
        }
        print("\(failures.count) 条失败：\(failures.joined(separator: "、"))")
        exit(1)
    }
}
```

### Step 2: 跑驱动 —— 确认失败

```bash
cd /Users/midasgao/code/github_project/midasism-Updraft
swiftc -o /tmp/appsearch-check \
  Sources/AppUpdaterKit/Models/AppInfo.swift \
  Sources/AppUpdaterKit/Models/AppSource.swift \
  Sources/AppUpdaterKit/Models/ReleaseInfo.swift \
  Sources/AppUpdaterKit/Models/UpdateResult.swift \
  /tmp/AppSearchCheck.swift
```

Expected: 编译失败 —— `cannot find 'AppSearch' in scope`。

> 这五个文件是 Models 里不依赖 AppKit 的纯数据子集（`UpgradeJob.swift` 依赖 `Installer.Plan`，所以不在列表里）。

### Step 3: 写最小实现

Create `Sources/AppUpdaterKit/Models/AppSearch.swift`：

```swift
import Foundation

/// 列表筛选的纯判定逻辑。
///
/// 刻意不放进 `UpdateStore`，也不放进视图：它只回答「给定一条记录和一个查询词，
/// 匹不匹配」，没有状态、不碰网络、不认识 SwiftUI。这样这批边界断言不必借 GUI
/// 与真机就能密集地写。与 `CheckPlanner`（只回答「现在该不该查」）是同一个路子。
public enum AppSearch {
    /// 把查询词按空白切成 token。
    ///
    /// 空数组表示「不筛选」——注意是不过滤，不是过滤掉全部。这是最容易写反的一处。
    /// `split` 顺带办掉了裁首尾空白与合并连续空白两件事，不需要额外 trim。
    public static func tokenize(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 每个 token 都要在「名称或 Bundle ID」里命中才算通过。
    ///
    /// 允许不同 token 命中不同字段：`"cherry com.kangfenmao"` 也成立。
    public static func matches(_ update: AppUpdate, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let fields = [update.app.name, update.app.bundleID].compactMap { $0 }
        return tokens.allSatisfy { token in
            fields.contains { $0.localizedCaseInsensitiveContains(token) }
        }
    }

    /// 过滤整个列表。查询词为空时原样返回。
    ///
    /// 顺序也不动——沿用 `AppUpdate.listOrder` 已经排好的结果，排序只有那一处定义。
    public static func filter(_ updates: [AppUpdate], query: String) -> [AppUpdate] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return updates }
        return updates.filter { matches($0, tokens: tokens) }
    }
}
```

### Step 4: 跑驱动 —— 确认通过

```bash
cd /Users/midasgao/code/github_project/midasism-Updraft
swiftc -o /tmp/appsearch-check \
  Sources/AppUpdaterKit/Models/AppInfo.swift \
  Sources/AppUpdaterKit/Models/AppSource.swift \
  Sources/AppUpdaterKit/Models/ReleaseInfo.swift \
  Sources/AppUpdaterKit/Models/UpdateResult.swift \
  Sources/AppUpdaterKit/Models/AppSearch.swift \
  /tmp/AppSearchCheck.swift && /tmp/appsearch-check
```

Expected: 12 行 `✔` + `全部通过`，退出码 0。

### Step 5: 写仓库里的 XCTest 用例（CI 跑）

Create `Tests/AppUpdaterTests/AppSearchTests.swift`：

```swift
import XCTest
@testable import AppUpdaterKit

/// 搜索匹配规则的边界。纯逻辑，不碰 GUI 与网络。
final class AppSearchTests: XCTestCase {
    private func update(_ name: String, bundleID: String? = nil) -> AppUpdate {
        let app = AppInfo(
            name: name,
            bundleID: bundleID,
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            currentVersion: "1.0",
            buildVersion: nil,
            source: .sparkle(feedURL: nil)
        )
        return AppUpdate(app: app, result: .upToDate(latest: "1.0"))
    }

    private lazy var sample: [AppUpdate] = [
        update("Cherry Studio", bundleID: "com.kangfenmao.CherryStudio"),
        update("IINA", bundleID: "com.colliderli.iina"),
        update("微信", bundleID: "com.tencent.xinWeChat"),
        update("ngrok")
    ]

    private func names(_ updates: [AppUpdate]) -> [String] { updates.map(\.app.name) }

    func testEmptyQueryReturnsEverything() {
        XCTAssertEqual(
            names(AppSearch.filter(sample, query: "")),
            names(sample),
            "空词是「不筛选」，不是「筛掉全部」"
        )
    }

    func testWhitespaceOnlyQueryReturnsEverything() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "   ")), names(sample))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "  iina  ")), ["IINA"])
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "CHERRY")), ["Cherry Studio"])
    }

    func testBundleIDIsSearchable() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "com.colliderli")), ["IINA"])
    }

    func testEntriesWithoutBundleIDDoNotCrash() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "ngrok")), ["ngrok"])
        XCTAssertTrue(AppSearch.filter(sample, query: "com.").count < sample.count, "缺 Bundle ID 的条目不该因为拿不到字段就全命中")
    }

    func testEveryTokenMustMatch() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "ch stu")), ["Cherry Studio"])
        XCTAssertTrue(AppSearch.filter(sample, query: "ch zzz").isEmpty)
    }

    func testTokensMayMatchDifferentFields() {
        XCTAssertEqual(
            names(AppSearch.filter(sample, query: "cherry com.kangfenmao")),
            ["Cherry Studio"]
        )
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(AppSearch.filter(sample, query: "不存在的词").isEmpty)
    }

    func testChineseNameIsSearchable() {
        XCTAssertEqual(names(AppSearch.filter(sample, query: "微信")), ["微信"])
    }

    func testFilteringPreservesOrder() {
        let zebra = update("Zebra", bundleID: "com.z")
        let apple = update("Apple", bundleID: "com.a")
        XCTAssertEqual(
            names(AppSearch.filter([zebra, apple], query: "a")),
            ["Zebra", "Apple"],
            "过滤不改顺序，排序只由 AppUpdate.listOrder 定义"
        )
    }

    func testTokenizeCollapsesWhitespace() {
        XCTAssertEqual(AppSearch.tokenize("  ch \t stu \n"), ["ch", "stu"])
        XCTAssertTrue(AppSearch.tokenize("   ").isEmpty)
    }
}
```

### Step 6: 确认整包还能编译

```bash
cd /Users/midasgao/code/github_project/midasism-Updraft
swift build --disable-sandbox
```

Expected: `Build complete!`

### Step 7: 提交

```bash
git add Sources/AppUpdaterKit/Models/AppSearch.swift Tests/AppUpdaterTests/AppSearchTests.swift
git commit -m "feat(search): AppSearch 纯匹配器（名称 + Bundle ID，多词 AND）"
```

---

## Task 2: 批量升级收窄到指定条目

**Files:**
- Modify: `Sources/AppUpdaterKit/UI/UpdateStore.swift`（第 105-112 行的派生数据区、第 278-286 行的 `requestUpgradeAll`）
- Test: `Tests/AppUpdaterTests/UpgradeTests.swift`（文件末尾追加一个测试类）
- 临时驱动: `/tmp/UpgradeSelectionCheck.swift`（不进仓库）

### Step 1: 写临时驱动，看它失败

建 `/tmp/UpgradeSelectionCheck.swift`：

```swift
import Foundation

var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    if condition { print("  ✔ \(label)") } else { failures.append(label); print("  ✘ \(label)") }
}

func update(_ name: String, source: AppSource, result: UpdateResult) -> AppUpdate {
    let app = AppInfo(
        name: name,
        bundleID: "com.example.\(name.lowercased())",
        path: URL(fileURLWithPath: "/Applications/\(name).app"),
        currentVersion: "1.0",
        buildVersion: nil,
        source: source
    )
    return AppUpdate(app: app, result: result)
}

@main
struct Check {
    static func main() {
        print("批量升级选条目：")

        let dmg = URL(string: "https://example.com/A.dmg")!
        let available = UpdateResult.updateAvailable(ReleaseInfo(version: "2.0", downloadURL: dmg))

        let batch = [
            update("Sparkle 可换包", source: .sparkle(feedURL: nil), result: available),
            update("仓库里的", source: .homebrewCask(token: "x"), result: available),
            update("已是最新", source: .sparkle(feedURL: nil), result: .upToDate(latest: "1.0")),
            update("AppStore 的", source: .appStore, result: available)
        ]

        let picked = UpdateStore.automatedCandidates(in: batch)
        check(picked.map(\.app.name) == ["Sparkle 可换包", "仓库里的"], "只挑出能自动完成的")
        check(UpdateStore.automatedCandidates(in: []).isEmpty, "空列表返回空")
        check(
            UpdateStore.automatedCandidates(in: [batch[2]]).isEmpty,
            "已是最新的条目不该进批量（守着「不顺手升全量」）"
        )

        if failures.isEmpty { print("全部通过"); exit(0) }
        print("\(failures.count) 条失败：\(failures.joined(separator: "、"))")
        exit(1)
    }
}
```

跑：

```bash
cd /Users/midasgao/code/github_project/midasism-Updraft
swiftc -o /tmp/upgrade-selection-check \
  Sources/AppUpdaterKit/Models/AppInfo.swift \
  Sources/AppUpdaterKit/Models/AppSource.swift \
  Sources/AppUpdaterKit/Models/ReleaseInfo.swift \
  Sources/AppUpdaterKit/Models/UpdateResult.swift \
  /tmp/UpgradeSelectionCheck.swift 2>&1 | tail -5
```

Expected: 失败 —— `cannot find 'UpdateStore' in scope`（`UpdateStore` 依赖 AppKit，本机跑不了驱动，因此**这个任务的驱动只能验证「选条目」这一层的纯逻辑，实现之后改用 `swift build` + 真机验证**）。

> 修正说明：`UpdateStore` 依赖 AppKit 且 `check()` 会扫真实目录，本机无法直编。所以 Task 2 的具体做法是——
> **把「选条目」这段逻辑抽成 `static` 纯函数**（不依赖 `UpdateStore` 实例），再把它单独 `swiftc` 验；
> 驱动里 `UpdateStore.automatedCandidates` 那三行改成下面 Step 3 的等价断言，见 Step 2。

### Step 2: 把断言驱动改成只依赖纯数据的版本

删掉 `/tmp/UpgradeSelectionCheck.swift` 里的 `UpdateStore` 调用，改成直接验证筛选谓词（`UpdateStore.automatedCandidates` 就是它的命名包装）：

```swift
@main
struct Check {
    static func main() {
        print("批量升级选条目：")

        let dmg = URL(string: "https://example.com/A.dmg")!
        let available = UpdateResult.updateAvailable(ReleaseInfo(version: "2.0", downloadURL: dmg))

        let batch = [
            update("Sparkle 可换包", source: .sparkle(feedURL: nil), result: available),
            update("仓库里的", source: .homebrewCask(token: "x"), result: available),
            update("已是最新", source: .sparkle(feedURL: nil), result: .upToDate(latest: "1.0")),
            update("AppStore 的", source: .appStore, result: available)
        ]

        let picked = batch.filter { $0.installAction.isAutomated }
        check(picked.map(\.app.name) == ["Sparkle 可换包", "仓库里的"], "只挑出能自动完成的")
        check(batch.filter { $0.installAction.isAutomated }.isEmpty == false, "非空批次能挑出东西")
        check([batch[2]].filter { $0.installAction.isAutomated }.isEmpty, "已是最新的不进批量")
        check([batch[3]].filter { $0.installAction.isAutomated }.isEmpty, "App Store 的不进批量")

        if failures.isEmpty { print("全部通过"); exit(0) }
        print("\(failures.count) 条失败：\(failures.joined(separator: "、"))")
        exit(1)
    }
}
```

```bash
swiftc -o /tmp/upgrade-selection-check \
  Sources/AppUpdaterKit/Models/AppInfo.swift \
  Sources/AppUpdaterKit/Models/AppSource.swift \
  Sources/AppUpdaterKit/Models/ReleaseInfo.swift \
  Sources/AppUpdaterKit/Models/UpdateResult.swift \
  /tmp/UpgradeSelectionCheck.swift && /tmp/upgrade-selection-check
```

Expected: 4 行 `✔` + `全部通过`。这一步确认「哪些条目算可自动完成」的前提成立，接下来的改动只是把这段谓词搬进 store。

### Step 3: 改实现

修改 `Sources/AppUpdaterKit/UI/UpdateStore.swift`。

**(a) 删掉 `automatedUpdateCount`（第 109-112 行）**——它将被 `automatedCandidates(in:)` 取代，留着就是同一件事的第二个定义：

```swift
    /// 能由本工具自己走完安装的条目数，决定「全部升级」按钮是否出现。
    public var automatedUpdateCount: Int {
        updates(in: .updateAvailable).filter { $0.installAction.isAutomated }.count
    }
```

删掉整段。调用点只有 `ContentView.swift:60`，Task 3 会一并改掉。

**(b) 替换 `requestUpgradeAll`（第 278-286 行）**：

```swift
    /// 全部升级：把能自动完成的条目合成一个任务，顺序执行。
    ///
    /// - Parameter visible: 界面当前筛出来的那批。传 nil 表示没有筛选，对全量生效。
    ///   搜索框有词时必须传它——否则用户筛出 1 个再点「升级这 1 个」，
    ///   结果升的是全量二十几个，而他一个都没看见。
    public func requestUpgradeAll(visible: [AppUpdate]? = nil) {
        guard job?.isRunning != true else { return }
        let candidates = Self.automatedCandidates(in: visible ?? updates)
        guard !candidates.isEmpty else { return }
        job = UpgradeJob(items: candidates.compactMap { makeItem(from: $0) })
    }

    /// 从一批条目里挑出本工具能自己走完安装的那些。
    ///
    /// 抽成静态纯函数是为了能被断言：`updates` 是 `private(set)`，且填充它要跑真实
    /// 扫描，测试里造不出来。而「只升传进来的这批」恰恰是最需要守住的边界，
    /// 不能只靠读代码相信。
    ///
    /// `candidates` 已经全部是 `.updateAvailable`（`installAction` 只在这种情况下
    /// 才不是 `.manual`），所以 `makeItem` 不会在这里丢掉任何一条。
    public static func automatedCandidates(in updates: [AppUpdate]) -> [AppUpdate] {
        updates.filter { $0.installAction.isAutomated }
    }
```

`SnapshotRunner.swift:199` 的 `store.requestUpgradeAll()` 因为参数有默认值，不用改。

### Step 4: 确认整包编译

```bash
cd /Users/midasgao/code/github_project/midasism-Updraft
swift build --disable-sandbox
```

Expected: `Build complete!` —— 注意这一步会先在 `ContentView.swift:60` 报 `automatedUpdateCount` 找不到，**这是预期的**，Task 3 修。若想先绿再加 Task 3，可临时把该行改成 `store.automatedCandidates...`；但按顺序做完 Task 3 更省事。

### Step 5: 写 XCTest 用例（CI 跑）

在 `Tests/AppUpdaterTests/UpgradeTests.swift` 末尾追加：

```swift
/// 「全部升级」只该动传进来的那批。
///
/// 这条边界靠读代码守不住：搜索框有词时，参数传错的话用户筛出 1 个却升了全量，
/// 而界面上一个提示都不会有。
final class AutomatedCandidateTests: XCTestCase {
    private func update(_ name: String, source: AppSource, result: UpdateResult) -> AppUpdate {
        let app = AppInfo(
            name: name,
            bundleID: "com.example.\(name.lowercased())",
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            currentVersion: "1.0",
            buildVersion: nil,
            source: source
        )
        return AppUpdate(app: app, result: result)
    }

    private func available() -> UpdateResult {
        .updateAvailable(
            ReleaseInfo(version: "2.0", downloadURL: URL(string: "https://example.com/A.dmg")!)
        )
    }

    func testOnlyAutoInstallableEntriesArePicked() {
        let batch = [
            update("Sparkle 可换包", source: .sparkle(feedURL: nil), result: available()),
            update("仓库里的", source: .homebrewCask(token: "x"), result: available()),
            update("已是最新", source: .sparkle(feedURL: nil), result: .upToDate(latest: "1.0")),
            update("AppStore 的", source: .appStore, result: available())
        ]

        XCTAssertEqual(
            UpdateStore.automatedCandidates(in: batch).map(\.app.name),
            ["Sparkle 可换包", "仓库里的"],
            "已是最新与 App Store 的都不该进批量任务"
        )
    }

    func testEmptyInputYieldsEmptySelection() {
        XCTAssertTrue(UpdateStore.automatedCandidates(in: []).isEmpty)
    }

    func testPkgOnlyEntryIsNotAutomated() {
        let pkg = update(
            "pkg 应用",
            source: .sparkle(feedURL: nil),
            result: .updateAvailable(
                ReleaseInfo(version: "2.0", downloadURL: URL(string: "https://example.com/A.pkg")!)
            )
        )
        XCTAssertTrue(
            UpdateStore.automatedCandidates(in: [pkg]).isEmpty,
            ".pkg 需要管理员密码，只能交给系统安装器"
        )
    }
}
```

### Step 6: 提交

```bash
git add Sources/AppUpdaterKit/UI/UpdateStore.swift Tests/AppUpdaterTests/UpgradeTests.swift
git commit -m "feat(search): 批量升级收窄到指定条目，automatedCandidates 可断言"
```

---

## Task 3: ContentView 搜索框、过滤与空态

**Files:**
- Modify: `Sources/AppUpdaterKit/UI/ContentView.swift`

这个任务靠 `--snapshot` + 真机验证，没有单元测试（项目里没有 GUI 测试）。

### Step 1: 改 `init` 与状态

把第 3-11 行替换为：

```swift
public struct ContentView: View {
    @ObservedObject private var store: UpdateStore
    /// 打开设置窗口；nil 时不显示齿轮（截图通道走默认值，不需要真窗口路由）。
    private let openSettings: (() -> Void)?
    /// 筛选词。刻意留在视图态而不是 `UpdateStore`：它是瞬时的界面状态，
    /// 不该进状态源，也不该让 store 知道「搜索」这件事存在。
    @State private var query: String
    @FocusState private var isSearchFocused: Bool

    public init(store: UpdateStore, openSettings: (() -> Void)? = nil, initialQuery: String = "") {
        self.store = store
        self.openSettings = openSettings
        _query = State(initialValue: initialQuery)
    }
```

### Step 2: 加派生数据

在 `body` 之后、`header` 之前插入：

```swift
    // MARK: - 筛选

    /// 当前筛选结果。查询词为空时就是全量。
    private var filteredUpdates: [AppUpdate] {
        AppSearch.filter(store.updates, query: query)
    }

    private func filtered(in group: UpdateGroup) -> [AppUpdate] {
        filteredUpdates.filter { $0.group == group }
    }

    private var isFiltering: Bool { !AppSearch.tokenize(query).isEmpty }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 筛选后仍能自动完成的条目数，决定「升级这 N 个」是否出现。
    private var visibleAutomatedCount: Int {
        UpdateStore.automatedCandidates(in: filtered(in: .updateAvailable)).count
    }
```

### Step 3: header 加搜索框、按钮文案跟着筛选走

把第 60-65 行的按钮替换为：

```swift
            if visibleAutomatedCount > 1, store.job?.isRunning != true {
                Button(isFiltering ? "升级这 \(visibleAutomatedCount) 个" : "全部升级") {
                    store.requestUpgradeAll(visible: filteredUpdates)
                }
                .disabled(store.isBusy)
            }
```

在 `Spacer(minLength: 12)`（第 50 行）之后插入：

```swift
            searchField
```

并在 `header` 之外新增：

```swift
    /// 自绘搜索框。
    ///
    /// 不用 `.searchable`：它的落点依赖 NavigationStack / toolbar 容器，而这个窗口是
    /// 一段自排的 VStack，搜索框会被塞到哪一层不可预期；`--snapshot` 通道还要求
    /// 渲染确定、可复现。代价是 ⌘F 要自己接。
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("搜索应用", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFocused)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("清除筛选")
                .accessibilityLabel("清除筛选")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSearchFocused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25),
                    lineWidth: 1
                )
        )
        .frame(width: 180)
        .onExitCommand { query = "" }
        .background(
            // 零尺寸的隐藏按钮只为接住 ⌘F。放在视图里而不是 .commands，是为了不把
            // 焦点状态（@FocusState）跨层传到 App 入口。
            Button("搜索") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .help("按名称或 Bundle ID 过滤（⌘F）")
    }
```

> ⚠️ **风险点**：`.opacity(0).frame(width: 0, height: 0)` 的隐藏按钮接快捷键是 SwiftUI on macOS 的常规变通，但需要真窗口才验得出来。**Step 7 必须实测 ⌘F**。
> 若不生效，退路是改用 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`（记得在 `.onDisappear` 里移除），或用 `AppUpdaterApp.commands` 里的 `CommandGroup` + `NotificationCenter` 转发。

### Step 4: 副标题改口径

把 `subtitleText`（第 103-108 行）替换为：

```swift
    private var subtitleText: String {
        if !store.statusMessage.isEmpty { return store.statusMessage }
        if store.updates.isEmpty { return "尚未检查" }
        if isFiltering {
            return "筛选“\(trimmedQuery)” · 命中 \(filteredUpdates.count) / 共 \(store.updates.count)"
        }
        let prefix = store.isShowingCachedResult ? "上次检查：\(store.lastCheckedText)" : store.lastCheckedText
        return "\(prefix) · 扫描 \(store.updates.count) 个应用"
    }
```

> 顺手把 `store.updates.map(\.app.name).count` 换成 `store.updates.count`：前者先建一个名字数组只为取个数，是白耗。

### Step 5: 列表走筛选结果，加无结果空态

把 `content` 与 `emptyState`（第 167-212 行）替换为：

```swift
    @ViewBuilder
    private var content: some View {
        if store.updates.isEmpty {
            emptyState
        } else if isFiltering && filteredUpdates.isEmpty {
            noMatchState
        } else {
            List {
                ForEach(UpdateGroup.allCases) { group in
                    let items = filtered(in: group)
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { update in
                                AppRowView(update: update, store: store)
                            }
                        } header: {
                            HStack {
                                Text(group.title)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("\(items.count)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(store.isBusy ? "正在检查…" : "还没有结果")
                .font(.system(size: 13, weight: .medium))
            Text("点右上角「重新检查」开始扫描已安装的应用")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 筛选零命中。
    ///
    /// 必须与 `emptyState`（尚未检查）在文案上分得开：一个说「没搜到」，
    /// 一个说「还没查过」。混成一句的话，用户会以为应用真的没了。
    private var noMatchState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("没有匹配“\(trimmedQuery)”的应用")
                .font(.system(size: 13, weight: .medium))
            Text("已扫描 \(store.updates.count) 个应用，换个词试试")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("清除筛选") { query = "" }
                .controlSize(.small)
                .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
```

### Step 6: 确认编译

```bash
cd /Users/midasgao/code/github_project/midasism-Updraft
swift build --disable-sandbox
```

Expected: `Build complete!`（Task 2 里那个 `automatedUpdateCount` 断链这一步就补上了）

### Step 7: 肉眼验证（`--snapshot` 出图）

Task 4 会加 `--query`。若想先看，可临时把 `ContentView(store: store)` 改成 `ContentView(store: store, initialQuery: "ch")` 再跑：

```bash
NSUnbufferedIO=YES .build/debug/AppUpdater --snapshot /tmp/search-check.png --mode main
```

Expected: `/tmp/search-check.png`（1760×1320）——检查四件事：
1. 搜索框在 header 里、与「全部升级 / 重新检查」不挤
2. 副标题是 `筛选“ch” · 命中 N / 共 92`
3. 三张统计卡片数字**与不筛选时完全一致**（这是双口径设计里最容易做错的一条）
4. 列表只剩命中的行、空分组标题消失

### Step 8: 提交

```bash
git add Sources/AppUpdaterKit/UI/ContentView.swift
git commit -m "feat(search): 主窗口搜索框，实时过滤列表并收窄批量升级范围"
```

---

## Task 4: 截图通道支持 `--query`

**Files:**
- Modify: `Sources/AppUpdaterKit/CLI/SnapshotRunner.swift`
- Modify: `Sources/AppUpdater/main.swift`

### Step 1: 改 `SnapshotRunner.run` 签名

第 34-38 行：

```swift
    public static func run(
        outputPath: String,
        mode: Mode = .main,
        size: NSSize? = nil,
        /// 初始筛选词。只有截图通道用，生产路径走默认空值。
        query: String = ""
    ) -> Int32 {
```

### Step 2: 传给 ContentView

第 78-79 行：

```swift
        case .main:
            root = AnyView(ContentView(store: store, initialQuery: query))
```

第 84 行的兜底分支（`confirm` / `batch` 找不到条目时退回主窗口）保持 `ContentView(store: store)` 不动——那条路上没有筛选语义。

### Step 3: 接上 CLI 参数

`Sources/AppUpdater/main.swift` 第 77-82 行替换为：

```swift
// 界面截图：把真实的视图渲染成 PNG，用于验证排版。
if let index = arguments.firstIndex(of: "--snapshot") {
    let path = index + 1 < arguments.count ? arguments[index + 1] : "app-snapshot.png"
    let mode = value(after: "--mode").flatMap(SnapshotRunner.Mode.init(rawValue:)) ?? .main
    let query = value(after: "--query") ?? ""
    let code = MainActor.assumeIsolated {
        SnapshotRunner.run(outputPath: path, mode: mode, query: query)
    }
    exit(code)
}
```

### Step 4: 跑一遍验证

```bash
cd /Users/midasgao/code/github_project/midasism-Updraft
swift build --disable-sandbox
NSUnbufferedIO=YES .build/debug/AppUpdater --snapshot /tmp/search-state.png --mode main --query "ch"
NSUnbufferedIO=YES .build/debug/AppUpdater --snapshot /tmp/search-nomatch.png --mode main --query "zzz"
```

Expected:
- 两张图都生成，尺寸 1760×1320
- `search-state.png`：筛选态（列表被过滤、副标题显示命中数、卡片数字不变）
- `search-nomatch.png`：**新空态**——放大镜图标 + 「没有匹配"zzz"的应用」+「清除筛选」按钮，而不是「还没有结果」

### Step 5: 提交

```bash
git add Sources/AppUpdaterKit/CLI/SnapshotRunner.swift Sources/AppUpdater/main.swift
git commit -m "feat(search): --snapshot 支持 --query，筛选态可留痕可重跑"
```

---

## Task 5: README 同步

**Files:**
- Modify: `README.md`

### Step 1: 功能清单加一条

在 `## 功能` 一节的 `- 🔍 **一个窗口看全**` 之后插入：

```markdown
- 🔎 **找得到想找的那个** — header 里一个搜索框，`⌘F` 聚焦、`Esc` 清空，按名称与 Bundle ID 实时过滤三档分组；筛选时「全部升级」自动收窄成「升级这 N 个」，**所见即所升**。三张统计卡片始终是全量口径，不跟着筛选跳——它回答的是「这台机器整体什么样」。
```

### Step 2: 命令表加一行

在「完整命令表」的 `--snapshot` 行之后插入：

```markdown
| `--query "<词>"` | 配合 `--snapshot` 使用，把筛选态渲染进截图（仅对 `main` 模式生效） |
```

### Step 3: 提交

```bash
git add README.md
git commit -m "docs: README 补搜索功能与 --query"
```

---

## Task 6: 全量验证与收尾

### Step 1: 整包构建（Debug + Release）

```bash
cd /Users/midasgao/code/github_project/midasism-Updraft
swift build --disable-sandbox
swift build -c release --disable-sandbox
echo "退出码 $?"
```

Expected: 两次 `Build complete!`。

### Step 2: 组装 `.app` 并真机跑

```bash
scripts/build-app.sh
open dist/AppUpdater.app
```

**必须真人点一遍这几件事**（单元测试与截图都覆盖不到）：

| # | 要验的 | 期望 |
|---|---|---|
| 1 | `⌘F` | 光标进搜索框 |
| 2 | 输入 `ch` | 列表实时收窄，副标题出现 `筛选"ch" · 命中 N / 共 92` |
| 3 | 三张统计卡片 | 数字与不筛选时**完全一致** |
| 4 | 点搜索框右侧 ⊗ | 清空，列表复原 |
| 5 | 输入 `zzz` | 显示「没有匹配"zzz"的应用」+「清除筛选」按钮，**不是**「还没有结果」 |
| 6 | `Esc` | 清空搜索框 |
| 7 | 输入后点「升级这 N 个」 | 任务面板里的条目**只有筛出来的那些** |
| 8 | 窗口拖到最小宽度（760pt） | 搜索框与右侧按钮不重叠、不被裁切 |
| 9 | 菜单栏下拉 | 徽标数字仍是全量待更新数（不受筛选影响） |

第 3、7、9 条是这次设计的三处要害，**必须逐条确认**，不能"看起来没问题"就过。

### Step 3: 清掉临时产物

```bash
rm -f /tmp/appsearch-check /tmp/upgrade-selection-check \
      /tmp/AppSearchCheck.swift /tmp/UpgradeSelectionCheck.swift \
      /tmp/probe-menubar.png /tmp/probe-main.png
```

（`/tmp/search-*.png` 留着，Step 4 可能要贴进 README）

### Step 4: 可选——把筛选态截图存进 `docs/screenshots/`

若 Step 2 的界面观感满意：

```bash
NSUnbufferedIO=YES .build/debug/AppUpdater --snapshot docs/screenshots/ui-v0.5-search.png --mode main --query "ch"
```

然后在 README 的「截图」一节加一张 `<img src="docs/screenshots/ui-v0.5-search.png" width="880" alt="搜索：筛选“ch”的实时过滤与命中数">`。

### Step 5: 最终提交

```bash
git add -A
git commit -m "chore(search): 收尾——截图与验证记录"
```

---

## 完成后

Phase 5 会给四个选项：合并回 `main` / 推送开 PR / 保留分支 / 丢弃。届时再定。

**未完成项（如实记录）：**

- 本机缺完整 Xcode，`swift test` 没跑过。Task 1、Task 2 新增的 15 个 XCTest 用例**只有 CI 才是权威验证**。建议推分支后盯一眼 CI 的 `swift test` 结果再合。
- `⌘F` 的隐藏按钮方案若在 Step 2 第 1 条实测不生效，按 Task 3 Step 3 的风险提示换 `NSEvent.addLocalMonitorForEvents`。
