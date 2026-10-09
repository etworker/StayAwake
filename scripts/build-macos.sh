#!/bin/sh

# Build StayAwake for macOS.
# Usage: ./scripts/build-macos.sh [arch...|universal]
#   arch: one or more of arm64 x86_64 (default: both, into separate per-arch dirs).
#   universal: build arm64 + x86_64 and merge into one fat binary via lipo.
# Set FPC to a full path to fpc if it is not on PATH.
#
# arm64 uses the native FPC (e.g. Homebrew's, compiler ppca64).
# x86_64 needs a cross compiler: Homebrew's FPC ships ppca64 only. Install the
# official multi-arch distribution once (its ppcx64 runs under Rosetta):
#   1. download https://sourceforge.net/projects/freepascal/files/Mac%20OS%20X/3.2.2/fpc-3.2.2.intelarm64-macosx.dmg
#   2. mount it and extract the payload to ~/fpc/3.2.2/, e.g.:
#      hdiutil attach fpc-3.2.2.intelarm64-macosx.dmg
#      pkgutil --expand-full "/Volumes/<vol>/fpc-3.2.2-intelarm64-macosx.mpkg" /tmp/fpce
#      mkdir -p ~/fpc
#      cp -R /tmp/fpce/Payload/usr/local/lib/fpc/3.2.2 ~/fpc/3.2.2
#      hdiutil detach "/Volumes/<vol>"
#   3. the script auto-detects ~/fpc/3.2.2/ppcx64 (override with FPC_X86_64).

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/out/macos"
FPC="${FPC:-fpc}"

# Single source of truth for the version is APP_VERSION in
# src/common/stayawake_common.pas; keep the Info.plist in sync with it
# instead of editing the number in two more places.
VERSION="$(sed -n "s/.*APP_VERSION *= *'\([^']*\)'.*/\1/p" "$SRC/common/stayawake_common.pas" | head -n1)"
[ -n "$VERSION" ] || { echo "!! could not read APP_VERSION from $SRC/common/stayawake_common.pas" >&2; exit 1; }

MODE="${1:-}"

# Resolve an x86_64 compiler + its extra flags. Prints nothing when the native
# frontend can target x86_64 (ppcx64 next to $FPC or on PATH); otherwise picks
# the Rosetta cross compiler installed under ~/fpc/3.2.2 (see header).
resolve_x86_64() {
  # Native frontend can dispatch to a ppcx64 it finds by itself.
  if command -v ppcx64 >/dev/null 2>&1; then
    return 0
  fi
  local cross="${FPC_X86_64:-$HOME/fpc/3.2.2/ppcx64}"
  if [ ! -x "$cross" ]; then
    echo "!! no x86_64 compiler: install the official multi-arch FPC (see header of this script)" >&2
    return 1
  fi
  local sdk cltlib
  sdk="$(xcrun --show-sdk-path)"
  cltlib="$(ls -d "$(xcrun --show-sdk-platform-path)/../../Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/"*"/lib/darwin" 2>/dev/null | sort -V | tail -n1)"
  CROSS_ARGS=(-XR"$sdk")
  [ -n "$cltlib" ] && CROSS_ARGS+=(-Fl"$cltlib")
  CROSS_ARGS+=(-Fl/usr/lib -Fu"$HOME/fpc/3.2.2/units/x86_64-darwin/rtl" \
               -Fu"$HOME/fpc/3.2.2/units/x86_64-darwin/cocoaint" \
               -Fu"$HOME/fpc/3.2.2/units/x86_64-darwin/univint")
  CROSS_COMPILER="$cross"
  return 0
}

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
  if [ "$arch" = "x86_64" ] && ! command -v ppcx64 >/dev/null 2>&1; then
    resolve_x86_64
    if ! "$CROSS_COMPILER" -Mobjfpc -O2 "${CROSS_ARGS[@]}" -Fucommon -Fumacos \
        -FU"$units" -FE"$macdir" -ostayawake stayawake.lpr; then
      echo "!! failed to build arch 'x86_64' with $CROSS_COMPILER" >&2
      return 1
    fi
  elif ! "$FPC" -Mobjfpc -O2 -P"$fpcpu" -Fucommon -Fumacos -FU"$units" -FE"$macdir" -ostayawake stayawake.lpr; then
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
  <string>$VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
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
    # Build both per-arch bundles (same code path as the standalone builds),
    # then merge the two executables into a third, universal bundle.
    build_macos_arch arm64
    build_macos_arch x86_64
    app="$OUT/StayAwake.app"; macdir="$app/Contents/MacOS"
    mkdir -p "$macdir"
    lipo -create -output "$macdir/stayawake" \
      "$OUT/arm64/StayAwake.app/Contents/MacOS/stayawake" \
      "$OUT/x86_64/StayAwake.app/Contents/MacOS/stayawake"
    chmod +x "$macdir/stayawake"
    cp "$OUT/arm64/StayAwake.app/Contents/Info.plist" "$app/Contents/Info.plist"
    echo "==> universal binary:"; lipo -info "$macdir/stayawake"
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
    # Explicit arch list, e.g. "./scripts/build-macos.sh arm64" or "x86_64 arm64".
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
