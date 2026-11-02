#!/bin/bash
# Unit tests for scripts/lib/wp_cron_trigger.sh (which sites the internal cron trigger asks for).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/../scripts/lib/wp_cron_trigger.sh"

echo "site URLs become <scheme> <host> <path> (path always ends in /)"
assert_eq "https example.com /" "$(wp_cron_trigger_parse_url https://example.com)" "bare https site"
assert_eq "http example.com /" "$(wp_cron_trigger_parse_url http://example.com/)" "trailing slash kept"
assert_eq "https example.com /blog/" "$(wp_cron_trigger_parse_url https://example.com/blog)" "subdirectory gets a slash"
assert_eq "https example.com /net/sub/" "$(wp_cron_trigger_parse_url https://example.com/net/sub/)" "multisite subdirectory site"
assert_eq "http 127.0.0.1:8000 /" "$(wp_cron_trigger_parse_url http://127.0.0.1:8000)" "host with a port"
assert_eq "https shop.example.com /" "$(wp_cron_trigger_parse_url HTTPS://Shop.Example.com/)" "scheme and host lowercased"
assert_eq "https xn--bcher-kva.example /" "$(wp_cron_trigger_parse_url https://xn--bcher-kva.example)" "punycode host"
for bad in "" "example.com" "ftp://example.com/" "https://" "https://exa mple.com/" "https://example.com/a b/" \
        "https://example.com/?x=1" "https://example.com/#frag" $'https://example.com/\r\nX-Evil: 1' "https://user@example.com/" \
        "https://[::1]/" "javascript:alert(1)"; do
    wp_cron_trigger_parse_url "$bad" >/dev/null && r=accepted || r=rejected
    assert_eq rejected "$r" "rejects '$bad'"
done

echo "batches rotate through a network larger than the per-run limit"
assert_eq "0" "$(wp_cron_trigger_batch 1 3 0 | xargs)" "single site, every run"
assert_eq "0" "$(wp_cron_trigger_batch 1 3 7 | xargs)" "single site whatever the offset"
assert_eq "0 1" "$(wp_cron_trigger_batch 2 3 0 | xargs)" "two sites, both every run"
assert_eq "0 1 2" "$(wp_cron_trigger_batch 7 3 0 | xargs)" "first three of seven"
assert_eq "3 4 5" "$(wp_cron_trigger_batch 7 3 3 | xargs)" "next three"
assert_eq "6 0 1" "$(wp_cron_trigger_batch 7 3 6 | xargs)" "wraps around"
assert_eq "" "$(wp_cron_trigger_batch 0 3 0 | xargs)" "no targets, nothing to do"
seen=""; offset=0
for _ in 1 2 3; do seen="$seen $(wp_cron_trigger_batch 7 3 "$offset" | xargs)"; offset=$(( (offset + 3) % 7 )); done
for i in 0 1 2 3 4 5 6; do assert_contains " $seen " " $i " "site $i covered within three runs"; done

echo "discovery runs WP-CLI as www-data, without plugins or themes, with one argument to eval"
# `wp eval` takes exactly one positional argument (the code); an extra one made WP-CLI fail with
# "Too many positional arguments", so discovery never succeeded and every site fell back to 127.0.0.1.
fake="$(mktemp -d)"
cat > "$fake/setpriv" <<'EOF'
#!/bin/bash
after_eval=-1
for a in "$@"; do
    [ "$after_eval" -ge 0 ] && after_eval=$((after_eval + 1))
    [ "$a" = eval ] && after_eval=0
done
echo "$1 $* eval-args=${after_eval}"
EOF
chmod +x "$fake/setpriv"
call="$(PATH="$fake:$PATH" wp_cron_trigger_discover)"
rm -rf "$fake"
assert_contains "$call" "--reuid=www-data" "as www-data"
assert_contains "$call" "--skip-plugins --skip-themes" "without plugins or themes"
assert_contains "$call" "eval-args=1" "exactly one argument after eval"

