#!/bin/sh
#
# build-links.sh - rebuild the static Links2 browser payload for recovery.
#
# Links2 is built with the Linux framebuffer driver and freetype so that pages
# are readable at 1080p.  It is linked statically against musl, OpenSSL, zlib,
# libpng, libjpeg-turbo, freetype, expat and fontconfig.  The source patch in
# tools/links2-2.30-begonia.patch removes the VT dependency (begonia has
# CONFIG_FB=y but no CONFIG_VT) and adds direct evdev touch/key input.
#
# Tested on Debian/Ubuntu x86_64.  Needs: curl, tar, xz, gzip, make, cmake,
# gperf, pkg-config, and the musl.cc aarch64 cross toolchain.
#
# Versions are pinned so a rebuild matches the committed binary.
set -eu

TC_URL=https://musl.cc/aarch64-linux-musl-cross.tgz
EXPAT=2.6.4
FREETYPE=2.13.3
FONTCONFIG=2.15.0
LIBPNG=1.6.44
JPEG=3.0.4
LINKS=2.30

TOP=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$TOP/recovery/root/system/etc/foxbrowse/bin/links"
WORK=${WORK:-/tmp/links-build}
PREFIX="$WORK/prefix"
Z="$PREFIX"

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
CFLAGS="-Os -fno-unwind-tables -fno-asynchronous-unwind-tables"
export CFLAGS

echo "== zlib"
if [ ! -f "$PREFIX/lib/libz.a" ]; then
    [ -f zlib-1.3.1.tar.gz ] || curl -fsSL https://zlib.net/fossils/zlib-1.3.1.tar.gz -o zlib-1.3.1.tar.gz
    rm -rf zlib-1.3.1 && tar -xzf zlib-1.3.1.tar.gz
    ( cd zlib-1.3.1 && ./configure --static --prefix="$PREFIX" >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null )
fi

echo "== openssl"
if [ ! -f "$PREFIX/lib/libssl.a" ]; then
    [ -f openssl-3.0.15.tar.gz ] || curl -fsSL https://github.com/openssl/openssl/releases/download/openssl-3.0.15/openssl-3.0.15.tar.gz -o openssl-3.0.15.tar.gz
    rm -rf openssl-3.0.15 && tar -xzf openssl-3.0.15.tar.gz
    ( cd openssl-3.0.15 && ./Configure linux-aarch64 no-shared no-tests no-legacy \
        --prefix="$PREFIX" --openssldir="$PREFIX/ssl" >/dev/null \
        && make -j"$(nproc)" >/dev/null 2>&1 && make install_sw >/dev/null 2>&1 )
fi

echo "== expat $EXPAT"
[ -f "expat-$EXPAT.tar.gz" ] || curl -fsSL "https://github.com/libexpat/libexpat/releases/download/R_2_6_4/expat-$EXPAT.tar.gz" -o "expat-$EXPAT.tar.gz"
rm -rf "expat-$EXPAT" && tar -xzf "expat-$EXPAT.tar.gz"
( cd "expat-$EXPAT" && ./configure --host=aarch64-linux-musl --prefix="$PREFIX" \
    --disable-shared --enable-static --without-docbook --without-examples --without-tests >/dev/null \
    && make -j"$(nproc)" >/dev/null && make install >/dev/null )

echo "== freetype $FREETYPE"
[ -f "freetype-$FREETYPE.tar.xz" ] || curl -fsSL "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE.tar.xz" -o "freetype-$FREETYPE.tar.xz"
rm -rf "freetype-$FREETYPE" && tar -xJf "freetype-$FREETYPE.tar.xz"
( cd "freetype-$FREETYPE" && ./configure --host=aarch64-linux-musl --prefix="$PREFIX" \
    --disable-shared --enable-static --without-harfbuzz --without-brotli --without-bzip2 --without-png \
    --with-zlib="$Z" CPPFLAGS="-I$Z/include" LDFLAGS="-L$Z/lib" >/dev/null \
    && make -j"$(nproc)" >/dev/null && make install >/dev/null )

