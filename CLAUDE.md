# Nothing Phone (2a) "Pacman" — mainline Linux port

Context for Claude Code. Owner works on Arch Linux (fish shell; use bash for build commands)
User-facing command cheat sheet: `docs/COMMANDS.md`
— keep it in sync when commands or images change.

## Safety rules (always)
- **Ask the owner before**: `fastboot flash|erase|flashing|set_active`, `dd` to any block device,
  anything touching `~/pacman/stock/`. Approval for one flash does not cover the next one.
- Only ever flash **`boot_b`** and **`vendor_boot_b`**. Never lk, preloader, dtbo, super,
  userdata, GPT. Stay on slot b (`fastboot getvar current-slot` must say b).
- `stock/` is read-only: nvram/nvdata/nvcfg/proinfo backups cannot be recovered.
- No charging management on mainline: keep tests reasonably short. Thermal is covered (critical
  trip 95 °C powers off), battery level is not visible.
- Building/editing in `port/` and `linux/` needs no permission. Commit only when asked.
- Read-only probing of the phone (pacsh run, devmem reads) is fine; MMIO **writes** only with a
  stated reason (they can hang the bus -> watchdog reset).

## Device
- MediaTek Dimensity 7200 Pro (MT6886): 6x Cortex-A510 (MIDR 0xd46) + 2x Cortex-A715 (0xd4d);
  little max 2.0 GHz, big max 2.8 GHz (LK leaves them at ~1.25 / 1.0 GHz).
- 12 GB RAM at 0x40000000 (~10.6 GB visible to Linux), UFS, A/B slots, **active slot b**.
- Boot chain: preloader -> LK (MediaTek lk2), bootloader unlocked, Magisk root on stock.
  boot.img header v4 (kernel only, LZ4 legacy); DTB in vendor_boot; init_boot exists.
  **`fastboot boot` is not supported** — test by flashing, return with `tools/to-stock.sh`.
- Panel: DSI **command mode** (Visionox/BOE RM692H5), 1080x2412, LK framebuffer 0xfe050000,
  stride 1088*4, a8r8g8b8.
- Downstream source (vendor 5.15): github.com/NothingOSS/android_kernel_5.15_nothing_mt6886
  (branch `mt6886/Pacman/t`) + android_kernel_modules_nothing_mt6886. `gh` is logged in.

## What works (2026-11-09)
| Area | State |
|---|---|
| Kernel | mainline 7.4-rc1 + our patches, slim config (MediaTek only), 8 CPUs, GICv3, timer, PSCI, mtk-wdt, ramoops |
| Display | `pacman-cmdfb` fbdev on LK's framebuffer, fbcon, mmap; hides LK's Orange State layer |
| USB | mtu3 peripheral + xsphy u2, `force-vbus`; g_cdc = ACM (ttyGS0) + ECM network (usb0), 42 MB/s PC->phone |
| Shell | busybox root shell on ttyGS0 (PC: /dev/ttyACM0), kernel console on ttyGS0 |
| Thermal | `mtk_therm_intf`: cpu0..7 + gpu zones from MCUPM firmware SRAM, critical 95 °C |
| Reboot | `pacman-reboot bootloader` -> LK fastboot (no key combo needed) |
| UI | `pacman-dash` on fb0: uptime, per-core load + °C, GPU °C, memory, loadavg |
| Missing | clocks, pinctrl, PMIC (SPMI), regulators, UFS, input (touch/keys), battery, Wi-Fi, GPU |

**Images** (`out/`, always paired with `out/pacman-usb1-vendor_boot.img`, DTB = `hybrid/test-U.img`):
- `pacman-net-boot.img` — newest **known-good**: serial shell, USB network, thermal, reboot, temp dash.
- `pacman-ovl-boot.img` — net + cmdfb hides LK's Orange State layer at probe. Not yet booted
  (the same register write worked by hand with devmem).
