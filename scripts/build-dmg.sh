#!/bin/bash
#
# 把 Updraft.app 打成一个带「拖拽安装」窗口的 DMG。
# 用法：scripts/build-dmg.sh
#       VERSION=0.3.0 scripts/build-dmg.sh
#
# 为什么用 dmgbuild 而不是 hdiutil + AppleScript：
# 窗口里图标的摆放位置存在卷根的 .DS_Store 里。用 AppleScript 摆图标，等于要驱动 Finder
# 去改这份 .DS_Store，而 Finder 自动化需要 GUI 会话和「自动化」权限，在 CI 上并不可靠。
# dmgbuild 自己直接写 .DS_Store，全程不碰 Finder，所以能在无 GUI 环境里跑。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
DMGBUILD_VERSION="1.6.7"
DIST="$ROOT/dist"
APP="$DIST/Updraft.app"
DMG="$DIST/Updraft-$VERSION-macOS.dmg"
VOLUME_NAME="Updraft"
VENV="$ROOT/.build/dmgbuild-venv"

# hdiutil 是 macOS 独有的，Linux 上做不了 DMG
if ! command -v hdiutil >/dev/null 2>&1; then
  echo "✘ 找不到 hdiutil：DMG 只能在 macOS 上生成" >&2
  exit 1
fi

# 默认自己出一遍 .app，保证 DMG 里的东西和当前源码一致。
# 流水线里 .app 已经单独出过了，用 SKIP_APP_BUILD=1 跳过，省一次重复编译。
if [ "${SKIP_APP_BUILD:-0}" != "1" ]; then
  echo "→ 编译并组装 .app…"
  VERSION="$VERSION" scripts/build-app.sh
fi

if [ ! -d "$APP" ]; then
  echo "✘ 找不到 $APP" >&2
  exit 1
fi

echo "→ 生成窗口背景图…"
# 1x 与 @2x 会一起生成，dmgbuild 靠这对文件合成 retina 背景
swift "$ROOT/tools/DmgBackground.swift" "$DIST" >/dev/null

echo "→ 准备 dmgbuild…"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==$DMGBUILD_VERSION"
fi

# 同名的卷还挂着的话，dmgbuild 后续 attach 会撞名
if [ -d "/Volumes/$VOLUME_NAME" ]; then
  echo "→ 先卸载残留的 /Volumes/$VOLUME_NAME…"
  hdiutil detach "/Volumes/$VOLUME_NAME" -quiet || true
fi

echo "→ 生成 DMG…"
rm -f "$DMG"
"$VENV/bin/dmgbuild" \
  --detach-retries 10 \
  -s "$ROOT/scripts/dmg-settings.py" \
  -D "app=$APP" \
  -D "background=$DIST/dmg-background.png" \
  "$VOLUME_NAME" \
  "$DMG"

echo ""
echo "✔ 已生成 $DMG"
echo "  试挂载：open \"$DMG\""
echo "  看结构：hdiutil attach \"$DMG\" -nobrowse && ls -la \"/Volumes/$VOLUME_NAME\""
