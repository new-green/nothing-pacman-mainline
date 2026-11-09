#!/usr/bin/env bash
# Takes a checkpoint of the whole project state into ~/pacman/checkpoint/<YYYY-MM-DD-HHMM>/:
#   port.bundle        port repo (master + checkpoint tag)
#   linux-*.bundle     our kernel commits on top of the base tag (they exist nowhere else)
#   *.img              the image pair given on the command line (default: the desktop pair)
#   README.txt, SHA256SUMS (sha256 of every file in the folder)
#
#   bash ~/pacman/port/tools/checkpoint.sh "what works / why"  [boot.img vendor_boot.img]
#
# Refuses to run with uncommitted changes in port/ or linux/. Nothing is pushed.
set -euo pipefail

TOP="${PACMAN:-$HOME/pacman}"
NOTE="${1:?usage: checkpoint.sh \"note\" [boot.img vendor_boot.img]}"
BOOT="${2:-$TOP/out/pacman-desktop-boot.img}"
VBOOT="${3:-$TOP/out/pacman-desktop-vendor_boot.img}"
BASE="${BASE:-v7.3.3}"                 # kernel base tag
STAMP=$(date +%Y-%m-%d-%H%M)
DIR="$TOP/checkpoint/$STAMP"
TAG="checkpoint-$STAMP"

die() { echo "checkpoint: $*" >&2; exit 1; }
[[ -z "$(git -C "$TOP/port" status --porcelain)" ]] || die "uncommitted changes in port/"
[[ -z "$(git -C "$TOP/linux" status --porcelain --untracked-files=no)" ]] || die "uncommitted changes in linux/"
[[ -e "$DIR" ]] && die "$DIR already exists"
for f in "$BOOT" "$VBOOT"; do [[ -f "$f" ]] || die "missing image $f"; done

kbranch=$(git -C "$TOP/linux" branch --show-current)
mkdir -p "$DIR"
git -C "$TOP/port" tag -a "$TAG" -m "Checkpoint: $NOTE"
git -C "$TOP/linux" tag -a "pacman-$TAG" -m "Checkpoint: $NOTE"
git -C "$TOP/port" bundle create "$DIR/port.bundle" master "$TAG" 2>/dev/null
git -C "$TOP/linux" bundle create "$DIR/linux-$kbranch.bundle" "$BASE..$kbranch" "pacman-$TAG" 2>/dev/null
cp -p "$BOOT" "$VBOOT" "$DIR/"

cat > "$DIR/README.txt" <<TXT
Checkpoint $STAMP
$NOTE

port.bundle             port repo: master + tag $TAG ($(git -C "$TOP/port" rev-parse --short HEAD))
linux-$kbranch.bundle   kernel commits $BASE..$kbranch + tag pacman-$TAG ($(git -C "$TOP/linux" rev-parse --short HEAD))
$(basename "$BOOT"), $(basename "$VBOOT")   image pair (boot_b / vendor_boot_b)
SHA256SUMS              sha256 of every file here; verify: sha256sum -c SHA256SUMS

Restore: git -C ~/pacman/port reset --hard $TAG
         git -C ~/pacman/linux fetch <this dir>/linux-$kbranch.bundle   (needs $BASE present)
TXT
(cd "$DIR" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS \
	&& sha256sum -c --quiet SHA256SUMS)
echo "$DIR"
ls -l "$DIR" | awk 'NR>1 {printf "  %10d  %s\n", $5, $9}'
