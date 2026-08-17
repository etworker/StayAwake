#!/bin/sh

# Build StayAwake for Linux.
# Usage: ./build-linux.sh [arch]
#   arch: x86_64|i386|aarch64|arm (default: native architecture).
# Set FPC to a full path to fpc if it is not on PATH.

set -e

SRC="$(cd "$(dirname "$0")" && pwd)/src"
OUT="$(cd "$(dirname "$0")" && pwd)/out/linux"
FPC="${FPC:-fpc}"

MODE="${1:-}"

case "$MODE" in
  ""|x86_64|i386|aarch64|arm) ;;
  *) echo "unsupported arch: $MODE (use x86_64, i386, aarch64, arm)" >&2; exit 1 ;;
esac

# Intermediate units live in out/linux/units, beside the final binary.
mkdir -p "$OUT/units"
cd "$SRC"
if [ -n "$MODE" ]; then
  exec "$FPC" -Mobjfpc -O2 -P"$MODE" -Fucommon -Fulinux -FU"$OUT/units" -FE"$OUT" stayawake.lpr
else
  exec "$FPC" -Mobjfpc -O2 -Fucommon -Fulinux -FU"$OUT/units" -FE"$OUT" stayawake.lpr
fi
