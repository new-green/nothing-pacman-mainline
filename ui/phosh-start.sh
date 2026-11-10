#!/pacman/bin/sh
# Starts Phosh from the root filesystem tools/phosh-up.sh sent into /tmp/phosh (RAM).
# Parks the X desktop (pacman-init does not restart it while /tmp/pacman-desktop.stop
# exists), prepares the chroot and runs /usr/local/bin/pacman-phosh in it.
#   phosh-start          start
#   phosh-start stop     stop Phosh and give the panel back to the X desktop
R=${PHOSH_ROOT:-/tmp/phosh}

if [ "$1" = stop ]; then
	for n in phoc phosh gnome-session-binary seatd; do kill $(pidof $n) 2> /dev/null; done
	sleep 2
	rm -f /tmp/pacman-desktop.stop
	echo "phosh stopped, the X desktop comes back"
	exit 0
fi

if [ ! -x "$R/usr/local/bin/pacman-phosh" ]; then
	echo "phosh-start: $R is empty. On the PC: bash ~/pacman/port/tools/phosh-up.sh" >&2
	exit 1
fi

touch /tmp/pacman-desktop.stop
kill $(pidof pacman-keysd) 2> /dev/null		# phosh handles the keys itself
kill $(pidof Xorg) 2> /dev/null
sleep 2

if ! mountpoint -q "$R/proc"; then
	mount -t proc proc "$R/proc"
	mount -t sysfs sysfs "$R/sys"
	mount -o bind /dev "$R/dev"
	mount -o bind /dev/pts "$R/dev/pts"
	mkdir -p "$R/dev/shm"
	mountpoint -q "$R/dev/shm" || mount -t tmpfs -o mode=1777 tmpfs "$R/dev/shm"
	mount -t tmpfs -o mode=0755 tmpfs "$R/run"
	mount -t tmpfs -o mode=1777 tmpfs "$R/tmp"
	hostname > "$R/etc/hostname"
fi
setsid chroot "$R" /usr/local/bin/pacman-phosh < /dev/null > /dev/null 2>&1 &
echo "phosh starting (log: $R/tmp/phosh.log, stop: phosh-start stop)"
