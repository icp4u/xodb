/* Many small owned mappings with planted needles for multi-range search. */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../check.h"
#define SMALL 600
/* The needle is stored masked so its plain bytes exist only where planted. */
static const unsigned char masked[] = { 0x22, 0x35, 0x3e, 0x38, 0x77, 0x28, 0x3b, 0x34, 0x3d, 0x3f, 0x77, 0x34, 0x3f, 0x3f, 0x3e, 0x36, 0x3f, 0x60, 0x08, 0x69 };
static size_t page;
static unsigned char *area;
__attribute__((noinline)) void ranges_ready(void) { __asm__ volatile("" ::: "memory"); }
static void plant(unsigned char *at, size_t from, size_t to) {
    for (size_t i = from; i < to; i++) at[i - from] = masked[i] ^ 0x5a;
}
static unsigned char *fixed(size_t at, size_t pages, int prot, int flags, int fd) {
    unsigned char *p = mmap(area + at * page, pages * page, prot, flags | MAP_FIXED, fd, 0);
    CHECK(p == area + at * page);
    return p;
}
int main(int argc, char **argv) {
    alarm(60);
    CHECK(argc == 2);
    const size_t n = sizeof masked;
    page = (size_t)sysconf(_SC_PAGESIZE);
    const size_t pages = 4 * SMALL + 16;
    area = mmap(0, pages * page, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    CHECK(area != MAP_FAILED);
    FILE *f = fopen(argv[1], "w");
    CHECK(f != NULL);
    CHECK(fprintf(f, "{\"area\":%llu,\"area_size\":%zu,\"page\":%zu,\"small\":[", (unsigned long long)(uintptr_t)area, pages * page, page) > 0);
    unsigned long long anon[SMALL];
    size_t planted = 0;
    for (size_t i = 0; i < SMALL; i++) {
        /* 1 or 2 pages; the gap stays a PROT_NONE reservation or, every
           tenth time, is unmapped outright. */
        const size_t length = (1 + i % 2) * page;
        unsigned char *p = fixed(4 * i, 1 + i % 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1);
        memset(p, (int)(0x80 + i % 64), length);
        if (i % 10 == 9) CHECK(munmap(p + length, 4 * page - length) == 0);
        size_t at = SIZE_MAX;
        if (i % 50 == 7) at = 0;                 /* first byte of a mapping */
        if (i % 50 == 17) at = length - n;       /* ends at a PROT_NONE page */
        if (i % 50 == 27) at = page - 3;         /* straddles a page inside one */
        if (i % 50 == 37) at = 100;
        if (at != SIZE_MAX) {
            plant(p + at, 0, n);
            anon[planted++] = (unsigned long long)(uintptr_t)(p + at);
        }
        CHECK(fprintf(f, "%s[%llu,%zu]", i ? "," : "", (unsigned long long)(uintptr_t)p, length) > 0);
    }
    CHECK(fprintf(f, "],\"anon\":[") > 0);
    for (size_t i = 0; i < planted; i++) CHECK(fprintf(f, "%s%llu", i ? "," : "", anon[i]) > 0);
    const size_t extra = 4 * SMALL;
    unsigned char *ro = fixed(extra, 1, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1);
    plant(ro + 64, 0, n);
    CHECK(mprotect(ro, page, PROT_READ) == 0);
    unsigned char *shared = fixed(extra + 4, 1, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1);
    plant(shared + 64, 0, n);
    int fd = memfd_create("ranges", 0);
    CHECK(fd >= 0 && ftruncate(fd, (off_t)page) == 0);
    unsigned char *file = fixed(extra + 8, 1, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd);
    plant(file + 64, 0, n);
    /* Broken needle: halves on either side of a PROT_NONE page. */
    unsigned char *split = fixed(extra + 12, 1, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1);
    fixed(extra + 14, 1, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1);
    plant(split + page - 8, 0, 8);
    plant(split + 2 * page, 8, n);
    CHECK(fprintf(f, "],\"ro\":%llu,\"shared\":%llu,\"file\":%llu,\"split\":%llu,\"needle_size\":%zu}\n", (unsigned long long)(uintptr_t)(ro + 64),
                  (unsigned long long)(uintptr_t)(shared + 64), (unsigned long long)(uintptr_t)(file + 64), (unsigned long long)(uintptr_t)split, n) > 0);
    CHECK(fclose(f) == 0);
    ranges_ready();
    return 0;
}
