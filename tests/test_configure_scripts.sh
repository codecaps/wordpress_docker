#!/bin/bash
# Runs the real configure scripts against a fake cgroup and checks the files they write: sized
# defaults, the nginx fragments, and that customer overrides still win.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
SCRIPTS="$HERE/../scripts"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/php/conf.d" "$tmp/nginx" "$tmp/state"
export CONTAINER_RESOURCES_CGROUP_ROOT="$tmp/cg"
export PHP_INI_DIR="$tmp/php"
export WORDPRESS_FPM_CONF_PATH="$tmp/fpm.conf"
export NGINX_GENERATED_DIR="$tmp/nginx"
export RUNTIME_STATE_DIR="$tmp/state"
unset CC_SIZING_LOADED WORDPRESS_CUSTOM_INI WORDPRESS_FPM_CONF NGINX_WORKER_PROCESSES
make_cgroup_fixture "$tmp/cg" v2 999997440 25000   # the 1G / 25% capsule

echo "php.ini defaults are sized to the capsule"
"$BASH" "$SCRIPTS/configure_wordpress_custom_ini.sh" >/dev/null
ini="$(cat "$tmp/php/conf.d/zz-custom.ini")"
assert_contains "$ini" $'\nmemory_limit = 128M\n' "memory_limit"
assert_contains "$ini" $'\nopcache.memory_consumption = 160\n' "opcache size"
assert_contains "$ini" $'\nopcache.interned_strings_buffer = 16\n' "interned strings"
assert_contains "$ini" $'\nupload_max_filesize = 64M\n' "upload default untouched"
assert_contains "$ini" $'\nauto_prepend_file = /usr/share/wp-runtime/prepend.php\n' "platform prepend wired in"
assert_contains "$ini" $'\nzend.assertions = -1\n' "production assertions"

echo "WORDPRESS_CUSTOM_INI overrides the sized defaults and adds new keys"
WORDPRESS_CUSTOM_INI=$'memory_limit = 512M\nopcache.memory_consumption=200\nmax_input_vars = 9000\nmy.new_key = 1' \
    "$BASH" "$SCRIPTS/configure_wordpress_custom_ini.sh" >/dev/null
ini="$(cat "$tmp/php/conf.d/zz-custom.ini")"
assert_contains "$ini" $'\nmemory_limit = 512M\n' "override memory_limit"
assert_not_contains "$ini" "memory_limit = 128M" "default memory_limit replaced"
assert_contains "$ini" $'\nopcache.memory_consumption=200\n' "override opcache"
assert_contains "$ini" $'\nmax_input_vars = 9000\n' "override max_input_vars"
assert_contains "$ini" $'\nmy.new_key = 1' "unknown keys appended"
assert_eq 1 "$(grep -c '^memory_limit' "$tmp/php/conf.d/zz-custom.ini")" "memory_limit appears once"

echo "FPM pool defaults are sized to the capsule and listen on loopback"
"$BASH" "$SCRIPTS/configure_wordpress_fpm_conf.sh" >/dev/null
fpm="$(cat "$tmp/fpm.conf")"
assert_contains "$fpm" $'\nlisten = 127.0.0.1:9000\n' "loopback listen"
assert_contains "$fpm" $'\npm.max_children = 3\n' "max_children"
assert_contains "$fpm" $'\npm.start_servers = 1\n' "start_servers"
assert_contains "$fpm" $'\npm.min_spare_servers = 1\n' "min_spare"
assert_contains "$fpm" $'\npm.max_spare_servers = 2\n' "max_spare"
assert_contains "$fpm" $'\nrequest_slowlog_timeout = 0\n' "slowlog off (no ptrace in the capsule)"
assert_contains "$fpm" $'\nrequest_terminate_timeout = 300s\n' "wall-clock kill matches WordPress's upgrade budget"
assert_contains "$fpm" $'\naccess.log = /dev/null\n' "fpm access log off (nginx logs every request)"

