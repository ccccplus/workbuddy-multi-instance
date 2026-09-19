#!/usr/bin/env bash
# ============================================================================
# WorkBuddy 2 —— 一键双开安装 / 修复 / 升级脚本（macOS）
#
# 做什么：把 /Applications/WorkBuddy.app 克隆为完全独立的第二实例
#         "WorkBuddy 2.app"（独立 Dock 图标、独立数据目录、独立登录态）。
#         已安装过 = 修复；主 app 升级后运行 = 同步新版本。
#
# 数据目录 ~/.workbuddy-2 永远不会被本脚本删除或覆盖。
#
# 用法：bash setup-workbuddy-2.sh              # 安装/修复并启动
#       bash setup-workbuddy-2.sh --no-launch  # 只部署，不启动
# ============================================================================
set -euo pipefail

SRC="/Applications/WorkBuddy.app"
DST="/Applications/WorkBuddy 2.app"
ALT_ID="com.tencent.workbuddy.mac.alt2"
CFG_DIR="$HOME/.workbuddy-2"
AUTH_ID="workbuddy-desktop-alt2"

# ---------------------------------------------------------------- 前置检查
if [ ! -d "$SRC" ]; then
  echo "❌ 找不到主 app：$SRC"
  echo "   请确认 WorkBuddy 已安装在 /Applications。"; exit 1
fi
if [ "$(uname)" != "Darwin" ]; then
  echo "❌ 本脚本仅支持 macOS。"; exit 1
fi

