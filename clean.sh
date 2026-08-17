#!/bin/sh

# Clean build intermediates (compiled units / object files) under out/.
# Keeps the final binaries and .app bundles. Safe: only generated 'units*'
# directories and stray *.o / *.ppu files are removed.
# For a full wipe of all build output, run: rm -rf out

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/out"

if [ ! -d "$OUT" ]; then
  echo "nothing to clean ($OUT does not exist)"
  exit 0
fi

echo "cleaning build intermediates under $OUT ..."

# Remove per-arch / per-platform intermediate unit directories.
find "$OUT" -type d -name 'units'   -prune -exec rm -rf {} +
find "$OUT" -type d -name 'units-*' -prune -exec rm -rf {} +

# Remove any stray object / ppu files left outside those directories.
find "$OUT" -type f \( -name '*.o' -o -name '*.ppu' \) -delete

echo "done."
