#!/bin/bash
set -euo pipefail

NGINX_HTTP_OVERRIDES_FILE="/etc/nginx/conf.d/generated_http_overrides.conf"
NGINX_SERVER_OVERRIDES_FILE="/etc/nginx/conf.d/generated_server_overrides.conf"
NGINX_CACHE_OVERRIDES_FILE="/etc/nginx/conf.d/generated_fastcgi_cache.conf"
NGINX_XMLRPC_OVERRIDES_FILE="/etc/nginx/conf.d/generated_xmlrpc_route.conf"
NGINX_SECURITY_HEADERS_FILE="/etc/nginx/conf.d/generated_security_headers.conf"
NGINX_DEBUG_HEADERS_FILE="/etc/nginx/conf.d/generated_debug_headers.conf"
NGINX_WP_CRON_FILE="/etc/nginx/conf.d/generated_wp_cron.conf"
NGINX_EXTRA_FILE="/etc/nginx/conf.d/generated_extra.conf"
NGINX_CACHE_KEY_FILE="/etc/nginx/conf.d/generated_cache_key.conf"

CACHE_IGNORE_STRIP_LAYERS=16

DEFAULT_RATE_LIMIT_NORMAL_ROUTES_RPM="120"
DEFAULT_RATE_LIMIT_PROTECTED_ROUTES_RPM="30"
DEFAULT_RATE_LIMIT_API_ROUTES_RPM="60"
DEFAULT_RATE_LIMIT_MAX_CONN_PER_IP="30"
DEFAULT_MAX_UPLOAD_SIZE="64M"
DEFAULT_XMLRPC_ENABLED="false"
DEFAULT_DISABLE_PUBLIC_WP_CRON="true"
DEFAULT_DEBUG_HEADERS="false"
DEFAULT_CSP_HEADER="default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: https:; frame-ancestors 'self';"

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

validated_upload_size() {
    local value="$1"
    local fallback="$2"
    local var_name="$3"

    if [[ "$value" =~ ^[0-9]+[KkMmGg]?$ ]]; then
        echo "${value^^}"
        return
    fi

    log "Invalid ${var_name} value '${value}'. Falling back to ${fallback}."
    echo "$fallback"
}

pattern_to_name_regex() {
    local pattern="$1"
    local result=""
    local i char

    for (( i=0; i<${#pattern}; i++ )); do
        char="${pattern:$i:1}"
        case "$char" in
            '*') result+='[^&=]*' ;;
            '.') result+='\\.' ;;
            '+') result+='\\+' ;;
            '?') result+='\\?' ;;
            '^') result+='\\^' ;;
            '$') result+='\\$' ;;
            '(') result+='\\(' ;;
            ')') result+='\\)' ;;
            '[') result+='\\[' ;;
            ']') result+='\\]' ;;
            '{') result+='\\{' ;;
            '}') result+='\\}' ;;
            '|') result+='\\|' ;;
            '\\') result+='\\\\' ;;
            *) result+="$char" ;;
        esac
    done

    echo "$result"
}

parse_cache_ignore_patterns() {
    local json="${CACHE_IGNORE_QUERY_PARAMS:-}"

    if [ -z "$json" ]; then
        return 1
    fi

    CACHE_IGNORE_PATTERNS_JSON="$json" php -r '
        $raw = getenv("CACHE_IGNORE_PATTERNS_JSON") ?: "[]";
        $decoded = json_decode($raw, true);
        if (!is_array($decoded) || json_last_error() !== JSON_ERROR_NONE) {
            fwrite(STDERR, "invalid json\n");
            exit(2);
        }
        foreach ($decoded as $item) {
            if (!is_string($item) || $item === "") {
                exit(3);
            }
            if (!preg_match("/^[A-Za-z0-9_*-]+$/", $item)) {
                exit(4);
            }
            echo $item, "\n";
        }
    '
}

