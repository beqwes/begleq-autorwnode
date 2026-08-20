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

VERSION="3.1"
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
# Reality-инбаунд отдаёт «украденный» сайт по адресу из dest. Панели пишут туда
# либо unix-сокет, либо 127.0.0.1:9443 — поэтому слушаем оба варианта сразу
FALLBACK_PORT="${FALLBACK_PORT:-9443}"
WEBROOT="${WEBROOT:-/var/www/html}"
DO_UPGRADE=1; DO_UFW=1; DO_F2B=1; DO_SWAP=1; DO_NGINX=1; DO_SITE=1; DO_MOTD=1; DO_TG=1
# TrafficGuard: списки сканеров и госсетей. Белый список важнее блок-листа —
# иначе панель или соседняя нода попадут под раздачу
TG_ALLOW="${TG_ALLOW:-}"; TG_FORCE=0
FORCE_KEY=0; STATUS_ONLY=0; NO_STATUS=0; ASSUME_YES=0; FORCE_SITE=0; MOTD_ONLY=0

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
  --fallback-port <p>  локальный порт для dest у Reality (по умолчанию 9443, 0 — выключить)
  --site-theme <t>     стиль заглушки: breakcore, lofi, dnb, synthwave, phonk,
                       ambient (по умолчанию случайный)
  --force-site         перезаписать уже существующий сайт в /var/www/html
  --no-nginx           не ставить nginx и не выпускать сертификат
  --no-site            не трогать сайт-заглушку
  --tg-allow <ips>     исключения TrafficGuard: IP панели, других нод, свои
                       (через запятую; IP панели и текущий SSH добавятся сами)
  --no-traffic-guard   не ставить TrafficGuard
  --tg-force           поставить, даже если на ноде уже есть свой traffic-guard
  --no-motd            не ставить отчёт о ноде при входе по SSH
  --motd-only          только поставить отчёт при входе и выйти
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
    --fallback-port) FALLBACK_PORT="${2:-9443}"; shift 2;;
    --site-theme)  SITE_THEME="${2:-}"; shift 2;;
    --force-site)  FORCE_SITE=1; shift;;
    --no-nginx)    DO_NGINX=0; shift;;
    --no-site)     DO_SITE=0; shift;;
    --tg-allow)    TG_ALLOW="${2:-}"; shift 2;;
    --no-traffic-guard) DO_TG=0; shift;;
    --tg-force)    TG_FORCE=1; shift;;
    --no-motd)     DO_MOTD=0; shift;;
    --motd-only)   MOTD_ONLY=1; shift;;
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

# сверяем то, что панель реально отдала ядру, с тем, что настроено на ноде:
# сайт-заглушку показывает Xray, а не nginx, поэтому SNI и dest должны сойтись
check_panel_inbound() {
  local args sock url cfg
  args="$(tr '\0' ' ' < /proc/"$(pgrep -f rw-core | head -1)"/cmdline 2>/dev/null)"
  sock="$(printf '%s' "$args" | grep -oE '@rwint-[A-Za-z0-9]+' | head -1 | sed 's/^@//')"
  url="$(printf '%s' "$args" | grep -oE '/internal/get-config\?token=[A-Za-z0-9]+' | head -1)"
  if [ -z "$sock" ] || [ -z "$url" ]; then
    warn "не смог прочитать живой конфиг Xray — проверь инбаунд в панели вручную"
    return 0
  fi
  cfg="$(curl -s --max-time 8 --abstract-unix-socket "$sock" "http://localhost$url" 2>/dev/null)"
  if [ -z "$cfg" ]; then
    warn "панель ещё не отдала ноде конфиг — привяжи ноду к инбаунду"
    return 0
  fi

  local names dests
  names="$(printf '%s' "$cfg" | grep -oE '"serverNames"[^]]*]' | grep -oE '"[a-z0-9.-]+\.[a-z]{2,}"' | tr -d '"' | sort -u | tr '\n' ' ')"
  dests="$(printf '%s' "$cfg" | grep -oE '"(dest|target)"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"[[:space:]]*:[[:space:]]*"//; s/"$//' | sort -u | tr '\n' ' ')"

  say "  инбаунд из панели: SNI [${names:-нет}] → dest [${dests:-нет}]"

  case " $names " in
    *" $DOMAIN "*) ok "домен $DOMAIN есть в serverNames инбаунда" ;;
    *)
      err "домена $DOMAIN нет в serverNames инбаунда — Reality рвёт чужой SNI, заглушка не покажется"
      say "      в панели: инбаунд этой ноды → serverNames должен содержать $DOMAIN"
      ;;
  esac

  local dest_ok=0
  case " $dests " in
    *"/dev/shm/nginx.sock"*) dest_ok=1; ok "dest указывает на наш сокет /dev/shm/nginx.sock" ;;
  esac
  if [ "$dest_ok" = 0 ] && [ "${FALLBACK_PORT:-0}" != "0" ]; then
    case " $dests " in
      *"127.0.0.1:$FALLBACK_PORT"*|*"localhost:$FALLBACK_PORT"*)
        dest_ok=1; ok "dest указывает на 127.0.0.1:$FALLBACK_PORT — этот порт мы слушаем" ;;
    esac
  fi
  if [ "$dest_ok" = 0 ]; then
    err "dest инбаунда ведёт не к заглушке (${dests:-пусто})"
    say "      варианты: поставить в панели dest = /dev/shm/nginx.sock с proxyProtocol,"
    say "      либо dest = 127.0.0.1:$FALLBACK_PORT, либо перезапустить скрипт с"
    say "      --fallback-port <порт из dest>"
  fi
}

