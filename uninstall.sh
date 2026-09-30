#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запустите uninstall.sh через sudo/root.' >&2; exit 1; }
if [[ -x /usr/local/sbin/ip-manager ]]; then
  exec /usr/local/sbin/ip-manager uninstall
fi
STATE=/var/lib/ip-manager/managed.tsv
if [[ -s $STATE ]]; then
  echo 'IP Manager не установлен, но найден state с managed IP:'
  cat "$STATE"
  echo 'State и сетевую конфигурацию автоматически не удаляем.'
fi
rm -f /usr/local/sbin/ip-manager
echo 'Бинарник IP Manager отсутствует/удалён. Сетевая конфигурация и state сохранены.'
