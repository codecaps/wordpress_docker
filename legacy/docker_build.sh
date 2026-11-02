#!/usr/bin/env bash
# Builds v_<wp-version>/ and tags it twice: the moving wordpress:<wp-version> tag and an immutable
# wordpress:<wp-version>-php<php-version> tag that capsule-api deploys (a re-pushed moving tag
# never reaches running pods: IfNotPresent + an unchanged pod spec means no rollout).
# Usage: ./docker_build.sh 6.9 [extra docker buildx args, e.g. --build-arg MIN_PHP_VERSION=...]
set -euo pipefail
cd "$(dirname "$0")"

WP_VERSION="${1:?usage: $0 <wp-version> [buildx args...]}"
shift
IMAGE=europe-west4-docker.pkg.dev/appstrax/main/wordpress

docker buildx build "v_${WP_VERSION}" --platform linux/amd64 --progress=auto --pull --load \
  -t "${IMAGE}:${WP_VERSION}" "$@"

PHP_VERSION="$(docker run --rm --platform linux/amd64 --entrypoint php "${IMAGE}:${WP_VERSION}" -r 'echo PHP_VERSION;')"
docker tag "${IMAGE}:${WP_VERSION}" "${IMAGE}:${WP_VERSION}-php${PHP_VERSION}"
echo "${IMAGE}:${WP_VERSION}-php${PHP_VERSION}"
