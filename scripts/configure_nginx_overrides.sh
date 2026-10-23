#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/runtime_env.sh
source "$SCRIPT_DIR/lib/runtime_env.sh"

NGINX_MAIN_OVERRIDES_FILE="/etc/nginx/conf.d/generated_main_overrides.conf"
NGINX_TRUSTED_PROXIES_FILE="/etc/nginx/conf.d/generated_trusted_proxies.conf"
NGINX_HTTP_OVERRIDES_FILE="/etc/nginx/conf.d/generated_http_overrides.conf"
NGINX_SERVER_OVERRIDES_FILE="/etc/nginx/conf.d/generated_server_overrides.conf"
NGINX_CACHE_OVERRIDES_FILE="/etc/nginx/conf.d/generated_fastcgi_cache.conf"
NGINX_CACHE_PURGE_FILE="/etc/nginx/conf.d/generated_cache_purge.conf"
NGINX_XMLRPC_OVERRIDES_FILE="/etc/nginx/conf.d/generated_xmlrpc_route.conf"
NGINX_SECURITY_HEADERS_FILE="/etc/nginx/conf.d/generated_security_headers.conf"
NGINX_DEBUG_HEADERS_FILE="/etc/nginx/conf.d/generated_debug_headers.conf"
NGINX_WP_CRON_FILE="/etc/nginx/conf.d/generated_wp_cron.conf"
NGINX_EXTRA_FILE="/etc/nginx/conf.d/generated_extra.conf"
NGINX_CACHE_KEY_FILE="/etc/nginx/conf.d/generated_cache_key.conf"
RUNTIME_STATE_DIR="/var/run/wp-runtime"
CACHE_STATE_FILE="${RUNTIME_STATE_DIR}/nginx-cache.env"

CACHE_IGNORE_STRIP_LAYERS=16

DEFAULT_RATE_LIMIT_NORMAL_ROUTES_RPM="300"
DEFAULT_RATE_LIMIT_PROTECTED_ROUTES_RPM="120"
DEFAULT_RATE_LIMIT_LOGIN_ROUTES_RPM="30"
DEFAULT_RATE_LIMIT_API_ROUTES_RPM="300"
DEFAULT_RATE_LIMIT_MAX_CONN_PER_IP="100"
DEFAULT_MAX_UPLOAD_SIZE="64M"
DEFAULT_CACHE_TTL_SECONDS="60"
DEFAULT_CACHE_MAX_SIZE="512M"
DEFAULT_XMLRPC_ENABLED="false"
DEFAULT_DISABLE_PUBLIC_WP_CRON="true"
DEFAULT_DEBUG_HEADERS="false"
DEFAULT_CSP_HEADER="default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: https:; connect-src 'self' https: wss:; frame-ancestors 'self';"
DEFAULT_HSTS_HEADER="max-age=31536000"
DEFAULT_TRUSTED_PROXY_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"

log() {
    echo "[nginx-overrides] $*"
}

