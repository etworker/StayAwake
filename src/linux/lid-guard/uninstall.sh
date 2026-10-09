#!/bin/bash
# Remove the StayAwake lid guard (user-level). The mode file is kept so a
# later reinstall remembers your choice; delete it manually if unwanted.
set -e

systemctl --user disable --now ac-lid-guard.service 2>/dev/null || true
rm -f "$HOME/.local/bin/ac-lid-guard.sh"
rm -f "$HOME/.config/systemd/user/ac-lid-guard.service"
systemctl --user daemon-reload

echo "lid guard removed. Mode file kept at: ${XDG_CONFIG_HOME:-$HOME/.config}/stayawake/lid-mode"
