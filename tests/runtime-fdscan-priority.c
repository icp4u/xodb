/* Fast synthetic scheduler regression. The injected clock bounds each scan to
 * one process without relying on filesystem speed or sleeping under load. */
#define _GNU_SOURCE 1
#include <time.h>
static int scan_clock(clockid_t, struct timespec *);
#define clock_gettime scan_clock
#include "../src/runtime/fdscan.c"
#undef clock_gettime
#include "check.h"
#include <sys/resource.h>

static uint64_t ticks;
static int scan_clock(clockid_t id, struct timespec *t)
{
    if (id != CLOCK_MONOTONIC) return clock_gettime(id, t);
    ticks += 1000000;
    t->tv_sec = (time_t)(ticks / 1000000000);
    t->tv_nsec = (long)(ticks % 1000000000);
    return 0;
}

static char root[] = ".work/fdpriority-XXXXXX";
static const int32_t fixture_pids[] = {100, 200, 300, 800, 900};

static void setup(void)
{
    (void)mkdir(".work", 0755);
    CHECK(mkdtemp(root));
    CHECK(chmod(root, 0755) == 0);
    for (unsigned i = 0; i < sizeof fixture_pids / sizeof *fixture_pids; i++) {
        const int pid = fixture_pids[i];
        char path[256];
        snprintf(path, sizeof path, "%s/%d", root, pid);
        CHECK(mkdir(path, 0755) == 0);
        snprintf(path, sizeof path, "%s/%d/stat", root, pid);
        FILE *f = fopen(path, "w");
        CHECK(f);
        CHECK(fprintf(f, "%d (priority-fixture) S 1 %d %d 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 1234 0 0\n", pid, pid, pid) > 0);
        CHECK(fclose(f) == 0);
        snprintf(path, sizeof path, "%s/%d/fd", root, pid);
        CHECK(mkdir(path, 0755) == 0);
        snprintf(path, sizeof path, "%s/%d/fd/0", root, pid);
        CHECK(symlink("pipe:[7]", path) == 0);
    }
}

static void cleanup(void)
{
    for (unsigned i = 0; i < sizeof fixture_pids / sizeof *fixture_pids; i++) {
        char path[256];
        snprintf(path, sizeof path, "%s/%d/fd/0", root, fixture_pids[i]);
        CHECK(unlink(path) == 0);
        snprintf(path, sizeof path, "%s/%d/fd", root, fixture_pids[i]);
        CHECK(rmdir(path) == 0);
        snprintf(path, sizeof path, "%s/%d/stat", root, fixture_pids[i]);
        CHECK(unlink(path) == 0);
        snprintf(path, sizeof path, "%s/%d", root, fixture_pids[i]);
        CHECK(rmdir(path) == 0);
    }
    CHECK(rmdir(root) == 0);
}

static struct xrt_fdscan *create(void)
{
    const struct xrt_fdscan_options o = {.proc = root, .include_self = 1, .budget_ms = 1};
    struct xrt_fdscan *s = NULL;
    CHECK(xrt_fdscan_create(&o, &s) == XRT_OK);
    return s;
}

static void ordered(const struct xrt_fd_snapshot *v, unsigned total)
{
    unsigned stale = 0;
    for (uint32_t i = 0; i < v->process_count; i++) {
        const struct xrt_fd_process *p = &v->processes[i];
        CHECK(!i || v->processes[i - 1].pid < p->pid);
        CHECK(!i || v->processes[i - 1].first <= p->first);
        CHECK(p->first <= v->fd_count && p->count <= v->fd_count - p->first);
        if (p->flags & XRT_FDP_STALE) {
            stale++;
            CHECK(p->opened == 0 && p->closed == 0 && p->interval_ns == 0);
        }
    }
    CHECK(stale == v->stale);
    CHECK(v->process_count + v->unscanned + v->gone + v->hidden + v->kernel_threads + v->dropped_processes == total);
}

