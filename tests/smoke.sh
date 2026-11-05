#!/usr/bin/env bash
# Smoke-tests one runtime image against a throwaway MySQL. Each check prints PASS/FAIL <name>;
# exits 0 only if every check passes. Installs WordPress with WP-CLI so real pages, the page
# cache, its purge, rate limits, headers and the graceful shutdown are exercised.
# Usage: tests/smoke.sh <image-ref> <min-php-version>
#   e.g. tests/smoke.sh europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime:php8.4-r1 8.4.27
set -uo pipefail
# NOTE: with pipefail, never `docker logs | grep -q`: grep closing the pipe early fails the pipeline.
cd "$(dirname "$0")/.."

IMG="${1:?usage: $0 <image-ref> <min-php-version>}"
MIN_PHP="${2:?usage: $0 <image-ref> <min-php-version>}"
N="wp-smoke-$$-$RANDOM"
GIT_IMG="${N}-git:latest"
GIT_CTX="$(mktemp -d)"
FAILED=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+: $2}"; FAILED=1; }

cleanup() {
    docker rm -f "$N-wp" "$N-wp2" "$N-wp3" "$N-sized" "$N-pinned" "$N-badenv" "$N-ms" "$N-git" "$N-db" >/dev/null 2>&1
    docker volume rm "$N-vol" >/dev/null 2>&1
    docker network rm "$N" >/dev/null 2>&1
    docker rmi "$GIT_IMG" >/dev/null 2>&1
    rm -rf "$GIT_CTX"
}
trap cleanup EXIT

# Starts a WordPress container named $1 on volume $2 (or none when empty) from image $3; any further
# arguments are extra `docker run` flags (e.g. -e DEBUG_HEADERS=true).
run_wp() {
    local name="$1" volume="$2" image="$3"
    shift 3
    local volume_args=()
    [ -n "$volume" ] && volume_args=(-v "$volume:/var/www/html")
    docker run -d --platform linux/amd64 --name "$name" --network "$N" -p 0:80 \
        -e WORDPRESS_DB_HOST="$N-db" -e WORDPRESS_DB_USER=root -e WORDPRESS_DB_PASSWORD=pw \
        -e WORDPRESS_DB_NAME=wp -e SESSION_COOKIE_SECURE=0 \
        ${volume_args[@]+"${volume_args[@]}"} "$@" "$image" >/dev/null
}

port_of() { docker port "$1" 80 | head -1 | cut -d: -f2; }

# Polls GET $2 on container $1 for up to 120s ($3 polls of 2s to change it); prints the last status code.
wait_http() {
    local code=000 port
    port="$(port_of "$1")"
    for _ in $(seq 1 "${3:-60}"); do
        code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}$2")"
        [ "$code" = 200 ] && break
        sleep 2
    done
    echo "$code"
}

# Response headers of GET $2 on container $1 (extra curl args after).
headers_of() {
    local name="$1" path="$2"
    shift 2
    curl -s -D - -o /dev/null "$@" "http://127.0.0.1:$(port_of "$name")${path}"
}
header_value() { grep -i "^$1:" | head -1 | cut -d' ' -f2- | tr -d '\r'; }

wp_cli() {
    local name="$1"
    shift
    docker exec "$name" wp --allow-root --path=/var/www/html "$@"
}

# PHP-FPM's master is the php-fpm process whose parent is PID 1 (workers are its children).
kill_fpm_master() {
    docker exec "$1" bash -c '
        for p in /proc/[0-9]*; do
            [ "$(cut -d" " -f4 "$p/stat" 2>/dev/null)" = 1 ] || continue
            tr "\0" " " < "$p/cmdline" 2>/dev/null | grep -qE "^php-fpm( |:|$)" && kill -KILL "${p#/proc/}"
        done'
}

docker network create "$N" >/dev/null
docker run -d --name "$N-db" --network "$N" -e MYSQL_ROOT_PASSWORD=pw -e MYSQL_DATABASE=wp mysql:8.4 >/dev/null
for _ in $(seq 1 60); do docker exec "$N-db" mysqladmin -uroot -ppw ping >/dev/null 2>&1 && break; sleep 2; done

# php-version
php="$(docker run --rm --platform linux/amd64 --entrypoint php "$IMG" -r 'echo PHP_VERSION;')"
if docker run --rm --platform linux/amd64 --entrypoint php "$IMG" \
        -r "exit(version_compare(PHP_VERSION, '${MIN_PHP}', '>=') ? 0 : 1);"; then
    pass php-version
else
    fail php-version "PHP ${php} < ${MIN_PHP}"
fi

# extensions + tooling baked into the image
modules="$(docker run --rm --platform linux/amd64 --entrypoint php "$IMG" -m)"
missing=""
for ext in redis imagick mysqli; do
    grep -qx "$ext" <<<"$modules" || missing="$missing $ext"
done
grep -qiE '^(zend )?opcache$' <<<"$modules" || missing="$missing opcache"
if [ -z "$missing" ]; then pass extensions; else fail extensions "missing${missing}"; fi

wpv="$(docker run --rm --platform linux/amd64 --entrypoint wp "$IMG" --allow-root --version 2>&1)"
if grep -q '^WP-CLI' <<<"$wpv"; then
    pass wp-cli
else
    fail wp-cli "wp --version failed"
fi

# imagick-policy: PostScript coders closed in the ImageMagick policy, PDF kept.
if docker run --rm --platform linux/amd64 --entrypoint bash "$IMG" -c \
        'grep -q "<policy domain=\"coder\" rights=\"none\" pattern=\"{PS,PS2,PS3,EPS,XPS,MVG,MSL}\" />" /etc/ImageMagick-*/policy.xml && ! grep -q "pattern=\"PDF\"" /etc/ImageMagick-*/policy.xml'; then
    pass imagick-policy
else
    fail imagick-policy "policy.xml does not close the PostScript coders"
fi

