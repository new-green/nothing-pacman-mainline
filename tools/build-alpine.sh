#!/usr/bin/env bash
# Builds a small Alpine Linux aarch64 userspace on the PC, without root and without
# giving the phone internet access:
#   ~/pacman/alpine/rootfs/                 the tree
#   ~/pacman/alpine/alpine-rootfs.tar.gz    what tools/alpine-push.sh sends to the phone
#
#   bash ~/pacman/port/tools/build-alpine.sh [extra packages...]
#   DESKTOP=1 bash ~/pacman/port/tools/build-alpine.sh    slim XFCE desktop -> rootfs-desktop/
#   UI=sxmo bash ~/pacman/port/tools/build-alpine.sh      sxmo (X11/dwm phone UI) -> rootfs-sxmo/
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
UI="${UI:-xfce}"
[[ "$UI" == sxmo || "$UI" == phosh ]] && DESKTOP=1
SUFFIX=""
if [[ "$DESKTOP" == 1 ]]; then
	PACKAGES+=(xorg-server xf86-video-fbdev xf86-input-evdev xinit font-dejavu dbus dbus-x11 x11vnc)
	if [[ "$UI" == phosh ]]; then
		# Phosh (GNOME's phone shell) on phoc (wlroots, pixman renderer: no GPU driver), on KMS
		# (pacman-drm). seatd hands phoc the DRM/input devices; eudev for libinput.
		PACKAGES+=(phosh phoc squeekboard seatd eudev gnome-console gnome-calculator
			adwaita-icon-theme font-dejavu)
		SUFFIX="-phosh"
	elif [[ "$UI" == sxmo ]]; then
		# sxmo's X11 session (dwm) and the helpers its start hook launches through superd;
		# a 7 MB Nerd font instead of the 31 MB DejaVu one sxmo asks for (alias below)
		PACKAGES+=(sxmo-utils sxmo-dwm sxmo-dmenu sxmo-st sxmobar svkbd lisgd superd bonsai dunst xob
			unclutter-xfixes autocutsel xdotool xinput xrandr xsetroot xmodmap xprop xset xrdb xclip
			xsel inotify-tools xdg-user-dirs libnotify xprintidle feh eudev font-droid-sans-mono-nerd)
		SUFFIX="-sxmo"
	else
		PACKAGES+=(xfwm4 xfce4-panel xfdesktop xfce4-session xfce4-settings xfce4-terminal)
		SUFFIX="-desktop"
	fi
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
	# no GPU driver: drop Mesa's software stack (only libGL/EGL/gbm and Xorg's GL modules use it).
	# Not for Phosh: phoc links libEGL, which links libgallium directly (Mesa 25); its rootfs goes
	# to RAM over USB anyway.
	if [[ "$UI" != phosh ]]; then
		rm -f "$ROOT"/usr/lib/libLLVM* "$ROOT"/usr/lib/libgallium*
		rm -rf "$ROOT"/usr/lib/dri
	fi

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
	echo "$UI" > "$ROOT/etc/pacman-ui"
	if [[ "$UI" == phosh ]]; then
		# Too big for vendor_boot (LK's 64 MiB ramdisk buffer): tools/alpine-push.sh sends it
		# into RAM (/tmp/phosh) after boot and /usr/local/bin/pacman-phosh starts it in a chroot.
		grep -q '^user:' "$ROOT/etc/passwd" || {
			echo 'user:x:1000:1000:user:/home/user:/bin/sh' >> "$ROOT/etc/passwd"
			echo 'user:x:1000:' >> "$ROOT/etc/group"
			echo 'user:!::0:::::' >> "$ROOT/etc/shadow"
			for g in video input audio tty seat; do
				sed -i "s/^\($g:[^:]*:[^:]*:\)\(.*\)$/\1\2,user/; s/:,user$/:user/" "$ROOT/etc/group"
			done
		}
		mkdir -p "$ROOT/home/user" "$ROOT/etc/phosh" "$ROOT/usr/local/bin"
		# Phosh's lock screen asks for the user's password: PIN 1234 (USB-only device, RAM only)
		sed -i "s#^user:[^:]*:#user:$(openssl passwd -6 1234):#" "$ROOT/etc/shadow"
		# apk --usermode drops setuid bits: PAM's password helper (the lock screen runs as the
		# user) and dbus' system service launcher need them
		chmod 4755 "$ROOT/usr/sbin/unix_chkpwd"
		chmod 4750 "$ROOT/usr/libexec/dbus-daemon-launch-helper"
		# gsd-power needs UPower/logind, which we do not have: as a required component its
		# crash loop ends the session ("Something went wrong")
		sed -i 's/org.gnome.SettingsDaemon.Power;//' "$ROOT/usr/share/gnome-session/sessions/phosh.session"
		# 1080 px wide panel: scale 3 = the 360 px wide layout Phosh is designed for
		cat > "$ROOT/etc/phosh/phoc.ini" <<'XEOF'
