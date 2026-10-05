#include "wire_target.h"
#include "target_internal.h"
/* Signed values retain their fixed-width two's-complement bit patterns. */
static void i32(struct xrt_codec *c, int32_t *v)
{
    uint32_t n = 0;
    if (!c->read)
        memcpy(&n, v, 4);
    xrt_codec_u32(c, &n);
    if (c->ok && c->read)
        memcpy(v, &n, 4);
}
static void i64(struct xrt_codec *c, int64_t *v)
{
    uint64_t n = 0;
    if (!c->read)
        memcpy(&n, v, 8);
    xrt_codec_u64(c, &n);
    if (c->ok && c->read)
        memcpy(v, &n, 8);
}
#define U64(v) xrt_codec_u64(c, &(v))
#define U32(v) xrt_codec_u32(c, &(v))
#define U16(v) xrt_codec_u16(c, &(v))
#define U8(v) xrt_codec_u8(c, &(v))
#define BOOL(v) xrt_codec_bool(c, &(v))
#define ENUM(v, max)                                                                               \
    do {                                                                                           \
        uint32_t n_ = c->read ? 0 : (uint32_t)(v);                                                 \
        U32(n_);                                                                                   \
        if (n_ > (max))                                                                            \
            c->ok = false;                                                                         \
        if (c->ok && c->read)                                                                      \
            (v) = n_;                                                                              \
    } while (0)
static void count(struct xrt_codec *c, size_t *v, uint32_t max)
{
    if (!c->read && *v > max) {
        c->ok = false;
        return;
    }
    uint32_t n = c->read ? 0 : (uint32_t)*v;
    U32(n);
    if (n > max)
        c->ok = false;
    if (c->ok && c->read)
        *v = n;
}
static void debug(struct xrt_codec *c, struct xrt_debug_registers *r)
{
    for (unsigned i = 0; i < 4; ++i)
        U64(r->address[i]);
    U64(r->status);
    U64(r->control);
}
static void thread(struct xrt_codec *c, struct xrt_thread *t)
{
    U64(t->id);
    i32(c, &t->tid);
    ENUM(t->state, XRT_EXITED);
    i32(c, &t->signal);
    BOOL(t->newborn);
    BOOL(t->interrupt_pending);
    ENUM(t->reason, XRT_STOP_VFORK_DONE);
    U64(t->breakpoint_address);
    BOOL(t->has_saved_debug);
    if (t->has_saved_debug)
        debug(c, &t->saved_debug);
    BOOL(t->has_arm_watch_slots);
    U8(t->arm_watch_slots);
    BOOL(t->has_arm_watch_hit);
    if (t->has_arm_watch_hit) {
        struct xrt_arm_watch_hit *h = &t->arm_watch_hit;
        U64(h->pc);
        U64(h->address);
        i32(c, &h->code);
        BOOL(h->other_threads_running);
        for (unsigned i = 0; i < 4; ++i) {
            U64(h->before[i]);
            BOOL(h->before_valid[i]);
        }
    }
}
static void event(struct xrt_codec *c, struct xrt_event *e)
{
    U64(e->sequence);
    U64(e->time_ns);
    i32(c, &e->tid);
    ENUM(e->kind, XRT_EVENT_PROCESS_SEPARATED);
    i64(c, &e->detail);
    U64(e->pc);
    U64(e->address);
    U64(e->before);
    U64(e->after);
    U8(e->size);
    BOOL(e->other_threads_running);
    BOOL(e->has_trap);
    if (e->has_trap) {
        U64(e->trap_pc);
        U64(e->trap_address);
        i32(c, &e->trap_code);
    }
    U8(e->watch_phase);
    U8(e->watch_attribution);
    BOOL(e->before_valid);
    BOOL(e->after_valid);
    if (e->watch_phase > 2 || e->watch_attribution > 2 || e->size > 8)
        c->ok = false;
}
void xrt_wire_birth(struct xrt_codec *c, struct xrt_birth *b)
{
    i32(c, &b->pid);
    i32(c, &b->parent_tid);
    ENUM(b->kind, XRT_BIRTH_CLONE_UNKNOWN);
    BOOL(b->stopped);
    BOOL(b->exited);
    i32(c, &b->status);
    U64(b->unpatched_probe);
    BOOL(b->has_saved_debug);
    if (b->has_saved_debug)
        debug(c, &b->saved_debug);
    i32(c, &b->vm_errno);
}
void xrt_wire_target(struct xrt_codec *c, struct xrt_target *t)
{
    uint16_t machine = c->read ? 0 : (t->arch ? t->arch->machine : 0);
    U16(machine);
    if (c->read) {
        t->arch = xrt_arch_get(machine);
        if (!t->arch)
            c->ok = false;
    }
    i32(c, &t->pid);
    ENUM(t->state, XRT_EXITED);
    BOOL(t->owned);
    BOOL(t->follow_processes);
    BOOL(t->stepping);
    BOOL(t->detach_pending);
    BOOL(t->want_run);
    U64(t->generation);
    U64(t->image_epoch);
    U64(t->sequence);
    U64(t->next_thread_id);
    U64(t->next_probe_id);
    count(c, &t->thread_count, XRT_MAX_THREADS);
    count(c, &t->event_count, XRT_MAX_EVENTS);
    count(c, &t->breakpoint_count, XRT_MAX_BREAKPOINTS);
    count(c, &t->birth_count, XRT_MAX_THREADS);
    for (size_t i = 0; i < t->thread_count && c->ok; ++i) {
        thread(c, &t->threads[i]);
        if (c->read && (t->threads[i].tid <= 0 || !t->threads[i].id))
            c->ok = false;
    }
    for (size_t i = 0; i < t->event_count && c->ok; ++i) {
        event(c, &t->events[i]);
        if (c->read && (!t->events[i].sequence ||
                        (i && t->events[i].sequence != t->events[i - 1].sequence + 1)))
            c->ok = false;
    }
    if (c->read && t->event_count && t->events[t->event_count - 1].sequence != t->sequence)
        c->ok = false;
    for (size_t i = 0; i < t->breakpoint_count && c->ok; ++i) {
        struct xrt_breakpoint *p = &t->breakpoints[i];
        U64(p->id);
        U64(p->address);
        xrt_codec_bytes(c, p->original, sizeof(p->original));
        BOOL(p->patched);
        BOOL(p->enabled);
        U64(p->hit_count);
        BOOL(p->pending);
        BOOL(p->internal);
        BOOL(p->temporary);
        if (c->read && (!p->id || p->id >= t->next_probe_id))
            c->ok = false;
    }
    for (unsigned i = 0; i < 4 && c->ok; ++i) {
        struct xrt_watchpoint *p = &t->watchpoints[i];
        BOOL(p->present);
        if (p->present) {
            U64(p->id);
            U64(p->address);
            U8(p->length);
            ENUM(p->kind, XRT_WATCH_EXECUTE);
            U64(p->previous);
            if (!p->id || (p->length != 1 && p->length != 2 && p->length != 4 && p->length != 8))
                c->ok = false;
        }
    }
    for (size_t i = 0; i < t->birth_count && c->ok; ++i)
        xrt_wire_birth(c, &t->births[i]);
    if (c->read && (t->pid < 0 || !t->next_thread_id || !t->next_probe_id))
        c->ok = false;
}
void xrt_wire_registers(struct xrt_codec *c, struct xrt_registers *r)
{
    U16(r->machine);
    const struct xrt_arch *arch = xrt_arch_get(r->machine);
    if (!arch) {
        c->ok = false;
        return;
    }
    for (unsigned i = 0; i < arch->register_count && c->ok; ++i) {
        uint64_t value = 0;
        void *field = (uint8_t *)&r->values + arch->registers[i].snapshot_offset;
        if (!c->read)
            memcpy(&value, field, 8);
        U64(value);
        if (c->ok && c->read)
            memcpy(field, &value, 8);
    }
}
void xrt_wire_xstate(struct xrt_codec *c, struct xrt_xstate *s)
{
    ENUM(s->source, XRT_FPREGS);
    U64(s->features);
    U64(s->in_use);
    U32(s->vector_bytes);
    U32(s->vector_count);
    if (s->vector_count > 32 ||
        (s->vector_bytes != 16 && s->vector_bytes != 32 && s->vector_bytes != 64)) {
        c->ok = false;
        return;
    }
    xrt_codec_bytes(c, s->vectors, sizeof(s->vectors));
    xrt_codec_bytes(c, s->st, sizeof(s->st));
    for (unsigned i = 0; i < 8; ++i) {
        BOOL(s->st_valid[i]);
        U64(s->masks[i]);
    }
    U32(s->mxcsr);
    U16(s->control);
    U16(s->status);
}

