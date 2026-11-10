# Mainline Linux on the Nothing Phone (2a) ("Pacman", MediaTek MT6886)

Bring-up of a mainline Linux kernel (7.3.3 stable) on the Nothing Phone (2a), codename *Pacman*
(MediaTek Dimensity 7200 Pro / MT6886). It boots from the stock bootloader (LK) into a small
Alpine Linux that runs entirely from RAM, with the touchscreen, the three hardware keys, CPU
frequency scaling, a root shell and a network link over USB, and a phone UI on the panel:
[sxmo](https://sxmo.org) out of the box, or Phosh (GNOME's phone shell) loaded from the PC.
Nothing is written to the phone's storage; it goes back to stock Android with one command.

> Not affiliated with Nothing Technology. This is experimental work on an unlocked device.
> Flashing the wrong partition can brick a phone — read [Safety](#safety) first.

## Branches

| Branch | Adds | UI |
|---|---|---|
| `master` | boot, display, USB, thermal, keys, touchscreen (loaded by hand), 12 kernel patches | XFCE over VNC |
| `sxmo` | modules loaded at boot, panel margins, opaque display layer, 14 patches | sxmo on the panel |
| `phosh` | KMS display driver (`pacman-drm`), Phosh loaded into RAM over USB, 15 patches | sxmo, or Phosh |

Each branch builds on the previous one; this README describes `phosh`.

## Status

| Area | State |
|---|---|
| Boot | LK starts our kernel from `boot_b` + `vendor_boot_b`; 8 CPUs, GICv3, arch timer, PSCI, watchdog, ramoops (pstore) |
| Display | KMS driver `pacman-drm` on the pipeline LK leaves running (DSI **command-mode** panel), `/dev/fb0` through fbdev emulation, rounded corners and camera hole left out, LK's "Orange State" layer hidden |
| USB | Device mode (mtu3 + xsphy, forced VBUS): CDC ACM serial shell + kernel console, CDC ECM network (~40 MB/s) |
| Touch | FocalTech FT3681 over SPI3 (own driver, polled at 60 Hz), multitouch, loaded at boot |
| Keys | Power + volume up (MT6363 PMIC over SPMI, polled), volume down (SoC keypad) |
| CPU | cpufreq through the MCUPM firmware (`mediatek-cpufreq-hw`): A510 up to 2.0 GHz, A715 up to 2.8 GHz |
| Thermal | CPU0-7 + GPU temperatures from the MCUPM firmware, critical trip at 95 °C (power off) |
| Userspace | Alpine Linux 3.24 aarch64 in RAM (replaces Android's ramdisk in `vendor_boot`); built-in initramfs with busybox, telnet over USB, fastfetch |
| UI | sxmo (X11/dwm, touch gestures, on-screen keyboard); Phosh on KMS (CPU rendering), sent from the PC after boot; XFCE over VNC |
| Reboot | `pacman-reboot bootloader` reboots straight into fastboot |
| Not yet | Clocks, pinctrl (touch interrupt), PMIC core/IRQs, regulators, RTC (the clock is set from the PC), UFS storage, battery/charging, audio, Wi-Fi, modem, GPU |

Nothing is stored on the phone: there is no storage driver, everything lives in RAM.

## How it works (short)

- **Boot chain.** Preloader -> LK. The kernel goes into `boot_b` (boot image v4, LZ4), the device
  tree into `vendor_boot_b` as an Android DT table. LK applies Nothing's DT overlay from `dtbo_b`
  and fills in reserved memory itself. LK refuses kernels much above ~20 MiB LZ4 / ~44 MiB
  decompressed, hence the MediaTek-only kernel config.
- **Device tree.** For now we use the stock DTB plus our own changes (`hybrid/test-T.dts`): a
  display node, USB in peripheral mode, the SPMI controller on the fixed 26 MHz clock, the SoC
  keypad and SPI3 with the touchscreen (the vendor touch node from LK's overlay is redirected to an
  unused node, see CLAUDE.md). A clean minimal DTS is in `arch/` but does not boot yet.
- **Display.** LK leaves the display pipeline running. `pacman-drm` copies what changed into
  LK's framebuffer and starts a frame on the command-mode panel; it also makes the layer opaque
  (LK leaves per-pixel alpha on, and X writes alpha 0).
- **USB.** The mainline mtu3 driver works once VBUS is forced (the charger IC senses VBUS, not
  the USB block) — see `kernel-patches/0003`.
- **Temperatures and CPU frequency.** The MCUPM co-processor's firmware runs the sensors and the
  DVFS; `kernel-patches/0004` exposes the temperatures, mainline `mediatek-cpufreq-hw` drives
  the frequencies.
- **Userspace.** LK unpacks the vendor ramdisk on top of our built-in initramfs, so everything of
  ours lives under `/pacman/`. `tools/build-vendor-boot.sh` puts Alpine Linux there instead of
  Android's ramdisk: `/` becomes Alpine and our init (`/pacman-init`) loads the modules and
  starts the UI. Phosh (~800 MB) does not fit into `vendor_boot`, so `tools/phosh-up.sh` sends it
  into RAM over USB and starts it in a chroot.

Details, register maps and pitfalls: [`CLAUDE.md`](CLAUDE.md) (project notes).

## Layout

The tools assume this layout under `~/pacman` (override with `PACMAN=...` where supported):

```
~/pacman/
├── linux/    v7.3.3 + kernel-patches/ applied (branch "phosh")
├── port/     this repository
├── alpine/   Alpine downloads and the root filesystems built by tools/build-alpine.sh
├── stock/    your own backups of the stock partitions (never published)
├── work/     vendor_boot repack area (vb/, vb_args.txt from unpack_bootimg)
└── out/      built images
```

This repository:

| Path | What |
|---|---|
| `kernel-patches/` | Kernel changes on top of stable `v7.3.3`, apply with `git am` |
| `pacman.config` | Kernel config fragment (merge on top of arm64 `defconfig`) |
| `drivers/`, `arch/` | Copies of our drivers and the (not yet booting) clean DTS |
| `hybrid/` | Device trees: `test-T.dts` (current) = stock DTB + display + USB peripheral + SPMI + keypad + touch; `.img` = DT-table-wrapped (`tools/build-dtb.sh`) |
| `ui/` | Initramfs: `pacman-init.sh` (PID 1), `pacman-keysd.c`, `pacman-dash.c`, `pacman-reboot.c`, `phosh-start.sh`, `/etc` files, `initramfs.list` |
| `tools/` | PC-side tools: builds, flashing back to stock, phone shell, sending root filesystems, screenshots, checkpoints |
| `docs/COMMANDS.md` | Command reference |

## Build

```bash
# kernel sources
git clone --depth 1 --branch v7.3.3 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git ~/pacman/linux
cd ~/pacman/linux && git switch -c phosh && git am ../port/kernel-patches/*.patch

# userspace for the built-in initramfs
make -C ~/pacman/port/ui                      # pacman-dash, pacman-reboot, pacman-keysd (aarch64, static)
bash ~/pacman/port/tools/build-busybox.sh
bash ~/pacman/port/tools/build-fastfetch.sh

# kernel image: modules FIRST, the initramfs embeds the touch/SPI/cpufreq modules
cd ~/pacman/linux && export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make defconfig && ./scripts/kconfig/merge_config.sh -m .config ../port/pacman.config && make olddefconfig
make -j$(nproc) modules && make -j$(nproc) Image.lz4
mkbootimg --header_version 4 --kernel arch/arm64/boot/Image.lz4 -o ../out/pacman-boot.img

# vendor_boot = your stock vendor_boot with our DTB and Alpine + sxmo instead of Android's ramdisk
unpack_bootimg --boot_img ~/pacman/stock/vendor_boot_b.img --out ~/pacman/work/vb --format=mkbootimg > ~/pacman/work/vb_args.txt
UI=sxmo bash ~/pacman/port/tools/build-alpine.sh
ROOT=~/pacman/alpine/rootfs-sxmo COMP=xz OUT=~/pacman/out/pacman-sxmo-vendor_boot.img \
  bash ~/pacman/port/tools/build-vendor-boot.sh

# optional: Phosh root filesystem (sent to the phone after boot, see Run)
UI=phosh bash ~/pacman/port/tools/build-alpine.sh
```

Needs: an aarch64 cross toolchain (`aarch64-linux-gnu-gcc`, glibc for static builds),
`mkbootimg`/`unpack_bootimg`, `lz4`, `xz`, `openssl` (Phosh), `adb`/`fastboot`, Python 3,
cmake/ninja (fastfetch). No root rights needed: Alpine packages are installed with Alpine's own
`apk.static` (signatures checked).
**Check the kernel size before flashing** (`ls -l arch/arm64/boot/Image*`): stay well below
~20 MiB LZ4 / ~44 MiB (this config: ~29.5 / 16.2 MiB).

## Run

```bash
adb reboot bootloader
fastboot getvar current-slot                      # must be b
fastboot flash boot_b        ~/pacman/out/pacman-boot.img
fastboot flash vendor_boot_b ~/pacman/out/pacman-sxmo-vendor_boot.img
fastboot reboot
```

The boot log scrolls on the panel, then sxmo starts (swipe up from the bottom edge for the
keyboard, down from the top edge for the menu). On the PC the phone shows up as `/dev/ttyACM0`
and as a network interface (phone `172.16.42.1`, the PC gets `172.16.42.2` by DHCP):

```bash
telnet 172.16.42.1                    # root shell (or: picocom -b 115200 /dev/ttyACM0)
bash ~/pacman/port/tools/phosh-up.sh  # switch to Phosh (lock screen PIN 1234)
bash ~/pacman/port/tools/to-stock.sh  # back to stock, no key combo needed
```

More: [`docs/COMMANDS.md`](docs/COMMANDS.md).

## Safety

- Back up your partitions first (at least `boot_*`, `vendor_boot_*`, `dtbo_*`, `nvram`, `nvdata`,
  `nvcfg`, `proinfo`, `persist`). The `nv*`/`proinfo` partitions hold per-device calibration
  and identity data that cannot be recreated.
- Only ever flash `boot_b` and `vendor_boot_b` (or the slot that is active on your phone).
  Never touch `lk`, `preloader`, `dtbo`, `super`, `userdata` or the partition table.
- `fastboot boot` is not supported by this bootloader: test images are flashed and the stock
  images flashed back (`tools/to-stock.sh`).
- There is no charging control or battery level under mainline yet; keep sessions reasonably short.
- The USB link is unauthenticated (root telnet, VNC without password, Phosh PIN 1234): it only
  reaches the PC the phone is plugged into.

## License

GPL-2.0, see [`LICENSE`](LICENSE). Kernel patches and drivers carry their own SPDX headers.
Third-party components (busybox, fastfetch, Alpine Linux, sxmo, Phosh) are downloaded and built
or installed by the tools and keep their own licenses.
