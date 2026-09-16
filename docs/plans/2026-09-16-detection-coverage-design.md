# 检测覆盖率：71 个「无法自动检测」的根因与优化路线设计文档

日期：2026-09-16
状态：待确认

## 一、要解决的问题

界面首屏给出的是这样一组数字：

```
3 分钟前检查 · 扫描 92 个应用
可更新 1        已是最新 20        无法自动检测 71
```

92 个应用里只有 21 个（22.8%）进了有效分组，其余 71 个（77.2%）全被丢进
「无法自动检测」这一格。这个比例下，这个工具对绝大多数用户来说是没用的——
它看起来在工作，但答案永远是「不知道」。

更糟的是**这个 71 里藏着一批本来查得出来、而且确实有更新的应用**。
本文先量化这件事，再按「投入产出比」排优化顺序。

## 二、真机证据（2026-09-16）

### 2.1 71 个的七类根因

按包内实际更新机制归类（脚本遍历 `Contents/` 判定，非人工目测）：

| # | 根因 | 个数 | 应用 |
|---|---|---|---|
| ① | App Store 安装（有 `_MASReceipt`），当前设计只标记不检测 | 18 | Bob、DingTalk、Doubao、Magnet、MailMaster、MediaCenter、NeteaseMusic、OpenIn、PDF Expert、Sabun、SenPlayer、SnippetsLab、TencentMeeting、TermBean、The Unarchiver、Thor Launcher、WeChat、pap.er |
| ② | Microsoft AutoUpdate 管理 | 4 | Microsoft Word / Excel / PowerPoint / Defender Shim |
| ③ | 套壳包 / 结构异常，扫描器读不出 `Info.plist` | 2 | TIM、RallyCut |
| ④ | 开源项目，有公开 GitHub Release，但本工具不认 | 6 | DBeaver Community、FlClash、Zed、Clash Verge、AltTab、Insomnia |
| ⑤ | Electron + `Squirrel.framework`，feed 地址在代码里硬编码 | 14 | Cursor、Claude、CodeBuddy、CatPaw、WorkBuddy、UGit、Grok Bot、Antigravity、AudioVisual、HiFox、TRAE SOLO CN、Open Design、PPDuck3、ZCode |
| ⑥ | 内嵌 Sparkle，但主 `Info.plist` 没有 `SUFeedURL` | 5 | ChatGPT、ChatGPT Classic、Reqable、ToDesk、ClashX Pro |
| ⑦ | 真·私有更新器（无公开接口） | 22 | Chrome、Steam、IntelliJ IDEA、JetBrains Toolbox、Snipaste、Tencent Lemon、UURemote、Nutstore、Otty、QSpace Pro、Grok、tabularis、wechatwebdevtools、Reasonix、Rebased、danbo、skill-zoo、MCPMacControl、macOS Assistant、Cockpit Tools、Claude Code URL Handler、jetbrains-crack-toolbox |

「① 只标记不检测」是**主动的设计选择**（`AppSource.isAutoDetectable` 对 `.appStore`
直接返回 `false`），但它是个错误的取舍——见 2.3。

### 2.2 brew 索引有个看得见的洞

界面顶栏那行小字：

```
⚠ fuse-t-sshfs、reasonix 无法读取，已跳过
```

实测两个 cask 各自的失败原因完全不同：

```
$ brew info --cask --json=v2 reasonix
Error: Cask 'reasonix' is unreadable: undefined local variable or method
       'staged_path' for an instance of Homebrew::InstallSteps::DSL

$ brew info --cask --json=v2 fuse-t-sshfs
Error: Refusing to load cask macos-fuse-t/cask/fuse-t-sshfs from untrusted
       tap macos-fuse-t/cask.
```

- `reasonix` 是**上游 cask 定义本身写坏了**（`staged_path` 未定义），不是本机问题。
- `fuse-t-sshfs` 是**未受信任的 tap**，`brew trust` 一下就能解。

批量 `brew info` 因此整体退化为逐 token 查询：

```
$ brew info --cask --json=v2 $(brew list --cask | tr '\n' ' ')
exit=1        stdout 0 字节        # 整批原子失败，一个坏 cask 毁掉全部
```

`BrewService.loadCaskInfo` 的逐 token 兜底**是生效的**（17/19 个 cask 正常读到），
所以这不是「功能瘫痪」，只是少了 2 个 cask 的映射。
**结论：brew 侧问题不大，144 个 unsupported 里不到 1 个是它造成的。**

### 2.3 真正扎眼的：漏掉的更新

「无法自动检测」这个分组名让人以为「这些东西就是查不了」。
实测下来，至少 **11 个应用查得出来，而且确实有更新**。

