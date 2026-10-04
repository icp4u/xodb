#include <stdint.h>
#ifndef MAPPED_NAME
#define MAPPED_NAME mapped_hot_a
#endif
__attribute__((noinline)) uint64_t MAPPED_NAME(uint64_t seed) {
    volatile uint64_t value = seed;
    for (unsigned i = 0; i < 400000; ++i)
        value = (value ^ (value >> 7)) * 6364136223846793005ULL + i;
    return value;
}
