/* C02 owned fixtures for bounded semantic queries (GPLv3, same as xodb).
 * Each function isolates one dependence question; see fixtures/EXPECT.md. */
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

/* Allocation-size arithmetic behind a length guard. flag reaches memset
 * but must never reach the malloc size. */
__attribute__((noinline)) void *qx_alloc(unsigned count, unsigned size, int flag)
{
	if (count > 4096)
		return NULL;
	size_t n = (size_t)count * size + 16;
	void *p = malloc(n);
	if (flag && p)
		memset(p, 0, n);
	return p;
}

/* Length guard controlling a copy. */
__attribute__((noinline)) int qx_copy(char *dst, const char *src, size_t len, size_t cap)
{
	if (len >= cap)
		return -1;
	memcpy(dst, src, len);
	dst[len] = 0;
	return 0;
}

__attribute__((noinline)) void qx_left(int v) { __asm__ volatile("" ::"r"(v)); }
__attribute__((noinline)) void qx_right(int v) { __asm__ volatile("" ::"r"(v)); }

/* Signed versus unsigned branches on the same bits. */
__attribute__((noinline)) void qx_branch_s(int a, int b)
{
	if (a < b)
		qx_left(a);
	else
		qx_right(b);
}

__attribute__((noinline)) void qx_branch_u(unsigned a, unsigned b)
{
	if (a < b)
		qx_left((int)a);
	else
		qx_right((int)b);
}

/* Loop with phi merges. n controls the loop but is not summed. */
__attribute__((noinline)) long qx_sum(const int *v, int n, long bias)
{
	long s = bias;
	for (int i = 0; i < n; i++)
		s += v[i];
	return s;
}

/* Merge of two definitions. */
__attribute__((noinline)) int qx_merge(int c, int x, int y)
{
	int r;
	if (c)
		r = x * 3;
	else
		r = y + 7;
	qx_left(r);
	return r;
}

typedef int (*qx_fn)(int);

/* Function-pointer call: result comes from an unknown callee. */
__attribute__((noinline)) int qx_indirect(qx_fn f, int x, int y)
{
	return f(x) + y;
}

/* Pointer alias counterexample: *q may alias *p, so the reload is needed. */
__attribute__((noinline)) int qx_alias(int *p, int *q, int a, int b)
{
	*p = a;
	*q = b;
	return *p;
}

/* No-alias variant: restrict promises distinct objects to the compiler. */
__attribute__((noinline)) int qx_noalias(int *restrict p, int *restrict q, int a, int b)
{
	*p = a;
	*q = b;
	return *p;
}

__attribute__((noinline)) void qx_fill(int *out) { __asm__ volatile("" ::"r"(out) : "memory"); }

/* Escaping local: the call may write it before the reload. */
__attribute__((noinline)) int qx_escape(int a)
{
	int x = a;
	qx_fill(&x);
	return x + 1;
}

static int qx_twice(int v) { return 2 * v; }

int main(int argc, char **argv)
{
	char buf[32];
	int x = argc, y = argc + 1;
	void *p = qx_alloc((unsigned)argc, 8, argc > 2);
	qx_copy(buf, argv[0], strlen(argv[0]) & 15, sizeof buf);
	qx_branch_s(argc, -argc);
	qx_branch_u((unsigned)argc, 3);
	int v[4] = {argc, 2, 3, 4};
	long s = qx_sum(v, argc, 5);
	free(p);
	return (int)s + qx_merge(argc & 1, x, y) + qx_indirect(qx_twice, x, y) + qx_alias(&x, &y, 1, 2) +
	       qx_noalias(&x, &y, 3, 4) + qx_escape(argc) + buf[0];
}
