#!/usr/bin/env bash
# Compiles a device tree source from hybrid/ and wraps it in the Android DT table that LK
# expects in vendor_boot (a raw FDT is not accepted):
#   bash ~/pacman/port/tools/build-dtb.sh hybrid/test-P.dts      -> hybrid/test-P.img
#   bash ~/pacman/port/tools/build-dtb.sh --check                 verify all hybrid/*.img
#
# The sources are decompiled stock DTBs that already carry __symbols__ (needed by LK's
# overlay), so dtc runs without -@. Table: magic d7b7ab1e, header 32 bytes, one 32-byte
# entry (id/rev 0), page size 2048, version 0.
set -euo pipefail

TOP="${PACMAN:-$HOME/pacman}"
DTC="${DTC:-$TOP/linux/scripts/dtc/dtc}"
[[ -x "$DTC" ]] || DTC=dtc

build() {   # build SRC.dts OUT.img
	local tmp; tmp=$(mktemp)
	"$DTC" -q -I dts -O dtb -o "$tmp" "$1"
	python3 -I - "$tmp" "$2" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(
    struct.pack(">8I", 0xd7b7ab1e, 64 + len(d), 32, 32, 1, 32, 2048, 0)
    + struct.pack(">8I", len(d), 64, 0, 0, 0, 0, 0, 0) + d)
PY
	rm -f "$tmp"
}

if [[ "${1:-}" == "--check" ]]; then
	dir="$(cd "$(dirname "$0")/../hybrid" && pwd)"; rc=0
	for src in "$dir"/*.dts; do
		out=$(mktemp); build "$src" "$out"
		if cmp -s "$out" "${src%.dts}.img"; then echo "ok       $(basename "$src")"
		else echo "MISMATCH $(basename "$src")"; rc=1; fi
		rm -f "$out"
	done
	exit $rc
fi

src="${1:?usage: build-dtb.sh FILE.dts [OUT.img] | --check}"
out="${2:-${src%.dts}.img}"
build "$src" "$out"
echo "$out ($(stat -c %s "$out") bytes)"
