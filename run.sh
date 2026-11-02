#!/bin/bash
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/run/wp-runtime"

# State shared with PHP (cache token, cron heartbeat): readable by www-data only.
mkdir -p "$STATE_DIR"
chown root:www-data "$STATE_DIR"
chmod 750 "$STATE_DIR"

# The cron heartbeat: written by PHP (runtime/prepend.php) each time WordPress's cron dispatcher
# really runs, read by wp-metrics.php. www-data may write this one file, not the directory.
CRON_HEARTBEAT_FILE="$STATE_DIR/cron-last-run"
: > "$CRON_HEARTBEAT_FILE"
chown www-data:www-data "$CRON_HEARTBEAT_FILE"
chmod 644 "$CRON_HEARTBEAT_FILE"

# Size PHP, PHP-FPM and nginx to this container's cgroup limits once, export the result for the
# configure scripts below (and, through php-fpm's clear_env=no, to PHP: wp-metrics reports it),
# and log it so the effective sizing is visible on every boot.
# shellcheck source=./scripts/lib/resource_sizing.sh
source "$RUN_DIR/scripts/lib/resource_sizing.sh"
resource_sizing_load
resource_sizing_log

"$RUN_DIR/scripts/configure_wordpress_custom_ini.sh"
"$RUN_DIR/scripts/configure_wordpress_fpm_conf.sh"
"$RUN_DIR/scripts/configure_nginx_overrides.sh"

# Validate the generated config. A broken NGINX_EXTRA_CONF must not take the site down: drop the
# fragment, say so loudly, and run without it.
if ! nginx -t 2>"$STATE_DIR/nginx-t.log"; then
    cat "$STATE_DIR/nginx-t.log" >&2
    if [ -n "${NGINX_EXTRA_CONF:-}" ]; then
        echo "[run] ERROR: nginx rejected the configuration. Disabling NGINX_EXTRA_CONF and retrying; fix the fragment and redeploy." >&2
        printf '# NGINX_EXTRA_CONF was rejected by nginx -t at startup and is disabled. See the container logs.\n' \
            > /etc/nginx/conf.d/generated_extra.conf
        nginx -t
    else
        exit 1
    fi
fi

