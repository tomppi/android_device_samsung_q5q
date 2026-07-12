#!/system/bin/sh
#
# q5q recovery-side second-kernel launcher
#
# This tool never writes a partition. It validates files in a temporary payload
# directory, asks the hash-verified payload kexec to load them into RAM, and
# executes only after a separate explicitly confirmed command.
#

set -eu
set -f
umask 077

PAYLOAD_DIR="${Q5Q_PAYLOAD_DIR:-/tmp/q5q-linux}"

MAX_IMAGE_BYTES=$((256 * 1024 * 1024))
MAX_INITRD_BYTES=$((256 * 1024 * 1024))
MAX_DTB_BYTES=$((8 * 1024 * 1024))
MAX_CMDLINE_BYTES=4096
MAX_KEXEC_BYTES=$((32 * 1024 * 1024))
MAX_SUMS_BYTES=4096
MAX_STATE_BYTES=4096

fatal_early() {
    printf 'q5q-linux-boot: ERROR: %s\n' "$*" >&2
    exit 1
}

case "$PAYLOAD_DIR" in
    /tmp/*) ;;
    *) fatal_early "payload directory must be below /tmp" ;;
esac

[ ! -L "$PAYLOAD_DIR" ] || fatal_early "payload directory must not be a symlink"
mkdir -p "$PAYLOAD_DIR" || fatal_early "could not create payload directory"
PAYLOAD_DIR="$(readlink -f "$PAYLOAD_DIR" 2>/dev/null)" ||
    fatal_early "could not resolve payload directory"
case "$PAYLOAD_DIR" in
    /tmp/*) ;;
    *) fatal_early "resolved payload directory escaped /tmp" ;;
esac
[ -d "$PAYLOAD_DIR" ] && [ ! -L "$PAYLOAD_DIR" ] ||
    fatal_early "payload directory is not a real directory"
chmod 0700 "$PAYLOAD_DIR" || fatal_early "could not secure payload directory"

LOG_FILE="$PAYLOAD_DIR/q5q-linux-boot.log"
STATE_FILE="$PAYLOAD_DIR/.q5q-loaded.sha256"
IMAGE="$PAYLOAD_DIR/Image"
INITRD="$PAYLOAD_DIR/initramfs.cpio.gz"
DTB="$PAYLOAD_DIR/sm8550-samsung-q5q.dtb"
CMDLINE_FILE="$PAYLOAD_DIR/cmdline.txt"
SUMS_FILE="$PAYLOAD_DIR/SHA256SUMS"
KEXEC_BIN="$PAYLOAD_DIR/kexec"

safe_output_path() {
    output_path="$1"
    [ ! -L "$output_path" ] ||
        fatal_early "refusing symlink output path: $output_path"
    if [ -e "$output_path" ] && [ ! -f "$output_path" ]; then
        fatal_early "refusing non-file output path: $output_path"
    fi
}

safe_output_path "$LOG_FILE"
safe_output_path "$STATE_FILE"
: >> "$LOG_FILE" || fatal_early "could not open launcher log"
chmod 0600 "$LOG_FILE" 2>/dev/null || true

log() {
    printf '%s %s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo unknown-time)" \
        "$*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat <<EOF_USAGE
Usage:
  q5q-linux-boot --check
  q5q-linux-boot --load
  q5q-linux-boot --status
  q5q-linux-boot --unload
  q5q-linux-boot --execute --confirm

Payload directory:
  $PAYLOAD_DIR

Required files:
  Image
  initramfs.cpio.gz
  sm8550-samsung-q5q.dtb
  cmdline.txt
  kexec
  SHA256SUMS

No command in this launcher writes a block-device partition.
EOF_USAGE
}

file_size() {
    stat -c '%s' "$1" 2>/dev/null ||
        wc -c < "$1" | tr -d ' '
}

require_regular_file() {
    checked_file="$1"
    size_limit="$2"

    [ -f "$checked_file" ] || die "missing regular file: $checked_file"
    [ ! -L "$checked_file" ] || die "symlinks are not accepted: $checked_file"

    checked_size="$(file_size "$checked_file")"
    case "$checked_size" in
        ''|*[!0-9]*) die "could not determine file size: $checked_file" ;;
    esac
    [ "$checked_size" -gt 0 ] || die "empty file: $checked_file"
    [ "$checked_size" -le "$size_limit" ] ||
        die "file exceeds safety limit ($checked_size > $size_limit): $checked_file"
}

require_root() {
    [ "$(id -u)" = "0" ] || die "root is required"
}

device_is_q5q() {
    for device_prop in ro.product.device ro.product.vendor.device ro.product.system.device; do
        device_value="$(getprop "$device_prop" 2>/dev/null || true)"
        [ "$device_value" = "q5q" ] && return 0
    done

    if [ -r /proc/device-tree/compatible ] &&
       tr '\000' '\n' < /proc/device-tree/compatible |
       grep -qx 'samsung,q5q'; then
        return 0
    fi

    if [ -r /proc/device-tree/model ] &&
       tr '\000' '\n' < /proc/device-tree/model |
       grep -q 'Galaxy Z Fold5'; then
        return 0
    fi

    return 1
}

kernel_has_kexec() {
    [ -e /sys/kernel/kexec_loaded ] && return 0

    if [ -r /proc/config.gz ]; then
        zcat /proc/config.gz 2>/dev/null |
            grep -q '^CONFIG_KEXEC=y$' && return 0
    fi

    return 1
}

mark_manifest_name() {
    allowed_name="$1"

    case "$allowed_name" in
        Image)
            [ "$seen_image" -eq 0 ] || die "duplicate SHA256SUMS entry: Image"
            seen_image=1
            ;;
        initramfs.cpio.gz)
            [ "$seen_initrd" -eq 0 ] ||
                die "duplicate SHA256SUMS entry: initramfs.cpio.gz"
            seen_initrd=1
            ;;
        sm8550-samsung-q5q.dtb)
            [ "$seen_dtb" -eq 0 ] ||
                die "duplicate SHA256SUMS entry: sm8550-samsung-q5q.dtb"
            seen_dtb=1
            ;;
        cmdline.txt)
            [ "$seen_cmdline" -eq 0 ] ||
                die "duplicate SHA256SUMS entry: cmdline.txt"
            seen_cmdline=1
            ;;
        kexec)
            [ "$seen_kexec" -eq 0 ] || die "duplicate SHA256SUMS entry: kexec"
            seen_kexec=1
            ;;
        *) die "SHA256SUMS contains a disallowed path: $allowed_name" ;;
    esac
}

validate_sums_manifest() {
    require_regular_file "$SUMS_FILE" "$MAX_SUMS_BYTES"

    seen_image=0
    seen_initrd=0
    seen_dtb=0
    seen_cmdline=0
    seen_kexec=0
    entry_count=0

    while IFS= read -r manifest_line || [ -n "$manifest_line" ]; do
        [ -n "$manifest_line" ] || die "SHA256SUMS contains a blank line"

        # Intentional field splitting. Globbing is disabled globally with set -f.
        # shellcheck disable=SC2086
        set -- $manifest_line
        [ "$#" -eq 2 ] || die "malformed SHA256SUMS line"

        manifest_hash="$1"
        manifest_name="${2#\*}"

        [ "${#manifest_hash}" -eq 64 ] || die "SHA256SUMS contains a bad digest"
        case "$manifest_hash" in
            *[!0-9a-fA-F]*) die "SHA256SUMS contains a non-hex digest" ;;
        esac

        mark_manifest_name "$manifest_name"
        entry_count=$((entry_count + 1))
    done < "$SUMS_FILE"

    if [ "$entry_count" -ne 5 ] ||
       [ "$seen_image" -ne 1 ] ||
       [ "$seen_initrd" -ne 1 ] ||
       [ "$seen_dtb" -ne 1 ] ||
       [ "$seen_cmdline" -ne 1 ] ||
       [ "$seen_kexec" -ne 1 ]; then
        die "SHA256SUMS must contain exactly the five required payload files"
    fi

    (
        cd "$PAYLOAD_DIR"
        sha256sum -c SHA256SUMS
    ) >> "$LOG_FILE" 2>&1 || die "payload SHA-256 verification failed"
}

verify_manifest_entry() {
    entry_manifest="$1"
    entry_name="$2"
    entry_file="$3"
    entry_expected=""
    entry_matches=0

    while IFS= read -r entry_line || [ -n "$entry_line" ]; do
        # Intentional field splitting. Globbing is disabled globally with set -f.
        # shellcheck disable=SC2086
        set -- $entry_line
        [ "$#" -eq 2 ] || continue
        parsed_name="${2#\*}"
        [ "$parsed_name" = "$entry_name" ] || continue
        entry_expected="$1"
        entry_matches=$((entry_matches + 1))
    done < "$entry_manifest"

    [ "$entry_matches" -eq 1 ] ||
        die "manifest must contain exactly one $entry_name entry"
    [ "${#entry_expected}" -eq 64 ] || die "manifest contains a bad $entry_name digest"
    case "$entry_expected" in
        *[!0-9a-fA-F]*) die "manifest contains a non-hex $entry_name digest" ;;
    esac

    entry_actual_line="$(sha256sum "$entry_file" 2>/dev/null)" ||
        die "could not hash $entry_name"
    # Intentional field splitting of sha256sum output.
    # shellcheck disable=SC2086
    set -- $entry_actual_line
    [ "$#" -ge 1 ] || die "could not parse $entry_name digest"
    [ "$1" = "$entry_expected" ] || die "$entry_name hash verification failed"
}

validate_dtb_identity() {
    grep -aq 'samsung,q5q' "$DTB" ||
        die "DTB does not contain samsung,q5q compatibility"
    grep -aq 'Samsung Galaxy Z Fold5' "$DTB" ||
        die "DTB does not contain the expected Fold5 model"
}

validate_cmdline() {
    cmdline_size="$(file_size "$CMDLINE_FILE")"
    [ "$cmdline_size" -le "$MAX_CMDLINE_BYTES" ] ||
        die "kernel command line is too large"

    cmdline_lines="$(grep -c '^' "$CMDLINE_FILE" 2>/dev/null || true)"
    [ "$cmdline_lines" -eq 1 ] || die "kernel command line must be exactly one line"

    VALIDATED_CMDLINE="$(tr -d '\r\n' < "$CMDLINE_FILE")"
    [ -n "$VALIDATED_CMDLINE" ] || die "kernel command line is empty"

    removed_bytes=$((cmdline_size - ${#VALIDATED_CMDLINE}))
    [ "$removed_bytes" -eq 0 ] || [ "$removed_bytes" -eq 1 ] ||
        die "kernel command line contains carriage returns or extra newlines"

    if printf '%s' "$VALIDATED_CMDLINE" | grep -q '[[:cntrl:]]' 2>/dev/null; then
        die "kernel command line contains control characters"
    fi
}

validate_payload() {
    require_regular_file "$IMAGE" "$MAX_IMAGE_BYTES"
    require_regular_file "$INITRD" "$MAX_INITRD_BYTES"
    require_regular_file "$DTB" "$MAX_DTB_BYTES"
    require_regular_file "$CMDLINE_FILE" "$MAX_CMDLINE_BYTES"
    require_regular_file "$KEXEC_BIN" "$MAX_KEXEC_BYTES"

    validate_sums_manifest
    verify_manifest_entry "$SUMS_FILE" kexec "$KEXEC_BIN"
    validate_dtb_identity
    validate_cmdline
    chmod 0700 "$KEXEC_BIN" 2>/dev/null || die "could not mark kexec executable"
}

check_environment() {
    require_root
    device_is_q5q || die "device identity is not q5q"
    kernel_has_kexec || die "running recovery kernel does not expose kexec support"

    validate_payload
    verify_manifest_entry "$SUMS_FILE" kexec "$KEXEC_BIN"
    "$KEXEC_BIN" --version >> "$LOG_FILE" 2>&1 || die "kexec binary did not run"

    log "environment and payload checks passed"
}

kexec_loaded_value() {
    if [ -r /sys/kernel/kexec_loaded ]; then
        cat /sys/kernel/kexec_loaded
    else
        echo unknown
    fi
}

rollback_loaded_image() {
    rollback_manifest="$1"

    if (verify_manifest_entry "$rollback_manifest" kexec "$KEXEC_BIN"); then
        log "rolling back the loaded image"
        "$KEXEC_BIN" -u >> "$LOG_FILE" 2>&1 ||
            log "warning: kexec unload during rollback failed"
    else
        log "warning: refusing rollback because payload kexec is no longer verified"
    fi
}

create_state_manifest() {
    TEMP_STATE="$PAYLOAD_DIR/.q5q-loaded.sha256.tmp.$$"
    if [ -e "$TEMP_STATE" ] || [ -L "$TEMP_STATE" ]; then
        die "temporary state path already exists"
    fi

    (
        cd "$PAYLOAD_DIR"
        sha256sum Image initramfs.cpio.gz sm8550-samsung-q5q.dtb \
            cmdline.txt kexec
    ) > "$TEMP_STATE" || {
        rm -f "$TEMP_STATE"
        die "could not create loaded-state manifest"
    }
    chmod 0600 "$TEMP_STATE" 2>/dev/null || true

    require_regular_file "$TEMP_STATE" "$MAX_STATE_BYTES"
    (
        cd "$PAYLOAD_DIR"
        sha256sum -c "${TEMP_STATE##*/}"
    ) >> "$LOG_FILE" 2>&1 || {
        rm -f "$TEMP_STATE"
        die "payload changed while preparing the load"
    }
}