static int32_t poll_one(struct xrt_fdscan *s, unsigned total)
{
    struct xrt_fd_snapshot v;
    CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
    ordered(&v, total);
    int32_t fresh = 0;
    for (uint32_t i = 0; i < v.process_count; i++) {
        if (!(v.processes[i].flags & XRT_FDP_STALE)) {
            CHECK(!fresh);
            fresh = v.processes[i].pid;
        }
    }
    CHECK(fresh);
    return fresh;
}

static void scheduler(void)
{
    struct xrt_fdscan *s = create();
    const int32_t demand[] = {900, 800, 800, 999};
    CHECK(xrt_fdscan_interest(s, demand, 4, 1) == XRT_OK);
    /* The first scan is a deadline-cut full sweep. Then priority rotates in
     * PID order, independent of the preserved background cursor. Every
     * background PID advances even with continuous demand. */
    const int32_t expected[] = {100, 800, 200, 900, 300, 800, 800, 900, 900, 800};
    for (unsigned i = 0; i < sizeof expected / sizeof *expected; i++)
        CHECK(poll_one(s, 5) == expected[i]);
    CHECK(xrt_fdscan_interest(s, NULL, 0, 1) == XRT_OK);
    CHECK(poll_one(s, 5) == 100);
    CHECK(poll_one(s, 5) == 200);
    CHECK(poll_one(s, 5) == 300);
    xrt_fdscan_destroy(s);
    puts("PASS priority rotation, background progress, sorted/stale accounting and removed demand");

    s = create();
    const int32_t missing = 999;
    CHECK(xrt_fdscan_interest(s, &missing, 1, 1) == XRT_OK);
    CHECK(poll_one(s, 5) == 100);
    CHECK(poll_one(s, 5) == 200);
    CHECK(xrt_fdscan_interest(s, NULL, 0, 1) == XRT_OK);
    CHECK(poll_one(s, 5) == 300);
    CHECK(poll_one(s, 5) == 800);
    xrt_fdscan_destroy(s);
    puts("PASS missing PIDs and poll_all do not consume priority turns");

    s = create();
    xrt_fdscan_detail(s, 900);
    CHECK(poll_one(s, 5) == 100);
    CHECK(poll_one(s, 5) == 900);
    CHECK(poll_one(s, 5) == 200);
    CHECK(poll_one(s, 5) == 900);
    xrt_fdscan_detail(s, 0);
    CHECK(poll_one(s, 5) == 300);
    xrt_fdscan_destroy(s);
    puts("PASS detail demand uses the same scheduler and releases its turns");

    const int32_t scope[] = {100, 100, 800};
    const struct xrt_fdscan_options scoped = {.proc = root, .include_self = 1,
        .budget_ms = 1, .pids = scope, .pid_count = 3};
    CHECK(xrt_fdscan_create(&scoped, &s) == XRT_OK);
    for (unsigned i = 0; i < 12; i++) {
        s->window = 1; /* hold the smallest window across every adaptive turn */
        CHECK(poll_one(s, 2) == (i % 2 ? 800 : 100));
    }
    xrt_fdscan_destroy(s);
    puts("PASS one-PID windows advance and wrap past duplicate scoped PIDs without demand");

    CHECK(xrt_fdscan_create(&scoped, &s) == XRT_OK);
    const int32_t scoped_demand[] = {900, 100, 800};
    CHECK(xrt_fdscan_interest(s, scoped_demand, 3, 0) == XRT_OK);
    CHECK(poll_one(s, 2) == 100);
    CHECK(poll_one(s, 2) == 100);
    CHECK(poll_one(s, 2) == 800);
    CHECK(poll_one(s, 2) == 100);
    xrt_fdscan_destroy(s);
    puts("PASS duplicate listing and out-of-scope demand");

    const struct xrt_fdscan_options limited = {.proc = root, .include_self = 1,
        .budget_ms = 1, .max_processes = 2, .max_fds = 2, .max_strings = 256};
    CHECK(xrt_fdscan_create(&limited, &s) == XRT_OK);
    CHECK(xrt_fdscan_interest(s, demand, 4, 1) == XRT_OK);
    for (unsigned i = 0; i < 12; i++) {
        struct xrt_fd_snapshot v;
        CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
        ordered(&v, 5);
        CHECK(v.fd_count <= 2 && v.process_count <= 2 && v.strings_length <= 256);
        CHECK(v.dropped_processes > 0);
    }
    xrt_fdscan_destroy(s);
    puts("PASS priority preserves row and string limits");

    s = create();
    CHECK(xrt_fdscan_interest(s, demand, 4, 1) == XRT_OK);
    CHECK(poll_one(s, 5) == 100);
    CHECK(poll_one(s, 5) == 800);
    xrt_fdscan_budget(s, 0);
    struct xrt_fd_snapshot v;
    CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
    ordered(&v, 5);
    CHECK(v.process_count == 5 && v.stale == 0 && v.unscanned == 0);
    xrt_fdscan_budget(s, 1);
    CHECK(poll_one(s, 5) == 100);
    CHECK(poll_one(s, 5) == 800);
    xrt_fdscan_destroy(s);
    puts("PASS unbudgeted scans remain complete and resetting the budget resets cursors");

    /* A budget that covers the whole list keeps every scan complete: demand
     * must not cut a full sweep short at the requested PID. */
    const struct xrt_fdscan_options roomy = {.proc = root, .include_self = 1, .budget_ms = 1000};
    CHECK(xrt_fdscan_create(&roomy, &s) == XRT_OK);
    CHECK(xrt_fdscan_interest(s, demand, 4, 1) == XRT_OK);
    for (unsigned i = 0; i < 6; i++) {
        CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
        ordered(&v, 5);
        CHECK(v.process_count == 5 && v.stale == 0 && v.unscanned == 0);
    }
    xrt_fdscan_destroy(s);
    puts("PASS demand under a sufficient budget keeps full sweeps");
}