- `pacman-dashtemp-boot.img` — previous good (g_serial only, no network).
- Older: `pacman-therm-boot.img`, `pacman-slim-boot.img`, `pacman-usb2-boot.img` (all good), `pacman-usb2b-boot.img` (bootloops, too big).

## Workflow
- Flash (owner approves): `adb reboot bootloader`; `fastboot flash boot_b <img>`;
  `fastboot flash vendor_boot_b out/pacman-usb1-vendor_boot.img`; `fastboot reboot`.
- Back to stock: `bash tools/to-stock.sh -n <name>` — reboots mainline into fastboot via
  `pacman-reboot bootloader` (or Android via adb), checks slot b, flashes stock boot_b/vendor_boot_b,
  waits for Android, saves pstore console log to `~/pacman/logs/log-<name>-<date>.txt`.
- Talk to the phone: `tools/pacsh.py run 'cmd' [-t s]`, `tools/pacsh.py push LOCAL REMOTE [-x]`
  (gzip+base64 over ttyACM0, md5-checked, ~16 MB/s into RAM). Close picocom first
  (`pgrep -a picocom`), two readers split the output. Owner uses `picocom -b 115200 /dev/ttyACM0`.
- Build: `make -C port/ui` (pacman-dash, pacman-reboot); `tools/build-busybox.sh`,
  `tools/build-fastfetch.sh` (once); kernel:
  `cd linux; export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-;`
  `./scripts/kconfig/merge_config.sh -m .config ../port/pacman.config && make olddefconfig && make -j$(nproc) Image.lz4`;
  `mkbootimg --header_version 4 --kernel arch/arm64/boot/Image.lz4 -o ../out/<name>-boot.img`.
- vendor_boot (only when the DTB changes): `cd work; cp ../port/hybrid/<dtb>.img vb/dtb;`
  `eval mkbootimg $(cat vb_args.txt) --vendor_boot ../out/<name>-vendor_boot.img`.
  DTB sources are decompiled stock DTBs: `linux/scripts/dtc/dtc -I dts -O dtb` (no -@, `__symbols__`
  already present), then wrap in an Android DT table (see rule 1 below).
- **Before every flash check the kernel size** (see LK rules). Name new images, don't overwrite known-good ones.

## Layout (~/pacman)
- `linux/` mainline, branch `pacman`: DTS + cmdfb, cmdfb mmap, mtu3 force-vbus, mtk_therm_intf.
  `linux/pacman.config` is a stale untracked copy — the real fragment is `port/pacman.config`.
- `port/` (git, master): `pacman.config`, `drivers/` (copies of our drivers), `kernel-patch/`,
  `hybrid/` (DTB sources: test-H = stock + display node, **test-U = test-H + USB peripheral**),
  `ui/` (pacman-init.sh, initramfs.list, pacman-dash.c, pacman-reboot.c, os-release, udhcpd.conf),
  `tools/`, `docs/COMMANDS.md`, `README.md`, `arch/` (clean minimal DTS, does not boot yet).
- `stock/` read-only backups. `work/` vendor_boot repack (`vb/`, `vb_args.txt` reproduces stock
  byte-for-byte). `out/` images. `logs/` pstore logs, `pl_lk.txt` (LK log), `live.dtb`.
  `busybox/`, `fastfetch/` third-party sources + static binaries. `archive/` old tests.
- `~/pacman/CLAUDE.md` is a symlink to this file.

## LK / boot rules (hard-won — do not relearn)
1. vendor_boot DTB must be an **Android DT table** (magic d7b7ab1e, 1 entry, id 0) wrapping the FDT.
   Raw FDT -> LK never starts the kernel.
2. LK applies Nothing's overlay from dtbo_b (entry 0): the base DTB needs `__symbols__` and every
   label the overlay references. Keep nodes/labels like `/soc/usb0@11201000/port` for that reason.
3. Do NOT add nodes to `/reserved-memory` or change `/chosen` (a reserved region over LK's
   framebuffer stopped boot). LK fills reserved-memory (mblock-*) itself.
