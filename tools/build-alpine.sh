#!/usr/bin/env bash
# Builds a small Alpine Linux aarch64 userspace on the PC, without root and without
# giving the phone internet access:
#   ~/pacman/alpine/rootfs/                 the tree
#   ~/pacman/alpine/alpine-rootfs.tar.gz    what tools/alpine-push.sh sends to the phone
#
#   bash ~/pacman/port/tools/build-alpine.sh [extra packages...]
#   DESKTOP=1 bash ~/pacman/port/tools/build-alpine.sh    slim XFCE desktop -> rootfs-desktop/
#
# DESKTOP=1 adds Xorg (fbdev), a slim XFCE (no xfce4 meta package), x11vnc and dbus, then removes
# Mesa's LLVM/gallium (~200 MiB): there is no GPU driver, Xorg runs on fbdev with GLX disabled.
# The post-install work skipped by --no-scripts (messagebus user, font/pixbuf/schema caches) is
# done by hand here or at first start by /usr/local/bin/pacman-desktop.
#
# Minirootfs: sha256 + GPG (Natanael Copa's key, fingerprint pinned below).
# Packages: installed with Alpine's own apk.static (x86_64 build), signatures checked
# against the keys shipped in the minirootfs. Post-install scripts are skipped
# (--no-scripts): fine for these packages; run `apk fix` on the phone if one needs them.
set -euo pipefail

V=3.24.4
BRANCH=v3.24
MINI_SHA256=4b14c18f7e90a063b61462ea1462a5732c154bf6adad594974fe6487cd98a8de
NCOPA_FPR=0482D84022F52DF1C4E7CD43293ACD0907D9495A
APKTOOLS=apk-tools-static-3.0.9-r0
PACKAGES=(bash htop nano fastfetch evtest "$@")
DESKTOP="${DESKTOP:-0}"
SUFFIX=""
if [[ "$DESKTOP" == 1 ]]; then
	PACKAGES+=(xorg-server xf86-video-fbdev xf86-input-evdev xinit xfwm4 xfce4-panel xfdesktop xfce4-session
		xfce4-settings xfce4-terminal font-dejavu dbus dbus-x11 x11vnc)
	SUFFIX="-desktop"
fi

TOP="${PACMAN:-$HOME/pacman}/alpine"
DL="$TOP/dl"
ROOT="$TOP/rootfs$SUFFIX"
OUT="$TOP/alpine-rootfs$SUFFIX.tar.gz"
CDN=https://dl-cdn.alpinelinux.org/alpine

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
mkdir -p "$DL/apkcache" "$TOP/apktools"

# --- minirootfs: download + verify ---
mini="alpine-minirootfs-$V-aarch64.tar.gz"
for f in "$mini" "$mini.asc"; do
	[[ -f "$DL/$f" ]] || curl -fsSL -o "$DL/$f" "$CDN/$BRANCH/releases/aarch64/$f"
done
[[ -f "$DL/ncopa.asc" ]] || curl -fsSL -o "$DL/ncopa.asc" https://alpinelinux.org/keys/ncopa.asc
echo "$MINI_SHA256  $DL/$mini" | sha256sum -c --quiet -
G=$(mktemp -d); trap 'rm -rf "$G"' EXIT
gpg --homedir "$G" --quiet --import "$DL/ncopa.asc" 2>/dev/null
gpg --homedir "$G" --status-fd 1 --verify "$DL/$mini.asc" "$DL/$mini" 2>/dev/null \
	| grep -q "VALIDSIG $NCOPA_FPR" || { echo "GPG signature could not be verified" >&2; exit 1; }
say "minirootfs $V: sha256 + GPG OK"

# --- apk.static (runs on the PC) ---
APK="$TOP/apktools/sbin/apk.static"
if [[ ! -x "$APK" ]]; then
	curl -fsSL -o "$TOP/apktools/$APKTOOLS.apk" "$CDN/$BRANCH/main/x86_64/$APKTOOLS.apk"
	tar -xzf "$TOP/apktools/$APKTOOLS.apk" -C "$TOP/apktools" sbin/apk.static 2>/dev/null
fi

# --- rootfs ---
rm -rf "$ROOT"; mkdir -p "$ROOT"
tar -xpzf "$DL/$mini" -C "$ROOT"
"$APK" --root "$ROOT" --arch aarch64 --usermode --no-scripts --cache-dir "$DL/apkcache" \
	add "${PACKAGES[@]}"

