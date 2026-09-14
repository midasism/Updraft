#!/bin/sh
#
# 一行命令把 Updraft 装进 /Applications，顺带绕开 Gatekeeper。
#
#   curl -fsSL https://raw.githubusercontent.com/midasism/Updraft/main/scripts/install.sh | sh
#
# 为什么这条路能做到「双击即开」：
#   Gatekeeper 只在文件带 com.apple.quarantine 属性时才会介入，而这个属性是浏览器、
#   邮件、AirDrop 这类经手方通过 LaunchServices 打上的标记。**curl 不经过 LaunchServices，
#   它下载的东西不带这个属性**，于是未公证的 ad-hoc 包也能直接启动。
#   这就是本项目不买 Developer ID 时的免费替代路径——详见 README「安装」一节。
#
# 可选环境变量：
#   VERSION       指定版本号（默认取 latest release）
#   INSTALL_DIR   安装目录（默认 /Applications）
#
set -eu

REPO="midasism/Updraft"
APP_NAME="AppUpdater"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
VERSION="${VERSION:-}"

TARGET="$INSTALL_DIR/$APP_NAME.app"
STAGE="$INSTALL_DIR/.$APP_NAME.app.new"
OLD="$INSTALL_DIR/.$APP_NAME.app.old"

die() { echo "✘ $*" >&2; exit 1; }

# ---- 前置检查 ----
[ "$(uname -s)" = "Darwin" ] || die "只能在 macOS 上安装"
command -v curl    >/dev/null 2>&1 || die "找不到 curl"
command -v hdiutil >/dev/null 2>&1 || die "找不到 hdiutil"

# hw.optional.arm64 比 uname -m 靠谱：Rosetta 下 uname -m 会骗人
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]; then
  echo "⚠︎  发布包是 arm64-only（CI 跑在 Apple Silicon runner 上）。"
  printf "   请改用源码构建，见 https://github.com/%s#从源码构建\n" "$REPO"
fi

[ -w "$INSTALL_DIR" ] || die "$INSTALL_DIR 不可写——用 sudo 重跑，或设 INSTALL_DIR 换个位置"

# ---- 解析版本 ----
if [ -z "$VERSION" ]; then
  echo "→ 查询最新版本…"
  LATEST_JSON="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")" \
    || die "查不到最新 release（网络问题，或者仓库还没有发布过）"
  # 故意拆成三个最基础的 sed 表达式，不用区间量词 \{m,n\}——
  # 那个在 toybox / busybox 的 sed 上不可靠（会静默把整串替换成空），
  # 而 macOS 上 sed 完全可能被 PATH 里别的东西顶掉。
  VERSION="$(printf '%s' "$LATEST_JSON" \
    | grep -o '"tag_name": *"[^"]*"' | head -1 \
    | sed -e 's/.*"tag_name": *"//' -e 's/"$//' -e 's/^v//')"
  [ -n "$VERSION" ] || die "没能从 GitHub 响应里解析出版本号，可以手动指定：VERSION=x.y.z …"
fi

DMG_NAME="Updraft-${VERSION}-macOS.dmg"
BASE_URL="https://github.com/$REPO/releases/download/v${VERSION}"

WORK="$(mktemp -d)"
MOUNT="$WORK/mnt"
cleanup() {
  hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- 下载 ----
echo "→ 下载 $DMG_NAME …"
curl -fsSL -o "$WORK/$DMG_NAME" "$BASE_URL/$DMG_NAME" \
  || die "下载失败：$BASE_URL/$DMG_NAME"

# ---- 校验和 ----
if curl -fsSL -o "$WORK/SHA256SUMS.txt" "$BASE_URL/SHA256SUMS.txt" >/dev/null 2>&1; then
  echo "→ 校验 SHA-256 …"
  # 校验和文件里是裸文件名，所以要在同一个目录下按名字挑出这一行
  if ( cd "$WORK" && grep -F "$DMG_NAME" SHA256SUMS.txt | shasum -a 256 -c - >/dev/null 2>&1 ); then
    echo "  ✔ 校验通过"
  else
    die "校验和不匹配——下载可能被篡改或损坏，已中止安装"
  fi
else
  echo "  ⚠︎  没下到 SHA256SUMS.txt，跳过校验"
fi

# ---- 挂载 ----
echo "→ 挂载镜像…"
mkdir -p "$MOUNT"
hdiutil attach "$WORK/$DMG_NAME" -nobrowse -quiet -mountpoint "$MOUNT" \
  || die "挂载失败（若提示卷名冲突，先 hdiutil detach /Volumes/Updraft）"

SRC="$MOUNT/$APP_NAME.app"
[ -d "$SRC" ] || die "镜像里没找到 $APP_NAME.app"

# ---- 让正在跑的旧版本先退出 ----
# 直接覆盖一个正在运行的 app，系统会把它当成「正在使用」而让替换出问题，所以这步不能省。
# 两级降级：先请求优雅退出，不行再发 SIGTERM。
wait_gone() {
  i=0
  while [ "$i" -lt "$1" ]; do
    pgrep -f "$TARGET/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

if pgrep -f "$TARGET/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
  echo "→ 退出正在运行的旧版本…"

  # 优雅退出走 AppleEvent，需要「自动化」权限——首次会弹一次系统授权框，同意即可。
  osascript -e "tell application id \"com.local.appupdater\" to quit" >/dev/null 2>&1 || true

  if ! wait_gone 10; then
    # 优雅退出没生效（多半是自动化权限没给，或者弹框没人点）。
    # 发 SIGTERM：AppKit 默认不接管它，进程会直接结束。Updraft 自己带中断自愈，
    # 下次启动会收拾残留的中间态文件，所以这里不会留下不可恢复的烂摊子。
    echo "  优雅退出没生效，改用 SIGTERM…"
    pkill -TERM -f "$TARGET/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
    wait_gone 10 || die "旧版本没退干净，请手动退出「App 更新」后重跑"
  fi
fi

# ---- 安装：同卷 rename 原子替换 ----
echo "→ 安装到 $TARGET …"
rm -rf "$STAGE" "$OLD"
ditto "$SRC" "$STAGE" || die "拷贝失败（$INSTALL_DIR 可能不可写，试试 sudo 重跑）"

if [ -d "$TARGET" ]; then
  mv "$TARGET" "$OLD" || die "无法移动旧版本（可能是别的账号装的，试试 sudo 重跑）"
fi

if ! mv "$STAGE" "$TARGET"; then
  if [ -d "$OLD" ]; then mv "$OLD" "$TARGET"; fi
  die "替换失败，旧版本已放回原处"
fi
rm -rf "$OLD"

# ---- 兜底：清掉可能残留的隔离属性 ----
# 正常路径下压根不会有它（curl 不打这个标记）。留着这步是因为：用户可能是先手动把
# dmg 下到本地、又用这个脚本装的；或者系统将来改了策略——那时这里能自愈。
if xattr "$TARGET" 2>/dev/null | grep -q quarantine; then
  echo "→ 发现残留的隔离属性，清除…"
  xattr -dr com.apple.quarantine "$TARGET" || true
fi

# ---- 验证 ----
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$TARGET/Contents/Info.plist" 2>/dev/null || echo '?')"

if codesign --verify --deep --strict "$TARGET" >/dev/null 2>&1; then
  echo "  ✔ 签名自洽"
else
  echo "  ⚠︎  签名校验没通过（一般不影响使用，但说明包可能不完整）"
fi

echo ""
echo "✔ Updraft $INSTALLED_VERSION 已装到 $TARGET"
open "$TARGET"
