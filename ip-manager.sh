#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.3.6"
REPO="Khalif-abd/ip-manager"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
STATE_DIR=/var/lib/ip-manager
STATE_FILE="$STATE_DIR/managed.tsv"
SUBNETS_FILE="$STATE_DIR/subnets.tsv"
BLOCKED_FILE="$STATE_DIR/blocked.tsv"
BACKUP_DIR="$STATE_DIR/backups"
LOG_FILE=/var/log/ip-manager.log
NETPLAN_FILE=/etc/netplan/90-ip-manager.yaml
IFUPDOWN_FILE=/etc/network/interfaces.d/ip-manager
NETWORKD_DROPIN_NAME=90-ip-manager.conf
SYSCTL_FILE=/etc/sysctl.d/90-ip-manager.conf
CURL_TEST_URL="https://api.ipify.org"
LOCK_FILE=/run/ip-manager.lock

NETPLAN_WHY=""
BACKEND="" IFACE="" PRIMARY_CIDR="" PRIMARY_IP="" GATEWAY="" OS_NAME="" OS_VERSION="" NETPLAN_TYPE="" NETPLAN_ID="" NM_UUID="" NETWORKD_FILE=""
ASSUME_YES=0 WORK=""

say(){ printf '%s\n' "$*"; }
die(){ printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
warn(){ printf 'Внимание: %s\n' "$*" >&2; }
log_event(){ printf '%(%F %T)T %s\n' -1 "$*" >>"$LOG_FILE" 2>/dev/null || true; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Не найдена зависимость: $1"; }
backup_file(){ local f=$1; [[ -e $f ]] || return 0; mkdir -p "$BACKUP_DIR/files" && cp -a -- "$f" "$BACKUP_DIR/files/$(basename "$f").$(date +%Y%m%d%H%M%S)"; }
# Every step is checked explicitly: callers run this inside `if`/`||`, where set -e is OFF. Without the checks a
# full disk produced an EMPTY file that was moved over the real config and reported as success; the IPs then
# vanished at the next networkd restart. On failure $dst is never touched.
atomic_install(){
  local src=$1 dst=$2 mode=${3:-600} dir tmp
  dir=$(dirname -- "$dst")
  # New directories must be traversable by systemd-network (networkd drop-in dir); umask 077 gave 0700.
  if [[ ! -d $dir ]]; then (umask 022; mkdir -p -- "$dir") || { warn "Не удалось создать каталог $dir"; return 1; }; fi
  tmp=$(mktemp -- "$dir/.ip-manager.XXXXXX") || { warn "Не удалось создать временный файл в $dir (диск заполнен или только для чтения?)"; return 1; }
  if cat -- "$src" >"$tmp" && cmp -s -- "$src" "$tmp" && chmod "$mode" -- "$tmp" && chown root:root -- "$tmp" \
     && sync -- "$tmp" && mv -fT -- "$tmp" "$dst" && cmp -s -- "$src" "$dst"; then
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  warn "Не удалось записать $dst (диск заполнен или файловая система только для чтения?)"
  return 1
}
# systemd-networkd reads its configs as the unprivileged user systemd-network. Netplan writes them
# as 0640 root:systemd-network, but under our umask 077 they came out 0600: invisible to networkd.
# Nothing breaks until networkd restarts (e.g. a package upgrade) — then every additional IP disappears.
netplan_gen(){ (umask 022; netplan generate); }
networkd_config_paths(){
  case $BACKEND in
    # Only .network/.netdev are read by networkd; .link files are read by udev as root and stay root:root.
    netplan) compgen -G '/run/systemd/network/*netplan*.network' || true; compgen -G '/run/systemd/network/*netplan*.netdev' || true;;
    networkd) printf '%s\n' "$NETWORKD_FILE"; [[ -e "${NETWORKD_FILE}.d/$NETWORKD_DROPIN_NAME" ]] && printf '%s\n' "${NETWORKD_FILE}.d/$NETWORKD_DROPIN_NAME";;
  esac
  return 0
}
# Prints configs systemd-network cannot read; empty output = OK (or the check is impossible).
networkd_unreadable(){
  [[ $BACKEND == netplan || $BACKEND == networkd ]] || return 0
  id systemd-network >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 || return 0
  local f; while read -r f; do
    [[ -n $f ]] || continue
    runuser -u systemd-network -- test -r "$f" 2>/dev/null || printf '%s\n' "$f"
  done < <(networkd_config_paths)
}
# Fixes configs left unreadable by older versions; the runtime network is not touched.
repair_networkd_perms(){
  local bad f; bad=$(networkd_unreadable); [[ -n $bad ]] || return 0
  warn "systemd-networkd не может прочитать свою конфигурацию — при перезапуске сети дополнительные IP пропадут:"
  while read -r f; do printf '  %s\n' "$f" >&2; done <<<"$bad"
  case $BACKEND in
    netplan) netplan_gen >/dev/null 2>&1 || warn "netplan generate завершился ошибкой — проверьте: sudo netplan generate";;
    networkd) while read -r f; do
        [[ -n $f ]] || continue
        # Versions before 1.3.6 created the drop-in directory as 0700 (umask 077): networkd cannot traverse it.
        [[ $f == "${NETWORKD_FILE}.d/$NETWORKD_DROPIN_NAME" ]] && chmod go+rx -- "${NETWORKD_FILE}.d"
        chmod go+r -- "$f"
      done <<<"$bad";;
  esac
  bad=$(networkd_unreadable)
  if [[ -n $bad ]]; then
    case $BACKEND in
      netplan) warn "Права исправить не удалось. Проверьте вручную: ls -l /run/systemd/network/";;
      *) warn "Права исправить не удалось. Проверьте вручную права файлов и их каталогов (ls -ld): ${bad//$'\n'/ }";;
    esac
  else say "✓ Права конфигурации systemd-networkd исправлены (runtime-сеть не перезапускалась)."; log_event "REPAIR networkd config permissions"; fi
}

confirm(){
  local a
  if ((ASSUME_YES)); then say "${1:-Продолжить? [y/N]: }y (--yes)"; return 0; fi
  read -r -p "${1:-Продолжить? [y/N]: }" a || true; [[ $a =~ ^[YyДд]$ ]]
}

