#
# Development-only Lineage Recovery product for q5q second-kernel testing.
#
# Normal Android boot remains unchanged. This product exists only to build a
# recovery image whose kernel requests kexec and whose ramdisk contains the
# guarded q5q launcher.
#

$(call inherit-product, device/samsung/q5q/lineage_q5q.mk)

PRODUCT_NAME := lineage_q5q_kexec

PRODUCT_COPY_FILES += \
    device/samsung/q5q/recovery/q5q-linux-boot.sh:$(TARGET_COPY_OUT_RECOVERY)/system/bin/q5q-linux-boot

PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.q5q.kexec_recovery=1
