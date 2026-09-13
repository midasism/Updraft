#!/bin/bash
#
# 把 SwiftPM 的可执行文件组装成一个可以双击运行的 .app。
# 用法：scripts/build-app.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="AppUpdater"
DISPLAY_NAME="App 更新"
BUNDLE_ID="com.local.appupdater"
VERSION="0.1.0"
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
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
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

echo "→ 临时签名…"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  （签名跳过，首次打开需右键→打开）"

echo ""
echo "✔ 已生成 $APP"
echo "  试运行：open \"$APP\""
echo "  自检：  \"$APP/Contents/MacOS/$APP_NAME\" --check"
