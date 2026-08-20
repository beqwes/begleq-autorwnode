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

VERSION="2.3"
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
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.28}"
# self-steal домен: под него выпускается сертификат и ставится сайт-заглушка
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
SITE_THEME="${SITE_THEME:-}"
XHTTP_PATH="${XHTTP_PATH:-/api/v3/media}"
WEBROOT="${WEBROOT:-/var/www/html}"
DO_UPGRADE=1; DO_UFW=1; DO_F2B=1; DO_SWAP=1; DO_NGINX=1; DO_SITE=1
FORCE_KEY=0; STATUS_ONLY=0; NO_STATUS=0; ASSUME_YES=0; FORCE_SITE=0

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
  --domain <host>      self-steal домен ноды: сертификат, nginx и сайт-заглушка
  --email <mail>       почта для Let's Encrypt (по умолчанию admin@домен)
  --xhttp-path <path>  путь, который nginx отдаёт Xray (по умолчанию /api/v3/media)
  --site-theme <t>     тема заглушки: media, files, studio, shop (по умолчанию случайная)
  --force-site         перезаписать уже существующий сайт в /var/www/html
  --no-nginx           не ставить nginx и не выпускать сертификат
  --no-site            не трогать сайт-заглушку
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
    --domain)      DOMAIN="${2:-}"; shift 2;;
    --email)       EMAIL="${2:-}"; shift 2;;
    --xhttp-path)  XHTTP_PATH="${2:-}"; shift 2;;
    --site-theme)  SITE_THEME="${2:-}"; shift 2;;
    --force-site)  FORCE_SITE=1; shift;;
    --no-nginx)    DO_NGINX=0; shift;;
    --no-site)     DO_SITE=0; shift;;
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
# в дефолт подставляем текущий образ ноды, но latest не предлагаем:
# именно с него и прилетает alert 40, а сюда обычно приходят чинить его
DEF_IMAGE="$NODE_IMAGE_DEFAULT"
case "$OLD_IMAGE" in
  ""|*:latest) : ;;
  *) DEF_IMAGE="$OLD_IMAGE" ;;
esac
if [ -z "$NODE_IMAGE" ]; then
  say ""
  say "  Версия ноды должна совпадать с версией панели, иначе mTLS не сойдётся"
  say "  и в логах будет «tls alert handshake failure ... alert number 40»."
  say "  Достаточно вписать номер версии, например 3.2.2 — имя образа подставится само."
  say "  latest сейчас 3.3.x и подходит только к панелям 3.3.x; с панелями 2.8.x берут 3.2.2."
  case "$OLD_IMAGE" in
    *:latest) warn "сейчас на ноде $OLD_IMAGE — если ловишь alert 40, впиши конкретную версию" ;;
  esac
