#define _GNU_SOURCE 1
#include "perf_internal.h"
#include "perf_remote.h"
#include "xrt_remote.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
_Static_assert(sizeof(struct xrt_perf_attr) == 144, "perf attr version 9");
_Static_assert(offsetof(struct xrt_perf_attr, flags) == 40, "perf flags");
_Static_assert(offsetof(struct xrt_perf_attr, clockid) == 92, "perf clock");
_Static_assert(offsetof(struct xrt_perf_attr, sample_max_stack) == 108, "perf stack");
void xrt_perf_fail(struct xrt_perf_failure *f, const char *call, int error, int32_t tid,
                   const char *detail)
{
    if (!f)
        return;
    enum xrt_perf_failure_kind kind = XRT_PERF_OTHER;
    if (error == ESRCH)
        kind = XRT_PERF_THREAD_GONE;
    else if (error == EPERM || error == EACCES)
        kind = XRT_PERF_PERMISSION;
    else if (!error || error == EINVAL || error == E2BIG)
        kind = XRT_PERF_CONFIGURATION;
    else if (error == ENOSYS || error == ENODEV || error == ENOENT || error == EOPNOTSUPP)
        kind = XRT_PERF_UNAVAILABLE;
    else if (error == EMFILE || error == ENFILE || error == ENOMEM || error == EAGAIN ||
             error == EBUSY)
        kind = XRT_PERF_RESOURCE;
    *f = (struct xrt_perf_failure){
        .kind = kind, .syscall = call, .detail = detail, .error = error, .tid = tid};
}
size_t xrt_perf_page_size(void)
{
    long size = sysconf(_SC_PAGESIZE);
    return size > 0 ? (size_t)size : 4096;
}
struct xrt_perf *xrt_perf_create(unsigned pages, size_t threads, uint64_t budget)
{
    if (!pages || pages > 64 || (pages & (pages - 1)) || !threads ||
        threads > XRT_PERF_MAX_THREADS) {
        errno = EINVAL;
        return NULL;
    }
    struct xrt_perf *p = calloc(1, sizeof(*p));
    if (!p)
        return NULL;
    p->page_size = xrt_perf_page_size();
    p->data_pages = pages;
    p->max_threads = threads;
    p->budget = budget;
    return p;
}
static uint64_t number(const void *p)
{
    uint64_t n;
    memcpy(&n, p, 8);
    return n;
}
void xrt_perf_info(const struct xrt_perf *p, struct xrt_perf_info *out)
{
    if (p->remote_target) {
        xrt_remote_perf_refresh((struct xrt_perf *)p);
        *out = p->remote_info;
        return;
    }
    *out = (struct xrt_perf_info){.threads = p->count,
                                  .page_size = p->page_size,
                                  .allocated_ring_bytes = p->allocated,
                                  .running = p->running,
                                  .failed = p->failed,
                                  .failure = p->failure};
    if (p->count && p->slots[0].map_size >= 1056) {
        const struct xrt_perf_slot *s = &p->slots[0];
        memcpy(&out->mmap_version, s->map, 4);
        out->data_offset = number(s->map + 1040);
        out->ring_data_bytes = number(s->map + 1048);
        if (!out->ring_data_bytes && s->map_size > p->page_size)
            out->ring_data_bytes = s->map_size - p->page_size;
    }
}
bool xrt_perf_thread(const struct xrt_perf *p, size_t index, struct xrt_perf_thread *out)
{
    if (p->remote_target)
        return xrt_remote_perf_thread(p, index, out);
    if (index >= p->count)
        return false;
    *out = p->slots[index].thread;
    return true;
}
static void release(struct xrt_perf *p, struct xrt_perf_slot *s)
{
    if (s->thread.event_count && s->fds[0] >= 0)
        ioctl(s->fds[0], PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP);
    if (s->owns_map) {
        munmap(s->map, s->map_size);
        p->allocated -= (uint64_t)p->data_pages * p->page_size;
    }
    s->map = NULL;
    s->map_size = 0;
    s->owns_map = false;
    for (size_t i = 0; i < s->thread.event_count; ++i)
        if (s->fds[i] >= 0) {
            close(s->fds[i]);
            s->fds[i] = -1;
        }
}
void xrt_perf_destroy(struct xrt_perf *p)
{
    if (p && p->remote_target) {
        xrt_remote_perf_destroy(p);
        return;
    }
    if (p) {
        for (size_t i = 0; i < p->count; ++i)
            release(p, &p->slots[i]);
        free(p);
    }
}
size_t xrt_perf_fd_count(const struct xrt_perf *p)
{
    size_t count = 0;
    for (size_t i = 0; i < p->count; ++i)
        for (size_t j = 0; j < p->slots[i].thread.event_count; ++j)
            count += p->slots[i].fds[j] >= 0;
    return count;
}
bool xrt_perf_read_file(const char *path, char *out, size_t cap, size_t *size)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return false;
    size_t used = 0;
    int error = 0;
    while (used < cap) {
        ssize_t n = read(fd, out + used, cap - used);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            error = errno;
            break;
        }
        if (!n) {
            *size = used;
            close(fd);
            return true;
        }
        used += (size_t)n;
    }
    close(fd);
    errno = error ? error : E2BIG;
    return false;
}
bool xrt_perf_unsigned(const char *text, size_t size, uint64_t *out)
{
    size_t i = 0;
    uint64_t n = 0;
    while (i < size && (text[i] == ' ' || text[i] == '\n' || text[i] == '\t' || text[i] == '\r'))
        ++i;
    size_t first = i;
    while (i < size && text[i] >= '0' && text[i] <= '9') {
        unsigned digit = (unsigned)(text[i++] - '0');
        if (n > (UINT64_MAX - digit) / 10)
            return false;
        n = n * 10 + digit;
    }
    if (i == first)
        return false;
    while (i < size && (text[i] == ' ' || text[i] == '\n' || text[i] == '\t' || text[i] == '\r'))
        ++i;
    if (i != size)
        return false;
    *out = n;
    return true;
}
static void start_time(struct xrt_perf_thread *t)
{
    char path[64], buf[1024];
    size_t size;
    snprintf(path, sizeof(path), "/proc/%d/stat", t->tid);
    if (!xrt_perf_read_file(path, buf, sizeof(buf) - 1, &size))
        return;
    buf[size] = 0;
    const char *at = strrchr(buf, ')');
    if (!at)
        return;
    ++at;
    for (unsigned i = 0; i <= 19; ++i) {
        while (*at == ' ')
            ++at;
        const char *begin = at;
        while (*at && *at != ' ' && *at != '\n')
            ++at;
        if (at == begin)
            return;
        if (i == 19)
            t->start_time_known =
                xrt_perf_unsigned(begin, (size_t)(at - begin), &t->start_time_ticks);
    }
}
bool xrt_perf_add(struct xrt_perf *p, int32_t tid, const struct xrt_perf_attr *attrs, size_t events,
                  xrt_perf_opener opener, void *context, struct xrt_perf_failure *f)
{
    if (tid <= 0 || !attrs || !events || events > XRT_PERF_MAX_EVENTS) {
        xrt_perf_fail(f, "enroll", EINVAL, tid, "invalid thread or event count");
        return false;
    }
    for (size_t i = 0; i < p->count; ++i)
        if (p->slots[i].thread.tid == tid) {
            xrt_perf_fail(f, "enroll", EINVAL, tid,
                          "thread id already recorded; reuse requires a new capture");
            return false;
        }
    if (p->count == p->max_threads) {
        xrt_perf_fail(f, "enroll", ENOMEM, tid,
                      p->max_threads == 1024 ? "capture reached 1024 distinct thread identities"
                                             : "capture reached distinct thread identity limit");
        return false;
    }
    const uint64_t bytes = (uint64_t)p->data_pages * p->page_size;
    if (p->allocated > p->budget || bytes > p->budget - p->allocated) {
        xrt_perf_fail(f, "enroll", ENOMEM, tid, "capture ring-data budget exhausted");
        return false;
    }
    struct xrt_perf_slot *s = &p->slots[p->count];
    memset(s, 0, sizeof(*s));
    s->thread.tid = tid;
    for (size_t i = 0; i < XRT_PERF_MAX_EVENTS; ++i)
        s->fds[i] = -1;
    const char *call = "perf_event_open", *detail = "thread open failed";
    for (size_t i = 0; i < events; ++i) {
        struct xrt_perf_attr attr = attrs[i];
        if (!(attr.flags & 1) || (attr.flags & (UINT64_C(1) << 1))) {
            errno = EINVAL;
            detail = "events must start disabled without inherit";
            goto fail;
        }
        int fd = opener ? opener(context, tid, s->fds[0], i, &attr)
                        : (int)syscall(SYS_perf_event_open, &attr, tid, -1, s->fds[0],
                                       PERF_FLAG_FD_CLOEXEC);
        if (fd < 0) {
            call = "perf_event_open";
            detail = "thread open failed";
            goto fail;
        }
        s->fds[s->thread.event_count++] = fd;
        if (attr.read_format == PERF_FORMAT_LOST) s->lost_read_mask |= UINT32_C(1) << i;
        call = "ioctl";
        detail = "PERF_EVENT_IOC_ID";
        if (ioctl(fd, PERF_EVENT_IOC_ID, &s->thread.event_ids[i]))
            goto fail;
        if (!i) {
            s->map_size = (1 + p->data_pages) * p->page_size;
            void *map = mmap(NULL, s->map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (map == MAP_FAILED) {
                s->map_size = 0;
                call = "mmap";
                detail = "ring mmap failed";
                goto fail;
            }
            s->map = map;
            s->owns_map = true;
            p->allocated += bytes;
        } else if (ioctl(fd, PERF_EVENT_IOC_SET_OUTPUT, s->fds[0])) {
            detail = "PERF_EVENT_IOC_SET_OUTPUT";
            goto fail;
        }
    }
    start_time(&s->thread);
    if (p->running && ioctl(s->fds[0], PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP)) {
        call = "ioctl";
        detail = "PERF_EVENT_IOC_ENABLE";
        goto fail;
    }
    ++p->count;
    return true;
fail:;
    const int error = errno;
    const uint16_t opened = (uint16_t)s->thread.event_count;
    release(p, s);
    memset(s, 0, sizeof(*s));
    xrt_perf_fail(f, call, error, tid, detail);
    if (f)
        f->opened_then_closed = opened;
    return false;
}
/* PERF_FORMAT_LOST counts failed ring reservations even before a later event
 * can emit PERF_RECORD_LOST. Each FD has its own cumulative counter. */
bool xrt_perf_read_lost(struct xrt_perf *p, size_t index, uint64_t *lost)
{
    if (!p || !lost || p->remote_target || index >= p->count) return false;
    const struct xrt_perf_slot *s = &p->slots[index];
    *lost = 0;
    if (!s->thread.event_count) return false;
    for (size_t i = 0; i < s->thread.event_count; ++i) {
        if (!(s->lost_read_mask & (UINT32_C(1) << i)) || s->fds[i] < 0) return false;
        uint64_t count[2]; /* value, lost; no GROUP, ID or time fields */
        if (read(s->fds[i], count, sizeof count) != sizeof count) return false;
        *lost = UINT64_MAX - *lost < count[1] ? UINT64_MAX : *lost + count[1];
    }
    return true;
}

bool xrt_perf_stop(struct xrt_perf *p, struct xrt_perf_failure *f)
{
    if (p->remote_target)
        return xrt_remote_perf_op(p, XRT_RPC_PERF_STOP, 0, f);
    bool ok = true;
    for (size_t i = 0; i < p->count; ++i) {
        struct xrt_perf_slot *s = &p->slots[i];
        if (s->thread.event_count && s->fds[0] >= 0 &&
            ioctl(s->fds[0], PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP) && errno != ESRCH) {
            xrt_perf_fail(f, "ioctl", errno, s->thread.tid, "PERF_EVENT_IOC_DISABLE");
            ok = false;
        }
    }
    if (ok)
        p->running = false;
    return ok;
}
bool xrt_perf_enable(struct xrt_perf *p, struct xrt_perf_failure *f)
{
    if (p->remote_target)
        return xrt_remote_perf_op(p, XRT_RPC_PERF_ENABLE, 0, f);
    if (p->failed) {
        if (f)
            *f = p->failure;
        return false;
    }
    if (p->running) {
        xrt_perf_fail(f, "restart", EINVAL, -1, "collector is already running");
        return false;
    }
    for (size_t i = 0; i < p->count; ++i) {
        struct xrt_perf_slot *s = &p->slots[i];
        if (s->thread.retiring || !s->thread.event_count || s->fds[0] < 0)
            continue;
        if (ioctl(s->fds[0], PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP)) {
            int error = errno;
            xrt_perf_stop(p, NULL);
            xrt_perf_fail(f, "ioctl", error, s->thread.tid, "PERF_EVENT_IOC_ENABLE");
            return false;
        }
    }
    p->running = true;
    return true;
}
bool xrt_perf_retire(struct xrt_perf *p, size_t index, struct xrt_perf_failure *f)
{
    if (p->remote_target)
        return xrt_remote_perf_op(p, XRT_RPC_PERF_RETIRE, index, f);
    if (index >= p->count) {
        xrt_perf_fail(f, "retire", EINVAL, -1, "unknown collector slot");
        return false;
    }
    struct xrt_perf_slot *s = &p->slots[index];
    if (!s->thread.event_count || s->fds[0] < 0 || s->thread.retiring)
        return true;
    if (ioctl(s->fds[0], PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP) && errno != ESRCH) {
        xrt_perf_fail(f, "ioctl", errno, s->thread.tid, "disable exited thread");
        return false;
    }
    s->thread.retiring = true;
    return true;
}
enum xrt_perf_drain_status xrt_perf_peek(struct xrt_perf *p, size_t index,
                                         struct xrt_perf_ring *out)
{
    if (index >= p->count)
        return XRT_PERF_DRAIN_MALFORMED;
    struct xrt_perf_slot *s = &p->slots[index];
    memset(out, 0, sizeof(*out));
    if (!s->map)
        return XRT_PERF_DRAIN_OK;
    if (s->map_size < 1056)
        return XRT_PERF_DRAIN_MALFORMED;
    const uint64_t head =
        atomic_load_explicit((_Atomic uint64_t *)(s->map + 1024), memory_order_acquire);
    uint64_t offset = number(s->map + 1040), size = number(s->map + 1048);
    if (!size) {
        if (s->map_size <= p->page_size)
            return XRT_PERF_DRAIN_MALFORMED;
        offset = p->page_size;
        size = s->map_size - p->page_size;
    }
    if (offset < p->page_size || offset > s->map_size || !size || size > s->map_size - offset ||
        (size & (size - 1)) || head < s->tail || head - s->tail > size)
        return XRT_PERF_DRAIN_MALFORMED;
    *out = (struct xrt_perf_ring){.data = s->map + (size_t)offset,
                                  .size = (size_t)size,
                                  .index = index,
                                  .head = head,
                                  .tail = s->tail,
                                  .thread = &s->thread};
    return XRT_PERF_DRAIN_OK;
}
enum xrt_perf_drain_status xrt_perf_commit(struct xrt_perf *p, const struct xrt_perf_ring *ring,
                                           struct xrt_perf_consumed result)
{
    if (ring->index >= p->count)
        return XRT_PERF_DRAIN_MALFORMED;
    struct xrt_perf_slot *s = &p->slots[ring->index];
    if (!s->map || s->tail != ring->tail)
        return XRT_PERF_DRAIN_MALFORMED;
    if (result.bytes > ring->head - s->tail || (result.bytes & 7))
        return XRT_PERF_DRAIN_MALFORMED;
    if (result.bytes) {
        s->tail += result.bytes;
        atomic_store_explicit((_Atomic uint64_t *)(s->map + 1032), s->tail, memory_order_seq_cst);
    }
    if (s->thread.retiring && result.status == XRT_PERF_DRAIN_OK && s->tail == ring->head)
        release(p, s);
    return XRT_PERF_DRAIN_OK;
}
enum xrt_perf_drain_status xrt_perf_drain(struct xrt_perf *p, xrt_perf_decoder decode,
                                          void *context)
{
    if (p->remote_target)
        return xrt_remote_perf_drain(p, decode, context);
    size_t first = p->cursor;
    for (size_t i = 0; i < p->count; ++i) {
        const size_t index = (first + i) % p->count;
        struct xrt_perf_ring ring = {0};
        enum xrt_perf_drain_status status = xrt_perf_peek(p, index, &ring);
        if (status != XRT_PERF_DRAIN_OK)
            return status;
        if (!ring.size)
            continue;
        const struct xrt_perf_consumed result = decode(context, &ring);
        status = xrt_perf_commit(p, &ring, result);
        if (status != XRT_PERF_DRAIN_OK)
            return status;
        if (result.status == XRT_PERF_DRAIN_CAPACITY)
            p->cursor = (index + (result.bytes != 0)) % p->count;
        else if (result.status == XRT_PERF_DRAIN_STOP)
            p->cursor = (index + 1) % p->count;
        if (result.status != XRT_PERF_DRAIN_OK)
            return result.status;
    }
    if (p->count)
        p->cursor = (first + 1) % p->count;
    return XRT_PERF_DRAIN_OK;
}
bool xrt_perf_copy(const uint8_t *ring, size_t size, uint64_t tail, void *out, size_t length)
{
    if (!size || (size & (size - 1)) || length > size)
        return false;
    size_t at = (size_t)(tail & (size - 1)), first = length < size - at ? length : size - at;
    memcpy(out, ring + at, first);
    memcpy((uint8_t *)out + first, ring, length - first);
    return true;
}

uint64_t xrt_perf_timestamp(const struct xrt_perf *p, uint64_t producer)
{
    return xrt_target_timestamp(p->remote_target, producer);
}