# ставит баннер о состоянии ноды, который показывается при входе по SSH
install_motd() {
if [ "$DO_MOTD" != "1" ]; then
  warn "пропущено (--no-motd)"
elif [ ! -d /etc/update-motd.d ]; then
  warn "нет /etc/update-motd.d — баннер при входе не поставить"
else
  cat > /etc/update-motd.d/99-remnanode <<'MOTD'
#!/bin/sh
# Состояние ноды при входе по SSH. Поставлен node-setup.sh, убрать — просто удалить файл.
command -v docker >/dev/null 2>&1 || exit 0

G='\033[32m'; Y='\033[33m'; R='\033[31m'; C='\033[36m'; B='\033[1m'; N='\033[0m'
TAB="$(printf '\t')"

# чистим экран от вывода логина и печатаем шапку
clear 2>/dev/null || printf '\033[2J\033[H'
printf "%b" "${C}${B}"
cat <<'BANNER'
███  ████  ███ █    ████  ██       ███  ███   ██  ███
█  █ █    █    █    █    █  █      █  █ █  █ █  █ █  █
███  ███  █ ██ █    ███  █  █  ██  ███  ███  █  █ █  █
█  █ █    █  █ █    █    █ ██      █    █ █  █  █ █  █
███  ████  ███ ████ ████  ███      █    █  █  ██  ███
BANNER
printf "%b\n" "${N}"
printf "%b\n" "  ${B}$(hostname)${N}  ·  $(date '+%d.%m.%Y %H:%M')  ·  аптайм $(uptime -p 2>/dev/null | sed 's/^up //')"

printf "%b\n" "${B}${C}=== контейнеры ===${N}"
if [ -z "$(docker ps -aq 2>/dev/null)" ]; then
  printf "%b\n" "  ${Y}!!${N}  контейнеров нет"
else
  docker ps -a --format "{{.Names}}${TAB}{{.Status}}${TAB}{{.Image}}" 2>/dev/null |
  while IFS="$TAB" read -r name status image; do
    case "$status" in
      Up*restarting*|Restarting*) m="${R}xx${N}" ;;
      Up*unhealthy*)              m="${R}xx${N}" ;;
      Up*)                        m="${G}ok${N}" ;;
      *)                          m="${Y}!!${N}" ;;
    esac
    printf "%b\n" "  $m  $(printf '%-20s %-26s %s' "$name" "$image" "$status")"
  done
fi

PORT="$(grep -hE '^[[:space:]]*NODE_PORT=' /opt/remnanode/.env 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\"'\"'\''[:space:]')"
[ -z "$PORT" ] && PORT=2222
if ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -qx "$PORT"; then
  printf "%b\n" "  ${G}ok${N}  порт панели $PORT слушается"
else
  printf "%b\n" "  ${R}xx${N}  порт панели $PORT НЕ слушается"
fi
if ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -qx 443; then
  printf "%b\n" "  ${G}ok${N}  443 занят Xray"
else
  printf "%b\n" "  ${Y}!!${N}  на 443 никто не слушает"
fi
[ -S /dev/shm/nginx.sock ]  && printf "%b\n" "  ${G}ok${N}  сокет nginx поднят" \
                            || printf "%b\n" "  ${Y}!!${N}  сокета /dev/shm/nginx.sock нет"
[ -S /dev/shm/xrxh.socket ] && printf "%b\n" "  ${G}ok${N}  сокет Xray поднят"
if ipset list TG-BLOCK-V4 >/dev/null 2>&1; then
  if iptables -C INPUT -j TRAFFIC-GUARD 2>/dev/null; then
    printf "%b
" "  ${G}ok${N}  TrafficGuard: $(ipset list TG-BLOCK-V4 | grep -cE '^[0-9]') сетей в блоке, $(ipset list TG-ALLOW-V4 2>/dev/null | grep -cE '^[0-9]') в белом списке"
  else
    printf "%b
" "  ${R}xx${N}  TrafficGuard: цепочка не в INPUT (systemctl start tg-apply)"
  fi
fi

for c in remnawave-nginx; do
  st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
  [ -n "$st" ] && [ "$st" != "running" ] && {
    printf "%b\n" "${B}${R}--- $c упал, причина: ---${N}"
    docker logs --tail 40 "$c" 2>&1 | tr -d '\000' | grep -iE 'emerg|error' | tail -2 | cut -c1-160 | sed 's/^/  /'
  }
done

printf "\n%b\n" "${B}${C}=== логи ноды, последние 25 строк ===${N}"
docker logs --tail 25 remnanode 2>&1 | tr -d '\000' | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-150 | sed 's/^/  /'
printf "\n%b\n" "  подробный отчёт: ${B}bash /opt/remnanode/node-setup.sh --status-only${N}"
MOTD
  chmod +x /etc/update-motd.d/99-remnanode
  ok "баннер при входе поставлен: /etc/update-motd.d/99-remnanode"
fi
}

say "${CB}node-setup v$VERSION${C0} — $(hostname), $(date '+%d.%m.%Y %H:%M %Z')"

if [ "$MOTD_ONLY" = "1" ]; then
  install_motd
  say ""
  say "РЕЗУЛЬТАТ: ok"
  exit 0
fi

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

  # сверка с панелью: домен берём из уже лежащего nginx.conf, если не задан флагом
  if [ -z "${DOMAIN:-}" ] && [ -f "$INSTALL_DIR/nginx.conf" ]; then
    DOMAIN="$(grep -m1 -E '^[[:space:]]*server_name[[:space:]]+[A-Za-z0-9.-]+;' "$INSTALL_DIR/nginx.conf" \
              | sed -E 's/.*server_name[[:space:]]+//; s/;.*//')"
  fi
  if [ -n "${DOMAIN:-}" ]; then
    check_panel_inbound
  fi

  # TrafficGuard: пусто — не установлен, иначе показываем размеры списков
  if command -v ipset >/dev/null 2>&1 && ipset list TG-BLOCK-V4 >/dev/null 2>&1; then
    TGB="$(ipset list TG-BLOCK-V4 2>/dev/null | grep -cE '^[0-9]')"
    TGA="$(ipset list TG-ALLOW-V4 2>/dev/null | grep -cE '^[0-9]')"
    if iptables -C INPUT -j TRAFFIC-GUARD 2>/dev/null; then
      ok "TrafficGuard: блок $TGB сетей, в белом списке $TGA (цепочка в INPUT)"
    else
      err "TrafficGuard: списки есть ($TGB/$TGA), но цепочки в INPUT нет — systemctl start tg-apply"
    fi
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
      SITE_THEME="$(shuf -e breakcore lofi dnb synthwave phonk ambient -n 1 2>/dev/null || echo lofi)"
      ok "тема сайта-заглушки выбрана случайно: $SITE_THEME"
    fi
    case "$SITE_THEME" in
      breakcore|lofi|dnb|synthwave|phonk|ambient|random) : ;;
      *) die "неизвестная тема: $SITE_THEME (breakcore|lofi|dnb|synthwave|phonk|ambient|random)";;
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
step "1/13  Имя, часовой пояс, время"
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
step "2/13  Пакеты"
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
step "3/13  Swap"
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
step "4/13  Сетевые лимиты и BBR"
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
step "5/13  Docker"
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
step "6/13  Фаервол и fail2ban"
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
step "7/13  Сертификат Let's Encrypt"
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
step "8/13  Сайт-заглушка"
# =============================================================================
if [ "$DO_NGINX" != "1" ] || [ "$DO_SITE" != "1" ]; then
  warn "пропущено"
