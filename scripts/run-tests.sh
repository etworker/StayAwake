#!/bin/sh

# Build and run the unit tests for the current platform.
#   macOS / Linux: builds and runs tests/test_common.pas (shared core);
#   Linux also runs the autostart scenario suite (tests/test_linux_autostart.pas)
#   with per-scenario isolated HOME dirs.
# Windows: tests are POSIX-oriented; run test_common under MSYS2/cygwin-style
# shell or extend here if needed.
# Everything compiles into a temp dir; nothing touches the source tree.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src"
TESTS="$ROOT/tests"
FPC="${FPC:-fpc}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "$(uname -s)" in
  Darwin) PLAT=macos ;;
  Linux)  PLAT=linux ;;
  *) echo "unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac

cd "$SRC"

echo "==> test_common ($PLAT)"
"$FPC" -Mobjfpc -O1 -Fucommon -Fu"$PLAT" -FE"$TMP" -o"$TMP/test_common" \
  "$TESTS/test_common.pas" > "$TMP/build.log" 2>&1 || { cat "$TMP/build.log"; exit 1; }
rm -rf "${TMP}/stayawake_unittest"
"$TMP/test_common"

if [ "$PLAT" = "linux" ]; then
  echo "==> test_linux_autostart"
  "$FPC" -Mobjfpc -O1 -Fucommon -Fulinux -FE"$TMP" -o"$TMP/test_as" \
    "$TESTS/test_linux_autostart.pas" > "$TMP/build2.log" 2>&1 || { cat "$TMP/build2.log"; exit 1; }
  ok=1
  for s in s1 s2 s3 s4; do
    rm -rf "$TMP/h_$s"; mkdir -p "$TMP/h_$s"
    HOME="$TMP/h_$s" "$TMP/test_as" "$s" || ok=0
  done
  HOME= "$TMP/test_as" s5 || ok=0
  [ "$ok" = 1 ] || exit 1
fi

echo "==> all tests passed"
