/* fd scanner: a synthetic procfs tree for parsing, limits and budgets, then
 * owned child processes with exactly known descriptor activity. */
#define _GNU_SOURCE 1
#include "xrt_fdscan.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int failures;
#define CHECK(x)                                                                 \
    do {                                                                         \
        if (!(x)) {                                                              \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #x); \
            failures++;                                                          \
        }                                                                        \
    } while (0)

static char root[256];

static void write_file(const char *path, const char *text)
{
    FILE *f = fopen(path, "w");
    if (!f || fputs(text, f) < 0 || fclose(f)) {
        perror(path);
        exit(1);
    }
}
static void fake_process(int pid, const char *comm, unsigned flags, unsigned long long start, unsigned long long rchar)
{
    char path[512], text[512];
    snprintf(path, sizeof(path), "%s/%d", root, pid);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/%d/stat", root, pid);
    snprintf(text, sizeof(text), "%d (%s) S 1 %d %d 0 -1 %u 0 0 0 0 0 0 0 0 20 0 1 0 %llu 0 0\n", pid, comm, pid, pid, flags, start);
    write_file(path, text);
    snprintf(path, sizeof(path), "%s/%d/io", root, pid);
    snprintf(text, sizeof(text), "rchar: %llu\nwchar: 7\nsyscr: 1\nsyscw: 1\nread_bytes: 0\nwrite_bytes: 0\n", rchar);
    write_file(path, text);
    snprintf(path, sizeof(path), "%s/%d/cmdline", root, pid);
    FILE *f = fopen(path, "w");
    fwrite("fake\0--flag\0", 1, 12, f);
    fclose(f);
    snprintf(path, sizeof(path), "%s/%d/fd", root, pid);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/%d/fdinfo", root, pid);
    mkdir(path, 0755);
}
static void fake_fd(int pid, int fd, const char *target, const char *info)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/%d/fd/%d", root, pid, fd);
    unlink(path);
    if (symlink(target, path)) {
        perror(path);
        exit(1);
    }
    snprintf(path, sizeof(path), "%s/%d/fdinfo/%d", root, pid, fd);
    write_file(path, info ? info : "pos:\t0\nflags:\t02\nmnt_id:\t1\n");
}
static const struct xrt_fd_process *find(const struct xrt_fd_snapshot *v, int pid)
{
    for (uint32_t i = 0; i < v->process_count; i++)
        if (v->processes[i].pid == pid)
            return &v->processes[i];
    return NULL;
}
static const struct xrt_fd_unseen *find_unseen(const struct xrt_fd_snapshot *v, int pid)
{
    for (uint32_t i = 0; i < v->unseen_count; i++)
        if (v->unseen[i].pid == pid)
            return &v->unseen[i];
    return NULL;
}
static const struct xrt_fd *find_fd(const struct xrt_fd_snapshot *v, const struct xrt_fd_process *p, int fd)
{
    for (uint32_t i = 0; p && i < p->count; i++)
        if (v->fds[p->first + i].fd == fd)
            return &v->fds[p->first + i];
    return NULL;
}

