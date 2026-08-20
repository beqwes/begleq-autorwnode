#!/usr/bin/env bash
# =============================================================================
#  node-setup.sh — состояние ноды + её первоначальная настройка, одним файлом
#
#  Запускать НА СЕРВЕРЕ от root:
#     bash node-setup.sh                      # спросит SECRET_KEY и остальное
#     bash node-setup.sh --status-only        # только отчёт, ничего не менять
#     bash node-setup.sh --secret 'КЛЮЧ' --panel-ip 203.0.113.10 --yes
#
#  Сначала показывает: кто и откуда заходил, что за программы работают,
#  какие порты открыты, сколько ресурсов. Потом настраивает ноду с нуля.
#  Идемпотентен: повторный запуск ничего не ломает.
#
#  Чужой SECRET_KEY, чужой docker-compose.yml с посторонними сервисами и
#  существующий /etc/docker/daemon.json скрипт не трогает.
# =============================================================================
set -u

VERSION="2.1"
STAMP="$(date +%s)"
FAILED=""

# ---------- параметры (можно задать флагом или переменной окружения) ---------
SECRET_KEY="${SECRET_KEY:-}"
# NODE_PORT и TIMEZONE намеренно пустые: ask() не задаёт вопрос, если
# переменная уже заполнена, и с дефолтом прямо здесь порт нельзя было бы
# поменять руками. Значения по умолчанию подставляются в самом вопросе.
NODE_PORT="${NODE_PORT:-}"
PANEL_IP="${PANEL_IP:-}"
SSH_PORT="${SSH_PORT:-}"
NEW_HOSTNAME="${NEW_HOSTNAME:-}"
TIMEZONE="${TIMEZONE:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/remnanode}"
LAST_COUNT="${LAST_COUNT:-10}"
# образ ноды намеренно пинится, а не latest: свежий node с панелью постарше
# не сходится по mTLS и валится с «tls alert handshake failure ... alert number 40»
NODE_IMAGE="${NODE_IMAGE:-}"
NODE_IMAGE_DEFAULT="remnawave/node:3.2.2"
DO_UPGRADE=1; DO_UFW=1; DO_F2B=1; DO_SWAP=1
FORCE_KEY=0; STATUS_ONLY=0; NO_STATUS=0; ASSUME_YES=0

# ---------- вывод ----------
if [ -t 1 ]; then C0=$'\e[0m'; CB=$'\e[1m'; CG=$'\e[32m'; CY=$'\e[33m'; CR=$'\e[31m'; CC=$'\e[36m'; CM=$'\e[35m'
else C0=""; CB=""; CG=""; CY=""; CR=""; CC=""; CM=""; fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s  ok %s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '%s  !! %s %s\n' "$CY" "$C0" "$*"; }
bad()  { printf '%s  xx %s %s\n' "$CR" "$C0" "$*"; }
err()  { bad "$*"; FAILED="$FAILED
  - $*"; }
step() { printf '\n%s==> %s%s\n' "$CB$CC" "$*" "$C0"; }
part() { printf '\n%s========== %s ==========%s\n' "$CB$CC" "$*" "$C0"; }
die()  { printf '\n%sОСТАНОВ:%s %s\n' "$CR" "$C0" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
node-setup.sh — отчёт о ноде и её первоначальная настройка

  --secret <key>       SECRET_KEY из панели (можно вставить строку SECRET_KEY=...)
  --panel-ip <ip>      IP панели; порт ноды откроется только ему
  --node-port <port>   порт связи с панелью (по умолчанию 2222, спросит при запуске)
  --node-version <tag> версия образа ноды, например 3.2.2 или latest
  --node-image <ref>   образ целиком, если нужен свой реестр
  --hostname <name>    переименовать сервер
  --timezone <tz>      часовой пояс (по умолчанию Europe/Moscow)
  --dir <path>         каталог ноды (по умолчанию /opt/remnanode)
  --last <N>           сколько последних входов показать (по умолчанию 10)
  --status-only        только отчёт, ничего не настраивать
  --no-status          пропустить отчёт, сразу настройка
  --no-upgrade         не обновлять пакеты
  --no-ufw             не трогать фаервол
  --no-fail2ban        не ставить fail2ban
  --no-swap            не создавать swap
  --force-key          перезаписать существующий SECRET_KEY
  --yes                ничего не спрашивать, брать дефолты
  -h, --help           эта справка
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --secret)      SECRET_KEY="${2:-}"; shift 2;;
    --panel-ip)    PANEL_IP="${2:-}"; shift 2;;
    --node-port)   NODE_PORT="${2:-}"; shift 2;;
    --node-version) NODE_IMAGE="remnawave/node:${2:-}"; shift 2;;
    --node-image)  NODE_IMAGE="${2:-}"; shift 2;;
    --hostname)    NEW_HOSTNAME="${2:-}"; shift 2;;
    --timezone)    TIMEZONE="${2:-}"; shift 2;;
    --dir)         INSTALL_DIR="${2:-}"; shift 2;;
    --last)        LAST_COUNT="${2:-10}"; shift 2;;
    --status-only) STATUS_ONLY=1; shift;;
    --no-status)   NO_STATUS=1; shift;;
    --no-upgrade)  DO_UPGRADE=0; shift;;
    --no-ufw)      DO_UFW=0; shift;;
    --no-fail2ban) DO_F2B=0; shift;;
    --no-swap)     DO_SWAP=0; shift;;
    --force-key)   FORCE_KEY=1; shift;;
    --yes|-y)      ASSUME_YES=1; shift;;
    -h|--help)     usage; exit 0;;
    *) die "неизвестный аргумент: $1 (--help)";;
  esac