elif [ -f "$WEBROOT/index.html" ] && [ "$FORCE_SITE" != "1" ]; then
  # вытащим название из <title>, иначе в сводке будет пустой прочерк
  SITE_NAME="$(grep -m1 -oE '<title>[^<]*</title>' "$WEBROOT/index.html" 2>/dev/null                | sed -E 's|</?title>||g; s/.*— //')"
  [ -z "$SITE_NAME" ] && SITE_NAME="уже был"
  ok "сайт в $WEBROOT уже есть («$SITE_NAME») — не трогаю (--force-site чтобы перезаписать)"
else
  [ -d "$WEBROOT" ] && [ -n "$(ls -A "$WEBROOT" 2>/dev/null)" ] && {
    cp -a "$WEBROOT" "${WEBROOT}.bak.$STAMP"; ok "старый сайт → ${WEBROOT}.bak.$STAMP"; }

  # каждая нода получает свой музыкальный «лейбл»: стиль, палитра, шрифты и
  # треки берутся случайно, поэтому две ноды не выглядят одинаково
  # выбранный стиль уважаем, всё остальное считаем «на твой вкус»
  case "$SITE_THEME" in
    breakcore|lofi|dnb|synthwave|phonk|ambient) STYLE="$SITE_THEME" ;;
    *) STYLE="$(shuf -e breakcore lofi dnb synthwave phonk ambient -n 1 2>/dev/null || echo lofi)" ;;
  esac

  case "$STYLE" in
    breakcore)
      SITE_NAME="$(shuf -e NOISEFLOOR SPLICEGATE GRIDLOCK TAPEBURN NULLBEAT -n 1)"
      TAGLINE="breakcore selections"; GENRE="breakcore / jungle"
      ACC="#e5ff5a"; BG="#0a0a0b"; CARD="#121214"; FG="#e9e9ec"; MUT="#85858e"
      GFONT="Space+Grotesk:wght@400;500;700&family=Space+Mono:wght@400;700"
      FAM="'Space Grotesk', system-ui, sans-serif"; MONO="'Space Mono', ui-monospace, monospace"
      TRACKS="1 hour breakcore mix reupload
amen sister edit vip
static bloom 174
hyperloop cassette rip
razor tape side b
kick drum liturgy
tokyo overdrive dub
sunset in a washing machine
final boss amen roll
mono ghost pressing"
      ;;
    lofi)
      SITE_NAME="$(shuf -e SLOWROOM PAPERTAPE DUSTLINE NIGHTDESK KOTATSU -n 1)"
      TAGLINE="lo-fi tapes for late hours"; GENRE="lo-fi / chillhop"
      ACC="#d9a066"; BG="#11100e"; CARD="#191714"; FG="#ece7de"; MUT="#8e877c"
      GFONT="Inter:wght@400;500;700&family=JetBrains+Mono:wght@400;700"
      FAM="'Inter', system-ui, sans-serif"; MONO="'JetBrains Mono', ui-monospace, monospace"
      TRACKS="rain on the balcony
cassette warmth loop
4am study session
tea gone cold
window seat, slow train
paper lantern
old radio dust
quiet floor two
morning without alarm
last bus home"
      ;;
    dnb)
      SITE_NAME="$(shuf -e SUBFRAME ROLLERBOX DEEPWIRE STEPCTRL LOWEND -n 1)"
      TAGLINE="drum and bass archive"; GENRE="drum and bass / liquid"
      ACC="#43e0a0"; BG="#080d0c"; CARD="#101917"; FG="#e6f2ee"; MUT="#7d938c"
      GFONT="Barlow:wght@400;500;700&family=IBM+Plex+Mono:wght@400;700"
      FAM="'Barlow', system-ui, sans-serif"; MONO="'IBM Plex Mono', ui-monospace, monospace"
      TRACKS="liquid rollers vol.4
two step warehouse
deep bassline sketch
amen revisited 174
night drive rollout
reese in the fog
half time detour
copper wire dub
skyline pressure
final rollout mix"
      ;;
    synthwave)
      SITE_NAME="$(shuf -e NEONMILE VHS-DRIVE OUTRUNNER LASERGRID MIDNIGHT88 -n 1)"
      TAGLINE="synthwave and retro drive"; GENRE="synthwave / outrun"
      ACC="#ff5ea8"; BG="#0b0716"; CARD="#151029"; FG="#ece8ff"; MUT="#8d86ad"
      GFONT="Orbitron:wght@500;700&family=Space+Mono:wght@400;700"
      FAM="'Orbitron', system-ui, sans-serif"; MONO="'Space Mono', ui-monospace, monospace"
      TRACKS="neon mile cruise
vhs sunset tape
turbo lane 1986
chrome and rain
arcade after midnight
laser grid horizon
cassette deck romance
outrun the storm
palm street signal
credits roll"
      ;;
    phonk)
      SITE_NAME="$(shuf -e COWBELL9 DRIFTCULT MEMPHIS404 SLOWDRIFT BLACKTAPE -n 1)"
      TAGLINE="phonk and drift tapes"; GENRE="phonk / drift"
      ACC="#ff7a3d"; BG="#0d0a09"; CARD="#171210"; FG="#efe6e0"; MUT="#8f8078"
      GFONT="Chakra+Petch:wght@500;700&family=Share+Tech+Mono"
      FAM="'Chakra Petch', system-ui, sans-serif"; MONO="'Share Tech Mono', ui-monospace, monospace"
      TRACKS="drift corner cowbell