static void synthetic(void)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/data", root);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/data/regular", root);
    write_file(path, "0123456789abcdef");
    fake_process(50, "empty", 0x400100, 9, 0); /* scanned first: no fds yet anywhere */
    fake_process(100, "fake (x) one", 0x400100, 4242, 1000);
    fake_fd(100, 0, "/dev/null", NULL);
    fake_fd(100, 3, "socket:[12345]", NULL);
    fake_fd(100, 4, "pipe:[777]", NULL);
    fake_fd(100, 5, "anon_inode:[eventfd]", NULL);
    fake_fd(100, 6, "/memfd:shm (deleted)", NULL);
    fake_fd(100, 7, "/nonexistent/gone (deleted)", NULL);
    fake_fd(100, 8, path, "pos:\t10\nflags:\t0102001\nmnt_id:\t1\n");
    fake_process(200, "kworker/0:1", 0x00200040, 5, 0); /* kernel thread: skipped */
    fake_process(300, "denied", 0x400100, 77, 0);
    fake_process(400, "torn", 0, 1, 0);
    snprintf(path, sizeof(path), "%s/400/stat", root);
    write_file(path, "400 (torn");
    snprintf(path, sizeof(path), "%s/300/fd", root);
    chmod(path, 0);
    const int root_user = geteuid() == 0;

    struct xrt_fdscan *s;
    /* The fake tree may hold this test's own pid: never leave it out. */
    struct xrt_fdscan_options o = { .include_self = 1, .proc = root };
    CHECK(xrt_fdscan_create(&o, &s) == XRT_OK);
    struct xrt_fd_snapshot v;
    CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
    CHECK(v.interval_ns == 0 && v.sequence == 1);
    CHECK(!find(&v, 200) && !find(&v, 400) && !find(&v, 300));
    CHECK(find_unseen(&v, 200) && find_unseen(&v, 200)->kernel && v.kernel_threads == 1);
    CHECK(find(&v, 50) && find(&v, 50)->count == 0);
    CHECK(v.gone == 1);
    const struct xrt_fd_process *p = find(&v, 100);
    CHECK(p && !strcmp(p->comm, "fake (x) one") && p->start == 4242 && p->ppid == 1);
    CHECK(p && p->count == 7 && (p->flags & XRT_FDP_NEW));
    CHECK(p && p->cmdline_length == 12 && !strcmp(v.strings + p->cmdline, "fake"));
    const struct xrt_fd *f = find_fd(&v, p, 0);
    CHECK(f && f->kind == XRT_FD_DEVICE);
    CHECK((f = find_fd(&v, p, 3)) && f->kind == XRT_FD_SOCKET && !(f->flags & XRT_FD_STAT));
    CHECK((f = find_fd(&v, p, 4)) && f->kind == XRT_FD_PIPE);
    CHECK((f = find_fd(&v, p, 5)) && f->kind == XRT_FD_ANON && !strcmp(v.strings + f->link, "anon_inode:[eventfd]"));
    CHECK((f = find_fd(&v, p, 6)) && f->kind == XRT_FD_MEMFD && !(f->flags & XRT_FD_DELETED));
    CHECK((f = find_fd(&v, p, 7)) && f->kind == XRT_FD_OTHER && (f->flags & XRT_FD_DELETED));
    CHECK((f = find_fd(&v, p, 8)) && f->kind == XRT_FD_REGULAR && f->size == 16 && f->pos == 10 &&
          (f->open_flags & 3) == 1 && (f->open_flags & O_APPEND) && !(f->flags & XRT_FD_OPENED));
    const struct xrt_fd_process *d;
    if (!root_user) {
        CHECK(find_unseen(&v, 300) && !find_unseen(&v, 300)->kernel && find_unseen(&v, 300)->start == 77 && v.hidden == 1);
    }
    /* An owned, immutable copy outlives the next poll. */
    struct xrt_fd_snapshot *copy = xrt_fd_snapshot_copy(&v);
    CHECK(copy && copy->process_count == v.process_count && copy->fd_count == v.fd_count && copy->unseen_count == v.unseen_count);

    /* fd 4 closes, 9 opens, 5 is replaced, the file advances by 4096. */
    snprintf(path, sizeof(path), "%s/100/fd/4", root);
    unlink(path);
    fake_fd(100, 9, "pipe:[778]", NULL);
    fake_fd(100, 5, "anon_inode:[eventpoll]", NULL);
    snprintf(path, sizeof(path), "%s/data/regular", root);
    fake_fd(100, 8, path, "pos:\t4106\nflags:\t0102001\nmnt_id:\t1\n");
    fake_process(100, "fake (x) one", 0x400100, 4242, 1500);
    CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
    p = find(&v, 100);
    CHECK(p && !(p->flags & XRT_FDP_NEW) && p->interval_ns > 0);
    CHECK(p && p->opened == 2 && p->closed == 2 && p->d_count == 0);
    CHECK(p && p->d_rchar == 500 && p->d_wchar == 0);
    CHECK(p && p->advance == 4096 && p->advance_rate > 0);
    CHECK((f = find_fd(&v, p, 8)) && f->advance == 4096 && f->rate > 0 && !(f->flags & XRT_FD_OPENED));
    if (copy) {
        const struct xrt_fd_process *q = find(copy, 100);
        const struct xrt_fd *g = find_fd(copy, q, 5);
        CHECK(q && q->count == 7 && g && !strcmp(copy->strings + g->link, "anon_inode:[eventfd]"));
        xrt_fd_snapshot_free(copy);
    }
    CHECK((f = find_fd(&v, p, 9)) && (f->flags & XRT_FD_OPENED));
    CHECK((f = find_fd(&v, p, 5)) && (f->flags & XRT_FD_OPENED));
    CHECK(v.opened == 2 && v.closed == 2);
    const struct xrt_fd_file *files;
    uint32_t nfiles;
    CHECK(xrt_fdscan_files(s, &files, &nfiles) == XRT_OK);
    CHECK(nfiles >= 1 && files[0].kind == XRT_FD_REGULAR && files[0].rate > 0 && files[0].write_rate == files[0].rate);

    /* A reopen under the same path onto the same number is a close and an
     * open, with the new inode (log rotation). */
    {
        char moved[600];
        snprintf(moved, sizeof(moved), "%s.1", path);
        CHECK(!rename(path, moved));
        write_file(path, "fresh");
        CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
        p = find(&v, 100);
        struct stat now;
        CHECK(!stat(path, &now));
        CHECK((f = find_fd(&v, p, 8)) && (f->flags & XRT_FD_OPENED) && f->inode == now.st_ino && f->size == 5);
        CHECK(p && p->opened == 1 && p->closed == 1);
    }

    /* A new identity behind the same pid gets no deltas. */
    fake_process(100, "reborn", 0x400100, 9999, 50);
    CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
    p = find(&v, 100);
    CHECK(p && (p->flags & XRT_FDP_NEW) && p->opened == 0 && p->d_rchar == 0 && p->history.samples == 1);
    /* Denied tables are retried periodically, not every scan. */
    if (!root_user) {
        snprintf(path, sizeof(path), "%s/300/fd", root);
        chmod(path, 0755);
        int visible = 0, polls = 0;
        while (!visible && polls++ < 9) {
            CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
            d = find(&v, 300);
            visible = d != NULL;
        }
        CHECK(visible && polls > 1);
        chmod(path, 0);
    }
    xrt_fdscan_destroy(s);

    /* Growth is measured over the history window: a one-off rise decays. */
    {
        const int32_t one[] = { 50 };
        struct xrt_fdscan_options o50 = { .include_self = 1, .proc = root, .pids = one, .pid_count = 1 };
        CHECK(xrt_fdscan_create(&o50, &s) == XRT_OK);
        CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
        fake_fd(50, 3, "pipe:[50]", NULL);
        fake_fd(50, 4, "pipe:[51]", NULL);
        fake_fd(50, 5, "anon_inode:[eventfd]", NULL);
        CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
        CHECK(v.processes[0].growth == 3 && v.processes[0].grew[XRT_FD_PIPE] == 2 && v.processes[0].grew[XRT_FD_ANON] == 1);
        for (int k = 0; k < XRT_FD_HISTORY; k++)
            CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
        CHECK(v.processes[0].growth == 0 && v.processes[0].lifetime_low == 0 && v.processes[0].count == 3);
        xrt_fdscan_destroy(s);
        for (int fd = 3; fd <= 5; fd++) {
            snprintf(path, sizeof(path), "%s/50/fd/%d", root, fd);
            unlink(path);
        }
    }

    /* Limits are counted, never silent. */
    struct xrt_fdscan_options small = { .include_self = 1, .proc = root, .max_fds = 3, .max_strings = 40 };
    CHECK(xrt_fdscan_create(&small, &s) == XRT_OK);
    CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
    p = find(&v, 100);
    CHECK(p && (p->flags & XRT_FDP_TRUNCATED) && p->count == 3 && v.dropped_fds == 4);
    CHECK(v.cut_strings > 0);
    xrt_fdscan_destroy(s);
    const int32_t only[] = { 100 };
    struct xrt_fdscan_options listed = { .include_self = 1, .proc = root, .pids = only, .pid_count = 1 };
    CHECK(xrt_fdscan_create(&listed, &s) == XRT_OK);
    CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
    CHECK(v.process_count == 1 && v.processes[0].pid == 100);
    xrt_fdscan_destroy(s);

    /* A tight time budget carries unscanned processes, flagged stale, with no
     * invented opens or closes. */
    for (int pid = 1000; pid < 4000; pid++) {
        fake_process(pid, "many", 0x400100, 1, 0);
        fake_fd(pid, 0, "pipe:[1]", NULL);
    }
    struct xrt_fdscan_options budget = { .include_self = 1, .proc = root };
    CHECK(xrt_fdscan_create(&budget, &s) == XRT_OK);
    CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
    const uint32_t all = v.process_count;
    xrt_fdscan_destroy(s);
    budget.budget_ms = 1;
    CHECK(xrt_fdscan_create(&budget, &s) == XRT_OK);
    static unsigned char seen[4000];
    uint32_t covered = 0, polls = 0, first_scan = 0, stale_max = 0;
    while (covered < all && polls < 2000) {
        CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
        if (!polls)
            first_scan = v.process_count;
        polls++;
        uint32_t stale = 0;
        for (uint32_t i = 0; i < v.process_count; i++) {
            const struct xrt_fd_process *q = &v.processes[i];
            CHECK(!i || v.processes[i - 1].pid < q->pid);
            CHECK(!i || v.processes[i - 1].first <= q->first);
            if (q->flags & XRT_FDP_STALE) {
                stale++;
                CHECK(q->opened == 0 && q->closed == 0 && q->interval_ns == 0 && (q->pid < 1000 || q->count == 1));
            } else if (q->pid < 4000 && !seen[q->pid]) {
                seen[q->pid] = 1;
                covered++;
            }
        }
        CHECK(stale == v.stale && v.opened == 0 && v.closed == 0);
        /* Every listed process is accounted for in every scan. */
        if (v.process_count + v.hidden + v.kernel_threads + v.unscanned + v.gone != 3005)
            fprintf(stderr, "budget counts: %u visible %u hidden %u kernel %u unscanned %u gone %u dropped\n", v.process_count, v.hidden,
                    v.kernel_threads, v.unscanned, v.gone, v.dropped_processes);
        CHECK(v.process_count + v.hidden + v.kernel_threads + v.unscanned + v.gone == 3005);
        if (stale > stale_max)
            stale_max = stale;
    }
    CHECK(first_scan < all && covered == all && stale_max > 0);
    printf("budget 1 ms: %u of %u processes in the first scan; all reached after %u scans\n", first_scan, all, polls);
    xrt_fdscan_destroy(s);
}

