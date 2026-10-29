#!/bin/sh

# Uninstall the StayAwake lid guard (macOS).
# Run from Terminal:  sudo ./uninstall.sh
#
# Removes the scoped sudoers entry and restores the system default
# (closing the lid sleeps again, the Apple-menu Sleep item works).

set -e

[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行: sudo $0"; exit 1; }

rm -f /etc/sudoers.d/stayawake
/usr/bin/pmset -a disablesleep 0

echo "已卸载: 合盖行为恢复系统默认,应用菜单「立即睡眠」改用系统授权框。"