# --- small customisations ---
echo pacman > "$ROOT/etc/hostname"
# root without password, like our busybox system (console/USB access only)
sed -i 's/^root:[^:]*:/root::/' "$ROOT/etc/shadow"
cat > "$ROOT/etc/motd" <<'EOF'

  Alpine Linux on the Nothing Phone (2a) -- mainline kernel, running from RAM.
  Nothing here survives a reboot. No internet: install packages on the PC
  (tools/build-alpine.sh <package...>), then rebuild the vendor_boot image
  (tools/build-vendor-boot.sh) or push into a running phone (tools/alpine-push.sh).

  fastfetch       system info          pacman-dash     dashboard on the panel
  pacman-reboot   reboot [bootloader|recovery|poweroff]

EOF
cat > "$ROOT/etc/profile.d/pacman.sh" <<'EOF'
export PS1='\[\e[1;32m\]alpine\[\e[0m\]@\h:\w# '
# our static tools from the kernel's built-in initramfs (pacman-reboot, pacman-dash, ...)
case ":$PATH:" in *:/pacman/bin:*) ;; *) [ -d /pacman/bin ] && PATH="$PATH:/pacman/bin" ;; esac
EOF

if [[ "$DESKTOP" == 1 ]]; then
	# no GPU driver: drop Mesa's software stack (only libGL/EGL/gbm and Xorg's GL modules use it)
	rm -f "$ROOT"/usr/lib/libLLVM* "$ROOT"/usr/lib/libgallium*
	rm -rf "$ROOT"/usr/lib/dri

	# dbus pre-install script (skipped): system bus user
	grep -q '^messagebus:' "$ROOT/etc/group" || echo 'messagebus:x:101:messagebus' >> "$ROOT/etc/group"
	grep -q '^messagebus:' "$ROOT/etc/passwd" ||
		echo 'messagebus:x:100:101:messagebus:/run/dbus:/sbin/nologin' >> "$ROOT/etc/passwd"
	grep -q '^messagebus:' "$ROOT/etc/shadow" || echo 'messagebus:!::0:::::' >> "$ROOT/etc/shadow"

	# Xorg on our fbdev (pacman-cmdfb), landscape, no input devices (x11vnc injects via XTEST)
	mkdir -p "$ROOT/etc/X11/xorg.conf.d"
	cat > "$ROOT/etc/X11/xorg.conf.d/10-pacman.conf" <<'XEOF'
Section "ServerFlags"
	Option "AutoAddDevices" "false"
	Option "AllowEmptyInput" "true"
	Option "BlankTime" "0"
	Option "StandbyTime" "0"
	Option "SuspendTime" "0"
	Option "OffTime" "0"
EndSection

Section "Module"
	Disable "glx"
EndSection

Section "Device"
	Identifier "pacman-cmdfb"
	Driver "fbdev"
	Option "fbdev" "/dev/fb0"
	Option "ShadowFB" "on"
	Option "Rotate" "CW"
EndSection
XEOF

	# XFCE: 2x scaling (1080x2412 panel), big window decorations, no GL compositor
	X="$ROOT/root/.config/xfce4/xfconf/xfce-perchannel-xml"
	mkdir -p "$X"
	cat > "$X/xsettings.xml" <<'XEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Gdk" type="empty">
    <property name="WindowScalingFactor" type="int" value="2"/>
  </property>
  <property name="Xft" type="empty">
    <property name="DPI" type="int" value="96"/>
  </property>
</channel>
XEOF
	cat > "$X/xfwm4.xml" <<'XEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Default-xhdpi"/>
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XEOF

	# started by /pacman-init instead of the login prompt when present
	mkdir -p "$ROOT/usr/local/bin"
	cat > "$ROOT/usr/local/bin/pacman-desktop" <<'XEOF'
#!/bin/sh
# XFCE on the panel (Xorg on fb0, vt1) + x11vnc on the USB network (PC: vncviewer 172.16.42.1).
export HOME=/root USER=root LOGNAME=root SHELL=/bin/sh
export XDG_RUNTIME_DIR=/run/user/0 PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/pacman/bin
mkdir -p -m 0700 "$XDG_RUNTIME_DIR"

