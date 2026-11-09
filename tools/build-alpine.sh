#!/usr/bin/env bash
# Builds a small Alpine Linux aarch64 userspace on the PC, without root and without
# giving the phone internet access:
#   ~/pacman/alpine/rootfs/                 the tree
#   ~/pacman/alpine/alpine-rootfs.tar.gz    what tools/alpine-push.sh sends to the phone
#
#   bash ~/pacman/port/tools/build-alpine.sh [extra packages...]
#
# Minirootfs: sha256 + GPG (Natanael Copa's key, fingerprint pinned below).
# Packages: installed with Alpine's own apk.static (x86_64 build), signatures checked
# against the keys shipped in the minirootfs. Post-install scripts are skipped
# (--no-scripts): fine for these packages; run `apk fix` on the phone if one needs them.
set -euo pipefail

V=3.24.4
BRANCH=v3.24
MINI_SHA256=4b14c18f7e90a063b61462ea1462a5732c154bf6adad594974fe6487cd98a8de
NCOPA_FPR=0482D84022F52DF1C4E7CD43293ACD0907D9495A
APKTOOLS=apk-tools-static-3.0.9-r0
PACKAGES=(bash htop nano fastfetch "$@")

TOP="${PACMAN:-$HOME/pacman}/alpine"
DL="$TOP/dl"
ROOT="$TOP/rootfs"
OUT="$TOP/alpine-rootfs.tar.gz"
CDN=https://dl-cdn.alpinelinux.org/alpine

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
mkdir -p "$DL/apkcache" "$TOP/apktools"

# --- minirootfs: download + verify ---
mini="alpine-minirootfs-$V-aarch64.tar.gz"
for f in "$mini" "$mini.asc"; do
	[[ -f "$DL/$f" ]] || curl -fsSL -o "$DL/$f" "$CDN/$BRANCH/releases/aarch64/$f"
done
[[ -f "$DL/ncopa.asc" ]] || curl -fsSL -o "$DL/ncopa.asc" https://alpinelinux.org/keys/ncopa.asc
echo "$MINI_SHA256  $DL/$mini" | sha256sum -c --quiet -
G=$(mktemp -d); trap 'rm -rf "$G"' EXIT
gpg --homedir "$G" --quiet --import "$DL/ncopa.asc" 2>/dev/null
gpg --homedir "$G" --status-fd 1 --verify "$DL/$mini.asc" "$DL/$mini" 2>/dev/null \
	| grep -q "VALIDSIG $NCOPA_FPR" || { echo "GPG signature could not be verified" >&2; exit 1; }
say "minirootfs $V: sha256 + GPG OK"

# --- apk.static (runs on the PC) ---
APK="$TOP/apktools/sbin/apk.static"
if [[ ! -x "$APK" ]]; then
	curl -fsSL -o "$TOP/apktools/$APKTOOLS.apk" "$CDN/$BRANCH/main/x86_64/$APKTOOLS.apk"
	tar -xzf "$TOP/apktools/$APKTOOLS.apk" -C "$TOP/apktools" sbin/apk.static 2>/dev/null
fi

# --- rootfs ---
rm -rf "$ROOT"; mkdir -p "$ROOT"
tar -xpzf "$DL/$mini" -C "$ROOT"
"$APK" --root "$ROOT" --arch aarch64 --usermode --no-scripts --cache-dir "$DL/apkcache" \
	add "${PACKAGES[@]}"

# --- small customisations ---
echo pacman > "$ROOT/etc/hostname"
# root without password, like our busybox system (console/USB access only)
sed -i 's/^root:[^:]*:/root::/' "$ROOT/etc/shadow"
cat > "$ROOT/etc/motd" <<'EOF'

  Alpine Linux on the Nothing Phone (2a) -- mainline kernel, running from RAM.
  Nothing here survives a reboot. No internet: install packages on the PC
  (tools/build-alpine.sh <package...>), then rebuild the vendor_boot image
  (tools/build-vendor-boot.sh) or push into a running phone (tools/alpine-push.sh).

  fastfetch       system info          pacman-dash     dashboard on the panel
  pacman-reboot   reboot [bootloader|recovery|poweroff]

EOF
cat > "$ROOT/etc/profile.d/pacman.sh" <<'EOF'
export PS1='\[\e[1;32m\]alpine\[\e[0m\]@\h:\w# '
# our static tools from the kernel's built-in initramfs (pacman-reboot, pacman-dash, ...)
case ":$PATH:" in *:/pacman/bin:*) ;; *) [ -d /pacman/bin ] && PATH="$PATH:/pacman/bin" ;; esac
EOF

tar --numeric-owner --owner=0 --group=0 -czf "$OUT" -C "$ROOT" .
say "$(du -sh "$ROOT" | cut -f1) rootfs -> $OUT ($(du -h "$OUT" | cut -f1))"
