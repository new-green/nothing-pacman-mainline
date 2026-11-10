#!/usr/bin/env bash
# Touchscreen bring-up in one go, while the phone runs a touch image (DTB hybrid/test-T.dts,
# kernel with CONFIG_SPI_MT65XX=m and CONFIG_TOUCHSCREEN_FOCALTECH_FTS_SPI=m) and the USB
# network is up:
#
#   bash ~/pacman/port/tools/touch-bringup.sh [--evtest SECONDS] [--x] [--spi-hz HZ]
#
# 1. checks that the modules match the running kernel (vermagic),
# 2. reads (never writes) the SPI3 clock gate, the SPI source mux and the SPI3 pin modes;
#    stops before loading anything if the gate or the mux is off (touching the SPI block
#    then hangs the bus -> watchdog reset),
# 3. pushes crc-ccitt, spi-mt65xx and focaltech-fts-spi to /tmp and loads them; the SPI rate
#    is set so that SCK is ~6 MHz for the source clock the bootloader selected (the device
#    tree assumes the fastest one, 208 MHz),
# 4. prints the kernel messages and, with --evtest, the touch events for a few seconds
#    (touch the screen), with --x restarts the desktop so Xorg picks the touchscreen up.
set -euo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
LINUX="${LINUX:-$HOME/pacman/linux}"
# MODDIR: take the .ko files from one flat folder instead (e.g. a checkpoint's modules/)
MODDIR="${MODDIR:-}"
EVTEST=0 RESTART_X=0 SPI_HZ=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--evtest) EVTEST="${2:?--evtest SECONDS}"; shift ;;
	--x) RESTART_X=1 ;;
	--spi-hz) SPI_HZ="${2:?--spi-hz HZ}"; shift ;;
	-h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "unknown option $1" >&2; exit 1 ;;
	esac
	shift
done

ph() { python3 -I "$TOOLS/pacsh.py" --net run "$1" -t "${2:-20}"; }
MODS=(lib/crc/crc-ccitt.ko drivers/spi/spi-mt65xx.ko drivers/input/touchscreen/focaltech-fts-spi.ko)
ko() { if [[ -n "$MODDIR" ]]; then echo "$MODDIR/$(basename "$1")"; else echo "$LINUX/$1"; fi; }

echo "== kernel / modules"
running=$(ph 'uname -r' | grep -a -m1 '^[0-9]' | tr -d '\r\n ')
built=$(modinfo -F vermagic "$(ko "${MODS[2]}")" | cut -d' ' -f1)
echo "running $running, modules for $built"
[[ "$running" == "$built" ]] || { echo "mismatch: flash the matching boot image first" >&2; exit 1; }

echo "== read-only checks"
chk=$(ph '
s=$(printf "%08x" $(($(devmem 0x11036010 32))))
c=$(printf "%08x" $(($(devmem 0x10000060 32))))
m=""; for p in 141 142 143 144; do
	m="$m $(( ($(devmem $((0x10005300 + (p / 8) * 0x10)) 32) >> ((p % 8) * 4)) & 0xf ))"
done
echo "gate=$(( (0x$s >> 15) & 1 )) sel=$(( (0x$c >> 24) & 7 )) muxoff=$(( (0x$c >> 31) & 1 )) pins=$m"
')
line=$(echo "$chk" | grep -a '^gate=' | tail -1)
[[ -n "$line" ]] || { echo "unexpected answer: $chk" >&2; exit 1; }
echo "$line"
eval "$(echo "$line" | sed 's/pins=.*//')"
pins=$(echo "$line" | sed 's/.*pins= *//')
rates=(26000000 208000000 182000000 156000000 136500000 124800000 104000000 78000000)
src=${rates[$sel]}
echo "SPI3 clock gate: $([[ $gate == 0 ]] && echo open || echo GATED)," \
     "spi_sel=$sel (~$((src / 1000000)) MHz)$([[ $muxoff == 1 ]] && echo ', MUX OFF'), SPI3 pin modes:$pins (want 2 2 2 2)"
if [[ $gate != 0 || $muxoff != 0 ]]; then
	echo "SPI3 is not clocked: not loading anything (would hang the bus)." >&2
	echo "Opening it needs an MMIO write (pericfg_ao +0x2c bit 15): ask the owner first." >&2
	exit 1
fi
[[ "$pins" == "2 2 2 2" ]] || echo "warning: SPI3 pins are not in SPI mode, the chip will probably not answer"
# DT says 208 MHz; ask for 6 MHz * 208 / real source so that the divider gives ~6 MHz
[[ -n "$SPI_HZ" ]] || SPI_HZ=$(( 6000000 * 208000000 / src ))
echo "spi_hz=$SPI_HZ (SCK ~ $(( src / ((208000000 + SPI_HZ - 1) / SPI_HZ) / 1000 )) kHz)"

echo "== push + load"
for m in "${MODS[@]}"; do
	python3 -I "$TOOLS/pacsh.py" --net push "$(ko "$m")" "/tmp/$(basename "$m")" > /dev/null
done
ph "
lsmod | grep -q crc_ccitt || insmod /tmp/crc-ccitt.ko
lsmod | grep -q spi_mt65xx || insmod /tmp/spi-mt65xx.ko
lsmod | grep -q focaltech_fts_spi && rmmod focaltech_fts_spi
insmod /tmp/focaltech-fts-spi.ko spi_hz=$SPI_HZ
sleep 2
dmesg | grep -iE 'spi|fts|focal|ft3681' | tail -n 15
grep -A4 FT3681 /proc/bus/input/devices | grep -E 'N:|H:'
" 40

if [[ $EVTEST -gt 0 ]]; then
	echo "== touch the screen now ($EVTEST s)"
	ph "
ev=\$(grep -A4 FT3681 /proc/bus/input/devices | sed -n 's/.*\\(event[0-9]*\\).*/\\1/p' | head -1)
[ -n \"\$ev\" ] && timeout $EVTEST evtest /dev/input/\$ev | grep -E 'POSITION|BTN_TOUCH|SYN_REPORT' | head -n 60
" $((EVTEST + 15))
fi

if [[ $RESTART_X == 1 ]]; then
	echo "== restarting the desktop (Xorg picks up the touchscreen)"
	ph 'pkill -x Xorg; sleep 8; grep -E "pacman-touch|FT3681" /tmp/Xorg.0.log | head -n 8' 30
fi
