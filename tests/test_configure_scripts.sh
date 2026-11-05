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

# Runs a configure script and asserts it exits 0. The file checks alone cannot see a failure after
# the files are written: a stray variable in a closing log line passed them all under set -u while
# the real container exited at startup. The assertion reports on fd 3 because callers redirect the
# script's output.
exec 3>&1
configure() {
    local script="$1" status
    "$BASH" "$SCRIPTS/$script"
    status=$?
    assert_eq 0 "$status" "$script exits 0" >&3
}

echo "php.ini defaults are sized to the capsule"
configure configure_wordpress_custom_ini.sh >/dev/null
ini="$(cat "$tmp/php/conf.d/zz-custom.ini")"
assert_contains "$ini" $'\nmemory_limit = 128M\n' "memory_limit"
assert_contains "$ini" $'\nopcache.memory_consumption = 160\n' "opcache size"
assert_contains "$ini" $'\nopcache.interned_strings_buffer = 16\n' "interned strings"
assert_contains "$ini" $'\nupload_max_filesize = 64M\n' "upload default untouched"
assert_contains "$ini" $'\nauto_prepend_file = /usr/share/wp-runtime/prepend.php\n' "platform prepend wired in"
assert_contains "$ini" $'\nzend.assertions = -1\n' "production assertions"

echo "WORDPRESS_CUSTOM_INI overrides the sized defaults and adds new keys"
WORDPRESS_CUSTOM_INI=$'memory_limit = 512M\nopcache.memory_consumption=200\nmax_input_vars = 9000\nmy.new_key = 1' \
    configure configure_wordpress_custom_ini.sh >/dev/null
ini="$(cat "$tmp/php/conf.d/zz-custom.ini")"
assert_contains "$ini" $'\nmemory_limit = 512M\n' "override memory_limit"
assert_not_contains "$ini" "memory_limit = 128M" "default memory_limit replaced"
assert_contains "$ini" $'\nopcache.memory_consumption=200\n' "override opcache"
assert_contains "$ini" $'\nmax_input_vars = 9000\n' "override max_input_vars"
assert_contains "$ini" $'\nmy.new_key = 1' "unknown keys appended"
assert_eq 1 "$(grep -c '^memory_limit' "$tmp/php/conf.d/zz-custom.ini")" "memory_limit appears once"

echo "FPM pool defaults are sized to the capsule and listen on loopback"
configure configure_wordpress_fpm_conf.sh >/dev/null
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
WORDPRESS_FPM_CONF=$'[www]\npm = static\npm.max_children = 10' configure configure_wordpress_fpm_conf.sh >/dev/null
fpm="$(cat "$tmp/fpm.conf")"
assert_contains "$fpm" $'\npm = static\n' "override pm"
assert_contains "$fpm" $'\npm.max_children = 10\n' "override max_children"
assert_not_contains "$fpm" "pm.max_children = 3" "default max_children replaced"

echo "pinning only pm.max_children keeps the pool startable (spares re-derived)"
unset CC_SIZING_LOADED
WORDPRESS_FPM_CONF=$'[www]\npm.max_children = 1' configure configure_wordpress_fpm_conf.sh >/dev/null
fpm="$(cat "$tmp/fpm.conf")"
assert_contains "$fpm" $'\npm.max_children = 1\n' "pinned max_children"
assert_contains "$fpm" $'\npm.max_spare_servers = 1\n' "max_spare <= pinned max_children"
assert_contains "$fpm" $'\npm.min_spare_servers = 1\n' "min_spare"
assert_contains "$fpm" $'\npm.start_servers = 1\n' "start"

echo "a pinned memory_limit shrinks the pool written by the FPM script (4G / 4 CPU)"
unset CC_SIZING_LOADED
make_cgroup_fixture "$tmp/cg" v2 4294967296 400000
configure configure_wordpress_fpm_conf.sh >/dev/null
assert_contains "$(cat "$tmp/fpm.conf")" $'\npm.max_children = 27\n' "27 workers at 256M on 4096M ((4096-336-256)/128)"
unset CC_SIZING_LOADED
WORDPRESS_CUSTOM_INI='memory_limit = 512M' configure configure_wordpress_fpm_conf.sh >/dev/null
assert_contains "$(cat "$tmp/fpm.conf")" $'\npm.max_children = 13\n' "13 workers at 512M on 4G"
unset CC_SIZING_LOADED
make_cgroup_fixture "$tmp/cg" v2 999997440 25000

