# AGENT.md —— AI 操作员执行手册：在 macOS 上部署 WorkBuddy 双开

> **给 AI 的话**：你是一位操作 macOS 的 AI 助手。用户要求你在他的 Mac 上部署第二个 WorkBuddy 实例（双账号、数据隔离）。请严格按本手册执行：**先读「铁律」，再按阶段推进，每个阶段先检查、后动手、再验收**。本手册全程不修改主 app 的任何文件，所有动作可回滚。

用户可以这样把任务交给 AI：

> 请阅读并严格按照 https://raw.githubusercontent.com/ccccplus/workbuddy-multi-instance/main/AGENT.md 执行 WorkBuddy 双开部署。遇到与本手册冲突的情况，以本手册为准，并暂停向我确认。

---

## 铁律（违反任何一条立即停止）

1. **绝不修改主 app** `/Applications/WorkBuddy.app` 内的任何文件 —— 它只允许被读取。
2. **绝不改副本的 `CFBundleName`**（必须保持 `WorkBuddy`）。改了会导致 `FATAL: Unable to find helper app`，Dock 有图标但永远无窗口，且无报错弹窗。只允许改 `CFBundleIdentifier` 和 `CFBundleDisplayName`。
3. **绝不拷贝身份类文件**到新数据目录：`credentials/`、`device-id`、`workbuddy.db*`、`sessions/`、`security/`、`connectors/`、`storage/`、`local_storage/`。拷了 = 复制主实例身份 → 互踢或串号。
4. **绝不用 `rm -rf` 处理用户数据目录** `~/.workbuddy-2`。清理一律先备份到 `/tmp` 再移入 `~/.Trash/`。
5. **绝不用 `pkill -f "WorkBuddy 2.app"`** —— 该模式会匹配到执行命令的 shell 自身并自杀。杀副本进程用精确路径匹配（见阶段 1）。
6. **绝不使用 `kill -9`** 杀副本，除非常规 `kill` 确认无效。强杀会把副本打成僵尸状态。
7. 所有破坏性动作（`rm -rf "$DST"`、覆盖文件）之前，先确认目标路径正确，并向用户口头说明。
8. 若用户的 WorkBuddy 版本明显不在 5.5.x 附近（`CFBundleShortVersionString`），先警告用户"未经此版本验证"，征得同意后再继续。

---

## 阶段 0 · 环境检查（只读）

逐条执行并核对输出：

```bash
# 0.1 操作系统
uname    # 期望: Darwin
sw_vers -productVersion   # macOS 13+ 为佳

# 0.2 主 app 存在与版本
defaults read /Applications/WorkBuddy.app/Contents/Info.plist CFBundleShortVersionString
# 期望: 5.5.x 附近。若报错 = 未安装 WorkBuddy，终止并告知用户。

# 0.3 磁盘空间
df -h / | tail -1 | awk '{print $4}'
# 期望: 剩余 ≥ 5 GB（app 克隆 ~1GB + 运行时 ~700MB + 余量）

# 0.4 主 app 是否在运行（仅记录，不是问题）
lsappinfo list 2>/dev/null | grep -c 'bundleID="com.tencent.workbuddy.mac"'
```

**若 `/Applications/WorkBuddy 2.app` 已存在** → 这是修复/升级场景，直接跳到阶段 2 运行 setup 脚本即可（脚本自身处理旧副本）。

---

## 阶段 1 · 部署（一条命令完成）

优先用仓库脚本（推荐）：

```bash
curl -fsSL https://raw.githubusercontent.com/ccccplus/workbuddy-multi-instance/main/scripts/setup-workbuddy-2.sh -o /tmp/setup-wb2.sh \
  && bash /tmp/setup-wb2.sh --no-launch
```

若网络不可达，从阶段 A-1 起手动分步执行（每步都有验收点）：

**A-1 关闭可能存在的旧副本**（精确路径匹配，禁用 pkill -f）：

```bash
ps aux | grep -E 'WorkBuddy 2\.app/Contents' | grep -v grep | awk '{print $2}' | while read -r p; do kill "$p" 2>/dev/null; done
sleep 3
```

**A-2 克隆**：

```bash
rm -rf "/Applications/WorkBuddy 2.app"   # 只删副本，绝不碰主 app
cp -R "/Applications/WorkBuddy.app" "/Applications/WorkBuddy 2.app"
du -sh "/Applications/WorkBuddy 2.app"   # 期望 ~1GB
```

**A-3 改 Info.plist**：

```bash
cd "/Applications/WorkBuddy 2.app/Contents"
plutil -replace CFBundleIdentifier  -string "com.tencent.workbuddy.mac.alt2"    Info.plist
plutil -replace CFBundleDisplayName -string "WorkBuddy 2"                       Info.plist
plutil -replace LSEnvironment.WORKBUDDY_CONFIG_DIR -string "$HOME/.workbuddy-2" Info.plist
# 验收：三条都应输出期望值；CFBundleName 必须仍是 WorkBuddy
plutil -extract CFBundleName raw -o - Info.plist
```

**A-4 改 product.json 三件套**（防串号核心）：

```bash
/usr/bin/python3 - "/Applications/WorkBuddy 2.app/Contents/Resources/app.asar.unpacked/cli/product.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['productName'] = 'WorkBuddy2'
d['darwinBundleIdentifier'] = 'com.tencent.workbuddy.mac.alt2'
d.setdefault('authentication', {})['id'] = 'workbuddy-desktop-alt2'
json.dump(d, open(p, 'w'), ensure_ascii=False, indent=2)
print('OK')
PY
# 期望输出: OK
```

