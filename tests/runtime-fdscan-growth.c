#define _GNU_SOURCE 1
#include "check.h"
#include "xrt_fdgraph.h"
#include "xrt_fdscan.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static struct {
    void *pointer;
    size_t bytes;
} allocations[256];
static size_t live_bytes, peak_bytes, max_request;
static int fail_after = -1;
static int reject(void) {
    if (fail_after < 0)
        return 0;
    if (!fail_after) {
        errno = ENOMEM;
        return 1;
    }
    --fail_after;
    return 0;
}
static void remember(void *p, size_t n) {
    CHECK(p);
    unsigned i = 0;
    while (i < 256 && allocations[i].pointer)
        ++i;
    CHECK(i < 256);
    allocations[i].pointer = p;
    allocations[i].bytes = n;
    live_bytes += n;
    if (live_bytes > peak_bytes)
        peak_bytes = live_bytes;
    if (n > max_request)
        max_request = n;
}
static void forget(void *p) {
    if (!p)
        return;
    unsigned i = 0;
    while (i < 256 && allocations[i].pointer != p)
        ++i;
    CHECK(i < 256);
    live_bytes -= allocations[i].bytes;
    allocations[i].pointer = NULL;
}
static void *tracked_malloc(size_t n) {
    if (reject())
        return NULL;
    void *p = malloc(n);
    if (p)
        remember(p, n);
    return p;
}
static void *tracked_calloc(size_t n, size_t width) {
    if (reject())
        return NULL;
    void *p = calloc(n, width);
    if (p)
        remember(p, n * width);
    return p;
}
static void *tracked_realloc(void *p, size_t n) {
    if (reject())
        return NULL;
    /* Remove bookkeeping before realloc invalidates p; restore on failure. */
    size_t previous = 0;
    for (unsigned i = 0; i < 256; ++i)
        if (allocations[i].pointer == p && p)
            previous = allocations[i].bytes;
    forget(p);
    void *q = realloc(p, n);
    if (q)
        remember(q, n);
    else if (p)
        remember(p, previous);
    return q;
}
static void tracked_free(void *p) {
    forget(p);
    free(p);
}
#define malloc tracked_malloc
#define calloc tracked_calloc
#define realloc tracked_realloc
#define free tracked_free
#include "../src/runtime/fdscan.c"
#undef malloc
#undef calloc
#undef realloc
#undef free