echo "== fontconfig $FONTCONFIG"
[ -f "fontconfig-$FONTCONFIG.tar.xz" ] || curl -fsSL "https://www.freedesktop.org/software/fontconfig/release/fontconfig-$FONTCONFIG.tar.xz" -o "fontconfig-$FONTCONFIG.tar.xz"
rm -rf "fontconfig-$FONTCONFIG" && tar -xJf "fontconfig-$FONTCONFIG.tar.xz"
( cd "fontconfig-$FONTCONFIG" && ./configure --host=aarch64-linux-musl --prefix="$PREFIX" \
    --disable-shared --enable-static --disable-docs --disable-cache-build --with-expat="$PREFIX" \
    CPPFLAGS="-I$PREFIX/include -I$Z/include" LDFLAGS="-L$PREFIX/lib -L$Z/lib" >/dev/null \
    && make -j"$(nproc)" >/dev/null && make install >/dev/null )

echo "== libpng $LIBPNG"
[ -f "libpng-$LIBPNG.tar.xz" ] || curl -fsSL "https://download.sourceforge.net/libpng/libpng-$LIBPNG.tar.xz" -o "libpng-$LIBPNG.tar.xz"
rm -rf "libpng-$LIBPNG" && tar -xJf "libpng-$LIBPNG.tar.xz"
( cd "libpng-$LIBPNG" && ./configure --host=aarch64-linux-musl --prefix="$PREFIX" \
    --disable-shared --enable-static CPPFLAGS="-I$Z/include" LDFLAGS="-L$Z/lib" >/dev/null \
    && make -j"$(nproc)" >/dev/null && make install >/dev/null )

echo "== libjpeg-turbo $JPEG"
[ -f "libjpeg-turbo-$JPEG.tar.gz" ] || curl -fsSL "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG/libjpeg-turbo-$JPEG.tar.gz" -o "libjpeg-turbo-$JPEG.tar.gz"
rm -rf "libjpeg-turbo-$JPEG" jpeg-build && tar -xzf "libjpeg-turbo-$JPEG.tar.gz"
mkdir jpeg-build && cd jpeg-build
cmake "../libjpeg-turbo-$JPEG" -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF \
    -DCMAKE_BUILD_TYPE=MinSizeRel >/dev/null
make -j"$(nproc)" >/dev/null && make install >/dev/null
cd "$WORK"

# Links2 includes <gpm.h> even when the GPM mouse is unused.  A tiny stub
# satisfies the header and the link; actual input is direct evdev.
aarch64-linux-musl-gcc -Os -I"$TOP/tools/gpm-stub" -c "$TOP/tools/gpm-stub/gpm_stub.c" -o gpm_stub.o
aarch64-linux-musl-ar rcs "$PREFIX/lib/libgpm.a" gpm_stub.o
cp "$TOP/tools/gpm-stub/gpm.h" "$PREFIX/include/gpm.h"

echo "== links $LINKS"
[ -f "links-$LINKS.tar.bz2" ] || curl -fsSL "http://links.twibright.com/download/links-$LINKS.tar.bz2" -o "links-$LINKS.tar.bz2"
rm -rf "links-$LINKS" && tar -xjf "links-$LINKS.tar.bz2"
( cd "links-$LINKS" && patch -p1 < "$TOP/tools/links2-2.30-begonia.patch" )
cd "links-$LINKS"
LIBFREETYPE_CFLAGS="-I$PREFIX/include/freetype2 -I$PREFIX/include" \
LIBFREETYPE_LIBS="-L$PREFIX/lib -lfontconfig -lfreetype -lexpat" \
LIBPNG_CFLAGS="-I$PREFIX/include" LIBPNG_LIBS="-L$PREFIX/lib -lpng16" \
OPENSSL_CFLAGS="-I$Z/include" OPENSSL_LIBS="-L$Z/lib -lssl -lcrypto" \
CPPFLAGS="-I$PREFIX/include -I$Z/include" LDFLAGS="-static -L$PREFIX/lib -L$Z/lib" \
./configure --enable-graphics --without-x --without-libevent --without-bzip2 \
    --without-directfb --without-svgalib --without-pmshell --without-windows \
    --without-atheos --without-haiku --without-grx --without-libtiff --without-libwebp \
    --with-ssl="$Z" >/dev/null
make -j"$(nproc)" LIBS="-L$PREFIX/lib -L$Z/lib -lfontconfig -lfreetype -lexpat -lpng16 -ljpeg -lssl -lcrypto -lz -lgpm -lm -lpthread" >/dev/null
cp links "$OUT"
chmod 0755 "$OUT"
aarch64-linux-musl-strip "$OUT" 2>/dev/null || true
echo "== wrote $OUT ($(wc -c < "$OUT") bytes)"