void xrt_wire_file_identity(struct xrt_codec *c, struct xrt_file_identity *v)
{
    U64(v->device);
    U64(v->inode);
    i64(c, &v->size);
    i64(c, &v->mtime_sec);
    i64(c, &v->mtime_ns);
    i64(c, &v->ctime_sec);
    i64(c, &v->ctime_ns);
}
void xrt_wire_file_request(struct xrt_codec *c, struct xrt_file_request *r, char *path,
                           size_t capacity)
{
    ENUM(r->kind, XRT_FILE_THREAD_COMM);
    i32(c, &r->tid);
    struct xrt_mapping *m = &r->mapping;
    U64(m->start);
    U64(m->end);
    U64(m->offset);
    U64(m->device_major);
    U64(m->device_minor);
    U64(m->inode);
    uint32_t length = 0;
    if (!c->read && m->path) {
        size_t n = 0;
        while (n < 8192 && m->path[n])
            ++n;
        if (n >= 8192) {
            c->ok = false;
            return;
        }
        length = (uint32_t)n;
    }
    U32(length);
    if (length >= 8192 || (c->read && length >= capacity)) {
        c->ok = false;
        return;
    }
    xrt_codec_bytes(c, c->read ? (void *)path : (void *)m->path, length);
    if (c->ok && c->read) {
        if (memchr(path, 0, length)) {
            c->ok = false;
            return;
        }
        path[length] = 0;
        m->path = path;
    }
}

void xrt_wire_signal(struct xrt_codec *c, struct xrt_signal_info *s)
{
    i32(c, &s->number);
    i32(c, &s->code);
    i32(c, &s->error_number);
    i32(c, &s->sender);
    U64(s->address);
    BOOL(s->has_sender);
    BOOL(s->has_address);
}