# install: a fresh volume gets core copied in and renders the installer. DEBUG_HEADERS exposes
# X-Cache for the cache checks below; the cache itself is on by default.
run_wp "$N-wp" "$N-vol" "$IMG" -e DEBUG_HEADERS=true
code="$(wait_http "$N-wp" /wp-admin/install.php)"
if [ "$code" = 200 ]; then pass install; else fail install "HTTP ${code}"; fi
PORT="$(port_of "$N-wp")"

# starting-page: while run.sh's starting flag exists, every request is a 503 with Retry-After and the
# holding page; once it is gone the site answers again (the flag is what covers a slow first boot).
docker exec "$N-wp" touch /var/run/wp-runtime/starting
h="$(headers_of "$N-wp" /wp-admin/install.php)"
body="$(curl -s "http://127.0.0.1:${PORT}/healthz")"
docker exec "$N-wp" rm -f /var/run/wp-runtime/starting
after="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/wp-admin/install.php")"
if grep -q '^HTTP/1.1 503' <<<"$h" && [ "$(header_value Retry-After <<<"$h")" = 5 ] \
        && grep -q 'starting up' <<<"$body" && [ "$after" = 200 ]; then
    pass starting-page
else
    fail starting-page "$(grep -E '^HTTP|^Retry' <<<"$h" | tr '\n' ' ') after=${after}"
fi

# fpm-loopback: PHP-FPM must not be reachable from the pod network.
tcp="$(docker exec "$N-wp" cat /proc/net/tcp /proc/net/tcp6 2>/dev/null)"
if grep -qE ' 0100007F:2328 0{8}:0000 0A ' <<<"$tcp" && ! grep -qE ' 0{8}:2328 0{8}:0000 0A | 0{32}:2328 0{32}:0000 0A ' <<<"$tcp"; then
    pass fpm-loopback
else
    fail fpm-loopback "$(grep -E ':2328 ' <<<"$tcp" | head -3 | tr '\n' ';')"
fi

# logs-stdout: nginx access log lines reach the container's stdout.
logs="$(docker logs "$N-wp" 2>&1)"
if grep -q '"GET /wp-admin/install.php' <<<"$logs"; then
    pass logs-stdout
else
    fail logs-stdout "no access log line in docker logs"
fi

# headers-static: security headers survive on static assets (headers-more, not add_header).
h="$(headers_of "$N-wp" /wp-includes/js/jquery/jquery.min.js)"
if grep -qi '^X-Frame-Options:' <<<"$h" && grep -qi '^X-Content-Type-Options:' <<<"$h" \
        && grep -qi '^Content-Security-Policy:' <<<"$h" && [ "$(grep -ci '^Cache-Control:' <<<"$h")" = 1 ]; then
    pass headers-static
else
    fail headers-static "$(grep -iE '^(X-|Content-Security|Cache-Control)' <<<"$h" | tr '\n' ' ' | head -c 300)"
fi

# hsts: only when the request came in over HTTPS, and without includeSubDomains.
hsts_https="$(headers_of "$N-wp" /wp-admin/install.php -H 'X-Forwarded-Proto: https' | header_value Strict-Transport-Security)"
hsts_http="$(headers_of "$N-wp" /wp-admin/install.php | header_value Strict-Transport-Security)"
if [ "$hsts_https" = "max-age=31536000" ] && [ -z "$hsts_http" ]; then
    pass hsts
else
    fail hsts "https='${hsts_https}' http='${hsts_http}'"
fi

# https-redirect: nginx's own redirects must not downgrade https visitors to http.
loc="$(headers_of "$N-wp" /wp-admin -H 'X-Forwarded-Proto: https' -H 'Host: example.test' | header_value Location)"
if [ "$loc" = "/wp-admin/" ]; then pass https-redirect; else fail https-redirect "Location: ${loc}"; fi

# wp-install: WP-CLI installs the site so the following checks hit real pages.
if wp_cli "$N-wp" core install --url="http://127.0.0.1:${PORT}" --title=Smoke --admin_user=smoke \
        --admin_password='smoke-pass-1' --admin_email=smoke@example.test --skip-email >/dev/null 2>&1 \
        && [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/")" = 200 ]; then
    pass wp-install
else
    fail wp-install "wp core install failed or / is not 200"
fi

# prepend-constants: the platform prepend applies (also to the CLI) and the mu-plugin is loaded.
# WP_MEMORY_LIMIT follows the container-sized php.ini memory_limit (256M here: no cgroup limit, so
# the host's memory is used) and WP_MAX_MEMORY_LIMIT is twice it.
consts="$(wp_cli "$N-wp" eval 'echo (DISABLE_WP_CRON ? "cron-off" : "cron-on"), " ", (DISALLOW_FILE_EDIT ? "noedit" : "edit"), " ", WP_MEMORY_LIMIT, "/", WP_MAX_MEMORY_LIMIT, " ", (function_exists("CodeCapsules\\Runtime\\purge_all") ? "mu-loaded" : "mu-missing");' 2>/dev/null)"
php_limit="$(docker exec "$N-wp" php -r 'echo ini_get("memory_limit");')"
if [ "$consts" = "cron-off noedit ${php_limit}/$(( 2 * ${php_limit%M} ))M mu-loaded" ]; then
    pass prepend-constants
else
    fail prepend-constants "'${consts}'"
fi

# prepend-respects-owner: a constant the owner defines in WORDPRESS_CONFIG_EXTRA is left alone.
# (`php -r` does not run auto_prepend_file, so the prepend is required explicitly; the control
# run without the owner's define proves the check can see the constant at all.)
owner="$(docker exec -e "WORDPRESS_CONFIG_EXTRA=define('WP_MEMORY_LIMIT', '96M');" "$N-wp" php -r 'require "/usr/share/wp-runtime/prepend.php"; echo defined("WP_MEMORY_LIMIT") ? "defined" : "skipped";')"
control="$(docker exec "$N-wp" php -r 'require "/usr/share/wp-runtime/prepend.php"; echo defined("WP_MEMORY_LIMIT") ? "defined" : "skipped";')"
if [ "$owner" = "skipped" ] && [ "$control" = "defined" ]; then
    pass prepend-respects-owner
