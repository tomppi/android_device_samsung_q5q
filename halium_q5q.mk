# Minimal Halium 15 product for Samsung Galaxy Z Fold5 (q5q / SM-F946B).
# This target is for early hybris-boot and Droidian bring-up, not a full ROM.

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

# Keep the first image deliberately small. Android vendor-container and UI
# integration will be added after kernel + USB-network shell bring-up works.
