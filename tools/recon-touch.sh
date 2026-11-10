#!/usr/bin/env bash
# Stage 0 recon for the touchscreen: reads (never writes) what LK leaves configured.
# Run on the PC while the phone runs mainline with the USB network up:
#   bash ~/pacman/port/tools/recon-touch.sh
# Layouts from the vendor kernel: pinctrl-mt6886.c (GPIO base 0x10005000: DIR +0x000,
# DIN +0x200, MODE +0x300, 0x10 per register, mode = 4 bits/pin), clk-mt6886-peri.c
# (pericfg_ao 0x11036000: gate status PERAO0 +0x10, bit 15 = SPI3, 1 = gated off).
set -euo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
python3 -I "$TOOLS/pacsh.py" --net run '
G=0x10005000
rd() { printf "%08x" $(($(devmem $(($1)) 32))); }
pin() {  # pin name
	m=$(( ($(devmem $((G + 0x300 + ($1 / 8) * 0x10)) 32) >> (($1 % 8) * 4)) & 0xf ))
	d=$(( ($(devmem $((G + 0x000 + ($1 / 32) * 0x10)) 32) >> ($1 % 32)) & 1 ))
	i=$(( ($(devmem $((G + 0x200 + ($1 / 32) * 0x10)) 32) >> ($1 % 32)) & 1 ))
	printf "GPIO%-3d %-14s mode=%d dir=%s level=%d\n" $1 $2 $m $([ $d = 1 ] && echo out || echo in) $i
}
echo "== pins (SPI3_A = mode 2 on 141..144; SPI3_B = mode 3 on 93..96)"
pin 5 touch-reset; pin 96 touch-irq
pin 141 SPI3_A_CLK; pin 142 SPI3_A_CSB; pin 143 SPI3_A_MO; pin 144 SPI3_A_MI
pin 93 SPI3_B_CLK; pin 94 SPI3_B_CSB; pin 95 SPI3_B_MO
echo "== pericfg_ao gates (bit set = clock gated OFF)"
s=$(rd 0x11036010); echo "PERAO0_STA=$s  spi3(bit15)=$(( (0x$s >> 15) & 1 ))"
echo "PERAO1_STA=$(rd 0x11036014) PERAO2_STA=$(rd 0x11036018)"
echo "== SPI source clock: topckgen CLK_CFG_5 (0x10000060) bits 24-26 = spi_sel, bit 31 = mux off"
c=$(rd 0x10000060); m=$(( (0x$c >> 24) & 7 ))
set -- 26 208 182 156 136.5 124.8 104 78
shift $m; echo "CLK_CFG_5=$c spi_sel=$m (~$1 MHz) off=$(( (0x$c >> 31) & 1 ))"
echo "== SPI3 controller @0x11013000 (only meaningful if its clock runs)"
if [ $(( (0x$s >> 15) & 1 )) = 0 ]; then
	for o in 0x00 0x04 0x18 0x1c 0x28; do printf "  +%s=%s" $o $(rd $((0x11013000 + o))); done; echo
else
	echo "  skipped: clock is gated, reading could hang the bus"
fi
echo "== touch irq line sampled 20x over 2 s (touch the screen now)"
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	printf "%d" $(( ($(devmem $((G + 0x200 + (96 / 32) * 0x10)) 32) >> (96 % 32)) & 1 )); usleep 100000
done; echo
' -t 30
