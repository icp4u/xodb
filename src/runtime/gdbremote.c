#define _GNU_SOURCE 1
#include "gdbremote.h"
#include "gdb_link.h"
#include "gdb_description.h"
#include "gdb_lldb.h"
#include "target_internal.h"
#include "wire_target.h"
#include "xrt_log.h"
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

struct remote_thread { uint64_t pid, tid; int32_t local; };
struct xrt_gdb {
    struct xrt_gdb_link link;
    struct xrt_gdb_description description;
    struct xrt_gdb_info info;
    struct remote_thread threads[XRT_MAX_THREADS];
    size_t thread_count;
    struct xrt_gdb_thread_info thread_info[XRT_MAX_THREADS];
    size_t thread_info_count;
    uint64_t process, rearm;
    int32_t selected, signal_tid;
    unsigned pending_signal;
    bool vcont_signal_continue, vcont_signal_step, single_write_unavailable, unmapped_signal;
    bool multiprocess, vcont_continue, vcont_step, interrupt, step_after_rearm, detach_confirmed;
    uint8_t reply[XRT_GDB_PAYLOAD_MAX + 1];
    size_t length, last_stop_size;
    uint8_t *last_stop;
    /* LLDB extensions (Apple debugserver). native_signals: stop replies carry
     * the target's own signal numbers, not GDB's. */
    struct xrt_gdb_host host;
    bool native_signals, single_registers, bank_valid, rewatch, watch_armed[XRT_MAX_WATCHPOINTS];
    /* Registers read one p packet at a time, kept until the next resume or write. */
    char *bank;
    int32_t bank_tid, watch_tid; /* watch_tid stopped before its watched access. */
    uint8_t watch_capacity;
    bool kernel; /* No target.xml: built-in layouts and classic c/s packets. */
    /* Filled once when kernel mode is selected. Later policy reads this table
     * instead of growing more kernel branches. */
    struct {
        bool empty_list_end, nul_comm, rewind_break, break_interrupt;
        bool lazy_inventory, names_on_demand, cap_inventory, detach_after_failure;
        size_t memory_chunk;
    } quirks;
    bool inventory_capped;
};
static enum xrt_status problem(struct xrt_gdb *g, enum xrt_status status, const char *reason)
{
    snprintf(g->info.reason, sizeof(g->info.reason), "%s", reason);
    return status;
}
static int hex(unsigned c)
{
    if (c >= '0' && c <= '9') return (int)(c - '0');
    if (c >= 'a' && c <= 'f') return (int)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (int)(c - 'A' + 10);
    return -1;
}
static bool hexadecimal(const char *text, size_t n, uint64_t *out)
{
    if (!n || n > 16) return false;
    uint64_t value = 0;
    for (size_t i = 0; i < n; ++i) {
        int digit = hex((uint8_t)text[i]);
        if (digit < 0) return false;
        value = value * 16 + (unsigned)digit;
    }
    *out = value; return true;
}
static enum xrt_status query(struct xrt_gdb *g, const char *text)
{
    enum xrt_status status = xrt_gdb_exchange(&g->link, text, strlen(text),
                                              g->reply, sizeof(g->reply) - 1, &g->length);
    if (status != XRT_OK) return problem(g, status, g->link.reason);
    /* In ack mode an interrupt byte can be mistaken for a negative ACK by
     * a stub reporting a later signal. A retransmitted stop is already
     * acknowledged by the link; consume it without treating it as this
     * command's response. Compare exact bytes, and bound repetitions. */
    for (unsigned retry = 0; g->last_stop && g->length == g->last_stop_size &&
         !memcmp(g->reply, g->last_stop, g->length); ++retry) {
        if (retry == 3) return problem(g, XRT_PROTOCOL_ERROR, "Repeated GDB stop exceeds retry budget");
        status = xrt_gdb_receive(&g->link, g->reply, sizeof(g->reply) - 1, &g->length, true);
        if (status != XRT_OK) return problem(g, status, g->link.reason);
    }
    if (memchr(g->reply, 0, g->length)) return problem(g, XRT_PROTOCOL_ERROR, "NUL in GDB text response");
    g->reply[g->length] = 0;
    return XRT_OK;
}
/* A reply above the packet limit keeps the link: *cut marks its raw prefix. */
static enum xrt_status query_prefix(struct xrt_gdb *g, const char *text, bool *cut)
{
    *cut = false;
    if (strlen(text) > g->link.packet_size) return problem(g, XRT_BUFFER_TOO_SMALL, "GDB command exceeds PacketSize");
    enum xrt_status status = xrt_gdb_exchange_prefix(&g->link, text, strlen(text),
                                                     g->reply, sizeof(g->reply) - 1, &g->length);
    if (status == XRT_BUFFER_TOO_SMALL && !g->link.failed) {
        *cut = true;
        if (g->length > 512) g->length = 512;
    } else if (status != XRT_OK) return problem(g, status, g->link.reason);
    if (memchr(g->reply, 0, g->length)) return problem(g, XRT_PROTOCOL_ERROR, "NUL in GDB text response");
    g->reply[g->length] = 0;
    return XRT_OK;
}
static enum xrt_status ok(struct xrt_gdb *g, const char *command, const char *what)
{
    enum xrt_status status = query(g, command);
    if (status != XRT_OK) return status;
    if (!g->length) return problem(g, XRT_UNSUPPORTED_CONTROL, what);
    if (g->length == 2 && !memcmp(g->reply, "OK", 2)) return XRT_OK;
    if (g->reply[0] == 'E') return problem(g, XRT_PERMISSION_DENIED, what);
    return problem(g, XRT_PROTOCOL_ERROR, "Unexpected GDB command confirmation");
}
static bool feature(const char *text, const char *name)
{
    size_t length = strlen(name);
    for (const char *p = text; *p;) {
        const char *end = strchr(p, ';'); if (!end) end = p + strlen(p);
        if ((size_t)(end - p) == length && !memcmp(p, name, length)) return true;
        p = *end ? end + 1 : end;
    }
    return false;
}
static void event(struct xrt_target *t, enum xrt_event_kind kind, int32_t tid, int64_t detail)
{
    if (t->event_count == XRT_MAX_EVENTS) {
        memmove(t->events, t->events + 1, (XRT_MAX_EVENTS - 1) * sizeof(t->events[0]));
        --t->event_count;
    }
    t->events[t->event_count++] = (struct xrt_event){
        .sequence = ++t->sequence, .time_ns = xrt_now(), .tid = tid, .kind = kind, .detail = detail};
    ++t->generation;
}
static int thread_index(const struct xrt_gdb *g, int32_t local)
{
    for (size_t i = 0; i < g->thread_count; ++i)
        if (g->threads[i].local == local) return (int)i;
    return -1;
}
static bool thread_id(const char *text, size_t length, uint64_t *pid, uint64_t *tid)
{
    *pid = 0;
    if (length && text[0] == 'p') {
        const char *dot = memchr(text, '.', length);
        if (!dot || !hexadecimal(text + 1, (size_t)(dot - text - 1), pid) || !*pid) return false;
        length -= (size_t)(dot + 1 - text); text = dot + 1;
    }
    return hexadecimal(text, length, tid) && *tid && *tid <= UINT32_MAX && *pid <= UINT32_MAX;
}
/* A negative KGDB id is a per-CPU shadow (CPU 0 is -2). Snapshots reject a
 * non-positive tid, so the local id is a positive alias of that magnitude. */
