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

VERSION="4.4"
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
DO_UPGRADE=1; DO_UFW=1; DO_F2B=1; DO_SWAP=1; DO_NGINX=1; DO_SITE=1; DO_MOTD=1; DO_TG=1; DO_WARP=1; DO_BBR=1
# TrafficGuard: списки сканеров и госсетей. Белый список важнее блок-листа —
# иначе панель или соседняя нода попадут под раздачу
TG_ALLOW="${TG_ALLOW:-}"; TG_FORCE=0; WARP_FORCE=0
FORCE_KEY=0; STATUS_ONLY=0; NO_STATUS=0; ASSUME_YES=0; FORCE_SITE=0; MOTD_ONLY=0; WARP_ONLY=0; WARP_OFF=0; WARP_PURGE=0; BBR_ONLY=0; MENU=0

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
  --no-warp            не ставить WARP
  --warp-force         переставить WARP, даже если интерфейс уже есть
  --warp-only          только поставить WARP и выйти
  --warp-off           выключить WARP (профиль остаётся) и выйти
  --warp-purge         снести WARP полностью и выйти
  --menu               открыть меню настроек (то же, что команда begleq)
  --bbr-only           только включить BBR и сетевые лимиты, затем выйти
  --no-bbr             не трогать sysctl и BBR
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
    --no-warp)     DO_WARP=0; shift;;
    --warp-force)  WARP_FORCE=1; shift;;
    --warp-only)   WARP_ONLY=1; shift;;
    --warp-off)    WARP_OFF=1; shift;;
    --warp-purge)  WARP_PURGE=1; shift;;
    --menu)        MENU=1; shift;;
    --bbr-only)    BBR_ONLY=1; shift;;
    --no-bbr)      DO_BBR=0; shift;;
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

# меню настроек. Открывается командой begleq из любого места
menu_main() {
  [ -n "$TTY_IN" ] || die "меню нужен терминал — запусти из консоли сервера"
  SELF="$INSTALL_DIR/node-setup.sh"
  [ -f "$SELF" ] || SELF="$0"
  while :; do
    clear 2>/dev/null || printf '\033[2J\033[H'
    printf '%b\n' "${CB}${CC}begleq${C0} · $(hostname) · $(date '+%d.%m.%Y %H:%M')"
    say ""
    # короткая сводка, чтобы было видно, что вообще происходит
    NODE_ST="$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null)"
    NGX_ST="$(docker inspect -f '{{.State.Status}}' remnawave-nginx 2>/dev/null)"
    CC_ST="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    ip link show warp >/dev/null 2>&1 && W_ST="поднят" || W_ST="выключен"
    ipset list TG-BLOCK-V4 >/dev/null 2>&1 && TG_ST="$(ipset list TG-BLOCK-V4 2>/dev/null | grep -cE '^[0-9]') сетей" || TG_ST="не стоит"
    printf '  нода: %-12s nginx: %-12s BBR: %-6s WARP: %-9s TrafficGuard: %s\n' \
      "${NODE_ST:-нет}" "${NGX_ST:-нет}" "${CC_ST:-?}" "$W_ST" "$TG_ST"
    say ""
    say "  1) состояние ноды подробно"
    say "  2) настроить или обновить ноду"
    say "  3) WARP: включить"
    say "  4) WARP: выключить"
    say "  5) WARP: снести полностью"
    say "  6) BBR и сетевые лимиты: включить"
    say "  7) TrafficGuard: исключения"
    say "  8) заглушка: пересобрать"
    say "  9) показать outbound для панели"
    say " 10) обновить сам скрипт с гитхаба"
    say "  0) выход"
    say ""
    printf '%b' "${CC}?${C0} выбор: "
    IFS= read -r choice < "$TTY_IN" || break
    say ""
    case "$choice" in
      1)  bash "$SELF" --status-only ;;
      2)  bash "$SELF" ;;
      3)  bash "$SELF" --warp-only ;;
      4)  bash "$SELF" --warp-off ;;
      5)  printf '%b' "${CY}снести WARP полностью? [y/N]: ${C0}"
          IFS= read -r yn < "$TTY_IN"
          case "$yn" in [yYдД]*) bash "$SELF" --warp-purge ;; *) warn "отменено" ;; esac ;;
      6)  bash "$SELF" --bbr-only ;;
      7)  if command -v tg-allow >/dev/null 2>&1; then
            tg-allow list
            say ""
            printf '%b' "${CC}?${C0} добавить IP в белый список (Enter — пропустить): "
            IFS= read -r ip < "$TTY_IN"
            [ -n "$ip" ] && tg-allow add "$ip"
          else
            warn "TrafficGuard не установлен — поставится при пункте 2"
          fi ;;
      8)  D="$(grep -m1 -E '^[[:space:]]*server_name[[:space:]]+[A-Za-z0-9.-]+;' "$INSTALL_DIR/nginx.conf" 2>/dev/null \
               | sed -E 's/.*server_name[[:space:]]+//; s/;.*//')"
          if [ -z "$D" ]; then
            warn "домен не найден — сначала настрой ноду (пункт 2)"
          else
            say "  доступные стили:"
            printf '%s\n' "$ALL_PRESETS_HINT" | fold -s -w 76 | sed 's/^/    /'
            printf '%b' "${CC}?${C0} стиль (Enter — случайный): "
            IFS= read -r st < "$TTY_IN"
            bash "$SELF" --no-status --no-upgrade --no-swap --no-traffic-guard --no-motd --no-warp \
                 --domain "$D" --force-site ${st:+--site-theme "$st"} --yes
          fi ;;
      9)  if [ -f "$INSTALL_DIR/warp-outbound.json" ]; then
            say "  вставь это в outbounds конфига ноды в панели:"
            sed 's/^/    /' "$INSTALL_DIR/warp-outbound.json"
          else
            warn "файла нет — сначала подними WARP (пункт 3)"
          fi ;;
      10) if curl -fsSL --max-time 60 https://raw.githubusercontent.com/beqwes/begleq-autorwnode/main/node-setup.sh -o "$SELF.new"; then
            if bash -n "$SELF.new" 2>/dev/null; then
              mv "$SELF.new" "$SELF"; ok "скрипт обновлён"
            else
              rm -f "$SELF.new"; err "скачанный скрипт не прошёл проверку синтаксиса"
            fi
          else
            err "не смог скачать с гитхаба"
          fi ;;
      0|q|"") say "пока"; return 0 ;;
      *)  warn "нет такого пункта" ;;
    esac
    say ""
    printf '%b' "${CC}Enter${C0} — назад в меню "
    IFS= read -r _ < "$TTY_IN"
  done
}

# ставит команду begleq, чтобы меню открывалось откуда угодно
install_cli() {
  RAW_URL="https://raw.githubusercontent.com/beqwes/begleq-autorwnode/main/node-setup.sh"
  mkdir -p "$INSTALL_DIR"

  # при запуске через curl | bash в $0 лежит пайп, копировать нечего —
  # тогда тянем свежую копию с гитхаба, иначе команда останется битой
  SELF_PATH="$(readlink -f "$0" 2>/dev/null)"
  DEST_PATH="$(readlink -f "$INSTALL_DIR/node-setup.sh" 2>/dev/null)"
  if [ -f "$0" ] && [ -r "$0" ] && [ "$SELF_PATH" != "$DEST_PATH" ]; then
    cp -f "$0" "$INSTALL_DIR/node-setup.sh" 2>/dev/null
  fi
  if [ ! -s "$INSTALL_DIR/node-setup.sh" ]; then
    if curl -fsSL --max-time 60 "$RAW_URL" -o "$INSTALL_DIR/node-setup.sh" 2>/dev/null; then
      ok "скрипт скачан в $INSTALL_DIR/node-setup.sh"
    else
      warn "не смог положить скрипт в $INSTALL_DIR — begleq скачает его при первом запуске"
    fi
  fi

  # обёртка чинит себя сама: нет файла — качает и продолжает
  cat > /usr/local/bin/begleq <<CLI
#!/bin/sh
# Меню настройки ноды. Поставлено node-setup.sh
S="$INSTALL_DIR/node-setup.sh"
if [ ! -s "\$S" ]; then
  echo "скрипт не найден, качаю с гитхаба…"
  mkdir -p "$INSTALL_DIR"
  curl -fsSL --max-time 60 "$RAW_URL" -o "\$S" || { echo "не смог скачать \$S"; exit 1; }
fi
exec bash "\$S" --menu "\$@"
CLI
  chmod +x /usr/local/bin/begleq
  ok "команда begleq поставлена — открывает меню настроек"
}

# BBR + fq и сетевые лимиты. Вынесено отдельно, чтобы можно было
# применить одним флагом на уже настроенной ноде
enable_bbr() {
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
}

# выключает WARP, профиль остаётся — включить обратно можно --warp-only
disable_warp() {
  if ! ip link show warp >/dev/null 2>&1 && [ ! -f /etc/wireguard/warp.conf ]; then
    warn "WARP на ноде и не стоял"
    return 0
  fi
  systemctl disable --now wg-quick@warp >/dev/null 2>&1
  ip link delete warp >/dev/null 2>&1
  if ip link show warp >/dev/null 2>&1; then
    err "интерфейс warp всё ещё поднят"
  else
    ok "WARP выключен, автозапуск снят (профиль на месте)"
    say "      включить обратно: bash $0 --warp-only"
    say "      не забудь убрать outbound warp из конфига ноды в панели,"
    say "      иначе Xray будет слать трафик в несуществующий интерфейс"
  fi
}

# сносит WARP полностью: юнит, профиль, аккаунт wgcf
purge_warp() {
  systemctl disable --now wg-quick@warp >/dev/null 2>&1
  ip link delete warp >/dev/null 2>&1
  rm -f /etc/wireguard/warp.conf /etc/wireguard/warp.conf.disabled
  rm -f /etc/wireguard/wgcf-account.toml /etc/wireguard/wgcf-profile.conf
  rm -f /usr/local/bin/wgcf "$INSTALL_DIR/warp-outbound.json"
  ok "WARP снесён полностью: интерфейс, профиль, аккаунт wgcf и файл outbound"
  say "      убери outbound warp из конфига ноды в панели"
}


# ставит WARP отдельным интерфейсом: маршрут по умолчанию не трогаем,
# Xray сам привязывает к нему нужные соединения через sockopt.interface
install_warp() {
WARP_OUT="$INSTALL_DIR/warp-outbound.json"
if [ "$DO_WARP" != "1" ]; then
  warn "пропущено (--no-warp)"
elif ip link show warp >/dev/null 2>&1 && [ "$WARP_FORCE" != "1" ]; then
  ok "интерфейс warp уже поднят — не трогаю (--warp-force чтобы переставить)"
else
  apt-get install -y -qq wireguard-tools >/dev/null 2>&1
  if ! command -v wg-quick >/dev/null 2>&1; then
    err "wireguard-tools не поставились — WARP не поднять"
  else
    # wgcf регистрирует бесплатный аккаунт WARP и отдаёт готовый профиль
    if ! command -v wgcf >/dev/null 2>&1; then
      case "$(uname -m)" in
        x86_64|amd64) WARCH=amd64 ;;
        aarch64|arm64) WARCH=arm64 ;;
        *) WARCH=amd64 ;;
      esac
      WURL="$(curl -fsSL --max-time 30 https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null \
              | grep -oE '"browser_download_url": *"[^"]*linux_'"$WARCH"'"' | cut -d'"' -f4 | head -1)"
      if [ -n "$WURL" ] && curl -fsSL --max-time 60 "$WURL" -o /usr/local/bin/wgcf; then
        chmod +x /usr/local/bin/wgcf
        ok "wgcf $(basename "$WURL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) установлен"
      else
        err "не смог скачать wgcf с github"
      fi
    fi

    if command -v wgcf >/dev/null 2>&1; then
      mkdir -p /etc/wireguard
      cd /etc/wireguard || die "нет /etc/wireguard"
      [ -f wgcf-account.toml ] || wgcf register --accept-tos >/dev/null 2>&1
      if [ ! -f wgcf-account.toml ]; then
        err "wgcf не зарегистрировал аккаунт WARP"
      else
        wgcf generate --profile /etc/wireguard/warp.conf >/dev/null 2>&1
        if [ ! -s /etc/wireguard/warp.conf ]; then
          err "wgcf не сгенерировал профиль"
        else
          # Table = off принципиально: иначе wg-quick уводит в WARP весь трафик
          # ноды, включая связь с панелью. Нам нужен только сам интерфейс,
          # Xray сам привяжет к нему нужные соединения
          # строку DNS= убираем: wg-quick требует под неё resolvconf, которого
          # в Debian нет, а системный резолвер нам менять и незачем
          sed -i '/^DNS *=/d' /etc/wireguard/warp.conf
          grep -q '^Table' /etc/wireguard/warp.conf || \
            sed -i '/^\[Interface\]/a Table = off' /etc/wireguard/warp.conf
          grep -q '^MTU' /etc/wireguard/warp.conf || \
            sed -i '/^\[Interface\]/a MTU = 1280' /etc/wireguard/warp.conf
          chmod 600 /etc/wireguard/warp.conf

          systemctl enable wg-quick@warp >/dev/null 2>&1
          if ! systemctl restart wg-quick@warp >/dev/null 2>&1; then
            # на нодах без IPv6 профиль с v6-адресом не поднимается — срезаем
            sed -i 's/, *[0-9a-fA-F:]*:[0-9a-fA-F:]*\/128//; s/, *::\/0//' /etc/wireguard/warp.conf
            systemctl restart wg-quick@warp >/dev/null 2>&1 && warn "WARP поднят без IPv6"
          fi

          if ip link show warp >/dev/null 2>&1; then
            ok "интерфейс warp поднят"
            WTRACE="$(curl -s --interface warp --max-time 15 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)"
            WSTATE="$(printf '%s' "$WTRACE" | grep -E '^warp=' | cut -d= -f2)"
            WIP="$(printf '%s' "$WTRACE" | grep -E '^ip=' | cut -d= -f2)"
            case "$WSTATE" in
              on|plus) ok "трафик через WARP работает: warp=$WSTATE, внешний IP $WIP" ;;
              *) err "интерфейс есть, но трафик через него не идёт (warp=${WSTATE:-нет ответа})" ;;
            esac
            # проверяем, что маршрут по умолчанию остался прежним
            DEFDEV="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
            if [ "$DEFDEV" = "warp" ]; then
              err "маршрут по умолчанию ушёл в warp — панель потеряет ноду, чиню"
              sed -i '/^Table/d' /etc/wireguard/warp.conf
              sed -i '/^\[Interface\]/a Table = off' /etc/wireguard/warp.conf
              systemctl restart wg-quick@warp >/dev/null 2>&1
            else
              ok "маршрут по умолчанию не тронут (идёт через $DEFDEV)"
            fi
          else
            err "интерфейс warp не поднялся: $(systemctl status wg-quick@warp --no-pager 2>&1 | tail -2 | tr '\n' ' ')"
          fi
        fi
      fi
    fi
  fi
fi