else
    fail prepend-respects-owner "owner=${owner} control=${control}"
fi

# prepend-owner-cache: a constant wp-config.php defines is left to it (no "already defined" warning),
# the names found in wp-config.php are cached on local disk instead of being re-read from the volume
# on every request, and editing wp-config.php takes effect at once (the cache key includes the file's
# mtime and size).
docker exec -i "$N-wp" bash -c 'cat > /var/www/html/cc-smoke-max.php' <<'EOP'
<?php require __DIR__ . '/wp-load.php'; echo WP_MAX_MEMORY_LIMIT;
EOP
# OPcache revalidates files every 60s (opcache.revalidate_freq), so after each edit the compiled
# wp-config.php is invalidated explicitly, as a minute passing would.
docker exec -i "$N-wp" bash -c 'cat > /var/www/html/cc-smoke-opcache.php' <<'EOP'
<?php opcache_invalidate(__DIR__ . '/wp-config.php', true); echo 'ok';
EOP
docker exec "$N-wp" sed -i "1a define( 'WP_MAX_MEMORY_LIMIT', '300M' );" /var/www/html/wp-config.php
curl -s -o /dev/null "http://127.0.0.1:${PORT}/cc-smoke-opcache.php?s=1"
owned="$(curl -s "http://127.0.0.1:${PORT}/cc-smoke-max.php?s=1")"
cached="$(docker exec "$N-wp" sh -c 'grep -l WP_MAX_MEMORY_LIMIT /tmp/cc-runtime-defines-*.json 2>/dev/null | wc -l')"
docker exec "$N-wp" sed -i "/define( 'WP_MAX_MEMORY_LIMIT', '300M' );/d" /var/www/html/wp-config.php
curl -s -o /dev/null "http://127.0.0.1:${PORT}/cc-smoke-opcache.php?s=1"
sized="$(curl -s "http://127.0.0.1:${PORT}/cc-smoke-max.php?s=1")"
redefined="$(docker logs "$N-wp" 2>&1 | grep -c 'WP_MAX_MEMORY_LIMIT already defined')"
docker exec "$N-wp" rm -f /var/www/html/cc-smoke-max.php /var/www/html/cc-smoke-opcache.php
if [ "$owned" = 300M ] && [[ "$sized" =~ ^[0-9]+M$ ]] && [ "$sized" != 300M ] && [ "$cached" -ge 1 ] && [ "$redefined" = 0 ]; then
    pass prepend-owner-cache
else
    fail prepend-owner-cache "owned=${owned} after-edit=${sized} cache-files=${cached} already-defined-warnings=${redefined}"
fi

# cache-hit: the second anonymous GET of the front page is served from the page cache.
curl -s -o /dev/null "http://127.0.0.1:${PORT}/"
xc="$(headers_of "$N-wp" / | header_value X-Cache)"
if [ "$xc" = "HIT" ]; then pass cache-hit; else fail cache-hit "X-Cache: ${xc}"; fi

# cache-bypass-rules: shop-like slugs and plural query params are cached; search, the cart and the REST
# API under every spelling (?rest_route= on plain permalinks, /index.php/wp-json/) are not.
bypass_ok=1; detail=""
for path in /cartoons/ /accounting-tips/ "/?tags=news" "/shop/?filters=red"; do
    xc="$(headers_of "$N-wp" "$path" | header_value X-Cache)"
    [ "$xc" != "BYPASS" ] || { bypass_ok=0; detail="$detail $path=$xc"; }
done
for path in "/?s=hello" /cart/ "/checkout/?step=1" "/?add-to-cart=5" "/?rest_route=/" "/index.php/wp-json/"; do
    xc="$(headers_of "$N-wp" "$path" | header_value X-Cache)"
    [ "$xc" = "BYPASS" ] || { bypass_ok=0; detail="$detail $path=$xc"; }
done
if [ "$bypass_ok" = 1 ]; then pass cache-bypass-rules; else fail cache-bypass-rules "$detail"; fi

# cache-purge: publishing a post purges the page cache (mu-plugin -> nginx cache-purge module).
curl -s -o /dev/null "http://127.0.0.1:${PORT}/"
before="$(headers_of "$N-wp" / | header_value X-Cache)"
wp_cli "$N-wp" post create --post_title='Smoke post' --post_status=publish --porcelain >/dev/null 2>&1
after="$(headers_of "$N-wp" / | header_value X-Cache)"
if [ "$before" = "HIT" ] && [ "$after" = "MISS" ]; then
    pass cache-purge
else
    fail cache-purge "before=${before} after=${after}"
fi
purge_out="$(wp_cli "$N-wp" cc cache purge 2>&1)"
if grep -q 'Page cache purged' <<<"$purge_out"; then
    pass cache-purge-cli
else
    fail cache-purge-cli "wp cc cache purge did not succeed"
fi

# donotcachepage: a page WordPress marks DONOTCACHEPAGE is never stored (second view is still a
# MISS), the marker header the mu-plugin uses does not leak to the client, and an ordinary page
# with a query string is still cached (control).
docker exec -i "$N-wp" bash -c 'mkdir -p /var/www/html/wp-content/mu-plugins && cat > /var/www/html/wp-content/mu-plugins/cc-smoke-nocache.php' <<'EOP'
<?php
add_action('template_redirect', function () {
    if (isset($_GET['cc_smoke_nocache'])) {
        define('DONOTCACHEPAGE', true);
    }
    // The SEOPress/feed pattern: define the constant and end the request at priority 10.
    if (isset($_GET['cc_smoke_nocache_exit'])) {
        define('DONOTCACHEPAGE', true);
        echo 'exit-body';
        exit;
    }
});
EOP
curl -s -o /dev/null "http://127.0.0.1:${PORT}/?cc_smoke_nocache=1"
h="$(headers_of "$N-wp" "/?cc_smoke_nocache=1")"
curl -s -o /dev/null "http://127.0.0.1:${PORT}/?cc_smoke_nocache_exit=1"
hx="$(curl -s -D - "http://127.0.0.1:${PORT}/?cc_smoke_nocache_exit=1")"
curl -s -o /dev/null "http://127.0.0.1:${PORT}/?cc_smoke_cached=1"
control="$(headers_of "$N-wp" "/?cc_smoke_cached=1" | header_value X-Cache)"
docker exec "$N-wp" rm -f /var/www/html/wp-content/mu-plugins/cc-smoke-nocache.php
if [ "$(header_value X-Cache <<<"$h")" = "MISS" ] && ! grep -qi '^X-CC-No-Cache:' <<<"$h" \
        && [ "$(header_value X-Cache <<<"$hx")" = "MISS" ] && grep -q 'exit-body' <<<"$hx" && [ "$control" = "HIT" ]; then
    pass donotcachepage
