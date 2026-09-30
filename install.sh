#!/usr/bin/env bash
set -Eeuo pipefail

REPO="Khalif-abd/ip-manager"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
INSTALL_PATH="/usr/local/sbin/ip-manager"
STATE_DIR="/var/lib/ip-manager"
STATE_FILE="$STATE_DIR/managed.tsv"
LOG_FILE="/var/log/ip-manager.log"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запустите установщик через sudo/root.' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo 'Ошибка: для remote-установки нужен curl.' >&2; exit 1; }

umask 077
install -d -m 700 "$STATE_DIR"
touch "$STATE_FILE" "$LOG_FILE"
chmod 600 "$STATE_FILE"
chmod 640 "$LOG_FILE"
chown root:root "$STATE_FILE" "$LOG_FILE"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Если install.sh запущен из git clone, предпочитаем локальный ip-manager.sh.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
if [[ -n ${SCRIPT_DIR:-} && -f "$SCRIPT_DIR/ip-manager.sh" ]]; then
  cp "$SCRIPT_DIR/ip-manager.sh" "$tmp"
else
  echo 'Скачиваю IP Manager из GitHub...'
  curl -fL --retry 3 --connect-timeout 10 --max-time 60 -o "$tmp" "$RAW_BASE/ip-manager.sh"
fi

bash -n "$tmp" || { echo 'Ошибка: ip-manager.sh не прошёл проверку bash -n. Установка отменена.' >&2; exit 1; }
version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$tmp" | head -n1)
[[ -n $version ]] || { echo 'Ошибка: не удалось определить версию IP Manager.' >&2; exit 1; }

install -m 755 "$tmp" "$INSTALL_PATH.new"
mv -f "$INSTALL_PATH.new" "$INSTALL_PATH"

echo "IP Manager v$version установлен."
echo 'Запуск: sudo ip-manager'
echo 'Обновление: sudo ip-manager update'
echo 'Удаление: sudo ip-manager uninstall'