# A header value that is safe inside a double-quoted nginx string: no quotes, no $ (variable
# interpolation), no backslashes, no newlines. Falls back to the default, loudly.
validated_header_value() {
    local value="$1" fallback="$2" var_name="$3"
    if [[ "$value" =~ ^[A-Za-z0-9\ \'\*:\;/.,_=+~!%@-]*$ ]]; then
        echo "$value"
        return
    fi
    log "Invalid ${var_name} value (only letters, digits, space and ' * : ; / . , _ = + ~ ! % @ - are allowed). Falling back to the default."
    echo "$fallback"
}

validated_cidrs() {
    local raw="$1" fallback="$2" var_name="$3" out="" cidr
    for cidr in ${raw//,/ }; do
        if [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || [[ "$cidr" =~ ^[0-9A-Fa-f:]+(/[0-9]+)?$ ]]; then
            out="${out}${cidr} "
        else
            log "Invalid ${var_name} entry '${cidr}'. Falling back to the default list."
            echo "$fallback"
            return
        fi
    done
    echo "${out% }"
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

    CACHE_IGNORE_PATTERNS_JSON="$json" php -d auto_prepend_file= -r '
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

# The cache key is "<scheme>|<method>|<host>|<uri>". The runtime mu-plugin purges with the
# ngx_cache_purge module (exact key, "<prefix>*", or "*" for everything) — keep the shape stable.
write_default_cache_key() {
    cat > "$NGINX_CACHE_KEY_FILE" <<'EOC'
# Auto-generated at container startup. Do not edit manually.
fastcgi_cache_key "$forwarded_scheme|$request_method|$host|$request_uri";
EOC
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
            cat <<EOC
map \$${from_var} \$${to_var} {
    default \$${from_var};
    ~^(.*)&${name_regex}=[^&]*&(.*)$ \$1&\$2;
    ~^(.*)&${name_regex}=[^&]*$ \$1;
    ~^${name_regex}=[^&]*&(.*)$ \$1;
    ~^${name_regex}=[^&]*$ "";
}

EOC
            from_var="$to_var"
        done

        cat <<EOC
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

fastcgi_cache_key "\$forwarded_scheme|\$request_method|\$host|\$cache_uri_path\$cache_key_suffix";
EOC
    } > "$NGINX_CACHE_KEY_FILE"
}

# --- Parse env vars ---

xmlrpc_enabled_raw="${XMLRPC_ENABLED:-$DEFAULT_XMLRPC_ENABLED}"
disable_public_wp_cron_raw="${DISABLE_PUBLIC_WP_CRON:-$DEFAULT_DISABLE_PUBLIC_WP_CRON}"
debug_headers_raw="${DEBUG_HEADERS:-$DEFAULT_DEBUG_HEADERS}"
nginx_extra_conf="${NGINX_EXTRA_CONF:-}"

csp_header="$(validated_header_value "${CSP_HEADER-$DEFAULT_CSP_HEADER}" "$DEFAULT_CSP_HEADER" "CSP_HEADER")"
hsts_header="$(validated_header_value "${HSTS_HEADER-$DEFAULT_HSTS_HEADER}" "$DEFAULT_HSTS_HEADER" "HSTS_HEADER")"
trusted_proxy_cidrs="$(validated_cidrs "${TRUSTED_PROXY_CIDRS:-$DEFAULT_TRUSTED_PROXY_CIDRS}" "$DEFAULT_TRUSTED_PROXY_CIDRS" "TRUSTED_PROXY_CIDRS")"

normal_routes_rpm="$(validated_positive_int "${RATE_LIMIT_NORMAL_ROUTES_RPM:-$DEFAULT_RATE_LIMIT_NORMAL_ROUTES_RPM}" "$DEFAULT_RATE_LIMIT_NORMAL_ROUTES_RPM" "RATE_LIMIT_NORMAL_ROUTES_RPM")"
protected_routes_rpm="$(validated_positive_int "${RATE_LIMIT_PROTECTED_ROUTES_RPM:-$DEFAULT_RATE_LIMIT_PROTECTED_ROUTES_RPM}" "$DEFAULT_RATE_LIMIT_PROTECTED_ROUTES_RPM" "RATE_LIMIT_PROTECTED_ROUTES_RPM")"
login_routes_rpm="$(validated_positive_int "${RATE_LIMIT_LOGIN_ROUTES_RPM:-$DEFAULT_RATE_LIMIT_LOGIN_ROUTES_RPM}" "$DEFAULT_RATE_LIMIT_LOGIN_ROUTES_RPM" "RATE_LIMIT_LOGIN_ROUTES_RPM")"
api_routes_rpm="$(validated_positive_int "${RATE_LIMIT_API_ROUTES_RPM:-$DEFAULT_RATE_LIMIT_API_ROUTES_RPM}" "$DEFAULT_RATE_LIMIT_API_ROUTES_RPM" "RATE_LIMIT_API_ROUTES_RPM")"
max_conn_per_ip="$(validated_positive_int "${RATE_LIMIT_MAX_CONN_PER_IP:-$DEFAULT_RATE_LIMIT_MAX_CONN_PER_IP}" "$DEFAULT_RATE_LIMIT_MAX_CONN_PER_IP" "RATE_LIMIT_MAX_CONN_PER_IP")"
max_upload_size="$(validated_upload_size "${MAX_UPLOAD_SIZE:-$DEFAULT_MAX_UPLOAD_SIZE}" "$DEFAULT_MAX_UPLOAD_SIZE" "MAX_UPLOAD_SIZE")"
cache_max_size="$(validated_upload_size "${CACHE_MAX_SIZE:-$DEFAULT_CACHE_MAX_SIZE}" "$DEFAULT_CACHE_MAX_SIZE" "CACHE_MAX_SIZE")"

# nginx workers: one per CPU the cgroup allows, 1..4 (nginx is not the bottleneck in front of
# PHP-FPM; `auto` would spawn one per host core regardless of the pod's quota).
worker_processes="$(clamp "$(cgroup_cpu_limit)" 1 4)"
if [ -n "${NGINX_WORKER_PROCESSES:-}" ]; then
    worker_processes="$(validated_positive_int "$NGINX_WORKER_PROCESSES" "$worker_processes" "NGINX_WORKER_PROCESSES")"
fi

# --- Cache and TTL ---
# On by default (60s). CACHE_TTL_SECONDS=0/off/false disables; anything else invalid keeps the default.

cache_enabled="true"
cache_ttl_seconds="$DEFAULT_CACHE_TTL_SECONDS"
cache_ttl_raw="${CACHE_TTL_SECONDS:-$DEFAULT_CACHE_TTL_SECONDS}"
if [[ "${cache_ttl_raw,,}" =~ ^(0|off|false|no|none|disabled)$ ]]; then
    cache_enabled="false"
    cache_ttl_seconds=""
elif [[ "$cache_ttl_raw" =~ ^[0-9]+$ ]] && [ "$cache_ttl_raw" -ge 1 ]; then
    cache_ttl_seconds="$cache_ttl_raw"
else
    log "Invalid CACHE_TTL_SECONDS value '${cache_ttl_raw}' (positive integer, or 0 to disable). Falling back to ${DEFAULT_CACHE_TTL_SECONDS}."
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
        log "Invalid CACHE_IGNORE_QUERY_PARAMS value '${CACHE_IGNORE_QUERY_PARAMS}'. Must be a JSON array of non-empty strings (allowed: A-Za-z0-9_*-). Using default cache key."
    fi
fi

# nginx lowercase size suffix (e.g. 64M -> 64m)
nginx_upload_size="${max_upload_size,,}"
nginx_cache_max_size="${cache_max_size,,}"

# --- Write generated files ---

# main{} context: worker count.
cat > "$NGINX_MAIN_OVERRIDES_FILE" <<EOC
# Auto-generated at container startup. Do not edit manually.
worker_processes ${worker_processes};
EOC

# http{} context: trusted intermediaries whose X-Forwarded-For is believed (plus Cloudflare's
# edge ranges, baked at build into cloudflare_ips.conf).
{
    echo "# Auto-generated at container startup. Do not edit manually."
    for cidr in $trusted_proxy_cidrs; do
        echo "set_real_ip_from ${cidr};"
    done
} > "$NGINX_TRUSTED_PROXIES_FILE"

# http{} context: rate limit zones, cache storage, upload size, HSTS.
cat > "$NGINX_HTTP_OVERRIDES_FILE" <<EOC
# Auto-generated at container startup. Do not edit manually.
limit_req_zone \$binary_remote_addr zone=normal_routes:20m rate=${normal_routes_rpm}r/m;
limit_req_zone \$binary_remote_addr zone=protected_routes:20m rate=${protected_routes_rpm}r/m;
limit_req_zone \$binary_remote_addr zone=login_routes:10m rate=${login_routes_rpm}r/m;
limit_req_zone \$binary_remote_addr zone=api_routes:20m rate=${api_routes_rpm}r/m;
client_max_body_size ${nginx_upload_size};

# FastCGI full-page cache storage (keys_zone 64m indexes ~500k pages).
fastcgi_cache_path /var/cache/nginx/wordpress
    levels=1:2
    keys_zone=WORDPRESS:64m
    inactive=60m
    max_size=${nginx_cache_max_size}
    use_temp_path=off;

# HSTS only when the request arrived over HTTPS (Traefik sets X-Forwarded-Proto).
map \$forwarded_scheme \$hsts_header {
    https   "${hsts_header}";
    default "";
}
EOC

# server{} context: per-IP connection limit.
cat > "$NGINX_SERVER_OVERRIDES_FILE" <<EOC
# Auto-generated at container startup. Do not edit manually.
limit_conn per_ip_conn ${max_conn_per_ip};
EOC

# Never cache an empty-bodied 200 (e.g. a blank page from a failed whole-page
# output buffer). Controlled by CACHE_SKIP_EMPTY (default: true); references the
# $cache_skip_empty map in nginx.conf.
cache_skip_empty_enabled="true"
if is_false "${CACHE_SKIP_EMPTY:-true}"; then
    cache_skip_empty_enabled="false"
fi

cache_no_cache_vars="\$skip_cache \$upstream_http_set_cookie"
if [ "$cache_skip_empty_enabled" = "true" ]; then
    cache_no_cache_vars="$cache_no_cache_vars \$cache_skip_empty"
fi

# FastCGI cache directives (location{} context) + the loopback purge endpoint the runtime
# mu-plugin calls. The token stops anyone who can spoof X-Forwarded-For: 127.0.0.1 from purging.
mkdir -p "$RUNTIME_STATE_DIR"
if [ "$cache_enabled" = "true" ]; then
    purge_token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    cat > "$NGINX_CACHE_OVERRIDES_FILE" <<EOC
# Auto-generated at container startup. Do not edit manually.
fastcgi_cache_valid 200 301 302 ${cache_ttl_seconds}s;
fastcgi_cache_valid 404 1m;
fastcgi_cache_use_stale error timeout updating http_500 http_503;
fastcgi_cache_background_update on;
fastcgi_cache_lock on;
fastcgi_cache_lock_timeout 10s;
fastcgi_cache_bypass \$skip_cache;
fastcgi_no_cache ${cache_no_cache_vars};
EOC
    cat > "$NGINX_CACHE_PURGE_FILE" <<EOC
# Auto-generated at container startup. Do not edit manually.
# Purge endpoint for the runtime mu-plugin (loopback only, token required).
# ?key=<exact cache key> | ?key=<prefix>* | ?key=*  (everything)
location = /.cc-cache-purge {
    allow 127.0.0.1;
    deny all;
    access_log off;
    if (\$arg_token != "${purge_token}") {
        return 403;
    }
    fastcgi_cache_purge WORDPRESS \$arg_key;
}
EOC
    printf 'enabled=1\nttl=%s\ntoken=%s\n' "$cache_ttl_seconds" "$purge_token" > "$CACHE_STATE_FILE"
else
    cat > "$NGINX_CACHE_OVERRIDES_FILE" <<'EOC'
# Auto-generated at container startup. Do not edit manually.
# Caching disabled.
fastcgi_cache_bypass 1;
fastcgi_no_cache 1;
EOC
    cat > "$NGINX_CACHE_PURGE_FILE" <<'EOC'
# Auto-generated at container startup. Do not edit manually.
# Caching disabled: no purge endpoint.
EOC
    printf 'enabled=0\nttl=0\ntoken=\n' > "$CACHE_STATE_FILE"
fi
# PHP (www-data) reads the state; nobody else needs to.
chown root:www-data "$CACHE_STATE_FILE" 2>/dev/null || true
chmod 640 "$CACHE_STATE_FILE" 2>/dev/null || true

# FastCGI cache key (http{} context).
if [ "$cache_ignore_query_params_enabled" = "true" ]; then
    write_normalized_cache_key "$cache_ignore_name_regex"
else
    write_default_cache_key
fi

# XML-RPC route (location{} context).
if is_true "$xmlrpc_enabled_raw"; then
    cat > "$NGINX_XMLRPC_OVERRIDES_FILE" <<'EOC'
# Auto-generated at container startup. Do not edit manually.
include /etc/nginx/snippets/wp-fastcgi.conf;
fastcgi_no_cache 1;
fastcgi_cache_bypass 1;
EOC
else
    cat > "$NGINX_XMLRPC_OVERRIDES_FILE" <<'EOC'
# Auto-generated at container startup. Do not edit manually.
return 403;
EOC
fi

# wp-cron location block (server{} context, full location block).
if is_true "$disable_public_wp_cron_raw"; then
    cat > "$NGINX_WP_CRON_FILE" <<'EOC'
# Auto-generated at container startup. Do not edit manually.
# wp-cron restricted to localhost; the internal trigger loop in run.sh calls it.
location = /wp-cron.php {
    allow 127.0.0.1;
    deny all;
    include /etc/nginx/snippets/wp-fastcgi.conf;
    fastcgi_no_cache 1;
    fastcgi_cache_bypass 1;
}
EOC
else
    cat > "$NGINX_WP_CRON_FILE" <<'EOC'
# Auto-generated at container startup. Do not edit manually.
# wp-cron public access enabled (DISABLE_PUBLIC_WP_CRON=false).
location = /wp-cron.php {
    limit_req zone=login_routes burst=3 nodelay;
    include /etc/nginx/snippets/wp-fastcgi.conf;
    fastcgi_no_cache 1;
    fastcgi_cache_bypass 1;
}
EOC
fi

# Security headers (server{} context). more_set_headers (headers-more module) is additive, so these
# survive in locations that set their own headers (static assets, X-Cache, NGINX_EXTRA_CONF).
{
    echo "# Auto-generated at container startup. Do not edit manually."
    if [ -n "$csp_header" ]; then
        echo "more_set_headers \"Content-Security-Policy: ${csp_header}\";"
    else
        echo "# CSP disabled (CSP_HEADER is empty)."
    fi
    # An empty value removes the header, so this is a no-op over plain HTTP.
    echo "more_set_headers \"Strict-Transport-Security: \$hsts_header\";"
} > "$NGINX_SECURITY_HEADERS_FILE"

# Debug headers (location{} context inside PHP handler): X-Cache when DEBUG_HEADERS=true.
if is_true "$debug_headers_raw"; then
    cat > "$NGINX_DEBUG_HEADERS_FILE" <<'EOC'
# Auto-generated at container startup. Do not edit manually.
more_set_headers "X-Cache: $upstream_cache_status";
EOC
else
    cat > "$NGINX_DEBUG_HEADERS_FILE" <<'EOC'
# Auto-generated at container startup. Do not edit manually.
# X-Cache header disabled (set DEBUG_HEADERS=true to enable).
EOC
fi

# Customer-injected nginx config (server{} context). run.sh validates it with nginx -t and
# disables it (keeping the site up) if it does not parse.
if [ -n "$nginx_extra_conf" ]; then
    printf '%s\n' "# Auto-generated at container startup. Do not edit manually." > "$NGINX_EXTRA_FILE"
    printf '%s\n' "$nginx_extra_conf" >> "$NGINX_EXTRA_FILE"
else
    cat > "$NGINX_EXTRA_FILE" <<'EOC'
# Auto-generated at container startup. Do not edit manually.
# No NGINX_EXTRA_CONF set.
EOC
fi

log "Generated overrides:"
log "  worker_processes=${worker_processes}, trusted_proxy_cidrs=${trusted_proxy_cidrs}"
log "  cache_enabled=${cache_enabled}, cache_ttl_seconds=${cache_ttl_seconds:-unset}, cache_max_size=${cache_max_size}, cache_skip_empty=${cache_skip_empty_enabled}"
log "  cache_ignore_query_params=$([ "$cache_ignore_query_params_enabled" = "true" ] && echo "$cache_ignore_patterns_log" || echo "disabled")"
log "  xmlrpc_enabled=${xmlrpc_enabled_raw}, disable_public_wp_cron=${disable_public_wp_cron_raw}"
log "  max_upload_size=${max_upload_size}, max_conn_per_ip=${max_conn_per_ip}"
log "  normal_routes_rpm=${normal_routes_rpm}, protected_routes_rpm=${protected_routes_rpm}, login_routes_rpm=${login_routes_rpm}, api_routes_rpm=${api_routes_rpm}"
log "  debug_headers=${debug_headers_raw}, csp_header=$([ -n "$csp_header" ] && echo "set" || echo "empty"), hsts_header=$([ -n "$hsts_header" ] && echo "set" || echo "empty")"
log "  nginx_extra_conf=$([ -n "$nginx_extra_conf" ] && echo "set" || echo "empty")"
