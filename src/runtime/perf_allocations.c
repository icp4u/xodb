#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "xrt_allocations.h"
#include "xrt_process.h"
#include "perf_remote.h"
#include "xrt_remote.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
struct file {
    int fd;
    struct xrt_allocation_source source;
    struct stat identity;
};
struct xrt_allocations {
    struct xrt_perf *perf;
    bool remote;
    int32_t pid;
    struct file files[XRT_ALLOCATION_MAX_HOOKS];
    size_t count;
};
static struct xrt_file_identity identity(const struct stat *s)
{
    return (struct xrt_file_identity){.device = s->st_dev,
                                      .inode = s->st_ino,
                                      .size = s->st_size,
                                      .mtime_sec = s->st_mtim.tv_sec,
                                      .mtime_ns = s->st_mtim.tv_nsec,
                                      .ctime_sec = s->st_ctim.tv_sec,
                                      .ctime_ns = s->st_ctim.tv_nsec};
}
static bool same(struct xrt_file_identity a, struct xrt_file_identity b)
{
    return a.device == b.device && a.inode == b.inode && a.size == b.size &&
           a.mtime_sec == b.mtime_sec && a.mtime_ns == b.mtime_ns && a.ctime_sec == b.ctime_sec &&
           a.ctime_ns == b.ctime_ns;
}
static bool held(int32_t pid, int32_t tid, struct xrt_perf_failure *f)
{
    struct xrt_task_info info;
    enum xrt_status status = xrt_task_inspect(tid, &info);
    if (status == XRT_OK && info.group == pid && (info.state == 't' || info.state == 'T'))
        return true;
    xrt_perf_fail(f, "allocations.scope", status == XRT_PROCESS_GONE ? ESRCH : 0, tid,
                  "AllocationRequiresHeldThread");
    return false;
}
static uint64_t le(const uint8_t *p, unsigned n)
{
    uint64_t v = 0;
    for (unsigned i = 0; i < n; ++i)
        v |= (uint64_t)p[i] << (8 * i);
    return v;
}
const char *xrt_allocation_offset(int fd, uint64_t offset)
{
    struct stat s;
    uint8_t h[64], ph[56];
    if (fstat(fd, &s) || !S_ISREG(s.st_mode) || s.st_size < 64 || offset >= (uint64_t)s.st_size)
        return "InvalidAllocationElf";
    if (pread(fd, h, sizeof(h), 0) != (ssize_t)sizeof(h) || memcmp(h, "\177ELF\002\001", 6) ||
        le(h + 18, 2) != 62 || (le(h + 16, 2) != 2 && le(h + 16, 2) != 3))
        return "InvalidAllocationElf";
    uint64_t start = le(h + 32, 8), count = le(h + 56, 2);
    if (le(h + 54, 2) != 56 || !count || count > 4096 || start > (uint64_t)s.st_size ||
        count * 56 > (uint64_t)s.st_size - start)
        return "InvalidAllocationElf";
    for (uint64_t i = 0; i < count; ++i) {
        if (pread(fd, ph, sizeof(ph), (off_t)(start + i * 56)) != (ssize_t)sizeof(ph))
            return "InvalidAllocationElf";
        if (le(ph, 4) != 1 || !(le(ph + 4, 4) & 1))
            continue;
        uint64_t from = le(ph + 8, 8), size = le(ph + 32, 8);
        if (from <= offset && offset - from < size && from <= (uint64_t)s.st_size &&
            size <= (uint64_t)s.st_size - from)
            return NULL;
    }
    return "AllocationOffsetNotExecutable";
}
bool xrt_allocation_retprobe(const char *text, size_t size, uint64_t *mask)
{
    while (size && (*text == ' ' || *text == '\t' || *text == '\r' || *text == '\n')) {
        ++text;
        --size;
    }
    if (size < 8 || memcmp(text, "config:", 7))
        return false;
    uint64_t bit;
    if (!xrt_perf_unsigned(text + 7, size - 7, &bit) || bit >= 64)
        return false;
    *mask = UINT64_C(1) << bit;
    return true;
}
void xrt_allocations_destroy(struct xrt_allocations *a)
{
    if (!a)
        return;
    xrt_perf_destroy(a->perf);
    for (size_t i = 0; i < a->count; ++i)
        if (a->files[i].fd >= 0)
            close(a->files[i].fd);
    free(a);
}
struct xrt_perf *xrt_allocations_perf(struct xrt_allocations *a)
{
    return a->perf;
}
static bool files_unchanged(struct xrt_allocations *a, struct xrt_perf_failure *f)
{
    for (size_t i = 0; i < a->count; ++i) {
        struct stat current;
        if (fstat(a->files[i].fd, &current) ||
            !same(identity(&a->files[i].identity), identity(&current))) {
            xrt_perf_fail(f, "allocations.file", 0, -1, "runtime ELF changed during preparation");
            return false;
        }
    }
    return true;
}
bool xrt_allocations_enable(struct xrt_allocations *a, struct xrt_perf_failure *f)
{
    if (a->remote)
        return xrt_perf_enable(a->perf, f);
    struct xrt_perf_info info;
    xrt_perf_info(a->perf, &info);
    for (size_t i = 0; i < info.threads; ++i) {
        struct xrt_perf_thread thread;
        xrt_perf_thread(a->perf, i, &thread);
        if (!held(a->pid, thread.tid, f))
            return false;
    }
    return files_unchanged(a, f) && xrt_perf_enable(a->perf, f);
}
struct opening {
    struct xrt_allocations *a;
    const struct xrt_allocation_config *config;
};
static int open_event(void *raw, int32_t tid, int group, size_t index,
                      const struct xrt_perf_attr *attr)
{
    struct opening *o = raw;
    const struct xrt_allocation_config *c = o->config;
    if (c->cancelled && c->cancelled(c->context)) {
        errno = ECANCELED;
        return -1;
    }
    const struct file *file = &o->a->files[index / 2];
    if (c->opener)
        return c->opener(c->context, tid, group, file->fd, file->source.offset, index % 2 != 0,
                         index == 0, c->callstacks);
    char path[64];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", file->fd);
    struct xrt_perf_attr opened = *attr;
    opened.config1 = (uintptr_t)path;
    return (int)syscall(SYS_perf_event_open, &opened, tid, -1, group, PERF_FLAG_FD_CLOEXEC);
}
struct xrt_allocations *xrt_allocations_start(const struct xrt_allocation_config *c,
                                              struct xrt_perf_failure *f)
{
#if !defined(__x86_64__)
    xrt_perf_fail(f, "allocations.architecture", 0, -1,
                  "uprobe register decoding currently supports Linux x86-64");
    return NULL;
#endif
    if (!c || c->pid <= 0 || !c->tids || !c->thread_count || c->thread_count > 32 || !c->sources ||
        !c->source_count || c->source_count > 16) {
        xrt_perf_fail(f, "allocations.scope", 0, -1,
                      "select 1..32 held threads and 1..16 explicit runtime ELF hooks");
        return NULL;
    }
    for (size_t i = 0; i < c->thread_count; ++i) {
        if (c->tids[i] <= 0) {
            xrt_perf_fail(f, "allocations.scope", 0, c->tids[i], "invalid selected thread");
            return NULL;
        }
        for (size_t j = 0; j < i; ++j)
            if (c->tids[i] == c->tids[j]) {
                xrt_perf_fail(f, "allocations.scope", 0, c->tids[i], "duplicate selected thread");
                return NULL;
            }
        if (!held(c->pid, c->tids[i], f))
            return NULL;
    }
    char text[128];
    size_t size;
    uint64_t pmu, mask;
    if (!xrt_perf_read_file("/sys/bus/event_source/devices/uprobe/type", text, sizeof(text),
                            &size)) {
        xrt_perf_fail(f, "allocations.pmu", errno, -1, "AllocationMetadataRead");
        return NULL;
    }
    if (!xrt_perf_unsigned(text, size, &pmu) || pmu > UINT32_MAX) {
        xrt_perf_fail(f, "allocations.pmu", 0, -1, "invalid uprobe PMU type");
        return NULL;
    }
    if (!xrt_perf_read_file("/sys/bus/event_source/devices/uprobe/format/retprobe", text,
                            sizeof(text), &size)) {
        xrt_perf_fail(f, "allocations.pmu", errno, -1, "AllocationMetadataRead");
        return NULL;
    }
    if (!xrt_allocation_retprobe(text, size, &mask)) {
        xrt_perf_fail(f, "allocations.pmu", 0, -1, "UnsupportedRetprobeFormat");
        return NULL;
    }
    struct xrt_allocations *a = calloc(1, sizeof(*a));
    if (!a) {
        xrt_perf_fail(f, "alloc", ENOMEM, -1, "allocation collector");
        return NULL;
    }
    a->pid = c->pid;
    a->perf = xrt_perf_create(16, 32, UINT64_MAX);
    if (!a->perf) {
        xrt_perf_fail(f, "alloc", errno, -1, "allocation rings");
        free(a);
        return NULL;
    }
    for (size_t i = 0; i < c->source_count; ++i) {
        struct file *file = &a->files[a->count++];
        file->source = c->sources[i];
        file->fd = fcntl(file->source.fd, F_DUPFD_CLOEXEC, 0);
        if (file->fd < 0 || fstat(file->fd, &file->identity)) {
            xrt_perf_fail(f, "allocations.file", errno, -1, "cannot pin runtime ELF descriptor");
            goto fail;
        }
        if (!same(identity(&file->identity), file->source.identity)) {
            xrt_perf_fail(f, "allocations.file", 0, -1,
                          "runtime ELF changed after hook resolution");
            goto fail;
        }
        const char *invalid = xrt_allocation_offset(file->fd, file->source.offset);
        if (invalid) {
            xrt_perf_fail(f, "allocations.file", 0, -1, invalid);
            goto fail;
        }
        if (!file->source.id) {
            xrt_perf_fail(f, "allocations.identity", 0, -1, "InvalidAllocationHookIdentity");
            goto fail;
        }
        for (size_t j = 0; j < i; ++j) {
            struct file *old = &a->files[j];
            if (old->source.id == file->source.id ||
                (old->identity.st_dev == file->identity.st_dev &&
                 old->identity.st_ino == file->identity.st_ino &&
                 old->source.offset == file->source.offset)) {
                xrt_perf_fail(f, "allocations.file", 0, -1,
                              "duplicate hook ID or aliased file offset would double-count calls");
                goto fail;
            }
        }
    }
    /* Heap storage keeps the same collector usable on small-stack target ISAs. */
    struct xrt_perf_attr *attrs = calloc(c->source_count * 2, sizeof(*attrs));
    if (!attrs) {
        xrt_perf_fail(f, "alloc", ENOMEM, -1, "allocation events");
        goto fail;
    }
    for (size_t i = 0; i < c->source_count * 2; ++i) {
        struct xrt_perf_attr *attr = &attrs[i];
        const bool stacks = c->callstacks && !(i % 2);
        attr->size = 112;
        attr->type = (uint32_t)pmu;
        attr->config = i % 2 ? mask : 0;
        attr->config2 = a->files[i / 2].source.offset;
        attr->sample_period = 1;
        attr->sample_type =
            PERF_SAMPLE_TID | PERF_SAMPLE_TIME | PERF_SAMPLE_ID | PERF_SAMPLE_REGS_USER;
        if (stacks)
            attr->sample_type |= PERF_SAMPLE_CALLCHAIN | PERF_SAMPLE_STACK_USER;
        attr->sample_max_stack = stacks ? 32 : 0;
        attr->sample_stack_user = stacks ? 8 : 0;
        attr->sample_regs_user = (UINT64_C(1) << 0) | (UINT64_C(1) << 4) | (UINT64_C(1) << 5) |
                                 (UINT64_C(1) << 7) | (UINT64_C(1) << 8);
        attr->flags = 1 | (UINT64_C(1) << 5) | (UINT64_C(1) << 6) | (UINT64_C(1) << 18) |
                      (UINT64_C(1) << 21) | (UINT64_C(1) << 25);
        if (!i)
            attr->flags |= (UINT64_C(1) << 9) | (UINT64_C(1) << 13) | (UINT64_C(1) << 24);
        if (!i && c->callstacks)
            attr->flags |= (UINT64_C(1) << 8) | (UINT64_C(1) << 23);
        attr->clockid = CLOCK_MONOTONIC;
    }
    struct opening opening = {a, c};
    bool ok = true;
    for (size_t i = 0; i < c->thread_count && ok; ++i)
        ok = xrt_perf_add(a->perf, c->tids[i], attrs, c->source_count * 2, open_event, &opening, f);
    free(attrs);
    if (!ok) {
        if (f && !strcmp(f->syscall, "perf_event_open")) {
            f->syscall =
                f->error == ECANCELED ? "allocations.cancel" : "allocations.perf_event_open";
            f->detail = f->error == ECANCELED ? "allocation preparation cancelled"
                                              : "task-local uprobe open failed; current kernels "
                                                "require CAP_SYS_ADMIN for creation";
        }
        goto fail;
    }
    if (!files_unchanged(a, f) || (c->enable && !xrt_allocations_enable(a, f)))
        goto fail;
    return a;
fail:
    if (f)
        f->opened_then_closed += (uint16_t)xrt_perf_fd_count(a->perf);
    xrt_allocations_destroy(a);
    return NULL;
}

struct xrt_allocations *xrt_allocations_remote(struct xrt_perf *perf)
{
    struct xrt_allocations *a = calloc(1, sizeof(*a));
    if (a) {
        a->perf = perf;
        a->remote = true;
    }
    return a;
}
struct xrt_allocations *xrt_allocations_start_target(const struct xrt_target *t,
                                                     const struct xrt_allocation_config *c,
                                                     const struct xrt_mapping *mapping,
                                                     const char *helper, struct xrt_perf_failure *f)
{
    if (!xrt_target_is_remote(t))
        return xrt_allocations_start(c, f);
    struct xrt_perf *p = xrt_remote_allocations_start(t, c, mapping, helper, f);
    if (!p)
        return NULL;
    struct xrt_allocations *a = xrt_allocations_remote(p);
    if (!a) {
        xrt_perf_destroy(p);
        xrt_perf_fail(f, "alloc", ENOMEM, -1, "remote allocation owner");
    }
    return a;
}
