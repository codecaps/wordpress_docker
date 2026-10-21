#!/usr/bin/env bash
# Pushes both tags produced by ./build.sh <minor>: the immutable php<minor>-r<REVISION> tag first,
# then the moving php<minor> alias. Refuses to overwrite an immutable tag that already exists
# (bump REVISION in tracks/php<minor>.env instead), and refuses a local image whose PHP is older
# than the track's MIN_PHP_VERSION (e.g. one built with a MIN_PHP_VERSION override).
# Usage: ./push.sh 8.4
set -euo pipefail
cd "$(dirname "$0")"

MINOR="${1:?usage: $0 <php-minor>}"
TRACK="tracks/php${MINOR}.env"
if ! [[ "$MINOR" =~ ^[0-9]+\.[0-9]+$ ]] || [ ! -f "$TRACK" ]; then
    echo "unknown track: ${MINOR}" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$TRACK"

IMAGE=europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime
REF="${IMAGE}:php${MINOR}-r${REVISION}"

if ! docker run --rm --platform linux/amd64 --entrypoint php "${REF}" \
        -r "exit(version_compare(PHP_VERSION, '${MIN_PHP_VERSION}', '>=') ? 0 : 1);"; then
    echo "${REF} is missing locally or its PHP is older than MIN_PHP_VERSION=${MIN_PHP_VERSION}; rebuild with ./build.sh ${MINOR}" >&2
    exit 1
fi

if docker buildx imagetools inspect "${REF}" >/dev/null 2>&1; then
    echo "tag already exists: ${REF} (bump REVISION in ${TRACK})" >&2
    exit 1
fi

docker push "${REF}"
docker push "${IMAGE}:php${MINOR}"