build_cache_ignore_name_regex() {
    local patterns=()
    local pattern regex combined=""

    cache_ignore_name_regex=""
    cache_ignore_patterns_log=""

    patterns_raw="$(parse_cache_ignore_patterns)"
    local parse_rc=$?
    if [ "$parse_rc" -ne 0 ]; then
        return "$parse_rc"
    fi

    while IFS= read -r pattern; do
        [ -n "$pattern" ] || continue
        patterns+=("$pattern")
    done <<< "$patterns_raw"

    if [ "${#patterns[@]}" -eq 0 ]; then
        return 5
    fi

    for pattern in "${patterns[@]}"; do
        regex="$(pattern_to_name_regex "$pattern")"
        if [ -n "$combined" ]; then
            combined+="|"
        fi
        combined+="$regex"
    done

    cache_ignore_patterns_log="$(IFS=,; echo "${patterns[*]}")"
    cache_ignore_name_regex="(?:${combined})"
}

write_default_cache_key() {
    cat > "$NGINX_CACHE_KEY_FILE" <<'EOF'
# Auto-generated at container startup. Do not edit manually.
fastcgi_cache_key "$http_x_forwarded_proto|$request_method|$host|$request_uri";
EOF
}

write_normalized_cache_key() {
    local name_regex="$1"
    local layer from_var to_var

    {
        echo "# Auto-generated at container startup. Do not edit manually."
        echo "# Cache key ignores query params matching: ${cache_ignore_patterns_log}"
        echo ""
        echo "map \$request_uri \$cache_uri_path {"
        echo "    default \$request_uri;"
        echo "    ~^([^?]+) \$1;"
        echo "}"
        echo ""
        echo "map \$args \$cache_args_0 {"
        echo "    default \$args;"
        echo '    "" "";'
        echo "}"
        echo ""

        from_var="cache_args_0"
        for (( layer=0; layer<CACHE_IGNORE_STRIP_LAYERS; layer++ )); do
            to_var="cache_args_$((layer + 1))"
            cat <<EOF
map \$${from_var} \$${to_var} {
    default \$${from_var};
    ~^(.*)&${name_regex}=[^&]*&(.*)$ \$1&\$2;
    ~^(.*)&${name_regex}=[^&]*$ \$1;
    ~^${name_regex}=[^&]*&(.*)$ \$1;
    ~^${name_regex}=[^&]*$ "";
}

EOF
            from_var="$to_var"
        done

        cat <<EOF
map \$${from_var} \$cache_args {
    default \$${from_var};
    ~^&(.*)$ \$1;
    ~^(.*)&$ \$1;
    ~^&+$ "";
}

map \$cache_args \$cache_key_suffix {
    default "?\$cache_args";
    "" "";
}

fastcgi_cache_key "\$http_x_forwarded_proto|\$request_method|\$host|\$cache_uri_path\$cache_key_suffix";
EOF
    } > "$NGINX_CACHE_KEY_FILE"
}

# --- Parse env vars ---

xmlrpc_enabled_raw="${XMLRPC_ENABLED:-$DEFAULT_XMLRPC_ENABLED}"
disable_public_wp_cron_raw="${DISABLE_PUBLIC_WP_CRON:-$DEFAULT_DISABLE_PUBLIC_WP_CRON}"
debug_headers_raw="${DEBUG_HEADERS:-$DEFAULT_DEBUG_HEADERS}"
csp_header="${CSP_HEADER:-$DEFAULT_CSP_HEADER}"
nginx_extra_conf="${NGINX_EXTRA_CONF:-}"

