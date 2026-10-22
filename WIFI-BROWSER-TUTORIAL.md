# How to use WiFi and the FoxWeb dashboard in OrangeFox on begonia

The `wifi-browser` branch of the begonia device tree adds a working MediaTek WiFi stack, **FoxWeb** (a browser dashboard served by the recovery itself), a file/backup browser and wireless ADB. It also ships `wget` and `curl`, so you can download files without leaving recovery. You can join a network from the recovery terminal, then scan, connect, browse files, enable ADB over WiFi and reboot from any browser on the same LAN — or over USB with `adb forward`.

This guide covers the terminal commands, the dashboard, the file manager, the USB fallback, wireless ADB, security notes and the usual failure modes.

> **Applies to:** Redmi Note 8 Pro (begonia), OrangeFox 12.1, device tree branch `wifi-browser` (current tip). Builds from `unified` do not include WiFi, FoxWeb or wireless ADB.

## Before you start

- Boot a `wifi-browser` recovery image. The `orangefox-r12.0-begonia` release asset was built before the gzip-ramdisk fix, and its [release notes](https://github.com/methylphetamine/orangefox-begonia-build/releases/tag/orangefox-r12.0-begonia) warn that it black-screens on begonia. Check whether the asset has been replaced; if not, use the latest successful [OrangeFox build (begonia)](https://github.com/methylphetamine/orangefox-begonia-build/actions/workflows/build.yml) run on the `wifi-browser` branch (Actions → Artifacts) or build it yourself.
- Have the WiFi SSID and password ready. 2.4 GHz and 5 GHz networks both work.
- Put the phone and the browser device on the same network, or use the USB method below.
- Open a shell: OrangeFox menu → **Terminal**, or `adb shell` from a computer. Commands run as root.

At boot, init starts `foxwifi` and `foxweb`. `foxwifi` waits 10 seconds, then auto-joins a saved network if one exists. With no saved network it still brings the WiFi stack up and keeps it ready, but does not join anything, so first-time setup is manual.

## Part 1 — Join WiFi from the recovery terminal

Check the current state:

```sh
foxwifi status
```

If it says `State : off (WMT/WiFi not initialised)`, start the stack:

```sh
foxwifi on
```

This loads the MediaTek WMT firmware, starts `wpa_supplicant` and creates `wlan0`. Then scan:

```sh
foxwifi scan
```

The output is one line per network: signal in dBm, security type, then SSID. A full scan takes about five seconds.

Connect to a WPA2 network:

```sh
foxwifi connect "MyNetwork" "my-password" WPA2
```

Other security types:

```sh
foxwifi connect "MyNetwork" "my-password" WPA3
foxwifi connect "Cafe" "" OPEN
```

Hidden networks use the same command; `scan_ssid` is set automatically. SSIDs and passwords cannot contain double quotes, backslashes or newlines. SSIDs are limited to 32 bytes and passwords to 64 bytes.

`connect` waits up to 30 seconds for association, then up to 15 seconds for a DHCP lease. It tries `dhcpcd` first and falls back to BusyBox `udhcpc` when `/data` is encrypted or unavailable. On success it prints `connected to "MyNetwork" - IP 192.168.1.23`.

Verify the link:

```sh
foxwifi status
```

You get the interface state, SSID, IP address, MAC address and DHCP state.

### Remember the network

```sh
foxwifi save
```

This writes `/sdcard/Fox/wifi.conf` with mode `0600`. The file is **plaintext**, so treat it like a password. On the next boot the `foxwifi` daemon reconnects automatically after about 10 seconds. You can also trigger it manually:

```sh
foxwifi auto
```

Remove the saved network with:

```sh
foxwifi forget
```

### Other terminal commands

```sh
foxwifi off       # stop DHCP and wpa_supplicant, link down
foxwifi restart   # full bring-up again
foxwifi log       # recent lines from /tmp/foxwifi.log
```

### Download files with wget and curl

The image includes BusyBox `wget` and a real `curl`:

```sh
wget https://example.com/file.zip
curl -LO https://example.com/file.zip
curl -fsSL https://example.com/install.sh -o /tmp/install.sh
```

Downloads land in the current directory, so use `/tmp` or `/sdcard` when you need a known path. `curl` validates HTTPS against the bundled Mozilla CA file (`CURL_CA_BUNDLE=/system/etc/security/cacert.pem`, exported by init). If the variable is missing in your shell, add `--cacert /system/etc/security/cacert.pem`. BusyBox `wget` goes through `ssl_client`, which does **not** validate certificates in this build — prefer `curl` for HTTPS.

`curl` is built from `external/curl`; the `wifi-browser` CI workflow clones that project before building because the minimal manifest removes it.

## Part 2 — Open the FoxWeb dashboard

`foxweb` runs as an init service and serves the dashboard on TCP port 8080. Get the address and token:

```sh
foxweb status
```

The output looks like this:

```text
FoxWeb    : running on port 8080
URL       : http://192.168.1.23:8080/
One-click : http://192.168.1.23:8080/#token=...
Token     : 9f3c...
USB       : adb forward tcp:8080 tcp:8080, then http://localhost:8080/
```

Open the **One-click** URL. The `#token=...` fragment is imported into the browser's local storage and removed from the address bar. The fragment itself is never sent to the server; the dashboard sends the token in the `X-Fox-Token` header when you perform an action.

If you open the plain URL instead, the dashboard still loads, but actions that change state will ask for the token. Run `foxweb token` and paste the value into the token dialog. A `401 Unauthorized` response means the token is missing or wrong; open the one-click URL again or re-enter the token.

### What the dashboard can do

- Show link state, SSID, IP address and MAC address, refreshed every seven seconds.
- Scan for nearby networks and join WPA, WPA2, WPA3 or open networks.
- Join a hidden network from the manual form.
- Turn WiFi on or off, disconnect, and forget the saved network.
- Optionally remember a network on `/sdcard` (writes the same plaintext `wifi.conf`).
- Browse `/sdcard` and `/tmp`, download and upload files, calculate SHA-256, and create, rename or delete items.
- Enable or disable ADB over WiFi and show QR codes for the FoxWeb dashboard and the `adb connect` command.
- Show the WiFi and FoxWeb logs.
- Reboot to recovery, system or bootloader.

Scanning and status are read-only. **Connect, disconnect, WiFi on/off, forget, reboot, every file/directory operation and every file read (listing, download or SHA-256) require the access token.** The reboot buttons use `sys.powerctl`, so the device leaves recovery immediately.

### USB fallback (no WiFi needed)

The dashboard is also reachable over the recovery ADB interface:

```sh
adb forward tcp:8080 tcp:8080
```

Then open `http://localhost:8080/` in a browser. You still need the token for actions; use `foxweb token`, or build the one-click URL manually:

```text
http://localhost:8080/#token=YOUR_TOKEN
```

This works even when `wlan0` has no IP address.

### Files and backups

The **Files & backups** card is a two-root file manager. It only exposes the recovery's writable storage:

- **Internal storage** opens `/sdcard`. The dashboard keeps the friendly `/sdcard` path even when the kernel resolves it to `/data/media/0`.
- **TWRP backups** opens `/sdcard/TWRP/BACKUPS`.
- **Fox folder** opens `/sdcard/Fox`.
- **/tmp** opens the RAM-backed temporary directory.

If your recovery stores backups somewhere else, open `/sdcard` and navigate to the folder it uses. The shortcut buttons are only starting points; the **Up** button and breadcrumb trail walk back to `/sdcard` or `/tmp`.

What you can do:

- Open folders and download files.
- Upload one or more files to the current folder. Uploads are sent as raw request bodies, so a large backup is not buffered in the recovery shell. The limit is **8 GiB per file**; the browser asks before replacing an existing name.
- Calculate a file's SHA-256 on demand. This is useful for checking a downloaded backup, but large files take time.
- Create a folder, rename a file or folder, or delete an item. Deleting a folder removes everything inside it and cannot be undone.

File listings, downloads and hashes are token-protected too. A generated download link carries the token in its query string; avoid sharing that link. Uploads, renames, folder creation and deletion use the token in the request header.

`/tmp` is cleared on reboot. `/sdcard` persists, but its contents may be unavailable until `/data` is decrypted and mounted.

### Wireless ADB and QR codes

The **ADB over WiFi** card controls adbd's TCP listener on port **5555**. The terminal equivalents are:

```sh
foxadb on          # set service.adb.tcp.port=5555 and restart adbd
foxadb status      # state, IP address and adb connect command
foxadb url         # print only the adb connect command
foxadb off         # clear the TCP port and restart adbd
foxadb log         # recent lines from /tmp/foxadb.log
```

Once WiFi has an IPv4 address, connect from a computer on the same network:

```sh
adb connect 192.168.1.23:5555
adb devices
```

USB ADB is independent and keeps working, so a USB cable is still the fallback. Wireless ADB uses the recovery's existing ADB authorization keys: if the computer is already trusted over USB, `adb connect` normally works without a new prompt. If `adb devices` shows `unauthorized`, connect over USB first and authorize the computer.

The ADB QR code contains the complete `adb connect <ip>:5555` text. A generic phone camera will display that text so you can copy it; an ADB-capable client can use it directly. The FoxWeb QR code contains the dashboard URL and, when a token is stored, the `#token=...` fragment. Anyone who scans the FoxWeb code gets token access, so treat the screen as sensitive. Both QR images are generated offline in the browser; no QR service is contacted.

Wireless ADB does not encrypt its transport. Enable it only on a trusted local network and run `foxadb off` when you are done.

### Token management

```sh
foxweb token                # print the current token
foxweb set-token "new-one"  # change it and restart the server
foxweb restart              # restart httpd
foxweb log                  # recent lines from /tmp/foxweb.log
```

If the token file disappears, the CGI helpers fail closed and reject every mutation until a new token is generated (restart `foxweb` or run `foxweb token`).

## Security notes

- FoxWeb is **HTTP only**. Do not expose port 8080 to the internet or to an untrusted network.
- The token stops casual access, but it travels in plaintext over HTTP. On a shared or public network, use the USB forward instead.
- Generated download links put the token in the URL query string. Do not paste them into chat, issue trackers or browser sync.
- File operations are confined to `/sdcard` and `/tmp`, but deleting a folder is recursive and permanent.
- Wireless ADB on port 5555 is unencrypted and uses the computer's existing ADB key. Enable it only on a trusted network and disable it with `foxadb off` when finished.
- `/sdcard/Fox/wifi.conf` stores the SSID, password and security type in plaintext.
- Run `foxwifi forget` and `foxwifi off` when you are done, especially on someone else's network.
- The dashboard is not a replacement for the recovery UI; it is a convenience for headless or touch-broken devices.

## Troubleshooting

### `wlan0 did not appear (WMT firmware load failed?)`

The MediaTek connectivity co-processor did not boot. Run `foxwifi log` and check `/tmp/foxwifi.log`. Try `foxwifi restart` once. The `wmt_loader`, `wmt_launcher` and `wlan_assistant` binaries are stock MediaTek programs; a firmware/kernel mismatch can make them fail. Capture the log before changing the firmware set.

### `foxwifi scan` shows no networks

Confirm WiFi is up with `foxwifi status`. Scans take about five seconds; run the command again after a pause. If the interface is up but the list stays empty, move closer to the access point and check that the network is not 6 GHz-only (the stock driver is 2.4/5 GHz).

### `association failed (state=...)`

Usually a wrong password or the wrong security type. Try `WPA2` explicitly for WPA2/WPA2-PSK networks and `WPA3` only when the access point advertises SAE. Hidden networks are supported, but the SSID must match exactly. Check `foxwifi log` for the `wpa_cli` response.

### `no DHCP lease on wlan0`

Association succeeded but the router did not hand out an address. Check the router's DHCP pool, then run `foxwifi restart`. When `/data` is encrypted, `dhcpcd` cannot write its lease file; the script falls back to `udhcpc` automatically. `foxwifi status` shows whether DHCP is running.

### MAC address is blank or all zeros

`wlan_assistant` reads calibration data from `/mnt/vendor/nvdata/APCFG/APRDEB`. If the `nvdata` partition is missing or unreadable, the MAC may stay unset. Association can still work. Check the mount with `mount | grep nvdata` and the log with `foxwifi log`.

### The dashboard does not load over WiFi

Use the exact IP printed by `foxwifi status` or `foxweb status`, and include port `8080`. Make sure the browser device is on the same subnet and that the access point is not using client isolation. If it still fails, use the USB forward — it bypasses the network entirely.

### The dashboard loads but every action returns 401

Open the one-click URL, or paste `foxweb token` into the token dialog. If `foxweb token` prints nothing, the token file is missing; the server fails closed by design. Restart it with `foxweb restart`, then reload the page.

### The file browser says the path is outside `/sdcard` and `/tmp`

The manager resolves symlinks before allowing access, so a path that escapes either root is rejected. Use the **Internal storage** and **/tmp** shortcuts, or navigate from them. If `/sdcard` is empty or missing, decrypt/mount `/data` first. The manager never exposes `/data`, `/system`, `/vendor` or raw block devices.

### Uploads fail with 411, 413 or 507

- `411 Length Required`: the request did not include a usable `Content-Length`. Retry with a current browser; the upload endpoint deliberately refuses an unknown size.
- `413 Request Entity Too Large`: the file is larger than 8 GiB.
- `507 Insufficient Storage`: the target filesystem does not have enough free space after the recovery's headroom. Free space and retry.

If an upload stops early, the partial `.foxupload.*` file is removed and the destination is not replaced.

### `adb connect` is refused or times out

Run `foxadb status` and confirm the port is enabled and the shown IP belongs to `wlan0`. The computer and phone must be on the same network and the access point must not use client isolation. If the address changed, use the new one. A stale local ADB server can be reset with `adb kill-server`, then `adb connect <ip>:5555` again. If `adb devices` says `unauthorized`, authorize the computer over USB first.

### `foxweb: /system/bin/busybox is missing`

The build did not include the static BusyBox. Rebuild from the `wifi-browser` branch and check that `/system/bin/busybox` exists in the ramdisk. Without it, `httpd`, the DHCP fallback and several helpers cannot run.

## Quick reference

```sh
# WiFi
foxwifi on
foxwifi scan
foxwifi connect "SSID" "PASSWORD" WPA2
foxwifi status
foxwifi save
foxwifi auto
foxwifi forget
foxwifi off
foxwifi restart
foxwifi log

# Download tools
wget https://example.com/file.zip
curl -LO https://example.com/file.zip
curl --cacert /system/etc/security/cacert.pem -LO https://example.com/file.zip

# Dashboard
foxweb status
foxweb token
foxweb set-token "new-token"
foxweb restart
foxweb log

# Wireless ADB
foxadb on
foxadb status
foxadb url
foxadb off
foxadb log

# USB access
adb forward tcp:8080 tcp:8080
# open http://localhost:8080/
adb connect <phone-ip>:5555
```

## Limits

- `wmt_loader`, `wmt_launcher` and `wlan_assistant` are stock MediaTek binaries linked against bionic; they need the recovery ramdisk's `libc++`, `liblog`, `libcutils` and `libnl`. A different firmware version may refuse to run.
- `wlan_assistant` needs the `nvdata` calibration partition. Without it the MAC may be unset, although association can still succeed.
- The file manager is limited to `/sdcard` and `/tmp`. Uploads are capped at 8 GiB per file and deletion is recursive.
- Wireless ADB listens on TCP 5555 without transport encryption and relies on the existing ADB authorization keys. Disable it when not needed.
- FoxWeb is HTTP-only and intended for a trusted local network.
- WiFi, FoxWeb and wireless ADB are additive: they do not patch OrangeFox itself. Everything ships in the device tree.

## Source

- [Device tree (wifi-browser branch)](https://github.com/methylphetamine/device_xiaomi_begonia-orangefox/tree/wifi-browser)
- [CI builder](https://github.com/methylphetamine/orangefox-begonia-build/tree/wifi-browser)
- [Usage notes and limits](https://github.com/methylphetamine/device_xiaomi_begonia-orangefox/blob/wifi-browser/README.md)