else
    fail donotcachepage "nocache=$(header_value X-Cache <<<"$h") marker-leaked=$(grep -ci '^X-CC-No-Cache:' <<<"$h") exit=$(header_value X-Cache <<<"$hx") control=${control}"
fi

# rate-limit-login: wp-login.php is throttled per IP, and the 429s are visible in the logs.
codes=""
for _ in $(seq 1 15); do
    codes="$codes $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/wp-login.php")"
done
logs="$(docker logs "$N-wp" 2>&1)"
if grep -q 429 <<<"$codes" && grep -q 'limiting requests' <<<"$logs"; then
    pass rate-limit-login
else
    fail rate-limit-login "codes:${codes}"
fi

# sensitive-files: config copies, dumps and core internals are not served.
docker exec "$N-wp" bash -c 'echo x > /var/www/html/wp-config.old; echo x > /var/www/html/backup.sql; echo x > /var/www/html/wp-content/debug.log'
sens_ok=1; detail=""
for path in /wp-config.php /wp-config.old /backup.sql /wp-content/debug.log /wp-includes/version.php /wp-config-sample.php /.env; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}${path}")"
    [ "$code" = 404 ] || { sens_ok=0; detail="$detail $path=$code"; }
done
if [ "$sens_ok" = 1 ]; then pass sensitive-files; else fail sensitive-files "$detail"; fi

# xmlrpc-blocked by default.
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/xmlrpc.php")"
if [ "$code" = 403 ]; then pass xmlrpc-blocked; else fail xmlrpc-blocked "HTTP ${code}"; fi

# upload-size-sync: PHP's upload limit equals the nginx limit (both from MAX_UPLOAD_SIZE).
up="$(docker exec "$N-wp" php -r 'echo ini_parse_quantity(ini_get("upload_max_filesize")), " ", ini_parse_quantity(ini_get("post_max_size"));')"
if [ "$up" = "67108864 67108864" ]; then pass upload-size-sync; else fail upload-size-sync "$up"; fi

# metrics: served from outside the docroot, so it works with a volume over /var/www/html; the
# sizing in effect is exported too (run.sh's CC_SIZING_* reach PHP through clear_env=no).
metrics="$(docker exec "$N-wp" curl -s 127.0.0.1:8080/wp-metrics)"
if grep -qx 'wp_cron_trigger_enabled 1' <<<"$metrics" && grep -q '^wordpress_core_version_info{version=' <<<"$metrics" \
        && grep -qE '^cc_runtime_fpm_max_children [1-9][0-9]*$' <<<"$metrics" \
        && grep -qE '^cc_runtime_php_max_inflight_requests [1-9][0-9]*$' <<<"$metrics" \
        && grep -qE '^cc_runtime_php_memory_limit_bytes (134217728|268435456)$' <<<"$metrics"; then
    pass metrics
else
    fail metrics "$(grep -E '^(cc_runtime|wp_cron_trigger_enabled|wordpress_core)' <<<"$metrics" | tr '\n' ' ' | head -c 300)"
fi

# metrics-port: the same metrics are scrapeable from the pod network at :9254/metrics (the loopback
# server above is not), and that port serves nothing else.
podip="$(docker exec "$N-wp" hostname -i | awk '{print $1}')"
pod_metrics="$(docker exec "$N-wp" curl -s "http://${podip}:9254/metrics")"
pod_other="$(docker exec "$N-wp" curl -s -o /dev/null -w '%{http_code}' "http://${podip}:9254/wp-metrics")"
if grep -qE '^cc_runtime_fpm_max_children [1-9][0-9]*$' <<<"$pod_metrics" \
        && grep -q '^wp_cron_trigger_last_success_timestamp_seconds ' <<<"$pod_metrics" && [ "$pod_other" = 404 ]; then
    pass metrics-port
else
    fail metrics-port "ip=${podip} other=${pod_other} $(head -c 120 <<<"$pod_metrics")"
fi

# httpoxy: a client's Proxy request header never reaches PHP as HTTP_PROXY (CVE-2016-5385).
docker exec -i "$N-wp" bash -c 'cat > /var/www/html/cc-smoke-proxy.php' <<'EOP'
<?php echo var_export(getenv('HTTP_PROXY'), true), '|', var_export($_SERVER['HTTP_PROXY'] ?? null, true);
EOP
proxy="$(curl -s -H 'Proxy: http://evil.test:3128' "http://127.0.0.1:${PORT}/cc-smoke-proxy.php?s=1")"
docker exec "$N-wp" rm -f /var/www/html/cc-smoke-proxy.php
if [ -n "$proxy" ] && ! grep -q 'evil.test' <<<"$proxy"; then pass httpoxy; else fail httpoxy "${proxy:-empty response}"; fi

# fpm-sizing: the pool was derived from the limits (3..64 children), listens on loopback, and the
# nginx in-flight cap follows it (4 per worker, at least 8).
pool="$(docker exec "$N-wp" cat /usr/local/etc/php-fpm.d/zzz-custom.conf)"
children="$(sed -n 's/^pm\.max_children = \([0-9]*\)$/\1/p' <<<"$pool")"
inflight="$(docker exec "$N-wp" sed -n 's/^    server 127.0.0.1:9000 max_conns=\([0-9]*\);$/\1/p' /etc/nginx/conf.d/generated_upstream.conf)"
if [ -n "$children" ] && [ "$children" -ge 3 ] && [ "$children" -le 64 ] && grep -qx 'listen = 127.0.0.1:9000' <<<"$pool" \
        && [ "$inflight" = "$(( children * 4 > 8 ? children * 4 : 8 ))" ]; then
    pass fpm-sizing