/* Evidence mode compares CPU/RSS and sample gaps on the same small owned tree;
 * it is not a timing oracle or a claim about a particular busy host. */
static long resident_kib(void)
{
    FILE *f = fopen("/proc/self/statm", "r");
    unsigned long size, resident;
    CHECK(f && fscanf(f, "%lu %lu", &size, &resident) == 2);
    CHECK(fclose(f) == 0);
    const long page = sysconf(_SC_PAGESIZE);
    CHECK(page > 0);
    return (long)(resident * (unsigned long)page / 1024);
}

static void measure(void)
{
    struct xrt_fdscan *s = create();
    const int32_t wanted = 900;
    CHECK(xrt_fdscan_interest(s, &wanted, 1, 1) == XRT_OK);
    const long rss_before = resident_kib();
    const uint64_t cpu_start = clock_ns(CLOCK_PROCESS_CPUTIME_ID);
    unsigned last = 0, max_gap = 0, samples = 0;
    for (unsigned i = 1; i <= 2000; i++) {
        if (poll_one(s, 5) == wanted) {
            if (i - last > max_gap) max_gap = i - last;
            last = i;
            samples++;
        }
    }
    const uint64_t cpu_used = clock_ns(CLOCK_PROCESS_CPUTIME_ID) - cpu_start;
    struct rusage after;
    CHECK(getrusage(RUSAGE_SELF, &after) == 0);
    printf("polls=2000 target_samples=%u max_gap_polls=%u cpu_ns=%llu rss_before_kib=%ld rss_after_kib=%ld rss_peak_kib=%ld\n",
           samples, max_gap, (unsigned long long)cpu_used, rss_before, resident_kib(), after.ru_maxrss);
    xrt_fdscan_destroy(s);
}

int main(int argc, char **argv)
{
    setup();
    if (argc == 2 && !strcmp(argv[1], "--measure")) measure();
    else { CHECK(argc == 1); scheduler(); }
    cleanup();
    return 0;
}
