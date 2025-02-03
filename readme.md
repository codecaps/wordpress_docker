# Wordpress Deployments

This repository is used for Code Capsules wordpress deployments.
<br>

All wordpress deployment must use FPM images (FPM is PHP's fastcgi implementation)

We use nginx as a proxy. `default.conf` and `nginx.conf` are used as the nginx config.

`run.sh` is the file which docker rus on image start, this file will: 
<br>- copy the custom php.ini values from `$WP_CUSTOM_INI` to the `$PHP_INI_DIR/conf.d/` directory
<br>- start the nginx service
<br>- run the wordpress php-fpm start command

## V6.7
We use `FROM wordpress:6.7.1-php8.3-fpm` as the base image

## V6.6
We use `FROM wordpress:6.6.2-php8.3-fpm` as the base image

## V6.5
We use `FROM wordpress:6.5.5-php8.3-fpm` as the base image