else
    fail fpm-sizing "pm.max_children='${children}' inflight='${inflight}'"
fi

# sized-limits: with cgroup limits (1 GiB, 0.25 CPU) the sizing is deterministic: 3 workers, 128M
# requests, 176M OPcache, a 12-connection cap, and (seen through php-fpm, where run.sh's exports
# apply) WP_MEMORY_LIMIT 128M / WP_MAX_MEMORY_LIMIT 256M and ImageMagick bounded to 128/256 MiB.
run_wp "$N-sized" "" "$IMG" --memory 1g --cpus 0.25 -e WP_CRON_TRIGGER_ENABLED=false
wait_http "$N-sized" /healthz 150 >/dev/null
sized_files="$(docker exec "$N-sized" bash -c '
    sed -n "s/^pm\.max_children = //p" /usr/local/etc/php-fpm.d/zzz-custom.conf
    sed -n "s/^    server 127.0.0.1:9000 max_conns=\([0-9]*\);$/\1/p" /etc/nginx/conf.d/generated_upstream.conf
    sed -n "s/^memory_limit = //p" "$PHP_INI_DIR/conf.d/zz-custom.ini"
    sed -n "s/^opcache\.memory_consumption = //p" "$PHP_INI_DIR/conf.d/zz-custom.ini"' | tr '\n' ' ')"
docker exec -i "$N-sized" bash -c 'cat > /var/www/html/cc-smoke-env.php' <<'EOP'
<?php
$mb = static fn($v) => $v >= 1048576 ? intdiv((int) $v, 1048576) : (int) $v;
echo ini_get('memory_limit'), ' ', WP_MEMORY_LIMIT, ' ', WP_MAX_MEMORY_LIMIT, ' ',
    $mb(Imagick::getResourceLimit(Imagick::RESOURCETYPE_MEMORY)), ' ', $mb(Imagick::getResourceLimit(Imagick::RESOURCETYPE_MAP));
EOP
sport="$(port_of "$N-sized")"
sized_http="$(curl -s "http://127.0.0.1:${sport}/cc-smoke-env.php")"
sized_log="$(docker logs "$N-sized" 2>&1 | grep -c '\[sizing\] Container limits (cgroup): memory=1024M cpu=250m')"
if [ "$sized_files" = "3 12 128M 176 " ] && [ "$sized_http" = "128M 128M 256M 128 256" ] && [ "$sized_log" = 1 ]; then
    pass sized-limits
else
    fail sized-limits "files='${sized_files}' http='${sized_http}' log=${sized_log}"
fi

# inflight-cap: past the pool's connection cap nginx answers 503 + Retry-After at once instead of
# queueing. 20 concurrent 2s requests against 3 workers and a cap of 12: the admitted ones all
# complete (no keep-alive stall), the rest are immediate 503s with the busy page. The requests
# bypass the page cache (?s= is a search): a cacheable URL would be rendered once and the other 19
# served as cache HITs from behind fastcgi_cache_lock, which is exactly what the cap must not shed.
docker exec -i "$N-sized" bash -c 'cat > /var/www/html/cc-smoke-slow.php' <<'EOP'
<?php usleep(2000000); echo "slow";
EOP
codes_file="$(mktemp)"
for _ in $(seq 1 20); do
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 60 "http://127.0.0.1:${sport}/cc-smoke-slow.php?s=1" >>"$codes_file" &
done
wait
n200="$(grep -c '^200$' "$codes_file")"; n503="$(grep -c '^503$' "$codes_file")"; rm -f "$codes_file"
busy="$(for _ in $(seq 1 14); do curl -s -o /dev/null "http://127.0.0.1:${sport}/cc-smoke-slow.php?s=1" & done; sleep 0.5; curl -s -D - "http://127.0.0.1:${sport}/cc-smoke-slow.php?s=1"; wait)"
if [ "$n200" -ge 3 ] && [ "$n503" -ge 1 ] && [ $(( n200 + n503 )) -eq 20 ] \
        && grep -q 'busy right now' <<<"$busy" && [ "$(header_value Retry-After <<<"$busy")" = 5 ]; then
    pass inflight-cap
else
    fail inflight-cap "200=${n200} 503=${n503} busy-page=$(grep -c 'busy right now' <<<"$busy")"
fi

# upstream-crash: a request whose PHP worker dies mid-request (here the script kills its own worker,
# as an OOM kill or request_terminate_timeout would) is a plain 502, not the busy page: only the
# capacity cap ("no live upstreams", $upstream_addr carrying the upstream name rather than an
# address) gets the holding page and its auto-refresh.
docker exec -i "$N-sized" bash -c 'cat > /var/www/html/cc-smoke-crash.php' <<'EOP'
<?php posix_kill(getmypid(), 9);
EOP
crash="$(curl -s -D - "http://127.0.0.1:${sport}/cc-smoke-crash.php?s=1")"
crash_code="$(head -1 <<<"$crash" | awk '{print $2}')"
if [ "$crash_code" = 502 ] && ! grep -q 'busy right now' <<<"$crash"; then
    pass upstream-crash
else
    fail upstream-crash "HTTP ${crash_code} busy-page=$(grep -c 'busy right now' <<<"$crash")"
fi
docker rm -f "$N-sized" >/dev/null

# pinned-overrides: a customer pin PHP-FPM accepts (trailing comment, quoted value) is fed back
# into the sizing and the pool starts: php-fpm -t passes, the spares follow the pinned count, the
# worker budget follows the pinned limit, and the capacity cap follows the pool.
run_wp "$N-pinned" "" "$IMG" --memory 1g --cpus 0.25 -e WP_CRON_TRIGGER_ENABLED=false \
    -e WORDPRESS_FPM_CONF=$'[www]\npm.max_children = 4 ; keep it small' -e WORDPRESS_CUSTOM_INI='memory_limit = "192M"'
