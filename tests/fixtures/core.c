#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
static _Atomic int ready;
static void *worker(void *unused) {
    (void)unused;
    atomic_store(&ready, 1);
    for (;;) usleep(1000);
}
__attribute__((noinline)) static void crash_site(long input) {
    volatile long held = input + 1;
    *(volatile int *)0x12345000 = (int)held;
}
int main(void) {
    alarm(15);
    pthread_t thread;
    if (pthread_create(&thread, 0, worker, 0)) return 1;
    while (!atomic_load(&ready)) usleep(1000);
    crash_site(70);
    return 0;
}