[output:DSI-1]
scale = 3
XEOF
		# Phosh only unblanks through gnome-session presence, which needs logind: wake helper
		cat > "$ROOT/usr/local/bin/pacman-power-wake" <<'XEOF'
#!/usr/bin/python3
# Phosh blanks the screen on a power key press, but only unblanks through gnome-session's
# presence status (idle monitor), which does not work without systemd/logind here. When the
# power key is pressed while Phosh's screen saver is active, wake it over D-Bus ourselves.
# Started by gnome-session (/etc/xdg/autostart/pacman-power-wake.desktop).
import glob, os, struct, subprocess

EV_KEY, KEY_POWER = 1, 116
EVENT = struct.Struct("llHHi")		# struct input_event on 64-bit
SS = ["gdbus", "call", "--session", "--dest", "org.gnome.ScreenSaver",
      "--object-path", "/org/gnome/ScreenSaver", "--method"]

def power_key_device():
    for d in glob.glob("/sys/class/input/event*"):
        try:
            if open(d + "/device/name").read().strip() == "mt6363-keys":
                return "/dev/input/" + os.path.basename(d)
        except OSError:
            pass
    return None

def main():
    dev = power_key_device()
    if not dev:
        return
    with open(dev, "rb", buffering=0) as f:
        while True:
            data = f.read(EVENT.size)
            if len(data) < EVENT.size:
                return
            _, _, typ, code, value = EVENT.unpack(data)
            if typ != EV_KEY or code != KEY_POWER or value != 1:
                continue
            active = subprocess.run(SS + ["org.gnome.ScreenSaver.GetActive"],
                                    capture_output=True, text=True).stdout
            if "true" in active:
                subprocess.run(SS + ["org.gnome.ScreenSaver.SetActive", "false"],
                               capture_output=True)

main()
XEOF
		chmod 0755 "$ROOT/usr/local/bin/pacman-power-wake"
		cat > "$ROOT/etc/xdg/autostart/pacman-power-wake.desktop" <<'XEOF'
[Desktop Entry]
Type=Application
Name=Power key wake-up (pacman)
Exec=/usr/local/bin/pacman-power-wake
NoDisplay=true
X-GNOME-AutoRestart=true
XEOF
		cat > "$ROOT/usr/local/bin/pacman-phosh" <<'XEOF'
#!/bin/sh
# Starts Phosh inside the chroot (run as root by the host's phosh-start). Log: /tmp/phosh.log
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
log() { echo "pacman-phosh: $*" > /dev/kmsg; }

