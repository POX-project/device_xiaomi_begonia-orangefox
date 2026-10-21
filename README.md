Device configuration for Redmi Note 8 Pro (begonia)
===================================================

The Redmi Note 8 Pro (codenamed _"begonia"_) is a high-end, mid-range smartphone from Xiaomi.
It was released in September 2019.

| Basic                   | Spec Sheet                                                                                                                     |
| -----------------------:|:------------------------------------------------------------------------------------------------------------------------------ |
| CPU                     | Octa-core                                                                                                                      |
| Chipset                 | Mediatek Helio G90T                                                                                                            |
| GPU                     | Mali-G76 MC4                                                                                                                   |
| Memory                  | 6/8 GB RAM                                                                                                                     |
| Shipped Android Version | 9.0                                                                                                                            |
| Storage                 | 64/128/256 GB                                                                                                                  |
| Battery                 | Non-removable Li-Po 4500 mAh battery                                                                                           |
| Display                 | 1080 x 2340 pixels, 19.5:9 ratio (~395 ppi density)                                                                            |
| Camera (Rear - Main)    | 64 MP, f/1.9, 26mm (wide), 1/1.7", 0.8µm, PDAF                                                                                 |
| Camera (Front)          | 20 MP, f/2.0, 0.9µm                                                                                                            |

# Status
Current state of features (from [here](https://twrp.me/faq/OfficialMaintainer.html)):

### Blocking checks
- [x] Correct screen/recovery size
- [x] Working Touch, screen
- [x] Backup to internal/microSD
- [x] Restore from internal/microSD
- [x] reboot to system
- [x] ADB

### Medium checks
- [x] update.zip sideload
- [x] UI colors (red/blue inversions)
- [x] Screen goes off and on
- [x] F2FS/EXT4 Support, exFAT/NTFS where supported
- [x] all important partitions listed in mount/backup lists
- [x] backup/restore to/from external (USB-OTG) storage (not supported by the device)
- [x] backup/restore to/from adb (https://gerrit.omnirom.org/#/c/15943/)
- [x] decrypt /data
- [x] Correct date

### Minor checks
- [x] MTP export
- [x] reboot to bootloader
- [x] reboot to recovery
- [x] poweroff
- [x] battery level
- [x] temperature
- [x] encrypted backups
- [x] input devices via USB (USB-OTG) - keyboard, mouse and disks (not supported by the device)
- [x] USB mass storage export
- [x] set brightness
- [x] vibrate
- [x] screenshot
- [x] partition SD card

# Building (TWRP)
```bash
repo init -u https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp.git -b twrp-12.1 --depth=1
# put this tree at device/xiaomi/begonia
export ALLOW_MISSING_DEPENDENCIES=true
source build/envsetup.sh
lunch twrp_begonia-eng
mka recoveryimage -j$(nproc --all)
```

`twrp_begonia.mk` inherits `vendor/twrp/config/common.mk`. The
`pb_begonia.mk` product is kept for PBRP builds.

**Copyright (C) 2022 Team Win Recovery Project**


## Branches

| Branch | Layout | Notes |
| --- | --- | --- |
| `twrp-12.1` | physical (non-dynamic) | ext4 system/vendor, ext4+f2fs /data. Baseline TWRP tree. |
| `unified` | **both** | see below. |
### `unified`

One recovery that boots on both a stock (non-dynamic) begonia and a
repartitioned (dynamic / `super`) one, mounting whichever filesystem the ROM
shipped (erofs or ext4; /data is ext4/f2fs).

- `recovery/root/system/etc/recovery.fstab` carries two sets of entries:
  - `logical` entries for `system`, `system_ext`, `product`, `vendor`, `odm`
    (dynamic layout). Each is an explicit `erofs` + `ext4` pair. TWRP discards
    a `logical` entry when `Prepare_Super_Volume()` fails, i.e. when the device
    has no `super` partition, so these are inert on non-dynamic devices.
  - physical `by-name` entries for `system` and `vendor` (non-dynamic layout) -
    also explicit `erofs` + `ext4` pairs, and the only ones left in the list
    once the logical entries are dropped.
  - entries are ordered logical-first because `Find_Partition_By_Path()`
    returns the first match.
  - TWRP probes the actual filesystem with libblkid; the matching entry's
    flags are selected automatically. `/data` keeps an explicit `ext4` +
    `f2fs` pair.
- `BoardConfig.mk` keeps the physical image flags and adds the retrofitted
  A-only super configuration (`BOARD_SUPER_PARTITION_*`,
  `BOARD_XIAOMI_DYNAMIC_PARTITIONS_*`).
- `device.mk` adds `PRODUCT_USE_DYNAMIC_PARTITIONS := true`, `fastbootd`
  and the health HAL used by decryption.
- FBEv2 decryption: `TW_USE_FSCRYPT_POLICY := 2`, the FBEv2 data fstab
  flags (`inlinecrypt_optimized`, `fsverity`, `checkpoint=fs` on f2fs),
  and no early `vold` start in `init.recovery.mt6785.rc`.
- `system.prop` adds `ro.fastbootd.available=true`.
- Product branding is `Randi` / `Nut 8 Pro`; `pb_begonia.mk` is kept for PBRP builds.

Build it by pointing `local_manifests/begonia.xml` at `revision="unified"`.

EROFS support is built in: the prebuilt recovery kernel has
`CONFIG_EROFS_FS=y` / `CONFIG_EROFS_FS_ZIP=y`, libblkid probes erofs, and the
fstab carries explicit `erofs` + `ext4` pairs. The dual-entry fstab depends on
TWRP discarding unprepared `logical` entries, and decryption must be checked
against the installed ROM's FBE version.
