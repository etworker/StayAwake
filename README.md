# stayawake

一个用 Free Pascal 编写的托盘应用，用于防止系统因「空闲」而进入睡眠 / 熄屏 / 锁屏。Windows 下通过 `SetThreadExecutionState`（`ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED`）告知系统保持唤醒，并辅以每 60 秒移动鼠标 1 像素（再移回）的「保险」动作（与 Rust 版行为一致）。

## 下载

Windows 预编译 exe（无需安装 FPC）可在 [Releases](https://github.com/etworker/StayAwake/releases) 页面获取：

- `stayawake-win64.exe`（64 位，推荐）
- `stayawake-win32.exe`（32 位）

> 目前仅提供 Windows 构建；Linux / macOS 需自行按「编译」一节从源码构建。

## 功能

- 托盘图标：绿色 = 正在防止睡眠；灰色（两条竖杠）= 已暂停。
- 右键菜单：
  - **Start Awake / Stop Awake**：启动 / 停止（按当前状态自动置灰）。
  - **Start on Login**：开机自启开关（带勾选状态，随时可切换）。
  - **About...**：关于对话框。
  - **Quit**：退出。
- 左键单击托盘图标：在启动 / 停止之间切换。
- 启动参数 `--start-active`：以「激活」状态启动（**默认即为激活状态**，此参数可显式确保）。
- **单实例**：同一用户下只允许运行一个实例（Windows 用命名互斥体；Linux/macOS 用 `/tmp` 下的 `flock` 文件锁）。
- **exe 图标**：Windows 可执行文件内置图标（绿色圆形，与托盘一致，含 16/32/48/64/256 多尺寸）。

## 限制与注意事项

本程序只能阻止「空闲导致」的睡眠 / 熄屏 / 锁屏，**不能**拦截由显式电源动作触发的行为：

- **合盖不防睡**：关闭笔记本盖子时是否睡眠 / 休眠 / 锁屏，由 Windows 电源计划中「关闭盖子时」的动作决定，属于*显式*电源动作。`SetThreadExecutionState` 无法覆盖它，本程序也无权拦截。只要该项设为「睡眠」或「休眠」，合盖必睡。
- **改合盖策略需要管理员**：把「关闭盖子时」改为「不采取任何操作」属于修改系统电源策略，写入 `HKLM\SYSTEM\CurrentControlSet\Control\Power`，**需要管理员权限**。标准用户会被拒绝（Access is denied）。在受企业镜像 / 域控管理的机器上，该设置可能根本不向用户暴露，即便拿到 GUID 也无法写入。
- **仅在开盖时有效**：本程序在「盖子打开、正常使用或闲置」时保持系统常亮；一旦合盖且策略为睡眠，效果即终止。

> 非管理员用户的现实约束：本机已验证当前账户为普通用户（非 `Administrators`），且「电源按钮和盖子」子组中仅暴露「开始菜单电源按钮」一项，「关闭盖子」设置不可见。因此在该环境下，**合盖防睡无解**——只能保持开盖，或外接显示器并切到「仅第二屏」（部分机型仍可能睡眠），或取得管理员后修改电源策略。

## 平台支持

三个平台，一份主程序入口，公共逻辑共享；**每个平台在 `src/` 下有独立目录，各自实现该平台的托盘 / 鼠标移动 / 开机自启 / 单实例**，文件内不再有 `$IFDEF` 条件编译，平台代码通过编译时的单元搜索路径（`-Fu`）选择。

| 平台 | 目录 | 托盘实现 | 移动鼠标实现 |
| ---- | ---- | -------- | ------------ |
| Windows | `src/win/` | `Shell_NotifyIconA` + 隐藏消息窗口 + DIB 图标 | `SetCursorPos` |
| Linux | `src/linux/` | GTK2 `GtkStatusIcon` | 动态加载 `libX11.so.6` / `libXtst.so.6`（`XTestFakeMotionEvent`） |
| macOS | `src/macos/` | Cocoa `NSStatusItem` + 菜单 | CoreGraphics `CGEventCreateMouseEvent` |

- 开机自启：Windows 用 Windows Registry API（`TRegistry`）直接写入 `HKCU\...\CurrentVersion\Run`，不调用 `reg.exe`，因此启动时不产生控制台窗口、也无额外进程开销；Linux 写 `~/.config/autostart/stayawake.desktop`；macOS 写 `~/Library/LaunchAgents/com.stayawake.plist`。
  - 自启路径取自当前运行 exe 自身的位置（`ExpandFileName(ParamStr(0))`）。若移动了 exe，重新运行一次即可自动刷新注册表/启动项中的路径。
- 单实例：Windows 用 `CreateMutexA`（命名互斥体）；Linux/macOS 用 `flock` 独占锁（进程异常退出时内核自动释放，不会留下僵尸锁）。

> 说明：Windows 版（32/64 位）已在本地编译并运行验证；Linux / macOS 版代码按 FPC 3.2.2 源码（gtk2/gtk2ext、cocoaint）逐一核对过 API，但因缺少交叉编译环境，尚未在实际目标机上编译验证。

## 依赖

- [Free Pascal Compiler 3.2.2+](https://www.freepascal.org/)（需在 `PATH` 中，或通过 `FPC` 环境变量指定完整路径）。
- Windows：32 位与 64 位各需对应的 FPC 工具链（`i386-win32` / `x86_64-win64`，两者都装则脚本自动按目标选择）。
- Linux：需已安装 GTK2 运行时（`libgtk2.0-0` 等）；编译不依赖 GTK 头文件/静态库（FPC 的 gtk2 单元在运行时动态加载）。
- macOS：需 Xcode Command Line Tools（链接 Cocoa 框架）。

## 编译

构建产物统一输出到 `out/`（exe 与 `.ppu/.o` 分开），不污染源码目录。exe 图标由 `tools/gen_icon.pas` 生成到 `assets/stayawake.ico`（缺失时自动生成）。

Windows（生成 `out/win64/stayawake.exe` 或 `out/win32/stayawake.exe`）：

```bat
build.cmd            :: 默认 64 位
build.cmd win32      :: 32 位
build.cmd win64      :: 64 位
```

Linux / macOS（生成 `out/stayawake`）：

```sh
chmod +x build.sh
./build.sh linux            # Linux（本机架构）
./build.sh linux aarch64    # 交叉编译到 ARM64（需对应跨编译器/RTL）
./build.sh macos            # macOS（Intel 或 Apple Silicon）
```

> 架构说明：源码与架构无关。Windows 分 `win32` / `win64` 两个产物目录（对应 FPC 的 `i386-win32` / `x86_64-win64` 工具链）。Linux 可用 `-P` 指定 i386 / x86_64 / aarch64 / arm 等目标。macOS 现代系统只有 64 位（Intel x86_64 与 Apple Silicon aarch64，均为 64 位），不再区分 32 位。

## 使用

```sh
# 普通启动（默认即 Working / 激活状态）
out/stayawake

# 以激活状态启动
out/stayawake --start-active
```

- 左键单击托盘图标 = 切换开/关；右键 = 弹出菜单。
- 菜单「Start on Login」可随时开启/关闭开机自启（勾选 = 已开启）。
- 单实例：重复启动会立即静默退出。

## 项目结构

```
stayawake/
├── build.cmd / build.sh     # 构建脚本（平台目录在脚本内以 -Fu 指定）
├── assets/
│   └── stayawake.ico       # 生成的多尺寸 exe 图标
├── tools/
│   └── gen_icon.pas         # 图标生成器（与托盘同款像素画）
├── src/
│   ├── stayawake.lpr       # 主程序：单实例 → 参数解析 → 自启 → 线程 → 托盘
│   ├── stayawake.rc        # (Windows) 图标资源定义
│   ├── common/              # 跨平台共享：常量、全局状态、图标像素生成
│   │   └── stayawake_common.pas
│   ├── win/                 # Windows：mover / tray / autostart / single
│   ├── linux/               # Linux：mover / tray / autostart / single
│   └── macos/               # macOS：mover / tray / autostart / single
└── out/                     # 构建产物
    ├── win32/ win64/        # Windows 分位数产物（stayawake.exe + units/）
    └── stayawake           # (Linux/macOS) 可执行文件 + units/
```

每个平台目录内四个单元，接口一致，主程序无需感知平台差异：

| 单元 | 职责 |
| ---- | ---- |
| `stayawake_single.pas` | `AcquireSingleInstance`：单实例锁 |
| `stayawake_mover.pas` | `StartMoverThread`：定时移动鼠标的线程（`NudgeMouse`） |
| `stayawake_tray.pas` | `TrayCreate`：托盘图标 + 右键菜单 + 事件循环 |
| `stayawake_autostart.pas` | `EnsureAutoStart` / `IsAutoStartEnabled` / `DisableAutoStart` |