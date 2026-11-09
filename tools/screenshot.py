#!/usr/bin/env python3
"""Screenshot of the phone's panel (/dev/fb0) as PNG, over the USB network.

  python3 screenshot.py                 -> ~/pacman/screenshots/screen-<date>.png
  python3 screenshot.py out.png [--scale 0.5]

Needs the net image (telnet + usb0). The PC opens the connection (ufw-safe):
the phone serves /dev/fb0 once with `nc -l`, we read exactly stride*height bytes.
Captures what we draw into fb0 (fbcon text, pacman-dash, ...); LK's own OVL layers
are not part of fb0.
"""
import argparse, os, socket, sys, time, zlib, struct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pacsh  # noqa: E402

PORT = 9001


def png_rgb(path, w, h, rows):
    """Minimal PNG writer (no Pillow needed): rows = list of RGB byte strings."""
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    raw = b"".join(b"\0" + r for r in rows)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", nargs="?")
    ap.add_argument("--host", default="172.16.42.1")
    ap.add_argument("--scale", type=float, default=1.0, help="resize (needs Pillow), e.g. 0.5")
    a = ap.parse_args()

    out = a.out or os.path.expanduser(time.strftime("~/pacman/screenshots/screen-%Y%m%d-%H%M%S.png"))
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)

    ph = pacsh.NetPhone(a.host)
    geo = ph.run("cd /sys/class/graphics/fb0 && cat virtual_size stride bits_per_pixel").split()
    w, h = (int(v) for v in geo[0].split(","))
    stride, bpp = int(geo[1]), int(geo[2])
    if bpp != 32:
        sys.exit("unexpected bits_per_pixel %d" % bpp)
    size = stride * h

    ph.run('pkill -f "nc -l -p %d" 2>/dev/null; '
           'setsid sh -c "nc -l -p %d < /dev/fb0 > /dev/null" < /dev/null > /dev/null 2>&1 & sleep 1'
           % (PORT, PORT))
    s = socket.create_connection((a.host, PORT), timeout=10)
    buf = bytearray()
    while len(buf) < size:
        d = s.recv(min(1 << 20, size - len(buf)))
        if not d:
            break
        buf += d
    s.close()
    if len(buf) < size:
        sys.exit("short read: %d of %d bytes" % (len(buf), size))

    # a8r8g8b8 in little-endian memory = B, G, R, A
    try:
        from PIL import Image
        img = Image.frombuffer("RGB", (w, h), bytes(buf), "raw", "BGRX", stride, 1)
        if a.scale != 1.0:
            img = img.resize((int(w * a.scale), int(h * a.scale)), Image.LANCZOS)
        img.save(out)
    except ImportError:
        rows = []
        for y in range(h):
            line = buf[y * stride: y * stride + w * 4]
            rgb = bytearray(w * 3)
            rgb[0::3] = line[2::4]
            rgb[1::3] = line[1::4]
            rgb[2::3] = line[0::4]
            rows.append(bytes(rgb))
        png_rgb(out, w, h, rows)
    print(out)


if __name__ == "__main__":
    main()
