#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "xrt_allocations.h"
#include "xrt_process.h"
#include "perf_remote.h"
#include "xrt_remote.h"
#include "xrt_uprobes.h"
#include "../profile/allocation_broker.h"
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
    bool remote, functions;
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
static struct xrt_allocations *uprobes_start(const struct xrt_allocation_config *c,
                                              bool functions, struct xrt_perf_failure *f)
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
    a->functions = functions;
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
        attr->sample_regs_user = functions ? XRT_FUNCTION_REGISTER_MASK : XRT_ALLOCATION_REGISTER_MASK;
        attr->flags = 1 | (UINT64_C(1) << 5) | (UINT64_C(1) << 6) | (UINT64_C(1) << 18) |
                      (UINT64_C(1) << 21) | (UINT64_C(1) << 25);
        if (!i)
            attr->flags |= (UINT64_C(1) << 9) | (UINT64_C(1) << 13) | (UINT64_C(1) << 24);
        if (!i && (c->callstacks || functions))
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
                         : functions ? "task-local function uprobe open failed"
                                              : "task-local uprobe open failed; current kernels "
                                                "require CAP_SYS_ADMIN for creation";
        }
        goto fail;
    }
    if (c->cancelled && c->cancelled(c->context)) {
        xrt_perf_fail(f, "allocations.cancel", ECANCELED, -1, "uprobe preparation cancelled");
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

struct xrt_allocations *xrt_allocations_start(const struct xrt_allocation_config *c,
                                              struct xrt_perf_failure *f)
{
    return uprobes_start(c, false, f);
}

struct uprobe_broker {
    int fd, child, pid;
    bool functions;
    const struct xrt_allocation_config *config;
};
static int broker_cancel(void *raw)
{
    const struct uprobe_broker *b = raw;
    return b->config->cancelled && b->config->cancelled(b->config->context);
}
static int broker_event(void *raw, int32_t tid, int group, int file, uint64_t offset,
                         bool returning, bool leader, bool stacks)
{
    struct uprobe_broker *b = raw;
    return b->functions
               ? xodb_function_broker_open(b->fd, b->pid, tid, file, group, offset, returning,
                                            leader, stacks, broker_cancel, b)
               : xodb_allocation_broker_open(b->fd, b->pid, tid, file, group, offset, returning,
                                              leader, stacks, broker_cancel, b);
}
static bool broker_cancelled(void *raw)
{
    return broker_cancel(raw) != 0;
}
static void function_failure(struct xrt_perf_failure *f)
{
    if (!f)
        return;
    /* Preserve kind/errno/TID/rollback; avoid allocator labels on function jobs. */
    if (f->syscall && !strncmp(f->syscall, "allocations.", 12))
        f->syscall = f->error == ECANCELED ? "functions.cancel" : "functions.prepare";
    if (f->detail && (!strncmp(f->detail, "Allocation", 10) ||
                      !strncmp(f->detail, "InvalidAllocation", 17)))
        f->detail = "invalid function uprobe preparation evidence";
    else if (f->detail && !strncmp(f->detail, "allocation ", 11))
        f->detail = f->error == ECANCELED ? "function uprobe preparation cancelled"
                                          : "function uprobe preparation failed";
}
static bool function_mapping(int32_t file_pid, const struct xrt_mapping *mapping,
                              const struct xrt_allocation_config *c)
{
    if (!mapping || mapping->start >= mapping->end)
        return false;
    for (size_t i = 0; i < c->source_count; ++i)
        if (c->sources[i].offset < mapping->offset ||
            c->sources[i].offset - mapping->offset >= mapping->end - mapping->start)
            return false;
    int fd = -1;
    const struct xrt_file_request request = {.kind = XRT_FILE_MAPS};
    if (xrt_process_file(file_pid, &request, &fd) != XRT_OK)
        return false;
    FILE *maps = fdopen(fd, "r");
    if (!maps) {
        close(fd);
        return false;
    }
    bool found = false;
    char line[8192];
    for (size_t i = 0; i < 65536 && fgets(line, sizeof(line), maps); ++i) {
        unsigned long long start, end, offset, major, minor, inode;
        char permissions[5];
        if (sscanf(line, "%llx-%llx %4s %llx %llx:%llx %llu", &start, &end, permissions,
                   &offset, &major, &minor, &inode) == 7 && permissions[2] == 'x' &&
            start == mapping->start && end == mapping->end && offset == mapping->offset &&
            major == mapping->device_major && minor == mapping->device_minor &&
            inode == mapping->inode) {
            found = true;
            break;
        }
    }
    fclose(maps);
    return found;
}
static struct xrt_allocations *uprobes_start_local_scope(const struct xrt_function_scope *scope,
                                                         const struct xrt_allocation_config *c,
                                                         const struct xrt_mapping *mapping,
                                                         const char *helper, bool functions,
                                                         struct xrt_perf_failure *f)
{
    if (!scope || !c || !mapping || c->opener || !c->tids || !c->sources ||
        !c->thread_count || c->thread_count > 32 || !c->source_count ||
        c->source_count > XRT_ALLOCATION_MAX_HOOKS || scope->file_pid <= 0 ||
        scope->breakpoint_count > 128) {
        xrt_perf_fail(f, "config", EINVAL, -1, "invalid target uprobe configuration");
        return NULL;
    }
    if (c->cancelled && c->cancelled(c->context)) {
        xrt_perf_fail(f, "cancel", ECANCELED, -1, "uprobe preparation cancelled");
        return NULL;
    }
    if (functions && !function_mapping(scope->file_pid, mapping, c)) {
        xrt_perf_fail(f, "functions.mapping", EINVAL, -1,
                      "function offsets must belong to the verified executable mapping");
        return NULL;
    }
    if (functions) {
        /* Mapping bounds above prove this addition cannot wrap. A live int3 at
         * the entry would compete with perf's own instruction replacement. */
        for (size_t i = 0; i < c->source_count; ++i) {
            const uint64_t address = mapping->start + (c->sources[i].offset - mapping->offset);
            for (size_t j = 0; j < scope->breakpoint_count; ++j) {
                if (scope->breakpoint_addresses[j] == address) {
                    xrt_perf_fail(f, "functions.breakpoint", EBUSY, -1,
                                  "function entry overlaps an enabled software breakpoint");
                    return NULL;
                }
            }
        }
    }
    struct xrt_file_request request = {.kind = XRT_FILE_MAPPED, .mapping = *mapping};
    int fd = -1;
    if (xrt_process_file(scope->file_pid, &request, &fd) != XRT_OK) {
        xrt_perf_fail(f, "file", ENOENT, -1, "target mapped file unavailable");
        return NULL;
    }
    struct xrt_allocation_source sources[XRT_ALLOCATION_MAX_HOOKS];
    for (size_t i = 0; i < c->source_count; ++i) {
        sources[i] = c->sources[i];
        sources[i].fd = fd;
    }
    struct xrt_allocation_config config = *c;
    config.sources = sources;
    struct uprobe_broker broker = {.fd = -1, .child = -1, .pid = c->pid,
                                    .functions = functions, .config = c};
    if (helper && *helper) {
        if (xodb_allocation_broker_start(helper, &broker.fd, &broker.child)) {
            close(fd);
            xrt_perf_fail(f, "helper", errno, -1, "explicit target uprobe helper start failed");
            return NULL;
        }
        config.opener = broker_event;
        config.cancelled = broker_cancelled;
        config.context = &broker;
    }
    struct xrt_allocations *a = uprobes_start(&config, functions, f);
    xodb_allocation_broker_close(broker.fd, broker.child);
    close(fd);
    if (functions && !a)
        function_failure(f);
    return a;
}
bool xrt_functions_capture_scope(const struct xrt_target *t, const int32_t *tids,
                                  size_t count, struct xrt_function_scope *out,
                                  struct xrt_perf_failure *f)
{
    if (!t || !tids || !count || count > 32 || !out) {
        xrt_perf_fail(f, "scope", EINVAL, -1, "invalid function scope request");
        return false;
    }
    const struct xrt_arch *arch = xrt_target_arch(t);
    if (!arch || arch->machine != XRT_X86_64) {
        xrt_perf_fail(f, "functions.architecture", ENOTSUP, -1,
                      "function uprobes currently require Linux x86-64");
        return false;
    }
    struct xrt_target_view view;
    xrt_target_view(t, &view);
    if (view.pid <= 0 || view.state != XRT_STOPPED || view.breakpoint_count > 128) {
        xrt_perf_fail(f, "scope", EINVAL, -1, "function observation requires a held target");
        return false;
    }
    struct xrt_function_scope scope = {.remote = xrt_target_is_remote(t), .pid = view.pid,
                                        .file_pid = tids[0], .thread_count = count};
    for (size_t i = 0; i < count; ++i) {
        bool found = false;
        for (size_t j = 0; j < i; ++j)
            if (tids[j] == tids[i]) {
                xrt_perf_fail(f, "scope", EINVAL, tids[i], "duplicate selected thread");
                return false;
            }
        for (size_t j = 0; j < view.thread_count; ++j)
            if (view.threads[j].tid == tids[i] && view.threads[j].state == XRT_STOPPED)
                found = true;
        if (!found) {
            xrt_perf_fail(f, "scope", EINVAL, tids[i], "selected thread is not held by target");
            return false;
        }
        scope.tids[i] = tids[i];
    }
    for (size_t i = 0; i < view.breakpoint_count; ++i)
        if (view.breakpoints[i].enabled && !view.breakpoints[i].pending)
            scope.breakpoint_addresses[scope.breakpoint_count++] = view.breakpoints[i].address;
    *out = scope;
    return true;
}
struct xrt_allocations *xrt_uprobes_start_local(const struct xrt_target *t,
                                               const struct xrt_allocation_config *c,
                                               const struct xrt_mapping *mapping,
                                               const char *helper, bool functions,
                                               struct xrt_perf_failure *f)
{
    struct xrt_function_scope scope;
    if (!c || !xrt_functions_capture_scope(t, c->tids, c->thread_count, &scope, f))
        return NULL;
    if (scope.remote || c->pid != scope.pid) {
        xrt_perf_fail(f, "scope", EINVAL, -1, "invalid native target scope");
        return NULL;
    }
    return uprobes_start_local_scope(&scope, c, mapping, helper, functions, f);
}
struct xrt_functions *xrt_functions_start_target(const struct xrt_target *t,
                                                const struct xrt_function_config *c,
                                                const struct xrt_mapping *mapping,
                                                const char *helper, struct xrt_perf_failure *f)
{
    struct xrt_function_scope scope;
    if (!c) {
        xrt_perf_fail(f, "config", EINVAL, -1, "invalid function observation configuration");
        return NULL;
    }
    if (!xrt_functions_capture_scope(t, c->tids, c->thread_count, &scope, f))
        return NULL;
    return xrt_functions_start_scoped(scope.remote ? t : NULL, &scope, c, mapping, helper, f);
}
struct xrt_functions *xrt_functions_start_scoped(const struct xrt_target *remote_target,
                                                const struct xrt_function_scope *scope,
                                                const struct xrt_function_config *c,
                                                const struct xrt_mapping *mapping,
                                                const char *helper, struct xrt_perf_failure *f)
{
    if (!scope || !c || c->pid <= 0 || !c->tids || !c->thread_count || c->thread_count > 32 ||
        !c->sources || !c->source_count || c->source_count > XRT_FUNCTION_MAX_SOURCES ||
        scope->pid != c->pid || scope->thread_count != c->thread_count ||
        scope->file_pid <= 0 || scope->file_pid != scope->tids[0] ||
        scope->breakpoint_count > 128 || scope->remote != (remote_target != NULL)) {
        xrt_perf_fail(f, "config", EINVAL, -1, "invalid function observation configuration");
        return NULL;
    }
    for (size_t i = 0; i < c->thread_count; ++i)
        if (scope->tids[i] != c->tids[i]) {
            xrt_perf_fail(f, "scope", EINVAL, -1, "function thread scope changed after preparation");
            return NULL;
        }
    for (size_t i = 0; i < c->source_count; ++i) {
        if (!c->sources[i].id || c->sources[i].fd < 0 || c->sources[i].fd != c->sources[0].fd) {
            xrt_perf_fail(f, "config", EINVAL, -1, "invalid function source identity");
            return NULL;
        }
        for (size_t j = 0; j < i; ++j)
            if (c->sources[i].id == c->sources[j].id ||
                c->sources[i].offset == c->sources[j].offset) {
                xrt_perf_fail(f, "config", EINVAL, -1, "duplicate function source identity");
                return NULL;
            }
    }
    struct xrt_allocation_source sources[XRT_FUNCTION_MAX_SOURCES];
    for (size_t i = 0; i < c->source_count; ++i) {
        const struct xrt_function_source *source = &c->sources[i];
        sources[i] = (struct xrt_allocation_source){.id = source->id, .fd = source->fd,
                                                   .offset = source->offset,
                                                   .identity = source->identity};
    }
    const struct xrt_allocation_config config = {
        .pid = c->pid, .tids = c->tids, .thread_count = c->thread_count, .sources = sources,
        .source_count = c->source_count, .enable = c->enable, .callstacks = c->callstacks,
        .cancelled = c->cancelled, .context = c->context};
    struct xrt_allocations *a;
    if (scope->remote) {
        struct xrt_perf *p = xrt_remote_functions_start(remote_target, &config, mapping, helper, f);
        if (!p) {
            function_failure(f);
            return NULL;
        }
        a = xrt_allocations_remote(p);
        if (!a) {
            xrt_perf_destroy(p);
            xrt_perf_fail(f, "alloc", ENOMEM, -1, "remote function owner");
        } else
            a->functions = true;
    } else
        a = uprobes_start_local_scope(scope, &config, mapping, helper, true, f);
    return (struct xrt_functions *)a;
}
bool xrt_functions_enable(struct xrt_functions *functions, struct xrt_perf_failure *f)
{
    bool ok = xrt_allocations_enable((struct xrt_allocations *)functions, f);
    if (!ok)
        function_failure(f);
    return ok;
}
void xrt_functions_destroy(struct xrt_functions *functions)
{
    xrt_allocations_destroy((struct xrt_allocations *)functions);
}
struct xrt_perf *xrt_functions_perf(struct xrt_functions *functions)
{
    return xrt_allocations_perf((struct xrt_allocations *)functions);
}
