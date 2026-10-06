/* Source-line selection fixtures (GPLv3, same as xodb): one line holding two
 * functions, and helper bodies that exist only as inlined code. Tests find the
 * lines by the marker comments. */
#include <stdlib.h>

static inline __attribute__((always_inline)) unsigned grow(unsigned v)
{
	return v * 3u + 7u; /* GROW: inlined into inl_a and inl_b */
}

static inline __attribute__((always_inline)) unsigned widen(unsigned v)
{
	return v * 5u + 9u; /* WIDEN: inlined into inl_c only */
}

__attribute__((noinline)) void *two_a(unsigned n) { return malloc(n * 3u + 1u); } __attribute__((noinline)) void *two_b(unsigned n, unsigned k) { return malloc(n + k); } /* TWO */
__attribute__((noinline)) void *inl_a(unsigned n) { return malloc(grow(n)); }
__attribute__((noinline)) void *inl_b(unsigned n, unsigned k) { return malloc(grow(n) + k); }
__attribute__((noinline)) void *inl_c(unsigned n) { return malloc(widen(n)); }

int main(int argc, char **argv)
{
	(void)argv;
	void *p = two_a((unsigned)argc), *q = two_b((unsigned)argc, 2);
	void *r = inl_a((unsigned)argc), *s = inl_b((unsigned)argc, 3), *t = inl_c((unsigned)argc);
	free(p);
	free(q);
	free(r);
	free(s);
	free(t);
	return 0;
}
