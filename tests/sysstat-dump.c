#define _GNU_SOURCE 1
/* Prints one JSON snapshot per line from the live system observer.
 * usage: sysstat-dump [interval_ms] [count] [groups] [flags] */
#include "xrt_sysstat.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
int main(int argc, char **argv)
{
    long interval = argc > 1 ? strtol(argv[1], NULL, 0) : 1000;
    long count = argc > 2 ? strtol(argv[2], NULL, 0) : 2;
    struct xrt_sys_limits l;
    xrt_sys_limits_default(&l);
    if (argc > 3) l.groups = (uint32_t)strtoul(argv[3], NULL, 0);
    if (argc > 4) l.flags = (uint32_t)strtoul(argv[4], NULL, 0);
    struct xrt_sys *s = xrt_sys_open(&l);
    if (!s) return 1;
    struct xrt_sys_snapshot snap = {0};
    struct xrt_sys_json_opts o = {.groups = l.groups, .sort = XRT_SYS_SORT_PID};
    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);
    for (long i = 0; i < count; ++i) {
        if (i) {
            next.tv_nsec += (interval % 1000) * 1000000L;
            next.tv_sec += interval / 1000 + next.tv_nsec / 1000000000L;
            next.tv_nsec %= 1000000000L;
            clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
        }
        if (xrt_sys_sample(s, &snap) != XRT_OK) return 1;
        char *j = xrt_sys_json(&snap, &o);
        if (!j) return 1;
        puts(j);
        fflush(stdout);
        free(j);
    }
    xrt_sys_snapshot_free(&snap);
    xrt_sys_close(s);
    return 0;
}
