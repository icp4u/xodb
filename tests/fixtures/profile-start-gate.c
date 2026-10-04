// Test-only launch barrier for the unmodified T04 request server.
// Link with --wrap=pthread_create,--wrap=pthread_join. Its main thread creates
// all workers/clients before joining; no thread callback runs before the gate.
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define MAX_THREADS 512
struct launch { void *(*entry)(void *); void *argument; };
static struct launch launches[MAX_THREADS];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static unsigned created, entered, joined;
static int released;
static uint64_t ready_ns, released_ns, ended_ns;
// Visible while stopped: prove that a long preparation pause has not started
// any workload callback, and hence none of the request clocks or counters.
unsigned profile_gate_started;

int __real_pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
int __real_pthread_join(pthread_t, void **);

static uint64_t now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) abort();
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static void report(void) {
    fprintf(stderr, "{\"profile_gate\":true,\"created\":%u,\"started\":%u,\"joined\":%u,"
            "\"ready_ns\":%llu,\"released_ns\":%llu,\"ended_ns\":%llu}\n",
            created, profile_gate_started, joined, (unsigned long long)ready_ns,
            (unsigned long long)released_ns, (unsigned long long)ended_ns);
}
__attribute__((noinline)) void profile_gate_ready(void) { __asm__ volatile("" ::: "memory"); }
static void *gated(void *argument) {
    struct launch *item = argument;
    pthread_mutex_lock(&lock);
    ++entered;
    pthread_cond_broadcast(&changed);
    while (!released) pthread_cond_wait(&changed, &lock);
    ++profile_gate_started;
    pthread_mutex_unlock(&lock);
    return item->entry(item->argument);
}
int __wrap_pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                          void *(*entry)(void *), void *argument) {
    pthread_mutex_lock(&lock);
    // Deliberately reject another launch phase: this harness is for the T04
    // create-all-then-join lifecycle, not a replacement pthread implementation.
    if (released || created == MAX_THREADS) abort();
    if (created == 0 && atexit(report)) abort();
    struct launch *item = &launches[created++];
    *item = (struct launch){entry, argument};
    int result = __real_pthread_create(thread, attr, gated, item);
    if (result) --created;
    pthread_mutex_unlock(&lock);
    return result;
}
int __wrap_pthread_join(pthread_t thread, void **result) {
    pthread_mutex_lock(&lock);
    if (!released) {
        while (entered != created) pthread_cond_wait(&changed, &lock);
        ready_ns = now();
        profile_gate_ready();
        released_ns = now();
        released = 1;
        pthread_cond_broadcast(&changed);
    }
    pthread_mutex_unlock(&lock);
    int status = __real_pthread_join(thread, result);
    if (status == 0 && ++joined == created) ended_ns = now();
    return status;
}
