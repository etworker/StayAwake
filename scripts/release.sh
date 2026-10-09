#!/bin/sh

# Upload built binaries to a GitHub Release.
# Requires: gh CLI authenticated, and the builds already present:
#   Windows: out/windows/x86_64/stayawake.exe + out/windows/i386/stayawake.exe
#            (run scripts/build.cmd win64 / scripts/build.cmd win32)
#   Linux:   out/linux/stayawake-linux-<arch>.tar.gz
#            (run ./scripts/package-linux.sh, optionally per arch)
# (macOS ships as .app bundles; zip them manually before uploading if desired.)
# Usage: ./scripts/release.sh <tag>   (default: latest git tag)

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TAG="${1:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null)}"
[ -n "$TAG" ] || { echo "no tag given and none found" >&2; exit 1; }

# --- Windows (required) -----------------------------------------------------
WIN64="$OUT/windows/x86_64/stayawake.exe"
WIN32="$OUT/windows/i386/stayawake.exe"
[ -f "$WIN64" ] || { echo "missing: $WIN64 (run scripts/build.cmd win64)" >&2; exit 1; }
[ -f "$WIN32" ] || { echo "missing: $WIN32 (run scripts/build.cmd win32)" >&2; exit 1; }

# gh release upload keeps the file's basename as the asset name, so stage
# copies with the published names (stayawake-win64.exe / stayawake-win32.exe).
cp "$WIN64" "$TMP/stayawake-win64.exe"
cp "$WIN32" "$TMP/stayawake-win32.exe"

# --- Linux tarballs (optional; built by ./scripts/package-linux.sh) ----------
set -- "$TMP/stayawake-win64.exe" "$TMP/stayawake-win32.exe"
for f in "$OUT"/linux/stayawake-linux-*.tar.gz; do
  [ -f "$f" ] || continue
  cp "$f" "$TMP/"
  set -- "$@" "$TMP/$(basename "$f")"
  echo "==> staged linux asset: $(basename "$f")"
done
if [ "$#" -le 2 ]; then
  echo "warning: no Linux tarballs staged (run ./scripts/package-linux.sh first)" >&2
fi

echo "==> uploading to release $TAG"
gh release upload "$TAG" --clobber "$@"
echo "==> done"