code="$(wait_http "$N-pinned" /healthz 150)"
fpm_t="$(docker exec "$N-pinned" php-fpm -t 2>&1 | tail -1)"
plogs="$(docker logs "$N-pinned" 2>&1)"
pinned="$(docker exec "$N-pinned" bash -c '
    sed -n "s/^pm\.max_spare_servers = //p" /usr/local/etc/php-fpm.d/zzz-custom.conf
    sed -n "s/^    server 127.0.0.1:9000 max_conns=\([0-9]*\);$/\1/p" /etc/nginx/conf.d/generated_upstream.conf
    php -r "echo ini_get(\"memory_limit\");"' | tr '\n' ' ')"
if [ "$code" = 200 ] && grep -q 'test is successful' <<<"$fpm_t" && grep -q 'pm.max_children pinned to 4' <<<"$plogs" \
        && grep -q 'worker_budget=96M' <<<"$plogs" && [ "$pinned" = "2 16 192M" ]; then
    pass pinned-overrides
else
    fail pinned-overrides "healthz=${code} fpm-t='${fpm_t}' values='${pinned}'"
fi
docker rm -f "$N-pinned" >/dev/null

# env-fallback: settings nginx would reject, or that are plain invalid, fall back to the defaults and
# the site comes up. Before, a /33 CIDR or an oversized size passed validation and failed nginx -t, and
# a rejected value was no better: the validator's log line ended up inside the fallback value, so
# the generated config failed nginx -t either way and the pod crash-looped.
# The same container carries misspelt on/off switches and timeouts, checked below.
run_wp "$N-badenv" "" "$IMG" -e WP_CRON_TRIGGER_ENABLED=false -e TRUSTED_PROXY_CIDRS=10.0.0.0/8,10.0.0.0/33 \
    -e MAX_UPLOAD_SIZE=99999999999G -e CACHE_MAX_SIZE=99999999999G -e RATE_LIMIT_MAX_CONN_PER_IP=70000 \
    -e NGINX_WORKER_PROCESSES=99999 -e 'CSP_HEADER=default-src "self"' \
    -e DISABLE_PUBLIC_WP_CRON=ture -e XMLRPC_ENABLED=yess -e DEBUG_HEADERS=tru -e CACHE_SKIP_EMPTY=nope \
    -e WP_DISALLOW_FILE_EDIT=flase -e SHUTDOWN_TIMEOUT_SECONDS=20s -e FPM_STARTUP_TIMEOUT_SECONDS=10m
code="$(wait_http "$N-badenv" /healthz 150)"
blogs="$(docker logs "$N-badenv" 2>&1)"
n_invalid="$(grep '^\[nginx-overrides\] Invalid' <<<"$blogs" | grep -vc 'yes/no or on/off')"
up="$(docker exec "$N-badenv" php -r 'echo ini_get("upload_max_filesize");' 2>&1)"
if [ "$code" = 200 ] && [ "$n_invalid" = 6 ] && [ "$up" = 64M ] && ! grep -q 'test failed' <<<"$blogs"; then
    pass env-fallback
else
    fail env-fallback "healthz=${code} invalid-lines=${n_invalid} upload_max_filesize='${up}' $(grep -m1 'emerg' <<<"$blogs")"
fi

# switch-fallback: a misspelt on/off switch falls back to its default, with a log line. It used to
# count silently as the other state: DISABLE_PUBLIC_WP_CRON=ture made wp-cron.php public.
n_switch="$(grep -c "^\[nginx-overrides\] Invalid .* yes/no or on/off). Falling back to" <<<"$blogs")"
bport="$(port_of "$N-badenv")"
cron_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${bport}/wp-cron.php")"
xmlrpc_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${bport}/xmlrpc.php")"
edit="$(docker exec "$N-badenv" php -r 'require "/usr/share/wp-runtime/prepend.php"; echo DISALLOW_FILE_EDIT ? "noedit" : "edit";' 2>&1)"
# This container's WP_CRON_TRIGGER_ENABLED=false is a real off value: the metric must say 0, or an
# alert on wp_cron_trigger_enabled == 1 would fire for every capsule that turned the trigger off.
off_metric="$(docker exec "$N-badenv" curl -s 127.0.0.1:8080/wp-metrics | sed -n 's/^wp_cron_trigger_enabled //p')"
if [ "$n_switch" = 4 ] && [ "$cron_code" = 403 ] && [ "$xmlrpc_code" = 403 ] && [ "$edit" = noedit ] \
        && [ "$off_metric" = 0 ] && grep -q "^\[custom-ini\] Invalid WP_DISALLOW_FILE_EDIT value 'flase'" <<<"$blogs"; then
    pass switch-fallback
else
    fail switch-fallback "switch-lines=${n_switch} wp-cron=${cron_code} xmlrpc=${xmlrpc_code} file-edit=${edit} wp_cron_trigger_enabled=${off_metric:-none}"
fi

# timeout-fallback: a timeout that is not a whole number falls back to its default. 20s used to
# break the arithmetic in the TERM handler, so run.sh died without waiting for in-flight requests.
start=$(date +%s)
docker stop -t 30 "$N-badenv" >/dev/null
took=$(( $(date +%s) - start ))
exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$N-badenv")"
blogs="$(docker logs "$N-badenv" 2>&1)"
if [ "$exit_code" = 0 ] && [ "$took" -lt 10 ] && grep -q '\[run\] Shutting down (exit 0)' <<<"$blogs" \
        && grep -q "^\[run\] Invalid SHUTDOWN_TIMEOUT_SECONDS value '20s'" <<<"$blogs" \
        && grep -q "^\[run\] Invalid FPM_STARTUP_TIMEOUT_SECONDS value '10m'" <<<"$blogs"; then
    pass timeout-fallback
else
    fail timeout-fallback "took ${took}s, exit ${exit_code}; $(grep '^\[run\] Invalid' <<<"$blogs" | tr '\n' ' ')"
fi
docker rm -f "$N-badenv" >/dev/null

