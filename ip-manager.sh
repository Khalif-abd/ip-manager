#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.1.0"
REPO="Khalif-abd/ip-manager"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
STATE_DIR=/var/lib/ip-manager
STATE_FILE="$STATE_DIR/managed.tsv"
LOG_FILE=/var/log/ip-manager.log
NETPLAN_FILE=/etc/netplan/90-ip-manager.yaml
IFUPDOWN_FILE=/etc/network/interfaces.d/ip-manager
NETWORKD_DROPIN_NAME=90-ip-manager.conf
CURL_TEST_URL="https://api.ipify.org"
LOCK_FILE=/run/ip-manager.lock

BACKEND="" IFACE="" PRIMARY_CIDR="" PRIMARY_IP="" GATEWAY="" OS_NAME="" OS_VERSION="" NETPLAN_TYPE="" NETPLAN_ID="" NM_UUID="" NETWORKD_FILE=""

say(){ printf '%s\n' "$*"; }
die(){ printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
warn(){ printf 'Внимание: %s\n' "$*" >&2; }
log_event(){ printf '%(%F %T)T %s\n' -1 "$*" >>"$LOG_FILE" 2>/dev/null || true; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Не найдена зависимость: $1"; }
backup_file(){ local f=$1; [[ -e $f ]] || return 0; cp -a -- "$f" "$f.ip-manager.bak.$(date +%Y%m%d%H%M%S)"; }
atomic_install(){ local src=$1 dst=$2 mode=${3:-600}; local dir tmp; dir=$(dirname "$dst"); mkdir -p "$dir"; tmp=$(mktemp "$dir/.ip-manager.XXXXXX"); cat "$src" >"$tmp"; chmod "$mode" "$tmp"; chown root:root "$tmp"; mv -fT "$tmp" "$dst"; }
confirm(){ local a; read -r -p "${1:-Продолжить? [y/N]: }" a || true; [[ $a =~ ^[YyДд]$ ]]; }

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите через sudo или от root."; }
init(){
  require_root; umask 077; mkdir -p "$STATE_DIR"; touch "$STATE_FILE" "$LOG_FILE"; chmod 600 "$STATE_FILE"; chmod 640 "$LOG_FILE"
  exec 9>"$LOCK_FILE"; flock -n 9 || die "Уже запущен другой экземпляр ip-manager."
  need ip; need awk; need sed; need grep; need sort; need mktemp; need flock; need python3
  detect_os; detect_network; reconcile_state
}

detect_os(){
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release
  case ${ID:-} in ubuntu|debian) ;; *) die "v1 поддерживает только Ubuntu и Debian (обнаружено: ${ID:-unknown}).";; esac
  OS_NAME=${NAME:-$ID}; OS_VERSION=${VERSION_ID:-unknown}
}

default_route_line(){ ip -4 route show default 2>/dev/null | awk '$1=="default" {print; exit}'; }

