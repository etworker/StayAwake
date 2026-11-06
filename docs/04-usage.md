# 04 使用

## 安装与启动

### Windows

从 [Releases](https://github.com/etworker/StayAwake/releases) 下载 `stayawake-win64.exe`（64 位，推荐）或 `stayawake-win32.exe`，放到任意固定位置（如 `D:\Tools\`）后双击运行。程序只出现在系统托盘（可能折叠在 `^` 里），无窗口。

### macOS

按芯片选择 zip：Apple Silicon（M 系列）用 `StayAwake-macos-arm64.zip`，Intel 用 `StayAwake-macos-x86_64.zip`。解压出 `StayAwake.app`，拖入「应用程序」后双击启动。

- 程序是**菜单栏代理**（`LSUIElement`）：不进 Dock、不弹终端，只在顶栏显示一只眼睛；
- 从源码构建的产物位于 `out/macos/<arch>/StayAwake.app`，`open out/macos/StayAwake.app` 即可启动。

### Linux

下载 `stayawake-linux-x86_64.tar.gz`（或 aarch64），解压出 `stayawake` 直接运行（需要 GTK2 运行时与 X11）：

```sh
tar xzf stayawake-linux-x86_64.tar.gz
./stayawake
```

如需手动安装/卸载用户级合盖守卫（免 sudo），运行包内 `lid-guard/install.sh` / `uninstall.sh`；通常无需手动操作——托盘启动时会自动确保守卫就绪。

## 托盘菜单

左键或右键点击图标都会打开同一个菜单（点击图标本身不会静默改变任何行为）：

- **保持清醒 (阻止闲置睡眠)**：勾选 = 阻止空闲睡眠/熄屏/锁屏；取消 = 系统按自然策略睡眠。启动默认为勾选，切换实时生效；
- **合盖时**（三平台一致，**仅在带电池的设备上显示**——台式机、Mac mini / Mac Studio 等无电池无盖设备自动隐藏，托盘与后台逻辑均不涉及合盖），扁平单层无三级嵌套：
  - **[接电源]**：勾选「保持运行(合盖不休眠)」。Linux 与 macOS 默认开启（Linux 首次运行会弹气泡说明这一行为）；
  - **[用电池]**：单选「合盖睡眠(默认)」/ 保持清醒 1/5/15/30/60 分钟后自动入睡 /「盒盖不睡(直到没电关机)」；
  - **[低电量]**：电量底线 10/15/20/25% 或「关闭」。电池合盖期间电量跌到底线即入睡，先于定时器；
  - 平台差异只在**执行层**：
    - Linux：用户级守卫持有 logind inhibitor 拦截合盖事件（读内核 `/sys` 判断电源，免疫 UPower 误判）；电池定时到期/到线由应用 `systemctl suspend`（免提权）；日志 `/tmp/stayawake_power.log`；
    - macOS：`pmset disablesleep` 按电源分档，一次性 sudoers 白名单永久免密；睡眠入口用菜单「立即睡眠」；日志 `/tmp/stayawake_power.log`；
    - Windows：需一次性管理员把「关闭盖子时」设为「不采取任何操作」（手动 `powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0` 与 `/setdcvalueindex ... 0`），之后全程免管理员——合盖事件由应用经电源通知感知，到期主动 `SetSuspendState`；日志 `%TEMP%\stayawake_lid.log`；
- **语言 / Language**：子菜单自动列出发现的语言包（默认随附 English / 中文）。切换后所有菜单文字、托盘悬浮提示、关于对话框立即更新；
- **添加语言**：复制一份语言包改名为 `stayawake.<代码>.lang`（如 `stayawake.de.lang`），翻译右侧的值，放入**用户语言包目录**并重启，菜单自动出现该语言：Linux `~/.config/stayawake/langs/`、Windows `%APPDATA%\stayawake\langs\`、macOS `~/Library/Application Support/stayawake/langs/`（此目录更新应用不会丢失）。同名代码会覆盖随附语言包；缺失的键自动回退内置英文，不完整的翻译不会出现空白。文件编码支持 UTF-8（推荐，可有/可无 BOM）与系统 ANSI 代码页（如简体中文 Windows 下的 GB2312/GBK），按内容自动识别。随附语言包则位于应用目录（Windows/Linux 为 exe 旁，macOS 为 .app 内 `Contents/Resources`）；
- **立即睡眠**（macOS / Linux）：macOS 在 `pmset disablesleep` 开启期间系统菜单「睡眠」不可用，休眠请点本菜单的「立即睡眠」；Linux 直接 `systemctl suspend`；
- **开机自启**：勾选后登录时自动运行。三平台分别为：Windows 注册表 Run 键、Linux XDG autostart、macOS 登录项（系统设置 → 通用 → 登录项 中可见）；
- **关于 / 退出**。

> macOS 顶栏图标为全彩渲染（与 Windows/Linux 同一套绿色眼睛）：睁眼 = 激活，闭眼（灰色）= 暂停。

## 配置文件

| 设置 | Linux | Windows | macOS |
| ---- | ---- | ---- | ---- |
| 语言 | `~/.config/stayawake/lang` | `%APPDATA%\stayawake\lang` | `~/Library/Application Support/stayawake/lang` |
| 插电合盖 | `~/.config/stayawake/lid-ac`（`awake`/`default`） | `%APPDATA%\stayawake\lid-ac` | `~/Library/Application Support/stayawake/lid-ac` |
| 电池合盖定时 | `~/.config/stayawake/lid-battery-mins`（`0`/`1`/`5`/`15`/`30`/`60`/`-1`） | `%APPDATA%\stayawake\lid-battery-mins` | `~/Library/Application Support/stayawake/lid-battery-mins` |
| 电量底线 | `~/.config/stayawake/lid-battery-pct`（`0`/`10`/`15`/`20`/`25`） | `%APPDATA%\stayawake\lid-battery-pct` | `~/Library/Application Support/stayawake/lid-battery-pct` |
| 旧合盖模式（已迁移废弃） | `~/.config/stayawake/lid-mode` | — | `~/Library/Application Support/stayawake/lid-mode` |

均为纯文本，一般通过菜单修改；手动编辑后守卫/策略数秒内自动跟随，菜单状态重开即同步。

## 常见问题

**托盘图标不见了？**
Windows 检查托盘折叠区；重复启动会因单实例静默退出（先确认已有实例未退出）。Linux 需要 GNOME/KDE 等带托盘扩展的桌面（Wayland 下需支持 AppIndicator 的环境）。

**开机自启勾选了但重启没启动？**
Linux：确认桌面环境支持 XDG autostart；GNOME 下被「启动应用程序」禁用过的条目需在托盘菜单重新勾选一次。macOS：管理型机器首次注册可能需要在「系统设置 → 通用 → 登录项」里手动允许。

**合盖还是睡眠了？**
Windows：先完成一次性管理员授权（`powercfg` 把盖子动作设为「不采取任何操作」）。macOS：菜单选「保持唤醒」或电池时长会**弹出引导对话框**（内含一次性管理员命令，可一键复制到终端执行）；执行后一切免密，期间系统菜单「睡眠」不可用，休眠请用本应用菜单的「立即睡眠」；恢复合盖睡眠选「系统默认」。Linux：托盘启动会自动安装并拉起守卫（也可手动跑包内 `lid-guard/install.sh`）；用电池时守卫按设计让位给系统默认（合盖即睡），电池定时档需在菜单选择后守卫才会在电池下拦截合盖事件。

**怎么彻底退出？**
托盘菜单 → 退出。Linux/macOS 下锁文件由内核自动释放，不会留下僵尸锁。

## 限制速览（详见 01-requirements）

- 只阻止「空闲导致」的睡眠，不拦截显式电源动作（电源键、开始菜单睡眠）；
- 合盖拦截：Linux ✅（插电默认开启；电池定时档需在菜单选择）、macOS ✅（仅 Apple Silicon，一次性授权后永久免密）、Windows ✅（一次性管理员把盖子动作设为「不采取任何操作」，此后免管理员）；
- 全部功能免 root / 免管理员（Windows 的一次性授权除外）。
