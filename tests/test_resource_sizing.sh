#!/bin/bash
# Unit tests for scripts/lib/resource_sizing.sh (the pure sizing model and load()).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/../scripts/lib/resource_sizing.sh"

# Loads a sizing into an associative array `S`.
size() {
    declare -gA S=()
    while IFS='=' read -r k v; do S["$k"]="$v"; done < <(resource_sizing_compute "$@")
}

echo "Basic plan (0.28G / 7% CPU): the floor of 3 workers is forced, opcache at its floor"
size 280 70
assert_eq 128 "${S[CC_SIZING_PHP_MEMORY_LIMIT_MB]}" "memory_limit"
assert_eq 96  "${S[CC_SIZING_OPCACHE_MB]}" "opcache floor"
assert_eq 8   "${S[CC_SIZING_OPCACHE_INTERNED_MB]}" "interned strings"
assert_eq 1   "${S[CC_SIZING_FPM_MEM_BASED]}" "memory-bound children"
assert_eq 1   "${S[CC_SIZING_FPM_CPU_BASED]}" "cpu-bound children"
assert_eq 3   "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "max_children floor"
assert_eq 1   "${S[CC_SIZING_FPM_FLOOR_FORCED]}" "floor reported as forced"
assert_eq 1   "${S[CC_SIZING_NGINX_WORKERS]}" "nginx workers"
assert_eq 12  "${S[CC_SIZING_PHP_MAX_INFLIGHT]}" "in-flight: 3 x 4 = 12"
assert_eq 128 "${S[CC_SIZING_WP_MAX_MEMORY_LIMIT_MB]}" "admin limit cannot exceed what is left: stays at the request limit"
assert_eq 128 "${S[CC_SIZING_MAGICK_MEMORY_MB]}" "imagick memory = 2 x worker budget"
assert_eq 256 "${S[CC_SIZING_MAGICK_MAP_MB]}" "imagick map = 2 x memory"
assert_eq 1   "${S[CC_SIZING_FPM_START_SERVERS]}" "start_servers"
assert_eq 1   "${S[CC_SIZING_FPM_MIN_SPARE]}" "min_spare"
assert_eq 2   "${S[CC_SIZING_FPM_MAX_SPARE]}" "max_spare"

echo "Standard plan (0.6G / 15% CPU) is CPU-bound below the floor"
size 600 150
assert_eq 96 "${S[CC_SIZING_OPCACHE_MB]}" "opcache (100 rounds down to 96)"
assert_eq 6  "${S[CC_SIZING_FPM_MEM_BASED]}" "memory-bound children"
assert_eq 2  "${S[CC_SIZING_FPM_CPU_BASED]}" "cpu-bound children"
assert_eq 3  "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "floor"
assert_eq 1  "${S[CC_SIZING_FPM_FLOOR_FORCED]}" "floor forced"

echo "Premium plan (1G / 25% CPU) is CPU-bound to 3 workers"
size 953 250
assert_eq 128 "${S[CC_SIZING_PHP_MEMORY_LIMIT_MB]}" "memory_limit"
assert_eq 160 "${S[CC_SIZING_OPCACHE_MB]}" "opcache = 953/6 rounded to 16"
assert_eq 16  "${S[CC_SIZING_OPCACHE_INTERNED_MB]}" "interned strings"
assert_eq 139 "${S[CC_SIZING_RESERVED_MB]}" "reserved"
assert_eq 64  "${S[CC_SIZING_WORKER_MB]}" "worker budget = memory_limit / 2"
assert_eq 10  "${S[CC_SIZING_FPM_MEM_BASED]}" "memory-bound children"
assert_eq 3   "${S[CC_SIZING_FPM_CPU_BASED]}" "cpu-bound children"
assert_eq 3   "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "max_children = min(mem, cpu)"
assert_eq 0   "${S[CC_SIZING_FPM_FLOOR_FORCED]}" "floor not forced"
assert_eq 1   "${S[CC_SIZING_FPM_MIN_SPARE]}" "min_spare"
assert_eq 2   "${S[CC_SIZING_FPM_MAX_SPARE]}" "max_spare"
assert_eq 1   "${S[CC_SIZING_FPM_START_SERVERS]}" "start_servers"
assert_eq 12  "${S[CC_SIZING_PHP_MAX_INFLIGHT]}" "in-flight: 3 x 4"
assert_eq 1   "${S[CC_SIZING_NGINX_WORKERS]}" "nginx workers"
assert_eq 256 "${S[CC_SIZING_WP_MAX_MEMORY_LIMIT_MB]}" "admin limit: twice the request limit"

