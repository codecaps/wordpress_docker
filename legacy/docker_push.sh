#!/usr/bin/env bash
# Pushes both tags produced by ./docker_build.sh <wp-version>: the immutable <wp>-php<php> tag that
# capsule-api deploys, then the moving <wp> tag. Refuses to overwrite the immutable tag when it
# already exists, or when the registry cannot say whether it does (rebuilt content under a deployed
# tag would split pods that cached the old image from newly scheduled ones).
# Usage: ./docker_push.sh 6.9
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=../tools/registry_guard.sh
source ../tools/registry_guard.sh

WP_VERSION="${1:?usage: $0 <wp-version>}"
IMAGE=europe-west4-docker.pkg.dev/appstrax/main/wordpress

PHP_VERSION="$(docker run --rm --platform linux/amd64 --entrypoint php "${IMAGE}:${WP_VERSION}" -r 'echo PHP_VERSION;')"
REF="${IMAGE}:${WP_VERSION}-php${PHP_VERSION}"

state=0
registry_tag_state "${REF}" || state=$?
case "$state" in
    0) ;;
    1) echo "tag already exists: ${REF} (this PHP patch was already released for ${WP_VERSION}; there is nothing new to push)" >&2; exit 1 ;;
    *) exit 1 ;;
esac

docker push "${REF}"
docker push "${IMAGE}:${WP_VERSION}"
