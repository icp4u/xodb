#!/bin/sh
# Build C02 compiled fixtures from qx.c (next to this script): GCC and Clang
# at -O0 and -O2 with build IDs, plus a symbol oracle (name entry size) per
# binary from nm (canonical hex).  usage: build_fixtures.sh OUTDIR
# Debug paths are mapped so a rebuild with the same compilers is byte-stable.
set -eu
umask 022
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: build_fixtures.sh OUTDIR}
mkdir -p "$out"
out=$(cd "$out" && pwd)
mkdir -p "$out"
for cc in gcc clang; do
	for opt in O0 O2; do
		bin=$out/qx-$cc-$opt
		(cd "$here" && timeout 120 $cc -$opt -g -Wl,--build-id=sha1 -no-pie -ffile-prefix-map="$here"=fixtures \
			-o "$bin" qx.c)
		nm -S --defined-only "$bin" | awk 'function c(h) { sub(/^0+/, "", h); return "0x" (h == "" ? "0" : h) }
			$3 ~ /^[Tt]$/ {print $4, c($1), c($2)}' |
			LC_ALL=C sort > "$bin.oracle"
		$cc --version | head -1 > "$bin.compiler"
	done
done
(cd "$out" && sha256sum qx-gcc-O0 qx-gcc-O2 qx-clang-O0 qx-clang-O2 > SHA256SUMS)