load_payload() {
    check_environment

    loaded_value="$(kexec_loaded_value)"
    [ "$loaded_value" != "1" ] ||
        die "a kexec image is already loaded; use --unload first"

    safe_output_path "$STATE_FILE"
    rm -f "$STATE_FILE"
    create_state_manifest

    verify_manifest_entry "$TEMP_STATE" kexec "$KEXEC_BIN"
    log "loading q5q second-stage kernel into RAM"
    if ! "$KEXEC_BIN" -l "$IMAGE" \
        --initrd="$INITRD" \
        --dtb="$DTB" \
        --command-line="$VALIDATED_CMDLINE" >> "$LOG_FILE" 2>&1; then
        rm -f "$TEMP_STATE"
        die "kexec load failed"
    fi

    if ! (
        cd "$PAYLOAD_DIR"
        sha256sum -c "${TEMP_STATE##*/}"
    ) >> "$LOG_FILE" 2>&1; then
        rollback_loaded_image "$TEMP_STATE"
        rm -f "$TEMP_STATE"
        die "payload changed during kexec load"
    fi

    if ! mv "$TEMP_STATE" "$STATE_FILE"; then
        rollback_loaded_image "$TEMP_STATE"
        rm -f "$TEMP_STATE"
        die "could not commit loaded-state manifest"
    fi
    chmod 0600 "$STATE_FILE" 2>/dev/null || true

    loaded_value="$(kexec_loaded_value)"
    [ "$loaded_value" = "1" ] ||
        log "warning: the kernel does not expose /sys/kernel/kexec_loaded=1"

    log "payload loaded; execution still requires --execute --confirm"
}

