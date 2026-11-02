#!/bin/bash
# Shared validators for the startup scripts. Sourced by configure_*.sh; every function logs
# through the caller's log(). The cgroup-aware sizing lives in resource_sizing.sh.

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

# Positive integer or the fallback (logged).
validated_positive_int() {
    local value="$1" fallback="$2" var_name="$3"
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ]; then
        echo "$value"
        return
    fi
    log "Invalid ${var_name} value '${value}'. Falling back to ${fallback}."
    echo "$fallback"
}

# An upload size nginx and PHP agree on: <n>M or <n>G (or <n>K, at least 1024K), uppercase.
# Rejects 0/unlimited, bare bytes, 'MB' spellings and anything PHP would misparse.
validated_upload_size() {
    local value="$1" fallback="$2" var_name="$3"
    local upper="${value^^}"
    if [[ "$upper" =~ ^[1-9][0-9]*[MG]$ ]] || { [[ "$upper" =~ ^[1-9][0-9]*K$ ]] && [ "${upper%K}" -ge 1024 ]; }; then
        echo "$upper"
        return
    fi
    log "Invalid ${var_name} value '${value}' (use e.g. 64M or 1G). Falling back to ${fallback}."
    echo "$fallback"
}
