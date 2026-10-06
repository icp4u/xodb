/* C01 owned decompiler fixture. Public domain / same license as delivery. */
#include <stdio.h>
#include <stdlib.h>

struct point { int x; int y; long weight; struct point *next; };

typedef int (*binop_fn)(int, int);

__attribute__((noinline)) int fx_arith(int a, int b, int c)
{
	int t = a * 3 + b;
	t ^= c << 2;
	return t / (b | 1) - (a % 7);
}

__attribute__((noinline)) int fx_loop(const int *v, int n)
{
	int s = 0;
	for (int i = 0; i < n; i++) {
		if (v[i] > 10)
			s += v[i];
		else
			s -= 1;
	}
	return s;
}

__attribute__((noinline)) long fx_struct(struct point *p)
{
	long acc = 0;
	while (p != NULL) {
		acc += (long)p->x * p->y + p->weight;
		p = p->next;
	}
	return acc;
}

__attribute__((noinline)) int fx_add(int a, int b) { return a + b; }
__attribute__((noinline)) int fx_sub(int a, int b) { return a - b; }

binop_fn fx_table[2] = { fx_add, fx_sub };

__attribute__((noinline)) int fx_calls(int sel, int a, int b)
{
	int direct = fx_add(a, b);
	binop_fn f = fx_table[sel & 1];
	return f(direct, b);
}

__attribute__((noinline)) int fx_switch(int k, int x)
{
	switch (k) {
	case 0: return x + 1;
	case 1: return x * 2;
	case 2: return x - 7;
	case 3: return x ^ 0x55;
	case 4: return x << 3;
	case 5: return -x;
	case 6: return x / 3;
	default: return 0;
	}
}

int main(int argc, char **argv)
{
	int v[5] = { 1, 20, 3, 40, 5 };
	struct point b = { 3, 4, 5, NULL }, a = { 1, 2, 3, &b };
	int k = argc > 1 ? atoi(argv[1]) : 2;
	printf("%d %d %ld %d %d\n", fx_arith(k, 5, 9), fx_loop(v, 5),
	       fx_struct(&a), fx_calls(k, 3, 4), fx_switch(k, 11));
	return 0;
}