echo "nginx worker count and the PHP in-flight cap follow the sizing"
configure configure_nginx_overrides.sh >/dev/null
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
assert_contains "$(cat "$nconf")" 'if ($upstream_addr != "php_fpm") {' "only the cap (no server selected) gets the busy page; a crashed worker stays a 502"
assert_contains "$(cat "$nginxconf")" 'map $remote_addr $cc_loopback_php_upstream {' "loopback upstream map for the public cron mode"
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
NGINX_WORKER_PROCESSES=2 configure configure_nginx_overrides.sh >/dev/null
assert_contains "$(cat "$tmp/nginx/generated_main_overrides.conf")" "worker_processes 2;" "NGINX_WORKER_PROCESSES override"
unset CC_SIZING_LOADED
make_cgroup_fixture "$tmp/cg" v2 4294967296 300000
configure configure_nginx_overrides.sh >/dev/null
assert_contains "$(cat "$tmp/nginx/generated_main_overrides.conf")" "worker_processes 3;" "3 workers for 3 CPUs"
unset CC_SIZING_LOADED
DISABLE_PUBLIC_WP_CRON=false configure configure_nginx_overrides.sh >/dev/null
cron="$(cat "$tmp/nginx/generated_wp_cron.conf")"
assert_contains "$cron" 'set $php_upstream $cc_loopback_php_upstream;' "public cron mode: the loopback trigger still reaches the uncapped upstream"
assert_not_contains "$cron" 'deny all' "public cron mode: no loopback restriction"

echo "values nginx would reject fall back to the defaults instead of failing nginx -t"
unset CC_SIZING_LOADED
make_cgroup_fixture "$tmp/cg" v2 999997440 25000
TRUSTED_PROXY_CIDRS="10.0.0.0/8,10.0.0.0/33" MAX_UPLOAD_SIZE=99999999999G CACHE_MAX_SIZE=99999999999G \
    RATE_LIMIT_MAX_CONN_PER_IP=70000 NGINX_WORKER_PROCESSES=99999 CACHE_TTL_SECONDS=99999999999 \
    configure configure_nginx_overrides.sh > "$tmp/badenv.log" 2>&1
http="$(cat "$tmp/nginx/generated_http_overrides.conf")"
assert_contains "$(cat "$tmp/nginx/generated_trusted_proxies.conf")" $'set_real_ip_from 10.0.0.0/8;\nset_real_ip_from 172.16.0.0/12;\nset_real_ip_from 192.168.0.0/16;' "a /33 entry falls back to the default proxy list"
assert_contains "$http" "client_max_body_size 64m;" "an oversized upload limit falls back to 64M"
assert_contains "$http" "max_size=512m" "an oversized cache falls back to 512M"
assert_contains "$(cat "$tmp/nginx/generated_server_overrides.conf")" "limit_conn per_ip_conn 100;" "limit_conn above 65535 falls back"
assert_contains "$(cat "$tmp/nginx/generated_main_overrides.conf")" "worker_processes 1;" "99999 workers falls back to the sized count"
assert_contains "$(cat "$tmp/nginx/generated_fastcgi_cache.conf")" "fastcgi_cache_valid 200 301 60s;" "an eleven-digit TTL falls back to 60s"
assert_eq 6 "$(grep -c 'Invalid\|Falling back' "$tmp/badenv.log")" "each fallback is logged"

echo "a misspelt on/off switch falls back to its default instead of counting as the other state"
unset CC_SIZING_LOADED
DISABLE_PUBLIC_WP_CRON=ture XMLRPC_ENABLED=yess DEBUG_HEADERS=tru CACHE_SKIP_EMPTY=nope \
    configure configure_nginx_overrides.sh > "$tmp/badswitch.log" 2>&1
assert_contains "$(cat "$tmp/nginx/generated_wp_cron.conf")" 'deny all;' "DISABLE_PUBLIC_WP_CRON=ture keeps wp-cron.php loopback-only"
assert_contains "$(cat "$tmp/nginx/generated_xmlrpc_route.conf")" 'return 403;' "XMLRPC_ENABLED=yess keeps XML-RPC off"
assert_not_contains "$(cat "$tmp/nginx/generated_debug_headers.conf")" 'more_set_headers' "DEBUG_HEADERS=tru adds no X-Cache header"
assert_contains "$(cat "$tmp/nginx/generated_fastcgi_cache.conf")" '$cache_skip_empty' "CACHE_SKIP_EMPTY=nope still skips empty pages"
assert_eq 4 "$(grep -c '^\[nginx-overrides\] Invalid .* (true/false, 1/0, yes/no or on/off)\. Falling back to' "$tmp/badswitch.log")" "each fallback is logged"
unset CC_SIZING_LOADED
DISABLE_PUBLIC_WP_CRON=No XMLRPC_ENABLED=ON DEBUG_HEADERS=Yes CACHE_SKIP_EMPTY=OFF \
    configure configure_nginx_overrides.sh > "$tmp/goodswitch.log" 2>&1
