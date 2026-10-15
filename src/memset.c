/* memset for the xodb executable.
 *
 * Zig 0.16's bundled compiler_rt exports a weak memset that stores one byte
 * per iteration. A weak definition inside the executable still binds before
 * libc's, so every @memset, every zeroed default and every ReleaseSafe
 * `undefined` fill (0xAA) ran that loop; startup fills about 14 MB. This
 * strong definition replaces it on every target without changing which
 * runtime is linked. (Linking libgcc_s instead does not work: Zig maps -lgcc_s
 * to libunwind, and x86-64 still needs __zig_probe_stack and roundq.)
 *
 * Built with -fno-builtin so clang cannot turn these loops back into a call
 * to memset. Hidden, so shared libraries keep their own libc memset. */
#include <stddef.h>
#include <stdint.h>

typedef unsigned char block __attribute__((vector_size(16), aligned(1), may_alias));
typedef unsigned char aligned_block __attribute__((vector_size(16), may_alias));
typedef uint64_t word __attribute__((aligned(1), may_alias));
typedef uint32_t half __attribute__((aligned(1), may_alias));

__attribute__((visibility("hidden"))) void *memset(void *dest, int c, size_t n)
{
    unsigned char *d = dest, b = (unsigned char)c;
    if (n < 16) {
        /* Two possibly overlapping stores cover 8..15 and 4..7 bytes; three cover 1..3. */
        if (n >= 8) {
            uint64_t v = 0x0101010101010101u * b;
            *(word *)d = v;
            *(word *)(d + n - 8) = v;
        } else if (n >= 4) {
            uint32_t v = 0x01010101u * b;
            *(half *)d = v;
            *(half *)(d + n - 4) = v;
        } else if (n) {
            d[0] = b;
            d[n / 2] = b;
            d[n - 1] = b;
        }
        return dest;
    }
    block v;
    for (int i = 0; i < 16; ++i) v[i] = b;
    /* Unaligned head and tail, then aligned blocks strictly between them. */
    *(block *)d = v;
    *(block *)(d + n - 16) = v;
    unsigned char *end = d + n - 16;
    for (unsigned char *p = (unsigned char *)(((uintptr_t)d + 16) & ~(uintptr_t)15); p < end; p += 16)
        *(aligned_block *)p = v;
    return dest;
}
