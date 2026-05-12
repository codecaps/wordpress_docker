#!/bin/bash
set -euo pipefail

NGINX_HTTP_OVERRIDES_FILE="/etc/nginx/conf.d/generated_http_overrides.conf"
NGINX_CACHE_OVERRIDES_FILE="/etc/nginx/conf.d/generated_fastcgi_cache.conf"
NGINX_XMLRPC_OVERRIDES_FILE="/etc/nginx/conf.d/generated_xmlrpc_route.conf"

DEFAULT_CACHE_ENABLED="false"
DEFAULT_CACHE_TTL_MINUTES="10"
DEFAULT_RATE_LIMIT_NORMAL_ROUTES_RPM="120"
DEFAULT_RATE_LIMIT_PROTECTED_ROUTES_RPM="30"
DEFAULT_RATE_LIMIT_API_ROUTES_RPM="60"
DEFAULT_XMLRPC_ENABLED="false"

log() {
    echo "[nginx-overrides] $*"
}

is_true() {
    case "${1,,}" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

validated_positive_int() {
    local value="$1"
    local fallback="$2"
    local var_name="$3"

    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ]; then
        echo "$value"
        return
    fi

    log "Invalid ${var_name} value '${value}'. Falling back to ${fallback}."
    echo "$fallback"
}

cache_enabled_raw="${CACHE_ENABLED:-$DEFAULT_CACHE_ENABLED}"
xmlrpc_enabled_raw="${XMLRPC_ENABLED:-$DEFAULT_XMLRPC_ENABLED}"
cache_ttl_minutes="$(validated_positive_int "${CACHE_TTL_MINUTES:-$DEFAULT_CACHE_TTL_MINUTES}" "$DEFAULT_CACHE_TTL_MINUTES" "CACHE_TTL_MINUTES")"
normal_routes_rpm="$(validated_positive_int "${RATE_LIMIT_NORMAL_ROUTES_RPM:-$DEFAULT_RATE_LIMIT_NORMAL_ROUTES_RPM}" "$DEFAULT_RATE_LIMIT_NORMAL_ROUTES_RPM" "RATE_LIMIT_NORMAL_ROUTES_RPM")"
protected_routes_rpm="$(validated_positive_int "${RATE_LIMIT_PROTECTED_ROUTES_RPM:-$DEFAULT_RATE_LIMIT_PROTECTED_ROUTES_RPM}" "$DEFAULT_RATE_LIMIT_PROTECTED_ROUTES_RPM" "RATE_LIMIT_PROTECTED_ROUTES_RPM")"
api_routes_rpm="$(validated_positive_int "${RATE_LIMIT_API_ROUTES_RPM:-$DEFAULT_RATE_LIMIT_API_ROUTES_RPM}" "$DEFAULT_RATE_LIMIT_API_ROUTES_RPM" "RATE_LIMIT_API_ROUTES_RPM")"

if is_true "$cache_enabled_raw"; then
    cache_enabled="true"
else
    cache_enabled="false"
fi

if is_true "$xmlrpc_enabled_raw"; then
    xmlrpc_enabled="true"
else
    xmlrpc_enabled="false"
fi

cat > "$NGINX_HTTP_OVERRIDES_FILE" <<EOF
# Auto-generated at container startup. Do not edit manually.
limit_req_zone \$binary_remote_addr zone=normal_routes:20m rate=${normal_routes_rpm}r/m;
limit_req_zone \$binary_remote_addr zone=protected_routes:20m rate=${protected_routes_rpm}r/m;
limit_req_zone \$binary_remote_addr zone=api_routes:20m rate=${api_routes_rpm}r/m;
EOF

if [ "$cache_enabled" = "true" ]; then
    cat > "$NGINX_CACHE_OVERRIDES_FILE" <<EOF
# Auto-generated at container startup. Do not edit manually.
fastcgi_cache_valid 200 301 302 ${cache_ttl_minutes}m;
fastcgi_cache_valid 404 1m;
fastcgi_cache_use_stale error timeout updating http_500 http_503;
fastcgi_cache_background_update on;
fastcgi_cache_lock on;
fastcgi_cache_lock_timeout 10s;
fastcgi_cache_bypass \$skip_cache;
fastcgi_no_cache \$skip_cache \$upstream_http_set_cookie;
EOF
else
    cat > "$NGINX_CACHE_OVERRIDES_FILE" <<'EOF'
# Auto-generated at container startup. Do not edit manually.
# Caching disabled by NGINX_CACHE_ENABLED.
fastcgi_cache_bypass 1;
fastcgi_no_cache 1;
EOF
fi

if [ "$xmlrpc_enabled" = "true" ]; then
    cat > "$NGINX_XMLRPC_OVERRIDES_FILE" <<'EOF'
# Auto-generated at container startup. Do not edit manually.
include fastcgi_params;
fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
fastcgi_param SCRIPT_NAME $fastcgi_script_name;
fastcgi_param REMOTE_ADDR $remote_addr;
fastcgi_param HTTP_X_REAL_IP $remote_addr;
fastcgi_param HTTP_X_FORWARDED_FOR $http_x_forwarded_for;
fastcgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
fastcgi_pass php_fpm;
fastcgi_no_cache 1;
fastcgi_cache_bypass 1;
EOF
else
    cat > "$NGINX_XMLRPC_OVERRIDES_FILE" <<'EOF'
# Auto-generated at container startup. Do not edit manually.
return 403;
EOF
fi

log "Generated overrides: cache_enabled=${cache_enabled}, xmlrpc_enabled=${xmlrpc_enabled}, cache_ttl_minutes=${cache_ttl_minutes}, normal_routes_rpm=${normal_routes_rpm}, protected_routes_rpm=${protected_routes_rpm}, api_routes_rpm=${api_routes_rpm}"
