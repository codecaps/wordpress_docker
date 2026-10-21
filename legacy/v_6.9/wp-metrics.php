<?php
// Prometheus metrics endpoint.
// Reachable only via 127.0.0.1:8080/wp-metrics (nginx internal metrics server).
// SHORTINIT loads WP core only — no plugins/themes — fast and safe.

define('SHORTINIT', true);
require dirname(__FILE__) . '/wp-load.php';

global $wpdb;

$metrics = [
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
