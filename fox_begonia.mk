#
# OrangeFox-specific settings for begonia.
# This file is picked up by twrp_begonia.mk via inherit-product-if-exists,
# so plain TWRP/SHRP builds of this tree are unaffected.
#

# Build metadata shown in recovery (About / build info).
OF_MAINTAINER := A X

# Encryption / MIUI
OF_DONT_PATCH_ENCRYPTED_DEVICE := 1
OF_NO_MIUI_PATCH_WARNING := 1
OF_NO_TREBLE_COMPATIBILITY_CHECK := 1
OF_UNBIND_SDCARD_F2FS := 1
OF_PATCH_AVB20 := 1
# Let TWRP read the installed ROM's vendor fstab for /data and /metadata.
# That fstab describes the crypto layout that actually encrypted this ROM's
# data (FBE v1, FBE v2, metadata encryption, wrapped keys, ...), while the
# recovery.fstab lines are only a fallback when no vendor fstab is found.
#
# Do not set OF_FORCE_USE_RECOVERY_FSTAB / TW_SKIP_ADDITIONAL_FSTAB here:
# doing so forces one hard-coded policy version and breaks the other ROMs.
# The recovery also patches vold to prefer /etc/additional.fstab and to
# sanity-check the actual policy on /data/misc.
# The vendor tree provides keymaster 4.0 (beanpod).  This is only the
# fallback: OrangeFox still uses the installed ROM's version when it can
# detect one.
OF_DEFAULT_KEYMASTER_VERSION := 4.0
# This recovery only ships the keymaster 4.0 service, so do not let a
# ROM-provided 4.1/3.0 prop select a service that does not exist here.
TW_FORCE_KEYMASTER_VER := true
# Begonia ROMs often leave metadata unmounted until vold is ready.
OF_FBE_METADATA_MOUNT_IGNORE := 1
# TW_PREPARE_DATA_MEDIA_EARLY is already enabled in BoardConfig.mk.
OF_FIX_DECRYPTION_ON_DATA_MEDIA := 1

# Tools and backup behaviour
OF_ENABLE_LPTOOLS := 1
OF_ENABLE_ALL_PARTITION_TOOLS := 1
OF_USE_DMCTL := 1
OF_QUICK_BACKUP_LIST := /boot;/data;
OF_ENABLE_FRP_ADDON := 1
# OrangeFox appends /brightness and /max_brightness to OF_FL_PATH1, so it must
# be the torch LED *directory*, not a script.  The MT6360 driver registers
# three classdevs: torch-light0 (CH1), torch-light1 (CH2) and torch-light2
# (both channels).
#
# Only torch-light2 actually powers the LED: in this kernel's
# flashlights-mt6360-mt6785.c the single-channel brightness_set
# (torch-light0/1) calls flashlight_set_torch_brightness() and sets
# mt6360_en_ch*, but leaves mt6360_enable() commented out, so the
# channel is never put into TORCH mode.  torch2_brightness_set is the only
# path that calls mt6360_enable(), so it is the only one that lights up.
# begonia wires its flash LED to CH1; torch-light2 enables both channels
# (CH2 is unwired, so the extra channel is harmless).
#
# Leave OF_FL_PATH2 unset: with both paths set, OrangeFox writes the
# second one last, and the two channels disable each other.
OF_FL_PATH1 := /sys/class/leds/torch-light2
OF_DISABLE_OTA_MENU := 1
OF_USE_LEGACY_BATTERY_SERVICES := 1
OF_USE_GREEN_LED := 0

# Display
OF_SCREEN_H := 2340
OF_STATUS_H := 80
OF_STATUS_INDENT_LEFT := 64
OF_STATUS_INDENT_RIGHT := 48
OF_HIDE_NOTCH := 1
OF_CLOCK_POS := 1
OF_OPTIONS_LIST_NUM := 12

# Keep log history only for non-stable builds.
ifeq ($(FOX_BUILD_TYPE),Stable)
  OF_DONT_KEEP_LOG_HISTORY := 1
endif

# The prebuilt begonia kernel only has CONFIG_RD_GZIP=y. Its initramfs
# decompressor has no LZMA/LZ4/XZ support, so an LZMA-compressed OrangeFox
# ramdisk makes the bootloader hand the kernel an image it cannot unpack
# (black screen / recovery bootloop). Keep the default gzip ramdisk.
# OF_USE_LZMA_COMPRESSION := 1
OF_SPLASH_MAX_SIZE := 130

# Use magiskboot for boot/recovery patching.
OF_USE_MAGISKBOOT := 1
OF_USE_MAGISKBOOT_FOR_ALL_PATCHES := 1