# готовый кусок для панели — его человек вставляет в outbounds сам
cat > "$WARP_OUT" <<'WJSON'
{
  "tag": "warp",
  "protocol": "freedom",
  "settings": {
    "domainStrategy": "UseIP"
  },
  "streamSettings": {
    "sockopt": {
      "interface": "warp",
      "tcpFastOpen": true
    }
  }
}
WJSON
if ip link show warp >/dev/null 2>&1; then
  say ""
  say "  ${CB}Вставь в панели в outbounds конфига этой ноды:${C0}"
  sed 's/^/    /' "$WARP_OUT"
  say ""
  say "  и правило маршрутизации, что гнать через WARP, например:"
  say '    { "type": "field", "domain": ["geosite:openai"], "outboundTag": "warp" }'
  say ""
  say "  файл лежит здесь: $WARP_OUT"
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
██████    ████████    ██████  ██        ████████    ████              ██████    ██████      ████    ██████
██████    ████████    ██████  ██        ████████    ████              ██████    ██████      ████    ██████
██    ██  ██        ██        ██        ██        ██    ██            ██    ██  ██    ██  ██    ██  ██    ██
██    ██  ██        ██        ██        ██        ██    ██            ██    ██  ██    ██  ██    ██  ██    ██
██████    ██████    ██  ████  ██        ██████    ██    ██    ████    ██████    ██████    ██    ██  ██    ██
██████    ██████    ██  ████  ██        ██████    ██    ██    ████    ██████    ██████    ██    ██  ██    ██
██    ██  ██        ██    ██  ██        ██        ██  ████            ██        ██  ██    ██    ██  ██    ██
██    ██  ██        ██    ██  ██        ██        ██  ████            ██        ██  ██    ██    ██  ██    ██
██████    ████████    ██████  ████████  ████████    ██████            ██        ██    ██    ████    ██████
██████    ████████    ██████  ████████  ████████    ██████            ██        ██    ██    ████    ██████
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
printf "\n%b\n" "  настройки: ${B}begleq${N}   ·   подробный отчёт: ${B}begleq${N} → 1"
MOTD
  chmod +x /etc/update-motd.d/99-remnanode

  # штатный MOTD слишком болтливый: юридический текст Debian, реклама ESM,
  # справка про справку. Права снимаем, а не удаляем — вернуть можно chmod +x
  if [ -s /etc/motd ]; then
    mv /etc/motd /etc/motd.disabled-by-node-setup
    ok "текст /etc/motd убран (лежит рядом с пометкой .disabled-by-node-setup)"
  fi
  for f in 10-help-text 50-motd-news 91-contract-ua-esm-status 91-release-upgrade 50-landscape-sysinfo; do
    [ -x "/etc/update-motd.d/$f" ] && chmod -x "/etc/update-motd.d/$f"
  done
  ok "лишние блоки приветствия отключены"
  ok "баннер при входе поставлен: /etc/update-motd.d/99-remnanode"
  install_cli
fi
}

ALL_PRESETS_HINT="noisefloor subframe neonmile driftcult fieldroom dustline kissaten roastline reelpaper pixelpress sweaterweather monogrid tapehouse kanso studioquiet nexora riotgrain hexline filmgrain sunbleach makimahouse arcadechar phonkchar synthchar cinechar ghibliroom animecine kyotocine ambientcine gamecine"

# в меню эта строка ни к чему — оно всё равно очищает экран
[ "$MENU" = "1" ] || say "${CB}node-setup v$VERSION${C0} — $(hostname), $(date '+%d.%m.%Y %H:%M %Z')"

if [ "$MENU" = "1" ]; then
  menu_main
  exit 0
fi

if [ "$WARP_OFF" = "1" ] || [ "$WARP_PURGE" = "1" ]; then
  [ "$WARP_PURGE" = "1" ] && purge_warp || disable_warp
  say ""
  say "РЕЗУЛЬТАТ: ok"
  exit 0
fi

if [ "$BBR_ONLY" = "1" ]; then
  enable_bbr
  say ""
  say "РЕЗУЛЬТАТ: ok"
  exit 0
fi

if [ "$WARP_ONLY" = "1" ]; then
  install_warp
  say ""
  if [ -n "$FAILED" ]; then
    bad "проблемы:$FAILED"
    say "РЕЗУЛЬТАТ: с ошибками"
    exit 1
  fi
  say "РЕЗУЛЬТАТ: ok"
  exit 0
fi

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

  CC_NOW="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  QD_NOW="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  if [ "$CC_NOW" = "bbr" ]; then ok "BBR включён (qdisc: ${QD_NOW:-?})"
  else warn "BBR выключен (сейчас ${CC_NOW:-?}) — включить: bash $0 --bbr-only"; fi

  if ip link show warp >/dev/null 2>&1; then
    WSTATE_NOW="$(curl -s --interface warp --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^warp=' | cut -d= -f2)"
    if [ -n "$WSTATE_NOW" ]; then ok "WARP поднят и отвечает (warp=$WSTATE_NOW)"
    else err "интерфейс warp есть, но трафик через него не идёт"; fi
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

  # мало знать срок — важно, продлится ли он сам
  if [ -d /etc/letsencrypt/renewal ]; then
    R_TIMER="$(systemctl is-active certbot.timer 2>/dev/null)"
    R_AUTH="$(grep -hm1 "^authenticator" /etc/letsencrypt/renewal/*.conf 2>/dev/null | sed "s/.*= *//")"
    if [ "$R_TIMER" = "active" ] || [ -f /etc/cron.d/certbot ]; then
      ok "автопродление: способ ${R_AUTH:-?}, таймер ${R_TIMER:-cron пакета}"
    else
      err "автопродление не настроено — сертификат протухнет (способ ${R_AUTH:-?})"
    fi
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
step "1/14  Имя, часовой пояс, время"
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
step "2/14  Пакеты"
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
step "3/14  Swap"
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
step "4/14  Сетевые лимиты и BBR"
# =============================================================================
if [ "$DO_BBR" != "1" ]; then
  warn "пропущено (--no-bbr)"
else
  enable_bbr
fi

# =============================================================================
step "5/14  Docker"
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
step "6/14  Фаервол и fail2ban"
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
step "7/14  Сертификат Let's Encrypt"
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

  # автопродление обычно включает сам пакет certbot, но на части систем таймер
  # приходит выключенным — тогда сертификат тихо протухнет через три месяца
  if systemctl list-unit-files --no-pager 2>/dev/null | grep -q "^certbot.timer"; then
    systemctl enable --now certbot.timer >/dev/null 2>&1
    CB_NEXT="$(systemctl list-timers certbot.timer --no-pager 2>/dev/null | awk 'NR==2{print $1" "$2" "$3}')"
    ok "автопродление включено (certbot.timer), ближайшая проверка: ${CB_NEXT:-по расписанию}"
  elif [ -f /etc/cron.d/certbot ]; then
    ok "автопродление через cron пакета certbot"
  else
    err "автопродления нет: ни certbot.timer, ни /etc/cron.d/certbot"
    say "      сертификат протухнет через 90 дней — переустанови пакет certbot"
  fi
fi