# what package post-install scripts would have done (rootfs is in RAM: every boot)
[ -s /etc/machine-id ] || dbus-uuidgen > /etc/machine-id
mkdir -p /var/lib/dbus /run/dbus && ln -sf /etc/machine-id /var/lib/dbus/machine-id
# without the mime cache gdk-pixbuf cannot identify icons and the XFCE session aborts (Wnck)
[ -f /usr/share/mime/mime.cache ] || update-mime-database /usr/share/mime > /dev/null 2>&1
fc-cache -s > /dev/null 2>&1
gdk-pixbuf-query-loaders --update-cache > /dev/null 2>&1
glib-compile-schemas /usr/share/glib-2.0/schemas > /dev/null 2>&1
for d in /usr/share/icons/*/; do gtk-update-icon-cache -q -f "$d" > /dev/null 2>&1; done
dbus-daemon --system --fork > /dev/null 2>&1

# x11vnc once the X socket exists; only on the USB link, no password
(
	for i in $(seq 1 60); do [ -S /tmp/.X11-unix/X0 ] && break; sleep 1; done
	x11vnc -display :0 -listen 172.16.42.1 -rfbport 5900 -forever -shared -nopw \
		-quiet -bg -o /tmp/x11vnc.log
) &

# XFCE's own xinitrc sets up the session environment (XDG dirs, dbus, xrdb) before
# xfce4-session. Client output also goes to the kernel log so it survives in pstore.
# Hardware keys (power, volume up/down) as X keyboards and the touchscreen as an absolute
# pointer, all through evdev. Device numbers are not fixed, so the config is generated from
# the input devices that exist when X starts (no hotplug: AutoAddDevices is off). If X dies
# quickly with it, the next start runs without it. The touchscreen reports portrait panel
# coordinates; X is rotated CW (RandR "right"), hence the matrix. Override it for a test by
# writing 9 numbers to /tmp/pacman-touch-matrix and restarting X.
KEYS=/etc/X11/xorg.conf.d/20-pacman-keys.conf
rm -f "$KEYS"
if [ ! -e /tmp/pacman-keys-conf.failed ]; then
	n=0
	for d in /sys/class/input/event*; do
		case "$(cat "$d/device/name" 2>/dev/null)" in
		mt6363-keys|mt6779-keypad) ;;
		*FT3681*)
			m="0 1 0 -1 0 1 0 0 1"
			[ -s /tmp/pacman-touch-matrix ] && m=$(cat /tmp/pacman-touch-matrix)
			cat >> "$KEYS" <<KEOF
Section "InputDevice"
	Identifier "pacman-touch"
	Driver "evdev"
	Option "Device" "/dev/input/${d##*/}"
	Option "AutoServerLayout" "on"
	Option "TransformationMatrix" "$m"
EndSection
KEOF
			continue ;;
		*) continue ;;
		esac
		cat >> "$KEYS" <<KEOF
Section "InputDevice"
	Identifier "pacman-keys$n"
	Driver "evdev"
	Option "Device" "/dev/input/${d##*/}"
	Option "AutoServerLayout" "on"
EndSection
KEOF
		n=$((n + 1))
	done
fi

t0=$(cut -d. -f1 /proc/uptime)
xinit /etc/xdg/xfce4/xinitrc -- /usr/bin/Xorg :0 vt1 -nolisten tcp -noreset \
	-logfile /tmp/Xorg.0.log > /tmp/xfce-session.log 2>&1
rc=$?
if [ -e "$KEYS" ] && [ $(( $(cut -d. -f1 /proc/uptime) - t0 )) -lt 20 ]; then
	touch /tmp/pacman-keys-conf.failed
	echo "pacman-desktop: X exited quickly with the keys config, retrying without it" > /dev/kmsg
fi
tail -n 15 /tmp/xfce-session.log | while IFS= read -r l; do echo "pacman-desktop: $l" > /dev/kmsg; done
exit $rc
XEOF
	chmod 0755 "$ROOT/usr/local/bin/pacman-desktop"
	cat >> "$ROOT/etc/motd" <<'XEOF'
  Desktop: XFCE runs on the panel; control it from the PC with a VNC viewer
  (172.16.42.1:5900). Restart it: pkill Xorg (pacman-init starts it again).

XEOF
fi

tar --numeric-owner --owner=0 --group=0 -czf "$OUT" -C "$ROOT" .
say "$(du -sh "$ROOT" | cut -f1) rootfs -> $OUT ($(du -h "$OUT" | cut -f1))"
