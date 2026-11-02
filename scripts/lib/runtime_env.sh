#!/bin/bash
# Shared validators for the startup scripts. Sourced by configure_*.sh. Every validator prints its
# result on stdout and logs through the caller's log() on stderr: callers capture the result with
# $(...), and a log line on stdout would end up inside the value (a rejected setting then wrote
# "[nginx-overrides] Invalid ..." into the generated config, which nginx refused, so no fallback ever
# worked). The cgroup-aware sizing lives in resource_sizing.sh.

is_true() {
    case "${1,,}" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

is_false() {
    case "${1,,}" in
        false|0|no|off) return 0 ;;
        *) return 1 ;;
    esac
}

# Positive integer (at most MAX, default 999999999) or the fallback (logged). The bound keeps the
# value inside what bash and nginx can represent: a value nginx rejects would fail `nginx -t`, and
# run.sh can only recover from a broken NGINX_EXTRA_CONF, so the pod would crash-loop instead.
validated_positive_int() {
    local value="$1" fallback="$2" var_name="$3" max="${4:-999999999}"
    if [[ "$value" =~ ^[0-9]{1,9}$ ]] && [ "$value" -ge 1 ] && [ "$value" -le "$max" ]; then
        echo "$value"
        return
    fi
    log "Invalid ${var_name} value '${value}' (a whole number from 1 to ${max}). Falling back to ${fallback}." >&2
    echo "$fallback"
}

# An upload size nginx and PHP agree on: <n>M or <n>G (or <n>K, at least 1024K), uppercase, at most
# 100G. Rejects 0/unlimited, bare bytes, 'MB' spellings, anything PHP would misparse, and sizes
# nginx rejects (which would fail `nginx -t` and crash-loop the pod).
validated_upload_size() {
    local value="$1" fallback="$2" var_name="$3"
    local upper="${value^^}" number mib
    if [[ "$upper" =~ ^([1-9][0-9]{0,8})([KMG])$ ]]; then
        number="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2]}" in
            K) mib=$(( number / 1024 )) ;;
            M) mib="$number" ;;
            G) mib=$(( number * 1024 )) ;;
        esac
        if [ "$mib" -ge 1 ] && [ "$mib" -le 102400 ]; then
            echo "$upper"
            return
        fi
    fi
    log "Invalid ${var_name} value '${value}' (use e.g. 64M or 1G, from 1024K to 100G). Falling back to ${fallback}." >&2
    echo "$fallback"
}

# An address or CIDR nginx's set_real_ip_from accepts: IPv4 with octets 0-255 and a /0-32 prefix,
# or IPv6 (at most eight groups of 1-4 hex digits, at most one "::") with a /0-128 prefix. Anything
# else would fail `nginx -t`, which run.sh cannot recover from, and crash-loop the pod.
valid_cidr() {
    local cidr="$1" addr prefix="" octet group
    local -a parts
    addr="${cidr%%/*}"
    if [[ "$cidr" == */* ]]; then
        prefix="${cidr#*/}"
        [[ "$prefix" =~ ^[0-9]{1,3}$ ]] || return 1
    fi
    if [[ "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        IFS=. read -r -a parts <<<"$addr"
        for octet in "${parts[@]}"; do
            [ "$((10#$octet))" -le 255 ] || return 1
        done
        # nginx parses 255.255.255.255 as its own error value (INADDR_NONE) and rejects it.
        [ "$addr" != 255.255.255.255 ] || return 1
        [ -z "$prefix" ] || [ "$((10#$prefix))" -le 32 ]
        return
    fi
    [[ "$addr" =~ ^[0-9A-Fa-f:]+$ && "$addr" == *:* && "$addr" != *:::* ]] || return 1
    # At most one "::" (a double colon spans the missing groups).
    [[ "${addr#*::}" != *::* ]] || return 1
    [[ "$addr" == *::* || "$addr" =~ ^([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}$ ]] || return 1
    IFS=: read -r -a parts <<<"$addr"
    [ "${#parts[@]}" -le 8 ] || return 1
    for group in "${parts[@]}"; do
        [[ -z "$group" || "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
    # A single leading or trailing colon is only valid as part of "::".
    [[ "$addr" != :* || "$addr" == ::* ]] && [[ "$addr" != *: || "$addr" == *:: ]] || return 1
    [ -z "$prefix" ] || [ "$((10#$prefix))" -le 128 ]
}

validated_cidrs() {
    local raw="$1" fallback="$2" var_name="$3" out="" cidr
    for cidr in ${raw//,/ }; do
        if valid_cidr "$cidr"; then
            out="${out}${cidr} "
        else
            log "Invalid ${var_name} entry '${cidr}'. Falling back to the default list." >&2
            echo "$fallback"
            return
        fi
    done
    echo "${out% }"
}