fi
ask NODE_IMAGE "Образ ноды (можно просто номер версии)" "$DEF_IMAGE"
case "$NODE_IMAGE" in
  *:*) : ;;                                   # уже с тегом
  */*) NODE_IMAGE="$NODE_IMAGE:latest" ;;     # репозиторий без тега
  *)   NODE_IMAGE="remnawave/node:$NODE_IMAGE" ;;  # ввели просто «3.2.2»
esac
case "$NODE_IMAGE" in
  *:latest) warn "берётся latest — при следующем обновлении может разойтись с панелью" ;;
esac
[ -n "$OLD_IMAGE" ] && [ "$OLD_IMAGE" != "$NODE_IMAGE" ] && warn "образ меняется: $OLD_IMAGE → $NODE_IMAGE"

# --- домен self-steal: он же для сертификата и сайта-заглушки ---
if [ "$DO_NGINX" = "1" ]; then
  if [ -z "$DOMAIN" ]; then
    say ""
    say "  Домен ноды нужен для сертификата, nginx и сайта-заглушки."
    say "  A-запись должна уже указывать на этот сервер. Enter — пропустить,"
    say "  тогда поднимется только нода без nginx и заглушки."
  fi
  ask DOMAIN "Домен ноды (self-steal)" ""
  if [ -z "$DOMAIN" ]; then
    DO_NGINX=0
    warn "домен не задан — nginx, сертификат и сайт пропускаются"
  else
    ask EMAIL "Почта для Let's Encrypt" "admin@$DOMAIN"
    RESOLVED="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
    MY_IP="$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null)"
    if [ -z "$RESOLVED" ]; then
      warn "$DOMAIN не резолвится — сертификат не выпустится, пока не появится A-запись"
    elif [ -n "$MY_IP" ] && [ "$RESOLVED" != "$MY_IP" ]; then
      warn "$DOMAIN указывает на $RESOLVED, а сервер $MY_IP — сертификат не выпустится"
    else
      ok "DNS: $DOMAIN → $RESOLVED"
    fi
    # тема заглушки: если не задана — берём случайную
    if [ -z "$SITE_THEME" ]; then
      SITE_THEME="$(shuf -e media files studio shop -n 1 2>/dev/null || echo media)"
      ok "тема сайта-заглушки выбрана случайно: $SITE_THEME"
    fi
    case "$SITE_THEME" in
      media|files|studio|shop) : ;;
      *) die "неизвестная тема сайта: $SITE_THEME (media|files|studio|shop)";;
    esac
  fi
fi

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
step "1/11  Имя, часовой пояс, время"
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
step "2/11  Пакеты"
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
step "3/11  Swap"
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
step "4/11  Сетевые лимиты и BBR"
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
step "5/11  Docker"
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
step "6/11  Фаервол и fail2ban"
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
step "7/11  Сертификат Let's Encrypt"
# =============================================================================
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
if [ "$DO_NGINX" != "1" ]; then
  warn "пропущено: домен не задан"
elif [ -f "$CERT_DIR/fullchain.pem" ]; then
  ok "сертификат уже есть, годен до $(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2)"
else
  command -v certbot >/dev/null 2>&1 || apt-get install -y -qq certbot >/dev/null 2>&1
  # :80 в этой схеме свободен — Xray держит только :443, nginx сидит на сокете
  BUSY80="$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -x 80 | head -1)"
  [ -n "$BUSY80" ] && warn "порт 80 кем-то занят — certbot может не пройти"
  if certbot certonly --standalone -n --agree-tos -m "$EMAIL" -d "$DOMAIN" >/dev/null 2>&1; then
    ok "сертификат выпущен для $DOMAIN"
  else
    err "certbot не выпустил сертификат для $DOMAIN (проверь A-запись и что :80 доступен снаружи)"
  fi
fi
# после продления nginx надо перечитать сертификат
if [ "$DO_NGINX" = "1" ]; then
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-remnawave-nginx.sh <<'HOOK'
#!/bin/sh
docker exec remnawave-nginx nginx -s reload >/dev/null 2>&1 || true
HOOK
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-remnawave-nginx.sh
fi

# =============================================================================
step "8/11  Сайт-заглушка"
# =============================================================================
if [ "$DO_NGINX" != "1" ] || [ "$DO_SITE" != "1" ]; then
  warn "пропущено"
elif [ -f "$WEBROOT/index.html" ] && [ "$FORCE_SITE" != "1" ]; then
  ok "сайт в $WEBROOT уже есть — не трогаю (--force-site чтобы перезаписать)"
else
  [ -d "$WEBROOT" ] && [ -n "$(ls -A "$WEBROOT" 2>/dev/null)" ] && {
    cp -a "$WEBROOT" "${WEBROOT}.bak.$STAMP"; ok "старый сайт → ${WEBROOT}.bak.$STAMP"; }

  # содержимое подбирается под тему, названия и цифры разные при каждом запуске
  RND_A="$(shuf -i 1000-9999 -n 1 2>/dev/null || echo 4242)"
  case "$SITE_THEME" in
    media)
      SITE_NAME="$(shuf -e Lumen Vireo Aster Nimbus Kestrel -n 1 2>/dev/null || echo Lumen) Stream"
      TAGLINE="Потоковое видео и трансляции"; NAV2="Библиотека"; NAV2_SLUG="library"
      F1="Прямые эфиры|Мультибитрейтный HLS, адаптивное качество, задержка до 4 секунд."
      F2="Библиотека|Более 12 000 часов записей с автоматической расстановкой глав."
      F3="Аналитика|Онлайн-статистика по зрителям, буферизации и качеству сегментов." ;;
    files)
      SITE_NAME="$(shuf -e Dropstone Cratebox Vaultly Parcело Filoak -n 1 2>/dev/null || echo Dropstone)"
      TAGLINE="Файловое хранилище и обмен"; NAV2="Тарифы"; NAV2_SLUG="pricing"
      F1="Быстрая отдача|Раздача по 10 Гбит/с, докачка, прямые ссылки без ожидания."
      F2="Шифрование|AES-256 на стороне хранилища, ссылки с ограниченным сроком жизни."
      F3="API|Загрузка чанками, вебхуки на завершение, S3-совместимость." ;;
    studio)
      SITE_NAME="$(shuf -e Northline Meridian Karbon Oakform Pilotworks -n 1 2>/dev/null || echo Northline) Studio"
      TAGLINE="Веб-разработка и цифровые продукты"; NAV2="Работы"; NAV2_SLUG="work"
      F1="Продукты|Проектирование, дизайн-система, фронтенд и бэкенд одной командой."
      F2="Поддержка|Дежурная смена, мониторинг, восстановление до 30 минут."
      F3="Интеграции|Платежи, CRM, складской учёт и телеметрия в одном контуре." ;;
    shop)
      SITE_NAME="$(shuf -e Vellum Ferra Lintwood Bruna Sadovaya -n 1 2>/dev/null || echo Vellum) Store"
      TAGLINE="Товары для дома и интерьера"; NAV2="Каталог"; NAV2_SLUG="catalog"
      F1="Доставка|По городу за день, по стране от двух дней, самовывоз из 14 точек."
      F2="Возврат|30 дней на возврат без объяснения причин, обмен по размеру бесплатно."
      F3="Гарантия|Официальная гарантия производителя, сервис в каждом регионе." ;;
  esac
  ACCENT="$(shuf -e '#2f6df6' '#0f9d76' '#c2410c' '#7c3aed' '#0891b2' -n 1 2>/dev/null || echo '#2f6df6')"

  mkdir -p "$WEBROOT/assets/js" "$WEBROOT/$NAV2_SLUG" "$WEBROOT/about"

  cat > "$WEBROOT/assets/style.css" <<CSS
:root{--bg:#fff;--fg:#14171c;--muted:#5d6673;--line:#e6e9ee;--acc:$ACCENT;--card:#fafbfd}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--fg:#e8ecf2;--muted:#98a2b3;--line:#232833;--card:#151922}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
a{color:var(--acc);text-decoration:none}a:hover{text-decoration:underline}
.wrap{max-width:1060px;margin:0 auto;padding:0 20px}
header{border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:5}
header .wrap{display:flex;align-items:center;gap:24px;height:62px}
.logo{display:flex;align-items:center;gap:9px;font-weight:700;letter-spacing:-.02em}
.logo i{width:22px;height:22px;border-radius:6px;background:var(--acc);display:block}
nav{margin-left:auto;display:flex;gap:20px}nav a{color:var(--muted);font-size:14px}
.hero{padding:70px 0 40px}.hero h1{font-size:40px;line-height:1.15;margin:0 0 14px;letter-spacing:-.03em}
.hero p{color:var(--muted);font-size:18px;max-width:620px;margin:0 0 26px}
.btn{display:inline-block;padding:11px 20px;border-radius:9px;background:var(--acc);color:#fff;font-weight:600;font-size:15px}
.btn.ghost{background:transparent;color:var(--fg);border:1px solid var(--line)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:18px;padding:26px 0 60px}
.card{border:1px solid var(--line);border-radius:14px;padding:20px;background:var(--card)}
.card h3{margin:0 0 8px;font-size:17px}.card p{margin:0;color:var(--muted);font-size:14px}
.stats{display:flex;gap:34px;flex-wrap:wrap;padding:26px 0;border-top:1px solid var(--line);border-bottom:1px solid var(--line)}
.stats div b{display:block;font-size:26px;letter-spacing:-.02em}.stats div span{color:var(--muted);font-size:13px}
table{width:100%;border-collapse:collapse;font-size:14px;margin:10px 0 40px}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line)}th{color:var(--muted);font-weight:600}
footer{border-top:1px solid var(--line);padding:26px 0;color:var(--muted);font-size:13px}
footer .wrap{display:flex;gap:18px;flex-wrap:wrap}
h2{font-size:24px;letter-spacing:-.02em;margin:38px 0 10px}
p.lead{color:var(--muted)}
@media(max-width:640px){.hero h1{font-size:30px}nav{display:none}}
CSS

  cat > "$WEBROOT/assets/js/app.js" <<'JS'
(function () {
  var started = Date.now();
  function tick() {
    var el = document.querySelector('[data-uptime]');
    if (el) {
      var s = Math.floor((Date.now() - started) / 1000);
      el.textContent = Math.floor(s / 60) + 'м ' + (s % 60) + 'с';
    }
  }
  setInterval(tick, 1000); tick();
  document.querySelectorAll('[data-toggle]').forEach(function (b) {
    b.addEventListener('click', function (e) {
      e.preventDefault();
      var box = document.querySelector(b.getAttribute('data-toggle'));
      if (box) box.hidden = !box.hidden;
    });
  });
  try {
    var k = 'v_' + new Date().toISOString().slice(0, 10);
    var n = parseInt(localStorage.getItem(k) || '0', 10) + 1;
    localStorage.setItem(k, String(n));
    var c = document.querySelector('[data-visits]');
    if (c) c.textContent = String(n);
  } catch (e) {}
})();
JS

  cat > "$WEBROOT/favicon.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="$ACCENT"/><path d="M20 20h24v8H20zm0 16h24v8H20z" fill="#fff"/></svg>
SVG

  page_head() {
    printf '%s\n' "<!doctype html>" "<html lang=\"ru\"><head>" \
      "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" \
      "<title>$1 — $SITE_NAME</title>" \
      "<meta name=\"description\" content=\"$TAGLINE\">" \
      "<link rel=\"icon\" href=\"/favicon.svg\" type=\"image/svg+xml\">" \
      "<link rel=\"stylesheet\" href=\"/assets/style.css\">" \
      "</head><body>" \
      "<header><div class=\"wrap\">" \
      "  <a class=\"logo\" href=\"/\"><i></i>$SITE_NAME</a>" \
      "  <nav><a href=\"/\">Главная</a><a href=\"/$NAV2_SLUG/\">$NAV2</a><a href=\"/about/\">О нас</a></nav>" \
      "</div></header>"
  }
  page_foot() {
    printf '%s\n' "<footer><div class=\"wrap\">" \
      "  <span>© $(date +%Y) $SITE_NAME</span>" \
      "  <span>Сессия: <b data-uptime>0м 0с</b></span>" \
      "  <span>Визитов: <b data-visits>1</b></span>" \
      "</div></footer>" \
      "<script src=\"/assets/js/app.js\"></script>" \
      "</body></html>"
  }
  card() { printf '    <div class="card"><h3>%s</h3><p>%s</p></div>\n' "${1%%|*}" "${1#*|}"; }

  {
    page_head "$TAGLINE"
    printf '%s\n' "<section class=\"hero\"><div class=\"wrap\">" \
      "  <h1>$SITE_NAME</h1>" \
      "  <p>$TAGLINE. Инфраструктура в двух дата-центрах, отдача через распределённую сеть кэширования.</p>" \
      "  <a class=\"btn\" href=\"/$NAV2_SLUG/\">Раздел «$NAV2»</a>" \
      "  <a class=\"btn ghost\" href=\"/about/\">Подробнее</a>" \
      "</div></section>" \
      "<div class=\"wrap\">" \
      "  <div class=\"stats\">" \
      "    <div><b>99.9%</b><span>доступность за 90 дней</span></div>" \
      "    <div><b>$((RND_A % 40 + 12)) мс</b><span>медианный отклик</span></div>" \
      "    <div><b>$((RND_A % 9 + 6))</b><span>точек присутствия</span></div>" \
      "    <div><b>10 Гбит/с</b><span>полоса на узел</span></div>" \
      "  </div>" \
      "  <div class=\"grid\">"
    card "$F1"; card "$F2"; card "$F3"
    printf '%s\n' "  </div>" "</div>"
    page_foot
  } > "$WEBROOT/index.html"

  {
    page_head "$NAV2"
    printf '%s\n' "<div class=\"wrap\">" \
      "  <h2>$NAV2</h2>" \
      "  <p class=\"lead\">Раздел обновляется автоматически. Ниже последние записи.</p>" \
      "  <table>" \
      "    <tr><th>Название</th><th>Обновлено</th><th>Размер</th><th>Статус</th></tr>" \
      "    <tr><td>Выпуск $(date +%Y)-$(date +%m)</td><td>$(date +%d.%m.%Y)</td><td>1.2 ГБ</td><td>Готово</td></tr>" \
      "    <tr><td>Выпуск $(date -d '-1 month' +%Y-%m 2>/dev/null || date +%Y-%m)</td><td>$(date -d '-31 days' +%d.%m.%Y 2>/dev/null || date +%d.%m.%Y)</td><td>940 МБ</td><td>Готово</td></tr>" \
      "    <tr><td>Архив $(($(date +%Y)-1))</td><td>$(($(date +%Y)-1))</td><td>18 ГБ</td><td>В архиве</td></tr>" \
      "  </table>" \
      "  <p><a href=\"#\" data-toggle=\"#more\">Показать технические детали</a></p>" \
      "  <div id=\"more\" hidden class=\"card\"><p>Объекты раздаются через кэширующий слой, ключи инвалидации живут 3600 секунд.</p></div>" \
      "</div>"
    page_foot
  } > "$WEBROOT/$NAV2_SLUG/index.html"

  {
    page_head "О нас"
    printf '%s\n' "<div class=\"wrap\">" \
      "  <h2>О компании</h2>" \
      "  <p class=\"lead\">$SITE_NAME работает с $(($(date +%Y)-6)) года. $TAGLINE — основное направление.</p>" \
      "  <div class=\"grid\">" \
      "    <div class=\"card\"><h3>Инфраструктура</h3><p>Стойки в двух ЦОД, резервирование питания и каналов, ежедневные снапшоты.</p></div>" \
      "    <div class=\"card\"><h3>Поддержка</h3><p>Обращения принимаются круглосуточно, первая реакция в течение 15 минут.</p></div>" \
      "    <div class=\"card\"><h3>Документы</h3><p>Оферта и политика обработки данных доступны по запросу.</p></div>" \
      "  </div>" \
      "  <h2>Контакты</h2>" \
      "  <table><tr><th>Почта</th><td>info@$DOMAIN</td></tr><tr><th>Поддержка</th><td>help@$DOMAIN</td></tr></table>" \
      "</div>"
    page_foot
  } > "$WEBROOT/about/index.html"

  # путь Xray в robots.txt намеренно не упоминается
  printf 'User-agent: *\nAllow: /\nDisallow: /admin/\nSitemap: https://%s/sitemap.xml\n' "$DOMAIN" > "$WEBROOT/robots.txt"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    printf '  <url><loc>https://%s/</loc><priority>1.0</priority></url>\n' "$DOMAIN"
    printf '  <url><loc>https://%s/%s/</loc><priority>0.8</priority></url>\n' "$DOMAIN" "$NAV2_SLUG"
    printf '  <url><loc>https://%s/about/</loc><priority>0.5</priority></url>\n' "$DOMAIN"
    printf '%s\n' '</urlset>'
  } > "$WEBROOT/sitemap.xml"

  chown -R root:root "$WEBROOT" 2>/dev/null; chmod -R a+rX "$WEBROOT" 2>/dev/null
  ok "сайт «$SITE_NAME» ($SITE_THEME) собран: главная, /$NAV2_SLUG/, /about/, robots, sitemap"
fi

# =============================================================================
step "9/11  nginx"
# =============================================================================
if [ "$DO_NGINX" != "1" ]; then
  warn "пропущено: домен не задан"
else
  [ -f "$INSTALL_DIR/nginx.conf" ] && { cp -a "$INSTALL_DIR/nginx.conf" "$INSTALL_DIR/nginx.conf.bak.$STAMP"; ok "бэкап nginx.conf"; }
  # фрагмент для conf.d: nginx слушает не :443, а unix-сокет с proxy_protocol —
  # :443 держит сам Xray и отдаёт сюда всё, что не его трафик (self-steal)
  cat > "$INSTALL_DIR/nginx.conf" <<NGINX
server_names_hash_bucket_size 64;

access_log off;
server_tokens off;

real_ip_header proxy_protocol;
set_real_ip_from unix:;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

server {
    server_name $DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate         /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;

    root $WEBROOT;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;

    location $XHTTP_PATH {
        client_max_body_size 0;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_http_version 1.1;
        client_body_timeout 5m;
        proxy_read_timeout 315s;
        proxy_send_timeout 5m;
        proxy_pass http://unix:/dev/shm/xrxh.socket;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    ssl_reject_handshake on;
    return 444;
}
NGINX
  ok "nginx.conf записан (домен $DOMAIN, путь $XHTTP_PATH → /dev/shm/xrxh.socket)"
fi

# =============================================================================
step "10/11  Нода Remnawave"
# =============================================================================
cd "$INSTALL_DIR" || die "нет $INSTALL_DIR"

# если в compose уже есть посторонние сервисы — это боевая нода со своей
# обвязкой, её файл трогать нельзя
COMPOSE_MARK="# generated-by: node-setup"
OTHER_SVC=""
if [ -f docker-compose.yml ]; then
  # свой же файл (с нашим маркером) переписывать можно — там наш nginx,
  # а вот чужую обвязку трогать нельзя
  if ! grep -qF "$COMPOSE_MARK" docker-compose.yml; then
    OTHER_SVC="$(awk '/^services:/{f=1;next} f&&/^[A-Za-z]/{f=0} f&&/^  [A-Za-z0-9_.-]+:/{gsub(/[ :]/,"");print}' docker-compose.yml \
                 | grep -v '^remnanode$' | tr '\n' ' ' | sed 's/ *$//')"
  fi
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
$COMPOSE_MARK
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
      - /etc/letsencrypt:/etc/letsencrypt:ro
COMPOSE

  # nginx нужен только в связке с доменом: он отдаёт сайт-заглушку и
  # проксирует путь Xray с unix-сокета
  if [ "$DO_NGINX" = "1" ]; then
    cat >> docker-compose.yml <<COMPOSE

  remnawave-nginx:
    image: $NGINX_IMAGE
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    network_mode: host
    ulimits:
      nofile: { soft: 1048576, hard: 1048576 }
    logging:
      driver: json-file
      options: { max-size: 100m, max-file: "5" }
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - $WEBROOT:$WEBROOT:ro
      - /dev/shm:/dev/shm:rw
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
COMPOSE
    ok "docker-compose.yml записан (нода + nginx)"
  else
    ok "docker-compose.yml записан (только нода)"
  fi

  if docker compose pull -q >/dev/null 2>&1; then
    ok "образ $NODE_IMAGE скачан"
  else
    err "образ $NODE_IMAGE не скачался — проверь, что такой тег существует"
    say "      список версий: https://hub.docker.com/r/remnawave/node/tags"
  fi
  docker compose up -d >/dev/null 2>&1 && ok "контейнер поднят" || err "docker compose up упал"
fi

# =============================================================================
step "11/11  Проверка"
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
if [ -n "$LOGERR" ]; then
  warn "в логах ноды есть ошибки:"
  printf '%s\n' "$LOGERR" | cut -c1-150 | sed 's/^/      /'
fi

if [ "$DO_NGINX" = "1" ]; then
  NG_STATUS="$(docker ps --filter name=remnawave-nginx --format '{{.Status}}' 2>/dev/null)"
  if [ -n "$NG_STATUS" ]; then ok "remnawave-nginx: $NG_STATUS"
  else err "контейнер remnawave-nginx не запущен"; docker logs --tail 15 remnawave-nginx 2>&1 | sed 's/^/      /'; fi

  if docker exec remnawave-nginx nginx -t >/dev/null 2>&1; then
    ok "конфиг nginx валиден"
  else
    err "nginx -t не прошёл:"
    docker exec remnawave-nginx nginx -t 2>&1 | sed 's/^/      /'
  fi

  # сокет nginx появляется сразу, а сокет Xray — только когда панель отдаст
  # ноде конфиг с этим inbound
  [ -S /dev/shm/nginx.sock ] && ok "сокет /dev/shm/nginx.sock поднят" || err "сокета /dev/shm/nginx.sock нет"
  if [ -S /dev/shm/xrxh.socket ]; then
    ok "сокет Xray /dev/shm/xrxh.socket на месте"
  else
    warn "сокета /dev/shm/xrxh.socket ещё нет — появится, когда панель привяжет inbound к ноде"
  fi

  [ -f "$WEBROOT/index.html" ] && ok "сайт-заглушка на месте: $WEBROOT/index.html" || warn "сайта в $WEBROOT нет"

  CERT_TILL="$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2)"
  [ -n "$CERT_TILL" ] && ok "сертификат $DOMAIN годен до $CERT_TILL"
fi

# #############################################################################
part "ИТОГ"
# #############################################################################
say "  Хост        : $(hostname)"
say "  ОС          : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")"
say "  Docker      : $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
say "  Каталог     : $INSTALL_DIR"
say "  Образ ноды  : $NODE_IMAGE"
if [ "$DO_NGINX" = "1" ]; then
  say "  Домен       : $DOMAIN  (сертификат до ${CERT_TILL:-—})"
  say "  Сайт        : $WEBROOT — «${SITE_NAME:-—}», тема ${SITE_THEME:-—}"
  say "  nginx       : ${NG_STATUS:-не запущен}"
  say "  Путь Xray   : $XHTTP_PATH → unix:/dev/shm/xrxh.socket"
fi
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