done

[ "$(id -u)" = "0" ] || die "нужен root"

# вопросы читаем с терминала, чтобы работало и через  curl ... | bash
# проверка именно попыткой открыть: /dev/tty существует всегда, но без
# управляющего терминала (ssh host < script, plink -m, cron) не открывается
TTY_IN=""
if { : < /dev/tty; } 2>/dev/null; then TTY_IN=/dev/tty; fi
interactive() { [ "$ASSUME_YES" = 1 ] && return 1; [ -n "$TTY_IN" ] && return 0; return 1; }

ask() {   # ask ПЕРЕМЕННАЯ "вопрос" "дефолт"
  # __ans инициализируем: если read сорвётся, при set -u скрипт бы упал
  local __var="$1" __q="$2" __def="${3:-}" __cur="" __ans=""
  eval "__cur=\${$__var:-}"
  [ -n "$__cur" ] && return 0
  if ! interactive; then eval "$__var=\"\$__def\""; return 0; fi
  if [ -n "$__def" ]; then printf '%s?%s %s [%s]: ' "$CC" "$C0" "$__q" "$__def"
  else printf '%s?%s %s: ' "$CC" "$C0" "$__q"; fi
  IFS= read -r __ans < "$TTY_IN" || true
  [ -z "$__ans" ] && __ans="$__def"
  eval "$__var=\"\$__ans\""
}
confirm() {   # confirm "вопрос" y|n
  local q="$1" def="${2:-y}" a=""
  # без терминала молчание НЕ значит согласие: менять что-то на сервере
  # можно только с явным --yes, иначе «нет». Иначе запуск без tty
  # (ssh host < script, plink -m, curl | bash в cron) начнёт настройку сам.
  if ! interactive; then
    [ "$ASSUME_YES" = 1 ] && return 0
    return 1
  fi
  printf '%s?%s %s [y/n, по умолчанию %s]: ' "$CC" "$C0" "$q" "$def"
  IFS= read -r a < "$TTY_IN" || true
  a="${a:-$def}"
  case "$a" in [yYдД]*) return 0;; *) return 1;; esac
}

say "${CB}node-setup v$VERSION${C0} — $(hostname), $(date '+%d.%m.%Y %H:%M %Z')"

# #############################################################################
if [ "$NO_STATUS" != "1" ]; then
part "ЧАСТЬ 1: что сейчас на ноде"
# #############################################################################

# =============================================================================
step "Кто и откуда заходил"
# =============================================================================
CUR_IP="$(echo "${SSH_CLIENT:-}" | awk '{print $1}')"
[ -n "$CUR_IP" ] && say "  сейчас ты с $CUR_IP"

if command -v last >/dev/null 2>&1; then
  say "  последние входы:"
  last -aiF 2>/dev/null | grep -vE '^(reboot|wtmp|$)' | head -n "$LAST_COUNT" | while IFS= read -r line; do
    ip="$(printf '%s' "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1)"
    if [ -n "$ip" ] && [ -n "$CUR_IP" ] && [ "$ip" != "$CUR_IP" ]; then
      printf '%s   * %s%s\n' "$CM" "$line" "$C0"
    else
      printf '     %s\n' "$line"
    fi
  done
  [ -n "$CUR_IP" ] && say "  (звёздочкой помечены входы не с твоего текущего IP)"
  RB="$(last -F reboot 2>/dev/null | head -1 | sed 's/  */ /g')"
  [ -n "$RB" ] && say "  последняя перезагрузка: $RB"
else
  warn "утилита last недоступна"
fi

say ""
say "  сейчас в системе:"
if command -v who >/dev/null 2>&1 && [ -n "$(who 2>/dev/null)" ]; then
  who -u 2>/dev/null | sed 's/^/    /'
else
  say "    (никого, кроме этой сессии)"
fi

FAILN="$(lastb 2>/dev/null | grep -cvE '^(btmp|$)')"
if [ "${FAILN:-0}" -gt 0 ]; then
  warn "неудачных попыток входа в журнале: $FAILN, последние:"
  lastb -aiF 2>/dev/null | head -5 | sed 's/^/      /'
else
  ok "неудачных попыток входа в журнале нет"
fi

if command -v fail2ban-client >/dev/null 2>&1; then
  F2B="$(fail2ban-client status sshd 2>/dev/null | grep -E 'Currently banned|Total banned' | tr -s ' \t' ' ' | tr '\n' ' ')"
  [ -n "$F2B" ] && ok "fail2ban sshd:$F2B"
fi