echo "docker --memory 1g --cpus 0.25 (the smoke test's sized container)"
size 1024 250
assert_eq 128 "${S[CC_SIZING_PHP_MEMORY_LIMIT_MB]}" "memory_limit"
assert_eq 176 "${S[CC_SIZING_OPCACHE_MB]}" "opcache"
assert_eq 3   "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "max_children"
assert_eq 12  "${S[CC_SIZING_PHP_MAX_INFLIGHT]}" "in-flight"
assert_eq 256 "${S[CC_SIZING_WP_MAX_MEMORY_LIMIT_MB]}" "admin limit"

echo "the memory_limit tier flips at 1.5G"
size 1535 500
assert_eq 128 "${S[CC_SIZING_PHP_MEMORY_LIMIT_MB]}" "just below: 128M"
assert_eq 256 "${S[CC_SIZING_OPCACHE_MB]}" "opcache ceiling"
assert_eq 32  "${S[CC_SIZING_OPCACHE_INTERNED_MB]}" "interned strings"
assert_eq 6   "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "cpu-bound at 0.5 CPU"
size 1536 500
assert_eq 256 "${S[CC_SIZING_PHP_MEMORY_LIMIT_MB]}" "at 1.5G: 256M"
assert_eq 128 "${S[CC_SIZING_WORKER_MB]}" "worker budget follows"
assert_eq 6   "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "still cpu-bound"

echo "2G / 1 CPU gets 256M requests and 12 workers"
size 2000 1000
assert_eq 256 "${S[CC_SIZING_PHP_MEMORY_LIMIT_MB]}" "memory_limit"
assert_eq 256 "${S[CC_SIZING_OPCACHE_MB]}" "opcache cap"
assert_eq 12  "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "max_children"
assert_eq 4   "${S[CC_SIZING_FPM_START_SERVERS]}" "start_servers"
assert_eq 3   "${S[CC_SIZING_FPM_MIN_SPARE]}" "min_spare"
assert_eq 6   "${S[CC_SIZING_FPM_MAX_SPARE]}" "max_spare"
assert_eq 1   "${S[CC_SIZING_NGINX_WORKERS]}" "nginx workers"
assert_eq 48  "${S[CC_SIZING_PHP_MAX_INFLIGHT]}" "in-flight"
assert_eq 512 "${S[CC_SIZING_WP_MAX_MEMORY_LIMIT_MB]}" "admin limit 512M on 2G"
assert_eq 256 "${S[CC_SIZING_MAGICK_MEMORY_MB]}" "imagick memory capped at 256"
assert_eq 512 "${S[CC_SIZING_MAGICK_MAP_MB]}" "imagick map"

echo "4G / 2 CPU"
size 4000 2000
assert_eq 24 "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "max_children"
assert_eq 2  "${S[CC_SIZING_NGINX_WORKERS]}" "nginx workers"
assert_eq 96 "${S[CC_SIZING_PHP_MAX_INFLIGHT]}" "in-flight"

echo "very large containers hit the ceilings"
size 16000 8000
assert_eq 64  "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "max_children ceiling"
assert_eq 4   "${S[CC_SIZING_NGINX_WORKERS]}" "nginx workers ceiling"
assert_eq 256 "${S[CC_SIZING_PHP_MAX_INFLIGHT]}" "64 workers x 4"
PHP_INFLIGHT_PER_WORKER=40 size 16000 8000
assert_eq 1024 "${S[CC_SIZING_PHP_MAX_INFLIGHT]}" "in-flight ceiling of 1024"
PHP_INFLIGHT_PER_WORKER=8 size 2000 1000
assert_eq 96 "${S[CC_SIZING_PHP_MAX_INFLIGHT]}" "per-worker knob"