/* ---------------------------------------------------------------- live */
static pid_t spawn(void (*body)(int, int), int *to_child, int *from_child)
{
    int down[2], up[2];
    if (pipe(down) || pipe(up))
        exit(1);
    const pid_t pid = fork();
    if (pid < 0)
        exit(1);
    if (pid == 0) {
        prctl(PR_SET_PDEATHSIG, SIGKILL);
        close(down[1]);
        close(up[0]);
        body(down[0], up[1]);
        _exit(0);
    }
    close(down[0]);
    close(up[1]);
    *to_child = down[1];
    *from_child = up[0];
    return pid;
}
static void step(int to, int from)
{
    char c = 's';
    if (write(to, &c, 1) != 1 || read(from, &c, 1) != 1)
        exit(1);
}
static char block[4096];
static char dir[300];

static void writer(int in, int out)
{
    char path[512], c;
    snprintf(path, sizeof(path), "%s/written", dir);
    const int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (write(out, "r", 1) != 1)
        _exit(1);
    while (read(in, &c, 1) == 1) {
        for (int i = 0; i < 75; i++) /* 300 KiB */
            if (write(fd, block, sizeof(block)) != (ssize_t)sizeof(block))
                _exit(1);
        if (write(out, "w", 1) != 1)
            _exit(1);
    }
}
static void churner(int in, int out)
{
    char path[512], c;
    int window[8];
    for (int i = 0; i < 8; i++) {
        snprintf(path, sizeof(path), "%s/churn-%d", dir, i);
        window[i] = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0644);
    }
    int k = 8;
    if (write(out, "r", 1) != 1)
        _exit(1);
    while (read(in, &c, 1) == 1) {
        for (int i = 0; i < 5; i++, k++) { /* five rotations to new names */
            close(window[k % 8]);
            snprintf(path, sizeof(path), "%s/churn-%d", dir, k);
            window[k % 8] = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0644);
        }
        if (write(out, "w", 1) != 1)
            _exit(1);
    }
}
static void leaker(int in, int out)
{
    char c;
    if (write(out, "r", 1) != 1)
        _exit(1);
    while (read(in, &c, 1) == 1) {
        int p[2];
        if (pipe(p) || open("/dev/null", O_RDONLY) < 0)
            _exit(1);
        if (write(out, "w", 1) != 1)
            _exit(1);
    }
}
static void holder(int in, int out)
{
    char path[512], c;
    snprintf(path, sizeof(path), "%s/held", dir);
    const int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    for (int i = 0; i < 256; i++)
        if (write(fd, block, sizeof(block)) != (ssize_t)sizeof(block))
            _exit(1);
    if (write(fd, block, 123) != 123 || unlink(path) || write(out, "r", 1) != 1)
        _exit(1);
    while (read(in, &c, 1) == 1)
        if (write(out, "w", 1) != 1)
            _exit(1);
}

