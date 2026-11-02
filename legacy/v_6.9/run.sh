#!/bin/bash
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$RUN_DIR/scripts/configure_wordpress_custom_ini.sh"
"$RUN_DIR/scripts/configure_wordpress_fpm_conf.sh"
"$RUN_DIR/scripts/configure_nginx_overrides.sh"

nginx -t

_shutdown() {
    echo "[run] Signal received — shutting down"
    [ -n "${NGINX_PID:-}"     ] && kill -TERM "$NGINX_PID"     2>/dev/null || true
    [ -n "${NGINX_EXP_PID:-}" ] && kill -TERM "$NGINX_EXP_PID" 2>/dev/null || true
    [ -n "${FPM_EXP_PID:-}"   ] && kill -TERM "$FPM_EXP_PID"   2>/dev/null || true
    [ -n "${FPM_PID:-}"       ] && kill -TERM "$FPM_PID"        2>/dev/null || true
    wait 2>/dev/null || true
    exit 0
}
trap _shutdown TERM INT

nginx -g 'daemon off;' &
NGINX_PID=$!

nginx-prometheus-exporter \
    --nginx.scrape-uri="http://127.0.0.1:8080/nginx_status" \
    --web.listen-address=":9113" &
NGINX_EXP_PID=$!

php-fpm_exporter server \
    --phpfpm.scrape-uri="tcp://127.0.0.1:9000/fpm-status" \
    --web.listen-address=":9253" &
FPM_EXP_PID=$!

docker-entrypoint.sh php-fpm &
FPM_PID=$!

# Exit as soon as nginx or php-fpm dies — triggers _shutdown for the rest.
wait -n "$NGINX_PID" "$FPM_PID" 2>/dev/null || true
_shutdown