normal_routes_rpm="$(validated_positive_int "${RATE_LIMIT_NORMAL_ROUTES_RPM:-$DEFAULT_RATE_LIMIT_NORMAL_ROUTES_RPM}" "$DEFAULT_RATE_LIMIT_NORMAL_ROUTES_RPM" "RATE_LIMIT_NORMAL_ROUTES_RPM")"
protected_routes_rpm="$(validated_positive_int "${RATE_LIMIT_PROTECTED_ROUTES_RPM:-$DEFAULT_RATE_LIMIT_PROTECTED_ROUTES_RPM}" "$DEFAULT_RATE_LIMIT_PROTECTED_ROUTES_RPM" "RATE_LIMIT_PROTECTED_ROUTES_RPM")"
api_routes_rpm="$(validated_positive_int "${RATE_LIMIT_API_ROUTES_RPM:-$DEFAULT_RATE_LIMIT_API_ROUTES_RPM}" "$DEFAULT_RATE_LIMIT_API_ROUTES_RPM" "RATE_LIMIT_API_ROUTES_RPM")"
max_conn_per_ip="$(validated_positive_int "${RATE_LIMIT_MAX_CONN_PER_IP:-$DEFAULT_RATE_LIMIT_MAX_CONN_PER_IP}" "$DEFAULT_RATE_LIMIT_MAX_CONN_PER_IP" "RATE_LIMIT_MAX_CONN_PER_IP")"
max_upload_size="$(validated_upload_size "${MAX_UPLOAD_SIZE:-$DEFAULT_MAX_UPLOAD_SIZE}" "$DEFAULT_MAX_UPLOAD_SIZE" "MAX_UPLOAD_SIZE")"

# --- Cache and TTL ---

cache_enabled="false"
cache_ttl_seconds=""

if [ -n "${CACHE_TTL_SECONDS:-}" ]; then
    if [[ "$CACHE_TTL_SECONDS" =~ ^[0-9]+$ ]] && [ "$CACHE_TTL_SECONDS" -ge 1 ]; then
        cache_enabled="true"
        cache_ttl_seconds="$CACHE_TTL_SECONDS"
    else
        log "Invalid CACHE_TTL_SECONDS value '${CACHE_TTL_SECONDS}'. Must be a positive integer."
        exit 1
    fi
fi

# --- Cache ignore query params (requires cache enabled) ---

cache_ignore_query_params_enabled="false"
cache_ignore_patterns_log=""

if [ "$cache_enabled" = "true" ] && [ -n "${CACHE_IGNORE_QUERY_PARAMS:-}" ]; then
    parse_status=0
    build_cache_ignore_name_regex || parse_status=$?

    if [ "$parse_status" -eq 0 ] && [ -n "$cache_ignore_name_regex" ]; then
        cache_ignore_query_params_enabled="true"
    elif [ "$parse_status" -eq 5 ]; then
        log "CACHE_IGNORE_QUERY_PARAMS is empty or []. Using default cache key."
    else
        log "Invalid CACHE_IGNORE_QUERY_PARAMS value '${CACHE_IGNORE_QUERY_PARAMS}'. Must be a JSON array of non-empty strings (allowed: A-Za-z0-9_*-)."
        exit 1
    fi
fi

# nginx lowercase size suffix (e.g. 64M -> 64m)
nginx_upload_size="${max_upload_size,,}"

# --- Write generated files ---

# http{} context: rate limit zones + upload size.
cat > "$NGINX_HTTP_OVERRIDES_FILE" <<EOF
# Auto-generated at container startup. Do not edit manually.
limit_req_zone \$binary_remote_addr zone=normal_routes:20m rate=${normal_routes_rpm}r/m;
limit_req_zone \$binary_remote_addr zone=protected_routes:20m rate=${protected_routes_rpm}r/m;
limit_req_zone \$binary_remote_addr zone=api_routes:20m rate=${api_routes_rpm}r/m;
client_max_body_size ${nginx_upload_size};
EOF

# server{} context: per-IP connection limit.
cat > "$NGINX_SERVER_OVERRIDES_FILE" <<EOF
# Auto-generated at container startup. Do not edit manually.
limit_conn per_ip_conn ${max_conn_per_ip};
EOF