# =============================================================================
step "Контейнеры"
# =============================================================================
if command -v docker >/dev/null 2>&1; then
  say "  запущено $(docker ps -q 2>/dev/null | wc -l) из $(docker ps -aq 2>/dev/null | wc -l)"
  for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
    st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
    since="$(docker inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null | cut -dT -f1,2 | cut -d. -f1 | tr T ' ')"
    rc="$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null)"
    hl="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null)"
    img="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)"
    line="$(printf '%-22s %-28s %-9s рестартов:%-3s %s' "$c" "$img" "$st" "${rc:-0}" "${hl:+health:$hl }с $since")"
    case "$st" in
      running) if [ "$hl" = "unhealthy" ]; then bad "$line"; elif [ "${rc:-0}" -gt 5 ]; then warn "$line"; else ok "$line"; fi ;;
      restarting) bad "$line" ;;
      *) warn "$line" ;;
    esac
  done
else
  warn "docker не установлен"
fi

# =============================================================================
step "Здоровье ноды"
# =============================================================================
if command -v docker >/dev/null 2>&1 && [ -n "$(docker ps -aq --filter name=remnanode 2>/dev/null)" ]; then
  N_IMG="$(docker inspect -f '{{.Config.Image}}' remnanode 2>/dev/null)"
  N_ST="$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null)"
  N_HL="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' remnanode 2>/dev/null)"
  N_RC="$(docker inspect -f '{{.RestartCount}}' remnanode 2>/dev/null)"
  case "$N_IMG" in
    *:latest) warn "образ: $N_IMG — тег latest, при обновлении может разойтись с панелью" ;;
    *:*)      ok   "образ: $N_IMG" ;;
    *)        warn "образ: $N_IMG — тег не указан, версия не зафиксирована" ;;
  esac
  if [ "$N_ST" = "running" ]; then ok "контейнер: running, рестартов ${N_RC:-0}${N_HL:+, health: $N_HL}"
  else bad "контейнер: ${N_ST:-нет}, рестартов ${N_RC:-0}"; fi

  # порт связи с панелью
  P_CUR=""
  [ -f "$INSTALL_DIR/.env" ] && P_CUR="$(grep -E '^[[:space:]]*(NODE_PORT|APP_PORT)=' "$INSTALL_DIR/.env" | head -1 | cut -d= -f2 | tr -d '"'\''[:space:]')"
  [ -z "$P_CUR" ] && P_CUR=2222
  if [ -n "$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -x "$P_CUR" | head -1)" ]; then
    ok "порт панели $P_CUR слушается"
  else
    bad "порт панели $P_CUR не слушается"
  fi

  # разбор логов: типовые поломки видно сразу
  # логи ноды идут с ANSI-раскраской и нулевыми байтами — чистим,
  # иначе bash ругается «ignored null byte» и вывод разъезжается
  NLOG="$(docker logs --tail 200 remnanode 2>&1 | tr -d '\000' | sed 's/\x1b\[[0-9;]*m//g')"
  if printf '%s' "$NLOG" | grep -qi 'alert number 40\|handshake failure'; then
    bad "mTLS не сходится: панель и нода разных версий (SSL alert 40)"
    say "      лечится пином версии образа:  bash node-setup.sh --node-version 3.2.2"
  fi
  printf '%s' "$NLOG" | grep -qi 'unauthorized\|invalid secret\|jwt' && bad "панель не пускает: похоже, SECRET_KEY не тот"
  printf '%s' "$NLOG" | grep -qi 'xray.*started\|core.*started' && ok "ядро Xray стартовало"
  LASTERR="$(printf '%s' "$NLOG" | grep -iE 'error|panic|fatal' | tail -2)"
  if [ -n "$LASTERR" ]; then
    warn "последние ошибки в логе ноды:"
    printf '%s\n' "$LASTERR" | cut -c1-150 | sed 's/^/      /'
  fi

  # сколько сейчас клиентских соединений
  EST="$(ss -tnH state established 2>/dev/null | wc -l)"
  EST443="$(ss -tnH state established '( sport = :443 )' 2>/dev/null | wc -l)"
  say "  соединений: всего $EST, из них на :443 — $EST443"
else
  warn "контейнер remnanode не найден — нода ещё не настроена"
fi

# трафик с момента загрузки: показывает, работает ли нода вообще
IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
if [ -n "$IFACE" ]; then
  awk -v i="$IFACE" '$1 ~ "^"i":" {
      gsub(/.*:/, "", $1);
      printf "  трафик %s: принято %.1f ГиБ, отдано %.1f ГиБ (с момента загрузки)\n", i, $2/1073741824, $10/1073741824
    }' /proc/net/dev
fi
if command -v vnstat >/dev/null 2>&1; then
  vnstat --oneline 2>/dev/null | awk -F';' 'NF>10 {printf "  vnstat: сегодня %s, за месяц %s\n", $6, $11}'
fi

