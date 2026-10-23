#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/runtime_env.sh
source "$SCRIPT_DIR/lib/runtime_env.sh"
# shellcheck source=./lib/merge_and_write_config.sh
source "$SCRIPT_DIR/lib/merge_and_write_config.sh"

log() {
    echo "[fpm-conf] $*"
}

# Size the pool to the container instead of assuming a 1-2GB VM:
#   by memory: what is left after nginx, the exporters, the FPM master and the resident OPcache,
#              at ~64MB per WordPress worker;
#   by CPU:    12 workers per CPU (WordPress waits on MySQL/NFS a lot, so more than 1:1 pays off);
#   clamped to 2..64. WORDPRESS_FPM_CONF still overrides any of these.
_mem_mb="$(cgroup_memory_limit_mb)"
_cpus="$(cgroup_cpu_limit)"
_opcache_mb="$(opcache_memory_mb_for "$_mem_mb")"
_reserve_mb=$(( 128 + _opcache_mb / 2 ))
_by_mem=$(( (_mem_mb - _reserve_mb) / 64 ))
_by_cpu=$(( _cpus * 12 ))
_max_children=$(( _by_mem < _by_cpu ? _by_mem : _by_cpu ))
_max_children="$(clamp "$_max_children" 2 64)"
_min_spare="$(clamp $(( _max_children / 4 )) 1 "$_max_children")"
_start="$_min_spare"
_max_spare="$(clamp $(( _max_children / 2 )) "$_start" "$_max_children")"

log "memory_limit_mb=${_mem_mb}, cpus=${_cpus} -> pm.max_children=${_max_children} (by_mem=${_by_mem}, by_cpu=${_by_cpu}), start=${_start}, min_spare=${_min_spare}, max_spare=${_max_spare}"

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

; Sized at startup from the container's cgroup limits (see configure_wordpress_fpm_conf.sh).
; Override any value through WORDPRESS_FPM_CONF.
pm = dynamic
pm.max_children = ${_max_children}
pm.start_servers = ${_start}
pm.min_spare_servers = ${_min_spare}
pm.max_spare_servers = ${_max_spare}
pm.max_requests = 500

; Kill very slow PHP requests instead of letting workers hang forever.
request_terminate_timeout = 120s

; Slow request logging.
request_slowlog_timeout = 5s
slowlog = /proc/self/fd/2

; Docker-friendly logging.
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

# zzz- sorts after the upstream image's zz-docker.conf, whose `listen = 9000` (all interfaces)
# would otherwise win over the loopback-only listen above.
merge_and_write_config \
    "$DEFAULT_WORDPRESS_FPM_CONF" \
    "${WORDPRESS_FPM_CONF:-}" \
    "/usr/local/etc/php-fpm.d/zzz-custom.conf" \
    "1" \
    "FPM pool config"
