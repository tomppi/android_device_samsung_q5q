#
# Development-only Lineage Recovery product for q5q second-kernel testing.
#
# Normal Android boot remains unchanged. This product exists only to build a
# recovery image whose kernel requests kexec and whose ramdisk contains the
# guarded q5q launcher.
#

$(call inherit-product, device/samsung/q5q/lineage_q5q.mk)

PRODUCT_NAME := lineage_q5q_kexec

# Android.bp declares an explicit namespace in this device tree. Export it to
# the Make product namespace so PRODUCT_PACKAGES can resolve the recovery-only
# launcher modules below.
PRODUCT_SOONG_NAMESPACES += device/samsung/q5q

PRODUCT_PACKAGES += \
    q5q-linux-boot-safe \
    q5q-linux-boot-backend
