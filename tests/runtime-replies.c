/* Host validation of agent replies.
 * Run: runtime-replies [PATH-TO-XODB-AGENT]
 * Each crafted case starts this executable as a scripted agent behind the
 * production transport (xrt_target_remote) and sends one reply the real agent
 * never produces. The host must break the connection with XRT_PROTOCOL_ERROR
 * and leave the published snapshot unchanged. Matching well-formed replies
 * from the same scripted agent are accepted. With an agent path, a real agent
 * then serves an owned child of this executable with the thread and probe
 * tables at capacity, and every reply must be accepted. */
#define _GNU_SOURCE 1
#include "target_internal.h"
#include "remote_internal.h"
#include "wire_target.h"
#include "xrt_remote.h"
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static unsigned failures;
#define EXPECT(cond)                                                                               \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond);                             \
            ++failures;                                                                            \
        }                                                                                          \
    } while (0)

enum { PID = 4242, CREATE_GENERATION = 5 };
enum trigger { VIEW, REGISTERS, CONTROL, REGISTER_WRITE, CREATE };

struct reply {
    struct xrt_target *snapshot; /* NULL: no snapshot */
    uint64_t value;
    uint32_t status;
    uint8_t extra[1024];
    size_t extra_size;
    void (*patch)(uint8_t *snapshot, size_t size);
};

struct scenario {
    const char *name, *rule;
    int rejected;          /* expected outcome on a host that validates replies */
    enum trigger trigger;
    uint32_t status;       /* host status expected when accepted */
    void (*craft)(struct reply *, uint64_t request_generation);
};

static const struct xrt_arch *other_row(void)
{
    return xrt_arch_get(xrt_arch_native()->machine == XRT_X86_64 ? XRT_AARCH64 : XRT_X86_64);
}

/* The scripted agent's baseline: what a real agent reports for a stopped
 * single-threaded child right after CREATE. */
static void baseline(struct xrt_target *t, const struct xrt_arch *arch)
{
    memset(t, 0, sizeof(*t));
    t->arch = arch;
    t->pid = PID;
    t->state = XRT_STOPPED;
    t->owned = true;
    t->generation = CREATE_GENERATION;
    t->next_thread_id = 2;
    t->next_probe_id = 1;
    t->thread_count = 1;
    t->threads[0] = (struct xrt_thread){.id = 1, .tid = PID, .state = XRT_STOPPED};
}

static struct xrt_breakpoint resolved(const struct xrt_arch *arch, uint64_t id, uint64_t address)
{
    struct xrt_breakpoint p = {.id = id,
                               .address = address,
                               .enabled = true,
                               .patched = true,
                               .width = arch->probes[0].width,
                               .isa_mode = arch->probes[0].isa_mode,
                               .alignment = arch->probes[0].alignment};
    memcpy(p.planted, arch->probes[0].bytes, sizeof(p.planted));
    return p;
}

static struct xrt_target *view_of(struct reply *r)
{
    struct xrt_target *t = r->snapshot;
    r->status = XRT_OK;
    return t;
}

static void put64(uint8_t *at, uint64_t value)
{
    struct xrt_codec c = xrt_codec(at, 8, false);
    xrt_codec_u64(&c, &value);
}

/* Offsets of the trailing breakpoint record when a snapshot has no events,
 * births or watchpoints: the record is followed only by four absent flags. */
enum { BP_RECORD = 40, BP_PENDING = 30, BP_WIDTH = 33, BP_PLANTED = 36 };
static uint8_t *last_breakpoint(uint8_t *bytes, size_t size)
{
    return bytes + size - XRT_MAX_WATCHPOINTS - BP_RECORD;
}

