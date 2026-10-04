// Library unload/reload at the same addresses, permission changes, and JIT-like
// anonymous code. The worker variant changes mappings from another sampled TID.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static const char *paths[2];
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static int ready, go;
static volatile uint64_t value;
__attribute__((noinline)) void profile_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void profile_done(void) { __asm__ volatile("" ::: "memory"); }
static uint64_t now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
__attribute__((noinline)) static void run_hot(uint64_t (*hot)(uint64_t)) {
    uint64_t until = now() + 300000000;
    do { value ^= hot(value + 1); } while (now() < until);
}
static void sequence(void) {
    uintptr_t first = 0;
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    for (unsigned phase = 0; phase < 2; ++phase) {
        void *image = dlopen(paths[phase], RTLD_NOW | RTLD_LOCAL);
        if (!image) { fprintf(stderr,"dlopen: %s\n",dlerror()); exit(2); }
        uint64_t (*hot)(uint64_t) = dlsym(image, phase ? "mapped_hot_b" : "mapped_hot_a");
        if (!hot) exit(2);
        if (!phase) first = (uintptr_t)hot;
        else if (first != (uintptr_t)hot) { fprintf(stderr,"fixture did not reuse the address\n");exit(3); }
        fprintf(stderr,"phase=%u address=%lx time_ns=%llu\n",phase,(unsigned long)(uintptr_t)hot,(unsigned long long)now());
        run_hot(hot);
        if (phase) {
            void *code = (void *)((uintptr_t)hot & ~(page - 1));
            if (mprotect(code,page,PROT_READ|PROT_WRITE)) exit(2);
            if (mprotect(code,page,PROT_READ|PROT_EXEC)) exit(2);
            run_hot(hot);
        }
        if (dlclose(image)) exit(2);
    }
    unsigned char *anon = mmap(NULL,page,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    if (anon == MAP_FAILED) exit(2);
    // x86-64: mov ecx,100000000; dec ecx; jnz; ret. No external references.
    const unsigned char code[] = {0xb9,0x00,0xe1,0xf5,0x05,0xff,0xc9,0x75,0xfc,0xc3};
    memcpy(anon,code,sizeof(code));
    if (mprotect(anon,page,PROT_READ|PROT_EXEC)) exit(2);
    for (unsigned i=0;i<4;++i) ((void (*)(void))anon)();
    if (munmap(anon,page)) exit(2);
}
static void *worker(void *unused) {
    (void)unused;
    pthread_mutex_lock(&mutex);
    ready=1;pthread_cond_broadcast(&condition);
    while (!go) pthread_cond_wait(&condition,&mutex);
    pthread_mutex_unlock(&mutex);
    sequence();
    return NULL;
}
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    paths[0]=argv[1];paths[1]=argv[2];
    int threaded=argc>3 && !strcmp(argv[3],"worker");
    (void)now();
    pthread_t thread;
    if (threaded) {
        if (pthread_create(&thread,NULL,worker,NULL)) return 2;
        pthread_mutex_lock(&mutex);
        while (!ready) pthread_cond_wait(&condition,&mutex);
        pthread_mutex_unlock(&mutex);
    }
    profile_ready();
    if (threaded) {
        pthread_mutex_lock(&mutex);
        go=1;pthread_cond_broadcast(&condition);
        pthread_mutex_unlock(&mutex);
        pthread_join(thread,NULL);
    } else sequence();
    profile_done();
    return 0;
}
