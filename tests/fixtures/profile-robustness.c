// Owned perf stress fixture: task scope changes and bursts of mapping records.
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static int ready, go;
static unsigned mode;
static uint64_t now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) abort();
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
__attribute__((noinline)) void profile_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void profile_done(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) static void hot(unsigned ms) {
    uint64_t end = now() + (uint64_t)ms * 1000000, value = 123;
    do {
        for (unsigned i = 0; i < 50000; ++i) value = (value ^ (value >> 11)) * 0x9e3779b1;
        __asm__ volatile("" : "+r"(value));
    } while (now() < end);
}
static void *late_worker(void *unused) {
    (void)unused;
    hot(150);
    return NULL;
}
static void mapping_burst(unsigned count) {
    size_t size = (size_t)sysconf(_SC_PAGESIZE);
    for (unsigned i = 0; i < count; ++i) {
        void *p = mmap(NULL, size, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED || munmap(p, size)) abort();
        // Small batches exercise repeated drains without depending on host load
        // to decide whether the kernel ring overflows before the model limit.
        if (i % 32 == 31) usleep(1000);
    }
}
static void *worker(void *argument) {
    uintptr_t index = (uintptr_t)argument;
    pthread_mutex_lock(&lock);
    ++ready;
    pthread_cond_broadcast(&condition);
    while (!go) pthread_cond_wait(&condition, &lock);
    pthread_mutex_unlock(&lock);
    if (index == 0) {
        hot(120);
        if (mode == 1) {
            pthread_t thread;
            if (pthread_create(&thread, NULL, late_worker, NULL) || pthread_join(thread, NULL)) abort();
        } else if (mode == 2) {
            pid_t parent = getpid(), child = fork();
            if (child < 0) abort();
            if (child == 0) {
                // Avoid leaving a child if the debugger/test exits early.
                if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent) _exit(3);
                _exit(0);
            }
            int status;
            while (waitpid(child, &status, 0) < 0) if (errno != EINTR) abort();
            if (!WIFEXITED(status) || WEXITSTATUS(status)) abort();
        } else mapping_burst(mode == 4 ? 4300 : 512);
        hot(150);
    } else {
        for (unsigned i = 0; i < 40; ++i) {
            hot(1);
            usleep(5000);
        }
    }
    return NULL;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    mode = !strcmp(argv[1], "thread") ? 1 : !strcmp(argv[1], "fork") ? 2 : !strcmp(argv[1], "burst") ? 3 : !strcmp(argv[1], "limit") ? 4 : 0;
    if (!mode) return 2;
    alarm(15);
    pthread_t threads[8];
    for (uintptr_t i = 0; i < 8; ++i) if (pthread_create(&threads[i], NULL, worker, (void *)i)) abort();
    pthread_mutex_lock(&lock);
    while (ready != 8) pthread_cond_wait(&condition, &lock);
    pthread_mutex_unlock(&lock);
    profile_ready();
    pthread_mutex_lock(&lock);
    go = 1;
    pthread_cond_broadcast(&condition);
    pthread_mutex_unlock(&lock);
    for (unsigned i = 0; i < 8; ++i) if (pthread_join(threads[i], NULL)) abort();
    profile_done();
    return 0;
}
