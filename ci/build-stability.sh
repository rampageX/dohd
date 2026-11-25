#!/usr/bin/env bash
# Isolated diagnostic builds. Never installs into /mmc, /opt or system paths.
set -euo pipefail
arch="${1:-native}"
version="${2:-5.9.4}"
case "$version" in
  5.1.0) wolf_commit=2b670c026debc8e70621eb5c75b60931c9aa0bc5 ;;
  5.9.4) wolf_commit=3c5eead44904df64e6a5a1f4ebdce377d35a849a ;;
  *) echo "Unsupported comparison version: $version" >&2; exit 2 ;;
esac
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
root="${BUILD_ROOT:-$repo_root/.stability-build}/$arch-wolfssl-$version"
mkdir -p "$root"
root="$(cd "$root" && pwd)"
prefix="$root/prefix"
jobs="${JOBS:-2}"
host_args=()
arch_flags=()
case "$arch" in
  native) cc="${CC:-gcc}"; ar="${AR:-ar}"; ranlib="${RANLIB:-ranlib}"; strip="${STRIP:-strip}" ;;
  armv5te)
    cross="${CROSS_PREFIX:-arm-linux-musleabi-}"
    cc="${cross}gcc"; ar="${cross}ar"; ranlib="${cross}ranlib"; strip="${cross}strip"
    host_args=(--host=arm-linux-musleabi)
    arch_flags=(-march=armv5te -marm -mfloat-abi=soft)
    ;;
  *) echo "Unknown target: $arch" >&2; exit 2 ;;
esac
for tool in "$cc" "$ar" "$ranlib" "$strip" git curl make tar sha256sum autoreconf; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 1; }
done
export CC="$cc" AR="$ar" RANLIB="$ranlib"
export CFLAGS="-O2 -Wno-error ${arch_flags[*]}"
export PKG_CONFIG_PATH=
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
mkdir -p "$prefix" "$root/dist"
if [[ ! -f "$prefix/.nghttp2-1.68.0-complete" ]]; then
  archive="$root/nghttp2-1.68.0.tar.xz"
  if [[ ! -f "$archive" ]]; then
    curl -fL --retry 3 -o "$archive.tmp" \
      https://github.com/nghttp2/nghttp2/releases/download/v1.68.0/nghttp2-1.68.0.tar.xz
    mv "$archive.tmp" "$archive"
  fi
  echo "5511d3128850e01b5b26ec92bf39df15381c767a63441438b25ad6235def902c  $archive" | sha256sum -c -
  rm -rf "$root/nghttp2-1.68.0"
  tar -xJf "$archive" -C "$root"
  (
    cd "$root/nghttp2-1.68.0"
    ./configure "${host_args[@]}" --prefix="$prefix" --libdir="$prefix/lib" \
      --enable-lib-only --enable-static --disable-shared
    make -j"$jobs"
    make install
  )
  touch "$prefix/.nghttp2-1.68.0-complete"
fi
if [[ ! -f "$prefix/.wolfssl-$wolf_commit-complete" ]]; then
  wolf="$root/wolfssl"
  if [[ ! -d "$wolf/.git" ]]; then
    git clone --depth 1 --branch "v$version-stable" https://github.com/wolfSSL/wolfssl.git "$wolf"
  fi
  [[ "$(git -C "$wolf" rev-parse HEAD)" == "$wolf_commit" ]] || {
    echo "wolfSSL source commit mismatch" >&2; exit 1;
  }
  (
    cd "$wolf"
    ./autogen.sh
    ./configure "${host_args[@]}" --prefix="$prefix" --libdir="$prefix/lib" \
      --enable-static --disable-shared --enable-tls13 --enable-alpn \
      --enable-session-ticket --enable-curve25519 --enable-opensslextra \
      --disable-asm --disable-examples --disable-crypttests
    make -j"$jobs"
    make install
  )
  touch "$prefix/.wolfssl-$wolf_commit-complete"
fi
test -s "$prefix/lib/libwolfssl.a"
test -s "$prefix/lib/libnghttp2.a"
rm -rf "$root/dohd-src"
cp -R "$repo_root/src" "$root/dohd-src"
make -C "$root/dohd-src" clean
make -C "$root/dohd-src" -j"$jobs" ODOH=0 VERSION=0.8 \
  CC="$cc ${arch_flags[*]}" CPPFLAGS="-I$prefix/include" \
  LDFLAGS="-static -L$prefix/lib" \
  LDLIBS="$prefix/lib/libwolfssl.a $prefix/lib/libnghttp2.a -pthread -lrt -lm"
out="$root/dist/dohd_$arch"_wolfssl_"$version"
cp "$root/dohd-src/dohd" "$out"
"$strip" "$out"
file "$out"
readelf -h -l -A "$out" > "$out.elf.txt"
if grep -Eq 'INTERP|DYNAMIC' "$out.elf.txt"; then
  echo "Unexpected dynamic ELF segment" >&2; exit 1
fi
if [[ "$arch" == armv5te ]]; then
  grep -Eq 'Tag_CPU_arch: v5TE([[:space:]]|$)' "$out.elf.txt"
  if grep -q 'Tag_ABI_VFP_args: VFP registers' "$out.elf.txt"; then
    echo "Hard-float ABI is not allowed" >&2; exit 1
  fi
fi
(
  cd "$root/dist"
  sha256sum "$(basename "$out")" > "$(basename "$out").sha256"
  printf 'wolfSSL=%s\nwolfSSL_commit=%s\nnghttp2=1.68.0\nsource=%s\n' \
    "$version" "$wolf_commit" "$(git -C "$repo_root" rev-parse HEAD)" > "$(basename "$out").build-info"
)
echo "Binary: $out"