echo "invariants hold across a sweep of sizes"
for mem in 256 280 512 600 953 1000 1024 1500 1536 2000 3000 4000 6000 8000 12000 16000 32000; do
    for cpu in 50 70 100 150 250 500 1000 2000 4000 8000; do
        size "$mem" "$cpu"
        mc="${S[CC_SIZING_FPM_MAX_CHILDREN]}"
        assert_le "${S[CC_SIZING_FPM_MIN_SPARE]}" "${S[CC_SIZING_FPM_START_SERVERS]}" "min_spare <= start ($mem/$cpu)"
        assert_le "${S[CC_SIZING_FPM_START_SERVERS]}" "${S[CC_SIZING_FPM_MAX_SPARE]}" "start <= max_spare ($mem/$cpu)"
        assert_le "${S[CC_SIZING_FPM_MAX_SPARE]}" "$mc" "max_spare <= max_children ($mem/$cpu)"
        assert_le 3 "$mc" "max_children >= 3 ($mem/$cpu)"
        assert_le "$mc" 64 "max_children <= 64 ($mem/$cpu)"
        assert_le 96 "${S[CC_SIZING_OPCACHE_MB]}" "opcache >= 96 ($mem/$cpu)"
        assert_le "${S[CC_SIZING_OPCACHE_MB]}" 256 "opcache <= 256 ($mem/$cpu)"
        assert_eq 0 $(( S[CC_SIZING_OPCACHE_MB] % 16 )) "opcache multiple of 16 ($mem/$cpu)"
        assert_le 8 "${S[CC_SIZING_PHP_MAX_INFLIGHT]}" "in-flight >= 8 ($mem/$cpu)"
        assert_le "${S[CC_SIZING_PHP_MAX_INFLIGHT]}" 1024 "in-flight <= 1024 ($mem/$cpu)"
        assert_le 1 "${S[CC_SIZING_NGINX_WORKERS]}" "nginx >= 1 ($mem/$cpu)"
        assert_le "${S[CC_SIZING_NGINX_WORKERS]}" 4 "nginx <= 4 ($mem/$cpu)"
        assert_le "${S[CC_SIZING_PHP_MEMORY_LIMIT_MB]}" "${S[CC_SIZING_WP_MAX_MEMORY_LIMIT_MB]}" "wp_max >= memory_limit ($mem/$cpu)"
        assert_le "${S[CC_SIZING_WP_MAX_MEMORY_LIMIT_MB]}" $(( 2 * S[CC_SIZING_PHP_MEMORY_LIMIT_MB] )) "wp_max <= 2 x memory_limit ($mem/$cpu)"
        assert_le 64 "${S[CC_SIZING_MAGICK_MEMORY_MB]}" "imagick >= 64 ($mem/$cpu)"
        assert_le "${S[CC_SIZING_MAGICK_MEMORY_MB]}" 256 "imagick <= 256 ($mem/$cpu)"
        budget=$(( S[CC_SIZING_RESERVED_MB] + S[CC_SIZING_OPCACHE_MB] + mc * S[CC_SIZING_WORKER_MB] ))
        assert_eq "$budget" "${S[CC_SIZING_BUDGET_MB]}" "budget reported ($mem/$cpu)"
        # The budget fits the container whenever the floor was not forced; the floor is forced
        # only when the binding bound (memory or CPU) came out below it.
        lo="${S[CC_SIZING_FPM_MEM_BASED]}"
        [ "${S[CC_SIZING_FPM_CPU_BASED]}" -lt "$lo" ] && lo="${S[CC_SIZING_FPM_CPU_BASED]}"
        if [ "${S[CC_SIZING_FPM_FLOOR_FORCED]}" = 0 ]; then
            assert_le "$budget" "$mem" "memory budget fits ($mem/$cpu)"
            assert_le 3 "$lo" "floor not forced means the bound was at least 3 ($mem/$cpu)"
        else
            assert_le "$lo" 2 "floor only forced when the bound was below it ($mem/$cpu)"
        fi
    done
done

