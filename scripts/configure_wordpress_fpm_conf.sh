#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/merge_and_write_config.sh
source "$SCRIPT_DIR/lib/merge_and_write_config.sh"
# shellcheck source=./lib/resource_sizing.sh
source "$SCRIPT_DIR/lib/resource_sizing.sh"

# Output path is overridable only so the script can be exercised outside the image (see tests/);
# the image always uses the default. zzz- sorts after the upstream image's zz-docker.conf, whose
# `listen = 9000` (all interfaces) would otherwise win over the loopback-only listen below.
WORDPRESS_FPM_CONF_PATH="${WORDPRESS_FPM_CONF_PATH:-/usr/local/etc/php-fpm.d/zzz-custom.conf}"

# The worker pool is sized from the container's cgroup limits (see scripts/lib/resource_sizing.sh).
# No-op when run.sh has already loaded and exported the values.
resource_sizing_load

DEFAULT_WORDPRESS_FPM_CONF="[global]
; Keep PHP-FPM in foreground. Do not override daemonize from the Docker image.
emergency_restart_threshold = 10
emergency_restart_interval = 1m
process_control_timeout = 10s

[www]
; Loopback only: nginx is in this container, and FastCGI from the pod network would bypass every
; nginx rule (and PHP_ADMIN_VALUE gives code execution).
listen = 127.0.0.1:9000
listen.backlog = 2048

; Worker pool sized at startup to the container's memory and CPU limits:
;   max_children = min( (memory - reserved - opcache) / per-worker budget,
;                       cpu cores * PHP_FPM_WORKERS_PER_CPU )   clamped 3..64
; so the pool can never grow past what the container can hold, and does not fork workers the
; CPU quota cannot run anyway (they would only add memory and contention). nginx admits at most
; PHP_INFLIGHT_PER_WORKER requests per worker and answers 429 past that, so a burst is shed
; instead of queued for minutes. Override any of these via WORDPRESS_FPM_CONF, or tune the
; inputs with PHP_WORKER_MEMORY_MB / PHP_FPM_WORKERS_PER_CPU / PHP_INFLIGHT_PER_WORKER.
pm = dynamic
pm.max_children = ${CC_SIZING_FPM_MAX_CHILDREN}
pm.start_servers = ${CC_SIZING_FPM_START_SERVERS}
pm.min_spare_servers = ${CC_SIZING_FPM_MIN_SPARE}
pm.max_spare_servers = ${CC_SIZING_FPM_MAX_SPARE}

; Recycle workers periodically so a leaking plugin cannot grow a worker beyond its budget
; indefinitely.
pm.max_requests = 500

; Kill very slow PHP requests instead of letting workers hang forever (wall clock). 300s is what
; WordPress budgets for core/plugin upgrades (set_time_limit(300)), which a 0.07-0.25 vCPU pod
; needs; nginx gives admin requests the same 300s and public ones 120s, and the capacity cap
; bounds how many requests can be in flight at all. php.ini's max_execution_time counts CPU time
; only on this build, so this is the limit that actually fires.
request_terminate_timeout = 300s

; Slow request logging is off: capturing a trace needs ptrace(), which the capsule's security
; context does not permit, so every slow request only produced an \"ERROR: failed to
; ptrace(ATTACH)\" line and no trace. nginx's access log carries rt= and urt= per request.
request_slowlog_timeout = 0

; Docker-friendly logging. nginx already logs every request with the real client IP, timing and
; cache status, so php-fpm's own access log (on in the upstream image) would duplicate each line.
access.log = /dev/null
catch_workers_output = yes
decorate_workers_output = no

php_admin_value[error_log] = /proc/self/fd/2
php_admin_flag[log_errors] = on

; Useful for health checks / metrics.
pm.status_path = /fpm-status
ping.path = /fpm-ping
ping.response = pong

; WordPress only needs PHP scripts executed as PHP.
security.limit_extensions = .php

; Keep env vars available for WordPress Docker env config.
clear_env = no"

merge_and_write_config \
    "$DEFAULT_WORDPRESS_FPM_CONF" \
    "${WORDPRESS_FPM_CONF:-}" \
    "$WORDPRESS_FPM_CONF_PATH" \
    "1" \
    "FPM pool config"