/* --- snapshot identities --- */
static void dup_thread_id(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    t->threads[1] = (struct xrt_thread){.id = 1, .tid = PID + 1, .state = XRT_STOPPED};
    t->thread_count = 2;
    t->next_thread_id = 3;
}
static void dup_tid(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    t->threads[1] = (struct xrt_thread){.id = 2, .tid = PID, .state = XRT_STOPPED};
    t->thread_count = 2;
    t->next_thread_id = 3;
}
static void thread_id_unallocated(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    t->threads[0].id = t->next_thread_id;
}
static void dup_breakpoint_id(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    const uint64_t step = t->arch->trap_alignment;
    t->breakpoints[0] = resolved(t->arch, 1, 0x400000);
    t->breakpoints[1] = resolved(t->arch, 1, 0x400000 + 16 * step);
    t->breakpoint_count = 2;
    t->next_probe_id = 3;
}
static void dup_breakpoint_address(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    t->breakpoints[0] = resolved(t->arch, 1, 0x400000);
    t->breakpoints[1] = resolved(t->arch, 2, 0x400000);
    t->breakpoint_count = 2;
    t->next_probe_id = 3;
}
static void watch_id_unallocated(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    t->next_probe_id = 2;
    t->watchpoints[0] = (struct xrt_watchpoint){
        .id = 2, .address = 0x601000, .length = 8, .kind = XRT_WATCH_WRITE, .present = true};
}
static void watch_id_of_breakpoint(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    t->breakpoints[0] = resolved(t->arch, 1, 0x400000);
    t->breakpoint_count = 1;
    t->next_probe_id = 2;
    t->watchpoints[0] = (struct xrt_watchpoint){
        .id = 1, .address = 0x601000, .length = 8, .kind = XRT_WATCH_WRITE, .present = true};
}
static void dup_watch_id(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    t->next_probe_id = 3;
    t->watchpoints[0] = (struct xrt_watchpoint){
        .id = 1, .address = 0x601000, .length = 8, .kind = XRT_WATCH_WRITE, .present = true};
    t->watchpoints[2] = (struct xrt_watchpoint){
        .id = 1, .address = 0x601008, .length = 8, .kind = XRT_WATCH_WRITE, .present = true};
}
static void watch_misaligned(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    t->next_probe_id = 2;
    t->watchpoints[0] = (struct xrt_watchpoint){
        .id = 1, .address = 0x601004, .length = 8, .kind = XRT_WATCH_WRITE, .present = true};
}
static void valid_view(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    t->generation = CREATE_GENERATION + 3;
    for (unsigned i = 1; i < 4; ++i)
        t->threads[i] = (struct xrt_thread){.id = 7 - i, .tid = PID + 9 - (int32_t)i,
                                            .state = XRT_STOPPED};
    t->thread_count = 4;
    t->next_thread_id = 8;
    const uint64_t step = t->arch->trap_alignment;
    t->breakpoints[0] = resolved(t->arch, 4, 0x400000 + 32 * step);
    t->breakpoints[1] = resolved(t->arch, 2, 0x400000);
    t->breakpoints[1].enabled = t->breakpoints[1].patched = false;
    t->breakpoints[2] = (struct xrt_breakpoint){.id = 9, .pending = true, .enabled = true};
    t->breakpoint_count = 3;
    t->next_probe_id = 10;
    t->watchpoints[1] = (struct xrt_watchpoint){
        .id = 3, .address = 0x601000, .length = 8, .kind = XRT_WATCH_WRITE, .present = true};
    t->watchpoints[3] = (struct xrt_watchpoint){
        .id = 5, .address = 0x601010, .length = 1, .kind = XRT_WATCH_EXECUTE, .present = true};
}
/* --- event PC availability --- */
#define EVENT_PC UINT64_C(0x1122334455667788)
static void patch_pc_unknown(uint8_t *bytes, size_t size)
{
    static const uint8_t pc[8] = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88};
    for (size_t i = 0; i + 9 <= size; ++i)
        if (!memcmp(bytes + i, pc, 8) && bytes[i + 8] == 1) {
            bytes[i + 8] = 0;
            return;
        }
}
static void event_pc_unknown_nonzero(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    t->event_count = 1;
    t->sequence = 1;
    t->events[0] = (struct xrt_event){
        .sequence = 1, .tid = PID, .kind = XRT_EVENT_STOP, .pc = EVENT_PC, .pc_known = 1};
    r->patch = patch_pc_unknown;
}
static void event_pc_known(struct reply *r, uint64_t g)
{
    event_pc_unknown_nonzero(r, g);
    r->patch = NULL;
}
/* --- identity and generation --- */
static void generation_backwards(struct reply *r, uint64_t g)
{
    (void)g;
    view_of(r)->generation = CREATE_GENERATION - 1;
}
static void generation_same(struct reply *r, uint64_t g)
{
    (void)g;
    view_of(r)->generation = CREATE_GENERATION;
}
static void row_changed(struct reply *r, uint64_t g)
{
    (void)g;
    view_of(r)->arch = other_row();
}
/* --- breakpoint encodings already refused by the decoder --- */
static void pending_with_width(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    t->breakpoints[0] = (struct xrt_breakpoint){.id = 1, .pending = true, .enabled = true};
    t->breakpoint_count = 1;
    t->next_probe_id = 2;
    r->patch = NULL;
}
static void patch_pending_width(uint8_t *bytes, size_t size)
{
    last_breakpoint(bytes, size)[BP_WIDTH] = 1;
}
static void pending_encoded(struct reply *r, uint64_t g)
{
    pending_with_width(r, g);
    r->patch = patch_pending_width;
}
static void patch_resolved_pending(uint8_t *bytes, size_t size)
{
    last_breakpoint(bytes, size)[BP_PENDING] = 1;
}
static void resolved_marked_pending(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_target *t = view_of(r);
    t->breakpoints[0] = resolved(t->arch, 1, 0x400000);
    t->breakpoint_count = 1;
    t->next_probe_id = 2;
    r->patch = patch_resolved_pending;
}
static void patch_planted(uint8_t *bytes, size_t size)
{
    last_breakpoint(bytes, size)[BP_PLANTED] ^= 0x5a;
}
static void resolved_wrong_trap(struct reply *r, uint64_t g)
{
    resolved_marked_pending(r, g);
    r->patch = patch_planted;
}
/* --- register replies --- */
static void registers_of(struct reply *r, const struct xrt_registers *regs,
                         void (*edit)(uint8_t *bytes))
{
    r->status = XRT_OK;
    struct xrt_codec c = xrt_codec(r->extra, sizeof(r->extra), false);
    xrt_wire_registers(&c, (struct xrt_registers *)regs);
    if (!c.ok) {
        fprintf(stderr, "scripted agent: register encode failed\n");
        exit(3);
    }
    r->extra_size = c.at;
    if (edit)
        edit(r->extra);
}
/* Values follow 7 identity bytes and the layout byte, one u64 per descriptor. */
static uint8_t *register_slot(uint8_t *bytes, unsigned id)
{
    return bytes + 8 + 8 * id;
}
static void set_slot0(uint8_t *bytes)
{
    put64(register_slot(bytes, 0), UINT64_C(0x1111111111111111));
}
static void absent_slot_carries_value(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_registers regs = {.abi = xrt_arch_abi(xrt_arch_native())};
    regs.absent_count = 1;
    regs.absent_id[0] = 0;
    registers_of(r, &regs, set_slot0);
}
static void unknown_slot_carries_value(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_registers regs = {.abi = xrt_arch_abi(xrt_arch_native())};
    regs.unknown_count = 1;
    regs.unknown_id[0] = 0;
    registers_of(r, &regs, set_slot0);
}
static void absent_listed_twice(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_registers regs = {.abi = xrt_arch_abi(xrt_arch_native())};
    regs.absent_count = 1;
    regs.unknown_count = 1;
    regs.unknown_id[0] = 1;
    registers_of(r, &regs, NULL);
    /* Lists: [absent count][ids][unknown count][ids]. Unknown 1 becomes 0,
     * which is also listed absent. */
    const size_t lists = 8 + 8 * (size_t)xrt_arch_native()->register_count;
    r->extra[lists + 4] = 0;
    r->extra[lists + 5] = 0;
}
static void valid_registers(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_registers regs = {.abi = xrt_arch_abi(xrt_arch_native())};
    regs.absent_count = 1;
    regs.absent_id[0] = 0;
    regs.unknown_count = 1;
    regs.unknown_id[0] = 2;
    registers_of(r, &regs, NULL);
}
static void registers_other_row(struct reply *r, uint64_t g)
{
    (void)g;
    struct xrt_registers regs = {.abi = xrt_arch_abi(other_row())};
    registers_of(r, &regs, NULL);
}
static void m68k_sr_wide(uint8_t *bytes)
{
    put64(register_slot(bytes, 17), UINT64_C(0x10000));
}
static void m68k_pc_wide(uint8_t *bytes)
{
    put64(register_slot(bytes, 16), UINT64_C(0x100000000));
}
static void m68k_registers(struct reply *r, void (*edit)(uint8_t *))
{
    struct xrt_registers regs = {.abi = xrt_arch_abi(xrt_arch_get(XRT_M68K))};
    regs.values.m68k.sr = 0xffff;
    regs.values.m68k.pc = 0xfffffffe;
    registers_of(r, &regs, edit);
}
static void sr_wide(struct reply *r, uint64_t g)
{
    (void)g;
    m68k_registers(r, m68k_sr_wide);
}
static void pc_wide(struct reply *r, uint64_t g)
{
    (void)g;
    m68k_registers(r, m68k_pc_wide);
}
static void m68k_valid(struct reply *r, uint64_t g)
{
    (void)g;
    m68k_registers(r, NULL);
}
/* --- REGISTER_WRITE / CONTROL_WRITE flags --- */
static void mutation(struct reply *r, uint64_t g, uint64_t value, uint32_t status, uint64_t next)
{
    struct xrt_target *t = view_of(r);
    r->value = value;
    r->status = status;
    t->generation = g + next;
}
static void flags_issued_two(struct reply *r, uint64_t g)
{
    mutation(r, g, 0x0002, XRT_PARTIAL_REGISTER_WRITE, 1);
}
static void flags_confirmed_two(struct reply *r, uint64_t g)
{
    mutation(r, g, 0x0201, XRT_OK, 1);
}
static void flags_high_byte(struct reply *r, uint64_t g)
{
    mutation(r, g, 0x010101, XRT_OK, 1);
}
static void flags_confirmed_not_issued(struct reply *r, uint64_t g)
{
    mutation(r, g, 0x0100, XRT_OK, 1);
}
static void flags_ok_unconfirmed(struct reply *r, uint64_t g)
{
    mutation(r, g, 0x0001, XRT_OK, 1);
}
static void flags_failed_confirmed(struct reply *r, uint64_t g)
{
    mutation(r, g, 0x0101, XRT_PARTIAL_REGISTER_WRITE, 1);
}
static void flags_issued_generation_kept(struct reply *r, uint64_t g)
{
    mutation(r, g, 0x0101, XRT_OK, 0);
}
static void flags_issued_no_snapshot(struct reply *r, uint64_t g)
{
    r->snapshot = NULL;
    r->value = 0x0001;
    r->status = XRT_PARTIAL_REGISTER_WRITE;
    (void)g;
}
static void flags_ok(struct reply *r, uint64_t g)
{
    mutation(r, g, 0x0101, XRT_OK, 1);
}
static void flags_partial(struct reply *r, uint64_t g)
{
    mutation(r, g, 0x0001, XRT_PARTIAL_REGISTER_WRITE, 1);
}
static void flags_preflight(struct reply *r, uint64_t g)
{
    mutation(r, g, 0, XRT_NOT_STOPPED, 0);
}
static void flags_stale(struct reply *r, uint64_t g)
{
    mutation(r, g, 0, XRT_STALE_SNAPSHOT, 2);
}