4. LK overwrites `model`; not usable as a marker.
5. **Kernel size limit**: Image 44.6 MiB / lz4 20.3 MiB bootloops (preloader every 13-20 s, kernel
   never reaches USB); 43.4 / 19.1 MiB boots. Limit is ~20 MiB lz4 or ~44 MiB (0x2c00000)
   decompressed — unknown which. Stock lz4 = 19.7 MiB. Slim config now gives 29.6 / 16.0 MiB.
   LK loads the ramdisk into a separate 64 MiB buffer (mb_ramdisk @0x66f00000; stock Android
   vendor ramdisk uses 29.6 MiB of it).
6. LK's Android vendor ramdisk is unpacked **on top of** our built-in initramfs and brings `/bin`,
   `/etc` (dangling link to /system/etc), `/init`… -> everything of ours lives under `/pacman/`,
   `rdinit=/pacman-init`.
7. Kernel cmdline is built in (`CMDLINE_FORCE`); edit it in `port/pacman.config`.
8. Reset timing is not a success signal; trust USB enumeration (PC `journalctl -k`) and pstore.

## Hardware notes
**Display.** `pacman-cmdfb` (drivers/video/fbdev): LK's framebuffer is reserved as "map" (normal
RAM) -> memremap(MEMREMAP_WB), `dcache_clean_poc` + frame kick every 50 ms: `writel(1, mutex+0x20)`
(mutex0 EN, mutex @0x14001000), DSI_START (DSI0 @0x14017000 +0x00) 0 then 1. `.fb_mmap` =
`vm_iomap_memory` with cacheable prot (matches the WB alias). OVL blocks: ovl0 @0x14002000,
ovl0_2l @0x14003000, ovl1_2l @0x14004000. MT6886 OVL regs (downstream mtk_disp_ovl.c):
SRC_CON +0x2c (bits 0-3 = layer L0-L3 enable), DATAPATH_EXT_CON +0x324 (bits 0-2 = EL0-EL2),
layer addr +0xf40+0x20n, ext layer addr +0xfb0+0x10n, RDMA_CTRL(n). As LK leaves it: ovl1_2l L0 =
our fb (0xfe050000, pitch 4352); **ovl0 L1 = "Orange State" warning** (buffer 0xfea68000, 1084x2412,
alpha) blended on top. Clearing ovl0 SRC_CON bit 1 removes it (verified live); cmdfb now clears
every enabled L/EL layer whose address != our fb at probe (param `pacman_cmdfb.hide_lk_layers`).

**USB.** DT `/soc/usb0@11201000` (mtu3) + `/soc/usb-phy0@11e40000` (xsphy). test-U changes: clocks
= clk26m fixed-clock (0x42) "sys_ck", no vusb33-supply, phys = u2 only, dr_mode peripheral,
`mediatek,u3p-dis-msk = <1>` (else mtu3 waits for the U3 MAC clock: "clks of sts1 are not stable"),
u2 phy without nvmem-cells (efuse "mediatek,devinfo" has no driver). SSUSB is powered/clocked by LK.
VBUS is sensed by the charger IC -> our mtu3 patch honours `mediatek,force-vbus` (VBUS_FRC_EN|VBUS_ON
in U3D_MISC_CTRL); without it the gadget pulls D+ but never enumerates.
g_serial = 0525:a4a7; g_cdc = 0525:a4aa (fixed MACs via `g_cdc.dev_addr/host_addr` in cmdline).