# Stops every child gracefully, then exits with $1 (default 0: a signal-initiated shutdown is clean).
# nginx and php-fpm get QUIT (finish in-flight requests; FPM honours process_control_timeout),
# bounded by SHUTDOWN_TIMEOUT_SECONDS, then TERM/KILL for anything still alive.
_shutdown() {
    local status="${1:-0}" deadline pid
    echo "[run] Shutting down (exit ${status})"
    trap - TERM INT QUIT
    [ -n "${CRON_LOOP_PID:-}" ] && kill -TERM "$CRON_LOOP_PID" 2>/dev/null || true
    [ -n "${NGINX_PID:-}"     ] && kill -QUIT "$NGINX_PID"     2>/dev/null || true
    [ -n "${FPM_PID:-}"       ] && kill -QUIT "$FPM_PID"       2>/dev/null || true
    [ -n "${NGINX_EXP_PID:-}" ] && kill -TERM "$NGINX_EXP_PID" 2>/dev/null || true
    [ -n "${FPM_EXP_PID:-}"   ] && kill -TERM "$FPM_EXP_PID"   2>/dev/null || true

    deadline=$(( SECONDS + ${SHUTDOWN_TIMEOUT_SECONDS:-20} ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! kill -0 "${NGINX_PID:-0}" 2>/dev/null && ! kill -0 "${FPM_PID:-0}" 2>/dev/null; then
            break
        fi
        sleep 0.2
    done
    for pid in "${NGINX_PID:-}" "${FPM_PID:-}" "${NGINX_EXP_PID:-}" "${FPM_EXP_PID:-}" "${CRON_LOOP_PID:-}"; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "[run] $pid did not stop in time; terminating" >&2; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null; } || true
    done
    wait 2>/dev/null || true
    exit "$status"
}
# The upstream image's STOPSIGNAL is QUIT; the Dockerfile sets TERM. Handle all of them.
trap '_shutdown 0' TERM INT QUIT

# Startup order. nginx comes up first so the pod's TCP probes pass and visitors get a 503 "starting
# up" page (default.conf, flag file below) instead of connection refused; php-fpm starts next, and
# on a first boot the upstream entrypoint copies WordPress core onto the (network) volume before it
# listens, which can take a minute. The flag is removed the moment FPM listens; until then every
# request, /healthz included, is a 503 with Retry-After, so HTTP probes stay honest.
STARTING_FLAG="$STATE_DIR/starting"
touch "$STARTING_FLAG"

nginx -g 'daemon off;' &
NGINX_PID=$!

docker-entrypoint.sh php-fpm &
FPM_PID=$!

fpm_listening() {
    # 0100007F:2328 = 127.0.0.1:9000, state 0A = LISTEN
    grep -qE '^\s*[0-9]+: 0100007F:2328 0{8}:0000 0A ' /proc/net/tcp 2>/dev/null
}
echo "[run] waiting for php-fpm on 127.0.0.1:9000 (serving the starting page meanwhile)"
fpm_wait_started=$SECONDS
until fpm_listening; do
    if ! kill -0 "$FPM_PID" 2>/dev/null; then
        wait "$FPM_PID" || status=$?
        echo "[run] php-fpm exited during startup (status ${status:-?})" >&2
        _shutdown "${status:-1}"
    fi
    if [ $(( SECONDS - fpm_wait_started )) -ge "${FPM_STARTUP_TIMEOUT_SECONDS:-600}" ]; then
        echo "[run] php-fpm is not listening after ${FPM_STARTUP_TIMEOUT_SECONDS:-600}s; removing the starting page anyway" >&2
        break
    fi
    sleep 0.5
done
rm -f "$STARTING_FLAG"
echo "[run] php-fpm ready after $(( SECONDS - fpm_wait_started ))s"

# The exporters need no privileges: run them as www-data.
setpriv --reuid=www-data --regid=www-data --clear-groups \
    nginx-prometheus-exporter \
    --nginx.scrape-uri="http://127.0.0.1:8080/nginx_status" \
    --web.listen-address=":9113" &
NGINX_EXP_PID=$!

setpriv --reuid=www-data --regid=www-data --clear-groups \
    php-fpm_exporter server \
    --phpfpm.scrape-uri="tcp://127.0.0.1:9000/fpm-status" \
    --web.listen-address=":9253" &
FPM_EXP_PID=$!

# Internal wp-cron trigger loop. wp-cron.php is restricted to 127.0.0.1 by nginx
# (DISABLE_PUBLIC_WP_CRON), and the platform prepend defines DISABLE_WP_CRON so WordPress's own
# page-load spawner (which self-requests the public URL and would be refused) stays quiet — this
# loop is what runs cron. On by default; set WP_CRON_TRIGGER_ENABLED=false only if the capsule
# triggers cron some other way. Tune the interval with WP_CRON_TRIGGER_INTERVAL_SECONDS
# (default 60: WooCommerce's Action Scheduler and most schedulers expect a minute).
#
# Each run triggers every site WordPress reports (its own host, path and scheme, so multisite
# networks and HTTPS-only sites run their cron), at most WP_CRON_TRIGGER_SITES_PER_RUN of them
# (default 3, rotating through a larger network); the list is refreshed every
# WP_CRON_TRIGGER_TARGETS_REFRESH_SECONDS (default 3600). See scripts/lib/wp_cron_trigger.sh.
wp_cron_trigger_enabled="${WP_CRON_TRIGGER_ENABLED:-true}"

# Validation matches validated_positive_int() in scripts/lib/runtime_env.sh (min 1, fallback on
# anything non-numeric). Without it, a bad value makes `sleep` fail: under `set -e` that would
# silently kill the loop for good (0 would instead spin it tight enough to exhaust FPM workers).
_wp_cron_positive_int() {
    local name="$1" value="$2" fallback="$3"
    if [[ "$value" =~ ^[0-9]{1,9}$ ]] && [ "$value" -ge 1 ]; then
        echo "$value"
        return
    fi
    echo "[wp-cron-trigger] Invalid ${name} value '${value}'. Falling back to ${fallback}." >&2
    echo "$fallback"
}
wp_cron_trigger_interval="$(_wp_cron_positive_int WP_CRON_TRIGGER_INTERVAL_SECONDS "${WP_CRON_TRIGGER_INTERVAL_SECONDS:-60}" 60)"
wp_cron_trigger_sites_per_run="$(_wp_cron_positive_int WP_CRON_TRIGGER_SITES_PER_RUN "${WP_CRON_TRIGGER_SITES_PER_RUN:-3}" 3)"
wp_cron_trigger_refresh="$(_wp_cron_positive_int WP_CRON_TRIGGER_TARGETS_REFRESH_SECONDS "${WP_CRON_TRIGGER_TARGETS_REFRESH_SECONDS:-3600}" 3600)"
echo "[run]   wp_cron_trigger_enabled=${wp_cron_trigger_enabled}, wp_cron_trigger_interval_seconds=${wp_cron_trigger_interval}, sites_per_run=${wp_cron_trigger_sites_per_run}"

if [[ "${wp_cron_trigger_enabled,,}" =~ ^(true|1|yes|on)$ ]]; then
    echo "[wp-cron-trigger] internal trigger loop starting (interval=${wp_cron_trigger_interval}s)"
    (
        # Deliberately not strict: this loop must survive for the life of the container on
        # nothing but validated numbers, WP-CLI and curl calls whose failures are handled below,
        # and a `sleep` that can only be interrupted by the TERM trap.
        set +e
        trap 'kill -TERM "${SLEEP_PID:-}" 2>/dev/null; exit 0' TERM
        # shellcheck source=./scripts/lib/wp_cron_trigger.sh
        source "$RUN_DIR/scripts/lib/wp_cron_trigger.sh"
        WP_CRON_TRIGGER_TARGETS=()
        WP_CRON_TRIGGER_EXPIRES=0
        offset=0
        logged_targets=""
        # nginx was started a moment ago; give it a beat before the first trigger.
        sleep 2
        while true; do
            wp_cron_trigger_refresh "$(date +%s)" "$wp_cron_trigger_refresh"
            n="${#WP_CRON_TRIGGER_TARGETS[@]}"
            if [ "${WP_CRON_TRIGGER_TARGETS[*]}" != "$logged_targets" ]; then
                logged_targets="${WP_CRON_TRIGGER_TARGETS[*]}"
                if [ "$WP_CRON_TRIGGER_FALLBACK" = 1 ]; then
                    echo "[wp-cron-trigger] WordPress did not report its site URLs (not installed yet, or the database is unreachable); triggering http://127.0.0.1/ and asking again within 5 minutes"
                else
                    shown=""
                    for (( i = 0; i < n && i < 5; i++ )); do
                        shown="${shown} $(wp_cron_trigger_url "${WP_CRON_TRIGGER_TARGETS[$i]}")"
                    done
                    [ "$n" -gt 5 ] && shown="${shown} (+$(( n - 5 )) more)"
                    echo "[wp-cron-trigger] ${n} site(s), up to ${wp_cron_trigger_sites_per_run} per run:${shown}"
                fi
            fi
            # wp-cron.php calls fastcgi_finish_request() and closes the connection before doing
            # any real work, so each request returns in milliseconds regardless of how long the
            # cron callbacks run afterwards in the detached FPM worker. Its status only says nginx
            # and PHP-FPM took the request; the heartbeat says whether cron ran.
            for i in $(wp_cron_trigger_batch "$n" "$wp_cron_trigger_sites_per_run" "$offset"); do
                if ! wp_cron_trigger_fire "${WP_CRON_TRIGGER_TARGETS[$i]}"; then
                    echo "[wp-cron-trigger] trigger failed for $(wp_cron_trigger_url "${WP_CRON_TRIGGER_TARGETS[$i]}")" >&2
                fi
            done
            [ "$n" -gt 0 ] && offset=$(( (offset + wp_cron_trigger_sites_per_run) % n ))
            sleep "$wp_cron_trigger_interval" &
            SLEEP_PID=$!
            wait "$SLEEP_PID"
        done
    ) &
    CRON_LOOP_PID=$!
fi

echo "[run] nginx and php-fpm are up"

# Exit as soon as nginx or php-fpm dies — triggers _shutdown for the rest. Either one dying is
# a failure, so exit non-zero even if it exited cleanly (Kubernetes then reports the crash).
died_status=0
wait -n "$NGINX_PID" "$FPM_PID" 2>/dev/null || died_status=$?
echo "[run] nginx or php-fpm exited (status ${died_status})" >&2
[ "$died_status" -eq 0 ] && died_status=1
_shutdown "$died_status"