echo "WORDPRESS_FPM_CONF overrides the sized pool"
WORDPRESS_FPM_CONF=$'[www]\npm = static\npm.max_children = 10' "$BASH" "$SCRIPTS/configure_wordpress_fpm_conf.sh" >/dev/null
fpm="$(cat "$tmp/fpm.conf")"
assert_contains "$fpm" $'\npm = static\n' "override pm"
assert_contains "$fpm" $'\npm.max_children = 10\n' "override max_children"
assert_not_contains "$fpm" "pm.max_children = 3" "default max_children replaced"

echo "pinning only pm.max_children keeps the pool startable (spares re-derived)"
unset CC_SIZING_LOADED
WORDPRESS_FPM_CONF=$'[www]\npm.max_children = 1' "$BASH" "$SCRIPTS/configure_wordpress_fpm_conf.sh" >/dev/null
fpm="$(cat "$tmp/fpm.conf")"
assert_contains "$fpm" $'\npm.max_children = 1\n' "pinned max_children"
assert_contains "$fpm" $'\npm.max_spare_servers = 1\n' "max_spare <= pinned max_children"
assert_contains "$fpm" $'\npm.min_spare_servers = 1\n' "min_spare"
assert_contains "$fpm" $'\npm.start_servers = 1\n' "start"

echo "a pinned memory_limit shrinks the pool written by the FPM script (4G / 4 CPU)"
unset CC_SIZING_LOADED
make_cgroup_fixture "$tmp/cg" v2 4294967296 400000
"$BASH" "$SCRIPTS/configure_wordpress_fpm_conf.sh" >/dev/null
assert_contains "$(cat "$tmp/fpm.conf")" $'\npm.max_children = 27\n' "27 workers at 256M on 4096M ((4096-336-256)/128)"
unset CC_SIZING_LOADED
WORDPRESS_CUSTOM_INI='memory_limit = 512M' "$BASH" "$SCRIPTS/configure_wordpress_fpm_conf.sh" >/dev/null
assert_contains "$(cat "$tmp/fpm.conf")" $'\npm.max_children = 13\n' "13 workers at 512M on 4G"
unset CC_SIZING_LOADED
make_cgroup_fixture "$tmp/cg" v2 999997440 25000

