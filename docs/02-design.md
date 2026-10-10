# 02 设计

本文描述各功能的设计方案与平台差异。架构层面的划分见 03-architecture。

## 总体行为

进程启动即进入**激活**状态（无命令行参数）：先取单实例锁，再做开机自启同步，随后启动鼠标微动线程并进入托盘事件循环。

## 睡眠抑制（双保险）

1. **电源断言**（平台原生机制，可靠）；
2. **鼠标微动**（每 60 秒移动 1 像素再复位，兜底）。

| 平台 | 电源断言 | 微动实现 |
| ---- | ---- | ---- |
| Windows | `SetThreadExecutionState(ES_CONTINUOUS \| ES_SYSTEM_REQUIRED \| ES_DISPLAY_REQUIRED)` | `SetCursorPos(+1, y)` → 复位 |
| Linux | 无系统级 API（靠微动 + 合盖守卫） | X11 `XTestFakeMotionEvent`（动态加载） |
| macOS | `IOPMAssertionCreateWithName(NoDisplaySleepAssertion)` | `CGEventPost` 鼠标移动事件 |

### Windows 的按线程语义（关键设计点）

`SetThreadExecutionState` 的效果**只作用于调用线程**。托盘在主线程点击「暂停」只能清除主线程的断言，微动线程上一轮设置的 `ES_*` 会残留，导致暂停失效。因此：

- 微动线程每轮**无条件**刷新自己的断言状态（激活则持有，暂停则清除）；
- 暂停时通过自动复位事件对象（`TEvent`）**立即唤醒**微动线程，让清除动作即时发生，而不是等到下一个 60 秒周期。

## 托盘菜单（三平台一致）

```
[✓] 保持清醒 (阻止闲置睡眠)
────────────────────────────
合盖行为(接电源时) ▸        ← Linux / macOS；Windows 无此项
[ ] 不动作(守卫拦截睡眠)
[•] 睡眠(系统默认)
[✓] 开机自启
────────────────────────────
语言 / Language ▸
[•] 跟随系统
[ ] English
[ ] 中文
────────────────────────────
关于 StayAwake
退出
```

- **任意键点击托盘图标都打开菜单**——点击图标本身绝不静默改变任何行为（这是刻意设计：状态变化必须经过用户的显式选择）；
- 勾选态在每次菜单打开前与真实状态同步；程序化同步会屏蔽信号/事件，防止「设状态→触发处理→再同步」的递归。

## 合盖行为（FR-7）

模式持久化为文本文件（`block` / `allow`），**写入与读取统一在共享核心**（`stayawake_common` 的 `LidMode`/`SetLidMode`），平台只实现「应用」动作。

### Linux：用户级 systemd 守卫

- `src/linux/lid-guard/install.sh` 安装 `ac-lid-guard.service`（用户服务，免 sudo）；
- 守卫进程在**插电**时持有 logind inhibitor 锁拦截合盖睡眠；电源状态直接读内核 `/sys`，因此免疫 GNOME/UPower 的电源误判（实测修复过 XPS 13 + Ubuntu 22.04 上「插着电却被按电池策略合盖睡眠」的案例）；
- 切到「不动作」时托盘调用 `systemctl --user enable --now` 自愈拉起服务；电池合盖始终系统默认。

### macOS：引导式管理员命令（仅 Apple Silicon）

