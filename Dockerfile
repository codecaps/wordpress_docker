# The PHP runtime for every WordPress capsule. WordPress core lives on the capsule's volume (or, for
# git capsules, in its repo), so the image only pins PHP: one track per PHP minor (tracks/*.env).
# No default base image: a build that does not name a track must fail. Use ./build.sh <minor>.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.source=https://github.com/codecaps/wordpress_docker

# Refuse to build on a PHP older than the patched release (set per track).
ARG MIN_PHP_VERSION
RUN test -n "$MIN_PHP_VERSION" || { echo "MIN_PHP_VERSION is required (see tracks/*.env)" >&2; exit 1; }
RUN php -r 'exit(version_compare(PHP_VERSION, getenv("MIN_PHP_VERSION"), ">=") ? 0 : 1);' \
    || { echo "PHP $(php -r 'echo PHP_VERSION;') is older than MIN_PHP_VERSION=$MIN_PHP_VERSION" >&2; exit 1; }

ARG NGINX_EXPORTER_VERSION=1.4.0
ARG FPM_EXPORTER_VERSION=2.2.0
ARG TARGETARCH=amd64

# Install nginx, curl, and Prometheus exporter binaries in a single layer.
RUN apt-get update && apt-get install -y --no-install-recommends nginx curl \
    && curl -fsSL \
       "https://github.com/nginx/nginx-prometheus-exporter/releases/download/v${NGINX_EXPORTER_VERSION}/nginx-prometheus-exporter_${NGINX_EXPORTER_VERSION}_linux_${TARGETARCH}.tar.gz" \
       | tar -xz -C /usr/local/bin nginx-prometheus-exporter \
    && curl -fsSL \
       "https://github.com/hipages/php-fpm_exporter/releases/download/v${FPM_EXPORTER_VERSION}/php-fpm_exporter_${FPM_EXPORTER_VERSION}_linux_${TARGETARCH}" \
       -o /usr/local/bin/php-fpm_exporter \
    && chmod +x /usr/local/bin/php-fpm_exporter \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Install the PhpRedis (PECL) C extension so the Redis object cache uses the fast
# native client instead of the pure-PHP Predis fallback (every wp_cache_*/transient
# call is a Redis round-trip, so the per-op cost matters). Build deps ($PHPIZE_DEPS
# is provided by the upstream php image) are installed and purged in the same layer
# to keep the image slim. `yes ''` accepts pecl's default prompt answers
# non-interactively; the final `php -m` check fails the build if the extension
# didn't load.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends $PHPIZE_DEPS; \
    yes '' | pecl install redis; \
    docker-php-ext-enable redis; \
    apt-get purge -y --auto-remove $PHPIZE_DEPS; \
    rm -rf /var/lib/apt/lists/*; \
    php -m | grep -q '^redis$'

# Copy WordPress application metrics endpoint (served via internal nginx on :8080). It lives
# outside the docroot: capsules mount a volume over /var/www/html, which would hide it.
COPY wp-metrics.php /usr/share/wp-runtime/wp-metrics.php

# Copy nginx config.
COPY nginx.conf /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf

# Bake Cloudflare edge ranges into the trusted-proxy set so X-Forwarded-For
# recursion resolves the true client IP when proxied by Cloudflare (see nginx.conf).
# Prefer the live published lists; fall back to the version-controlled snapshot
# (with a warning) if the fetch fails, so the image never ships an empty trust set.
COPY cloudflare_ips.fallback.conf /usr/share/nginx/cloudflare_ips.fallback.conf
RUN set -eux; \
    v4="$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v4 || true)"; \
    v6="$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v6 || true)"; \
    if printf '%s' "$v4" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then \
        { echo '# Fetched from Cloudflare at build time.'; \
          for ip in $v4 $v6; do echo "set_real_ip_from $ip;"; done; \
        } > /etc/nginx/conf.d/cloudflare_ips.conf; \
    else \
        echo 'WARNING: Cloudflare IP fetch failed/empty at build — using bundled fallback ranges.' >&2; \
        cp /usr/share/nginx/cloudflare_ips.fallback.conf /etc/nginx/conf.d/cloudflare_ips.conf; \
    fi

# Copy entrypoint and startup scripts.
COPY run.sh /usr/run.sh
COPY scripts /usr/scripts
RUN chmod +x /usr/run.sh \
              /usr/scripts/configure_wordpress_custom_ini.sh \
              /usr/scripts/configure_wordpress_fpm_conf.sh \
              /usr/scripts/configure_nginx_overrides.sh

RUN mkdir -p /var/cache/nginx/wordpress \
    && chown -R www-data:www-data /var/cache/nginx

EXPOSE 80
EXPOSE 9113
EXPOSE 9253

ENTRYPOINT ["/usr/run.sh"]
