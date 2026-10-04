// Owned worker growth/churn; new threads map code before doing CPU work.
#define _GNU_SOURCE
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

__attribute__((noinline)) void profile_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void profile_done(void) { __asm__ volatile("" ::: "memory"); }
static uint64_t cpu_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)) abort();
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
__attribute__((noinline)) static void late_hot(unsigned ms) {
    uint64_t end = cpu_ns() + (uint64_t)ms * 1000000, value = 19;
    do {
        for (unsigned i = 0; i < 10000; ++i) value = (value ^ (value >> 9)) * 0x9e3779b1;
        __asm__ volatile("" : "+r"(value));
    } while (cpu_ns() < end);
}
static void *worker(void *arg) {
    void *p = mmap(NULL, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) abort();
    late_hot((unsigned)(uintptr_t)arg);
    if (munmap(p, 4096)) abort();
    return NULL;
}
static void *nested(void *arg) {
    pthread_t t;
    if (pthread_create(&t, NULL, worker, arg) || pthread_join(t, NULL)) abort();
    return worker(arg);
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    alarm(30);
    unsigned count = (unsigned)strtoul(argv[2], NULL, 10);
    if (count > 1100) return 2;
    profile_ready();
    if (!strcmp(argv[1], "fork") || !strcmp(argv[1], "vfork")) {
        pid_t parent = getpid(), child = !strcmp(argv[1], "vfork") ? vfork() : fork();
        if (child < 0) abort();
        if (!child) {
            if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent) _exit(3);
            _exit(0);
        }
        int status;
        if (waitpid(child, &status, 0) != child || status) abort();
        late_hot(80);
    } else if (!strcmp(argv[1], "pool")) {
        pthread_t pool[64];
        if (count > 64) return 2;
        for (unsigned i = 0; i < count; ++i) if (pthread_create(&pool[i], NULL, worker, (void *)(uintptr_t)25)) abort();
        for (unsigned i = 0; i < count; ++i) if (pthread_join(pool[i], NULL)) abort();
    } else {
        for (unsigned i = 0; i < count; ++i) {
            pthread_t t;
            unsigned ms = i == 0 || i + 1 == count ? 75 : 1;
            if (pthread_create(&t, NULL, i == 0 ? nested : worker, (void *)(uintptr_t)ms) || pthread_join(t, NULL)) abort();
        }
    }
    profile_done();
    return 0;
}
