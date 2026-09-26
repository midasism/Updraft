#!/bin/bash
#
# 把 SwiftPM 的可执行文件组装成一个可以双击运行的 .app。
# 用法：scripts/build-app.sh
#
# 可用环境变量：
#   VERSION           版本号（写进 Info.plist 的 CFBundleShortVersionString）
#   BUILD_NUMBER      构建号（写进 CFBundleVersion）
#   CODESIGN_IDENTITY "Developer ID Application: <名字> (TEAMID)"。
#                     配了就正式签名（公证的前提），没配就退回 ad-hoc。
#   SELF_UPDATE_ED_PUBLIC_KEY
#                     自更新包的 Ed25519 公钥（base64）。配了就写进 Info.plist，
#                     应用才能校验自己下载到的安装包；不配则应用内更新仍然可用，
#                     只是没法做密码学校验（界面上会如实标注）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="AppUpdater"
DISPLAY_NAME="App 更新"
BUNDLE_ID="com.local.appupdater"
# 版本号可由外部注入（发布流水线按 tag 传入），本地直接跑则用默认值。
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "→ 编译 release 版本…"
# SwiftPM 的 manifest 编译会自己再套一层 sandbox，在受限环境里会失败，所以显式关掉。
swift build -c release --disable-sandbox

BIN="$(swift build -c release --disable-sandbox --show-bin-path)/$APP_NAME"
if [ ! -x "$BIN" ]; then
  echo "✘ 找不到编译产物：$BIN" >&2
  exit 1
fi

echo "→ 生成图标…"
if [ ! -f "$DIST/AppIcon.icns" ]; then
  swift "$ROOT/tools/IconGen.swift" "$DIST" >/dev/null
  iconutil -c icns "$DIST/AppIcon.iconset" -o "$DIST/AppIcon.icns"
fi

echo "→ 组装 $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# 自更新用的 Ed25519 公钥。键名沿用 Sparkle 的 SUPublicEDKey——算法与语义完全相同，
# 应用给自己升级时用的还是同一套规矩，没必要另发明一个。
if [ -n "${SELF_UPDATE_ED_PUBLIC_KEY:-}" ]; then
  ED_KEY_ENTRY="    <key>SUPublicEDKey</key>
    <string>$SELF_UPDATE_ED_PUBLIC_KEY</string>"
else
  ED_KEY_ENTRY="    <!-- 未配 SELF_UPDATE_ED_PUBLIC_KEY：应用内自更新跳密码学校验 -->"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
$ED_KEY_ENTRY
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

echo "→ 签名…"
# 两条路：
#   配了 CODESIGN_IDENTITY（CI 里由 secret 注入）→ Developer ID 正式签名。
#     --options runtime（hardened runtime）与 --timestamp（可信时间戳）都是公证的硬性要求，
#     少任何一项 notarytool 都会拒。这一步之后才由 scripts/notarize.sh 送公证。
#   没配 → ad-hoc 兜底。它的作用**不是过 Gatekeeper**（根本过不了），而是让 arm64 二进制
#     能被加载——Apple Silicon 上未签名的可执行文件跑不起来。
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp \
    --sign "$CODESIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
  echo "  ✔ 已用「$CODESIGN_IDENTITY」签名（hardened runtime + 时间戳）"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 \
    || echo "  （ad-hoc 签名失败——dist 里本地跑没问题，分发出去会被 Gatekeeper 拦）"
  echo "  未配 CODESIGN_IDENTITY，退回 ad-hoc：产物未公证，"
  echo "  用户首次打开会被 Gatekeeper 拦下，处置见 README「安装」一节。"
fi

echo ""
echo "✔ 已生成 $APP"
if [ -n "${SELF_UPDATE_ED_PUBLIC_KEY:-}" ]; then
  echo "  已写入 SUPublicEDKey：应用内自更新会校验安装包签名"
else
  echo "  未配 SELF_UPDATE_ED_PUBLIC_KEY：应用内自更新可用，但不做密码学校验"
  echo "  生成一对密钥：swift tools/ReleaseSign.swift keygen"
fi
echo "  试运行：open \"$APP\""
echo "  自检：  \"$APP/Contents/MacOS/$APP_NAME\" --check"
