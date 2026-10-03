# 打包、代码签名与公证指南

Updraft 提供了完整的应用打包、DMG 生成、代码签名与 Apple 公证流水线。

## 1. 脚本概览

| 脚本 | 产出 | 职责 |
|---|---|---|
| `scripts/build-app.sh` | `dist/Updraft.app` | 编译 Release 二进制、组装 `.app` bundle、执行签名 |
| `scripts/notarize.sh` | 已 staple 票据的 `.app` | 提交至 Apple 公证服务并附加票据（未配置凭据时跳过） |
| `scripts/build-dmg.sh` | `dist/Updraft-<版本>-macOS.dmg` | 调用前者生成 `.app`，打包为带有背景图与拖拽窗口的 DMG |

支持的环境变量：
- `VERSION`：注入版本号（如 `VERSION=0.3.0`，写入 `Info.plist`）。
- `BUILD_NUMBER`：构建编号（可选）。
- `SKIP_APP_BUILD=1`：跳过应用编译步骤，直接基于现有 `dist/Updraft.app` 构建 DMG。

---

## 2. 自动化发布（GitHub Actions）

当向仓库推送 `v*` 标签（如 `git tag v0.3.0 && git push origin v0.3.0`）时，[`.github/workflows/release.yml`](../.github/workflows/release.yml) 会自动触发：
1. 编译 release 产物并打包为 zip 与 DMG。
2. 生成各文件的 SHA-256 校验和（`SHA256SUMS.txt`）。
3. 使用仓库配置的 Ed25519 私钥生成自更新签名清单（`update.json`）。
4. 创建 GitHub Release 并上传资产。

手动触发该 workflow 则只生成 Actions Artifacts，不发布 Release，供单独验证流水线。

---

## 3. 自更新包签名（Ed25519）

自更新机制依赖 Ed25519 签名作为可信凭据。私钥仅存在于 GitHub Secrets，公钥写入应用的 `SelfUpdateIdentity.publicEDKey`。

### Secrets 配置

| Secret | 内容 | 说明 |
|---|---|---|
| `UPDRAFT_ED25519_PRIVATE_KEY` | 私钥（Base64 编码，32 字节 raw） | 用于 GitHub Actions 签署自更新清单 `update.json`；未配置时跳过签名 |

---

## 4. Apple Developer ID 代码签名与公证

### 凭据配置

默认情况下，构建脚本采用 ad-hoc 临时签名。若需消除 macOS Gatekeeper 警告并实现双击即开，需配置 Apple Developer Program 开发者凭据：

| Secret | 内容 | 获取方式 |
|---|---|---|
| `APPLE_CERT_P12` | Developer ID Application 证书的 Base64 编码 | 从钥匙串导出 `.p12`，运行 `base64 -i cert.p12 \| pbcopy` |
| `APPLE_CERT_PASSWORD` | 导出 `.p12` 时设置的密码 | 导出时自定义 |
| `APPLE_CODESIGN_IDENTITY` | 证书身份名称，如 `Developer ID Application: Name (TEAMID)` | `security find-identity -v -p codesigning` |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API Key 的 Key ID | App Store Connect → 用户和访问 → 集成 → 密钥 |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API Key 的 Issuer ID | 同上页面顶部 |
| `APPLE_NOTARY_KEY_P8` | `.p8` 私钥文件的文本内容 | 创建密钥时下载的内容 |

### 本地完整签名与公证流程

```bash
CODESIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" VERSION=0.3.0 scripts/build-app.sh
NOTARY_KEY_PATH=~/AuthKey.p8 NOTARY_KEY_ID=xxx NOTARY_ISSUER_ID=yyy scripts/notarize.sh
VERSION=0.3.0 SKIP_APP_BUILD=1 scripts/build-dmg.sh
```

> [!NOTE]
> 顺序不可颠倒：代码签名必须包含 hardened runtime 与时间戳，公证并 staple 票据后方可打包进 DMG / zip，打包后不可再修改 bundle 内容。

---

## 5. DMG 窗口与背景图

- DMG 窗口布局在 `scripts/dmg-settings.py` 中定义。
- 背景图由 `tools/DmgBackground.swift` 渲染生成。
- 打包采用 [dmgbuild](https://github.com/dmgbuild/dmgbuild) 直接写入卷根目录的 `.DS_Store`，不依赖 Finder GUI 会话与 AppleScript 自动化权限，适合在 CI 环境中稳定运行。
