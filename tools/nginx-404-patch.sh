#!/bin/bash
# Переводит заглушку уже настроенной ноды на поведение node-setup 4.6:
#   * чужой SNI и заход по IP — сертификат ноды и 404 вместо обрыва рукопожатия;
#   * несуществующий путь на домене — 404 вместо главной страницы;
#   * :80 — редирект в https только своим доменам, по IP — 404.
# Правит /opt/remnanode/nginx.conf на месте (файл смонтирован в контейнер
# одиночным bind mount — менять содержимое, не подменять файл), перед reload
# проверяет nginx -t и при ошибке возвращает прежний файл. Повторный запуск
# ничего не меняет.
#   nginx-404-patch.sh          применить
#   nginx-404-patch.sh --dry    показать, что изменится
set -u
CONF=/opt/remnanode/nginx.conf
DRY=0; [ "${1:-}" = "--dry" ] && DRY=1
[ -f "$CONF" ] || { echo "SKIP: нет $CONF"; exit 0; }
docker ps --format '{{.Names}}' | grep -qx remnawave-nginx || { echo "SKIP: нет контейнера remnawave-nginx"; exit 0; }

NEW=$(mktemp)
NOTES=$(python3 - "$CONF" "$NEW" <<'EOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
conf = open(src, encoding="utf-8").read()
orig, notes = conf, []

n = conf.count("try_files $uri $uri/ /index.html;")
conf = conf.replace("try_files $uri $uri/ /index.html;", "try_files $uri $uri/ =404;")
if n:
    notes.append(f"несуществующие пути → 404 ({n} блок.)")

m = re.search(r"ssl_certificate\s+/etc/letsencrypt/live/([^/\s]+)/fullchain\.pem;", conf)
dom = m.group(1) if m else None
reject = re.compile(r"server \{\n(?P<ind>[ \t]+)listen (?P<listen>[^\n;]+?) default_server;\n[ \t]+server_name _;\n"
                    r"[ \t]+ssl_reject_handshake on;\n[ \t]+return 444;\n\}")
if dom:
    def repl(mm):
        i = mm.group("ind")
        return (f"server {{\n{i}listen {mm.group('listen')} default_server;\n{i}server_name _;\n"
                f"{i}ssl_certificate     /etc/letsencrypt/live/{dom}/fullchain.pem;\n"
                f"{i}ssl_certificate_key /etc/letsencrypt/live/{dom}/privkey.pem;\n{i}return 404;\n}}")
    conf, k = reject.subn(repl, conf)
    if k:
        notes.append(f"чужой SNI/IP → сертификат {dom} и 404 ({k} блок.)")
elif reject.search(conf):
    notes.append("сертификатов в конфиге нет — обрыв по IP оставлен")

p80 = re.compile(r"server \{\n(?P<ind>[ \t]+)listen 0\.0\.0\.0:80 default_server;\n[ \t]+server_name (?P<names>[^\n;]*?) _;\n"
                 r"(?P<body>(?:.*\n)*?)\}")
mm = p80.search(conf)
if mm and "return 301" in mm.group("body"):
    i = mm.group("ind")
    acme = (f"{i}location ^~ /.well-known/acme-challenge/ {{\n{i}    root /var/www/certbot;\n"
            f"{i}    default_type text/plain;\n{i}}}\n")
    new = (f"server {{\n{i}listen 0.0.0.0:80;\n{i}server_name {mm.group('names')};\n{mm.group('body')}}}\n\n"
           f"server {{\n{i}listen 0.0.0.0:80 default_server;\n{i}server_name _;\n\n{acme}\n"
           f"{i}location / {{\n{i}    return 404;\n{i}}}\n}}")
    conf = conf[:mm.start()] + new + conf[mm.end():]
    notes.append(":80 по IP → 404, своим доменам редирект")

open(dst, "w", encoding="utf-8").write(conf)
print("; ".join(notes) if conf != orig else "")
EOF
) || { rm -f "$NEW"; echo "FAIL: разбор конфига"; exit 1; }

if cmp -s "$CONF" "$NEW"; then rm -f "$NEW"; echo "OK: уже в новом виде, без изменений"; exit 0; fi
if [ "$DRY" = 1 ]; then echo "DRY: $NOTES"; diff -u "$CONF" "$NEW" | head -80; rm -f "$NEW"; exit 0; fi

BAK="$CONF.bak-404-$(date +%Y%m%d-%H%M%S)"
cp -a "$CONF" "$BAK"
cat "$NEW" > "$CONF"; rm -f "$NEW"
if ! docker exec remnawave-nginx nginx -t >/tmp/.ngt 2>&1; then
  cat "$BAK" > "$CONF"
  echo "FAIL: nginx -t не прошёл, файл возвращён из $BAK"; tail -3 /tmp/.ngt; rm -f /tmp/.ngt; exit 1
fi
rm -f /tmp/.ngt
docker exec remnawave-nginx nginx -s reload >/dev/null 2>&1
echo "OK: $NOTES; бэкап $BAK"
