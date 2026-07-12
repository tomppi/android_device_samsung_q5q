# q5q Halium 15 branch

This branch is an experimental Halium/Droidian bring-up for the Samsung Galaxy Z Fold5 (SM-F946B, q5q).

## What differs from lineage-23.2

- Registers `halium_q5q-ap2a-userdebug`.
- Uses the current SM8550/q5q boot and partition definitions.
- Builds the kernel from `kernel/samsung/sm8550`.
- Merges `q5q_halium.fragment` on top of `q5q_defconfig`.
- Disables AVB and verity for the unlocked development image.
- Adds Halium binder, mount-point, fold-state, framebuffer-console, and touch-service init hooks.
- Adds conservative device metadata without assuming Samsung supports fastboot flashing.

## Intentional deviations from the original prototype

The original prototype used an absolute prebuilt-kernel path and recovery/TWRP-style header-v2 offsets. Those are not carried forward here. Normal q5q boot uses header v4 with `init_boot` and `vendor_boot`; a recovery-path test image must be constructed and validated separately.

The extracted prototype `prebuilt/dtb.img` is also not copied. The first build should use DTBs produced from the matching q5q kernel source, avoiding an unexplained binary DTB in the device tree.

## Status

Pre-alpha. Source configuration only. Do not flash output until the boot image has been unpacked and compared with known-good dumps from the exact device firmware.
