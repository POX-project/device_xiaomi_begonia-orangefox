#
# Copyright (C) 2022 The Android Open Source Project
# Copyright (C) 2022 SebaUbuntu's TWRP device tree generator
#
# SPDX-License-Identifier: Apache-2.0
#

# Soong namespaces
PRODUCT_SOONG_NAMESPACES += \
    $(LOCAL_PATH)

# Unified partitions: enable the dynamic (super/logical) path alongside the
# legacy physical layout. This only drives image building - which layout is
# actually mounted is decided at runtime by the fstab in
# recovery/root/system/etc/recovery.fstab.
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# API
PRODUCT_SHIPPING_API_LEVEL := 29

# HACK: Set vendor patch level
PRODUCT_PROPERTY_OVERRIDES += \
    ro.vendor.build.security_patch=2099-12-31 \
    ro.bootimage.build.date.utc=0 \
    ro.build.date.utc=0

# Additional target Libraries
TARGET_RECOVERY_DEVICE_MODULES += \
    libkeymaster4 \
    libpuresoftkeymasterdevice

TW_RECOVERY_ADDITIONAL_RELINK_LIBRARY_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libkeymaster4.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/libpuresoftkeymasterdevice.so

PRODUCT_PACKAGES += \
    libshim_beanpod

# Health HAL (needed by the decryption bring-up)
PRODUCT_PACKAGES += \
    android.hardware.health@2.1-impl \
    android.hardware.health@2.1-service

# fastbootd is required to flash/erase logical partitions on dynamic devices
PRODUCT_PACKAGES += \
    fastbootd

# Recovery WiFi.
#
# The begonia kernel has the MediaTek WMT/WLAN stack built in, but recovery
# needs the userspace half: wpa_supplicant, wpa_cli, the MediaTek firmware
# loader and a DHCP client.  The firmware loader, dhcpcd, BusyBox and the
# dashboard live in recovery/root and are packed into the ramdisk; only
# wpa_supplicant/wpa_cli are built from source (external/wpa_supplicant_8).
#
# CONFIG_CTRL_IFACE_HIDL is disabled for recovery by the builder workflow so
# wpa_cli can talk to the daemon over the unix control socket.
PRODUCT_PACKAGES += \
    wpa_supplicant \
    wpa_cli

TARGET_RECOVERY_DEVICE_MODULES += \
    wpa_supplicant \
    wpa_cli

TW_RECOVERY_ADDITIONAL_RELINK_BINARY_FILES += \
    $(TARGET_OUT_VENDOR_EXECUTABLES)/hw/wpa_supplicant \
    $(TARGET_OUT_VENDOR_EXECUTABLES)/wpa_cli

TW_RECOVERY_ADDITIONAL_RELINK_LIBRARY_FILES += \
    $(TARGET_OUT_VENDOR_SHARED_LIBRARIES)/libkeystore-wifi-hidl.so \
    $(TARGET_OUT_VENDOR_SHARED_LIBRARIES)/libkeystore-engine-wifi-hidl.so \
    $(TARGET_OUT_VENDOR_SHARED_LIBRARIES)/libnl.so \
    $(TARGET_OUT_VENDOR_SHARED_LIBRARIES)/libssl.so

# curl for downloading files from recovery.
#
# external/curl is removed by the minimal TWRP manifest, so the builder clones
# it before lunch.  Keep this conditional: a tree built without that source
# (or the plain unified branch) still builds, just without curl.
#
# wget is already a BusyBox applet; recovery/root/system/bin/wget exposes it.
ifneq ($(wildcard external/curl/Android.bp),)
TARGET_RECOVERY_DEVICE_MODULES += \
    curl

TW_RECOVERY_ADDITIONAL_RELINK_BINARY_FILES += \
    $(TARGET_OUT_EXECUTABLES)/curl

# curl is linked against BoringSSL and zlib.  libssl.so is already relinked
# above for wpa_supplicant; pull in its runtime companions explicitly.
TW_RECOVERY_ADDITIONAL_RELINK_LIBRARY_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libcrypto.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/libz.so
endif
