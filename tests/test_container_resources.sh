#!/bin/bash
# Unit tests for scripts/lib/container_resources.sh (cgroup v1/v2 detection).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/../scripts/lib/container_resources.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CONTAINER_RESOURCES_CGROUP_ROOT="$tmp/cg"
export CONTAINER_RESOURCES_PROC_ROOT="$tmp/proc"
mkdir -p "$tmp/proc"; printf 'MemTotal:       16384000 kB\nMemFree:        1000 kB\n' > "$tmp/proc/meminfo"

echo "cgroup v2 with limits (the 1G / 25% capsule)"
make_cgroup_fixture "$tmp/cg" v2 999997440 25000
assert_eq 953 "$(container_resources_memory_limit_mb)" "v2 memory MiB"
assert_eq 250 "$(container_resources_cpu_millicores)" "v2 cpu millicores"

echo "cgroup v2 without limits"
make_cgroup_fixture "$tmp/cg" v2 max max
assert_eq 0 "$(container_resources_memory_limit_mb)" "v2 memory unlimited -> 0"
assert_eq 0 "$(container_resources_cpu_millicores)" "v2 cpu unlimited -> 0"

echo "cgroup v1 with limits"
make_cgroup_fixture "$tmp/cg" v1 2147483648 150000
assert_eq 2048 "$(container_resources_memory_limit_mb)" "v1 memory MiB"
assert_eq 1500 "$(container_resources_cpu_millicores)" "v1 cpu millicores"

echo "cgroup v1 without limits (sentinel values)"
make_cgroup_fixture "$tmp/cg" v1 9223372036854771712 -1
assert_eq 0 "$(container_resources_memory_limit_mb)" "v1 memory sentinel -> 0"
assert_eq 0 "$(container_resources_cpu_millicores)" "v1 cpu -1 -> 0"

echo "no cgroup files at all"
make_cgroup_fixture "$tmp/cg" none
assert_eq 0 "$(container_resources_memory_limit_mb)" "missing memory -> 0"
assert_eq 0 "$(container_resources_cpu_millicores)" "missing cpu -> 0"

echo "garbage content is treated as unknown"
make_cgroup_fixture "$tmp/cg" v2 "oops" "abc"
assert_eq 0 "$(container_resources_memory_limit_mb)" "garbage memory -> 0"
assert_eq 0 "$(container_resources_cpu_millicores)" "garbage cpu -> 0"

echo "host fallbacks"
assert_eq 16000 "$(container_resources_host_memory_mb)" "MemTotal in MiB"
CONTAINER_RESOURCES_NPROC=6 assert_eq 6 "$(CONTAINER_RESOURCES_NPROC=6 container_resources_host_cpus)" "nproc override"
rm -f "$tmp/proc/meminfo"
assert_eq 0 "$(container_resources_host_memory_mb)" "missing meminfo -> 0"

finish
