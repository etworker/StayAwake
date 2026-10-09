#!/bin/sh

# Cross-compile StayAwake for Windows from Linux (no Windows machine needed).
#
# Usage: ./build-cross.sh [win64|win32|both]   (default: both)
#
# Output mirrors build.cmd:
#   out/windows/x86_64/stayawake.exe
#   out/windows/i386/stayawake.exe
#
# Requirements (Debian/Ubuntu: apt-get install fpc fpc-source binutils-mingw-w64 gcc):
#   - a native FPC (ppcx64) and, for the 32-bit target, an i386 FPC (ppc386);
#   - the FPC RTL sources from the 'fpc-source' package, used to satisfy the
#     Win32/Win64 RTL units that Debian does not ship prebuilt;
#   - gcc, required by windres to preprocess the .rc (both targets fail without);
#   - mingw-w64 binutils, reachable by FPC as x86_64-win64-ld / i386-win32-ld
#     (plus matching 'windres'); the script below links them into PATH if the
#     distro-provided names differ.
# See the README section 'Linux → Windows 交叉编译前置条件' for the full,
# reproducible setup, including the Debian multiarch caveats that make the
# plain 'apt-get install fp-compiler-3.2.2:i386' path fail.
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/out/windows"
MODE="${1:-both}"

FPCSRC="${FPCSRC:-/usr/share/fpcsrc/3.2.2}"
RTL="$FPCSRC/rtl"
PKG="$FPCSRC/packages"

[ -d "$RTL" ] || { echo "FPC sources not found at $FPCSRC (install 'fpc-source', or set FPCSRC)" >&2; exit 1; }

# FPC looks for binutils named after the target; Debian ships them as
# <triplet>-*. Provide the expected aliases (idempotent, best effort).
link_tool() { # <expected-name> <real-name>
  command -v "$1" >/dev/null 2>&1 && return 0
  command -v "$2" >/dev/null 2>&1 || return 0
  for d in /usr/local/bin "$HOME/.local/bin"; do
    [ -d "$d" ] && [ -w "$d" ] && ln -sf "$(command -v "$2")" "$d/$1" && return 0
  done
  return 0
}
for arch in x86_64-win64 i386-win32; do
  case "$arch" in
    x86_64-win64) triplet=x86_64-w64-mingw32 ;;
    i386-win32)   triplet=i686-w64-mingw32 ;;
  esac
  link_tool "$arch-ld"      "$triplet-ld"
  link_tool "$arch-as"      "$triplet-as"
  link_tool "$arch-windres" "$triplet-windres"
done

# Include / unit search paths shared by both Windows targets.
INC="-Fi$RTL/inc -Fi$RTL/win -Fi$RTL/win/wininc -Fi$RTL/objpas -Fi$RTL/objpas/sysutils -Fi$RTL/objpas/classes -Fi$PKG/fcl-base/src -Fi$PKG/fcl-registry/src"

build_win() { # <cpu> <target-os> <os-rtl-dir> <cpu-rtl-dir> <out-subdir>
  cpu="$1"; tos="$2"; osdir="$3"; archdir="$4"; outdir="$5"
  dest="$OUT/$outdir"
  mkdir -p "$dest/units"
  echo "==> building Windows $tos ($cpu) -> $dest"
  ( cd "$SRC" && fpc -P"$cpu" -T"$tos" -Mobjfpc -O2 -Sg \
      -Fi"$RTL/$osdir" -Fi"$RTL/$archdir" $INC \
      -Fucommon -Fuwin \
      -Fu"$RTL/$osdir" -Fu"$RTL/$archdir" -Fu"$RTL/win" -Fu"$RTL/inc" \
      -Fu"$RTL/objpas" -Fu"$RTL/objpas/classes" -Fu"$RTL/objpas/sysutils" \
      -Fu"$PKG/fcl-base/src" -Fu"$PKG/fcl-registry/src" \
      -FU"$dest/units" -FE"$dest" stayawake.lpr )
}

# Make sure the shared exe icon exists (the .rc references ../assets/stayawake.ico).
if [ ! -f "$ROOT/assets/stayawake.ico" ]; then
  echo "==> generating assets/stayawake.ico"
  mkdir -p "$ROOT/out/tools"
  fpc -Mobjfpc -O2 -Fusrc/common -FU"$ROOT/out/tools" -FE"$ROOT/out/tools" "$ROOT/tools/gen_icon.pas" >/dev/null
  "$ROOT/out/tools/gen_icon" "$ROOT/assets/stayawake.ico"
fi

case "$MODE" in
  win64) build_win x86_64 win64 win64 x86_64 x86_64 ;;
  win32) build_win i386   win32 win32 i386   i386   ;;
  both)
    build_win x86_64 win64 win64 x86_64 x86_64
    build_win i386   win32 win32 i386   i386
    ;;
  *) echo "Usage: $0 [win64|win32|both]" >&2; exit 1 ;;
esac

echo "==> done:"
[ -f "$OUT/x86_64/stayawake.exe" ] && echo "    $OUT/x86_64/stayawake.exe"
[ -f "$OUT/i386/stayawake.exe" ]   && echo "    $OUT/i386/stayawake.exe"
exit 0
