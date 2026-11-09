# Nothing Phone (2a) "Pacman" — mainline Linux port

Context for Claude Code. Owner works on Arch Linux (fish shell; bash for build
commands).

## Device
- SoC: MediaTek Dimensity 7200 Pro (MT6886): 6x Cortex-A510 (MIDR 0xd46) + 2x Cortex-A715 (0xd4d)
- 12 GB RAM at 0x40000000, UFS, A/B slots, **active slot b**
- Boot: preloader -> LK (MediaTek lk2). Bootloader unlocked, Magisk root on stock
- boot.img header v4 (kernel only, LZ4 legacy), DTB lives in vendor_boot, init_boot exists
- **`fastboot boot` is not supported**: test by flashing boot_b / vendor_boot_b, restore from stock/
- Panel: DSI **command mode** (Visionox/BOE RM692H5), 1080x2412, framebuffer 0xfe050000,
  stride 1088*4, a8r8g8b8, VRAM 0x1e50000
- Downstream source: github.com/NothingOSS/android_kernel_5.15_nothing_mt6886
  (+ android_kernel_modules_nothing_mt6886)

## Status (2026-11-09)
- Mainline 7.4-rc1 boots: 8 CPUs, GICv3, arch timer, PSCI, mtk-wdt, ramoops
- Boot logs on screen via our driver `drivers/video/fbdev/pacman-cmdfb.c` (fbcon on fb0)
- `ui/pacman-dash.c`: fb0 dashboard, built into the kernel as /pacman-init — written, NOT yet tested on device
- No clocks/pinctrl/PMIC/UFS/USB/input drivers yet (all downstream nodes defer)

## Hard-won rules about LK (do not relearn these)
1. vendor_boot DTB must be an **Android DT table** (magic d7b7ab1e, 1 entry, id 0) wrapping the FDT.
   Raw FDT -> LK never starts the kernel.
2. LK applies Nothing's overlay from dtbo_b (entry 0) to the DTB: base DTB needs `__symbols__`
   (dtc -@) and all labels the overlay references (see overlay-sink dtsi).
3. Do NOT add nodes to `/reserved-memory` or change `/chosen` (adding a reserved region over
   LK's framebuffer stopped boot). LK fills reserved-memory (mblock-*) itself.
4. LK overwrites `model`; it is not usable as a test marker.
5. Framebuffer region is reserved by LK as "map" (normal RAM): ioremap fails ->
   use memremap(MEMREMAP_WB) + dcache_clean_poc.
6. Command-mode frame push: writel(1, mutex+0x20) (mutex0 EN, mutex @0x14001000),
   then DSI_START (DSI0 @0x14017000, +0x00) = 0 then 1.
7. Working DTB today = stock DTB + `pacman-display@14017000` node (`hybrid/test-H.dts`).
   Our clean minimal DTB (`arch/.../mt6886-nothing-pacman.dts`) does not boot yet —
   most likely because it copies LK's reserved regions (rule 3). Next cleanup target.
8. Timing of resets is NOT a reliable success signal. Only trust the pstore log.

## Debugging without a screen
Kernel cmdline (built in, CMDLINE_FORCE) sets ramoops at the stock pstore location
(0x48090000, size 0xe0000, console 0x40000, record 0x1000, ftrace 0x1000, pmsg 0x80000).
After a test: flash stock back, boot Android, then
`adb shell 'su -c "cat /sys/fs/pstore/console-ramoops-0"'`. Warm resets keep RAM;
a long power-key reset may wipe it.
LK's own log (current boot only): `/proc/pl_lk` on stock Android.

## Layout (~/pacman)
- `linux/` mainline tree, our changes on branch `pacman`
- `port/` this repo (DTS, driver, config fragment, ui/, hybrid/ DTB sources, README)
- `stock/` stock partition backups, read-only — NEVER modify or delete
  (nvram/nvdata/nvcfg/proinfo cannot be recovered)
- `work/` vendor_boot repack area: `vb/` + `vb_args.txt`
  (`eval mkbootimg $(cat vb_args.txt) --vendor_boot ...` reproduces stock byte-for-byte)
- `out/` built images, `logs/` pstore logs, `archive/` old tests

Build / flash commands: see README.md.

## Safety rules for Claude
- Always ask the owner before: `fastboot flash`, `fastboot erase`, `fastboot flashing ...`,
  `fastboot set_active`, `dd` to any block device, or anything touching `stock/`.
- Only ever flash `boot_b` and `vendor_boot_b`. Never touch lk, preloader, dtbo, super, userdata, GPT.
- Mainline has no charging/thermal management: keep device tests short.
- Building, compiling and editing files in `port/` and `linux/` is fine without asking.

## Planned next: USB serial console (agreed with owner, not started)
Goal: phone shows up on the PC as /dev/ttyACM0 (g_serial / CDC ACM), later a busybox shell
on ttyGS0 and the kernel console on ttyGS0 (ends the flash -> stock -> pstore loop).
Findings from the stock DTB (`/soc/usb0@11201000`):
- Controller `mediatek,mtu3` (mainline driver, CONFIG_USB_MTU3=y already), reg-names mac/ippc,
  irq SPI 0xa0, already has `maximum-speed = "high-speed"` and `mediatek,force-vbus`, dr_mode "otg".
- PHY `mediatek,xsphy` (`/soc/usb-phy0@11e40000`, u2 port @0x11e40000, u3 @0x11e43400):
  mainline driver exists but CONFIG_PHY_MTK_XSPHY is off -> this is why the last log said
  `usb0: deferred probe pending: wait for supplier usb3-phy0`. PHY "ref" clock is a fixed-clock (fine).
- Controller clocks come from `mediatek,mt6886-pericfg_ao` (no mainline driver) and
  vusb33-supply from a PMIC regulator (no driver) -> both would defer forever.
Stage 1 plan (DTB = test-H.dts + changes to usb0 only):
- clocks -> the existing fixed-clock (phandle 0x42 in stock), drop vusb33-supply
  (dummy regulator), dr_mode = "peripheral", drop usb-role-switch/port, keep only the u2 phy.
- Config: CONFIG_PHY_MTK_XSPHY=y, CONFIG_USB_G_SERIAL=y (built-in, binds to the UDC by itself),
  later CONFIG_U_SERIAL_CONSOLE=y.
- Success = `lsusb` on the PC shows "Gadget Serial" (0525:a4a7) and /dev/ttyACM0 appears.
- Open question: whether preloader/LK leave the SSUSB block powered/clocked. If not, MMIO access
  hangs -> watchdog reset (harmless). Check pstore.
Stage 2: static busybox in the built-in initramfs, shell on /dev/ttyGS0;
PC: `screen /dev/ttyACM0 115200`. Can be combined with the pacman-dash test in one flash.

## Next steps (ideas)
- Test pacman-dash on device
- Clear LK's "Orange State" overlay layer
- Clean minimal DTB without copied reserved regions
- Volume keys (mediatek keypad / PMIC), busybox initramfs
- Long term: MT6886 clock + pinctrl, MT6363/MT6368 PMIC (SPMI), USB gadget, UFS
  (references: postmarketOS linux-postmarketos-mediatek-mt6878, mainline MT8188/MT8195)
