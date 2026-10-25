#!/bin/bash
# create-arorafm-zip.sh - build an "enhanced" OrangeFox installer ZIP.
#
# The official installer ZIP produced by the AOSP build already carries the
# NetSurf browser inside recovery.img.  This script derives a second,
# AromaFM-style installer from it: the same installer payload and recovery
# image, plus the NetSurf userspace files exposed under
# sdcard/Fox/FoxFiles/NetSurf/ so they are available on /sdcard once the ZIP
# has been flashed.
#
# The official update-binary/updater-script are copied verbatim, so the
# result flashes exactly like the official ZIP.  Because the archive is
# modified it is re-signed with the AOSP testkey when signapk is available.
#
# Usage:
#   tools/create-arorafm-zip.sh [official.zip]
#
# Environment:
#   OUTPUT_ZIP    destination path
#                 (default: <device dir>/OrangeFox-begonia-arorafm-enhanced-<date>.zip)
#   GITHUB_OUTPUT when set, "zip_path=<path>" is appended to it.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEVICE_DIR=$(dirname "$SCRIPT_DIR")
ANDROID_ROOT=$(cd "$DEVICE_DIR/../../.." && pwd)
PRODUCT_OUT="$ANDROID_ROOT/out/target/product/begonia"

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# --- locate the official installer ZIP -------------------------------------
OFFICIAL_ZIP=${1:-}
if [ -z "$OFFICIAL_ZIP" ]; then
    OFFICIAL_ZIP=$(find "$PRODUCT_OUT" -maxdepth 1 -type f -name 'OrangeFox*.zip' \
        ! -name '*arorafm*' 2>/dev/null | sort | head -1)
fi
[ -n "$OFFICIAL_ZIP" ] || die "no official OrangeFox ZIP found in $PRODUCT_OUT"
[ -f "$OFFICIAL_ZIP" ] || die "official ZIP not found: $OFFICIAL_ZIP"

OUTPUT_ZIP=${OUTPUT_ZIP:-"$DEVICE_DIR/OrangeFox-begonia-arorafm-enhanced-$(date +%Y%m%d).zip"}
mkdir -p "$(dirname "$OUTPUT_ZIP")"
rm -f "$OUTPUT_ZIP"

# --- validate the official ZIP ---------------------------------------------
REQUIRED_ENTRIES="
META-INF/com/google/android/update-binary
META-INF/com/google/android/updater-script
recovery.img
"
# List the archive once, to a file.  Piping unzip into "grep -q" is unsafe
# under "set -o pipefail": grep exits at the first match, unzip dies of
# SIGPIPE and the pipeline reports 141 even though the entry was found.
entries=$(mktemp)
unzip -Z1 "$OFFICIAL_ZIP" >"$entries" || die "cannot list $OFFICIAL_ZIP"
for entry in $REQUIRED_ENTRIES; do
    grep -qx "$entry" "$entries" \
        || die "official ZIP is missing $entry: $OFFICIAL_ZIP"
done
rm -f "$entries"

# --- validate the NetSurf payload ------------------------------------------
PAYLOAD="$DEVICE_DIR/recovery/root/system/etc/foxbrowse"
[ -x "$PAYLOAD/bin/netsurf-fb" ] || die "missing payload: $PAYLOAD/bin/netsurf-fb"
[ -f "$PAYLOAD/etc/start.html" ] || die "missing payload: $PAYLOAD/etc/start.html"
[ -d "$PAYLOAD/fonts" ] || die "missing payload: $PAYLOAD/fonts"
[ -d "$PAYLOAD/netsurf" ] || die "missing payload: $PAYLOAD/netsurf"

# --- stage the official ZIP and add the NetSurf files ----------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
unsigned="$work/unsigned.zip"
mkdir -p "$stage"

log "staging $OFFICIAL_ZIP"
unzip -q "$OFFICIAL_ZIP" -d "$stage"

foxfiles="$stage/sdcard/Fox/FoxFiles/NetSurf"
mkdir -p "$foxfiles/bin" "$foxfiles/etc" "$foxfiles/fonts" \
    "$foxfiles/netsurf" "$foxfiles/docs"

cp -a "$PAYLOAD/bin/netsurf-fb" "$foxfiles/bin/"
cp -a "$PAYLOAD/etc/." "$foxfiles/etc/"
cp -a "$PAYLOAD/fonts/." "$foxfiles/fonts/"
cp -a "$PAYLOAD/netsurf/." "$foxfiles/netsurf/"

for tool in foxbrowse foxweb foxwifi foxadb curl; do
    src="$DEVICE_DIR/recovery/root/system/bin/$tool"
    [ -f "$src" ] && cp -a "$src" "$foxfiles/bin/"
