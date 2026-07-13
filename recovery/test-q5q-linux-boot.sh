#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$SCRIPT_DIR/q5q-linux-boot.sh"

if [[ ${1:-} != --inside-mount-namespace ]]; then
  exec sudo unshare --mount --propagation private \
    bash "$0" --inside-mount-namespace
fi

[[ $EUID -eq 0 ]] || {
  echo "behavioral test must run as root inside the mount namespace" >&2
  exit 1
}

for tool in mount sha256sum stat; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing test tool: $tool" >&2
    exit 1
  }
done

TEST_ROOT="$(mktemp -d /tmp/q5q-launcher-test.XXXXXX)"
PAYLOAD_DIR="$TEST_ROOT/payload"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_KERNEL="$TEST_ROOT/kernel"
EXEC_MARKER="$TEST_ROOT/kexec-executed"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$PAYLOAD_DIR" "$FAKE_BIN" "$FAKE_KERNEL"
printf '0\n' > "$FAKE_KERNEL/kexec_loaded"
mount --bind "$FAKE_KERNEL" /sys/kernel

cat > "$FAKE_BIN/getprop" <<'EOF_GETPROP'
#!/bin/sh
case "${1:-}" in
  ro.product.device) printf '%s\n' q5q ;;
  *) printf '\n' ;;
esac
EOF_GETPROP
chmod 0755 "$FAKE_BIN/getprop"

cat > "$TEST_ROOT/fake-kexec" <<'EOF_KEXEC'
#!/bin/sh
set -eu
case "${1:-}" in
  --version)
    echo "kexec-tools test double"
    ;;
  -l)
    printf '1\n' > "${Q5Q_TEST_KEXEC_STATE:?}"
    ;;
  -u)
    printf '0\n' > "${Q5Q_TEST_KEXEC_STATE:?}"
    ;;
  -e)
    : > "${Q5Q_TEST_EXEC_MARKER:?}"
    ;;
  *)
    echo "unexpected fake kexec arguments: $*" >&2
    exit 64
    ;;
esac
EOF_KEXEC
chmod 0755 "$TEST_ROOT/fake-kexec"

export PATH="$FAKE_BIN:/usr/sbin:/usr/bin:/sbin:/bin"
export Q5Q_PAYLOAD_DIR="$PAYLOAD_DIR"
export Q5Q_TEST_KEXEC_STATE=/sys/kernel/kexec_loaded
export Q5Q_TEST_EXEC_MARKER="$EXEC_MARKER"

create_payload() {
  rm -rf "$PAYLOAD_DIR"
  mkdir -p "$PAYLOAD_DIR"

  printf 'test arm64 Image\n' > "$PAYLOAD_DIR/Image"
  printf 'test initramfs\n' > "$PAYLOAD_DIR/initramfs.cpio.gz"
  printf 'samsung,q5q\0Samsung Galaxy Z Fold5\0' \
    > "$PAYLOAD_DIR/sm8550-samsung-q5q.dtb"
  printf 'console=tty0 rdinit=/init\n' > "$PAYLOAD_DIR/cmdline.txt"
  cp "$TEST_ROOT/fake-kexec" "$PAYLOAD_DIR/kexec"
  chmod 0755 "$PAYLOAD_DIR/kexec"

  (
    cd "$PAYLOAD_DIR"
    sha256sum Image initramfs.cpio.gz sm8550-samsung-q5q.dtb \
      cmdline.txt kexec > SHA256SUMS
  )
}

run_launcher() {
  sh "$LAUNCHER" "$@" >/dev/null 2>&1
}

expect_success() {
  local description="$1"
  shift
  if ! "$@"; then
    echo "FAIL: expected success: $description" >&2
    exit 1
  fi
  echo "PASS: $description"
}

expect_failure() {
  local description="$1"
  shift
  if "$@"; then
    echo "FAIL: expected failure: $description" >&2
    exit 1
  fi
  echo "PASS: $description"
}

assert_state() {
  local expected="$1"
  local actual
  actual="$(cat /sys/kernel/kexec_loaded)"
  [[ $actual == "$expected" ]] || {
    echo "FAIL: expected kexec_loaded=$expected, got $actual" >&2
    exit 1
  }
}

create_payload
expect_failure "execute requires the literal confirmation" \
  run_launcher --execute
[[ ! -e "$EXEC_MARKER" ]] || {
  echo "FAIL: kexec execute ran without confirmation" >&2
  exit 1
}

expect_success "valid payload passes --check" run_launcher --check
expect_success "valid payload loads" run_launcher --load
assert_state 1
[[ -f "$PAYLOAD_DIR/.q5q-loaded.sha256" ]] || {
  echo "FAIL: load did not create a state manifest" >&2
  exit 1
}
expect_failure "a second load is rejected" run_launcher --load

printf 'tamper\n' >> "$PAYLOAD_DIR/Image"
expect_failure "payload mutation blocks execution" \
  run_launcher --execute --confirm
[[ ! -e "$EXEC_MARKER" ]] || {
  echo "FAIL: mutated payload reached kexec execute" >&2
  exit 1
}
expect_success "unload remains available after non-kexec payload mutation" \
  run_launcher --unload
assert_state 0
[[ ! -e "$PAYLOAD_DIR/.q5q-loaded.sha256" ]] || {
  echo "FAIL: unload left the state manifest behind" >&2
  exit 1
}

create_payload
expect_success "fresh payload reloads" run_launcher --load
cp "$PAYLOAD_DIR/kexec" "$TEST_ROOT/kexec-backup"
printf '# tampered\n' >> "$PAYLOAD_DIR/kexec"
expect_failure "mutated kexec cannot unload the staged image" \
  run_launcher --unload
assert_state 1
cp "$TEST_ROOT/kexec-backup" "$PAYLOAD_DIR/kexec"
chmod 0755 "$PAYLOAD_DIR/kexec"
expect_success "restored verified kexec can unload" run_launcher --unload
assert_state 0

create_payload
printf '%064d  unexpected-file\n' 0 >> "$PAYLOAD_DIR/SHA256SUMS"
expect_failure "manifest entries outside the allowlist are rejected" \
  run_launcher --check

create_payload
mv "$PAYLOAD_DIR/Image" "$TEST_ROOT/Image.real"
ln -s "$TEST_ROOT/Image.real" "$PAYLOAD_DIR/Image"
(
  cd "$PAYLOAD_DIR"
  sha256sum Image initramfs.cpio.gz sm8550-samsung-q5q.dtb \
    cmdline.txt kexec > SHA256SUMS
)
expect_failure "symlink payload files are rejected" run_launcher --check

create_payload
expect_success "payload loads before confirmed execute test" run_launcher --load
expect_failure "a returning fake kexec makes execute fail closed" \
  run_launcher --execute --confirm
[[ -f "$EXEC_MARKER" ]] || {
  echo "FAIL: confirmed execute did not invoke kexec -e" >&2
  exit 1
}

echo "All q5q recovery launcher behavioral tests passed."
