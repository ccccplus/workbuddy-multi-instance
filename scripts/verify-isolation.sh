#!/usr/bin/env bash
# ============================================================================
# WorkBuddy 双开隔离自检 —— 逐项核对两个实例是否真正"分家"
# 用法：bash verify-isolation.sh
# 退出码：0 = 全部通过；1 = 存在未通过项
# ============================================================================
set -uo pipefail

SRC="/Applications/WorkBuddy.app"
DST="/Applications/WorkBuddy 2.app"
ALT_ID="com.tencent.workbuddy.mac.alt2"
CFG_DIR="$HOME/.workbuddy-2"
AUTH_ID="workbuddy-desktop-alt2"
SHARED_AUTH="$HOME/Library/Application Support/CodeBuddyExtension/Data/Public/auth"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
note() { echo "  ⚠️  $1"; }

echo "════════════════════════════════════════════"
echo " WorkBuddy 双开隔离自检"
echo "════════════════════════════════════════════"

echo ""
echo "【1/6】程序副本"
if [ -d "$DST" ]; then
  ok "副本存在：$DST (v$(defaults read "$DST/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?'))"
  BID=$(defaults read "$DST/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "?")
  [ "$BID" = "$ALT_ID" ] && ok "Bundle ID = $BID" || bad "Bundle ID = $BID（应为 $ALT_ID）"
  BN=$(defaults read "$DST/Contents/Info.plist" CFBundleName 2>/dev/null || echo "?")
  [ "$BN" = "WorkBuddy" ] && ok "CFBundleName 保持 WorkBuddy（未误改）" \
                          || bad "CFBundleName = $BN —— 被改过！Helper 会找不到，必须恢复为 WorkBuddy"
else
  bad "副本不存在，先运行 scripts/setup-workbuddy-2.sh"
fi

echo ""
echo "【2/6】环境变量注入"
ENV_VAL=$(plutil -extract LSEnvironment.WORKBUDDY_CONFIG_DIR raw -o - "$DST/Contents/Info.plist" 2>/dev/null || echo "")
[ "$ENV_VAL" = "$CFG_DIR" ] && ok "LSEnvironment.WORKBUDDY_CONFIG_DIR = $ENV_VAL" \
                            || bad "WORKBUDDY_CONFIG_DIR 注入异常（当前: '${ENV_VAL:-未设置}'）"

echo ""
echo "【3/6】product.json 三件套"
PJ="$DST/Contents/Resources/app.asar.unpacked/cli/product.json"
if [ -f "$PJ" ]; then
  /usr/bin/python3 - "$PJ" "$ALT_ID" "$AUTH_ID" <<'PYEOF'
import json, sys, os
d = json.load(open(sys.argv[1]))
alt_id, auth_id = sys.argv[2], sys.argv[3]
def check(name, cond, detail):
    print(("  ✅ " if cond else "  ❌ ") + name + "：" + detail)
    if not cond: os._exit(3)
check("productName", d.get('productName') == 'WorkBuddy2', repr(d.get('productName')))
check("darwinBundleIdentifier", d.get('darwinBundleIdentifier') == alt_id, repr(d.get('darwinBundleIdentifier')))
check("authentication.id", d.get('authentication', {}).get('id') == auth_id, repr(d.get('authentication', {}).get('id')))
check("applicationName 未被改动", d.get('applicationName') == 'WorkBuddy', repr(d.get('applicationName')))
PYEOF
  [ $? -eq 0 ] && PASS=$((PASS+4)) || FAIL=$((FAIL+1))
else
  bad "product.json 不存在：$PJ"
fi

echo ""
echo "【4/6】数据目录"
if [ -d "$CFG_DIR" ]; then ok "数据目录存在：$CFG_DIR"; else bad "数据目录不存在：$CFG_DIR"; fi
if [ -d "$HOME/.workbuddy" ]; then ok "主实例数据目录未被挪动：$HOME/.workbuddy"; fi

echo ""
echo "【5/6】更新缓存目录分离"
ALT_CACHE="$HOME/Library/Caches/$ALT_ID.BundleMigration"
MAIN_CACHE="$HOME/Library/Caches/com.tencent.workbuddy.mac.BundleMigration"
[ -d "$ALT_CACHE" ] && ok "副本独立缓存已生成：$ALT_CACHE" \
                    || note "副本缓存尚未生成（首次启动后出现；若已启动多次仍无 → product.json 未生效）"
[ -d "$MAIN_CACHE" ] && ok "主实例缓存原样存在"

echo ""
echo "【6/6】共享 auth 会话文件（同登同退的根源地）"
# 注意：沙箱环境里 ls 该目录可能被 TCC 拦截返回空，用 python 直读更可靠
/usr/bin/python3 - "$SHARED_AUTH" <<'PYEOF'
import os, sys, time
d = sys.argv[1]
if not os.path.isdir(d):
    print("  ⚠️  共享 auth 目录不存在（从未登录过？）:", d); sys.exit(0)
files = sorted(os.listdir(d))
infos = [f for f in files if f.endswith('.info')]
main  = [f for f in infos if f == 'workbuddy-desktop.info']
alt   = [f for f in infos if 'alt2' in f]
if main: print("  ✅ 主实例会话文件在场：workbuddy-desktop.info")
if alt:  print("  ✅ 副本独立会话文件在场：" + ", ".join(alt))
elif main:
    print("  ⚠️  副本尚未登录（没有 alt2 会话文件）—— 属正常，登录第二账号后出现")
if len(infos) == 1 and 'alt2' not in infos[0] and os.path.getsize(os.path.join(d, infos[0])) > 0:
    print("  ℹ️  目前只有一份会话文件。若两窗口显示同一账号，说明隔离未生效，重跑 setup 脚本。")
PYEOF

echo ""
echo "════════════════════════════════════════════"
echo " 结果：$PASS 项通过，$FAIL 项未通过"
[ "$FAIL" -eq 0 ] && echo " 🎉 隔离完好。" || echo " 🔧 修复建议：重跑 bash scripts/setup-workbuddy-2.sh"
echo "════════════════════════════════════════════"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