static uint32_t proc_count(pid_t pid)
{
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/fd", (int)pid);
    DIR *d = opendir(path);
    uint32_t n = 0;
    for (struct dirent *e; d && (e = readdir(d));)
        n += e->d_name[0] != '.';
    if (d)
        closedir(d);
    return n;
}

static void live(void)
{
    snprintf(dir, sizeof(dir), "%s/live", root);
    mkdir(dir, 0755);
    memset(block, 'x', sizeof(block));
    int to[4], from[4];
    pid_t pids[4];
    void (*bodies[4])(int, int) = { writer, churner, leaker, holder };
    for (int i = 0; i < 4; i++) {
        char c;
        pids[i] = spawn(bodies[i], &to[i], &from[i]);
        if (read(from[i], &c, 1) != 1)
            exit(1);
    }
    struct xrt_fdscan *s;
    struct xrt_fdscan_options o = { .pids = pids, .pid_count = 4 };
    CHECK(xrt_fdscan_create(&o, &s) == XRT_OK);
    struct xrt_fd_snapshot v;
    CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
    CHECK(v.process_count == 4 && v.hidden == 0);
    for (int round = 0; round < 12; round++) {
        for (int i = 0; i < 4; i++)
            step(to[i], from[i]);
        CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
        const struct xrt_fd_process *w = find(&v, pids[0]), *c = find(&v, pids[1]), *l = find(&v, pids[2]);
        CHECK(w && w->advance == 300u * 1024 && w->d_wchar >= 300u * 1024 && w->d_wchar <= 300u * 1024 + 16);
        CHECK(c && c->opened == 5 && c->closed == 5 && c->d_count == 0);
        CHECK(l && l->opened == 3 && l->closed == 0 && l->d_count == 3);
        for (int i = 0; i < 4; i++) {
            const struct xrt_fd_process *p = find(&v, pids[i]);
            CHECK(p && p->count == proc_count(pids[i]));
        }
    }
    const struct xrt_fd_process *l = find(&v, pids[2]);
    CHECK(l && (l->flags & XRT_FDP_LEAKING) && xrt_fd_growth(l) == 36);
    CHECK(l && l->grew[XRT_FD_PIPE] == 24 && l->grew[XRT_FD_DEVICE] == 12);
    CHECK(l && l->history.samples == 13 && l->history.fds[12] - l->history.fds[0] == 36);
    const struct xrt_fd_process *c = find(&v, pids[1]);
    CHECK(c && !(c->flags & XRT_FDP_LEAKING) && xrt_fd_growth(c) == 0);
    const struct xrt_fd_file *files;
    uint32_t nfiles, deleted = 0, shared = 0;
    CHECK(xrt_fdscan_files(s, &files, &nfiles) == XRT_OK);
    for (uint32_t i = 0; i < nfiles; i++) {
        if (files[i].flags & XRT_FD_DELETED) {
            deleted++;
            CHECK(files[i].kind == XRT_FD_REGULAR && files[i].size == 256 * 4096 + 123 && files[i].holders == 1);
        }
        /* The parent's ends are not scanned; each child's own pipe pair is one file per pipe. */
        shared += files[i].kind == XRT_FD_PIPE && files[i].fds == 2 && files[i].holders == 1;
    }
    CHECK(deleted == 1);
    CHECK(shared >= 12);
    float totals[16];
    CHECK(xrt_fdscan_totals(s, XRT_FD_METRIC_FDS, totals, 16) == 12);
    /* Unlinking a held file keeps the same open: deleted, not churn. */
    {
        char path[400];
        snprintf(path, sizeof(path), "%s/written", dir);
        CHECK(!unlink(path));
        step(to[0], from[0]);
        CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
        const struct xrt_fd_process *w = find(&v, pids[0]);
        const struct xrt_fd *held = NULL;
        for (uint32_t i = 0; w && i < w->count; i++)
            if (v.fds[w->first + i].kind == XRT_FD_REGULAR)
                held = &v.fds[w->first + i];
        CHECK(w && w->opened == 0 && w->closed == 0 && w->advance == 300u * 1024);
        CHECK(held && (held->flags & XRT_FD_DELETED) && !(held->flags & XRT_FD_OPENED));
    }
    /* A child that exits between scans simply disappears. */
    kill(pids[3], SIGKILL);
    waitpid(pids[3], NULL, 0);
    CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
    CHECK(v.process_count == 3 && !find(&v, pids[3]));
    xrt_fdscan_destroy(s);

    /* Another user's process is counted hidden, not dropped. */
    struct stat st;
    if (stat("/proc/1", &st) == 0 && st.st_uid != geteuid()) {
        const int32_t init[] = { 1 };
        struct xrt_fdscan_options other = { .pids = init, .pid_count = 1 };
        CHECK(xrt_fdscan_create(&other, &s) == XRT_OK);
        CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
        CHECK(v.hidden == 1 && v.process_count == 0 && v.unseen_count == 1 && v.unseen[0].pid == 1);
        xrt_fdscan_destroy(s);
    }
    /* The scanner leaves itself out unless asked. */
    CHECK(xrt_fdscan_create(NULL, &s) == XRT_OK);
    CHECK(xrt_fdscan_poll(s, &v) == XRT_OK);
    CHECK(!find(&v, getpid()) && find(&v, pids[0]));
    xrt_fdscan_destroy(s);
    for (int i = 0; i < 3; i++) {
        kill(pids[i], SIGKILL);
        waitpid(pids[i], NULL, 0);
    }
}

