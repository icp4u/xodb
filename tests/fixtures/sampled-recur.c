/* Owned CPU-only target for GCC/Clang sampled DWARF reconstruction checks. */
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
static volatile uint64_t sink;
__attribute__((noinline)) void sampled_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) static void sampled_leaf(void) {
    sampled_ready();
    struct timespec begin, now;
    clock_gettime(CLOCK_MONOTONIC, &begin);
    do {
        for (unsigned i = 0; i < 100000; ++i) sink += i;
        clock_gettime(CLOCK_MONOTONIC, &now);
    } while ((now.tv_sec - begin.tv_sec) * 1000000000LL + now.tv_nsec - begin.tv_nsec < 2000000000LL);
}
__attribute__((noinline)) static uint64_t sampled_recur(unsigned depth) {
    volatile uint64_t local[4] = {depth, depth + 1, depth + 2, depth + 3};
    if (depth) local[0] += sampled_recur(depth - 1); else sampled_leaf();
    return local[0] + local[3];
}
int main(void) { sink = sampled_recur(12); return 0; }