- 实测结论：持有 IOKit `PreventSystemSleep` 断言时合盖仍进入 Clamshell Sleep（Apple Silicon、插电、断言先于合盖 4 分钟创建）——**用户态断言在当前 macOS 上不覆盖合盖路径**，生态内工具（Lunar / Amphetamine 等）同样只能依赖 `pmset disablesleep`；
- 菜单的勾选状态**直接反映 pmset 真实状态**：解析 `pmset -g` 的 `SleepDisabled` 标志行（经 libc `popen` 读取）。注意 `disablesleep` 设置**不会**出现在 `pmset -g custom` 的列表中（首版解析源即错于此，实测修正）；
- 合盖子菜单仅出现在 **Apple Silicon**（运行时 `uname -m` 探测）；Intel Mac 的合盖由 SMC 强制，命令无效，菜单直接隐藏（与 Windows 的处理一致）；
- 点选某一项时，若真实状态与之不符，**直接弹出 macOS 标准管理员密码框**（`AuthorizationExecuteWithPrivileges` 运行 `pmset -a disablesleep …`），输一次密码即生效，无需终端；复制命令的引导对话框保留为降级路径（授权 API 不可用时）；
- `disablesleep` 对电池同样生效（合盖一律不睡）；恢复使用 `sudo pmset -a disablesleep 0`（对话框中一并给出）。

### Windows：不提供

修改合盖策略需要管理员写入 `HKLM\SYSTEM\...\Power`，且管控机普遍隐藏该设置。菜单中直接不出现合盖项（共享菜单树的 `HasLid=False`）。

## 开机自启（FR-6）

统一接口 `EnsureAutoStart` / `IsAutoStartEnabled` / `DisableAutoStart`（Linux 另有 `EnableAutoStart`），各平台实现：

| 平台 | 机制 | 要点 |
| ---- | ---- | ---- |
| Windows | Registry API 写 `HKCU\...\Run` | 不调 `reg.exe`，无控制台窗口；路径变化时下次启动自动刷新 |
| Linux | `~/.config/autostart/stayawake.desktop` | GNOME 禁用是**就地**把 `X-GNOME-Autostart-enabled` 改为 `false`（文件保留），故区分两个语义：启动同步 `EnsureAutoStart`（路径不匹配才重写，**尊重**用户禁用）与托盘开关 `EnableAutoStart`（强制启用） |
| macOS | SMAppService 登录项（macOS 13+） | 即「系统设置 → 通用 → 登录项」；**不写文件**——管控机 `~/Library/LaunchAgents/` 常为 root 所有不可写，plist 方案会静默失败；macOS < 13 回退 plist 文件 |

## 单实例（FR-9）

| 平台 | 机制 |
| ---- | ---- |
| Windows | `CreateMutexA` 命名互斥体（`Local\stayawake_single_instance`） |
| Linux / macOS | `flock` 独占锁；锁文件优先 `$XDG_RUNTIME_DIR/stayawake.lock`，否则 `$TMPDIR(/tmp)/stayawake_<uid>.lock`（带 UID，多用户互不干扰）；进程崩溃内核自动释放 |

## 界面语言（FR-8）

- 语言偏好写 `lang` 文件（空 = 跟随系统）；跟随系统时按平台探测 UI 语言（Linux `LANG`、macOS `AppleLanguages`、Windows `GetUserDefaultUILanguage`），`zh-*` → 中文；
- 切换语言只重写文件 + 触发平台渲染器**重新标注**所有菜单项 + 刷新 tooltip，无需重启。

## 图标（FR-3）

- 全平台共用一份程序化像素画（`GenerateIconPixels`）：睁眼 = 激活（绿），闭眼带睫毛 = 暂停（灰）；3×3 超采样抗锯齿，参数化尺寸；
- 同一函数同时喂给 Windows `.ico` 生成器（`tools/gen_icon.pas`，16–256px）与各平台托盘，**保证永不漂移**；
- macOS 以 template 方式渲染（36px @ 18pt @2x），系统按菜单栏深浅自动着色；关于对话框用彩色 256px 版本。

## 配置文件（FR-10）

全部为「一行一值」的纯文本，位于平台用户配置目录下：

| 文件 | Linux | Windows | macOS |
| ---- | ---- | ---- | ---- |
| 语言 | `~/.config/stayawake/lang` | `%APPDATA%\stayawake\lang` | `~/Library/Application Support/stayawake/lang` |
| 合盖模式 | `~/.config/stayawake/lid-mode` | —（无此功能） | `~/Library/Application Support/stayawake/lid-mode` |