**A-5 修签名幽灵 + 重签名 + 清属性**：

```bash
rm -rf "/Applications/WorkBuddy 2.app/Contents/PlugIns/WechatShare.appex/Contents/_CodeSignature"
codesign --force --deep --sign - "/Applications/WorkBuddy 2.app"
xattr -cr "/Applications/WorkBuddy 2.app"
codesign -v "/Applications/WorkBuddy 2.app" && echo "签名有效"
```

**A-6 数据目录**（只拷无身份内容）：

```bash
mkdir -p "$HOME/.workbuddy-2"
[ -d "$HOME/.workbuddy/skills" ] && [ ! -d "$HOME/.workbuddy-2/skills" ] && cp -R "$HOME/.workbuddy/skills" "$HOME/.workbuddy-2/skills"
[ -f "$HOME/.workbuddy/mcp.json" ] && [ ! -f "$HOME/.workbuddy-2/mcp.json" ] && cp "$HOME/.workbuddy/mcp.json" "$HOME/.workbuddy-2/mcp.json"
```

**A-7 注册 LaunchServices**：

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "/Applications/WorkBuddy 2.app"
```

---

## 阶段 2 · 验证

```bash
# 2.1 启动
open -a "/Applications/WorkBuddy 2.app"
sleep 15

# 2.2 双实例在场（期望输出 1，加上主实例共 2 个 WorkBuddy 图标）
lsappinfo list 2>/dev/null | grep -c 'com.tencent.workbuddy.mac.alt2'

# 2.3 副本从自己的 app 加载（而不是主实例的更新缓存）—— 关键验收
PID=$(lsappinfo list 2>/dev/null | grep -B1 -A4 'com.tencent.workbuddy.mac.alt2' | grep -oE 'pid = [0-9]+' | head -1 | awk '{print $3}')
lsof -p "$PID" 2>/dev/null | grep -c "WorkBuddy 2.app.*app\.asar"   # 期望 ≥ 1

# 2.4 登录态干净（副本的 daemon 日志里应出现 noAuthFile 或 hasSession=false，
#     若出现 hasSession=true 且 uid 与主实例相同 → product.json 未生效，回阶段 1 A-4）
grep -oE "hasSession=[a-z]+" "$HOME/.workbuddy-2/logs/daemon.log" 2>/dev/null | tail -3

# 2.5 全量自检
bash /tmp/setup-wb2.sh 2>/dev/null; curl -fsSL https://raw.githubusercontent.com/ccccplus/workbuddy-multi-instance/main/scripts/verify-isolation.sh -o /tmp/verify-wb2.sh && bash /tmp/verify-wb2.sh
```

**无害告警（不要当成故障）**：`EADDRINUSE port 18488`（端口自动顺延）、`[Splash] Skipped due to previous crash`。

---

## 阶段 3 · 用户操作（AI 只提示，不代劳）

1. 请用户在副本窗口**扫码登录第二个账号**。
2. 登录后验收：共享 auth 目录出现副本自己的会话文件：

```bash
python3 -c "import os; d=os.path.expanduser('~/Library/Application Support/CodeBuddyExtension/Data/Public/auth'); print(sorted(f for f in os.listdir(d) if f.endswith('.info')))"
# 期望同时包含: workbuddy-desktop.info 与 workbuddy-desktop-alt2.info
```

3. 请用户做**终极测试**：在副本里登出 → 观察主实例是否仍在登录状态。主实例安坐不动 = 部署成功。

---

## 失败处理速查

| 现象 | 处置 |
|---|---|
| `open` 后 Dock 有图标、无窗口、日志不动 | 检查 `CFBundleName` 是否被误改 → 恢复为 `WorkBuddy`；若无法恢复，回阶段 1 A-2 重来 |
| 副本直接是主账号登录态 | `authentication.id` 未生效 → 重做 A-4，重签名，重启 |
| 副本秒退、无日志、`open` 无反应 | 曾被 `kill -9`：回阶段 1 重跑脚本重建副本 |
| `codesign -v` 报 sealed resource missing（WechatShare.cstemp） | **可忽略**（不影响启动）；强迫症则回 A-5 先删内层 `_CodeSignature` |
| "app 已损坏" 弹窗 | `xattr -cr` 未执行或被系统重新打标 → 再跑一次 |
| 端口 `EADDRINUSE 18488` | 无害，自动顺延到 18489/18490 |

## 回滚（用户要求撤销时）

```bash
PID=$(lsappinfo list 2>/dev/null | grep -B1 -A4 'com.tencent.workbuddy.mac.alt2' | grep -oE 'pid = [0-9]+' | head -1 | awk '{print $3}')
[ -n "$PID" ] && kill "$PID" && sleep 4
rm -rf "/Applications/WorkBuddy 2.app"          # 只删程序副本
# 数据目录 ~/.workbuddy-2 含用户登录态与数据 —— 必须先询问用户，确认后移入 ~/.Trash/（禁止 rm）
```

主 app 与 `~/.workbuddy` 全程未被本手册修改。

## 完工汇报模板

> ✅ WorkBuddy 双开部署完成：副本 v<版本> / Bundle ID `…alt2` / 数据目录 `~/.workbuddy-2`。
> 验证：双进程并存 ✓ / 副本从自身 app.asar 加载 ✓ / 登录态干净 ✓。
> 请扫码登录第二个账号，并做一次"副本登出 → 主实例不动"的终极测试。
