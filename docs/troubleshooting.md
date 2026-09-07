# 踩坑全记录 —— 每一个坑都是真金白银撞出来的

> 本文档记录在 WorkBuddy 5.5.2/5.5.3 真机上逆向 + 部署双开时遇到的**全部**故障，按剧情顺序排列。每条含：现象 → 误判 → 真因 → 解法 → 预防。适合需要深度定制（第三实例、自动化、插件隔离）的读者。

---

## 第一幕：找开关

### 坑 1.1 · 别在二进制里瞎猜，官方留了门

**做法**：用脚本分段扫描 `app.asar`（283 MB 的 JS 明文），搜索 `WORKBUDDY[A-Z_]*` 模式，找到数据目录覆盖开关：

```js
const envDir = (process.env.WORKBUDDY_CONFIG_DIR || process.env.CODEBUDDY_CONFIG_DIR || "").trim();
if (envDir) return path.resolve(envDir);
return path.join(os.homedir(), ".workbuddy");   // 默认
```

**结论**：`WORKBUDDY_CONFIG_DIR` = 整棵数据树搬家（账号、会话、skills、plugins、connectors、memory 全跟着走）。macOS 分支**没有** `requestSingleInstanceLock`（那套只在 Windows 用），双进程无法律障碍。

### 坑 1.2 · 命令行启动的 GUI 进程会"猝死"

**现象**：`nohup …/Electron &` 启动后 1 分半，进程消失，日志停在 `session.setProxy`。
**真因**：Bash 工具的命令结束时整个进程组被清场。
**解法**：脱离进程组启动：

```python
subprocess.Popen([…], env=env, start_new_session=True, cwd="/", stdout=log, stderr=subprocess.STDOUT)
```

**教训**：临时验证可以这么干，长期使用必须走 app 副本（launchd 正规启动）。

### 坑 1.3 · 判断进程存活别用 ps/pgrep

部分沙箱环境拦截 `ps`（返回空 ≠ 没进程）。用持久证据：`lsappinfo list | grep bundleID`、日志文件的 mtime 是否增长。

---

## 第二幕：独立图标的副本

### 坑 2.1 · 🚨 头号坑：`CFBundleName` 是隐形杀手

**现象**：改完 Info.plist，启动后 **Dock 出现图标但没有窗口**，无报错、无弹窗、日志纹丝不动 —— 与"进程假死"一模一样。
**误判**：怀疑签名、怀疑 Launch Services 注册、怀疑隔离属性，绕了大圈。
**真因**：直接跑副本二进制抓到现场：

```
FATAL:electron/shell/app/electron_main_delegate_mac.mm:65] Unable to find helper app
```

Electron 按 `CFBundleName + " Helper"` 去 `Contents/Frameworks/` 找辅助进程。磁盘上是 `WorkBuddy Helper.app`、`WorkBuddy Helper (GPU).app`、`(Plugin)`、`(Renderer).app` —— 一窝四个。`CFBundleName` 改成 "WorkBuddy 2" 后全家失联。
**解法**：**只改 `CFBundleIdentifier` 和 `CFBundleDisplayName`，`CFBundleName` 永远保持 `WorkBuddy`**。Dock 显示名由 DisplayName 决定，改它就够了。
**预防**：任何 Electron app 做副本都适用此规则。

### 坑 2.2 · codesign 的 `.cstemp` 幽灵文件

**现象**：`codesign -vvv --deep --strict` 报 `a sealed resource is missing`，缺失文件是 `WechatShare.cstemp` —— 磁盘上根本不存在。
**真因**：`codesign --deep` 签名时给微信分享插件造了临时文件、写进封印、随后自己删掉。幽灵从此活在封印里。
**解法**：删掉内层旧签名再签：`rm -rf …/WechatShare.appex/Contents/_CodeSignature` 后重新整体签。
**重要**：**此瑕疵不影响启动**（app 照跑）。别为签名洁癖消耗时间 —— 能跑就不折腾。

### 坑 2.3 · 改了 app 内任何文件都要重签名

