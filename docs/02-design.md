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
合盖时 ▸                    ← 带电池的设备（无电池整组隐藏）
  [接电源]                  ← 灰色小节标题
  [✓] 保持运行(合盖不休眠)
  ────────────────────
  [用电池]
  [•] 合盖睡眠(默认)
  [ ] 保持清醒 1 分钟后睡眠   ← 5/15/30/60 分钟同组
  [ ] 盒盖不睡(直到没电关机)
  ────────────────────
  [低电量]
  [•] 15% 睡眠(默认)         ← 关闭 / 10 / 20 / 25% 同组
[✓] 开机自启
────────────────────────────
语言 / Language ▸
[•] 跟随系统
[ ] English
[ ] 中文
────────────────────────────
立即睡眠                    ← macOS / Linux
────────────────────────────
关于 StayAwake
退出
```

- **任意键点击托盘图标都打开菜单**——点击图标本身绝不静默改变任何行为（这是刻意设计：状态变化必须经过用户的显式选择）；
- 勾选态在每次菜单打开前与真实状态同步；程序化同步会屏蔽信号/事件，防止「设状态→触发处理→再同步」的递归。

## 合盖行为（FR-7）

三平台共用同一套**配置、菜单与决策引擎**，平台只实现「探测 / 执行 / 强制」三件事：

- **配置**（`stayawake_common`）：`lid-ac`（`awake`/`default`，缺省 awake）、`lid-battery-mins`（`0`=合盖即睡、`1..60` 分钟、`-1`=直到耗尽，缺省 0）、`lid-battery-pct`（底线，缺省 15，`0`=关闭）。旧的 `lid-mode`（`block`/`allow`）已迁移废弃：`block` → `lid-ac=awake`+`mins=15`，`allow` → `lid-ac=default`（与 macOS 迁移同一套映射）；
- **决策引擎**（`stayawake_lidpolicy`，纯函数可单测）：`LidEngineTick` 维护合盖片段状态（合盖起点计时、开盖复位、一次性触发标志），每 tick 调 `LidDecide` 产出「强制档位 + 是否立即睡」。电池侧两个睡眠条件赛跑，先到先得：定时器到期、电量触底（底线与定时模式无关，也约束 `-1` 档；电量未知永不触发）；
- **平台差异**用一个布尔概括：`KernelHandlesClose`。macOS/Linux 内核会处理合盖事件（clamshell / logind），`mins=0` 的「合盖即睡」交给 OS，引擎只在电池侧主动入睡；Windows 内核盖子动作被安装期一次性禁用，`KernelHandlesClose=False`，所有「应睡」的合盖都由应用主动执行（`ldrClose` 分支），且电池定时/底线不受「保持运行」勾选约束。

| 平台 | 探测 | 执行（主动入睡） | 强制（拦合盖事件） |
| ---- | ---- | ---- | ---- |
| Linux | `/proc/acpi/button/lid/*/state`（无则视为无盖）+ `/sys` 电源电量，2s tick | `systemctl suspend`（免提权） | 守卫脚本持 logind inhibitor，见下 |
| macOS | IORegistry `AppleClamshellState` 轮询 + `pmset -g batt`（缓存 5 tick） | `pmset -b disablesleep 0` + `pmset sleepnow` | `pmset disablesleep` 按电源分档，每 tick 变化才重申（自愈外部干扰） |
| Windows | `WM_POWERBROADCAST` 合盖事件推送 + `GetSystemPowerStatus` | `SetSuspendState`（`SeShutdownPrivilege` 免管理员） | 安装期 `powercfg LIDACTION 0`（静态，运行期无操作） |

### Linux：用户级 systemd 守卫

- 守卫进程（`ac-lid-guard.service`，用户服务免 sudo）**不需要知道合盖状态**——inhibit 与否可由「配置文件 + 电源状态」直接算出，脚本每 3s 重读配置：
  - 插电且 `lid-ac=awake`（缺省）→ 持有 `sleep:handle-lid-switch` inhibitor（合盖不动作；连空闲睡眠一并持有，保住「合盖无头用法」的历史行为）；
  - 电池且 `lid-ac=awake` 且 `lid-battery-mins≠0` → 仅持 `handle-lid-switch` inhibitor（只拦合盖事件，让定时窗口内的空闲睡眠先行——语义同 macOS「至多保持 N 分钟」，也避免自家 inhibitor 挡住 `systemctl suspend`；`lid-ac` 门控与引擎侧一致：插电「保持运行」勾选是整个合盖策略的总开关）；
  - 其余组合不持锁，系统默认行为；
- 托盘启动即幂等确保守卫安装并运行（`HookApplyLidMode`），内嵌组件与已安装内容不一致时原位升级脚本；电源状态直接读内核 `/sys`，免疫 GNOME/UPower 的电源误判（实测修复过 XPS 13 + Ubuntu 22.04 上「插着电却被按电池策略合盖睡眠」的案例）；
- 首次运行（无任何 lid 配置）写入共享默认 `lid-ac=awake` 并弹一次 libnotify 气泡告知；手动安装器 `lid-guard/install.sh` 保留，行为等同。

### macOS：pmset disablesleep + 应用菜单「立即睡眠」

三类机制在同一台 Apple Silicon 实机上逐一验证：

1. **电源断言**：持有 IOKit `PreventSystemSleep` 时合盖仍进入 Clamshell Sleep——无效；
2. **睡眠协商取消**：读 IORegistry 的 `AppleClamshellState`（powerd 自己的合盖标志，判定精准）并应答 `IOCancelPowerChange`——powerd 仅将睡眠**延迟约 5 秒**后照常执行，且不再重新询问应用——无效；
3. **`pmset disablesleep`**：**有效**，但会连 Apple 菜单「睡眠」一并禁用。

**最终方案（用户确认）**：接受第 3 项的代价，睡眠入口改由应用提供；切换与「立即睡眠」通过一次性安装的白名单 sudoers 条目实现**永久免密**（`src/macos/guard/install.sh`，sudo 运行一次，卸载用 `uninstall.sh`）——

- 合盖菜单按电源分档断言 `disablesleep`，勾选状态反映共享配置文件；
- 首次点选合盖项且守护未安装时弹出引导对话框，给出一次性命令并自动复制到剪贴板；
- **菜单「立即睡眠」**：`pmset sleepnow`（免 root，实测在 `disablesleep 1` 下依然生效，日志 `Software Sleep pid=…` 为证）——系统菜单「睡眠」失效后，这就是休眠入口；
- 睡眠协商（配合逻辑）保留：显式睡眠（含 `sleepnow`）发生时立即应答放行并释放防睡断言，唤醒后自动重建（实测 4ms 应答、无超时记录）。

### Windows：一次性管理员 + 全程免管理员运行

运行期策略全部免管理员（`SetSuspendState` 只需用户令牌里默认持有的 `SeShutdownPrivilege`）；唯一的管理员步骤是安装期把内核盖子动作设为「不采取任何操作」（`powercfg /setacvalueindex … LIDACTION 0` + `/setdcvalueindex … 0`），否则内核在应用介入前就睡了。此后合盖事件经 `WM_POWERBROADCAST`（`GUID_LIDSWITCH_STATE_CHANGE`，需隐藏的顶级窗口接收）推送给应用。

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
| 插电合盖 | `~/.config/stayawake/lid-ac` | `%APPDATA%\stayawake\lid-ac` | `~/Library/Application Support/stayawake/lid-ac` |
| 电池合盖定时 | `~/.config/stayawake/lid-battery-mins` | `%APPDATA%\stayawake\lid-battery-mins` | `~/Library/Application Support/stayawake/lid-battery-mins` |
| 电量底线 | `~/.config/stayawake/lid-battery-pct` | `%APPDATA%\stayawake\lid-battery-pct` | `~/Library/Application Support/stayawake/lid-battery-pct` |
| 旧合盖模式（迁移废弃） | `~/.config/stayawake/lid-mode` | — | `~/Library/Application Support/stayawake/lid-mode` |
