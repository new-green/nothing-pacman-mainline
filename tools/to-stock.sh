#!/usr/bin/env bash
# Back to stock: flashes the stock boot_b + vendor_boot_b, boots Android and
# saves the pstore log of the last (mainline) boot under ~/pacman/logs/.
#
# Usage:
#   bash ~/pacman/port/tools/to-stock.sh            # flash + reboot + log
#   bash ~/pacman/port/tools/to-stock.sh --no-log   # flash + reboot only
#   bash ~/pacman/port/tools/to-stock.sh -n NAME    # log name: logs/log-NAME-<date>.txt
#
# The script gets the phone into fastboot itself: from Android with `adb reboot bootloader`,
# from the mainline shell on USB with `pacman-reboot bootloader`. If neither is there
# (e.g. mainline hung) it waits for power + volume down, SHORT press; a long reset may
# wipe RAM and pstore.
#
# Safety: only boot_b and vendor_boot_b are written; stock/ is only read.

set -euo pipefail

PACMAN="${PACMAN:-$HOME/pacman}"
STOCK="$PACMAN/stock"
LOGDIR="$PACMAN/logs"
BOOT_IMG="$STOCK/boot_b.img"
VBOOT_IMG="$STOCK/vendor_boot_b.img"
PART_SIZE=67108864          # 64 MiB: size of the stock backups
FASTBOOT_WAIT=120           # s
ANDROID_WAIT=240            # s

want_log=1
name="stock"
while [[ $# -gt 0 ]]; do
	case "$1" in
	--no-log) want_log=0 ;;
	-n|--name) name="${2:?-n needs a name}"; shift ;;
	-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
	*) echo "Unknown argument: $1" >&2; exit 2 ;;
	esac
	shift
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

command -v fastboot >/dev/null || die "fastboot not found"
command -v adb >/dev/null || die "adb not found"

# --- 1. Stock images present and the right size (read only) ---
for img in "$BOOT_IMG" "$VBOOT_IMG"; do
	[[ -r "$img" ]] || die "Cannot read: $img"
	size=$(stat -c %s "$img")
	[[ "$size" -eq "$PART_SIZE" ]] || die "$img is $size bytes, expected $PART_SIZE"
done
say "Stock images OK (2 x 64 MiB)"

# --- 2. Get the phone into fastboot ---
fb_present() { [[ -n "$(fastboot devices 2>/dev/null)" ]]; }

if ! fb_present; then
	if [[ "$(adb get-state 2>/dev/null)" == "device" ]]; then
		say "Phone runs Android: adb reboot bootloader"
		adb reboot bootloader
	elif [[ -e /dev/ttyACM0 && -n "$(lsusb -d 0525:a4a7 2>/dev/null; lsusb -d 0525:a4aa 2>/dev/null)" ]]; then
		# 0525:a4a7 = g_serial (stage 2), 0525:a4aa = g_cdc (serial + USB network)
		# mainline + busybox shell on ttyGS0 (stage 2): reboot-mode -> LK fastboot.
		# The shell dies with the reboot, so pacsh's timeout is expected.
		# Prefer telnet (own shell): the serial shell may be running conspy for the owner.
		if ping -c 1 -W 1 172.16.42.1 >/dev/null 2>&1; then
			say "Phone runs mainline: pacman-reboot bootloader (USB network, telnet)"
			python3 -I "$(dirname "$0")/pacsh.py" --net run 'pacman-reboot bootloader' -t 3 >/dev/null 2>&1 || true
		else
			say "Phone runs mainline: pacman-reboot bootloader (USB serial)"
			python3 -I "$(dirname "$0")/pacsh.py" run 'pacman-reboot bootloader' -t 3 >/dev/null 2>&1 || true
		fi
	else
		say "Waiting for fastboot (power + volume down, short press)..."
	fi
	for ((i = 0; i < FASTBOOT_WAIT; i++)); do
		fb_present && break
		sleep 1
	done
	fb_present || die "no fastboot device within ${FASTBOOT_WAIT} s"
fi
say "Fastboot device: $(fastboot devices | head -1)"

# --- 3. Active slot must be b ---
slot=$(fastboot getvar current-slot 2>&1 | awk -F': *' '/current-slot:/{print $2; exit}' | tr -d '\r ')
[[ "$slot" == "b" || "$slot" == "_b" ]] || die "Active slot is '$slot' (expected b) - nothing was written"
say "Active slot: b"

# --- 4. Flash (boot_b and vendor_boot_b only) ---
say "boot_b <- $BOOT_IMG"
fastboot flash boot_b "$BOOT_IMG"
say "vendor_boot_b <- $VBOOT_IMG"
fastboot flash vendor_boot_b "$VBOOT_IMG"

say "Rebooting"
fastboot reboot

if [[ "$want_log" -eq 0 ]]; then
	say "Done (no log taken)"
	exit 0
fi

# --- 5. Let Android boot, fetch the pstore log ---
say "Waiting for Android (at most ${ANDROID_WAIT} s)..."
timeout "$ANDROID_WAIT" adb wait-for-device || die "no adb device; fetch the log by hand later"
for ((i = 0; i < ANDROID_WAIT; i++)); do
	[[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] && break
	sleep 1
done
sleep 3     # let pstore and su settle

mkdir -p "$LOGDIR"
out="$LOGDIR/log-$name-$(date +%F-%H%M).txt"
say "pstore log -> $out  (Magisk may ask for su approval on the phone the first time)"
if ! adb exec-out "su -c 'cat /sys/fs/pstore/console-ramoops-0'" > "$out" || [[ ! -s "$out" ]]; then
	rm -f "$out"
	warn "console-ramoops-0 unreadable or empty. pstore files present:"
	adb shell "su -c 'ls -l /sys/fs/pstore/'" || true
	exit 1
fi

say "Saved: $out ($(wc -l < "$out") lines)"
# pstore has bit flips -> grep -a
command grep -a -m1 "Linux version" "$out" || true
echo "--- last 5 lines ---"
tail -n 5 "$out"
