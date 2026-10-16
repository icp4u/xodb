/* Owned fixtures for Ghidra stack and split variable storage (GPLv3). */
#include <stdint.h>

__attribute__((noinline)) int qx_stack(int a, int b, int c, int d, int e, int f, int seventh)
{
	__asm__ volatile("" :: "r"(seventh));
	return a + seventh;
}

typedef struct { uint64_t low; uint32_t high; } qx_pair;
__attribute__((noinline)) uint64_t qx_split(qx_pair pair)
{
	__asm__ volatile("" :: "r"(pair.low), "r"(pair.high));
	return pair.low + pair.high;
}

__attribute__((noinline)) uint64_t qx_wide(unsigned __int128 wide, uint64_t after)
{
	__asm__ volatile("" :: "r"((uint64_t)wide), "r"((uint64_t)(wide >> 64)), "r"(after));
	return (uint64_t)wide ^ (uint64_t)(wide >> 64) ^ after;
}

/* Ghidra puts z in RDI:RSI and shifts e and g onto caller stack slots. */
__attribute__((noinline)) uint64_t qx_complex(_Complex double z, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t g)
{
	__asm__ volatile("" :: "r"(a), "r"(b), "r"(c), "r"(d), "r"(e), "r"(g));
	return a ^ b ^ c ^ d ^ e ^ g ^ (uint64_t)(__real__ z > 0);
}

/* Unread misplaced arguments: no code contradicts Ghidra, so only the
 * producer's type rules refuse them. z and v are in XMM0, a and b in RDI and
 * RSI; the over-aligned s is at CFA+16, not CFA+8, and t at CFA+32. */
typedef int64_t qx_v2 __attribute__((vector_size(16)));
typedef struct { qx_v2 v; } qx_vector;
typedef struct { uint64_t lo, hi; } __attribute__((aligned(16))) qx_al16;
__attribute__((noinline)) uint64_t qx_cfloat(_Complex float z, uint64_t a, uint64_t b)
{
	(void)z;
	__asm__ volatile("" :: "r"(a), "r"(b));
	return a ^ b;
}
__attribute__((noinline)) uint64_t qx_vector_arg(qx_vector v, uint64_t a, uint64_t b)
{
	(void)v;
	__asm__ volatile("" :: "r"(a), "r"(b));
	return a ^ b;
}
__attribute__((noinline)) uint64_t qx_aligned(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f, uint64_t g, qx_al16 s, uint64_t t)
{
	(void)s; (void)t;
	__asm__ volatile("" :: "r"(a), "r"(g));
	return a ^ g;
}

int main(void)
{
	qx_pair pair = { 8, 9 };
	unsigned __int128 wide = ((unsigned __int128)0x99aabbccddeeff00ull << 64) | 0x1122334455667788ull;
	return qx_stack(1, 2, 3, 4, 5, 6, 7) + (int)qx_split(pair) + (int)qx_wide(wide, 10) +
	       (int)qx_complex(1.0 + 2.0i, 11, 12, 13, 14, 15, 16) + (int)qx_cfloat(3.0f + 4.0fi, 17, 18) +
	       (int)qx_vector_arg((qx_vector){ { 19, 20 } }, 21, 22) + (int)qx_aligned(23, 24, 25, 26, 27, 28, 29, (qx_al16){ 30, 31 }, 32);
}
