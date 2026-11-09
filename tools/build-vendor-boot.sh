#!/usr/bin/env bash
# Builds a vendor_boot image whose ramdisk is our Alpine Linux, so the phone boots straight
# into Alpine without the PC:
#   ~/pacman/out/pacman-alpine-vendor_boot.img
#
#   bash ~/pacman/port/tools/build-vendor-boot.sh [dtb.img]     (default: hybrid/test-U.img)
#   OUT=~/pacman/out/other.img bash ...                          (other output name)
#
# Starts from your stock vendor_boot's mkbootimg arguments (work/vb_args.txt, made with
# `unpack_bootimg --format=mkbootimg`) and only swaps the DTB and the first (platform) ramdisk
# fragment, which on stock is Android's ramdisk. LK loads that fragment into its 64 MiB ramdisk
# buffer; the kernel unpacks it on top of our built-in initramfs, so / becomes Alpine and
# /pacman-init (still PID 1) finds /etc/alpine-release.
# Needs: tools/build-alpine.sh first (~/pacman/alpine/rootfs), GNU cpio, gzip, mkbootimg.
set -euo pipefail

TOP="${PACMAN:-$HOME/pacman}"
PORT="$(cd "$(dirname "$0")/.." && pwd)"
DTB="$(realpath "${1:-$PORT/hybrid/test-U.img}")"
ROOT="$TOP/alpine/rootfs"
WORK="$TOP/work"
OUT="${OUT:-$TOP/out/pacman-alpine-vendor_boot.img}"
RD="$TOP/alpine/alpine-ramdisk.cpio.gz"
LIMIT=$((64 * 1024 * 1024))     # vendor_boot partition and LK's ramdisk buffer

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$ROOT/etc/alpine-release" ]] || die "no Alpine rootfs: run tools/build-alpine.sh first"
[[ -f "$WORK/vb_args.txt" ]] || die "missing $WORK/vb_args.txt (unpack_bootimg of your stock vendor_boot)"
[[ -f "$DTB" ]] || die "missing DTB $DTB"
args=$(cat "$WORK/vb_args.txt")
[[ "$args" == *"--vendor_ramdisk_fragment vb/vendor_ramdisk00"* && "$args" == *"--dtb vb/dtb"* ]] \
	|| die "unexpected vb_args.txt layout"

say "ramdisk: Alpine $(cat "$ROOT/etc/alpine-release") ($(du -sh "$ROOT" | cut -f1))"
(cd "$ROOT" && find . -mindepth 1 -print0 | LC_ALL=C sort -z \
	| cpio --null --quiet -o -H newc -R 0:0) | gzip -9 > "$RD"

args=${args/--dtb vb\/dtb/--dtb $DTB}
args=${args/--vendor_ramdisk_fragment vb\/vendor_ramdisk00/--vendor_ramdisk_fragment $RD}
mkdir -p "$(dirname "$OUT")"
(cd "$WORK" && eval mkbootimg "$args" --vendor_boot "$OUT")

size=$(stat -c %s "$OUT")
(( size < LIMIT )) || die "$OUT is $size bytes, over 64 MiB"
say "$OUT: $(du -h "$OUT" | cut -f1) (ramdisk $(du -h "$RD" | cut -f1), DTB $(basename "$DTB"))"
