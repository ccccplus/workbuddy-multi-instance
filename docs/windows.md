# Windows 可行性探讨 · 这套方案能移植吗？

> ⚠️ **先说边界**：本文档**没有在 Windows 上实测过**。
> 它是从 macOS 版 WorkBuddy（5.5.6）的程序包里逆向出的证据 + 推理。
> 实证部分会注明出处，推演部分会标明"推演"，未知部分直接写"未知"。
> 如果你在 Windows 上试成了（或试挂了），欢迎提 issue 把结论补上。

---

## 结论速览

**思路通用，脚本不通。** 三个层次里，两个可以直接搬，一个要换字段，还有一个悬而未决。

| 层次 | macOS 做法 | Windows 判断 | 依据 |
|---|---|---|---|
| 数据目录隔离 | `WORKBUDDY_CONFIG_DIR` | ✅ **同样有效** | 读 env 的是纯 Node 代码，平台无关（实证） |
| 登录态隔离 | `authentication.id` | ✅ **同样需要改** | 逻辑层，不涉及系统 API（实证） |
| 应用身份 | `productName` | ✅ **建议改** | 影响 `app.name` → 单实例锁名（实证） |
| 平台专属 ID | `darwinBundleIdentifier` | 🔁 **换成 Win 字段** | product.json 里有一整套 Win 字段（实证） |
| 单实例锁 | Electron `requestSingleInstanceLock` | ⚠️ **存在额外 Mutex 风险** | `win32MutexName` 字段（推演） |
| 重签名 | 必须 `codesign` | ✅ **不需要** | Windows 没有 Gatekeeper |

**一句话**：底层思路（环境变量分家 + product.json 改身份）是通用的，
但 Windows 有一套**自己的身份字段**，且可能存在一个**改 JSON 也未必绕得开的原生互斥体**。

---

## 实证：从 macOS 包里挖到的三条证据

证据来自 `/Applications/WorkBuddy.app/Contents/Resources/`，任何人都可以复现。

### 证据 1 · 数据目录靠环境变量，代码平台无关

```js
function resolveConfigDir() {
  const fromEnv = process.env.WORKBUDDY_CONFIG_DIR?.trim();
  if (fromEnv) return fromEnv;
  const folder = process.env.WORKBUDDY_DATA_FOLDER_NAME?.trim() || ".workbuddy";
  return path.join(os.homedir(), folder);
}
```

纯 Node，没有任何 macOS 专属 API。Windows 上同样成立 —— 只要你能把环境变量喂给进程。

### 证据 2 · userData 被主动重定向，官方注释直接点名了 `%APPDATA%`

```js
app.setPath("userData",    getWorkbuddyUserDataDir());
app.setPath("sessionData", getWorkbuddySessionDataDir());
```

源码注释里写着：

> Electron 默认 userData 在那，但 WorkBuddy 通过 `app.setPath('userData', '<数据目录>/app')` 重定向了，
> 所以 `%APPDATA%` 实际不被项目使用……

这意味着 Windows 上两份实例只要数据目录不同，userData 就天然分开 —— **Electron 的单实例锁也就天然不撞**。

### 证据 3 · product.json 里躺着完整的 Windows 字段集

从 `app.asar.unpacked/cli/product.json` 直接读到：

```jsonc
"darwinBundleIdentifier": "com.tencent.workbuddy.mac",   // macOS 专用
"win32x64AppId":          "{61A882F2-969F-45BF-A652-FA5C6B03DE22}",
"win32arm64AppId":        "{E5979B74-105C-46B5-AED6-599C029B689D}",
"win32x64UserAppId":      "{BFD312E9-1019-4F57-9F44-F86246833B50}",
"win32arm64UserAppId":    "{B7353D0F-D01C-4EC3-96A9-5CEA88358454}",
"win32MutexName":         "workbuddy",                    // ← 注意这个
"win32AppUserModelId":    "WorkBuddy.WorkBuddy"
```

同一份配置里还有 `kylinV10` 与 `uos`（国产 Linux 发行版）—— 说明官方的配置是按平台组织身份字段的。

其中两个字段的用法在代码里有实锤：

```js
// win32AppUserModelId —— 任务栏图标分组
if (process.platform === "win32") {
  const appUserModelId = productConfig?.win32AppUserModelId || "WorkBuddy.WorkBuddy";
  electron.app.setAppUserModelId(appUserModelId);
}

// 单实例锁 —— 无参数调用，锁名由 app 身份推导
acquireSingletonLock() {
  const gotTheLock = electron.app.requestSingleInstanceLock();
  if (!gotTheLock) { /* 让位给已运行的实例 */ }
}
```