# =============================================================================
step "8/14  Сайт-заглушка"
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

  # пресет: раскладка + тема контента + палитра. Если не задан — случайный
  ALL_PRESETS="noisefloor subframe neonmile driftcult fieldroom dustline kissaten roastline reelpaper pixelpress sweaterweather monogrid tapehouse kanso studioquiet nexora riotgrain hexline filmgrain sunbleach makimahouse arcadechar phonkchar synthchar cinechar ghibliroom animecine kyotocine ambientcine gamecine"
  case " $ALL_PRESETS " in
    *" $SITE_THEME "*) PRESET="$SITE_THEME" ;;
    *) PRESET="$(shuf -e $ALL_PRESETS -n 1 2>/dev/null || echo noisefloor)" ;;
  esac

  case "$PRESET" in
    noisefloor)
      LAYOUT=hero; TOPIC=breakcore
      NAMES="NOISEFLOOR SPLICEGATE GRIDLOCK TAPEBURN NULLBEAT"
      HEADLINE="ON AIR<br>AROUND THE CLOCK"; TAGLINE="breakcore selections"; LABEL="breakcore / jungle"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#000000"; PANEL="#0b0b0c"; CARD="#131315"; FG="#f4f4f5"; MUT="#8b8b93"
      ACC="#e5ff5a"; ACC2="#ff3d7f"; LINE="#ffffff14"; BLEND="screen"
      OVER="linear-gradient(180deg,#000000cc 0%,#00000055 34%,#000000f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#f4f4f5"; BTNFG="#000000"
      ;;
    subframe)
      LAYOUT=hero; TOPIC=dnb
      NAMES="SUBFRAME ROLLERBOX DEEPWIRE STEPCTRL LOWEND"
      HEADLINE="ROLLING<br>WITHOUT A BREAK"; TAGLINE="drum and bass archive"; LABEL="drum and bass / liquid"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#03121a"; PANEL="#061d27"; CARD="#0a2632"; FG="#e9f6fb"; MUT="#7ea6b4"
      ACC="#43e0a0"; ACC2="#2f7dff"; LINE="#ffffff17"; BLEND="screen"
      OVER="linear-gradient(180deg,#03121acc 0%,#03121a55 34%,#03121af2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#e9f6fb"; BTNFG="#03121a"
      ;;
    neonmile)
      LAYOUT=hero; TOPIC=synthwave
      NAMES="NEONMILE VHSDRIVE OUTRUNNER LASERGRID MIDNIGHT88"
      HEADLINE="NIGHT DRIVE<br>NEVER ENDS"; TAGLINE="synthwave and retro drive"; LABEL="synthwave / outrun"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#0a0520"; PANEL="#150c33"; CARD="#1d1142"; FG="#f0ecff"; MUT="#9a90c4"
      ACC="#ff5ea8"; ACC2="#4de2ff"; LINE="#ffffff1a"; BLEND="screen"
      OVER="linear-gradient(180deg,#0a0520cc 0%,#0a052055 34%,#0a0520f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#f0ecff"; BTNFG="#0a0520"
      ;;
    driftcult)
      LAYOUT=hero; TOPIC=phonk
      NAMES="DRIFTCULT COWBELL9 MEMPHIS404 SLOWDRIFT BLACKTAPE"
      HEADLINE="TAPES FOR<br>THE NIGHT SHIFT"; TAGLINE="phonk and drift tapes"; LABEL="phonk / drift"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#130a05"; PANEL="#1c1009"; CARD="#25160e"; FG="#f6ece4"; MUT="#a58a78"
      ACC="#ff7a3d"; ACC2="#b14cff"; LINE="#ffffff17"; BLEND="screen"
      OVER="linear-gradient(180deg,#130a05cc 0%,#130a0555 34%,#130a05f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#f6ece4"; BTNFG="#130a05"
      ;;
    fieldroom)
      LAYOUT=hero; TOPIC=ambient
      NAMES="FIELDROOM SLOWGLASS QUIETMASS PALEHOUR DRIFTWOOD"
      HEADLINE="SLOW AIR,<br>LONG FORM"; TAGLINE="ambient and field recordings"; LABEL="ambient / drone"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#e8eef2"; PANEL="#dce5eb"; CARD="#f3f7f9"; FG="#101a21"; MUT="#5e7180"
      ACC="#2f7fae"; ACC2="#7aa7c7"; LINE="#0f1a2114"; BLEND="normal"
      OVER="linear-gradient(180deg,#e8eef2d9 0%,#e8eef255 38%,#e8eef2fa 100%)"; CHIP="#ffffffbb"; CHIPB="#10202c1f"; BTNBG="#101a21"; BTNFG="#e8eef2"
      ;;
    dustline)
      LAYOUT=editorial; TOPIC=lofi
      NAMES="DUSTLINE PAPERTAPE SLOWROOM NIGHTDESK KOTATSU"
      HEADLINE=""; TAGLINE="lo-fi tapes for late hours"; LABEL="lo-fi / chillhop"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#efece3"; PANEL="#e5e1d5"; CARD="#f6f4ee"; FG="#1b1a17"; MUT="#6f6a5d"
      ACC="#4f8f96"; ACC2="#c07a4b"; LINE="#1b1a1722"; BLEND="normal"
      OVER="linear-gradient(180deg,#efece3cc 0%,#efece355 34%,#efece3f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#1b1a17"; BTNFG="#efece3"
      ;;
    kissaten)
      LAYOUT=editorial; TOPIC=japan
      NAMES="KISSATEN HANAMI YOKOCHO SHIORI TSUKIMI"
      HEADLINE=""; TAGLINE="walks and quiet streets"; LABEL="japan / field notes"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#f6ecec"; PANEL="#eddede"; CARD="#fbf4f4"; FG="#241a1a"; MUT="#7d6262"
      ACC="#c25b5b"; ACC2="#5b7dc2"; LINE="#241a1a1f"; BLEND="normal"
      OVER="linear-gradient(180deg,#f6ececcc 0%,#f6ecec55 34%,#f6ececf2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#241a1a"; BTNFG="#f6ecec"
      ;;
    roastline)
      LAYOUT=editorial; TOPIC=coffee
      NAMES="ROASTLINE SLOWPOUR CREMA BEANHAUS DRIPHOUSE"
      HEADLINE=""; TAGLINE="notes on brewing"; LABEL="coffee / slow bar"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#f2ede4"; PANEL="#e7e0d2"; CARD="#faf7f1"; FG="#20180f"; MUT="#7a6a56"
      ACC="#b4462f"; ACC2="#3f6f5f"; LINE="#20180f1f"; BLEND="normal"
      OVER="linear-gradient(180deg,#f2ede4cc 0%,#f2ede455 34%,#f2ede4f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#20180f"; BTNFG="#f2ede4"
      ;;
    reelpaper)
      LAYOUT=editorial; TOPIC=cinema
      NAMES="REELPAPER FRAMESET LUMIERE SILVERSCREEN CINEROOM"
      HEADLINE=""; TAGLINE="a paper about films"; LABEL="cinema / archive"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#e9f1ec"; PANEL="#dbe8e0"; CARD="#f4faf6"; FG="#141d18"; MUT="#5f7268"
      ACC="#2f8f63"; ACC2="#8f6f2f"; LINE="#141d181f"; BLEND="normal"
      OVER="linear-gradient(180deg,#e9f1eccc 0%,#e9f1ec55 34%,#e9f1ecf2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#141d18"; BTNFG="#e9f1ec"
      ;;
    pixelpress)
      LAYOUT=editorial; TOPIC=gaming
      NAMES="PIXELPRESS SAVEPOINT LOOTROOM CARTRIDGE OVERWORLD"
      HEADLINE=""; TAGLINE="soundtracks and long sessions"; LABEL="games / soundtracks"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#eaeff5"; PANEL="#dbe4ee"; CARD="#f5f8fc"; FG="#121821"; MUT="#5f6c7d"
      ACC="#3f6fbf"; ACC2="#bf7f3f"; LINE="#1218211f"; BLEND="normal"
      OVER="linear-gradient(180deg,#eaeff5cc 0%,#eaeff555 34%,#eaeff5f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#121821"; BTNFG="#eaeff5"
      ;;
    sweaterweather)
      LAYOUT=split; TOPIC=coffee
      NAMES="SWEATERWEATHER SLOWBAR NORTHROAST PAPERCUP EMBER"
      HEADLINE="Talking about coffee, what's your opinion?"; TAGLINE="Is it a social lubricant or a dangerous stimulant?"; LABEL="coffee bar"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#faf8f5"; PANEL="#141210"; CARD="#f5f2ee"; FG="#141210"; MUT="#8b8378"
      ACC="#141210"; ACC2="#6b6257"; LINE="#1412101a"; BLEND="normal"
      OVER="linear-gradient(180deg,#faf8f5cc 0%,#faf8f555 34%,#faf8f5f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#141210"; BTNFG="#faf8f5"
      ;;
    monogrid)
      LAYOUT=split; TOPIC=tech
      NAMES="MONOGRID BASELINE STUDIOZERO FORMLAB NORTHFORM"
      HEADLINE="We build quiet things that keep working."; TAGLINE="Studio notes, process and shipped work"; LABEL="design studio"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#ffffff"; PANEL="#111111"; CARD="#fafafa"; FG="#111111"; MUT="#8a8a8a"
      ACC="#111111"; ACC2="#555555"; LINE="#1111111a"; BLEND="normal"
      OVER="linear-gradient(180deg,#ffffffcc 0%,#ffffff55 34%,#fffffff2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#111111"; BTNFG="#ffffff"
      ;;
    tapehouse)
      LAYOUT=split; TOPIC=lofi
      NAMES="TAPEHOUSE SLOWDESK CASSETTA PAPERLOOP HUSHROOM"
      HEADLINE="Tapes for the hours nobody schedules."; TAGLINE="Long selections, no ads, no accounts"; LABEL="tape room"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#f7f9fa"; PANEL="#0e1114"; CARD="#f2f5f7"; FG="#0e1114"; MUT="#7d858c"
      ACC="#0e1114"; ACC2="#5b636a"; LINE="#0e11141a"; BLEND="normal"
      OVER="linear-gradient(180deg,#f7f9facc 0%,#f7f9fa55 34%,#f7f9faf2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#0e1114"; BTNFG="#f7f9fa"
      ;;
    kanso)
      LAYOUT=split; TOPIC=japan
      NAMES="KANSO SHIBUI MAROOM ENGAWA SUMIDA"
      HEADLINE="Empty streets, early light, long walks."; TAGLINE="Recordings from cities that stay quiet"; LABEL="field notes"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#faf8f5"; PANEL="#141210"; CARD="#f5f2ee"; FG="#141210"; MUT="#8b8378"
      ACC="#141210"; ACC2="#6b6257"; LINE="#1412101a"; BLEND="normal"
      OVER="linear-gradient(180deg,#faf8f5cc 0%,#faf8f555 34%,#faf8f5f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#141210"; BTNFG="#faf8f5"
      ;;
    studioquiet)
      LAYOUT=split; TOPIC=ambient
      NAMES="STUDIOQUIET LONGROOM PALEDESK STILLBOX SLOWWAVE"
      HEADLINE="Sound that fills a room without asking."; TAGLINE="Ambient sessions and field recordings"; LABEL="listening room"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#f7f9fa"; PANEL="#0e1114"; CARD="#f2f5f7"; FG="#0e1114"; MUT="#7d858c"
      ACC="#0e1114"; ACC2="#5b636a"; LINE="#0e11141a"; BLEND="normal"
      OVER="linear-gradient(180deg,#f7f9facc 0%,#f7f9fa55 34%,#f7f9faf2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#0e1114"; BTNFG="#f7f9fa"
      ;;
    nexora)
      LAYOUT=halftone; TOPIC=tech
      NAMES="NEXORA VANTIX ORBITAL NORTHPEAK LUMENARC"
      HEADLINE="Bold Ideas That Start With Vision."; TAGLINE="We help modern brands craft digital stories that inspire action."; LABEL="studio"
      TRUST="Trusted by teams of every scale"; PREV="Previous"; NEXT="Next"
      BG="#ffffff"; PANEL="#111111"; CARD="#fafafa"; FG="#111111"; MUT="#8a8a8a"
      ACC="#111111"; ACC2="#555555"; LINE="#1111111a"; BLEND="normal"
      OVER="linear-gradient(180deg,#ffffffcc 0%,#ffffff55 34%,#fffffff2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#111111"; BTNFG="#ffffff"
      ;;
    riotgrain)
      LAYOUT=halftone; TOPIC=breakcore
      NAMES="RIOTGRAIN HARDEDGE SPLITSEC RAWFEED CRUSHER"
      HEADLINE="Loud Ideas That Refuse To Sit Still."; TAGLINE="Long sets, sharp edits and nothing safe"; LABEL="label"
      TRUST="Played by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#f7f9fa"; PANEL="#0e1114"; CARD="#f2f5f7"; FG="#0e1114"; MUT="#7d858c"
      ACC="#0e1114"; ACC2="#5b636a"; LINE="#0e11141a"; BLEND="normal"
      OVER="linear-gradient(180deg,#f7f9facc 0%,#f7f9fa55 34%,#f7f9faf2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#0e1114"; BTNFG="#f7f9fa"
      ;;
    hexline)
      LAYOUT=halftone; TOPIC=gaming
      NAMES="HEXLINE SAVESTATE PIXELWORKS ARCADIA BITHOUSE"
      HEADLINE="Soundtracks That Carry The Whole Run."; TAGLINE="Full scores from games that stayed with people"; LABEL="archive"
      TRUST="Trusted by players of every kind"; PREV="Previous"; NEXT="Next"
      BG="#faf8f5"; PANEL="#141210"; CARD="#f5f2ee"; FG="#141210"; MUT="#8b8378"
      ACC="#141210"; ACC2="#6b6257"; LINE="#1412101a"; BLEND="normal"
      OVER="linear-gradient(180deg,#faf8f5cc 0%,#faf8f555 34%,#faf8f5f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#141210"; BTNFG="#faf8f5"
      ;;
    filmgrain)
      LAYOUT=halftone; TOPIC=cinema
      NAMES="FILMGRAIN REELWORKS SILVERHALIDE CUTROOM PROJECTOR"
      HEADLINE="Every Frame Deserves A Second Look."; TAGLINE="Trailers, scores and the rooms that made them"; LABEL="cinema"
      TRUST="Screened in every kind of room"; PREV="Previous"; NEXT="Next"
      BG="#ffffff"; PANEL="#111111"; CARD="#fafafa"; FG="#111111"; MUT="#8a8a8a"
      ACC="#111111"; ACC2="#555555"; LINE="#1111111a"; BLEND="normal"
      OVER="linear-gradient(180deg,#ffffffcc 0%,#ffffff55 34%,#fffffff2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#111111"; BTNFG="#ffffff"
      ;;
    sunbleach)
      LAYOUT=halftone; TOPIC=japan
      NAMES="SUNBLEACH ASAHIROOM KOMOREBI SHIOKAZE HIROBA"
      HEADLINE="Cities Recorded At Walking Speed."; TAGLINE="Long walks, quiet streets, nothing staged"; LABEL="field"
      TRUST="Followed by walkers of every pace"; PREV="Previous"; NEXT="Next"
      BG="#faf8f5"; PANEL="#141210"; CARD="#f5f2ee"; FG="#141210"; MUT="#8b8378"
      ACC="#141210"; ACC2="#6b6257"; LINE="#1412101a"; BLEND="normal"
      OVER="linear-gradient(180deg,#faf8f5cc 0%,#faf8f555 34%,#faf8f5f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#141210"; BTNFG="#faf8f5"
      ;;
    makimahouse)
      LAYOUT=character; TOPIC=anime
      NAMES="MAKIMAHOUSE DEVILHUNT REDCOLLAR NOCTURNE SAKURAFIST"
      HEADLINE="Openings, endings and everything between."; TAGLINE="anime openings in 4k"; LABEL="character / anime"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#f6ecec"; PANEL="#eddede"; CARD="#fbf4f4"; FG="#241a1a"; MUT="#7d6262"
      ACC="#c25b5b"; ACC2="#5b7dc2"; LINE="#241a1a1f"; BLEND="normal"
      OVER="linear-gradient(180deg,#f6ececcc 0%,#f6ecec55 34%,#f6ececf2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#241a1a"; BTNFG="#f6ecec"
      ;;
    arcadechar)
      LAYOUT=character; TOPIC=gaming
      NAMES="ARCADECHAR PLAYERTWO CONTINUE9 SAVEROOM BOSSRUSH"
      HEADLINE="Every run has a soundtrack."; TAGLINE="full soundtracks from long nights"; LABEL="games / scores"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#e9f1ec"; PANEL="#dbe8e0"; CARD="#f4faf6"; FG="#141d18"; MUT="#5f7268"
      ACC="#2f8f63"; ACC2="#8f6f2f"; LINE="#141d181f"; BLEND="normal"
      OVER="linear-gradient(180deg,#e9f1eccc 0%,#e9f1ec55 34%,#e9f1ecf2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#141d18"; BTNFG="#e9f1ec"
      ;;
    phonkchar)
      LAYOUT=character; TOPIC=phonk
      NAMES="PHONKCHAR DRIFTKING COWBELLCLUB SMOKEROOM NIGHTPASS"
      HEADLINE="Cowbell, smoke and the whole corner."; TAGLINE="phonk and drift tapes"; LABEL="phonk / drift"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#f2ede4"; PANEL="#e7e0d2"; CARD="#faf7f1"; FG="#20180f"; MUT="#7a6a56"
      ACC="#b4462f"; ACC2="#3f6f5f"; LINE="#20180f1f"; BLEND="normal"
      OVER="linear-gradient(180deg,#f2ede4cc 0%,#f2ede455 34%,#f2ede4f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#20180f"; BTNFG="#f2ede4"
      ;;
    synthchar)
      LAYOUT=character; TOPIC=synthwave
      NAMES="SYNTHCHAR NEONCHILD GRIDRUNNER VHSKID CHROMEHEART"
      HEADLINE="The city is faster after midnight."; TAGLINE="synthwave and retro drive"; LABEL="synth / outrun"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#eaeff5"; PANEL="#dbe4ee"; CARD="#f5f8fc"; FG="#121821"; MUT="#5f6c7d"
      ACC="#3f6fbf"; ACC2="#bf7f3f"; LINE="#1218211f"; BLEND="normal"
      OVER="linear-gradient(180deg,#eaeff5cc 0%,#eaeff555 34%,#eaeff5f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#121821"; BTNFG="#eaeff5"
      ;;
    cinechar)
      LAYOUT=character; TOPIC=cinema
      NAMES="CINECHAR ROLECALL SCREENTEST FRAMEONE CASTROOM"
      HEADLINE="Films remembered by their faces."; TAGLINE="trailers and scores"; LABEL="cinema / archive"
      TRUST="Trusted by rooms of every size"; PREV="Previous"; NEXT="Next"
      BG="#efece3"; PANEL="#e5e1d5"; CARD="#f6f4ee"; FG="#1b1a17"; MUT="#6f6a5d"
      ACC="#4f8f96"; ACC2="#c07a4b"; LINE="#1b1a1722"; BLEND="normal"
      OVER="linear-gradient(180deg,#efece3cc 0%,#efece355 34%,#efece3f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#1b1a17"; BTNFG="#efece3"
      ;;
    ghibliroom)
      LAYOUT=cinema; TOPIC=cinema
      NAMES="GHIBLIROOM LANTERNHILL QUIETFILM SOFTREEL PAPERMOON"
      HEADLINE="A room that plays one film at a time."; TAGLINE="films and their scores"; LABEL="cinema"
      TRUST="Trusted by rooms of every size"; PREV="Previous session"; NEXT="Next session"
      BG="#eaeff5"; PANEL="#dbe4ee"; CARD="#f5f8fc"; FG="#121821"; MUT="#5f6c7d"
      ACC="#3f6fbf"; ACC2="#bf7f3f"; LINE="#1218211f"; BLEND="normal"
      OVER="linear-gradient(180deg,#eaeff5cc 0%,#eaeff555 34%,#eaeff5f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#121821"; BTNFG="#eaeff5"
      ;;
    animecine)
      LAYOUT=cinema; TOPIC=anime
      NAMES="ANIMECINE OPENINGROOM SAKURACUT REDPETAL FRAMEIDOL"
      HEADLINE="Openings that are better than the show."; TAGLINE="anime openings in 4k"; LABEL="anime"
      TRUST="Trusted by rooms of every size"; PREV="Earlier openings"; NEXT="Later openings"
      BG="#f6ecec"; PANEL="#eddede"; CARD="#fbf4f4"; FG="#241a1a"; MUT="#7d6262"
      ACC="#c25b5b"; ACC2="#5b7dc2"; LINE="#241a1a1f"; BLEND="normal"
      OVER="linear-gradient(180deg,#f6ececcc 0%,#f6ecec55 34%,#f6ececf2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#241a1a"; BTNFG="#f6ecec"
      ;;
    kyotocine)
      LAYOUT=cinema; TOPIC=japan
      NAMES="KYOTOCINE LONGWALK MACHIYA RIVERSIDE ASAGIRI"
      HEADLINE="Walk the city without leaving the room."; TAGLINE="long walks in 4k"; LABEL="japan"
      TRUST="Trusted by rooms of every size"; PREV="Yesterday's walk"; NEXT="Tomorrow's walk"
      BG="#e9f1ec"; PANEL="#dbe8e0"; CARD="#f4faf6"; FG="#141d18"; MUT="#5f7268"
      ACC="#2f8f63"; ACC2="#8f6f2f"; LINE="#141d181f"; BLEND="normal"
      OVER="linear-gradient(180deg,#e9f1eccc 0%,#e9f1ec55 34%,#e9f1ecf2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#141d18"; BTNFG="#e9f1ec"
      ;;
    ambientcine)
      LAYOUT=cinema; TOPIC=ambient
      NAMES="AMBIENTCINE SLOWFRAME LONGEXPOSURE STILLROOM PALEREEL"
      HEADLINE="Sound designed to be left running."; TAGLINE="ambient sessions"; LABEL="ambient"
      TRUST="Trusted by rooms of every size"; PREV="Previous session"; NEXT="Next session"
      BG="#efece3"; PANEL="#e5e1d5"; CARD="#f6f4ee"; FG="#1b1a17"; MUT="#6f6a5d"
      ACC="#4f8f96"; ACC2="#c07a4b"; LINE="#1b1a1722"; BLEND="normal"
      OVER="linear-gradient(180deg,#efece3cc 0%,#efece355 34%,#efece3f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#1b1a17"; BTNFG="#efece3"
      ;;
    gamecine)
      LAYOUT=cinema; TOPIC=gaming
      NAMES="GAMECINE CREDITSROLL FINALSAVE ENDGAME SCOREROOM"
      HEADLINE="Scores that outlived their games."; TAGLINE="full game soundtracks"; LABEL="games"
      TRUST="Trusted by rooms of every size"; PREV="Previous score"; NEXT="Next score"
      BG="#f2ede4"; PANEL="#e7e0d2"; CARD="#faf7f1"; FG="#20180f"; MUT="#7a6a56"
      ACC="#b4462f"; ACC2="#3f6f5f"; LINE="#20180f1f"; BLEND="normal"
      OVER="linear-gradient(180deg,#f2ede4cc 0%,#f2ede455 34%,#f2ede4f2 100%)"; CHIP="#ffffff0f"; CHIPB="#ffffff24"; BTNBG="#20180f"; BTNFG="#f2ede4"
      ;;
  esac
  SITE_NAME="$(shuf -e $NAMES -n 1 2>/dev/null || echo "${NAMES%% *}")"
  GENRE="$LABEL"

  case "$TOPIC" in
    breakcore) TRACKS="X6nEHPgPRXI|1 hour breakcore mix \\reupload|limiminami|1:26:58
