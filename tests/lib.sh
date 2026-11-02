#!/bin/bash
# Minimal assertion helpers for the shell test suite (no external deps).

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" what="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" != "$actual" ]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $what: expected '$expected', got '$actual'"
    fi
}

assert_le() {
    local a="$1" b="$2" what="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$a" -gt "$b" ]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $what: expected $a <= $b"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" what="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $what: expected to contain '$needle'"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" what="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $what: expected NOT to contain '$needle'"
    fi
}

# Writes a fake cgroup tree. usage: make_cgroup_fixture <dir> v2|v1|none <mem_bytes|max> <cpu_quota|max> [period]
make_cgroup_fixture() {
    local dir="$1" layout="$2" mem="${3:-}" quota="${4:-}" period="${5:-100000}"
    rm -rf "$dir"; mkdir -p "$dir"
    case "$layout" in
        v2)
            echo "$mem" > "$dir/memory.max"
            echo "$quota $period" > "$dir/cpu.max" ;;
        v1)
            mkdir -p "$dir/memory" "$dir/cpu"
            echo "$mem" > "$dir/memory/memory.limit_in_bytes"
            echo "$quota" > "$dir/cpu/cpu.cfs_quota_us"
            echo "$period" > "$dir/cpu/cpu.cfs_period_us" ;;
        none) ;;
    esac
}

finish() {
    echo "  $TESTS_RUN assertions, $TESTS_FAILED failed"
    [ "$TESTS_FAILED" -eq 0 ]
}