**App Store 组（18 个）全部可查，其中 9 个有更新**——
`https://itunes.apple.com/lookup?bundleId=<id>&country=cn`，免费、无鉴权、无频率问题：

| 应用 | 本地 | App Store | |
|---|---|---|---|
| Magnet | 2.14.0 | **3.0.7** | 跨大版本 |
| PDF Expert | 3.10.5 | **3.13.3** | |
| MediaCenter | 2.3.5 | **3.0.6** | 跨大版本 |
| WeChat | 4.1.11 | **4.1.13** | |
| TencentMeeting | 3.45.3 | **3.46.1** | |
| TermBean | 2.3.12 | **2.4.1** | |
| OpenIn | 4.4.2 | **4.4.4** | |
| SenPlayer | 6.1.8 | **6.2.1** | |
| pap.er | 5.5.5 | **5.5.6** | |

18/18 全部查得到，**没有一个是查不到的**。

包括 `DingTalk` 这种 bundle ID 带 team 前缀的（`5ZSL2CJU2T.com.dingtalk.mac`）——
**原样查就能命中**：

```
bundleId=5ZSL2CJU2T.com.dingtalk.mac  →  resultCount 1   （8.5.5）
bundleId=com.dingtalk.mac             →  resultCount 0
```

⚠️ 我第一版文档在这里写反了，写成「要剥掉第一个点前的段才命中」——那是从
「原样试失败才剥」的脚本里反推出来的，**没有单独验证过**。实测恰恰相反：
剥掉前缀的那个查不到。所以**不要做任何 bundle ID 归一**。

**④ 开源组（6 个）全部可查，其中 2 个有更新**：

| 应用 | 本地 | GitHub latest | |
|---|---|---|---|
| FlClash | 0.8.91 | **v0.8.98** | 有更新 |
| AltTab | 11.4.3 | **v11.6.1** | 有更新，跨 11.5 / 11.6 |
| DBeaver Community | 26.2.0 | 26.2.0 | 已最新 |
| Zed | 1.19.2 | v1.19.2 | 已最新 |
| Clash Verge | 2.5.2 | v2.5.2 | 已最新 |

### 2.4 「1 个可更新」是被低估的

| | 界面现在 | 修完①②③④后 |
|---|---|---|
| 可更新 | 1 | **12** |
| 已是最新 | 20 | **33** |
| 无法自动检测 | 71 | **47** |

也就是说：**这个工具现在漏掉了 11 个真实可用的更新**，占全部可用更新（12 个）的 92%。
Proxyman / Wireshark / Typora 之外，还有 Magnet 大版本、PDF Expert、微信、
腾讯会议、FlClash、AltTab 一整排等着。

## 三、根因分析

### 3.1 扫描器只认「标准 `.app`」，把非标准包静默降级

`AppScanner.inspect` 硬编码读 `Contents/Info.plist`（`AppScanner.swift:82-83`）。
两条路径会落空：

| 应用 | 真实结构 | 后果 |
|---|---|---|
| TIM | `TIM.app/WrappedBundle → Wrapper/QQ.app`，**扁平 iOS bundle**（没有 `Contents/`） | 名字退回目录名，`bundleID = nil`，`currentVersion = nil` |
| RallyCut | 同上 | 同上 |

于是这两个包连「我是谁」都答不出来，被归到「未识别到公开的更新接口」——
而它们其实是 App Store 套装（`Wrapper/iTunesMetadata.plist` 在），
本该进 ① 组用 MAS 接口查。

`AppScanner.inspect(bundleAt:)` 里那句 `guard appURL.pathExtension == "app"` 也拦不住这种情况，
因为它检查的是 `.app` 后缀，而套壳包的顶层确实叫 `.app`。

### 3.2 更新机制的白名单太窄

`AppClassifier.source(for:)` 的判定顺序是：brew cask → MAS receipt → `SUFeedURL` →
内嵌 Sparkle → `app-update.yml` → Microsoft → 关键词表。

六个分支之外，全落到最后一行 `未识别到公开的更新接口`（31 个走这条）。
缺的三个信号：

1. **`Squirrel.framework`**——Electron 的 macOS 自更新框架。
   Cursor / Claude / CodeBuddy / CatPaw / WorkBuddy / UGit / Insomnia 全都带着它，
   但分类器完全不看 `Frameworks/` 里有什么（只看 `Sparkle.framework` / `Autoupdate.app`）。
   **包里有没有 `Squirrel.framework` 是「这个应用能不能自更新」的强信号**，
   即使 feed 地址拿不到，也该如实说「应用内自更新」，而不是「未识别到公开的更新接口」。

2. **VS Code 系 `Resources/app/product.json`**——Cursor / CodeBuddy / CatPaw / TRAE 都带这个文件，
   里面有 `updateUrl` / `quality` / `commit`。**但这条路对本机走不通**，见 3.3。

