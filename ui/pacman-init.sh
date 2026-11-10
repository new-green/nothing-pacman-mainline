#!/pacman/bin/busybox sh
# PID 1 on the phone (kernel: rdinit=/pacman-init, built-in initramfs).
#
# Everything of ours lives under /pacman/: LK's vendor ramdisk (stock: Android,
# ours: Alpine Linux) is unpacked on top of the built-in initramfs and would
# overwrite /bin, /etc, /init ...
#
# - mounts proc/sys/devtmpfs/tmpfs, installs busybox applet links
# - panel: boot messages on fbcon, then a login prompt on tty1 (root, no password)
# - USB network: usb0 = 172.16.42.1, DHCP for the PC, telnet (PC: telnet 172.16.42.1)
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

# Android ramdisk's /etc and /bin are dangling links to /system/...: point them
# at ours (os-release, passwd...; getty runs /bin/login, scripts use #!/bin/sh).
# rootfs lives in RAM, nothing persists.
for d in etc bin; do
	if [ -L /$d ] || [ ! -e /$d ]; then
		rm -f /$d && ln -s /pacman/$d /$d
	fi
done
hostname pacman

echo "pacman-init: busybox $($BB | $BB head -1 | $BB cut -d' ' -f2)" > /dev/kmsg

# The MT6363 PMIC's Self-Protection Timer (enabled by TF-A at boot) power-cycles the phone after
# 1.5-26 min under mainline (LK then logs SELFWDT=0x41): nothing here keeps it satisfied. Turn
# it off; the AP watchdog (mtk-wdt) and the PMIC long-press reset still work. Needs the
# mt6363-keys-polled driver (SPMI); re-enabled by the firmware on every boot.
SPT=/sys/bus/spmi/devices/0-04/spt_enable
if [ -w "$SPT" ]; then
	echo 0 > "$SPT" && echo "pacman-init: PMIC self-protection timer off" > /dev/kmsg
else
	echo "pacman-init: no $SPT (SPMI/PMIC driver missing): expect PMIC resets" > /dev/kmsg
fi

# Modules built with this kernel (ui/initramfs.list): cpufreq (MCUPM DVFS firmware interface),
# then the touchscreen on SPI3. Touching the SPI block while its clock gate is closed hangs the
# bus (watchdog reset), so check the gate (pericfg_ao PERAO0 bit 15) and the source mux
# (topckgen CLK_CFG_5 bit 31) first; LK has always left both on so far. Reads only.
M=/pacman/lib/modules
if [ -d $M ]; then
	insmod $M/mediatek-cpufreq-hw.ko && echo "pacman-init: cpufreq-hw loaded" > /dev/kmsg
	gate=$(( ($(devmem 0x11036010 32) >> 15) & 1 ))
	cfg=$(devmem 0x10000060 32)
	if [ $gate = 0 ] && [ $(( (cfg >> 31) & 1 )) = 0 ]; then
		# the DT assumes the fastest SPI source (208 MHz): ask for 6 MHz * 208 / real rate
		set -- 26 208 182 156 136 124 104 78
		shift $(( (cfg >> 24) & 7 ))
		insmod $M/crc-ccitt.ko
		insmod $M/spi-mt65xx.ko
		insmod $M/focaltech-fts-spi.ko spi_hz=$(( 6000000 * 208 / $1 )) &&
			echo "pacman-init: touchscreen loaded (SPI source ~$1 MHz)" > /dev/kmsg
	else
		echo "pacman-init: SPI3 clock gate/mux off ($gate/$cfg): touchscreen NOT loaded" > /dev/kmsg
	fi
fi

# Hardware keys: power = blank/unblank the panel (see ui/pacman-keysd.c).
/pacman/bin/pacman-keysd < /dev/null > /dev/null 2>&1 &

# Alpine as the root filesystem (tools/build-vendor-boot.sh puts it into vendor_boot's
# ramdisk, which the kernel unpacks on top of us): prefer its programs, keep ours
# reachable, give it /run. Logins then land in Alpine.
if [ -f /etc/alpine-release ]; then
	export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/pacman/bin
	export HOME=/root
	$BB mkdir -p /run
	$BB mount -t tmpfs -o mode=0755 tmpfs /run
	echo "pacman-init: root filesystem is Alpine Linux $($BB cat /etc/alpine-release)" > /dev/kmsg
fi

# Panel: kernel + init messages scroll on fbcon (tty1). Once the deferred-probe
# summary (~10 s) has gone by, quiet the console and start the XFCE desktop if the
# Alpine root has one (/usr/local/bin/pacman-desktop, DESKTOP=1 build), otherwise a
# login prompt on tty1. Root has no password. Type into the console from the PC:
# `conspy 1` in picocom/telnet (exit: Esc 3x). pacman-dash is still available.
(
	while [ "$(cut -d. -f1 /proc/uptime)" -lt 12 ]; do
		sleep 1
	done
	echo N > /sys/module/printk/parameters/ignore_loglevel
	dmesg -n 1
	if [ -x /usr/local/bin/pacman-desktop ]; then
		# restart the desktop when it exits; give up after 3 quick failures
		fails=0
		while [ $fails -lt 3 ]; do
			# phosh-start (or anyone) can park the desktop: it is not restarted meanwhile
			while [ -e /tmp/pacman-desktop.stop ]; do sleep 5; done
			echo "pacman-init: starting XFCE desktop (VNC 172.16.42.1:5900)" > /dev/kmsg
			t0=$(cut -d. -f1 /proc/uptime)
			/usr/local/bin/pacman-desktop < /dev/null > /tmp/pacman-desktop.log 2>&1
			[ $(( $(cut -d. -f1 /proc/uptime) - t0 )) -lt 30 ] && fails=$((fails + 1)) || fails=0
			sleep 2
		done
		echo "pacman-init: desktop keeps failing (/tmp/pacman-desktop.log), login prompt instead" > /dev/kmsg
		chvt 1
	fi
	echo "pacman-init: login prompt on tty1, console quiet (dmesg for kernel log)" > /dev/kmsg
	while :; do
		printf '\033[H\033[2J' > /dev/tty1
		getty -l /pacman/bin/login 38400 tty1 linux
		sleep 1
	done
) &

# USB network (g_cdc ECM function -> usb0). Phone 172.16.42.1; the PC gets
# 172.16.42.2 from udhcpd. No router option is handed out, so the PC keeps
# its own default route. telnetd: root shell without password, bound to the
# USB link only (the PC does not forward it anywhere).
$BB mkdir -p /dev/pts
mount -t devpts devpts /dev/pts
ip link set lo up
if ip link show usb0 > /dev/null 2>&1; then
	ip addr add 172.16.42.1/24 dev usb0
	ip link set usb0 up
	touch /tmp/udhcpd.leases
	udhcpd /pacman/etc/udhcpd.conf
	telnetd -b 172.16.42.1 -l /pacman/bin/sh
	echo "pacman-init: usb0 172.16.42.1, udhcpd + telnetd up" > /dev/kmsg
else
	echo "pacman-init: no usb0 (USB network gadget missing?)" > /dev/kmsg
fi

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
