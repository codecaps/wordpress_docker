#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/runtime_env.sh
source "$SCRIPT_DIR/lib/runtime_env.sh"
# shellcheck source=./lib/merge_and_write_config.sh
source "$SCRIPT_DIR/lib/merge_and_write_config.sh"
# shellcheck source=./lib/resource_sizing.sh
source "$SCRIPT_DIR/lib/resource_sizing.sh"

log() {
    echo "[custom-ini] $*"
}

# memory_limit and the OPcache sizes are derived from the container's cgroup limits (see
# scripts/lib/resource_sizing.sh). No-op when run.sh has already loaded and exported them.
resource_sizing_load

# MAX_UPLOAD_SIZE drives upload_max_filesize and post_max_size so they stay in sync with the nginx
# client_max_body_size set by configure_nginx_overrides.sh (same validation, same fallback).
_upload_size="$(validated_upload_size "${MAX_UPLOAD_SIZE:-64M}" "64M" "MAX_UPLOAD_SIZE")"

# SESSION_COOKIE_SECURE: set to 0 for local HTTP development, 1 for production HTTPS.
_session_secure="${SESSION_COOKIE_SECURE:-1}"
if [[ "$_session_secure" != "0" && "$_session_secure" != "1" ]]; then
    log "Invalid SESSION_COOKIE_SECURE value '${_session_secure}'. Falling back to 1."
    _session_secure="1"
fi

# The platform prepend (HTTPS awareness, hardened constants, runtime mu-plugin). Off with
# WP_RUNTIME_PREPEND_ENABLED=false; a user auto_prepend_file in WORDPRESS_CUSTOM_INI overrides it.
_prepend_line="auto_prepend_file = /usr/share/wp-runtime/prepend.php"
_prepend_enabled="$(validated_bool "${WP_RUNTIME_PREPEND_ENABLED:-true}" "true" "WP_RUNTIME_PREPEND_ENABLED")"
if [ "$_prepend_enabled" = "false" ]; then
    _prepend_line="; auto_prepend_file disabled (WP_RUNTIME_PREPEND_ENABLED=false)"
else
    # The prepend reads these switches itself on every request, with the same fallback; they are
    # checked here only so that a typo is reported, once, at startup.
    validated_bool "${WP_RUNTIME_MU_PLUGIN_ENABLED:-true}" "true" "WP_RUNTIME_MU_PLUGIN_ENABLED" >/dev/null
    validated_bool "${WP_DISALLOW_FILE_EDIT:-true}" "true" "WP_DISALLOW_FILE_EDIT" >/dev/null
    if [ -n "${WP_DISABLE_WP_CRON:-}" ]; then
        validated_bool "$WP_DISABLE_WP_CRON" "the default (follows WP_CRON_TRIGGER_ENABLED)" "WP_DISABLE_WP_CRON" >/dev/null
    fi
fi

log "memory_limit=${CC_SIZING_PHP_MEMORY_LIMIT_MB}M, opcache.memory_consumption=${CC_SIZING_OPCACHE_MB}, upload_size=${_upload_size}, prepend=$([ "$_prepend_enabled" = "true" ] && echo on || echo off)"

DEFAULT_WORDPRESS_CUSTOM_INI="; Security / information leakage
expose_php = Off
cgi.fix_pathinfo = 0

; Resource limits.
; memory_limit is the per-request cap and is sized to the container: 128M below 1.5G of memory,
; 256M above. The platform prepend sets WP_MEMORY_LIMIT to the same value (so WordPress does not
; raise it behind our back) and WP_MAX_MEMORY_LIMIT to up to twice it for admin work.
; Together with the PHP-FPM worker count (also sized to the container) this keeps the worst-case
; PHP footprint inside the container's memory limit so the pod cannot be OOM-killed under load.
memory_limit = ${CC_SIZING_PHP_MEMORY_LIMIT_MB}M
; max_execution_time counts CPU time, not wall-clock time, on this (non-threaded) build: at a
; fraction of a vCPU it never fires. PHP-FPM's request_terminate_timeout (300s) is the real cap.
max_execution_time = 60
max_input_time = 60
max_input_vars = 3000

; Uploads — kept in sync with nginx MAX_UPLOAD_SIZE
upload_max_filesize = ${_upload_size}
post_max_size = ${_upload_size}
file_uploads = On

; Error handling
display_errors = Off
display_startup_errors = Off
log_errors = On
error_log = /proc/self/fd/2
error_reporting = E_ALL & ~E_DEPRECATED

; Production values (php.ini-production is installed; these matter if it is ever removed)
zend.assertions = -1
output_buffering = 4096

; Sessions
session.cookie_httponly = 1
session.cookie_samesite = Lax
session.cookie_secure = ${_session_secure}

; Realpath cache helps WordPress/plugin file lookups (the docroot is usually a network volume).
realpath_cache_size = 4096K
realpath_cache_ttl = 600

; OPcache - important for WordPress performance.
; The shared-memory segment is sized to the container (memory/6, 96M..256M): WordPress core plus
; a typical plugin set compiles to 40-120M, and only the pages actually used are charged to the
; container, so erring large costs nothing while a full OPcache recompiles on every request.
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = ${CC_SIZING_OPCACHE_MB}
opcache.interned_strings_buffer = ${CC_SIZING_OPCACHE_INTERNED_MB}
opcache.max_accelerated_files = 20000
opcache.max_wasted_percentage = 10

; Safer default when plugins/themes may update files at runtime.
opcache.validate_timestamps = 1
opcache.revalidate_freq = 60

; For immutable container images where plugins/themes never update at runtime,
; you can use this for better performance:
; opcache.validate_timestamps = 0

; JIT usually does not help typical WordPress workloads.
opcache.jit_buffer_size = 0

; Pathinfo/security hardening
allow_url_fopen = On
allow_url_include = Off

; Platform prepend: HTTPS behind the proxy, hardened wp-config defaults, runtime mu-plugin.
${_prepend_line}

; Optional: uncomment only after testing plugin compatibility.
; disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,parse_ini_file,show_source
"

merge_and_write_config \
    "$DEFAULT_WORDPRESS_CUSTOM_INI" \
    "${WORDPRESS_CUSTOM_INI:-}" \
    "$PHP_INI_DIR/conf.d/zz-custom.ini" \
    "0" \
    "ini"
