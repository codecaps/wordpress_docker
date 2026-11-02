# PHP comes from the maintained wordpress:php8.3-fpm track; only WordPress core is taken from
# the pinned release. Upstream stopped rebuilding wordpress:6.8.3-php8.3-fpm, so basing on it directly
# would freeze PHP at whatever patch it last shipped (PHP2Shell: CVE-2026-109618/109619).
ARG PHP_BASE_IMAGE=wordpress:php8.3-fpm
FROM wordpress:6.8.3-php8.3-fpm AS wordpress-core

FROM ${PHP_BASE_IMAGE}

# Refuse to build on a PHP older than the patched release.
ARG MIN_PHP_VERSION=8.3.36
RUN php -r 'exit(version_compare(PHP_VERSION, getenv("MIN_PHP_VERSION"), ">=") ? 0 : 1);' \
    || { echo "PHP $(php -r 'echo PHP_VERSION;') is older than MIN_PHP_VERSION=$MIN_PHP_VERSION" >&2; exit 1; }

RUN rm -rf /usr/src/wordpress
COPY --from=wordpress-core --chown=www-data:www-data /usr/src/wordpress /usr/src/wordpress

RUN apt update
RUN apt install -y nginx

COPY nginx.conf /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf
COPY run.sh /usr/run.sh

EXPOSE 80

ENTRYPOINT ["/usr/run.sh"]
