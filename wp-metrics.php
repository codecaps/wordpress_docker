<?php
// Prometheus metrics endpoint.
// Reachable only via 127.0.0.1:8080/wp-metrics (nginx internal metrics server).
// SHORTINIT loads WP core only — no plugins/themes — fast and safe.

define('SHORTINIT', true);
require '/var/www/html/wp-load.php';

global $wpdb, $wp_version;

// Written by the platform prepend (runtime/prepend.php) each time WordPress's cron
// dispatcher really runs, i.e. reaches its event list after WordPress loaded for the
// site the internal trigger (run.sh) asked for. A trigger request WordPress redirected
// or aborted does not count, so the timestamp means "cron ran", not "a request was sent".
// Report the enabled flag alongside the timestamp: without it, "0 / stale"
// looks identical for a capsule that has turned it off as it does for one
// where the loop actually died — any alert on the timestamp needs to be
// conditioned on wp_cron_trigger_enabled==1 to avoid firing fleet-wide.
// Only an explicit off value turns it off: unset, empty or a typo means enabled, as in run.sh
// (validated_bool() in scripts/lib/runtime_env.sh), where a typo falls back to on.
$wp_cron_trigger_enabled = in_array(strtolower(trim((string) getenv('WP_CRON_TRIGGER_ENABLED'))), ['0', 'false', 'no', 'off'], true) ? 0 : 1;

$wp_cron_trigger_heartbeat_file  = '/var/run/wp-runtime/cron-last-run';
$wp_cron_trigger_last_success    = is_readable($wp_cron_trigger_heartbeat_file)
    ? (int) trim((string) file_get_contents($wp_cron_trigger_heartbeat_file))
    : 0;

// WordPress >= 6.6 stores autoloaded options as 'on'/'auto-on'/'auto' as well as 'yes'
// (wp_autoload_values_to_autoload()).
$autoload_values = "('yes','on','auto-on','auto')";

// The runtime's sizing (scripts/lib/resource_sizing.sh): run.sh exports CC_SIZING_*, which reaches
// this script through php-fpm's clear_env=no. 0 when a value is missing.
$sizing = static function (string $name): int {
    $value = getenv('CC_SIZING_' . $name);
    return ($value === false || !ctype_digit((string) $value)) ? 0 : (int) $value;
};

$metrics = [
    'cc_runtime_container_memory_bytes' => [
        'help'  => 'Memory limit the runtime sized itself to (cgroup, or the host when unlimited).',
        'type'  => 'gauge',
        'value' => $sizing('MEM_MB') * 1024 * 1024,
    ],
    'cc_runtime_container_cpu_millicores' => [
        'help'  => 'CPU quota the runtime sized itself to, in millicores (cgroup, or the host when unlimited).',
        'type'  => 'gauge',
        'value' => $sizing('CPU_MC'),
    ],
    'cc_runtime_fpm_max_children' => [
        'help'  => 'PHP-FPM pm.max_children in effect (sized, or pinned via WORDPRESS_FPM_CONF). Compare with phpfpm_active_processes.',
        'type'  => 'gauge',
        'value' => $sizing('FPM_MAX_CHILDREN'),
    ],
    'cc_runtime_php_max_inflight_requests' => [
        'help'  => 'Concurrent PHP requests nginx admits before answering 503 + Retry-After (pm.max_children x PHP_INFLIGHT_PER_WORKER).',
        'type'  => 'gauge',
        'value' => $sizing('PHP_MAX_INFLIGHT'),
    ],
    'cc_runtime_php_memory_limit_bytes' => [
        'help'  => 'Per-request PHP memory_limit in effect (also WP_MEMORY_LIMIT unless the site defines it).',
        'type'  => 'gauge',
        'value' => $sizing('PHP_MEMORY_LIMIT_MB') * 1024 * 1024,
    ],
    'wp_cron_trigger_enabled' => [
        'help'  => 'Whether the internal wp-cron trigger loop (run.sh, WP_CRON_TRIGGER_ENABLED) is on. 1=enabled, 0=disabled.',
        'type'  => 'gauge',
        'value' => $wp_cron_trigger_enabled,
    ],
    'wp_cron_trigger_last_success_timestamp_seconds' => [
        'help'  => 'Unix timestamp of the last time the WordPress cron dispatcher actually ran (written by PHP, not by the trigger). 0 if disabled, never ran yet, or WP_RUNTIME_PREPEND_ENABLED=false — check wp_cron_trigger_enabled before alerting on staleness.',
        'type'  => 'gauge',
        'value' => $wp_cron_trigger_last_success,
    ],
    'wordpress_published_posts_total' => [
        'help'  => 'Published posts',
        'type'  => 'gauge',
        'value' => (int) $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->posts} WHERE post_status='publish' AND post_type='post'"),
    ],
    'wordpress_published_pages_total' => [
        'help'  => 'Published pages',
        'type'  => 'gauge',
        'value' => (int) $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->posts} WHERE post_status='publish' AND post_type='page'"),
    ],
    'wordpress_approved_comments_total' => [
        'help'  => 'Approved comments',
        'type'  => 'gauge',
        'value' => (int) $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->comments} WHERE comment_approved='1'"),
    ],
    'wordpress_users_total' => [
        'help'  => 'Registered users',
        'type'  => 'gauge',
        'value' => (int) $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->users}"),
    ],
    'wordpress_autoloaded_options_total' => [
        'help'  => 'Autoloaded option rows — above ~1000 slows every page load',
        'type'  => 'gauge',
        'value' => (int) $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->options} WHERE autoload IN {$autoload_values}"),
    ],
    'wordpress_autoloaded_options_bytes' => [
        'help'  => 'Total bytes of autoloaded options — above 5MB signals plugin bloat',
        'type'  => 'gauge',
        'value' => (int) $wpdb->get_var("SELECT COALESCE(SUM(LENGTH(option_value)),0) FROM {$wpdb->options} WHERE autoload IN {$autoload_values}"),
    ],
];

header('Content-Type: text/plain; version=0.0.4; charset=utf-8');
foreach ($metrics as $name => $m) {
    printf("# HELP %s %s\n# TYPE %s %s\n%s %s\n\n",
        $name, $m['help'], $name, $m['type'], $name, $m['value']);
}
// The installed WordPress core version, as a label (the design doc lists reporting it as a follow-up).
printf("# HELP wordpress_core_version_info Installed WordPress core version (from wp-includes/version.php).\n# TYPE wordpress_core_version_info gauge\nwordpress_core_version_info{version=\"%s\",php_version=\"%s\"} 1\n",
    addslashes((string) $wp_version), PHP_VERSION);
