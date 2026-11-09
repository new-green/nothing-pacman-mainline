#!/usr/bin/env bash
# Checkpoints of the whole project state in ~/pacman/checkpoint/<YYYY-MM-DD-HHMM>/.
#
#   checkpoint.sh --new-check ["note"] [--images BOOT.img VENDOR_BOOT.img]
#   checkpoint.sh --list
#   checkpoint.sh --verify [STAMP]        (default: all checkpoints)
#
# --new-check writes:
#   port.bundle            port repo (master + checkpoint tag)
#   linux-<branch>.bundle  our kernel commits on top of the base tag (they exist nowhere else)
#   *.img                  image pair (default: out/pacman-desktop-{boot,vendor_boot}.img)
#   kernel.config          full .config of the kernel tree
#   versions.txt           toolchain, kernel, userspace versions, DTB, image sizes
#   alpine-packages*.txt   installed packages of the Alpine root filesystems
#   phone-dmesg.txt, phone-screen.png   only if the phone runs mainline and answers on USB
#   README.txt, SHA256SUMS (sha256 of every file in the folder, verified after writing)
# Both repos get a tag (checkpoint-<stamp>, pacman-checkpoint-<stamp>). Nothing is pushed.
# Without a note, one is made from the latest commits. Refuses to run with uncommitted
# changes in port/ or linux/ (a checkpoint must be reproducible from git).
set -euo pipefail

TOP="${PACMAN:-$HOME/pacman}"
CK="$TOP/checkpoint"
BASE="${BASE:-v7.3.3}"                 # kernel base tag
TOOLS="$(cd "$(dirname "$0")" && pwd)"

die() { echo "checkpoint: $*" >&2; exit 1; }
usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

sums() {   # write + verify SHA256SUMS in $1
	(cd "$1" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort \
		| xargs sha256sum > SHA256SUMS && sha256sum -c --quiet SHA256SUMS)
}

