#!/bin/sh
# Turns Cloudflare's published edge ranges (https://www.cloudflare.com/ips-v4 and ips-v6) into
# nginx set_real_ip_from directives. Used at image build (Dockerfile, POSIX sh).
#
# Every line of both lists must be a CIDR; anything else (an empty or partial download, an error
# page from a proxy) fails, so the build falls back to the bundled snapshot instead of baking a
# directive nginx rejects at every boot.

# cloudflare_ips_conf <ipv4 list> <ipv6 list>: prints the nginx fragment, or fails (status 1).
cloudflare_ips_conf() {
    _cf_v4="$1"
    _cf_v6="$2"
    [ -n "$_cf_v4" ] && [ -n "$_cf_v6" ] || return 1
    if printf '%s\n' "$_cf_v4" | grep -qvE '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$'; then
        return 1
    fi
    if printf '%s\n' "$_cf_v6" | grep -qviE '^[0-9a-f]{1,4}(:[0-9a-f]{0,4}){1,7}/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$'; then
        return 1
    fi
    echo '# Fetched from Cloudflare at build time.'
    printf '%s\n%s\n' "$_cf_v4" "$_cf_v6" | while IFS= read -r _cf_ip; do
        echo "set_real_ip_from ${_cf_ip};"
    done
}