# cron-multisite: every site of a multisite network gets its cron run. The trigger used to ask for a
# site called 127.0.0.1, which WordPress cannot route (it redirects and exits after wp-cron.php has
# already answered 200), so no site's cron ever ran while the trigger reported success.
docker exec "$N-db" mysql -uroot -ppw -e 'CREATE DATABASE wpms' >/dev/null 2>&1
# WP_HTTP_BLOCK_EXTERNAL: a new site's first cron run checks for core/plugin/theme updates over the
# internet; blocked, it cannot hold the site's cron lock (60s) while the check waits for the event.
run_wp "$N-ms" "" "$IMG" -e WORDPRESS_DB_NAME=wpms -e WP_CRON_TRIGGER_INTERVAL_SECONDS=2 -e WP_CRON_TRIGGER_TARGETS_REFRESH_SECONDS=3 \
    -e "WORDPRESS_CONFIG_EXTRA=define('WP_HTTP_BLOCK_EXTERNAL', true);"
wait_http "$N-ms" /healthz 150 >/dev/null
ms_ok=1
wp_cli "$N-ms" core multisite-install --url=http://cc-smoke.test --title=MS --admin_user=smoke \
    --admin_password='smoke-pass-1' --admin_email=smoke@example.test --skip-email >/dev/null 2>&1 || ms_ok=0
wp_cli "$N-ms" site create --slug=sub --url=http://cc-smoke.test >/dev/null 2>&1 || ms_ok=0
docker exec -i "$N-ms" bash -c 'mkdir -p /var/www/html/wp-content/mu-plugins && cat > /var/www/html/wp-content/mu-plugins/cc-smoke-cron.php' <<'EOP'
<?php
add_action('cc_smoke_cron', function () {
    file_put_contents('/tmp/cc-smoke-cron-' . get_current_blog_id(), (string) time());
});
EOP
for url in http://cc-smoke.test/ http://cc-smoke.test/sub/; do
    wp_cli "$N-ms" --url="$url" eval 'wp_schedule_single_event(time() - 60, "cc_smoke_cron");' >/dev/null 2>&1 || ms_ok=0
done
ran=""
for _ in $(seq 1 75); do
    sleep 1
    ran="$(docker exec "$N-ms" sh -c 'ls /tmp/cc-smoke-cron-* 2>/dev/null' | sort | xargs)"
    [ "$ran" = "/tmp/cc-smoke-cron-1 /tmp/cc-smoke-cron-2" ] && break
done
mslogs="$(docker logs "$N-ms" 2>&1)"
hb="$(docker exec "$N-ms" cat /var/run/wp-runtime/cron-last-run)"
if [ "$ms_ok" = 1 ] && [ "$ran" = "/tmp/cc-smoke-cron-1 /tmp/cc-smoke-cron-2" ] && [ -n "$hb" ] \
        && grep -q '\[wp-cron-trigger\] 2 site(s), up to 3 per run:' <<<"$mslogs" \
        && grep '\[wp-cron-trigger\] 2 site(s)' <<<"$mslogs" | grep -q 'http://cc-smoke.test/sub/'; then
    pass cron-multisite
else
    sub_lock="$(wp_cli "$N-ms" --url=http://cc-smoke.test/sub/ transient get doing_cron 2>&1 | tail -1)"
    sub_events="$(wp_cli "$N-ms" --url=http://cc-smoke.test/sub/ cron event list --fields=hook,next_run_relative --format=csv 2>&1 | grep -c cc_smoke_cron)"
    sub_hits="$(grep -c '"GET /sub/wp-cron.php?doing_wp_cron HTTP/1.1" 200' <<<"$mslogs")"
    fail cron-multisite "setup=${ms_ok} ran='${ran}' heartbeat='${hb}' sub: lock='${sub_lock}' event-still-scheduled=${sub_events} trigger-hits=${sub_hits}; $(grep '\[wp-cron-trigger\]' <<<"$mslogs" | tail -3 | tr '\n' ' ')"
fi
docker rm -f "$N-ms" >/dev/null

# graceful-stop: a stop finishes well inside the grace period, exits 0, and shuts down cleanly.
start=$(date +%s)
docker stop -t 30 "$N-wp" >/dev/null
took=$(( $(date +%s) - start ))
exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$N-wp")"
logs="$(docker logs "$N-wp" 2>&1)"
if [ "$took" -lt 10 ] && [ "$exit_code" = 0 ] && grep -q '\[run\] Shutting down (exit 0)' <<<"$logs"; then
    pass graceful-stop
else
    fail graceful-stop "took ${took}s, exit ${exit_code}"
fi

# existing-volume: an existing volume's core is never touched by (re)starting the image.
docker rm -f "$N-wp" >/dev/null
run_wp "$N-wp2" "$N-vol" "$IMG"
wait_http "$N-wp2" /healthz >/dev/null
docker exec "$N-wp2" sed -i "s/^\$wp_version = .*/\$wp_version = '6.5.5';/" /var/www/html/wp-includes/version.php
docker rm -f "$N-wp2" >/dev/null
# WP_CRON_TRIGGER_ENABLED is misspelt on purpose: it falls back to on (cron-switch-fallback below).
run_wp "$N-wp3" "$N-vol" "$IMG" -e WP_CRON_TRIGGER_INTERVAL_SECONDS=2 -e WP_CRON_TRIGGER_TARGETS_REFRESH_SECONDS=3 \
    -e WP_CRON_TRIGGER_ENABLED=enabled
wait_http "$N-wp3" /healthz >/dev/null
marker="$(docker exec "$N-wp3" grep '^\$wp_version' /var/www/html/wp-includes/version.php)"
if [ "$marker" = "\$wp_version = '6.5.5';" ]; then
    pass existing-volume
else
    fail existing-volume "${marker:-version.php missing}"
fi