static int32_t kernel_local(uint64_t tid)
{
    if (!tid || tid > UINT32_MAX) return 0;
    if (tid <= (uint64_t)INT32_MAX) return (int32_t)tid;
    int32_t signed_id = (int32_t)tid;
    if (signed_id >= -1 || signed_id == INT32_MIN) return 0;
    uint32_t magnitude = (uint32_t)(-(int64_t)signed_id);
    if (!magnitude || magnitude > 4096 || (uint32_t)0x60000000u + magnitude > (uint32_t)INT32_MAX)
        return 0;
    return (int32_t)(0x60000000u + magnitude);
}
static void apply_kernel_quirks(struct xrt_gdb *g)
{
    g->kernel = true;
    g->info.kernel = true;
    g->quirks.empty_list_end = true;
    g->quirks.nul_comm = true;
    g->quirks.break_interrupt = true;
    g->quirks.lazy_inventory = true;
    g->quirks.names_on_demand = true;
    g->quirks.cap_inventory = true;
    g->quirks.detach_after_failure = true;
    g->quirks.memory_chunk = 511;
}
static void note_capped(struct xrt_gdb *g)
{
    if (g->inventory_capped) return;
    g->inventory_capped = true;
    xrt_log(XRT_LOG_WARN, XRT_LOG_RUNTIME,
            "xodb: KGDB thread list exceeds the table; later tasks are not shown.\n");
}
bool xrt_gdb_detach_holds_link(const struct xrt_gdb *g)
{
    return g && g->quirks.detach_after_failure && g->link.fd >= 0;
}
static enum xrt_status remember_thread(struct xrt_gdb *g, struct xrt_target *t,
                                       uint64_t pid, uint64_t tid, int32_t *local)
{
    if (pid && g->process && pid != g->process)
        return problem(g, XRT_UNSUPPORTED_PROCESS_FOLLOWING, "Multiple GDB processes are not supported");
    if (pid) g->process = pid;
    for (size_t i = 0; i < g->thread_count; ++i)
        if (g->threads[i].pid == pid && g->threads[i].tid == tid) {
            *local = g->threads[i].local;
            return xrt_thread_index(t, *local) >= 0 ? XRT_OK : xrt_add_thread(t, *local, false);
        }
    if (g->thread_count == XRT_MAX_THREADS) return XRT_TOO_MANY_THREADS;
    int32_t id;
    if (g->kernel) {
        id = kernel_local(tid);
        if (!id || thread_index(g, id) >= 0)
            return problem(g, XRT_PROTOCOL_ERROR, "KGDB thread id is not a task or a per-CPU shadow");
    } else {
        id = tid <= INT_MAX ? (int32_t)tid : 1;
        while (thread_index(g, id) >= 0) {
            if (id == INT_MAX) return XRT_TOO_MANY_THREADS;
            ++id;
        }
    }
    g->threads[g->thread_count++] = (struct remote_thread){pid, tid, id};
    enum xrt_status status = xrt_add_thread(t, id, false);
    if (status != XRT_OK) { --g->thread_count; return status; }
    *local = id;
    if (!t->pid) t->pid = g->process && g->process <= INT_MAX ? (int32_t)g->process : id;
    return XRT_OK;
}
static void format_thread(const struct xrt_gdb *g, const struct remote_thread *thread,
                           char *out, size_t size)
{
    if (g->multiprocess && thread->pid)
        snprintf(out, size, "p%" PRIx64 ".%" PRIx64, thread->pid, thread->tid);
    else snprintf(out, size, "%" PRIx64, thread->tid);
}
static enum xrt_status select_thread(struct xrt_gdb *g, int32_t tid)
{
    int i = thread_index(g, tid);
    if (i < 0) return XRT_UNKNOWN_THREAD;
    if (g->selected == tid) return XRT_OK;
    char id[40], command[48]; format_thread(g, &g->threads[i], id, sizeof(id));
    snprintf(command, sizeof(command), "Hg%s", id);
    enum xrt_status status = ok(g, command, "GDB thread selection unavailable");
    if (status == XRT_OK) g->selected = tid;
    return status;
}
static enum xrt_status threads(struct xrt_gdb *g, struct xrt_target *t)
{
    /* Finish the bounded inventory before changing either table. Old and new
     * inventories may each be full, with no threads in common. */
    struct remote_thread present[XRT_MAX_THREADS];
    size_t count = 0;
    enum xrt_status status = query(g, "qfThreadInfo");
    if (status != XRT_OK) return status;
    if (!g->length || g->reply[0] == 'E') {
        g->info.unsupported |= XRT_GDB_CAP_THREADS;
        g->info.supported &= ~XRT_GDB_CAP_THREADS;
        return XRT_OK; /* A stop may still identify one thread. */
    }
    unsigned pages = 0;
    while (g->length && g->reply[0] == 'm') {
        /* A hostile stub that never ends the list is a protocol error. A long
         * real list is capped below and does not fail the connection. */
        if (++pages > 8192) return XRT_PROTOCOL_ERROR;
        char *p = (char *)g->reply + 1;
        if (!*p) return XRT_PROTOCOL_ERROR;
        while (*p) {
            char *end = strchr(p, ','); if (!end) end = p + strlen(p);
            uint64_t pid, tid;
            if (!thread_id(p, (size_t)(end - p), &pid, &tid)) return XRT_PROTOCOL_ERROR;
            if (pid && g->process && pid != g->process)
                return problem(g, XRT_UNSUPPORTED_PROCESS_FOLLOWING, "Multiple GDB processes are not supported");
            if (pid) g->process = pid;
            for (size_t i = 0; i < count; ++i)
                if (present[i].pid == pid && present[i].tid == tid) return XRT_PROTOCOL_ERROR;
            if (count == XRT_MAX_THREADS) {
                if (!g->quirks.cap_inventory) return XRT_TOO_MANY_THREADS;
                note_capped(g);
            } else present[count++] = (struct remote_thread){.pid = pid, .tid = tid};
            p = *end ? end + 1 : end;
        }
        status = query(g, "qsThreadInfo"); if (status != XRT_OK) return status;
    }
    /* kgdb ends the list with an empty reply rather than "l". */
    if (!(g->length == 1 && g->reply[0] == 'l') && !(g->quirks.empty_list_end && !g->length))
        return XRT_PROTOCOL_ERROR;
    size_t kept = 0;
    for (size_t i = 0; i < g->thread_count; ++i) {
        bool found = false;
        for (size_t j = 0; j < count; ++j)
            if (g->threads[i].pid == present[j].pid && g->threads[i].tid == present[j].tid) {
                found = true; break;
            }
        if (found) g->threads[kept++] = g->threads[i];
        else if (g->selected == g->threads[i].local) g->selected = 0;
    }
    g->thread_count = kept;
    for (size_t i = t->thread_count; i > 0; --i) {
        size_t at = i - 1;
        if (thread_index(g, t->threads[at].tid) < 0) {
            event(t, XRT_EVENT_THREAD_EXITING, t->threads[at].tid, 0);
            memmove(t->threads + at, t->threads + at + 1, (t->thread_count - at - 1) * sizeof(t->threads[0]));
            --t->thread_count;
        }
    }
    for (size_t i = 0; i < count; ++i) {
        int32_t local;
        status = remember_thread(g, t, present[i].pid, present[i].tid, &local);
        if (status != XRT_OK) return status;
    }
    g->info.supported |= XRT_GDB_CAP_THREADS;
    g->info.unsupported &= ~XRT_GDB_CAP_THREADS;
    return XRT_OK;
}
static enum xrt_status refresh_thread_info(struct xrt_gdb *g)
{
    g->thread_info_count = 0;
    if (g->host.os != XRT_GDB_OS_DARWIN || (g->info.unsupported & XRT_GDB_CAP_THREAD_INFO)) return XRT_OK;
    bool cut;
    enum xrt_status status = query_prefix(g, "jThreadsInfo", &cut);
    if (status != XRT_OK) return status;
    g->info.supported &= ~XRT_GDB_CAP_THREAD_INFO;
    g->info.failed &= ~XRT_GDB_CAP_THREAD_INFO;
    if (!g->length) {
        g->info.unsupported |= XRT_GDB_CAP_THREAD_INFO;
        return XRT_OK;
    }
    size_t count = 0;
    status = cut ? XRT_BUFFER_TOO_SMALL :
        xrt_gdb_threads_parse((const char *)g->reply, g->length, g->thread_info, XRT_MAX_THREADS, &count);
    if (status != XRT_OK) {
        g->info.failed |= XRT_GDB_CAP_THREAD_INFO;
        /* This optional metadata cannot change authoritative thread/control
         * state. Discard partial rows and keep the framed connection usable. */
        return XRT_OK;
    }
    g->thread_info_count = count;
    for (size_t i = 0; i < count; ++i) {
        char command[80]; bool extended_cut;
        snprintf(command,sizeof command,"jThreadExtendedInfo:{\"thread\":%" PRIu64 "}",
                 g->thread_info[i].remote_tid);
        status=query_prefix(g,command,&extended_cut);
        if (status!=XRT_OK) return status;
        /* Unsupported: do not pay one more round trip per thread at this stop. */
        if (!g->length) break;
        if (g->reply[0]=='E') continue;
        if (extended_cut) {
            g->thread_info_count=0;
            g->info.failed|=XRT_GDB_CAP_THREAD_INFO;
            return XRT_OK;
        }
        uint64_t queue=0;
        if (xrt_gdb_thread_extended_parse((const char *)g->reply,g->length,&queue)!=XRT_OK) {
            g->thread_info_count=0;
            g->info.failed|=XRT_GDB_CAP_THREAD_INFO;
            return XRT_OK;
        }
        if (queue) {
            g->thread_info[i].dispatch_queue=queue;
            g->thread_info[i].has_dispatch_queue=true;
        }
    }
    g->info.supported |= XRT_GDB_CAP_THREAD_INFO;
    return XRT_OK;
}
static enum xrt_status cache_kernel_name(struct xrt_gdb *g, uint64_t remote_tid)
{
    if (!g->length || g->reply[0] == 'E') return XRT_TASK_INFO_UNAVAILABLE;
    if (g->length % 2 || g->length / 2 >= sizeof(g->thread_info[0].name)) {
        g->thread_info_count = 0;
        g->info.failed |= XRT_GDB_CAP_THREAD_INFO;
        return XRT_OK;
    }
    char decoded[128];
    size_t n = 0, hex_n = g->length / 2;
    bool bad = false;
    for (size_t b = 0; b < hex_n; ++b) {
        int hi = hex(g->reply[2 * b]), lo = hex(g->reply[2 * b + 1]);
        unsigned char c;
        if (hi < 0 || lo < 0) { bad = true; break; }
        c = (unsigned char)(hi * 16 + lo);
        /* kgdb sends the 16-byte comm with its NUL padding. */
        if (g->quirks.nul_comm && !c) break;
        if (c < 0x20 || c > 0x7e) { bad = true; break; }
        decoded[n++] = (char)c;
    }
    if (bad) {
        g->thread_info_count = 0;
        g->info.failed |= XRT_GDB_CAP_THREAD_INFO;
        return XRT_OK;
    }
    struct xrt_gdb_thread_info *info = NULL;
    for (size_t i = 0; i < g->thread_info_count; ++i)
        if (g->thread_info[i].remote_tid == remote_tid) { info = &g->thread_info[i]; break; }
    if (!info) {
        if (g->thread_info_count == XRT_MAX_THREADS) return XRT_OK;
        info = &g->thread_info[g->thread_info_count++];
    }
    memset(info, 0, sizeof(*info));
    info->remote_tid = remote_tid;
    info->has_name = true;
    memcpy(info->name, decoded, n);
    info->name[n] = 0;
    g->info.supported |= XRT_GDB_CAP_THREAD_INFO;
    g->info.unsupported &= ~XRT_GDB_CAP_THREAD_INFO;
    return XRT_OK;
}
static enum xrt_status kernel_names(struct xrt_gdb *g)
{
    if (!g->kernel) return XRT_OK;
    g->thread_info_count = 0;
    for (size_t i = 0; i < g->thread_count; ++i) {
        char id[40], command[80];
        format_thread(g, &g->threads[i], id, sizeof(id));
        snprintf(command, sizeof(command), "qThreadExtraInfo,%s", id);
        enum xrt_status status = query(g, command);
        if (status != XRT_OK) return status;
        status = cache_kernel_name(g, g->threads[i].tid);
        if (status != XRT_OK && status != XRT_TASK_INFO_UNAVAILABLE) return status;
        if (g->info.failed & XRT_GDB_CAP_THREAD_INFO) return XRT_OK;
    }
    return XRT_OK;
}
static enum xrt_status annex(void *ctx, const char *name, char **out, size_t *size)
{
    struct xrt_gdb *g = ctx;
    char *text = malloc(XRT_GDB_XML_MAX + 1);
    if (!text) return XRT_OUT_OF_MEMORY;
    size_t used = 0;
    for (unsigned n = 0; n < 1024; ++n) {
        char command[256];
        size_t chunk = g->link.packet_size > 4096 ? 4096 : g->link.packet_size - 1;
        snprintf(command, sizeof(command), "qXfer:features:read:%s:%zx,%zx", name, used, chunk);
        enum xrt_status status = query(g, command);
        if (status != XRT_OK) { free(text); return status; }
        if (!g->length || (g->reply[0] != 'm' && g->reply[0] != 'l')) {
            free(text); return problem(g, XRT_REGISTER_UNAVAILABLE, "GDB target.xml unavailable");
        }
        if (g->length - 1 > chunk || g->length - 1 > XRT_GDB_XML_MAX - used ||
            (g->reply[0] == 'm' && g->length == 1)) {
            free(text); return XRT_PROTOCOL_ERROR;
        }
        memcpy(text + used, g->reply + 1, g->length - 1); used += g->length - 1;
        if (g->reply[0] == 'l') {
            text[used] = 0; *out = text; *size = used; return XRT_OK;
        }
    }
    free(text); return XRT_BUFFER_TOO_SMALL;
}
static enum xrt_status registers(struct xrt_gdb *g, struct xrt_target *t,
                                  int32_t tid, struct xrt_registers *out)
{
    if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
    enum xrt_status status = select_thread(g, tid);
    if (status != XRT_OK) return status;
    if (!g->single_registers) {
        status = query(g, "g");
        if (status != XRT_OK) return status;
        if (g->length && g->reply[0] == 'E') return XRT_REGISTER_UNAVAILABLE;
        if (g->length) return xrt_gdb_description_decode(&g->description, g->reply, g->length, out);
        g->single_registers = true; /* debugserver has no g packet. */
    }
    /* Build the same hexadecimal bank from p packets, for the registers this
     * client maps. Everything else stays unavailable ('x'). */
    size_t bytes = 0;
    for (unsigned i = 0; i < g->description.arch->register_count; ++i) {
        const struct xrt_gdb_register *r =
            xrt_gdb_description_register(&g->description, &g->description.arch->registers[i]);
        if (r && r->offset + r->bytes > bytes) bytes = r->offset + r->bytes;
    }
    if (!bytes || bytes > XRT_GDB_PAYLOAD_MAX / 2) return XRT_REGISTER_UNAVAILABLE;
    if (!g->bank && !(g->bank = malloc(XRT_GDB_PAYLOAD_MAX))) return XRT_OUT_OF_MEMORY;
    if (!g->bank_valid || g->bank_tid != tid) {
        g->bank_valid = false;
        memset(g->bank, 'x', 2 * bytes);
        for (unsigned i = 0; i < g->description.arch->register_count; ++i) {
            const struct xrt_gdb_register *r =
                xrt_gdb_description_register(&g->description, &g->description.arch->registers[i]);
            if (!r) continue;
            char command[24]; snprintf(command, sizeof(command), "p%x", r->number);
            status = query(g, command);
            if (status != XRT_OK) return status;
            if (!g->length || g->reply[0] == 'E') continue;
            if (g->length != 2 * (size_t)r->bytes) return XRT_UNEXPECTED_REGISTER_SIZE;
            memcpy(g->bank + 2 * (size_t)r->offset, g->reply, g->length);
        }
        g->bank_tid = tid; g->bank_valid = true;
    }
    memcpy(g->reply, g->bank, 2 * bytes);
    g->length = 2 * bytes; g->reply[g->length] = 0;
    return xrt_gdb_description_decode(&g->description, g->reply, g->length, out);
}
static enum xrt_status read_memory(struct xrt_gdb *g, struct xrt_target *t,
                                    uint64_t address, void *out, size_t size, size_t *count)
{
    *count = 0;
    if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
    if (size > XRT_RPC_DATA_MAX || size > UINT64_MAX - address) return XRT_INVALID_ARGUMENT;
    while (*count < size) {
        size_t chunk = size - *count;
        if (chunk > (g->link.packet_size - 1) / 2) chunk = (g->link.packet_size - 1) / 2;
        if (g->quirks.memory_chunk && chunk > g->quirks.memory_chunk) chunk = g->quirks.memory_chunk;
        char command[64]; snprintf(command, sizeof(command), "m%" PRIx64 ",%zx", address + *count, chunk);
        enum xrt_status status = query(g, command);
        if (status != XRT_OK) return status;
        if (!g->length || g->reply[0] == 'E') return XRT_MEMORY_UNREADABLE;
        if (g->length % 2 || g->length > chunk * 2) return XRT_PROTOCOL_ERROR;
        size_t got = g->length / 2;
        for (size_t i = 0; i < got; ++i) {
            int hi = hex(g->reply[2 * i]), lo = hex(g->reply[2 * i + 1]);
            if (hi < 0 || lo < 0) return XRT_PROTOCOL_ERROR;
            ((uint8_t *)out)[*count + i] = (uint8_t)(hi * 16 + lo);
        }
        *count += got;
        if (got < chunk) return XRT_OK;
    }
    return XRT_OK;
}
static enum xrt_status write_memory(struct xrt_gdb *g, struct xrt_target *t,
                                     uint64_t address, const uint8_t *data, size_t size)
{
    if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
    if (!size || size > XRT_RPC_DATA_MAX || size > UINT64_MAX - address) return XRT_INVALID_ARGUMENT;
    char *command = malloc(g->link.packet_size + 1);
    uint8_t *verify = malloc(g->link.packet_size);
    if (!command || !verify) { free(command); free(verify); return XRT_OUT_OF_MEMORY; }
    enum xrt_status status = XRT_OK;
    static const char digits[] = "0123456789abcdef";
    for (size_t at = 0; at < size;) {
        size_t chunk = size - at, max = (g->link.packet_size - 64) / 2;
        if (g->quirks.memory_chunk && max > g->quirks.memory_chunk) max = g->quirks.memory_chunk;
        if (chunk > max) chunk = max;
        int n = snprintf(command, 64, "M%" PRIx64 ",%zx:", address + at, chunk);
        for (size_t i = 0; i < chunk; ++i) {
            command[n + 2 * i] = digits[data[at + i] >> 4];
            command[n + 2 * i + 1] = digits[data[at + i] & 15];
        }
        command[n + 2 * chunk] = 0;
        ++t->generation; /* Sending a mutation invalidates even on E/timeout. */
        status = ok(g, command, "GDB memory write unconfirmed");
        if (status != XRT_OK) { status = XRT_PARTIAL_MEMORY_WRITE; break; }
        size_t count;
        status = read_memory(g, t, address + at, verify, chunk, &count);
        if (status != XRT_OK || count != chunk || memcmp(data + at, verify, chunk)) {
            status = XRT_PARTIAL_MEMORY_WRITE; break;
        }
        at += chunk;
    }
    if (status == XRT_OK) event(t, XRT_EVENT_MEMORY_WRITTEN, t->pid, (int64_t)size);
    free(command); free(verify); return status;
}
static enum xrt_status write_register(struct xrt_gdb *g, struct xrt_target *t,
                                       int32_t tid, const char *name, size_t length,
                                       uint64_t value, uint64_t *packed)
{
    if (packed) *packed = 0;
    if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
    const struct xrt_register_desc *desc = xrt_arch_register(t->arch->machine, name, length);
    if (!desc) return XRT_UNKNOWN_REGISTER;
    const struct xrt_gdb_register *r = xrt_gdb_description_register(&g->description, desc);
    if (!r) return XRT_REGISTER_UNAVAILABLE;
    enum xrt_status status = xrt_register_admit(desc, value);
    if (status != XRT_OK) return status;
    if (r->bytes < 8 && value >> (r->bytes * 8)) return XRT_INVALID_ARGUMENT;
    if (desc->role == XRT_ROLE_PC && t->arch->machine == XRT_AARCH64 && value % 4) return XRT_INVALID_ADDRESS;
    status = select_thread(g, tid); if (status != XRT_OK) return status;
    char command[80]; int n = snprintf(command, sizeof(command), "P%x=", r->number);
    static const char digits[] = "0123456789abcdef";
    for (uint32_t i = 0; i < r->bytes; ++i) {
        uint8_t byte = (uint8_t)(value >> (8 * (t->arch->little_endian ? i : r->bytes - i - 1)));
        command[n + 2 * i] = digits[byte >> 4]; command[n + 2 * i + 1] = digits[byte & 15];
    }
    command[n + 2 * r->bytes] = 0;
    struct xrt_registers before;
    status = registers(g, t, tid, &before);
    if (status != XRT_OK) return status;
    uint64_t previous;
    if (xrt_registers_value_desc(&before, desc, &previous) != XRT_OK) return XRT_REGISTER_UNAVAILABLE;
    size_t bank_size = g->length;
    char *expected = malloc(bank_size + 2);
    if (!expected) return XRT_OUT_OF_MEMORY;
    expected[0] = 'G'; memcpy(expected + 1, g->reply, bank_size); expected[bank_size + 1] = 0;
    memcpy(expected + 1 + 2 * r->offset, command + n, 2 * r->bytes);
    g->bank_valid = false;
    if (!g->single_write_unavailable) {
        if (packed) *packed = 1;
        ++t->generation;
        status = ok(g, command, "GDB register write unconfirmed");
        if (status == XRT_UNSUPPORTED_CONTROL) g->single_write_unavailable = true;
        else if (status != XRT_OK) { free(expected); return XRT_PARTIAL_REGISTER_WRITE; }
    }
    if (g->single_write_unavailable) {
        /* Some gdbservers omit P and expose an unavailable suffix (e.g.
         * shadow-stack state) in g. Send only the known G prefix, which that
         * server may accept; never substitute values for unavailable bytes.
         * An unavailable hole cannot be represented this way and is refused. */
        size_t prefix = bank_size;
        const char *unknown = memchr(expected + 1, 'x', bank_size);
        if (unknown) {
            prefix = (size_t)(unknown - expected - 1);
            for (size_t i = prefix; i < bank_size; ++i) if (expected[i + 1] != 'x') {
                free(expected);
                return problem(g, XRT_REGISTER_UNAVAILABLE, "GDB full-register write has an unavailable hole");
            }
        }
        if (prefix + 1 > g->link.packet_size) { free(expected); return XRT_BUFFER_TOO_SMALL; }
        char saved = expected[prefix + 1]; expected[prefix + 1] = 0;
        if (packed) *packed = 1;
        ++t->generation;
        status = ok(g, expected, "GDB register-bank prefix write unconfirmed");
        expected[prefix + 1] = saved;
        if (status == XRT_UNSUPPORTED_CONTROL) {
            g->info.unsupported |= XRT_GDB_CAP_REGISTER_WRITE; free(expected); return status;
        }
        if (status != XRT_OK) { free(expected); return XRT_PARTIAL_REGISTER_WRITE; }
    }
    struct xrt_registers verify; uint64_t actual;
    status = registers(g, t, tid, &verify);
    bool confirmed = status == XRT_OK && bank_size == g->length &&
        xrt_registers_value_desc(&verify, desc, &actual) == XRT_OK && actual == value;
    if (confirmed) for (size_t i = 0; i < bank_size; ++i) {
        unsigned want = (unsigned char)expected[i + 1], got = g->reply[i];
        if (want == 'x' ? got != 'x' : hex(want) != hex(got)) { confirmed = false; break; }
    }
    free(expected);
    if (!confirmed) return XRT_PARTIAL_REGISTER_WRITE;
    if (packed) *packed = 0x101;
    g->info.supported |= XRT_GDB_CAP_REGISTER_WRITE;
    event(t, XRT_EVENT_REGISTER_WRITTEN, tid, 0);
    return XRT_OK;
}

