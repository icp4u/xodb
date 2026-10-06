#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <time.h>
#ifndef DELAY_NS
#define DELAY_NS 8000000L
#endif
static volatile uint64_t sink;
__attribute__((noinline)) void observation_ready(void) { __asm__ volatile ("" ::: "memory"); }
__attribute__((noinline)) void observation_done(void) { __asm__ volatile ("" ::: "memory"); }
__attribute__((noinline)) uint64_t observed_work(uint64_t value) {
    struct timespec delay = { .tv_sec = 0, .tv_nsec = DELAY_NS };
    while (nanosleep(&delay, &delay)) {}
    for (unsigned i = 0; i < 1000; ++i) sink = sink * 1664525 + value + i;
    return sink;
}
int main(void) {
    observation_ready();
    for (unsigned i = 0; i < 16; ++i) sink = observed_work(i);
    observation_done();
    return 0;
}
