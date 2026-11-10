# Mainline Linux on the Nothing Phone (2a) ("Pacman", MediaTek MT6886)

Bring-up of a mainline Linux kernel (7.3.3 stable) on the Nothing Phone (2a), codename *Pacman*
(MediaTek Dimensity 7200 Pro / MT6886). It boots from the stock bootloader (LK), shows the
boot log on the panel, gives a root shell and a network link over USB, reads CPU/GPU
temperatures and boots straight into a small Alpine Linux userspace, all without a PC.

> Not affiliated with Nothing Technology. This is experimental work on an unlocked device.
> Flashing the wrong partition can brick a phone — read [Safety](#safety) first.

## Status

| Area | State |
|---|---|
| Boot | LK starts our kernel from `boot_b` + `vendor_boot_b`; 8 CPUs, GICv3, arch timer, PSCI, watchdog, ramoops (pstore) |
| Display | Framebuffer on the DSI **command-mode** panel (`pacman-cmdfb`): fbcon boot log, mmap for userspace, LK's "Orange State" warning layer hidden |
| USB | Device mode (mtu3 + xsphy, forced VBUS): CDC ACM serial shell + kernel console, CDC ECM network (~42 MB/s) |
| Userspace | Built-in initramfs: busybox, login prompt on the panel, telnet over USB, fastfetch, `pacman-dash` dashboard |
| Alpine | Boots straight into Alpine Linux 3.24 aarch64 (it replaces Android's ramdisk in `vendor_boot`); runs from RAM |
| Keys | Power + volume up (MT6363 PMIC over SPMI, polled), volume down (SoC keypad); power = blank/unblank the panel, all three reach Xorg |
| Touch | FocalTech FT3681 over SPI3 (own driver, polled at 60 Hz), multitouch, works in XFCE |
| Desktop | Slim XFCE on Xorg/fbdev (landscape, 2x scaling), controlled from the PC over VNC |
| Thermal | CPU0-7 + GPU temperatures from the MCUPM firmware, critical trip at 95 °C (power off) |
| Reboot | `pacman-reboot bootloader` reboots straight into fastboot |
| Not yet | Clocks, pinctrl, PMIC core/IRQs, regulators, UFS storage, cpufreq, battery/charging, Wi-Fi, GPU, on-screen keyboard |

Nothing is stored on the phone: there is no storage driver yet, everything lives in RAM.

## How it works (short)

- **Boot chain.** Preloader -> LK. The kernel goes into `boot_b` (boot image v4, LZ4), the device
  tree into `vendor_boot_b` as an Android DT table. LK applies Nothing's DT overlay from `dtbo_b`
  and fills in reserved memory itself. LK refuses kernels much above ~20 MiB LZ4 / ~44 MiB
  decompressed, hence the MediaTek-only kernel config.
- **Device tree.** For now we use the stock DTB plus our own changes (`hybrid/test-T.dts`): a
  display node, USB in peripheral mode, the SPMI controller on the fixed 26 MHz clock, the SoC
  keypad and SPI3 with the touchscreen (the vendor touch node from LK's overlay is redirected to an
  unused node, see CLAUDE.md). A clean minimal DTS is
  in `arch/` but does not boot yet.
- **Display.** LK leaves the display pipeline running. `pacman-cmdfb` maps LK's framebuffer and
  kicks a frame to the command-mode panel every 50 ms.
- **USB.** The mainline mtu3 driver works once VBUS is forced (the charger IC senses VBUS, not
  the USB block) — see `kernel-patches/0003`.
- **Temperatures.** The LVTS sensors are run by firmware on the MCUPM co-processor, which
  publishes them in SRAM; `kernel-patches/0004` exposes them as thermal zones.
- **Userspace.** LK unpacks the vendor ramdisk on top of our built-in initramfs, so everything of
  ours lives under `/pacman/`. `tools/build-vendor-boot.sh` puts Alpine Linux there instead of
  Android's ramdisk: `/` becomes Alpine and our init (`/pacman-init`) hands logins to it.

Details, register maps and pitfalls: [`CLAUDE.md`](CLAUDE.md) (project notes).

## Layout

The tools assume this layout under `~/pacman` (override with `PACMAN=...` where supported):

```
~/pacman/
├── linux/    v7.3.3 + kernel-patches/ applied (branch "pacman-7.3")
├── port/     this repository
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
| `ui/` | Initramfs: `pacman-init.sh` (PID 1), `pacman-dash.c`, `pacman-reboot.c`, `/etc` files, `initramfs.list` |
| `tools/` | PC-side tools: flashing back to stock, phone shell, Alpine, screenshots, builds |
| `docs/COMMANDS.md` | Command reference |

## Build

```bash
# kernel
git clone --depth 1 --branch v7.3.3 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git ~/pacman/linux
cd ~/pacman/linux && git switch -c pacman-7.3 && git am ../port/kernel-patches/*.patch

# userspace for the built-in initramfs
make -C ~/pacman/port/ui                      # pacman-dash, pacman-reboot (aarch64, static)
bash ~/pacman/port/tools/build-busybox.sh
bash ~/pacman/port/tools/build-fastfetch.sh

# kernel image
cd ~/pacman/linux && export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make defconfig && ./scripts/kconfig/merge_config.sh -m .config ../port/pacman.config && make olddefconfig
make -j$(nproc) Image.lz4
mkbootimg --header_version 4 --kernel arch/arm64/boot/Image.lz4 -o ../out/pacman-boot.img

# vendor_boot = your stock vendor_boot with our DTB and Alpine instead of Android's ramdisk
unpack_bootimg --boot_img ~/pacman/stock/vendor_boot_b.img --out ~/pacman/work/vb --format=mkbootimg > ~/pacman/work/vb_args.txt
bash ~/pacman/port/tools/build-alpine.sh
bash ~/pacman/port/tools/build-vendor-boot.sh        # -> ~/pacman/out/pacman-alpine-vendor_boot.img
```

Needs: an aarch64 cross toolchain (`aarch64-linux-gnu-gcc`, glibc for static builds),
`mkbootimg`/`unpack_bootimg`, `lz4`, `adb`/`fastboot`, Python 3, cmake/ninja (fastfetch).
**Check the kernel size before flashing** (`ls -l arch/arm64/boot/Image*`): stay well below
~20 MiB LZ4 / ~44 MiB.

## Run

```bash
adb reboot bootloader
fastboot getvar current-slot                      # must be b
fastboot flash boot_b        ~/pacman/out/pacman-boot.img
fastboot flash vendor_boot_b ~/pacman/out/pacman-alpine-vendor_boot.img
fastboot reboot
```

The boot log scrolls on the panel, then Alpine's `pacman login:` prompt appears (root, no password).
On the PC the phone shows up as `/dev/ttyACM0` and as a network interface (phone
`172.16.42.1`, the PC gets `172.16.42.2` by DHCP):

```bash
picocom -b 115200 /dev/ttyACM0        # or: telnet 172.16.42.1
conspy 1                              # (on the phone) type into the panel's console
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
- There is no charging control under mainline yet; keep sessions reasonably short.

## License

GPL-2.0, see [`LICENSE`](LICENSE). Kernel patches and drivers carry their own SPDX headers.
Third-party components (busybox, fastfetch, Alpine Linux) are downloaded and built by the
tools and keep their own licenses.