echo "nginx worker count and the PHP in-flight cap follow the sizing"
"$BASH" "$SCRIPTS/configure_nginx_overrides.sh" >/dev/null
assert_contains "$(cat "$tmp/nginx/generated_main_overrides.conf")" "worker_processes 1;" "1 worker for 0.25 CPU"
up="$(cat "$tmp/nginx/generated_upstream.conf")"
assert_contains "$up" $'upstream php_fpm {\n    zone php_fpm 64k;\n    server 127.0.0.1:9000 max_conns=12;\n}' "capped upstream: 3 workers x 4"
assert_contains "$up" $'upstream php_fpm_internal {\n    server 127.0.0.1:9000;\n}' "uncapped internal upstream"
assert_not_contains "$up" "keepalive" "no upstream keepalive"
assert_contains "$(cat "$tmp/nginx/generated_wp_cron.conf")" 'set $php_upstream php_fpm_internal;' "loopback cron uses the uncapped upstream"
cache="$(cat "$tmp/nginx/generated_fastcgi_cache.conf")"
assert_contains "$cache" '$upstream_http_x_cc_no_cache' "DONOTCACHEPAGE marker honoured by fastcgi_no_cache"
assert_contains "$cache" '$cc_upstream_nocache' "WordPress nocache headers honoured by fastcgi_no_cache"
assert_contains "$cache" $'\nfastcgi_cache_valid 200 301 60s;\n' "pages and canonical 301s cached"
assert_eq 0 "$(grep -c '^fastcgi_cache_valid.*302' "$tmp/nginx/generated_fastcgi_cache.conf")" "302s are never cached"
assert_contains "$(cat "$tmp/state/nginx-cache.env")" "enabled=1" "cache state for the mu-plugin"
nconf="$HERE/../default.conf"; snippet="$HERE/../nginx/snippets/wp-fastcgi.conf"; nginxconf="$HERE/../nginx.conf"
assert_eq 0 "$(cat "$nconf" "$snippet" "$nginxconf" "$SCRIPTS/configure_nginx_overrides.sh" | grep -c 'generated_php_inflight')" "no limit_conn-based cap left anywhere"
assert_contains "$(cat "$nconf")" 'set $php_upstream php_fpm;' "server-level upstream variable"
assert_contains "$(cat "$nconf")" 'error_page 502 =503 @busy;' "cap exhaustion answers 503 with the busy page"
assert_contains "$(cat "$nconf")" 'fastcgi_pass php_fpm_internal;' "healthz on the uncapped upstream"
admin_line="$(grep -n 'location ~\* ^/wp-admin/\.\*\\\.php\$ {' "$nconf" | cut -d: -f1)"
timeout_line="$(grep -n 'fastcgi_read_timeout 300s;' "$nconf" | cut -d: -f1)"
assert_eq 1 "$(grep -c 'fastcgi_read_timeout 300s;' "$nconf")" "exactly one location raises the read timeout"
assert_le 1 $(( timeout_line - admin_line )) "the 300s timeout sits inside the admin PHP location"
assert_le $(( timeout_line - admin_line )) 4 "the 300s timeout sits inside the admin PHP location (before the include)"
assert_contains "$(cat "$snippet")" 'fastcgi_pass $php_upstream;' "snippet passes to the variable upstream"
assert_eq 0 "$(grep -cE '^\s*(keepalive |fastcgi_keep_conn on|fastcgi_(read|send|connect)_timeout)' "$snippet")" "snippet carries no keep-alive and no timeouts (server{} sets them)"
assert_contains "$(cat "$snippet")" "fastcgi_hide_header X-CC-No-Cache;" "no-cache marker hidden from clients"
assert_contains "$(cat "$nginxconf")" "generated_upstream.conf" "upstreams included from nginx.conf"
assert_contains "$(cat "$nginxconf")" 'map "$upstream_status:$upstream_http_cache_control" $cc_upstream_nocache' "nocache map declared"
assert_contains "$(cat "$nginxconf")" "worker_rlimit_nofile 65536;" "fd limit raised"
assert_eq 1 "$([ -f "$HERE/../runtime/html/busy.html" ] && echo 1 || echo 0)" "busy page shipped"
unset CC_SIZING_LOADED
NGINX_WORKER_PROCESSES=2 "$BASH" "$SCRIPTS/configure_nginx_overrides.sh" >/dev/null
assert_contains "$(cat "$tmp/nginx/generated_main_overrides.conf")" "worker_processes 2;" "NGINX_WORKER_PROCESSES override"
unset CC_SIZING_LOADED
make_cgroup_fixture "$tmp/cg" v2 4294967296 300000
"$BASH" "$SCRIPTS/configure_nginx_overrides.sh" >/dev/null
assert_contains "$(cat "$tmp/nginx/generated_main_overrides.conf")" "worker_processes 3;" "3 workers for 3 CPUs"

echo "a bigger capsule gets bigger defaults from the same scripts"
unset CC_SIZING_LOADED
make_cgroup_fixture "$tmp/cg" v1 4294967296 200000
"$BASH" "$SCRIPTS/configure_wordpress_custom_ini.sh" >/dev/null
"$BASH" "$SCRIPTS/configure_wordpress_fpm_conf.sh" >/dev/null
assert_contains "$(cat "$tmp/php/conf.d/zz-custom.ini")" $'\nmemory_limit = 256M\n' "4G memory_limit"
assert_contains "$(cat "$tmp/php/conf.d/zz-custom.ini")" $'\nopcache.memory_consumption = 256\n' "4G opcache"
assert_contains "$(cat "$tmp/fpm.conf")" $'\npm.max_children = 24\n' "4G/2CPU max_children"

finish