# ---------------------------------------------------------------------------
# IPv4 math and validation live in one embedded Python helper (stdlib only).
# It never touches the system: bash passes it snapshots of state as files.
# ---------------------------------------------------------------------------
PY_HELPER=$(cat <<'PY'
import argparse, ipaddress as A, random, sys

MAXN = 1024

def die(m):
    print('Ошибка: ' + m, file=sys.stderr); sys.exit(1)

def lines(p):
    if not p: return []
    try:
        with open(p, encoding='utf-8') as f: return [l.rstrip('\n') for l in f if l.strip()]
    except FileNotFoundError: return []

def ipset(p):
    s = set()
    for l in lines(p):
        try: s.add(A.IPv4Interface(l.split('\t')[0].strip()).ip)
        except ValueError: pass
    return s

def parse_ip(s, tok):
    try: return A.IPv4Address(s.strip())
    except ValueError: die(f'некорректный IPv4: {tok}')

class Ctx:
    def __init__(self, a):
        self.subs = []
        for l in lines(a.subnets):
            f = l.split('\t')
            if len(f) < 6 or f[0] != a.iface: continue
            self.subs.append(dict(net=A.IPv4Network(f[1]), gw=None if f[2] in ('', '-') else A.IPv4Address(f[2]),
                                  table=f[3], prio=f[4], routing=f[5]))
        self.primary = A.IPv4Address(a.primary) if a.primary else None
        self.gws = {s['gw'] for s in self.subs if s['gw']}
        if a.gw: self.gws.add(A.IPv4Address(a.gw))
        self.existing = ipset(a.existing)
        self.blocked = ipset(a.blocked)
        self.managed = {}
        for l in lines(a.managed):
            i = A.IPv4Interface(l.strip()); self.managed[i.ip] = i

    def owner(self, ip):
        return next((s for s in self.subs if ip in s['net']), None)

def expand(tok):
    """-> [(ip, prefix|None, from_range)]"""
    tok = tok.strip()
    if '-' in tok:
        if '/' in tok: die(f'{tok}: у диапазона маска не указывается — она берётся из зарегистрированной подсети (ip-manager subnet add)')
        a, b = tok.split('-', 1); start = parse_ip(a, tok)
        if b.isdigit():
            if int(b) > 255: die(f'{tok}: последний октет больше 255')
            end = A.IPv4Address((int(start) & 0xFFFFFF00) | int(b))
        else:
            end = parse_ip(b, tok)
        if end < start: die(f'{tok}: конец диапазона меньше начала')
        n = int(end) - int(start) + 1
        if n > MAXN: die(f'{tok}: слишком большой диапазон ({n} адресов, максимум {MAXN})')
        return [(A.IPv4Address(int(start) + i), None, True) for i in range(n)]
    if '/' in tok:
        try: i = A.IPv4Interface(tok)
        except ValueError: die(f'некорректный IPv4/CIDR: {tok}')
        n = i.network
        if n.prefixlen <= 30 and i.ip == n.network_address:
            die(f'{tok} — это адрес сети, а не один IP. Адреса из подсети добавляются диапазоном '
                f'(например {n.network_address + 2}-{int(str(n.broadcast_address - 1).split(".")[-1])}) '
                f'или случайно: ip-manager add --random N --from {n}')
        return [(i.ip, n.prefixlen, False)]
    return [(parse_ip(tok, tok), None, False)]

def resolve(c, ip, prefix):
    own = c.owner(ip)
    if own:
        sp = own['net'].prefixlen
        if prefix is not None and prefix != sp:
            die(f'{ip}/{prefix}: адрес входит в зарегистрированную подсеть {own["net"]} — маска должна быть /{sp} (или укажите IP без маски)')
        return A.IPv4Interface(f'{ip}/{sp}'), own
    return A.IPv4Interface(f'{ip}/{32 if prefix is None else prefix}'), None

def problem(c, i):
    ip, n = i.ip, i.network
    if ip.is_loopback or ip.is_multicast or ip.is_unspecified or ip.is_link_local or ip.is_reserved:
        return 'служебный адрес (loopback/multicast/link-local/reserved)'
    if n.prefixlen <= 30 and ip == n.network_address: return f'адрес сети {n}'
    if n.prefixlen <= 30 and ip == n.broadcast_address: return f'broadcast-адрес подсети {n}'
    if ip in c.gws: return 'адрес шлюза — назначать его серверу нельзя'
    if ip == c.primary: return 'основной IP сервера'
    if ip in c.existing: return 'уже назначен на сервере'
    if ip in c.blocked: return 'помечен как заблокированный (снять: ip-manager unblock IP)'
    return None

def parse_net(s):
    try: i = A.IPv4Interface(s)
    except ValueError: die(f'некорректная подсеть: {s}')
    if '/' not in s: die(f'{s}: укажите подсеть с маской, например 179.253.180.32/27')
    if i.ip != i.network.network_address: die(f'{s}: укажите адрес сети — {i.network}')
    return i.network

def cmd_plan_add(a):
    c = Ctx(a); out = []; seen = set(); warns = []; unreg = set()
    for tok in a.tokens:
        for ip, pre, rng in expand(tok):
            i, own = resolve(c, ip, pre)
            p = problem(c, i) or ('указан повторно' if ip in seen else None)
            if p:
                if rng:
                    if ip not in seen: warns.append(f'{ip}: пропущен — {p}')
                    continue
                die(f'{ip}: {p}')
            seen.add(ip); out.append(i)
            if own is None and i.network.prefixlen < 32: unreg.add(i.network)
    if a.random is not None:
        if a.random < 1: die('--random: количество должно быть больше нуля')
        if a.frm: n = parse_net(a.frm)
        elif len(c.subs) == 1: n = c.subs[0]['net']
        elif not c.subs: die('нет зарегистрированных подсетей — укажите --from, например --from 179.253.180.32/27')
        else: die('зарегистрировано несколько подсетей — укажите, из какой брать: --from ' + ', '.join(str(s['net']) for s in c.subs))
        own = next((s for s in c.subs if s['net'] == n), None)
        if own is None:
            hit = next((s for s in c.subs if n.overlaps(s['net'])), None)
            if hit: die(f'{n} пересекается с зарегистрированной подсетью {hit["net"]} — используйте --from {hit["net"]}')
            if n.prefixlen < 32: unreg.add(n)
        if n.num_addresses > 65536: die(f'{n}: слишком большая подсеть для случайного выбора')
        cands = []
        for h in n.hosts():
            i = A.IPv4Interface(f'{h}/{n.prefixlen}')
            if h in seen or problem(c, i): continue
            cands.append(i)
        if len(cands) < a.random:
            die(f'в {n} свободно только {len(cands)} адрес(ов) (без адреса сети, broadcast, шлюза, занятых и заблокированных)')
        out.extend(sorted(random.SystemRandom().sample(cands, a.random), key=lambda x: int(x.ip)))
    if len(out) > MAXN: die(f'слишком много адресов за одну операцию ({len(out)}, максимум {MAXN})')
    for n in sorted(unreg):
        warns.append(f'подсеть {n} не зарегистрирована: шлюз неизвестен и не защищён от назначения. '
                     f'Рекомендуется сначала: ip-manager subnet add {n} --gw <шлюз>')
    for i in out: print(f'ADD\t{i}')
    for w in warns: print(f'WARN\t{w}')

def cmd_plan_del(a):
    c = Ctx(a); out = []; seen = set(); warns = []
    for tok in a.tokens:
        tok = tok.strip()
        if '/' in tok and '-' not in tok:
            try: i = A.IPv4Interface(tok)
            except ValueError: die(f'некорректный IPv4/CIDR: {tok}')
            if i.network.prefixlen <= 30 and i.ip == i.network.network_address:
                hit = sorted((m for ip, m in c.managed.items() if ip in i.network), key=lambda x: int(x.ip))
                if not hit: die(f'в {i.network} нет адресов под управлением IP Manager')
                for m in hit:
                    if m.ip not in seen: seen.add(m.ip); out.append(m)
                continue
            items = [(i.ip, None, False)]
        else:
            items = expand(tok)
        for ip, _, rng in items:
            if ip in seen: continue
            if ip in c.managed: seen.add(ip); out.append(c.managed[ip]); continue
            if rng: continue
            die(f'{ip}: ' + ('не управляется IP Manager (системный/внешний адрес) — удалять его здесь нельзя' if ip in c.existing else 'не назначен на сервере'))
    if not out: die('в указанных диапазонах нет адресов под управлением IP Manager')
    for i in out: print(f'DEL\t{i}')
    for w in warns: print(f'WARN\t{w}')

def cmd_subnet_check(a):
    c = Ctx(a); n = parse_net(a.cidr)
    if not 8 <= n.prefixlen <= 31: die(f'{n}: поддерживаются подсети от /8 до /31')
    for s in c.subs:
        if n.overlaps(s['net']): die(f'{n} пересекается с уже зарегистрированной подсетью {s["net"]}')
    if c.primary and c.primary in n:
        die(f'основной IP {c.primary} входит в {n} — эту подсеть настраивает конфигурация провайдера, регистрировать её не нужно')
    gw = None
    if a.subnet_gw:
        gw = parse_ip(a.subnet_gw, a.subnet_gw)
        if gw not in n: die(f'шлюз {gw} не входит в подсеть {n}')
        if n.prefixlen <= 30 and gw in (n.network_address, n.broadcast_address): die(f'{gw} — адрес сети/broadcast, шлюзом быть не может')
        if gw in c.existing: die(f'{gw} (шлюз!) назначен на этом сервере — это ломает подсеть. Сначала удалите его с интерфейса')
    for ip, m in sorted(c.managed.items()):
        if ip in n and m.network.prefixlen != n.prefixlen:
            print(f'WARN\t{m} уже назначен с маской /{m.network.prefixlen}; чтобы он работал через шлюз подсети, удалите и добавьте его заново')
    print(f'OK\t{n}\t{gw or "-"}')

def cmd_count_in(a):
    c = Ctx(a); n = parse_net(a.cidr)
    print(sum(1 for ip in c.managed if ip in n))

def cmd_expand(a):
    for tok in a.tokens:
        if '/' in tok and '-' not in tok:
            try: print(A.IPv4Interface(tok).ip)
            except ValueError: die(f'некорректный IPv4: {tok}')
        else:
            for ip, _, _ in expand(tok): print(ip)

def cmd_stats(a):
    c = Ctx(a)
    for s in c.subs:
        n = s['net']; usable = []
        for h in n.hosts():
            if h == s['gw']: continue
            usable.append(h)
        act = sum(1 for h in usable if h in c.managed)
        ext = sum(1 for h in usable if h in c.existing and h not in c.managed)
        blk = sum(1 for h in usable if h in c.blocked and h not in c.existing)
        free = len(usable) - act - ext - blk
        rt = f'policy routing: table {s["table"]}' if s['routing'] == '1' else 'без policy routing'
        print(f'  {n}  шлюз {s["gw"] or "—"}  ({rt})')
        line = f'    активно: {act}  заблокировано: {blk}  свободно: {free}  из {len(usable)} рабочих'
        if ext: line += f'  (+{ext} назначено вне IP Manager)'
        print(line)

# argv: CMD [options] [-- tokens...]  (tokens split off manually: argparse mixes positionals and options badly)
cmd, argv = sys.argv[1], sys.argv[2:]
tokens = []
if '--' in argv:
    i = argv.index('--'); tokens = argv[i + 1:]; argv = argv[:i]
p = argparse.ArgumentParser()
p.add_argument('--iface', default=''); p.add_argument('--primary', default='')
p.add_argument('--gw', default=''); p.add_argument('--subnets'); p.add_argument('--existing')
p.add_argument('--blocked'); p.add_argument('--managed'); p.add_argument('--random', type=int)
p.add_argument('--from', dest='frm'); p.add_argument('--cidr'); p.add_argument('--subnet-gw', dest='subnet_gw')
a = p.parse_args(argv); a.tokens = [t for t in tokens if t.strip()]
{'plan_add': cmd_plan_add, 'plan_del': cmd_plan_del, 'subnet_check': cmd_subnet_check,
 'count_in': cmd_count_in, 'expand': cmd_expand, 'stats': cmd_stats}[cmd](a)
PY
)

