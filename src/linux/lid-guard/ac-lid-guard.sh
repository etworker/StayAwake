#!/bin/bash
# StayAwake lid guard (user-level, no sudo required).
#
# Holds logind inhibitors so that the per-power-source lid policy chosen in
# the tray takes effect (the kernel's own lid handling must not fire first):
#   on AC,      lid-ac=awake (default) -> sleep:handle-lid-switch inhibitor:
#       closing the lid does nothing, and idle sleep is held too (headless
#       use of a closed lid on power keeps working as it always has)
#   on battery, lid-ac=awake AND lid-battery-mins != 0 -> handle-lid-switch
#       inhibitor only: the close event itself is blocked while a timer
#       window can run, but idle sleep is NOT held (sleeping earlier than
#       the timer is allowed, same as macOS) and the app's `systemctl
#       suspend` is not blocked by our own inhibitor. The lid-ac gate
#       mirrors the engine: the awake-on-power checkbox is the master
#       switch for the whole lid policy.
# Any other combination -> no inhibitor, system default behavior.
#
# Config dir: ${XDG_CONFIG_HOME:-$HOME/.config}/stayawake
#   lid-ac            awake|default (missing = awake)
#   lid-battery-mins  0|1|5|15|30|60|-1 (missing = 0: sleep on close)
# The guard re-reads both files every cycle, so the tray can change the
# policy without restarting anything. Reading the adapter state from /sys
# (kernel) instead of UPower makes this immune to UPower AC misdetection
# bugs.

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/stayawake"

ac_online() { grep -q "^1$" /sys/class/power_supply/A*/online 2>/dev/null; }

# What should be inhibited right now: "both" (on AC, awake on close),
# "lid" (on battery, policy on and a timer or never mode is armed), or "none".
desired() {
  if ac_online; then
    if [ "$(cat "$CONF_DIR/lid-ac" 2>/dev/null || echo awake)" = "awake" ]; then
      echo both
      return
    fi
  elif [ "$(cat "$CONF_DIR/lid-ac" 2>/dev/null || echo awake)" = "awake" ] \
       && [ "$(cat "$CONF_DIR/lid-battery-mins" 2>/dev/null || echo 0)" != "0" ]; then
    echo lid
    return
  fi
  echo none
}

while :; do
  case "$(desired)" in
    both)
      systemd-inhibit --what=sleep:handle-lid-switch --who="StayAwake lid-guard" \
        --why="AC lid close = do nothing (user choice)" \
        bash -c 'CONF="${XDG_CONFIG_HOME:-$HOME/.config}/stayawake"; while [ "$(cat "$CONF/lid-ac" 2>/dev/null || echo awake)" = "awake" ] && grep -q "^1$" /sys/class/power_supply/A*/online 2>/dev/null; do sleep 3; done'
      ;;
    lid)
      systemd-inhibit --what=handle-lid-switch --who="StayAwake lid-guard" \
        --why="battery lid timer armed" \
        bash -c 'CONF="${XDG_CONFIG_HOME:-$HOME/.config}/stayawake"; while [ "$(cat "$CONF/lid-ac" 2>/dev/null || echo awake)" = "awake" ] && [ "$(cat "$CONF/lid-battery-mins" 2>/dev/null || echo 0)" != "0" ] && ! grep -q "^1$" /sys/class/power_supply/A*/online 2>/dev/null; do sleep 3; done'
      ;;
    *)
      sleep 3
      ;;
  esac
done
