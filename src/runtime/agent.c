#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "xrt_remote.h"
#include "rpc.h"
#include "wire_target.h"
#include "perf_remote.h"
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
struct entry {
    uint32_t id;
    struct xrt_target *target;
    struct xrt_agent_perf *collectors;
};
struct agent_file {
    uint32_t id, target;
    int fd;
    uint64_t position;
    bool regular;
    struct xrt_file_identity identity;
};
struct agent {
    struct xrt_agent_perf *collectors;
    struct entry entries[XRT_RPC_TARGETS];
    uint32_t next_id, next_file;
    struct agent_file files[32];
    char file_path[8192];
    uint8_t *request, *reply, *extra;
};
static void newborn(void *raw, const struct xrt_thread *thread, bool same_group)
{
    struct entry *entry = raw;
    xrt_agent_perf_observe(entry->collectors, entry->target, thread, same_group);
}
static struct entry *lookup(struct agent *a, uint32_t id)
{
    for (unsigned i = 0; i < XRT_RPC_TARGETS; ++i)
        if (a->entries[i].target && a->entries[i].id == id)
            return &a->entries[i];
    return NULL;
}
static uint32_t identity(struct agent *a, const struct xrt_target *target)
{
    for (unsigned i = 0; i < XRT_RPC_TARGETS; ++i)
        if (a->entries[i].target == target)
            return a->entries[i].id;
    return 0;
}
static bool read_only(uint16_t op)
{
    return op == XRT_RPC_HELLO || op == XRT_RPC_CREATE || op == XRT_RPC_SYNC ||
           op == XRT_RPC_READ || op == XRT_RPC_REGISTERS || op == XRT_RPC_EXTENDED ||
           op == XRT_RPC_WATCH_CAPACITY || op == XRT_RPC_SIGNAL_INFO || op == XRT_RPC_VIEW ||
           op == XRT_RPC_FILE_OPEN || op == XRT_RPC_FILE_READ || op == XRT_RPC_FILE_CLOSE;
}
static enum xrt_status dispatch(struct agent *a, struct xrt_wire_frame *frame, uint64_t *value,
                                size_t *extra_size, struct xrt_target **snapshot)
{
    struct xrt_codec in = xrt_codec(a->request, frame->size, true);
    uint64_t generation = 0, args[3] = {0};
    xrt_codec_u64(&in, &generation);
    for (unsigned i = 0; i < 3; ++i)
        xrt_codec_u64(&in, &args[i]);
    if (!in.ok || frame->size - XRT_RPC_REQUEST_PREFIX > XRT_RPC_DATA_MAX)
        return XRT_INVALID_ARGUMENT;
    uint8_t *data = a->request + in.at;
    size_t size = frame->size - in.at;
    struct entry *entry = lookup(a, frame->target);
    struct xrt_target *t = entry ? entry->target : NULL;
    *snapshot = frame->op == XRT_RPC_FILE_OPEN || frame->op == XRT_RPC_FILE_READ ||
                        frame->op == XRT_RPC_FILE_CLOSE
                    ? NULL
                    : t;
    if (frame->op == XRT_RPC_HELLO) {
        if (frame->target || size)
            return XRT_INVALID_ARGUMENT;
        const struct xrt_arch *arch = xrt_arch_native();
        struct xrt_codec extra = xrt_codec(a->extra, XRT_RPC_DATA_MAX, false);
        uint64_t now = xrt_now();
        uint32_t hz = (uint32_t)xrt_target_tick_hz(NULL);
        uint32_t page = (uint32_t)xrt_target_page_size(NULL);
        xrt_codec_u64(&extra, &now);
        xrt_codec_u32(&extra, &hz);
        xrt_codec_u32(&extra, &page);
        *extra_size = extra.at;
        *value = arch ? arch->machine : 0;
        return arch ? XRT_OK : XRT_UNSUPPORTED_ARCHITECTURE;
    }
    if (frame->op == XRT_RPC_CREATE) {
        if (frame->target || size)
            return XRT_INVALID_ARGUMENT;
        if (a->next_id == UINT32_MAX)
            return XRT_PROCESS_LIMIT;
        for (unsigned i = 0; i < XRT_RPC_TARGETS; ++i)
            if (!a->entries[i].target) {
                t = xrt_target_create();
                if (!t)
                    return XRT_OUT_OF_MEMORY;
                a->entries[i] =
                    (struct entry){.id = ++a->next_id, .target = t, .collectors = a->collectors};
                xrt_target_observer(t, newborn, &a->entries[i]);
                *value = a->next_id;
                *snapshot = t;
                return XRT_OK;
            }
        return XRT_PROCESS_LIMIT;
    }
    if (!t)
        return XRT_INVALID_STATE;
    if (frame->op >= XRT_RPC_CPU_START) {
        *snapshot = NULL;
        return xrt_agent_perf_dispatch(a->collectors, t, frame->op, args, data, size, value,
                                       a->extra, extra_size);
    }
    if (!read_only(frame->op)) {
        enum xrt_status expected = xrt_target_expect(t, generation);
        if (expected != XRT_OK)
            return expected;
    }
    if (size && frame->op != XRT_RPC_LAUNCH && frame->op != XRT_RPC_WRITE &&
        frame->op != XRT_RPC_REGISTER_WRITE && frame->op != XRT_RPC_FILE_OPEN)
        return XRT_INVALID_ARGUMENT;
    enum xrt_status status = XRT_OK;
    switch (frame->op) {
    case XRT_RPC_HELLO:
    case XRT_RPC_CREATE:
        return XRT_INVALID_ARGUMENT;
    case XRT_RPC_DESTROY:
        if (xrt_agent_perf_uses(a->collectors, t))
            return XRT_INVALID_STATE;
        status = xrt_target_destroy(t);
        if (status == XRT_OK) {
            entry->target = NULL;
            *snapshot = NULL;
        }
        return status;
    case XRT_RPC_SYNC:
        return xrt_target_poll(t);
    case XRT_RPC_VIEW:
        return XRT_OK;
    case XRT_RPC_LAUNCH: {
        if (!args[0] || args[0] > 255 || !size)
            return XRT_INVALID_ARGUMENT;
        const char *argv[256];
        size_t at = 0;
        for (size_t i = 0; i < args[0]; ++i) {
            if (at >= size)
                return XRT_INVALID_ARGUMENT;
            const uint8_t *end = memchr(data + at, 0, size - at);
            if (!end)
                return XRT_INVALID_ARGUMENT;
            argv[i] = (const char *)data + at;
            at = (size_t)(end - data) + 1;
        }
        if (at != size || !*argv[0])
            return XRT_INVALID_ARGUMENT;
        argv[args[0]] = NULL;
        return xrt_target_launch(t, argv);
    }
    case XRT_RPC_ATTACH:
        return args[0] > INT32_MAX ? XRT_INVALID_PID : xrt_target_attach(t, (int32_t)args[0]);
    case XRT_RPC_INTERRUPT:
        return xrt_target_interrupt(t);
    case XRT_RPC_CONTINUE:
        return xrt_target_continue(t);
    case XRT_RPC_STEP:
        return args[0] > INT32_MAX ? XRT_INVALID_PID : xrt_target_step(t, (int32_t)args[0]);
    case XRT_RPC_WAIT_STOPPED:
        return xrt_target_wait_stopped(t);
    case XRT_RPC_DETACH:
        return xrt_target_detach(t);
    case XRT_RPC_DETACH_FAMILY:
        return xrt_target_detach_family(t);
    case XRT_RPC_CLOSE:
        return xrt_target_close(t);
    case XRT_RPC_RESET:
        return xrt_target_reset(t);
    case XRT_RPC_FOLLOW:
        return args[0] > 1 ? XRT_INVALID_ARGUMENT : xrt_target_set_following(t, args[0] != 0);
    case XRT_RPC_ADOPT: {
        if (args[0] > INT32_MAX || args[1] > UINT32_MAX)
            return XRT_INVALID_ARGUMENT;
        struct entry *child = lookup(a, (uint32_t)args[1]);
        if (!child || child == entry)
            return XRT_INVALID_ARGUMENT;
        struct xrt_birth birth = {0};
        status = xrt_target_adopt(t, (int32_t)args[0], child->target, &birth);
        xrt_target_observer(child->target, newborn, child);
        if (status == XRT_OK) {
            struct xrt_codec extra = xrt_codec(a->extra, XRT_RPC_DATA_MAX, false);
            xrt_wire_birth(&extra, &birth);
            if (!extra.ok)
                return XRT_BUFFER_TOO_SMALL;
            *extra_size = extra.at;
        }
        return status;
    }
    case XRT_RPC_BP_SET:
        return args[1] > 1 ? XRT_INVALID_ARGUMENT
                           : xrt_target_breakpoint_set(t, args[0], args[1] != 0, value);
    case XRT_RPC_BP_RESERVE:
        return xrt_target_breakpoint_reserve(t, value);
    case XRT_RPC_BP_RESTORE:
        return args[1] > 1 ? XRT_INVALID_ARGUMENT
                           : xrt_target_breakpoint_restore(t, args[0], args[1] != 0);
    case XRT_RPC_BP_RESOLVE:
        return xrt_target_breakpoint_resolve(t, args[0], args[1]);
    case XRT_RPC_BP_WITHDRAW:
        return xrt_target_breakpoint_withdraw(t, args[0]);
    case XRT_RPC_BP_ENABLE:
        return args[1] > 1 ? XRT_INVALID_ARGUMENT
                           : xrt_target_breakpoint_enable(t, args[0], args[1] != 0);
    case XRT_RPC_BP_INTERNAL:
        return args[1] > 1 ? XRT_INVALID_ARGUMENT
                           : xrt_target_breakpoint_internal(t, args[0], args[1] != 0);
    case XRT_RPC_BP_REMOVE:
        return xrt_target_breakpoint_remove(t, args[0]);
    case XRT_RPC_WATCH_SET:
        return args[1] > UINT8_MAX || args[2] > XRT_WATCH_EXECUTE
                   ? XRT_INVALID_ARGUMENT
                   : xrt_target_watchpoint_set(t, args[0], (uint8_t)args[1],
                                               (enum xrt_watch_kind)args[2], value);
    case XRT_RPC_WATCH_REMOVE:
        return xrt_target_watchpoint_remove(t, args[0]);
    case XRT_RPC_WATCH_CAPACITY: {
        uint8_t capacity = 0;
        status = xrt_target_watchpoint_capacity(t, &capacity);
        *value = capacity;
        return status;
    }
    case XRT_RPC_READ:
        if (args[1] > XRT_RPC_DATA_MAX)
            return XRT_BUFFER_TOO_SMALL;
        return xrt_target_read(t, args[0], a->extra, (size_t)args[1], extra_size);
    case XRT_RPC_WRITE:
        return xrt_target_write(t, args[0], data, size);
    case XRT_RPC_REGISTERS: {
        if (args[0] > INT32_MAX)
            return XRT_INVALID_PID;
        struct xrt_registers regs = {0};
        status = xrt_target_registers(t, (int32_t)args[0], &regs);
        if (status == XRT_OK) {
            struct xrt_codec extra = xrt_codec(a->extra, XRT_RPC_DATA_MAX, false);
            xrt_wire_registers(&extra, &regs);
            if (!extra.ok)
                return XRT_BUFFER_TOO_SMALL;
            *extra_size = extra.at;
        }
        return status;
    }
    case XRT_RPC_REGISTER_WRITE:
        return args[0] > INT32_MAX ? XRT_INVALID_PID
                                   : xrt_target_register_write(t, (int32_t)args[0],
                                                               (const char *)data, size, args[1]);
    case XRT_RPC_EXTENDED: {
        if (args[0] > INT32_MAX)
            return XRT_INVALID_PID;
        struct xrt_xstate *state = calloc(1, sizeof(*state));
        if (!state)
            return XRT_OUT_OF_MEMORY;
        status = xrt_target_extended(t, (int32_t)args[0], state);
        if (status == XRT_OK) {
            struct xrt_codec extra = xrt_codec(a->extra, XRT_RPC_DATA_MAX, false);
            xrt_wire_xstate(&extra, state);
            if (!extra.ok)
                status = XRT_BUFFER_TOO_SMALL;
            else
                *extra_size = extra.at;
        }
        free(state);
        return status;
    }
    case XRT_RPC_SIGNAL_SUPPRESS:
        return args[0] > INT32_MAX ? XRT_INVALID_PID
                                   : xrt_target_signal_suppress(t, (int32_t)args[0]);
    case XRT_RPC_INVALIDATE:
        xrt_target_invalidate(t);
        return XRT_OK;
    case XRT_RPC_EVENT:
        if (args[0] > XRT_EVENT_PROCESS_SEPARATED || args[1] > INT32_MAX)
            return XRT_INVALID_ARGUMENT;
        {
            int64_t detail;
            memcpy(&detail, &args[2], 8);
            xrt_target_event(t, (enum xrt_event_kind)args[0], (int32_t)args[1], detail);
        }
        return XRT_OK;
    case XRT_RPC_FILE_OPEN: {
        *snapshot = NULL;
        unsigned slot = 0;
        while (slot < 32 && a->files[slot].id)
            ++slot;
        if (slot == 32 || a->next_file == UINT32_MAX)
            return XRT_FILE_LIMIT;
        struct xrt_file_request request = {0};
        struct xrt_codec file = xrt_codec(data, size, true);
        xrt_wire_file_request(&file, &request, a->file_path, sizeof(a->file_path));
        if (!file.ok || file.at != file.size)
            return XRT_INVALID_ARGUMENT;
        int fd;
        status = xrt_target_file(t, &request, &fd);
        if (status != XRT_OK)
            return status;
        struct agent_file opened = {.id = ++a->next_file,
                                    .target = frame->target,
                                    .fd = fd,
                                    .regular = request.kind == XRT_FILE_MAPPED};
        if (opened.regular) {
            status = xrt_file_identity(fd, &opened.identity);
            if (status == XRT_OK &&
                (opened.identity.size <= 0 || opened.identity.size > 256 * 1024 * 1024))
                status = XRT_FILE_LIMIT;
            if (status != XRT_OK) {
                close(fd);
                return status;
            }
        }
        struct xrt_codec extra = xrt_codec(a->extra, XRT_RPC_DATA_MAX, false);
        xrt_codec_bool(&extra, &opened.regular);
        xrt_wire_file_identity(&extra, &opened.identity);
        a->files[slot] = opened;
        *value = opened.id;
        *extra_size = extra.at;
        return XRT_OK;
    }
    case XRT_RPC_FILE_READ:
    case XRT_RPC_FILE_CLOSE: {
        *snapshot = NULL;
        unsigned slot = 0;
        while (slot < 32 &&
               (a->files[slot].id != args[0] || a->files[slot].target != frame->target))
            ++slot;
        if (slot == 32 || !args[0])
            return XRT_INVALID_ARGUMENT;
        struct agent_file *file = &a->files[slot];
        status = file->regular ? xrt_file_unchanged(file->fd, &file->identity) : XRT_OK;
        if (frame->op == XRT_RPC_FILE_CLOSE) {
            close(file->fd);
            file->id = 0;
            return status;
        }
        if (status != XRT_OK)
            return status;
        if (args[2] > XRT_RPC_DATA_MAX || args[1] > INT64_MAX ||
            (!file->regular && args[1] != file->position))
            return XRT_INVALID_ARGUMENT;
        ssize_t got;
        do {
            got = file->regular ? pread(file->fd, a->extra, (size_t)args[2], (off_t)args[1])
                                : read(file->fd, a->extra, (size_t)args[2]);
        } while (got < 0 && errno == EINTR);
        if (got < 0)
            return XRT_FILE_UNAVAILABLE;
        if (file->regular) {
            status = xrt_file_unchanged(file->fd, &file->identity);
            if (status != XRT_OK)
                return status;
        }
        file->position += (uint64_t)got;
        *extra_size = (size_t)got;
        return XRT_OK;
    }
    case XRT_RPC_SIGNAL_INFO: {
        if (args[0] > INT32_MAX)
            return XRT_INVALID_PID;
        struct xrt_signal_info info = {0};
        status = xrt_target_signal_info(t, (int32_t)args[0], &info);
        if (status == XRT_OK) {
            struct xrt_codec extra = xrt_codec(a->extra, XRT_RPC_DATA_MAX, false);
            xrt_wire_signal(&extra, &info);
            *extra_size = extra.at;
        }
        return status;
    }
    default:
        return XRT_INVALID_ARGUMENT;
    }
}
int xrt_agent_serve(int input, int output, const volatile sig_atomic_t *stop)
{
    struct agent *a = calloc(1, sizeof(*a));
    if (!a)
        return 1;
    a->request = malloc(XRT_WIRE_MAX_BODY);
    a->reply = malloc(XRT_WIRE_MAX_BODY);
    a->extra = malloc(XRT_RPC_DATA_MAX);
    a->collectors = xrt_agent_perf_create();
    int result = 0;
    uint64_t next_request = 1;
    if (!a->request || !a->reply || !a->extra || !a->collectors) {
        result = 1;
        goto done;
    }
    while (!stop || !*stop) {
        struct pollfd fd = {.fd = input, .events = POLLIN};
        int ready = poll(&fd, 1, 100);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            result = 1;
            break;
        }
        if (!ready)
            continue;
        struct xrt_wire_frame f;
        enum xrt_wire_result received =
            xrt_wire_read(input, &f, a->request, XRT_WIRE_MAX_BODY, 10000);
        if (received == XRT_WIRE_EOF)
            break;
        if (received != XRT_WIRE_OK || f.flags || f.status || f.request != next_request++ ||
            f.size < XRT_RPC_REQUEST_PREFIX) {
            result = 1;
            break;
        }
        uint64_t value = 0;
        size_t extra_size = 0;
        struct xrt_target *snapshot = NULL;
        enum xrt_status status = dispatch(a, &f, &value, &extra_size, &snapshot);
        struct xrt_codec out = xrt_codec(a->reply, XRT_WIRE_MAX_BODY, false);
        xrt_codec_u64(&out, &value);
        uint32_t extra = (uint32_t)extra_size;
        xrt_codec_u32(&out, &extra);
        xrt_codec_bytes(&out, a->extra, extra_size);
        bool present = snapshot != NULL;
        xrt_codec_bool(&out, &present);
        if (snapshot) {
            bool shared = xrt_target_shared_vm(snapshot);
            uint32_t root = identity(a, xrt_target_family_root(snapshot));
            xrt_codec_bool(&out, &shared);
            xrt_codec_u32(&out, &root);
            xrt_wire_target(&out, snapshot);
        }
        if (!out.ok) {
            result = 1;
            break;
        }
        f.flags = 1;
        f.status = (uint32_t)status;
        f.size = (uint32_t)out.at;
        if (xrt_wire_write(output, &f, a->reply, 10000) != XRT_WIRE_OK) {
            result = 1;
            break;
        }
    }
done:
    xrt_agent_perf_destroy(a->collectors);
    for (unsigned i = 0; i < 32; ++i)
        if (a->files[i].id)
            close(a->files[i].fd);
    /* Keep every handle alive until family cleanup has visited all members. */
    for (unsigned i = 0; i < XRT_RPC_TARGETS; ++i)
        if (a->entries[i].target && xrt_target_close(a->entries[i].target) != XRT_OK)
            result |= 2;
    for (unsigned i = 0; i < XRT_RPC_TARGETS; ++i)
        if (a->entries[i].target && xrt_target_destroy(a->entries[i].target) != XRT_OK)
            result |= 2;
    free(a->request);
    free(a->reply);
    free(a->extra);
    free(a);
    return result;
}