2i9vG5ZtK3c|starry breakcore mix|masen|1:11:12
6l5kJUWhDqQ|1 HOUR BREAKCORE FOR YOUR CORE / Music Playlist if you Broken|CURSEDEVIL|1:02:52
BhZ0Ky9uqts|Breakcore mix to dissociate to|Utsudere|1:43:22
CtSc5Gn6xvY|breakcore / jungle / ambient dnb mix to dive into the unknown|fever recognition|2:32:30
bunBUv4hDj4|1 Hour Of Breakcore That Makes You Feel The Vibe|Alithium Music Archive|1:01:56
gKh5eyGE9fs|Breakcore: The Sounds of Destruction [ breakcore mix to die to o|AngelSvrgery|2:19:10
lZUOxJbvCmY|【 𝗯𝗿𝗲𝗮𝗸𝗰𝗼𝗿𝗲/𝗷𝘂𝗻𝗴𝗹𝗲/𝗱𝗻𝗯 𝗺𝗶𝘅 𝗳𝗼𝗿 𝙡𝙤𝙘𝙠𝙞𝙣𝙜 𝙩𝙛 𝙞𝙣 】|deltea|1:05:40
v9ykDyCR3TY|【𝟐𝟎𝟐𝟒 𝐇𝐞𝐚𝐯𝐞𝐧𝐥𝐲 𝐁𝐫𝐞𝐚𝐤𝐜𝐨𝐫𝐞 𝐌𝐢𝐱 - 𝟏 𝐇𝐨𝐮𝐫 🎧】|Lix|1:00:45" ;;
    lofi) TRACKS="LTphVIore3A|No Copyright Music Playlist - 1 Hour Lofi Hip Hop Mix|Super Lofi World|1:41:00
n61ULEU7CO0|Best of lofi hip hop 2021 ✨ [beats to relax/study to]|Lofi Girl|6:10:58
CFGLoQIhmow|lofi hip hop mix 📚 beats to relax/study to (Part 1)|Lofi Girl|2:50:41
8b3fqIBrNW0|lofi hip hop mix 📚 beats to relax/study to (Part 2)|Lofi Girl|4:05:02
TbAjL4qgzC0|Lo-Fi Homer CHILL / STUDY / RELAX / SLEEP ONE HOUR|TheRealPaul|1:07:54
82ujdQBjpDQ|Quiet Solitude - Lofi Song ~ Lofi hip hop mix ~ Stress Relief / |Chilli High|11:54:56
lTRiuFIWV54|1 A.M Study Session 📚 [lofi hip hop]|Lofi Girl|1:01:14
CLeZyIID9Bo|Chill Lofi Mix [chill lo-fi hip hop beats]|Settle|1:44:52
l_7e2ZamUpI|Chillhop Drive 90's - Lofi hip hop ~ Deep Focus, Relaxing Music |chilli music|24:04:20" ;;
    dnb) TRACKS="R8MWKsheHxk|'The Journey' (2 Hour Drum & Bass Mix)|SuicideSheeep|1:54:21
7j4WQ5qOBZY|Best Drum & Bass Mix 2020 (Melodic/Liquid Drum and Bass)|MrMoMMusic|2:28:40
9r-crUUUU50|1 Hour Unbelievable Liquid Drum & Bass Mega Mix|ThaLineBass|1:01:25
CxvPDeJJK8c|1 HOUR - LIQUID DRUM & BASS SUMMER MIX 2024 [NO ADS]|FINAL CONTACT|1:10:06
PUsk2mrXvKo|Dark n Heavy Drum & Bass MIX [1 Hour 1080p HD]|Evil Bass Mixes|59:51
9ogliXhWcg4|1 HOUR DRUM & BASS - OCT 2025|xKito Music|1:01:22
iFeg7F2q-PU|Chill Liquid Drum and Bass Mix #3|U:Fourier UK|2:42:09
LeMk0yiSoq4|UKF Drum & Bass: Best of Drum & Bass 2023 Mix|UKF Drum & Bass|1:16:32
mbNi5L3QOCA|(5 Hours) Best Liquid Drum and Bass mix [Study / Chill DnB]|Rubee|5:01:13" ;;
    synthwave) TRACKS="MxGJCjNa-80|/ L O S T N I G H T S / - A NewRetroWave Mix / 1 Hour / Synthwav|NewRetroWave|1:12:20
S10zEFq_wmg|２𝟶４９ // 𝗠𝗜𝗗𝗡𝗜𝗚𝗛𝗧 𝗗𝗥𝗜𝗩𝗘 / 1 HOUR SYNTHWAVE MIX|PHONKONAUT|1:08:32
zvTgZ2ch7aU|1 Hour Synthwave for Coding, Work & Focus|Neon Dusk Radio|1:00:16
_Gajv2yJt5M|𝟭𝟵𝟵𝟵 𝗗𝗥𝗜𝗙𝗧 𝗜𝗡𝗧𝗢 𝗠𝗘𝗠𝗢𝗥𝗬 // Synthwave, Vaporwave, Cyberpunk, Chill|Moebius FM|2:07:10
QvSN30awLK8|Synthwave mix night drive / Synthwave 10 hours|Cat the Driver - Background Music|10:00:01
QHnYKXQkZjk|P L I S S K E N - A NewRetroWave Mix / 1 Hour / Retrowave/ Dream|NewRetroWave|1:00:39
LLPoZGX0qZk|'OUTRUN' / Best of Synthwave And Retro Electro Music Mix for 1 H|ThePrimeThanatos|1:02:08
Swu5uIhe-Ms|M E M O R I E S - A NewRetroWave Mix / 1 Hour / Synthwave/ Retro|NewRetroWave|1:07:06
LTln_sCHfQs|🎷 1 Hour No Copyright 80s Synthwave Retro Electro Wave Music Lon|Aries Beats [Free Retro Music Producer & Composer]|57:58" ;;
    phonk) TRACKS="Ljq0c5C7LuM|TOP VIRAL PHONK/FUNK PLAYLIST 🔥 / TIKTOK PHONK 2025🔥|Twisco|1:01:40
7vFMAZD37X4|AURA = ♾️ / 1 HOUR VIRAL AURA MUSIC PLAYLIST 2026 🔥 TRENDING PHO|EMPIRE PHONK|1:20:03
_xUxFLEP6gc|Phonk Music Mix 2025 ※ 1 HOUR AGGRESSIVE PHONK PLAYLIST ※ Фонка |PHONK Club|1:47:37
6FvnWof4xL8|TOP 50 MOST VIRAL PHONK/FUNK 2026 🔥🎵 PLAYLIST 🎵|Twisco|1:37:37
KfX9rDANEfE|ULTIMATE VIRAL PHONK/FUNK PLAYLIST 🔥 / TIKTOK PHONK 2026🔥🎵|Twisco|1:45:32
y1ELYBtvKFQ|Phonk Music Mix 2025 🎶 1 HOUR PHONK PLAYLIST 🎶|SynthWavesZ|1:01:20
m_52WB-sYd4|Mix of the BEST BRAZILIAN PHONK of 2025-2026🎵|Superior|1:04:06
xwyh6yg7rEo|Phonk Vol 2 - Music Mix 2025 🎶 1 HOUR PHONK PLAYLIST 🎶|SynthWavesZ|1:01:42
c2t7abhod10|AURA = ♾️ / 1 HOUR VIRAL AURA MUSIC PLAYLIST 2026 🔥 TRENDING PHO|EMPIRE PHONK|1:12:25" ;;
    ambient) TRACKS="NaZeslUINF4|best of øneheart, antent, reidenshi, tilekid, knonzzz / ambient |dreamslow|1:00:44
WxQIUXnokAo|ambient era / antent ambient songs (2022-2024)|Antent|2:37:10
O5p2ZX7UU9w|forgotten dreams // dark ambient music mix|dreamscape|1:01:39
hzLdZWIeq3c|best of øneheart // ambient mix|dreamscape|36:54
Rv0QsmjIQ_U|a coldcore ambient playlist|Zerofuturism|1:22:54
Jk1TyOSQi5s|best of antent // ambient mix|dreamscape|47:25
NGiTTTimQ_8|Aphex Twin Ambient Mix (Reupload with the original gif)|Hender|2:14:02
roMz1PPslbM|escape everything // dark ambient music mix|dreamscape|54:28
4Yn8-2NkrYk|Risen 1 Soundtrack / Ambient Mix (1 Hour)|Craft of Ambience|1:00:01" ;;
    coffee) TRACKS="XlLqJwJHjp0|How To Make Pour Over Coffee - SIMPLE V60 Brew Tutorial|Mirror Coffee Roasters|4:06
dS9NwmLtDsA|HOW TO POUROVER: Understanding Pourover Coffee / Percolation|Lance Hedrick|29:07
3SIFFaT1MFU|Winning POUR OVER Recipe from World Brewers Cup Champion (Martin|European Coffee Trip|8:46
1oB1oDrDkHM|A Better 1 Cup V60 Technique|James Hoffmann|10:25
sHnsCa3-W4Y|Pour Over Coffee for Beginners / Pour Over 101|HomeGrounds Coffee|9:00
AI4ynXzkSQo|The Ultimate V60 Technique|James Hoffmann|12:11
2mrLiE4ilXw|Pourover Lesson for Advanced Brewers|Lance Hedrick|17:11
mMwscUNKbPk|How To Avoid A Bad Pour Over Brew|James Hoffmann|13:18
o97e_mGejiw|Beginners Guide To Making Pour-Over Coffee At Home (Without a Sc|Espresso Doc.|3:55" ;;
    tech) TRACKS="hGaC1w1ibEg|Dezea® Studio — Showreel [ 2024 ]|Dezea Studio|1:16
5wUVJ5uDn0k|YS DESIGN SHOWREEL 2024|Yakovlevsky - Creative Design Studio|1:58
bRyU3gco_dY|Pixtar Brand Design Agency Showreel 2024|Pixtar Brand Design Agency - Dubai|3:56
gOOxscC3oDA|Boyutgraf Creative Agency 2024 Showreel|Boyutgraf|1:54
TXsNnOOCSIU|Obys Showreel 2024|Design Education Series® by Obys®|1:16
x6zrGTvsv4g|Our Showreel / Creative Agency Dubai / Moonbox|Moonbox|1:15
2Fo0kt36Dtc|MOOCH DESIGN STUDIO SHOWREEL 2024|MOOCH|1:26
5p_Dh1yhCV8|Creative Agency Showreel / Abdy Studio|abdystudio|1:30
SaOwutdzd24|Halo showreel. A design-led creative agency.|Halo Advertising|2:01" ;;
    anime) TRACKS="WO8SoTZ8QTM|Naruto Shippuden Op/ Opening 16 [4k 60 FSP]|NakiriSaku ,|1:32
st4wcpjZeQQ|Demon Slayer - Opening 3 / 4K / 60FPS / Creditless /|Anicrad|2:02
Bt3D3Ca9nww|Death Note OP 1 [4K / 60FPS / Creditless]|Alina|1:21
dy7gr0vaNho|Steins;Gate - Opening 【Hacking to the Gate】 4K 60FPS Creditless |Neobrane|2:09
gjD_x4222Q8|Tokyo Ghoul Opening 1 (4k 60FPS)┃Creditless|KaizenK|1:47
4qXzCm9sRxE|[Creditless] Fate/stay night UBW OP [Brave Shine] [4K HDR] [60FP|Nephastion|1:53
XSo75BY-es4|One Piece - Opening 26 【Uuuuus!】 4K 60FPS / CC|Neobrane|2:04
fBsfD0Eytjw|Your Lie in April - Opening 1 【Hikaru nara】 4K 60FPS Creditless |Neobrane|2:05
SJkCLcnGB-c|JoJo's Bizarre Adventure - Opening 2 [4K 60FPS / Creditless / CC|Neobrane|2:04" ;;
    cinema) TRACKS="I1dHzoRl0sQ|PRINCESS MONONOKE 4K Remaster / Official IMAX Trailer|GKIDS Films|1:39
iwROgK94zcM|Howl's Moving Castle - Official Trailer|Crunchyroll Store Australia|1:36
vf6c6n35wr4|PRINCESS MONONOKE / Official English Trailer|GKIDS Films|1:04
PhHoCnRg1Yw|THE WIND RISES Trailer / Festival 2013|TIFF|4:17
ByXuk9QqQkk|Spirited Away - Official Trailer|Crunchyroll Store Australia|2:27
5fW_H88W2VE|Studio Ghibli / Official Trailer / The Classics|StudiocanalUK|1:13
oCIeWol8jVk|Howl's Moving Castle - Celebrate Studio Ghibli - Official Traile|Crunchyroll Store Australia|1:31
GAp2_0JJskk|SPIRITED AWAY / Official Trailer|GKIDS Films|1:00
h6XP82TyFWw|PONYO / Official English Trailer|GKIDS Films|1:57" ;;
    japan) TRACKS="arOQ7slh3pM|Kyoto, Japan 4K Walking Tour - Captions & Immersive Sound [4K Ul|HP Walking Tours|1:11:42
SKJG4xqdH_0|Spring Morning Walk through Historic Higashiyama / Kyoto, Japan |Ambient Exploration|2:06:52
qgfd-uWTVwg|Walk in Kyoto Midnight Rainstorm - 4K HDR|VIRTUAL JAPAN|58:53
QP11A3q7ZP4|🇯🇵 Japan Walking Tour - Wandering Historic Streets of Kyoto [ 4K|World Wanderings: 4K Walking Tours|1:22:08
YlNDqTN8e_g|Sunset Walk on Side Streets and Iconic Sights / Kyoto, Japan 4K|Ambient Exploration|2:26:59
8zcPIr0mDzU|Kyoto Hidden Valleys Drive 🌿 Arashiyama to Kibune / 8K 60fps HDR|Abao Vision|1:33:12
pQzt0sQ3Pio|Quiet Dawn Walk along Philosopher's Path / Kyoto, Japan 4K Morni|Ambient Exploration|1:48:48
OjHbS-_nncw|🇯🇵 Japan Walking Tour - Discovering Kyoto’s Suburban Streets in |World Wanderings: 4K Walking Tours|1:08:10
XSaF_sDxLdo|Kyoto Morning Walk through Temples and Neighborhoods / Japan 4K|Ambient Exploration|1:53:10" ;;
    gaming) TRACKS="nnvjKf_mRYM|[Official] TUNIC (Original Soundtrack) - Full Album / Lifeformed|Lifeformed|3:01:50
