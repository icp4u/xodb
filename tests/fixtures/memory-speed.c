/* Large owned mapping with planted needles for memory search throughput. */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../check.h"
unsigned char *base;
uint64_t size, hole, hole2;
static const char needle[] = "xodb:planted-needle:5Q";
__attribute__((noinline)) void speed_ready(void) { __asm__ volatile("" ::: "memory"); }
static void plant(uint64_t at) { memcpy(base + at, needle, sizeof(needle) - 1); }
int main(int argc, char **argv) {
    alarm(60);
    size = (uint64_t)(argc > 1 ? atoi(argv[1]) : 256) << 20;
    CHECK(size >= 32u << 20);
    base = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(base != MAP_FAILED);
    /* Non-zero filler so reads touch real pages, not the shared zero page. */
    uint64_t x = 0x9e3779b97f4a7c15u;
    for (uint64_t i = 0; i < size; i += 8) {
        x = x * 6364136223846793005u + 1442695040888963407u;
        memcpy(base + i, &x, 8);
    }
    const uint64_t n = sizeof(needle) - 1;
    hole = size / 2;
    plant(0);
    plant((1u << 20) - 7);       /* straddles a 1 MiB read */
    plant((4u << 20) - 3);       /* straddles a 4 MiB read */
    plant((16u << 20) - 10);     /* straddles a 16 MiB read */
    hole2 = hole + (8u << 20);
    plant(hole - n);             /* ends exactly at the first unmapped page */
    plant(hole + 4096);          /* starts right after it */
    memcpy(base + hole2 - 10, needle, 10);            /* broken by the second */
    memcpy(base + hole2 + 4096, needle + 10, n - 10); /* hole: never a match */
    plant(size - n);
    CHECK(munmap(base + hole, 4096) == 0);
    CHECK(munmap(base + hole2, 4096) == 0);
    speed_ready();
    return 0;
}
