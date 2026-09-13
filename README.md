# AppUpdater

macOS 上没有统一的 App 更新入口。这个工具把散落在各处的更新状态收进一个窗口：一眼看到哪些应用该更新了，点一下就升完。

![主界面](docs/screenshots/ui-v0.2-main.png)

![升级确认](docs/screenshots/ui-v0.2-confirm.png)

本机实测：扫描 122 项，9.3 秒内查出 **22 个应用有待更新**，其中 **21 个可以一键自动升级**。

## 它怎么工作

不同来源的应用走不同的更新通道：

| 来源 | 检测方式 | 更新动作 |
|---|---|---|
| Homebrew cask | `brew outdated --cask --greedy --json=v2` | 跑 `brew upgrade --cask`，带实时日志 |
| Sparkle | 读 `Info.plist` 的 `SUFeedURL`，拉 appcast.xml 比对版本 | **下载 → 校验签名 → 备份 → 原子替换** |
| Electron | 读包内 `app-update.yml`，走 GitHub Releases API 或 `latest-mac.yml` | 同上（dmg / zip） |
| App Store | 只识别（`_MASReceipt`） | 暂不支持 |
| Microsoft AutoUpdate | 只识别 | 暂不支持 |
| Adobe / 游戏 / JetBrains 等 | 只识别，并给出具体原因 | 暂不支持 |

版本比对优先用构建号整数（Sparkle 里这是权威值），回退到点分版本号。两者都拿不到就判定为"检查失败"，**绝不猜测**。

### 一键升级的执行流程

```
检查上次中断的残留
    ↓
下载安装包（带进度）
    ↓
EdDSA 签名校验 ──── 不通过就地中止，磁盘上什么都没变
    ↓
解包 dmg / zip
    ↓
确认包身份（Bundle ID、版本、代码签名、签名主体是否换了人）
    ↓
备份旧版本
    ↓
优雅退出正在运行的应用（退不掉就中止，不强杀）
    ↓
同一卷内 rename 原子换包
    ↓
验证新版本 + 重新打开应用
    ↓
任何一步失败 → 自动回滚到旧版本
```

**三道独立的身份校验**，任一条不过就中止：

1. **Ed25519 签名** — 用应用自己 `Info.plist` 里公布的 `SUPublicEDKey`，对下载到的整个文件做密码学验签。本机 27 个应用公布了公钥，实测 AlDente 的 12.2 MB dmg 验签通过。
2. **代码签名** — `codesign --verify --deep --strict`；严格模式不过会退到普通校验并记一条警告。
3. **签名主体一致性** — Bundle ID 必须一致；Team ID 或证书主体变了要拦下来。若该应用没有公布公钥，主体变化就是硬性拒绝；有公钥且验签通过则降级为警告。

换包用「同卷 rename」而不是「删除 + 拷贝」：rename 是原子的，不存在"App 被删到一半掉电导致它消失"的窗口；旧包在换包瞬间被改名而非删除，所以回滚只是一次 rename。

### 关于 `.delta` 文件

Sparkle 的 appcast 里，`<sparkle:deltas>` 下挂的也是 `<enclosure>`，但它们指向的是**增量补丁**（魔数 `spk!`，XZ 压缩的二进制差分），必须由 Sparkle 拿着旧包应用，单独下载下来**永远装不上**。

解析器对此有明确规则：记录 `deltas` 的嵌套深度并忽略其中的 `enclosure`，同时让正式包的字段**先到先得**（否则补丁会覆盖正式包）。这条边界有 7 个回归测试守着。

## 怎么用

```bash
# 编译并打包成 .app
scripts/build-app.sh

# 运行
open dist/AppUpdater.app
```

命令行入口（都在 `dist/AppUpdater.app/Contents/MacOS/AppUpdater` 上）：

```bash
AppUpdater --check                  # 打印完整检测结果
AppUpdater --plan-all               # 列出所有可自动升级的条目及预检详情（不下载）
AppUpdater --plan "AlDente"         # 单个应用的预检
AppUpdater --install "AlDente"      # 真实执行升级
AppUpdater --install-all            # 升级全部可自动完成的条目
AppUpdater --recover                # 清理上一次被中断的安装残留
AppUpdater --snapshot /tmp/ui.png [--mode main|confirm|batch]
```

首次打开若提示"无法验证开发者"，右键 →「打开」，或：

```bash
xattr -d com.apple.quarantine dist/AppUpdater.app
```

## 开发

```bash
swift build          # 编译
swift test           # 89 个单元测试
```

> 若在受限环境里编译报 `sandbox-exec: sandbox_apply: Operation not permitted`，
> 说明 SwiftPM 编译 manifest 时套的内层沙箱被挡了，加 `--disable-sandbox` 即可。

## 结构

```
Sources/AppUpdaterKit/
  Models/      AppInfo / AppSource / UpdateResult / ReleaseInfo / UpgradeJob —— 纯数据
  Core/        扫描、分类、版本比对、进程执行、缓存、检查编排
               SignatureVerifier / PackageDownloader / BackupStore / Installer
  Probes/      Sparkle 与 Electron 两套探针 + appcast 解析
  UI/          SwiftUI 界面 + 状态源
  CLI/         --check / --snapshot / --install / --plan / --recover
Sources/AppUpdater/main.swift   可执行入口
```

分层的关键约束：**检测逻辑不认识 UI，UI 不认识网络**。新增一种更新来源 = 加一个探针 + 在分类器里加一条判定，别的文件都不用动。

## 备份与恢复

旧版本备份到 `~/Library/Application Support/AppUpdater/Backups/<Bundle ID>/<时间戳>-<版本>/`，每个应用只保留最近 1 份（IINA 一个包就 104 MB，无限留存会变成磁盘黑洞）。

安装流程中间被强杀（强制退出、断电）会留下隐藏的中间态文件，下次启动时会自动收拾。最坏的情况是崩溃恰好落在"旧包已挪走、新包未就位"之间——此时应用会从 `/Applications` 消失，恢复逻辑会把旧包搬回去。**没有可用的旧包时什么都不删**，只如实上报等人判断。

## 已知限制

- 46 个应用没有公开的更新接口（Adobe 全家桶、Steam / Battle.net / Epic、JetBrains Toolbox、VMware Fusion、Logi Options+ 等），只能标记。
- 5 个应用（AltTab、ChatGPT、CheatSheet、Codex、PopClip）内嵌了 Sparkle 但更新源硬编码在程序里，读不出来。
- ToDesk 用的是 `.pkg` 安装器，需要管理员密码，只能交给系统安装器。
- 未公布 `SUPublicEDKey` 的应用无法做密码学验签，界面上会明确标注"未校验"。
- LM Studio 用 s3 provider，配置里只有 bucket，拼不出可访问地址，不猜。
- 少数应用的 appcast 已经失效（ClashX 返回 404、Vox 返回 410），会显示为「检查失败」而不是假装是最新。

## 路线

- **v0.3** — 每日定时后台检查 + 系统通知；菜单栏图标。
- **v0.4** — 接入 App Store 应用；针对 Chrome 私有更新接口、JetBrains Toolbox 等做专门适配。
- 长期 — 支持 Sparkle 增量补丁（`spk!` 格式），大应用升级可以少下载很多。