memphis tape loop
midnight touge run
slowed and reversed
smoke on the overpass
engine bay hymn
concrete drift club
tokyo night pass
tyre smoke ritual
last gear pull"
      ;;
    ambient)
      SITE_NAME="$(shuf -e FIELDROOM SLOWGLASS QUIETMASS PALEHOUR DRIFTWOOD -n 1)"
      TAGLINE="ambient and field recordings"; GENRE="ambient / drone"
      ACC="#7ab8ff"; BG="#080a0d"; CARD="#101418"; FG="#e4eaf1"; MUT="#7d8894"
      GFONT="Manrope:wght@400;500;700&family=Roboto+Mono:wght@400;700"
      FAM="'Manrope', system-ui, sans-serif"; MONO="'Roboto Mono', ui-monospace, monospace"
      TRACKS="glacier room tone
pale hour drift
harbour at four am
snow static field
long exposure pad
slow glass motion
distant turbine hum
empty pool reverb
winter window
tape hiss lullaby"
      ;;
  esac

  YEAR="$(date +%Y)"
  mkdir -p "$WEBROOT/assets" "$WEBROOT/archive" "$WEBROOT/about"

  # ---------- стили ----------
  cat > "$WEBROOT/assets/style.css" <<'CSS'
:root{--bg:__BG__;--card:__CARD__;--fg:__FG__;--mut:__MUT__;--acc:__ACC__;--line:#ffffff14}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-family:__FAM__;line-height:1.6;
  background-image:radial-gradient(60rem 30rem at 80% -10%, __ACC__14, transparent 60%)}
a{color:inherit;text-decoration:none}
.wrap{max-width:1080px;margin:0 auto;padding:0 22px}
header{position:sticky;top:0;z-index:9;background:__BG__e6;backdrop-filter:blur(8px);border-bottom:1px solid var(--line)}
header .wrap{display:flex;align-items:center;gap:20px;height:64px}
.logo{font-weight:700;letter-spacing:.14em;font-size:15px}
.live{font-family:__MONO__;font-size:11px;color:var(--acc);border:1px solid var(--acc);
  border-radius:999px;padding:3px 10px;letter-spacing:.12em}
.live i{display:inline-block;width:6px;height:6px;border-radius:50%;background:var(--acc);
  margin-right:6px;animation:pulse 1.6s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.25}}
