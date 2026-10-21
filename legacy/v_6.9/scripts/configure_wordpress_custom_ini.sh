#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/merge_and_write_config.sh
source "$SCRIPT_DIR/lib/merge_and_write_config.sh"

# MAX_UPLOAD_SIZE drives the default for upload_max_filesize and post_max_size so
# they stay in sync with the nginx client_max_body_size set by configure_nginx_overrides.sh.
# Customers can still override via WORDPRESS_CUSTOM_INI.
_upload_size="${MAX_UPLOAD_SIZE:-64M}"

# SESSION_COOKIE_SECURE: set to 0 for local HTTP development, 1 for production HTTPS.
_session_secure="${SESSION_COOKIE_SECURE:-1}"
if [[ "$_session_secure" != "0" && "$_session_secure" != "1" ]]; then
    echo "[custom-ini] Invalid SESSION_COOKIE_SECURE value '${_session_secure}'. Falling back to 1."
    _session_secure="1"
fi

DEFAULT_WORDPRESS_CUSTOM_INI="; Security / information leakage
expose_php = Off
cgi.fix_pathinfo = 0

; Resource limits
memory_limit = 256M
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
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT

; Sessions
session.cookie_httponly = 1
session.cookie_samesite = Lax
session.cookie_secure = ${_session_secure}

; Realpath cache helps WordPress/plugin file lookups.
realpath_cache_size = 4096K
realpath_cache_ttl = 600

; OPcache - important for WordPress performance.
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 16
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

; Optional: uncomment only after testing plugin compatibility.
; disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,parse_ini_file,show_source
"

merge_and_write_config \
    "$DEFAULT_WORDPRESS_CUSTOM_INI" \
    "${WORDPRESS_CUSTOM_INI:-}" \
    "$PHP_INI_DIR/conf.d/zz-custom.ini" \
    "0" \
    "ini"