static void remove_tree(const char *path)
{
    DIR *d = opendir(path);
    if (!d) {
        unlink(path);
        return;
    }
    chmod(path, 0755);
    for (struct dirent *e; (e = readdir(d));) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
            continue;
        char child[1024];
        snprintf(child, sizeof(child), "%s/%s", path, e->d_name);
        struct stat st;
        if (!lstat(child, &st) && S_ISDIR(st.st_mode)) {
            chmod(child, 0755);
            remove_tree(child);
        } else
            unlink(child);
    }
    closedir(d);
    rmdir(path);
}

int main(void)
{
    const char *tmp = getenv("TMPDIR");
    char template[256];
    snprintf(template, sizeof(template), "%s/xodb-fdscan-XXXXXX", tmp && tmp[0] ? tmp : "/tmp");
    strcpy(root, template);
    if (!mkdtemp(root)) {
        perror("mkdtemp");
        return 1;
    }
    chmod(root, 0755);
    synthetic();
    remove_tree(root);
    strcpy(root, template);
    if (!mkdtemp(root)) {
        perror("mkdtemp");
        return 1;
    }
    live();
    remove_tree(root);
    if (failures) {
        fprintf(stderr, "fdscan: %d failures\n", failures);
        return 1;
    }
    printf("fdscan: ok\n");
    return 0;
}