3. **开源项目的 GitHub Release**——DBeaver / FlClash / Zed / AltTab 都是原生应用（非 Electron），
   没有 `app-update.yml`，于是掉进「未识别」。它们的 Release 全在公开 GitHub 上。

### 3.3 Cursor / CodeBuddy 这类，技术上真想查也查不了

Cursor 的更新地址在 `Contents/Resources/app/out/main.js` 里是这么拼的：

```js
createUpdateURL(e, t, n, r = !1) {
  const s = this._updateBaseUrlOverride ?? n.updateUrl,
        i = Es.localMode ? "cursor-local" : n.nameShort.replace(/ /g, "-").toLowerCase(),
        a = this.getReleaseTrack(),
        o = `${s}/api/update/${e}/${i}/${n.version}/${this.machineId}/${a}`;
  return o
}
```

路径里带 **`this.machineId`**。实测把 `machineId` 换成猜的值，任何平台段都是 404：

```
[404] https://api2.cursor.sh/updates/api/update/darwin-arm64/stable/2fdd31c9…
[404] https://api2.cursor.sh/updates/api/update/darwin-universal/stable/2fdd31c9…
[404] https://www.codebuddy.ai/api/update/darwin-arm64/stable/1ba59196…
```

要查就得带上本机设备标识——**为了一个版本号去冒用设备 ID 不值得，也不该做**。
所以 Cursor / CodeBuddy 这一类正确答案是「内置更新器，需设备标识」，不是「未识别」。

### 3.4 界面把「查不了」和「还没查」混成一格

`AppUpdate.group`（`UpdateResult.swift:76-82`）把 `.unsupported` 和 `.failed` 合并成同一组：

```swift
case .unsupported, .failed: return .unsupported
```

于是「ClashX Pro 的 appcast 返回 410（更新源已下线）」和「Steam 在客户端内更新」
显示在同一个「无法自动检测」标题下。用户无法区分：

- 这类**结构上就查不了**（Steam、Adobe、系统应用）→ 折叠起来别占地方
- 这类**本来能查，只是失败了**（网络/410/502）→ 需要显眼、需要重试

## 四、优化路线（按投入产出比排序）

### 第一梯队：低风险、高收益、纯增量

| 优先级 | 措施 | 新增可检测 | 改动面 |
|---|---|---|---|
| **P0** | 接 App Store Lookup API（`itunes.apple.com/lookup`），`.appStore` 从「只标记」改为「真检测」 | **18** | 新增一个 probe + `isAutoDetectable` 放开 `.appStore` |
| **P0** | 内置「知名开源应用 → GitHub repo」映射表，复用已有的 `ElectronProbe.probeGitHub` | **6** | 一张常量表 + 分类器加一个分支 |
| **P1** | 扫描器跟随 `WrappedBundle` 符号链接 / 兼容扁平 iOS bundle | **2** | `AppScanner.inspect` 加一层路径归一 |

P0 两项加起来 **+24 个可检测**，把可检测率从 22.8% 拉到 48.9%，
而且**不引入任何新的安全面**——两个都是公开、无鉴权的 GET 接口，
不需要往 `/Applications` 写任何东西，`InstallAction` 保持 `.openDownload`。

**实现要点：**

1. **不要对 bundle ID 做归一**。实测 `5ZSL2CJU2T.com.dingtalk.mac` 原样命中，
   剥掉前缀的 `com.dingtalk.mac` 反而 `resultCount 0`（见 2.3 的更正）。
   而且剥前缀有**误匹配风险**：`com.foo.Bar` 可能撞上另一个开发者的同名反向域名。
2. **版本只能比 `version` 字段**。`lookup` 的响应里**没有 `bundleVersion`**，
   只有 `version`（营销版本号，如 `4.1.13`）。所以比对时 `latest.buildVersion` 必须传 `nil`，
   别把本地 `CFBundleVersion`（`255`、`58012001` 这种整数）带进来——
   `VersionComparison` 的构建号分支一旦两边都能解析就会优先走它，
   拿本地构建号去比一个不存在的对方构建号没有意义。
3. **`country=cn` 查空时兜底不带 country 再查一次**。CN 商店没有的应用（或用户不在国内）
   第一次会 `resultCount 0`，而接口对「查不到」返回的是 **HTTP 200 + 空数组**，不是 404。
   最多两次请求。
4. **GitHub 映射表要区分「版本号可比」**：Zed 的 `CFBundleShortVersionString` 是 `1.19.2`，
   tag 是 `v1.19.2`——剥 `v` 后可比（实测已最新，正确）。
   但 FlClash 的 `CFBundleVersion` 是 `2025122201`，只有 `CFBundleShortVersionString`（`0.8.91`）可比。
   映射表里每条得标清楚比哪个字段，不能一律拿 `CFBundleVersion` 去比。
   还要处理**改名**：repo 改名后 GitHub API 会 301，得跟跳转。
