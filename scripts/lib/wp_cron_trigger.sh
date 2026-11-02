#!/bin/bash
#
# The internal wp-cron trigger (run.sh): which sites to trigger, and how.
#
# wp-cron.php answers before WordPress loads (it calls fastcgi_finish_request() first), so the HTTP
# status never says whether cron ran: a request WordPress cannot route (a multisite network has no
# site called 127.0.0.1) or redirects (a plugin that forces HTTPS on plain-HTTP requests) still gets
# its 200 and then exits before a single event runs. So the trigger addresses each site the way its
# visitors reach it, with the site's own host, path and scheme (X-Forwarded-Proto, which nginx turns
# into HTTPS=on), and the heartbeat is written by PHP itself once the cron dispatcher reaches its
# event list (runtime/prepend.php), never by this loop.
#
# The site URLs come from WordPress (WP-CLI, as www-data, without plugins or themes): refreshed every
# WP_CRON_TRIGGER_TARGETS_REFRESH_SECONDS, and retried within five minutes while WordPress cannot
# answer (not installed yet, database down), meanwhile triggering the bare loopback address as before.

# Sourcing-safe: a second `source` in the same shell is a no-op.
if [ -n "${WP_CRON_TRIGGER_LIB_LOADED:-}" ]; then return 0; fi
WP_CRON_TRIGGER_LIB_LOADED=1

# The target used until WordPress reports its URLs.
WP_CRON_TRIGGER_LOOPBACK="http 127.0.0.1 /"

# Prints "<scheme> <host> <path>" for a site URL (the path always ends in /), or fails for anything
# that is not a plain http(s) URL. The host and path are restricted to characters that cannot break
# out of a header or the request line.
wp_cron_trigger_parse_url() {
    local url="$1" scheme host path
    [[ "$url" =~ ^([Hh][Tt][Tt][Pp][Ss]?)://([A-Za-z0-9.-]+(:[0-9]+)?)(/[A-Za-z0-9._~%!\$\&\'\(\)\*\+,\;=:@/-]*)?$ ]] || return 1
    scheme="${BASH_REMATCH[1],,}"
    host="${BASH_REMATCH[2],,}"
    path="${BASH_REMATCH[4]:-/}"
    [[ "$path" == */ ]] || path="$path/"
    echo "$scheme $host $path"
}

# Prints the site URLs WordPress reports, one per line: the site URL, or for a multisite network up
# to 100 of its live sites, most recently updated first (get_sites() treats 0 as "no limit", so the
# cap is a literal: inside `wp eval`, $args is WP-CLI's own argument list, not extra arguments).
# Fails (prints nothing) when WordPress cannot answer.
wp_cron_trigger_discover() {
    setpriv --reuid=www-data --regid=www-data --clear-groups \
        env HOME=/tmp wp --path=/var/www/html --skip-plugins --skip-themes --quiet eval '
            if (is_multisite()) {
                $ids = get_sites([
                    "number" => 100, "fields" => "ids", "archived" => 0, "deleted" => 0,
                    "spam" => 0, "orderby" => "last_updated", "order" => "DESC",
                ]);
                foreach ($ids as $id) {
                    echo get_site_url($id), "\n";
                }
            } else {
                echo site_url(), "\n";
            }' 2>/dev/null
}

# Refreshes WP_CRON_TRIGGER_TARGETS ("<scheme> <host> <path>" entries) when NOW has reached
# WP_CRON_TRIGGER_EXPIRES. A successful lookup is kept for REFRESH seconds; after a failed one the
# loopback target is used and WordPress is asked again within five minutes. Sets
# WP_CRON_TRIGGER_FALLBACK to 1 while the loopback target is in use.
wp_cron_trigger_refresh() {
    local now="$1" refresh="$2" url parsed
    local -a found=()
    if [ "$now" -lt "${WP_CRON_TRIGGER_EXPIRES:-0}" ]; then
        return 0
    fi
    while IFS= read -r url; do
        url="${url%$'\r'}"
        if parsed="$(wp_cron_trigger_parse_url "$url")"; then
            found+=("$parsed")
        fi
    done < <(wp_cron_trigger_discover)
    if [ "${#found[@]}" -gt 0 ]; then
        WP_CRON_TRIGGER_TARGETS=("${found[@]}")
        WP_CRON_TRIGGER_EXPIRES=$(( now + refresh ))
        WP_CRON_TRIGGER_FALLBACK=0
    else
        WP_CRON_TRIGGER_TARGETS=("$WP_CRON_TRIGGER_LOOPBACK")
        WP_CRON_TRIGGER_EXPIRES=$(( now + (refresh < 300 ? refresh : 300) ))
        WP_CRON_TRIGGER_FALLBACK=1
    fi
}

# Prints the indexes of the targets to trigger this run: PER_RUN of N targets starting at OFFSET,
# wrapping around, so a network larger than PER_RUN is covered over consecutive runs.
wp_cron_trigger_batch() {
    local n="$1" per_run="$2" offset="$3" count i
    [ "$n" -gt 0 ] || return 0
    count=$(( per_run < n ? per_run : n ))
    for (( i = 0; i < count; i++ )); do
        echo $(( (offset + i) % n ))
    done
}

# "<scheme>://<host><path>" for a target, for the logs.
wp_cron_trigger_url() {
    local scheme host path
    read -r scheme host path <<<"$1"
    echo "${scheme}://${host}${path}"
}

# Requests wp-cron.php for one target through this container's nginx (the loopback-only location).
wp_cron_trigger_fire() {
    local scheme host path
    read -r scheme host path <<<"$1"
    curl -fsS -o /dev/null --max-time 30 -H "Host: ${host}" -H "X-Forwarded-Proto: ${scheme}" \
        "http://127.0.0.1${path}wp-cron.php?doing_wp_cron"
}
