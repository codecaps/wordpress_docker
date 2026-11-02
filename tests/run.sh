#!/bin/bash
# Runs every tests/test_*.sh. Needs bash >= 4 (the image ships 5; on macOS use
# Homebrew's: /opt/homebrew/bin/bash tests/run.sh).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
for t in "$HERE"/test_*.sh; do
    echo "== $(basename "$t")"
    if ! "${BASH:-bash}" "$t"; then status=1; fi
done
[ "$status" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit "$status"
