// Second translation unit: local names that duplicate fixture.c's.
static int counter = 100;
static __attribute__((noinline)) int helper(int x) { return x * counter; }
int dup_helper(int x) { return helper(x); }