assert_not_contains "$(cat "$tmp/nginx/generated_wp_cron.conf")" 'deny all;' "DISABLE_PUBLIC_WP_CRON=No makes wp-cron.php public"
assert_contains "$(cat "$tmp/nginx/generated_xmlrpc_route.conf")" 'include /etc/nginx/snippets/wp-fastcgi.conf;' "XMLRPC_ENABLED=ON enables XML-RPC"
assert_contains "$(cat "$tmp/nginx/generated_debug_headers.conf")" 'more_set_headers "X-Cache: $upstream_cache_status";' "DEBUG_HEADERS=Yes adds X-Cache"
assert_not_contains "$(cat "$tmp/nginx/generated_fastcgi_cache.conf")" '$cache_skip_empty' "CACHE_SKIP_EMPTY=OFF caches empty pages"
assert_eq 0 "$(grep -c 'Invalid' "$tmp/goodswitch.log")" "any-case spellings are not reported"

echo "the switches the prepend reads are reported at startup; a misspelt one keeps the prepend on"
unset CC_SIZING_LOADED
WP_RUNTIME_PREPEND_ENABLED=flase WP_RUNTIME_MU_PLUGIN_ENABLED=disabled WP_DISALLOW_FILE_EDIT=nah WP_DISABLE_WP_CRON=maybe \
    configure configure_wordpress_custom_ini.sh > "$tmp/badswitch.log" 2>&1
assert_contains "$(cat "$tmp/php/conf.d/zz-custom.ini")" $'\nauto_prepend_file = /usr/share/wp-runtime/prepend.php\n' "WP_RUNTIME_PREPEND_ENABLED=flase keeps the prepend"
log_out="$(cat "$tmp/badswitch.log")"
assert_contains "$log_out" "[custom-ini] Invalid WP_RUNTIME_PREPEND_ENABLED value 'flase' (true/false, 1/0, yes/no or on/off). Falling back to true." "prepend switch"
assert_contains "$log_out" "[custom-ini] Invalid WP_RUNTIME_MU_PLUGIN_ENABLED value 'disabled'" "mu-plugin switch"
assert_contains "$log_out" "[custom-ini] Invalid WP_DISALLOW_FILE_EDIT value 'nah'" "file-edit switch"
assert_contains "$log_out" "[custom-ini] Invalid WP_DISABLE_WP_CRON value 'maybe' (true/false, 1/0, yes/no or on/off). Falling back to the default (follows WP_CRON_TRIGGER_ENABLED)." "cron spawner switch"
assert_contains "$log_out" "prepend=on" "the summary line says the prepend is on"
unset CC_SIZING_LOADED
WP_RUNTIME_PREPEND_ENABLED=Off WP_DISALLOW_FILE_EDIT=nah configure configure_wordpress_custom_ini.sh > "$tmp/badswitch.log" 2>&1
assert_contains "$(cat "$tmp/php/conf.d/zz-custom.ini")" $'\n; auto_prepend_file disabled (WP_RUNTIME_PREPEND_ENABLED=false)\n' "WP_RUNTIME_PREPEND_ENABLED=Off turns the prepend off"
assert_eq 0 "$(grep -c 'Invalid' "$tmp/badswitch.log")" "with the prepend off its switches are not checked"

echo "run.sh reads its timeouts and switches only through the validators"
runsh="$(cat "$HERE/../run.sh")"
for var in SHUTDOWN_TIMEOUT_SECONDS FPM_STARTUP_TIMEOUT_SECONDS WP_CRON_TRIGGER_ENABLED WP_CRON_TRIGGER_INTERVAL_SECONDS \
        WP_CRON_TRIGGER_SITES_PER_RUN WP_CRON_TRIGGER_TARGETS_REFRESH_SECONDS; do
    assert_eq 1 "$(grep -cE "\\\$\\{?${var}([^A-Za-z0-9_]|\$)" <<<"$runsh")" "${var} is expanded on one line only"
    assert_eq 1 "$(grep -cE "^[a-z_]+=\"\\\$\\(validated_(positive_int|bool) \"\\\$\\{${var}:-" <<<"$runsh")" "${var} goes through a validator"
done

