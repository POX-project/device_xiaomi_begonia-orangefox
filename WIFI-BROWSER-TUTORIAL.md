# How to use WiFi and the FoxWeb dashboard in OrangeFox on begonia

The `wifi-browser` branch of the begonia device tree adds two things to OrangeFox recovery: a working MediaTek WiFi stack and **FoxWeb**, a small browser dashboard served by the recovery itself. It also ships `wget` and `curl`, so you can download files without leaving recovery. You can join a network from the recovery terminal, then scan, connect, disconnect and reboot from any browser on the same LAN — or over USB with `adb forward`.

This guide covers the terminal commands, the dashboard, the USB fallback, security notes and the usual failure modes.

> **Applies to:** Redmi Note 8 Pro (begonia), OrangeFox 12.1, device tree branch `wifi-browser` (commit `5972561` or later). Builds from `unified` do not include WiFi or FoxWeb.

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
- Show the WiFi and FoxWeb logs.
- Reboot to recovery, system or bootloader.

Scanning and status are read-only. **Connect, disconnect, WiFi on/off, forget and reboot require the access token.** The reboot buttons use `sys.powerctl`, so the device leaves recovery immediately.

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

# USB access
adb forward tcp:8080 tcp:8080
# open http://localhost:8080/
```

## Limits

- `wmt_loader`, `wmt_launcher` and `wlan_assistant` are stock MediaTek binaries linked against bionic; they need the recovery ramdisk's `libc++`, `liblog`, `libcutils` and `libnl`. A different firmware version may refuse to run.
- `wlan_assistant` needs the `nvdata` calibration partition. Without it the MAC may be unset, although association can still succeed.
- FoxWeb is HTTP-only and intended for a trusted local network.
- WiFi and FoxWeb are additive: they do not patch OrangeFox itself. Everything ships in the device tree.

## Source

- [Device tree (wifi-browser branch)](https://github.com/methylphetamine/device_xiaomi_begonia-orangefox/tree/wifi-browser)
- [CI builder](https://github.com/methylphetamine/orangefox-begonia-build/tree/wifi-browser)
- [Usage notes and limits](https://github.com/methylphetamine/device_xiaomi_begonia-orangefox/blob/wifi-browser/README.md)