---

## 推演：Windows 上大概要这么干

> 🚧 以下为**推演路线，未经实测**，按顺序尝试并逐条验证。

### 第 1 步 · 复制程序目录

Windows 没有签名校验，**改完文件不会被系统拦** —— 这是比 macOS 省心的地方（省掉整个 codesign 环节）。

- 安装版通常在 `%LOCALAPPDATA%\Programs\WorkBuddy\` 或 `C:\Program Files\WorkBuddy\`
- 把整个目录复制一份，例如 `WorkBuddy2\`

### 第 2 步 · 改 product.json

位置应为 `resources\app.asar.unpacked\cli\product.json`（与 macOS 同构）。
建议改这几处，与 macOS 的三件套一一对应：

| 字段 | 改成 | 作用 |
|---|---|---|
| `productName` | `WorkBuddy2` | 应用名 → 影响 `app.name` 与单实例锁 |
| `authentication.id` | `workbuddy-desktop-alt2` | **串号元凶**，与 macOS 同理必须改 |
| `win32AppUserModelId` | `WorkBuddy.WorkBuddy2` | 任务栏图标别合并成一组 |
| `win32MutexName` | `workbuddy2` | 若原生层用它做单实例，改名才可能绕过 |
| `win32x64AppId` / `win32x64UserAppId` | 换个 GUID | 避免与安装器/卸载项/更新器撞车 |

> 💡 好消息：改的是 `app.asar.unpacked` 里的文件，**不进 app.asar 包内**，
> 因此不会触发 Electron 的 asar 完整性校验 —— 这一点与 macOS 完全相同。

### 第 3 步 · 用启动器注入环境变量

Windows 没有 `LSEnvironment`（那是 Info.plist 的机制），改用一个 `.bat` 包装：

```bat
@echo off
set "WORKBUDDY_CONFIG_DIR=%USERPROFILE%\.workbuddy-2"
start "" "%~dp0WorkBuddy.exe"
```

快捷方式指向这个 bat 即可。**别设成系统全局环境变量** —— 那会把主实例也一起改掉。

### 第 4 步 · 验证清单

- [ ] 两个窗口能同时存在（不是第二个点了没反应）
- [ ] 任务栏是两个独立图标，不是合并成一组
- [ ] 两个实例能登录**不同**账号
- [ ] 一边登出，另一边**不掉线**（这是终极测试）
- [ ] 数据目录真的分家：`%USERPROFILE%\.workbuddy` 与 `%USERPROFILE%\.workbuddy-2`
- [ ] 共享 auth 目录里出现两个会话文件（Windows 路径待确认，可搜 `auth` 文件夹）

---

## ❓ 三个真未知（不实测就没有答案）

1. **`win32MutexName` 到底是谁在用？**
   它在 macOS 包里只存在于 product.json，**任何 JS 代码都没引用它**。
   推测由 Windows 端的原生启动器/安装器（exe）使用。若是启动器在创建同名全局 Mutex，
   那么改 product.json 可能**无效** —— 这是 Windows 方案最大的不确定项。

2. **安装版 vs 解压版行为可能不同。**
   安装版带注册表项、卸载项、自动更新器（AppId 那组 GUID 大概率与之相关）。
   改名后更新器可能找不到自己 —— 但副本本来就不该自动更新，或许反而是好事。

3. **Windows 版包结构是否与 macOS 同构？**
   macOS 包里的 `platform` 字段说明配置按平台裁剪，Windows 的 app.asar 内容可能不同，
   上述路径与字段位置需以实际目录为准。

---

## 为什么 macOS 版能成 —— 回看一眼原理

macOS 上成功的关键是**三件套齐全**，缺一个就会退回"同登同退"：

```
productName            → app.name → 钥匙串身份 + 单实例锁名
darwinBundleIdentifier → 更新缓存目录（5.5.6 起疑似不再生成，但仍须改）
authentication.id      → 共享 auth 目录里的会话文件名 ← 串号真凶
```

Windows 的对应物就是上面那张字段表。**原理不变，字段名换一套。**

---

## 给愿意当小白鼠的人

如果你在 Windows 上试了，最有价值的三件事：

1. `win32MutexName` 改了之后能不能双开（这条能定生死）
2. 实际的安装目录与 product.json 路径
3. 共享 auth 目录在 Windows 上的真实路径

带着结果来开 issue，我会把结论补进这份文档，并注明实测版本。
