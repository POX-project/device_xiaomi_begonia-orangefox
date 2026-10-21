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

# Building (TWRP / OrangeFox)
```bash
repo init -u https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp.git -b twrp-12.1 --depth=1
# put this tree at device/xiaomi/begonia
export ALLOW_MISSING_DEPENDENCIES=true
source build/envsetup.sh
lunch twrp_begonia-eng
mka recoveryimage -j$(nproc --all)
```

`twrp_begonia.mk` inherits `vendor/twrp/config/common.mk` and, when present,
`fox_begonia.mk`. The `pb_begonia.mk` product is kept for PBRP builds.

## OrangeFox

The same tree builds OrangeFox from its official 12.1 sync:

```bash
# after orangefox_sync.sh has prepared the source tree
lunch twrp_begonia-eng
FOX_BUILD_DEVICE=begonia FOX_BUILD_TYPE=Unofficial mka recoveryimage -j$(nproc --all)
```

`fox_begonia.mk` carries the OrangeFox UI, LZMA, magiskboot and partition
tool settings. The CI builder lives at
`methylphetamine/orangefox-begonia-build`.

**Copyright (C) 2022 Team Win Recovery Project**


## Branches

| Branch | Layout | Notes |
| --- | --- | --- |
| `twrp-12.1` | physical (non-dynamic) | ext4 system/vendor, ext4+f2fs /data. Baseline TWRP tree. |
| `unified` | **both** | see below. |
| `wifi-browser` | **both** | `unified` + MediaTek WiFi and the FoxWeb dashboard. |
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

### `wifi-browser`

`wifi-browser` is `unified` plus recovery WiFi and a browser dashboard.  It
does not patch OrangeFox: everything is added from this device tree.

- The prebuilt kernel already has the MediaTek CONSYS/WMT/WLAN stack built in
  (`CONFIG_MTK_COMBO_WIFI=y`, `CONFIG_WLAN_DRV_BUILD_IN=y`,
  `CONFIG_MTK_COMBO_CHIP_CONSYS_6785=y`, `CONFIG_CFG80211=y`).  The tree adds
  the missing userspace pieces:
  - `wmt_loader`, `wmt_launcher`, `wlan_assistant` and the stock firmware in
    `recovery/root/system/etc/firmware` (also reachable as `/vendor/firmware`).
  - `wpa_supplicant`/`wpa_cli` built from `external/wpa_supplicant_8` with
    `BOARD_WPA_SUPPLICANT_DRIVER := NL80211`.
  - TWRP's static `dhcpcd`, with a BusyBox `udhcpc` fallback for encrypted
    devices where `/data/misc/dhcp` is unavailable.
  - A static BusyBox 1.36.1 in `/system/bin/busybox` (contains `httpd` with CGI).
  - `foxwifi`, `foxweb` and the dashboard in `recovery/root/system/etc/foxwww`.
- The builder must comment out `CONFIG_CTRL_IFACE_HIDL=y` in
  `external/wpa_supplicant_8/wpa_supplicant/android.config` before compiling,
  so `wpa_cli` uses the unix control socket.  The stock `notify.c` includes
  `hidl.h` and calls `wpas_hidl_*` unconditionally even when HIDL is disabled,
  and the header's own no-op stubs are incomplete, so the builder also drops a
  recovery-only no-op `hidl.h` into
  `external/wpa_supplicant_8/wpa_supplicant/`.  The `wifi-browser` CI branch
  does both automatically.

#### Using it

In the recovery terminal:

```sh
foxwifi on                 # load WMT firmware and start wpa_supplicant
foxwifi scan               # list nearby networks
foxwifi connect "MyNet" "password" WPA2
foxwifi status             # state, IP and MAC
foxweb status              # URL, one-click URL and access token
foxwifi save               # remember the network on /sdcard/Fox/wifi.conf
foxwifi auto               # reconnect using the remembered network
```

`foxweb` is started by init on port 8080.  Open the URL printed by
`foxweb status`; the `#token=...` fragment is imported by the dashboard so
mutating actions work without typing the token.  The token is also accepted
via the `X-Fox-Token` header and is required for connect, disconnect, WiFi
on/off, forget and reboot.

Without WiFi, the same dashboard is reachable over USB:

```sh
adb forward tcp:8080 tcp:8080
# then open http://localhost:8080/
```

The dashboard can scan, join WPA/WPA2/WPA3 and open networks, toggle WiFi,
disconnect, forget a saved network, show logs and reboot to recovery, system
or bootloader.  Credentials are only written to `/sdcard/Fox/wifi.conf` when
"Remember this network" is selected; that file is plaintext, so treat it
accordingly.

#### Limits

- `wmt_launcher`/`wmt_loader` are stock MediaTek binaries; they are linked
  against bionic and need the recovery ramdisk's `libc++`, `liblog`,
  `libcutils` and `libnl`.  If they refuse to run on a particular firmware
  version, capture `/tmp/foxwifi.log` and adjust the firmware set.
- `wlan_assistant` reads calibration from `/mnt/vendor/nvdata/APCFG/APRDEB`;
  `foxwifi` mounts `nvdata` read-only.  A missing or unreadable `nvdata`
  partition can leave the MAC unset, but association may still work.
- The dashboard is HTTP-only and intended for a trusted local network.  It is
  not a replacement for the recovery UI; use the token and disconnect WiFi
  when you are done.