echo "tuning knobs"
PHP_WORKER_MEMORY_MB=200 size 2000 4000
assert_eq 200 "${S[CC_SIZING_WORKER_MB]}" "worker budget knob"
assert_eq 7   "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "fewer children with a bigger worker budget"
PHP_FPM_WORKERS_PER_CPU=4 size 4000 1000
assert_eq 4 "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "workers-per-cpu knob"
out="$(PHP_FPM_WORKERS_PER_CPU=lots resource_sizing_compute 2000 1000 2>&1)"
assert_contains "$out" "Invalid PHP_FPM_WORKERS_PER_CPU" "invalid knob is reported"
assert_contains "$out" "CC_SIZING_FPM_MAX_CHILDREN=12" "invalid knob falls back to the default"
# A leading zero is decimal: bash arithmetic reads 08 and 09 as bad octal, which aborted the sizing
# (and, under set -e, the container start).
PHP_FPM_WORKERS_PER_CPU=08 PHP_INFLIGHT_PER_WORKER=09 size 4000 1000
assert_eq 8  "${S[CC_SIZING_FPM_MAX_CHILDREN]:-}" "workers-per-cpu 08 is 8"
assert_eq 72 "${S[CC_SIZING_PHP_MAX_INFLIGHT]:-}" "inflight-per-worker 09 is 9 (8 workers x 9)"
PHP_WORKER_MEMORY_MB=0200 size 2000 4000
assert_eq 200 "${S[CC_SIZING_WORKER_MB]:-}" "worker budget 0200 is 200"

echo "ini size parsing"
assert_eq 256  "$(resource_sizing_ini_size_to_mb 256M)" "256M"
assert_eq 1024 "$(resource_sizing_ini_size_to_mb 1G)" "1G"
assert_eq 128  "$(resource_sizing_ini_size_to_mb 134217728)" "bytes"
assert_eq 0    "$(resource_sizing_ini_size_to_mb 512K)" "sub-MiB rounds to 0"
assert_eq ""   "$(resource_sizing_ini_size_to_mb -1)" "-1 is unparseable"
assert_eq ""   "$(resource_sizing_ini_size_to_mb 'lots')" "garbage is unparseable"

echo "override lookup follows the merge rules (last wins, comments ignored, whitespace tolerated)"
blob=$'; memory_limit = 1G\nmemory_limit = 128M\nfoo=1\n  memory_limit=512M  '
assert_eq 512M "$(resource_sizing_override_value memory_limit "$blob")" "last occurrence"
assert_eq ""   "$(resource_sizing_override_value max_input_vars "$blob")" "absent key"
assert_eq 9    "$(resource_sizing_override_value pm.max_children $'[www]\npm.max_children = 9')" "fpm key"
assert_eq 4    "$(resource_sizing_override_value pm.max_children $'[www]\npm.max_children = 4 ; keep it small')" "trailing comment dropped (PHP's scanner does the same)"
assert_eq 4    "$(resource_sizing_override_value pm.max_children $'[www]\npm.max_children = \"4\"')" "double quotes stripped"
assert_eq 512M "$(resource_sizing_override_value memory_limit $'memory_limit = \"512M\" ; big\r')" "quotes, comment and CR together"

echo "a pinned memory_limit shrinks the pool (down to the floor)"
size 953 250 512
assert_eq 512 "${S[CC_SIZING_PHP_MEMORY_LIMIT_MB]}" "pinned limit"
assert_eq 256 "${S[CC_SIZING_WORKER_MB]}" "budget follows it"
assert_eq 2   "${S[CC_SIZING_FPM_MEM_BASED]}" "memory allows 2"
assert_eq 3   "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "floor holds"
assert_eq 1   "${S[CC_SIZING_FPM_FLOOR_FORCED]}" "and is reported"
size 4000 4000 512
assert_eq 13  "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "4G at 512M: 13 workers instead of 24"
size 953 250 1
assert_eq 1   "${S[CC_SIZING_WORKER_MB]}" "a 1M limit still yields a sizing (no division by zero)"

echo "spare pool invariants for pinned child counts"
for n in 1 2 3 5 9 17 64; do
    read -r start min max < <(resource_sizing_spares "$n")
    assert_le "$min" "$start" "min <= start ($n)"
    assert_le "$start" "$max" "start <= max ($n)"
    assert_le "$max" "$n" "max <= children ($n)"
    assert_le 1 "$min" "min >= 1 ($n)"