static uint64_t resident(void) {
    FILE *f = fopen("/proc/self/statm", "r");
    CHECK(f);
    unsigned long size, pages;
    CHECK(fscanf(f, "%lu %lu", &size, &pages) == 2);
    CHECK(!fclose(f));
    return (uint64_t)pages * (uint64_t)sysconf(_SC_PAGESIZE);
}
static void cgroups(void) {
    CHECK(!mkdir(".work", 0755) || errno == EEXIST);
    char path[] = ".work/fdgroup-XXXXXX";
    CHECK(mkdtemp(path));
    CHECK(!chmod(path, 0755));
    int dir = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    CHECK(dir >= 0);
    const char *cases[] = {"0::/demo.slice/example.service\n", "2:cpu:/legacy\n", "0::/one\n0::/two\n",
                           "0::/unterminated"};
    const enum xrt_fd_cgroup_status expected[] = {XRT_FD_CGROUP_CURRENT, XRT_FD_CGROUP_UNSUPPORTED,
                                                  XRT_FD_CGROUP_MALFORMED, XRT_FD_CGROUP_MALFORMED};
    struct xrt_fdscan scanner = {.o = {.max_strings = 4096}};
    struct snap snapshot = {.nstrings = 1};
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; ++i) {
        int fd = openat(dir, "cgroup", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        CHECK(fd >= 0);
        size_t n = strlen(cases[i]);
        CHECK(write(fd, cases[i], n) == (ssize_t)n);
        CHECK(!close(fd));
        struct xrt_fd_process process = {0};
        read_cgroup(&scanner, &snapshot, &process, dir);
        CHECK(process.cgroup_status == expected[i]);
        if (!i)
            CHECK(process.cgroup_length == 27 &&
                  !strcmp(snapshot.strings + process.cgroup, "/demo.slice/example.service"));
        else
            CHECK(!process.cgroup_length);
    }
    CHECK(!unlinkat(dir, "cgroup", 0));
    struct xrt_fd_process missing = {0};
    read_cgroup(&scanner, &snapshot, &missing, dir);
    CHECK(missing.cgroup_status == XRT_FD_CGROUP_UNAVAILABLE && missing.cgroup_error == ENOENT);
    CHECK(!close(dir) && !rmdir(path));
    tracked_free(snapshot.strings);
    CHECK(!live_bytes);
}
int main(int argc, char **argv) {
    cgroups();
    int large = argc == 2 && !strcmp(argv[1], "--large"),
        wrong = argc == 2 && !strcmp(argv[1], "--wrong-oracle");
    struct rlimit limit;
    CHECK(!getrlimit(RLIMIT_NOFILE, &limit));
    uint32_t count = large ? 100000 : limit.rlim_cur >= 2048 ? 1024 : 256;
    unsigned children = large ? 2 : 1;
    uint32_t each = count / children;
    CHECK(limit.rlim_cur >= each + 64u);
    int commands[2][2], answers[2][2];
    int32_t pids[2];
    for (unsigned child_index = 0; child_index < children; ++child_index) {
        CHECK(!pipe(commands[child_index]) && !pipe(answers[child_index]));
        pid_t child = fork();
        CHECK(child >= 0);
        if (!child) {
            for (unsigned i = 0; i < child_index; ++i) {
                close(commands[i][1]);
                close(answers[i][0]);
            }
            close(commands[child_index][1]);
            close(answers[child_index][0]);
            int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
            if (fd < 0)
                _exit(2);
            if (write(answers[child_index][1], "r", 1) != 1)
                _exit(3);
            char c;
            while (read(commands[child_index][0], &c, 1) == 1 && c != 'q') {
                for (uint32_t i = 0; i < each; ++i)
                    if (dup(fd) < 0)
                        _exit(4);
                if (write(answers[child_index][1], "r", 1) != 1)
                    _exit(5);
            }
            _exit(0);
        }
        pids[child_index] = child;
        close(commands[child_index][0]);
        close(answers[child_index][1]);
        char ready;
        CHECK(read(answers[child_index][0], &ready, 1) == 1);
    }
    struct xrt_fdscan_options o = {.pids = pids,
                                   .pid_count = children,
                                   .max_fds = 262144,
                                   .max_processes = 16384,
                                   .max_strings = 16u << 20};
    struct xrt_fdscan *s = NULL;
    CHECK(xrt_fdscan_create(&o, &s) == XRT_OK);
    /* Huge caps do not reserve their arrays at construction. */
    CHECK(live_bytes < 128u * 1024 && max_request <= 32768);
    struct xrt_fd_snapshot first, current;
    CHECK(xrt_fdscan_poll(s, &first) == XRT_OK);
    CHECK(first.process_count == children);
    uint32_t initial = first.fd_count;
    for (unsigned i = 0; i < children; ++i) {
        char ready;
        CHECK(write(commands[i][1], "g", 1) == 1 && read(answers[i][0], &ready, 1) == 1);
    }
    fail_after = 0;
    CHECK(xrt_fdscan_poll(s, &current) == XRT_OUT_OF_MEMORY);
    fail_after = -1;
    CHECK(s->sequence == first.sequence && first.fd_count == initial && first.process_count == children);
    uint64_t rss_before = resident(), cpu = clock_ns(CLOCK_PROCESS_CPUTIME_ID),
             wall = clock_ns(CLOCK_MONOTONIC);
    CHECK(xrt_fdscan_poll(s, &current) == XRT_OK);
    uint64_t cpu_ns = clock_ns(CLOCK_PROCESS_CPUTIME_ID) - cpu, wall_ns = clock_ns(CLOCK_MONOTONIC) - wall,
             rss_after = resident();
    CHECK(current.fd_count == initial + count && !current.dropped_fds && current.process_count == children);
    CHECK(s->s[s->cur].fds_cap >= current.fd_count && s->s[s->cur].fds_cap < current.fd_count * 2);
    const struct xrt_fd_file *files = NULL;
    uint32_t nfiles = 0;
    CHECK(xrt_fdscan_files(s, &files, &nfiles) == XRT_OK && nfiles > 0 && nfiles < initial + 2);
    uint64_t total = 0;
    for (uint32_t i = 0; i < nfiles; ++i)
        total += files[i].fds;
    CHECK(total == current.fd_count);
    struct xrt_fdgraph *g = NULL;
    CHECK(xrt_fdgraph_build(&current, NULL, 0, &g) == XRT_OK && g->member_count == current.fd_count);
    xrt_fdgraph_free(g);
    /* Failure during aggregate growth also keeps prior allocations owned. */
    s->files_sequence = 0;
    s->files_cap = 0;
    fail_after = 0;
    CHECK(xrt_fdscan_files(s, &files, &nfiles) == XRT_OUT_OF_MEMORY);
    fail_after = -1;
    CHECK(xrt_fdscan_files(s, &files, &nfiles) == XRT_OK);
    size_t retained = live_bytes;
    xrt_fdscan_destroy(s);
    CHECK(!live_bytes);
    for (unsigned i = 0; i < children; ++i) {
        CHECK(write(commands[i][1], "q", 1) == 1);
        close(commands[i][1]);
        close(answers[i][0]);
        int status;
        CHECK(waitpid(pids[i], &status, 0) == pids[i] && WIFEXITED(status) && !WEXITSTATUS(status));
    }
    CHECK(!wrong);
    printf("{\"owned_added_fds\":%u,\"cpu_ns\":%llu,\"wall_ns\":%llu,\"rss_before\":%llu,\"rss_after\":%llu,"
           "\"retained_bytes\":%zu,\"peak_bytes\":%zu}\n",
           count, (unsigned long long)cpu_ns, (unsigned long long)wall_ns, (unsigned long long)rss_before,
           (unsigned long long)rss_after, retained, peak_bytes);
    puts("fdscan demand growth: bounded allocation, owned counts, failed-scan retention, aggregate cleanup "
         "PASS");
    return 0;
}
