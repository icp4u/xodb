/* Shared pieces of the T04 profiling workloads: time, a seeded generator,
 * CPU work counted in iterations, and application-event probes. */
#ifndef XODB_WORKLOAD_H
#define XODB_WORKLOAD_H
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

/* USDT probes when the headers are installed; the noinline marker functions in
 * each workload carry the same events for tools that attach by symbol. */
#if __has_include(<sys/sdt.h>)
#include <sys/sdt.h>
#define PROBE1(name, a) DTRACE_PROBE1(xodb, name, a)
#define PROBE2(name, a, b) DTRACE_PROBE2(xodb, name, a, b)
#else
#define PROBE1(name, a) ((void)0)
#define PROBE2(name, a, b) ((void)0)
#endif

static volatile sig_atomic_t stop_requested;
static void request_stop(int sig) { (void)sig; stop_requested = 1; }
/* SIGINT/SIGTERM end the run early and still print the summary; SIGALRM bounds it. */
static void install_stop(unsigned max_seconds) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = request_stop;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGALRM, &sa, NULL);
    alarm(max_seconds);
}

static inline uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
static inline void sleep_until_ns(uint64_t deadline) {
    struct timespec ts = {(time_t)(deadline / 1000000000ull), (long)(deadline % 1000000000ull)};
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL) == EINTR && !stop_requested) {}
}

/* splitmix64: the whole run is a function of the seed. */
static inline uint64_t rng_next(uint64_t *state) {
    uint64_t z = (*state += 0x9e3779b97f4a7c15ull);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return z ^ (z >> 31);
}

/* CPU work is counted in iterations, not time, so every machine does the same
 * amount of it. One iteration is three dependent shift-xor steps.
 *
 * Nearly every on-CPU sample lands here, so this leaf must have a frame: GCC
 * 16 omits it even with -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer,
 * and frame-pointer unwinding then skips burn's caller, which is the function
 * a profile is supposed to name. Asking for the frame address forces the frame. */
__attribute__((noinline)) static uint64_t burn(uint64_t iterations, uint64_t x) {
#ifndef XODB_FRAMELESS_LEAF
    __asm__ volatile("" : : "r"(__builtin_frame_address(0)));
#endif
    x |= 1;
    for (uint64_t i = 0; i < iterations; i++) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        __asm__ volatile(""); /* keep the loop */
    }
    return x;
}

static int cmp_u32(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return (x > y) - (x < y);
}
/* Sorts `v` and returns the value at quantile q (0..1). */
static uint32_t quantile(uint32_t *v, size_t n, double q) {
    if (n == 0) return 0;
    qsort(v, n, sizeof *v, cmp_u32);
    size_t i = (size_t)(q * (double)n);
    return v[i < n ? i : n - 1];
}
/* Process totals from the kernel's own accounting, for the JSON summary. */
static void print_rusage(void) {
    struct rusage u;
    getrusage(RUSAGE_SELF, &u);
    printf("\"rusage\":{\"user_ms\":%ld,\"system_ms\":%ld,\"voluntary_switches\":%ld,\"involuntary_switches\":%ld,\"minor_faults\":%ld,\"major_faults\":%ld},", u.ru_utime.tv_sec * 1000 + u.ru_utime.tv_usec / 1000, u.ru_stime.tv_sec * 1000 + u.ru_stime.tv_usec / 1000, u.ru_nvcsw, u.ru_nivcsw, u.ru_minflt, u.ru_majflt);
}
static int64_t arg_int(const char *name, const char *value) {
    char *end;
    errno = 0;
    long long v = strtoll(value, &end, 10);
    if (errno || *end || v < 0) {
        fprintf(stderr, "bad value for %s: %s\n", name, value);
        exit(2);
    }
    return v;
}
#endif
