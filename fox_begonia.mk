#
# OrangeFox-specific settings for begonia.
# This file is picked up by twrp_begonia.mk via inherit-product-if-exists,
# so plain TWRP/SHRP builds of this tree are unaffected.
#

# Encryption / MIUI
OF_DONT_PATCH_ENCRYPTED_DEVICE := 1
OF_NO_MIUI_PATCH_WARNING := 1
OF_NO_TREBLE_COMPATIBILITY_CHECK := 1
OF_UNBIND_SDCARD_F2FS := 1
OF_PATCH_AVB20 := 1

# Tools and backup behaviour
OF_ENABLE_LPTOOLS := 1
OF_ENABLE_ALL_PARTITION_TOOLS := 1
OF_USE_DMCTL := 1
OF_QUICK_BACKUP_LIST := /boot;/data;
OF_ENABLE_FRP_ADDON := 1

# Display
OF_SCREEN_H := 2340
OF_STATUS_H := 100
OF_STATUS_INDENT_LEFT := 48
OF_STATUS_INDENT_RIGHT := 48
OF_HIDE_NOTCH := 1
OF_CLOCK_POS := 1
OF_OPTIONS_LIST_NUM := 9

# Keep the ramdisk within the 64 MB recovery partition.
OF_USE_LZMA_COMPRESSION := 1
OF_SPLASH_MAX_SIZE := 130

# Use magiskboot for boot/recovery patching.
OF_USE_MAGISKBOOT := 1
OF_USE_MAGISKBOOT_FOR_ALL_PATCHES := 1
