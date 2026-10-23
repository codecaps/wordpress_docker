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
    docker rm -f "$N-wp" "$N-wp2" "$N-wp3" "$N-git" "$N-db" >/dev/null 2>&1
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

# Polls GET $2 on container $1 for up to 120s; prints the last status code.
wait_http() {
    local code=000 port
    port="$(port_of "$1")"
    for _ in $(seq 1 60); do
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
consts="$(wp_cli "$N-wp" eval 'echo (DISABLE_WP_CRON ? "cron-off" : "cron-on"), " ", (DISALLOW_FILE_EDIT ? "noedit" : "edit"), " ", WP_MEMORY_LIMIT, " ", (function_exists("CodeCapsules\\Runtime\\purge_all") ? "mu-loaded" : "mu-missing");' 2>/dev/null)"
if [ "$consts" = "cron-off noedit 256M mu-loaded" ]; then
    pass prepend-constants
else
    fail prepend-constants "'${consts}'"
fi

# prepend-respects-owner: a constant the owner defines in WORDPRESS_CONFIG_EXTRA is left alone.
owner="$(docker exec -e "WORDPRESS_CONFIG_EXTRA=define('WP_MEMORY_LIMIT', '96M');" "$N-wp" php -r 'echo defined("WP_MEMORY_LIMIT") ? "defined" : "skipped";')"
if [ "$owner" = "skipped" ]; then pass prepend-respects-owner; else fail prepend-respects-owner "$owner"; fi

# cache-hit: the second anonymous GET of the front page is served from the page cache.
curl -s -o /dev/null "http://127.0.0.1:${PORT}/"
xc="$(headers_of "$N-wp" / | header_value X-Cache)"
if [ "$xc" = "HIT" ]; then pass cache-hit; else fail cache-hit "X-Cache: ${xc}"; fi

# cache-bypass-rules: shop-like slugs and plural query params are cached; search and the cart are not.
bypass_ok=1; detail=""
for path in /cartoons/ /accounting-tips/ "/?tags=news" "/shop/?filters=red"; do
    xc="$(headers_of "$N-wp" "$path" | header_value X-Cache)"
    [ "$xc" != "BYPASS" ] || { bypass_ok=0; detail="$detail $path=$xc"; }
done
for path in "/?s=hello" /cart/ "/checkout/?step=1" "/?add-to-cart=5"; do
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

# metrics: served from outside the docroot, so it works with a volume over /var/www/html.
metrics="$(docker exec "$N-wp" curl -s 127.0.0.1:8080/wp-metrics)"
if grep -qx 'wp_cron_trigger_enabled 1' <<<"$metrics" && grep -q '^wordpress_core_version_info{version=' <<<"$metrics"; then
    pass metrics
else
    fail metrics "$(head -c 200 <<<"$metrics")"
fi

# fpm-sizing: the pool was derived from the cgroup limits (2..64 children) and listens on loopback.
pool="$(docker exec "$N-wp" cat /usr/local/etc/php-fpm.d/zzz-custom.conf)"
children="$(sed -n 's/^pm\.max_children = \([0-9]*\)$/\1/p' <<<"$pool")"
if [ -n "$children" ] && [ "$children" -ge 2 ] && [ "$children" -le 64 ] && grep -qx 'listen = 127.0.0.1:9000' <<<"$pool"; then
    pass fpm-sizing
else
    fail fpm-sizing "pm.max_children='${children}'"
fi

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
run_wp "$N-wp3" "$N-vol" "$IMG"
wait_http "$N-wp3" /healthz >/dev/null
marker="$(docker exec "$N-wp3" grep '^\$wp_version' /var/www/html/wp-includes/version.php)"
if [ "$marker" = "\$wp_version = '6.5.5';" ]; then
    pass existing-volume
else
    fail existing-volume "${marker:-version.php missing}"
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
