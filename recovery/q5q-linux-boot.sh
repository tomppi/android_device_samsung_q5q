#!/system/bin/sh
#
# q5q recovery-side second-kernel launcher
#
# This tool never writes a partition. It only validates files under PAYLOAD_DIR,
# asks kexec-tools to load them into RAM, and executes a separately confirmed
# handoff.
#

set -eu

PAYLOAD_DIR="${Q5Q_PAYLOAD_DIR:-/tmp/q5q-linux}"
LOG_FILE="$PAYLOAD_DIR/q5q-linux-boot.log"
STATE_FILE="$PAYLOAD_DIR/.q5q-loaded.sha256"

IMAGE="$PAYLOAD_DIR/Image"
INITRD="$PAYLOAD_DIR/initramfs.cpio.gz"
DTB="$PAYLOAD_DIR/sm8550-samsung-q5q.dtb"
CMDLINE_FILE="$PAYLOAD_DIR/cmdline.txt"
SUMS_FILE="$PAYLOAD_DIR/SHA256SUMS"

MAX_IMAGE_BYTES=$((256 * 1024 * 1024))
MAX_INITRD_BYTES=$((256 * 1024 * 1024))
MAX_DTB_BYTES=$((8 * 1024 * 1024))
MAX_CMDLINE_BYTES=4096
MAX_KEXEC_BYTES=$((32 * 1024 * 1024))

mkdir -p "$PAYLOAD_DIR"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE" 2>/dev/null || true

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo unknown-time)" "$*" |
        tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat <<EOF
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
  SHA256SUMS
  kexec                    # static arm64 kexec-tools binary

No command in this launcher writes a block-device partition.
EOF
}

file_size() {
    stat -c '%s' "$1" 2>/dev/null ||
        wc -c < "$1" |
        tr -d ' '
}

require_regular_file() {
    file="$1"
    limit="$2"

    [ -f "$file" ] || die "missing regular file: $file"
    [ ! -L "$file" ] || die "symlinks are not accepted: $file"

    size="$(file_size "$file")"
    case "$size" in
        ''|*[!0-9]*) die "could not determine file size: $file" ;;
    esac

    [ "$size" -gt 0 ] || die "empty file: $file"
    [ "$size" -le "$limit" ] ||
        die "file exceeds safety limit ($size > $limit): $file"
}

require_root() {
    [ "$(id -u)" = "0" ] || die "root is required"
}

device_is_q5q() {
    for prop in ro.product.device ro.product.vendor.device ro.product.system.device; do
        value="$(getprop "$prop" 2>/dev/null || true)"
        [ "$value" = "q5q" ] && return 0
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
    if [ -e /sys/kernel/kexec_loaded ]; then
        return 0
    fi

    if [ -r /proc/config.gz ]; then
        zcat /proc/config.gz 2>/dev/null |
            grep -q '^CONFIG_KEXEC=y$' && return 0
    fi

    return 1
}

find_kexec() {
    for candidate in \
        "$PAYLOAD_DIR/kexec" \
        /system/bin/kexec \
        /sbin/kexec
    do
        if [ -f "$candidate" ] && [ ! -L "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

validate_sums_manifest() {
    [ -f "$SUMS_FILE" ] || die "missing SHA256SUMS"
    [ ! -L "$SUMS_FILE" ] || die "SHA256SUMS must not be a symlink"

    while IFS= read -r line; do
        [ -n "$line" ] || continue

        name="${line#*  }"
        [ "$name" != "$line" ] || name="${line#* *}"
        name="${name#\*}"

        case "$name" in
            Image|initramfs.cpio.gz|sm8550-samsung-q5q.dtb|cmdline.txt|kexec)
                ;;
            *)
                die "SHA256SUMS contains a disallowed path: $name"
                ;;
        esac
    done < "$SUMS_FILE"

    (
        cd "$PAYLOAD_DIR"
        sha256sum -c SHA256SUMS
    ) >> "$LOG_FILE" 2>&1 ||
        die "payload SHA-256 verification failed"
}

validate_dtb_identity() {
    grep -aq 'samsung,q5q' "$DTB" ||
        die "DTB does not contain samsung,q5q compatibility"
    grep -aq 'Samsung Galaxy Z Fold5' "$DTB" ||
        die "DTB does not contain the expected Fold5 model"
}

