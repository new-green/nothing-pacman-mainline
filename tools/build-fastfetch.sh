#!/usr/bin/env bash
# Builds a static aarch64 fastfetch -> ~/pacman/fastfetch/fastfetch
# (goes into the initramfs as /pacman/bin/fastfetch, see ui/initramfs.list)
#
#   bash ~/pacman/port/tools/build-fastfetch.sh
set -euo pipefail

V=2.70.0
COMMIT=17bb3fd2384bd814b421d73b8c8b8d08e06cfa26   # tag 2.70.0, 2026-10-14
TOP="${PACMAN:-$HOME/pacman}/fastfetch"
SRC="$TOP/src-$V"
BUILD="$TOP/build-$V"
CROSS="${CROSS:-aarch64-linux-gnu-}"
SYSROOT="/usr/${CROSS%-}"

mkdir -p "$TOP"
[[ -d "$SRC" ]] || git clone -q --depth 1 --branch "$V" \
	https://github.com/fastfetch-cli/fastfetch.git "$SRC"
got=$(git -C "$SRC" rev-parse HEAD)
[[ "$got" == "$COMMIT" ]] || { echo "commit $got != $COMMIT (tag moved?)" >&2; exit 1; }

# No optional libraries at all (the phone has none, and nothing may pick up the
# PC's x86 ones): pkg-config and find_* only look at the aarch64 sysroot.
export PKG_CONFIG_LIBDIR=/nonexistent PKG_CONFIG_PATH=
off=()
for o in VULKAN WAYLAND XCB_RANDR XRANDR DRM VADRM VAX11 VDPAU GIO DCONF EET DBUS \
	SQLITE3 RPM EGL GLX OPENCL FREETYPE ELF IMAGE_LOGO IMAGEMAGICK7 IMAGEMAGICK6 \
	SIXEL CHAFA ZLIB LUA LIBZFS LTO; do
	off+=("-DENABLE_$o=OFF")
done

cmake -S "$SRC" -B "$BUILD" -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_SYSTEM_NAME=Linux \
	-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
	-DCMAKE_C_COMPILER="${CROSS}gcc" \
	-DCMAKE_FIND_ROOT_PATH="$SYSROOT" \
	-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
	-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
	-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
	-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
	-DBINARY_LINK_TYPE=static \
	-DBUILD_FLASHFETCH=OFF \
	-DBUILD_TESTS=OFF \
	"${off[@]}" > "$TOP/cmake.log"
cmake --build "$BUILD" --target fastfetch
"${CROSS}strip" -o "$TOP/fastfetch" "$BUILD/fastfetch"
file "$TOP/fastfetch"
ls -l "$TOP/fastfetch"