static const struct scenario scenarios[] = {
    {"duplicate-thread-id", "thread identity", 1, VIEW, 0, dup_thread_id},
    {"duplicate-tid", "thread identity", 1, VIEW, 0, dup_tid},
    {"thread-id-not-allocated", "thread identity", 1, VIEW, 0, thread_id_unallocated},
    {"duplicate-breakpoint-id", "probe identity", 1, VIEW, 0, dup_breakpoint_id},
    {"duplicate-resolved-address", "probe identity", 1, VIEW, 0, dup_breakpoint_address},
    {"watch-id-not-allocated", "probe identity", 1, VIEW, 0, watch_id_unallocated},
    {"watch-id-of-breakpoint", "probe identity", 1, VIEW, 0, watch_id_of_breakpoint},
    {"duplicate-watch-id", "probe identity", 1, VIEW, 0, dup_watch_id},
    {"watch-misaligned", "probe identity", 1, VIEW, 0, watch_misaligned},
    {"valid-view", "accepted", 0, VIEW, XRT_OK, valid_view},
    {"event-pc-unknown-nonzero", "event availability", 1, VIEW, 0, event_pc_unknown_nonzero},
    {"event-pc-known", "accepted", 0, VIEW, XRT_OK, event_pc_known},
    {"generation-backwards", "generation", 1, VIEW, 0, generation_backwards},
    {"generation-unchanged", "accepted", 0, VIEW, XRT_OK, generation_same},
    {"snapshot-row-changed", "target identity", 1, VIEW, 0, row_changed},
    {"create-row-not-hello", "target identity", 1, CREATE, 0, NULL},
    {"pending-with-encoding", "breakpoint encoding", 1, VIEW, 0, pending_encoded},
    {"resolved-marked-pending", "breakpoint encoding", 1, VIEW, 0, resolved_marked_pending},
    {"resolved-wrong-trap", "breakpoint encoding", 1, VIEW, 0, resolved_wrong_trap},
    {"absent-slot-value", "register availability", 1, REGISTERS, 0, absent_slot_carries_value},
    {"unknown-slot-value", "register availability", 1, REGISTERS, 0,
     unknown_slot_carries_value},
    {"id-absent-and-unknown", "register availability", 1, REGISTERS, 0, absent_listed_twice},
    {"valid-availability", "accepted", 0, REGISTERS, XRT_OK, valid_registers},
    {"registers-other-row", "target identity", 1, REGISTERS, 0, registers_other_row},
    {"m68k-sr-wide", "register width", 1, REGISTERS, 0, sr_wide},
    {"m68k-pc-wide", "register width", 1, REGISTERS, 0, pc_wide},
    {"m68k-full-width", "accepted", 0, REGISTERS, XRT_OK, m68k_valid},
    {"control-issued-2", "mutation flags", 1, CONTROL, 0, flags_issued_two},
    {"control-confirmed-2", "mutation flags", 1, CONTROL, 0, flags_confirmed_two},
    {"control-high-byte", "mutation flags", 1, CONTROL, 0, flags_high_byte},
    {"control-confirmed-not-issued", "mutation flags", 1, CONTROL, 0,
     flags_confirmed_not_issued},
    {"control-ok-unconfirmed", "mutation flags", 1, CONTROL, 0, flags_ok_unconfirmed},
    {"control-failed-confirmed", "mutation flags", 1, CONTROL, 0, flags_failed_confirmed},
    {"control-issued-generation-kept", "mutation flags", 1, CONTROL, 0,
     flags_issued_generation_kept},
    {"control-issued-no-snapshot", "mutation flags", 1, CONTROL, 0, flags_issued_no_snapshot},
    {"control-ok", "accepted", 0, CONTROL, XRT_OK, flags_ok},
    {"control-partial", "accepted", 0, CONTROL, XRT_PARTIAL_REGISTER_WRITE, flags_partial},
    {"control-preflight", "accepted", 0, CONTROL, XRT_NOT_STOPPED, flags_preflight},
    {"control-stale", "accepted", 0, CONTROL, XRT_STALE_SNAPSHOT, flags_stale},
    {"register-write-confirmed-2", "mutation flags", 1, REGISTER_WRITE, 0, flags_confirmed_two},
    {"register-write-ok-unconfirmed", "mutation flags", 1, REGISTER_WRITE, 0,
     flags_ok_unconfirmed},
    {"register-write-ok", "accepted", 0, REGISTER_WRITE, XRT_OK, flags_ok},
    {"register-write-partial", "accepted", 0, REGISTER_WRITE, XRT_PARTIAL_REGISTER_WRITE,
     flags_partial},
};
#define SCENARIOS (sizeof(scenarios) / sizeof(scenarios[0]))