`Info.plist`、`product.json`……动一个字节，封印就破。macOS 对失效签名的表现是"已损坏，建议移到废纸篓"。`codesign --force --deep --sign -`（ad-hoc）+ `xattr -cr`（清 quarantine/provenance）二连即可。macOS 新版还会重新贴 `com.apple.provenance`，启动失败时先查属性再怀疑人生。

### 坑 2.4 · 沙箱会拦截复制大文件

`cp -R` 1 GB app 到 `/Applications` 可能报 `Operation not permitted`（对 `app.asar` 等）。需要提权/豁免执行环境。APFS 克隆模式下复制约 2 秒，无真实 IO 成本。

### 坑 2.5 · `kill -9` 把副本打成僵尸

**现象**：强杀后 `open -a` 无反应、直接跑二进制 `returncode=0` 秒退且零输出、连日志文件都不生成。
**真因**：LaunchServices 认为它在跑（或单例锁残留），新进程一启动就自己退出。
**诊断**：用全新空目录启动同一 app 区分"app 坏"还是"数据坏"：

```bash
mkdir -p /tmp/fresh-test
WORKBUDDY_CONFIG_DIR=/tmp/fresh-test "/Applications/WorkBuddy 2.app/Contents/MacOS/Electron"
```

新目录也起不来 → app 本体坏了 → 重建副本（setup 脚本一键搞定，数据目录不受影响）。

### 坑 2.6 · `pkill -f` 会杀掉你自己

`pkill -f "WorkBuddy 2.app"` 的 `-f` 匹配**完整命令行** —— 执行这条命令的 shell 自身命令行里也含这串字符，直接自杀（表现为 `SIGKILL`、输出截断）。
**解法**：

```bash
ps aux | grep -E 'WorkBuddy 2\.app/Contents' | grep -v grep | awk '{print $2}' | xargs kill
```

---

## 第三幕：串号之谜（本指南的灵魂剧情）

### 坑 3.1 · 第一层：更新缓存目录名不读运行时 Bundle ID

**现象**：副本改了 Bundle ID，但 `lsof` 显示它加载的是**主实例缓存**里的代码：
`~/Library/Caches/com.tencent.workbuddy.mac.BundleMigration/extracted/5.5.3…/app.asar`
**真因**（源码实锤）：

```js
const bundleId = productConfig?.darwinBundleIdentifier || "com.workbuddy.workbuddy";
this.migrationCacheDir = `~/Library/Caches/${bundleId}.BundleMigration`;
```

缓存目录名取自 `product.json` 的**硬编码值**，不看运行时身份。两实例共用同一缓存、从同一份 bundle 启动 → 身份自然合体。
**解法**：改副本 `app.asar.unpacked/cli/product.json` 的 `darwinBundleIdentifier`。

### 坑 3.2 · 第二层：auth 会话文件在共享目录（同登同退的真凶）

**现象**：副本一打开"直接就是已登录"；任一边登出，另一边秒掉线。
**误判过程**（写出来防止后人重走）：先怀疑从主实例拷过去的 `connectors/`（清掉后又自动重建）、再怀疑 `security/`、`storage/`、`local_storage/`、`workbuddy.db`、`app/session`、钥匙串（Keychain）……**全部清空/隔离后依然串号** —— 因为母本根本不在这些地方。
**真凶**（FileAuthStorage 源码）：

```js
return path.join(this.filePathService.sharedDataPath, "auth", `${authenticationId}.info`);
// sharedDataPath = ~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/
```

官方注释：*"Stores authentication session in a shared location that can be accessed by CLI subprocesses"* —— 为让 CLI 子进程共享登录态，会话文件**故意**全局共享，文件名 = `product.json` 的 `authentication.id`（默认所有实例同名）。登出 = 写 `.logged-out` 标记，FileAuthStorage 带**文件监视器**，一边写另一边秒看到。

