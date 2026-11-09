# Nothing Phone (2a) "Pacman" — mainline Linux port

Context for Claude Code. The owner works on Arch Linux (fish shell; use bash for build commands).
User-facing command reference: `docs/COMMANDS.md`, overview: `README.md` — keep both in sync
when commands, images or results change. Personal/local instructions (language, local-only docs)
live in `~/pacman/CLAUDE.local.md`, which is not part of this repository.

**Publishing:** this repo is pushed to GitHub (`new-green/nothing-pacman-mainline`). Everything
committed must be English; local-only files are listed in `.git/info/exclude`. After changing
kernel commits on `linux/` branch `pacman-7.3`, regenerate the series:
`git -C ../linux format-patch -o kernel-patches v7.3.3..pacman-7.3` (delete the old files first).

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
| Kernel | stable 7.3.3 + our patches (branch `pacman-7.3`; old 7.4-rc1 branch `pacman` kept), slim config (MediaTek only), 8 CPUs, GICv3, timer, PSCI, mtk-wdt, ramoops |
| Display | `pacman-cmdfb` fbdev on LK's framebuffer, fbcon, mmap; hides LK's Orange State layer |
| USB | mtu3 peripheral + xsphy u2, `force-vbus`; g_cdc = ACM (ttyGS0) + ECM network (usb0), 42 MB/s PC->phone |
| Shell | busybox root shell on ttyGS0 (PC: /dev/ttyACM0), kernel console on ttyGS0 |
| Thermal | `mtk_therm_intf`: cpu0..7 + gpu zones from MCUPM firmware SRAM, critical 95 °C |
| Reboot | `pacman-reboot bootloader` -> LK fastboot (no key combo needed) |
| SPMI/PMIC | mainline `spmi-mtk-pmif` with MT8195 data reads the MT6363 (chip id 0x63) |
| Keys | power + volume up via MT6363 TOPSTATUS, polled (`mt6363-keys-polled`), `/dev/input/event0` |
| UI | boot log on fbcon, then slim XFCE on Xorg/fbdev (landscape, 2x), controlled over VNC (172.16.42.1:5900); login prompt on tty1 as fallback |
| Missing | clocks, pinctrl (volume down), PMIC core/IRQs, regulators, UFS, touch, battery, Wi-Fi, GPU |
| PMIC SPT | MT6363 Self-Protection Timer reset the phone after 1.5-26 min; init turns it off at boot (SOLVED, see below) |

**Images** (`out/`; a copy of the current pair + SHA256SUMS is in `archive/checkpoint-2026-11-09-xfce-images/`):
- **Current known-good pair:** `pacman-desktop-boot.img` + `pacman-desktop-vendor_boot.img`
  (7.3.3 + 9 patches, DTB test-P, SPT off at boot, Alpine + slim XFCE in an xz ramdisk, 39 MB).
- Also in `out/`: `pacman-alpine-vendor_boot.img` (Alpine without desktop, test-P; default output of
  build-vendor-boot.sh) and `pacman-usb1-vendor_boot.img` (stock Android ramdisk + test-U DTB: no
  SPMI -> the SPT cannot be turned off -> resets after minutes). Both pair with the desktop boot image.
- All other images of 2026-11-09 were moved to `archive/out-2026-11-09/` (7.4-rc1 builds, 7.3.3
  steps, control/debug images; none has the full SPT fix, `pacman-usb2b-boot.img` bootloops).

## Workflow
- Flash (owner approves each time): `adb reboot bootloader` (or `pacman-reboot bootloader` on mainline);
  `fastboot getvar current-slot` = b; `fastboot flash boot_b <boot.img>`;
  `fastboot flash vendor_boot_b <vendor_boot.img>`; `fastboot reboot`.
- Back to stock: `bash tools/to-stock.sh [-n name | --no-log]` — gets the phone into fastboot itself
  (adb, or `pacman-reboot bootloader` over telnet/serial), checks slot b, flashes stock
  boot_b/vendor_boot_b, optionally saves the pstore log to `~/pacman/logs/log-<name>-<date>.txt`.
- Talk to the phone: `tools/pacsh.py --net run 'cmd' [-t s]`, `tools/pacsh.py --net push LOCAL REMOTE [-x]`
  (telnet, own shell per call). Without `--net` it uses the serial shell shared with the owner's
  picocom (see Pitfalls). Screenshot: `tools/screenshot.py [out.png] [--scale f]`.
- Build userspace: `make -C port/ui` (pacman-dash, pacman-reboot); once: `tools/build-busybox.sh`,
  `tools/build-fastfetch.sh`. Kernel:
  `cd linux; export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-;`
  `./scripts/kconfig/merge_config.sh -m .config ../port/pacman.config && make olddefconfig && make -j$(nproc) Image.lz4`;
  `mkbootimg --header_version 4 --kernel arch/arm64/boot/Image.lz4 -o ../out/<name>-boot.img`.
  The built-in initramfs embeds ui/ + busybox + fastfetch: rebuild the kernel after changing them.
