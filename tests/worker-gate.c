/* Test-only pthread launch gate. Never preload this into a user application. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct launch { void *(*run)(void *); void *arg; char round[PATH_MAX]; };
static void path(char *out, size_t size, const char *base, const char *suffix) {
    int n = snprintf(out, size, "%s/%s", base, suffix);
    if (n < 0 || (size_t)n >= size) _exit(125);
}
static void mark(const char *round, const char *name) {
    char file[PATH_MAX]; path(file, sizeof file, round, name);
    int fd = open(file, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0644);
    if (fd < 0 || close(fd)) _exit(125);
}
static void *held(void *arg) {
    struct launch saved = *(struct launch *)arg;
    free(arg);
    char release[PATH_MAX]; path(release, sizeof release, saved.round, "release");
    mark(saved.round, "entered");
    struct timespec began, now;
    if (clock_gettime(CLOCK_MONOTONIC, &began)) _exit(125);
    while (access(release, F_OK)) {
        if (errno != ENOENT || clock_gettime(CLOCK_MONOTONIC, &now)) _exit(125);
        /* Watchdog only: a successful test explicitly releases the callback. */
        if (now.tv_sec - began.tv_sec >= 60) { mark(saved.round, "timeout"); _exit(124); }
        struct timespec pause = {.tv_nsec = 1000000};
        (void)nanosleep(&pause, NULL);
    }
    mark(saved.round, "released");
    return saved.run(saved.arg);
}
int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*run)(void *), void *arg) {
    int (*real_create)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) =
        dlsym(RTLD_NEXT, "pthread_create");
    if (!real_create) return EAGAIN;
    const char *base = getenv("XODB_TEST_WORKER_GATE");
    if (!base) return real_create(thread, attr, run, arg);
    char arm[PATH_MAX], claimed[PATH_MAX];
    path(arm, sizeof arm, base, "arm"); path(claimed, sizeof claimed, base, "claimed");
    int fd = open(arm, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return real_create(thread, attr, run, arg);
    struct launch *saved = calloc(1, sizeof *saved);
    if (!saved) { close(fd); return ENOMEM; }
    ssize_t n = read(fd, saved->round, sizeof saved->round - 1);
    close(fd);
    if (n <= 0 || saved->round[0] != '/') { free(saved); return EINVAL; }
    if (rename(arm, claimed)) { free(saved); return real_create(thread, attr, run, arg); }
    saved->run = run; saved->arg = arg;
    int result = real_create(thread, attr, held, saved);
    if (result) { mark(saved->round, "spawn-failed"); free(saved); }
    return result;
}
