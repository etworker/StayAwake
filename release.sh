#!/bin/sh

# Upload built Windows binaries to a GitHub Release.
# Requires: gh CLI authenticated, and the Windows binaries already built:
#   out/windows/x86_64/stayawake.exe
#   out/windows/i386/stayawake.exe
# (macOS ships as .app bundles; zip them manually before uploading if desired.)
# Usage: ./release.sh <tag>   (default: latest git tag)

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/out"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TAG="${1:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null)}"
[ -n "$TAG" ] || { echo "no tag given and none found" >&2; exit 1; }

WIN64="$OUT/windows/x86_64/stayawake.exe"
WIN32="$OUT/windows/i386/stayawake.exe"
[ -f "$WIN64" ] || { echo "missing: $WIN64 (run build.cmd win64)" >&2; exit 1; }
[ -f "$WIN32" ] || { echo "missing: $WIN32 (run build.cmd win32)" >&2; exit 1; }

# gh release upload keeps the file's basename as the asset name, so stage
# copies with the published names (stayawake-win64.exe / stayawake-win32.exe).
cp "$WIN64" "$TMP/stayawake-win64.exe"
cp "$WIN32" "$TMP/stayawake-win32.exe"

echo "==> uploading to release $TAG"
gh release upload "$TAG" --clobber \
  "$TMP/stayawake-win64.exe" \
  "$TMP/stayawake-win32.exe"
echo "==> done"