# Snapshot current state into $WORK so the helper sees a consistent picture.
refresh_ctx(){
  ip -o -4 addr show | awk '{print $4}' >"$WORK/existing"
  cut -f1 "$BLOCKED_FILE" >"$WORK/blocked"
  managed_for_iface >"$WORK/managed"
}
pyip(){
  local cmd=$1; shift
  refresh_ctx
  python3 -c "$PY_HELPER" "$cmd" --iface "$IFACE" --primary "$PRIMARY_IP" --gw "${GATEWAY:-}" \
    --subnets "$SUBNETS_FILE" --existing "$WORK/existing" --blocked "$WORK/blocked" --managed "$WORK/managed" "$@"
}

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите через sudo или от root."; }
init(){
  require_root; umask 077; mkdir -p "$STATE_DIR"; touch "$STATE_FILE" "$SUBNETS_FILE" "$BLOCKED_FILE" "$LOG_FILE"
  chmod 600 "$STATE_FILE" "$SUBNETS_FILE" "$BLOCKED_FILE"; chmod 640 "$LOG_FILE"
  exec 9>"$LOCK_FILE"; flock -n 9 || die "Уже запущен другой экземпляр ip-manager."
  need ip; need awk; need sed; need grep; need sort; need cut; need mktemp; need cmp; need flock; need python3
  WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
  detect_os; detect_network; reconcile_state; repair_networkd_perms
}

detect_os(){
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release."
  # Read in a subshell: os-release defines VERSION, which would clobber ours.
  local id
  IFS='|' read -r id OS_NAME OS_VERSION < <(. /etc/os-release; printf '%s|%s|%s\n' "${ID:-}" "${NAME:-${ID:-}}" "${VERSION_ID:-unknown}")
  case $id in ubuntu|debian) ;; *) die "Поддерживаются только Ubuntu и Debian (обнаружено: ${id:-unknown}).";; esac
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
  command -v netplan >/dev/null 2>&1 && compgen -G '/etc/netplan/*.y*ml' >/dev/null && np=1
  command -v nmcli >/dev/null 2>&1 && nmcli -t -f GENERAL.STATE device show "$IFACE" 2>/dev/null | grep -qE '100|connected' && nm=1
  command -v networkctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-networkd 2>/dev/null && networkctl status "$IFACE" --no-pager 2>/dev/null | grep -q 'Network File:' && nd=1
  [[ -r /etc/network/interfaces ]] && command -v ifquery >/dev/null 2>&1 && ifquery "$IFACE" >/dev/null 2>&1 && iu=1

  # Netplan is the source of truth when it declares this interface, even if renderer is NM/networkd.
  if ((np)); then
    if detect_netplan_identity; then BACKEND=netplan; return; fi
  fi
  local count=$((nm+nd+iu))
  if ((count!=1)); then
    ((np)) && [[ -n $NETPLAN_WHY ]] && warn "Netplan: $NETPLAN_WHY"
    die "Сетевой backend неоднозначен или не поддерживается (NM=$nm, networkd=$nd, ifupdown=$iu). Ничего не изменено."
  fi
  if ((nm)); then BACKEND=networkmanager; detect_nm_identity
  elif ((nd)); then BACKEND=networkd; detect_networkd_identity
  else BACKEND=ifupdown; detect_ifupdown_identity; fi
}

