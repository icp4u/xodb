#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "remote_internal.h"
#include "target_internal.h"
#include "wire_target.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <sys/mman.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
struct xrt_connection {
    pthread_mutex_t mutex;
    int fd;
    pid_t child;
    uint64_t request, producer_ns, host_ns, uncertainty_ns;
    uint32_t tick_hz, page_size;
    enum xrt_status failed;
    struct xrt_target *targets[XRT_RPC_TARGETS];
    uint8_t *request_bytes, *reply;
    struct xrt_target *decoded;
    bool reaped;
    int exit_status;
};
static enum xrt_status broken(struct xrt_connection *c, enum xrt_status status)
{
    c->failed = status;
    if (c->fd >= 0) {
        close(c->fd);
        c->fd = -1;
    }
    return status;
}
static bool reap(struct xrt_connection *c)
{
    if (c->reaped)
        return true;
    const uint64_t deadline = xrt_now() + UINT64_C(5000000000);
    while (xrt_now() < deadline) {
        pid_t got = waitpid(c->child, &c->exit_status, WNOHANG);
        if (got == c->child) {
            c->reaped = true;
            return true;
        }
        if (got < 0 && errno != EINTR)
            return false;
        struct timespec pause = {.tv_nsec = 1000000};
        nanosleep(&pause, NULL);
    }
    return false;
}
static void release_connection(struct xrt_connection *c)
{
    if (c->fd >= 0)
        close(c->fd);
    c->fd = -1;
    if (!reap(c)) {
        kill(c->child, SIGTERM);
        reap(c);
    }
    free(c->request_bytes);
    free(c->reply);
    free(c->decoded);
    pthread_mutex_destroy(&c->mutex);
    free(c);
}
bool xrt_target_is_remote(const struct xrt_target *t)
{
    return t && t->connection;
}
uint64_t xrt_target_timestamp(const struct xrt_target *t, uint64_t producer)
{
    if (!t || !t->connection)
        return producer;
    const struct xrt_connection *c = t->connection;
    if (producer >= c->producer_ns) {
        uint64_t delta = producer - c->producer_ns;
        return delta > UINT64_MAX - c->host_ns ? UINT64_MAX : c->host_ns + delta;
    }
    uint64_t delta = c->producer_ns - producer;
    return delta > c->host_ns ? 0 : c->host_ns - delta;
}
uint64_t xrt_target_tick_hz(const struct xrt_target *t)
{
    if (t && t->connection)
        return t->connection->tick_hz;
    long hz = sysconf(_SC_CLK_TCK);
    return hz > 0 ? (uint64_t)hz : 0;
}
uint64_t xrt_target_page_size(const struct xrt_target *t)
{
    if (t && t->connection)
        return t->connection->page_size;
    long size = sysconf(_SC_PAGESIZE);
    return size > 0 ? (uint64_t)size : 0;
}
bool xrt_target_clock(const struct xrt_target *t, struct xrt_clock *out)
{
    if (!t || !t->connection || !out)
        return false;
    const struct xrt_connection *c = t->connection;
    *out = (struct xrt_clock){c->producer_ns, c->host_ns, c->uncertainty_ns};
    return true;
}
const struct xrt_arch *xrt_target_arch(const struct xrt_target *t)
{
    return t ? t->arch : xrt_arch_native();
}
const struct xrt_target *xrt_remote_root(const struct xrt_target *t)
{
    for (unsigned i = 0; i < XRT_RPC_TARGETS; ++i)
        if (t->connection->targets[i] && t->connection->targets[i]->remote_id == t->remote_root)
            return t->connection->targets[i];
    return t;
}
static enum xrt_status invoke(const struct xrt_target *target, const struct xrt_call *call)
{
    struct xrt_target *t = (struct xrt_target *)target;
    struct xrt_connection *c = t->connection;
    if (c->failed != XRT_OK)
        return c->failed;
    if (call->size > XRT_RPC_DATA_MAX || (call->size && !call->data))
        return XRT_INVALID_ARGUMENT;
    if (c->request == UINT64_MAX)
        return broken(c, XRT_PROTOCOL_ERROR);
    struct xrt_codec request = xrt_codec(c->request_bytes, XRT_WIRE_MAX_BODY, false);
    const bool file_call = call->op >= XRT_RPC_CPU_START || call->op == XRT_RPC_FILE_OPEN ||
                           call->op == XRT_RPC_FILE_READ || call->op == XRT_RPC_FILE_CLOSE;
    uint64_t generation = file_call ? 0 : t->generation, args[3];
    memcpy(args, call->args, sizeof(args));
    xrt_codec_u64(&request, &generation);
    for (unsigned i = 0; i < 3; ++i)
        xrt_codec_u64(&request, &args[i]);
    xrt_codec_bytes(&request, (void *)call->data, call->size);
    struct xrt_wire_frame frame = {.op = call->op,
                                   .request = ++c->request,
                                   .target = t->remote_id,
                                   .size = (uint32_t)request.at};
    if (!request.ok)
        return XRT_BUFFER_TOO_SMALL;
    if (xrt_wire_write(c->fd, &frame, c->request_bytes, 10000) != XRT_WIRE_OK)
        return broken(c, XRT_TRANSPORT_FAILED);
    struct xrt_wire_frame reply;
    enum xrt_wire_result received =
        xrt_wire_read(c->fd, &reply, c->reply, XRT_WIRE_MAX_BODY, 10000);
    if (received != XRT_WIRE_OK)
        return broken(c, received == XRT_WIRE_INVALID ? XRT_PROTOCOL_ERROR : XRT_TRANSPORT_FAILED);
    if (reply.flags != 1 || reply.request != frame.request || reply.op != frame.op ||
        reply.target != frame.target || reply.status > XRT_FILE_LIMIT)
        return broken(c, XRT_PROTOCOL_ERROR);
    struct xrt_codec in = xrt_codec(c->reply, reply.size, true);
    uint64_t value = 0;
    uint32_t size = 0, root = 0;
    bool present = false, shared = false;
    xrt_codec_u64(&in, &value);
    xrt_codec_u32(&in, &size);
    if (!in.ok || size > call->capacity || size > in.size - in.at || (size && !call->out))
        return broken(c, XRT_PROTOCOL_ERROR);
    const size_t extra_at = in.at;
    in.at += size;
    xrt_codec_bool(&in, &present);
    if (present) {
        xrt_codec_bool(&in, &shared);
        xrt_codec_u32(&in, &root);
        memset(c->decoded, 0, sizeof(*c->decoded));
        xrt_wire_target(&in, c->decoded);
    }
    if (!in.ok || in.at != in.size ||
        (reply.status == XRT_OK &&
         present != (call->op != XRT_RPC_HELLO && call->op != XRT_RPC_DESTROY && !file_call)))
        return broken(c, XRT_PROTOCOL_ERROR);
    if (present) {
        /* Connection identity stays immutable: metadata workers may use it
         * while the event-loop thread publishes a new target snapshot. */
        const struct xrt_target *v = c->decoded;
        t->arch = v->arch;
        t->pid = v->pid;
        t->state = v->state;
        t->owned = v->owned;
        t->follow_processes = v->follow_processes;
        t->stepping = v->stepping;
        t->detach_pending = v->detach_pending;
        t->want_run = v->want_run;
        t->generation = v->generation;
        t->image_epoch = v->image_epoch;
        t->sequence = v->sequence;
        t->next_thread_id = v->next_thread_id;
        t->next_probe_id = v->next_probe_id;
        t->thread_count = v->thread_count;
        t->event_count = v->event_count;
        t->breakpoint_count = v->breakpoint_count;
        t->birth_count = v->birth_count;
        memcpy(t->threads, v->threads, v->thread_count * sizeof(v->threads[0]));
        memcpy(t->events, v->events, v->event_count * sizeof(v->events[0]));
        for (size_t i = 0; i < t->event_count; ++i)
            t->events[i].time_ns = xrt_target_timestamp(t, t->events[i].time_ns);
        memcpy(t->breakpoints, v->breakpoints, v->breakpoint_count * sizeof(v->breakpoints[0]));
        memcpy(t->births, v->births, v->birth_count * sizeof(v->births[0]));
        memcpy(t->watchpoints, v->watchpoints, sizeof(v->watchpoints));
        t->remote_root = root;
        t->remote_shared = shared;
    }
    if (size)
        memcpy(call->out, c->reply + extra_at, size);
    if (call->length)
        *call->length = size;
    if (call->value && reply.status == XRT_OK)
        *call->value = value;
    enum xrt_status status = (enum xrt_status)reply.status;
    if (!file_call && call->op != XRT_RPC_VIEW && call->op != XRT_RPC_HELLO &&
        call->op != XRT_RPC_READ && call->op != XRT_RPC_REGISTERS && call->op != XRT_RPC_EXTENDED &&
        call->op != XRT_RPC_WATCH_CAPACITY) {
        enum xrt_status synced = xrt_remote_sync_family(t);
        if (status == XRT_OK)
            status = synced;
    }
    return status;
}
enum xrt_status xrt_remote_call(const struct xrt_target *target, const struct xrt_call *call)
{
    struct xrt_connection *c = target->connection;
    pthread_mutex_lock(&c->mutex);
    enum xrt_status status = invoke(target, call);
    pthread_mutex_unlock(&c->mutex);
    return status;
}
enum xrt_status xrt_remote_health(const struct xrt_target *t)
{
    pthread_mutex_lock(&t->connection->mutex);
    enum xrt_status status = t->connection->failed;
    pthread_mutex_unlock(&t->connection->mutex);
    return status;
}
enum xrt_status xrt_remote_fail(const struct xrt_target *t, enum xrt_status status)
{
    pthread_mutex_lock(&t->connection->mutex);
    status = broken(t->connection, status);
    pthread_mutex_unlock(&t->connection->mutex);
    return status;
}
static enum xrt_status create_remote(struct xrt_connection *c, struct xrt_target *t)
{
    unsigned slot = 0;
    while (slot < XRT_RPC_TARGETS && c->targets[slot])
        ++slot;
    if (slot == XRT_RPC_TARGETS)
        return XRT_PROCESS_LIMIT;
    t->connection = c;
    uint64_t id = 0;
    enum xrt_status status =
        xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_CREATE, .value = &id});
    if (status != XRT_OK) {
        t->connection = NULL;
        return status;
    }
    if (!id || id > UINT32_MAX) {
        t->connection = NULL;
        return broken(c, XRT_PROTOCOL_ERROR);
    }
    t->remote_id = (uint32_t)id;
    c->targets[slot] = t;
    return XRT_OK;
}
enum xrt_status xrt_target_remote(const char *const argv[], struct xrt_target **out)
{
    if (!argv || !argv[0] || !out)
        return XRT_INVALID_ARGUMENT;
    struct xrt_connection *c = calloc(1, sizeof(*c));
    if (!c)
        return XRT_OUT_OF_MEMORY;
    pthread_mutexattr_t attr;
    if (pthread_mutexattr_init(&attr)) {
        free(c);
        return XRT_OUT_OF_MEMORY;
    }
    int mutex_error = pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    if (!mutex_error)
        mutex_error = pthread_mutex_init(&c->mutex, &attr);
    pthread_mutexattr_destroy(&attr);
    if (mutex_error) {
        free(c);
        return XRT_OUT_OF_MEMORY;
    }
    c->fd = -1;
    c->request_bytes = malloc(XRT_WIRE_MAX_BODY);
    c->reply = malloc(XRT_WIRE_MAX_BODY);
    c->decoded = calloc(1, sizeof(*c->decoded));
    if (!c->request_bytes || !c->reply || !c->decoded) {
        free(c->request_bytes);
        free(c->reply);
        free(c->decoded);
        pthread_mutex_destroy(&c->mutex);
        free(c);
        return XRT_OUT_OF_MEMORY;
    }
    struct xrt_target *t = xrt_target_create();
    if (!t) {
        free(c->request_bytes);
        free(c->reply);
        free(c->decoded);
        pthread_mutex_destroy(&c->mutex);
        free(c);
        return XRT_OUT_OF_MEMORY;
    }
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets)) {
        free(t);
        free(c->request_bytes);
        free(c->reply);
        free(c->decoded);
        pthread_mutex_destroy(&c->mutex);
        free(c);
        return XRT_PIPE_FAILED;
    }
    /* Keep dup2 sources above stdio even when a library caller closed stdin. */
    for (unsigned i = 0; i < 2; ++i)
        if (sockets[i] < 3) {
            int high = fcntl(sockets[i], F_DUPFD_CLOEXEC, 3);
            if (high < 0) {
                close(sockets[0]);
                close(sockets[1]);
                free(t);
                free(c->request_bytes);
                free(c->reply);
                free(c->decoded);
                pthread_mutex_destroy(&c->mutex);
                free(c);
                return XRT_PIPE_FAILED;
            }
            close(sockets[i]);
            sockets[i] = high;
        }
    c->child = fork();
    if (c->child < 0) {
        close(sockets[0]);
        close(sockets[1]);
        free(t);
        free(c->request_bytes);
        free(c->reply);
        free(c->decoded);
        pthread_mutex_destroy(&c->mutex);
        free(c);
        return XRT_FORK_FAILED;
    }
    if (!c->child) {
        close(sockets[0]);
        if (dup2(sockets[1], STDIN_FILENO) < 0 || dup2(sockets[1], STDOUT_FILENO) < 0)
            _exit(126);
        close(sockets[1]);
        execvp(argv[0], (char *const *)argv);
        _exit(127);
    }
    close(sockets[1]);
    c->fd = sockets[0];
    int flags = fcntl(c->fd, F_GETFL);
    if (flags < 0 || fcntl(c->fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        release_connection(c);
        free(t);
        return XRT_PIPE_FAILED;
    }
    t->connection = c;
    uint64_t machine = 0;
    enum xrt_status status = XRT_OK;
    uint64_t shortest = UINT64_MAX;
    /* Repeat after transport startup. Pick the shortest round trip so SSH
     * authentication/startup delay does not dominate the clock estimate. */
    for (unsigned probe = 0; probe < 4 && status == XRT_OK; ++probe) {
        uint8_t meta[16];
        size_t meta_size = 0;
        const uint64_t before = xrt_now();
        status = xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_HELLO,
                                                       .value = &machine,
                                                       .out = meta,
                                                       .capacity = sizeof(meta),
                                                       .length = &meta_size});
        const uint64_t after = xrt_now();
        if (status != XRT_OK)
            break;
        struct xrt_codec in = xrt_codec(meta, meta_size, true);
        uint64_t producer = 0;
        uint32_t hz = 0, page = 0;
        xrt_codec_u64(&in, &producer);
        xrt_codec_u32(&in, &hz);
        xrt_codec_u32(&in, &page);
        if (!in.ok || in.at != in.size || !hz || !page || (page & (page - 1)) || after < before) {
            status = XRT_PROTOCOL_ERROR;
            break;
        }
        if (after - before < shortest) {
            shortest = after - before;
            c->producer_ns = producer;
            c->host_ns = before + shortest / 2;
            c->uncertainty_ns = shortest / 2 + shortest % 2;
            c->tick_hz = hz;
            c->page_size = page;
        }
    }
    if (status == XRT_OK && (machine > UINT16_MAX || !xrt_arch_get((uint16_t)machine)))
        status = XRT_UNSUPPORTED_ARCHITECTURE;
    if (status == XRT_OK)
        status = create_remote(c, t);
    if (status != XRT_OK) {
        release_connection(c);
        free(t);
        return status;
    }
    *out = t;
    return XRT_OK;
}
enum xrt_status xrt_remote_destroy(struct xrt_target *t)
{
    if (__atomic_load_n(&t->remote_collectors, __ATOMIC_SEQ_CST))
        return XRT_INVALID_STATE;
    struct xrt_connection *c = t->connection;
    enum xrt_status status = xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_DESTROY});
    if (status != XRT_OK) {
        /* A broken stream forces agent cleanup. Exit bit 2 means its detach
         * failed; keep the handle in that case, as the local API does. */
        if (c->fd >= 0 || !reap(c) || !WIFEXITED(c->exit_status) ||
            (WEXITSTATUS(c->exit_status) & 2))
            return status;
    }
    unsigned left = 0;
    for (unsigned i = 0; i < XRT_RPC_TARGETS; ++i) {
        if (c->targets[i] == t)
            c->targets[i] = NULL;
        left += c->targets[i] != NULL;
    }
    free(t);
    if (!left)
        release_connection(c);
    return XRT_OK;
}
enum xrt_status xrt_remote_sync_family(struct xrt_target *t)
{
    struct xrt_connection *c = t->connection;
    for (unsigned i = 0; i < XRT_RPC_TARGETS; ++i)
        if (c->targets[i] && c->targets[i] != t) {
            enum xrt_status status =
                xrt_remote_call(c->targets[i], &(struct xrt_call){.op = XRT_RPC_VIEW});
            if (status != XRT_OK)
                return status;
        }
    return XRT_OK;
}
enum xrt_status xrt_remote_launch(struct xrt_target *t, const char *const argv[])
{
    if (!argv || !argv[0])
        return XRT_INVALID_ARGUMENT;
    uint8_t *data = malloc(XRT_RPC_DATA_MAX);
    if (!data)
        return XRT_OUT_OF_MEMORY;
    size_t count = 0, used = 0;
    while (argv[count]) {
        if (count == 255) {
            free(data);
            return XRT_TOO_MANY_ARGUMENTS;
        }
        size_t n = strnlen(argv[count], XRT_RPC_DATA_MAX - used);
        if (n == XRT_RPC_DATA_MAX - used) {
            free(data);
            return XRT_BUFFER_TOO_SMALL;
        }
        memcpy(data + used, argv[count], n + 1);
        used += n + 1;
        ++count;
    }
    enum xrt_status status = xrt_remote_call(
        t, &(struct xrt_call){.op = XRT_RPC_LAUNCH, .args = {count}, .data = data, .size = used});
    free(data);
    return status;
}
enum xrt_status xrt_remote_registers(const struct xrt_target *t, int32_t tid,
                                     struct xrt_registers *out)
{
    if (!out)
        return XRT_INVALID_ARGUMENT;
    uint8_t bytes[1024];
    size_t size = 0;
    enum xrt_status status = xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_REGISTERS,
                                                                   .args = {(uint32_t)tid},
                                                                   .out = bytes,
                                                                   .capacity = sizeof(bytes),
                                                                   .length = &size});
    if (status != XRT_OK)
        return status;
    struct xrt_registers regs = {0};
    struct xrt_codec in = xrt_codec(bytes, size, true);
    xrt_wire_registers(&in, &regs);
    if (!in.ok || in.at != in.size)
        return xrt_remote_fail(t, XRT_PROTOCOL_ERROR);
    *out = regs;
    return XRT_OK;
}
enum xrt_status xrt_remote_extended(const struct xrt_target *t, int32_t tid, struct xrt_xstate *out)
{
    if (!out)
        return XRT_INVALID_ARGUMENT;
    uint8_t *bytes = malloc(4096);
    if (!bytes)
        return XRT_OUT_OF_MEMORY;
    size_t size = 0;
    enum xrt_status status = xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_EXTENDED,
                                                                   .args = {(uint32_t)tid},
                                                                   .out = bytes,
                                                                   .capacity = 4096,
                                                                   .length = &size});
    if (status == XRT_OK) {
        struct xrt_xstate decoded = {0};
        struct xrt_codec in = xrt_codec(bytes, size, true);
        xrt_wire_xstate(&in, &decoded);
        if (!in.ok || in.at != in.size)
            status = xrt_remote_fail(t, XRT_PROTOCOL_ERROR);
        else
            *out = decoded;
    }
    free(bytes);
    return status;
}
enum xrt_status xrt_remote_capacity(const struct xrt_target *t, uint8_t *out)
{
    if (!out)
        return XRT_INVALID_ARGUMENT;
    uint64_t value = 0;
    enum xrt_status status =
        xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_WATCH_CAPACITY, .value = &value});
    if (status == XRT_OK) {
        if (value > 4)
            return xrt_remote_fail(t, XRT_PROTOCOL_ERROR);
        *out = (uint8_t)value;
    }
    return status;
}
enum xrt_status xrt_remote_adopt(struct xrt_target *t, int32_t pid, struct xrt_target *child,
                                 struct xrt_birth *birth)
{
    if (!child || !birth || child == t)
        return XRT_INVALID_ARGUMENT;
    if (child->pid || child->thread_count || child->core)
        return XRT_INVALID_STATE;
    if (!child->connection) {
        enum xrt_status status = create_remote(t->connection, child);
        if (status != XRT_OK)
            return status;
    }
    if (child->connection != t->connection)
        return XRT_INVALID_STATE;
    uint8_t bytes[256];
    size_t size = 0;
    enum xrt_status status =
        xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_ADOPT,
                                              .args = {(uint32_t)pid, child->remote_id},
                                              .out = bytes,
                                              .capacity = sizeof(bytes),
                                              .length = &size});
    if (status != XRT_OK)
        return status;
    struct xrt_birth result = {0};
    struct xrt_codec in = xrt_codec(bytes, size, true);
    xrt_wire_birth(&in, &result);
    if (!in.ok || in.at != in.size)
        return xrt_remote_fail(t, XRT_PROTOCOL_ERROR);
    status = xrt_remote_sync_family(t);
    if (status == XRT_OK)
        *birth = result;
    return status;
}
/* File bytes cross in bounded chunks. A private sealed memfd lets existing
 * host ELF/DWARF libraries use ordinary descriptors without reopening a path
 * on the host or retaining a mutable target-backed mapping. */