# what package post-install scripts would have done (in RAM: every start)
[ -s /etc/machine-id ] || dbus-uuidgen > /etc/machine-id
mkdir -p /var/lib/dbus /run/dbus && ln -sf /etc/machine-id /var/lib/dbus/machine-id
chgrp messagebus /usr/libexec/dbus-daemon-launch-helper && chmod 4750 /usr/libexec/dbus-daemon-launch-helper
[ -f /usr/share/mime/mime.cache ] || update-mime-database /usr/share/mime > /dev/null 2>&1
glib-compile-schemas /usr/share/glib-2.0/schemas > /dev/null 2>&1
gdk-pixbuf-query-loaders --update-cache > /dev/null 2>&1
fc-cache -s > /dev/null 2>&1
for d in /usr/share/icons/*/; do gtk-update-icon-cache -q -f "$d" > /dev/null 2>&1; done

chown -R user:user /home/user
mkdir -p /run/user/1000 && chown user:user /run/user/1000 && chmod 0700 /run/user/1000
# pacman-power-wake reads the power key as the user (single-user device)
chmod 0666 /dev/input/event*

# The panel rows hidden by pacman-drm's margins are not part of the output, the touchscreen
# still reports the whole panel: map its y range onto the shown rows (libinput calibration).
P=/sys/module/pacman_drm/parameters
[ -d $P ] || P=/sys/module/pacman_cmdfb/parameters
st=$(LC_ALL=C awk -v t="$(cat $P/top_margin 2>/dev/null || echo 0)" \
	-v b="$(cat $P/bottom_margin 2>/dev/null || echo 0)" \
	'BEGIN { y = 2412 - t - b; printf "%.6f %.6f", 2412 / y, -t / y }')
mkdir -p /etc/udev/rules.d
echo "ATTRS{name}==\"FocalTech FT3681 touchscreen\", ENV{LIBINPUT_CALIBRATION_MATRIX}=\"1 0 0 0 $st\"" \
	> /etc/udev/rules.d/90-pacman-touch.rules

# libinput (phoc) wants udev-processed devices; net devices stay untouched (usb0 keeps its name).
# Our /run is the chroot's own, so checks look at sockets here, not at processes (pgrep sees the
# host's daemons too). A udevd of the host desktop (sxmo) is stopped: one udevd per kernel.
if [ ! -S /run/udev/control ]; then
	pkill -x udevd; sleep 1
	udevd --daemon
	udevadm trigger --subsystem-match=input --subsystem-match=drm --action=add
	udevadm settle -t 5
fi
[ -S /run/dbus/system_bus_socket ] || dbus-daemon --system --fork
# seatd gives phoc (as "user") the DRM and input devices
if [ ! -S /run/seatd.sock ]; then
	seatd -g user > /tmp/seatd.log 2>&1 &
	sleep 1
fi

log "starting phosh-session as user (log /tmp/phosh.log)"
exec su -s /bin/sh user -c 'exec env -i HOME=/home/user USER=user LOGNAME=user SHELL=/bin/sh \
	PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin XDG_RUNTIME_DIR=/run/user/1000 \
	XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Phosh:GNOME LIBSEAT_BACKEND=seatd \
	WLR_RENDERER=pixman GSK_RENDERER=cairo LANG=C.UTF-8 \
	phosh-session > /tmp/phosh.log 2>&1'
XEOF
		chmod 0755 "$ROOT/usr/local/bin/pacman-phosh"
	fi
	if [[ "$UI" == sxmo ]]; then
		# sxmo is a portrait UI: no rotation
		sed -i '/Option "Rotate"/d' "$ROOT/etc/X11/xorg.conf.d/10-pacman.conf"
		# device profile (SXMO_DEVICE_NAME=pacman is set by pacman-desktop)
		cat > "$ROOT/usr/bin/sxmo_deviceprofile_pacman.sh" <<'XEOF'
#!/bin/sh
# Nothing Phone (2a) on mainline (pacman port): no modem, audio or LEDs yet.
export SXMO_NO_MODEM=1 SXMO_NO_AUDIO=1 SXMO_DISABLE_LEDS=1
export SXMO_TOUCHSCREEN_ID="pacman-touch"
for d in /sys/class/input/event*; do
	case "$(cat "$d/device/name" 2>/dev/null)" in
	*FT3681*) export SXMO_LISGD_INPUT_DEVICE="/dev/input/${d##*/}" ;;
	esac
done
XEOF
		chmod 0755 "$ROOT/usr/bin/sxmo_deviceprofile_pacman.sh"
		# sxmo refuses to run as root: its session runs as "user" (Xorg stays root)
		grep -q '^user:' "$ROOT/etc/passwd" || {
			echo 'user:x:1000:1000:user:/home/user:/bin/sh' >> "$ROOT/etc/passwd"
			echo 'user:x:1000:' >> "$ROOT/etc/group"
			echo 'user:!::0:::::' >> "$ROOT/etc/shadow"
			for g in video input audio tty; do
				sed -i "s/^\($g:[^:]*:[^:]*:\)\(.*\)$/\1\2,user/; s/:,user$/:user/" "$ROOT/etc/group"
			done
		}
		echo 'permit nopass user' > "$ROOT/etc/doas.conf"
		mkdir -p "$ROOT/home/user"
		# 1080x2412 panel: scale sxmo's 11 pt fonts up
		printf 'Xft.dpi: 288\n' > "$ROOT/home/user/.Xresources"
		mkdir -p "$ROOT/usr/local/bin"
		cat > "$ROOT/usr/local/bin/pacman-sxmo-session" <<'XEOF'
