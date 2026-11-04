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
 *     (DISABLE_WP_CRON, DISALLOW_FILE_EDIT, WP_MEMORY_LIMIT and WP_MAX_MEMORY_LIMIT from the
 *     container-sized php.ini memory_limit, WP_REDIS_*).
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
    // An on/off switch: true/1/yes/on or false/0/no/off in any case; unset, empty or anything else
    // is the default. Same rule as validated_bool() in scripts/lib/runtime_env.sh, which reports a
    // typo once at startup (this runs on every request, so it never logs).
    $flag = static function (string $name, bool $default) use ($env): bool {
        $value = strtolower(trim((string) $env($name, '')));
        if (in_array($value, ['1', 'true', 'yes', 'on'], true)) {
            return true;
        }
        if (in_array($value, ['0', 'false', 'no', 'off'], true)) {
            return false;
        }
        return $default;
    };

    // Constants the site defines itself (wp-config.php, or WORDPRESS_CONFIG_EXTRA which the
    // official wp-config-docker.php eval()s at runtime). Ours are only defaults for the rest.
    $definedIn = static function (string $source): array {
        $names = [];
        if ($source !== '' && preg_match_all('/define\s*\(\s*[\'"]([A-Za-z0-9_]+)[\'"]/', $source, $matches)) {
            foreach ($matches[1] as $name) {
                $names[] = strtoupper($name);
            }
        }
        return $names;
    };
    // wp-config.php sits on the capsule's (network) volume and this runs before every request, so
    // its names are cached on local disk, keyed on the file's identity and mtime: a request costs
    // one stat of the volume instead of a read. The cache is data (JSON), never included, so a
    // file planted in /tmp can at most change which of these defaults get skipped.
    $definedInFile = static function (string $file) use ($definedIn): array {
        // is_file() first: it never raises a warning for a missing file, while a suppressed stat()
        // warning would still show up in error_get_last() for the rest of the request.
        if (!@is_file($file) || ($stat = @stat($file)) === false) {
            return [];
        }
        $cache = sys_get_temp_dir() . '/cc-runtime-defines-'
            . md5($file . '|' . $stat['dev'] . '|' . $stat['ino'] . '|' . $stat['mtime'] . '|' . $stat['size']) . '.json';
        $cached = @is_file($cache) ? @file_get_contents($cache) : false;
        if ($cached !== false && is_array($names = json_decode($cached, true))) {
            return $names;
        }
        $source = @file_get_contents($file);
        if ($source === false) {
            return [];
        }
        $names = $definedIn($source);
        $tmp   = $cache . '.' . getmypid();
        if (@file_put_contents($tmp, json_encode($names)) !== false && !@rename($tmp, $cache)) {
            @unlink($tmp);
        }
        return $names;
    };
    $docroot = isset($_SERVER['DOCUMENT_ROOT']) && $_SERVER['DOCUMENT_ROOT'] !== ''
        ? rtrim((string) $_SERVER['DOCUMENT_ROOT'], '/')
        : '/var/www/html';
    $owned = array_fill_keys($definedIn((string) getenv('WORDPRESS_CONFIG_EXTRA')), true);
    foreach (array_unique([$docroot . '/wp-config.php', dirname($docroot) . '/wp-config.php']) as $file) {
        $owned += array_fill_keys($definedInFile($file), true);
    }
    $define = static function (string $name, $value) use ($owned): void {
        if (!defined($name) && !isset($owned[$name])) {
            define($name, $value);
        }
    };

    // WordPress's page-load cron spawner self-requests the public wp-cron.php, which the runtime
    // blocks (DISABLE_PUBLIC_WP_CRON); the internal trigger loop runs cron instead. Follow it unless
    // WP_DISABLE_WP_CRON says otherwise.
    $define('DISABLE_WP_CRON', $flag('WP_DISABLE_WP_CRON', $flag('WP_CRON_TRIGGER_ENABLED', true)));

    // The theme/plugin file editors turn any admin session into code execution on a writable
    // docroot. Off by default like every managed WordPress host; WP_DISALLOW_FILE_EDIT=false re-enables.
    $define('DISALLOW_FILE_EDIT', $flag('WP_DISALLOW_FILE_EDIT', true));

    // WordPress raises memory_limit to WP_MEMORY_LIMIT whenever that is higher, which would defeat
    // the per-request cap the runtime sized to the container (zz-custom.ini: 128M below 1.5G of
    // memory, 256M above). So WP_MEMORY_LIMIT defaults to that sized value (WordPress's own
    // default is 40M, which modern plugins exceed). WP_MAX_MEMORY_LIMIT, which WordPress uses for
    // admin work, image editing and upgrades, comes from the sizing too (CC_SIZING_* reach PHP
    // through php-fpm's clear_env = no): twice the request limit where the container can hold it;
    // without the sizing in the environment (the CLI), twice the limit and at least 256M.
    $limitMb = 256;
    if (preg_match('/^\s*(\d+)\s*([KMG]?)\s*$/i', (string) ini_get('memory_limit'), $m) && (int) $m[1] > 0) {
        $limitMb = max(1, match (strtoupper($m[2])) {
            'G'     => (int) $m[1] * 1024,
            'M'     => (int) $m[1],
            'K'     => intdiv((int) $m[1], 1024),
            default => intdiv((int) $m[1], 1024 * 1024),
        });
    }
    $sizedMax = $env('CC_SIZING_WP_MAX_MEMORY_LIMIT_MB');
    $maxMb    = ($sizedMax !== null && ctype_digit($sizedMax) && (int) $sizedMax > 0)
        ? (int) $sizedMax
        : max(256, 2 * $limitMb);
    $define('WP_MEMORY_LIMIT', $env('WP_MEMORY_LIMIT', $limitMb . 'M'));
    $define('WP_MAX_MEMORY_LIMIT', $env('WP_MAX_MEMORY_LIMIT', $maxMb . 'M'));

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

    // Cron heartbeat (read by wp-metrics.php): written when wp-cron.php's dispatcher reaches its
    // event list, which happens only after WordPress fully loaded for the requested site. The
    // trigger's HTTP status cannot say that: wp-cron.php answers before WordPress loads, so a site
    // that redirects or aborts the request still returned 200. Pre-initialised like the mu-plugin
    // hook below, so it works with WP_RUNTIME_MU_PLUGIN_ENABLED=false too.
    $heartbeat = '/var/run/wp-runtime/cron-last-run';
    $GLOBALS['wp_filter']['pre_get_ready_cron_jobs'][10][] = [
        'function'      => static function ($pre) use ($heartbeat) {
            if (function_exists('wp_doing_cron') && wp_doing_cron() && @is_writable($heartbeat)) {
                @file_put_contents($heartbeat, time() . "\n");
            }
            return $pre;
        },
        'accepted_args' => 1,
    ];

    $plugin = '/usr/share/wp-runtime/mu-plugins/code-capsules.php';
    if ($flag('WP_RUNTIME_MU_PLUGIN_ENABLED', true) && is_file($plugin)) {
        // Shape expected by WP_Hook::build_preinitialized_hooks(): [hook][priority][] = callback.
        $GLOBALS['wp_filter']['muplugins_loaded'][-100][] = [
            'function'      => static function () use ($plugin): void {
                require_once $plugin;
            },
            'accepted_args' => 1,
        ];
    }
})();