enum xrt_status xrt_remote_file(const struct xrt_target *t, const struct xrt_file_request *request,
                                int *out, struct xrt_file_identity *original)
{
    uint8_t *bytes = malloc(XRT_RPC_DATA_MAX);
    if (!bytes)
        return XRT_OUT_OF_MEMORY;
    struct xrt_file_request copy = *request;
    struct xrt_codec wire = xrt_codec(bytes, XRT_RPC_DATA_MAX, false);
    xrt_wire_file_request(&wire, &copy, NULL, 0);
    if (!wire.ok) {
        free(bytes);
        return XRT_INVALID_ARGUMENT;
    }
    uint8_t meta[128];
    size_t size = 0;
    uint64_t id = 0;
    enum xrt_status status = xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_FILE_OPEN,
                                                                   .data = bytes,
                                                                   .size = wire.at,
                                                                   .value = &id,
                                                                   .out = meta,
                                                                   .capacity = sizeof(meta),
                                                                   .length = &size});
    if (status != XRT_OK) {
        free(bytes);
        return status;
    }
    struct xrt_codec in = xrt_codec(meta, size, true);
    bool regular = false;
    struct xrt_file_identity identity = {0};
    xrt_codec_bool(&in, &regular);
    xrt_wire_file_identity(&in, &identity);
    int fd = -1;
    if (!in.ok || in.at != in.size || !id || id > UINT32_MAX ||
        (regular && (identity.size <= 0 || identity.size > 256 * 1024 * 1024))) {
        status = xrt_remote_fail(t, XRT_PROTOCOL_ERROR);
        goto done;
    }
    fd = memfd_create("xodb-target-file", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) {
        status = XRT_FILE_UNAVAILABLE;
        goto done;
    }
    const uint64_t limit = regular ? (uint64_t)identity.size : UINT64_C(4) * 1024 * 1024;
    uint64_t at = 0;
    for (;;) {
        size = 0;
        status = xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_FILE_READ,
                                                       .args = {id, at, XRT_RPC_DATA_MAX},
                                                       .out = bytes,
                                                       .capacity = XRT_RPC_DATA_MAX,
                                                       .length = &size});
        if (status != XRT_OK)
            break;
        if (!size) {
            if (regular && at != (uint64_t)identity.size)
                status = XRT_FILE_CHANGED;
            break;
        }
        if (size > limit - at) {
            status = XRT_FILE_LIMIT;
            break;
        }
        size_t written = 0;
        while (written < size) {
            ssize_t n = write(fd, bytes + written, size - written);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0) {
                status = XRT_FILE_UNAVAILABLE;
                break;
            }
            written += (size_t)n;
        }
        if (status != XRT_OK)
            break;
        at += size;
    }
    if (status == XRT_OK &&
        (fcntl(fd, F_ADD_SEALS, F_SEAL_SEAL | F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE) < 0 ||
         lseek(fd, 0, SEEK_SET) < 0))
        status = XRT_FILE_UNAVAILABLE;
done:;
    enum xrt_status closed =
        xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_FILE_CLOSE, .args = {id}});
    if (status == XRT_OK)
        status = closed;
    if (status == XRT_OK) {
        *out = fd;
        if (original)
            *original = identity;
    } else if (fd >= 0)
        close(fd);
    free(bytes);
    return status;
}
