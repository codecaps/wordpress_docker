#!/usr/bin/env bash
# Smoke-tests one runtime image against a throwaway MySQL. Each check prints PASS/FAIL <name>;
# exits 0 only if every check passes.
# Usage: tests/smoke.sh <image-ref> <min-php-version>
#   e.g. tests/smoke.sh europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime:php8.4-r1 8.4.27
set -uo pipefail
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
    docker rm -f "$N-wp" "$N-wp2" "$N-git" "$N-db" >/dev/null 2>&1
    docker volume rm "$N-vol" >/dev/null 2>&1
    docker network rm "$N" >/dev/null 2>&1
    docker rmi "$GIT_IMG" >/dev/null 2>&1
    rm -rf "$GIT_CTX"
}
trap cleanup EXIT

# Starts a WordPress container named $1 on volume $2 (or none when empty) from image $3.
run_wp() {
    local volume_args=()
    [ -n "$2" ] && volume_args=(-v "$2:/var/www/html")
    docker run -d --platform linux/amd64 --name "$1" --network "$N" -p 0:80 \
        -e WORDPRESS_DB_HOST="$N-db" -e WORDPRESS_DB_USER=root -e WORDPRESS_DB_PASSWORD=pw \
        -e WORDPRESS_DB_NAME=wp ${volume_args[@]+"${volume_args[@]}"} "$3" >/dev/null
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

# extensions
modules="$(docker run --rm --platform linux/amd64 --entrypoint php "$IMG" -m)"
missing=""
for ext in redis imagick mysqli; do
    grep -qx "$ext" <<<"$modules" || missing="$missing $ext"
done
grep -qiE '^(zend )?opcache$' <<<"$modules" || missing="$missing opcache"
if [ -z "$missing" ]; then pass extensions; else fail extensions "missing${missing}"; fi

# install: a fresh volume gets core copied in and renders the installer.
run_wp "$N-wp" "$N-vol" "$IMG"
code="$(wait_http "$N-wp" /wp-admin/install.php)"
if [ "$code" = 200 ]; then pass install; else fail install "HTTP ${code}"; fi

# metrics: served from outside the docroot, so it works with a volume over /var/www/html.
metrics="$(docker exec "$N-wp" curl -s 127.0.0.1:8080/wp-metrics)"
if grep -qx 'wp_cron_trigger_enabled 1' <<<"$metrics"; then
    pass metrics
else
    fail metrics "$(head -c 200 <<<"$metrics")"
fi

# existing-volume: an existing volume's core is never touched by (re)starting the image.
docker exec "$N-wp" sed -i "s/^\$wp_version = .*/\$wp_version = '6.5.5';/" /var/www/html/wp-includes/version.php
docker rm -f "$N-wp" >/dev/null
run_wp "$N-wp2" "$N-vol" "$IMG"
wait_http "$N-wp2" /healthz >/dev/null
marker="$(docker exec "$N-wp2" grep '^\$wp_version' /var/www/html/wp-includes/version.php)"
if [ "$marker" = "\$wp_version = '6.5.5';" ]; then
    pass existing-volume
else
    fail existing-volume "${marker:-version.php missing}"
fi

# healthz: 200 while FPM is up; non-200 (or the container exits non-zero) once FPM dies.
code="$(wait_http "$N-wp2" /healthz)"
if [ "$code" != 200 ]; then
    fail healthz "HTTP ${code} with FPM up"
else
    port="$(port_of "$N-wp2")"
    kill_fpm_master "$N-wp2"
    result="still 200 after 10s"
    for _ in $(seq 1 10); do
        sleep 1
        if [ "$(docker inspect -f '{{.State.Running}}' "$N-wp2")" != true ]; then
            exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$N-wp2")"
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
