#define _GNU_SOURCE
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/types.h>
#include <sys/wait.h>

void *volatile retained;
volatile size_t impossible = SIZE_MAX;
__attribute__((noinline)) void allocation_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void allocation_done(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void allocation_marker(int phase) { __asm__ volatile("" : : "r"(phase) : "memory"); }
static void delay(void) { struct timespec t = { .tv_nsec = 3000000 }; nanosleep(&t, NULL); }
static atomic_int worker_gate;
static void *release_worker(void *unused) {
    (void)unused;
    while (atomic_load(&worker_gate) == 0) delay();
    free(retained);
    retained = NULL;
    atomic_store(&worker_gate,2);
    while (atomic_load(&worker_gate) == 2) delay();
    return NULL;
}
int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "balanced";
    pthread_t worker;
    const int threaded = !strcmp(mode,"threads");
    if (threaded && pthread_create(&worker,NULL,release_worker,NULL)) return 5;
    if (!strcmp(mode, "demo")) allocation_marker(0); else allocation_ready();
    if (!strcmp(mode, "exec")) { execl("/bin/true", "true", NULL); return 2; }
    if (!strcmp(mode, "fork")) {
        pid_t child = fork();
        if (!child) _exit(0);
        if (child > 0) waitpid(child, NULL, 0);
    }
    if (!strcmp(mode, "burst")) {
        for (unsigned i = 0; i < 200000; ++i) {
            void *p = malloc(31 + i % 16);
            __asm__ volatile("" : : "r"(p) : "memory");
            free(p);
        }
    } else {
        void *a = malloc(37); delay();
        void *b = calloc(3,17); delay();
        void *resized = realloc(a,73); if (!resized) return 3; a = resized; delay();
        free(b); delay(); free(a); delay();
        void *c = malloc(55); delay();
        resized = realloc(c,impossible); if (resized) return 4; delay();
        free(c); delay(); free(NULL); delay();
        retained = malloc(29); delay();
    }
    if (threaded) {
        atomic_store(&worker_gate,1);
        while (atomic_load(&worker_gate) != 2) delay();
    }
    if (!strcmp(mode, "exit")) _exit(0);
    if (!strcmp(mode, "demo")) allocation_marker(1); else allocation_done();
    if (threaded) { atomic_store(&worker_gate,3); pthread_join(worker,NULL); }
    free(retained);
    return 0;
}