VWziHqEd0Uw|Diablo 2 - Complete Soundtrack HD|Jesterhead|1:42:54
B_3FKsiNOrU|MENACE / Official Game Soundtrack / Full Album|Scott Buckley|1:27:13
gkntjUvYDDo|Alkis Livathinos - HUE Official Soundtrack [Full Album] / Instru|Alkis Livathinos|58:35
3GRKJ87S5cI|Hades: Original Soundtrack - Full Album|Supergiant Games|2:29:44
uH3Aoj1nw58|Pyre Original Soundtrack - Full Album|Supergiant Games|1:51:10
I6rufOlNyYM|Gris - Original Game Soundtrack (full ost official video)|berlinist|1:19:29
7kvmPh2nYBM|Journey OST ♬ Complete Original Soundtrack|Jepedillo|57:26
3djZ6rgdHhE|Baldur's Gate 3 - Extended Soundtrack [OST / Music]|Pharysz|2:53:23" ;;
  esac

  YEAR="$(date +%Y)"
  mkdir -p "$WEBROOT/assets" "$WEBROOT/archive" "$WEBROOT/about"

  # обложки берём с ютуба: у длинных роликов почти всегда есть maxres
  thumb() {
    if curl -sfI --max-time 8 "https://i.ytimg.com/vi/$1/maxresdefault.jpg" >/dev/null 2>&1; then
      printf 'https://i.ytimg.com/vi/%s/maxresdefault.jpg' "$1"
    else
      printf 'https://i.ytimg.com/vi/%s/hqdefault.jpg' "$1"
    fi
  }

  F_ID="$(printf '%s\n' "$TRACKS" | sed -n 1p | cut -d'|' -f1)"
  F_TIT="$(printf '%s\n' "$TRACKS" | sed -n 1p | cut -d'|' -f2)"
  F_CH="$(printf '%s\n' "$TRACKS" | sed -n 1p | cut -d'|' -f3)"
  F_LEN="$(printf '%s\n' "$TRACKS" | sed -n 1p | cut -d'|' -f4)"
  T2="$(printf '%s\n' "$TRACKS" | sed -n 2p | cut -d'|' -f1)"
  T3="$(printf '%s\n' "$TRACKS" | sed -n 3p | cut -d'|' -f1)"
  HERO="$(thumb "$F_ID")"
  N_TRACKS="$(printf '%s\n' "$TRACKS" | grep -c '|')"
  LOGOS_HTML="<span>MERCURY</span><span>ramp</span><span>HEX</span><span>Vercel</span><span>descript</span><span>Cash App</span><span>SUPERCELL</span><span>runway</span>"

  # штрихкод для журнальной обложки
  BARCODE="$(i=0; printf '<div class=\"strip\">'; while [ $i -lt 26 ]; do printf '<i style=\"height:%d%%\"></i>' $(( (i * 37 % 55) + 45 )); i=$((i+1)); done; printf '</div>')"

  case "$LAYOUT" in
    hero)
      GFONTS="Space+Grotesk:wght@400;500;700&family=Space+Mono:wght@400;700"
      cat > "$WEBROOT/assets/style.css" <<CSS
:root{--bg:$BG;--panel:$PANEL;--card:$CARD;--line:$LINE;--fg:$FG;--mut:$MUT;--acc:$ACC;--acc2:$ACC2;--r:26px}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;background:var(--bg);color:var(--fg);line-height:1.45;
  font-family:'Space Grotesk',system-ui,-apple-system,sans-serif;-webkit-font-smoothing:antialiased}
a{color:inherit;text-decoration:none}
img{display:block;max-width:100%}
.wrap{max-width:1240px;margin:0 auto;padding:0 20px}
.mono{font-family:'Space Mono',ui-monospace,monospace}

.top{position:absolute;left:0;right:0;top:0;z-index:5}
.top .wrap{display:flex;align-items:center;gap:26px;height:78px}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;letter-spacing:.02em;color:var(--fg)}
.brand i{width:22px;height:22px;border-radius:50%;background:var(--acc);display:block}
.top nav{display:flex;gap:22px;font-size:13.5px;color:var(--fg);opacity:.82}
.top nav a:hover{color:var(--acc);opacity:1}
.pill{margin-left:auto;display:flex;align-items:center;gap:9px;background:$BTNBG;color:$BTNFG;
  border-radius:999px;padding:9px 9px 9px 20px;font-size:13.5px;font-weight:500}
.pill b{width:30px;height:30px;border-radius:50%;background:$BTNFG;color:$BTNBG;display:grid;
  place-items:center;font-size:13px}

.hero{position:relative;min-height:660px;border-radius:0 0 var(--r) var(--r);overflow:hidden;
  display:flex;align-items:flex-end;isolation:isolate}
.hero .bg{position:absolute;inset:0;z-index:-2;width:100%;height:100%;object-fit:cover;filter:saturate(.6) contrast(1.05)}
.hero::after{content:"";position:absolute;inset:0;z-index:-1;background:$OVER}
.hero .title{position:absolute;left:0;right:0;top:96px;text-align:center;pointer-events:none}
.hero .title h1{margin:0;font-size:clamp(56px,15.5vw,210px);line-height:.82;letter-spacing:-.045em;
  font-weight:700;color:var(--fg);mix-blend-mode:$BLEND}
.hero .foot{width:100%;padding:0 0 40px;position:relative}
.hero .foot .wrap{display:flex;align-items:flex-end;gap:26px;flex-wrap:wrap}
.hero .lead{max-width:430px}
.hero .lead p{color:var(--mut);font-size:13.5px;margin:0 0 14px;max-width:340px}
.hero .lead h2{margin:0;font-size:clamp(28px,4.4vw,52px);line-height:1.02;letter-spacing:-.03em}
.cards-abs{margin-left:auto;display:flex;gap:14px;align-items:flex-end}
.gcard{background:$CHIP;backdrop-filter:blur(14px);border:1px solid $CHIPB;border-radius:20px;
  padding:16px 18px;width:216px}
.gcard b{display:block;font-size:15px;margin-bottom:6px}
.gcard span{font-size:11.5px;color:var(--mut);line-height:1.4;display:block}
.gcard.art{padding:0;overflow:hidden;width:236px}
.gcard.art img{aspect-ratio:16/9;object-fit:cover;width:100%}
.gcard.art .in{padding:14px 16px 16px}

section.blk{padding:96px 0 0}
.eyebrow{display:flex;gap:8px;color:var(--mut);font-size:11.5px;letter-spacing:.14em;text-transform:uppercase}
.two{display:grid;grid-template-columns:270px 1fr;gap:40px;align-items:start}
.two h3{margin:0;font-size:clamp(21px,2.5vw,31px);line-height:1.22;letter-spacing:-.02em;font-weight:500}
.two h3 span{color:var(--mut)}
.two p{color:var(--mut);font-size:13.5px;max-width:62ch;margin:16px 0 0}
.btn{display:inline-flex;align-items:center;gap:10px;background:$BTNBG;color:$BTNFG;border-radius:999px;
  padding:11px 11px 11px 22px;font-size:14px;font-weight:500;margin-top:22px}
.btn b{width:32px;height:32px;border-radius:50%;background:$BTNFG;color:$BTNBG;display:grid;place-items:center}

.stats{display:grid;grid-template-columns:1fr 1.35fr;gap:16px;margin-top:40px}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:22px;padding:16px;
  display:flex;gap:18px;align-items:center}
.stat img{width:150px;aspect-ratio:4/3;object-fit:cover;border-radius:16px;flex:none}
.stat .v{font-size:clamp(28px,3.4vw,42px);font-weight:700;letter-spacing:-.03em;line-height:1}
.stat .k{font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:var(--mut);margin-top:6px}
.stat .d{font-size:12px;color:var(--mut);margin-top:10px;max-width:44ch}

.rot{display:grid;grid-template-columns:repeat(auto-fill,minmax(268px,1fr));gap:18px;margin-top:34px}
.tr{background:var(--card);border:1px solid var(--line);border-radius:22px;overflow:hidden;
  cursor:pointer;transition:border-color .15s}
.tr:hover{border-color:var(--acc)}
.tr img{aspect-ratio:16/9;object-fit:cover;width:100%}
.tr .in{padding:14px 16px 16px}
.tr b{display:block;font-size:14.5px;font-weight:500;line-height:1.3;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;min-height:2.6em}
.tr .m{display:flex;justify-content:space-between;color:var(--mut);font-size:11.5px;margin-top:9px}
.tr .n{display:none}

.player{margin-top:34px;background:var(--panel);border:1px solid var(--line);border-radius:24px;
  padding:18px;display:flex;gap:20px;align-items:center}
.player img{width:190px;aspect-ratio:16/9;object-fit:cover;border-radius:16px;flex:none}
.player .np{flex:1;min-width:0}
.player small{color:var(--mut);font-size:11px;letter-spacing:.16em;text-transform:uppercase}
.player h4{margin:7px 0 3px;font-size:19px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.player .ch{color:var(--mut);font-size:13px;margin-bottom:14px}
.bar{height:3px;background:var(--line);border-radius:2px;overflow:hidden}
.bar i{display:block;height:100%;width:8%;background:linear-gradient(90deg,var(--acc2),var(--acc))}
.tm{display:flex;justify-content:space-between;color:var(--mut);font-size:11px;margin-top:7px}
.eq{display:flex;gap:3px;align-items:flex-end;height:36px;flex:none}
.eq b{width:4px;background:var(--acc);border-radius:2px;animation:e 1.1s infinite ease-in-out}
.eq b:nth-child(2){animation-delay:.15s}.eq b:nth-child(3){animation-delay:.3s}
.eq b:nth-child(4){animation-delay:.45s}.eq b:nth-child(5){animation-delay:.6s}
@keyframes e{0%,100%{height:8px}50%{height:34px}}

.steps{background:var(--panel);border-radius:var(--r);padding:60px 0;margin-top:96px}
.step{display:grid;grid-template-columns:330px 1fr;gap:26px;background:var(--card);
  border:1px solid var(--line);border-radius:22px;overflow:hidden;margin-top:16px}
.step img{width:100%;height:100%;object-fit:cover;aspect-ratio:16/10}
.step .in{padding:26px 28px 28px}
.step .n{font-size:38px;font-weight:700;letter-spacing:-.03em}
.step h5{margin:2px 0 12px;font-size:12.5px;letter-spacing:.14em;text-transform:uppercase;color:var(--mut);font-weight:400}
.step p{margin:0;color:var(--mut);font-size:13px;max-width:70ch}
footer{padding:70px 0 46px;color:var(--mut);font-size:12px}
footer .wrap{display:flex;gap:24px;flex-wrap:wrap;border-top:1px solid var(--line);padding-top:26px}
table{width:100%;border-collapse:collapse;font-size:14px}
td{padding:12px;border-bottom:1px solid var(--line)}
td.k{color:var(--mut);width:170px;font-size:12px}
@media(max-width:900px){.two,.stats,.step{grid-template-columns:1fr}.top nav{display:none}
  .cards-abs{width:100%;margin-left:0}.player{flex-wrap:wrap}}
CSS
      cover_html() {
        cat <<HTML
<div class="top"><div class="wrap">
  <a class="brand" href="/"><i></i>$SITE_NAME</a>
  <nav><a href="/">Radio</a><a href="/#rotation">Rotation</a><a href="/archive/">Archive</a><a href="/about/">About</a></nav>
  <a class="pill" href="/about/">Submit a mix <b>&#8594;</b></a>
</div></div>
<header class="hero">
  <img class="bg" src="$HERO" alt="">
  <div class="title"><h1>$SITE_NAME</h1></div>
  <div class="foot"><div class="wrap">
    <div class="lead">
      <p>$TAGLINE. One continuous stream, hand-picked sets, no ads and no accounts.</p>
      <h2>$HEADLINE</h2>
    </div>
    <div class="cards-abs">
      <div class="gcard"><b>$N_TRACKS SETS</b><span>In current rotation, refreshed every week.</span></div>
      <div class="gcard art">
        <img src="https://i.ytimg.com/vi/$F_ID/hqdefault.jpg" alt="">
        <div class="in"><b>NOW PLAYING</b><span>$F_TIT</span></div>
      </div>
    </div>
  </div></div>
</header>
HTML
      }
      ;;
    editorial)
      GFONTS="Inter:wght@400;500;600;700&family=Space+Mono:wght@400;700"
      cat > "$WEBROOT/assets/style.css" <<CSS
