#!/bin/sh

# Build StayAwake for macOS.
# Usage: ./build-macos.sh [arch...|universal]
#   arch: one or more of arm64 x86_64 (default: both, into separate per-arch dirs).
#   universal: build both arm64 + x86_64 and merge into one fat binary via lipo.
# Set FPC to a full path to fpc if it is not on PATH.

set -e

SRC="$(cd "$(dirname "$0")" && pwd)/src"
OUT="$(cd "$(dirname "$0")" && pwd)/out/macos"
FPC="${FPC:-fpc}"

MODE="${1:-}"

# Compile one macOS executable for the given arch and wrap it in a .app bundle
# under out/macos/<arch>/StayAwake.app. Intermediate units land in
# out/macos/<arch>/units (beside the app, not inside it).
# FPC's -P CPU for Apple Silicon is "aarch64", so map arm64 -> aarch64.
build_macos_arch() {
  local arch="$1"
  local fpcpu="$arch"
  [ "$arch" = "arm64" ] && fpcpu="aarch64"
  local app="$OUT/$arch/StayAwake.app"
  local macdir="$app/Contents/MacOS"
  local units="$OUT/$arch/units"
  mkdir -p "$units" "$macdir"
  echo "==> compiling macOS slice: -P$fpcpu (dir $arch)"
  if ! "$FPC" -Mobjfpc -O2 -P"$fpcpu" -Fucommon -Fumacos -FU"$units" -FE"$macdir" -ostayawake stayawake.lpr; then
    echo "!! failed to build arch '$arch' (is its RTL + compiler installed?)" >&2
    return 1
  fi
  chmod +x "$macdir/stayawake"
  # Wrap into a .app bundle so double-clicking does not open Terminal.
  # LSUIElement=true => menu-bar (agent) app, no Dock icon.
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>StayAwake</string>
  <key>CFBundleDisplayName</key>
  <string>StayAwake</string>
  <key>CFBundleIdentifier</key>
  <string>com.stayawake</string>
  <key>CFBundleExecutable</key>
  <string>stayawake</string>
  <key>CFBundleVersion</key>
  <string>0.1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>LSBackgroundOnly</key>
  <false/>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
  echo "==> built: $app"
  return 0
}

cd "$SRC"

case "$MODE" in
  universal)
    # Build both slices to temp unit dirs, then merge with lipo into one fat app.
    mkdir -p "$OUT/units-arm64" "$OUT/units-x86_64"
    "$FPC" -Mobjfpc -O2 -Paarch64 -Fucommon -Fumacos -FU"$OUT/units-arm64" -FE"$OUT" -ostayawake-arm64 stayawake.lpr
    "$FPC" -Mobjfpc -O2 -Px86_64  -Fucommon -Fumacos -FU"$OUT/units-x86_64" -FE"$OUT" -ostayawake-x86_64 stayawake.lpr
    if ! lipo -create -output "$OUT/stayawake" "$OUT/stayawake-arm64" "$OUT/stayawake-x86_64"; then
      echo "lipo failed — is the x86_64-darwin RTL + ppcx64 installed?" >&2
      exit 1
    fi
    rm -f "$OUT/stayawake-arm64" "$OUT/stayawake-x86_64"
    app="$OUT/StayAwake.app"; macdir="$app/Contents/MacOS"
    mkdir -p "$macdir"
    cp "$OUT/stayawake" "$macdir/stayawake"; chmod +x "$macdir/stayawake"; rm -f "$OUT/stayawake"
    echo "==> universal binary:"; lipo -info "$app/Contents/MacOS/stayawake"
    echo "==> built: $app"
    ;;
  "")
    # Default: build each architecture into its own directory.
    ok=1
    for arch in arm64 x86_64; do
      build_macos_arch "$arch" || ok=0
    done
    [ "$ok" = 1 ] || { echo "!! some architectures failed to build" >&2; exit 1; }
    ;;
  *)
    # Explicit arch list, e.g. "./build-macos.sh arm64" or "x86_64 arm64".
    ok=1
    for arch in $MODE; do
      case "$arch" in
        arm64|x86_64) ;;
        *) echo "unsupported macOS arch: $arch (use arm64 or x86_64)" >&2; exit 1 ;;
      esac
      build_macos_arch "$arch" || ok=0
    done
    [ "$ok" = 1 ] || { echo "!! some architectures failed to build" >&2; exit 1; }
    ;;
esac