echo "discovery covers every live site of a network: no cap, stable order, constant memory"
# A cap (it was the 100 most recently updated sites) left every other subsite without cron, since
# DISABLE_WP_CRON is on; the per-run limit bounds the load instead.
code="$(declare -f wp_cron_trigger_discover)"
assert_contains "$code" '"number" => 0' "no limit on the site query (WP_Site_Query defaults to 100)"
assert_contains "$code" '"orderby" => "id", "order" => "ASC"' "id order, so the rotation is stable across refreshes"
assert_not_contains "$code" "get_site_url(" "siteurl read per site without switching blogs (no per-site cache growth)"
assert_contains "$code" '"archived" => 0, "deleted" => 0' "archived and deleted sites left out"

echo "cycle length: how many runs to reach every site"
assert_eq 1 "$(wp_cron_trigger_cycle_runs 1 3)" "single site"
assert_eq 1 "$(wp_cron_trigger_cycle_runs 3 3)" "exactly one batch"
assert_eq 2 "$(wp_cron_trigger_cycle_runs 4 3)" "one more than a batch"
assert_eq 34 "$(wp_cron_trigger_cycle_runs 101 3)" "101 sites at 3 per run"
assert_eq 0 "$(wp_cron_trigger_cycle_runs 0 3)" "no sites"

echo "refresh: WordPress's answer is used and kept for the refresh period"
wp_cron_trigger_discover() { printf 'https://example.com/\nhttps://example.com/sub/\r\nnot a url\n'; }
WP_CRON_TRIGGER_EXPIRES=0; WP_CRON_TRIGGER_TARGETS=()
wp_cron_trigger_refresh 1000 3600
assert_eq 2 "${#WP_CRON_TRIGGER_TARGETS[@]}" "two valid URLs kept, the junk line dropped"
assert_eq "https example.com /" "${WP_CRON_TRIGGER_TARGETS[0]}" "main site"
assert_eq "https example.com /sub/" "${WP_CRON_TRIGGER_TARGETS[1]}" "subsite (CRLF stripped)"
assert_eq 4600 "$WP_CRON_TRIGGER_EXPIRES" "kept for the refresh period"
assert_eq 0 "$WP_CRON_TRIGGER_FALLBACK" "not the fallback"
wp_cron_trigger_discover() { echo "https://other.example/"; }
wp_cron_trigger_refresh 4599 3600
assert_eq "https example.com /" "${WP_CRON_TRIGGER_TARGETS[0]}" "not asked again before it expires"
wp_cron_trigger_refresh 4600 3600
assert_eq "https other.example /" "${WP_CRON_TRIGGER_TARGETS[0]}" "asked again once it expires"

echo "refresh: when WordPress cannot answer, the loopback target is used and retried soon"
wp_cron_trigger_discover() { return 1; }
WP_CRON_TRIGGER_EXPIRES=0
wp_cron_trigger_refresh 1000 3600
assert_eq "http 127.0.0.1 /" "${WP_CRON_TRIGGER_TARGETS[*]}" "loopback fallback"
assert_eq 1300 "$WP_CRON_TRIGGER_EXPIRES" "retried within five minutes"
assert_eq 1 "$WP_CRON_TRIGGER_FALLBACK" "fallback flagged"
WP_CRON_TRIGGER_EXPIRES=0
wp_cron_trigger_refresh 1000 60
assert_eq 1060 "$WP_CRON_TRIGGER_EXPIRES" "a shorter refresh period wins over the five minutes"
wp_cron_trigger_discover() { echo "Error: not installed"; }
WP_CRON_TRIGGER_EXPIRES=0
wp_cron_trigger_refresh 1000 3600
assert_eq "http 127.0.0.1 /" "${WP_CRON_TRIGGER_TARGETS[*]}" "output without a URL is a failure too"

echo "targets render back to URLs for the logs"
assert_eq "https://example.com/sub/" "$(wp_cron_trigger_url "https example.com /sub/")" "log form"

finish
