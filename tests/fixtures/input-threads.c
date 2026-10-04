/* T07 fixture: forty idle worker threads, to make a held J or K visible in the thread list. */
#include <pthread.h>
#include <unistd.h>
static void *worker(void *arg) { (void)arg; for (;;) usleep(10000); return 0; }
int main(void) {
    pthread_t t[40];
    for (int i = 0; i < 40; i++) pthread_create(&t[i], 0, worker, 0);
    for (;;) usleep(10000);
}