# сертификаты, если нода стоит за своим nginx
if [ -d /etc/letsencrypt/live ]; then
  for d in /etc/letsencrypt/live/*/; do
    [ -f "$d/fullchain.pem" ] || continue
    END="$(openssl x509 -enddate -noout -in "$d/fullchain.pem" 2>/dev/null | cut -d= -f2)"
    END_TS="$(date -d "$END" +%s 2>/dev/null)"
    NOW_TS="$(date +%s)"
    DAYS=$(( (END_TS - NOW_TS) / 86400 ))
    NAME="$(basename "$d")"
    if   [ "$DAYS" -lt 7 ];  then bad  "сертификат $NAME истекает через $DAYS дн."
    elif [ "$DAYS" -lt 21 ]; then warn "сертификат $NAME истекает через $DAYS дн."
    else                          ok   "сертификат $NAME годен ещё $DAYS дн."; fi
  done
fi

# =============================================================================
step "Службы"
# =============================================================================
if command -v systemctl >/dev/null 2>&1; then
  # список юнитов забираем один раз, а не дёргаем systemctl на каждую службу
  UNIT_FILES=" $(systemctl list-unit-files --no-pager --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ') "
  for s in ssh sshd docker ufw fail2ban cron chrony systemd-timesyncd nginx caddy xray wg-quick@wg0; do
    case "$UNIT_FILES" in
      *" ${s}.service "*)
        state="$(systemctl is-active "$s" 2>/dev/null)"
        boot="$(systemctl is-enabled "$s" 2>/dev/null)"
        line="$(printf '%-20s %-10s (автозапуск: %s)' "$s" "$state" "${boot:-?}")"
        if [ "$state" = "active" ]; then ok "$line"; else warn "$line"; fi
        ;;
    esac
  done
  # --plain убирает маркер в начале строки, иначе он попадает в имя юнита
  FAILED_UNITS="$(systemctl list-units --state=failed --no-legend --no-pager --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ' | sed 's/ *$//')"
  if [ -n "$FAILED_UNITS" ]; then bad "упавшие юниты: $FAILED_UNITS"; else ok "упавших юнитов нет"; fi
  say "  всего работает служб: $(systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | wc -l)"
else
  warn "systemd недоступен"
fi

# =============================================================================
step "Порты наружу"
# =============================================================================
if command -v ss >/dev/null 2>&1; then
  ss -tlnpH 2>/dev/null | awk '{
      proc = "";
      if (match($0, /users:\(\("[^"]+"/)) { proc = substr($0, RSTART+9, RLENGTH-9); gsub(/"/, "", proc); }
      printf "    tcp    %-22s %s\n", $4, proc
    }' | sort -u
  # Xray держит десятки случайных высоких UDP-портов — сворачиваем их в строку,
  # иначе они вытесняют из вывода всё осмысленное
  ss -ulnpH 2>/dev/null | awk '{
      addr = $4; n = split(addr, a, ":"); port = a[n] + 0;
      proc = "";
      if (match($0, /users:\(\("[^"]+"/)) { proc = substr($0, RSTART+9, RLENGTH-9); gsub(/"/, "", proc); }
      if (port <= 1024) { printf "    udp    %-22s %s\n", addr, proc }
      else { high[proc]++ }
    }
    END { for (p in high) printf "    udp    %-22s %s\n", "высоких портов: " high[p], (p == "" ? "(без процесса)" : p) }' | sort -u
else
  warn "ss недоступен"
fi
if command -v ufw >/dev/null 2>&1; then
  UST="$(ufw status 2>/dev/null | head -1)"
  UNIT_STATE="$(systemctl is-active ufw 2>/dev/null)"
  case "$UST" in
    *active*)
      ok "$UST"
      if [ -n "$UNIT_STATE" ] && [ "$UNIT_STATE" != "active" ]; then
        warn "при этом служба ufw в состоянии '$UNIT_STATE' — правила подняты, но после перезагрузки не встанут"
      fi
      ;;
    *) warn "${UST:-ufw статус неизвестен}" ;;
  esac
fi

# =============================================================================
step "Ресурсы"
# =============================================================================
say "  ОС        : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
say "  внешний IP: $(curl -s --max-time 6 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
say "  аптайм    : $(uptime -p 2>/dev/null | sed 's/^up //')"
say "  нагрузка  : $(uptime | sed 's/.*load average: //')  (ядер: $(nproc))"
say "  память    : $(free -m | awk '/^Mem:/{printf "%s из %s МБ занято", $3, $2}')"
say "  swap      : $(free -m | awk '/^Swap:/{if ($2==0) print "нет"; else printf "%s из %s МБ занято", $3, $2}')"
DISK_PCT="$(df -P / | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
DISK_TXT="$(df -h / | awk 'NR==2{print $3" из "$2" занято, свободно "$4}')"
if   [ "${DISK_PCT:-0}" -ge 90 ]; then bad  "диск / : $DISK_TXT (${DISK_PCT}%)"
elif [ "${DISK_PCT:-0}" -ge 80 ]; then warn "диск / : $DISK_TXT (${DISK_PCT}%)"
else                                   ok   "диск / : $DISK_TXT (${DISK_PCT}%)"; fi
DSIZE="$(docker system df --format '{{.Type}} {{.Size}}' 2>/dev/null | tr '\n' ' ')"
[ -n "$DSIZE" ] && say "  docker    : $DSIZE"

fi   # NO_STATUS

if [ "$STATUS_ONLY" = "1" ]; then
  say ""
  ok "только отчёт (--status-only) — ничего не менял"
  say "РЕЗУЛЬТАТ: ok"
  exit 0
fi

# #############################################################################
part "ЧАСТЬ 2: параметры настройки"
# #############################################################################
command -v apt-get >/dev/null 2>&1 || die "настройка рассчитана на Debian/Ubuntu (нет apt-get)"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

mkdir -p "$INSTALL_DIR"

# --- SECRET_KEY: валидный существующий не трогаем ---
EXIST_KEY=""
[ -f "$INSTALL_DIR/.env" ] && EXIST_KEY="$(grep -E '^[[:space:]]*SECRET_KEY=' "$INSTALL_DIR/.env" | head -1 | cut -d= -f2- | tr -d '"'\''[:space:]')"
if [ -z "$EXIST_KEY" ] && [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
  # ключ нового формата — base64, поэтому класс символов широкий, а префикс
  # срезаем якорем от начала строки: жадный .* съел бы '=' внутри самого ключа
  EXIST_KEY="$(grep -oE 'SECRET_KEY[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._+/=-]{16,}' "$INSTALL_DIR/docker-compose.yml" \
               | head -1 | sed -E 's/^SECRET_KEY[[:space:]]*[:=][[:space:]]*//')"