static const struct xrt_arch *target_row(const struct scenario *s)
{
    return s->craft == sr_wide || s->craft == pc_wide || s->craft == m68k_valid
               ? xrt_arch_get(XRT_M68K)
               : xrt_arch_native();
}

/* Scripted agent: answers HELLO and CREATE as a real agent would, then
 * replies to every other request with the scenario's crafted reply. */
static int scripted_agent(const struct scenario *s)
{
    uint8_t *request = malloc(XRT_WIRE_MAX_BODY), *body = malloc(XRT_WIRE_MAX_BODY);
    struct xrt_target *created = calloc(1, sizeof(*created)),
                      *crafted = calloc(1, sizeof(*crafted));
    if (!request || !body || !created || !crafted)
        return 4;
    const struct xrt_arch *row = target_row(s);
    baseline(created, row);
    for (;;) {
        struct xrt_wire_frame f;
        const enum xrt_wire_result got = xrt_wire_read(0, &f, request, XRT_WIRE_MAX_BODY, 10000);
        if (got == XRT_WIRE_EOF)
            break;
        if (got != XRT_WIRE_OK)
            return 5;
        struct xrt_codec in = xrt_codec(request, f.size, true);
        uint64_t generation = 0;
        xrt_codec_u64(&in, &generation);
        struct reply r = {.status = XRT_OK};
        if (f.op == XRT_RPC_HELLO) {
            r.value = s->trigger == CREATE ? other_row()->machine : row->machine;
            struct xrt_codec meta = xrt_codec(r.extra, sizeof(r.extra), false);
            uint64_t now = xrt_now();
            uint32_t hz = 100, page = 4096;
            xrt_codec_u64(&meta, &now);
            xrt_codec_u32(&meta, &hz);
            xrt_codec_u32(&meta, &page);
            r.extra_size = meta.at;
        } else if (f.op == XRT_RPC_CREATE) {
            r.value = 1;
            r.snapshot = created;
        } else if (f.op == XRT_RPC_DESTROY) {
        } else {
            memcpy(crafted, created, sizeof(*crafted));
            r.snapshot = crafted;
            if (s->craft)
                s->craft(&r, generation);
        }
        struct xrt_codec out = xrt_codec(body, XRT_WIRE_MAX_BODY, false);
        uint32_t extra = (uint32_t)r.extra_size;
        bool present = r.snapshot != NULL, shared = false;
        uint32_t root = 1;
        xrt_codec_u64(&out, &r.value);
        xrt_codec_u32(&out, &extra);
        xrt_codec_bytes(&out, r.extra, r.extra_size);
        xrt_codec_bool(&out, &present);
        if (present) {
            xrt_codec_bool(&out, &shared);
            xrt_codec_u32(&out, &root);
            const size_t at = out.at;
            xrt_wire_target(&out, r.snapshot);
            if (out.ok && r.patch)
                r.patch(body + at, out.at - at);
        }
        if (!out.ok)
            return 6;
        f.flags = 1;
        f.status = r.status;
        f.size = (uint32_t)out.at;
        if (xrt_wire_write(1, &f, body, 10000) != XRT_WIRE_OK)
            return 7;
    }
    free(request);
    free(body);
    free(created);
    free(crafted);
    return 0;
}

