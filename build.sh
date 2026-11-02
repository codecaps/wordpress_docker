#!/usr/bin/env bash
# Builds the runtime for one PHP track (tracks/php<minor>.env) and tags it twice: the immutable
# wordpress-runtime:php<minor>-r<REVISION> that capsule-api deploys, and the moving
# wordpress-runtime:php<minor> alias for humans (never deploy it). Prints the immutable ref last.
# Usage: ./build.sh 8.4 [extra docker buildx args]
set -euo pipefail
cd "$(dirname "$0")"

MINOR="${1:?usage: $0 <php-minor> [buildx args...]}"
shift
TRACK="tracks/php${MINOR}.env"
if ! [[ "$MINOR" =~ ^[0-9]+\.[0-9]+$ ]] || [ ! -f "$TRACK" ]; then
    echo "unknown track: ${MINOR} (expected one of: $(ls tracks | sed -n 's/^php\(.*\)\.env$/\1/p' | xargs))" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$TRACK"

IMAGE=europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime
REF="${IMAGE}:php${MINOR}-r${REVISION}"

docker buildx build . --platform linux/amd64 --progress=auto --pull --load \
  --build-arg BASE_IMAGE="${BASE_IMAGE}" --build-arg MIN_PHP_VERSION="${MIN_PHP_VERSION}" \
  -t "${REF}" -t "${IMAGE}:php${MINOR}" "$@"

echo "${REF}"
