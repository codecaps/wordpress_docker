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

# Third-party binaries are pinned by version AND checksum (from each project's release
# checksums.txt) so a revision is reproducible and a tampered release asset fails the build.
ARG TARGETARCH=amd64
ARG NGINX_EXPORTER_VERSION=1.5.3
ARG NGINX_EXPORTER_SHA256_AMD64=3a0dd1ea6db57cd360544d0aed38df4adabcfeb31e931dc481d535c66f92641d
ARG NGINX_EXPORTER_SHA256_ARM64=a0b1a5f5bba09483bd2e04c759c1a75fffe46ca72c0314ee2bb925d1742ff23b
ARG FPM_EXPORTER_VERSION=2.2.0
ARG FPM_EXPORTER_SHA256_AMD64=9de0d094aec6ad8a2ea536a5eb8e039ccda4882a2b574ac642d07e589fd5a903
ARG FPM_EXPORTER_SHA256_ARM64=bbd13fafb94f4b24e541366760d4022d6475f83dae1938053c9f99ae1a9d01f3
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832
ARG PHPREDIS_VERSION=6.3.0

# nginx with two Debian modules: headers-more (security headers that survive per-location
# add_header) and cache-purge (the mu-plugin purges the page cache through it); curl for the
# cron trigger; the Prometheus exporters; WP-CLI. Logs go to the container streams.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        nginx libnginx-mod-http-headers-more-filter libnginx-mod-http-cache-purge curl ca-certificates; \
    case "$TARGETARCH" in \
        amd64) nginx_exp_sha="$NGINX_EXPORTER_SHA256_AMD64"; fpm_exp_sha="$FPM_EXPORTER_SHA256_AMD64" ;; \
        arm64) nginx_exp_sha="$NGINX_EXPORTER_SHA256_ARM64"; fpm_exp_sha="$FPM_EXPORTER_SHA256_ARM64" ;; \
        *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/nginx-exporter.tgz \
        "https://github.com/nginx/nginx-prometheus-exporter/releases/download/v${NGINX_EXPORTER_VERSION}/nginx-prometheus-exporter_${NGINX_EXPORTER_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    echo "${nginx_exp_sha}  /tmp/nginx-exporter.tgz" | sha256sum -c -; \
    tar -xzf /tmp/nginx-exporter.tgz -C /usr/local/bin nginx-prometheus-exporter; \
    curl -fsSL -o /usr/local/bin/php-fpm_exporter \
        "https://github.com/hipages/php-fpm_exporter/releases/download/v${FPM_EXPORTER_VERSION}/php-fpm_exporter_${FPM_EXPORTER_VERSION}_linux_${TARGETARCH}"; \
    echo "${fpm_exp_sha}  /usr/local/bin/php-fpm_exporter" | sha256sum -c -; \
    chmod +x /usr/local/bin/php-fpm_exporter; \
    curl -fsSL -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"; \
    echo "${WP_CLI_SHA512}  /usr/local/bin/wp" | sha512sum -c -; \
    chmod +x /usr/local/bin/wp; \
    wp --info --allow-root >/dev/null; \
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log; \
    rm -rf /var/lib/apt/lists/* /tmp/nginx-exporter.tgz; \
    apt-get clean

# PhpRedis (PECL) C extension, pinned: the Redis object cache uses the fast native client instead
# of the pure-PHP Predis fallback. Build deps ($PHPIZE_DEPS is provided by the upstream php image)
# are installed and purged in the same layer; `php -m` fails the build if it did not load.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends $PHPIZE_DEPS; \
    yes '' | pecl install "redis-${PHPREDIS_VERSION}"; \
    docker-php-ext-enable redis; \
    apt-get purge -y --auto-remove $PHPIZE_DEPS; \
    rm -rf /var/lib/apt/lists/*; \
    php -m | grep -q '^redis$'

# Production php.ini (zend.assertions=-1, output_buffering ...); zz-custom.ini still overrides.
# ImageMagick: keep PDF thumbnails, but close the Ghostscript/PostScript coders WordPress never needs.
RUN set -eux; \
    cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"; \
    policy="$(ls /etc/ImageMagick-*/policy.xml | head -1)"; \
    sed -i 's#</policymap>#  <policy domain="coder" rights="none" pattern="{PS,PS2,PS3,EPS,XPS,MVG,MSL}" />\n</policymap>#' "$policy"; \
    grep -q 'pattern="{PS,PS2,PS3,EPS,XPS,MVG,MSL}"' "$policy"

# Runtime files that live outside the docroot (a volume over /var/www/html would hide them):
# the metrics endpoint, the platform prepend and the runtime mu-plugin.
COPY wp-metrics.php /usr/share/wp-runtime/wp-metrics.php
COPY runtime/ /usr/share/wp-runtime/

# nginx config.
COPY nginx.conf /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf
COPY nginx/snippets/wp-fastcgi.conf /etc/nginx/snippets/wp-fastcgi.conf

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

RUN mkdir -p /var/cache/nginx/wordpress /var/run/wp-runtime \
    && chown -R www-data:www-data /var/cache/nginx \
    && chown root:www-data /var/run/wp-runtime && chmod 750 /var/run/wp-runtime

EXPOSE 80
EXPOSE 9113
EXPOSE 9253

# run.sh handles TERM (and the upstream image's QUIT) with a graceful nginx/php-fpm shutdown.
STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/run.sh"]
