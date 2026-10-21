#!/usr/bin/env bash
# Pushes both tags produced by ./docker_build.sh <wp-version>.
# Usage: ./docker_push.sh 6.9
set -euo pipefail

WP_VERSION="${1:?usage: $0 <wp-version>}"
IMAGE=europe-west4-docker.pkg.dev/appstrax/main/wordpress

PHP_VERSION="$(docker run --rm --platform linux/amd64 --entrypoint php "${IMAGE}:${WP_VERSION}" -r 'echo PHP_VERSION;')"
docker push "${IMAGE}:${WP_VERSION}-php${PHP_VERSION}"
docker push "${IMAGE}:${WP_VERSION}"