status_payload() {
    loaded_value="$(kexec_loaded_value)"
    log "kexec_loaded=$loaded_value"

    if [ -e "$STATE_FILE" ]; then
        require_regular_file "$STATE_FILE" "$MAX_STATE_BYTES"
        log "loaded-state manifest:"
        tee -a "$LOG_FILE" < "$STATE_FILE"
    else
        log "no launcher state manifest exists"
    fi
}

unload_payload() {
    require_root
    device_is_q5q || die "device identity is not q5q"
    require_regular_file "$KEXEC_BIN" "$MAX_KEXEC_BYTES"

    if [ -e "$STATE_FILE" ]; then
        require_regular_file "$STATE_FILE" "$MAX_STATE_BYTES"
        verify_manifest_entry "$STATE_FILE" kexec "$KEXEC_BIN"
    else
        validate_sums_manifest
        verify_manifest_entry "$SUMS_FILE" kexec "$KEXEC_BIN"
    fi

    chmod 0700 "$KEXEC_BIN" 2>/dev/null || die "could not mark kexec executable"
    "$KEXEC_BIN" -u >> "$LOG_FILE" 2>&1 || die "kexec unload failed"

    if [ -e "$STATE_FILE" ]; then
        require_regular_file "$STATE_FILE" "$MAX_STATE_BYTES"
        rm -f "$STATE_FILE"
    fi
    log "unloaded the staged kexec image"
}