**Thermal.** LVTS is run by MCUPM firmware (started by LK); it publishes signed millidegrees in SRAM
0x114000 (DT `therm-intf@114000`, "mediatek,therm_intf"): CPU n at +4n, GPU +0x180, CPU headroom
+0x20, limit/cur freq kHz +0x200/+0x210 (little, big), max temp +0x220. Unused slots = 0x27bc86aa.
Layout: downstream drivers/thermal/mediatek/thermal_interface.h. +0x330 = firmware reboot
temperature (writable — don't). Idle 35-38 °C. `mediatek,cpufreq-hw` node also exists
(perf domains @0x11bc10/0x11bd30) -> candidate for mainline `ARM_MEDIATEK_CPUFREQ_HW`.

**Reboot mode.** `watchdog@1c007000/reboot-mode` (syscon-reboot-mode, TOPRGU +0x24, mask 0xf):
charger 1, recovery 2, bootloader 3, … `SYSCON_REBOOT_MODE=y` (defconfig). PSCI does the reset
(prio 129 > mtk-wdt 128); the register survives and LK honours it.

**Memory.** Stock DTB defines 1.25 GiB CMA (ssmr 288 MiB, ssheap 960 MiB, + 32 MiB default),
released after rootfs is mounted -> tmpfs rootfs limit shows ~4.7 GiB, /tmp ~5.3 GiB.

## Userspace (built-in initramfs, `port/ui/initramfs.list`)
- `/pacman-init` = `ui/pacman-init.sh` (busybox sh, PID 1): mounts proc/sys/devtmpfs/tmpfs/devpts,
  `busybox --install -s /pacman/bin`, `/etc` -> `/pacman/etc`, hostname `pacman`, starts
  pacman-dash, (net image) usb0 172.16.42.1 + udhcpd (gives the PC 172.16.42.2, no router/DNS) +
  telnetd, then a respawning `setsid -c sh -i` on /dev/ttyGS0. Logs "pacman-init: …" to /dev/kmsg.
- `/pacman/bin`: busybox 1.37.0 (static, sha256-pinned), fastfetch 2.70.0 (static, commit-pinned,
  all optional libs off), pacman-dash, pacman-reboot. `/pacman/etc`: os-release, udhcpd.conf.
- cmdline: `console=ttyGS0,115200 console=tty0` (tty0 last = /dev/console), ramoops params, panic=5.

## Pitfalls
- PC runs **ufw** (default deny incoming): phone -> PC TCP connections are blocked. Always let
  the PC initiate (PC -> phone nc/telnet/VNC). Don't change the owner's firewall without asking.
- Background jobs in the interactive ttyGS0 shell get SIGTTIN if they read the tty (busybox nc
  does): run them as `setsid sh -c '... < /dev/null' < /dev/null > /dev/null 2>&1 &`.
- busybox `ip` has no `-br`.
- pstore logs contain bit flips -> file(1) says "data"; this shell's `grep` wrapper (ugrep -I)
  silently skips them: use `command grep -a`.
- A freshly reset ttyACM0 has echo ON: the console's buffered boot log can be echoed back into
  the phone shell as input. termios persists raw across replugs afterwards; pacsh sends ^C on open.
- `ui/Makefile`: never `CC ?=` (make predefines CC=cc -> silently builds x86-64).
- busybox `setsid` forks-and-returns if the caller is a process group leader; fine from the
  non-interactive init script.
- Non-English locales may use a decimal comma: `printf %f` with dots fails in bash -> use `LC_ALL=C`.

## Roadmap (agreed with owner: "real Linux desktop")
1. Done: USB network (verified: DHCP, ping, telnet port, 200 MB at 42 MB/s md5-checked).
   Orange State found and removed (live); boot `pacman-ovl-boot.img` to confirm the driver version.
2. Alpine Linux aarch64 rootfs built on the PC, transferred over USB network into RAM, switch_root.
3. Xorg + xf86-video-fbdev (rotate to landscape) + XFCE, controlled from the PC via x11vnc.
4. Later: replace the Android vendor ramdisk with our own (≈60 MiB room), cpufreq-hw, clean
   minimal DTB (without copied reserved regions), PMIC (MT6363/MT6368 over SPMI) -> keys,
   regulators, UFS (read-only first), touch, battery. References: postmarketOS
   linux-postmarketos-mediatek-mt6878, mainline MT8188/MT8195.