static enum xrt_status trigger(struct xrt_target *t, enum trigger kind)
{
    switch (kind) {
    case VIEW:
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_VIEW});
    case REGISTERS: {
        struct xrt_registers regs;
        memset(&regs, 0x5a, sizeof(regs));
        const struct xrt_registers before = regs;
        const enum xrt_status status = xrt_target_registers(t, PID, &regs);
        if (status != XRT_OK)
            EXPECT(memcmp(&regs, &before, sizeof(regs)) == 0);
        return status;
    }
    case CONTROL:
        return xrt_target_control_write(
            t, PID, &(struct xrt_control_request){.count = 1, .value = {0x401000}});
    case REGISTER_WRITE: {
        const char *name = xrt_arch_native()->registers[3].name;
        return xrt_target_register_write(t, PID, name, strlen(name), 7);
    }
    case CREATE:
        break;
    }
    return XRT_INVALID_ARGUMENT;
}

static int crafted_replies(const char *self)
{
    unsigned mismatched = 0;
    for (size_t i = 0; i < SCENARIOS; ++i) {
        const struct scenario *s = &scenarios[i];
        const char *argv[] = {self, "--scripted-agent", s->name, NULL};
        struct xrt_target *t = NULL;
        enum xrt_status status = xrt_target_remote(argv, &t);
        int rejected = 0;
        if (s->trigger == CREATE) {
            rejected = status == XRT_PROTOCOL_ERROR;
            EXPECT(rejected ? t == NULL : status == XRT_OK);
        } else if (status != XRT_OK) {
            fprintf(stderr, "%s: transport %d\n", s->name, status);
            ++failures;
            continue;
        } else {
            struct xrt_target_view before;
            xrt_target_view(t, &before);
            EXPECT(before.generation == CREATE_GENERATION && before.thread_count == 1);
            const struct xrt_arch *const arch_before = t->arch;
            status = trigger(t, s->trigger);
            rejected = status == XRT_PROTOCOL_ERROR;
            if (rejected) {
                EXPECT(xrt_remote_health(t) == XRT_PROTOCOL_ERROR);
                struct xrt_target_view after;
                xrt_target_view(t, &after);
                EXPECT(after.generation == before.generation &&
                       after.thread_count == before.thread_count &&
                       after.breakpoint_count == before.breakpoint_count &&
                       t->arch == arch_before);
            } else {
                EXPECT(status == s->status && xrt_remote_health(t) == XRT_OK);
            }
        }
        if (t)
            EXPECT(xrt_target_destroy(t) == XRT_OK);
        printf("%-32s %-22s expected %-8s got %-8s %s\n", s->name, s->rule,
               s->rejected ? "rejected" : "accepted", rejected ? "rejected" : "accepted",
               rejected == s->rejected ? "PASS" : "FAIL");
        mismatched += rejected != s->rejected;
    }
    return (int)mismatched;
}