- Root filesystem + vendor_boot: `[DESKTOP=1] tools/build-alpine.sh [pkgs]`, then
  `[ROOT=~/pacman/alpine/rootfs-desktop COMP=xz OUT=...] tools/build-vendor-boot.sh hybrid/test-P.img`.
- DTB: edit `hybrid/<name>.dts`, `tools/build-dtb.sh hybrid/<name>.dts` (dtc + Android DT table);
  `tools/build-dtb.sh --check` verifies all committed `.img` files.
- **Before every flash check the kernel size** (LK rule 5). Name new images, don't overwrite known-good ones.
- Checkpoints: tag `checkpoint-2026-11-09-xfce` in port (pushed) and `pacman-checkpoint-2026-11-09-xfce`
  in linux; bundles in `archive/checkpoint-2026-11-09-xfce-*.bundle`. The kernel commits exist only
  locally (+ as kernel-patches/): bundle them again after changing the branch.

## Layout (~/pacman)
- `linux/` shallow clone; branch `pacman-7.3` = v7.3.3 (stable) + our 9 commits: DTS + cmdfb, cmdfb
  mmap, mtu3 force-vbus, mtk_therm_intf, cmdfb hide LK layers, SPMI MT6886, MT6363 polled keys,
  xsphy force-bit backport, SPT attribute. Old branch `pacman` = first 7 on 7.4-rc1 (fa4ad798f).
  Untracked there: `scripts/gen_init_cpio` (build artifact). The config fragment is `port/pacman.config`.
- `port/` (git, master, pushed to GitHub): `pacman.config`, `kernel-patches/` (git am series on
  `v7.3.3`), `drivers/` (copies of our three own drivers), `LICENSE`, `README.md`, `docs/COMMANDS.md`,
  `hybrid/` (DTB sources + wrapped images: test-H = stock + display node, test-U = + USB peripheral,
  **test-P = + SPMI clocks, current**), `ui/` (initramfs: pacman-init.sh, initramfs.list,
  pacman-dash.c, pacman-reboot.c, alpine-enter.sh, /etc files), `tools/`, `arch/` (clean minimal
  DTS, does not boot yet). Local-only, git-excluded: `KOMUTLAR.md`, `README.tr.md`.
- `stock/` read-only backups. `work/` vendor_boot repack (`vb/`, `vb_args.txt` reproduces stock
  byte-for-byte). `out/` images. `logs/` pstore logs, `pl_lk.txt` (stock LK log), `live.dtb`.
  `alpine/` (downloads, apk.static, `rootfs/`, `rootfs-desktop/`), `busybox/`, `fastfetch/`
  third-party sources + static binaries. `screenshots/`. `archive/` old tests, backups, checkpoints.
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
   `/etc` and `/bin` (dangling links to /system/...), `/init`… -> everything of ours lives under
   `/pacman/`, `rdinit=/pacman-init`; init re-points /etc and /bin to /pacman/{etc,bin}.
   Anything that execs a hard-coded /bin/... (getty -> /bin/login!) or follows an absolute
   symlink from outside a chroot (Alpine's /bin/sh -> /bin/busybox) resolves against OUR root.
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

## Userspace
- Built-in initramfs (`ui/initramfs.list`), everything under `/pacman/`: busybox 1.37.0 (static,
  sha256-pinned), fastfetch 2.70.0 (static, commit-pinned), pacman-dash, pacman-reboot, `alpine`
  (chroot helper), `/pacman/etc` (passwd, issue, motd, os-release, udhcpd.conf).
- `/pacman-init` = `ui/pacman-init.sh` (busybox sh, PID 1), in order: mounts proc/sys/devtmpfs/tmpfs;
  applet links; `/etc` and `/bin` -> `/pacman/...` if dangling; hostname; **SPT off**; if `/` is Alpine:
  Alpine PATH + /run; background job that at ~12 s quietens the console and starts
  `/usr/local/bin/pacman-desktop` (XFCE) if present, else getty on tty1; usb0 172.16.42.1 + udhcpd
  (PC gets 172.16.42.2, no router/DNS) + telnetd; respawning shell on /dev/ttyGS0.
  Logs "pacman-init: …" to /dev/kmsg.
- cmdline: `console=ttyGS0,115200 console=tty0` (tty0 last = /dev/console), g_cdc MACs, ramoops, panic=5.

## SPMI + MT6363 keys (2026-11-09, works)
- PMIF/SPMI-master register layout of MT6886 (downstream `mt6xxx_regs` + `mt6853_spmi_regs`) == mainline
  `mt8195_regs`/`mt8195_spmi_regs`; AP uses SW interface channel 2 in both (downstream ignores the DT's
  `swinf_ch_start`). Kernel: `mediatek,mt6886-spmi` -> `mt8195_pmif_arb` (spmi_ver 1: no IRQ setup, the
  probe writes nothing). LK leaves PMIF initialised (INIT_DONE, ARB/INF_EN 0x5ffdf, MST_REQ_EN 1).
- DTB `hybrid/test-P.dts` = test-U + spmi node: clocks = 3x clk26m (0x42) "pmif_sys_ck", "pmif_tmr_ck",
  "spmimst_clk_mux"; `interrupts-extended` removed (parent = mt6886-pinctrl 0x16, no driver -> fw_devlink
  would block the controller forever).
- `drivers/input/keyboard/mt6363-keys-polled.c`: binds the SPMI device "mediatek,mt6363" (usid 4),
  regmap_spmi_ext (16-bit reg, 8-bit val), checks SWCID (0x0b) == 0x63, polls TOPSTATUS (0x1e) every
  20 ms while the input device is open: bit1 power, bit3 "home" = KEY_VOLUMEUP; bit clear = pressed.
  Reads only, except the root-only `spt_enable` attribute. Mainline has no MT6363 MFD/IRQ driver yet (only regulator + auxadc). Volume down is not on
  the PMIC (GPIO -> needs pinctrl).
- Test: Alpine has `evtest`; evtest output piped into /dev/kmsg survives resets via ramoops.

## SOLVED: spontaneous resets = MT6363 Self-Protection Timer (2026-11-09)
- Cause: TF-A enables the PMIC's SPT at every boot (RG_SELFWDT_EN, reg 0xa14 bit 0; see TF-A
  plat/mediatek/drivers/pmic/mt6363/mt6363_psc.c). Nothing in our system satisfies it -> the PMIC
  power-cycles the phone after 1.5-26 min (also on 7.3.3, also unplugged).
