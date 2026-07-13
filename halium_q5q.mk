# Downstream Halium 15 kernel product for Samsung Galaxy Z Fold5
# (q5q / SM-F946B).
#
# This target is not a flashable ROM or recovery image. It exists to build the
# q5q downstream kernel, matching modules, DTB and DTBO artifacts with
# q5q_defconfig + q5q_halium.fragment. q5q-halium-port packages those artifacts
# with a Droidian initramfs as a direct recovery-partition boot image.

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/base.mk)

PRODUCT_NAME := halium_q5q
PRODUCT_DEVICE := q5q
PRODUCT_BRAND := samsung
PRODUCT_MODEL := SM-F946B
PRODUCT_MANUFACTURER := Samsung

PRODUCT_USE_DYNAMIC_PARTITIONS := true
PRODUCT_FULL_TREBLE_OVERRIDE := true

PRODUCT_SOONG_NAMESPACES += \
    device/samsung/q5q

PRODUCT_PACKAGES += \
    init.halium.q5q.rc

# Android-container and UI integration are added only after the direct recovery
# kernel, initramfs, exact module tree and USB/SSH bring-up have been validated.
