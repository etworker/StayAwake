#!/bin/bash
# StayAwake lid guard (user-level, no sudo required).
#
# While the AC adapter is PHYSICALLY present and mode is "block", hold a
# logind inhibitor (sleep + handle-lid-switch) so that closing the lid does
# nothing. Reading the adapter state from /sys (kernel) instead of UPower
# makes this immune to UPower AC misdetection bugs.
#
# Mode file: ${XDG_CONFIG_HOME:-$HOME/.config}/stayawake/lid-mode
#   block = lid close on AC does nothing (guard active)
#   allow = system default behavior (GNOME suspends on lid close)
# The guard reads the mode file every cycle, so the tray can switch modes
# without restarting anything.

MODE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/stayawake/lid-mode"

while :; do
  MODE=$(cat "$MODE_FILE" 2>/dev/null || echo allow)
  if [ "$MODE" = "block" ] && grep -q "^1$" /sys/class/power_supply/A*/online 2>/dev/null; then
    systemd-inhibit --what=sleep:handle-lid-switch --who="StayAwake lid-guard" \
      --why="AC lid close = do nothing (user choice)" \
      bash -c 'MF="${XDG_CONFIG_HOME:-$HOME/.config}/stayawake/lid-mode"; while [ "$(cat "$MF" 2>/dev/null || echo allow)" = "block" ] && grep -q "^1$" /sys/class/power_supply/A*/online 2>/dev/null; do sleep 3; done'
  else
    sleep 3
  fi
done
