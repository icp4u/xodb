// Two known CPU paths, recursive callers, and an optional late executable map.
// Build with frame pointers and without sibling calls for the sampling demo.
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>

volatile uint64_t profile_result;
__attribute__((noinline)) void profile_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void profile_done(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) uint64_t hot_mix(uint64_t seed) {
    volatile uint64_t value = seed;
    for (unsigned i = 0; i < 250000; ++i) value = (value ^ (value >> 7)) * 6364136223846793005ULL + i;
    return value;
}
__attribute__((noinline)) uint64_t hot_hash(uint64_t seed) {
    volatile uint64_t value = seed;
    for (unsigned i = 0; i < 100000; ++i) value = (value << 5) ^ (value >> 3) ^ (i * 2654435761U);
    return value;
}
__attribute__((noinline)) uint64_t recursive_mix(unsigned depth, uint64_t seed) {
    uint64_t result = depth ? recursive_mix(depth - 1, seed + depth) : hot_mix(seed);
    __asm__ volatile("" : "+r"(result));
    return result;
}
static atomic_int worker_go, worker_stop;
static void *profile_worker(void *unused) {
    (void)unused;
    while (!atomic_load(&worker_go)) usleep(1000);
    uint64_t result = 1;
    while (!atomic_load(&worker_stop)) result ^= hot_hash(result);
    return (void *)(uintptr_t)(result & 0xffff);
}
static pthread_mutex_t idle_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t idle_condition = PTHREAD_COND_INITIALIZER;
static atomic_uint idle_ready;
static void *idle_worker(void *unused) {
    (void)unused;
    pthread_mutex_lock(&idle_mutex);
    atomic_fetch_add(&idle_ready, 1);
    while (!atomic_load(&worker_stop)) pthread_cond_wait(&idle_condition, &idle_mutex);
    pthread_mutex_unlock(&idle_mutex);
    return NULL;
}
static char kernel_buffer[8 * 1024 * 1024];
static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ULL + t.tv_nsec;
}
int main(int argc, char **argv) {
    unsigned seconds = argc > 1 ? (unsigned)atoi(argv[1]) : 20;
    (void)now_ns(); // resolve lazy loader paths before the capture checkpoint
    puts("profile demo ready: P, then Space; P stops capture, F toggles flames");
    int threaded = argc > 2 && !strcmp(argv[2], "threads");
    /* Tests may finish a threaded run after observing the needed samples.
     * The seconds argument remains a fail-safe if the harness disappears. */
    const char *stop_file = threaded && argc > 3 ? argv[3] : NULL;
    pthread_t worker;
    if (threaded && pthread_create(&worker, NULL, profile_worker, NULL)) return 2;
    int kernel = argc > 2 && !strcmp(argv[2], "kernel");
    int sleeping = argc > 2 && !strcmp(argv[2], "sleep");
    int many = argc > 2 && !strcmp(argv[2], "many");
    unsigned idle_count = many ? (argc > 3 ? (unsigned)atoi(argv[3]) : 639) : 0;
    if (idle_count > 1023) return 2;
    pthread_t idle[1023];
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 64 * 1024);
    for (unsigned i = 0; i < idle_count; ++i)
        if (pthread_create(&idle[i], &attr, idle_worker, NULL)) return 2;
    pthread_attr_destroy(&attr);
    while (atomic_load(&idle_ready) != idle_count) usleep(1000);
    int zero = -1;
    if (kernel) {
        zero = open("/dev/zero", O_RDONLY);
        if (zero < 0) return 2;
        memset(kernel_buffer, 1, sizeof(kernel_buffer));
        if (read(zero, kernel_buffer, sizeof(kernel_buffer)) <= 0) return 2;
    }
    profile_ready();
    atomic_store(&worker_go, 1);
    uint64_t begin = now_ns(), iterations = 0;
    void *late_map = NULL;
    while (now_ns() - begin < (uint64_t)seconds * 1000000000ULL) {
        if (stop_file && access(stop_file, F_OK) == 0) break;
        if (kernel) {
            if (read(zero, kernel_buffer, sizeof(kernel_buffer)) <= 0) return 2;
        } else if (sleeping) usleep(10000);
        else {
            profile_result ^= recursive_mix(3, iterations);
            profile_result ^= hot_hash(iterations);
        }
        ++iterations;
        if (argc > 2 && !strcmp(argv[2], "map") && !late_map && now_ns() - begin > 500000000) {
            late_map = mmap(NULL, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        }
    }
    pthread_mutex_lock(&idle_mutex);
    atomic_store(&worker_stop, 1);
    pthread_cond_broadcast(&idle_condition);
    pthread_mutex_unlock(&idle_mutex);
    for (unsigned i = 0; i < idle_count; ++i) pthread_join(idle[i], NULL);
    if (zero >= 0) close(zero);
    if (threaded) pthread_join(worker, NULL);
    profile_done();
    if (late_map && late_map != MAP_FAILED) munmap(late_map, 4096);
    printf("iterations=%llu result=%llu\n", (unsigned long long)iterations, (unsigned long long)profile_result);
    return 0;
}
