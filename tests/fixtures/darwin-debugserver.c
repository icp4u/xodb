/* Owned fixture for the debugserver tests. It prints the addresses and signal
 * numbers the test compares against, then loops: main -> outer -> middle ->
 * inner -> tick. The debugger sets want_watch or want_signal to ask for a
 * watched write or a SIGUSR1. Built on the Mac by tests/macos-debugserver.py. */
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

volatile uint64_t marker = UINT64_C(0x1122334455667788);
volatile uint32_t halves[2] = {7, 9};
volatile uint32_t want_signal, want_watch, got_signal;

__attribute__((noinline)) void tick(void) { marker++; __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void inner(void)
{
    tick();
    if (want_watch) halves[1] = (uint32_t)marker; /* the second half of the watched pair */
    __asm__ volatile("" ::: "memory");
}
__attribute__((noinline)) void middle(void) { inner(); __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void outer(void) { middle(); __asm__ volatile("" ::: "memory"); }
static void on_signal(int number) { got_signal = (uint32_t)number; }
static void *worker(void *unused)
{
    (void)unused;
    for (;;) usleep(1000);
    return 0;
}
int main(void)
{
    pthread_t thread;
    signal(SIGUSR1, on_signal);
    printf("pid=%d\nmarker=%p\nhalves=%p\nwant_signal=%p\nwant_watch=%p\ngot_signal=%p\n"
           "tick=%p\ninner=%p\nmiddle=%p\nouter=%p\nmain=%p\nsigusr1=%d\nsigstop=%d\nready\n",
           (int)getpid(), (void *)&marker, (void *)halves, (void *)&want_signal,
           (void *)&want_watch, (void *)&got_signal, (void *)tick, (void *)inner,
           (void *)middle, (void *)outer, (void *)main, SIGUSR1, SIGSTOP);
    fflush(stdout);
    if (pthread_create(&thread, 0, worker, 0)) return 1;
    for (;;) {
        outer();
        if (want_signal) {
            want_signal = 0;
            raise(SIGUSR1);
        }
        usleep(1000);
    }
}
