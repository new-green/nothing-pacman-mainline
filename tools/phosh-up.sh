#!/usr/bin/env bash
# Phosh on the phone: its root filesystem (UI=phosh tools/build-alpine.sh, ~600 MB) does not fit
# into vendor_boot, so it is sent over the USB network into RAM (/tmp/phosh, ~10 s) and started
# in a chroot by phosh-start (built-in initramfs). Needs a running image with pacman-drm (KMS).
#   bash ~/pacman/port/tools/phosh-up.sh          send + start
#   bash ~/pacman/port/tools/phosh-up.sh --start  start again (already sent)
set -euo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
TAR="${TAR:-$HOME/pacman/alpine/alpine-rootfs-phosh.tar.gz}"
pacsh() { python3 -I "$TOOLS/pacsh.py" --net "$@"; }

if [[ "${1:-}" != --start ]]; then
	[[ -f "$TAR" ]] || { echo "missing $TAR: run UI=phosh bash $TOOLS/build-alpine.sh" >&2; exit 1; }
	pacsh run 'phosh-start stop > /dev/null 2>&1; R=/tmp/phosh; for m in tmp run dev/shm dev/pts dev sys proc; do mountpoint -q $R/$m && umount -l $R/$m; done; true' -t 30 > /dev/null
	TAR="$TAR" DEST=/tmp/phosh bash "$TOOLS/alpine-push.sh"
fi
pacsh run "date -s @$(date +%s) > /dev/null; phosh-start" -t 30
sleep 15
pacsh run 'tail -n 20 /tmp/phosh/tmp/phosh.log; pgrep -a phoc | head -1; pgrep -a phosh | head -2' -t 20
