#!/usr/bin/env python3
"""Talk to the phone's busybox shell.

  pacsh.py [--net] run 'uname -a' [-t 10]   run a command, print its output
  pacsh.py [--net] push LOCAL REMOTE [-x]   copy a file into the phone's RAM
                                            (gzip + base64, md5-checked; -x: chmod +x)

Default: the shell on /dev/ttyACM0. That shell is shared with the owner's picocom
session: whatever runs there in the foreground (e.g. conspy!) gets our keystrokes.
--net: telnet to the phone (--host, default 172.16.42.1, net image) for a fresh shell of
our own on every call; never collides with picocom/conspy. Prefer it when available.
"""
import argparse, base64, gzip, hashlib, os, re, select, socket, sys, termios, time

DEV = os.environ.get("PACSH_DEV", "/dev/ttyACM0")


class Phone:
    def __init__(self, dev=DEV):
        self.fd = os.open(dev, os.O_RDWR | os.O_NOCTTY)
        a = termios.tcgetattr(self.fd)
        a[0] = a[1] = a[3] = 0                     # raw: no i/o/local processing
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[6][termios.VMIN] = 0
        a[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, a)
        self.drain()
        # A freshly reset ttyACM0 starts with echo on: anything that arrived
        # before tcsetattr (e.g. the console's buffered boot log) may have been
        # echoed back into the phone's shell as typed input. ^C discards
        # whatever half-line the shell's line editor is holding.
        self.write(b"\x03")
        self.drain(0.5)

    def drain(self, t=0.3):
        end = time.time() + t
        while time.time() < end:
            if select.select([self.fd], [], [], 0.05)[0]:
                os.read(self.fd, 65536)

    def write(self, data):
        view = memoryview(data)
        while view:
            n = os.write(self.fd, view)
            view = view[n:]

    def wait_for(self, token, timeout):
        buf = b""
        end = time.time() + timeout
        while time.time() < end and token not in buf:
            if select.select([self.fd], [], [], 0.2)[0]:
                buf += os.read(self.fd, 65536)
        if token not in buf:
            raise TimeoutError("no %r within %ss; got: %r" % (token, timeout, buf[-300:]))
        return buf

    def run(self, cmd, timeout=10):
        # markers are split with "" so the shell's echo of the line never matches
        self.write(('echo __B""EG__; %s; echo __E""ND__\n' % cmd).encode())
        buf = self.wait_for(b"__END__", timeout)
        text = buf.decode("utf-8", "replace").replace("\r", "")
        return text.split("__BEG__\n", 1)[-1].split("__END__", 1)[0]

    def push(self, local, remote, executable=False):
        raw = open(local, "rb").read()
        payload = base64.encodebytes(gzip.compress(raw, 9))   # 76-char lines
        tmp = remote + ".part"
        self.run("stty -echo")
        try:
            # wait until the pipeline runs: ash's line editor may swallow
            # bytes that arrive while it is still reading the command line
            self.write(('echo __R""DY__; base64 -d | gunzip > %s; echo __P""END__\n' % tmp).encode())
            self.wait_for(b"__RDY__", 10)
            t0 = time.time()
            self.write(payload)
            self.write(b"\x04")                   # ^D at line start: EOF for base64
            self.wait_for(b"__PEND__", 120)
            dt = time.time() - t0
        finally:
            self.run("stty echo")
        got = self.run("md5sum %s" % tmp).split()[0]
        want = hashlib.md5(raw).hexdigest()
        if got != want:
            self.run("rm -f %s" % tmp)
            raise RuntimeError("md5 mismatch: phone %s, local %s" % (got, want))
        self.run("mv %s %s%s" % (tmp, remote, "; chmod +x %s" % remote if executable else ""))
        return len(raw), len(payload), dt, want


IAC_RE = re.compile(rb"\xff[\xfb-\xfe].|\xff[\xf0-\xfa]")   # telnet negotiation


class NetPhone(Phone):
    """Same API over telnet (busybox telnetd on the USB network)."""

    def __init__(self, host="172.16.42.1", port=23):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.settimeout(0.2)
        self.drain(1.0)                           # banner, prompt, negotiation

    def _recv(self):
        try:
            d = self.sock.recv(65536)
        except socket.timeout:
            return b""
        if not d:
            raise ConnectionError("telnet connection closed by the phone")
        return IAC_RE.sub(b"", d)

    def drain(self, t=0.3):
        end = time.time() + t
        while time.time() < end:
            self._recv()

    def write(self, data):
        self.sock.settimeout(60)                  # big pushes wait on the phone's pty
        try:
            self.sock.sendall(data)
        finally:
            self.sock.settimeout(0.2)

    def wait_for(self, token, timeout):
        buf = b""
        end = time.time() + timeout
        while time.time() < end and token not in buf:
            buf += self._recv()
        if token not in buf:
            raise TimeoutError("no %r within %ss; got: %r" % (token, timeout, buf[-300:]))
        return buf


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--net", action="store_true",
                   help="use telnet over the USB network instead of /dev/ttyACM0")
    p.add_argument("--host", default="172.16.42.1", help="phone address for --net")
    sub = p.add_subparsers(dest="op", required=True)
    r = sub.add_parser("run"); r.add_argument("cmd"); r.add_argument("-t", type=float, default=10)
    s = sub.add_parser("push"); s.add_argument("local"); s.add_argument("remote")
    s.add_argument("-x", action="store_true")
    a = p.parse_args()

    ph = NetPhone(a.host) if a.net else Phone()
    if a.op == "run":
        sys.stdout.write(ph.run(a.cmd, a.t))
    else:
        size, sent, dt, md5 = ph.push(a.local, a.remote, a.x)
        print("%s -> %s: %d bytes (%d sent) in %.1f s, md5 %s OK"
              % (a.local, a.remote, size, sent, dt, md5))


if __name__ == "__main__":
    main()
