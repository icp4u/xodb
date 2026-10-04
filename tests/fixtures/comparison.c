#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
volatile uint64_t comparison_result;
__attribute__((noinline)) void comparison_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void comparison_done(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void hot_before(unsigned count) {
    volatile uint64_t n = 17;
    for (unsigned i=0;i<count;++i) n=(n^(n>>7))*6364136223846793005ULL+i;
    comparison_result=n;
}
__attribute__((noinline)) void hot_after(unsigned count) {
    volatile uint64_t n = 29;
    for (unsigned i=0;i<count;++i) n=(n^(n>>7))*6364136223846793005ULL+i;
    comparison_result=n;
}
static uint64_t now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000+t.tv_nsec; }
int main(int argc,char **argv) {
    const int after=argc>1 && atoi(argv[1]);
    comparison_ready();
    const uint64_t start=now();
    while (now()-start<1500000000) { hot_before(after?10000:190000); hot_after(after?190000:10000); }
    comparison_done();
    return 0;
}
