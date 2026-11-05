#!/bin/bash
# Runs runtime/prepend.php under the local PHP CLI and checks the constants its on/off switches
# define: the same spellings, and the same fallback for a typo, as validated_bool() in
# scripts/lib/runtime_env.sh, which reports the typo at startup.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
PREPEND="$HERE/../runtime/prepend.php"

# CI must run these (GitHub sets CI=true; its Ubuntu runners ship PHP), so only a local run may skip.
if ! command -v php >/dev/null 2>&1; then
    if [ -n "${CI:-}" ]; then
        echo "  FAIL: no php on PATH in CI"
        exit 1
    fi
    echo "  SKIP: no php on PATH (tests/smoke.sh checks the prepend in the image)"
    exit 0
fi

# `php -r` does not run auto_prepend_file, so the prepend is required explicitly. env -i keeps the
# caller's environment (a WP_* variable in the developer's shell) out of the result; -n keeps the
# local php.ini out.
consts() {
    env -i PATH="$PATH" "$@" php -n -r '
        require $argv[1];
        echo (DISABLE_WP_CRON ? "cron-off" : "cron-on"), " ", (DISALLOW_FILE_EDIT ? "noedit" : "edit");' -- "$PREPEND"
}

echo "defaults: WordPress's cron spawner and the file editors are off"
assert_eq "cron-off noedit" "$(consts)" "nothing set"
assert_eq "cron-off noedit" "$(consts WP_CRON_TRIGGER_ENABLED= WP_DISALLOW_FILE_EDIT=)" "empty values are the defaults"

echo "DISABLE_WP_CRON follows WP_CRON_TRIGGER_ENABLED; a typo there falls back to on"
assert_eq "cron-on noedit" "$(consts WP_CRON_TRIGGER_ENABLED=false)" "trigger off: the spawner is back"
assert_eq "cron-on noedit" "$(consts WP_CRON_TRIGGER_ENABLED=OFF)" "any case"
assert_eq "cron-off noedit" "$(consts WP_CRON_TRIGGER_ENABLED=enabled)" "typo: the trigger runs, so the spawner stays off"

echo "WP_DISABLE_WP_CRON overrides it; a typo there follows the trigger again"
assert_eq "cron-on noedit" "$(consts WP_DISABLE_WP_CRON=false)" "explicitly on"
assert_eq "cron-off noedit" "$(consts WP_CRON_TRIGGER_ENABLED=false WP_DISABLE_WP_CRON=Yes)" "explicitly off"
assert_eq "cron-off noedit" "$(consts WP_DISABLE_WP_CRON=maybe)" "typo, trigger on"
assert_eq "cron-on noedit" "$(consts WP_CRON_TRIGGER_ENABLED=false WP_DISABLE_WP_CRON=maybe)" "typo, trigger off"

echo "WP_DISALLOW_FILE_EDIT: only an off value re-enables the editors"
assert_eq "cron-off edit" "$(consts WP_DISALLOW_FILE_EDIT=false)" "off"
assert_eq "cron-off edit" "$(consts "WP_DISALLOW_FILE_EDIT= No ")" "any case, surrounding spaces"
assert_eq "cron-off noedit" "$(consts WP_DISALLOW_FILE_EDIT=flase)" "typo: the editors stay off"

echo "surrounding whitespace: exactly what validated_bool() strips (tab, CR, LF, VT; not a form feed)"
assert_eq "cron-off edit" "$(consts $'WP_DISALLOW_FILE_EDIT=\v\tfalse\r\n')" "tab, CR, LF and VT are stripped"
assert_eq "cron-off noedit" "$(consts $'WP_DISALLOW_FILE_EDIT=false\f')" "a form feed makes it a typo"

finish
