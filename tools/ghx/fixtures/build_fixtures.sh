#!/bin/sh
# Build owned x86-64 ELF fixtures from fx.c (next to this script):
# {gcc,clang} x {O0,O2}, stripped copies and an nm-derived function oracle
# (name entry size, canonical hex).  usage: build_fixtures.sh OUTDIR
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
    n=fx-$cc-$opt
    (cd "$here" && timeout 120 $cc -$opt -g -fno-pie -no-pie -fcf-protection=none -Wl,--build-id=sha1 \
        -ffile-prefix-map="$here"=fixtures -o "$out/$n" fx.c)
    strip -o "$out/$n.stripped" "$out/$n"
    nm -S --defined-only "$out/$n" | awk 'function c(h) { sub(/^0+/, "", h); return "0x" (h == "" ? "0" : h) }
        $3=="T"||$3=="t"{print $4, c($1), c($2)}' \
        | LC_ALL=C sort > "$out/$n.oracle"
  done
done
cd "$out"
{ for f in fx-*; do
    case $f in *.oracle) continue;; esac
    bid=$(readelf -n "$f" | awk '/Build ID/{print $3}')
    printf '%s %s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "${bid:-none}" "$f"
  done; } > MANIFEST
{ gcc --version | head -1; clang --version | head -1; } > TOOLS
