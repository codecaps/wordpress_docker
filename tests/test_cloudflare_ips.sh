#!/bin/bash
# Unit tests for scripts/lib/cloudflare_ips.sh (the build-time Cloudflare range check).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/../scripts/lib/cloudflare_ips.sh"

v4=$'173.245.48.0/20\n103.21.244.0/22\n104.16.0.0/13'
v6=$'2400:cb00::/32\n2606:4700::/32\n2a06:98c0::/29'

conf_rc() { cloudflare_ips_conf "$1" "$2" >/dev/null; echo $?; }

echo "well-formed lists become set_real_ip_from lines"
out="$(cloudflare_ips_conf "$v4" "$v6")"
assert_eq 0 "$?" "accepted"
assert_eq 6 "$(grep -c '^set_real_ip_from ' <<<"$out")" "one directive per range"
assert_contains "$out" $'set_real_ip_from 173.245.48.0/20;\n' "IPv4 range"
assert_contains "$out" "set_real_ip_from 2a06:98c0::/29;" "IPv6 range"
assert_eq "# Fetched from Cloudflare at build time." "$(head -1 <<<"$out")" "marked as fetched"

echo "anything but CIDR lines in either list falls back to the snapshot"
assert_eq 1 "$(conf_rc "" "$v6")" "empty IPv4 list"
assert_eq 1 "$(conf_rc "$v4" "")" "empty IPv6 list"
assert_eq 1 "$(conf_rc $'173.245.48.0/20\n<html>' "$v6")" "one valid IPv4 line among junk (the old check accepted this)"
assert_eq 1 "$(conf_rc "$v4" $'2400:cb00::/32\nService Unavailable')" "junk in the IPv6 list (never checked before)"
assert_eq 1 "$(conf_rc $'173.245.48.0/33' "$v6")" "IPv4 prefix out of range"
assert_eq 1 "$(conf_rc "$v4" $'2400:cb00::/129')" "IPv6 prefix out of range"
assert_eq 1 "$(conf_rc $'173.245.48.0/20\r' "$v6")" "CRLF line endings"
assert_eq 1 "$(conf_rc $'173.245.48.0/20;\ninclude /etc/passwd' "$v6")" "an nginx directive smuggled in"

finish