static enum xrt_status breakpoint_packet(struct xrt_gdb *g, struct xrt_target *t,
                                          struct xrt_breakpoint *bp, bool enable)
{
    char command[96];
    snprintf(command, sizeof(command), "%c0,%" PRIx64 ",%x", enable ? 'Z' : 'z', bp->address, bp->width);
    ++t->generation;
    enum xrt_status status = ok(g, command, "GDB software breakpoint unconfirmed");
    if (status == XRT_OK) {
        bp->patched = enable;
        if (t->plant_cleanup.active && t->plant_cleanup.address == bp->address)
            t->plant_cleanup.active = 0;
        g->info.supported |= XRT_GDB_CAP_SOFTWARE_BREAK;
    } else if (status == XRT_UNSUPPORTED_CONTROL) g->info.unsupported |= XRT_GDB_CAP_SOFTWARE_BREAK;
    else {
        t->plant_cleanup.active = 1; t->plant_cleanup.address = bp->address;
        t->plant_cleanup.width = bp->width;
    }
    return status;
}
static enum xrt_status breakpoint_resolve(struct xrt_gdb *g, struct xrt_target *t,
                                           struct xrt_breakpoint *bp, uint64_t address)
{
    if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
    if (!bp->pending) return XRT_BREAKPOINT_ALREADY_RESOLVED;
    uint8_t width = t->arch->trap_size;
    if (!xrt_arch_breakpoint_valid(t->arch->machine, address, width)) return XRT_INVALID_BREAKPOINT_ADDRESS;
    for (size_t i = 0; i < t->breakpoint_count; ++i)
        if (&t->breakpoints[i] != bp && !t->breakpoints[i].pending && t->breakpoints[i].address == address)
            return XRT_BREAKPOINT_LOCATION_ALREADY_USED;
    uint8_t original[4]; size_t count;
    enum xrt_status status = read_memory(g, t, address, original, width, &count);
    if (status != XRT_OK || count != width) return status != XRT_OK ? status : XRT_MEMORY_UNREADABLE;
    if (!memcmp(original, t->arch->trap, width)) return XRT_EXISTING_TRAP_INSTRUCTION;
    bp->address = address; bp->width = width; bp->alignment = t->arch->trap_alignment;
    bp->isa_mode = t->arch->isa_mode; memcpy(bp->original, original, width);
    memcpy(bp->planted, t->arch->trap, width);
    if (bp->enabled) {
        status = breakpoint_packet(g, t, bp, true);
        if (status != XRT_OK) {
            return status;
        }
    }
    bp->pending = false;
    event(t, XRT_EVENT_BREAKPOINT_SET, t->pid, (int64_t)bp->id);
    return XRT_OK;
}
static enum xrt_status cleanup_plant(struct xrt_gdb *g, struct xrt_target *t)
{
    if (!t->plant_cleanup.active) return XRT_OK;
    struct xrt_breakpoint bp = {.address = t->plant_cleanup.address, .width = t->plant_cleanup.width};
    enum xrt_status status = breakpoint_packet(g, t, &bp, false);
    if (status == XRT_OK) {
        t->plant_cleanup.active = 0;
        for (size_t i = 0; i < t->breakpoint_count; ++i)
            if (t->breakpoints[i].address == bp.address) t->breakpoints[i].patched = false;
    }
    return status;
}
static enum xrt_status watch_packet(struct xrt_gdb *g, struct xrt_target *t, unsigned slot, bool enable)
{
    const struct xrt_watchpoint *watch = &t->watchpoints[slot];
    if (g->watch_armed[slot] == enable) return XRT_OK;
    char command[64];
    snprintf(command, sizeof(command), "%c%c,%" PRIx64 ",%x", enable ? 'Z' : 'z',
             watch->kind == XRT_WATCH_WRITE ? '2' : '4', watch->address, watch->length);
    ++t->generation;
    enum xrt_status status = ok(g, command, g->kernel ?
        "KGDB hardware watchpoint was refused by the stub" :
        "GDB hardware watchpoint unconfirmed");
    if (status == XRT_OK) g->watch_armed[slot] = enable;
    return status;
}
static enum xrt_status watch_all(struct xrt_gdb *g, struct xrt_target *t, bool enable)
{
    for (unsigned i = 0; i < XRT_MAX_WATCHPOINTS; ++i)
        if (t->watchpoints[i].present) {
            enum xrt_status status = watch_packet(g, t, i, enable);
            if (status != XRT_OK) return status;
        }
    return XRT_OK;
}
/* The stub stops before the access: the value read here is the old one.
 * Returns whether a watchpoint of this client covers the address. */