/* The encoder never carries a sentinel under an unavailable descriptor. */
static void canonical_unavailable(void)
{
    const struct xrt_arch *arch = xrt_arch_native();
    struct xrt_registers regs = {.abi = xrt_arch_abi(arch)};
    memset(&regs.values, 0x11, sizeof(regs.values));
    for (unsigned i = 0; i < arch->register_count; ++i)
        if (arch->registers[i].width < 8) {
            uint64_t narrow = 0;
            memcpy((unsigned char *)&regs.values + arch->registers[i].snapshot_offset, &narrow, 8);
        }
    EXPECT(xrt_registers_mark_absent(&regs, 0) == XRT_OK);
    EXPECT(xrt_registers_mark_unknown(&regs, 1) == XRT_OK);
    uint8_t bytes[1024];
    struct xrt_codec out = xrt_codec(bytes, sizeof(bytes), false);
    xrt_wire_registers(&out, &regs);
    EXPECT(out.ok);
    struct xrt_registers got = {0};
    struct xrt_codec in = xrt_codec(bytes, out.at, true);
    xrt_wire_registers(&in, &got);
    EXPECT(in.ok && in.at == out.at);
    for (unsigned i = 0; i < 16; ++i)
        EXPECT(register_slot(bytes, 0)[i] == 0);
    uint64_t value = 1;
    EXPECT(xrt_registers_value_desc(&got, &arch->registers[0], &value) ==
               XRT_REGISTER_UNAVAILABLE &&
           value == 1);
    EXPECT(xrt_registers_value_desc(&got, &arch->registers[2], &value) == XRT_OK &&
           value == UINT64_C(0x1111111111111111));
}

