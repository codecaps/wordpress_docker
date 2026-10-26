#!/bin/bash
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/run/wp-runtime"

# State shared with PHP (cache token, cron heartbeat): readable by www-data only.
mkdir -p "$STATE_DIR"
chown root:www-data "$STATE_DIR"
chmod 750 "$STATE_DIR"

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
wp_cron_trigger_enabled="${WP_CRON_TRIGGER_ENABLED:-true}"

# Validation matches validated_positive_int() in scripts/lib/runtime_env.sh (min 1, fallback on
# anything non-numeric). Without it, a bad value makes `sleep` fail: under `set -e` that would
# silently kill the loop for good (0 would instead spin it tight enough to exhaust FPM workers).
wp_cron_trigger_interval="${WP_CRON_TRIGGER_INTERVAL_SECONDS:-60}"
if ! [[ "$wp_cron_trigger_interval" =~ ^[0-9]+$ ]] || [ "$wp_cron_trigger_interval" -lt 1 ]; then
    echo "[wp-cron-trigger] Invalid WP_CRON_TRIGGER_INTERVAL_SECONDS value '${wp_cron_trigger_interval}'. Falling back to 60." >&2
    wp_cron_trigger_interval=60
fi
echo "[run]   wp_cron_trigger_enabled=${wp_cron_trigger_enabled}, wp_cron_trigger_interval_seconds=${wp_cron_trigger_interval}"

if [[ "${wp_cron_trigger_enabled,,}" =~ ^(true|1|yes|on)$ ]]; then
    echo "[wp-cron-trigger] internal trigger loop starting (interval=${wp_cron_trigger_interval}s)"
    (
        # Deliberately not strict: this loop must survive for the life of the container on
        # nothing but a validated interval, a curl call whose failure is handled below, and a
        # `sleep` that can only be interrupted by the TERM trap.
        set +e
        trap 'kill -TERM "${SLEEP_PID:-}" 2>/dev/null; exit 0' TERM
        # Written on every successful trigger; read by wp-metrics.php as
        # wp_cron_trigger_last_success_timestamp_seconds.
        wp_cron_trigger_heartbeat_file="/var/run/wp-cron-trigger-last-success"
        last_heartbeat_log=0
        # nginx was started a moment ago; give it a beat before the first trigger.
        sleep 2
        while true; do
            # wp-cron.php calls fastcgi_finish_request() and closes the connection before doing
            # any real work, so this returns in milliseconds regardless of how long the cron
            # callbacks run afterwards in the detached FPM worker.
            if curl -fsS --max-time 30 -H "Host: 127.0.0.1" \
                    "http://127.0.0.1/wp-cron.php?doing_wp_cron" >/dev/null; then
                now=$(date +%s)
                printf '%s\n' "$now" > "$wp_cron_trigger_heartbeat_file" 2>/dev/null \
                    && chmod 644 "$wp_cron_trigger_heartbeat_file" 2>/dev/null
                # Log on success too, but throttled to hourly.
                if [ $(( now - last_heartbeat_log )) -ge 3600 ]; then
                    echo "[wp-cron-trigger] heartbeat: trigger succeeded at $(date -u +%FT%TZ)"
                    last_heartbeat_log=$now
                fi
            else
                echo "[wp-cron-trigger] trigger failed" >&2
            fi
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