execute_payload() {
    require_root
    device_is_q5q || die "device identity is not q5q"
    require_regular_file "$STATE_FILE" "$MAX_STATE_BYTES"
    require_regular_file "$KEXEC_BIN" "$MAX_KEXEC_BYTES"

    (
        cd "$PAYLOAD_DIR"
        sha256sum -c "${STATE_FILE##*/}"
    ) >> "$LOG_FILE" 2>&1 || die "payload changed after it was loaded"
    verify_manifest_entry "$STATE_FILE" kexec "$KEXEC_BIN"

    loaded_value="$(kexec_loaded_value)"
    [ "$loaded_value" = "1" ] || die "kernel does not report a loaded kexec image"

    chmod 0700 "$KEXEC_BIN" 2>/dev/null || die "could not mark kexec executable"
    log "executing the loaded second-stage kernel now"
    sync
    sleep 1

    verify_manifest_entry "$STATE_FILE" kexec "$KEXEC_BIN"
    "$KEXEC_BIN" -e
    die "kexec execute returned unexpectedly"
}

case "${1:-}" in
    --check)
        [ "$#" -eq 1 ] || die "--check takes no additional arguments"
        check_environment
        ;;
    --load)
        [ "$#" -eq 1 ] || die "--load takes no additional arguments"
        load_payload
        ;;
    --status)
        [ "$#" -eq 1 ] || die "--status takes no additional arguments"
        status_payload
        ;;
    --unload)
        [ "$#" -eq 1 ] || die "--unload takes no additional arguments"
        unload_payload
        ;;
    --execute)
        if [ "${2:-}" != "--confirm" ] || [ "$#" -ne 2 ]; then
            die "--execute requires the literal second argument --confirm"
        fi
        execute_payload
        ;;
    -h|--help|'')
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
