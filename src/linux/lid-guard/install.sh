#!/bin/bash
# Install the StayAwake lid guard (user-level systemd service).
# No sudo required: everything lives under your home directory.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/stayawake"

mkdir -p "$BIN_DIR" "$UNIT_DIR" "$CONF_DIR"

install -m 755 "$DIR/ac-lid-guard.sh" "$BIN_DIR/ac-lid-guard.sh"
install -m 644 "$DIR/ac-lid-guard.service" "$UNIT_DIR/ac-lid-guard.service"

# No defaults are written: the shared defaults apply (lid-ac missing =
# awake on power, lid-battery-mins missing = sleep on close). Adjust the
# per-source policy from the StayAwake tray menu.

systemctl --user daemon-reload
systemctl --user enable --now ac-lid-guard.service

echo "lid guard installed and running."
echo "Per-source lid policy lives in the StayAwake tray menu."
echo "Config files: $CONF_DIR/lid-ac, $CONF_DIR/lid-battery-mins"