done

if [ -f "$DEVICE_DIR/tools/NETSURF.md" ]; then
    cp -a "$DEVICE_DIR/tools/NETSURF.md" "$foxfiles/docs/"
fi

cat > "$foxfiles/README.txt" <<'EOF'
OrangeFox enhanced ZIP - NetSurf browser
========================================

This package is the official OrangeFox installer ZIP for begonia plus the
NetSurf browser userspace files, packed AromaFM-style under:

    sdcard/Fox/FoxFiles/NetSurf/

The live browser is already built into recovery.img:
    /system/etc/foxbrowse/bin/netsurf-fb   static AArch64 NetSurf
    /system/bin/foxbrowse                  launcher

The copies below are for reference, sharing, or manual reuse; they are not
needed to run the browser that ships in this recovery.

Files:
    bin/netsurf-fb      static AArch64 NetSurf framebuffer binary
    bin/foxbrowse       browser launcher script
    bin/foxweb          web dashboard
    bin/foxwifi         WiFi helper
    bin/foxadb          ADB helper
    bin/curl            curl wrapper
    etc/start.html      NetSurf start page
    etc/fonts.conf      font configuration
    fonts/              DejaVu font set
    netsurf/            NetSurf resources (CSS, Messages, welcome page)
    docs/NETSURF.md     payload provenance and rebuild recipe

Flashing:
    This ZIP uses the official OrangeFox update-binary, so flash it the same
    way as the official installer ZIP.  The embedded recovery.img is
    byte-identical to the verified build output.  Since the archive is
    re-signed with the AOSP testkey, leave "Zip signature verification"
    disabled (the default in OrangeFox) or the check will reject it.

The recovery image itself is unchanged; only extra files are added to
/sdcard/Fox/FoxFiles/ when the ZIP is flashed.
EOF

# Keep the installer entrypoints executable after the re-zip.
chmod 0755 "$stage/META-INF/com/google/android/update-binary" 2>/dev/null || true

# --- rebuild and verify -----------------------------------------------------
top_entries=$(cd "$stage" && ls -A)
# shellcheck disable=SC2086
( cd "$stage" && zip -q -r -X "$unsigned" $top_entries )

unzip -tq "$unsigned" >/dev/null || die "rebuilt ZIP failed the integrity check"
entries="$work/unsigned-entries.txt"
unzip -Z1 "$unsigned" >"$entries" || die "cannot list $unsigned"
for entry in recovery.img sdcard/Fox/FoxFiles/NetSurf/bin/netsurf-fb \
             sdcard/Fox/FoxFiles/NetSurf/README.txt; do
    grep -qx "$entry" "$entries" \
        || die "rebuilt ZIP is missing $entry"
done

# The recovery image must be untouched.
official_img="$work/official-recovery.img"
new_img="$work/new-recovery.img"
unzip -p "$OFFICIAL_ZIP" recovery.img > "$official_img"
unzip -p "$unsigned" recovery.img > "$new_img"
cmp -s "$official_img" "$new_img" || die "recovery.img changed while repackaging"

# --- sign -------------------------------------------------------------------
SIGNJAR="$ANDROID_ROOT/out/host/linux-x86/framework/signapk.jar"
KEYS="$ANDROID_ROOT/build/target/product/security"
if [ -f "$SIGNJAR" ] && [ -f "$KEYS/testkey.x509.pem" ] && [ -f "$KEYS/testkey.pk8" ]; then
    log "signing with the AOSP testkey"
    java -jar "$SIGNJAR" -w "$KEYS/testkey.x509.pem" "$KEYS/testkey.pk8" \
        "$unsigned" "$OUTPUT_ZIP"
else
    warn "signapk or testkey not found; leaving the ZIP unsigned"
    warn "disable 'Zip signature verification' in recovery when flashing it"
    mv "$unsigned" "$OUTPUT_ZIP"
fi

# --- report -----------------------------------------------------------------
unzip -tq "$OUTPUT_ZIP" >/dev/null || die "final ZIP failed the integrity check"
size=$(stat -c%s "$OUTPUT_ZIP")
sha=$(sha256sum "$OUTPUT_ZIP" | awk '{print $1}')
log "created: $OUTPUT_ZIP"
log "size: $size bytes"
log "sha256: $sha"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "zip_path=$OUTPUT_ZIP" >> "$GITHUB_OUTPUT"
    echo "zip_sha256=$sha" >> "$GITHUB_OUTPUT"
    echo "zip_size=$size" >> "$GITHUB_OUTPUT"
fi