**实锤证据链**：
1. 该文件是**明文 JSON**（未加密），直接含账号 uid
2. 两实例在**同一秒**各做一次凭据恢复，读到相同字节数、相同 uid
3. 共享目录里躺着副本 daemon 亲手写回的文件（文件名带其 pid）
4. "服务器绑定"假设被完整证伪 —— 全程本地行为

**解法**：三件套一起改（缺一不可）：

```bash
d['productName'] = 'WorkBuddy2'                                   # 钥匙串身份
d['darwinBundleIdentifier'] = 'com.tencent.workbuddy.mac.alt2'    # 更新缓存目录
d.setdefault('authentication', {})['id'] = 'workbuddy-desktop-alt2'  # auth 会话文件名
```

改后重签名、重启。**验收三绿**：副本日志出现 `noAuthFile`（首次找不到共享会话）／`AppStartup` 显示 `userId=unknown`／主实例 `hasSession=true` 纹丝不动。

**方法论**：定位"谁在共享"，最快的手段是 `lsof -p <pid>` 看进程实际打开了哪些文件 —— 比读代码猜路径快得多。

### 坑 3.3 · 沙箱里的 TCC 假象：`ls` 返回空 ≠ 目录为空

共享 auth 目录在受限环境里 `ls` 输出可能为空（TCC 拦截），实际文件都在。用 Python `os.listdir` 或提权方式直读，别被假象带偏。

### 坑 3.4 · 拷数据目录时的身份雷区

准备新数据目录时，**只拷"无身份"内容**（`skills/`、`mcp.json`）。以下一律不拷：

```
device-id、credentials/、workbuddy.db*、sessions/、security/、storage/、
local_storage/、app/connector-keys、connectors/   ← connectors 里有 <uid>/.master.key
```

实测：即使事后清空 `security/`、`storage/` 等，第二实例每次启动都会**自动重建** `connectors/<主实例uid>/` 并据此恢复主实例身份 —— 母本污染物，必须从源头不拷。

---

## 第四幕：插件层的伪共享

### 坑 4.1 · 第三方插件可能硬编码 `~/.workbuddy`

**案例**：某生活服务专家插件（v1.0.2）的 `run.js:40`：

```js
const AUTH_DIR = path.join(require('os').homedir(), '.workbuddy', 'credentials', '…');
```

完全无视 `WORKBUDDY_CONFIG_DIR`，且用 `Object.assign` **显式覆盖**外部传入的环境变量（`LSEnvironment` 注入无效）。后果：副本实例读写的全是主实例的插件凭据。

**解法**：只改副本侧的插件脚本（主实例零改动），把硬编码路径改为：

```js
const AUTH_DIR = path.join(
  process.env.WORKBUDDY_CONFIG_DIR || path.join(require('os').homedir(), '.workbuddy'),
  'credentials', '…'
);
```

**验收**：带 `WORKBUDDY_CONFIG_DIR` 跑插件查询命令 → 应该查无凭据（`NO_TOKEN`）；不带 env → 主实例凭据正常读取。

**排查口诀**：多实例串数据时，除了 app 本体，记得 `grep -rn "\.workbuddy" <插件目录>/scripts/` —— 插件作者可不管你的环境变量。

### 坑 4.2 · 工具类小坑

- **BSD grep 的 BRE 不支持 `\|` 交替**（静默零匹配、不报错），多模式用 `grep -E "a|b"` —— 一次 grep 漏检曾让整个分析方向偏了两轮
- macOS **没有 `timeout` 命令**
- `open -na` 启动的 app **不继承 shell 环境变量** —— 环境变量注入必须走 `LSEnvironment`（Info.plist）

---

## 验证状态速记

| 项目 | 状态 |
|---|---|
| 双进程同时运行 | ✅ 实测 |
| 独立 Dock 图标 | ✅ 实测 |
| 数据/缓存/偏好/凭据隔离 | ✅ 实测 |
| 双账号登录、登出互不影响 | ✅ 实测（终极测试通过） |
| 插件凭据隔离（补丁后） | ✅ 实测 |
| 服务端风控 | ⚠️ 无法从客户端代码判断，实测未触发，风险自担 |
