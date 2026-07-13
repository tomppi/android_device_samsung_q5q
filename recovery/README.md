# q5q recovery kexec prototype

This directory contains the first development-only launcher for handing off from
Lineage Recovery to a second arm64 Linux kernel.

It deliberately does **not** contain a kernel, initramfs, DTB, root filesystem,
or prebuilt `kexec` binary. Those are staged over ADB under `/tmp/q5q-linux` so
the recovery image remains a normal repair environment by default.

## Build

Use the dedicated product so `BoardConfig.mk` adds
`q5q_halium_debug.fragment` only to this development image:

```bash
source build/envsetup.sh
lunch lineage_q5q_kexec-userdebug
mka recoveryimage
```

After building, verify that the merged kernel configuration contains at least:

```text
CONFIG_KEXEC=y
CONFIG_KEXEC_FILE=y
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
```

Also enforce the known recovery partition size before any device test.

## Payload

Push these files to `/tmp/q5q-linux`:

```text
Image
initramfs.cpio.gz
sm8550-samsung-q5q.dtb
cmdline.txt
kexec
SHA256SUMS
```

`kexec` must be a static arm64 build of kexec-tools. `SHA256SUMS` may contain
only the five payload files listed above.

Example staging flow:

```bash
adb shell mkdir -p /tmp/q5q-linux
adb push out/q5q-payload/. /tmp/q5q-linux/
adb shell sh /system/bin/q5q-linux-boot --check
adb shell sh /system/bin/q5q-linux-boot --load
adb shell sh /system/bin/q5q-linux-boot --status
```

Execution is intentionally separate:

```bash
adb shell sh /system/bin/q5q-linux-boot --execute --confirm
```

## Safety properties

- no automatic execution;
- no block-device writes;
- q5q identity and DTB identity checks;
- strict file-size limits;
- strict SHA-256 allowlist;
- rejection of symlinks;
- load and execute are separate actions;
- payload changes after load prevent execution;
- an existing loaded image must be explicitly unloaded first.

This is still experimental. A successful `kexec -l` does not prove that the
second kernel can survive watchdog, remote-processor, firmware, reserved-memory,
or USB state left by Android Recovery.