nav{margin-left:auto;display:flex;gap:18px;font-size:13px;color:var(--mut);font-family:__MONO__}
nav a:hover{color:var(--acc)}
.hero{padding:64px 0 26px}
.hero h1{font-size:clamp(38px,7vw,74px);line-height:.98;margin:0 0 12px;letter-spacing:-.03em}
.hero p{color:var(--mut);margin:0;font-family:__MONO__;font-size:13px;letter-spacing:.1em;text-transform:uppercase}
.player{margin:26px 0 12px;border:1px solid var(--line);border-radius:16px;background:var(--card);overflow:hidden}
.player .top{display:flex;gap:18px;padding:18px;align-items:center}
.cover{width:96px;height:96px;border-radius:10px;flex:none;
  background:linear-gradient(135deg,__ACC__,#ffffff10);position:relative;overflow:hidden}
.cover span{position:absolute;inset:auto 8px 8px 8px;font-family:__MONO__;font-size:10px;color:#0009}
.np{flex:1;min-width:0}
.np small{font-family:__MONO__;font-size:11px;color:var(--mut);letter-spacing:.14em;text-transform:uppercase}
.np h3{margin:4px 0 10px;font-size:20px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bar{height:4px;border-radius:2px;background:#ffffff14;overflow:hidden}
.bar i{display:block;height:100%;width:12%;background:var(--acc)}
.time{display:flex;justify-content:space-between;font-family:__MONO__;font-size:11px;color:var(--mut);margin-top:6px}
.eq{display:flex;gap:3px;align-items:flex-end;height:28px}
.eq b{width:4px;background:var(--acc);border-radius:2px;animation:eq 1.1s infinite ease-in-out}
.eq b:nth-child(2){animation-delay:.15s}.eq b:nth-child(3){animation-delay:.3s}
.eq b:nth-child(4){animation-delay:.45s}.eq b:nth-child(5){animation-delay:.6s}
@keyframes eq{0%,100%{height:7px}50%{height:26px}}
table{width:100%;border-collapse:collapse;font-size:14px;margin:8px 0 44px}
th{font-family:__MONO__;font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--mut);
  text-align:left;font-weight:400;padding:10px 12px;border-bottom:1px solid var(--line)}
td{padding:12px;border-bottom:1px solid var(--line)}
tr[data-t]{cursor:pointer}
tr[data-t]:hover{background:#ffffff08}
tr[data-t]:hover td:nth-child(2){color:var(--acc)}
td.num,td.dur{font-family:__MONO__;color:var(--mut);font-size:12px;width:1%;white-space:nowrap}
h2{font-size:13px;font-family:__MONO__;letter-spacing:.16em;text-transform:uppercase;color:var(--mut);
  margin:40px 0 12px;font-weight:400}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:16px;padding-bottom:40px}
.rel{border:1px solid var(--line);border-radius:12px;overflow:hidden;background:var(--card)}
.rel .art{aspect-ratio:1;background:linear-gradient(135deg,#ffffff12,__ACC__30)}
.rel .meta{padding:12px}
.rel .meta b{display:block;font-size:14px;font-weight:500}
.rel .meta span{font-family:__MONO__;font-size:11px;color:var(--mut)}
footer{border-top:1px solid var(--line);padding:26px 0 40px;color:var(--mut);
  font-family:__MONO__;font-size:11.5px;letter-spacing:.06em}
footer .wrap{display:flex;gap:20px;flex-wrap:wrap}
p.lead{color:var(--mut);max-width:60ch}
@media(max-width:600px){nav{display:none}.player .top{flex-wrap:wrap}}
CSS

  # ---------- скрипт ----------
  cat > "$WEBROOT/assets/app.js" <<'JS'
(function () {
  var bar = document.querySelector('.bar i');
  var cur = document.querySelector('[data-cur]');
  var tot = document.querySelector('[data-tot]');
  var np  = document.querySelector('[data-np]');
  var pos = 12, len = 214;

  function fmt(s) {
    var m = Math.floor(s / 60), r = Math.floor(s % 60);
    return m + ':' + (r < 10 ? '0' : '') + r;
  }
  if (tot) tot.textContent = fmt(len);
  setInterval(function () {
    pos = (pos + 0.35) % 100;
    if (bar) bar.style.width = pos.toFixed(1) + '%';
    if (cur) cur.textContent = fmt(len * pos / 100);
  }, 300);

  document.querySelectorAll('tr[data-t]').forEach(function (row) {
    row.addEventListener('click', function () {
      if (np) np.textContent = row.getAttribute('data-t');
      pos = 0;
    });
  });

  try {
    var k = 'listens_' + new Date().toISOString().slice(0, 10);
    var n = parseInt(localStorage.getItem(k) || '0', 10) + 1;
    localStorage.setItem(k, String(n));
    var el = document.querySelector('[data-listens]');
    if (el) el.textContent = String(n);
  } catch (e) {}
})();
JS

  sed -i "s|__BG__|$BG|g; s|__CARD__|$CARD|g; s|__FG__|$FG|g; s|__MUT__|$MUT|g; s|__ACC__|$ACC|g" "$WEBROOT/assets/style.css"
  sed -i "s|__FAM__|$FAM|g; s|__MONO__|$MONO|g" "$WEBROOT/assets/style.css"

  cat > "$WEBROOT/favicon.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="12" fill="$BG"/><rect x="14" y="30" width="6" height="18" rx="3" fill="$ACC"/><rect x="26" y="18" width="6" height="30" rx="3" fill="$ACC"/><rect x="38" y="26" width="6" height="22" rx="3" fill="$ACC"/></svg>
SVG

  # ---------- общие куски страниц ----------
  head_html() {
    cat <<HTML
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$1 — $SITE_NAME</title>
<meta name="description" content="$SITE_NAME — $TAGLINE">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=$GFONT&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/assets/style.css">
</head><body>
<header><div class="wrap">
  <a class="logo" href="/">$SITE_NAME</a>
  <span class="live"><i></i>STREAM ONLINE</span>
  <nav><a href="/">radio</a><a href="/archive/">archive</a><a href="/about/">about</a></nav>
</div></header>
HTML
  }
  foot_html() {
    cat <<HTML
<footer><div class="wrap">
  <span>$SITE_NAME · $GENRE</span>
  <span>listens today: <b data-listens>1</b></span>
  <span>since $((YEAR-4))</span>
</div></footer>
<script src="/assets/app.js"></script>
</body></html>
HTML
  }

  # ---------- главная ----------
  FIRST="$(printf '%s\n' "$TRACKS" | head -1)"
  {
    head_html "$TAGLINE"
    cat <<HTML
<section class="hero"><div class="wrap">
  <h1>$SITE_NAME</h1>
  <p>$TAGLINE — 24/7</p>
  <div class="player">
    <div class="top">
      <div class="cover"><span>$GENRE</span></div>
      <div class="np">
        <small>now playing</small>
        <h3 data-np>$FIRST</h3>
        <div class="bar"><i></i></div>
        <div class="time"><span data-cur>0:24</span><span data-tot>3:34</span></div>
      </div>
      <div class="eq" aria-hidden="true"><b></b><b></b><b></b><b></b><b></b></div>
    </div>
  </div>
</div></section>
<div class="wrap">
  <h2>tracklist</h2>
  <table>
    <tr><th>#</th><th>title</th><th>plays</th><th>length</th></tr>
HTML
    n=0
    printf '%s\n' "$TRACKS" | while IFS= read -r t; do
      [ -z "$t" ] && continue
      n=$((n+1))
      mm=$(( (RANDOM % 5) + 2 )); ss=$(( RANDOM % 60 ))
      plays=$(( (RANDOM % 90) + 10 ))
      printf '    <tr data-t="%s"><td class="num">%02d</td><td>%s</td><td class="dur">%s.%dk</td><td class="dur">%d:%02d</td></tr>\n' \
        "$t" "$n" "$t" "$plays" "$((RANDOM % 9))" "$mm" "$ss"
    done
    cat <<HTML
  </table>
  <h2>latest releases</h2>
  <div class="grid">
HTML
    for i in 1 2 3 4; do
      printf '    <div class="rel"><div class="art"></div><div class="meta"><b>%s vol.%d</b><span>%s · %d tracks</span></div></div>\n' \
        "$SITE_NAME" "$i" "$((YEAR - i + 1))" "$(( (RANDOM % 8) + 5 ))"
    done
    cat <<HTML
  </div>
</div>
HTML
    foot_html
  } > "$WEBROOT/index.html"

  # ---------- архив ----------
  {
    head_html "archive"
    cat <<HTML
<div class="wrap">
  <h2>archive</h2>
  <p class="lead">Everything that aired on the stream, oldest sessions first. Rips are mirrored twice a week.</p>
  <table>
    <tr><th>#</th><th>session</th><th>date</th><th>length</th></tr>
HTML
    n=0
    printf '%s\n' "$TRACKS" | while IFS= read -r t; do
      [ -z "$t" ] && continue
      n=$((n+1))
      printf '    <tr><td class="num">%02d</td><td>%s</td><td class="dur">%02d.%02d.%s</td><td class="dur">%d:%02d</td></tr>\n' \
        "$n" "$t" "$(( (RANDOM % 28) + 1 ))" "$(( (RANDOM % 12) + 1 ))" "$YEAR" "$(( (RANDOM % 5) + 2 ))" "$(( RANDOM % 60 ))"
    done
    cat <<HTML
  </table>
</div>
HTML
    foot_html
  } > "$WEBROOT/archive/index.html"

  # ---------- about ----------
  {
    head_html "about"
    cat <<HTML
<div class="wrap">
  <h2>about</h2>
  <p class="lead">$SITE_NAME is a small independent stream focused on $GENRE. No ads, no accounts,
  no algorithm — just a running playlist and an archive of past sessions.</p>
  <p class="lead">Submissions are open. Send a link to your mix, we listen to everything and reply
  when it fits the rotation.</p>
  <h2>contact</h2>
  <table>
    <tr><td>demos</td><td class="dur">demo@$DOMAIN</td></tr>
    <tr><td>general</td><td class="dur">hi@$DOMAIN</td></tr>
  </table>
</div>
HTML
    foot_html
  } > "$WEBROOT/about/index.html"

  printf 'User-agent: *\nAllow: /\nDisallow: /admin/\nSitemap: https://%s/sitemap.xml\n' "$DOMAIN" > "$WEBROOT/robots.txt"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    for u in "/" "/archive/" "/about/"; do
      printf '  <url><loc>https://%s%s</loc></url>\n' "$DOMAIN" "$u"
    done
    printf '%s\n' '</urlset>'
  } > "$WEBROOT/sitemap.xml"

  chown -R root:root "$WEBROOT" 2>/dev/null; chmod -R a+rX "$WEBROOT" 2>/dev/null
  SITE_THEME="$STYLE"
  ok "сайт «$SITE_NAME» ($STYLE) собран: радио, /archive/, /about/, robots, sitemap"
fi

# =============================================================================
step "9/13  nginx"
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

  # порт 80: без него сайт-заглушка выглядит неживой — настоящий сайт на :80
  # отвечает редиректом, а не обрывом связи. Заодно отдаём ACME-челлендж,
  # чтобы сертификат продлевался без остановки nginx
  BUSY80="$(ss -tlnpH 2>/dev/null | awk '$4 ~ /:80$/ {print $0}' | grep -v nginx | head -1)"
  if [ -n "$BUSY80" ]; then
    warn "порт 80 занят другим процессом — блок редиректа не добавляю"
  else
    mkdir -p /var/www/certbot
    cat >> "$INSTALL_DIR/nginx.conf" <<NGINX

server {
    listen 0.0.0.0:80 default_server;
    server_name $DOMAIN _;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINX
    ok "на :80 повешен редирект в https и путь для продления сертификата"
  fi

  # второй вход для панелей, где у Reality dest = 127.0.0.1:<порт>, а не сокет.
  # Наружу порт не открывается — только петля, снаружи его не видно
  if [ "${FALLBACK_PORT:-0}" != "0" ]; then
    cat >> "$INSTALL_DIR/nginx.conf" <<NGINX

server {
    server_name $DOMAIN;
    listen 127.0.0.1:$FALLBACK_PORT ssl;
    http2 on;

    ssl_certificate         /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;

    root $WEBROOT;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;

    location $XHTTP_PATH {
        client_max_body_size 0;
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
    listen 127.0.0.1:$FALLBACK_PORT ssl default_server;
    server_name _;
    ssl_reject_handshake on;
    return 444;
}
NGINX
    ok "заглушка также слушает 127.0.0.1:$FALLBACK_PORT (для dest вида 127.0.0.1:$FALLBACK_PORT)"
  fi
  ok "nginx.conf записан (домен $DOMAIN, путь $XHTTP_PATH → /dev/shm/xrxh.socket)"
  if ! [ -f "$CERT_DIR/fullchain.pem" ]; then
    warn "сертификата ещё нет — nginx будет падать по кругу, пока он не появится"
  fi
fi

# =============================================================================
step "10/13  Нода Remnawave"
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
      - /var/www/certbot:/var/www/certbot:ro
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

  # nginx мог крутиться в цикле падений, пока сертификата ещё не было: docker
  # наращивает паузу между попытками, и сам он поднимется нескоро. Раз сертификат
  # уже на месте — перезапускаем принудительно и ждём, пока встанет
  if [ "$DO_NGINX" = "1" ] && [ -f "$CERT_DIR/fullchain.pem" ]; then
    NG_STATE="$(docker inspect -f '{{.State.Status}}' remnawave-nginx 2>/dev/null)"
    if [ "$NG_STATE" != "running" ]; then
      docker restart remnawave-nginx >/dev/null 2>&1
      i=0
      while [ "$i" -lt 15 ]; do
        NG_STATE="$(docker inspect -f '{{.State.Status}}' remnawave-nginx 2>/dev/null)"
        [ "$NG_STATE" = "running" ] && break
        sleep 2; i=$((i+1))
      done
      [ "$NG_STATE" = "running" ] && ok "nginx перезапущен после появления сертификата" \
        || warn "nginx всё ещё не поднялся (состояние: ${NG_STATE:-нет})"
    fi
  fi
fi

# =============================================================================
step "11/13  Проверка"
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

  # в контейнер, который перезапускается, через exec не зайти — тогда nginx -t
  # молча выдаёт пустоту, а настоящая причина лежит в логах контейнера
  NG_STATE="$(docker inspect -f '{{.State.Status}}' remnawave-nginx 2>/dev/null)"
  if [ "$NG_STATE" != "running" ]; then
    err "nginx не работает (состояние: ${NG_STATE:-нет контейнера}), из логов:"
    docker logs --tail 40 remnawave-nginx 2>&1 | tr -d '\000' | grep -iE 'emerg|error' \
      | tail -2 | cut -c1-200 | sed 's/^/      /'
    if ! [ -f "$CERT_DIR/fullchain.pem" ]; then
      say "      сертификата ${CERT_DIR}/fullchain.pem нет — сначала выпусти его,"
      say "      затем перезапусти: cd $INSTALL_DIR && docker compose up -d"
    fi
  elif docker exec remnawave-nginx nginx -t >/dev/null 2>&1; then
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

  # раз nginx занял :80, продлевать standalone-способом уже нельзя — переводим
  # renew на webroot, теперь сертификат обновляется без остановки контейнера
  RCONF="/etc/letsencrypt/renewal/$DOMAIN.conf"
  if [ -f "$CERT_DIR/fullchain.pem" ] && [ -d /var/www/certbot ] && [ "$NG_STATE" = "running" ] && [ -f "$RCONF" ]; then
    # certbot с --keep-until-expiring просто ничего не делает и способ продления
    # не меняет, поэтому переключаем authenticator прямо в конфиге продления
    if grep -q '^authenticator = standalone' "$RCONF"; then
      cp -a "$RCONF" "$RCONF.bak.$STAMP"
      sed -i 's|^authenticator = standalone|authenticator = webroot|' "$RCONF"
      grep -q '^webroot_path' "$RCONF" || sed -i '/^authenticator = webroot/a webroot_path = /var/www/certbot,' "$RCONF"
      grep -q '^\[\[webroot_map\]\]' "$RCONF" || printf '
[[webroot_map]]
%s = /var/www/certbot
' "$DOMAIN" >> "$RCONF"
      if certbot renew --dry-run --cert-name "$DOMAIN" >/dev/null 2>&1; then
        ok "продление переведено на webroot и проверено сухим прогоном"
      else
        err "после перевода на webroot сухой прогон продления не прошёл"
        say "      проверь вручную: certbot renew --dry-run --cert-name $DOMAIN"
      fi
    else
      ok "продление уже настроено без standalone"
    fi
  fi

  CERT_TILL="$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2)"
  [ -n "$CERT_TILL" ] && ok "сертификат $DOMAIN годен до $CERT_TILL"

  # заглушку отдаёт не nginx напрямую, а Xray по правилам инбаунда из панели.
  # Сверяем их: чаще всего сайт «не появляется» именно из-за настроек панели
  check_panel_inbound
fi

# =============================================================================
step "12/13  TrafficGuard"
# =============================================================================
if [ "$DO_TG" != "1" ]; then
  warn "пропущено (--no-traffic-guard)"
elif [ -x /usr/local/bin/traffic-guard ] && [ "$TG_FORCE" != "1" ]; then
  warn "на ноде уже стоит свой traffic-guard — не трогаю (--tg-force поставит наш рядом)"
else
  apt-get install -y -qq ipset >/dev/null 2>&1
  if ! command -v ipset >/dev/null 2>&1; then
    err "ipset не установился — TrafficGuard не поставить"
  else
    mkdir -p /etc/traffic-guard/lists /var/lib/traffic-guard

    # --- белый список: панель, текущий SSH-клиент и всё, что дали флагом ---
    TG_ALLOW_FILE=/etc/traffic-guard/allow.list
    if [ ! -f "$TG_ALLOW_FILE" ]; then
      cat > "$TG_ALLOW_FILE" <<'ALLOWHDR'
# Исключения TrafficGuard: эти адреса никогда не блокируются.
# Сюда IP панели и других нод. По одному на строку, можно CIDR.
# Менять удобнее командой:  tg-allow add 1.2.3.4 "панель"
ALLOWHDR
    fi
    SSH_PEER="$(echo "${SSH_CLIENT:-}" | awk '{print $1}')"
    for a in $PANEL_IP $SSH_PEER $(printf '%s' "$TG_ALLOW" | tr ',;' '  '); do
      [ -z "$a" ] && continue
      grep -qxF "$a" "$TG_ALLOW_FILE" 2>/dev/null || echo "$a" >> "$TG_ALLOW_FILE"
    done
    ok "в белом списке: $(grep -cvE '^\s*(#|$)' "$TG_ALLOW_FILE") адресов"

    # --- обновление списков и применение правил ---
    cat > /usr/local/bin/tg-refresh <<'TGREFRESH'
#!/bin/sh
# TrafficGuard: качает блок-листы, собирает ipset и вешает цепочку в INPUT.
# Белый список всегда имеет приоритет над блок-листом.
#   tg-refresh              полное обновление
#   tg-refresh --allow-only только перечитать белый список
#   tg-refresh --hook-only  только пересобрать цепочку и вернуть её в INPUT
set -u
DIR=/etc/traffic-guard
LISTS=$DIR/lists
ALLOW=$DIR/allow.list
SAVE=/var/lib/traffic-guard/ipset.save
SRC="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/main/public/antiscanner.list
https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/main/public/government_networks.list"
MODE="${1:-full}"

mkdir -p "$LISTS" /var/lib/traffic-guard
[ -f "$ALLOW" ] || : > "$ALLOW"

fill() {   # fill ИМЯ_СЕТА СЕМЕЙСТВО ФАЙЛЫ...
  set_name="$1"; fam="$2"; shift 2
  ipset create "$set_name" hash:net family "$fam" -exist
  ipset create "${set_name}-tmp" hash:net family "$fam" -exist
  ipset flush "${set_name}-tmp"
  n=0
  if [ "$fam" = inet ]; then
    pat='^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'
  else
    pat='^[0-9a-fA-F:]+(/[0-9]{1,3})?$'
  fi
  for f in "$@"; do
    [ -f "$f" ] || continue
    sed 's/#.*//' "$f" | tr -d ' \t\r' | grep -E "$pat" | while IFS= read -r net; do
      ipset add "${set_name}-tmp" "$net" -exist 2>/dev/null
    done
  done
  n="$(ipset list "${set_name}-tmp" | grep -cE "$pat")"
  ipset swap "${set_name}-tmp" "$set_name"
  ipset destroy "${set_name}-tmp"
  echo "$n"
}

if [ "$MODE" = "full" ]; then
  for u in $SRC; do
    f="$LISTS/$(basename "$u")"
    if curl -fsSL --max-time 90 "$u" -o "$f.new" && [ -s "$f.new" ]; then
      mv "$f.new" "$f"
    else
      rm -f "$f.new"
      echo "tg-refresh: не смог скачать $u, оставляю прежний список" >&2
    fi
  done
fi

if [ "$MODE" != "hook-only" ]; then
  A4="$(fill TG-ALLOW-V4 inet "$ALLOW")"
  A6="$(fill TG-ALLOW-V6 inet6 "$ALLOW")"
  B4="$(fill TG-BLOCK-V4 inet "$LISTS"/*.list)"
  B6="$(fill TG-BLOCK-V6 inet6 "$LISTS"/*.list)"
  echo "tg-refresh: блок v4=$B4 v6=$B6, разрешено v4=$A4 v6=$A6"
else
  for s in TG-ALLOW-V4 TG-BLOCK-V4; do ipset create "$s" hash:net family inet -exist; done
  for s in TG-ALLOW-V6 TG-BLOCK-V6; do ipset create "$s" hash:net family inet6 -exist; done
fi

# цепочка: сначала пропускаем своих (RETURN — трафик идёт дальше по правилам
# ufw, а не проскакивает мимо них), только потом рубим сканеры
iptables -N TRAFFIC-GUARD 2>/dev/null
iptables -F TRAFFIC-GUARD
iptables -A TRAFFIC-GUARD -m set --match-set TG-ALLOW-V4 src -j RETURN
iptables -A TRAFFIC-GUARD -m set --match-set TG-BLOCK-V4 src -j DROP
while iptables -D INPUT -j TRAFFIC-GUARD 2>/dev/null; do :; done
iptables -I INPUT 1 -j TRAFFIC-GUARD

if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -N TRAFFIC-GUARD 2>/dev/null
  ip6tables -F TRAFFIC-GUARD
  ip6tables -A TRAFFIC-GUARD -m set --match-set TG-ALLOW-V6 src -j RETURN
  ip6tables -A TRAFFIC-GUARD -m set --match-set TG-BLOCK-V6 src -j DROP
  while ip6tables -D INPUT -j TRAFFIC-GUARD 2>/dev/null; do :; done
  ip6tables -I INPUT 1 -j TRAFFIC-GUARD
fi

ipset save > "$SAVE" 2>/dev/null
exit 0
TGREFRESH
    chmod +x /usr/local/bin/tg-refresh

    # --- управление исключениями ---
    cat > /usr/local/bin/tg-allow <<'TGALLOW'
#!/bin/sh
# Исключения TrafficGuard.
#   tg-allow add 1.2.3.4 [комментарий]   добавить
#   tg-allow del 1.2.3.4                 убрать
#   tg-allow list                        показать
#   tg-allow test 1.2.3.4                проверить, блокируется ли адрес
set -u
F=/etc/traffic-guard/allow.list
[ -f "$F" ] || : > "$F"
case "${1:-list}" in
  add)
    [ -n "${2:-}" ] || { echo "нужен адрес: tg-allow add 1.2.3.4 [комментарий]"; exit 1; }
    if grep -qxF "$2" "$F"; then
      echo "$2 уже в списке"
    else
      [ -n "${3:-}" ] && echo "# $3" >> "$F"
      echo "$2" >> "$F"
      echo "добавлен $2"
    fi
    /usr/local/bin/tg-refresh --allow-only
    ;;
  del)
    [ -n "${2:-}" ] || { echo "нужен адрес"; exit 1; }
    grep -vxF "$2" "$F" > "$F.tmp" && mv "$F.tmp" "$F"
    echo "убран $2"
    /usr/local/bin/tg-refresh --allow-only
    ;;
  test)
    [ -n "${2:-}" ] || { echo "нужен адрес"; exit 1; }
    if ipset test TG-ALLOW-V4 "$2" 2>/dev/null; then
      echo "$2: в белом списке, не блокируется"
    elif ipset test TG-BLOCK-V4 "$2" 2>/dev/null; then
      echo "$2: БЛОКИРУЕТСЯ (добавь: tg-allow add $2)"
    else
      echo "$2: не в списках, проходит обычные правила"
    fi
    ;;
  *)
    echo "белый список ($F):"
    grep -vE '^\s*$' "$F" | sed 's/^/  /'
    echo
    echo "в ipset: $(ipset list TG-ALLOW-V4 2>/dev/null | grep -cE '^[0-9]') адресов"
    echo "в блок-листе: $(ipset list TG-BLOCK-V4 2>/dev/null | grep -cE '^[0-9]') сетей"
    ;;
esac
TGALLOW
    chmod +x /usr/local/bin/tg-allow

    # --- systemd: восстановление после перезагрузки и ежедневное обновление ---
    cat > /etc/systemd/system/tg-apply.service <<'UNIT'
[Unit]
Description=TrafficGuard: восстановить ipset и вернуть цепочку в INPUT
After=network.target ufw.service docker.service
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '[ -f /var/lib/traffic-guard/ipset.save ] && ipset restore -exist < /var/lib/traffic-guard/ipset.save || true'
ExecStart=/usr/local/bin/tg-refresh --hook-only

[Install]
WantedBy=multi-user.target
UNIT

    cat > /etc/systemd/system/tg-refresh.service <<'UNIT'
[Unit]
Description=TrafficGuard: обновление блок-листов
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tg-refresh
UNIT

    cat > /etc/systemd/system/tg-refresh.timer <<'UNIT'
[Unit]
Description=TrafficGuard: ежедневное обновление блок-листов

[Timer]
OnCalendar=daily
RandomizedDelaySec=3h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now tg-apply.service >/dev/null 2>&1
    systemctl enable --now tg-refresh.timer >/dev/null 2>&1

    TG_OUT="$(/usr/local/bin/tg-refresh 2>&1 | tail -1)"
    ok "${TG_OUT:-правила применены}"

    # --- контроль: свои адреса не должны блокироваться ---
    TG_BAD=""
    for a in $PANEL_IP $SSH_PEER; do
      [ -z "$a" ] && continue
      if ipset test TG-ALLOW-V4 "$a" >/dev/null 2>&1; then
        ok "$a в белом списке"
      else
        TG_BAD="$TG_BAD $a"
      fi
    done
    [ -n "$TG_BAD" ] && err "не попали в белый список:$TG_BAD — добавь через tg-allow add"
    ok "исключения: tg-allow add <ip> | tg-allow list | tg-allow test <ip>"
  fi
fi

# =============================================================================
step "13/13  Отчёт при входе"
# =============================================================================
install_motd

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