/* Owned child for the real agent: THREADS sleeping threads. */
static void *sleeper(void *unused)
{
    (void)unused;
    for (;;)
        pause();
    return NULL;
}
static int child(int threads)
{
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 64 * 1024);
    for (int i = 0; i < threads; ++i) {
        pthread_t thread;
        if (pthread_create(&thread, &attr, sleeper, NULL))
            return 2;
    }
    for (;;)
        pause();
}

static void real_agent(const char *agent, const char *self, int threads)
{
    struct xrt_target *t = NULL;
    const char *transport[] = {agent, "--stdio", NULL};
    if (xrt_target_remote(transport, &t) != XRT_OK) {
        EXPECT(0);
        return;
    }
    char count[16];
    snprintf(count, sizeof(count), "%d", threads);
    const char *argv[] = {self, "--threads", count, NULL};
    EXPECT(xrt_target_launch(t, argv) == XRT_OK);
    EXPECT(xrt_target_continue(t) == XRT_OK);
    struct xrt_target_view v;
    const uint64_t deadline = xrt_now() + UINT64_C(20000000000);
    do {
        EXPECT(xrt_target_poll(t) == XRT_OK);
        xrt_target_view(t, &v);
        if (v.thread_count < (size_t)threads + 1)
            usleep(1000);
    } while (v.thread_count < (size_t)threads + 1 && xrt_now() < deadline);
    EXPECT(v.thread_count == (size_t)threads + 1);
    EXPECT(xrt_target_interrupt(t) == XRT_OK);
    EXPECT(xrt_target_wait_stopped(t) == XRT_OK);
    int32_t tid = 0;
    EXPECT(xrt_target_stopped_tid(t, &tid) == XRT_OK);
    struct xrt_registers regs;
    uint64_t pc = 0, sp = 0;
    EXPECT(xrt_target_registers(t, tid, &regs) == XRT_OK);
    EXPECT(xrt_registers_pc(&regs, &pc) == XRT_OK);
    EXPECT(xrt_registers_role(&regs, XRT_ROLE_SP, &sp) == XRT_OK);
    const struct xrt_arch *arch = t->arch;
    uint64_t id = 0;
    for (unsigned i = 0; i + 1 < XRT_MAX_BREAKPOINTS; ++i)
        EXPECT(xrt_target_breakpoint_set(t, pc + (uint64_t)i * arch->trap_alignment, false,
                                         &id) == XRT_OK);
    EXPECT(xrt_target_breakpoint_reserve(t, &id) == XRT_OK);
    uint8_t capacity = 0;
    EXPECT(xrt_target_watchpoint_capacity(t, &capacity) == XRT_OK);
    for (unsigned i = 0; i < capacity; ++i)
        EXPECT(xrt_target_watchpoint_set(t, (sp & ~UINT64_C(7)) + 8 * i, 8, XRT_WATCH_WRITE,
                                         &id) == XRT_OK);
    EXPECT(xrt_target_control_write(t, tid, &(struct xrt_control_request){.count = 1,
                                                                          .value = {pc}}) ==
           XRT_OK);
    EXPECT(t->last_mutation.issued && t->last_mutation.confirmed);
    if (arch->machine == XRT_X86_64) {
        /* The kernel forces eflags bit 1: issued, not confirmed, still valid. */
        EXPECT(xrt_target_register_write(t, tid, "eflags", 6, 0) == XRT_PARTIAL_REGISTER_WRITE);
        EXPECT(t->last_mutation.issued && !t->last_mutation.confirmed);
    }
    const uint64_t generation = t->generation;
    EXPECT(xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_INVALIDATE}) == XRT_OK);
    EXPECT(t->generation > generation);
    EXPECT(xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_VIEW}) == XRT_OK);
    xrt_target_view(t, &v);
    EXPECT(v.thread_count == (size_t)threads + 1 && v.breakpoint_count == XRT_MAX_BREAKPOINTS);
    EXPECT(xrt_target_registers(t, tid, &regs) == XRT_OK);
    EXPECT(xrt_remote_health(t) == XRT_OK);
    printf("real agent: %zu threads, %zu breakpoints, %u watchpoints, mutations and register "
           "replies accepted\n",
           v.thread_count, v.breakpoint_count, (unsigned)capacity);
    EXPECT(xrt_target_close(t) == XRT_OK);
    EXPECT(xrt_target_destroy(t) == XRT_OK);
}

int main(int argc, char **argv)
{
    if (argc == 3 && strcmp(argv[1], "--scripted-agent") == 0) {
        for (size_t i = 0; i < SCENARIOS; ++i)
            if (strcmp(scenarios[i].name, argv[2]) == 0)
                return scripted_agent(&scenarios[i]);
        return 2;
    }
    if (argc == 3 && strcmp(argv[1], "--threads") == 0)
        return child(atoi(argv[2]));
    signal(SIGPIPE, SIG_IGN);
    char self[4096];
    const ssize_t length = readlink("/proc/self/exe", self, sizeof(self) - 1);
    if (length <= 0)
        return 1;
    self[length] = 0;
    canonical_unavailable();
    const int mismatched = crafted_replies(self);
    if (argc > 1)
        real_agent(argv[1], self, argc > 2 ? atoi(argv[2]) : XRT_MAX_THREADS - 1);
    if (mismatched || failures) {
        fprintf(stderr, "runtime replies: %d unexpected outcome(s), %u failure(s)\n", mismatched,
                failures);
        return 1;
    }
    puts("C replies: hostile snapshots, register replies and mutation flags rejected; real "
         "agent replies accepted");
    return 0;
}
