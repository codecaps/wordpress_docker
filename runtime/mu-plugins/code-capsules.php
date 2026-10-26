<?php
/**
 * Plugin Name: Code Capsules Runtime
 * Description: Keeps the runtime's nginx page cache fresh: purges it when content changes, adds a "Purge page cache" admin-bar item and the `wp cc cache` commands.
 * Version: 1.0.0
 * Author: Code Capsules
 *
 * Loaded by /usr/share/wp-runtime/prepend.php at `muplugins_loaded`; it is not a file on the
 * site's volume. Disable with WP_RUNTIME_MU_PLUGIN_ENABLED=false.
 *
 * The nginx FastCGI cache lives in this container. Its state (enabled, TTL, purge token) is
 * written at startup by scripts/configure_nginx_overrides.sh to STATE_FILE; purges are HTTP calls
 * to the loopback-only /.cc-cache-purge location, which the ngx_cache_purge module serves.
 */

namespace CodeCapsules\Runtime;

if (!defined('ABSPATH')) {
    return;
}

const STATE_FILE = '/var/run/wp-runtime/nginx-cache.env';
const PURGE_URL  = 'http://127.0.0.1/.cc-cache-purge';

/** @return array{enabled: bool, ttl: int, token: string} */
function cache_state(): array
{
    static $state = null;
    if ($state !== null) {
        return $state;
    }
    $state = ['enabled' => false, 'ttl' => 0, 'token' => ''];
    if (@is_readable(STATE_FILE)) {
        $parsed = parse_ini_string((string) @file_get_contents(STATE_FILE), false, INI_SCANNER_RAW);
        if (is_array($parsed)) {
            $state['enabled'] = isset($parsed['enabled']) && (string) $parsed['enabled'] === '1';
            $state['ttl']     = (int) ($parsed['ttl'] ?? 0);
            $state['token']   = (string) ($parsed['token'] ?? '');
        }
    }
    return $state;
}

function cache_enabled(): bool
{
    return cache_state()['enabled'] && cache_state()['token'] !== '';
}

/**
 * Purges the whole page cache of this container. One call, host- and scheme-agnostic, so it is
 * always correct; a page is re-cached on its next anonymous view.
 */
function purge_all(string $reason = ''): bool
{
    if (!cache_enabled()) {
        return false;
    }
    // `*` must reach nginx unencoded; the token is hex.
    $url      = PURGE_URL . '?key=*&token=' . rawurlencode(cache_state()['token']);
    $response = wp_remote_get($url, [
        'timeout'     => 3,
        'redirection' => 0,
        'headers'     => ['Host' => '127.0.0.1'],
    ]);
    // 404 = nothing was cached, which is also "purged".
    $ok = !is_wp_error($response)
        && in_array((int) wp_remote_retrieve_response_code($response), [200, 404], true);
    if (!$ok) {
        error_log('[cc-runtime] page cache purge failed (' . $reason . '): ' . (
            is_wp_error($response) ? $response->get_error_message() : 'HTTP ' . wp_remote_retrieve_response_code($response)
        ));
    }
    do_action('cc_cache_purged', $ok, $reason);
    return $ok;
}

/** Many hooks fire in one save; purge once, at shutdown, after the content is stored. */
function schedule_purge(string $reason): void
{
    static $scheduled = false;
    if ($scheduled || !cache_enabled()) {
        return;
    }
    $scheduled = true;
    add_action('shutdown', static function () use ($reason): void {
        purge_all($reason);
    }, 0);
}

function is_public_post(?\WP_Post $post): bool
{
    if (!$post instanceof \WP_Post || wp_is_post_revision($post) || wp_is_post_autosave($post)) {
        return false;
    }
    $type = get_post_type_object($post->post_type);
    return $type !== null && !empty($type->public);
}

// --- Content changes that make cached pages stale -------------------------------------------

add_action('transition_post_status', static function (string $new, string $old, \WP_Post $post): void {
    if (($new === 'publish' || $old === 'publish') && is_public_post($post)) {
        schedule_purge("post {$post->ID} {$old}->{$new}");
    }
}, 10, 3);

add_action('save_post', static function (int $id, \WP_Post $post): void {
    if ($post->post_status === 'publish' && is_public_post($post)) {
        schedule_purge("post {$id} saved");
    }
}, 10, 2);

