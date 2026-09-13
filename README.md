# AppUpdater

macOS 上没有统一的 App 更新入口。这个工具把散落在各处的更新状态收进一个窗口：一眼看到哪些应用该更新了，能一键升的直接升完。

![界面](docs/screenshots/ui-v0.1.png)

本机实测：扫描 122 项，10.6 秒内查出 **27 个应用有待更新**。

## 它怎么工作

不同来源的应用走不同的更新通道：

| 来源 | 检测方式 | 更新动作 |
|---|---|---|
| Homebrew cask | `brew outdated --cask --greedy --json=v2` | **一键全自动升级**，带实时日志 |
| Sparkle | 读 `Info.plist` 的 `SUFeedURL`，拉 appcast.xml 比对版本 | 打开安装包直链 |
| Electron | 读包内 `app-update.yml`，走 GitHub Releases API 或 `latest-mac.yml` | 打开安装包直链 |
| App Store | 只识别（`_MASReceipt`） | 暂不支持 |
| Microsoft AutoUpdate | 只识别 | 暂不支持 |
| Adobe / 游戏 / JetBrains 等 | 只识别，并给出具体原因 | 暂不支持 |

版本比对优先用构建号整数（Sparkle 里这是权威值），回退到点分版本号。两者都拿不到就判定为"检查失败"，**绝不猜测**。

## 怎么用

```bash
# 编译并打包成 .app
scripts/build-app.sh

# 运行
open dist/AppUpdater.app

# 无界面自检，打印完整检测结果（用于核对）
dist/AppUpdater.app/Contents/MacOS/AppUpdater --check

# 把界面渲染成 PNG（不需要屏幕录制权限）
dist/AppUpdater.app/Contents/MacOS/AppUpdater --snapshot /tmp/ui.png
```

首次打开若提示"无法验证开发者"，右键 →「打开」，或：

```bash
xattr -d com.apple.quarantine dist/AppUpdater.app
```

## 开发

```bash
swift build          # 编译
swift test           # 38 个单元测试
```

> 若在受限环境里编译报 `sandbox-exec: sandbox_apply: Operation not permitted`，
> 说明 SwiftPM 编译 manifest 时套的内层沙箱被挡了，加 `--disable-sandbox` 即可。

## 结构

```
Sources/AppUpdaterKit/
  Models/      AppInfo / AppSource / UpdateResult —— 纯数据
  Core/        扫描、分类、版本比对、进程执行、缓存、检查编排
  Probes/      Sparkle 与 Electron 两套探针 + appcast 解析
  UI/          SwiftUI 界面 + 状态源
  CLI/         --check 与 --snapshot 两个辅助入口
Sources/AppUpdater/main.swift   可执行入口
```

分层的关键约束：**检测逻辑不认识 UI，UI 不认识网络**。新增一种更新来源 = 加一个探针 + 在分类器里加一条判定，别的文件都不用动。

## 安全边界（v0.1）

整个过程**不写入 `/Applications`，不修改任何被检查的应用**。最坏情况是某个版本号显示有误。自动下载并替换 App 包留到 v0.2。

## 已知限制

- 44 个应用没有公开的更新接口（Adobe 全家桶、Steam / Battle.net / Epic、JetBrains Toolbox、VMware Fusion、Logi Options+ 等），只能标记。
- 5 个应用（AltTab、ChatGPT、CheatSheet、Codex、PopClip）内嵌了 Sparkle 但更新源硬编码在程序里，读不出来。
- LM Studio 用 s3 provider，配置里只有 bucket，拼不出可访问地址，不猜。
- 少数应用的 appcast 已经失效（ClashX 返回 404、Vox 返回 410），会显示为「检查失败」而不是假装是最新。

## 路线

- **v0.2** — Sparkle 应用自动安装：下载 → 校验 EdDSA 签名 → 检查 App 是否在运行 → 备份旧版 → 替换 → 去隔离属性 → 重开。加上每日定时检查与系统通知。
- **v0.3** — 接入 App Store 应用；针对 Chrome 私有更新接口、JetBrains Toolbox 等做专门适配。