detect_network(){
  local r; r=$(default_route_line); [[ -n $r ]] || die "Не найден IPv4 default route."
  IFACE=$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$r")
  GATEWAY=$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$r")
  [[ -n $IFACE ]] || die "Не удалось однозначно определить интерфейс default route."

  # Primary = preferred source of the default route; fallback only when exactly one global IPv4 exists.
  PRIMARY_IP=$(ip -4 route get "${GATEWAY:-1.1.1.1}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  if [[ -z $PRIMARY_IP ]]; then
    mapfile -t _globals < <(ip -o -4 addr show dev "$IFACE" scope global | awk '{print $4}')
    ((${#_globals[@]}==1)) || die "Не удалось безопасно определить основной IPv4: на $IFACE несколько адресов и route-get не дал src."
    PRIMARY_IP=${_globals[0]%/*}
  fi
  PRIMARY_CIDR=$(ip -o -4 addr show dev "$IFACE" | awk -v ip="$PRIMARY_IP" '$4 ~ "^"ip"/" {print $4; exit}')
  [[ -n $PRIMARY_CIDR ]] || die "Основной IPv4 $PRIMARY_IP не найден на $IFACE."

  detect_backend
}

detect_backend(){
  local np=0 nm=0 nd=0 iu=0
  command -v netplan >/dev/null 2>&1 && compgen -G '/etc/netplan/*.yaml' >/dev/null && np=1
  command -v nmcli >/dev/null 2>&1 && nmcli -t -f GENERAL.STATE device show "$IFACE" 2>/dev/null | grep -qE '100|connected' && nm=1
  command -v networkctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-networkd 2>/dev/null && networkctl status "$IFACE" --no-pager 2>/dev/null | grep -q 'Network File:' && nd=1
  [[ -r /etc/network/interfaces ]] && command -v ifquery >/dev/null 2>&1 && ifquery "$IFACE" >/dev/null 2>&1 && iu=1

  # Netplan is the source of truth when it declares this interface, even if renderer is NM/networkd.
  if ((np)); then
    if detect_netplan_identity; then BACKEND=netplan; return; fi
  fi
  local count=$((nm+nd+iu)); ((count==1)) || die "Сетевой backend неоднозначен или не поддерживается (NM=$nm, networkd=$nd, ifupdown=$iu). Ничего не изменено."
  if ((nm)); then BACKEND=networkmanager; detect_nm_identity
  elif ((nd)); then BACKEND=networkd; detect_networkd_identity
  else BACKEND=ifupdown; detect_ifupdown_identity; fi
}

detect_netplan_identity(){
  need netplan
  local merged; merged=$(netplan get 2>/dev/null) || return 1
  # Parse YAML with PyYAML if available. Netplan installations normally provide python yaml, but fail safely otherwise.
  # Parse the merged model via netplan get; do not infer YAML ownership from filenames.
  python3 - "$IFACE" >"$STATE_DIR/.np-id" <<'PY' || return 1
import subprocess,sys
try:
 import yaml
except Exception: sys.exit(2)
data=yaml.safe_load(subprocess.check_output(['netplan','get'], text=True)) or {}
n=(data.get('network') or {})
iface=sys.argv[1]
hits=[]
for typ in ('ethernets','bonds','bridges','vlans'):
 for ident,cfg in (n.get(typ) or {}).items():
  if ident==iface: hits.append((typ,ident))
  elif isinstance(cfg,dict):
   m=cfg.get('match') or {}
   if m.get('name')==iface: hits.append((typ,ident))
if len(hits)!=1: sys.exit(3)
print(hits[0][0]); print(hits[0][1])
PY
  mapfile -t _np <"$STATE_DIR/.np-id"; rm -f "$STATE_DIR/.np-id"
  ((${#_np[@]}==2)) || return 1
  NETPLAN_TYPE=${_np[0]}; NETPLAN_ID=${_np[1]}; return 0
}

detect_nm_identity(){
  NM_UUID=$(nmcli -t -f GENERAL.CON-UUID device show "$IFACE" | cut -d: -f2- | head -n1)
  [[ -n $NM_UUID && $NM_UUID != -- ]] || die "NetworkManager: не удалось определить активный connection UUID для $IFACE."
}

detect_networkd_identity(){
  NETWORKD_FILE=$(networkctl status "$IFACE" --no-pager | sed -n 's/^[[:space:]]*Network File:[[:space:]]*//p' | head -n1)
  [[ $NETWORKD_FILE == /*.network && -f $NETWORKD_FILE ]] || die "systemd-networkd: не удалось определить применённый .network файл."
  [[ $NETWORKD_FILE != /run/systemd/network/*netplan* ]] || die "Обнаружен networkd-файл, сгенерированный Netplan, но Netplan-конфигурация интерфейса не определена. Fail-safe."
}

detect_ifupdown_identity(){
  grep -Eq '^[[:space:]]*(source|source-directory)[[:space:]]+/etc/network/interfaces\.d(/\*|[[:space:]]|$)' /etc/network/interfaces || \
    die "ifupdown обнаружен, но /etc/network/interfaces.d не подключён. v1 не будет менять основной /etc/network/interfaces."
  mkdir -p /etc/network/interfaces.d
}

valid_cidr(){ python3 - "$1" <<'PY'
import ipaddress,sys
try:
 x=sys.argv[1]
 if '/' not in x: x += '/32'
 i=ipaddress.ip_interface(x)
 assert i.version==4
 print(str(i))
except Exception: sys.exit(1)
PY
}
normalize_cidr(){ valid_cidr "$1"; }
ip_only(){ printf '%s\n' "${1%/*}"; }

managed_for_iface(){ awk -F '\t' -v d="$IFACE" '$1==d {print $2}' "$STATE_FILE" | sort -u; }
all_global(){ ip -o -4 addr show dev "$IFACE" scope global | awk '{print $4}' | sort -u; }
is_managed(){ grep -Fqx "$IFACE"$'\t'"$1" "$STATE_FILE"; }
reconcile_state(){
  local tmp; tmp=$(mktemp); while IFS=$'\t' read -r d a; do [[ -n ${d:-} && -n ${a:-} ]] || continue; printf '%s\t%s\n' "$d" "$a"; done <"$STATE_FILE" | sort -u >"$tmp"; mv "$tmp" "$STATE_FILE"
}

show_header(){
  say "IP Manager v$VERSION"; say ""; say "Система: $OS_NAME $OS_VERSION"; say "Backend: $BACKEND"; say "Интерфейс: $IFACE"; say "Основной IP: $PRIMARY_CIDR"; say "Gateway: ${GATEWAY:-не указан}"; say ""; say "Дополнительные IP:"
  local n=0 a; while read -r a; do [[ -n $a && $a != "$PRIMARY_CIDR" ]] || continue; ((++n)); if is_managed "$a"; then printf '  %d. %-22s [IP Manager]\n' "$n" "$a"; else printf '  %d. %-22s [системный]\n' "$n" "$a"; fi; done < <(all_global)
  ((n)) || say "  нет"
}

render_persistence(){
  local out=$1; mapfile -t ips < <(managed_for_iface)
  case $BACKEND in
    netplan)
      {
        echo 'network:'; echo '  version: 2'
        if ((${#ips[@]})); then
          printf '  %s:\n' "$NETPLAN_TYPE"; printf '    %s:\n' "$NETPLAN_ID"; echo '      addresses:'
          local a; for a in "${ips[@]}"; do printf '        - %s\n' "$a"; done
        fi
      } >"$out";;
    networkd)
      { echo '[Network]'; local a; for a in "${ips[@]}"; do printf 'Address=%s\n' "$a"; done; } >"$out";;
    ifupdown)
      {
        echo '# Managed by ip-manager. Do not edit manually.'
        if ((${#ips[@]})); then
          echo "iface $IFACE inet manual"
          local a; for a in "${ips[@]}"; do printf '    up ip address add %q dev %q || true\n' "$a" "$IFACE"; printf '    down ip address del %q dev %q || true\n' "$a" "$IFACE"; done
        fi
      } >"$out";;
    networkmanager) : >"$out";;
  esac
}

persist_validate_commit(){
  local tmp=$1
  case $BACKEND in
    netplan)
      backup_file "$NETPLAN_FILE"; atomic_install "$tmp" "$NETPLAN_FILE" 600
      if ! netplan generate >/tmp/ip-manager-netplan.err 2>&1; then
        local b; b=$(ls -1t "$NETPLAN_FILE".ip-manager.bak.* 2>/dev/null | head -n1 || true)
        [[ -n $b ]] && cp -a "$b" "$NETPLAN_FILE" || rm -f "$NETPLAN_FILE"
        netplan generate >/dev/null 2>&1 || true
        cat /tmp/ip-manager-netplan.err >&2; return 1
      fi;;
    networkd)
      local dir="${NETWORKD_FILE}.d" dst; mkdir -p "$dir"; dst="$dir/$NETWORKD_DROPIN_NAME"; backup_file "$dst"; atomic_install "$tmp" "$dst" 600
      # The generated drop-in contains only [Network]/Address= entries. Avoid network-wide reload merely to "validate" it.
      grep -q '^\[Network\]$' "$dst" || return 1
      while IFS= read -r line; do
        [[ $line == '[Network]' || -z $line ]] && continue
        [[ $line == Address=* ]] || return 1
        valid_cidr "${line#Address=}" >/dev/null || return 1
      done <"$dst";;
    ifupdown)
      backup_file "$IFUPDOWN_FILE"; atomic_install "$tmp" "$IFUPDOWN_FILE" 600
      ifquery --list >/dev/null 2>&1 || return 1;;
    networkmanager)
      # Persist managed addresses by appending/removing only our values on the existing active profile.
      local current desired a
      current=$(nmcli -g ipv4.addresses connection show uuid "$NM_UUID" || true)
      mapfile -t desired < <(managed_for_iface)
      # Remove only addresses previously owned but no longer in state, tracked via caller snapshot is unavailable;
      # normalize by preserving all non-managed-live profile addresses and adding desired managed values.
      mapfile -t oldmanaged < <(awk -F '\t' -v d="$IFACE" '$1==d {print $2}' "$STATE_FILE.prev" 2>/dev/null || true)
      for a in "${oldmanaged[@]}"; do nmcli connection modify uuid "$NM_UUID" -ipv4.addresses "$a" 2>/dev/null || true; done
      for a in "${desired[@]}"; do nmcli connection modify uuid "$NM_UUID" +ipv4.addresses "$a"; done
      nmcli connection verify uuid "$NM_UUID" >/dev/null;;
  esac
}

commit_state_and_persistence(){
  local newstate=$1 tmpcfg; cp -a "$STATE_FILE" "$STATE_FILE.prev"; cp "$newstate" "$STATE_FILE"; tmpcfg=$(mktemp); render_persistence "$tmpcfg"
  if ! persist_validate_commit "$tmpcfg"; then cp "$STATE_FILE.prev" "$STATE_FILE"; rm -f "$tmpcfg"; die "Проверка постоянной конфигурации не прошла. State возвращён; runtime не изменён."; fi
  rm -f "$tmpcfg" "$STATE_FILE.prev"
}

add_ips(){
  local line token norm ip; read -r -p "Введите IP-адреса через пробел: " line
  [[ -n $line ]] || return 0
  local -a add=(); declare -A seen=()
  local -a tokens=()
  IFS=' ' read -r -a tokens <<<"$line"
  for token in "${tokens[@]}"; do
    norm=$(normalize_cidr "$token") || die "Некорректный IPv4/CIDR: $token"; ip=$(ip_only "$norm")
    [[ $ip != "$PRIMARY_IP" ]] || die "Нельзя добавить основной IP: $ip"
    [[ -z ${seen[$norm]+x} ]] || die "Дубликат во вводе: $norm"; seen[$norm]=1
    ! ip -o -4 addr show dev "$IFACE" | awk '{print $4}' | grep -Fqx "$norm" || die "$norm уже назначен $IFACE."
    add+=("$norm")
  done
  say ""; say "Будут добавлены:"; printf '+ %s\n' "${add[@]}"; say ""; confirm || { say "Отменено."; return; }
  local ns; ns=$(mktemp); cp "$STATE_FILE" "$ns"; for norm in "${add[@]}"; do printf '%s\t%s\n' "$IFACE" "$norm" >>"$ns"; done; sort -u -o "$ns" "$ns"
  commit_state_and_persistence "$ns"; rm -f "$ns"
  # Runtime is deliberately changed only after persistent config validated; no network-wide reload.
  local added=(); for norm in "${add[@]}"; do if ip address add "$norm" dev "$IFACE"; then added+=("$norm"); else for token in "${added[@]}"; do ip address del "$token" dev "$IFACE" || true; done; die "Не удалось назначить $norm. Постоянная конфигурация уже записана; удалите адрес через меню перед reboot."; fi; done
  for norm in "${add[@]}"; do log_event "ADD $norm $IFACE SUCCESS"; done
  say "Готово. Сеть целиком не перезапускалась."; verify_list "${add[@]}"
}

select_managed(){ mapfile -t SELECTABLE < <(managed_for_iface); ((${#SELECTABLE[@]})) || { say "Нет IP под управлением IP Manager."; return 1; }; local i; for i in "${!SELECTABLE[@]}"; do printf '[%d] %s\n' "$((i+1))" "${SELECTABLE[$i]}"; done; }

delete_ips(){
  select_managed || return 0; local line x idx; read -r -p "Какие IP удалить? Номера через пробел: " line; [[ -n $line ]] || return
  local -a del=() nums=(); declare -A seen=(); IFS=' ' read -r -a nums <<<"$line"; for x in "${nums[@]}"; do [[ $x =~ ^[0-9]+$ ]] || die "Некорректный номер: $x"; idx=$((x-1)); ((idx>=0 && idx<${#SELECTABLE[@]})) || die "Нет пункта $x"; [[ -z ${seen[$idx]+x} ]] || continue; seen[$idx]=1; del+=("${SELECTABLE[$idx]}"); done
  say ""; say "Будут удалены:"; printf -- '- %s\n' "${del[@]}"; say ""; confirm || { say "Отменено."; return; }
  local ns a; ns=$(mktemp); cp "$STATE_FILE" "$ns"; for a in "${del[@]}"; do awk -F '\t' -v d="$IFACE" -v a="$a" '!( $1==d && $2==a )' "$ns" >"$ns.x"; mv "$ns.x" "$ns"; done
  commit_state_and_persistence "$ns"; rm -f "$ns"
  for a in "${del[@]}"; do ip address del "$a" dev "$IFACE" 2>/dev/null || warn "$a отсутствовал в runtime"; log_event "DELETE $a $IFACE SUCCESS"; done
  say "Готово. Основной IP, gateway и чужие адреса не изменялись."
}

verify_one(){
  local a=$1 ip=${1%/*}; printf '%s\n' "$a"
  if ip -o -4 addr show dev "$IFACE" | awk '{print $4}' | grep -Fqx "$a"; then say "  ✓ IP назначен локально"; else say "  ✗ IP не назначен локально"; fi
  if is_managed "$a"; then say "  ✓ отмечен как постоянный IP Manager"; else say "  ? не управляется IP Manager"; fi
  if command -v curl >/dev/null 2>&1; then
    local out; if out=$(curl --interface "$ip" -4 -fsS --connect-timeout 5 --max-time 10 "$CURL_TEST_URL" 2>/dev/null); then say "  ✓ исходящее соединение работает (внешний IP: $out)"; else say "  ✗ исходящее соединение через source IP не работает"; say "    Возможна проблема маршрутизации/назначения IP у провайдера; IP Manager API провайдера не настраивает."; fi
  else say "  ? curl не установлен — внешний тест пропущен"; fi
}
verify_list(){ local a; for a in "$@"; do verify_one "$a"; done; }
verify_menu(){ local -a arr; mapfile -t arr < <(all_global); verify_list "${arr[@]}"; }

import_ips(){
  say "Импорт в v1 выполняется только как принятие ownership без удаления исходной конфигурации."; say "Это безопасно лишь если адрес НЕ объявлен в постоянной конфигурации другого менеджера."
  local -a candidates=(); local a; while read -r a; do [[ $a == "$PRIMARY_CIDR" ]] && continue; is_managed "$a" && continue; candidates+=("$a"); done < <(all_global)
  ((${#candidates[@]})) || { say "Нет кандидатов."; return; }
  local i; for i in "${!candidates[@]}"; do printf '[%d] %s\n' "$((i+1))" "${candidates[$i]}"; done
  say ""; warn "Автоматическая миграция чужих persistent-конфигов отключена в v1: Netplan sequence нельзя безопасно вычесть overlay-файлом, а ownership NM/networkd/ifupdown может быть неоднозначным."
  say "Используйте диагностику и сначала удалите адрес из исходного конфигурационного источника вручную. После этого перезапустите ip-manager и добавьте его обычным пунктом «Добавить IP»."
}

diagnostics(){
  say "=== IP Manager diagnostics ==="; date -Is; say "Version: $VERSION"; say "OS: $OS_NAME $OS_VERSION"; say "Backend: $BACKEND"; say "Default interface: $IFACE"; say "Primary IPv4: $PRIMARY_CIDR"; say "Gateway: ${GATEWAY:-none}"; say "Netplan type/id: ${NETPLAN_TYPE:-n/a}/${NETPLAN_ID:-n/a}"; say "NM UUID: ${NM_UUID:-n/a}"; say "networkd file: ${NETWORKD_FILE:-n/a}"; say ""; say "--- ip -4 addr ---"; ip -4 addr show; say ""; say "--- ip -4 route ---"; ip -4 route show; say ""; say "--- Managed IP ($IFACE) ---"; managed_for_iface || true; say ""; say "--- System IP ($IFACE) ---"; local a; while read -r a; do is_managed "$a" || echo "$a"; done < <(all_global); say ""; say "--- Services ---"; for a in systemd-networkd NetworkManager; do printf '%s: ' "$a"; systemctl is-active "$a" 2>/dev/null || true; done
  if [[ $BACKEND == netplan ]]; then say ""; say "--- netplan get (network config; проверьте перед публикацией) ---"; netplan get 2>/dev/null || true; fi
}


show_version(){
  say "IP Manager v$VERSION"
}

self_update(){
  require_root
  need curl
  local tmp remote_version
  tmp=$(mktemp)
  say "Проверяю обновления IP Manager..."
  if ! curl -fL --retry 3 --connect-timeout 10 --max-time 60 -o "$tmp" "$RAW_BASE/ip-manager.sh"; then
    rm -f "$tmp"
    die "Не удалось скачать новую версию из GitHub. Текущая установка не изменена."
  fi
  if ! bash -n "$tmp"; then
    rm -f "$tmp"
    die "Скачанный файл не прошёл bash -n. Текущая установка не изменена."
  fi
  remote_version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$tmp" | head -n1)
  [[ -n $remote_version ]] || { rm -f "$tmp"; die "Не удалось определить версию скачанного файла."; }
  if [[ $remote_version == "$VERSION" ]]; then
    rm -f "$tmp"
    say "Уже установлена актуальная версия: v$VERSION"
    return 0
  fi
  install -m 755 "$tmp" /usr/local/sbin/ip-manager.new
  mv -f /usr/local/sbin/ip-manager.new /usr/local/sbin/ip-manager
  rm -f "$tmp"
  log_event "UPDATE $VERSION -> $remote_version SUCCESS"
  say "IP Manager обновлён: v$VERSION → v$remote_version"
  say "Запустите снова: sudo ip-manager"
}

self_uninstall(){
  require_root
  say "Удаление IP Manager"
  say ""
  if [[ -s $STATE_FILE ]]; then
    say "Сейчас IP Manager управляет следующими адресами:"
    cat "$STATE_FILE"
    say ""
    warn "Удаление программы НЕ снимет эти IP и НЕ удалит persistent network-конфигурацию."
    warn "Это сделано специально, чтобы рабочие IP не исчезли после uninstall/reboot."
    say "Если IP больше не нужны, сначала удалите их через пункт 2 основного меню."
    say ""
  fi
  confirm "Удалить только программу /usr/local/sbin/ip-manager? [y/N]: " || { say "Отменено."; return 0; }
  rm -f /usr/local/sbin/ip-manager
  log_event "UNINSTALL BINARY SUCCESS"
  say "IP Manager удалён. State, лог и managed network-конфигурация оставлены на месте."
}

menu(){
  while true; do clear 2>/dev/null || true; detect_network; show_header; cat <<'M'

1) Добавить IP
2) Удалить IP
3) Показать IP
4) Проверить IP
5) Импортировать существующие IP
6) Диагностика
7) Обновить IP Manager
8) Удалить IP Manager
0) Выход
M
    local c; read -r -p "Выберите действие: " c || exit 0
    case $c in 1)add_ips;;2)delete_ips;;3)show_header;;4)verify_menu;;5)import_ips;;6)diagnostics;;7)self_update; exit 0;;8)self_uninstall; exit 0;;0)exit 0;;*)say "Неизвестный пункт.";; esac
    say ""; read -r -p "Enter — продолжить..." _ || true
  done
}

case "${1:-}" in
  --version|version) show_version; exit 0 ;;
  update|--update)
    require_root; umask 077; mkdir -p "$STATE_DIR"; touch "$STATE_FILE" "$LOG_FILE"
    self_update; exit 0 ;;
  uninstall|remove|--uninstall)
    require_root; umask 077; mkdir -p "$STATE_DIR"; touch "$STATE_FILE" "$LOG_FILE"
    self_uninstall; exit 0 ;;
  "") init; menu ;;
  *) printf 'Использование: sudo ip-manager [update|uninstall|version]\n' >&2; exit 2 ;;
esac
