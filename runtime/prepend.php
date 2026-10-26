<?php
/**
 * Code Capsules WordPress runtime — platform prepend.
 *
 * Wired in as php.ini `auto_prepend_file`, so it runs before every PHP script (PHP-FPM and the
 * CLI). It does three cheap things and must never throw or print:
 *
 *  1. Tells PHP the request was HTTPS when Traefik says so (X-Forwarded-Proto), so `is_ssl()` is
 *     right even for git capsules whose wp-config.php lacks the proxy shim.
 *  2. Defines hardened defaults for a few wp-config constants the site has not defined itself
 *     (DISABLE_WP_CRON, DISALLOW_FILE_EDIT, WP_MEMORY_LIMIT, WP_MAX_MEMORY_LIMIT, WP_REDIS_*).
 *     A constant the owner defines in wp-config.php or WORDPRESS_CONFIG_EXTRA always wins: those
 *     names are detected and skipped, so there is never an "already defined" warning.
 *  3. Loads the runtime mu-plugin (/usr/share/wp-runtime/mu-plugins/code-capsules.php) through a
 *     pre-initialised `muplugins_loaded` hook, which WordPress core supports explicitly
 *     (WP_Hook::build_preinitialized_hooks). Nothing is written to the site's volume.
 *
 * Disable everything with WP_RUNTIME_PREPEND_ENABLED=false (the ini line is then not written),
 * or only the mu-plugin with WP_RUNTIME_MU_PLUGIN_ENABLED=false.
 */

if (PHP_SAPI !== 'cli'
    && isset($_SERVER['HTTP_X_FORWARDED_PROTO'])
    && stripos((string) $_SERVER['HTTP_X_FORWARDED_PROTO'], 'https') !== false) {
    $_SERVER['HTTPS'] = 'on';
}

(static function (): void {
    $env = static function (string $name, ?string $default = null): ?string {
        $value = getenv($name);
        return ($value === false || $value === '') ? $default : $value;
    };
    $falsy = static function (?string $value): bool {
        return in_array(strtolower(trim((string) $value)), ['0', 'false', 'no', 'off'], true);
    };
    $truthy = static function (?string $value): bool {
        return in_array(strtolower(trim((string) $value)), ['1', 'true', 'yes', 'on'], true);
    };

    // Constants the site defines itself (wp-config.php, or WORDPRESS_CONFIG_EXTRA which the
    // official wp-config-docker.php eval()s at runtime). Ours are only defaults for the rest.
    $owned   = [];
    $sources = [(string) getenv('WORDPRESS_CONFIG_EXTRA')];
    $docroot = isset($_SERVER['DOCUMENT_ROOT']) && $_SERVER['DOCUMENT_ROOT'] !== ''
        ? rtrim((string) $_SERVER['DOCUMENT_ROOT'], '/')
        : '/var/www/html';
    foreach (array_unique([$docroot . '/wp-config.php', dirname($docroot) . '/wp-config.php']) as $file) {
        if (@is_file($file) && @is_readable($file)) {
            $sources[] = (string) @file_get_contents($file);
        }
    }
    foreach ($sources as $source) {
        if ($source !== '' && preg_match_all('/define\s*\(\s*[\'"]([A-Za-z0-9_]+)[\'"]/', $source, $matches)) {
            foreach ($matches[1] as $name) {
                $owned[strtoupper($name)] = true;
            }
        }
    }
    $define = static function (string $name, $value) use ($owned): void {
        if (!defined($name) && !isset($owned[$name])) {
            define($name, $value);
        }
    };

    // WordPress's page-load cron spawner self-requests the public wp-cron.php, which the runtime
    // blocks (DISABLE_PUBLIC_WP_CRON); the internal trigger loop runs cron instead. Follow it unless
    // WP_DISABLE_WP_CRON says otherwise.
    $disableCron = $env('WP_DISABLE_WP_CRON');
    $define('DISABLE_WP_CRON', $disableCron === null
        ? !$falsy($env('WP_CRON_TRIGGER_ENABLED', 'true'))
        : $truthy($disableCron));

    // The theme/plugin file editors turn any admin session into code execution on a writable
    // docroot. Off by default like every managed WordPress host; WP_DISALLOW_FILE_EDIT=false re-enables.
    $define('DISALLOW_FILE_EDIT', !$falsy($env('WP_DISALLOW_FILE_EDIT', 'true')));

    // WordPress's own default is 40M, which modern plugins exceed. PHP memory_limit (256M) caps the
    // admin value; WordPress raises its limit with ini_set when allowed.
    $define('WP_MEMORY_LIMIT', $env('WP_MEMORY_LIMIT', '256M'));
    $define('WP_MAX_MEMORY_LIMIT', $env('WP_MAX_MEMORY_LIMIT', '512M'));

    // Redis object cache: when a Redis host is given, the Redis Cache plugin's constants are set
    // from env so enabling the plugin is the only remaining step. PhpRedis is compiled into the image.
    $redisHost = $env('WP_REDIS_HOST');
    if ($redisHost !== null) {
        $define('WP_REDIS_HOST', $redisHost);
        $define('WP_REDIS_PORT', (int) $env('WP_REDIS_PORT', '6379'));
        if (($password = $env('WP_REDIS_PASSWORD')) !== null) {
            $define('WP_REDIS_PASSWORD', $password);
        }
        if (($database = $env('WP_REDIS_DATABASE')) !== null) {
            $define('WP_REDIS_DATABASE', (int) $database);
        }
        // A per-site prefix keeps two sites on one Redis from corrupting each other's cache.
        $define('WP_REDIS_PREFIX', $env('WP_REDIS_PREFIX', (string) $env('WORDPRESS_DB_NAME', 'wordpress')));
        $define('WP_REDIS_CLIENT', 'phpredis');
        $define('WP_REDIS_TIMEOUT', 1);
        $define('WP_REDIS_READ_TIMEOUT', 1);
    }

    $plugin = '/usr/share/wp-runtime/mu-plugins/code-capsules.php';
    if (!$falsy($env('WP_RUNTIME_MU_PLUGIN_ENABLED', 'true')) && is_file($plugin)) {
        // Shape expected by WP_Hook::build_preinitialized_hooks(): [hook][priority][] = callback.
        $GLOBALS['wp_filter']['muplugins_loaded'][-100][] = [
            'function'      => static function () use ($plugin): void {
                require_once $plugin;
            },
            'accepted_args' => 1,
        ];
    }
})();
