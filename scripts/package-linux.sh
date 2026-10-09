#!/bin/sh

# Package the Linux build into a distributable tar.gz.
# Usage: ./scripts/package-linux.sh [arch]
#   arch: x86_64|i386|aarch64|arm (default: native architecture).
# Builds first (delegates to build-linux.sh), then stages:
#   stayawake                       main binary (GTK2 + X11/libXtst runtime)
#   lid-guard/ac-lid-guard.sh       lid-close guard script (user-level)
#   lid-guard/ac-lid-guard.service  systemd --user unit
#   lid-guard/install.sh            user-level installer (no root)
#   lid-guard/uninstall.sh
#   lid-guard/README.txt            quick usage note
# Output: out/linux/stayawake-linux-<arch>.tar.gz

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ARCH="${1:-}"
case "$ARCH" in
  ""|x86_64|i386|aarch64|arm) ;;
  *) echo "unsupported arch: $ARCH (use x86_64, i386, aarch64, arm)" >&2; exit 1 ;;
esac

# Build first (build-linux.sh defaults to the native arch without an arg).
"$ROOT/scripts/build-linux.sh" ${ARCH:+"$ARCH"}

if [ -z "$ARCH" ]; then
  native="$(uname -m)"
  case "$native" in
    x86_64|amd64)   ARCH=x86_64 ;;
    i?86)           ARCH=i386 ;;
    aarch64|arm64)  ARCH=aarch64 ;;
    armv7*|armv6*)  ARCH=arm ;;
    *)              ARCH="$native" ;;
  esac
fi

DEST="$ROOT/out/linux/$ARCH"
[ -f "$DEST/stayawake" ] || { echo "missing: $DEST/stayawake (build failed?)" >&2; exit 1; }

STAGE="$ROOT/out/linux/stayawake-linux-$ARCH"
rm -rf "$STAGE"
mkdir -p "$STAGE/lid-guard"

cp "$DEST/stayawake" "$STAGE/stayawake"
for f in ac-lid-guard.sh ac-lid-guard.service install.sh uninstall.sh; do
  cp "$ROOT/src/linux/lid-guard/$f" "$STAGE/lid-guard/$f"
done

cat > "$STAGE/lid-guard/README.txt" <<'EOF'
Lid Close on AC (Linux)
=======================
Companion component for the StayAwake tray: choose whether closing the
lid on AC power does nothing or suspends the machine. The tray menu
("Lid Close on AC") switches modes; this guard service enforces the
choice at the logind level (immune to UPower misdetection).

Install (user-level, no root):  ./lid-guard/install.sh
Remove:                         ./lid-guard/uninstall.sh
Mode file: ~/.config/stayawake/lid-mode  (block | allow)
EOF

TGZ="$ROOT/out/linux/stayawake-linux-$ARCH.tar.gz"
tar -czf "$TGZ" -C "$ROOT/out/linux" "stayawake-linux-$ARCH"
rm -rf "$STAGE"

echo "==> $TGZ"
