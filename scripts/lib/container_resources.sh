#!/bin/bash
#
# Reads the container's own CPU and memory limits from the cgroup it runs in.
#
# Kubernetes enforces capsule scale with cgroup limits, but nothing inside the
# container reports them: `nproc` and /proc/meminfo describe the *node*, so a
# 0.25-CPU / 1G capsule sees 4+ cores and tens of GB of RAM. Anything sized
# from those host figures (nginx workers, PHP-FPM children) over-commits the
# capsule and the kernel OOM-kills the whole container under load.
#
# Both cgroup v2 (unified) and cgroup v1 layouts are supported. Every function
# prints a single integer and prints 0 when no limit is set or detectable, so
# callers can fall back to host figures explicitly.
#
# The roots are overridable so the detection can be unit-tested with fixture
# directories; production callers never set them.

: "${CONTAINER_RESOURCES_CGROUP_ROOT:=/sys/fs/cgroup}"
: "${CONTAINER_RESOURCES_PROC_ROOT:=/proc}"

# cgroup v1 reports "no memory limit" as a value near 2^63; treat anything
# above 1 TiB as unlimited.
readonly CONTAINER_RESOURCES_UNLIMITED_MEMORY_BYTES=$((1024 * 1024 * 1024 * 1024))

_container_resources_read() {
    local path="$1"
    [ -r "$path" ] || return 1
    tr -d '[:space:]' < "$path" 2>/dev/null
}

_container_resources_is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# Memory limit of this container in MiB (0 = none / unknown).
container_resources_memory_limit_mb() {
    local root="$CONTAINER_RESOURCES_CGROUP_ROOT" bytes=""

    bytes="$(_container_resources_read "$root/memory.max")" \
        || bytes="$(_container_resources_read "$root/memory/memory.limit_in_bytes")" \
        || bytes=""

    if ! _container_resources_is_uint "$bytes" \
        || [ "$bytes" -eq 0 ] \
        || [ "$bytes" -gt "$CONTAINER_RESOURCES_UNLIMITED_MEMORY_BYTES" ]; then
        echo 0
        return
    fi
    echo $(( bytes / 1024 / 1024 ))
}

# CPU quota of this container in millicores (0 = no quota / unknown).
container_resources_cpu_millicores() {
    local root="$CONTAINER_RESOURCES_CGROUP_ROOT" quota="" period="" line=""

    if [ -r "$root/cpu.max" ]; then
        # cgroup v2: "<quota|max> <period>"
        line="$(cat "$root/cpu.max" 2>/dev/null)"
        quota="${line%% *}"
        period="${line##* }"
    elif [ -r "$root/cpu/cpu.cfs_quota_us" ]; then
        # cgroup v1: -1 means no quota.
        quota="$(_container_resources_read "$root/cpu/cpu.cfs_quota_us")"
        period="$(_container_resources_read "$root/cpu/cpu.cfs_period_us")"
    fi

    if ! _container_resources_is_uint "$quota" || ! _container_resources_is_uint "$period" \
        || [ "$period" -eq 0 ] || [ "$quota" -eq 0 ]; then
        echo 0
        return
    fi
    echo $(( quota * 1000 / period ))
}

# Total memory of the host in MiB (0 = unknown). Used only as a fallback.
container_resources_host_memory_mb() {
    local kb
    kb="$(awk '/^MemTotal:/ {print $2; exit}' "$CONTAINER_RESOURCES_PROC_ROOT/meminfo" 2>/dev/null)"
    if ! _container_resources_is_uint "$kb"; then
        echo 0
        return
    fi
    echo $(( kb / 1024 ))
}

# Online CPUs of the host (0 = unknown). Used only as a fallback.
container_resources_host_cpus() {
    local n="${CONTAINER_RESOURCES_NPROC:-}"
    [ -n "$n" ] || n="$(nproc 2>/dev/null)"
    if ! _container_resources_is_uint "$n"; then
        echo 0
        return
    fi
    echo "$n"
}
