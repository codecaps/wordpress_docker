# PHP comes from the maintained wordpress:php8.4-fpm track; only WordPress core is taken from
# the pinned release. Upstream stopped rebuilding wordpress:6.9-php8.4-fpm, so basing on it directly
# would freeze PHP at whatever patch it last shipped (PHP2Shell: CVE-2026-109618/109619).
ARG PHP_BASE_IMAGE=wordpress:php8.4-fpm
FROM wordpress:6.9-php8.4-fpm AS wordpress-core

FROM ${PHP_BASE_IMAGE}

# Refuse to build on a PHP older than the patched release.
ARG MIN_PHP_VERSION=8.4.27
RUN php -r 'exit(version_compare(PHP_VERSION, getenv("MIN_PHP_VERSION"), ">=") ? 0 : 1);' \
    || { echo "PHP $(php -r 'echo PHP_VERSION;') is older than MIN_PHP_VERSION=$MIN_PHP_VERSION" >&2; exit 1; }

RUN rm -rf /usr/src/wordpress
COPY --from=wordpress-core --chown=www-data:www-data /usr/src/wordpress /usr/src/wordpress

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




# Copy WordPress application metrics endpoint (served via internal nginx on :8080).
COPY wp-metrics.php /var/www/html/wp-metrics.php

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