- Fix: `mt6363-keys-polled` logs the state and has sysfs `spt_enable`
  (/sys/bus/spmi/devices/0-04/spt_enable); `/pacman-init` writes 0 at every boot. Verified: 30 min
  without reset. Cost: a fully hung kernel is no longer power-cycled by the PMIC (mtk-wdt and the
  long power-key press still work). Needs the SPMI DTB (test-P).
- Investigation notes (kept for reference):
- Silent resets 96-315 s after boot: no oops/panic, no thermal/critical message (console loglevel 8),
  kernel log just stops. Happened with the keys image with AND without key polling, and with the same
  kernel + test-U DTB where SPMI never probes -> NOT caused by our SPMI/keys code.
- LK's log of the boot after such a reset (vs a normal boot): `[PMIC]SELFWDT=0x41` (normal 0x0),
  PONSTS 0x0 (normal 0x14), POFFSTS 0x10 (normal 0x20), `[RGU] STA 0x0` (not the AP watchdog).
  -> the MT6363 PMIC's own watchdog resets the system. Who must feed it (SSPM/SPM firmware? a HW
  signal?) is unknown; no downstream kernel driver touches it.
- Earlier the same day images ran 15 min without resets. Next step: bisect — boot an older image
  (pacman-login-boot.img + pacman-usb1-vendor_boot.img, stock Android ramdisk) and wait 10 min.
- Reading LK's log from mainline: needs a kernel built with `# CONFIG_STRICT_DEVMEM is not set`
  (pacman.config sets it =y again; flip it for debugging), then on the phone:
  `dd if=/dev/mem bs=4096 skip=$((0x33ffb0000/4096)) count=64 | strings | grep -E "RGU|PMIC|SELFWDT"`
  (mblock-10-log_store, 256 KiB at 0x33ffb0000, contains preloader+LK log of the current boot).
- Normal-boot reference: logs/pl_lk.txt (stock, SELFWDT=0x0).

