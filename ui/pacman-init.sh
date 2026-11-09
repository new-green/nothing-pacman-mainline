#!/pacman/bin/busybox sh
# PID 1 on the phone (kernel: rdinit=/pacman-init, built-in initramfs).
#
# Everything of ours lives under /pacman/: LK's Android ramdisk is unpacked
# on top of the built-in initramfs and would overwrite /bin, /etc, /init ...
#
# - mounts proc/sys/devtmpfs/tmpfs, installs busybox applet links
# - starts pacman-dash on fb0
# - keeps a root shell on /dev/ttyGS0 (USB CDC ACM; PC: picocom /dev/ttyACM0)

BB=/pacman/bin/busybox
export PATH=/pacman/bin
export HOME=/tmp TERM=xterm-256color USER=root LOGNAME=root PS1='\u@\h:\w# '

$BB mkdir -p /proc /sys /dev /tmp
$BB mount -t proc proc /proc
$BB mount -t sysfs sysfs /sys
$BB mount -t devtmpfs devtmpfs /dev
$BB mount -t tmpfs tmpfs /tmp
$BB --install -s /pacman/bin

# Android ramdisk's /etc is a dangling link to /system/etc: point it at ours
# (os-release for fastfetch). rootfs lives in RAM, nothing persists.
if [ -L /etc ] || [ ! -e /etc ]; then
	rm -f /etc && ln -s /pacman/etc /etc
fi
hostname pacman

echo "pacman-init: busybox $($BB | $BB head -1 | $BB cut -d' ' -f2)" > /dev/kmsg

pacman-dash &

# Shell on ttyGS0, respawned when it exits (logout, cable unplug -> SIGHUP).
# This script is non-interactive, so its children are not process group
# leaders and busybox setsid does not fork-and-return (which would make
# this loop spawn a new shell every second).
while :; do
	if [ ! -c /dev/ttyGS0 ]; then
		sleep 1
		continue
	fi
	echo "pacman-init: shell on ttyGS0" > /dev/kmsg
	setsid -c sh -i < /dev/ttyGS0 > /dev/ttyGS0 2>&1
	sleep 1
done