done

echo "resource_sizing_load reads the cgroup once and exports"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CONTAINER_RESOURCES_CGROUP_ROOT="$tmp/cg" CONTAINER_RESOURCES_PROC_ROOT="$tmp/proc"
make_cgroup_fixture "$tmp/cg" v2 999997440 25000
unset CC_SIZING_LOADED
resource_sizing_load
assert_eq cgroup "$CC_SIZING_SOURCE" "source"
assert_eq 3 "$CC_SIZING_FPM_MAX_CHILDREN" "exported max_children"
assert_eq 3 "$(bash -c 'echo "$CC_SIZING_FPM_MAX_CHILDREN"')" "visible to child processes"
make_cgroup_fixture "$tmp/cg" v2 max max
resource_sizing_load
assert_eq 3 "$CC_SIZING_FPM_MAX_CHILDREN" "second load is a no-op"

echo "the boot log explains a forced floor"
make_cgroup_fixture "$tmp/cg" v2 293601280 7000   # 280M / 7%
unset CC_SIZING_LOADED
out="$(resource_sizing_load; resource_sizing_log)"
assert_contains "$out" "max_children=3 (memory-bound=1, cpu-bound=1" "sizing line"
assert_contains "$out" "WARNING: the pool floor of 3 workers exceeds" "floor warning"
make_cgroup_fixture "$tmp/cg" v2 999997440 25000
unset CC_SIZING_LOADED
out="$(resource_sizing_load; resource_sizing_log)"
assert_not_contains "$out" "WARNING" "no warning when the budget fits"
assert_not_contains "$out" "note:" "no floor note when the floor was not forced"
assert_contains "$out" "wp_max_memory_limit=256M" "admin limit logged"
assert_contains "$out" "imagick: memory=128MiB map=256MiB" "imagick limits logged"
assert_eq "128MiB 256MiB" "$MAGICK_MEMORY_LIMIT $MAGICK_MAP_LIMIT" "imagick limits exported for php-fpm"
make_cgroup_fixture "$tmp/cg" v2 629145600 15000   # 600M / 15%: the CPU bound forces the floor, the budget fits
unset CC_SIZING_LOADED
out="$(resource_sizing_load; resource_sizing_log)"
assert_contains "$out" "max_children=3 (memory-bound=6, cpu-bound=2" "standard plan sizing"
assert_not_contains "$out" "exceeds this container's memory budget" "no memory warning when only the CPU bound forced the floor"
assert_contains "$out" "note: the CPU quota bounds the pool at 2 worker(s)" "the floor is explained instead"
make_cgroup_fixture "$tmp/cg" v2 999997440 25000
unset CC_SIZING_LOADED
out="$(WORDPRESS_CUSTOM_INI='memory_limit = 1G' resource_sizing_load; resource_sizing_log)"
assert_contains "$out" "a single request can exceed the container" "a limit at or above the container is called out"
unset CC_SIZING_LOADED
out="$(export MAGICK_MEMORY_LIMIT=32MiB; unset MAGICK_MAP_LIMIT; resource_sizing_load; echo "$MAGICK_MEMORY_LIMIT $MAGICK_MAP_LIMIT")"
assert_contains "$out" "32MiB 256MiB" "an explicit MAGICK_MEMORY_LIMIT wins, the map limit is still derived"

