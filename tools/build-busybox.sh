#!/usr/bin/env bash
# Builds a static aarch64 busybox -> ~/pacman/busybox/busybox
# (goes into the initramfs as /pacman/bin/busybox, see ui/initramfs.list)
#
#   bash ~/pacman/port/tools/build-busybox.sh
set -euo pipefail

V=1.37.0
SHA256=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4
TOP="${PACMAN:-$HOME/pacman}/busybox"
DL="$TOP/dl"
SRC="$TOP/src-$V"
CROSS="${CROSS:-aarch64-linux-gnu-}"

mkdir -p "$DL"
tarball="$DL/busybox-$V.tar.bz2"
[[ -f "$tarball" ]] || curl -fsSL -o "$tarball" "https://busybox.net/downloads/busybox-$V.tar.bz2"
echo "$SHA256  $tarball" | sha256sum -c -

if [[ ! -d "$SRC" ]]; then
	mkdir -p "$SRC"
	tar -xjf "$tarball" -C "$SRC" --strip-components=1
fi

cd "$SRC"
make -s CROSS_COMPILE="$CROSS" defconfig >/dev/null
# static; tc does not build against new kernel headers (CBQ was removed);
# SHA hardware acceleration is x86 only
sed -i \
	-e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
	-e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
	-e 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' \
	-e 's/^CONFIG_SHA1_HWACCEL=y/# CONFIG_SHA1_HWACCEL is not set/' \
	-e 's/^CONFIG_SHA256_HWACCEL=y/# CONFIG_SHA256_HWACCEL is not set/' \
	.config
# `yes` gets SIGPIPE when make exits; `|| :` keeps pipefail/set -e quiet
{ yes '' || :; } | make -s CROSS_COMPILE="$CROSS" oldconfig >/dev/null
make -s CROSS_COMPILE="$CROSS" -j"$(nproc)" busybox
"${CROSS}strip" -o "$TOP/busybox" busybox
file "$TOP/busybox"
ls -l "$TOP/busybox"
