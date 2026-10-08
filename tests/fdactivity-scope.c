#define _GNU_SOURCE 1
#include "xrt_fdevent.h"
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>
static unsigned fd_count(void)
{
    DIR *d = opendir("/proc/self/fd");
    assert(d);
    unsigned n = 0;
    struct dirent *e;
    while ((e = readdir(d)))
        if (e->d_name[0] != '.')
            n++;
    closedir(d);
    return n;
}
static void *sleeper(void *unused)
{
    (void)unused;
    for (;;)
        pause();
    return NULL;
}
static uint64_t start(pid_t pid)
{
    char path[64], buf[4096];
    snprintf(path, sizeof path, "/proc/%d/stat", pid);
    FILE *f = fopen(path, "r");
    assert(f);
    assert(fgets(buf, sizeof buf, f));
    fclose(f);
    char *p = strrchr(buf, ')') + 2;
    for (unsigned i = 3; i < 22; i++)
        p = strchr(p, ' ') + 1;
    return strtoull(p, NULL, 10);
}
int main(void)
{
    for (int mode = 0; mode < 2; mode++) {
        const unsigned before = fd_count();
        int ready[2];
        assert(pipe(ready) == 0);
        pid_t child = fork();
        assert(child >= 0);
        if (!child) {
            prctl(PR_SET_PDEATHSIG, SIGKILL);
            close(ready[0]);
            if (mode)
                assert(prctl(PR_SET_DUMPABLE, 0) == 0);
            else
                for (unsigned i = 0; i < 32; i++) {
                    pthread_t thread;
                    assert(pthread_create(&thread, NULL, sleeper, NULL) == 0);
                }
            assert(write(ready[1], "r", 1) == 1);
            for (;;)
                pause();
        }
        close(ready[1]);
        char ch;
        assert(read(ready[0], &ch, 1) == 1);
        close(ready[0]);
        struct xrt_fdevent_options opts = {.pid = child, .expected_start = start(child)};
        struct xrt_fdevent *capture = NULL;
        struct xrt_perf_failure failure = {0};
        enum xrt_status status = xrt_fdevent_open(&opts, &capture, &failure);
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {
        }
        if (status != (mode ? XRT_PERMISSION_DENIED : XRT_TOO_MANY_THREADS) || capture) {
            fprintf(stderr, "mode=%d status=%d errno=%d reason=%s\n", mode, status, failure.error,
                    failure.detail);
            abort();
        }
        assert(fd_count() == before);
        puts(mode ? "PASS non-dumpable owned task reports permission without leaking handles"
                  : "PASS 33-thread scope refuses without leaking handles");
    }
}
