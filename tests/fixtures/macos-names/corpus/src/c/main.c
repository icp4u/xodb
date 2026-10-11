/* cprog: owned fixture for the debugserver transcripts and the symbol corpus.
 * It prints the addresses a test compares against, starts named threads and
 * a dispatch queue, then loops main -> outer -> middle -> inner -> tick. The
 * debugger writes one of the want_* words to ask for an event. */
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include "dep.h"

#define BARRIER __asm__ volatile("" ::: "memory")
volatile uint64_t marker = UINT64_C(0x1122334455667788);
volatile uint32_t halves[2] = {7, 9};
volatile uint32_t want_signal, want_watch, want_read, want_dlopen, want_crash, want_fork, want_exec, want_exit;
volatile uint32_t got_signal, read_sink, workers_up, wait_interrupted;
volatile int32_t child_status = -1;
volatile uint64_t plug_result;
void *volatile plug_handle;
uint8_t *pages;
long pagesize;
static char **saved_argv;

__attribute__((noinline)) void tick(void) { marker++; BARRIER; }
__attribute__((noinline)) void inner(void)
{
    tick();
    if (want_watch) halves[1] = (uint32_t)marker;
    if (want_read) read_sink = halves[0];
    BARRIER;
}
__attribute__((noinline)) void middle(void) { inner(); BARRIER; }
__attribute__((noinline)) void outer(void) { middle(); BARRIER; }
__attribute__((noinline)) void after_dlopen(void) { BARRIER; }
__attribute__((noinline)) void after_dlclose(void) { BARRIER; }
__attribute__((noinline)) void after_fork(void) { BARRIER; }
__attribute__((noinline)) void threads_ready(void) { BARRIER; }
__attribute__((noinline)) void worker_spin(long index) { (void)index; BARRIER; }
static void on_signal(int number) { got_signal = (uint32_t)number; }
static void *worker(void *argument)
{
    char name[32];
    snprintf(name, sizeof name, "xf-worker-%ld", (long)argument);
    pthread_setname_np(name);
    __sync_fetch_and_add(&workers_up, 1);
    for (;;) {
        worker_spin((long)argument);
        usleep(1000);
    }
    return 0;
}
static void queue_work(void *context)
{
    (void)context;
    __sync_fetch_and_add(&workers_up, 1);
    for (;;) usleep(1000);
}
static void requests(void)
{
    if (want_signal) {
        want_signal = 0;
        raise(SIGUSR1);
    }
    if (want_dlopen == 1) {
        want_dlopen = 0;
        plug_handle = dlopen("@loader_path/libplug.dylib", RTLD_NOW | RTLD_LOCAL);
        uint64_t (*entry)(uint64_t) = plug_handle ? (uint64_t (*)(uint64_t))dlsym(plug_handle, "plug_entry") : 0;
        plug_result = entry ? entry(5) : 0;
        after_dlopen();
    }
    if (want_dlopen == 2) {
        want_dlopen = 0;
        if (plug_handle) dlclose(plug_handle);
        plug_handle = 0;
        after_dlclose();
    }
    if (want_crash == 1) *(volatile int *)0x10 = 1;
    if (want_crash == 2) abort();
    if (want_fork) {
        want_fork = 0;
        pid_t child = fork();
        if (child == 0) {
            tick();
            _exit(7);
        }
        int status = -1;
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) wait_interrupted++; /* a debugger stop interrupts the call */
        child_status = status;
        after_fork();
    }
    if (want_exec) execl(saved_argv[0], saved_argv[0], "execd", (char *)0);
    if (want_exit) exit(3);
}
int main(int argc, char **argv)
{
    pthread_t thread;
    saved_argv = argv;
    setvbuf(stdout, 0, _IONBF, 0);
    signal(SIGUSR1, on_signal);
    pagesize = sysconf(_SC_PAGESIZE);
    /* page 0: pattern, readable and writable; page 1: no access; page 2: unmapped. */
    pages = mmap(0, (size_t)pagesize * 3, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (pages == MAP_FAILED) return 1;
    for (long i = 0; i < pagesize; i++) pages[i] = (uint8_t)(i * 7 + (i >> 8));
    mprotect(pages + pagesize, (size_t)pagesize, PROT_NONE);
    munmap(pages + pagesize * 2, (size_t)pagesize);
    printf("pid=%d\nexecd=%d\npagesize=%ld\npages=%p\nmarker=%p\nhalves=%p\nwant_signal=%p\nwant_watch=%p\n"
           "want_read=%p\nwant_dlopen=%p\nwant_crash=%p\nwant_fork=%p\nwant_exec=%p\nwant_exit=%p\n"
           "got_signal=%p\nchild_status=%p\nplug_result=%p\nplug_handle=%p\ndep_counter=%p\n"
           "tick=%p\ninner=%p\nmiddle=%p\nouter=%p\nmain=%p\nafter_dlopen=%p\nafter_dlclose=%p\n"
           "after_fork=%p\nthreads_ready=%p\nworker_spin=%p\ndep_add=%p\nsigusr1=%d\nsigstop=%d\n",
           (int)getpid(), argc > 1 && !strcmp(argv[1], "execd"), pagesize, (void *)pages, (void *)&marker,
           (void *)halves, (void *)&want_signal, (void *)&want_watch, (void *)&want_read, (void *)&want_dlopen,
           (void *)&want_crash, (void *)&want_fork, (void *)&want_exec, (void *)&want_exit, (void *)&got_signal,
           (void *)&child_status, (void *)&plug_result, (void *)&plug_handle, (void *)&dep_counter, (void *)tick,
           (void *)inner, (void *)middle, (void *)outer, (void *)main, (void *)after_dlopen, (void *)after_dlclose,
           (void *)after_fork, (void *)threads_ready, (void *)worker_spin, (void *)dep_add, SIGUSR1, SIGSTOP);
    for (long i = 1; i <= 3; i++)
        if (pthread_create(&thread, 0, worker, (void *)i)) return 1;
    dispatch_async_f(dispatch_queue_create("xodb.fixture.queue", 0), 0, queue_work);
    while (workers_up < 4) usleep(1000);
    puts("ready");
    threads_ready();
    for (;;) {
        outer();
        marker += (uint64_t)dep_add(1, 2) + util_mix(marker, 2) % 3 + (uint64_t)util_sum(3, 1, 2, 3) + types_touch(marker) % 5 + dep_make(4, "tag").id;
        requests();
        usleep(1000);
    }
}
