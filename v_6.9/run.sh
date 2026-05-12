#!/bin/bash
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$RUN_DIR/scripts/configure_wordpress_custom_ini.sh"
"$RUN_DIR/scripts/configure_wordpress_fpm_conf.sh"
"$RUN_DIR/scripts/configure_nginx_overrides.sh"

nginx -t

set +e
service nginx start
docker-entrypoint.sh php-fpm
service nginx stop