MAIN_VER=$(defaults read "$SRC/Contents/Info.plist" CFBundleShortVersionString)
echo "🔍 主 app 版本：$MAIN_VER"
CUR_VER=""
if [ -d "$DST" ]; then
  CUR_VER=$(defaults read "$DST/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "")
  echo "📦 副本当前版本：$CUR_VER"
fi

# 已是最新版则跳过，避免白白关掉副本重建一遍（首次安装时 DST 不存在，不受影响）
# --force 可强制重建。⚠️ 变量紧跟中文标点时必须写 ${VAR}：macOS bash 3.2 会把
# 多字节标点吞进变量名（$CUR_VER，→ 找名为 "CUR_VER，" 的变量 → unbound variable）
FORCE=0
for arg in "$@"; do [[ "$arg" == "--force" ]] && FORCE=1; done
if [[ -n "$CUR_VER" && "$CUR_VER" == "$MAIN_VER" && "$FORCE" == "0" ]]; then
  echo "✨ 副本已是最新版 ${CUR_VER}，无需更新（想强制重建加 --force）"
  exit 0
fi

# ---------------------------------------------------------------- 1. 关闭副本
PID=$(lsappinfo list 2>/dev/null | grep -B1 -A4 "$ALT_ID" \
      | grep -oE 'pid = [0-9]+' | head -1 | awk '{print $3}' || true)
if [ -n "${PID:-}" ]; then
  echo "⏹  关闭副本进程 (pid=$PID)…"
  kill "$PID" 2>/dev/null || true
  sleep 4
fi
# 兜底：精确匹配进程路径（绝不使用 pkill -f —— 会误杀执行脚本自身的 shell）
ps aux | grep -E 'WorkBuddy 2\.app/Contents' | grep -v grep \
  | awk '{print $2}' | while read -r p; do kill "$p" 2>/dev/null || true; done
sleep 2

# ---------------------------------------------------------------- 2. 重建副本
echo "♻️  克隆副本（APFS clone，约 2 秒）…"
rm -rf "$DST"
cp -R "$SRC" "$DST"

# ---------------------------------------------------------------- 3. 改 Info.plist
# ⚠️ 绝不改 CFBundleName！Electron 按 "CFBundleName Helper" 在 Contents/Frameworks/
#    里找辅助进程（WorkBuddy Helper.app 等四个）。改了 → FATAL: Unable to find helper app，
#    表现为 Dock 有图标但永远没有窗口。
echo "🪪  改写 Info.plist（Bundle ID / 显示名 / 环境变量）…"
cd "$DST/Contents"
plutil -replace CFBundleIdentifier  -string "$ALT_ID"       Info.plist
plutil -replace CFBundleDisplayName -string "WorkBuddy 2"   Info.plist
# CFBundleName 保持原值 WorkBuddy，故意不动。
plutil -replace LSEnvironment.WORKBUDDY_CONFIG_DIR -string "$CFG_DIR" Info.plist

# ---------------------------------------------------------------- 4. product.json 三件套
# 不改这里，两个实例会共用同一份登录会话文件（同登同退）和同一个更新缓存
# （甚至从同一份缓存 bundle 启动）。三处缺一不可：
#   productName               → 应用名 → 钥匙串身份
#   darwinBundleIdentifier    → BundleMigration 更新缓存目录名（注意：不读运行时 Bundle ID！）
#   authentication.id         → 共享 auth 目录里的会话文件名（默认两实例同名 → 串号根源）
PRODUCT_JSON="$DST/Contents/Resources/app.asar.unpacked/cli/product.json"
if [ -f "$PRODUCT_JSON" ]; then
  cp "$PRODUCT_JSON" /tmp/product.json.orig.bak
  /usr/bin/python3 - "$PRODUCT_JSON" "$ALT_ID" "$AUTH_ID" <<'PYEOF'
import json, sys
path, alt_id, auth_id = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
d['productName'] = 'WorkBuddy2'              # → 钥匙串身份（applicationName 保持 WorkBuddy 不动）
d['darwinBundleIdentifier'] = alt_id         # → 独立更新缓存目录
d.setdefault('authentication', {})['id'] = auth_id  # → 独立 auth 会话文件
json.dump(d, open(path, 'w'), ensure_ascii=False, indent=2)
print("   ✅ product.json 三件套已隔离")
PYEOF
else
  echo "⚠️  未找到 product.json —— 登录态将与主实例串号！请检查 app 版本。"
fi

# ---------------------------------------------------------------- 5. 修签名幽灵
# codesign --deep 曾给微信分享插件造出 .cstemp 临时文件并写进封印，之后又删掉它，
# 导致严格校验报 "sealed resource missing"。删掉内层旧签名再签即可避免。
rm -rf "$DST/Contents/PlugIns/WechatShare.appex/Contents/_CodeSignature" 2>/dev/null || true

# ---------------------------------------------------------------- 6. 重签名 + 清隔离属性
echo "🔏  ad-hoc 重签名…"
codesign --force --deep --sign - "$DST" 2>&1 | grep -v "replacing existing signature" || true
xattr -cr "$DST"

# ---------------------------------------------------------------- 7. 准备数据目录
# 只拷贝技能与 MCP 配置这类「无身份」内容；credentials / device-id / workbuddy.db /
# sessions / security / connectors 一律不碰 —— 拷了等于复制主实例身份，会互踢。
echo "📁  准备数据目录 $CFG_DIR …"
mkdir -p "$CFG_DIR"
if [ -d "$HOME/.workbuddy/skills" ] && [ ! -d "$CFG_DIR/skills" ]; then
  cp -R "$HOME/.workbuddy/skills" "$CFG_DIR/skills" 2>/dev/null \
    && echo "   ✅ 已继承 skills/（如不需要可删除 $CFG_DIR/skills）"
fi
if [ -f "$HOME/.workbuddy/mcp.json" ] && [ ! -f "$CFG_DIR/mcp.json" ]; then
  cp "$HOME/.workbuddy/mcp.json" "$CFG_DIR/mcp.json" 2>/dev/null \
    && echo "   ✅ 已继承 mcp.json"
fi

# ---------------------------------------------------------------- 8. 注册 LaunchServices
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R "$DST" >/dev/null 2>&1 || true

NEW_VER=$(defaults read "$DST/Contents/Info.plist" CFBundleShortVersionString)

# ---------------------------------------------- 8.5 三件套自检（任一不对立刻停手报警）
# 官方改版可能挪动 product.json 字段位置；与其让你开着半隔离的副本排查三天，
# 不如在部署时当场把三件套验一遍。
echo "🔬 自检 product.json 三件套…"
/usr/bin/python3 - "$PRODUCT_JSON" "$ALT_ID" "$AUTH_ID" <<'PYEOF' \
  || { echo "❌ 隔离自检未通过！请勿使用，检查 product.json 字段是否被新版改动"; exit 1; }
import json, sys
path, alt_id, auth_id = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
checks = [
    ("productName",            d.get('productName'),                  'WorkBuddy2'),
    ("darwinBundleIdentifier", d.get('darwinBundleIdentifier'),       alt_id),
    ("authentication.id",      d.get('authentication', {}).get('id'), auth_id),
]
ok = True
for name, got, want in checks:
    if got == want:
        print(f"   ✅ {name} = {got}")
    else:
        print(f"   ❌ {name} = {got}（应为 {want}）"); ok = False
sys.exit(0 if ok else 1)
PYEOF

# ---------------------------------------------- 8.6 插件补丁复检
# 副本的插件在数据目录 ~/.workbuddy-2 内，升级 app 不会动它；
# 但插件自身升级会覆盖脚本、把路径补丁冲掉 —— 打过补丁的话记得重打。
if [ -d "$CFG_DIR/plugins" ]; then
  echo "🍜 提示：若你给副本插件打过路径补丁，插件自行升级会冲掉它 —— 需重打一次。"
fi

echo ""
echo "✅ 部署完成：WorkBuddy 2 v$NEW_VER"
echo "   · 程序：$DST"
echo "   · 数据：$CFG_DIR（独立登录态，首次启动请重新登录第二个账号）"
echo ""

# ---------------------------------------------------------------- 9. 启动
if [[ "${1:-}" != "--no-launch" ]]; then
  echo "🚀 启动 WorkBuddy 2 …"
  open -a "$DST"
  sleep 3
  echo "   如果 Dock 出现第二个图标但没窗口，等 10 秒再点一次图标即可。"
fi
echo ""
echo "🧪 建议运行隔离自检：bash scripts/verify-isolation.sh"