do_list() {
	[[ -d "$CK" ]] || { echo "no checkpoints yet"; return; }
	for d in "$CK"/*/; do
		[[ -f "$d/README.txt" ]] || continue
		printf '%s  %5s  %s\n' "$(basename "$d")" "$(du -sh "$d" | cut -f1)" "$(sed -n 2p "$d/README.txt")"
	done
}

do_verify() {
	local rc=0 d
	for d in "$CK"/${1:-*}/; do
		[[ -f "$d/SHA256SUMS" ]] || { echo "MISSING  $(basename "$d") (no SHA256SUMS)"; rc=1; continue; }
		if (cd "$d" && sha256sum -c --quiet SHA256SUMS 2>/dev/null); then echo "ok       $(basename "$d")"
		else echo "CORRUPT  $(basename "$d")"; rc=1; fi
	done
	return $rc
}

do_new() {
	local note="" boot="$TOP/out/pacman-desktop-boot.img" vboot="$TOP/out/pacman-desktop-vendor_boot.img"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--images) boot="${2:?--images BOOT VENDOR_BOOT}"; vboot="${3:?--images BOOT VENDOR_BOOT}"; shift 2 ;;
		-*) die "unknown option $1" ;;
		*) note="$1" ;;
		esac
		shift
	done

	[[ -z "$(git -C "$TOP/port" status --porcelain)" ]] || die "uncommitted changes in port/ (commit first)"
	[[ -z "$(git -C "$TOP/linux" status --porcelain --untracked-files=no)" ]] || die "uncommitted changes in linux/"
	for f in "$boot" "$vboot"; do [[ -f "$f" ]] || die "missing image $f"; done

	local stamp dir tag kbranch
	stamp=$(date +%Y-%m-%d-%H%M)
	dir="$CK/$stamp"; tag="checkpoint-$stamp"
	[[ -e "$dir" ]] && die "$dir already exists (one checkpoint per minute)"
	kbranch=$(git -C "$TOP/linux" branch --show-current)
	[[ -n "$note" ]] || note="port: $(git -C "$TOP/port" log -1 --format=%s); kernel: $(git -C "$TOP/linux" log -1 --format=%s)"

	mkdir -p "$dir"
	git -C "$TOP/port" tag -a "$tag" -m "Checkpoint: $note"
	git -C "$TOP/linux" tag -a "pacman-$tag" -m "Checkpoint: $note"
	git -C "$TOP/port" bundle create "$dir/port.bundle" master "$tag" 2>/dev/null
	git -C "$TOP/linux" bundle create "$dir/linux-$kbranch.bundle" "$BASE..$kbranch" "pacman-$tag" 2>/dev/null
	cp -p "$boot" "$vboot" "$dir/"
	[[ -f "$TOP/linux/.config" ]] && cp -p "$TOP/linux/.config" "$dir/kernel.config"

	{
		echo "date:        $(date -Is)"
		echo "port:        $(git -C "$TOP/port" describe --always --dirty) on $(git -C "$TOP/port" branch --show-current)"
		echo "kernel:      $(git -C "$TOP/linux" describe --always) on $kbranch (base $BASE, $(git -C "$TOP/linux" rev-list --count "$BASE..$kbranch") commits)"
		[[ -f "$TOP/linux/vmlinux" ]] && echo "vmlinux:     $(strings "$TOP/linux/vmlinux" | command grep -am1 '^Linux version' | cut -c1-120)"
		echo "compiler:    $(aarch64-linux-gnu-gcc --version 2>/dev/null | head -1)"
		echo "binutils:    $(aarch64-linux-gnu-ld --version 2>/dev/null | head -1)"
		echo "host:        $(uname -sr)"
		echo "busybox:     $(sed -n 's/^V=//p' "$TOOLS/build-busybox.sh")"
		echo "fastfetch:   $(sed -n 's/^V=//p' "$TOOLS/build-fastfetch.sh")"
		echo "alpine:      $(sed -n 's/^V=//p' "$TOOLS/build-alpine.sh")"
		echo "images:"
		for f in "$boot" "$vboot"; do printf '  %-36s %10d bytes\n' "$(basename "$f")" "$(stat -c %s "$f")"; done
		echo "hybrid DTBs:"
		(cd "$TOP/port/hybrid" && sha256sum ./*.img | sed 's/^/  /')
	} > "$dir/versions.txt"

	local r n
	for r in "$TOP"/alpine/rootfs*/; do
		[[ -f "$r/lib/apk/db/installed" ]] || continue
		n=$(basename "$r"); n=${n#rootfs}
		awk '/^P:/{p=substr($0,3)} /^V:/{print p, substr($0,3)}' "$r/lib/apk/db/installed" \
			| LC_ALL=C sort > "$dir/alpine-packages$n.txt"
	done

	# evidence from the running phone, if it is on mainline and reachable (read-only)
	local phone="no (not reachable on 172.16.42.1)"
	if ping -c 1 -W 1 172.16.42.1 > /dev/null 2>&1; then
		if timeout 30 python3 -I "$TOOLS/pacsh.py" --net run 'uname -a; cat /proc/uptime; dmesg' -t 20 \
			> "$dir/phone-dmesg.txt" 2>/dev/null && [[ -s "$dir/phone-dmesg.txt" ]]; then
			phone="dmesg"
			timeout 60 python3 -I "$TOOLS/screenshot.py" "$dir/phone-screen.png" > /dev/null 2>&1 \
				&& phone="dmesg + screenshot"
		else
			rm -f "$dir/phone-dmesg.txt"
		fi
	fi

	cat > "$dir/README.txt" <<TXT
Checkpoint $stamp
$note

port.bundle             port repo: master + tag $tag ($(git -C "$TOP/port" rev-parse --short HEAD))
linux-$kbranch.bundle   kernel commits $BASE..$kbranch + tag pacman-$tag ($(git -C "$TOP/linux" rev-parse --short HEAD))
$(basename "$boot"), $(basename "$vboot")   image pair (boot_b / vendor_boot_b)
kernel.config, versions.txt, alpine-packages*.txt   what the images were built from
phone evidence:         $phone
SHA256SUMS              sha256 of every file here; verify: checkpoint.sh --verify $stamp

Restore: git -C ~/pacman/port reset --hard $tag
         git -C ~/pacman/linux fetch <this dir>/linux-$kbranch.bundle   (needs $BASE present)
TXT
	sums "$dir"
	echo "$dir"
	ls -l "$dir" | awk 'NR>1 {printf "  %10d  %s\n", $5, $9}'
}

case "${1:-}" in
--new-check) shift; do_new "$@" ;;
--list) do_list ;;
--verify) do_verify "${2:-}" ;;
-h|--help|"") usage ;;
*) die "unknown command $1 (try --help)" ;;
esac
