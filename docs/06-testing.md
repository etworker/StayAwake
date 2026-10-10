# 06 测试与验证

本项目无独立测试框架，采用「分层就地验证」：能自动化的自动化，无法自动化的（GUI 点击）明确标注人工项。所有验证均可在开发机上完成，不需要真实的目标硬件。

## 三层验证矩阵

| 层 | 环境 | 覆盖 | 方式 |
| ---- | ---- | ---- | ---- |
| L1 原生 | 开发机 macOS (arm64) | macOS 全量构建 + 运行 | `scripts/build-macos.sh`；进程存活、干净退出、产物落盘检查 |
| L2 容器 | docker `debian:bookworm-slim` | Linux 全量构建 + 行为测试 | 容器内 `fpc` 全量编译链接（真 GTK2）；行为测试直接调用单元函数 |
| L3 模拟 | docker + qemu-user | Windows 交叉编译 | Debian amd64 的 `ppcx64`/`ppc386` 经 `qemu-x86_64-static`/`qemu-i386-static` 运行，链接官方 FPC Windows 安装包抽取的 RTL `.ppu`，产出真实 PE 并核对导入表 |

L3 的价值：Windows 代码在本机无 Windows 的情况下也能完成**编译级**验证（曾抓出 TEvent 构造签名错误、菜单重构图错误等）；再配合对 `stayawake_autostart` 这类平台无关逻辑的行为测试，把「只能在真机发现」的问题压缩到纯 GUI 交互层。

## 行为测试用例

针对**平台无关逻辑**（编译进测试程序直接调用），已覆盖：

### 自启动（Linux desktop 文件语义）
- 首次创建：Exec 带引号指向当前二进制、`X-GNOME-Autostart-enabled=true`；
- 幂等：路径匹配且已启用时，启动同步**不重写**文件；
- 禁用语义：GNOME 就地改 `=false` 后，启动同步**尊重**禁用（不强行改回），托盘开关 `EnableAutoStart` **强制重新启用**；
- 旧路径自愈：Exec 指向已迁移路径时自动刷新；
- 异常输入：`HOME` 为空不崩溃不写文件。

### 开机自启（macOS SMAppService）
- 注册 / 注销 / 幂等往返（`IsAutoStartEnabled` 状态机）；
- 管控机场景：`~/Library/LaunchAgents` 为 root 所有时的降级行为（SMAppService 不依赖文件写权限）。

### 系统级效果验证（不可自动断言部分的替代）
- macOS 合盖守卫：`pmset -g assertions` 应在「不动作」模式出现 `PreventSystemSleep named: "StayAwake lid guard"`，「睡眠」模式与退出后消失（已实测通过）；
- Windows 抑制：导入表核对 `SetThreadExecutionState` / `CreateEventA` / `SetCursorPos` 存在（win32 + win64）。

## 已知未覆盖（需人工确认）

- 托盘菜单的真实点击、勾选状态渲染、语言切换的视觉更新（macOS 上屏幕录制 / 辅助功能权限未授予自动化进程）；
- 合盖动作的物理验证（合上盖子看是否睡眠）；
- Wayland 下的 Linux 托盘可见性（依赖 AppIndicator 扩展）。

## 回归案例

- **配置目录初始化时序**（2026-10）：平台配置目录与钩子原先在 `TrayCreate` 中注册，而 `stayawake.lpr` 在其之前运行 `StartMoverThread`——macOS 合盖守卫启动时读到空配置目录，把 `block` 当成 `allow`，断言未持有（用户实测「插电合盖仍睡眠」暴露）。修复：三平台托盘单元统一把 `InitPlatformConfig` 挂到单元 `initialization` 节（先于主程序体），并在 `TrayCreate` 末尾自愈式重放 `ApplyLidMode`。教训：**共享核心对路径的读取时机不可假设**，平台注册必须先于任何主程序体调用。

## 回归基线

每次影响共享核心（`stayawake_common`）或任一渲染器的改动，最低回归标准：

1. macOS universal 构建通过 + 启动存活 3 秒 + 干净退出；
2. 容器 Linux 全量构建通过 + 行为测试全过；
3. Windows win64 + win32 交叉编译通过 + 导入表核对；
4. `git grep` 检查无新增平台 IFDEF（架构约束）。
