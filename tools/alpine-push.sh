#!/usr/bin/env bash
# Sends the Alpine userspace (tools/build-alpine.sh) into the phone's RAM over the USB
# network and installs the phone-side `alpine` command. Phone must run the net image.
#
#   bash ~/pacman/port/tools/alpine-push.sh
#   then on the phone (telnet 172.16.42.1 or picocom):  alpine
#
# The PC opens every connection (PC -> phone), so the PC firewall (ufw) is not involved.
set -euo pipefail

TOP="${PACMAN:-$HOME/pacman}"
TAR="${TAR:-$TOP/alpine/alpine-rootfs.tar.gz}"
DEST="${DEST:-/tmp/alpine}"	# where it is unpacked on the phone (RAM)
TOOLS="$(cd "$(dirname "$0")" && pwd)"
ENTER="$TOOLS/../ui/alpine-enter.sh"
PHONE=172.16.42.1
NC_PORT=9000

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }
# telnet (--net): a shell of our own, never the owner's picocom/conspy session on ttyACM0
pacsh() { python3 -I "$TOOLS/pacsh.py" --net "$@"; }

[[ -f "$TAR" ]] || die "$TAR missing: run bash $TOOLS/build-alpine.sh first"
ping -c 1 -W 2 "$PHONE" >/dev/null || die "$PHONE does not answer: is the phone running the net image?"

say "installing the 'alpine' command on the phone"
pacsh push "$ENTER" /pacman/bin/alpine -x >/dev/null

say "cleaning old /tmp/alpine, starting the receiver"
pacsh run 'R='"$DEST"'; for m in tmp dev/pts dev sys proc; do mountpoint -q $R/$m && umount -l $R/$m; done;
rm -rf $R $R.rc; mkdir -p $R;
setsid sh -c "nc -l -p '"$NC_PORT"' < /dev/null | tar -xzf - -C $R; echo \$? > $R.rc" < /dev/null > /dev/null 2>&1 &
sleep 1; echo ok' -t 20 >/dev/null

say "sending: $(du -h "$TAR" | cut -f1)"
python3 -I - "$TAR" "$PHONE" "$NC_PORT" <<'EOF'
import socket, sys, time
data = open(sys.argv[1], "rb").read()
s = socket.create_connection((sys.argv[2], int(sys.argv[3])), timeout=30)
t0 = time.time()
s.sendall(data)
s.shutdown(socket.SHUT_WR)
while s.recv(65536):      # the phone closes once it has read everything
    pass
s.close()
dt = time.time() - t0
print("    %.1f MB, %.1f s, %.1f MB/s" % (len(data) / 1e6, dt, len(data) / dt / 1e6))
EOF

for _ in $(seq 1 30); do
	rc=$(pacsh run "cat $DEST.rc 2>/dev/null" -t 10 | tr -d '\r\n ')
	[[ -n "$rc" ]] && break
	sleep 1
done
[[ "$rc" == "0" ]] || die "unpacking on the phone failed (tar exit code: '${rc:-none}')"
say "on the phone: $(pacsh run "du -sh $DEST | cut -f1" -t 60 | tr -d '\r\n') $DEST"
say "ready. On the phone: alpine   (or one command: alpine fastfetch)"
