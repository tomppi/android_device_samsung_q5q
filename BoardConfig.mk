#
# Copyright (C) 2023 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Halium 15 board configuration for q5q.
# Keep the current SM8550 partition and boot-image definitions, then apply
# only the overrides required for a Halium ramdisk and unlocked bootloader.
include device/samsung/sm8550-common/BoardConfigCommon.mk

DEVICE_PATH := device/samsung/q5q

# Assert
TARGET_OTA_ASSERT_DEVICE := q5q

# Display
TARGET_SCREEN_DENSITY := 420

# Kernel: build from the checked-out source tree; never use an absolute path.
# Lineage 23.2 treats TARGET_KERNEL_CONFIG as a list: first the base defconfig,
# then any fragments that should be merged into the final .config.
TARGET_KERNEL_CONFIG := q5q_defconfig q5q_halium.fragment

# Kernel modules
BOARD_SYSTEM_KERNEL_MODULES := $(strip $(shell cat $(DEVICE_PATH)/modules.load.system_dlkm))
BOARD_SYSTEM_KERNEL_MODULES_LOAD := $(strip $(shell cat $(DEVICE_PATH)/modules.load.system_dlkm))
BOARD_VENDOR_KERNEL_MODULES_LOAD := $(strip $(shell cat $(DEVICE_PATH)/modules.load))
BOARD_VENDOR_KERNEL_MODULES_BLOCKLIST_FILE := $(DEVICE_PATH)/modules.blocklist
BOARD_VENDOR_RAMDISK_KERNEL_MODULES_LOAD := $(strip $(shell cat $(DEVICE_PATH)/modules.load.vendor_boot))
BOARD_VENDOR_RAMDISK_KERNEL_MODULES_BLOCKLIST_FILE := $(DEVICE_PATH)/modules.blocklist.vendor_boot
BOARD_VENDOR_RAMDISK_RECOVERY_KERNEL_MODULES_LOAD := $(strip $(shell cat $(DEVICE_PATH)/modules.load.recovery))
BOARD_RECOVERY_KERNEL_MODULES_LOAD := $(strip $(shell cat $(DEVICE_PATH)/modules.load.recovery))
BOOT_KERNEL_MODULES := $(strip $(shell cat $(DEVICE_PATH)/modules.load.recovery $(DEVICE_PATH)/modules.include.vendor_ramdisk))
BOARD_RECOVERY_RAMDISK_KERNEL_MODULES_LOAD := $(strip $(shell cat $(DEVICE_PATH)/modules.load.recovery))
RECOVERY_KERNEL_MODULES := $(BOARD_RECOVERY_RAMDISK_KERNEL_MODULES_LOAD)

TARGET_KERNEL_EXT_MODULES := \
  qcom/opensource/mmrm-driver \
  qcom/opensource/mm-drivers/hw_fence \
  qcom/opensource/mm-drivers/msm_ext_display \
  qcom/opensource/mm-drivers/sync_fence \
  qcom/opensource/audio-kernel \
  qcom/opensource/camera-kernel \
  qcom/opensource/dataipa/drivers/platform/msm \
  qcom/opensource/datarmnet/core \
  qcom/opensource/datarmnet-ext/aps \
  qcom/opensource/datarmnet-ext/offload \
  qcom/opensource/datarmnet-ext/shs \
  qcom/opensource/datarmnet-ext/perf \
  qcom/opensource/datarmnet-ext/perf_tether \
  qcom/opensource/datarmnet-ext/sch \
  qcom/opensource/datarmnet-ext/wlan \
  qcom/opensource/securemsm-kernel \
  qcom/opensource/display-drivers/msm \
  qcom/opensource/eva-kernel \
  qcom/opensource/video-driver \
  qcom/opensource/graphics-kernel \
  qcom/opensource/wlan/platform \
  qcom/opensource/wlan/qcacld-3.0/.qca6490 \
  qcom/opensource/bt-kernel

# Halium boot arguments. The common tree already supplies the q5q USB,
# firmware, boot-header-v4, init_boot, vendor_boot and partition settings.
BOARD_KERNEL_CMDLINE += \
    console=tty0 \
    androidboot.selinux=permissive \
    androidboot.veritymode=disabled \
    androidboot.halium=1

# Halium supplies its own ramdisk. Keep AVB disabled only on this branch.
BOARD_AVB_ENABLE := false
BOARD_USES_GENERIC_KERNEL_IMAGE := false
BOARD_INCLUDE_RECOVERY_DTBO := false
BOARD_MOVE_GSI_AVB_KEYS_TO_VENDOR_BOOT := false
PRODUCT_SUPPORTS_VERITY := false
PRODUCT_SUPPORTS_VERITY_FEC := false

# Recovery remains available as a separate build target.
TARGET_RECOVERY_DEFAULT_ROTATION := ROTATION_LEFT
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 109576192

# Treble/vendor compatibility
PRODUCT_FULL_TREBLE_OVERRIDE := true
BOARD_VNDK_VERSION := current

# Properties
TARGET_VENDOR_PROP += $(DEVICE_PATH)/vendor.prop