# FastCGI cache directives (location{} context).
if [ "$cache_enabled" = "true" ]; then
    cat > "$NGINX_CACHE_OVERRIDES_FILE" <<EOF
# Auto-generated at container startup. Do not edit manually.
fastcgi_cache_valid 200 301 302 ${cache_ttl_seconds}s;
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
# Caching disabled.
fastcgi_cache_bypass 1;
fastcgi_no_cache 1;
EOF
fi

# FastCGI cache key (http{} context).
if [ "$cache_ignore_query_params_enabled" = "true" ]; then
    write_normalized_cache_key "$cache_ignore_name_regex"
else
    write_default_cache_key
fi

# XML-RPC route (location{} context).
if is_true "$xmlrpc_enabled_raw"; then
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

# wp-cron location block (server{} context, full location block).
if is_true "$disable_public_wp_cron_raw"; then
    cat > "$NGINX_WP_CRON_FILE" <<'EOF'
# Auto-generated at container startup. Do not edit manually.
# wp-cron restricted to localhost. Use a Kubernetes CronJob to trigger it.
location = /wp-cron.php {
    allow 127.0.0.1;
    deny all;
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
}
EOF
else
    cat > "$NGINX_WP_CRON_FILE" <<'EOF'
# Auto-generated at container startup. Do not edit manually.
# wp-cron public access enabled (DISABLE_PUBLIC_WP_CRON=false).
location = /wp-cron.php {
    limit_req zone=protected_routes burst=3 nodelay;
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
}
EOF
fi

# Security headers (server{} context): CSP.
cat > "$NGINX_SECURITY_HEADERS_FILE" <<EOF
# Auto-generated at container startup. Do not edit manually.
add_header Content-Security-Policy "${csp_header}" always;
EOF

# Debug headers (location{} context inside PHP handler): X-Cache when DEBUG_HEADERS=true.
if is_true "$debug_headers_raw"; then
    cat > "$NGINX_DEBUG_HEADERS_FILE" <<'EOF'
# Auto-generated at container startup. Do not edit manually.
add_header X-Cache $upstream_cache_status always;
EOF
else
    cat > "$NGINX_DEBUG_HEADERS_FILE" <<'EOF'
# Auto-generated at container startup. Do not edit manually.
# X-Cache header disabled (set DEBUG_HEADERS=true to enable).
EOF
fi

# Customer-injected nginx config (server{} context).
if [ -n "$nginx_extra_conf" ]; then
    printf '%s\n' "# Auto-generated at container startup. Do not edit manually." > "$NGINX_EXTRA_FILE"
    printf '%s\n' "$nginx_extra_conf" >> "$NGINX_EXTRA_FILE"
else
    cat > "$NGINX_EXTRA_FILE" <<'EOF'
# Auto-generated at container startup. Do not edit manually.
# No NGINX_EXTRA_CONF set.
EOF
fi

log "Generated overrides:"
log "  cache_enabled=${cache_enabled}, cache_ttl_seconds=${cache_ttl_seconds:-unset}"
log "  cache_ignore_query_params=$([ "$cache_ignore_query_params_enabled" = "true" ] && echo "$cache_ignore_patterns_log" || echo "disabled")"
log "  xmlrpc_enabled=${xmlrpc_enabled_raw}, disable_public_wp_cron=${disable_public_wp_cron_raw}"
log "  max_upload_size=${max_upload_size}, max_conn_per_ip=${max_conn_per_ip}"
log "  normal_routes_rpm=${normal_routes_rpm}, protected_routes_rpm=${protected_routes_rpm}, api_routes_rpm=${api_routes_rpm}"
log "  debug_headers=${debug_headers_raw}, csp_header=$([ -n "$csp_header" ] && echo "set" || echo "empty")"
log "  nginx_extra_conf=$([ -n "$nginx_extra_conf" ] && echo "set" || echo "empty")"
