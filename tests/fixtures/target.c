#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <time.h>

volatile uint64_t xodb_counter = 0x123456789abcdef0ULL;
static void *worker(void *unused) {
    (void)unused;
    for (;;) { usleep(10000); }
    return NULL;
}
static void *profile_birth(void *unused) {
    (void)unused;
    // The new thread changes mappings before doing any sustained CPU work.
    void *mapping = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mapping == MAP_FAILED) _exit(3);
    struct timespec start, now;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &start);
    do {
        for (unsigned i = 0; i < 10000; ++i) xodb_counter++;
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &now);
    } while ((now.tv_sec - start.tv_sec) * 1000000000L + now.tv_nsec - start.tv_nsec < 150000000L);
    munmap(mapping, 4096);
    return NULL;
}
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "profile-birth")) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, profile_birth, NULL)) return 2;
        pthread_join(thread, NULL);
        return 0;
    }
    if (argc > 1 && !strcmp(argv[1], "exit")) return 23;
    if (argc > 1 && !strcmp(argv[1], "signal")) { raise(SIGUSR1); return 99; }
    pthread_t thread;
    if (pthread_create(&thread, NULL, worker, NULL)) return 2;
    for (;;) { xodb_counter++; usleep(10000); }
}
