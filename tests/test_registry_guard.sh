#!/bin/bash
# Unit tests for tools/registry_guard.sh and the two push scripts that use it, against a fake
# `docker` on PATH: nothing here talks to a registry.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
source "$HERE/lib.sh"
source "$ROOT/tools/registry_guard.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# The fake docker: `buildx imagetools inspect` answers with $FAKE_INSPECT_RC / $FAKE_INSPECT_OUT,
# `run` prints a PHP version (and succeeds), `push` records what would have been pushed.
cat > "$tmp/bin/docker" <<'EOF'
#!/bin/bash
case "$1 ${2:-} ${3:-}" in
    "buildx imagetools inspect") printf '%s\n' "${FAKE_INSPECT_OUT:-}"; exit "${FAKE_INSPECT_RC:-0}" ;;
esac
case "$1" in
    run) echo "8.4.99"; exit 0 ;;
    push) echo "$2" >> "$FAKE_PUSHED"; exit 0 ;;
esac
echo "unexpected docker call: $*" >&2; exit 99
EOF
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" FAKE_PUSHED="$tmp/pushed"

state_of() { local rc=0; registry_tag_state "$1" 2>/dev/null || rc=$?; echo "$rc"; }

echo "registry_tag_state tells absent, present and unknown apart"
FAKE_INSPECT_RC=0 FAKE_INSPECT_OUT="Name: x" ; export FAKE_INSPECT_RC FAKE_INSPECT_OUT
assert_eq 1 "$(state_of reg.example/img:tag)" "an existing tag"
export FAKE_INSPECT_RC=1 FAKE_INSPECT_OUT="ERROR: reg.example/img:tag: not found"
assert_eq 0 "$(state_of reg.example/img:tag)" "a missing tag"
export FAKE_INSPECT_OUT="ERROR: docker.io/library/wordpress:nope: not found"
assert_eq 0 "$(state_of wordpress:nope)" "a missing tag (canonicalised ref)"
export FAKE_INSPECT_OUT=$'to select an already authenticated account to use.\nERROR: error getting credentials - err: exit status 1, out: ``'
assert_eq 2 "$(state_of reg.example/img:tag)" "an expired login is unknown, not absent"
export FAKE_INSPECT_OUT='ERROR: error getting credentials - err: exec: "docker-credential-gcloud": executable file not found in $PATH, out: ``'
assert_eq 2 "$(state_of reg.example/img:tag)" "a missing credential helper is unknown (despite 'not found' in the text)"
export FAKE_INSPECT_OUT='ERROR: failed to do request: Head "https://reg.example/v2/img/manifests/tag": dial tcp: lookup reg.example: no such host'
assert_eq 2 "$(state_of reg.example/img:tag)" "a network error is unknown"
err="$(registry_tag_state reg.example/img:tag 2>&1 >/dev/null)"
assert_contains "$err" "could not check whether reg.example/img:tag already exists" "and says so"

echo "push.sh pushes only a tag the registry says is absent"
run_push() { : > "$FAKE_PUSHED"; bash "$ROOT/push.sh" 8.4 >/dev/null 2>"$tmp/err"; echo $?; }
source "$ROOT/tracks/php8.4.env"
ref="europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime:php8.4-r${REVISION}"
export FAKE_INSPECT_RC=1 FAKE_INSPECT_OUT="ERROR: ${ref}: not found"
assert_eq 0 "$(run_push)" "absent: push succeeds"
assert_eq "$ref europe-west4-docker.pkg.dev/appstrax/main/wordpress-runtime:php8.4" "$(xargs < "$FAKE_PUSHED")" "immutable tag first, then the alias"
export FAKE_INSPECT_RC=0 FAKE_INSPECT_OUT="Name: ${ref}"
assert_eq 1 "$(run_push)" "present: refused"
assert_eq "" "$(cat "$FAKE_PUSHED")" "nothing pushed"
assert_contains "$(cat "$tmp/err")" "bump REVISION" "with the hint"
export FAKE_INSPECT_RC=1 FAKE_INSPECT_OUT="ERROR: error getting credentials - err: exit status 1, out: \`\`"
assert_eq 1 "$(run_push)" "unknown: refused"
assert_eq "" "$(cat "$FAKE_PUSHED")" "nothing pushed on an expired login"

echo "legacy/docker_push.sh guards its immutable tag the same way"
run_legacy() { : > "$FAKE_PUSHED"; bash "$ROOT/legacy/docker_push.sh" 6.8 >/dev/null 2>"$tmp/err"; echo $?; }
lref="europe-west4-docker.pkg.dev/appstrax/main/wordpress:6.8-php8.4.99"
export FAKE_INSPECT_RC=1 FAKE_INSPECT_OUT="ERROR: ${lref}: not found"
assert_eq 0 "$(run_legacy)" "absent: push succeeds"
assert_eq "$lref europe-west4-docker.pkg.dev/appstrax/main/wordpress:6.8" "$(xargs < "$FAKE_PUSHED")" "immutable tag first, then the moving tag"
export FAKE_INSPECT_RC=0 FAKE_INSPECT_OUT="Name: ${lref}"
assert_eq 1 "$(run_legacy)" "present: refused"
assert_eq "" "$(cat "$FAKE_PUSHED")" "the immutable tag is never overwritten"
export FAKE_INSPECT_RC=1 FAKE_INSPECT_OUT="ERROR: failed to do request: dial tcp: i/o timeout"
assert_eq 1 "$(run_legacy)" "unknown: refused"

finish
