#!/bin/sh
# Copy and build the Ghidra pieces the native worker needs (C01-R2).
#   sh tools/ghx/build_ghidra.sh GHIDRA_CHECKOUT OUTDIR
# The checkout is only read: its revision and clean tracked tree are verified,
# the decompiler C++ sources and the x86 processor specifications are copied
# to OUTDIR/ghidra-src, and libdecomp.a, sleigh_opt and x86-64.sla are built in
# the copy.  OUTDIR/ghidra-manifest.txt records the revision and the SHA-256 of
# every specification file the worker can snapshot plus the built library.
set -eu
umask 022
src=${1:?usage: build_ghidra.sh GHIDRA_CHECKOUT OUTDIR}
out=${2:?usage: build_ghidra.sh GHIDRA_CHECKOUT OUTDIR}
want=${GHIDRA_COMMIT:-a462673d2f1543d153c61d10bcd6c68f85555194}
jobs=${JOBS:-3}
got=$(git -C "$src" rev-parse HEAD)
[ "$got" = "$want" ] || { echo "build_ghidra: $src is at $got, expected $want" >&2; exit 1; }
[ -z "$(git -C "$src" status --porcelain --untracked-files=no)" ] || { echo "build_ghidra: tracked changes in $src" >&2; exit 1; }
gs=$out/ghidra-src
[ ! -e "$gs" ] || { echo "build_ghidra: $gs exists; use a fresh OUTDIR" >&2; exit 1; }
mkdir -p "$gs/Ghidra/Features/Decompiler/src/decompile" "$gs/Ghidra/Processors"
cp -a "$src/Ghidra/Features/Decompiler/src/decompile/cpp" "$gs/Ghidra/Features/Decompiler/src/decompile/"
cp -a "$src/Ghidra/Processors/x86" "$gs/Ghidra/Processors/"
cp "$src/LICENSE" "$src/NOTICE" "$gs/"
cpp=$gs/Ghidra/Features/Decompiler/src/decompile/cpp
mkdir -p "$cpp/com_opt" "$cpp/sla_opt"
timeout 3600 make -C "$cpp" -j"$jobs" sleigh_opt libdecomp.a > "$out/build-libdecomp.log" 2>&1 ||
	{ tail -20 "$out/build-libdecomp.log"; exit 1; }
(cd "$gs/Ghidra/Processors/x86/data/languages" && timeout 900 "$cpp/sleigh_opt" x86-64.slaspec x86-64.sla) \
	> "$out/build-sla.log" 2>&1 || { tail -20 "$out/build-sla.log"; exit 1; }
{
	echo "ghidra_commit $got"
	echo "libdecomp.a $(sha256sum "$cpp/libdecomp.a" | cut -d' ' -f1)"
	(cd "$gs" && find Ghidra/Processors -path '*/data/languages/*' -type f \
		\( -name '*.ldefs' -o -name '*.sla' -o -name '*.pspec' -o -name '*.cspec' \) |
		LC_ALL=C sort | xargs sha256sum)
	g++ --version | head -1
} > "$out/ghidra-manifest.txt"
echo "$cpp"
