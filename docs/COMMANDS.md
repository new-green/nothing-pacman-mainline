# Command reference

Everyday commands for the Nothing Phone (2a) mainline port. Paths assume the `~/pacman`
layout from the [README](../README.md). Flash commands only ever write **`boot_b`** and
**`vendor_boot_b`** (use your active slot).

---

## 1. Test cycle (no key combo needed)

```bash
# stock Android -> mainline
adb reboot bootloader
fastboot getvar current-slot                 # must be "b"
fastboot flash boot_b        ~/pacman/out/pacman-touch1-boot.img
fastboot flash vendor_boot_b ~/pacman/out/pacman-touch1-vendor_boot.img
fastboot reboot

# ... try things on the phone (sections 2-4) ...

# mainline -> stock Android (+ kernel log of the last boot)
bash ~/pacman/port/tools/to-stock.sh -n test1
```

`to-stock.sh` gets the phone into fastboot by itself: `adb reboot bootloader` from Android,
`pacman-reboot bootloader` over the USB network (or serial) from mainline. If the phone does
not answer (kernel hung), press **power + volume down** briefly — a long press may wipe RAM and
with it the pstore log.

| Option | Does |
|---|---|
| `to-stock.sh` | back to stock, save the log as `logs/log-stock-<date>.txt` |
| `to-stock.sh -n NAME` | log name `logs/log-NAME-<date>.txt` |
| `to-stock.sh --no-log` | back to stock only |
| `to-stock.sh -h` | help |

It expects your stock backups as `~/pacman/stock/boot_b.img` and `vendor_boot_b.img`
(64 MiB each), checks they are there and the right size, and refuses to write if the active
slot is not b.

---

## 2. The phone's shell (while mainline runs)

### Interactive
```bash
picocom -b 115200 /dev/ttyACM0        # exit: Ctrl-A then Ctrl-X
telnet 172.16.42.1                    # root shell without password, USB link only
```
Press **Enter** after connecting. Kernel messages mixed into the shell? Quieten them:
`echo N > /sys/module/printk/parameters/ignore_loglevel; dmesg -n 1`

### Scripted: `tools/pacsh.py`
```bash
cd ~/pacman/port/tools
python3 pacsh.py --net run 'uname -a'                  # run a command
python3 pacsh.py --net run 'long command' -t 60        # timeout (default 10 s)
python3 pacsh.py --net push ~/file /tmp/file           # PC -> phone RAM (md5-checked)
python3 pacsh.py --net push ~/program /tmp/program -x  # -x: make executable
```
`--net` uses telnet and opens a shell of its own every time. Without `--net` it uses the
serial shell, which is shared with your picocom session: close picocom first and make sure
nothing interactive (e.g. `conspy`) runs there, or it receives the keystrokes.

The phone has no storage yet: everything pushed lives in RAM and is gone after a reboot.

---

## 3. USB network

Besides the serial port the phone shows up as a network interface (USB id `0525:a4aa`).
The phone is `172.16.42.1`; it hands the PC `172.16.42.2` by DHCP — no default route and no
DNS, so the PC's own internet connection is not affected.

```bash
ping 172.16.42.1
telnet 172.16.42.1                    # needs a telnet client (e.g. inetutils)
```
If the PC runs a firewall that drops incoming connections, let the PC open every connection
(PC -> phone), as all tools here do. Large files (~40 MB/s):
```bash
# on the phone:  nc -l -p 9000 > /tmp/file
# on the PC:
python3 -c 'import socket,sys; s=socket.create_connection(("172.16.42.1",9000)); s.sendall(open(sys.argv[1],"rb").read())' ~/file
```

### Screenshot
```bash
python3 ~/pacman/port/tools/screenshot.py               # ~/pacman/screenshots/screen-<date>.png
python3 ~/pacman/port/tools/screenshot.py shot.png --scale 0.5
```
Reads the phone's framebuffer (`/dev/fb0`) over the USB network.

---

## 4. On the phone

### Keys and touchscreen
Power (short press) blanks/unblanks the panel (`pacman-keysd`); any key wakes it. Power, volume up
and volume down also reach Xorg as keys. The touchscreen driver is still a module: load it after
each boot (it checks the SPI3 clock gate first, read-only):
```sh
bash ~/pacman/port/tools/touch-bringup.sh --x          # load + restart X so it uses the touchscreen
bash ~/pacman/port/tools/touch-bringup.sh --evtest 10   # load + show touch events for 10 s
```