## XFCE desktop (WORKS 2026-11-09)
- `DESKTOP=1 tools/build-alpine.sh` -> `~/pacman/alpine/rootfs-desktop`: xorg-server, xf86-video-fbdev,
  xinit, xfwm4, xfce4-panel, xfdesktop, xfce4-session, xfce4-settings, xfce4-terminal, font-dejavu,
  dbus(-x11), x11vnc. Mesa's libLLVM/libgallium/dri removed (no GPU; 649 MB full xfce4 -> 169 MB).
  `ROOT=.../rootfs-desktop COMP=xz OUT=... tools/build-vendor-boot.sh hybrid/test-P.img` (gzip would
  not fit LK's 64 MiB ramdisk buffer comfortably; kernel has RD_XZ, xz needs --check=crc32).
- /etc/X11/xorg.conf.d/10-pacman.conf: fbdev on /dev/fb0, ShadowFB, Rotate CW, glx disabled, no
  input devices (x11vnc injects). XFCE: Gdk WindowScalingFactor 2, xfwm4 theme Default-xhdpi, no compositing.
- `/usr/local/bin/pacman-desktop` (started by /pacman-init at ~12 s instead of getty; restarted on
  exit, login prompt after 3 quick failures): does what skipped apk post-install scripts would do
  (machine-id, **update-mime-database**, fc-cache, pixbuf loaders, schemas, icon caches), system dbus,
  x11vnc on 172.16.42.1:5900 (no password, USB link only), `xinit /etc/xdg/xfce4/xinitrc -- Xorg :0 vt1`.
  Session output: /tmp/xfce-session.log, last lines also in kmsg ("pacman-desktop:").
- Pitfall found: without /usr/share/mime/mime.cache gdk-pixbuf cannot load icons and the session
  aborts in Wnck (default_icon_at_size) 1 s after start; Xorg.0.log looks clean in that case.
- PC: `gvncviewer 172.16.42.1:0`. Idle: ~520 MB RAM, load 0.4, 41 °C. Only hicolor icons; clock
  shows 1970 (no RTC driver).

## Alpine as root filesystem (stage 4, WORKS 2026-11-09)
- `tools/build-vendor-boot.sh [dtb]`: gzip newc cpio of `~/pacman/alpine/rootfs` (root-owned) replaces
  fragment 00 (type platform) of the stock vendor_boot via `work/vb_args.txt`; fragment 01 (recovery)
  and bootconfig unchanged. 7.6 MB image. LK accepts it.
- The kernel unpacks it over the built-in initramfs: / = Alpine. `/pacman-init` stays PID 1, sees
  /etc/alpine-release -> Alpine PATH first (+/pacman/bin), mounts /run; getty/telnet/serial logins
  land in Alpine (root password emptied by build-alpine.sh; Alpine's /etc/issue on the panel).
- / also contains leftovers from LK's other ramdisks (init, init.real, kernelsu.ko, system/,
  second_stage_resources/...): from init_boot's generic ramdisk and the recovery fragment. Unused.

## Alpine userspace in a chroot (stage 3, WORKS 2026-11-09: 3.24.4, bash, fastfetch with Alpine logo)
- `tools/build-alpine.sh [pkgs]`: Alpine 3.24.4 aarch64 minirootfs (sha256 + GPG, ncopa fingerprint
  pinned) + packages via Alpine's x86_64 `apk.static` 3.0.9 on the PC (`--root --arch aarch64
  --usermode --no-scripts`, signatures checked) -> `~/pacman/alpine/alpine-rootfs.tar.gz` (6.3 MB,
  root-owned). Default extras: bash htop nano fastfetch. No root needed on the PC.
- `tools/alpine-push.sh`: installs `/pacman/bin/alpine` (= `ui/alpine-enter.sh`) via `pacsh --net`, starts
  `nc | tar x` into /tmp/alpine on the phone (setsid, stdin /dev/null), sends the tarball PC -> phone.
- `alpine` on the phone: bind-mounts proc/sys/dev/devpts + tmpfs /tmp, `chroot /tmp/alpine` with a
  clean env; `alpine CMD` runs one command. Our init/dash/network keep running outside.
- The phone has no internet (no NAT on the PC, ufw): add packages on the PC and push again.

## Pitfalls
- The serial shell (ttyACM0) is SHARED with the owner's picocom. If something interactive runs
  there (conspy!), pacsh keystrokes go to it: once conspy forwarded `stty -echo` + a push into
  the owner's tty1 login shell. With the net image ALWAYS use `pacsh.py --net` (telnet, own pty)
  and check `pgrep -a picocom` before using the serial port at all.
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

## Roadmap
The owner wants a usable Linux on the phone but does NOT plan to move it to Linux permanently:
only boot_b/vendor_boot_b are ever written and the phone always goes back to stock.
Done (2026-11-09): boot, display, USB serial + network, thermal, reboot-to-fastboot, Alpine as
root filesystem, SPMI + PMIC keys, SPT fix, slim XFCE over VNC, move to 7.3.3 stable.
Next ideas, roughly by value:
1. Use the keys on the phone itself (power key: blank/unblank or a small menu; needs an input
   driver in Xorg, e.g. xf86-input-libinput) so the desktop is usable without the PC.
2. pinctrl/GPIO for MT6886 (volume down, touch reset/irq), then SPI + the FocalTech touchscreen.
3. A real MT6363 core driver (IRQs, regulators, RTC -> correct clock), cpufreq-hw.
4. Clean minimal DTB (without copied reserved regions); UFS read-only first; battery/charger (MT6375).
References: postmarketOS linux-postmarketos-mediatek-mt6878, mainline MT8188/MT8195/MT8196, TF-A
plat/mediatek.