fi
if [ -n "$EXIST_KEY" ] && [ "$FORCE_KEY" != "1" ]; then
  ok "на ноде уже есть SECRET_KEY (${EXIST_KEY:0:10}…, ${#EXIST_KEY} симв.)"
  if confirm "Оставить его?" y; then SECRET_KEY="$EXIST_KEY"; fi
fi

while [ -z "$SECRET_KEY" ]; do
  say ""
  say "  SECRET_KEY берётся в панели: Nodes → нода → команда установки."
  say "  Можно вставить целиком строку вида SECRET_KEY=... — лишнее срежется."
  ask SECRET_KEY "SECRET_KEY" ""
  SECRET_KEY="$(printf '%s' "$SECRET_KEY" | sed -E 's/.*SECRET_KEY[[:space:]]*[:=][[:space:]]*//' | tr -d '"'\''[:space:]')"
  if [ -n "$SECRET_KEY" ] && [ "${#SECRET_KEY}" -lt 16 ]; then
    bad "ключ подозрительно короткий (${#SECRET_KEY} симв.)"; SECRET_KEY=""
  fi
  interactive || break
done

# порт SSH определяем первым: он нужен и для правила ufw, и чтобы не дать
# занять им же порт ноды
if [ -z "$SSH_PORT" ]; then
  SSH_PORT="$(echo "${SSH_CONNECTION:-}" | awk '{print $4}')"
  [ -z "$SSH_PORT" ] && SSH_PORT="$(ss -tlnpH 2>/dev/null | awk '/"sshd"/{print $4}' | sed 's/.*://' | head -1)"
  [ -z "$SSH_PORT" ] && SSH_PORT="$(awk '/^Port /{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
  [ -z "$SSH_PORT" ] && SSH_PORT=22
fi

