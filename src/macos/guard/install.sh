#!/bin/sh

# One-time install of the StayAwake lid guard (macOS, Apple Silicon).
# Run ONCE from Terminal:   sudo ./install.sh
#
# What it does:
#   1. Applies `pmset -a disablesleep 1` - the lid switch stops putting the
#      machine to sleep (on AC and battery both).
#   2. Installs a SCOPED sudoers entry so the StayAwake app can toggle the
#      guard and sleep on demand WITHOUT ever asking for a password again.
#      The entry whitelists exactly three commands; nothing else.
#
# Undo at any time:  sudo ./uninstall.sh
# (or delete /etc/sudoers.d/stayawake and run `pmset -a disablesleep 0`)

set -e

[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行: sudo $0"; exit 1; }

USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
ENT="/etc/sudoers.d/stayawake"

printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -c disablesleep 1, /usr/bin/pmset -c disablesleep 0, /usr/bin/pmset -b disablesleep 1, /usr/bin/pmset -b disablesleep 0, /usr/bin/pmset sleepnow\n' \
  "$USER_NAME" > "$ENT.tmp"
chmod 0440 "$ENT.tmp"
# Validate before installing: a broken sudoers file would break sudo itself.
if visudo -cf "$ENT.tmp" > /dev/null; then
  mv "$ENT.tmp" "$ENT"
else
  rm -f "$ENT.tmp"
  echo "sudoers 校验失败,未安装" >&2
  exit 1
fi

/usr/bin/pmset -a disablesleep 1

echo "已安装: 合盖保持唤醒已生效(插电/电池),应用切换与「立即睡眠」不再需要密码。"
echo "恢复系统默认: 托盘菜单选「系统默认」,或 sudo ./uninstall.sh"