echo "resource_sizing_load feeds customer overrides back into the sizing"
make_cgroup_fixture "$tmp/cg" v2 4294967296 400000   # 4G / 4 CPU
unset CC_SIZING_LOADED
out="$(WORDPRESS_CUSTOM_INI=$'max_input_vars = 5000\nmemory_limit = 512M' resource_sizing_load; echo "children=$CC_SIZING_FPM_MAX_CHILDREN limit=$CC_SIZING_PHP_MEMORY_LIMIT_MB")"
assert_contains "$out" "memory_limit pinned to 512M" "pinned limit is logged"
assert_contains "$out" "children=13 limit=512" "pool shrinks with the pinned limit"
unset CC_SIZING_LOADED
out="$(WORDPRESS_CUSTOM_INI='memory_limit = -1' resource_sizing_load; echo "children=$CC_SIZING_FPM_MAX_CHILDREN limit=$CC_SIZING_PHP_MEMORY_LIMIT_MB")"
assert_contains "$out" "unlimited, below 2M or unparseable" "unlimited limit is reported"
assert_contains "$out" "children=27 limit=256" "and ignored for sizing (4096M: (4096-336-256)/128 = 27)"
unset CC_SIZING_LOADED
out="$(WORDPRESS_CUSTOM_INI='memory_limit = 1M' resource_sizing_load; echo "children=$CC_SIZING_FPM_MAX_CHILDREN limit=$CC_SIZING_PHP_MEMORY_LIMIT_MB")"
assert_contains "$out" "below 2M" "a 1M limit is reported"
assert_contains "$out" "children=27 limit=256" "and ignored instead of dividing by zero"
unset CC_SIZING_LOADED
out="$(WORDPRESS_CUSTOM_INI='memory_limit = "512M"' resource_sizing_load; echo "children=$CC_SIZING_FPM_MAX_CHILDREN limit=$CC_SIZING_PHP_MEMORY_LIMIT_MB")"
assert_contains "$out" "children=13 limit=512" "a quoted limit (which PHP applies) is fed back"
unset CC_SIZING_LOADED
out="$(WORDPRESS_FPM_CONF=$'[www]\npm.max_children = 9' resource_sizing_load; echo "pool=$CC_SIZING_FPM_MAX_CHILDREN/$CC_SIZING_FPM_START_SERVERS/$CC_SIZING_FPM_MIN_SPARE/$CC_SIZING_FPM_MAX_SPARE")"
assert_contains "$out" "pm.max_children pinned to 9" "pinned children is logged"
assert_contains "$out" "pool=9/3/2/5" "spares re-derived from the pinned count"
unset CC_SIZING_LOADED
out="$(WORDPRESS_FPM_CONF=$'[www]\npm.max_children = 4 ; keep it small' resource_sizing_load; echo "pool=$CC_SIZING_FPM_MAX_CHILDREN/$CC_SIZING_FPM_START_SERVERS/$CC_SIZING_FPM_MIN_SPARE/$CC_SIZING_FPM_MAX_SPARE inflight=$CC_SIZING_PHP_MAX_INFLIGHT")"
assert_contains "$out" "pool=4/2/1/2 inflight=16" "a pin with a trailing comment (which PHP-FPM accepts) is honoured"
unset CC_SIZING_LOADED
out="$(WORDPRESS_FPM_CONF=$'[www]\npm.max_children = "4"' resource_sizing_load; echo "pool=$CC_SIZING_FPM_MAX_CHILDREN/$CC_SIZING_FPM_START_SERVERS/$CC_SIZING_FPM_MIN_SPARE/$CC_SIZING_FPM_MAX_SPARE")"
assert_contains "$out" "pool=4/2/1/2" "a quoted pin is honoured"
unset CC_SIZING_LOADED
out="$(WORDPRESS_FPM_CONF=$'[www]\npm.max_children = 08' resource_sizing_load; echo "pool=$CC_SIZING_FPM_MAX_CHILDREN/$CC_SIZING_FPM_START_SERVERS/$CC_SIZING_FPM_MIN_SPARE/$CC_SIZING_FPM_MAX_SPARE")"
assert_contains "$out" "pool=8/$(resource_sizing_spares 8 | tr ' ' '/')" "a pin with a leading zero is decimal (PHP-FPM reads 08 as 8)"
assert_eq 36 "$(WORDPRESS_FPM_CONF=$'[www]\npm.max_children = 9' bash -c 'unset CC_SIZING_LOADED; source "'"$HERE"'/../scripts/lib/resource_sizing.sh"; resource_sizing_load >/dev/null; echo "$CC_SIZING_PHP_MAX_INFLIGHT"')" "in-flight cap follows the pinned count"
unset CC_SIZING_LOADED
out="$(WORDPRESS_FPM_CONF=$'[www]\npm.max_children = many' resource_sizing_load; echo "pool=$CC_SIZING_FPM_MAX_CHILDREN")"
assert_contains "$out" "not a positive integer" "bad pinned count is reported"
assert_contains "$out" "pool=27" "and ignored"
unset CC_SIZING_LOADED
make_cgroup_fixture "$tmp/cg" v2 999997440 25000
out="$(WORDPRESS_FPM_CONF=$'[www]\npm.max_children = 40' resource_sizing_load; resource_sizing_log)"
assert_contains "$out" "WARNING: the pinned pool plans" "an over-pinned pool is warned about"

