#!/bin/sh

# Build stayawake for Linux or macOS.
# Usage: ./build.sh [linux|macos] [arch]
#   arch: optional, one of x86_64|i386|aarch64|arm.
#         Default is native (no -P flag). Example: ./build.sh linux aarch64
# Set FPC to a full path to fpc if it is not on PATH.

set -e

SRC="$(cd "$(dirname "$0")" && pwd)/src"
OUT="$(cd "$(dirname "$0")" && pwd)/out"
FPC="${FPC:-fpc}"

case "${1:-linux}" in
  linux)  PLAT=linux ;;
  macos)  PLAT=macos ;;
  *) echo "usage: $0 [linux|macos] [arch]" >&2; exit 1 ;;
esac

ARCH="${2:-}"
case "$ARCH" in
  ""|x86_64|i386|aarch64|arm) ;;
  *) echo "unsupported arch: $ARCH (use x86_64, i386, aarch64, arm)" >&2; exit 1 ;;
esac

mkdir -p "$OUT/units"
cd "$SRC"
if [ -n "$ARCH" ]; then
  exec "$FPC" -Mobjfpc -O2 -P"$ARCH" -Fucommon -Fu"$PLAT" -FU"$OUT/units" -FE"$OUT" stayawake.lpr
else
  exec "$FPC" -Mobjfpc -O2 -Fucommon -Fu"$PLAT" -FU"$OUT/units" -FE"$OUT" stayawake.lpr
fi