# stayawake

一个用 Free Pascal 编写的托盘应用，用于防止系统因「空闲」而进入睡眠 / 熄屏 / 锁屏。Windows 下通过 `SetThreadExecutionState`（`ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED`）告知系统保持唤醒，并辅以每 60 秒移动鼠标 1 像素（再移回）的「保险」动作（与 Rust 版行为一致）。

## 下载

预编译二进制（无需安装 FPC）可在 [Releases](https://github.com/etworker/StayAwake/releases) 页面获取：

- Windows：`stayawake-win64.exe`（64 位，推荐）、`stayawake-win32.exe`（32 位）
- macOS：`StayAwake-macos-arm64.zip`（Apple Silicon）、`StayAwake-macos-x86_64.zip`（Intel）
  - 解压后按芯片选择对应的 `StayAwake.app` 双击启动。打包为菜单栏代理程序（`LSUIElement=true`），不弹终端、不进 Dock；左键单击菜单栏图标 = 切换开/关，右键 = 菜单。
- Linux：`stayawake-linux-x86_64.tar.gz`（64 位）、`stayawake-linux-aarch64.tar.gz`（ARM64）
  - 解压出 `stayawake` 可执行文件直接运行（需要 GTK2 运行时 `libgtk2.0-0` 与 X11/libXtst）。
  - 包内 `lid-guard/` 目录为**合盖行为组件**：运行其中的 `lid-guard/install.sh`（用户级，无需 root）后，
    托盘菜单出现「合盖行为(接电源时)」子菜单，可切换插电合盖「不动作 / 睡眠」（详见 [linux/lid-guard/](linux/lid-guard/)）。

## 功能

- 托盘图标：绿色 = 正在防止睡眠；灰色（两条竖杠）= 已暂停（系统可正常睡眠）。
- 菜单（**左键或右键单击托盘图标均可打开**；点击图标本身不会静默改变任何行为）：
  - **保持清醒 (Keep Awake)**：单条勾选项。勾选 = 阻止闲置睡眠；取消勾选 = 该睡就睡，实时生效。
  - **合盖行为(接电源时)** 子菜单（Linux）：「不动作(守卫拦截睡眠)」/「睡眠(系统默认)」二选一，免密码即时切换。
  - **语言 / Language** 子菜单：跟随系统 / English / 中文，切换后全部菜单文案即时更新。
  - **开机自启**：勾选开关（点击后立即反映真实状态）。
  - **关于 StayAwake / 退出**。
- 启动即以「激活」状态运行（无命令行参数，开箱即用）。
- **单实例**：同一用户下只允许运行一个实例（Windows 用命名互斥体；Linux/macOS 用 `flock` 文件锁，优先位于 `$XDG_RUNTIME_DIR`，否则退回 `/tmp` 下带 UID 的文件名，因此多用户机器上互不干扰）。
- **合盖行为（Linux）**：托盘菜单新增「Lid Close on AC」子菜单，可在 **Do Nothing (Guard)** 与 **Suspend** 之间切换插电时的合盖行为。守卫以用户级 systemd 服务运行（**无需 root**），直接读取内核（`/sys`）的电源状态，因此**免疫 UPower 误判**——即使 GNOME 误以为在使用电池，插电合盖也不会睡眠。电池合盖始终维持系统默认。详见 [linux/lid-guard/](linux/lid-guard/)。
- **exe 图标**：Windows 可执行文件内置图标（绿色圆形，与托盘一致，含 16/32/48/64/256 多尺寸）。

## 限制与注意事项

本程序对「空闲导致」的睡眠 / 熄屏 / 锁屏的拦截是全平台的；对「合盖」这类显式电源动作，各平台能力不同：

- **Linux：已支持**。`linux/lid-guard/` 组件提供用户级 systemd 服务 + 托盘子菜单（「Lid Close on AC」）：
  - 插电合盖可选「不动作」或「睡眠」，电池合盖始终维持系统默认；
  - 守卫直接读取内核（`/sys`）的电源状态，**免疫 UPower 误判**——已实际修复「插着电、GNOME 却按电池策略在合盖时睡眠」的案例（XPS 13 L322X / Ubuntu 22.04）；
  - 安装：`linux/lid-guard/install.sh`（用户级，无需 sudo）；卸载：同目录 `uninstall.sh`。
- **Windows：合盖防睡需要管理员**。把「关闭盖子时」改为「不采取任何操作」属于修改系统电源策略，写入 `HKLM\SYSTEM\CurrentControlSet\Control\Power`，**需要管理员权限**。标准用户会被拒绝（Access is denied）。在受企业镜像 / 域控管理的机器上，该设置可能根本不向用户暴露，即便拿到 GUID 也无法写入。
- **macOS：不支持**。苹果不提供合盖行为的用户级配置，第三方内核级补丁存在安全风险，本项目不予采用。
- **仅在开盖时有效（Windows/macOS）**：这两个平台的托盘程序只在「盖子打开、正常使用或闲置」时保持系统常亮；一旦合盖且策略为睡眠，效果即终止。

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
- 合盖守卫（Linux）：`linux/lid-guard/` — 用户级 systemd 服务 + 托盘子菜单，模式文件 `~/.config/stayawake/lid-mode`（`block` / `allow`），详见上文「功能」与「限制与注意事项」。

> 说明：Windows 版（32/64 位）已在本地编译并运行验证；macOS 版已在 Apple Silicon（aarch64-darwin，FPC 3.2.2）上实际编译并运行验证（托盘、鼠标微动、单实例、开机自启均正常；睡眠抑制通过 `IOPMAssertion` 实现），x86_64 macOS 为 Rosetta 交叉编译产物。Linux 版（x86_64）已在 Ubuntu 22.04 / GNOME (X11) 实机运行验证（托盘、鼠标微动、单实例、开机自启正常），合盖守卫组件亦已实测（模式切换、抑制锁、实机合盖拦截）。

## 依赖

- [Free Pascal Compiler 3.2.2+](https://www.freepascal.org/)（需在 `PATH` 中，或通过 `FPC` 环境变量指定完整路径）。
- Windows：32 位与 64 位各需对应的 FPC 工具链（`i386-win32` / `x86_64-win64`，两者都装则脚本自动按目标选择）。
- Linux：需已安装 GTK2 运行时（`libgtk2.0-0` 等）；编译不依赖 GTK 头文件/静态库（FPC 的 gtk2 单元在运行时动态加载）。
- macOS：需 Xcode Command Line Tools（链接 Cocoa 框架）。
- Linux → Windows 交叉编译另需 `gcc` 与（32 位目标）一份 i386 版 FPC，见下方「交叉编译前置条件」。

## 编译

构建产物按平台输出到 `out/<平台>/`，编译中间文件（`.ppu`/`.o`）放在可执行程序旁的 `units` 目录，不污染源码目录。Windows 为 `out/windows/i386`（32 位）、`out/windows/x86_64`（64 位）；Linux 为 `out/linux/<架构>/`（`<架构>` 为 `x86_64` / `i386` / `aarch64` / `arm`，二进制 `stayawake` + 旁边 `units/`）；macOS 为 `out/macos/<架构>/StayAwake.app`，架构目录为 `arm64`（Apple Silicon）与 `x86_64`（Intel），各自的 `units/` 在 `.app` 同目录。`exe` 图标由 `tools/gen_icon.pas` 生成到 `assets/stayawake.ico`（缺失时自动生成）。

编译脚本按平台拆分，互不沾染：

```bat
build.cmd            :: Windows（默认 64 位；win32 / win64 可选）
```

在 Linux 上交叉编译出 Windows 产物（无需 Windows 机器）：

```sh
./build-cross.sh            # 同时构建 win64 + win32
./build-cross.sh win64      # 仅 64 位
./build-cross.sh win32      # 仅 32 位
# 产物：out/windows/x86_64/stayawake.exe、out/windows/i386/stayawake.exe
```

> **Linux → Windows 交叉编译前置条件**（以 Debian/Ubuntu 为例）
>
> 1. 基础工具链：`apt-get install fpc fpc-source binutils-mingw-w64 gcc`
>    - `fpc-source`：Debian 的 `fpc` 不自带 Win32/Win64 的 RTL，脚本用这里的 RTL 源码现场构建所需单元。
>    - `gcc`：**必需**。`windres` 编译 `.rc` 资源时会调用 `gcc` 做预处理，缺失会直接报
>      `sh: 1: gcc: not found` → `preprocessing failed` → `Error while compiling resources`，
>      win64 / win32 两个目标都编不出来。（`gcc` 可能被其它包顺带装上，但不应依赖这点，显式安装更稳。）
>    - `binutils-mingw-w64`：mingw 的 binutils 命名与 FPC 期望不同，脚本会尝试在 `PATH` 中建立别名
>      （`x86_64-win64-ld` / `i386-win32-ld` / `*-windres` 等）。
>
> 2. **仅当需要 32 位目标（win32）时**，还需一份 i386 版 FPC（`ppc386`）。Debian 多架构下这一步
>    有三处坑，照下面顺序做即可：
>
>    ```sh
>    dpkg --add-architecture i386 && apt-get update
>    apt-get download fp-compiler-3.2.2:i386
>    dpkg -i --force-depends fp-compiler-3.2.2_3.2.2+dfsg-20_i386.deb
>    ln -sf /usr/lib/i386-linux-gnu/fpc/3.2.2/ppc386 /usr/local/bin/ppc386
>    ```
>
>    然后**把两套架构的单元搜索路径都补进 `/etc/fpc-3.2.2.cfg`**（见下面第三个坑，不补会连 amd64
>    目标都编不动；用 `#ifdef` 分架构，重复追加无害）：
>
>    ```sh
>    cat >> /etc/fpc-3.2.2.cfg <<'EOF'
>
>    # --- multiarch: keep both unit search roots so ppcx64 and ppc386 both resolve RTL ---
>    #ifdef cpux86_64
>    -Fu/usr/lib/x86_64-linux-gnu/fpc/$fpcversion/units/$fpctarget
>    -Fu/usr/lib/x86_64-linux-gnu/fpc/$fpcversion/units/$fpctarget/*
>    -Fu/usr/lib/x86_64-linux-gnu/fpc/$fpcversion/units/$fpctarget/rtl
>    #endif
>    #ifdef cpui386
>    -Fu/usr/lib/i386-linux-gnu/fpc/$fpcversion/units/$fpctarget
>    -Fu/usr/lib/i386-linux-gnu/fpc/$fpcversion/units/$fpctarget/*
>    -Fu/usr/lib/i386-linux-gnu/fpc/$fpcversion/units/$fpctarget/rtl
>    #endif
>    EOF
>    ```
>
>    三处坑：
>    - **`binutils` 与 `binutils:i386` 互相 `Conflicts`**，装不成「既有 amd64 又有 i386 的 binutils」。
>      所以不能走 `apt-get install fp-compiler-3.2.2:i386`——它依赖未限定架构的 `binutils`，apt 会
>      一路解到 `binutils:i386`，然后因冲突把整个安装判为不可满足（`E: Unable to correct problems,
>      you have held broken packages`）。i386 的 FPC 其实**用 amd64 的 binutils 就能工作**，因此直接用
>      `dpkg --force-depends` 单独装这个 `.deb` 即可绕开依赖解算。（装完 `dpkg --audit` 应为空。）
>    - **`ppc386` 不在 `PATH` 里**：该 `.deb` 不会把 `ppc386` 放进 `/usr/bin`（那里的 alternative 归
>      amd64 包所有），二进制实际在 `/usr/lib/i386-linux-gnu/fpc/3.2.2/ppc386`，故需手动 `ln -sf`。
>    - **共享的 `/etc/fpc-3.2.2.cfg` 会被写坏**：两个 `fp-compiler-3.2.2` 通过 `update-alternatives`
>      共用同一个 `/usr/bin/fpc` 与 `/etc/fpc-3.2.2.cfg`。最后装 i386 的那个，会把配置里的单元搜索
>      根路径整段改成 `/usr/lib/i386-linux-gnu/fpc/...`，于是 **`ppcx64` 找不到自己的 RTL**，连 amd64
>      的原生编译都会报 `Fatal: Can't find unit system`。上面那段按 `#ifdef cpu...` 把两种架构的路径
>      都写回即可（`-Fu` 是累加的，多写不冲突）。
>
>    装完确认：`which ppcx64 ppc386`（`/usr/bin/ppcx64` 与 `/usr/local/bin/ppc386`），
>    `dpkg --audit` 无输出，且 amd64 与 i386 各编一个 hello world 都通过。

```sh
chmod +x build-macos.sh build-linux.sh build-cross.sh clean.sh

# Linux（在 Linux 机器上运行，产物输出到 out/linux/<架构>/）
./build-linux.sh            # 本机架构（自动探测 x86_64 / i386 / aarch64 / arm）
./build-linux.sh aarch64    # 交叉编译到 ARM64（需对应跨编译器/RTL）
./package-linux.sh          # 构建并打包 stayawake-linux-<arch>.tar.gz（含 lid-guard 组件）

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
├── package-linux.sh        # Linux 打包脚本（二进制 + lid-guard 组件 → tar.gz）
├── build-cross.sh          # Linux → Windows 交叉编译脚本（win64 / win32 / both）
├── clean.sh                # 清理 out/ 下编译中间文件（保留最终二进制/.app）
├── release.sh              # 将 out/windows/<arch> 的 exe 上传到 GitHub Release（gh 需已登录）
├── assets/
│   └── stayawake.ico       # 生成的多尺寸 exe 图标
├── tools/
│   └── gen_icon.pas         # 图标生成器（与托盘同款像素画）
├── linux/
│   └── lid-guard/           # Linux 合盖守卫：守卫脚本 + systemd --user 单元 + 安装/卸载
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

每个平台目录内四个单元，结构一致，主程序只依赖各平台共有的 5 个符号
（`AcquireSingleInstance` / `UpdateExecutionState` / `EnsureAutoStart` /
`StartMoverThread` / `TrayCreate`），无需感知平台差异：

| 单元 | 职责 |
| ---- | ---- |
| `stayawake_single.pas` | `AcquireSingleInstance`：单实例锁 |
| `stayawake_mover.pas` | `StartMoverThread`：定时移动鼠标的线程（`NudgeMouse`）。Windows 额外导出 `WakeMoverThread`，供托盘在暂停/恢复时立即唤醒线程 |
| `stayawake_tray.pas` | `TrayCreate`：托盘图标 + 右键菜单 + 事件循环 |
| `stayawake_autostart.pas` | `EnsureAutoStart` / `IsAutoStartEnabled` / `DisableAutoStart`；Linux 额外导出 `EnableAutoStart`（GNOME 会把条目原地标记为 `X-GNOME-Autostart-enabled=false`，需要一个「即使存在也重新启用」的入口） |

> 除上表列出的 5 个共有符号外，各平台按自身需要额外导出少量符号（如 Windows 的
> `WakeMoverThread`、Linux 的 `EnableAutoStart`），主程序不引用它们。