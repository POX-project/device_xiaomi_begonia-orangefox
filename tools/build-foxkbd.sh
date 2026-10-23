#!/bin/sh
#
# build-foxkbd.sh - build the static on-screen keyboard helper.
#
# The helper is intentionally independent of the Android build system.  It is
# linked statically so recovery does not need to resolve a shared library for
# it.  CI installs gcc-aarch64-linux-gnu; a musl cross compiler can be supplied
# through CC as well.
set -eu

TOP=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$TOP/recovery/root/system/bin/foxkbd"
WORK=${WORK:-/tmp/foxkbd-build}

mkdir -p "$WORK" "$(dirname "$OUT")"
cd "$WORK"

if [ -n "${CC:-}" ]; then
    :
elif command -v aarch64-linux-musl-gcc >/dev/null 2>&1; then
    CC=aarch64-linux-musl-gcc
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    CC=aarch64-linux-gnu-gcc
else
    echo "error: no aarch64 static cross compiler found (install gcc-aarch64-linux-gnu or set CC)" >&2
    exit 1
fi

SYSROOT=
case "$CC" in
    *aarch64-linux-gnu-gcc*)
        SYSROOT=/usr/aarch64-linux-gnu
        ;;
esac
if [ -n "$SYSROOT" ] && [ -d "$SYSROOT" ]; then
    set -- --sysroot="$SYSROOT"
else
    set --
fi

echo "== compiler: $CC"
"$CC" --version | head -1
"$CC" -print-sysroot 2>/dev/null || true

"$CC" "$@" \
    -D_GNU_SOURCE -Os -static -s -Wall -Wextra \
    -I"$TOP/tools" \
    -o "$OUT" "$TOP/tools/foxkbd.c"

chmod 0755 "$OUT"
file "$OUT"
