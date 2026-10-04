#!/bin/sh
# Rebuild the T01 ELF fixtures into tests/fixtures/elf/out/.
# Needs gcc, clang, lld, binutils, and llvm-objcopy. Everything stays in the workdir.
set -eu
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
mkdir -p "$root/.work/tmp"
export TMPDIR="$root/.work/tmp"
rm -rf out
mkdir out
cflags="-g -O0 -Wall -Wextra"
rpath='-Wl,-rpath,$ORIGIN'

# Shared objects first; the executables link against them.
gcc $cflags -fPIC -shared libfix.c -o out/libfix.so
clang $cflags -fPIC -shared -fuse-ld=lld libfix.c -o out/libfix-lld.so

# Fixed-address executable, PIE with each compiler, and PIE linked by lld
# (lld lets the first two PT_LOADs share file page 0).
gcc $cflags -fno-pie -no-pie fixture.c dup.c -Lout -lfix "$rpath" -o out/gcc-exec
gcc $cflags -fPIE -pie fixture.c dup.c -Lout -lfix "$rpath" -o out/gcc-pie
clang $cflags -fPIE -pie fixture.c dup.c -Lout -lfix "$rpath" -o out/clang-pie
clang $cflags -fPIE -pie -fuse-ld=lld fixture.c dup.c -Lout -lfix-lld "$rpath" -o out/clang-lld-pie

# Static executable: .symtab only, IFUNC and TLS symbols from libc.
gcc $cflags -static -fno-pie -no-pie -DSTATIC static.c -o out/gcc-static

# Stripped variants: .dynsym only, debug-only companion (NOBITS contents),
# and no section header table at all.
strip --strip-all -o out/gcc-pie.stripped out/gcc-pie
strip --strip-all -o out/libfix.stripped.so out/libfix.so
objcopy --only-keep-debug out/gcc-pie out/gcc-pie.debug
strip --strip-all -o out/clang-pie.stripped out/clang-pie
objcopy --only-keep-debug out/clang-pie out/clang-pie.debug
llvm-objcopy --strip-sections out/gcc-pie out/gcc-pie.nosections

# libdw decompresses both modern and legacy GNU debug sections in memory.
for compression in zlib zstd zlib-gnu; do
  for compiler in gcc clang; do
    objcopy --compress-debug-sections="$compression" "out/$compiler-pie" "out/$compiler-pie.$compression"
    objcopy --compress-debug-sections="$compression" "out/$compiler-pie.debug" "out/$compiler-pie.debug.$compression"
  done
done

# More than 0xff00 sections: extended e_shnum/e_shstrndx and SHN_XINDEX symbols.
{
    echo 'int main(void) { return 0; }'
    seq 1 66000 | awk '{ printf "int many%d __attribute__((section(\"sec%d\"), used)) = %d;\n", $1, $1, $1 }'
} > out/many.c
clang -O0 -fPIE -pie -fuse-ld=lld out/many.c -o out/many-sections

# Inputs the reader must reject: relocatable object, 32-bit, big-endian, other machine.
gcc $cflags -c dup.c -o out/reject-rel.o
clang --target=i386-unknown-linux -nostdlib -static -fuse-ld=lld reject.c -o out/reject-i386
clang --target=powerpc64-unknown-linux -nostdlib -static -fuse-ld=lld reject.c -o out/reject-ppc64be
clang --target=aarch64-unknown-linux -nostdlib -static -fuse-ld=lld reject.c -o out/reject-aarch64

{
    gcc --version | head -n 1
    clang --version | head -n 1
    ld --version | head -n 1
    ld.lld --version
    llvm-objcopy --version | grep -i version
} > out/VERSIONS
gcc -shared -nostdlib unwind.S -o out/unwind-cfi.so
ls -l out