static bool publish_watch(struct xrt_gdb *g, struct xrt_target *t, int32_t tid,
                          bool known_pc, uint64_t pc, uint64_t address)
{
    for (unsigned i = 0; i < XRT_MAX_WATCHPOINTS; ++i) {
        struct xrt_watchpoint *watch = &t->watchpoints[i];
        if (!watch->present || address < watch->address || address - watch->address >= watch->length)
            continue;
        uint8_t bytes[8] = {0}; size_t count = 0; uint64_t value = 0;
        bool valid = read_memory(g, t, watch->address, bytes, watch->length, &count) == XRT_OK &&
            count == watch->length;
        for (unsigned n = 0; n < watch->length; ++n) value |= (uint64_t)bytes[n] << (8 * n);
        event(t, XRT_EVENT_WATCHPOINT_HIT, tid, (int64_t)watch->id);
        struct xrt_event *hit = &t->events[t->event_count - 1];
        hit->pc = known_pc ? pc : 0; hit->pc_known = known_pc;
        hit->address = watch->address; hit->size = watch->length;
        hit->has_trap = true; hit->trap_pc = hit->pc; hit->trap_address = address;
        hit->watch_phase = 2; /* The access has not completed. */
        hit->before = value; hit->before_valid = valid;
        if (valid) watch->previous = value;
        return true;
    }
    return false;
}
static enum xrt_status send_run(struct xrt_gdb *g, struct xrt_target *t,
                                 int32_t tid, bool step)
{
    char command[96], id[40];
    if (g->kernel) {
        if (g->pending_signal)
            return problem(g, XRT_UNSUPPORTED_CONTROL, "KGDB cannot deliver a signal; suppress it before resuming");
        int index = thread_index(g, tid);
        if (index < 0) return XRT_UNKNOWN_THREAD;
        format_thread(g, &g->threads[index], id, sizeof(id));
        char select[48];
        snprintf(select, sizeof(select), "Hc%s", step ? id : "0");
        enum xrt_status selected = ok(g, select, step ? "KGDB step thread selection unavailable" :
                                      "KGDB continue thread selection unavailable");
        if (selected != XRT_OK) return selected;
        snprintf(command, sizeof(command), "%s", step ? "s" : "c");
    } else if (step && !g->vcont_step)
        return problem(g, XRT_UNSUPPORTED_CONTROL, "GDB stub does not support vCont;s");
    else {
    int index = thread_index(g, tid);
    if (index < 0) return XRT_UNKNOWN_THREAD;
    format_thread(g, &g->threads[index], id, sizeof(id));
    if (g->pending_signal) {
        if (g->signal_tid != tid) return problem(g, XRT_UNSUPPORTED_CONTROL, "Select the pending-signal thread before resuming");
        if (step && !g->vcont_signal_step)
            return problem(g, XRT_UNSUPPORTED_CONTROL, "GDB stub does not support signal-delivering step");
        if (step) snprintf(command, sizeof(command), "vCont;S%02x:%s", g->pending_signal, id);
        else if (g->vcont_signal_continue)
            snprintf(command, sizeof(command), "vCont;C%02x:%s;c", g->pending_signal, id);
        else {
            enum xrt_status selected = select_thread(g, tid); if (selected != XRT_OK) return selected;
            snprintf(command, sizeof(command), "C%02x", g->pending_signal);
        }
    } else if (step) snprintf(command, sizeof(command), "vCont;s:%s", id);
    else snprintf(command, sizeof(command), "%s", g->vcont_continue ? "vCont;c" : "c");
    }
    ++t->generation;
    enum xrt_status status = xrt_gdb_send(&g->link, command, strlen(command));
    if (status != XRT_OK) return problem(g, status, g->link.reason);
    g->pending_signal = 0; g->bank_valid = false;
    if (!step || tid == g->watch_tid) g->watch_tid = 0;
    t->state = XRT_RUNNING; t->want_run = !step; t->stepping = step;
    for (size_t i = 0; i < t->thread_count; ++i) {
        t->threads[i].state = step && t->threads[i].tid != tid ? XRT_STOPPED : XRT_RUNNING;
        t->threads[i].signal = 0;
    }
    event(t, step ? XRT_EVENT_STEP_STARTED : XRT_EVENT_CONTINUED, tid, 0);
    return XRT_OK;
}
static enum xrt_status admit_step(struct xrt_gdb *g, struct xrt_target *t, uint64_t pc)
{
    if (!g->vcont_step && !g->kernel) return problem(g, XRT_UNSUPPORTED_CONTROL, "GDB stub does not support vCont;s");
    if (t->arch->machine == XRT_AARCH64) {
        uint8_t bytes[4]; size_t count;
        enum xrt_status status = read_memory(g, t, pc, bytes, sizeof(bytes), &count);
        if (status != XRT_OK || count != sizeof(bytes)) return status != XRT_OK ? status : XRT_MEMORY_UNREADABLE;
        uint32_t word = (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
                        (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
        if ((word & UINT32_C(0x3f000000)) == UINT32_C(0x08000000))
            return problem(g, XRT_UNSUPPORTED_CONTROL, "GDB stepping across AArch64 exclusive/ordered memory instructions is unsupported");
    }
    return XRT_OK;
}
static enum xrt_status resume(struct xrt_gdb *g, struct xrt_target *t, int32_t tid, bool step)
{
    if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
    if (t->plant_cleanup.active)
        return problem(g, XRT_INVALID_STATE, "GDB breakpoint state is unconfirmed; retry its operation or detach");
    if (g->unmapped_signal)
        return problem(g, XRT_UNSUPPORTED_CONTROL, "Suppress the unmapped GDB signal explicitly before resuming");
    enum xrt_status status;
    int i = xrt_thread_index(t, tid);
    if (i < 0) return XRT_UNKNOWN_THREAD;
    if (step && g->kernel && tid != g->info.stop_tid)
        return problem(g, XRT_UNSUPPORTED_CONTROL, "KGDB steps only the CPU that entered the debugger");
    struct xrt_registers regs; uint64_t pc;
    status = registers(g, t, tid, &regs);
    if (status != XRT_OK || xrt_registers_pc(&regs, &pc) != XRT_OK)
        return status != XRT_OK ? status : XRT_REGISTER_UNAVAILABLE;
    if (step) { status = admit_step(g, t, pc); if (status != XRT_OK) return status; }
    /* A breakpoint at this PC, or a watched access this thread stopped
     * before, is lifted for one hidden step and restored at its stop. */
    struct xrt_breakpoint *here = NULL;
    for (size_t n = 0; n < t->breakpoint_count && !here; ++n) {
        struct xrt_breakpoint *bp = &t->breakpoints[n];
        if (!bp->pending && bp->enabled && bp->patched && bp->address == pc) here = bp;
    }
    const bool watch = g->watch_tid == tid;
    if (!here && !watch) return send_run(g, t, tid, step);
    if (!step) { status = admit_step(g, t, pc); if (status != XRT_OK) return status; }
    if (here) { status = breakpoint_packet(g, t, here, false); if (status != XRT_OK) return status; }
    if (watch) status = watch_all(g, t, false);
    if (status == XRT_OK) {
        g->rearm = here ? here->id : 0; g->rewatch = watch; g->step_after_rearm = step;
        status = send_run(g, t, tid, true);
        if (status == XRT_OK) return XRT_OK;
    }
    g->rearm = 0; g->rewatch = false;
    enum xrt_status restored = here ? breakpoint_packet(g, t, here, true) : XRT_OK;
    if (watch && restored == XRT_OK) restored = watch_all(g, t, true);
    return restored != XRT_OK ? restored : status;
}
static int target_signal(const struct xrt_gdb *g, unsigned remote)
{
    /* A stub announcing native-signals reports the target system's own
     * numbers; info.os names the table that displays them. */
    if (g->native_signals && g->host.os != XRT_GDB_OS_UNKNOWN)
        return remote < (g->host.os == XRT_GDB_OS_DARWIN ? 32u : 65u) ? (int)remote : 0;
    /* Otherwise RSP uses GDB's portable numbering. Map it to Linux's generic
     * numbers: these describe the target, never the host running this client. */
    static const uint8_t signals[] = {0, 1 /* HUP */, 2 /* INT */, 3 /* QUIT */, 4 /* ILL */,
        5 /* TRAP */, 6 /* ABRT */, 0, 8 /* FPE */, 9 /* KILL */, 7 /* BUS */, 11 /* SEGV */,
        31 /* SYS */, 13 /* PIPE */, 14 /* ALRM */, 15 /* TERM */, 23 /* URG */, 19 /* STOP */,
        20 /* TSTP */, 18 /* CONT */, 17 /* CHLD */, 21 /* TTIN */, 22 /* TTOU */, 29 /* IO */,
        24 /* XCPU */, 25 /* XFSZ */, 26 /* VTALRM */, 27 /* PROF */, 28 /* WINCH */, 0,
        10 /* USR1 */, 12 /* USR2 */, 30 /* PWR */, 29 /* POLL */};
    return remote < sizeof(signals) / sizeof(signals[0]) ? signals[remote] : 0;
}
static enum xrt_status publish_stop(struct xrt_gdb *g, struct xrt_target *t,
                                    const uint8_t *packet, size_t size, bool initial)
{
    if (size < 3 || hex(packet[1]) < 0 || hex(packet[2]) < 0) return XRT_PROTOCOL_ERROR;
    if (memchr(packet, 0, size)) return XRT_PROTOCOL_ERROR;
    uint8_t *copy = malloc(size);
    if (!copy) return XRT_OUT_OF_MEMORY;
    memcpy(copy, packet, size); free(g->last_stop);
    g->last_stop = copy; g->last_stop_size = size;
    unsigned signal = (unsigned)(hex(packet[1]) * 16 + hex(packet[2]));
    g->bank_valid = false;
    if (packet[0] == 'W' || packet[0] == 'X') {
        t->state = XRT_EXITED; t->stepping = t->want_run = false; g->rearm = 0;
        g->rewatch = false; g->watch_tid = 0;
        for (size_t i = 0; i < t->thread_count; ++i) t->threads[i].state = XRT_EXITED;
        g->pending_signal = 0; g->info.pending_delivery = false;
        g->info.stop_tid = 0; g->thread_info_count = 0;
        int code = packet[0] == 'X' ? -(target_signal(g, signal) ? target_signal(g, signal) : (int)signal) : (int)signal;
        event(t, XRT_EVENT_EXIT, t->pid, code);
        return XRT_OK;
    }
    if (packet[0] != 'T' && packet[0] != 'S') return XRT_PROTOCOL_ERROR;
    if (packet[0] == 'S' && size != 3) return XRT_PROTOCOL_ERROR;
    struct xrt_gdb_stop stop = {0};
    if (g->host.os == XRT_GDB_OS_DARWIN && packet[0] == 'T' &&
        xrt_gdb_stop_parse((const char *)packet, size, &stop) != XRT_OK)
        return problem(g, XRT_PROTOCOL_ERROR, "Malformed GDB Mach exception or exec stop");
    uint64_t pid = 0, raw_tid = 0, watch_address = 0, fault = 0;
    bool has_thread = false, swbreak = false, watch = false, has_fault = false;
    /* debugserver expedites the fault address register with every stop. */
    const struct xrt_gdb_register *far = NULL;
    for (uint32_t i = 0; i < g->description.count && !far; ++i)
        if (!strcmp(g->description.registers[i].name, "far") && g->description.registers[i].bytes == 8)
            far = &g->description.registers[i];
    if (packet[0] == 'T') {
        size_t at = 3;
        while (at < size) {
            const uint8_t *end = memchr(packet + at, ';', size - at);
            if (!end) return XRT_PROTOCOL_ERROR;
            const uint8_t *colon = memchr(packet + at, ':', (size_t)(end - packet - at));
            if (!colon) return XRT_PROTOCOL_ERROR;
            size_t key = (size_t)(colon - packet - at), n = (size_t)(end - colon - 1);
            if (key == 6 && !memcmp(packet + at, "thread", 6)) {
                if (has_thread || !thread_id((const char *)colon + 1, n, &pid, &raw_tid)) return XRT_PROTOCOL_ERROR;
                has_thread = true;
            } else if (key == 7 && !memcmp(packet + at, "swbreak", 7)) swbreak = true;
            else if (key == 10 && !memcmp(packet + at, "watch_addr", 10)) {
                /* debugserver: the address of the watchpoint that fired. */
                if (watch || !hexadecimal((const char *)colon + 1, n, &watch_address)) return XRT_PROTOCOL_ERROR;
                watch = true;
            } else if ((key == 4 && !memcmp(packet + at, "fork", 4)) ||
                     (key == 5 && !memcmp(packet + at, "vfork", 5)) ||
                     (key == 4 && !memcmp(packet + at, "exec", 4))) {
                t->state = XRT_STOPPED; t->identity_admitted = 0; ++t->generation;
                return problem(g, XRT_UNSUPPORTED_PROCESS_FOLLOWING, "GDB exec/fork requires a new target admission");
            } else if (far && n == 16 && !has_fault) {
                /* An expedited register: hexadecimal number, target-order bytes. */
                uint64_t number;
                if (hexadecimal((const char *)packet + at, key, &number) && number == far->number) {
                    for (unsigned i = 0; i < 8; ++i) {
                        int hi = hex(colon[1 + 2 * i]), lo = hex(colon[2 + 2 * i]);
                        if (hi < 0 || lo < 0) return XRT_PROTOCOL_ERROR;
                        fault |= (uint64_t)(hi * 16 + lo) << (8 * (t->arch && !t->arch->little_endian ? 7 - i : i));
                    }
                    has_fault = true;
                }
            }
            at = (size_t)(end - packet) + 1;
        }
    }
    if (stop.has_exception && stop.exception == 1 && stop.code_count >= 2) {
        if (has_fault && fault != stop.codes[1])
            return problem(g, XRT_PROTOCOL_ERROR, "GDB fault register contradicts Mach exception address");
        fault = stop.codes[1]; has_fault = true;
    }
    g->info.stop_tid = 0;
    g->info.has_exception = stop.has_exception;
    g->info.exception_type = stop.exception;
    g->info.exception_count = stop.code_count;
    memcpy(g->info.exception_codes, stop.codes, sizeof(stop.codes));
    g->info.has_fault = stop.has_exception && stop.exception == 1 && has_fault;
    g->info.fault_address = g->info.has_fault ? fault : 0;
    g->info.pending_delivery = false;
    bool stepping = t->stepping;
    t->state = XRT_STOPPED; t->stepping = t->want_run = false; g->selected = 0;
    ++t->generation;
    if (stop.exec) {
        /* All old probes belonged to the replaced address space. Never
         * unplant their bytes or retain their step/rearm state. */
        t->identity_admitted = 0; t->breakpoint_count = 0; t->thread_count = 0;
        memset(t->watchpoints, 0, sizeof(t->watchpoints));
        memset(&t->plant_cleanup, 0, sizeof(t->plant_cleanup));
        t->inherited_rearm = t->watchpoints_dirty = t->watch_cancelled = false;
        g->rearm = 0; g->rewatch = false; g->watch_tid = 0;
        memset(g->watch_armed, 0, sizeof(g->watch_armed));
        g->thread_count = g->thread_info_count = 0;
        g->pending_signal = 0; g->signal_tid = 0; g->unmapped_signal = false;
        ++t->image_epoch;
        event(t, XRT_EVENT_IMAGE_REPLACED, t->pid, (int64_t)t->image_epoch);
        struct xrt_gdb_host current = {0};
        enum xrt_status admission = query(g, "qProcessInfo");
        if (admission != XRT_OK) return admission;
        if (xrt_gdb_process_parse((char *)g->reply, g->length, &current) != XRT_OK ||
            current.os != XRT_GDB_OS_DARWIN || current.pid != g->process ||
            current.cputype != g->host.cputype || !t->arch ||
            current.pointer_size * 8 != t->arch->address_bits || !current.has_endian ||
            current.little_endian != (t->arch->little_endian != 0))
            return problem(g, XRT_UNSUPPORTED_ARCHITECTURE, "GDB exec changed or omitted the admitted process architecture");
        t->identity_admitted = 1;
        stepping = false;
    }
    if (!has_thread) {
        enum xrt_status status = query(g, "qC");
        if (status != XRT_OK) return status;
        if (g->length > 2 && !memcmp(g->reply, "QC", 2))
            has_thread = thread_id((const char *)g->reply + 2, g->length - 2, &pid, &raw_tid);
    }
    int32_t tid = 0;
    bool known_stop = false;
    if (has_thread) for (size_t i = 0; i < g->thread_count; ++i)
        if (g->threads[i].pid == pid && g->threads[i].tid == raw_tid) { known_stop = true; break; }
    enum xrt_status status = XRT_OK;
    /* A later stop whose thread is already known does not re-list the tasks. */
    if (!(g->quirks.lazy_inventory && !initial && known_stop)) {
        status = threads(g, t);
        if (status != XRT_OK) return status;
    }
    status = refresh_thread_info(g);
    if (status != XRT_OK) return status;
    if (!g->quirks.names_on_demand) {
        status = kernel_names(g);
        if (status != XRT_OK) return status;
    }
    if (has_thread) {
        if (g->info.supported & XRT_GDB_CAP_THREADS) {
            for (size_t i = 0; i < g->thread_count; ++i)
                if (g->threads[i].pid == pid && g->threads[i].tid == raw_tid) {
                    tid = g->threads[i].local; break;
                }
        } else {
            status = remember_thread(g, t, pid, raw_tid, &tid);
            if (status != XRT_OK) return status;
        }
    }
    if (!tid && t->thread_count == 1 && (g->info.supported & XRT_GDB_CAP_THREADS)) tid = t->threads[0].tid;
    int index = xrt_thread_index(t, tid);
    if (index < 0) return problem(g, XRT_UNKNOWN_THREAD, "GDB stop did not identify a known thread");
    for (size_t i = 0; i < t->thread_count; ++i) {
        t->threads[i].state = XRT_STOPPED; t->threads[i].reason = XRT_STOP_NONE;
        t->threads[i].signal = 0; t->threads[i].breakpoint_address = 0;
    }
    g->info.stop_tid = tid;
    enum xrt_stop_reason reason = initial ?
        (g->info.attached == 1 ? XRT_STOP_INTERRUPT : XRT_STOP_EXEC) :
        (stop.exec ? XRT_STOP_EXEC : XRT_STOP_SIGNAL);
    if (!initial && !stop.exec && stop.has_exception && stop.exception != 5)
        reason = XRT_STOP_EXCEPTION;
    if (!initial && stepping && signal == 5) reason = XRT_STOP_SINGLE_STEP;
    if (!initial && g->interrupt &&
        (signal == 2 || (g->host.os == XRT_GDB_OS_DARWIN && signal == 17 /* its SIGSTOP */) ||
         (g->kernel && signal == 5 && !stepping) /* SysRq-G enters with SIGTRAP */)) {
        reason = XRT_STOP_INTERRUPT;
        g->info.supported |= XRT_GDB_CAP_INTERRUPT;
        g->info.failed &= ~XRT_GDB_CAP_INTERRUPT;
    }
    g->interrupt = false; g->pending_signal = 0; g->unmapped_signal = false;
    bool pass_sigchld = false;
    if (reason == XRT_STOP_SIGNAL) {
        int native = target_signal(g, signal);
        if (g->kernel) {
            t->threads[index].signal = native;
            g->pending_signal = 0;
            g->unmapped_signal = false;
        } else if (!native && signal) {
            g->pending_signal = signal; g->signal_tid = tid; g->unmapped_signal = true;
            t->threads[index].reason = XRT_STOP_SIGNAL;
            event(t, XRT_EVENT_STOP, tid, signal);
            return problem(g, XRT_UNSUPPORTED_CONTROL, "GDB signal has no host display mapping; explicit suppression is required to resume");
        } else {
        t->threads[index].signal = native; g->pending_signal = signal; g->signal_tid = tid;
        /* Not during a step: resuming here would turn the step into a run. */
        pass_sigchld = g->host.os == XRT_GDB_OS_DARWIN && native == 20 && !stepping;
        }
    }
    if (g->watch_tid && thread_index(g, g->watch_tid) < 0) g->watch_tid = 0;
    struct xrt_registers regs; uint64_t pc = 0; bool known_pc = false;
    status = registers(g, t, tid, &regs);
    if (g->link.failed) return status;
    if (status == XRT_OK && xrt_registers_pc(&regs, &pc) == XRT_OK) known_pc = true;
    /* x86 kgdb reports the address after int3. Rewind onto our breakpoint
     * (gdb's decr_pc_after_break) so resume steps over it, not into it. */
    if (g->quirks.rewind_break && !initial && signal == 5 && known_pc && pc && !stepping &&
        t->arch && t->arch->machine == XRT_X86_64)
        for (size_t i = 0; i < t->breakpoint_count; ++i) {
            const struct xrt_breakpoint *bp = &t->breakpoints[i];
            if (!bp->pending && bp->patched && bp->enabled && bp->address == pc - 1) {
                status = write_register(g, t, tid, "rip", 3, pc - 1, NULL);
                if (status != XRT_OK) return status;
                --pc;
                break;
            }
        }
    if (!initial && signal == 5 && known_pc) for (size_t i = 0; i < t->breakpoint_count; ++i) {
        struct xrt_breakpoint *bp = &t->breakpoints[i];
        if (!bp->pending && bp->patched && bp->enabled && bp->address == pc) {
            reason = XRT_STOP_BREAKPOINT; ++bp->hit_count; g->pending_signal = 0;
            t->threads[index].signal = 0; t->threads[index].breakpoint_address = pc;
            event(t, XRT_EVENT_BREAKPOINT_HIT, tid, (int64_t)bp->id);
            if (bp->temporary) {
                status = breakpoint_packet(g, t, bp, false);
                if (status != XRT_OK) return status;
                bp->enabled = false;
            }
            break;
        }
    }
    if (!initial && watch) {
        reason = XRT_STOP_WATCHPOINT; g->pending_signal = 0; t->threads[index].signal = 0;
        g->watch_tid = tid;
        /* The fault address is the byte accessed; the stub's own figure is
         * the watchpoint's start. Trust the first only inside a watchpoint. */
        if (!has_fault || !publish_watch(g, t, tid, known_pc, pc, fault))
            (void)publish_watch(g, t, tid, known_pc, pc, watch_address);
        if (g->link.failed) return XRT_TRANSPORT_FAILED;
    }
    if (swbreak && reason != XRT_STOP_BREAKPOINT) {
        reason = XRT_STOP_BREAKPOINT; g->pending_signal = 0; t->threads[index].signal = 0;
    }
    t->threads[index].reason = reason;
    if (g->rearm || g->rewatch) {
        if (g->rewatch) {
            g->rewatch = false;
            status = watch_all(g, t, true);
            if (status != XRT_OK) { g->rearm = 0; return status; }
        }
        if (g->rearm) {
            int bp_index = xrt_breakpoint_index(t, g->rearm);
            g->rearm = 0;
            if (bp_index < 0) return XRT_UNKNOWN_BREAKPOINT;
            status = breakpoint_packet(g, t, &t->breakpoints[bp_index], true);
            if (status != XRT_OK) return status;
        }
        if (!g->step_after_rearm && reason == XRT_STOP_SINGLE_STEP) return send_run(g, t, tid, false);
    }
    if (pass_sigchld && reason == XRT_STOP_SIGNAL) {
        t->threads[index].reason = XRT_STOP_NONE;
        t->threads[index].signal = 0;
        return send_run(g, t, tid, false);
    }
    g->info.pending_delivery = g->pending_signal != 0;
    event(t, reason == XRT_STOP_SINGLE_STEP ? XRT_EVENT_STEP_COMPLETE : XRT_EVENT_STOP, tid, signal);
    t->events[t->event_count - 1].pc_known = known_pc;
    t->events[t->event_count - 1].pc = known_pc ? pc : 0;
    return XRT_OK;
}
static enum xrt_status poll_stop(struct xrt_gdb *g, struct xrt_target *t, bool wait)
{
    if (t->state != XRT_RUNNING) return XRT_OK;
    enum xrt_status status = xrt_gdb_receive_stop(&g->link, g->reply, sizeof(g->reply) - 1, &g->length, wait);
    if (status == XRT_NOT_STOPPED) return XRT_OK;
    if (status == XRT_STOP_TIMEOUT) {
        if (g->interrupt) g->info.failed |= XRT_GDB_CAP_INTERRUPT;
        return problem(g, status, g->interrupt ? "GDB interrupt unconfirmed; target is still running" : "Waiting for a GDB stop timed out");
    }
    if (status != XRT_OK) return problem(g, status, g->link.reason);
    uint8_t *saved = malloc(g->length);
    if (!saved) return XRT_OUT_OF_MEMORY;
    size_t size = g->length; memcpy(saved, g->reply, size);
    status = publish_stop(g, t, saved, size, false);
    if (status == XRT_PROTOCOL_ERROR) {
        /* A received but malformed stop cannot leave stale threads looking
         * runnable. No further decoding or control is safe on this link. */
        t->identity_admitted = 0; t->state = XRT_STOPPED;
        t->stepping = t->want_run = false; t->thread_count = 0;
        g->thread_count = g->thread_info_count = 0; g->info.stop_tid = 0;
        g->pending_signal = 0; g->bank_valid = false;
        ++t->generation; g->link.failed = true;
        snprintf(g->info.reason, sizeof(g->info.reason), "Malformed GDB stop; reconnect required");
    }
    free(saved); return status;
}
static enum xrt_status interrupt(struct xrt_gdb *g)
{
    if (!g->quirks.break_interrupt) return xrt_gdb_interrupt(&g->link);
    enum xrt_status status = xrt_gdb_interrupt_break(&g->link);
    if (status == XRT_UNSUPPORTED_CONTROL)
        return problem(g, status, "KGDB ignores interrupts on this endpoint; enter with SysRq-G on the target or use serial:PATH,break");
    return status;
}
static enum xrt_status detach(struct xrt_gdb *g, struct xrt_target *t)
{
    if (!t->pid || t->state == XRT_EXITED || t->state == XRT_IDLE) return XRT_OK;
    if (t->state == XRT_RUNNING) {
        enum xrt_status status = interrupt(g);
        if (status == XRT_OK) {
            g->interrupt = true;
            status = poll_stop(g, t, true);
        }
        bool planted = t->breakpoint_count != 0;
        for (size_t i = 0; i < XRT_MAX_WATCHPOINTS; ++i) planted = planted || t->watchpoints[i].present;
        if (status != XRT_OK && g->kernel && planted)
            xrt_log(XRT_LOG_WARN, XRT_LOG_RUNTIME, "xodb: KGDB kernel is running with xodb breakpoints still planted; enter the debugger and detach to remove them.\n");
        if (status != XRT_OK) return status;
    }
    enum xrt_status status = cleanup_plant(g, t);
    if (status != XRT_OK) return status;
    for (size_t i = 0; i < t->breakpoint_count; ++i)
        if (t->breakpoints[i].patched) {
            status = breakpoint_packet(g, t, &t->breakpoints[i], false);
            if (status != XRT_OK) return status;
        }
    status = watch_all(g, t, false);
    if (status != XRT_OK) return status;
    char command[40];
    if (g->multiprocess && g->process) snprintf(command, sizeof(command), "D;%" PRIx64, g->process);
    else strcpy(command, "D");
    ++t->generation;
    status = ok(g, command, "GDB detach unconfirmed");
    if (status != XRT_OK) { t->detach_pending = true; return XRT_DETACH_INCOMPLETE; }
    g->detach_confirmed = true;
    event(t, XRT_EVENT_DETACH, t->pid, 0);
    t->pid = 0; t->thread_count = t->breakpoint_count = 0; t->state = XRT_IDLE;
    t->detach_pending = t->owned = false; g->thread_count = 0; g->process = 0; g->selected = 0;
    memset(t->watchpoints, 0, sizeof(t->watchpoints)); g->watch_tid = 0; g->rewatch = false;
    return XRT_OK;
}
enum xrt_status xrt_gdb_health(const struct xrt_gdb *g)
{
    return g->link.failed ? XRT_TRANSPORT_FAILED : XRT_OK;
}
bool xrt_gdb_detach_confirmed(const struct xrt_gdb *g)
{
    return g && g->detach_confirmed;
}
void xrt_gdb_info(const struct xrt_gdb *g, struct xrt_gdb_info *out)
{
    *out = g->info;
    out->pending_delivery = g->pending_signal != 0;
    out->packet_size = (uint32_t)g->link.packet_size;
    out->register_count = g->description.count;
    out->os = g->host.os;
    out->address_bits = g->host.address_bits;
}
enum xrt_status xrt_gdb_thread_info(const struct xrt_gdb *g, int32_t tid, struct xrt_gdb_thread_info *out)
{
    int index = thread_index(g, tid);
    if (index < 0) return XRT_UNKNOWN_THREAD;
    if (g->quirks.names_on_demand) {
        /* The public entry is const. Filling one name cache row is the read. */
        struct xrt_gdb *mut = (struct xrt_gdb *)g;
        for (size_t i = 0; i < g->thread_info_count; ++i)
            if (g->thread_info[i].remote_tid == g->threads[index].tid) {
                *out = g->thread_info[i];
                return XRT_OK;
            }
        char id[40], command[80];
        format_thread(g, &g->threads[index], id, sizeof(id));
        snprintf(command, sizeof(command), "qThreadExtraInfo,%s", id);
        enum xrt_status status = query(mut, command);
        if (status != XRT_OK) return status;
        status = cache_kernel_name(mut, g->threads[index].tid);
        if (status != XRT_OK && status != XRT_TASK_INFO_UNAVAILABLE) return status;
        for (size_t i = 0; i < mut->thread_info_count; ++i)
            if (mut->thread_info[i].remote_tid == g->threads[index].tid) {
                *out = mut->thread_info[i];
                return XRT_OK;
            }
        return XRT_TASK_INFO_UNAVAILABLE;
    }
    if (!(g->info.supported & XRT_GDB_CAP_THREAD_INFO)) return XRT_TASK_INFO_UNAVAILABLE;
    for (size_t i = 0; i < g->thread_info_count; ++i) if (g->thread_info[i].remote_tid == g->threads[index].tid) {
        *out = g->thread_info[i];
        return XRT_OK;
    }
    return XRT_TASK_INFO_UNAVAILABLE;
}
void xrt_gdb_abandon(struct xrt_gdb *g) { xrt_gdb_disconnect(&g->link); }
void xrt_gdb_free(struct xrt_gdb *g)
{
    if (!g) return;
    xrt_gdb_disconnect(&g->link); free(g->last_stop); free(g->bank); free(g);
}
uint64_t xrt_gdb_mutation_bytes(const struct xrt_gdb *g) { return g->link.mutation_written; }
static enum xrt_status open_connection(const char *endpoint, int fd, int32_t attach_pid,
                                       struct xrt_target *t, struct xrt_gdb **out,
                                       struct xrt_cancel *cancel)
{
    if (out) *out = NULL;
    if (!out || !t || (!endpoint && fd < 0) || attach_pid < 0 || (endpoint && attach_pid)) {
        if (fd >= 0) close(fd);
        return XRT_INVALID_ARGUMENT;
    }
    const uint64_t deadline = xrt_now() + XRT_GDB_OPEN_NS;
    struct xrt_gdb *g = calloc(1, sizeof(*g));
    if (!g) { if (fd >= 0) close(fd); return XRT_OUT_OF_MEMORY; }
    uint8_t *initial_stop = NULL; size_t initial_size = 0;
    g->info.attached = -1;
    g->info.unsupported = XRT_GDB_CAP_WATCH | XRT_GDB_CAP_LIBRARIES | XRT_GDB_CAP_BINARY_WRITE;
    enum xrt_status status = endpoint ? xrt_gdb_connect(&g->link, endpoint, cancel) : xrt_gdb_adopt(&g->link, fd, cancel);
    g->link.operation_deadline_ns = deadline;
    if (status != XRT_OK) goto fail;
    if (!endpoint) {
        /* Native debugserver only; do not change other GDB stubs' handshake. */
        status = ok(g, "QSetDetachOnError:1", "Debugserver detach-on-error negotiation failed");
        if (status != XRT_OK) goto fail;
    }
    status = query(g, "qSupported:multiprocess+;qXfer:features:read+;xmlRegisters=i386;swbreak+");
    if (status != XRT_OK) goto fail;
    g->multiprocess = feature((char *)g->reply, "multiprocess+");
    bool noack = feature((char *)g->reply, "QStartNoAckMode+");
    bool nonstop = feature((char *)g->reply, "QNonStop+");
    g->native_signals = feature((char *)g->reply, "native-signals+");
    if (!feature((char *)g->reply, "qXfer:features:read+")) apply_kernel_quirks(g);
    for (char *p = (char *)g->reply; *p;) {
        char *end = strchr(p, ';'); if (!end) end = p + strlen(p);
        if ((size_t)(end - p) >= 11 && !memcmp(p, "PacketSize=", 11)) {
            uint64_t size;
            if (!hexadecimal(p + 11, (size_t)(end - p - 11), &size) || size < 128) {
                status = problem(g, XRT_PROTOCOL_ERROR, "Invalid GDB PacketSize"); goto fail;
            }
            g->link.packet_size = size > XRT_GDB_PAYLOAD_MAX ? XRT_GDB_PAYLOAD_MAX : (size_t)size;
        }
        p = *end ? end + 1 : end;
    }
    if (noack) {
        status = ok(g, "QStartNoAckMode", "GDB no-ack negotiation failed");
        if (status != XRT_OK) goto fail;
        g->link.noack = true;
    }
    if (nonstop) {
        status = ok(g, "QNonStop:0", "GDB stub did not accept all-stop mode");
        if (status != XRT_OK) goto fail;
    }
    status = query(g, "vCont?");
    if (status != XRT_OK) goto fail;
    g->vcont_continue = feature((char *)g->reply, "c");
    g->vcont_step = feature((char *)g->reply, "s");
    g->vcont_signal_continue = feature((char *)g->reply, "C");
    g->vcont_signal_step = feature((char *)g->reply, "S");
    if (g->vcont_step) g->info.supported |= XRT_GDB_CAP_STEP;
    else g->info.unsupported |= XRT_GDB_CAP_STEP;
    if (attach_pid) {
        char command[32];
        snprintf(command, sizeof(command), "vAttach;%" PRIx32, (uint32_t)attach_pid);
        status = query(g, command);
        if (status != XRT_OK) goto fail;
        if (g->length && g->reply[0] == 'E') {
            status = problem(g, XRT_PERMISSION_DENIED, "Debugserver attach failed");
            goto fail;
        }
        if (!g->length || (g->reply[0] != 'T' && g->reply[0] != 'S')) {
            status = problem(g, XRT_PROTOCOL_ERROR, "Debugserver attach returned no stop");
            goto fail;
        }
        initial_size = g->length;
        initial_stop = malloc(initial_size);
        if (!initial_stop) { status = XRT_OUT_OF_MEMORY; goto fail; }
        memcpy(initial_stop, g->reply, initial_size);
        g->info.attached = 1;
    }
    g->info.unsupported |= XRT_GDB_CAP_REGIONS | XRT_GDB_CAP_IMAGES | XRT_GDB_CAP_THREAD_INFO;
    if (g->native_signals) {
        /* An LLDB-family stub. Its host and process descriptions select the
         * signal table and stand in for what target.xml leaves out. */
        status = query(g, "qHostInfo");
        if (status != XRT_OK) goto fail;
        if (g->length && g->reply[0] != 'E' &&
            xrt_gdb_host_parse((char *)g->reply, g->length, &g->host) != XRT_OK) {
            status = problem(g, XRT_PROTOCOL_ERROR, "Malformed GDB qHostInfo reply"); goto fail;
        }
        status = query(g, "qProcessInfo");
        if (status != XRT_OK) goto fail;
        if (g->length && g->reply[0] != 'E' &&
            xrt_gdb_process_parse((char *)g->reply, g->length, &g->host) != XRT_OK) {
            status = problem(g, XRT_PROTOCOL_ERROR, "Malformed GDB qProcessInfo reply"); goto fail;
        }
        if (attach_pid && g->host.pid && g->host.pid != (uint32_t)attach_pid) {
            status = problem(g, XRT_PROTOCOL_ERROR, "Debugserver attached a different process"); goto fail;
        }
        if (g->host.pid && !g->multiprocess) g->process = g->host.pid;
    }
    if (g->host.os == XRT_GDB_OS_DARWIN) {
        g->info.unsupported &= ~(XRT_GDB_CAP_REGIONS | XRT_GDB_CAP_IMAGES | XRT_GDB_CAP_THREAD_INFO);
        status = query(g, "qWatchpointSupportInfo:");
        if (status != XRT_OK) goto fail;
        uint64_t slots = 0;
        if (g->length > 5 && !memcmp(g->reply, "num:", 4) && g->reply[g->length - 1] == ';' &&
            hexadecimal((char *)g->reply + 4, g->length - 5, &slots) && slots) {
            g->watch_capacity = slots > XRT_MAX_WATCHPOINTS ? XRT_MAX_WATCHPOINTS : (uint8_t)slots;
            g->info.unsupported &= ~XRT_GDB_CAP_WATCH;
        }
    }
    /* Establish the stopped inferior before requesting target.xml. Some
     * gdbservers build their description only while encoding this reply. */
    if (!initial_stop) {
        status = query(g, "?");
        if (status != XRT_OK) goto fail;
        initial_size = g->length; initial_stop = malloc(initial_size ? initial_size : 1);
        if (!initial_stop) { status = XRT_OUT_OF_MEMORY; goto fail; }
        memcpy(initial_stop, g->reply, initial_size);
    }
    if (g->kernel) {
        status = query(g, "g");
        if (status != XRT_OK) goto fail;
        for (size_t i = 0; i < g->length; ++i) if (hex(g->reply[i]) < 0) {
            status = problem(g, XRT_PROTOCOL_ERROR, "KGDB register packet is not hexadecimal");
            goto fail;
        }
        status = xrt_gdb_description_builtin(&g->description, g->length);
    } else {
        char *xml = NULL; size_t size = 0;
        status = annex(g, "target.xml", &xml, &size);
        /* debugserver's target.xml names no architecture; its Mach CPU type does. */
        const char *fallback = g->host.os == XRT_GDB_OS_DARWIN &&
            g->host.cputype == UINT32_C(0x0100000c) ? "aarch64" : NULL;
        if (status == XRT_OK)
            status = xrt_gdb_description_parse_for(&g->description, xml, size, annex, g, fallback);
        free(xml);
    }
    if (status != XRT_OK) {
        if (g->description.reason[0]) snprintf(g->info.reason, sizeof(g->info.reason), "%s", g->description.reason);
        goto fail;
    }
    if (g->kernel) {
        g->info.attached = 1;
        g->info.supported |= XRT_GDB_CAP_STEP;
        g->info.unsupported &= ~XRT_GDB_CAP_STEP;
        g->watch_capacity = XRT_MAX_WATCHPOINTS;
        if (g->description.arch && g->description.arch->machine == XRT_X86_64)
            g->quirks.rewind_break = true;
    }
    t->arch = g->description.arch; t->identity_admitted = 1;
    snprintf(g->info.architecture, sizeof(g->info.architecture), "%s", g->description.architecture);
    status = publish_stop(g, t, initial_stop, initial_size, true);
    free(initial_stop); initial_stop = NULL;
    if (status != XRT_OK) goto fail;
    char command[48];
    if (g->multiprocess && g->process) snprintf(command, sizeof(command), "qAttached:%" PRIx64, g->process);
    else strcpy(command, "qAttached");
    status = query(g, command);
    if (status != XRT_OK) goto fail;
    if (g->length == 1 && (g->reply[0] == '0' || g->reply[0] == '1')) {
        if (attach_pid && g->reply[0] != '1') {
            status = problem(g, XRT_PROTOCOL_ERROR, "Debugserver contradicted the requested attach"); goto fail;
        }
        g->info.attached = g->reply[0] - '0';
    }
    /* The initial stop must be decoded before qAttached because decoding may
     * read registers and debugserver recordings preserve that packet order.
     * No observer can see the target until open returns, so correct an
     * attached target's provisional exec reason here. */
    if (g->info.attached == 1) {
        int initial = xrt_thread_index(t, g->info.stop_tid);
        if (initial >= 0) t->threads[initial].reason = XRT_STOP_INTERRUPT;
    }
    /* A program started by the stub is still not a locally owned child. */
    t->owned = false; ++t->image_epoch;
    event(t, XRT_EVENT_ATTACH, t->pid, 0);
    *out = g; return XRT_OK;
fail:
    free(initial_stop);
    /* A handshake that already stopped the kernel must not leave it stopped. */
    if (g->quirks.detach_after_failure && g->link.fd >= 0) {
        g->link.failed = false;
        (void)query(g, "D");
    }
    xrt_log(XRT_LOG_ERROR, XRT_LOG_RUNTIME, "xodb: GDB connection failed: %s (status %d)\n", g->info.reason, status);
    xrt_gdb_free(g); return status;
}
enum xrt_status xrt_gdb_open(const char *endpoint, struct xrt_target *t, struct xrt_gdb **out, struct xrt_cancel *cancel)
{
    return open_connection(endpoint, -1, 0, t, out, cancel);
}
enum xrt_status xrt_gdb_open_fd(int fd, int32_t attach_pid, struct xrt_target *t,
                                struct xrt_gdb **out, struct xrt_cancel *cancel)
{
    return open_connection(NULL, fd, attach_pid, t, out, cancel);
}
enum xrt_status xrt_gdb_call(struct xrt_gdb *g, struct xrt_target *t, const struct xrt_call *call)
{
    if (!g || !t || !call || call->size > XRT_RPC_DATA_MAX || (call->size && !call->data))
        return XRT_INVALID_ARGUMENT;
    g->link.operation_deadline_ns = xrt_now() + XRT_GDB_OPERATION_NS;
    if (call->length) *call->length = 0;
    if (call->value) *call->value = 0;
    if (call->op == XRT_RPC_INVALIDATE) { ++t->generation; return XRT_OK; }
    if (call->op == XRT_RPC_EVENT) {
        if (call->args[0] > XRT_EVENT_PROCESS_RELEASED) return XRT_INVALID_ARGUMENT;
        event(t, (enum xrt_event_kind)call->args[0], (int32_t)call->args[1], (int64_t)call->args[2]);
        return XRT_OK;
    }
    if (call->op == XRT_RPC_VIEW) return XRT_OK;
    if (g->link.failed) {
        if (g->quirks.detach_after_failure && g->link.fd >= 0 &&
            (call->op == XRT_RPC_DESTROY || call->op == XRT_RPC_DETACH ||
             call->op == XRT_RPC_DETACH_FAMILY || call->op == XRT_RPC_CLOSE)) {
            /* kgdb's D removes breakpoints. Do not walk Z packets first. */
            g->link.failed = false;
            (void)query(g, "D");
            g->detach_confirmed = true;
            return XRT_OK;
        }
        return XRT_TRANSPORT_FAILED;
    }
    if (call->op == XRT_RPC_DESTROY || call->op == XRT_RPC_DETACH ||
        call->op == XRT_RPC_DETACH_FAMILY || call->op == XRT_RPC_CLOSE) return detach(g, t);
    if (call->op == XRT_RPC_SYNC) return poll_stop(g, t, false);
    if (call->op == XRT_RPC_WAIT_STOPPED) {
        for (unsigned n = 0; n < 8 && t->state == XRT_RUNNING; ++n) {
            enum xrt_status status = poll_stop(g, t, true);
            if (status != XRT_OK) return status;
        }
        return t->state == XRT_RUNNING ? XRT_STOP_TIMEOUT : XRT_OK;
    }
    if (call->op == XRT_RPC_INTERRUPT) {
        if (t->state != XRT_RUNNING) return XRT_OK;
        ++t->generation;
        enum xrt_status status = interrupt(g);
        if (status == XRT_OK) g->interrupt = true;
        return status;
    }
    if (!t->identity_admitted) return XRT_UNSUPPORTED_ARCHITECTURE;
    switch (call->op) {
    case XRT_RPC_CONTINUE: {
        int32_t tid = g->pending_signal ? g->signal_tid : g->watch_tid;
        if (!tid) {
            for (size_t i = 0; i < t->thread_count; ++i)
                if (t->threads[i].reason != XRT_STOP_NONE) { tid = t->threads[i].tid; break; }
        }
        if (!tid && t->thread_count) tid = t->threads[0].tid;
        return resume(g, t, tid, false);
    }
    case XRT_RPC_STEP:
        return resume(g, t, (int32_t)call->args[0], true);
    case XRT_RPC_READ:
        if (!call->length || call->args[1] > call->capacity || (!call->out && call->args[1]))
            return XRT_INVALID_ARGUMENT;
        return read_memory(g, t, call->args[0], call->out, (size_t)call->args[1], call->length);
    case XRT_RPC_WRITE:
        return write_memory(g, t, call->args[0], call->data, call->size);
    case XRT_RPC_REGISTERS: {
        if (!call->out || !call->length) return XRT_INVALID_ARGUMENT;
        struct xrt_registers regs;
        enum xrt_status status = registers(g, t, (int32_t)call->args[0], &regs);
        if (status != XRT_OK) return status;
        struct xrt_codec encoded = xrt_codec(call->out, call->capacity, false);
        xrt_wire_registers(&encoded, &regs);
        if (!encoded.ok) return XRT_BUFFER_TOO_SMALL;
        *call->length = encoded.at;
        return XRT_OK;
    }
    case XRT_RPC_REGISTER_WRITE:
        return write_register(g, t, (int32_t)call->args[0], call->data, call->size, call->args[1], call->value);
    case XRT_RPC_CONTROL_WRITE: {
        if (call->args[1] != 1 || call->size != 8) return XRT_UNSUPPORTED_CONTROL;
        struct xrt_codec input = xrt_codec((void *)call->data, call->size, true);
        uint64_t value = 0; xrt_codec_u64(&input, &value);
        const struct xrt_register_desc *pc = xrt_arch_role(t->arch, XRT_ROLE_PC);
        if (!input.ok || !pc) return XRT_UNSUPPORTED_CONTROL;
        return write_register(g, t, (int32_t)call->args[0], pc->name, strlen(pc->name), value, call->value);
    }
    case XRT_RPC_BP_SET:
    case XRT_RPC_BP_RESERVE:
    case XRT_RPC_BP_RESTORE: {
        if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
        if (t->breakpoint_count == XRT_MAX_BREAKPOINTS) return XRT_BREAKPOINT_LIMIT;
        if (t->plant_cleanup.active) return XRT_INVALID_STATE;
        if (call->op == XRT_RPC_BP_RESTORE && xrt_breakpoint_index(t, call->args[0]) >= 0)
            return XRT_BREAKPOINT_ALREADY_RESOLVED;
        uint64_t id = call->op == XRT_RPC_BP_RESTORE ? call->args[0] : t->next_probe_id++;
        if (!id || id == UINT64_MAX) return XRT_INVALID_ARGUMENT;
        if (id >= t->next_probe_id) t->next_probe_id = id + 1;
        struct xrt_breakpoint *bp = &t->breakpoints[t->breakpoint_count++];
        *bp = (struct xrt_breakpoint){.id = id, .pending = true,
            .enabled = call->op != XRT_RPC_BP_RESTORE || call->args[1] != 0,
            .temporary = call->op == XRT_RPC_BP_SET && call->args[1] != 0};
        if (call->op == XRT_RPC_BP_SET) {
            enum xrt_status status = breakpoint_resolve(g, t, bp, call->args[0]);
            if (status != XRT_OK) { --t->breakpoint_count; return status; }
        } else ++t->generation;
        if (call->value) *call->value = id;
        return XRT_OK;
    }
    case XRT_RPC_BP_RESOLVE:
    case XRT_RPC_BP_WITHDRAW:
    case XRT_RPC_BP_ENABLE:
    case XRT_RPC_BP_INTERNAL:
    case XRT_RPC_BP_REMOVE: {
        if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
        int i = xrt_breakpoint_index(t, call->args[0]);
        if (i < 0) return XRT_UNKNOWN_BREAKPOINT;
        struct xrt_breakpoint *bp = &t->breakpoints[i];
        if (t->plant_cleanup.active && t->plant_cleanup.address != bp->address) return XRT_INVALID_STATE;
        if (call->op == XRT_RPC_BP_RESOLVE) return breakpoint_resolve(g, t, bp, call->args[1]);
        if (call->op == XRT_RPC_BP_INTERNAL) { bp->internal = call->args[1] != 0; ++t->generation; return XRT_OK; }
        bool enable = call->op == XRT_RPC_BP_ENABLE && call->args[1] != 0;
        if (!bp->pending && (bp->patched != enable || t->plant_cleanup.active)) {
            enum xrt_status status = breakpoint_packet(g, t, bp, enable);
            if (status != XRT_OK) return status;
        }
        if (call->op == XRT_RPC_BP_ENABLE) bp->enabled = enable;
        else if (call->op == XRT_RPC_BP_WITHDRAW) { bp->pending = true; bp->address = 0; }
        else {
            uint64_t id = bp->id;
            memmove(bp, bp + 1, (t->breakpoint_count - (size_t)i - 1) * sizeof(*bp));
            --t->breakpoint_count; event(t, XRT_EVENT_BREAKPOINT_REMOVED, t->pid, (int64_t)id);
        }
        ++t->generation; return XRT_OK;
    }
    case XRT_RPC_SIGNAL_SUPPRESS: {
        int i = xrt_thread_index(t, (int32_t)call->args[0]);
        if (i < 0) return XRT_UNKNOWN_THREAD;
        if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
        t->threads[i].signal = 0;
        if (g->signal_tid == (int32_t)call->args[0]) { g->pending_signal = 0; g->unmapped_signal = false; }
        ++t->generation; return XRT_OK;
    }
    case XRT_RPC_CLEAR_STOP: {
        int i = xrt_thread_index(t, (int32_t)call->args[0]);
        if (i < 0) return XRT_UNKNOWN_THREAD;
        if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
        if (t->threads[i].reason == XRT_STOP_BREAKPOINT && t->threads[i].breakpoint_address == call->args[1]) {
            t->threads[i].reason = XRT_STOP_INTERRUPT;
            ++t->generation;
        }
        return XRT_OK;
    }
    case XRT_RPC_FOLLOW:
        return call->args[0] ? XRT_UNSUPPORTED_PROCESS_FOLLOWING : XRT_OK;
    case XRT_RPC_EXTENDED:
        return XRT_EXTENDED_REGISTERS_UNAVAILABLE;
    case XRT_RPC_SIGNAL_INFO:
        return XRT_TASK_INFO_UNAVAILABLE;
    case XRT_RPC_FILE_OPEN:
    case XRT_RPC_FILE_READ:
    case XRT_RPC_FILE_CLOSE:
    case XRT_RPC_SOURCE_OPEN:
        return problem(g, XRT_FILE_UNAVAILABLE, "GDB process files and library mapping are unavailable");
    case XRT_RPC_WATCH_SET:
    case XRT_RPC_WATCH_REMOVE:
    case XRT_RPC_WATCH_CAPACITY: {
        if (!g->watch_capacity)
            return problem(g, XRT_UNSUPPORTED_CONTROL, g->kernel ?
                "KGDB hardware watchpoint was refused by the stub" :
                "GDB hardware watchpoints are unsupported by this client");
        if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
        if (call->op == XRT_RPC_WATCH_CAPACITY) {
            if (call->value) *call->value = g->watch_capacity;
            return XRT_OK;
        }
        if (call->op == XRT_RPC_WATCH_REMOVE) {
            for (unsigned i = 0; i < XRT_MAX_WATCHPOINTS; ++i) {
                struct xrt_watchpoint *watch = &t->watchpoints[i];
                if (!watch->present || watch->id != call->args[0]) continue;
                enum xrt_status status = watch_packet(g, t, i, false);
                if (status != XRT_OK) return status;
                watch->present = false;
                event(t, XRT_EVENT_WATCHPOINT_REMOVED, t->pid, (int64_t)call->args[0]);
                return XRT_OK;
            }
            return XRT_UNKNOWN_WATCHPOINT;
        }
        const uint64_t address = call->args[0], length = call->args[1], kind = call->args[2];
        if (kind > XRT_WATCH_EXECUTE) return XRT_INVALID_ARGUMENT;
        if (kind == XRT_WATCH_EXECUTE) return XRT_EXECUTION_WATCHPOINTS_UNSUPPORTED;
        if ((length != 1 && length != 2 && length != 4 && length != 8) || address % length)
            return XRT_INVALID_WATCH_RANGE;
        unsigned slot = 0;
        while (slot < g->watch_capacity && t->watchpoints[slot].present) ++slot;
        if (slot == g->watch_capacity || t->next_probe_id == UINT64_MAX) return XRT_WATCHPOINT_LIMIT;
        uint8_t bytes[8] = {0}; size_t count; uint64_t previous = 0;
        enum xrt_status status = read_memory(g, t, address, bytes, (size_t)length, &count);
        if (status != XRT_OK || count != length) return status != XRT_OK ? status : XRT_MEMORY_UNREADABLE;
        for (unsigned i = 0; i < length; ++i) previous |= (uint64_t)bytes[i] << (8 * i);
        t->watchpoints[slot] = (struct xrt_watchpoint){.address = address, .length = (uint8_t)length,
            .kind = (enum xrt_watch_kind)kind, .previous = previous};
        status = watch_packet(g, t, slot, true);
        if (status != XRT_OK) {
            if (status == XRT_UNSUPPORTED_CONTROL) g->info.unsupported |= XRT_GDB_CAP_WATCH;
            return status;
        }
        t->watchpoints[slot].id = t->next_probe_id++; t->watchpoints[slot].present = true;
        g->info.supported |= XRT_GDB_CAP_WATCH;
        event(t, XRT_EVENT_WATCHPOINT_SET, t->pid, (int64_t)t->watchpoints[slot].id);
        t->events[t->event_count - 1].address = address;
        if (call->value) *call->value = t->watchpoints[slot].id;
        return XRT_OK;
    }
    case XRT_RPC_LAUNCH:
    case XRT_RPC_ATTACH:
    case XRT_RPC_RESET:
        return problem(g, XRT_UNSUPPORTED_CONTROL, "Connect to a stub with an already launched or attached target");
    default:
        return problem(g, XRT_UNSUPPORTED_CONTROL, "Operation is unavailable on the GDB remote backend");
    }
}
enum xrt_status xrt_gdb_regions(struct xrt_gdb *g, struct xrt_target *t,
                                struct xrt_gdb_region *out, size_t capacity, size_t *total)
{
    if (!g || !t || !total || (capacity && !out)) return XRT_INVALID_ARGUMENT;
    *total = 0;
    g->info.regions_cut = false;
    if (g->link.failed) return XRT_TRANSPORT_FAILED;
    if (g->info.unsupported & XRT_GDB_CAP_REGIONS)
        return problem(g, XRT_FILE_UNAVAILABLE, "GDB stub has no memory region query");
    if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
    /* One round trip per region. The walk stops at the region limit or after
     * most of one operation budget, well before the link deadline. */
    const uint64_t budget = xrt_now() + XRT_GDB_OPERATION_NS / 10 * 8;
    g->link.operation_deadline_ns = xrt_now() + XRT_GDB_OPERATION_NS;
    for (uint64_t address = 0;;) {
        char command[48]; bool cut;
        snprintf(command, sizeof(command), "qMemoryRegionInfo:%" PRIx64, address);
        enum xrt_status status = query_prefix(g, command, &cut);
        if (status != XRT_OK) return status;
        if ((!g->length || g->reply[0] == 'E') && !*total) {
            if (!g->length) g->info.unsupported |= XRT_GDB_CAP_REGIONS;
            return problem(g, XRT_FILE_UNAVAILABLE, "GDB stub has no memory region query");
        }
        if (!g->length || g->reply[0] == 'E') break;
        struct xrt_gdb_region region;
        if (xrt_gdb_region_parse((char *)g->reply, g->length, cut, address, &region) != XRT_OK) {
            g->info.failed |= XRT_GDB_CAP_REGIONS;
            return problem(g, XRT_PROTOCOL_ERROR, "Malformed GDB memory region reply");
        }
        if (!region.size) break;
        if (*total == XRT_GDB_REGIONS_MAX) {
            g->info.regions_cut = true;
            break;
        }
        if (xrt_now() > budget)
            return problem(g, XRT_DISCOVERY_BUDGET, "GDB memory map walk exceeded its time budget");
        if (*total < capacity) out[*total] = region;
        ++*total;
        const uint64_t last = region.start + (region.size - 1);
        if (last == UINT64_MAX) break;
        address = last + 1; /* Past the address asked: the walk always advances. */
    }
    g->info.supported |= XRT_GDB_CAP_REGIONS; g->info.failed &= ~XRT_GDB_CAP_REGIONS;
    return XRT_OK;
}
enum xrt_status xrt_gdb_images(struct xrt_gdb *g, struct xrt_target *t,
                               struct xrt_gdb_image *out, size_t capacity, size_t *total)
{
    if (!g || !t || !total || (capacity && !out)) return XRT_INVALID_ARGUMENT;
    *total = 0;
    if (g->link.failed) return XRT_TRANSPORT_FAILED;
    if (g->info.unsupported & XRT_GDB_CAP_IMAGES)
        return problem(g, XRT_FILE_UNAVAILABLE, "GDB stub has no loaded-image query");
    if (t->state != XRT_STOPPED) return XRT_NOT_STOPPED;
    g->link.operation_deadline_ns = xrt_now() + XRT_GDB_OPERATION_NS;
    bool cut;
    /* UUIDs and segments bind local symbols and label shared-cache addresses.
     * The complete list remains bounded by the packet and image limits. */
    enum xrt_status status = query_prefix(g,
        "jGetLoadedDynamicLibrariesInfos:{\"fetch_all_solibs\":true}", &cut);
    if (status != XRT_OK) return status;
    if (cut) return problem(g, XRT_BUFFER_TOO_SMALL, "GDB loaded-image list exceeds the packet limit");
    if (!g->length || g->reply[0] != '{') {
        if (!g->length) g->info.unsupported |= XRT_GDB_CAP_IMAGES;
        return problem(g, XRT_FILE_UNAVAILABLE, "GDB stub has no loaded-image query");
    }
    status = xrt_gdb_images_parse((char *)g->reply, g->length, out, capacity, total);
    if (status == XRT_BUFFER_TOO_SMALL)
        return problem(g, status, "GDB loaded-image list exceeds the image limit");
    if (status != XRT_OK) {
        g->info.failed |= XRT_GDB_CAP_IMAGES;
        return problem(g, XRT_PROTOCOL_ERROR, "Malformed GDB loaded-image list");
    }
    g->info.supported |= XRT_GDB_CAP_IMAGES; g->info.failed &= ~XRT_GDB_CAP_IMAGES;
    return XRT_OK;
}
