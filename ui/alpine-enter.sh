#!/pacman/bin/busybox sh
# alpine: enter the Alpine userspace unpacked in RAM by the PC's tools/alpine-push.sh.
#   alpine            login shell inside Alpine
#   alpine CMD ...    run one command inside Alpine (e.g. `alpine fastfetch`)
# Our init, pacman-dash and the USB network keep running outside the chroot.

R=${ALPINE_ROOT:-/tmp/alpine}

# (not $R/bin/sh: it is an absolute symlink to /bin/busybox, which resolves
#  against our own root from out here)
if [ ! -f "$R/etc/alpine-release" ]; then
	echo "alpine: $R is empty. On the PC: bash ~/pacman/port/tools/alpine-push.sh" >&2
	exit 1
fi

if ! mountpoint -q "$R/proc"; then
	mount -t proc proc "$R/proc"
	mount -t sysfs sysfs "$R/sys"
	mount -o bind /dev "$R/dev"
	mount -o bind /dev/pts "$R/dev/pts"
	mount -t tmpfs tmpfs "$R/tmp"
	hostname > "$R/etc/hostname"
fi

ENV="HOME=/root TERM=${TERM:-xterm-256color} USER=root LOGNAME=root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
if [ $# -gt 0 ]; then
	exec chroot "$R" /usr/bin/env -i $ENV "$@"
fi
exec chroot "$R" /usr/bin/env -i $ENV /bin/sh -l