# --- порт ноды: если он уже настроен, предлагаем его же, а не 2222 ---
OLD_PORT=""
[ -f "$INSTALL_DIR/.env" ] && OLD_PORT="$(grep -E '^[[:space:]]*(NODE_PORT|APP_PORT)=' "$INSTALL_DIR/.env" | head -1 | cut -d= -f2 | tr -d '"'\''[:space:]')"
if [ -z "$OLD_PORT" ] && [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
  OLD_PORT="$(grep -oE '(NODE_PORT|APP_PORT)[[:space:]]*[:=][[:space:]]*[0-9]{2,5}' "$INSTALL_DIR/docker-compose.yml" \
              | head -1 | grep -oE '[0-9]{2,5}$')"
fi
[ -n "$OLD_PORT" ] && ok "сейчас нода настроена на порт $OLD_PORT"

valid_port() {
  case "${1:-}" in ''|*[!0-9]*) return 1;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

while :; do
  ask NODE_PORT "Порт связи с панелью" "${OLD_PORT:-2222}"
  if ! valid_port "$NODE_PORT"; then
    bad "порт должен быть числом от 1 до 65535, а не «$NODE_PORT»"
  elif [ "$NODE_PORT" = "$SSH_PORT" ]; then
    bad "порт $NODE_PORT занят SSH — возьми другой"
  else
    # порт может быть занят кем-то посторонним: своя же нода не в счёт
    BUSY="$(ss -tlnpH 2>/dev/null | awk -v p=":$NODE_PORT" '$4 ~ p"$" {print $0}' | grep -v 'rw-node\|remnanode' | head -1)"
    if [ -n "$BUSY" ]; then
      warn "порт $NODE_PORT уже слушает: $(printf '%s' "$BUSY" | grep -oE 'users:\(\("[^"]+' | sed 's/.*"//')"
      confirm "Всё равно занять его под ноду?" n && break
    else
      break
    fi
  fi
  interactive || die "порт $NODE_PORT не подходит"
  NODE_PORT=""
done
[ -n "$OLD_PORT" ] && [ "$OLD_PORT" != "$NODE_PORT" ] && warn "порт меняется: $OLD_PORT → $NODE_PORT (не забудь поправить его в панели)"

# --- версия образа: latest сплошь и рядом расходится с версией панели ---
OLD_IMAGE=""
[ -f "$INSTALL_DIR/docker-compose.yml" ] && OLD_IMAGE="$(grep -oE 'image:[[:space:]]*[^[:space:]]+' "$INSTALL_DIR/docker-compose.yml" | grep -i 'remnawave/node' | head -1 | sed -E 's/image:[[:space:]]*//')"
[ -n "$OLD_IMAGE" ] && ok "сейчас стоит образ $OLD_IMAGE"
if [ -z "$NODE_IMAGE" ]; then
  say ""
  say "  Версия ноды должна совпадать с версией панели, иначе mTLS не сойдётся"
  say "  и в логах будет «tls alert handshake failure ... alert number 40»."
  say "  latest сейчас 3.3.x; с панелями 2.8.x рабочая связка — 3.2.2."
fi
ask NODE_IMAGE "Образ ноды" "${OLD_IMAGE:-$NODE_IMAGE_DEFAULT}"
case "$NODE_IMAGE" in
  *:*) : ;;                                   # уже с тегом
  */*) NODE_IMAGE="$NODE_IMAGE:latest" ;;     # репозиторий без тега
  *)   NODE_IMAGE="remnawave/node:$NODE_IMAGE" ;;  # ввели просто «3.2.2»
esac
case "$NODE_IMAGE" in
  *:latest) warn "берётся latest — при следующем обновлении может разойтись с панелью" ;;
esac
[ -n "$OLD_IMAGE" ] && [ "$OLD_IMAGE" != "$NODE_IMAGE" ] && warn "образ меняется: $OLD_IMAGE → $NODE_IMAGE"

ask PANEL_IP     "IP панели Remnawave (Enter — порт откроется всем)" ""
ask NEW_HOSTNAME "Новое имя сервера (Enter — оставить $(hostname))" ""
ask TIMEZONE     "Часовой пояс" "Europe/Moscow"

say ""
say "  ${CB}Итого:${C0}"
say "     каталог     $INSTALL_DIR"
say "     порт ноды   $NODE_PORT  (панель: ${PANEL_IP:-любой IP})"
say "     SSH-порт    $SSH_PORT (для правила ufw)"
say "     ключ        ${SECRET_KEY:0:10}… (${#SECRET_KEY} симв.)"
say "     имя сервера ${NEW_HOSTNAME:-$(hostname) — без изменений}"
say "     часовой пояс $TIMEZONE"
say "     обновление пакетов: $([ "$DO_UPGRADE" = 1 ] && echo да || echo нет)   ufw: $([ "$DO_UFW" = 1 ] && echo да || echo нет)   fail2ban: $([ "$DO_F2B" = 1 ] && echo да || echo нет)   swap: $([ "$DO_SWAP" = 1 ] && echo да || echo нет)"
if ! confirm "Начинать настройку?" y; then
  if interactive; then die "отменено"; fi
  die "нет терминала для подтверждения — запусти из консоли сервера либо добавь --yes"
fi

# #############################################################################
part "ЧАСТЬ 3: настройка"
# #############################################################################

# =============================================================================
step "1/8  Имя, часовой пояс, время"
# =============================================================================
if [ -n "$NEW_HOSTNAME" ] && [ "$NEW_HOSTNAME" != "$(hostname)" ]; then
  if hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null; then
    grep -q "$NEW_HOSTNAME" /etc/hosts || echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
    ok "hostname → $NEW_HOSTNAME"
  else warn "не смог сменить hostname"; fi
fi
if [ -n "$TIMEZONE" ] && [ "$(timedatectl show -p Timezone --value 2>/dev/null)" != "$TIMEZONE" ]; then
  timedatectl set-timezone "$TIMEZONE" 2>/dev/null && ok "часовой пояс → $TIMEZONE" || warn "не смог выставить $TIMEZONE"
else
  ok "часовой пояс: $(timedatectl show -p Timezone --value 2>/dev/null)"
fi
timedatectl set-ntp true >/dev/null 2>&1

# =============================================================================
step "2/8  Пакеты"
# =============================================================================
apt-get update -qq 2>/dev/null && ok "apt update" || err "apt update не прошёл"
if [ "$DO_UPGRADE" = "1" ]; then
  say "  обновление пакетов, это пара минут…"
  apt-get -y -qq -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef upgrade >/dev/null 2>&1 \
    && ok "пакеты обновлены" || warn "upgrade прошёл с замечаниями"
fi
PKGS="curl ca-certificates gnupg jq unzip tar htop ufw chrony net-tools dnsutils"
apt-get install -y -qq $PKGS >/dev/null 2>&1 && ok "базовые пакеты на месте" || warn "часть пакетов не поставилась"

# =============================================================================
step "3/8  Swap"
# =============================================================================
RAM_MB="$(free -m | awk '/^Mem:/{print $2}')"
SWAP_MB="$(free -m | awk '/^Swap:/{print $2}')"
if [ "$DO_SWAP" = "1" ] && [ "${SWAP_MB:-0}" -lt 128 ]; then
  SZ=2G; [ "${RAM_MB:-0}" -ge 8000 ] && SZ=4G
  if fallocate -l "$SZ" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null; then
    chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "swap $SZ создан"
  else warn "не смог создать swap"; fi
else
  ok "swap: ${SWAP_MB:-0} МБ, создавать не нужно"
fi

# =============================================================================
step "4/8  Сетевые лимиты и BBR"
# =============================================================================
cat > /etc/sysctl.d/99-remnanode.conf <<'SYSCTL'
# сеть под VPN-нагрузку
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_forward = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
fs.file-max = 1048576
SYSCTL
sysctl --system >/dev/null 2>&1
CC_ALGO="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
[ "$CC_ALGO" = "bbr" ] && ok "sysctl применён, congestion control: bbr" || warn "sysctl применён, congestion control: ${CC_ALGO:-?}"

grep -q '^\* soft nofile' /etc/security/limits.conf 2>/dev/null || cat >> /etc/security/limits.conf <<'LIM'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIM
ok "лимиты открытых файлов подняты"

# =============================================================================
step "5/8  Docker"
# =============================================================================
if command -v docker >/dev/null 2>&1; then
  ok "docker уже стоит: $(docker --version | awk '{print $3}' | tr -d ,)"
else
  say "  ставлю docker с get.docker.com…"
  if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh >/dev/null 2>&1; then
    ok "docker установлен: $(docker --version | awk '{print $3}' | tr -d ,)"
  else
    err "docker не установился"
  fi
  rm -f /tmp/get-docker.sh
fi
docker compose version >/dev/null 2>&1 && ok "docker compose v2 на месте" || err "нет docker compose v2 — нода не поднимется"
systemctl enable --now docker >/dev/null 2>&1

if [ ! -f /etc/docker/daemon.json ]; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'DJSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m", "max-file": "5" }
}
DJSON
  systemctl restart docker >/dev/null 2>&1 && ok "ротация логов docker настроена"
else
  ok "/etc/docker/daemon.json уже есть — не трогаю"
fi

# =============================================================================
step "6/8  Фаервол и fail2ban"
# =============================================================================
if [ "$DO_UFW" != "1" ]; then
  warn "ufw пропущен по флагу"
elif ! command -v ufw >/dev/null 2>&1; then
  warn "ufw не установлен"
else
  ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null 2>&1
  # порт сменился — старое разрешение надо убрать, иначе останется открытым
  if [ -n "$OLD_PORT" ] && [ "$OLD_PORT" != "$NODE_PORT" ]; then
    ufw --force delete allow "${OLD_PORT}/tcp" >/dev/null 2>&1
    [ -n "$PANEL_IP" ] && ufw --force delete allow from "$PANEL_IP" to any port "$OLD_PORT" >/dev/null 2>&1
    ok "старое правило на порт $OLD_PORT удалено"
  fi
  if [ -n "$PANEL_IP" ]; then
    ufw allow from "$PANEL_IP" to any port "$NODE_PORT" comment 'remnawave panel' >/dev/null 2>&1
    ok "порт ноды $NODE_PORT открыт только для $PANEL_IP"
  else
    ufw allow "${NODE_PORT}/tcp" comment 'remnawave panel (any)' >/dev/null 2>&1
    warn "IP панели не задан — порт $NODE_PORT открыт всем, сузь позже"
  fi
  ufw allow 443/tcp comment 'VPN tls' >/dev/null 2>&1
  ufw allow 443/udp comment 'VPN quic/hysteria' >/dev/null 2>&1
  ufw allow 80/tcp  comment 'certbot' >/dev/null 2>&1
  UFW_STATE="$(ufw status 2>/dev/null | head -1)"
  case "$UFW_STATE" in
    *active*) ok "ufw уже включён, правила добавлены" ;;
    *) yes | ufw --force enable >/dev/null 2>&1 && ok "ufw включён (SSH-порт $SSH_PORT разрешён)" || err "не смог включить ufw" ;;
  esac
fi

if [ "$DO_F2B" = "1" ]; then
  apt-get install -y -qq fail2ban >/dev/null 2>&1
  if command -v fail2ban-server >/dev/null 2>&1; then
    [ -f /etc/fail2ban/jail.local ] || cat > /etc/fail2ban/jail.local <<F2B
[sshd]
enabled = true
port    = $SSH_PORT
backend = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
F2B
    systemctl enable --now fail2ban >/dev/null 2>&1 && ok "fail2ban сторожит SSH" || warn "fail2ban не стартовал"
  else warn "fail2ban не поставился"; fi
fi

# =============================================================================
step "7/8  Нода Remnawave"
# =============================================================================
cd "$INSTALL_DIR" || die "нет $INSTALL_DIR"

# если в compose уже есть посторонние сервисы — это боевая нода со своей
# обвязкой, её файл трогать нельзя
OTHER_SVC=""
if [ -f docker-compose.yml ]; then
  OTHER_SVC="$(awk '/^services:/{f=1;next} f&&/^[A-Za-z]/{f=0} f&&/^  [A-Za-z0-9_.-]+:/{gsub(/[ :]/,"");print}' docker-compose.yml \
               | grep -v '^remnanode$' | tr '\n' ' ' | sed 's/ *$//')"
fi

if [ -n "$OTHER_SVC" ]; then
  warn "в docker-compose.yml есть свои сервисы ($OTHER_SVC) — файл НЕ трогаю и контейнеры не перезапускаю"
  warn "нода уже обвязана: система подготовлена, ключ и compose оставлены как были"
elif [ -z "$SECRET_KEY" ]; then
  err "SECRET_KEY не задан — контейнер ноды не поднимаю"
elif [ "${#SECRET_KEY}" -lt 16 ]; then
  err "SECRET_KEY подозрительно короткий (${#SECRET_KEY} симв.) — не поднимаю"
else
  for f in docker-compose.yml .env; do
    [ -f "$f" ] && { cp -a "$f" "$f.bak.$STAMP"; ok "бэкап $f → $f.bak.$STAMP"; }
  done

  cat > .env <<ENV
### remnanode — создан node-setup $(date '+%d.%m.%Y %H:%M')
APP_PORT=$NODE_PORT
NODE_PORT=$NODE_PORT
SECRET_KEY=$SECRET_KEY
ENV
  chmod 600 .env
  ok ".env записан (ключ ${#SECRET_KEY} симв.)"

  cat > docker-compose.yml <<COMPOSE
services:
  remnanode:
    image: $NODE_IMAGE
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    cap_add: [NET_ADMIN]
    env_file: [.env]
    ulimits:
      nofile: { soft: 1048576, hard: 1048576 }
    logging:
      driver: json-file
      options: { max-size: 100m, max-file: "5" }
    volumes:
      - /dev/shm:/dev/shm:rw
COMPOSE
  ok "docker-compose.yml записан"

  if docker compose pull -q >/dev/null 2>&1; then
    ok "образ $NODE_IMAGE скачан"
  else
    err "образ $NODE_IMAGE не скачался — проверь, что такой тег существует"
    say "      список версий: https://hub.docker.com/r/remnawave/node/tags"
  fi
  docker compose up -d >/dev/null 2>&1 && ok "контейнер поднят" || err "docker compose up упал"
fi

# =============================================================================
step "8/8  Проверка"
# =============================================================================
sleep 6
CT_STATUS="$(docker ps --filter name=remnanode --format '{{.Status}}' 2>/dev/null)"
if [ -n "$CT_STATUS" ]; then ok "remnanode: $CT_STATUS"
else err "контейнер remnanode не запущен"; docker logs --tail 20 remnanode 2>&1 | sed 's/^/      /'; fi

# проверка без «| grep -q»: он рвёт поток и в конвейере даёт код 141
LISTEN="$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -x "$NODE_PORT" | head -1)"
if [ -n "$LISTEN" ]; then ok "порт $NODE_PORT слушается"
else err "порт $NODE_PORT не слушается"; fi

NLOG2="$(docker logs --tail 60 remnanode 2>&1 | tr -d '\000' | sed 's/\x1b\[[0-9;]*m//g')"
if printf '%s' "$NLOG2" | grep -qi 'alert number 40\|handshake failure'; then
  err "mTLS с панелью не сошёлся (SSL alert 40) — версии ноды и панели разные"
  say "      сейчас стоит $NODE_IMAGE; попробуй другую версию, например:"
  say "      bash node-setup.sh --node-version 3.2.2 --yes"
  say "      посмотреть версию панели: в её веб-интерфейсе внизу или docker inspect на сервере панели"
fi
printf '%s' "$NLOG2" | grep -qi 'unauthorized\|invalid secret' && err "панель не пускает ноду — SECRET_KEY не подходит"
LOGERR="$(printf '%s' "$NLOG2" | grep -iE 'error|invalid|unauthor' | head -3)"
[ -n "$LOGERR" ] && { warn "в логах ноды есть ошибки:"; printf '      %s\n' "$LOGERR"; }

# #############################################################################
part "ИТОГ"
# #############################################################################
say "  Хост        : $(hostname)"
say "  ОС          : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")"
say "  Docker      : $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
say "  Каталог     : $INSTALL_DIR"
say "  Образ ноды  : $NODE_IMAGE"
if [ -n "$OLD_PORT" ] && [ "$OLD_PORT" != "$NODE_PORT" ]; then
  say "  Порт ноды   : $NODE_PORT  (был $OLD_PORT — поменяй его и в панели!)  (панель: ${PANEL_IP:-любой IP})"
else
  say "  Порт ноды   : $NODE_PORT  (панель: ${PANEL_IP:-любой IP})"
fi
say "  SECRET_KEY  : ${SECRET_KEY:0:10}… (${#SECRET_KEY} симв.)"
say "  Контейнер   : ${CT_STATUS:-не запущен}"
say "  UFW         : $(ufw status 2>/dev/null | head -1)"
say "  Swap        : $(free -m | awk '/^Swap:/{print $2}') МБ"
say ""
if [ -n "$FAILED" ]; then
  bad "проблемы:$FAILED"
  say ""
  say "РЕЗУЛЬТАТ: настроено с ошибками"
  exit 1
fi
say "Дальше: в панели Remnawave привязать ноду к этому IP и порту $NODE_PORT,"
say "потом настроить inbound и хосты. Подготовка сервера закончена."
say ""
say "РЕЗУЛЬТАТ: ok"