add_action('deleted_post', static function (int $id, ?\WP_Post $post): void {
    if ($post instanceof \WP_Post && $post->post_status === 'publish' && is_public_post($post)) {
        schedule_purge("post {$id} deleted");
    }
}, 10, 2);

add_action('transition_comment_status', static function (string $new, string $old): void {
    if ($new === 'approved' || $old === 'approved') {
        schedule_purge('comment status');
    }
}, 10, 2);
add_action('comment_post', static function (int $id, $approved): void {
    if ($approved === 1 || $approved === '1') {
        schedule_purge('comment approved');
    }
}, 10, 2);

foreach (['created_term', 'edited_term', 'delete_term'] as $hook) {
    add_action($hook, static fn() => schedule_purge('term'));
}
add_action('wp_update_nav_menu', static fn() => schedule_purge('menu'));
add_action('switch_theme', static fn() => schedule_purge('theme'));
add_action('customize_save_after', static fn() => schedule_purge('customizer'));
add_action('upgrader_process_complete', static fn() => schedule_purge('upgrade'));
add_action('activated_plugin', static fn() => schedule_purge('plugin activated'));
add_action('deactivated_plugin', static fn() => schedule_purge('plugin deactivated'));
add_action('updated_option', static function (string $option): void {
    static $watched = [
        'permalink_structure', 'blogname', 'blogdescription', 'show_on_front', 'page_on_front',
        'page_for_posts', 'posts_per_page', 'sidebars_widgets', 'theme_mods', 'stylesheet', 'template',
        'home', 'siteurl', 'blog_public', 'site_icon', 'WPLANG',
    ];
    if (in_array($option, $watched, true) || str_starts_with($option, 'theme_mods_') || str_starts_with($option, 'widget_')) {
        schedule_purge("option {$option}");
    }
});

// Themes/plugins can ask for a purge: do_action('cc_cache_purge').
add_action('cc_cache_purge', static fn() => purge_all('cc_cache_purge action'));

// --- Admin bar button -------------------------------------------------------------------------

add_action('admin_bar_menu', static function (\WP_Admin_Bar $bar): void {
    if (!cache_enabled() || !current_user_can('manage_options')) {
        return;
    }
    $bar->add_node([
        'id'    => 'cc-purge-cache',
        'title' => __('Purge page cache'),
        'href'  => wp_nonce_url(admin_url('admin-post.php?action=cc_purge_cache'), 'cc_purge_cache'),
        'meta'  => ['title' => sprintf('Clear the Code Capsules page cache (TTL %ds)', cache_state()['ttl'])],
    ]);
}, 100);

add_action('admin_post_cc_purge_cache', static function (): void {
    if (!current_user_can('manage_options')) {
        wp_die(__('Sorry, you are not allowed to do that.'), 403);
    }
    check_admin_referer('cc_purge_cache');
    $ok       = purge_all('admin bar');
    $redirect = wp_get_referer() ?: admin_url();
    wp_safe_redirect(add_query_arg('cc-cache-purged', $ok ? '1' : '0', $redirect));
    exit;
});

add_action('admin_notices', static function (): void {
    if (!isset($_GET['cc-cache-purged'])) {
        return;
    }
    $ok = $_GET['cc-cache-purged'] === '1';
    printf(
        '<div class="notice notice-%s is-dismissible"><p>%s</p></div>',
        $ok ? 'success' : 'error',
        esc_html($ok ? __('Page cache purged.') : __('Page cache purge failed; check the capsule logs.'))
    );
});

// --- WP-CLI -----------------------------------------------------------------------------------

if (defined('WP_CLI') && WP_CLI && class_exists('\WP_CLI')) {
    \WP_CLI::add_command('cc cache purge', static function (): void {
        if (!cache_enabled()) {
            \WP_CLI::warning('The page cache is off (CACHE_TTL_SECONDS); nothing to purge.');
            return;
        }
        purge_all('wp-cli') ? \WP_CLI::success('Page cache purged.') : \WP_CLI::error('Page cache purge failed.');
    }, ['shortdesc' => 'Purges the Code Capsules nginx page cache of this container.']);

    \WP_CLI::add_command('cc cache status', static function (): void {
        $state = cache_state();
        \WP_CLI::line($state['enabled'] ? "enabled (TTL {$state['ttl']}s)" : 'disabled');
    }, ['shortdesc' => 'Shows whether the nginx page cache is on and its TTL.']);
}
