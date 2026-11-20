#!/bin/sh
# Offline test runner for host-side checks. No root or Android device is required.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
FAIL=0
TOTAL=0
SKIPPED=0
TMPROOT=${TMPDIR:-/tmp}/hsp-test-$$
mkdir -p "$TMPROOT"
trap 'rm -rf "$TMPROOT"' EXIT

run_case() {
    name=$1
    shift
    TOTAL=$((TOTAL + 1))
    "$@"
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        printf 'ok   %s\n' "$name"
    elif [ "$_rc" -eq 77 ]; then
        printf 'SKIP %s\n' "$name"
        SKIPPED=$((SKIPPED + 1))
    else
        printf 'FAIL %s\n' "$name"
        FAIL=$((FAIL + 1))
    fi
}

for f in "$HERE"/test_*.sh; do
    [ -f "$f" ] || continue
    # Load declarations first; each file defines and then runs its cases.
    . "$f"
done

printf '\n%s: %s checks, %s failed, %s skipped\n' "${0##*/}" "$TOTAL" "$FAIL" "$SKIPPED"
[ "$FAIL" -eq 0 ]
