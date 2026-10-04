/* Owned syscall workloads. --sync blocks until the tracer enables, so the
   timed section is the part a task-scoped collector can see. A helper process
   is used only for the known pipe wait; the collector is not supposed to
   follow it. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static long long mono(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) _exit(9);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void sync_go(int enabled) {
    char byte = 'R';
    if (!enabled) return;
    if (write(3, &byte, 1) != 1) _exit(2);
    if (read(4, &byte, 1) != 1) _exit(3);
}

static int copy_files(const char *dir, int *ops) {
    char src[512];
    char dst[512];
    char buf[4096];
    int i;
    int in;
    int out;
    int n;
    if (snprintf(src, sizeof src, "%s/src.bin", dir) >= (int)sizeof src) return 6;
    if (snprintf(dst, sizeof dst, "%s/dst.bin", dir) >= (int)sizeof dst) return 6;
    out = open(src, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (out < 0) return 6;
    memset(buf, 0x5a, sizeof buf);
    for (i = 0; i < 64; i++) {
        if (write(out, buf, sizeof buf) != (ssize_t)sizeof buf) return 6;
    }
    if (close(out) != 0) return 6;
    in = open(src, O_RDONLY);
    out = open(dst, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (in < 0 || out < 0) return 6;
    while ((n = (int)read(in, buf, sizeof buf)) > 0) {
        int off = 0;
        while (off < n) {
            int w = (int)write(out, buf + off, (size_t)(n - off));
            if (w < 0) return 6;
            off += w;
            *ops += 1;
        }
    }
    if (n < 0) return 6;
    if (close(in) != 0 || close(out) != 0) return 6;
    if (unlink(src) != 0 || unlink(dst) != 0) return 6;
    return 0;
}

static int wait_pipe(long long *programmed, long long *blocked, int *helper) {
    int fds[2];
    pid_t child;
    char byte = 0;
    int n;
    int status = 0;
    long long start;
    if (pipe(fds) != 0) return 4;
    child = fork();
    if (child < 0) return 4;
    if (child == 0) {
        struct timespec req;
        close(fds[0]);
        req.tv_sec = 0;
        req.tv_nsec = 50000000L;
        nanosleep(&req, NULL);
        byte = 1;
        if (write(fds[1], &byte, 1) != 1) _exit(5);
        _exit(0);
    }
    *helper = (int)child;
    close(fds[1]);
    *programmed = 50000000LL;
    start = mono();
    n = (int)read(fds[0], &byte, 1);
    *blocked = mono() - start;
    close(fds[0]);
    if (waitpid(child, &status, 0) < 0) return 5;
    if (n != 1 || byte != 1) return 5;
    return 0;
}

static int cpu_loop(int *ops) {
    volatile unsigned value = 1;
    int i;
    for (i = 0; i < 20000000; i++) value += (unsigned)i;
    if (value == 0) return 7;
    *ops = 20000000;
    return 0;
}

int main(int argc, char **argv) {
    int arg = 1;
    int sync = 0;
    const char *mode;
    const char *dir;
    struct rusage before;
    struct rusage after;
    long long t0;
    long long wall;
    long user_us;
    long sys_us;
    int ops = 0;
    long long programmed = 0;
    long long blocked = 0;
    int helper = 0;
    int rc;
    setvbuf(stdout, NULL, _IONBF, 0);
    if (arg < argc && strcmp(argv[arg], "--sync") == 0) {
        sync = 1;
        arg++;
    }
    if (arg + 1 >= argc) return 2;
    mode = argv[arg];
    dir = argv[arg + 1];
    sync_go(sync);
    if (getrusage(RUSAGE_SELF, &before) != 0) return 9;
    t0 = mono();
    if (strcmp(mode, "copy") == 0) rc = copy_files(dir, &ops);
    else if (strcmp(mode, "wait") == 0) rc = wait_pipe(&programmed, &blocked, &helper);
    else if (strcmp(mode, "cpu") == 0) rc = cpu_loop(&ops);
    else return 2;
    wall = mono() - t0;
    if (rc != 0) return rc;
    if (getrusage(RUSAGE_SELF, &after) != 0) return 9;
    user_us = (long)((after.ru_utime.tv_sec - before.ru_utime.tv_sec) * 1000000L +
                     (after.ru_utime.tv_usec - before.ru_utime.tv_usec));
    sys_us = (long)((after.ru_stime.tv_sec - before.ru_stime.tv_sec) * 1000000L +
                    (after.ru_stime.tv_usec - before.ru_stime.tv_usec));
    printf("RESULT fixture mode=%s wall_ns=%lld user_us=%ld sys_us=%ld maxrss_kb=%ld ops=%d programmed_ns=%lld blocked_ns=%lld helper_tid=%d\n",
           mode, wall, user_us, sys_us, after.ru_maxrss, ops, programmed, blocked, helper);
    return 0;
}
