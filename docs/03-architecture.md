# 03 架构

## 目录结构

```
stayawake/
├── docs/                        # 本文档集
├── scripts/                     # 构建 / 打包 / 发布脚本
│   ├── build.cmd                #   Windows（win32 / win64）
│   ├── build-macos.sh           #   macOS（arm64 / x86_64 / universal）
│   ├── build-linux.sh           #   Linux（本机架构或交叉）
│   ├── build-cross.sh           #   Linux → Windows 交叉编译
│   ├── package-linux.sh         #   Linux tar.gz 打包（含 lid-guard 组件）
│   ├── clean.sh / release.sh    #   清理 / 上传 GitHub Release
├── src/
│   ├── stayawake.lpr            # 主程序（全平台一份）
│   ├── stayawake.rc             # Windows 图标资源
│   ├── common/stayawake_common.pas  # ★ 共享核心：图标绘制、i18n、菜单树、动作分发、配置
│   ├── win/    stayawake_{single,mover,tray,autostart}.pas
│   ├── linux/  同上四单元 + lid-guard/（systemd 守卫组件）
│   └── macos/  同上四单元
├── tools/gen_icon.pas           # Windows .ico 生成器（复用共享图标绘制）
└── out/                         # 构建产物（git 忽略）
```

## 分层模型

```
┌────────────────────────────────────────────────────────┐
│ stayawake.lpr   单实例 → 自启同步 → 微动线程 → 托盘循环   │
├────────────────────────────────────────────────────────┤
│ 共享核心（src/common，无平台 IFDEF）                      │
│  • GenerateIconPixels   图标像素（托盘 + .ico 同源）      │
│  • i18n：字符串表 / CurrentLang / ApplyLanguage          │
│  • BuildTrayMenu：声明式菜单树（勾选/单选/子菜单/分隔线）   │
│  • MenuActionState / MenuActionInvoke                   │
│    （状态查询与点击分发，含自启开关——经平台 autostart 单元）│
│  • LidMode / SetLidMode（合盖模式文件）                   │
├──────────────┬──────────────────┬───────────────────────┤
│ 渲染器 win/   │ 渲染器 linux/     │ 渲染器 macos/          │
│  把菜单树绑定  │  绑定到 GTK 菜单  │  绑定到 NSMenu          │
│  到 HMENU     │                  │                       │
│  wParam=action│ g_object data    │ NSMenuItem.tag=action  │
├──────────────┴──────────────────┴───────────────────────┤
│ 平台服务单元（三端同名同接口，按 -Fu 搜索路径选择编译）      │
│  stayawake_single    单实例锁                            │
│  stayawake_mover     微动线程 + 睡眠断言                  │
│  stayawake_autostart 开机自启                             │
│  stayawake_tray      托盘渲染器（上層）                    │
└─────────────────────────────────────────────────────────┘
```

### 关键机制：无 IFDEF 的平台选择

平台差异不靠条件编译，而是靠**目录**：`src/win|linux|macos` 各有一套同名单元，编译时以 `-Fu` 搜索路径决定采用哪一套。主程序与共享核心只依赖统一接口（5 个共有符号 + 各平台一致的 autostart 接口）。

### 渲染器 + 钩子

菜单是「一份声明式树，三份原生渲染」：

- 各渲染器递归遍历 `BuildTrayMenu` 的树构建原生控件（NSMenu / HMENU / GTK 菜单），每个可点条目携带其 `TMenuAction`；
- 所有点击统一回流 `MenuActionInvoke`：共享逻辑修改状态（如 `AppActive` 取反、写语言/合盖文件），再调用**平台钩子**完成平台相关动作；
- 状态同步（打开菜单前、语言切换后）由渲染器遍历「节点↔原生控件」绑定表，用 `MenuActionState` 刷新。

```pascal
TTrayHooks = record
  HasLid: Boolean;               // Windows = False，菜单树不生成合盖子菜单
  RefreshVisual, ApplyAwake, ApplyLidMode,
  ApplyLanguage, ShowAbout, Quit: procedure; cdecl;
end;
```

真正无法共用的部分（弹系统对话框、持有/释放断言、拉起 systemd 服务、退出事件循环）全部收敛在这 6 个钩子里。

## 线程模型

- **主线程**：托盘事件循环（Win32 消息循环 / GTK main / NSApp run）；
- **微动线程**（每平台一个）：睡眠 60s → 激活则微动 → Windows 上无条件刷新自身断言；
- 跨线程数据只有 `AppActive` 布尔（单字节读写，平台均为原子性安全）；Windows 的暂停唤醒经 `TEvent`（自动复位）。

## 构建体系

| 脚本 | 产物 |
| ---- | ---- |
| `scripts/build.cmd` | `out/windows/{i386,x86_64}/stayawake.exe` |
| `scripts/build-linux.sh` | `out/linux/<arch>/stayawake` |
| `scripts/build-cross.sh` | Linux 上交叉构建 Windows（现场从 fpc-source 构建 Win RTL） |
| `scripts/build-macos.sh` | `out/macos/{arm64,x86_64}/StayAwake.app`；`universal` 合成 fat binary |
| `scripts/package-linux.sh` | `stayawake-linux-<arch>.tar.gz`（含 lid-guard 组件） |
| `scripts/release.sh` | 上传资产到 GitHub Release |

发布构建统一剥离符号：Linux/Windows 用 `-Xs`，macOS 因 Darwin 链接路径对 `-Xs` 无效而显式调用 `strip`（见 05-build 的体积表）。

macOS x86_64 切片使用官方 multi-arch FPC 的 `ppcx64`（安装在 `~/fpc/3.2.2/`，Apple Silicon 上经 Rosetta 运行），脚本自动探测；版本号唯一来源是 `stayawake_common` 的 `APP_VERSION`，构建脚本读取它写入 Info.plist。

## 依赖关系

共享核心的 `implementation` 部分引用 `stayawake_autostart`（自启开关的统一接口）——三平台各有一份同名实现，随 `-Fu` 解析，因此共享代码无需感知平台。其余平台 API 全部**动态加载**（dlopen/LoadLibrary：X11/Xtst、IOKit、CoreGraphics、ServiceManagement），缺失时功能降级而非崩溃。
