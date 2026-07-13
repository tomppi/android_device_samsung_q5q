#!/system/bin/sh
#
# Public q5q kexec launcher safety gate.
#
# The backend performs device, hash, load-state and kexec validation. This
# wrapper adds a non-optional first-handoff escape contract before any check,
# load or execute operation can proceed.

set -eu
set -f

PAYLOAD_DIR="${Q5Q_PAYLOAD_DIR:-/tmp/q5q-linux}"
CMDLINE_FILE="$PAYLOAD_DIR/cmdline.txt"
BACKEND=/system/bin/.q5q-linux-boot-backend

fail() {
    printf 'q5q-linux-boot: ESCAPE-GATE ERROR: %s\n' "$*" >&2
    exit 1
}

validate_escape_contract() {
    [ -f "$CMDLINE_FILE" ] || fail "missing cmdline.txt"
    [ ! -L "$CMDLINE_FILE" ] || fail "cmdline.txt must not be a symlink"

    cmdline_lines="$(grep -c '^' "$CMDLINE_FILE" 2>/dev/null || true)"
    [ "$cmdline_lines" -eq 1 ] || fail "cmdline.txt must contain exactly one line"

    cmdline="$(tr -d '\r\n' < "$CMDLINE_FILE")"
    [ -n "$cmdline" ] || fail "cmdline.txt is empty"

    panic_value=""
    escape_timeout=""
    panic_count=0
    oops_count=0
    rdinit_count=0
    timeout_count=0
    escape_required_count=0
    watchdog_required_count=0

    # Intentional field splitting; glob expansion is disabled above.
    # shellcheck disable=SC2086
    for token in $cmdline; do
        case "$token" in
            panic=*)
                panic_value="${token#*=}"
                panic_count=$((panic_count + 1))
                ;;
            oops=panic)
                oops_count=$((oops_count + 1))
                ;;
            rdinit=/init)
                rdinit_count=$((rdinit_count + 1))
                ;;
            q5q.escape_timeout=*)
                escape_timeout="${token#*=}"
                timeout_count=$((timeout_count + 1))
                ;;
            q5q.escape_required=1)
                escape_required_count=$((escape_required_count + 1))
                ;;
            q5q.watchdog_required=1)
                watchdog_required_count=$((watchdog_required_count + 1))
                ;;
            q5q.escape_required=*|q5q.watchdog_required=*)
                fail "escape and watchdog requirements must both equal 1"
                ;;
            nowatchdog)
                fail "nowatchdog is forbidden"
                ;;
        esac
    done

    case "$panic_value" in
        ''|*[!0-9]*) fail "panic timeout must be numeric" ;;
    esac
    [ "$panic_count" -eq 1 ] || fail "exactly one panic= value is required"
    [ "$panic_value" -ge 1 ] && [ "$panic_value" -le 60 ] ||
        fail "panic timeout must be between 1 and 60 seconds"

    [ "$oops_count" -eq 1 ] || fail "exactly one oops=panic is required"
    [ "$rdinit_count" -eq 1 ] || fail "exactly one rdinit=/init is required"

    case "$escape_timeout" in
        ''|*[!0-9]*) fail "q5q.escape_timeout must be numeric" ;;
    esac
    [ "$timeout_count" -eq 1 ] ||
        fail "exactly one q5q.escape_timeout is required"
    [ "$escape_timeout" -ge 10 ] && [ "$escape_timeout" -le 600 ] ||
        fail "q5q.escape_timeout must be between 10 and 600 seconds"

    [ "$escape_required_count" -eq 1 ] ||
        fail "q5q.escape_required=1 is mandatory"
    [ "$watchdog_required_count" -eq 1 ] ||
        fail "q5q.watchdog_required=1 is mandatory"

    printf 'q5q-linux-boot: escape contract accepted: auto-return=%ss panic=%ss watchdog=required\n' \
        "$escape_timeout" "$panic_value"
}

case "${1:-}" in
    --check|--load|--execute)
        validate_escape_contract
        ;;
esac

[ -x "$BACKEND" ] || fail "launcher backend is missing"
exec "$BACKEND" "$@"
