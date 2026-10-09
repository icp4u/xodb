/* Owned mappings with alternating permissions cannot be merged into one VMA. */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

__attribute__((noinline)) void maps_stop(void) { __asm__ volatile("" ::: "memory"); }
int main(void) {
    const size_t count = 6144;
    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0 || count > SIZE_MAX / (size_t)page) return 2;
    size_t bytes = count * (size_t)page;
    unsigned char *base = mmap(NULL, bytes, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) return 3;
    for (size_t i = 0; i < count; i += 2)
        if (mprotect(base + i * (size_t)page, (size_t)page, PROT_READ | PROT_WRITE)) return 4;
    maps_stop();
    if (munmap(base, bytes)) return 5;
    maps_stop();
    return 0;
}
