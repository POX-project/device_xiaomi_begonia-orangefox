#!/bin/sh
#
# build-foxnet.sh - rebuild the static musl networking payload for recovery.
#
# The recovery ramdisk cannot use AOSP's bionic curl: bionic's resolver
# ignores /etc/resolv.conf and the net.dns* properties and expects netd to
# populate its cache, which recovery does not run.  This script builds a
# fully static curl against musl + OpenSSL + zlib.  The binary lands in
# recovery/root/system/etc/foxnet/bin/curl (wrapped by system/bin/curl).
#
# Tested on Debian/Ubuntu x86_64 with ~3 GB of free disk.  Needs: curl, tar,
# xz, gzip, make, bison, perl, and the musl.cc aarch64 cross toolchain.
#
# Versions are pinned so a rebuild matches the committed binary.
set -eu

TC_URL=https://musl.cc/aarch64-linux-musl-cross.tgz
ZLIB=1.3.1
OPENSSL=3.0.15
CURL=8.11.1

TOP=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$TOP/recovery/root/system/etc/foxnet/bin/curl"
WORK=${WORK:-/tmp/foxnet-build}
PREFIX="$WORK/prefix"

mkdir -p "$WORK" "$PREFIX" "$(dirname "$OUT")"
cd "$WORK"

if [ ! -x "$WORK/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc" ]; then
    echo "== fetching musl cross toolchain"
    curl -fsSL "$TC_URL" -o tc.tgz
    tar -xzf tc.tgz
fi
PATH="$WORK/aarch64-linux-musl-cross/bin:$PATH"
export PATH
CC=aarch64-linux-musl-gcc
export CC

echo "== zlib $ZLIB"
[ -f "zlib-$ZLIB.tar.gz" ] || curl -fsSL "https://zlib.net/fossils/zlib-$ZLIB.tar.gz" -o "zlib-$ZLIB.tar.gz"
rm -rf "zlib-$ZLIB" && tar -xzf "zlib-$ZLIB.tar.gz"
( cd "zlib-$ZLIB" && ./configure --static --prefix="$PREFIX" >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null )

echo "== openssl $OPENSSL"
[ -f "openssl-$OPENSSL.tar.gz" ] || curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz" -o "openssl-$OPENSSL.tar.gz"
rm -rf "openssl-$OPENSSL" && tar -xzf "openssl-$OPENSSL.tar.gz"
( cd "openssl-$OPENSSL" && ./Configure linux-aarch64 no-shared no-tests no-legacy \
    --prefix="$PREFIX" --openssldir="$PREFIX/ssl" >/dev/null \
    && make -j"$(nproc)" >/dev/null 2>&1 && make install_sw >/dev/null 2>&1 )

echo "== curl $CURL"
[ -f "curl-$CURL.tar.xz" ] || curl -fsSL "https://curl.se/download/curl-$CURL.tar.xz" -o "curl-$CURL.tar.xz"
rm -rf "curl-$CURL" && tar -xJf "curl-$CURL.tar.xz"
( cd "curl-$CURL" && ./configure --host=aarch64-linux-musl --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --with-openssl="$PREFIX" --with-zlib="$PREFIX" \
    --without-libidn2 --without-libpsl --without-brotli --without-zstd \
    --without-nghttp2 --without-libssh2 --disable-ares \
    --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet \
    --disable-tftp --disable-pop3 --disable-imap --disable-smtp --disable-gopher \
    --disable-mqtt --disable-manual --disable-ntlm-wb \
    --enable-ipv6 --enable-threaded-resolver \
    CFLAGS="-Os -fno-unwind-tables -fno-asynchronous-unwind-tables" \
    LDFLAGS="-static -s" >/dev/null \
    && make -j"$(nproc)" >/dev/null )

cp "$WORK/curl-$CURL/src/curl" "$OUT"
chmod 0755 "$OUT"
aarch64-linux-musl-strip "$OUT" 2>/dev/null || true
echo "== wrote $OUT ($(wc -c < "$OUT") bytes)"
"$OUT" --version | head -2 || true