# cron-honest-https: the trigger asks for the site the way its visitors reach it (host and scheme
# from the site URL), and the heartbeat comes from PHP, only when the cron dispatcher really ran.
# A plugin that ends plain-HTTP requests early (as HTTPS-forcing plugins do) stops cron while the
# site URL is http: every trigger request still gets its 200, but the heartbeat must stay empty.
# Once the site URL is https the trigger sends X-Forwarded-Proto: https and the event runs.
# This container's WP_CRON_TRIGGER_ENABLED is misspelt on purpose: if this check fails together with
# cron-switch-fallback, look at the switch's fallback first.
port3="$(port_of "$N-wp3")"
docker exec -i "$N-wp3" bash -c 'mkdir -p /var/www/html/wp-content/mu-plugins && cat > /var/www/html/wp-content/mu-plugins/cc-smoke-cron.php' <<'EOP'
<?php
add_action('init', function () {
    if (wp_doing_cron() && !is_ssl()) {
        exit;
    }
}, 0);
add_action('cc_smoke_cron', function () {
    file_put_contents('/tmp/cc-smoke-cron-' . get_current_blog_id(), (string) time());
});
EOP
wp_cli "$N-wp3" eval 'wp_schedule_single_event(time() - 60, "cc_smoke_cron");' >/dev/null 2>&1
sleep 2
docker exec "$N-wp3" sh -c ': > /var/run/wp-runtime/cron-last-run'
sleep 8
hb_http="$(docker exec "$N-wp3" cat /var/run/wp-runtime/cron-last-run)"
ran_http="$(docker exec "$N-wp3" sh -c 'ls /tmp/cc-smoke-cron-1 2>/dev/null | wc -l')"
answered="$(docker logs --since 9s "$N-wp3" 2>&1 | grep -c '"GET /wp-cron.php?doing_wp_cron HTTP/1.1" 200')"
wp_cli "$N-wp3" option update siteurl "https://127.0.0.1:${port3}" >/dev/null 2>&1
wp_cli "$N-wp3" option update home "https://127.0.0.1:${port3}" >/dev/null 2>&1
ran=0
for _ in $(seq 1 30); do
    sleep 1
    docker exec "$N-wp3" test -f /tmp/cc-smoke-cron-1 && { ran=1; break; }
done
hb_https="$(docker exec "$N-wp3" cat /var/run/wp-runtime/cron-last-run)"
metric="$(docker exec "$N-wp3" curl -s 127.0.0.1:8080/wp-metrics | sed -n 's/^wp_cron_trigger_last_success_timestamp_seconds //p')"
if [ -z "$hb_http" ] && [ "$ran_http" = 0 ] && [ "$answered" -ge 2 ] && [ "$ran" = 1 ] && [ -n "$hb_https" ] \
        && [ "${metric:-0}" -gt 0 ] && docker logs "$N-wp3" 2>&1 | grep -q "\[wp-cron-trigger\] 1 site(s), up to 3 per run: https://127.0.0.1:${port3}/"; then
    pass cron-honest-https
else
    fail cron-honest-https "http: heartbeat='${hb_http}' ran=${ran_http} answered-200=${answered}; https: ran=${ran} heartbeat='${hb_https}' metric=${metric:-none}"
fi

# cron-switch-fallback: the misspelt WP_CRON_TRIGGER_ENABLED=enabled above is logged and counts as
# on everywhere: the trigger runs (cron-honest-https), WordPress's spawner stays off, and the
# metrics say enabled. It used to stop the trigger with the spawner still off: no cron at all.
w3logs="$(docker logs "$N-wp3" 2>&1)"
spawner="$(wp_cli "$N-wp3" eval 'echo DISABLE_WP_CRON ? "cron-off" : "cron-on";' 2>/dev/null)"
enabled_metric="$(docker exec "$N-wp3" curl -s 127.0.0.1:8080/wp-metrics | sed -n 's/^wp_cron_trigger_enabled //p')"
if grep -q "^\[run\] Invalid WP_CRON_TRIGGER_ENABLED value 'enabled'" <<<"$w3logs" \
        && grep -q '^\[wp-cron-trigger\] internal trigger loop starting' <<<"$w3logs" \
        && [ "$spawner" = cron-off ] && [ "$enabled_metric" = 1 ]; then
    pass cron-switch-fallback
else
    fail cron-switch-fallback "spawner=${spawner} wp_cron_trigger_enabled=${enabled_metric:-none} $(grep -m1 'WP_CRON_TRIGGER_ENABLED' <<<"$w3logs")"
fi

# healthz: 200 while FPM is up; non-200 (or the container exits non-zero) once FPM dies.
code="$(wait_http "$N-wp3" /healthz)"
if [ "$code" != 200 ]; then
    fail healthz "HTTP ${code} with FPM up"
else
    port="$(port_of "$N-wp3")"
    kill_fpm_master "$N-wp3"
    result="still 200 after 10s"
    for _ in $(seq 1 10); do
        sleep 1
        if [ "$(docker inspect -f '{{.State.Running}}' "$N-wp3")" != true ]; then
            exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$N-wp3")"
            [ "$exit_code" != 0 ] && result="" || result="container exited 0"
            break
        fi
        code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/healthz")"
        [ "$code" != 200 ] && { result=""; break; }
    done
    if [ -z "$result" ]; then pass healthz; else fail healthz "$result"; fi
fi

# git-variant: git/Dockerfile layers a repo over this runtime.
cp git/Dockerfile git/.dockerignore "$GIT_CTX/"
mkdir -p "$GIT_CTX/wp-html"
printf '<?php echo "git-ok";\n' > "$GIT_CTX/wp-html/index.php"
if docker buildx build "$GIT_CTX" --platform linux/amd64 --load -q \
        --build-arg RUNTIME_IMAGE="$IMG" -t "$GIT_IMG" >/dev/null; then
    run_wp "$N-git" "" "$GIT_IMG"
    wait_http "$N-git" /healthz >/dev/null
    body="$(curl -s "http://127.0.0.1:$(port_of "$N-git")/")"
    if grep -q git-ok <<<"$body"; then pass git-variant; else fail git-variant "$(head -c 200 <<<"$body")"; fi
else
    fail git-variant "build failed"
fi

exit "$FAILED"
