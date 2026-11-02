#!/bin/bash
# Unit tests for scripts/lib/merge_and_write_config.sh (the awk merge both configure scripts use).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/../scripts/lib/merge_and_write_config.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
defaults=$'; Security\nexpose_php = Off\n\n; Limits\nmemory_limit = 128M\n'
pool=$'[global]\n; master\nprocess_control_timeout = 10s\n\n[www]\nlisten = 127.0.0.1:9000\npm.max_children = 3\npm.max_spare_servers = 2\n'

echo "an empty override reproduces the defaults byte for byte (comments and blank lines included)"
merge_and_write_config "$defaults" "" "$tmp/a.ini" 0 ini >/dev/null
assert_eq "$(printf '%s' "$defaults")" "$(cat "$tmp/a.ini")" "flat file unchanged"
assert_eq 2 "$(grep -c '^;' "$tmp/a.ini")" "comment lines kept"
merge_and_write_config "$pool" "" "$tmp/a.conf" 1 pool >/dev/null
assert_eq "$(printf '%s' "$pool")" "$(cat "$tmp/a.conf")" "sectioned file unchanged"

echo "an override replaces the key in place, keeps the rest, and drops CRLF"
merge_and_write_config "$defaults" $'memory_limit = 512M\r\n' "$tmp/b.ini" 0 ini >/dev/null
assert_contains "$(cat "$tmp/b.ini")" $'; Limits\nmemory_limit = 512M' "replaced in place after its comment"
assert_not_contains "$(cat "$tmp/b.ini")" "128M" "default value gone"
assert_eq 0 "$(grep -c $'\r' "$tmp/b.ini")" "no carriage returns"
assert_eq 1 "$(grep -c '^memory_limit' "$tmp/b.ini")" "key appears once"

echo "unknown keys are appended; the last occurrence of a duplicated override key wins"
merge_and_write_config "$defaults" $'memory_limit = 1G\nmy.key = a\nmemory_limit = 256M' "$tmp/c.ini" 0 ini >/dev/null
assert_contains "$(cat "$tmp/c.ini")" $'\nmemory_limit = 256M\n' "last wins"
assert_not_contains "$(cat "$tmp/c.ini")" "1G" "earlier duplicate dropped"
assert_contains "$(cat "$tmp/c.ini")" $'\nmy.key = a' "unknown key appended"

echo "sectioned merge: same key in another section is distinct; unknown keys are appended at the end under their section header"
merge_and_write_config "$pool" $'[www]\npm.max_children = 9\n[global]\nlog_level = notice\n[extra]\nlisten = 9001' "$tmp/d.conf" 1 pool >/dev/null
out="$(cat "$tmp/d.conf")"
assert_contains "$out" $'[www]\nlisten = 127.0.0.1:9000\npm.max_children = 9\npm.max_spare_servers = 2' "www key replaced in place"
assert_contains "$out" $'[global]\n; master\nprocess_control_timeout = 10s\n' "existing global section untouched"
assert_contains "$out" $'\n[global]\nlog_level = notice\n' "unknown global key appended under a repeated [global] header (php-fpm re-enters the section)"
assert_contains "$out" $'[extra]\nlisten = 9001' "new section appended with a header"
assert_eq 1 "$(grep -c '^listen = 127.0.0.1:9000' "$tmp/d.conf")" "www listen untouched by the [extra] listen"

echo "lines without '=' and comments in the override are ignored"
merge_and_write_config "$defaults" $'; a comment\nnot a setting\n# another' "$tmp/e.ini" 0 ini >/dev/null
assert_eq "$(printf '%s' "$defaults")" "$(cat "$tmp/e.ini")" "defaults unchanged"

finish
