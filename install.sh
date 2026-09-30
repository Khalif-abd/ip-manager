#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запустите install.sh через sudo/root.' >&2; exit 1; }
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install -d -m 700 /var/lib/ip-manager
install -m 755 "$SCRIPT_DIR/ip-manager.sh" /usr/local/sbin/ip-manager
touch /var/lib/ip-manager/managed.tsv /var/log/ip-manager.log
chmod 600 /var/lib/ip-manager/managed.tsv
chmod 640 /var/log/ip-manager.log
chown root:root /var/lib/ip-manager/managed.tsv /var/log/ip-manager.log
echo 'IP Manager установлен: sudo ip-manager'
