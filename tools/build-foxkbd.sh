#!/bin/sh
#
# build-foxkbd.sh - build the static on-screen keyboard helper.
#
# The helper is intentionally independent of the Android build system.  It
# uses the same musl cross toolchain as the Links2 payload, so the result is a
# small self-contained aarch64 binary that runs in recovery without relying on
# bionic or any shared libraries.
set -eu

TC_URL=https://musl.cc/aarch64-linux-musl-cross.tgz

TOP=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$TOP/recovery/root/system/bin/foxkbd"
WORK=${WORK:-/tmp/foxkbd-build}

mkdir -p "$WORK" "$(dirname "$OUT")"
cd "$WORK"

if [ ! -x "$WORK/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc" ]; then
    echo "== fetching musl cross toolchain"
    curl -fsSL --retry 5 "$TC_URL" -o tc.tgz
    tar -xzf tc.tgz
    rm -f tc.tgz
fi

PATH="$WORK/aarch64-linux-musl-cross/bin:$PATH"
aarch64-linux-musl-gcc \
    -Os -static -s -Wall -Wextra \
    -I"$TOP/tools" \
    -o "$OUT" "$TOP/tools/foxkbd.c"

chmod 0755 "$OUT"
file "$OUT"