:root{--bg:$BG;--panel:$PANEL;--card:$CARD;--line:$LINE;--fg:$FG;--mut:$MUT;--acc:$ACC;--acc2:$ACC2}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);line-height:1.5;
  font-family:'Inter',system-ui,-apple-system,sans-serif;-webkit-font-smoothing:antialiased;
  background-image:radial-gradient(#00000009 1px,transparent 1px);background-size:3px 3px}
a{color:inherit;text-decoration:none}
img{display:block;max-width:100%}
.wrap{max-width:1180px;margin:0 auto;padding:0 26px}
.mono{font-family:'Space Mono',ui-monospace,monospace}

.top .wrap{display:flex;align-items:center;gap:26px;height:74px}
.brand{display:flex;align-items:center;gap:9px;font-weight:600;letter-spacing:.02em;font-size:14px}
.brand i{width:16px;height:16px;border-radius:50%;background:var(--acc);display:block}
.top nav{display:flex;gap:22px;font-size:12.5px;color:var(--mut)}
.top nav a:hover{color:var(--fg)}
.pill{margin-left:auto;display:flex;align-items:center;gap:9px;background:$BTNBG;color:$BTNFG;
  border-radius:999px;padding:8px 8px 8px 18px;font-size:12.5px}
.pill b{width:26px;height:26px;border-radius:50%;background:$BTNFG;color:$BTNBG;display:grid;
  place-items:center;font-size:12px}

/* обложка журнала */
.cover{position:relative;margin:8px 0 0;padding-bottom:0}
.cover .meta{display:grid;grid-template-columns:repeat(4,auto);gap:44px;justify-content:start;
  font-size:11px;letter-spacing:.02em;margin-bottom:-6px;position:relative;z-index:3;padding-left:2px}
.cover .meta div span{display:block;color:var(--mut);font-size:9.5px;letter-spacing:.14em;text-transform:uppercase}
.cover .meta div b{font-weight:500;font-size:11.5px}
.cover h1{margin:0;font-size:clamp(76px,20vw,268px);line-height:.78;letter-spacing:-.055em;
  font-weight:700;color:var(--acc);position:relative;z-index:1;white-space:nowrap}
.cover .shot{position:relative;z-index:2;margin:-11% auto 0;width:min(560px,72%);
  aspect-ratio:3/4;overflow:hidden;border-radius:2px}
.cover .shot img{width:100%;height:100%;object-fit:cover;filter:saturate(.72) contrast(1.06)}
.cover .strip{position:absolute;right:26px;bottom:88px;z-index:4;background:#fff;padding:7px 8px;
  display:flex;gap:2px;align-items:flex-end;height:52px;border:1px solid #00000018}
.cover .strip i{display:block;width:2px;background:#111}
.cover .band{position:absolute;left:0;right:0;bottom:0;z-index:3;display:flex;justify-content:space-between;
  padding:0 26px 18px;font-size:10.5px;letter-spacing:.16em;text-transform:uppercase;color:var(--mut)}
.sep{height:1px;background:var(--line);margin:34px 0 0}

section.blk{padding:56px 0 0}
.eyebrow{color:var(--mut);font-size:10.5px;letter-spacing:.18em;text-transform:uppercase}
.two{display:grid;grid-template-columns:230px 1fr;gap:34px;align-items:start}
.two h3{margin:0;font-size:clamp(20px,2.3vw,30px);line-height:1.24;letter-spacing:-.015em;font-weight:500}
.two h3 span{color:var(--mut)}
.two p{color:var(--mut);font-size:13px;max-width:62ch;margin:14px 0 0}
.btn{display:inline-flex;align-items:center;gap:10px;background:$BTNBG;color:$BTNFG;border-radius:999px;
  padding:10px 10px 10px 20px;font-size:13px;margin-top:20px}
.btn b{width:28px;height:28px;border-radius:50%;background:$BTNFG;color:$BTNBG;display:grid;place-items:center}

/* список выпусков */
.rot{margin-top:30px;border-top:1px solid var(--line)}
.tr{display:grid;grid-template-columns:34px 108px 1fr auto;gap:20px;align-items:center;
  padding:13px 4px;border-bottom:1px solid var(--line);cursor:pointer}
.tr:hover{background:#ffffff70}
.tr .n{color:var(--mut);font-size:11px}
.tr img{width:108px;aspect-ratio:16/9;object-fit:cover;border-radius:2px;filter:saturate(.75)}
.tr b{font-weight:500;font-size:14.5px;display:block}
.tr .c{color:var(--mut);font-size:12px}
.tr .l{color:var(--mut);font-size:11.5px}
.tr:hover b{color:var(--acc)}

.player{margin-top:26px;background:var(--card);border:1px solid var(--line);padding:16px;
  display:flex;gap:18px;align-items:center;border-radius:3px}
.player img{width:168px;aspect-ratio:16/9;object-fit:cover;border-radius:2px;flex:none}
.player .np{flex:1;min-width:0}
.player small{color:var(--mut);font-size:10px;letter-spacing:.18em;text-transform:uppercase}
.player h4{margin:6px 0 2px;font-size:17px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.player .ch{color:var(--mut);font-size:12.5px;margin-bottom:12px}
.bar{height:2px;background:var(--line);overflow:hidden}
.bar i{display:block;height:100%;width:8%;background:var(--acc)}
.tm{display:flex;justify-content:space-between;color:var(--mut);font-size:10.5px;margin-top:6px}
.eq{display:flex;gap:3px;align-items:flex-end;height:30px;flex:none}
.eq b{width:3px;background:var(--acc);border-radius:1px;animation:e 1.1s infinite ease-in-out}
.eq b:nth-child(2){animation-delay:.15s}.eq b:nth-child(3){animation-delay:.3s}
.eq b:nth-child(4){animation-delay:.45s}.eq b:nth-child(5){animation-delay:.6s}
@keyframes e{0%,100%{height:7px}50%{height:28px}}

.steps{margin-top:64px}
.step{display:grid;grid-template-columns:250px 1fr;gap:24px;border-top:1px solid var(--line);padding:24px 0}
.step img{width:100%;aspect-ratio:4/3;object-fit:cover;border-radius:2px;filter:saturate(.72)}
.step .n{font-size:30px;font-weight:700;letter-spacing:-.03em}
.step h5{margin:2px 0 10px;font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:var(--mut);font-weight:400}
.step p{margin:0;color:var(--mut);font-size:12.5px;max-width:68ch}
footer{padding:56px 0 40px;color:var(--mut);font-size:11.5px}
footer .wrap{display:flex;gap:22px;flex-wrap:wrap;border-top:1px solid var(--line);padding-top:22px}
table{width:100%;border-collapse:collapse;font-size:13.5px}
td{padding:11px 4px;border-bottom:1px solid var(--line)}
td.k{color:var(--mut);width:160px;font-size:11.5px;letter-spacing:.06em;text-transform:uppercase}
@media(max-width:860px){.two,.step{grid-template-columns:1fr}.top nav{display:none}
  .tr{grid-template-columns:26px 84px 1fr}.tr .l{display:none}.cover .strip{display:none}}
CSS
      cover_html() {
        cat <<HTML
<div class="top"><div class="wrap">
  <a class="brand" href="/"><i></i>$SITE_NAME</a>
  <nav><a href="/">Issue</a><a href="/#rotation">Selection</a><a href="/archive/">Archive</a><a href="/about/">About</a></nav>
  <a class="pill" href="/about/">Submit a tape <b>&#8594;</b></a>
</div></div>
<section class="cover"><div class="wrap">
  <div class="meta">
    <div><span>Curated by</span><b>$SITE_NAME</b></div>
    <div><span>Issue</span><b>$(date +%m) / $YEAR</b></div>
    <div><span>Selection</span><b>$N_TRACKS entries</b></div>
    <div><span>Runtime</span><b>continuous</b></div>
  </div>
  <h1>$SITE_NAME</h1>
  <div class="shot"><img src="$HERO" alt=""></div>
  $BARCODE
  <div class="band"><span>$TAGLINE</span><span>$LABEL</span></div>
</div></section>
HTML
      }
      ;;
    split)
      GFONTS="Inter:wght@400;500;600;700&family=Space+Mono:wght@400;700"
      cat > "$WEBROOT/assets/style.css" <<CSS
:root{--bg:$BG;--ink:$FG;--mut:$MUT;--dark:$PANEL;--card:$CARD;--line:$LINE;--acc:$ACC}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);line-height:1.5;
  font-family:'Inter',system-ui,sans-serif;-webkit-font-smoothing:antialiased}
a{color:inherit;text-decoration:none}
img{display:block;max-width:100%}
.wrap{max-width:1180px;margin:0 auto;padding:0 34px}
.mono{font-family:'Space Mono',ui-monospace,monospace}
.split{display:grid;grid-template-columns:1fr 1fr;min-height:600px}
.split .l{padding:34px 0 44px;display:flex;flex-direction:column}
.split .l .in{margin:auto 0;max-width:430px;padding-right:30px}
.brand{display:flex;align-items:center;gap:10px;font-size:13.5px;font-weight:600;line-height:1.15}
.brand i{width:30px;height:30px;border:1.5px solid var(--ink);display:block;flex:none}
.brand span{display:block;font-size:8.5px;letter-spacing:.22em;color:var(--mut);font-weight:400}
h1{font-size:clamp(27px,3.4vw,40px);line-height:1.16;letter-spacing:-.025em;margin:0 0 10px;font-weight:700}
.sub{color:var(--mut);font-size:12.5px;margin:0 0 26px}
.ul{font-size:12.5px;border-bottom:1px solid var(--ink);padding-bottom:2px}
.tabs{display:flex;gap:30px;font-size:11.5px;color:var(--mut);margin-top:auto;padding-top:40px}
.tabs a:hover{color:var(--ink)}
.split .r{background:var(--dark);position:relative;overflow:hidden;display:grid;place-items:center}
.split .r img{width:78%;aspect-ratio:1;object-fit:cover;filter:grayscale(1) contrast(1.1);
  box-shadow:0 30px 70px #0009}
.burger{position:absolute;right:26px;top:26px;width:20px;height:11px;
  border-top:2px solid #fff;border-bottom:2px solid #fff}
section.blk{padding:96px 0 0}
h2{font-size:clamp(21px,2.4vw,28px);letter-spacing:-.02em;margin:0 0 12px;font-weight:700}
.two{display:grid;grid-template-columns:300px 1fr;gap:46px;align-items:start}
.two p{color:var(--mut);font-size:12px;margin:0;max-width:46ch;line-height:1.65}
.rot{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:1px;margin-top:26px;
  background:var(--line)}
.tr{background:var(--dark);cursor:pointer;padding:0 0 20px;transition:opacity .15s}
.tr:hover{opacity:.86}
.tr img{width:100%;aspect-ratio:16/9;object-fit:cover;filter:grayscale(1) contrast(1.05);margin-bottom:16px}
.tr .in{padding:0 18px}
.tr b{display:block;color:#fff;font-size:13.5px;font-weight:500;line-height:1.35;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.tr .m{display:flex;justify-content:space-between;color:#ffffff70;font-size:10.5px;margin-top:8px}
.tr .n{display:none}
.dots{display:flex;gap:4px;margin-top:10px}
.dots i{width:5px;height:5px;border-radius:50%;background:#ffffff40}
.dots i:first-child,.dots i:nth-child(2){background:#fff}
.player{margin-top:36px;border:1px solid var(--line);padding:18px;display:flex;gap:20px;align-items:center}
.player img{width:180px;aspect-ratio:16/9;object-fit:cover;filter:grayscale(1);flex:none}
.player .np{flex:1;min-width:0}
.player small{color:var(--mut);font-size:10px;letter-spacing:.2em;text-transform:uppercase}
.player h4{margin:7px 0 2px;font-size:17px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.player .ch{color:var(--mut);font-size:12px;margin-bottom:13px}
.bar{height:2px;background:var(--line)}
.bar i{display:block;height:100%;width:8%;background:var(--ink)}
.tm{display:flex;justify-content:space-between;color:var(--mut);font-size:10.5px;margin-top:6px}
.eq{display:flex;gap:3px;align-items:flex-end;height:28px;flex:none}
.eq b{width:3px;background:var(--ink);animation:e 1.1s infinite ease-in-out}
.eq b:nth-child(2){animation-delay:.15s}.eq b:nth-child(3){animation-delay:.3s}
.eq b:nth-child(4){animation-delay:.45s}.eq b:nth-child(5){animation-delay:.6s}
@keyframes e{0%,100%{height:6px}50%{height:26px}}
.steps{margin-top:80px}
.step{display:grid;grid-template-columns:1fr 1fr;gap:0;align-items:stretch;margin-top:2px}
.step img{width:100%;height:100%;object-fit:cover;filter:grayscale(1) contrast(1.05);aspect-ratio:4/3}
.step .in{background:var(--dark);color:#fff;padding:34px 36px;display:flex;flex-direction:column;justify-content:center}
.step .n{font-size:12px;color:#ffffff70;letter-spacing:.2em}
.step h5{margin:10px 0 12px;font-size:22px;font-weight:700;letter-spacing:-.02em}
.step p{margin:0;color:#ffffff9c;font-size:12px;line-height:1.7}
.step:nth-child(odd) .in{order:-1}
footer{padding:70px 0 40px;color:var(--mut);font-size:11px}
footer .wrap{display:flex;gap:26px;flex-wrap:wrap;border-top:1px solid var(--line);padding-top:22px}
table{width:100%;border-collapse:collapse;font-size:13px}
td{padding:11px 0;border-bottom:1px solid var(--line)}
td.k{color:var(--mut);width:150px;font-size:11px;letter-spacing:.1em;text-transform:uppercase}
.eyebrow{color:var(--mut);font-size:10.5px;letter-spacing:.2em;text-transform:uppercase}
@media(max-width:860px){.split,.two,.step{grid-template-columns:1fr}.split .r{min-height:340px}}
CSS
      cover_html() {
        cat <<HTML
<section class="split">
  <div class="l"><div class="wrap" style="padding-left:34px">
    <a class="brand" href="/"><i></i><span style="display:block">$SITE_NAME<span>$LABEL</span></span></a>
  </div>
  <div class="wrap" style="padding-left:34px"><div class="in">
    <h1>$HEADLINE</h1>
    <p class="sub">$TAGLINE</p>
    <a class="ul" href="/archive/">See the selection</a>
  </div></div>
  <div class="wrap" style="padding-left:34px"><div class="tabs">
    <a href="/">Home</a><a href="/#rotation">Selection</a><a href="/archive/">Archive</a><a href="/about/">About</a>
  </div></div>
  </div>
  <div class="r"><span class="burger"></span><img src="$HERO" alt=""></div>
</section>
HTML
      }
      ;;
    halftone)
      GFONTS="Archivo:wght@400;600;800&family=Space+Mono:wght@400;700"
      cat > "$WEBROOT/assets/style.css" <<CSS
:root{--bg:$BG;--ink:$FG;--mut:$MUT;--card:$CARD;--line:$LINE;--acc:$ACC}
*{box-sizing:border-box}
body{margin:0;color:var(--ink);line-height:1.5;font-family:'Archivo',system-ui,sans-serif;
  -webkit-font-smoothing:antialiased;background:var(--bg);
  background-image:radial-gradient(#00000012 1px,transparent 1.1px),
                   radial-gradient(#0000000a 1px,transparent 1.1px);
  background-size:4px 4px,7px 7px;background-position:0 0,2px 3px}
a{color:inherit;text-decoration:none}
img{display:block;max-width:100%}
.wrap{max-width:1200px;margin:0 auto;padding:0 30px}
.mono{font-family:'Space Mono',ui-monospace,monospace}
.top .wrap{display:flex;align-items:center;gap:26px;height:76px}
.brand{font-weight:800;letter-spacing:-.02em;font-size:16px}
.brand sup{font-size:9px;vertical-align:super}
.top nav{display:flex;gap:24px;font-size:13.5px}
.top nav a:hover{color:var(--acc)}
.right{margin-left:auto;display:flex;align-items:center;gap:18px;font-size:13.5px}
.pill{background:var(--ink);color:var(--bg);border-radius:999px;padding:10px 20px;font-size:13.5px}
.cover{text-align:center;padding:46px 0 0;position:relative;overflow:hidden}
.cover h1{margin:0 auto;font-size:clamp(44px,8.4vw,104px);line-height:.98;letter-spacing:-.035em;
  font-weight:800;max-width:14ch}
.cover p{color:var(--mut);font-size:15px;max-width:44ch;margin:16px auto 26px}
.cover .cta{display:inline-flex;align-items:center;gap:10px;background:var(--ink);color:var(--bg);
  border-radius:999px;padding:14px 26px;font-size:15px}
.hands{position:relative;margin-top:-6px;height:330px;overflow:hidden}
.hands img{position:absolute;bottom:-6%;width:52%;aspect-ratio:16/10;object-fit:cover;
  filter:grayscale(1) contrast(1.5) brightness(1.06);mix-blend-mode:multiply;opacity:.92}
.hands img:first-child{left:-3%;transform:scaleX(-1)}
.hands img:last-child{right:-3%}
.trust{text-align:center;color:var(--mut);font-size:13px;padding:6px 0 14px}
.logos{display:flex;flex-wrap:wrap;gap:36px;justify-content:center;align-items:center;
  padding-bottom:60px;font-weight:800;letter-spacing:-.02em;font-size:17px;opacity:.72}
.logos span:nth-child(even){font-weight:400;font-family:'Space Mono',monospace;font-size:14px}
section.blk{padding:70px 0 0}
.eyebrow{color:var(--mut);font-size:10.5px;letter-spacing:.2em;text-transform:uppercase}
.two{display:grid;grid-template-columns:250px 1fr;gap:40px;align-items:start}
.two h3{margin:0;font-size:clamp(22px,2.6vw,34px);line-height:1.2;letter-spacing:-.025em;font-weight:800}
.two h3 span{color:var(--mut);font-weight:400}
.two p{color:var(--mut);font-size:13.5px;max-width:62ch;margin:14px 0 0}
.btn{display:inline-flex;align-items:center;gap:10px;background:var(--ink);color:var(--bg);
  border-radius:999px;padding:12px 22px;font-size:14px;margin-top:20px}
.rot{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:20px;margin-top:30px}
.tr{background:var(--card);border:1px solid var(--line);border-radius:16px;overflow:hidden;cursor:pointer}
.tr:hover{border-color:var(--ink)}
.tr img{aspect-ratio:16/9;object-fit:cover;width:100%;filter:grayscale(1) contrast(1.35)}
.tr .in{padding:14px 16px 16px}
.tr b{display:block;font-size:14px;font-weight:600;line-height:1.3;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;min-height:2.6em}
.tr .m{display:flex;justify-content:space-between;color:var(--mut);font-size:11px;margin-top:8px}
.tr .n{display:none}
.player{margin-top:30px;background:var(--card);border:1px solid var(--line);border-radius:18px;
  padding:18px;display:flex;gap:20px;align-items:center}
.player img{width:180px;aspect-ratio:16/9;object-fit:cover;border-radius:12px;flex:none;filter:grayscale(1) contrast(1.3)}
.player .np{flex:1;min-width:0}
.player small{color:var(--mut);font-size:10.5px;letter-spacing:.18em;text-transform:uppercase}
.player h4{margin:7px 0 2px;font-size:18px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.player .ch{color:var(--mut);font-size:12.5px;margin-bottom:13px}
.bar{height:3px;background:var(--line);border-radius:2px;overflow:hidden}
.bar i{display:block;height:100%;width:8%;background:var(--ink)}
.tm{display:flex;justify-content:space-between;color:var(--mut);font-size:11px;margin-top:6px}
.eq{display:flex;gap:3px;align-items:flex-end;height:32px;flex:none}
.eq b{width:4px;background:var(--ink);border-radius:2px;animation:e 1.1s infinite ease-in-out}
.eq b:nth-child(2){animation-delay:.15s}.eq b:nth-child(3){animation-delay:.3s}
.eq b:nth-child(4){animation-delay:.45s}.eq b:nth-child(5){animation-delay:.6s}
@keyframes e{0%,100%{height:8px}50%{height:30px}}
.steps{margin-top:74px}
.step{display:grid;grid-template-columns:290px 1fr;gap:26px;border-top:1px solid var(--line);padding:26px 0}
.step img{width:100%;aspect-ratio:4/3;object-fit:cover;border-radius:12px;filter:grayscale(1) contrast(1.3)}
.step .n{font-size:30px;font-weight:800;letter-spacing:-.03em}
.step h5{margin:2px 0 10px;font-size:11px;letter-spacing:.18em;text-transform:uppercase;color:var(--mut);font-weight:400}
.step p{margin:0;color:var(--mut);font-size:13px;max-width:66ch}
footer{padding:60px 0 40px;color:var(--mut);font-size:12px}
footer .wrap{display:flex;gap:24px;flex-wrap:wrap;border-top:1px solid var(--line);padding-top:22px}
table{width:100%;border-collapse:collapse;font-size:13.5px}
td{padding:11px 0;border-bottom:1px solid var(--line)}
td.k{color:var(--mut);width:150px;font-size:11px;letter-spacing:.1em;text-transform:uppercase}
@media(max-width:860px){.two,.step{grid-template-columns:1fr}.top nav{display:none}.hands{height:200px}}
CSS
      cover_html() {
        cat <<HTML
<div class="top"><div class="wrap">
  <a class="brand" href="/">$SITE_NAME<sup>&#169;</sup></a>
  <nav><a href="/#rotation">Selection</a><a href="/archive/">Archive</a><a href="/about/">About</a></nav>
  <div class="right"><a href="/about/">Contact</a><a class="pill" href="/archive/">Start now</a></div>
</div></div>
<section class="cover">
  <div class="wrap">
    <h1>$HEADLINE</h1>
    <p>$TAGLINE</p>
    <a class="cta" href="/#rotation">Open the selection &#8599;</a>
  </div>
  <div class="hands"><img src="$HERO" alt=""><img src="https://i.ytimg.com/vi/$T2/hqdefault.jpg" alt=""></div>
  <div class="trust">$TRUST</div>
  <div class="logos">$LOGOS_HTML</div>
</section>
HTML
      }
      ;;
    character)
      GFONTS="Archivo:wght@400;700;800&family=Caveat:wght@600&family=Space+Mono"
      cat > "$WEBROOT/assets/style.css" <<CSS
:root{--bg:$BG;--ink:$FG;--mut:$MUT;--card:$CARD;--line:$LINE;--acc:$ACC;--acc2:$ACC2}
*{box-sizing:border-box}
body{margin:0;color:var(--ink);line-height:1.5;font-family:'Archivo',system-ui,sans-serif;
  background:var(--bg);-webkit-font-smoothing:antialiased;
  background-image:linear-gradient(115deg,#00000008 0 6%,transparent 6% 13%,#00000008 13% 17%,transparent 17% 27%),
                   linear-gradient(200deg,#00000008 0 8%,transparent 8% 19%,#0000000a 19% 23%,transparent 23% 33%)}
a{color:inherit;text-decoration:none}
img{display:block;max-width:100%}
.wrap{max-width:1180px;margin:0 auto;padding:0 30px}
.mono{font-family:'Space Mono',ui-monospace,monospace}
.top .wrap{display:flex;align-items:center;gap:14px;height:74px;font-size:12.5px;font-weight:700;letter-spacing:.06em}
.top nav{display:flex;gap:12px;align-items:center}
.top nav a{padding:7px 15px;border-radius:999px}
.top nav a.on{background:var(--ink);color:var(--bg)}
.top .sep{width:1px;height:18px;background:var(--line);margin:0 6px}
.top .info{margin-left:auto;display:flex;align-items:center;gap:8px}
.top .info i{width:16px;height:16px;border-radius:50%;background:var(--ink);color:var(--bg);
  display:grid;place-items:center;font-size:10px;font-style:normal}
.cover{position:relative;min-height:560px;overflow:hidden}
.cover .ghost{position:absolute;right:6%;top:2%;font-size:clamp(90px,15vw,190px);font-weight:800;
  color:#00000010;letter-spacing:-.04em;line-height:.9;writing-mode:vertical-rl;text-orientation:mixed}
.cover .in{position:relative;z-index:2;max-width:560px;padding:56px 0 40px}
.cover h1{margin:0 0 16px;font-size:clamp(46px,7.6vw,96px);line-height:.92;letter-spacing:-.035em;font-weight:800}
.cover .d{font-size:13.5px;font-weight:700;margin-bottom:14px;max-width:40ch}
.cover p{color:var(--mut);font-size:13px;max-width:46ch;margin:0 0 18px}
.cover .link{display:inline-flex;align-items:center;gap:8px;font-size:12px;color:var(--mut)}
.cover .link img{width:34px;height:22px;object-fit:cover;border-radius:3px}
.sign{font-family:'Caveat',cursive;font-size:44px;margin:6px 0 24px;line-height:1}
.cbtns{display:flex;gap:12px}
.cbtns a{border:1.5px solid var(--ink);border-radius:999px;padding:10px 20px;font-size:12px;font-weight:700}
.cbtns a:first-child{background:var(--ink);color:var(--bg)}
.hero-img{position:absolute;right:0;bottom:0;top:0;width:46%;z-index:1;
  clip-path:polygon(18% 0,100% 0,100% 100%,0 100%)}
.hero-img img{width:100%;height:100%;object-fit:cover;filter:saturate(1.05)}
.rail{position:absolute;right:26px;top:52%;transform:translateY(-50%);z-index:3;display:flex;
  flex-direction:column;gap:11px}
.rail i{width:8px;height:8px;border-radius:50%;background:var(--ink);opacity:.35}
.rail i:first-child{opacity:1}
section.blk{padding:74px 0 0}
.eyebrow{color:var(--mut);font-size:10.5px;letter-spacing:.2em;text-transform:uppercase}
.two{display:grid;grid-template-columns:230px 1fr;gap:36px;align-items:start}
.two h3{margin:0;font-size:clamp(21px,2.5vw,31px);line-height:1.2;letter-spacing:-.025em;font-weight:800}
.two h3 span{color:var(--mut);font-weight:400}
.two p{color:var(--mut);font-size:13px;max-width:62ch;margin:14px 0 0}
.btn{display:inline-flex;align-items:center;gap:9px;background:var(--ink);color:var(--bg);
  border-radius:999px;padding:11px 20px;font-size:13px;margin-top:18px;font-weight:700}
.rot{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:18px;margin-top:28px}
.tr{background:var(--card);border:1.5px solid var(--ink);border-radius:18px;overflow:hidden;cursor:pointer;
  box-shadow:5px 5px 0 var(--ink)}
.tr:hover{transform:translate(-2px,-2px);box-shadow:7px 7px 0 var(--acc)}
.tr img{aspect-ratio:16/9;object-fit:cover;width:100%}
.tr .in{padding:13px 15px 15px}
.tr b{display:block;font-size:13.5px;font-weight:700;line-height:1.3;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;min-height:2.6em}
.tr .m{display:flex;justify-content:space-between;color:var(--mut);font-size:11px;margin-top:8px}
.tr .n{display:none}
.player{margin-top:28px;background:var(--card);border:1.5px solid var(--ink);border-radius:18px;
  padding:16px;display:flex;gap:18px;align-items:center;box-shadow:5px 5px 0 var(--ink)}
.player img{width:170px;aspect-ratio:16/9;object-fit:cover;border-radius:11px;flex:none}
.player .np{flex:1;min-width:0}
.player small{color:var(--mut);font-size:10px;letter-spacing:.18em;text-transform:uppercase}
.player h4{margin:6px 0 2px;font-size:17px;font-weight:800;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.player .ch{color:var(--mut);font-size:12.5px;margin-bottom:12px}
.bar{height:6px;background:var(--bg);border:1.5px solid var(--ink);border-radius:4px;overflow:hidden}
.bar i{display:block;height:100%;width:8%;background:var(--acc)}
.tm{display:flex;justify-content:space-between;color:var(--mut);font-size:11px;margin-top:6px}
.eq{display:flex;gap:3px;align-items:flex-end;height:30px;flex:none}
.eq b{width:4px;background:var(--ink);border-radius:2px;animation:e 1.1s infinite ease-in-out}
.eq b:nth-child(2){animation-delay:.15s}.eq b:nth-child(3){animation-delay:.3s}
.eq b:nth-child(4){animation-delay:.45s}.eq b:nth-child(5){animation-delay:.6s}
@keyframes e{0%,100%{height:7px}50%{height:28px}}
.steps{margin-top:70px}
.step{display:grid;grid-template-columns:270px 1fr;gap:24px;padding:22px 0;border-top:2px solid var(--ink)}
.step img{width:100%;aspect-ratio:4/3;object-fit:cover;border-radius:14px;border:1.5px solid var(--ink)}
.step .n{font-size:30px;font-weight:800}
.step h5{margin:2px 0 10px;font-size:11px;letter-spacing:.18em;text-transform:uppercase;color:var(--mut);font-weight:400}
.step p{margin:0;color:var(--mut);font-size:12.5px;max-width:66ch}
footer{padding:56px 0 36px;color:var(--mut);font-size:11.5px}
footer .wrap{display:flex;gap:22px;flex-wrap:wrap;border-top:2px solid var(--ink);padding-top:20px}
table{width:100%;border-collapse:collapse;font-size:13.5px}
td{padding:11px 0;border-bottom:1px solid var(--line)}
td.k{color:var(--mut);width:150px;font-size:11px;letter-spacing:.1em;text-transform:uppercase}
@media(max-width:900px){.hero-img{display:none}.two,.step{grid-template-columns:1fr}.top nav{display:none}}
CSS
      cover_html() {
        cat <<HTML
<div class="top"><div class="wrap">
  <nav><a href="/">HOME</a><a href="/#rotation">MENU</a><a class="on" href="/archive/">ARCHIVE</a><a href="/about/">ABOUT</a></nav>
  <span class="sep"></span>
  <div class="info">INFO <i>i</i></div>
</div></div>
<section class="cover"><div class="wrap">
  <div class="ghost">$SITE_NAME</div>
  <div class="hero-img"><img src="$HERO" alt=""></div>
  <div class="in">
    <h1>$SITE_NAME</h1>
    <div class="d">$HEADLINE</div>
    <p>$TAGLINE — hand-picked sessions, one continuous stream and an archive that stays online.</p>
    <div class="link"><img src="https://i.ytimg.com/vi/$T2/hqdefault.jpg" alt="">$LABEL</div>
    <div class="sign">$SITE_NAME</div>
    <div class="cbtns"><a href="/#rotation">LISTEN NOW</a><a href="/archive/">OPEN ARCHIVE</a></div>
  </div>
  <div class="rail"><i></i><i></i><i></i><i></i><i></i></div>
</div></section>
HTML
      }
      ;;
    cinema)
      GFONTS="Playfair+Display:wght@400;500&family=Inter:wght@400;500&family=Space+Mono"
      cat > "$WEBROOT/assets/style.css" <<CSS
:root{--bg:$BG;--ink:$FG;--mut:$MUT;--card:$CARD;--line:$LINE;--acc:$ACC;--panel:$PANEL}
*{box-sizing:border-box}
body{margin:0;color:var(--ink);line-height:1.55;font-family:'Inter',system-ui,sans-serif;
  background:var(--bg);-webkit-font-smoothing:antialiased}
a{color:inherit;text-decoration:none}
img{display:block;max-width:100%}
.wrap{max-width:1180px;margin:0 auto;padding:0 32px}
.mono{font-family:'Space Mono',ui-monospace,monospace}
.frame{position:relative;min-height:600px;overflow:hidden;isolation:isolate}
.frame .bg{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;z-index:-2;filter:saturate(.9)}
.frame::after{content:"";position:absolute;inset:0;z-index:-1;
  background:linear-gradient(96deg,$PANEL 0 46%,transparent 62%)}
.top{position:relative;z-index:3}
.top .wrap{display:flex;align-items:center;gap:24px;height:70px;font-size:13px}
.top nav{display:flex;gap:22px}
.top nav a.on{border-bottom:1.5px solid var(--ink)}
.burger{margin-left:auto;width:22px;height:12px;border-top:2px solid var(--ink);border-bottom:2px solid var(--ink)}
.cover{position:relative;z-index:2;padding:36px 0 56px}
.cover .yr{font-family:'Playfair Display',Georgia,serif;font-size:19px;letter-spacing:.02em;margin-bottom:6px}
.cover h1{font-family:'Playfair Display',Georgia,serif;margin:0;font-weight:500;
  font-size:clamp(52px,8.6vw,104px);line-height:.92;letter-spacing:-.01em;max-width:9ch}
.cover .btns{display:flex;align-items:center;gap:22px;margin-top:34px}
.cover .btns a:first-child{background:var(--ink);color:var(--bg);padding:13px 26px;font-size:13px;
  display:inline-flex;align-items:center;gap:9px;font-weight:500}
.cover .btns a:last-child{font-size:13px}
.side{position:absolute;right:32px;top:44%;transform:translateY(-50%);max-width:310px;z-index:3;
  font-size:12.5px;color:var(--ink)}
.side p{margin:0 0 12px;line-height:1.62}
.side b{font-size:12.5px}
.pager{position:absolute;left:0;right:0;bottom:20px;z-index:3;display:flex;justify-content:space-between;
  align-items:center;font-size:13px}
.pager .wrap{display:flex;justify-content:space-between;width:100%}
.pager a{display:inline-flex;align-items:center;gap:11px}
.pager i{width:32px;height:32px;border-radius:50%;border:1.5px solid var(--ink);display:grid;
  place-items:center;font-style:normal;font-size:13px}
section.blk{padding:78px 0 0}
.eyebrow{color:var(--mut);font-size:10.5px;letter-spacing:.2em;text-transform:uppercase}
.two{display:grid;grid-template-columns:240px 1fr;gap:38px;align-items:start}
.two h3{margin:0;font-family:'Playfair Display',Georgia,serif;font-weight:500;
  font-size:clamp(22px,2.7vw,34px);line-height:1.22}
.two h3 span{color:var(--mut)}
.two p{color:var(--mut);font-size:13px;max-width:62ch;margin:14px 0 0}
.btn{display:inline-flex;align-items:center;gap:9px;background:var(--ink);color:var(--bg);
  padding:12px 22px;font-size:13px;margin-top:18px}
.rot{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:20px;margin-top:28px}
.tr{cursor:pointer}
.tr img{aspect-ratio:2/3;object-fit:cover;width:100%;box-shadow:0 12px 32px #0000001f}
.tr .in{padding:12px 2px 0}
.tr b{display:block;font-family:'Playfair Display',Georgia,serif;font-size:16px;font-weight:500;line-height:1.25;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;min-height:2.5em}
.tr .m{display:flex;justify-content:space-between;color:var(--mut);font-size:11px;margin-top:6px}
.tr .n{display:none}
.tr:hover b{color:var(--acc)}
.player{margin-top:30px;background:var(--card);padding:18px;display:flex;gap:20px;align-items:center;
  border:1px solid var(--line)}
.player img{width:126px;aspect-ratio:2/3;object-fit:cover;flex:none}
.player .np{flex:1;min-width:0}
.player small{color:var(--mut);font-size:10px;letter-spacing:.2em;text-transform:uppercase}
.player h4{margin:7px 0 2px;font-family:'Playfair Display',Georgia,serif;font-size:20px;font-weight:500;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.player .ch{color:var(--mut);font-size:12.5px;margin-bottom:13px}
.bar{height:2px;background:var(--line)}
.bar i{display:block;height:100%;width:8%;background:var(--acc)}
.tm{display:flex;justify-content:space-between;color:var(--mut);font-size:11px;margin-top:6px}
.eq{display:flex;gap:3px;align-items:flex-end;height:30px;flex:none}
.eq b{width:3px;background:var(--acc);animation:e 1.1s infinite ease-in-out}
.eq b:nth-child(2){animation-delay:.15s}.eq b:nth-child(3){animation-delay:.3s}
.eq b:nth-child(4){animation-delay:.45s}.eq b:nth-child(5){animation-delay:.6s}
@keyframes e{0%,100%{height:7px}50%{height:28px}}
.steps{margin-top:74px}
.step{display:grid;grid-template-columns:280px 1fr;gap:26px;padding:24px 0;border-top:1px solid var(--line)}
.step img{width:100%;aspect-ratio:16/10;object-fit:cover}
.step .n{font-family:'Playfair Display',Georgia,serif;font-size:32px}
.step h5{margin:2px 0 10px;font-size:11px;letter-spacing:.18em;text-transform:uppercase;color:var(--mut);font-weight:400}
.step p{margin:0;color:var(--mut);font-size:12.5px;max-width:66ch}
footer{padding:60px 0 40px;color:var(--mut);font-size:11.5px}
footer .wrap{display:flex;gap:22px;flex-wrap:wrap;border-top:1px solid var(--line);padding-top:22px}
table{width:100%;border-collapse:collapse;font-size:13.5px}
td{padding:11px 0;border-bottom:1px solid var(--line)}
td.k{color:var(--mut);width:150px;font-size:11px;letter-spacing:.1em;text-transform:uppercase}
@media(max-width:900px){.side{position:static;max-width:none;margin-top:26px}
  .two,.step{grid-template-columns:1fr}.top nav{display:none}}
CSS
      cover_html() {
        cat <<HTML
<section class="frame">
  <img class="bg" src="$HERO" alt="">
  <div class="top"><div class="wrap">
    <nav><a href="/about/">About</a><a class="on" href="/#rotation">Selection</a><a href="/archive/">Archive</a></nav>
    <span class="burger"></span>
  </div></div>
  <div class="cover"><div class="wrap">
    <div class="yr">$YEAR</div>
    <h1>$SITE_NAME</h1>
    <div class="btns"><a href="/#rotation">&#9654; START THE STREAM</a><a href="/archive/">ARCHIVE</a></div>
  </div></div>
  <div class="side">
    <p>$TAGLINE. $HEADLINE</p>
    <p><b>Now playing:</b> $F_TIT</p>
  </div>
  <div class="pager"><div class="wrap">
    <a href="/archive/"><i>&#8592;</i> $PREV</a>
    <a href="/#rotation">$NEXT <i>&#8594;</i></a>
  </div></div>
</section>
HTML
      }
      ;;
  esac

  head_html() {
    cat <<HTML
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$1 — $SITE_NAME</title>
<meta name="description" content="$SITE_NAME — $TAGLINE">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=$GFONTS&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/assets/style.css">
</head><body>
HTML
  }
  foot_html() {
    cat <<HTML
<footer><div class="wrap">
  <span>© $YEAR $SITE_NAME</span>
  <span class="mono">$LABEL</span>
  <span class="mono">listens today: <b data-listens>1</b></span>
  <span class="mono">since $((YEAR-4))</span>
</div></footer>
<script src="/assets/app.js"></script>
</body></html>
HTML
  }
  cards_html() {
    n=0
    printf '%s\n' "$TRACKS" | while IFS='|' read -r id title chan len; do
      [ -z "$id" ] && continue
      n=$((n+1))
      printf '  <article class="tr" data-t="%s" data-c="%s" data-l="%s">' "$title" "$chan" "$len"
      printf '<span class="n">%02d</span>' "$n"
      printf '<img src="https://i.ytimg.com/vi/%s/hqdefault.jpg" alt="" loading="lazy">' "$id"
      printf '<div class="in"><b>%s</b><div class="m"><span class="c">%s</span><span class="mono l">%s</span></div>' "$title" "$chan" "$len"
      printf '<div class="dots"><i></i><i></i><i></i><i></i></div></div></article>\n'
    done
  }

  cat > "$WEBROOT/assets/app.js" <<'JS'
(function () {
  var bar = document.querySelector('.bar i'), cur = document.querySelector('[data-cur]');
  var tot = document.querySelector('[data-tot]'), ttl = document.querySelector('[data-np]');
  var ch = document.querySelector('[data-ch]'), art = document.querySelector('[data-art]');
  var pos = 8, len = 3600;
  function secs(t) {
    var p = t.split(':').map(Number);
    return p.length === 3 ? p[0] * 3600 + p[1] * 60 + p[2] : p[0] * 60 + (p[1] || 0);
  }
  function fmt(s) {
    var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), r = Math.floor(s % 60);
    return (h ? h + ':' : '') + ((m < 10 && h ? '0' : '') + m) + ':' + ((r < 10 ? '0' : '') + r);
  }
  if (tot) len = secs(tot.textContent);
  setInterval(function () {
    pos = (pos + 0.08) % 100;
    if (bar) bar.style.width = pos.toFixed(2) + '%';
    if (cur) cur.textContent = fmt(len * pos / 100);
  }, 500);
  document.querySelectorAll('.tr').forEach(function (c) {
    c.addEventListener('click', function () {
      if (ttl) ttl.textContent = c.getAttribute('data-t');
      if (ch) ch.textContent = c.getAttribute('data-c');
      if (art) art.src = c.querySelector('img').src;
      if (tot) { tot.textContent = c.getAttribute('data-l'); len = secs(tot.textContent); }
      pos = 0;
      window.scrollTo({ top: 0, behavior: 'smooth' });
    });
  });
  try {
    var k = 'l_' + new Date().toISOString().slice(0, 10);
    var n = parseInt(localStorage.getItem(k) || '0', 10) + 1;
    localStorage.setItem(k, String(n));
    var el = document.querySelector('[data-listens]');
    if (el) el.textContent = n.toLocaleString('en-US');
  } catch (e) {}
})();
JS

  player_html() {
    cat <<HTML
  <div class="player">
    <img src="https://i.ytimg.com/vi/$F_ID/hqdefault.jpg" alt="" data-art>
    <div class="np">
      <small>now playing</small>
      <h4 data-np>$F_TIT</h4>
      <div class="ch" data-ch>$F_CH</div>
      <div class="bar"><i></i></div>
      <div class="tm"><span data-cur>0:00</span><span data-tot>$F_LEN</span></div>
    </div>
    <div class="eq" aria-hidden="true"><b></b><b></b><b></b><b></b><b></b></div>
  </div>
HTML
  }

  {
    head_html "$TAGLINE"
    cover_html
    cat <<HTML
<section class="blk"><div class="wrap">
  <div class="two">
    <div class="eyebrow">◆ WHAT THIS IS</div>
    <div>
      <h3>A small room for $LABEL. <span>Long-form only, picked by hand and left to run.</span></h3>
      <p>No recommendations, no autoplay traps, no sign-up. The selection below is what is on air right now; everything that aired before stays in the archive.</p>
      <a class="btn" href="/archive/">Open archive <b>&#8594;</b></a>
    </div>
  </div>
HTML
    player_html
    cat <<HTML
</div></section>

<section class="blk" id="rotation"><div class="wrap">
  <div class="two">
    <div class="eyebrow">◆ CURRENT SELECTION</div>
    <div><h3>Everything on air this week. <span>Click an entry to move it to the player.</span></h3></div>
  </div>
  <div class="rot">
HTML
    cards_html
    cat <<HTML
  </div>
</div></section>

<section class="steps"><div class="wrap">
  <div class="two">
    <div class="eyebrow">◆ HOW IT GETS ON AIR</div>
    <div><h3>Three steps, no algorithm. <span>Anyone can send something in; we go through all of it.</span></h3></div>
  </div>
  <div class="step">
    <img src="https://i.ytimg.com/vi/$F_ID/hqdefault.jpg" alt="">
    <div class="in"><div class="n">01</div><h5>You send a link</h5>
    <p>Anything long enough to sit with. Nothing is filtered by view count.</p></div>
  </div>
  <div class="step">
    <img src="https://i.ytimg.com/vi/$T2/hqdefault.jpg" alt="">
    <div class="in"><div class="n">02</div><h5>We go through it end to end</h5>
    <p>Every submission gets played in full. If it fits the room, it joins the queue.</p></div>
  </div>
  <div class="step">
    <img src="https://i.ytimg.com/vi/$T3/hqdefault.jpg" alt="">
    <div class="in"><div class="n">03</div><h5>It goes on air</h5>
    <p>It joins the stream and stays in the archive afterwards, credit intact.</p></div>
  </div>
</div></section>
HTML
    foot_html
  } > "$WEBROOT/index.html"

  {
    head_html "archive"; cover_html
    cat <<HTML
<section class="blk"><div class="wrap">
  <div class="two">
    <div class="eyebrow">◆ ARCHIVE</div>
    <div><h3>Everything that aired. <span>Older entries are kept exactly as they were.</span></h3></div>
  </div>
  <div class="rot">
HTML
    cards_html
    cat <<HTML
  </div>
</div></section>
HTML
    foot_html
  } > "$WEBROOT/archive/index.html"

  {
    head_html "about"; cover_html
    cat <<HTML
<section class="blk"><div class="wrap">
  <div class="two">
    <div class="eyebrow">◆ ABOUT</div>
    <div>
      <h3>Started as a folder of links. <span>Now it runs on its own and nobody deletes the archive.</span></h3>
      <p>$SITE_NAME is about $LABEL. No ads, no accounts, no recommendations. Credit stays with the people who made the work.</p>
    </div>
  </div>
  <div class="two" style="margin-top:56px">
    <div class="eyebrow">◆ CONTACT</div>
    <div><table>
      <tr><td class="k">submissions</td><td>demo@$DOMAIN</td></tr>
      <tr><td class="k">general</td><td>hi@$DOMAIN</td></tr>
      <tr><td class="k">selection</td><td>updated weekly</td></tr>
    </table></div>
  </div>
</div></section>
HTML
    foot_html
  } > "$WEBROOT/about/index.html"

  cat > "$WEBROOT/favicon.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="$BG"/><circle cx="32" cy="32" r="13" fill="$ACC"/></svg>
SVG
  printf 'User-agent: *\nAllow: /\nDisallow: /admin/\nSitemap: https://%s/sitemap.xml\n' "$DOMAIN" > "$WEBROOT/robots.txt"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    for u in "/" "/archive/" "/about/"; do printf '  <url><loc>https://%s%s</loc></url>\n' "$DOMAIN" "$u"; done
    printf '%s\n' '</urlset>'
  } > "$WEBROOT/sitemap.xml"

  chown -R root:root "$WEBROOT" 2>/dev/null; chmod -R a+rX "$WEBROOT" 2>/dev/null
  SITE_THEME="$PRESET"
  ok "сайт «$SITE_NAME» ($PRESET: $LAYOUT / $TOPIC) собран: $N_TRACKS записей с обложками"
fi

# =============================================================================
step "9/14  nginx"
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
step "10/14  Нода Remnawave"
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
step "11/14  Проверка"
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

  # видно ли, что сертификат продлится сам
  RC="/etc/letsencrypt/renewal/$DOMAIN.conf"
  R_AUTH="$(grep -m1 "^authenticator" "$RC" 2>/dev/null | sed "s/.*= *//")"
  R_TIMER="$(systemctl is-active certbot.timer 2>/dev/null)"
  if [ "$R_TIMER" = "active" ] || [ -f /etc/cron.d/certbot ]; then
    ok "автопродление сертификата: способ ${R_AUTH:-?}, таймер ${R_TIMER:-cron}"
  else
    err "автопродление сертификата не настроено (способ ${R_AUTH:-?}, таймер ${R_TIMER:-нет})"
  fi

  CERT_TILL="$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2)"
  [ -n "$CERT_TILL" ] && ok "сертификат $DOMAIN годен до $CERT_TILL"

  # заглушку отдаёт не nginx напрямую, а Xray по правилам инбаунда из панели.
  # Сверяем их: чаще всего сайт «не появляется» именно из-за настроек панели
  check_panel_inbound
fi

# =============================================================================
step "12/14  TrafficGuard"
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
step "13/14  WARP"
# =============================================================================
install_warp

# =============================================================================
step "14/14  Отчёт при входе"
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
if ip link show warp >/dev/null 2>&1; then
  say "  WARP        : поднят, outbound для панели в $INSTALL_DIR/warp-outbound.json"
else
  say "  WARP        : не поднят"
fi
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
