/* Disposable T03 inferior. Modes are selected by argv[1]. A path in argv[2],
 * when present, receives one hexadecimal integer and a newline. */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ptrace.h>
#include <unistd.h>

volatile uint64_t xodb_marker = 0x1122334455667788ULL;

static void pause_forever(void) {
    sigset_t set;
    sigemptyset(&set);
    sigsuspend(&set);
    pause();
}

static void *pauser(void *arg) {
    (void)arg;
    pause_forever();
    return NULL;
}

static void *nested_outer(void *arg) {
    (void)arg;
    pthread_t thread;
    if (pthread_create(&thread, NULL, pauser, NULL) != 0) _exit(125);
    pause_forever();
    return NULL;
}

static void *exec_sleep(void *arg) {
    char *argv_sleep[] = {"lifecycle", "sleep", NULL};
    (void)arg;
    usleep(50000);
    execv("/proc/self/exe", argv_sleep);
    _exit(127);
}

static void *burst_child(void *arg) {
    (void)arg;
    pause_forever();
    return NULL;
}

static void *burst_spawner(void *arg) {
    pthread_t thread;
    pthread_attr_t attr;
    (void)arg;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&thread, &attr, burst_child, NULL);
    pthread_attr_destroy(&attr);
    return NULL;
}

static void write_hex(const char *path, unsigned long value) {
    FILE *file = fopen(path, "w");
    if (file == NULL) _exit(125);
    if (fprintf(file, "%lx\n", value) < 0) _exit(125);
    if (fclose(file) != 0) _exit(125);
}

int main(int argc, char **argv) {
    const char *mode;
    if (argc < 2) _exit(2);
    mode = argv[1];
    if (strcmp(mode, "sleep") == 0) pause_forever();
    if (strcmp(mode, "exit") == 0) _exit(23);
    if (strcmp(mode, "exit-soon") == 0) {
        usleep(20000);
        _exit(23);
    }
    if (strcmp(mode, "worker") == 0) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, pauser, NULL) != 0) _exit(125);
        pause_forever();
    }
    if (strcmp(mode, "nested") == 0) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, nested_outer, NULL) != 0) _exit(125);
        pause_forever();
    }
    if (strcmp(mode, "leader-exit") == 0) {
        pthread_t thread;
        if (argc < 3) _exit(2);
        if (pthread_create(&thread, NULL, pauser, NULL) != 0) _exit(125);
        write_hex(argv[2], (unsigned long)&xodb_marker);
        pthread_exit(NULL);
    }
    if (strcmp(mode, "leader-exec") == 0) {
        pthread_t thread;
        char *argv_sleep[] = {"lifecycle", "sleep", NULL};
        if (pthread_create(&thread, NULL, pauser, NULL) != 0) _exit(125);
        usleep(50000);
        execv("/proc/self/exe", argv_sleep);
        _exit(127);
    }
    if (strcmp(mode, "nonleader-exec") == 0) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, exec_sleep, NULL) != 0) _exit(125);
        pause_forever();
    }
    if (strcmp(mode, "fork-run") == 0) {
        pid_t child;
        if (argc < 3) _exit(2);
        child = fork();
        if (child < 0) _exit(125);
        if (child == 0) pause_forever();
        write_hex(argv[2], (unsigned long)child);
        pause_forever();
    }
    if (strcmp(mode, "vfork-window") == 0) {
        pid_t child = vfork();
        if (child < 0) _exit(125);
        if (child == 0) {
            sleep(4);
            xodb_marker = 0xABCDEF;
            _exit(0);
        }
        pause_forever();
    }
    if (strcmp(mode, "map-hole") == 0) {
        uint8_t *pages;
        long page;
        if (argc < 3) _exit(2);
        page = sysconf(_SC_PAGESIZE);
        if (page <= 0) _exit(125);
        pages = mmap(NULL, (size_t)page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (pages == MAP_FAILED) _exit(125);
        memset(pages, 0xAB, (size_t)page);
        if (munmap(pages + page, (size_t)page) != 0) _exit(125);
        write_hex(argv[2], (unsigned long)pages);
        pause_forever();
    }
    if (strcmp(mode, "hold-child") == 0) {
        pid_t child;
        if (argc < 3) _exit(2);
        child = fork();
        if (child < 0) _exit(125);
        if (child == 0) pause_forever();
        usleep(20000);
        write_hex(argv[2], (unsigned long)child);
        pause_forever();
    }
    if (strcmp(mode, "burst") == 0) {
        int i;
        for (i = 0; i < 80; i++) {
            pthread_t thread;
            pthread_attr_t attr;
            pthread_attr_init(&attr);
            pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
            if (pthread_create(&thread, &attr, burst_spawner, NULL) != 0) {
                pthread_attr_destroy(&attr);
                break;
            }
            pthread_attr_destroy(&attr);
        }
        pause_forever();
    }
    _exit(2);
}
