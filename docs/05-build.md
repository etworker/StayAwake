# 05 构建与发布

## 工具链

- [Free Pascal 3.2.2+](https://www.freepascal.org/)（`PATH` 中或 `FPC` 环境变量指定）；
- Windows：按目标位数准备 `x86_64-win64` / `i386-win32` 工具链（脚本自动选择）；
- Linux：构建需要 `fpc`；运行只需 GTK2 运行时（FPC 的 gtk2 单元运行时动态加载）；
- macOS：Xcode Command Line Tools；构建 x86_64 切片另需 multi-arch FPC（见下）。

## 快速构建

```sh
# Windows（在 Windows 上）
scripts\build.cmd                 # 默认 win64；win32 / win64 可选
# → out\windows\x86_64\stayawake.exe

# Linux（在 Linux 上）
./scripts/build-linux.sh          # 本机架构（x86_64 / i386 / aarch64 / arm）
./scripts/package-linux.sh        # 构建 + 打包 stayawake-linux-<arch>.tar.gz（含 lid-guard）

# macOS
./scripts/build-macos.sh          # 双架构目录（arm64 + x86_64）
./scripts/build-macos.sh arm64    # 仅 Apple Silicon
./scripts/build-macos.sh universal  # 合成通用二进制（fat app）
```

产物输出到 `out/<平台>/`，中间单元文件（.ppu/.o）在可执行旁的 `units/`，不污染源码目录。Windows 的 exe 图标由 `tools/gen_icon.pas` 自动生成到 `assets/stayawake.ico`（git 忽略，缺失时构建脚本现场生成）。

## 发布瘦身

发布构建统一剥离符号：Linux/Windows 用 `-Xs`；macOS 因 Darwin 链接路径对 `-Xs` 无效，构建脚本在链接后显式执行 `strip`。实测体积：

| 产物 | 未剥离 | 剥离后 |
| ---- | ---- | ---- |
| macOS 单架构二进制 | 3.73 MB | **2.24 MB** |
| macOS universal | 7.45 MB | **4.45 MB** |
| Linux aarch64 | — | **1.47 MB** |
| Windows win64 / win32 | 0.60 / 0.52 MB | 不变（PE 已紧凑） |

## Linux → Windows 交叉编译

```sh
./scripts/build-cross.sh          # win64 + win32
./scripts/build-cross.sh win64    # 仅 64 位
```

前置条件（Debian/Ubuntu）：

```sh
apt-get install fpc fpc-source binutils-mingw-w64 gcc
```

- `fpc-source`：Debian 的 fpc 不带 Win RTL，脚本用源码现场构建；
- `gcc`：`windres` 预处理 `.rc` 必需，缺失会报 `Error while compiling resources`；
- `binutils-mingw-w64`：脚本会在 PATH 中建立 `x86_64-win64-ld` 等别名。

**win32 目标额外需要 i386 版 ppc386**，Debian 多架构有三处坑（binutils 互斥冲突 → 用 `dpkg --force-depends` 单装 .deb；ppc386 不在 PATH → 手动 symlink；两架构共用 `/etc/fpc-3.2.2.cfg` 会被后装的覆盖 → 用 `#ifdef cpu...` 把两套单元路径都补回）。逐条命令：

```sh
dpkg --add-architecture i386 && apt-get update
apt-get download fp-compiler-3.2.2:i386
dpkg -i --force-depends fp-compiler-3.2.2_3.2.2+dfsg-20_i386.deb
ln -sf /usr/lib/i386-linux-gnu/fpc/3.2.2/ppc386 /usr/local/bin/ppc386
cat >> /etc/fpc-3.2.2.cfg <<'EOF'
#ifdef cpux86_64
-Fu/usr/lib/x86_64-linux-gnu/fpc/$fpcversion/units/$fpctarget
-Fu/usr/lib/x86_64-linux-gnu/fpc/$fpcversion/units/$fpctarget/*
-Fu/usr/lib/x86_64-linux-gnu/fpc/$fpcversion/units/$fpctarget/rtl
#endif
#ifdef cpui386
-Fu/usr/lib/i386-linux-gnu/fpc/$fpcversion/units/$fpctarget
-Fu/usr/lib/i386-linux-gnu/fpc/$fpcversion/units/$fpctarget/*
-Fu/usr/lib/i386-linux-gnu/fpc/$fpcversion/units/$fpctarget/rtl
#endif
EOF
```

## macOS x86_64 交叉编译（Apple Silicon 主机）

Homebrew 的 FPC 只带 arm64 编译器。x86_64 切片使用官方 multi-arch 发行版的 `ppcx64`（universal 二进制，经 Rosetta 运行），脚本自动探测 `~/fpc/3.2.2/ppcx64`（可用 `FPC_X86_64` 覆盖）：

```sh
# 一次性安装
curl -LO "https://sourceforge.net/projects/freepascal/Mac%20OS%20X/3.2.2/fpc-3.2.2.intelarm64-macosx.dmg"
hdiutil attach fpc-3.2.2.intelarm64-macosx.dmg
pkgutil --expand-full "/Volumes/<vol>/fpc-3.2.2-intelarm64-macosx.mpkg" /tmp/fpce
mkdir -p ~/fpc && cp -R /tmp/fpce/Payload/usr/local/lib/fpc/3.2.2 ~/fpc/3.2.2
hdiutil detach "/Volumes/<vol>"
```

## 发布

1. 更新 `src/common/stayawake_common.pas` 的 `APP_VERSION`（唯一版本来源，macOS Info.plist 由构建脚本读取同步）；
2. 各平台构建（脚本均含剥离）；
3. 打包命名约定：
   - `stayawake-win64.exe` / `stayawake-win32.exe`
   - `StayAwake-macos-arm64.zip` / `StayAwake-macos-x86_64.zip`（.app 打 zip）
   - `stayawake-linux-x86_64.tar.gz` / `stayawake-linux-aarch64.tar.gz`（`package-linux.sh`）
4. `git tag vX.Y.Z && git push`，然后 `gh release create` 上传；`scripts/release.sh <tag>` 可辅助上传 Windows/Linux 资产。

## 清理

```sh
./scripts/clean.sh   # 删除 out/ 下的 units 目录与 *.o/*.ppu，保留最终产物
```
