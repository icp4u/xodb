#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <unistd.h>
volatile long result;
__attribute__((noinline)) void policy_event(int n) {
    volatile int copy = n;
    __atomic_fetch_add(&result, copy, __ATOMIC_RELAXED); /* POLICY_STOP */
}
__attribute__((noinline)) void policy_done(void) {
    result += 0;
}
pthread_barrier_t start;
__attribute__((noinline)) void threads_ready(void) { result += 0; }
static void *worker(void *unused) {
    (void)unused;
    pthread_barrier_wait(&start);
    for (int i = 0; i < 4; ++i) policy_event(i);
    return 0;
}
int main(int argc, char **argv) {
    (void)argv;
    if (argc > 1) {
        alarm(15);
        pthread_t thread;
        pthread_barrier_init(&start, 0, 2);
        pthread_create(&thread, 0, worker, 0);
        threads_ready();
        pthread_barrier_wait(&start);
        for (int i = 100; i < 104; ++i) policy_event(i);
        pthread_join(thread, 0);
        policy_done();
        return 0;
    }
    alarm(15);
    for (int i = 0; i < 300; ++i) policy_event(i);
    policy_done();
    return result == 44850 ? 0 : 1;
}
