#define _GNU_SOURCE 1
#include "gdbremote.h"
#include "gdb_link.h"
#include "gdb_description.h"
#include "target_internal.h"
#include "wire_target.h"
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

struct remote_thread { uint64_t pid, tid; int32_t local; };
struct xrt_gdb {
    struct xrt_gdb_link link;
    struct xrt_gdb_description description;
    struct xrt_gdb_info info;
    struct remote_thread threads[XRT_MAX_THREADS];
    size_t thread_count;
    uint64_t process, rearm;
    int32_t selected, signal_tid;
    unsigned pending_signal;
    bool vcont_signal_continue, vcont_signal_step, single_write_unavailable, unmapped_signal;
    bool multiprocess, vcont_continue, vcont_step, interrupt, step_after_rearm;
    uint8_t reply[XRT_GDB_PAYLOAD_MAX + 1];
    size_t length, last_stop_size;
    uint8_t *last_stop;
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
    int32_t id = tid <= INT_MAX ? (int32_t)tid : 1;
    while (thread_index(g, id) >= 0) {
        if (id == INT_MAX) return XRT_TOO_MANY_THREADS;
        ++id;
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
        if (++pages > XRT_MAX_THREADS) return XRT_TOO_MANY_THREADS;
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
            if (count == XRT_MAX_THREADS) return XRT_TOO_MANY_THREADS;
            present[count++] = (struct remote_thread){.pid = pid, .tid = tid};
            p = *end ? end + 1 : end;
        }
        status = query(g, "qsThreadInfo"); if (status != XRT_OK) return status;
    }
    if (g->length != 1 || g->reply[0] != 'l') return XRT_PROTOCOL_ERROR;
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
    if (status == XRT_OK) status = query(g, "g");
    if (status != XRT_OK) return status;
    if (!g->length || g->reply[0] == 'E') return XRT_REGISTER_UNAVAILABLE;
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
static enum xrt_status send_run(struct xrt_gdb *g, struct xrt_target *t,
                                 int32_t tid, bool step)
{
    if (step && !g->vcont_step)
        return problem(g, XRT_UNSUPPORTED_CONTROL, "GDB stub does not support vCont;s");
    char command[96], id[40];
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
    ++t->generation;
    enum xrt_status status = xrt_gdb_send(&g->link, command, strlen(command));
    if (status != XRT_OK) return problem(g, status, g->link.reason);
    g->pending_signal = 0;
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
    if (!g->vcont_step) return problem(g, XRT_UNSUPPORTED_CONTROL, "GDB stub does not support vCont;s");
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
    struct xrt_registers regs; uint64_t pc;
    status = registers(g, t, tid, &regs);
    if (status != XRT_OK || xrt_registers_pc(&regs, &pc) != XRT_OK)
        return status != XRT_OK ? status : XRT_REGISTER_UNAVAILABLE;
    if (step) { status = admit_step(g, t, pc); if (status != XRT_OK) return status; }
    for (size_t n = 0; n < t->breakpoint_count; ++n) {
        struct xrt_breakpoint *bp = &t->breakpoints[n];
        if (!bp->pending && bp->enabled && bp->patched && bp->address == pc) {
            if (!step) { status = admit_step(g, t, pc); if (status != XRT_OK) return status; }
            status = breakpoint_packet(g, t, bp, false);
            if (status != XRT_OK) return status;
            g->rearm = bp->id; g->step_after_rearm = step;
            status = send_run(g, t, tid, true);
            if (status != XRT_OK) {
                enum xrt_status restored = breakpoint_packet(g, t, bp, true);
                g->rearm = 0;
                return restored != XRT_OK ? restored : status;
            }
            return XRT_OK;
        }
    }
    return send_run(g, t, tid, step);
}
static int native_signal(unsigned remote)
{
    /* RSP uses GDB's portable signal numbering, not the host's numbering. */
    static const int signals[] = {0, SIGHUP, SIGINT, SIGQUIT, SIGILL, SIGTRAP, SIGABRT,
        0, SIGFPE, SIGKILL, SIGBUS, SIGSEGV, SIGSYS, SIGPIPE, SIGALRM, SIGTERM,
        SIGURG, SIGSTOP, SIGTSTP, SIGCONT, SIGCHLD, SIGTTIN, SIGTTOU, SIGIO,
        SIGXCPU, SIGXFSZ, SIGVTALRM, SIGPROF, SIGWINCH, 0, SIGUSR1, SIGUSR2, SIGPWR, SIGPOLL};
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
    if (packet[0] == 'W' || packet[0] == 'X') {
        t->state = XRT_EXITED; t->stepping = t->want_run = false; g->rearm = 0;
        for (size_t i = 0; i < t->thread_count; ++i) t->threads[i].state = XRT_EXITED;
        event(t, XRT_EVENT_EXIT, t->pid, signal);
        return XRT_OK;
    }
    if (packet[0] != 'T' && packet[0] != 'S') return XRT_PROTOCOL_ERROR;
    if (packet[0] == 'S' && size != 3) return XRT_PROTOCOL_ERROR;
    uint64_t pid = 0, raw_tid = 0; bool has_thread = false, swbreak = false;
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
            else if ((key == 4 && !memcmp(packet + at, "fork", 4)) ||
                     (key == 5 && !memcmp(packet + at, "vfork", 5)) ||
                     (key == 4 && !memcmp(packet + at, "exec", 4))) {
                t->state = XRT_STOPPED; t->identity_admitted = 0; ++t->generation;
                return problem(g, XRT_UNSUPPORTED_PROCESS_FOLLOWING, "GDB exec/fork requires a new target admission");
            }
            at = (size_t)(end - packet) + 1;
        }
    }
    bool stepping = t->stepping;
    t->state = XRT_STOPPED; t->stepping = t->want_run = false; g->selected = 0;
    ++t->generation;
    if (!has_thread) {
        enum xrt_status status = query(g, "qC");
        if (status != XRT_OK) return status;
        if (g->length > 2 && !memcmp(g->reply, "QC", 2))
            has_thread = thread_id((const char *)g->reply + 2, g->length - 2, &pid, &raw_tid);
    }
    int32_t tid = 0;
    enum xrt_status status = threads(g, t);
    if (status != XRT_OK) return status;
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
    enum xrt_stop_reason reason = initial ? XRT_STOP_EXEC : XRT_STOP_SIGNAL;
    if (!initial && stepping && signal == 5) reason = XRT_STOP_SINGLE_STEP;
    if (!initial && g->interrupt && signal == 2) {
        reason = XRT_STOP_INTERRUPT;
        g->info.supported |= XRT_GDB_CAP_INTERRUPT;
        g->info.failed &= ~XRT_GDB_CAP_INTERRUPT;
    }
    g->interrupt = false; g->pending_signal = 0; g->unmapped_signal = false;
    if (reason == XRT_STOP_SIGNAL) {
        int native = native_signal(signal);
        if (!native && signal) {
            g->pending_signal = signal; g->signal_tid = tid; g->unmapped_signal = true;
            t->threads[index].reason = XRT_STOP_SIGNAL;
            event(t, XRT_EVENT_STOP, tid, signal);
            return problem(g, XRT_UNSUPPORTED_CONTROL, "GDB signal has no host display mapping; explicit suppression is required to resume");
        }
        t->threads[index].signal = native; g->pending_signal = signal; g->signal_tid = tid;
    }
    struct xrt_registers regs; uint64_t pc = 0; bool known_pc = false;
    status = registers(g, t, tid, &regs);
    if (g->link.failed) return status;
    if (status == XRT_OK && xrt_registers_pc(&regs, &pc) == XRT_OK) known_pc = true;
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
    if (swbreak && reason != XRT_STOP_BREAKPOINT) {
        reason = XRT_STOP_BREAKPOINT; g->pending_signal = 0; t->threads[index].signal = 0;
    }
    t->threads[index].reason = reason;
    if (g->rearm) {
        int bp_index = xrt_breakpoint_index(t, g->rearm);
        g->rearm = 0;
        if (bp_index < 0) return XRT_UNKNOWN_BREAKPOINT;
        status = breakpoint_packet(g, t, &t->breakpoints[bp_index], true);
        if (status != XRT_OK) return status;
        if (!g->step_after_rearm && reason == XRT_STOP_SINGLE_STEP) return send_run(g, t, tid, false);
    }
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
    free(saved); return status;
}
static enum xrt_status detach(struct xrt_gdb *g, struct xrt_target *t)
{
    if (!t->pid || t->state == XRT_EXITED || t->state == XRT_IDLE) return XRT_OK;
    if (t->state == XRT_RUNNING) {
        enum xrt_status status = xrt_gdb_interrupt(&g->link);
        if (status != XRT_OK) return status;
        g->interrupt = true;
        status = poll_stop(g, t, true);
        if (status != XRT_OK) return status;
    }
    enum xrt_status status = cleanup_plant(g, t);
    if (status != XRT_OK) return status;
    for (size_t i = 0; i < t->breakpoint_count; ++i)
        if (t->breakpoints[i].patched) {
            status = breakpoint_packet(g, t, &t->breakpoints[i], false);
            if (status != XRT_OK) return status;
        }
    char command[40];
    if (g->multiprocess && g->process) snprintf(command, sizeof(command), "D;%" PRIx64, g->process);
    else strcpy(command, "D");
    ++t->generation;
    status = ok(g, command, "GDB detach unconfirmed");
    if (status != XRT_OK) { t->detach_pending = true; return XRT_DETACH_INCOMPLETE; }
    event(t, XRT_EVENT_DETACH, t->pid, 0);
    t->pid = 0; t->thread_count = t->breakpoint_count = 0; t->state = XRT_IDLE;
    t->detach_pending = t->owned = false; g->thread_count = 0; g->process = 0; g->selected = 0;
    return XRT_OK;
}
enum xrt_status xrt_gdb_health(const struct xrt_gdb *g)
{
    return g->link.failed ? XRT_TRANSPORT_FAILED : XRT_OK;
}
void xrt_gdb_info(const struct xrt_gdb *g, struct xrt_gdb_info *out)
{
    *out = g->info;
    out->packet_size = (uint32_t)g->link.packet_size;
    out->register_count = g->description.count;
}
void xrt_gdb_abandon(struct xrt_gdb *g) { xrt_gdb_disconnect(&g->link); }
void xrt_gdb_free(struct xrt_gdb *g)
{
    if (!g) return;
    xrt_gdb_disconnect(&g->link); free(g->last_stop); free(g);
}
enum xrt_status xrt_gdb_open(const char *endpoint, struct xrt_target *t, struct xrt_gdb **out)
{
    const uint64_t deadline = xrt_now() + XRT_GDB_OPEN_NS;
    *out = NULL;
    struct xrt_gdb *g = calloc(1, sizeof(*g));
    if (!g) return XRT_OUT_OF_MEMORY;
    uint8_t *initial_stop = NULL; size_t initial_size = 0;
    g->info.attached = -1;
    g->info.unsupported = XRT_GDB_CAP_WATCH | XRT_GDB_CAP_LIBRARIES | XRT_GDB_CAP_BINARY_WRITE;
    enum xrt_status status = xrt_gdb_connect(&g->link, endpoint);
    g->link.operation_deadline_ns = deadline;
    if (status != XRT_OK) goto fail;
    status = query(g, "qSupported:multiprocess+;qXfer:features:read+;xmlRegisters=i386;swbreak+");
    if (status != XRT_OK) goto fail;
    g->multiprocess = feature((char *)g->reply, "multiprocess+");
    bool noack = feature((char *)g->reply, "QStartNoAckMode+");
    bool nonstop = feature((char *)g->reply, "QNonStop+");
    if (!feature((char *)g->reply, "qXfer:features:read+")) {
        status = problem(g, XRT_REGISTER_UNAVAILABLE, "GDB stub lacks qXfer:features:read target.xml");
        goto fail;
    }
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
    /* Establish the stopped inferior before requesting target.xml. Some
     * gdbservers build their description only while encoding this reply. */
    status = query(g, "?");
    if (status != XRT_OK) goto fail;
    initial_size = g->length; initial_stop = malloc(initial_size ? initial_size : 1);
    if (!initial_stop) { status = XRT_OUT_OF_MEMORY; goto fail; }
    memcpy(initial_stop, g->reply, initial_size);
    char *xml = NULL; size_t size = 0;
    status = annex(g, "target.xml", &xml, &size);
    if (status == XRT_OK) status = xrt_gdb_description_parse(&g->description, xml, size, annex, g);
    free(xml);
    if (status != XRT_OK) {
        if (g->description.reason[0]) snprintf(g->info.reason, sizeof(g->info.reason), "%s", g->description.reason);
        goto fail;
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
    if (g->length == 1 && (g->reply[0] == '0' || g->reply[0] == '1')) g->info.attached = g->reply[0] - '0';
    /* A program started by the stub is still not a locally owned child. */
    t->owned = false; ++t->image_epoch;
    event(t, XRT_EVENT_ATTACH, t->pid, 0);
    *out = g; return XRT_OK;
fail:
    free(initial_stop);
    fprintf(stderr, "xodb: GDB connection failed: %s (status %d)\n", g->info.reason, status);
    xrt_gdb_free(g); return status;
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
        if (call->args[0] > XRT_EVENT_PROCESS_SEPARATED) return XRT_INVALID_ARGUMENT;
        event(t, (enum xrt_event_kind)call->args[0], (int32_t)call->args[1], (int64_t)call->args[2]);
        return XRT_OK;
    }
    if (call->op == XRT_RPC_VIEW) return XRT_OK;
    if (g->link.failed) return XRT_TRANSPORT_FAILED;
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
        enum xrt_status status = xrt_gdb_interrupt(&g->link);
        if (status == XRT_OK) g->interrupt = true;
        return status;
    }
    if (!t->identity_admitted) return XRT_UNSUPPORTED_ARCHITECTURE;
    switch (call->op) {
    case XRT_RPC_CONTINUE: {
        int32_t tid = g->pending_signal ? g->signal_tid : 0;
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
    case XRT_RPC_WATCH_CAPACITY:
        return problem(g, XRT_UNSUPPORTED_CONTROL, "GDB hardware watchpoints are unsupported by this client");
    case XRT_RPC_LAUNCH:
    case XRT_RPC_ATTACH:
    case XRT_RPC_RESET:
        return problem(g, XRT_UNSUPPORTED_CONTROL, "Connect to a stub with an already launched or attached target");
    default:
        return problem(g, XRT_UNSUPPORTED_CONTROL, "Operation is unavailable on the GDB remote backend");
    }
}
