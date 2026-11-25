#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
ROOT="$(realpath -m "${ROOT:-$PWD/.dnsperf-armv5te}")"
PREFIX="$ROOT/prefix"
JOBS="${JOBS:-2}"
CROSS="${CROSS_PREFIX:-arm-linux-musleabi-}"
export CC="$(command -v "${CROSS}gcc")" AR="$(command -v "${CROSS}ar")" RANLIB="$(command -v "${CROSS}ranlib")"
STRIP="$(command -v "${CROSS}strip")"
export CFLAGS="-O2 -march=armv5te -marm -mfloat-abi=soft"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG_PATH=
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
mkdir -p "$ROOT" "$PREFIX" "$ROOT/dist"
cd "$ROOT"
fetch() {
    local name="$1" url="$2" digest="$3"
    if [[ ! -f "$name" ]]; then
        curl -fL --retry 3 --connect-timeout 30 -o "$name.tmp" "$url"
        mv "$name.tmp" "$name"
    fi
    printf '%s  %s\n' "$digest" "$name" | sha256sum -c -
}
clone_tag() {
    local dest="$1" url="$2" tag="$3" commit="$4"
    if [[ ! -d "$dest/.git" ]]; then git clone --depth 1 --branch "$tag" "$url" "$dest"; fi
    [[ "$(git -C "$dest" rev-parse HEAD)" == "$commit" ]]
}
# OpenSSL: a pinned 3.5 LTS release, no ARM assembly or shared objects.
if [[ ! -s "$PREFIX/lib/libssl.a" ]]; then
    fetch openssl-3.5.9.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
    rm -rf openssl-3.5.9; tar -xzf openssl-3.5.9.tar.gz
    (
      cd openssl-3.5.9
      ./Configure linux-armv4 no-shared no-asm no-tests no-module no-dso --prefix="$PREFIX" --libdir=lib
      make -j"$JOBS" build_sw
      make install_sw
    )
fi
if [[ ! -s "$PREFIX/lib/libnghttp2.a" ]]; then
    fetch nghttp2-1.68.0.tar.xz https://github.com/nghttp2/nghttp2/releases/download/v1.68.0/nghttp2-1.68.0.tar.xz 5511d3128850e01b5b26ec92bf39df15381c767a63441438b25ad6235def902c
    rm -rf nghttp2-1.68.0; tar -xJf nghttp2-1.68.0.tar.xz
    (
      cd nghttp2-1.68.0
      ./configure --host=arm-linux-musleabi --prefix="$PREFIX" --libdir="$PREFIX/lib" --enable-lib-only --enable-static --disable-shared
      make -j"$JOBS"; make install
    )
fi
# CK's ARM assembly requires ARMv6K. Explicitly use its compiler builtin path.
if [[ ! -s "$PREFIX/lib/libck.a" ]]; then
    clone_tag ck https://github.com/concurrencykit/ck.git 0.7.2 981e14290df3d4339974eade5d8820dafd506b58
    (
      cd ck
      ./configure --platform=arm --profile=arm --use-cc-builtins --prefix="$PREFIX"
      make -C src -j"$JOBS" libck.a
      mkdir -p "$PREFIX/include" "$PREFIX/lib/pkgconfig"
      cp -a include/. "$PREFIX/include/"
      cp src/libck.a "$PREFIX/lib/"
      cat >"$PREFIX/lib/pkgconfig/ck.pc" <<EOF
prefix=$PREFIX
libdir=$PREFIX/lib
includedir=$PREFIX/include
Name: ck
Description: Concurrency Kit compiler builtins
Version: 0.7.2
Libs: -L$PREFIX/lib -lck
Cflags: -I$PREFIX/include -DCK_USE_CC_BUILTINS=1
EOF
    )
fi
if [[ ! -s "$PREFIX/lib/libjson-c.a" ]]; then
    clone_tag json-c https://github.com/json-c/json-c.git json-c-0.18-20240915 41a55cfcedb54d9c1874f2f0eb07b504091d7e37
    cmake -S json-c -B json-c-build -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$CFLAGS" \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_TESTING=OFF -DBUILD_APPS=OFF
    cmake --build json-c-build --parallel "$JOBS"
    cmake --install json-c-build
fi
fetch dnsperf-2.16.0.tar.gz https://www.dns-oarc.net/files/dnsperf/dnsperf-2.16.0.tar.gz 6bccbd6949a4616442fdabb8a93d20011f5fbc2e5492d467e612a16aa39426e2
rm -rf dnsperf-2.16.0; tar -xzf dnsperf-2.16.0.tar.gz
(
    cd dnsperf-2.16.0
    export CFLAGS="$CFLAGS -DCK_USE_CC_BUILTINS=1"
    export LDFLAGS="$LDFLAGS -static"
    export LIBS="-latomic -pthread -lm"
    # LDNS is optional and only needed for dynamic updates.
    ./configure --host=arm-linux-musleabi --prefix="$PREFIX" --disable-shared --enable-static
    make -C src -j"$JOBS" dnsperf
    cp src/dnsperf "$ROOT/dist/dnsperf_armv5te_static_2.16.0"
)
bin="$ROOT/dist/dnsperf_armv5te_static_2.16.0"
"$STRIP" "$bin"
file "$bin"
readelf -h -l -A "$bin" > "$bin.elf.txt"
! grep -Eq 'INTERP|DYNAMIC' "$bin.elf.txt"
grep -Eq 'Tag_CPU_arch: v5TE([[:space:]]|$)' "$bin.elf.txt"
! grep -q 'Tag_ABI_VFP_args: VFP registers' "$bin.elf.txt"
(cd "$ROOT/dist"; sha256sum "$(basename "$bin")" > SHA256SUMS)
printf 'dnsperf=2.16.0\nopenssl=3.5.9\nnghttp2=1.68.0\nck=0.7.2 (compiler atomics)\njson-c=0.18\narch=ARMv5TE soft-float musl\nLDNS=disabled\n' > "$ROOT/dist/BUILD-INFO.txt"