echo "only the PHP handler caches: no no-op cache directives elsewhere"
assert_eq 0 "$(grep -c 'fastcgi_no_cache\|fastcgi_cache_bypass' "$nconf")" "default.conf has none outside the generated cache include"
assert_eq 1 "$(grep -c 'fastcgi_cache WORDPRESS;' "$nconf")" "one caching location"
unset CC_SIZING_LOADED
XMLRPC_ENABLED=true configure configure_nginx_overrides.sh >/dev/null
assert_eq 0 "$(cat "$tmp/nginx/generated_xmlrpc_route.conf" "$tmp/nginx/generated_wp_cron.conf" | grep -c 'fastcgi_no_cache\|fastcgi_cache_bypass')" "xmlrpc and wp-cron fragments carry none"
unset CC_SIZING_LOADED
DISABLE_PUBLIC_WP_CRON=false configure configure_nginx_overrides.sh >/dev/null
assert_eq 0 "$(grep -c 'fastcgi_no_cache\|fastcgi_cache_bypass' "$tmp/nginx/generated_wp_cron.conf")" "public wp-cron fragment carries none"

echo "the REST API is never page-cached, under any of its URL forms"
skipmap="$(sed -n '/map \$request_uri \$skip_cache_uri {/,/^    }/p' "$nginxconf")"
assert_contains "$skipmap" '~*^/wp-json(/|$)' "/wp-json/"
assert_contains "$skipmap" '~*^/index\.php/wp-json(/|$)' "/index.php/wp-json/ (almost-pretty permalinks)"
assert_contains "$skipmap" '~*[?&]rest_route=' "?rest_route= (plain permalinks, every fresh install)"

echo "httpoxy: a client's Proxy header never reaches PHP as HTTP_PROXY"
assert_contains "$(cat "$snippet")" 'fastcgi_param HTTP_PROXY "";' "every PHP location (shared snippet)"
assert_eq 2 "$(grep -c 'fastcgi_param HTTP_PROXY      "";' "$nginxconf")" "both metrics locations"

echo "WordPress metrics are scrapeable from the pod network, and nothing else there"
metrics_server="$(sed -n '/listen 9254;/,/^    }/p' "$nginxconf")"
assert_contains "$metrics_server" "location = /metrics {" "served at /metrics"
assert_contains "$metrics_server" "root /var/www/html;" "with the docroot the prepend needs"
assert_contains "$metrics_server" "fastcgi_param SCRIPT_FILENAME /usr/share/wp-runtime/wp-metrics.php;" "the same script"
assert_contains "$metrics_server" $'location / {\n            return 404;' "every other path is a 404"
assert_contains "$(cat "$HERE/../Dockerfile")" "EXPOSE 9254" "port declared"

echo "build and CI hardening"
assert_contains "$(cat "$HERE/../Dockerfile")" ". /usr/scripts/lib/cloudflare_ips.sh;" "Cloudflare ranges validated line by line at build"
assert_contains "$(cat "$HERE/../.github/workflows/runtime.yml")" $'defaults:\n  run:\n    shell: bash' "CI steps run with pipefail"
assert_contains "$(cat "$HERE/../.dockerignore")" $'\ntools' "host-side tools stay out of the build context"

echo "the cron trigger addresses sites as visitors do, and PHP writes the heartbeat"
runsh="$(cat "$HERE/../run.sh")"
assert_not_contains "$runsh" 'Host: 127.0.0.1' "no hard-coded loopback host"
assert_contains "$runsh" 'wp_cron_trigger_fire "${WP_CRON_TRIGGER_TARGETS[$i]}"' "fires each target"
assert_contains "$runsh" 'chown www-data:www-data "$CRON_HEARTBEAT_FILE"' "heartbeat file writable by PHP only"
assert_not_contains "$runsh" 'wp-cron-trigger-last-success' "the loop no longer writes a heartbeat"
assert_contains "$(cat "$HERE/../runtime/prepend.php")" "\$GLOBALS['wp_filter']['pre_get_ready_cron_jobs']" "heartbeat hook in the prepend"
assert_contains "$(cat "$HERE/../wp-metrics.php")" "'/var/run/wp-runtime/cron-last-run'" "metrics read the PHP heartbeat"

echo "a bigger capsule gets bigger defaults from the same scripts"
unset CC_SIZING_LOADED
make_cgroup_fixture "$tmp/cg" v1 4294967296 200000
configure configure_wordpress_custom_ini.sh >/dev/null
configure configure_wordpress_fpm_conf.sh >/dev/null
assert_contains "$(cat "$tmp/php/conf.d/zz-custom.ini")" $'\nmemory_limit = 256M\n' "4G memory_limit"
assert_contains "$(cat "$tmp/php/conf.d/zz-custom.ini")" $'\nopcache.memory_consumption = 256\n' "4G opcache"
assert_contains "$(cat "$tmp/fpm.conf")" $'\npm.max_children = 24\n' "4G/2CPU max_children"

finish
