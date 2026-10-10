# stayawake

一个用 Free Pascal 编写的三平台托盘应用：阻止系统因「空闲」而睡眠 / 熄屏 / 锁屏，随时可从托盘菜单暂停。眼睛图标——睁眼 = 清醒中，闭眼 = 已暂停。

- Windows：`SetThreadExecutionState` 电源断言 + 每 60 秒鼠标微动 1 像素兜底；
- macOS：`IOPMAssertion`，合盖行为可切换（Apple Silicon）；
- Linux：鼠标微动 + 用户级合盖守卫（免 sudo，免疫 UPower 误判）；
- 三平台一致的托盘菜单，内置简体中文 / English 双语。

## 下载

预编译二进制见 [Releases](https://github.com/etworker/StayAwake/releases)：

| 平台 | 资产 |
| ---- | ---- |
| Windows | `stayawake-win64.exe`（推荐）、`stayawake-win32.exe` |
| macOS | `StayAwake-macos-arm64.zip`（Apple Silicon）、`StayAwake-macos-x86_64.zip`（Intel） |
| Linux | `stayawake-linux-x86_64.tar.gz`、`stayawake-linux-aarch64.tar.gz` |

安装与使用见 [docs/04-usage.md](docs/04-usage.md)。

## 功能速览

- 托盘菜单：**保持清醒**开关、**开机自启**开关、**语言**（跟随系统 / English / 中文）、关于、退出——点击图标本身不会静默改变任何行为；
- **合盖行为(接电源时)**子菜单：Linux 一键切换（用户级守卫，免 sudo）；macOS 为引导式管理员命令（`sudo pmset disablesleep`，一次性）；Windows 不提供（系统策略修改需管理员）；
- 启动即激活；暂停立即生效；所有设置即时持久化；
- 单实例；全部功能免 root / 免管理员。

## 限制速览

只拦截「空闲导致」的睡眠。合盖拦截能力：Linux ✅（装守卫后）、macOS ⚠️（需一次性管理员命令，菜单引导）、Windows ❌。完整清单见 [docs/01-requirements.md](docs/01-requirements.md)。

## 文档

| 文档 | 内容 |
| ---- | ---- |
| [docs/01-requirements.md](docs/01-requirements.md) | 需求：目标、功能/非功能需求、非目标、平台约束 |
| [docs/02-design.md](docs/02-design.md) | 设计：睡眠抑制、托盘菜单、合盖守卫、自启、i18n、图标的方案与平台差异 |
| [docs/03-architecture.md](docs/03-architecture.md) | 架构：共享核心 + 平台渲染器、无 IFDEF 的平台选择、构建体系 |
| [docs/04-usage.md](docs/04-usage.md) | 使用：安装启动、菜单操作、配置文件、常见问题 |
| [docs/05-build.md](docs/05-build.md) | 构建：从源码构建、交叉编译（Linux→Windows、macOS x86_64）、发布瘦身 |
| [docs/06-testing.md](docs/06-testing.md) | 测试：三层验证矩阵、行为测试用例、回归基线 |

## 平台实现

每个平台在 `src/<平台>/` 有独立的一套四个单元（单实例 / 微动线程 / 自启 / 托盘渲染器），编译时以 `-Fu` 搜索路径选择，源码内无平台 `IFDEF`。跨平台共享逻辑（图标像素绘制、界面文案、菜单结构、状态与动作分发、配置读写）全部收敛在 `src/common/stayawake_common.pas`。

| 平台 | 托盘 | 微动 | 自启 |
| ---- | ---- | ---- | ---- |
| Windows | `Shell_NotifyIconW` + HMENU | `SetCursorPos` | 注册表 Run 键 |
| Linux | GTK2 `GtkStatusIcon` | X11 `XTestFakeMotionEvent` | XDG autostart |
| macOS | `NSStatusItem` + NSMenu | `CGEventPost` | SMAppService 登录项 |

## 开发

从源码构建、交叉编译（无需真机的 Windows/macOS 验证）、发布流程见 [docs/05-build.md](docs/05-build.md)；验证策略与回归基线见 [docs/06-testing.md](docs/06-testing.md)。

## 许可证

[MIT](LICENSE)
