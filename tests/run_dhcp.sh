#!/bin/sh
# Focused DHCP lifecycle runner. Uses the same run_case contract as tests/run.sh.
# Git Bash cannot reliably model setsid process lifetime, so only the cases which
# depend on that real process behaviour are skipped there.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TMPROOT=${TMPDIR:-/tmp}/hsp-dhcp-$$
mkdir -p "$TMPROOT"
trap 'rm -rf "$TMPROOT"' EXIT HUP INT TERM

FAIL=0
TOTAL=0
SKIPPED=0
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*) GIT_BASH=1 ;;
    *) GIT_BASH=0 ;;
esac

run_case() {
    name=$1
    shift
    TOTAL=$((TOTAL + 1))
    case "$name" in
        "actual udhcpd kill still degrades"|"lease reloads while serving stay healthy"|"DHCP retry failure is bounded and visible"|"explicit reset clears degraded state")
            if [ "$GIT_BASH" = 1 ]; then
                printf 'SKIP %s (Git Bash lacks setsid process semantics; run in WSL)\n' "$name"
                SKIPPED=$((SKIPPED + 1))
                return 0
            fi ;;
    esac
    if "$@"; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n' "$name"
        FAIL=$((FAIL + 1))
    fi
}

. "$HERE/test_dhcp.sh"

printf '\n%s: %s checks, %s failed, %s skipped\n' "${0##*/}" "$TOTAL" "$FAIL" "$SKIPPED"
[ "$FAIL" -eq 0 ]