detect_netplan_identity(){
  need netplan
  NETPLAN_WHY=""
  netplan get >/dev/null 2>&1 || { NETPLAN_WHY="netplan get завершился ошибкой (проверьте: sudo netplan get)"; return 1; }
  # Parse the merged model via netplan get; do not infer YAML ownership from filenames.
  local rc=0
  python3 - "$IFACE" >"$STATE_DIR/.np-id" <<'PY' || rc=$?
import fnmatch,os,subprocess,sys
try:
 import yaml
except Exception:
 print('ERR\tне установлен PyYAML: sudo apt install python3-yaml'); sys.exit(2)
data=yaml.safe_load(subprocess.check_output(['netplan','get'], text=True, stderr=subprocess.DEVNULL)) or {}
n=(data.get('network') or {})
iface=sys.argv[1]
def sysfs(path):
 try:
  with open(path) as f: return f.read().strip().lower()
 except OSError: return ''
mac=sysfs(f'/sys/class/net/{iface}/address')
try: drv=os.path.basename(os.readlink(f'/sys/class/net/{iface}/device/driver'))
except OSError: drv=''
# A bond/bridge/vlan inherits the MAC of its first slave, so the slave NIC's match: macaddress
# "matched" bond0 too and detection saw two owners. match:/set-name: never select these virtual
# devices; every other interface (physical NIC, virtio, veth in LXC) is matched as before.
virtual=(os.path.isdir(f'/sys/class/net/{iface}/bonding') or os.path.isdir(f'/sys/class/net/{iface}/bridge')
         or os.path.exists(f'/proc/net/vlan/{iface}'))
def matches(m):
 # Netplan semantics: every key present in match: must match (name/driver are globs).
 if virtual or not isinstance(m,dict) or not m: return False
 for k,v in m.items():
  if k=='name':
   if not fnmatch.fnmatchcase(iface,str(v)): return False
  elif k=='macaddress':
   if not mac or str(v).lower()!=mac: return False
  elif k=='driver':
   pats=v if isinstance(v,list) else [v]
   if not drv or not any(fnmatch.fnmatchcase(drv,str(x)) for x in pats): return False
  else: return False  # unknown match key -> fail-safe
 return True
hits=[]
for typ in ('ethernets','bonds','bridges','vlans'):
 for ident,cfg in (n.get(typ) or {}).items():
  cfg=cfg if isinstance(cfg,dict) else {}
  if 'match' in cfg:
   if matches(cfg.get('match')) or (not virtual and cfg.get('set-name')==iface): hits.append((typ,ident))
  elif ident==iface: hits.append((typ,ident))
if not hits:
 print(f'ERR\tинтерфейс {iface} не описан в netplan'); sys.exit(3)
if len(hits)>1:
 print(f'ERR\tинтерфейс {iface} описан в netplan несколько раз: ' + ', '.join(f'{t}/{i}' for t,i in hits)); sys.exit(3)
print(hits[0][0]); print(hits[0][1])
PY
  mapfile -t _np <"$STATE_DIR/.np-id"; rm -f "$STATE_DIR/.np-id"
  if ((rc)) || ((${#_np[@]}!=2)); then
    NETPLAN_WHY=${_np[0]:-}; NETPLAN_WHY=${NETPLAN_WHY#ERR$'\t'}; NETPLAN_WHY=${NETPLAN_WHY:-не удалось разобрать конфигурацию}; return 1
  fi
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
    die "ifupdown обнаружен, но /etc/network/interfaces.d не подключён. IP Manager не меняет основной /etc/network/interfaces."
  mkdir -p /etc/network/interfaces.d
}

managed_for_iface(){ awk -F '\t' -v d="$IFACE" '$1==d {print $2}' "$STATE_FILE" | sort -u; }
# Rows: subnet<TAB>gateway<TAB>table<TAB>priority — only subnets with policy routing on this interface.
routed_subnets_for_iface(){ awk -F '\t' -v d="$IFACE" '$1==d && $6=="1" {print $2"\t"$3"\t"$4"\t"$5}' "$SUBNETS_FILE"; }
all_global(){ ip -o -4 addr show dev "$IFACE" scope global | awk '{print $4}' | sort -u; }
is_managed(){ grep -Fqx "$IFACE"$'\t'"$1" "$STATE_FILE"; }
is_blocked(){ cut -f1 "$BLOCKED_FILE" | grep -Fqx "$1"; }
reconcile_state(){
  local tmp; tmp=$(mktemp); while IFS=$'\t' read -r d a; do [[ -n ${d:-} && -n ${a:-} ]] || continue; printf '%s\t%s\n' "$d" "$a"; done <"$STATE_FILE" | sort -u >"$tmp"; mv "$tmp" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# promote_secondaries: without it, deleting the first address of a /NN subnet
# makes the kernel drop every other address of that subnet.
# ---------------------------------------------------------------------------
promote_on(){
  local a d
  a=$(cat /proc/sys/net/ipv4/conf/all/promote_secondaries 2>/dev/null || echo 0)
  d=$(cat "/proc/sys/net/ipv4/conf/$IFACE/promote_secondaries" 2>/dev/null || echo 0)
  [[ $a == 1 || $d == 1 ]]
}
ensure_promote(){
  promote_on && return 0
  warn "net.ipv4.conf.all.promote_secondaries = 0: при удалении первого адреса подсети ядро снимет ВСЕ остальные её адреса."
  confirm "Включить promote_secondaries (сейчас и постоянно через $SYSCTL_FILE)? [y/N]: " || die "Отменено: без promote_secondaries работа с адресами /NN небезопасна."
  local tmp; tmp=$(mktemp)
  printf '# Managed by ip-manager\nnet.ipv4.conf.all.promote_secondaries = 1\n' >"$tmp"
  atomic_install "$tmp" "$SYSCTL_FILE" 644 || { rm -f "$tmp"; die "Не удалось записать $SYSCTL_FILE. Ничего не изменено."; }; rm -f "$tmp"
  echo 1 >/proc/sys/net/ipv4/conf/all/promote_secondaries
  log_event "SYSCTL promote_secondaries=1"
  say "✓ promote_secondaries включён."
}
needs_promote(){ local a; for a in "$@"; do [[ ${a#*/} != 32 ]] && return 0; done; return 1; }

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------
render_persistence(){
  local out=$1 a r s g t p; local -a ips=() rts=()
  mapfile -t ips < <(managed_for_iface)
  mapfile -t rts < <(routed_subnets_for_iface)
  case $BACKEND in
    netplan)
      {
        echo 'network:'; echo '  version: 2'
        if ((${#ips[@]} || ${#rts[@]})); then
          printf '  %s:\n' "$NETPLAN_TYPE"; printf '    %s:\n' "$NETPLAN_ID"
          if ((${#ips[@]})); then echo '      addresses:'; for a in "${ips[@]}"; do printf '        - %s\n' "$a"; done; fi
          if ((${#rts[@]})); then
            echo '      routes:'
            for r in "${rts[@]}"; do IFS=$'\t' read -r s g t p <<<"$r"
              printf '        - to: 0.0.0.0/0\n          via: %s\n          on-link: true\n          table: %s\n' "$g" "$t"; done
            echo '      routing-policy:'
            for r in "${rts[@]}"; do IFS=$'\t' read -r s g t p <<<"$r"
              printf '        - from: %s\n          table: %s\n          priority: %s\n' "$s" "$t" "$p"; done
          fi
        fi
      } >"$out";;
    networkd)
      {
        echo '[Network]'; for a in "${ips[@]}"; do printf 'Address=%s\n' "$a"; done
        for r in "${rts[@]}"; do IFS=$'\t' read -r s g t p <<<"$r"
          printf '\n[Route]\nDestination=0.0.0.0/0\nGateway=%s\nGatewayOnLink=yes\nTable=%s\n' "$g" "$t"
          printf '\n[RoutingPolicyRule]\nFrom=%s\nTable=%s\nPriority=%s\n' "$s" "$t" "$p"; done
      } >"$out";;
    ifupdown)
      {
        echo '# Managed by ip-manager. Do not edit manually.'
        if ((${#ips[@]} || ${#rts[@]})); then
          echo "iface $IFACE inet manual"
          for a in "${ips[@]}"; do printf '    up ip address add %q dev %q || true\n' "$a" "$IFACE"; printf '    down ip address del %q dev %q || true\n' "$a" "$IFACE"; done
          for r in "${rts[@]}"; do IFS=$'\t' read -r s g t p <<<"$r"
            printf '    up ip route replace default via %q dev %q onlink table %q || true\n' "$g" "$IFACE" "$t"
            printf '    up ip rule add from %q lookup %q priority %q || true\n' "$s" "$t" "$p"
            printf '    down ip rule del from %q lookup %q priority %q || true\n' "$s" "$t" "$p"
            printf '    down ip route flush table %q || true\n' "$t"; done
        fi
      } >"$out";;
    networkmanager) : >"$out";;
  esac
}

persist_target(){
  case $BACKEND in
    netplan) echo "$NETPLAN_FILE";;
    networkd) echo "${NETWORKD_FILE}.d/$NETWORKD_DROPIN_NAME";;
    ifupdown) echo "$IFUPDOWN_FILE";;
  esac
}

validate_target(){
  local f=$1
  case $BACKEND in
    netplan)
      netplan_gen >"$WORK/netplan.err" 2>&1 || { cat "$WORK/netplan.err" >&2; return 1; }
      local bad; bad=$(networkd_unreadable)
      [[ -z $bad ]] || { warn "systemd-networkd не сможет прочитать: $bad"; return 1; };;
    networkd)
      # Only the keys we generate are allowed; anything else means the file is not ours.
      awk '
        /^$/ {next}
        /^\[(Network|Route|RoutingPolicyRule)\]$/ {sec=$0; next}
        sec=="[Network]" && /^Address=/ {next}
        sec=="[Route]" && /^(Destination|Gateway|GatewayOnLink|Table)=/ {next}
        sec=="[RoutingPolicyRule]" && /^(From|Table|Priority)=/ {next}
        {bad=1} END {exit bad}' "$f" || { warn "$f содержит параметры, которые IP Manager не создаёт"; return 1; }
      # The drop-in (and its directory) must be readable by systemd-network, or the IPs vanish on networkd restart.
      local bad; bad=$(networkd_unreadable)
      [[ -z $bad ]] || { warn "systemd-networkd не сможет прочитать: $bad"; return 1; };;
    ifupdown)
      ifquery --list >/dev/null 2>&1;;
  esac
}

persist_nm(){
  # Persist managed addresses by removing our previous values and adding the desired ones on the active profile.
  local a; local -a desired=() oldmanaged=()
  mapfile -t desired < <(managed_for_iface)
  mapfile -t oldmanaged < <(awk -F '\t' -v d="$IFACE" '$1==d {print $2}' "$STATE_FILE.prev" 2>/dev/null || true)
  for a in "${oldmanaged[@]}"; do nmcli connection modify uuid "$NM_UUID" -ipv4.addresses "$a" 2>/dev/null || true; done
  for a in "${desired[@]}"; do nmcli connection modify uuid "$NM_UUID" +ipv4.addresses "$a"; done
  nmcli connection verify uuid "$NM_UUID" >/dev/null 2>&1 || true
}

persist_validate_commit(){
  local tmp=$1
  if [[ $BACKEND == networkmanager ]]; then persist_nm; return; fi
  # Called from `if !` in commit_config: set -e is off here, so every step is checked explicitly.
  local dst prev=""; dst=$(persist_target) || return 1
  [[ -n $dst ]] || return 1
  # Netplan YAML stays 0600 (netplan warns about wider modes); a networkd drop-in must be readable by systemd-network.
  local mode=600; [[ $BACKEND == networkd ]] && mode=644
  if [[ -e $dst ]]; then
    prev="$WORK/persist.prev"
    cp -a -- "$dst" "$prev" && cmp -s -- "$dst" "$prev" || { warn "Не удалось сохранить копию $dst перед изменением (диск заполнен?)"; return 1; }
    backup_file "$dst" || warn "Резервная копия $dst в $BACKUP_DIR не создана (продолжаю: откат возможен из временной копии)"
  fi
  # On failure atomic_install leaves $dst untouched: nothing to roll back.
  atomic_install "$tmp" "$dst" "$mode" || return 1
  validate_target "$dst" && return 0
  if [[ -n $prev ]]; then
    atomic_install "$prev" "$dst" "$mode" || warn "ОТКАТ $dst НЕ УДАЛСЯ — файл содержит новую (непроверенную) конфигурацию. Прежняя версия — последняя копия $(basename "$dst").* в $BACKUP_DIR/files/; восстановите её вручную до перезапуска сети."
  else
    rm -f -- "$dst" || warn "Не удалось удалить $dst при откате."
  fi
  if [[ $BACKEND == netplan ]]; then netplan_gen >/dev/null 2>&1 || warn "netplan generate после отката завершился ошибкой — проверьте: sudo netplan generate"; fi
  return 1
}

# Atomically switch state files + persistent config; restores the previous state on failure.
commit_config(){
  local new_managed=$1 new_subnets=$2 tmpcfg
  cp -a "$STATE_FILE" "$STATE_FILE.prev"; cp -a "$SUBNETS_FILE" "$SUBNETS_FILE.prev"
  [[ $new_managed -ef $STATE_FILE ]] || cp "$new_managed" "$STATE_FILE"
  [[ $new_subnets -ef $SUBNETS_FILE ]] || cp "$new_subnets" "$SUBNETS_FILE"
  tmpcfg="$WORK/persist.new"; render_persistence "$tmpcfg"
  if ! persist_validate_commit "$tmpcfg"; then
    cp "$STATE_FILE.prev" "$STATE_FILE"; cp "$SUBNETS_FILE.prev" "$SUBNETS_FILE"
    rm -f "$STATE_FILE.prev" "$SUBNETS_FILE.prev"
    die "Запись или проверка постоянной конфигурации не прошла. State возвращён; runtime не изменён."
  fi
  rm -f "$STATE_FILE.prev" "$SUBNETS_FILE.prev"
}
snapshot_state(){ cp -a "$STATE_FILE" "$WORK/old.managed"; cp -a "$SUBNETS_FILE" "$WORK/old.subnets"; }
restore_snapshot(){ commit_config "$WORK/old.managed" "$WORK/old.subnets"; }

# ---------------------------------------------------------------------------
# Add / delete addresses
# ---------------------------------------------------------------------------
PLAN=() PLAN_WARN=()
read_plan(){
  local out=$1 k v; PLAN=(); PLAN_WARN=()
  while IFS=$'\t' read -r k v; do
    case $k in ADD|DEL) PLAN+=("$v");; WARN) PLAN_WARN+=("$v");; esac
  done <<<"$out"
}

# Usage: do_add [--random N] [--from CIDR] [token...]
do_add(){
  local out; out=$(pyip plan_add "$@") || exit 1
  read_plan "$out"
  local w; for w in "${PLAN_WARN[@]}"; do warn "$w"; done
  ((${#PLAN[@]})) || { say "Нечего добавлять."; return 0; }
  say ""; say "Будут добавлены на $IFACE (${#PLAN[@]}):"; printf '+ %s\n' "${PLAN[@]}"; say ""
  confirm || { say "Отменено."; return 0; }
  if needs_promote "${PLAN[@]}"; then ensure_promote; fi

  local a ns="$WORK/new.managed"; snapshot_state
  cp "$STATE_FILE" "$ns"; for a in "${PLAN[@]}"; do printf '%s\t%s\n' "$IFACE" "$a" >>"$ns"; done; sort -u -o "$ns" "$ns"
  commit_config "$ns" "$SUBNETS_FILE"
  # Runtime is changed only after persistent config validated; no network-wide reload.
  local -a added=()
  for a in "${PLAN[@]}"; do
    if ip address add "$a" dev "$IFACE"; then added+=("$a"); continue; fi
    for w in "${added[@]}"; do ip address del "$w" dev "$IFACE" 2>/dev/null || true; done
    restore_snapshot
    die "Не удалось назначить $a. Изменения отменены (runtime и постоянная конфигурация возвращены)."
  done
  for a in "${PLAN[@]}"; do log_event "ADD $a $IFACE SUCCESS"; done
  say "Готово. Сеть целиком не перезапускалась."
  verify_list "${PLAN[@]}"
}

# Usage: do_delete BLOCK(0|1) token...
do_delete(){
  local block=$1; shift
  local out; out=$(pyip plan_del -- "$@") || exit 1
  read_plan "$out"
  say ""; say "Будут удалены (${#PLAN[@]}):"; printf -- '- %s\n' "${PLAN[@]}"
  ((block)) && say "  …и помечены как заблокированные (не будут выдаваться при случайном выборе)."
  say ""; confirm || { say "Отменено."; return 0; }
  if needs_promote "${PLAN[@]}"; then ensure_promote; fi

  local a ns="$WORK/new.managed"; cp "$STATE_FILE" "$ns"
  for a in "${PLAN[@]}"; do awk -F '\t' -v d="$IFACE" -v a="$a" '!( $1==d && $2==a )' "$ns" >"$ns.x"; mv "$ns.x" "$ns"; done
  commit_config "$ns" "$SUBNETS_FILE"
  for a in "${PLAN[@]}"; do
    ip address del "$a" dev "$IFACE" 2>/dev/null || warn "$a отсутствовал в runtime"
    log_event "DELETE $a $IFACE SUCCESS"
  done
  if ((block)); then mark_blocked "${PLAN[@]%/*}"; fi
  say "Готово. Основной IP, gateway и чужие адреса не изменялись."
}

mark_blocked(){
  local ip
  for ip in "$@"; do
    is_blocked "$ip" && continue
    printf '%s\t%(%F)T\n' "$ip" -1 >>"$BLOCKED_FILE"; log_event "BLOCK $ip"
  done
}

do_block(){
  local out; out=$(pyip expand -- "$@") || exit 1
  local -a ips=(); mapfile -t ips <<<"$out"
  mark_blocked "${ips[@]}"
  say "Помечены как заблокированные: ${#ips[@]}. Назначенные адреса не снимались — удалите их отдельно, если нужно."
}

do_unblock(){
  local out ip; out=$(pyip expand -- "$@") || exit 1
  local -a ips=(); mapfile -t ips <<<"$out"
  local tmp="$WORK/blocked.new"; cp "$BLOCKED_FILE" "$tmp"
  for ip in "${ips[@]}"; do awk -F '\t' -v ip="$ip" '$1!=ip' "$tmp" >"$tmp.x"; mv "$tmp.x" "$tmp"; log_event "UNBLOCK $ip"; done
  cat "$tmp" >"$BLOCKED_FILE"
  say "Сняты с блокировки: ${#ips[@]}."
}

show_blocked(){
  if [[ ! -s $BLOCKED_FILE ]]; then say "Заблокированных IP нет."; return; fi
  say "Заблокированные IP (не выдаются при случайном выборе):"
  awk -F '\t' '{printf "  %-18s с %s\n", $1, $2}' "$BLOCKED_FILE"
}

# ---------------------------------------------------------------------------
# Provider subnets (gateway + optional policy routing)
# ---------------------------------------------------------------------------
alloc_table(){
  local t
  for ((t=100; t<=250; t++)); do
    awk -F '\t' -v t="$t" '$4==t {f=1} END {exit !f}' "$SUBNETS_FILE" && continue
    [[ -z $(ip -4 route show table "$t" 2>/dev/null) ]] || continue
    grep -Eq "lookup $t( |\$)" <<<"$(ip rule show)" && continue
    echo "$t"; return 0
  done
  die "Не найдено свободной таблицы маршрутизации в диапазоне 100–250."
}
alloc_priority(){
  local p=$((1000 + $1))
  while grep -q "^$p:" <<<"$(ip rule show)"; do p=$((p+1)); done
  echo "$p"
}

subnet_runtime_up(){
  local s=$1 g=$2 t=$3 p=$4
  ip route replace default via "$g" dev "$IFACE" onlink table "$t" || return 1
  grep -Fq "from $s lookup $t" <<<"$(ip rule show)" || ip rule add from "$s" lookup "$t" priority "$p"
}
subnet_runtime_down(){
  local s=$1 t=$2 p=$3
  while ip rule del from "$s" lookup "$t" priority "$p" 2>/dev/null; do :; done
  ip route flush table "$t" 2>/dev/null || true
}

# Usage: subnet_add CIDR GW|"" ROUTING(0|1)
subnet_add(){
  local cidr=$1 gw=$2 routing=$3 out k net sgw w
  local -a args=(--cidr "$cidr"); [[ -n $gw ]] && args+=(--subnet-gw "$gw")
  out=$(pyip subnet_check "${args[@]}") || exit 1
  while IFS=$'\t' read -r k net sgw; do
    case $k in OK) :;; WARN) warn "$net";; esac
  done <<<"$out"
  IFS=$'\t' read -r k net sgw < <(grep '^OK' <<<"$out")
  [[ $sgw == - ]] && routing=0
  if ((routing)) && [[ $BACKEND == networkmanager ]]; then
    die "Policy routing для NetworkManager не поддерживается. Зарегистрируйте подсеть с --no-routing."
  fi
  local table=- prio=-
  if ((routing)); then table=$(alloc_table); prio=$(alloc_priority "$table"); fi

  say ""; say "Будет зарегистрирована подсеть на $IFACE:"
  say "  подсеть: $net"; say "  шлюз:    ${sgw/#-/не указан}"
  if ((routing)); then
    say "  policy routing: ответы с адресов $net уходят через $sgw (table $table, priority $prio)"
  else
    say "  policy routing: нет (исходящий трафик идёт через основной gateway ${GATEWAY:-—})"
  fi
  say "  Адреса из подсети будут добавляться с маской /${net#*/}; шлюз, адрес сети и broadcast — запрещены."
  say ""; confirm || { say "Отменено."; return 0; }

  local nsub="$WORK/new.subnets"; snapshot_state
  cp "$SUBNETS_FILE" "$nsub"; printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$IFACE" "$net" "$sgw" "$table" "$prio" "$routing" >>"$nsub"
  commit_config "$STATE_FILE" "$nsub"
  if ((routing)) && ! subnet_runtime_up "$net" "$sgw" "$table" "$prio"; then
    subnet_runtime_down "$net" "$table" "$prio"; restore_snapshot
    die "Не удалось применить маршрут/правило. Изменения отменены."
  fi
  log_event "SUBNET ADD $net gw=$sgw table=$table prio=$prio routing=$routing $IFACE"
  say "Готово. Теперь можно добавлять адреса: ip-manager add --random N  или  ip-manager add ${net%.*}.X"
}

subnet_del(){
  local cidr=$1 row cnt s g t p r
  row=$(awk -F '\t' -v d="$IFACE" -v c="$cidr" '$1==d && $2==c' "$SUBNETS_FILE")
  [[ -n $row ]] || die "Подсеть $cidr не зарегистрирована на $IFACE. Список: ip-manager subnet list"
  cnt=$(pyip count_in --cidr "$cidr") || exit 1
  ((cnt==0)) || die "В $cidr ещё $cnt адрес(ов) под управлением IP Manager. Сначала: ip-manager del $cidr"
  IFS=$'\t' read -r _ s g t p r <<<"$row"
  say "Будет удалена регистрация подсети $s (шлюз $g)$( [[ $r == 1 ]] && printf ' и её policy routing (table %s)' "$t")."
  confirm || { say "Отменено."; return 0; }
  local nsub="$WORK/new.subnets"
  awk -F '\t' -v d="$IFACE" -v c="$cidr" '!($1==d && $2==c)' "$SUBNETS_FILE" >"$nsub"
  commit_config "$STATE_FILE" "$nsub"
  [[ $r == 1 ]] && subnet_runtime_down "$s" "$t" "$p"
  log_event "SUBNET DEL $s $IFACE"
  say "Готово."
}

subnet_list(){
  if ! awk -F '\t' -v d="$IFACE" '$1==d {f=1} END {exit !f}' "$SUBNETS_FILE"; then say "  нет зарегистрированных подсетей"; return; fi
  pyip stats || true
}

# ---------------------------------------------------------------------------
# Views
# ---------------------------------------------------------------------------
show_header(){
  say "IP Manager v$VERSION"; say ""; say "Система: $OS_NAME $OS_VERSION"; say "Backend: $BACKEND"; say "Интерфейс: $IFACE"; say "Основной IP: $PRIMARY_CIDR"; say "Gateway: ${GATEWAY:-не указан}"
  say ""; say "Подсети провайдера:"; subnet_list
  say ""; say "Дополнительные IP:"
  local n=0 a; while read -r a; do [[ -n $a && $a != "$PRIMARY_CIDR" ]] || continue; ((++n)); if is_managed "$a"; then printf '  %d. %-22s [IP Manager]\n' "$n" "$a"; else printf '  %d. %-22s [внешний]\n' "$n" "$a"; fi; done < <(all_global)
  ((n)) || say "  нет"
  local b; b=$(grep -c . "$BLOCKED_FILE" || true); ((b)) && { say ""; say "Заблокированных IP: $b (ip-manager blocked)"; }
  return 0
}

verify_one(){
  local a=$1 ip=${1%/*}; printf '%s\n' "$a"
  if grep -Fqx "$a" <<<"$(ip -o -4 addr show dev "$IFACE" | awk '{print $4}')"; then say "  ✓ IP назначен локально"; else say "  ✗ IP не назначен локально"; fi
  if is_managed "$a"; then say "  ✓ отмечен как постоянный IP Manager"; else say "  ? не управляется IP Manager"; fi
  if command -v curl >/dev/null 2>&1; then
    local out; if out=$(curl --interface "$ip" -4 -fsS --connect-timeout 5 --max-time 10 "$CURL_TEST_URL" 2>/dev/null); then say "  ✓ исходящее соединение работает (внешний IP: $out)"; else say "  ✗ исходящее соединение через source IP не работает"; say "    Возможна проблема маршрутизации/назначения IP у провайдера; IP Manager API провайдера не настраивает."; fi
  else say "  ? curl не установлен — внешний тест пропущен"; fi
}
verify_list(){ local a; for a in "$@"; do verify_one "$a"; done; }
verify_subnets(){
  local r s g t p
  while IFS=$'\t' read -r s g t p; do
    [[ -n $s ]] || continue
    printf 'Подсеть %s (шлюз %s, table %s)\n' "$s" "$g" "$t"
    if grep -Fq "from $s lookup $t" <<<"$(ip rule show)"; then say "  ✓ правило ip rule активно"; else say "  ✗ правило ip rule отсутствует"; fi
    if grep -q "^default via $g" <<<"$(ip -4 route show table "$t")"; then say "  ✓ маршрут default via $g в table $t"; else say "  ✗ маршрут в table $t отсутствует"; fi
  done < <(routed_subnets_for_iface)
  if promote_on; then say "promote_secondaries: ✓ включён"; else say "promote_secondaries: ✗ выключен (удаление первого адреса /NN снимет остальные)"; fi
  if [[ $BACKEND == netplan || $BACKEND == networkd ]]; then
    local bad; bad=$(networkd_unreadable)
    if [[ -z $bad ]]; then say "конфигурация systemd-networkd: ✓ читается (IP переживут перезапуск сети)"
    else say "конфигурация systemd-networkd: ✗ не читается — после перезапуска сети IP пропадут: ${bad//$'\n'/ }"; fi
  fi
}
# Usage: verify_cmd [ip|range...]
verify_cmd(){
  local -a arr=()
  if (($#)); then
    local out ip c; out=$(pyip expand -- "$@") || exit 1
    while read -r ip; do
      c=$(ip -o -4 addr show dev "$IFACE" | awk -v ip="$ip" '{split($4,x,"/"); if (x[1]==ip) print $4}')
      arr+=("${c:-$ip/32}")
    done <<<"$out"
  else
    mapfile -t arr < <(all_global)
  fi
  verify_subnets; say ""; verify_list "${arr[@]}"
}

netplan_import_probe(){
  local cidr=$1
  python3 - "$cidr" "$NETPLAN_FILE" "$NETPLAN_TYPE" "$NETPLAN_ID" <<'PYCODE'
import glob, os, sys
try:
    import yaml
except Exception:
    print("ERR\tPyYAML недоступен: невозможно безопасно разобрать Netplan YAML")
    sys.exit(0)
cidr, managed_file, expected_type, expected_id = sys.argv[1:]
hits=[]
for path in sorted(glob.glob('/etc/netplan/*.yaml') + glob.glob('/etc/netplan/*.yml')):
    if os.path.realpath(path) == os.path.realpath(managed_file): continue
    try:
        with open(path, encoding='utf-8') as f: data=yaml.safe_load(f) or {}
    except Exception as e:
        print(f"ERR\tНе удалось разобрать {path}: {e}"); sys.exit(0)
    net=data.get('network') if isinstance(data,dict) else None
    if not isinstance(net,dict): continue
    for typ in ('ethernets','bonds','bridges','vlans'):
        group=net.get(typ)
        if not isinstance(group,dict): continue
        for ident,cfg in group.items():
            if not isinstance(cfg,dict): continue
            addrs=cfg.get('addresses')
            if isinstance(addrs,list) and cidr in [str(x) for x in addrs]: hits.append((path,typ,str(ident),cfg,net,data))
if not hits:
    print("NO\tIP не найден в отдельных Netplan YAML"); sys.exit(0)
if len(hits) != 1:
    print("ERR\tIP объявлен более чем в одном Netplan-источнике"); sys.exit(0)
path,typ,ident,cfg,net,data=hits[0]
if typ != expected_type or ident != expected_id:
    print(f"ERR\tИсточник относится к {typ}/{ident}, ожидался {expected_type}/{expected_id}"); sys.exit(0)
if set(data.keys()) != {'network'}:
    print(f"ERR\t{path} содержит верхнеуровневые параметры кроме network"); sys.exit(0)
if set(net.keys()) != {'version', typ} or net.get('version') != 2:
    print(f"ERR\t{path} содержит дополнительные параметры network"); sys.exit(0)
group=net.get(typ)
if not isinstance(group,dict) or set(group.keys()) != {ident}:
    print(f"ERR\t{path} содержит дополнительные Netplan-интерфейсы"); sys.exit(0)
if set(cfg.keys()) != {'addresses'}:
    print(f"ERR\t{path} содержит настройки кроме addresses"); sys.exit(0)
addrs=cfg.get('addresses')
if not isinstance(addrs,list) or [str(x) for x in addrs] != [cidr]:
    print(f"ERR\t{path} содержит более одного адреса или другой адрес"); sys.exit(0)
print(f"OK\t{path}")
PYCODE
}

import_ips(){
  if [[ $BACKEND != netplan ]]; then
    say "Автоматический импорт поддерживается только для однозначных Netplan address-overlay файлов."
    say "Backend $BACKEND не изменён."; return 0
  fi
  local -a candidates=() statuses=() sources=(); local a result status detail i
  while read -r a; do
    [[ $a == "$PRIMARY_CIDR" ]] && continue; is_managed "$a" && continue
    candidates+=("$a"); result=$(netplan_import_probe "$a"); status=${result%%$'\t'*}; detail=${result#*$'\t'}
    statuses+=("$status"); sources+=("$detail")
  done < <(all_global)
  ((${#candidates[@]})) || { say "Нет внешних дополнительных IP для импорта."; return 0; }
  say "Внешние дополнительные IP:"
  for i in "${!candidates[@]}"; do
    if [[ ${statuses[$i]} == OK ]]; then
      printf '[%d] %-22s ✓ можно импортировать\n    источник: %s\n' "$((i+1))" "${candidates[$i]}" "${sources[$i]}"
    else
      printf '[%d] %-22s ✗ автоимпорт запрещён\n    причина: %s\n' "$((i+1))" "${candidates[$i]}" "${sources[$i]}"
    fi
  done
  say ""; local line x idx
  read -r -p "Какие IP импортировать? Номера через пробел (Enter — отмена): " line
  [[ -n $line ]] || { say "Отменено."; return 0; }
  local -a nums=() chosen=() chosen_sources=(); declare -A seen=(); IFS=' ' read -r -a nums <<<"$line"
  for x in "${nums[@]}"; do
    [[ $x =~ ^[0-9]+$ ]] || die "Некорректный номер: $x"; idx=$((x-1)); ((idx>=0 && idx<${#candidates[@]})) || die "Нет пункта $x"
    [[ -z ${seen[$idx]+x} ]] || continue; seen[$idx]=1
    [[ ${statuses[$idx]} == OK ]] || die "${candidates[$idx]} нельзя импортировать автоматически: ${sources[$idx]}"
    chosen+=("${candidates[$idx]}"); chosen_sources+=("${sources[$idx]}")
  done
  ((${#chosen[@]})) || return 0
  say ""; say "Будут переданы под управление IP Manager:"
  for i in "${!chosen[@]}"; do printf '+ %s\n  %s → %s\n' "${chosen[$i]}" "${chosen_sources[$i]}" "$NETPLAN_FILE"; done
  say ""; say "Runtime IP, primary IP, gateway, DNS, bond/VLAN и маршруты изменяться не будут."
  confirm || { say "Отменено."; return 0; }

  local tx backup_dir old_state old_managed ns tmpcfg src base
  tx=$(date +%Y%m%d%H%M%S)-$$; backup_dir="$BACKUP_DIR/import-$tx"; mkdir -p "$backup_dir"
  old_state="$backup_dir/managed.tsv.before"; cp -a "$STATE_FILE" "$old_state"
  if [[ -e $NETPLAN_FILE ]]; then old_managed="$backup_dir/90-ip-manager.yaml.before"; cp -a "$NETPLAN_FILE" "$old_managed"; else old_managed=""; fi
  for i in "${!chosen[@]}"; do
    result=$(netplan_import_probe "${chosen[$i]}")
    [[ ${result%%$'\t'*} == OK && ${result#*$'\t'} == "${chosen_sources[$i]}" ]] || die "Источник ${chosen[$i]} изменился после анализа. Ничего не изменено."
  done
  ns=$(mktemp); cp "$STATE_FILE" "$ns"; for a in "${chosen[@]}"; do printf '%s\t%s\n' "$IFACE" "$a" >>"$ns"; done; sort -u -o "$ns" "$ns"
  # Order matters: provider YAMLs are removed only after our overlay and state are safely written,
  # so a write failure (full disk, read-only /etc) can never leave the IPs declared nowhere.
  tmpcfg=$(mktemp); STATE_FILE=$ns render_persistence "$tmpcfg"
  atomic_install "$tmpcfg" "$NETPLAN_FILE" 600 || { rm -f "$ns" "$tmpcfg"; die "Не удалось записать $NETPLAN_FILE. Импорт отменён, ничего не изменено."; }
  import_rollback(){
    cp -a -- "$old_state" "$STATE_FILE" || warn "Не удалось восстановить state из $old_state"
    if [[ -n $old_managed ]]; then atomic_install "$old_managed" "$NETPLAN_FILE" 600 || warn "Не удалось восстановить $NETPLAN_FILE из $old_managed"
    else rm -f -- "$NETPLAN_FILE" || warn "Не удалось удалить $NETPLAN_FILE"; fi
    for src in "${chosen_sources[@]}"; do base=$(basename "$src")
      [[ -e $src ]] || cp -a -- "$backup_dir/$base" "$src" || warn "Не удалось восстановить $src из $backup_dir/$base"; done
    netplan_gen >/dev/null 2>&1 || warn "Rollback файлов выполнен, но контрольный netplan generate завершился ошибкой. Проверьте диагностику."
    rm -f "$ns" "$tmpcfg"
  }
  cp -- "$ns" "$STATE_FILE" && cmp -s -- "$ns" "$STATE_FILE" || { import_rollback; die "Не удалось записать state. Импорт отменён, исходные YAML не тронуты."; }
  for src in "${chosen_sources[@]}"; do base=$(basename "$src")
    cp -a -- "$src" "$backup_dir/$base" && cmp -s -- "$src" "$backup_dir/$base" && rm -f -- "$src" \
      || { import_rollback; die "Не удалось сохранить копию $src в $backup_dir. Импорт отменён, исходные YAML восстановлены."; }
  done
  if ! netplan_gen >"$backup_dir/netplan-generate.log" 2>&1; then
    warn "Новая Netplan-конфигурация не прошла netplan generate. Выполняю rollback файлов."
    import_rollback; cat "$backup_dir/netplan-generate.log" >&2
    die "Импорт отменён. Исходные YAML восстановлены. Runtime-сеть не применялась."
  fi
  rm -f "$ns" "$tmpcfg"; for a in "${chosen[@]}"; do log_event "IMPORT $a $IFACE SUCCESS"; done
  say ""; say "Импорт завершён успешно."; say "✓ исходные YAML сохранены в: $backup_dir"; say "✓ адреса записаны в: $NETPLAN_FILE"; say "✓ netplan generate успешно"; say "✓ runtime-сеть не перезапускалась"; say ""
  verify_list "${chosen[@]}"
}

diagnostics(){
  say "=== IP Manager diagnostics ==="; date -Is; say "Version: $VERSION"; say "OS: $OS_NAME $OS_VERSION"; say "Backend: $BACKEND"; say "Default interface: $IFACE"; say "Primary IPv4: $PRIMARY_CIDR"; say "Gateway: ${GATEWAY:-none}"; say "Netplan type/id: ${NETPLAN_TYPE:-n/a}/${NETPLAN_ID:-n/a}"; say "NM UUID: ${NM_UUID:-n/a}"; say "networkd file: ${NETWORKD_FILE:-n/a}"
  say "promote_secondaries: all=$(cat /proc/sys/net/ipv4/conf/all/promote_secondaries 2>/dev/null || echo ?) $IFACE=$(cat "/proc/sys/net/ipv4/conf/$IFACE/promote_secondaries" 2>/dev/null || echo ?)"
  say ""; say "--- ip -4 addr ---"; ip -4 addr show; say ""; say "--- ip -4 route ---"; ip -4 route show
  say ""; say "--- ip rule ---"; ip rule show
  local s g t p; while IFS=$'\t' read -r s g t p; do [[ -n $s ]] || continue; say ""; say "--- table $t ($s) ---"; ip -4 route show table "$t"; done < <(routed_subnets_for_iface)
  say ""; say "--- Подсети (subnets.tsv) ---"; cat "$SUBNETS_FILE"
  say ""; say "--- Managed IP ($IFACE) ---"; managed_for_iface || true; say ""; say "--- System IP ($IFACE) ---"; local a; while read -r a; do is_managed "$a" || echo "$a"; done < <(all_global)
  say ""; say "--- Заблокированные ---"; cat "$BLOCKED_FILE"
  say ""; say "--- Services ---"; for a in systemd-networkd NetworkManager; do printf '%s: ' "$a"; systemctl is-active "$a" 2>/dev/null || true; done
  if [[ $BACKEND == netplan ]]; then say ""; say "--- /run/systemd/network ---"; ls -l /run/systemd/network/ 2>/dev/null || true; fi
  local bad; bad=$(networkd_unreadable); say "Не читается systemd-network: ${bad:-нет}"
  if [[ $BACKEND == netplan ]]; then say ""; say "--- netplan get (network config; проверьте перед публикацией) ---"; netplan get 2>/dev/null || true; fi
}

show_version(){ say "IP Manager v$VERSION"; }

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
  if [[ -s $STATE_FILE || -s $SUBNETS_FILE ]]; then
    say "Сейчас IP Manager управляет следующими адресами и подсетями:"
    cat "$STATE_FILE" "$SUBNETS_FILE"
    say ""
    warn "Удаление программы НЕ снимет эти IP/маршруты и НЕ удалит persistent network-конфигурацию."
    warn "Это сделано специально, чтобы рабочие IP не исчезли после uninstall/reboot."
    say "Если IP больше не нужны, сначала удалите их (ip-manager del …, ip-manager subnet del …)."
    say ""
  fi
  confirm "Удалить только программу /usr/local/sbin/ip-manager? [y/N]: " || { say "Отменено."; return 0; }
  rm -f /usr/local/sbin/ip-manager
  log_event "UNINSTALL BINARY SUCCESS"
  say "IP Manager удалён. State, лог и managed network-конфигурация оставлены на месте."
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
read_tokens(){ local line; read -r -p "$1" line || true; TOKENS=(); IFS=' ' read -r -a TOKENS <<<"$line"; }

menu_add(){
  say "Форматы: 179.253.180.41   179.253.180.41/27   179.253.180.34-40   179.253.180.34-179.253.180.50"
  say "Без маски: маска зарегистрированной подсети, иначе /32."
  read_tokens "Введите IP/диапазоны через пробел: "; ((${#TOKENS[@]})) || return 0
  do_add -- "${TOKENS[@]}"
}
menu_random(){
  local n from=""; local -a subs=()
  mapfile -t subs < <(awk -F '\t' -v d="$IFACE" '$1==d {print $2}' "$SUBNETS_FILE")
  if ((${#subs[@]}==1)); then from=${subs[0]}; say "Подсеть: $from"
  else
    ((${#subs[@]})) && say "Зарегистрированные подсети: ${subs[*]}"
    read -r -p "Из какой подсети (например 179.253.180.32/27): " from || true; [[ -n $from ]] || return 0
  fi
  read -r -p "Сколько адресов добавить: " n || true; [[ $n =~ ^[0-9]+$ ]] || { say "Нужно число."; return 0; }
  do_add --random "$n" --from "$from"
}
menu_delete(){
  local -a sel=(); mapfile -t sel < <(managed_for_iface)
  ((${#sel[@]})) || { say "Нет IP под управлением IP Manager."; return 0; }
  local i; for i in "${!sel[@]}"; do printf '[%d] %s\n' "$((i+1))" "${sel[$i]}"; done
  read_tokens "Какие IP удалить? Номера через пробел: "; ((${#TOKENS[@]})) || return 0
  local -a del=(); local x
  for x in "${TOKENS[@]}"; do [[ $x =~ ^[0-9]+$ ]] && ((x>=1 && x<=${#sel[@]})) || die "Нет пункта $x"; del+=("${sel[$((x-1))]}"); done
  local block=0; confirm "Пометить их как заблокированные (не выдавать при случайном выборе)? [y/N]: " && block=1
  do_delete "$block" "${del[@]}"
}
menu_subnets(){
  say "Подсети провайдера на $IFACE:"; subnet_list; say ""
  say "1) Зарегистрировать подсеть"; say "2) Удалить регистрацию"; say "0) Назад"
  local c cidr gw rt; read -r -p "Выберите: " c || return 0
  case $c in
    1) read -r -p "Подсеть (например 179.253.180.32/27): " cidr || true; [[ -n $cidr ]] || return 0
       read -r -p "Шлюз подсети (Enter — нет): " gw || true
       rt=0; [[ -n $gw ]] && confirm "Включить policy routing (ответы с этих IP через шлюз подсети)? [y/N]: " && rt=1
       subnet_add "$cidr" "$gw" "$rt";;
    2) read -r -p "Подсеть: " cidr || true; [[ -n $cidr ]] && subnet_del "$cidr";;
  esac
}
menu_blocked(){
  show_blocked; [[ -s $BLOCKED_FILE ]] || return 0
  read_tokens "Какие IP снять с блокировки (Enter — ничего): "; ((${#TOKENS[@]})) || return 0
  do_unblock "${TOKENS[@]}"
}

menu(){
  while true; do clear 2>/dev/null || true; detect_network; show_header; cat <<'M'

1) Добавить IP (адреса и диапазоны)
2) Добавить случайные IP из подсети
3) Удалить IP
4) Показать IP
5) Проверить IP
6) Подсети провайдера (шлюз, policy routing)
7) Заблокированные IP
8) Импортировать существующие IP
9) Диагностика
10) Обновить IP Manager
11) Удалить IP Manager
0) Выход
M
    local c; read -r -p "Выберите действие: " c || exit 0
    case $c in
      1) menu_add;; 2) menu_random;; 3) menu_delete;; 4) show_header;; 5) verify_cmd;;
      6) menu_subnets;; 7) menu_blocked;; 8) import_ips;; 9) diagnostics;;
      10) self_update; exit 0;; 11) self_uninstall; exit 0;; 0) exit 0;;
      *) say "Неизвестный пункт.";;
    esac
    say ""; read -r -p "Enter — продолжить..." _ || true
  done
}

usage(){
  cat <<'U'
Использование: sudo ip-manager [команда] [параметры]

Без команды — интерактивное меню.

Адреса:
  add IP|IP/NN|RANGE ...            добавить адреса (RANGE: 1.2.3.10-20 или 1.2.3.10-1.2.3.20)
  add --random N [--from SUBNET]    добавить N случайных свободных адресов из подсети
  del IP|RANGE|SUBNET ... [--blocked]
                                    удалить адреса IP Manager; SUBNET (1.2.3.32/27) — все из подсети;
                                    --blocked — пометить удалённые как заблокированные
  list                              показать адреса и подсети
  check [IP|RANGE ...]              проверить адреса, policy routing, promote_secondaries

Подсети провайдера:
  subnet add SUBNET [--gw GATEWAY] [--no-routing]
                                    зарегистрировать подсеть: маска и защита шлюза/сети/broadcast;
                                    с --gw включается policy routing через шлюз подсети
  subnet del SUBNET                 удалить регистрацию (адресов из подсети быть не должно)
  subnet list

Блокировки (для ротации):
  blocked                           список заблокированных IP
  block IP|RANGE ...                пометить как заблокированные (адреса не снимаются)
  unblock IP|RANGE ...              снять пометку

Прочее:
  diag | version | update | uninstall | help

Общие параметры:
  -y, --yes                         не спрашивать подтверждение
U
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
POS=() OPT_RANDOM="" OPT_FROM="" OPT_GW="" OPT_NOROUTING=0 OPT_BLOCKED=0
parse_args(){
  while (($#)); do
    case $1 in
      -y|--yes) ASSUME_YES=1;;
      --random) (($#>=2)) || die "--random: укажите количество"; OPT_RANDOM=$2; shift;;
      --from) (($#>=2)) || die "--from: укажите подсеть"; OPT_FROM=$2; shift;;
      --gw|--gateway) (($#>=2)) || die "--gw: укажите шлюз"; OPT_GW=$2; shift;;
      --no-routing) OPT_NOROUTING=1;;
      --blocked) OPT_BLOCKED=1;;
      --) shift; POS+=("$@"); break;;
      -*) die "Неизвестный параметр: $1 (см. ip-manager help)";;
      *) POS+=("$1");;
    esac
    shift
  done
  if [[ -n $OPT_RANDOM && ! $OPT_RANDOM =~ ^[0-9]+$ ]]; then die "--random: нужно число"; fi
  return 0
}

main(){
  local cmd=${1:-}; (($#)) && shift
  case $cmd in
    ""|menu) init; menu;;
    --version|version) show_version;;
    help|-h|--help) usage;;
    update|--update)
      require_root; umask 077; mkdir -p "$STATE_DIR"; touch "$STATE_FILE" "$LOG_FILE"
      self_update;;
    uninstall|remove|--uninstall)
      parse_args "$@"; require_root; umask 077; mkdir -p "$STATE_DIR"; touch "$STATE_FILE" "$SUBNETS_FILE" "$LOG_FILE"
      self_uninstall;;
    add)
      parse_args "$@"; init
      local -a a=(); [[ -n $OPT_RANDOM ]] && a+=(--random "$OPT_RANDOM"); [[ -n $OPT_FROM ]] && a+=(--from "$OPT_FROM")
      ((${#POS[@]} || ${#a[@]})) || die "Укажите адреса или --random N. Пример: ip-manager add 179.253.180.41"
      do_add "${a[@]}" -- "${POS[@]}";;
    del|delete|rm)
      parse_args "$@"; init; ((${#POS[@]})) || die "Укажите адреса. Пример: ip-manager del 179.253.180.41"
      do_delete "$OPT_BLOCKED" "${POS[@]}";;
    list|ls|show) init; show_header;;
    check|verify) parse_args "$@"; init; verify_cmd "${POS[@]}";;
    subnet|subnets)
      local sub=${1:-list}; (($#)) && shift
      parse_args "$@"; init
      case $sub in
        add) ((${#POS[@]}==1)) || die "Пример: ip-manager subnet add 179.253.180.32/27 --gw 179.253.180.33"
             local rt=1; ((OPT_NOROUTING)) && rt=0
             subnet_add "${POS[0]}" "$OPT_GW" "$rt";;
        del|delete|rm) ((${#POS[@]}==1)) || die "Пример: ip-manager subnet del 179.253.180.32/27"; subnet_del "${POS[0]}";;
        list|ls) subnet_list;;
        *) die "Неизвестная команда subnet $sub (add|del|list)";;
      esac;;
    blocked) init; show_blocked;;
    block) parse_args "$@"; init; ((${#POS[@]})) || die "Укажите адреса."; do_block "${POS[@]}";;
    unblock) parse_args "$@"; init; ((${#POS[@]})) || die "Укажите адреса."; do_unblock "${POS[@]}";;
    diag|diagnostics) init; diagnostics;;
    *) usage >&2; exit 2;;
  esac
}

main "$@"
