#!/bin/bash
#
# 把 dist/AppUpdater.app 送 Apple 公证，并把票据 staple 到 app 上。
# 用法：scripts/notarize.sh
#
# **没配凭据时不是失败，是跳过**（exit 0）。这样流水线在还没买开发者账号的情况下
# 照样能出包，只是产物退回未公证的 ad-hoc 签名——行为与之前完全一致。
# 买好账号、把凭据塞进 repo secrets 之后，同一个流水线自动变成签名 + 公证。
#
# 为什么公证的是 .app 而不是 .dmg：
#   notarytool 只吃 .dmg / .pkg / .zip；而 stapler 又无法给 .zip 钉票据，
#   只公证 dmg 覆盖不到 zip 渠道。先把票据钉在 .app 上，再用这个 app 出 dmg 和 zip，
#   两条渠道里的 app 就都带票据了——一次公证，两个包都通。
#
# 顺序要求：build-app.sh 之后、build-dmg.sh 之前。
#   公证后 app 不能再被修改，所以出包动作必须排在 staple 之后。
#
# 环境变量（全部可选；缺凭据即降级）：
#   NOTARY_KEY_ID      App Store Connect API Key 的 Key ID
#   NOTARY_ISSUER_ID   同上，Issuer ID
#   NOTARY_KEY_P8      .p8 私钥的文件内容（CI 里来自 secret）
#   NOTARY_KEY_PATH    .p8 的文件路径（本地调试用，与 KEY_P8 二选一）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/AppUpdater.app"

KEY_ID="${NOTARY_KEY_ID:-}"
ISSUER_ID="${NOTARY_ISSUER_ID:-}"
KEY_P8="${NOTARY_KEY_P8:-}"
KEY_PATH="${NOTARY_KEY_PATH:-}"

if [ ! -d "$APP" ]; then
  echo "✘ 找不到 $APP —— 先跑 scripts/build-app.sh" >&2
  exit 1
fi

# ---- 凭据缺失：明确跳过，不报错 ----
if [ -z "$KEY_PATH" ] && [ -z "$KEY_P8" ]; then
  echo "→ 没有公证凭据（NOTARY_KEY_P8 / NOTARY_KEY_PATH 均为空），跳过公证"
  echo "  产物保持 ad-hoc 未公证：用户首次打开需先清 quarantine，见 README「安装」"
  exit 0
fi

# 只配了一半要报错——静默降级会让"以为公证了其实没有"这种事发生
if [ -z "$KEY_ID" ] || [ -z "$ISSUER_ID" ]; then
  echo "✘ 有密钥但缺 NOTARY_KEY_ID / NOTARY_ISSUER_ID，凭据不完整" >&2
  exit 1
fi

# ---- 公证前先自检签名，把几分钟排队之后才会暴露的失败提前到一秒内拦下 ----
SIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"

if ! printf '%s' "$SIGN_INFO" | grep -q 'Authority=Developer ID Application'; then
  echo "✘ $APP 不是 Developer ID 签名的，公证必被拒。" >&2
  echo "  检查 CODESIGN_IDENTITY 是否指向 'Developer ID Application: <名字> (TEAMID)'。" >&2
  echo "  当前签名：" >&2
  printf '%s\n' "$SIGN_INFO" | head -6 >&2
  exit 1
fi

# hardened runtime 是公证的硬性要求，缺了直接拒
if ! printf '%s' "$SIGN_INFO" | grep -q 'flags=0x[0-9a-f]*(runtime)'; then
  echo "✘ 签名没带 hardened runtime（codesign 的 --options runtime），公证会被拒。" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# .p8 内容从 secret 来，落到临时文件后立刻收权限，脚本退出时随 WORK 一起删掉
if [ -z "$KEY_PATH" ]; then
  KEY_PATH="$WORK/AuthKey.p8"
  printf '%s' "$KEY_P8" > "$KEY_PATH"
  chmod 600 "$KEY_PATH"
elif [ ! -f "$KEY_PATH" ]; then
  echo "✘ NOTARY_KEY_PATH 指向的文件不存在：$KEY_PATH" >&2
  exit 1
fi

# notarytool 不接受裸 .app，得先打成 zip。必须用 ditto——zip -r 会丢符号链接与权限位。
SUBMIT_ZIP="$WORK/AppUpdater-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMIT_ZIP"

echo "→ 提交公证（Apple 侧排队，通常几分钟）…"
LOG="$WORK/notary.log"
if ! xcrun notarytool submit "$SUBMIT_ZIP" \
      --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER_ID" \
      --wait 2>&1 | tee "$LOG"; then
  echo "✘ 公证提交失败，Apple 的输出见上" >&2
  exit 1
fi

if ! grep -q 'status: Accepted' "$LOG"; then
  echo "✘ 公证未通过。Apple 的结论：" >&2
  tail -20 "$LOG" >&2
  SUB_ID="$(grep -m1 '^  id: ' "$LOG" | awk '{print $2}' || true)"
  if [ -n "$SUB_ID" ]; then
    echo "" >&2
    echo "  取详细日志：xcrun notarytool log $SUB_ID \\" >&2
    echo "                --key <AuthKey.p8> --key-id $KEY_ID --issuer $ISSUER_ID" >&2
  fi
  exit 1
fi

echo "→ 把票据 staple 到 app 上…"
# staple 只写入票据本身，不会让已签名的资源清单失效，所以排在签名之后是安全的；
# 但 staple 之后 app 就不能再改了——一改票据就失效，公证得从头再来。
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo ""
echo "✔ 公证完成，票据已钉在 $APP"
echo "  后续 build-dmg.sh / ditto 出的包会带着票据一起走，用户双击即开。"
