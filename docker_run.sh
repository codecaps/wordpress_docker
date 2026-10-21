#!/usr/bin/env bash
# Runs a locally built runtime (./build.sh <minor>) on :8000 against a MySQL on the host.
# Usage: ./docker_run.sh [php-minor, default 8.4]
set -euo pipefail

MINOR="${1:-8.4}"

docker run \
--add-host host.docker.internal:host-gateway \
-e WORDPRESS_DB_HOST=host.docker.internal:3306 \
-e WORDPRESS_DB_USER='root' \
-e WORDPRESS_DB_PASSWORD='qwerty' \
-e WORDPRESS_DB_NAME='wordpress' \
-e WORDPRESS_DEBUG=true \
-e SESSION_COOKIE_SECURE=0 \
-p 8000:80 \
--rm \
--name wordpress \
-v wordpress:/var/www/html \
-e CACHE_TTL_SECONDS=60 \
-d "europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime:php${MINOR}"