validate_cmdline() {
    size="$(file_size "$CMDLINE_FILE")"
    [ "$size" -le "$MAX_CMDLINE_BYTES" ] ||
        die "kernel command line is too large"

    if grep -q '[[:cntrl:]]' "$CMDLINE_FILE" 2>/dev/null; then
        cleaned="$(tr -d '\r\n' < "$CMDLINE_FILE")"
        printf '%s' "$cleaned" | grep -q '[[:cntrl:]]' 2>/dev/null &&
            die "kernel command line contains control characters"
    fi
}

validate_payload() {
    kexec_bin="$1"

    require_regular_file "$IMAGE" "$MAX_IMAGE_BYTES"
    require_regular_file "$INITRD" "$MAX_INITRD_BYTES"
    require_regular_file "$DTB" "$MAX_DTB_BYTES"
    require_regular_file "$CMDLINE_FILE" "$MAX_CMDLINE_BYTES"
    require_regular_file "$kexec_bin" "$MAX_KEXEC_BYTES"

    chmod 0700 "$kexec_bin" 2>/dev/null ||
        die "could not mark kexec executable"

    validate_sums_manifest
    validate_dtb_identity
    validate_cmdline
}

check_environment() {
    require_root
    device_is_q5q || die "device identity is not q5q"
    kernel_has_kexec || die "running recovery kernel does not expose kexec support"

    kexec_bin="$(find_kexec)" || die "no kexec binary found"
    validate_payload "$kexec_bin"

    "$kexec_bin" --version >> "$LOG_FILE" 2>&1 ||
        die "kexec binary did not run"

    log "environment and payload checks passed"
}

kexec_loaded_value() {
    if [ -r /sys/kernel/kexec_loaded ]; then
        cat /sys/kernel/kexec_loaded
    else
        echo unknown
    fi
}

load_payload() {
    check_environment

    loaded="$(kexec_loaded_value)"
    [ "$loaded" != "1" ] ||
        die "a kexec image is already loaded; use --unload first"

    kexec_bin="$(find_kexec)"
    cmdline="$(tr -d '\r\n' < "$CMDLINE_FILE")"

    log "loading q5q second-stage kernel into RAM"
    "$kexec_bin" -l "$IMAGE" \
        --initrd="$INITRD" \
        --dtb="$DTB" \
        --command-line="$cmdline" >> "$LOG_FILE" 2>&1 ||
        die "kexec load failed"

    (
        cd "$PAYLOAD_DIR"
        sha256sum Image initramfs.cpio.gz sm8550-samsung-q5q.dtb \
            cmdline.txt kexec
    ) > "$STATE_FILE"
    chmod 0600 "$STATE_FILE" 2>/dev/null || true

    loaded="$(kexec_loaded_value)"
    [ "$loaded" = "1" ] ||
        log "warning: the kernel does not expose /sys/kernel/kexec_loaded=1"

    log "payload loaded; execution still requires --execute --confirm"
}

status_payload() {
    loaded="$(kexec_loaded_value)"
    log "kexec_loaded=$loaded"

    if [ -f "$STATE_FILE" ]; then
        log "loaded-state manifest:"
        cat "$STATE_FILE" | tee -a "$LOG_FILE"
    else
        log "no launcher state manifest exists"
    fi
}

unload_payload() {
    require_root
    kexec_bin="$(find_kexec)" || die "no kexec binary found"

    "$kexec_bin" -u >> "$LOG_FILE" 2>&1 ||
        die "kexec unload failed"

    rm -f "$STATE_FILE"
    log "unloaded the staged kexec image"
}

execute_payload() {
    require_root
    device_is_q5q || die "device identity is not q5q"

    [ -f "$STATE_FILE" ] ||
        die "no launcher state exists; run --load first"

    (
        cd "$PAYLOAD_DIR"
        sha256sum -c "$STATE_FILE"
    ) >> "$LOG_FILE" 2>&1 ||
        die "payload changed after it was loaded"

    loaded="$(kexec_loaded_value)"
    [ "$loaded" = "1" ] ||
        die "kernel does not report a loaded kexec image"

    kexec_bin="$(find_kexec)" || die "no kexec binary found"

    log "executing the loaded second-stage kernel now"
    sync
    sleep 1

    "$kexec_bin" -e
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
        [ "${2:-}" = "--confirm" ] && [ "$#" -eq 2 ] ||
            die "--execute requires the literal second argument --confirm"
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
