#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static volatile uint64_t sink;
__attribute__((noinline)) void observation_ready(void) { __asm__ volatile ("" ::: "memory"); }
__attribute__((noinline)) void observation_done(void) { __asm__ volatile ("" ::: "memory"); }
__attribute__((noinline)) uint64_t observed_work(uint64_t slow, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f) {
    if (slow) { struct timespec delay = { .tv_nsec = 8000000 }; nanosleep(&delay, 0); }
    for (unsigned i = 0; i < 100; ++i) sink = sink * 1664525 + i;
    return slow ^ b ^ c ^ d ^ e ^ f;
}
__attribute__((noinline)) uint64_t observed_recursive(uint64_t depth) {
    uint64_t result = depth ? observed_recursive(depth - 1) + depth : 0;
    __asm__ volatile ("" : "+r" (result));
    return result;
}
int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "balanced";
    observation_ready();
    if (!strcmp(mode, "recursive")) sink = observed_recursive(4);
    else {
        unsigned count = !strcmp(mode, "limit") ? 200 : 16;
        for (unsigned i = 0; i < count; ++i) sink = observed_work(i & 1, UINT64_C(0xf000000000000002), 3, 4, 5, 6);
    }
    if (!strcmp(mode, "exec")) { execl("/bin/true", "true", (char *)0); return 3; }
    if (!strcmp(mode, "exit")) return 0;
    observation_done();
    fprintf(stderr, "observations fixture complete: %llu\n", (unsigned long long)sink);
    return 0;
}