### Login prompt on the panel
The kernel log scrolls on the panel, at ~12 s a `pacman login:` prompt appears (user **root**,
no password). The phone has no keyboard or touch driver yet, so type from the PC:
```sh
conspy 1          # in picocom/telnet: attach to the panel's console
                  # exit: press Esc three times quickly
```
Leave conspy (Esc x3) before closing picocom, otherwise it keeps running and forwards
whatever arrives on the serial port to the panel. After ~12 s kernel messages are no longer
printed to the consoles (so they don't overwrite the prompt); `dmesg` has all of them.

### Commands
```sh
fastfetch                          # system info
pacman-reboot bootloader           # reboot into fastboot
pacman-reboot recovery             # reboot into recovery
pacman-reboot poweroff             # power off
pacman-reboot                      # plain reboot (mainline again)
pacman-dash                        # dashboard on the panel: load + temperatures

# temperatures (millidegrees C)
for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type) $(cat $z/temp)"; done

dmesg | grep -i therm              # thermal driver
dmesg | grep -iE "mtu3|g_cdc"      # USB
free -m; cat /proc/loadavg; top
```
About 300 busybox commands (`ls`, `vi`, `top`, `devmem`, ...) are in `/pacman/bin`.
Critical temperature is **95 °C**: above it the kernel powers the phone off.

### XFCE desktop
```bash
# PC: build the desktop root filesystem and its vendor_boot image (xz ramdisk)
DESKTOP=1 bash ~/pacman/port/tools/build-alpine.sh
ROOT=~/pacman/alpine/rootfs-desktop COMP=xz OUT=~/pacman/out/pacman-desktop-vendor_boot.img \
  bash ~/pacman/port/tools/build-vendor-boot.sh ~/pacman/port/hybrid/test-T.img
```
With that image the boot log scrolls, then XFCE starts on the panel (landscape). Control it from
the PC with any VNC viewer: `gvncviewer 172.16.42.1:0` (no password, USB link only). If the desktop
fails three times in a row the login prompt appears instead; see `/tmp/xfce-session.log` and
`/tmp/Xorg.0.log` on the phone. Restart the desktop: `pkill Xorg`.

The PMIC's self-protection timer would power-cycle the phone after a few minutes; the init turns it
off at every boot (`cat /sys/bus/spmi/devices/0-04/spt_enable` -> 0).

### Alpine Linux
With `pacman-alpine-vendor_boot.img` the phone boots straight into Alpine: log in on the panel
(`conspy 1`), over telnet or on the serial shell — you are in Alpine (`cat /etc/alpine-release`),
with `apk`, `bash`, `htop`, `fastfetch`, and our tools from `/pacman/bin` in `PATH`.

```bash
# PC: build Alpine and the vendor_boot image (append package names to add more)
bash ~/pacman/port/tools/build-alpine.sh vim python3
bash ~/pacman/port/tools/build-vendor-boot.sh          # -> ~/pacman/out/pacman-alpine-vendor_boot.img
```

With the stock vendor_boot (Android ramdisk) Alpine can still be pushed into RAM and entered
with `chroot`:
```bash
# PC: build it (once; append package names to add more)
bash ~/pacman/port/tools/build-alpine.sh
bash ~/pacman/port/tools/build-alpine.sh vim python3

# PC: send it to the phone (USB network)
bash ~/pacman/port/tools/alpine-push.sh
```
On the phone:
```sh
alpine                # Alpine shell (leave with exit)
alpine fastfetch      # one command
```
Contains `bash`, `htop`, `nano`, `fastfetch`, Alpine's busybox and `apk`. The phone has no
internet: add packages on the PC with `build-alpine.sh <package...>` and push again. Do not
push while an Alpine shell is open (`/tmp/alpine` is replaced).

---

## 5. Building

```bash
# phone programs (pacman-dash, pacman-reboot) -> port/ui/
make -C ~/pacman/port/ui
make -C ~/pacman/port/ui preview         # PC preview of pacman-dash -> ui/preview.png

# busybox / fastfetch (once, again when the version changes)
bash ~/pacman/port/tools/build-busybox.sh
bash ~/pacman/port/tools/build-fastfetch.sh

# kernel (the initramfs picks the programs above up automatically)
cd ~/pacman/linux && export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
./scripts/kconfig/merge_config.sh -m .config ../port/pacman.config && make olddefconfig
make -j$(nproc) Image.lz4
mkbootimg --header_version 4 --kernel arch/arm64/boot/Image.lz4 -o ../out/pacman-NEW-boot.img

# device tree: compile + wrap for LK (current: hybrid/test-T.dts); --check verifies all images
bash ~/pacman/port/tools/build-dtb.sh ~/pacman/port/hybrid/test-T.dts
bash ~/pacman/port/tools/build-dtb.sh --check

# vendor_boot with Alpine as ramdisk (see section 4) and that device tree
bash ~/pacman/port/tools/build-vendor-boot.sh ~/pacman/port/hybrid/test-T.img
```

### Check the size before flashing
LK bootloops on kernels above roughly **20 MiB LZ4 / 44 MiB decompressed**:
```bash
ls -l ~/pacman/linux/arch/arm64/boot/Image ~/pacman/linux/arch/arm64/boot/Image.lz4
```
The MediaTek-only config gives about 29.6 MiB / 16.0 MiB.

---

## 6. Logs

```bash
ls -lt ~/pacman/logs | head
grep -a -i therm ~/pacman/logs/log-test1-*.txt      # pstore logs have bit flips: use grep -a
# by hand, with Android running (rooted):
adb shell 'su -c "cat /sys/fs/pstore/console-ramoops-0"' > ~/pacman/logs/log-manual.txt
```

---

## 7. Troubleshooting

| Symptom | What to do |
|---|---|
| Bootloop, the PC only sees the preloader (`0e8d:2000`) | Kernel too large or crashing early -> fastboot by key combo, `to-stock.sh` |
| No `/dev/ttyACM0` | `lsusb \| grep 0525` — if missing the gadget did not come up, read the pstore log |
| Garbled text in picocom | Kernel messages; quieten them (section 2) |
| `pacsh.py` times out | Use `--net`; without it check `pgrep -a picocom` and that conspy is not running |
| `pacman-reboot bootloader` did not reach fastboot | Power + volume down (short press) |

Watch USB events on the PC: `journalctl -kf | grep -i usb`

---

## Safety
- Flash only `boot_b` and `vendor_boot_b`. **Never** `lk`, `preloader`, `dtbo`, `super`,
  `userdata` or the partition table.
- Don't `fastboot set_active`; stay on your slot.
- Keep your stock backups read-only and safe (`nvram`/`nvdata`/`nvcfg`/`proinfo` cannot be recreated).
- No charging control under mainline yet: keep sessions short and watch the battery.