5. **映射表会腐坏**：写死在二进制里，repo 改名/归档就失效。
   建议映射表**只在 CI 里校验**（拉一遍所有 repo 的 `releases/latest` 断言 200），
   而不是运行时静默失败——运行时失败等于这条又变回「未识别」。

### 第二梯队：正确性修正，不增加检测数

| 优先级 | 措施 | 效果 |
|---|---|---|
| **P1** | 分类器认 `Squirrel.framework` → 新增 `.squirrel` 来源，标注「应用内自更新（Squirrel）」 | 14 个应用从「未识别」变「有名字的品类」；文案不再误导 |
| **P1** | VS Code 系单独一类，标注「内置更新器（需设备标识）」 | Cursor、CodeBuddy 等不再被当成「未识别」 |
| **P1** | `UpdateGroup` 拆出 `.checkFailed` 组，`.failed` 独立展示 | 4 个失败项可被看见、可重试 |
| **P2** | brew 索引只跳过坏 cask，不改批量路径；但部分失败时顶栏提示要能展开看是哪些 | 已有 `.partial` 状态，UI 只显示前 3 个 |

### 第三梯队：明确不做

| 措施 | 为什么不做 |
|---|---|
| 冒用 `machineId` 查 Cursor / CodeBuddy | 拿别人的设备标识去问接口，越界了；且违反渠道条款 |
| 抓包分析 Squirrel 的 feed 地址 | 每个应用都要单独逆向，回归成本高于收益 |
| 从二进制 strings 里抠硬编码 appcast URL | **实测不可行**：AltTab / ChatGPT / ChatGPT Classic / Reqable 的主二进制里都搜不到 appcast 地址（Sparkle 的 URL 是运行时构造的）。⑥ 组这 5 个只能留在「明确不支持」 |
| 为 Microsoft AutoUpdate 单独接 `macadmins.software` feed | 4 个 Office 组件，用户本来就走 MAU 自动更新，收益低 |

### 不建议动的地方

- **`AppClassifier` 的判定顺序别改**：`mac-mouse-fix` 同时是 brew cask 和 Sparkle，
  brew 优先是刻意的（唯一能一键升完）。
- **P0 不要放开 `InstallAction`**：MAS 应用只能跳 App Store，
  GitHub 应用下载的是 dmg/zip，签名主体和 App Store 版本不同，
  别顺手让它走 `replaceBundle`。
- **不要把 `.unsupported` 整个从「无法自动检测」里摘掉**——
  47 个真的查不了的东西需要一个诚实的去处，这一格不能取消。

## 五、范围

**包含：**

1. `MASProbe`（新）——App Store Lookup 查询 + bundle ID 归一
2. `OpenSourceCatalog`（新）——应用名 → GitHub repo + 版本字段的映射常量
3. `AppClassifier` 新增 `.appStore` 的可检测路径、`.squirrel`、VS Code 系
4. `AppScanner` 支持 `WrappedBundle` / 扁平 iOS bundle
5. `UpdateGroup` 拆出 `.checkFailed`
6. `--snapshot` 新增 `unsupported` / `failed` 两个 mode
7. README 功能清单同步

**不包含：**

1. Cursor / CodeBuddy / Claude 等 Squirrel 应用的真实版本检测（见第三梯队）
2. ⑥ 组 5 个 Sparkle 硬编码 feed 的破解
3. Microsoft AutoUpdate 的版本查询
4. 任何涉及设备标识、私有接口、抓包的手段

## 六、验收标准

| # | 标准 | 怎么验 |
|---|---|---|
| 1 | 本机「可更新」≥ 11 | 全量跑一遍 `--check`，比对第 2.3 节的 11 条 |
| 2 | 「无法自动检测」≤ 47 | 同上 |
| 3 | MAS 查询原样使用 bundle ID，不做任何剥离 | 单测：`5ZSL2CJU2T.com.dingtalk.mac` 拼出的 URL 里 ID 原样保留 |
| 4 | GitHub 映射表里每个 repo 都返回 200 | CI 加一个校验 job；本机脚本先跑一遍 |
| 5 | 套壳包不再解析成 `bundleID = nil` | 单测：假造 `WrappedBundle` 符号链接的临时目录 |
| 6 | 版本比较不因 `v` 前缀/字段选错而误报 | 单测覆盖 `v1.19.2` vs `1.19.2`、`0.8.91` vs `0.8.98` |
| 7 | 失败项与不支持项在界面上分开 | `--snapshot failed` 出一张图，肉眼确认 |
