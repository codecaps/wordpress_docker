FROM wordpress:6.9-php8.4-fpm

# Install nginx
RUN apt-get update && apt-get install -y --no-install-recommends nginx \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Copy nginx config
COPY nginx.conf /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf

# Copy entrypoint
COPY run.sh /usr/run.sh
COPY scripts /usr/scripts
RUN chmod +x /usr/run.sh /usr/scripts/configure_wordpress_custom_ini.sh /usr/scripts/configure_wordpress_fpm_conf.sh /usr/scripts/configure_nginx_overrides.sh

RUN mkdir -p /var/cache/nginx/wordpress \
    && chown -R www-data:www-data /var/cache/nginx

EXPOSE 80

ENTRYPOINT ["/usr/run.sh"]
