#!/bin/sh

# Build StayAwake for Linux.
# Usage: ./build-linux.sh [arch]
#   arch: x86_64|i386|aarch64|arm (default: native architecture).
# Set FPC to a full path to fpc if it is not on PATH.
# Output: out/linux/<arch>/stayawake (binary) + out/linux/<arch>/units (intermediates),
# matching the macOS layout out/macos/<arch>.

set -e

SRC="$(cd "$(dirname "$0")" && pwd)/src"
OUT="$(cd "$(dirname "$0")" && pwd)/out/linux"
FPC="${FPC:-fpc}"

MODE="${1:-}"

case "$MODE" in
  ""|x86_64|i386|aarch64|arm) ;;
  *) echo "unsupported arch: $MODE (use x86_64, i386, aarch64, arm)" >&2; exit 1 ;;
esac

# Map the requested / native arch to FPC's -P CPU name and the output folder.
if [ -z "$MODE" ]; then
  native="$(uname -m)"
  case "$native" in
    x86_64|amd64)   ARCH=x86_64;  FPCARCH=x86_64 ;;
    i?86)           ARCH=i386;    FPCARCH=i386 ;;
    aarch64|arm64)  ARCH=aarch64; FPCARCH=aarch64 ;;
    armv7*|armv6*)  ARCH=arm;     FPCARCH=arm ;;
    *)              ARCH="$native"; FPCARCH="$native" ;;
  esac
else
  ARCH="$MODE"; FPCARCH="$MODE"
fi

# Intermediate units live in out/linux/<arch>/units, beside the final binary.
DEST="$OUT/$ARCH"
mkdir -p "$DEST/units"
cd "$SRC"
exec "$FPC" -Mobjfpc -O2 -P"$FPCARCH" -Fucommon -Fulinux -FU"$DEST/units" -FE"$DEST" stayawake.lpr
