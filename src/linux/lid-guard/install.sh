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

# Default mode is "allow": installing must not change system behavior.
# Switch to "block" from the StayAwake tray menu (Lid Close on AC).
if [ ! -f "$CONF_DIR/lid-mode" ]; then
  echo allow > "$CONF_DIR/lid-mode"
fi

systemctl --user daemon-reload
systemctl --user enable --now ac-lid-guard.service

echo "lid guard installed and running."
echo "Switch modes from the StayAwake tray menu: 'Lid Close on AC'."
echo "Mode file: $CONF_DIR/lid-mode (block = do nothing, allow = suspend)."
