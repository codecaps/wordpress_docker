#!/bin/bash
# Shared helpers for the startup scripts: env validation and cgroup-aware sizing.
# Sourced by configure_*.sh; every function logs through the caller's log().

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

# Memory available to this container in MiB: cgroup v2, then v1, else the host's MemTotal.
cgroup_memory_limit_mb() {
    local bytes="" raw
    if [ -r /sys/fs/cgroup/memory.max ]; then
        raw="$(cat /sys/fs/cgroup/memory.max)"
        [[ "$raw" =~ ^[0-9]+$ ]] && bytes="$raw"
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        raw="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
        # cgroup v1 reports a huge number when unlimited.
        [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -lt 1000000000000 ] && bytes="$raw"
    fi
    if [ -z "$bytes" ]; then
        local kb
        kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 2097152)"
        echo $(( kb / 1024 ))
        return
    fi
    echo $(( bytes / 1048576 ))
}

# CPUs available to this container, rounded up from the CFS quota; nproc when unlimited.
cgroup_cpu_limit() {
    local quota="" period="" raw
    if [ -r /sys/fs/cgroup/cpu.max ]; then
        read -r quota period < /sys/fs/cgroup/cpu.max
    elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)"
        period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"
    fi
    if [[ "$quota" =~ ^[0-9]+$ ]] && [[ "$period" =~ ^[0-9]+$ ]] && [ "$period" -gt 0 ]; then
        echo $(( (quota + period - 1) / period ))
        return
    fi
    nproc 2>/dev/null || echo 1
}

clamp() {
    local value="$1" min="$2" max="$3"
    if [ "$value" -lt "$min" ]; then echo "$min"; elif [ "$value" -gt "$max" ]; then echo "$max"; else echo "$value"; fi
}

# OPcache shared memory (MB) for a container of this size: WordPress + a few plugins need
# ~60-120MB of compiled code; small pods cannot afford the full 256.
opcache_memory_mb_for() {
    local mem_mb="$1"
    if [ "$mem_mb" -le 320 ]; then echo 96
    elif [ "$mem_mb" -le 640 ]; then echo 128
    else echo 256
    fi
}
