#define _GNU_SOURCE 1
#include "fdevent_internal.h"
#include <dirent.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct xrt_fdevent {
    struct fd_event_counter counter;
    struct xrt_perf *perf;
    int proc_fd;
    uint16_t enter_type, exit_type;
    uint32_t drain_limit, drained;
    uint64_t starts[XRT_FDEVENT_MAX_THREADS];
    int32_t tids[XRT_FDEVENT_MAX_THREADS];
};
static uint64_t clock_ns(clockid_t id)
{
    struct timespec t;
    return clock_gettime(id, &t) ? 0 : (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
static uint64_t start_at(int dir, const char *name)
{
    int fd = openat(dir, name, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    char text[8192];
    ssize_t size = read(fd, text, sizeof(text) - 1);
    close(fd);
    if (size <= 0 || (size_t)size == sizeof(text) - 1)
        return 0;
    text[size] = 0;
    char *p = strrchr(text, ')');
    if (!p || p[1] != ' ')
        return 0;
    p += 2;
    for (unsigned field = 3; field < 22; ++field) {
        p = strchr(p, ' ');
        if (!p)
            return 0;
        ++p;
    }
    const char *end = p + strcspn(p, " \n");
    uint64_t value;
    return xrt_perf_unsigned(p, (size_t)(end - p), &value) ? value : 0;
}
static int native_image(int dir)
{
    int fd = openat(dir, "exe", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    Elf64_Ehdr e;
    ssize_t n = read(fd, &e, sizeof(e));
    const int saved = errno;
    close(fd);
    if (n < 0) {
        errno = saved;
        return -1;
    }
    errno = 0;
    return n == sizeof(e) && !memcmp(e.e_ident, ELFMAG, SELFMAG) &&
           e.e_ident[EI_CLASS] == ELFCLASS64 && e.e_ident[EI_DATA] == ELFDATA2LSB &&
           e.e_machine == EM_X86_64;
}
static int same_scope(const struct xrt_fdevent *c)
{
    int fd = openat(c->proc_fd, "task", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    DIR *tasks = fd < 0 ? NULL : fdopendir(fd);
    if (!tasks) {
        if (fd >= 0)
            close(fd);
        return 0;
    }
    unsigned count = 0;
    int ok = 1;
    struct dirent *entry;
    while ((entry = readdir(tasks))) {
        uint64_t id;
        if (!xrt_perf_unsigned(entry->d_name, strlen(entry->d_name), &id) || !id || id > INT_MAX)
            continue;
        uint32_t i = 0;
        while (i < c->counter.snapshot.threads && c->tids[i] != (int32_t)id)
            ++i;
        if (i == c->counter.snapshot.threads) {
            ok = 0;
            break;
        }
        ++count;
    }
    closedir(tasks);
    return ok && count == c->counter.snapshot.threads;
}
static enum xrt_status failure(struct xrt_perf_failure *f, enum xrt_status status, int error,
                               int32_t tid, const char *detail)
{
    xrt_perf_fail(f, "fd.events", error, tid, detail);
    return status;
}
void xrt_fdevent_stop(struct xrt_fdevent *c)
{
    if (!c)
        return;
    if (c->perf) {
        xrt_perf_destroy(c->perf);
        c->perf = NULL;
    }
    c->counter.snapshot.running = 0;
}
void xrt_fdevent_close(struct xrt_fdevent *c)
{
    if (!c)
        return;
    if (c->perf)
        xrt_perf_destroy(c->perf);
    if (c->proc_fd >= 0)
        close(c->proc_fd);
    fd_event_counter_destroy(&c->counter);
    free(c);
}
enum xrt_status xrt_fdevent_open(const struct xrt_fdevent_options *opts, struct xrt_fdevent **out,
                                 struct xrt_perf_failure *f)
{
    if (out)
        *out = NULL;
    if (!opts || !out || opts->pid <= 0 || !opts->expected_start || opts->max_rows > 65536 ||
        opts->drain_records > 1048576)
        return failure(f, XRT_INVALID_ARGUMENT, EINVAL, -1,
                       "positive pid/start identity and bounded limits required");
#if !defined(__x86_64__)
    return failure(f, XRT_UNSUPPORTED_ARCHITECTURE, 0, opts->pid,
                   "native x86-64 syscall events only");
#endif
    struct xrt_fdevent *c = calloc(1, sizeof(*c));
    if (!c)
        return failure(f, XRT_OUT_OF_MEMORY, ENOMEM, opts->pid, "event collector allocation");
    c->proc_fd = -1;
    if (!fd_event_counter_init(&c->counter, opts->max_rows ? opts->max_rows : 4096)) {
        xrt_fdevent_close(c);
        return failure(f, XRT_OUT_OF_MEMORY, ENOMEM, opts->pid, "event row allocation");
    }
    c->drain_limit = opts->drain_records ? opts->drain_records : 65536;
    struct xrt_fdevent_snapshot *s = &c->counter.snapshot;
    s->pid = opts->pid;
    s->start_ticks = opts->expected_start;
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d", opts->pid);
    c->proc_fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    enum xrt_status status = XRT_PROCESS_GONE;
    if (c->proc_fd < 0 || start_at(c->proc_fd, "stat") != opts->expected_start) {
        failure(f, status, errno, opts->pid, "process identity unavailable or changed");
        goto fail;
    }
    const int native = native_image(c->proc_fd);
    if (native != 1) {
        status = failure(f,
                         native < 0 ? (errno == EACCES || errno == EPERM ? XRT_PERMISSION_DENIED
                                                                         : XRT_FILE_UNAVAILABLE)
                                    : XRT_UNSUPPORTED_ARCHITECTURE,
                         native < 0 ? errno : 0, opts->pid,
                         native < 0 ? "executable identity unavailable"
                                    : "native x86-64 executable identity required");
        goto fail;
    }
    int task_fd = openat(c->proc_fd, "task", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    DIR *tasks = task_fd < 0 ? NULL : fdopendir(task_fd);
    if (!tasks) {
        if (task_fd >= 0)
            close(task_fd);
        status = failure(f, XRT_TASK_INFO_UNAVAILABLE, errno, opts->pid, "thread list unavailable");
        goto fail;
    }
    struct dirent *entry;
    while ((entry = readdir(tasks))) {
        uint64_t id;
        if (!xrt_perf_unsigned(entry->d_name, strlen(entry->d_name), &id) || !id || id > INT_MAX)
            continue;
        if (s->threads == XRT_FDEVENT_MAX_THREADS) {
            status = failure(f, XRT_TOO_MANY_THREADS, 0, opts->pid,
                             "event scope exceeds 32 explicit threads");
            closedir(tasks);
            goto fail;
        }
        snprintf(path, sizeof(path), "task/%u/stat", (unsigned)id);
        uint64_t start = start_at(c->proc_fd, path);
        if (!start) {
            status = failure(f, XRT_PROCESS_GONE, 0, (int32_t)id,
                             "thread identity changed during enrollment");
            closedir(tasks);
            goto fail;
        }
        c->tids[s->threads] = (int32_t)id;
        c->starts[s->threads++] = start;
    }
    closedir(tasks);
    if (!s->threads) {
        status = failure(f, XRT_PROCESS_GONE, 0, opts->pid, "no readable threads");
        goto fail;
    }
    s->started_ns = clock_ns(CLOCK_MONOTONIC);
    c->perf = xrt_syscalls_start_loss(opts->pid, c->tids, s->threads, &c->enter_type, &c->exit_type, f);
    if (!c->perf) {
        status = f && f->kind == XRT_PERF_PERMISSION ? XRT_PERMISSION_DENIED : XRT_FILE_UNAVAILABLE;
        goto fail;
    }
    for (uint32_t i = 0; i < s->threads; ++i) {
        struct xrt_perf_thread thread;
        snprintf(path, sizeof(path), "task/%d/stat", c->tids[i]);
        if (!xrt_perf_thread(c->perf, i, &thread) || !thread.start_time_known ||
            thread.start_time_ticks != c->starts[i] || start_at(c->proc_fd, path) != c->starts[i]) {
            status = failure(f, XRT_PROCESS_GONE, 0, c->tids[i],
                             "thread identity changed while opening events");
            goto fail;
        }
    }
    if (start_at(c->proc_fd, "stat") != opts->expected_start) {
        status = failure(f, XRT_PROCESS_GONE, 0, opts->pid,
                         "process identity changed while opening events");
        goto fail;
    }
    if (!same_scope(c) || native_image(c->proc_fd) != 1) {
        status = failure(f, XRT_PROCESS_GONE, 0, opts->pid,
                         "thread scope or executable changed while opening events");
        goto fail;
    }
    struct xrt_perf_info info;
    xrt_perf_info(c->perf, &info);
    s->ring_bytes = info.allocated_ring_bytes;
    /* Publish unsupported or failed loss accounting honestly from the first snapshot. */
    for (uint32_t i = 0; i < s->threads; ++i) {
        uint64_t lost = 0;
        const int known = xrt_perf_read_lost(c->perf, i, &lost);
        fd_event_counter_loss(&c->counter, i, lost, known, 0);
    }
    s->taken_ns = clock_ns(CLOCK_MONOTONIC);
    s->running = 1;
    *out = c;
    return XRT_OK;
fail:
    xrt_fdevent_close(c);
    return status;
}

static struct xrt_perf_consumed consume(void *opaque, const struct xrt_perf_ring *ring)
{
    struct xrt_fdevent *c = opaque;
    uint64_t consumed = 0;
    if (ring->index >= c->counter.snapshot.threads || ring->thread->tid != c->tids[ring->index])
        return (struct xrt_perf_consumed){0, XRT_PERF_DRAIN_MALFORMED};
    /* The largest accepted record is 1024 bytes. A ring with less room may
     * already have rejected a reservation, including on kernels without LOST. */
    if (ring->size - (ring->head - ring->tail) < 1024)
        fd_event_counter_loss(&c->counter, ring->index, c->counter.kernel_lost[ring->index], 1, 1);
    const struct xrt_fdevent_identity who = {.pid = c->counter.snapshot.pid,
                                             .tid = ring->thread->tid,
                                             .enter_id = ring->thread->event_ids[0],
                                             .exit_id = ring->thread->event_ids[1],
                                             .enter_type = c->enter_type,
                                             .exit_type = c->exit_type};
    while (consumed < ring->head - ring->tail) {
        if (c->drained == c->drain_limit)
            return (struct xrt_perf_consumed){consumed, XRT_PERF_DRAIN_CAPACITY};
        unsigned char record[1024];
        const uint64_t available = ring->head - ring->tail - consumed;
        if (available < 8 ||
            !xrt_perf_copy(ring->data, ring->size, ring->tail + consumed, record, 8))
            return (struct xrt_perf_consumed){consumed, XRT_PERF_DRAIN_MALFORMED};
        uint16_t size;
        memcpy(&size, record + 6, sizeof(size));
        if (size < 8 || size > sizeof(record) || size % 8 || size > available ||
            !xrt_perf_copy(ring->data, ring->size, ring->tail + consumed, record, size))
            return (struct xrt_perf_consumed){consumed, XRT_PERF_DRAIN_MALFORMED};
        struct xrt_fdevent_record event;
        if (!xrt_fdevent_decode(record, size, &who, &event))
            return (struct xrt_perf_consumed){consumed, XRT_PERF_DRAIN_MALFORMED};
        fd_event_counter_feed(&c->counter, ring->index, &event);
        ++c->drained;
        consumed += size;
    }
    return (struct xrt_perf_consumed){consumed, XRT_PERF_DRAIN_OK};
}
enum xrt_status xrt_fdevent_drain(struct xrt_fdevent *c, struct xrt_fdevent_snapshot *out)
{
    if (!c || !out)
        return XRT_INVALID_ARGUMENT;
    struct xrt_fdevent_snapshot *s = &c->counter.snapshot;
    if (!s->running) {
        *out = *s;
        return XRT_OK;
    }
    const uint64_t wall = clock_ns(CLOCK_MONOTONIC), cpu = clock_ns(CLOCK_THREAD_CPUTIME_ID);
    c->drained = 0;
    enum xrt_perf_drain_status status = xrt_perf_drain(c->perf, consume, c);
    for (uint32_t i = 0; i < s->threads; ++i) {
        uint64_t lost = 0;
        const int known = xrt_perf_read_lost(c->perf, i, &lost);
        fd_event_counter_loss(&c->counter, i, lost, known, 0);
    }

    s->pending = status == XRT_PERF_DRAIN_CAPACITY;
    if (status != XRT_PERF_DRAIN_OK && status != XRT_PERF_DRAIN_CAPACITY) {
        s->flags |= XRT_FDEVENT_BAD_RECORD;
        ++s->invalid;
        s->reason = "event ring decode failed; capture stopped with incomplete evidence";
        s->running = 0;
        xrt_fdevent_stop(c);
    }
    unsigned active = 0;
    for (uint32_t i = 0; i < s->threads; ++i)
        active += !c->counter.lane[i].closed;
    if (!active) {
        s->running = 0;
        s->reason = "selected thread scope ended or executed a new image";
        xrt_fdevent_stop(c);
    }
    s->drain_wall_ns = clock_ns(CLOCK_MONOTONIC) - wall;
    s->drain_cpu_ns = clock_ns(CLOCK_THREAD_CPUTIME_ID) - cpu;
    s->taken_ns = clock_ns(CLOCK_MONOTONIC);
    *out = *s;
    return XRT_OK;
}
