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

## Building and releasing an image

```bash
./docker_build.sh 6.9   # builds v_6.9/, tags wordpress:6.9 and wordpress:6.9-php<php version>
./docker_push.sh 6.9    # pushes both tags
```

capsule-api deploys the immutable `-php<version>` tag. Re-pushing only the moving `wordpress:6.9`
tag never reaches running capsules (unchanged pod spec + `IfNotPresent`), so after pushing, bump
the tag in capsule-api's `WordpressDeploymentService.getWordpressImage` and run its
`redeploy-wordpress-capsules` job.

Every version's PHP comes from the maintained `wordpress:php8.x-fpm` track; only WordPress core
is copied from the pinned release, because upstream stops rebuilding old version tags. Each
Dockerfile refuses to build on a PHP older than `MIN_PHP_VERSION` (the PHP2Shell fix,
CVE-2026-109618/109619).
