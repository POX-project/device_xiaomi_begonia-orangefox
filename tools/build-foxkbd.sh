#!/bin/sh
#
# build-foxkbd.sh - build the static on-screen keyboard helper.
#
# The helper is intentionally independent of the Android build system and is
# linked statically so recovery does not need a shared library for it.
#
# Compiler selection, in order:
#   1. $CC, when the caller pins one
#   2. aarch64-linux-musl-gcc
#   3. aarch64-linux-gnu-gcc
#   4. clang targeting aarch64-linux-gnu against the cross sysroot
#
# The system gcc cross compiler (gcc-aarch64-linux-gnu) Conflicts with
# gcc-multilib, which the OrangeFox build needs for 32-bit host tools, so CI
# installs only the aarch64 sysroot (libc6-dev-arm64-cross) and uses clang.
set -eu

TOP=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$TOP/recovery/root/system/bin/foxkbd"
WORK=${WORK:-/tmp/foxkbd-build}

mkdir -p "$WORK" "$(dirname "$OUT")"
cd "$WORK"

FLAGS=

if [ -n "${CC:-}" ]; then
    :
elif command -v aarch64-linux-musl-gcc >/dev/null 2>&1; then
    CC=aarch64-linux-musl-gcc
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    CC=aarch64-linux-gnu-gcc
elif command -v clang >/dev/null 2>&1 && [ -d /usr/aarch64-linux-gnu ]; then
    CC=clang
    FLAGS="--target=aarch64-linux-gnu --sysroot=/usr/aarch64-linux-gnu"
    # libgcc.a comes from libgcc-<ver>-dev-arm64-cross, which installs outside
    # the sysroot; hand clang the directory explicitly so the static link does
    # not depend on clang's default cross search path.
    for d in /usr/lib/gcc-cross/aarch64-linux-gnu/*/; do
        [ -d "$d" ] && FLAGS="$FLAGS -L$d"
    done
else
    echo "error: no aarch64 static cross compiler found" >&2
    echo "       install libc6-dev-arm64-cross (clang) or gcc-aarch64-linux-gnu" >&2
    exit 1
fi

case "$CC" in
    *aarch64-linux-gnu-gcc*)
        if [ -d /usr/aarch64-linux-gnu ]; then
            FLAGS="--sysroot=/usr/aarch64-linux-gnu"
        fi
        ;;
esac

echo "== compiler: $CC $FLAGS"
"$CC" --version | head -1
"$CC" -print-sysroot 2>/dev/null || true

# shellcheck disable=SC2086
"$CC" $FLAGS \
    -D_GNU_SOURCE -Os -static -s -Wall -Wextra \
    -I"$TOP/tools" \
    -o "$OUT" "$TOP/tools/foxkbd.c"

chmod 0755 "$OUT"
file "$OUT"
