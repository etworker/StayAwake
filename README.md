# stayawake

一个用 Free Pascal 编写的托盘应用，用于防止系统因「空闲」而进入睡眠 / 熄屏 / 锁屏。Windows 下通过 `SetThreadExecutionState`（`ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED`）告知系统保持唤醒，并辅以每 60 秒移动鼠标 1 像素（再移回）的「保险」动作（与 Rust 版行为一致）。

## 下载

预编译二进制（无需安装 FPC）可在 [Releases](https://github.com/etworker/StayAwake/releases) 页面获取：

- Windows：`stayawake-win64.exe`（64 位，推荐）、`stayawake-win32.exe`（32 位）
- macOS：`StayAwake-macos-arm64.zip`（Apple Silicon）、`StayAwake-macos-x86_64.zip`（Intel）
  - 解压后按芯片选择对应的 `StayAwake.app` 双击启动。打包为菜单栏代理程序（`LSUIElement=true`），不弹终端、不进 Dock；左键单击菜单栏图标 = 切换开/关，右键 = 菜单。
- Linux：需按「编译」一节从源码自构建（尚未提供预编译包）。

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

> 说明：Windows 版（32/64 位）已在本地编译并运行验证；macOS 版已在 Apple Silicon（aarch64-darwin，FPC 3.2.2）上实际编译并运行验证（托盘、鼠标微动、单实例、开机自启均正常；睡眠抑制通过 `IOPMAssertion` 实现）。Linux 版代码按 FPC 3.2.2 源码（gtk2/gtk2ext）逐一核对过 API，但因缺少对应环境，尚未在实际目标机上编译验证。

## 依赖

- [Free Pascal Compiler 3.2.2+](https://www.freepascal.org/)（需在 `PATH` 中，或通过 `FPC` 环境变量指定完整路径）。
- Windows：32 位与 64 位各需对应的 FPC 工具链（`i386-win32` / `x86_64-win64`，两者都装则脚本自动按目标选择）。
- Linux：需已安装 GTK2 运行时（`libgtk2.0-0` 等）；编译不依赖 GTK 头文件/静态库（FPC 的 gtk2 单元在运行时动态加载）。
- macOS：需 Xcode Command Line Tools（链接 Cocoa 框架）。

## 编译

构建产物按平台输出到 `out/<平台>/`，编译中间文件（`.ppu`/`.o`）放在可执行程序旁的 `units` 目录，不污染源码目录。Windows 为 `out/windows/i386`（32 位）、`out/windows/x86_64`（64 位）；Linux 为 `out/linux/<架构>/`（`<架构>` 为 `x86_64` / `i386` / `aarch64` / `arm`，二进制 `stayawake` + 旁边 `units/`）；macOS 为 `out/macos/<架构>/StayAwake.app`，架构目录为 `arm64`（Apple Silicon）与 `x86_64`（Intel），各自的 `units/` 在 `.app` 同目录。`exe` 图标由 `tools/gen_icon.pas` 生成到 `assets/stayawake.ico`（缺失时自动生成）。

编译脚本按平台拆分，互不沾染：

```bat
build.cmd            :: Windows（默认 64 位；win32 / win64 可选）
```

```sh
chmod +x build-macos.sh build-linux.sh clean.sh

# Linux（在 Linux 机器上运行，产物输出到 out/linux/<架构>/）
./build-linux.sh            # 本机架构（自动探测 x86_64 / i386 / aarch64 / arm）
./build-linux.sh aarch64    # 交叉编译到 ARM64（需对应跨编译器/RTL）

# macOS：默认同时构建两个架构目录（arm64 + x86_64），各自一个 .app
./build-macos.sh                 # 构建 out/macos/arm64/StayAwake.app 与 out/macos/x86_64/StayAwake.app
./build-macos.sh arm64           # 仅 arm64（Apple Silicon）
./build-macos.sh x86_64          # 仅 x86_64（Intel，需已安装 x86_64-darwin RTL 与 ppcx64 交叉编译器）
./build-macos.sh universal       # 把两个切片合成一个通用二进制 fat app（约 7.4MB）

# 清理：删除 out/ 下所有编译中间文件（units 目录与 *.o/*.ppu），保留最终二进制/.app
./clean.sh
```

> **分两个架构目录（而非通用二进制）**：每个 `.app` 只含单架构可执行文件，分别放在 `out/macos/arm64/` 与 `out/macos/x86_64/`。文件体积最小（每个约 3.7MB，无冗余切片），但需分发/选择两个文件。若想一份文件通吃两种芯片，可改用 `./build-macos.sh universal` 出通用二进制（约 7.4MB）。两种做法行为完全一致，按分发习惯选择即可。

> **x86_64 交叉编译环境**：Homebrew 版 FPC 默认只带本机（arm64）RTL 与编译器。要编出 `x86_64` 那份，需安装 `x86_64-darwin` 的 FPC RTL 与交叉编译器 `ppcx64`（本机已装好：RTL 在 `…/fpc/3.2.2/units/x86_64-darwin`，编译器在 `/opt/homebrew/bin/ppcx64`）。`ppcx64` 是 x86_64 程序，在 Apple Silicon 上经 Rosetta 2 运行，故 x86_64 那次编译较慢。

> **为什么是 `.app` 包**：裸 Mach-O 可执行文件被双击时会由 Terminal.app 当作命令行程序启动（弹出终端窗口）。打包成 `StayAwake.app` 并设置 `LSUIElement=true` 后，它作为菜单栏代理程序运行，双击不再弹终端、也不进 Dock。

> 架构说明：源码与架构无关。macOS 现代系统只有 64 位（Intel x86_64 与 Apple Silicon aarch64，均为 64 位），不再区分 32 位；两套构建产物共用同一份 macOS 平台源码。

## 使用

macOS 按芯片选择对应目录下的 `StayAwake.app` 双击启动即可：

```sh
# Apple Silicon（M1/M2…）
open out/macos/arm64/StayAwake.app

# Intel Mac
open out/macos/x86_64/StayAwake.app
```

`LSUIElement=true` 使程序作为菜单栏（代理）程序运行，不显示在 Dock。左键单击菜单栏图标 = 切换开/关；右键 = 弹出菜单。

- 左键单击菜单栏图标 = 切换开/关；右键 = 弹出菜单。
- 菜单「Start on Login」可随时开启/关闭开机自启（勾选 = 已开启）。
- 单实例：重复启动会立即静默退出。

## 项目结构

```
stayawake/
├── build.cmd               # Windows 构建脚本（默认 64 位；win32 / win64 可选）
├── build-macos.sh          # macOS 构建脚本（默认双架构目录；arm64 / x86_64 / universal 可选）
├── build-linux.sh          # Linux 构建脚本（默认本机架构；可指定 arch 交叉编译）
├── clean.sh                # 清理 out/ 下编译中间文件（保留最终二进制/.app）
├── release.sh              # 将 out/windows/<arch> 的 exe 上传到 GitHub Release（gh 需已登录）
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
    ├── windows/i386/ windows/x86_64/   # Windows 分位数产物（stayawake.exe + units/）
    ├── linux/<arch>/        # Linux 产物（stayawake + units/）
    └── macos/<arch>/        # macOS：arm64/ 与 x86_64/ 各一个 StayAwake.app（+ 同目录 units/）
```

每个平台目录内四个单元，接口一致，主程序无需感知平台差异：

| 单元 | 职责 |
| ---- | ---- |
| `stayawake_single.pas` | `AcquireSingleInstance`：单实例锁 |
| `stayawake_mover.pas` | `StartMoverThread`：定时移动鼠标的线程（`NudgeMouse`） |
| `stayawake_tray.pas` | `TrayCreate`：托盘图标 + 右键菜单 + 事件循环 |
| `stayawake_autostart.pas` | `EnsureAutoStart` / `IsAutoStartEnabled` / `DisableAutoStart` |