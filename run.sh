#!/bin/bash
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$RUN_DIR/scripts/configure_wordpress_custom_ini.sh"
"$RUN_DIR/scripts/configure_wordpress_fpm_conf.sh"
"$RUN_DIR/scripts/configure_nginx_overrides.sh"

nginx -t

_shutdown() {
    echo "[run] Signal received — shutting down"
    [ -n "${NGINX_PID:-}"      ] && kill -TERM "$NGINX_PID"      2>/dev/null || true
    [ -n "${NGINX_EXP_PID:-}"  ] && kill -TERM "$NGINX_EXP_PID"  2>/dev/null || true
    [ -n "${FPM_EXP_PID:-}"    ] && kill -TERM "$FPM_EXP_PID"    2>/dev/null || true
    [ -n "${CRON_LOOP_PID:-}"  ] && kill -TERM "$CRON_LOOP_PID"  2>/dev/null || true
    [ -n "${FPM_PID:-}"        ] && kill -TERM "$FPM_PID"        2>/dev/null || true
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

# Internal wp-cron trigger loop. wp-cron.php is restricted to 127.0.0.1 by
# nginx (DISABLE_PUBLIC_WP_CRON), so WordPress's own page-load-triggered
# pseudo-cron (which self-requests the public site URL) can never reach it —
# this loop calls it from inside the container instead, on the loopback
# interface nginx already trusts. On by default: with public wp-cron.php
# blocked, nothing else runs cron for these capsules. Set
# WP_CRON_TRIGGER_ENABLED=false to turn it off (e.g. a capsule with its own
# external trigger). Tune the interval with WP_CRON_TRIGGER_INTERVAL_SECONDS.
wp_cron_trigger_enabled="${WP_CRON_TRIGGER_ENABLED:-true}"

# Resolved and logged unconditionally (same shape as the "Generated
# overrides:" summary in configure_nginx_overrides.sh) so it's visible on
# every boot whether the loop ends up running or not — without this, "the env
# var wasn't set the way I think it was" and "it's set correctly but not
# doing anything yet" are indistinguishable from the logs alone.
#
# Validation matches validated_positive_int() in configure_nginx_overrides.sh
# (min 1, fallback on anything non-numeric) — kept inline since this script
# isn't sourced alongside that one. Without it, a bad value makes `sleep`
# fail: under `set -e` that would silently kill the loop for good (0 would
# instead spin it tight enough to exhaust FPM workers), which is exactly the
# kind of silent cron failure this loop exists to fix in the first place.
wp_cron_trigger_interval="${WP_CRON_TRIGGER_INTERVAL_SECONDS:-300}"
if ! [[ "$wp_cron_trigger_interval" =~ ^[0-9]+$ ]] || [ "$wp_cron_trigger_interval" -lt 1 ]; then
    echo "[wp-cron-trigger] Invalid WP_CRON_TRIGGER_INTERVAL_SECONDS value '${wp_cron_trigger_interval}'. Falling back to 300." >&2
    wp_cron_trigger_interval=300
fi
echo "[run]   wp_cron_trigger_enabled=${wp_cron_trigger_enabled}, wp_cron_trigger_interval_seconds=${wp_cron_trigger_interval}"

if [[ "${wp_cron_trigger_enabled,,}" =~ ^(true|1|yes|on)$ ]]; then
    # Unthrottled, one-time: the only positive confirmation on boot that this
    # feature is actually on, independent of whether the first HTTP trigger
    # succeeds — without it, "enabled but no logs yet" and "not enabled at
    # all" look identical until the (throttled) heartbeat below eventually
    # fires.
    echo "[wp-cron-trigger] internal trigger loop starting (interval=${wp_cron_trigger_interval}s)"
    (
        # Deliberately not strict here: this loop must survive for the life of
        # the container on nothing but a validated interval, a curl call whose
        # failure is already handled below, and a `sleep` that can only be
        # interrupted by the TERM trap. `set -e` inherited from run.sh would
        # turn any future edit that adds an unguarded failing command into a
        # permanent, silent cron outage — the trap's `exit 0` remains the only
        # intended exit path.
        set +e
        # Signal delivery to a backgrounded shell doesn't reliably reach a
        # grandchild `sleep` — trap TERM here and kill it explicitly so
        # shutdown doesn't stall for up to a full interval.
        trap 'kill -TERM "${SLEEP_PID:-}" 2>/dev/null; exit 0' TERM
        # Written on every successful trigger; read by wp-metrics.php as
        # wp_cron_trigger_last_success_timestamp_seconds so "is cron actually
        # still running" is an alertable metric, not just a log line someone
        # has to be watching at the right moment.
        wp_cron_trigger_heartbeat_file="/var/run/wp-cron-trigger-last-success"
        last_heartbeat_log=0
        # This loop starts as soon as it's forked, in parallel with nginx and
        # php-fpm still booting — observed in practice: php-fpm doesn't report
        # "ready to handle connections" until ~400ms after this point, so an
        # immediate first attempt reliably hits connection-refused. A fixed
        # warm-up avoids a guaranteed spurious "trigger failed" on every cold
        # start (which would false-positive any alerting on that log line at
        # the default 300s interval) — no readiness signal to poll here, and
        # 5s leaves ample margin over the ~400ms observed startup gap.
        sleep 5
        while true; do
            # wp-cron.php calls fastcgi_finish_request() and closes the HTTP
            # connection before doing any real work (before wp-load.php is
            # even included), so this response returns in milliseconds
            # regardless of how long the actual cron callbacks run afterward
            # in the detached FPM worker. --max-time here is a liveness check
            # on nginx/php-fpm accepting the request, not a budget for cron
            # work itself — it does not need to match php-fpm's
            # request_terminate_timeout.
            if curl -fsS --max-time 30 -H "Host: 127.0.0.1" \
                    "http://127.0.0.1/wp-cron.php?doing_wp_cron" >/dev/null; then
                now=$(date +%s)
                printf '%s\n' "$now" > "$wp_cron_trigger_heartbeat_file" 2>/dev/null \
                    && chmod 644 "$wp_cron_trigger_heartbeat_file" 2>/dev/null
                # Log on success too, but throttled to hourly — frequent enough
                # to positively confirm the loop is alive without flooding logs
                # at the (default 300s) trigger interval.
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

# Exit as soon as nginx or php-fpm dies — triggers _shutdown for the rest.
wait -n "$NGINX_PID" "$FPM_PID" 2>/dev/null || true
_shutdown
