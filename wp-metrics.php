<?php
// Prometheus metrics endpoint.
// Reachable only via 127.0.0.1:8080/wp-metrics (nginx internal metrics server).
// SHORTINIT loads WP core only — no plugins/themes — fast and safe.

define('SHORTINIT', true);
require dirname(__FILE__) . '/wp-load.php';

global $wpdb;

// Written by the internal wp-cron trigger loop in run.sh (a separate bash
// process — this is the only way to hand its state to this PHP script).
// Report the enabled flag alongside the timestamp: without it, "0 / stale"
// looks identical for a capsule that has turned it off as it does for one
// where the loop actually died — any alert on the timestamp needs to be
// conditioned on wp_cron_trigger_enabled==1 to avoid firing fleet-wide.
// Unset means enabled, matching the default in run.sh.
$wp_cron_trigger_enabled_raw = getenv('WP_CRON_TRIGGER_ENABLED');
$wp_cron_trigger_enabled_raw = $wp_cron_trigger_enabled_raw === false ? 'true' : (string) $wp_cron_trigger_enabled_raw;
$wp_cron_trigger_enabled     = in_array(strtolower(trim($wp_cron_trigger_enabled_raw)), ['1', 'true', 'on', 'yes'], true) ? 1 : 0;

$wp_cron_trigger_heartbeat_file  = '/var/run/wp-cron-trigger-last-success';
$wp_cron_trigger_last_success    = is_readable($wp_cron_trigger_heartbeat_file)
    ? (int) trim((string) file_get_contents($wp_cron_trigger_heartbeat_file))
    : 0;

$metrics = [
    'wp_cron_trigger_enabled' => [
        'help'  => 'Whether the internal wp-cron trigger loop (run.sh, WP_CRON_TRIGGER_ENABLED) is on. 1=enabled, 0=disabled.',
        'type'  => 'gauge',
        'value' => $wp_cron_trigger_enabled,
    ],
    'wp_cron_trigger_last_success_timestamp_seconds' => [
        'help'  => 'Unix timestamp of the last successful internal wp-cron trigger. 0 if disabled or never succeeded yet — check wp_cron_trigger_enabled before alerting on staleness.',
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
        'value' => (int) $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->options} WHERE autoload='yes'"),
    ],
    'wordpress_autoloaded_options_bytes' => [
        'help'  => 'Total bytes of autoloaded options — above 5MB signals plugin bloat',
        'type'  => 'gauge',
        'value' => (int) $wpdb->get_var("SELECT COALESCE(SUM(LENGTH(option_value)),0) FROM {$wpdb->options} WHERE autoload='yes'"),
    ],
];

header('Content-Type: text/plain; version=0.0.4; charset=utf-8');
foreach ($metrics as $name => $m) {
    printf("# HELP %s %s\n# TYPE %s %s\n%s %s\n\n",
        $name, $m['help'], $name, $m['type'], $name, $m['value']);
}