#!/bin/sh
# xinit client for sxmo: sxmo refuses to run as root, so the session runs as "user"
# (Xorg itself stays root for fb0/vt). Rootfs files are root-owned (built as a cpio
# without owners), so the home and runtime dirs are handed over here at every start.
chown -R user:user /home/user
mkdir -p /run/user/1000 && chown user:user /run/user/1000 && chmod 0700 /run/user/1000
# lisgd (gestures) and bonsaid read the input devices as the user; single-user device
chmod 0666 /dev/input/event*
# lisgd uses libinput, which only accepts devices udev has processed: run udevd, but
# trigger the input subsystem only (a triggered net device could get renamed -> no usb0)
if command -v udevd > /dev/null && ! pgrep -x udevd > /dev/null; then
	udevd --daemon
	udevadm trigger --subsystem-match=input --action=add
	udevadm settle -t 5
fi
# sxmo replaces ~/.Xresources (Xft.dpi 192) on first start; raise the DPI from its xinit
# file (sourced before dwm starts). Same configversion as the template: no migration.
X=/home/user/.config/sxmo/xinit
mkdir -p "${X%/*}"
cp /usr/share/sxmo/appcfg/xinit_template "$X"
printf 'echo "Xft.dpi: 288" | xrdb -merge -\n' >> "$X"
chown -R user:user /home/user/.config
exec su -s /bin/sh user -c 'exec env -i HOME=/home/user USER=user LOGNAME=user SHELL=/bin/sh \
	PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin XDG_RUNTIME_DIR=/run/user/1000 \
	DISPLAY=:0 SXMO_DEVICE_NAME=pacman /usr/bin/sxmo_dwminit.sh'
XEOF
		chmod 0755 "$ROOT/usr/local/bin/pacman-sxmo-session"
		mkdir -p "$ROOT/etc/fonts/conf.d"
		cat > "$ROOT/etc/fonts/conf.d/60-pacman-sxmo.conf" <<'XEOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>Sxmo</family>
    <prefer><family>DroidSansM Nerd Font</family></prefer>
  </alias>
</fontconfig>
XEOF
	fi

	# XFCE: 2x scaling (1080x2412 panel), big window decorations, no GL compositor
	[[ "$UI" == sxmo ]] || {
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
	}

	# started by /pacman-init instead of the login prompt when present
	mkdir -p "$ROOT/usr/local/bin"
	cat > "$ROOT/usr/local/bin/pacman-desktop" <<'XEOF'
#!/bin/sh
# XFCE or sxmo (/etc/pacman-ui) on the panel (Xorg on fb0, vt1) + x11vnc on the USB network
# (PC: vncviewer 172.16.42.1).
UI=$(cat /etc/pacman-ui 2>/dev/null || echo xfce)
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
			# The panel rows hidden by pacman_cmdfb's margins are not part of the X screen:
			# map panel y to the shown rows (s, t), then rotate for XFCE (X is rotated CW).
			P=/sys/module/pacman_cmdfb/parameters
			[ -d $P ] || P=/sys/module/pacman_drm/parameters
			st=$(LC_ALL=C awk -v t="$(cat $P/top_margin 2>/dev/null || echo 0)" \
				-v b="$(cat $P/bottom_margin 2>/dev/null || echo 0)" \
				-v y="$(cut -d, -f2 /sys/class/graphics/fb0/virtual_size)" \
				'BEGIN { printf "%.6f %.6f", (y + t + b) / y, -t / y }')
			if [ "$UI" = sxmo ]; then
				m="1 0 0 0 $st 0 0 1"
			else
				m="0 $st -1 0 1 0 0 1"
			fi
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

CLIENT=/etc/xdg/xfce4/xinitrc
if [ "$UI" = sxmo ]; then
	# sxmo handles the power key itself (screen off via DPMS -> our fb_blank)
	kill $(pidof pacman-keysd) 2> /dev/null
	CLIENT=/usr/local/bin/pacman-sxmo-session
fi

t0=$(cut -d. -f1 /proc/uptime)
xinit "$CLIENT" -- /usr/bin/Xorg :0 vt1 -nolisten tcp -noreset \
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
