#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <time.h>
#include <unistd.h>

volatile uint64_t profile_from_start_result;
static uint64_t constructor_entry_ns;

static uint64_t thread_cpu_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

__attribute__((noinline)) void profile_startup_hot(void) {
    const uint64_t start = thread_cpu_ns();
    uint64_t value = 0x123456789abcdef0ULL;
    do {
        for (unsigned i = 0; i < 10000; ++i)
            value = (value ^ (value >> 9)) * 6364136223846793005ULL + i;
        profile_from_start_result = value;
    } while (thread_cpu_ns() - start < 350000000ULL);
}

__attribute__((constructor)) static void before_main(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) == 0)
        constructor_entry_ns = (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
    profile_startup_hot();
}

__attribute__((noinline)) void profile_late_hot(void) {
    uint64_t value = profile_from_start_result | 1;
    for (unsigned i = 0; i < 1000000; ++i)
        value = (value << 7) ^ (value >> 3) ^ ((uint64_t)i * 2654435761U);
    profile_from_start_result = value;
}

int main(int argc, char **argv) {
    const char *stop = argc > 1 ? argv[1] : NULL;
    const char *ready = argc > 2 ? argv[2] : NULL;
    if (prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0) != 0) return 2;
    if (ready) {
        /* The ready file carries the constructor's CLOCK_MONOTONIC entry time,
           renamed into place so a reader never sees it partly written. */
        char partial[4096];
        if (snprintf(partial, sizeof partial, "%s.partial", ready) >= (int)sizeof partial) return 3;
        FILE *stream = fopen(partial, "wb");
        if (!stream) return 3;
        if (fprintf(stream, "%llu\n", (unsigned long long)constructor_entry_ns) < 0) return 3;
        if (fclose(stream) != 0) return 3;
        if (rename(partial, ready) != 0) return 3;
    }
    const uint64_t deadline = thread_cpu_ns() + 30000000000ULL;
    do {
        profile_late_hot();
    } while ((!stop || access(stop, F_OK) != 0) && thread_cpu_ns() < deadline);
    return 0;
}
