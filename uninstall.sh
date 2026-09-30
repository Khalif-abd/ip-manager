#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запустите uninstall.sh через sudo/root.' >&2; exit 1; }
STATE=/var/lib/ip-manager/managed.tsv
if [[ -s $STATE ]]; then
  echo 'IP Manager сейчас хранит следующие managed IP:'
  cat "$STATE"
  echo
  echo 'Удаление программы НЕ должно молча снимать рабочие IP.'
  echo 'Сначала удалите ненужные IP через sudo ip-manager.'
  read -r -p 'Удалить только программу, оставив managed-конфигурацию и state на месте? [y/N]: ' a
  [[ $a =~ ^[YyДд]$ ]] || { echo 'Отменено.'; exit 0; }
fi
rm -f /usr/local/sbin/ip-manager
echo 'Бинарник удалён. /var/lib/ip-manager, лог и сетевые managed-файлы оставлены намеренно.'
echo 'Это предотвращает неожиданное исчезновение IP после reboot.'
