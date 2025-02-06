#!/bin/bash

if [ "$WP_CUSTOM_INI" ]; then
    echo "Writing custom ini values"
    printf "$WP_CUSTOM_INI" > $PHP_INI_DIR/conf.d/custom.ini
fi

service nginx start 
docker-entrypoint.sh php-fpm
