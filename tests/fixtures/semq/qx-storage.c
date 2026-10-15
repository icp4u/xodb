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

int main(void)
{
	qx_pair pair = { 8, 9 };
	return qx_stack(1, 2, 3, 4, 5, 6, 7) + (int)qx_split(pair);
}