echo "resource_sizing_load falls back to the host when there are no limits"
make_cgroup_fixture "$tmp/cg" v2 max max
unset CC_SIZING_LOADED
mkdir -p "$tmp/proc"; printf 'MemTotal:       2097152 kB\n' > "$tmp/proc/meminfo"
out="$(CONTAINER_RESOURCES_NPROC=2 resource_sizing_load; echo "$CC_SIZING_SOURCE $CC_SIZING_MEM_MB $CC_SIZING_CPU_MC")"
assert_contains "$out" "No cgroup memory limit found" "memory fallback is logged"
assert_contains "$out" "No cgroup CPU quota found" "cpu fallback is logged"
assert_contains "$out" "host 2048 2000" "host figures used"

echo "WP_MEMORY_LIMIT in the environment feeds the sizing when it raises the cap"
make_cgroup_fixture "$tmp/cg" v2 999997440 25000
unset CC_SIZING_LOADED
out="$(WP_MEMORY_LIMIT=512M resource_sizing_load; echo "limit=$CC_SIZING_PHP_MEMORY_LIMIT_MB worker=$CC_SIZING_WORKER_MB children=$CC_SIZING_FPM_MAX_CHILDREN")"
assert_contains "$out" "WP_MEMORY_LIMIT=512M raises the per-request cap above 128M" "the raise is logged"
assert_contains "$out" "limit=512 worker=256 children=3" "pool sized from the raised cap"
unset CC_SIZING_LOADED
out="$(WP_MEMORY_LIMIT=64M resource_sizing_load; echo "limit=$CC_SIZING_PHP_MEMORY_LIMIT_MB")"
assert_not_contains "$out" "WP_MEMORY_LIMIT" "a lower value is not a raise (WordPress never lowers memory_limit)"
assert_contains "$out" "limit=128" "tiered limit kept"
unset CC_SIZING_LOADED
out="$(WORDPRESS_CUSTOM_INI='memory_limit = 768M' WP_MEMORY_LIMIT=512M resource_sizing_load; echo "limit=$CC_SIZING_PHP_MEMORY_LIMIT_MB")"
assert_contains "$out" "limit=768" "the higher of the ini pin and WP_MEMORY_LIMIT wins"
unset CC_SIZING_LOADED
out="$(WORDPRESS_CUSTOM_INI='memory_limit = 256M' WP_MEMORY_LIMIT=512M resource_sizing_load; echo "limit=$CC_SIZING_PHP_MEMORY_LIMIT_MB")"
assert_contains "$out" "raises the per-request cap above 256M" "compared against the ini pin, not the tier"
assert_contains "$out" "limit=512" "and wins over a lower pin"
unset CC_SIZING_LOADED
out="$(WP_MEMORY_LIMIT=-1 resource_sizing_load; echo "limit=$CC_SIZING_PHP_MEMORY_LIMIT_MB")"
assert_contains "$out" "WARNING: WP_MEMORY_LIMIT '-1' is unlimited" "unlimited is warned about"
assert_contains "$out" "limit=128" "and cannot be accounted for"
unset CC_SIZING_LOADED
out="$(WP_MEMORY_LIMIT=1G resource_sizing_load; resource_sizing_log)"
assert_contains "$out" "a single request can exceed the container" "a raise at or above the container is called out"

echo "the libraries can be sourced twice in one shell (include guards around the readonly constants)"
assert_eq ok "$(bash -c 'set -e; for i in 1 2; do source "'"$HERE"'/../scripts/lib/resource_sizing.sh"; source "'"$HERE"'/../scripts/lib/container_resources.sh"; done; echo ok' 2>&1)" "double source is a no-op"

finish
