#!/bin/bash
# Unit tests for scripts/lib/runtime_env.sh (the env validators). Every value they accept must be
# one nginx and PHP accept too: a value nginx rejects fails `nginx -t` and crash-loops the pod.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/../scripts/lib/runtime_env.sh"
log() { :; }

echo "validated_positive_int: whole numbers within the bound, else the fallback"
assert_eq 30 "$(validated_positive_int 30 7 X)" "plain number"
assert_eq 7 "$(validated_positive_int 0 7 X)" "zero"
assert_eq 7 "$(validated_positive_int -5 7 X)" "negative"
assert_eq 7 "$(validated_positive_int 3.5 7 X)" "decimal"
assert_eq 7 "$(validated_positive_int "" 7 X)" "empty"
assert_eq 7 "$(validated_positive_int 99999999999 7 X)" "beyond nine digits"
assert_eq 7 "$(validated_positive_int 99999999999999999999 7 X)" "beyond bash integers"
assert_eq 65535 "$(validated_positive_int 65535 100 X 65535)" "at the bound"
assert_eq 100 "$(validated_positive_int 70000 100 X 65535)" "above the bound (nginx limit_conn refuses 65536+)"
out="$(log() { echo "$*"; }; validated_positive_int 70000 100 RATE_LIMIT_MAX_CONN_PER_IP 65535 2>&1)"
assert_contains "$out" "a whole number from 1 to 65535" "the bound is named in the log"

echo "validated_upload_size: K/M/G from 1024K to 100G, uppercased"
assert_eq 64M "$(validated_upload_size 64m 1M X)" "lowercase accepted, uppercased"
assert_eq 1G "$(validated_upload_size 1G 1M X)" "gigabytes"
assert_eq 1024K "$(validated_upload_size 1024k 1M X)" "smallest kilobyte value"
assert_eq 100G "$(validated_upload_size 100G 1M X)" "largest value"
for bad in 1023K 0M 101G 102401M 99999999999G 64MB 64 -1 "" 1.5G; do
    assert_eq 1M "$(validated_upload_size "$bad" 1M X)" "rejects '$bad'"
done

echo "valid_cidr: only what nginx's set_real_ip_from accepts"
for good in 10.0.0.0/8 172.16.0.0/12 192.168.1.1 0.0.0.0/0 255.255.255.254/32 \
        2400:cb00::/32 ::1 ::/0 fe80::1/64 2001:db8:0:0:0:0:0:1 2001:db8::/128 1:2:3:4:5:6:7:8/64 ::ffff:0:0/96; do
    valid_cidr "$good" && r=valid || r=invalid
    assert_eq valid "$r" "accepts '$good'"
done
for bad in 10.0.0.0/33 999.1.1.1 255.255.255.255 255.255.255.255/32 10.0.0 10.0.0.0.0 10.0.0.0/ 10.0.0.0/8/8 a.b.c.d \
        :::: ::::/0 2400:cb00::/129 1:2:3:4:5:6:7:8:9 1::2::3 12345::1 :1 1: 2001:db8:::1 \
        1:2:3:4:5:6:7 gggg::1 "" /8 "10.0.0.0 /8"; do
    valid_cidr "$bad" && r=valid || r=invalid
    assert_eq invalid "$r" "rejects '$bad'"
done

echo "a rejected value returns only the fallback: the log line goes to stderr, never into the value"
# The callers capture the result with $(...) and their log() writes to stdout, which used to put
# "[nginx-overrides] Invalid ..." inside the value and break the generated config.
noisy() { log() { echo "[test] $*"; }; "$@" 2>/dev/null; }
assert_eq 100 "$(noisy validated_positive_int 70000 100 X 65535)" "positive int"
assert_eq 64M "$(noisy validated_upload_size 99999999999G 64M X)" "upload size"
assert_eq "D1 D2" "$(noisy validated_cidrs "10.0.0.0/33" "D1 D2" X)" "CIDR list"
assert_contains "$(log() { echo "[test] $*"; }; validated_upload_size 0M 64M MAX_UPLOAD_SIZE 2>&1 >/dev/null)" "Invalid MAX_UPLOAD_SIZE" "and the log line still reaches stderr"

echo "validated_cidrs: one bad entry falls back to the whole default list"
assert_eq "10.0.0.0/8 2400:cb00::/32" "$(validated_cidrs "10.0.0.0/8,2400:cb00::/32" "D" X)" "comma-separated list"
assert_eq "D" "$(validated_cidrs "10.0.0.0/8 10.0.0.0/33" "D" X)" "a /33 entry"
assert_eq "D" "$(validated_cidrs "10.0.0.0/8,999.1.1.1" "D" X)" "an octet above 255"

finish
