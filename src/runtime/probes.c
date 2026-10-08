#define _GNU_SOURCE 1
#include "target_internal.h"
#include "loongarch_step.h"

int xrt_breakpoint_at(const struct xrt_target *t, uint64_t address)
{
    for (size_t i = 0; i < t->breakpoint_count; ++i)
        if (!t->breakpoints[i].pending && t->breakpoints[i].address == address)
            return (int)i;
    return -1;
}
int xrt_breakpoint_index(const struct xrt_target *t, uint64_t id)
{
    for (size_t i = 0; i < t->breakpoint_count; ++i)
        if (t->breakpoints[i].id == id)
            return (int)i;
    return -1;
}
enum xrt_status xrt_target_patch_span(struct xrt_target *t, int32_t tid, uint64_t address,
                                      const uint8_t *bytes, size_t width, size_t *accepted)
{
    if (!accepted)
        return XRT_INVALID_ARGUMENT;
    *accepted = 0;
    if (!t || !bytes || width < 1 || width > 4 || address > UINT64_MAX - width)
        return XRT_INVALID_ARGUMENT;
    if (t->patch)
        return t->patch(t->patch_ctx, tid, address, bytes, width, accepted);
    return xrt_memory_patch(tid, address, bytes, width, accepted);
}
enum xrt_status xrt_patch_instruction_tid(struct xrt_target *t, int32_t tid, uint64_t address,
                                          const uint8_t *bytes, size_t width)
{
    if (!t->arch || !xrt_arch_breakpoint_valid(t->arch->machine, address, width))
        return XRT_INVALID_BREAKPOINT_ADDRESS;
    size_t count = 0;
    const enum xrt_status result = xrt_target_patch_span(t, tid, address, bytes, width, &count);
    if (result == XRT_OK && count == width)
        return XRT_OK;
    return count ? XRT_PARTIAL_MEMORY_WRITE : result;
}
enum xrt_status xrt_patch_instruction(struct xrt_target *t, uint64_t address, const uint8_t *bytes,
                                      size_t width)
{
    int32_t tid;
    TRY(xrt_target_stopped_tid(t, &tid));
    return xrt_patch_instruction_tid(t, tid, address, bytes, width);
}
enum xrt_status xrt_target_commit_bytes(struct xrt_target *t, uint64_t address,
                                        const uint8_t bytes[4], const uint8_t rollback[4],
                                        uint8_t width)
{
    if (!t || !bytes || !rollback)
        return XRT_INVALID_ARGUMENT;
    if (!t->identity_admitted)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (t->plant_cleanup.active)
        return XRT_INVALID_STATE;
    if (width < 1 || width > 4)
        return XRT_INVALID_ARGUMENT;
    int32_t tid;
    TRY(xrt_target_stopped_tid(t, &tid));
    size_t accepted = 0;
    const enum xrt_status status = xrt_target_patch_span(t, tid, address, bytes, width, &accepted);
    if (status == XRT_OK && accepted == width)
        return XRT_OK;
    if (!accepted)
        return status != XRT_OK ? status : XRT_PARTIAL_MEMORY_WRITE;
    size_t restored = 0;
    const enum xrt_status back =
        xrt_target_patch_span(t, tid, address, rollback, accepted, &restored);
    if (back == XRT_OK && restored == accepted)
        return status != XRT_OK ? status : XRT_PARTIAL_MEMORY_WRITE;
    t->plant_cleanup.active = 1;
    t->plant_cleanup.address = address;
    t->plant_cleanup.width = width;
    memcpy(t->plant_cleanup.original, rollback, 4);
    return XRT_PARTIAL_MEMORY_WRITE;
}
enum xrt_status xrt_target_commit_plant(struct xrt_target *t, uint64_t address,
                                        const struct xrt_probe_encoding *encoding,
                                        const uint8_t original[4])
{
    if (!t || !encoding || !original)
        return XRT_INVALID_ARGUMENT;
    return xrt_target_commit_bytes(t, address, encoding->bytes, original, encoding->width);
}
enum xrt_status xrt_target_commit_owned(struct xrt_target *t, uint64_t address,
                                        const uint8_t bytes[4], const uint8_t rollback[4],
                                        uint8_t width)
{
    if (!t || !bytes || !rollback)
        return XRT_INVALID_ARGUMENT;
    /* The patch seam is how a host test simulates a multi-byte trap. */
    if (!t->patch && (!t->arch || !xrt_arch_breakpoint_valid(t->arch->machine, address, width)))
        return XRT_INVALID_BREAKPOINT_ADDRESS;
    return xrt_target_commit_bytes(t, address, bytes, rollback, width);
}
enum xrt_status xrt_target_settle_plant_cleanup(struct xrt_target *t, int drop_if_exited)
{
    if (!t)
        return XRT_INVALID_ARGUMENT;
    if (!t->plant_cleanup.active)
        return XRT_OK;
    if (drop_if_exited && t->state == XRT_EXITED) {
        t->plant_cleanup.active = 0;
        return XRT_OK;
    }
    if (t->state != XRT_STOPPED)
        return XRT_INVALID_STATE;
    const enum xrt_status status = xrt_target_retry_plant_cleanup(t);
    if (status == XRT_OK)
        return XRT_OK;
    if (drop_if_exited && status == XRT_PROCESS_GONE) {
        t->plant_cleanup.active = 0;
        return XRT_OK;
    }
    return XRT_INVALID_STATE;
}
enum xrt_status xrt_target_retry_plant_cleanup(struct xrt_target *t)
{
    if (!t || !t->plant_cleanup.active)
        return XRT_OK;
    if (!t->identity_admitted)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    int32_t tid;
    TRY(xrt_target_stopped_tid(t, &tid));
    size_t accepted = 0;
    const enum xrt_status status = xrt_target_patch_span(
        t, tid, t->plant_cleanup.address, t->plant_cleanup.original, t->plant_cleanup.width,
        &accepted);
    if (status == XRT_OK && accepted == t->plant_cleanup.width) {
        t->plant_cleanup.active = 0;
        return XRT_OK;
    }
    return status != XRT_OK ? status : XRT_PARTIAL_MEMORY_WRITE;
}
enum xrt_status xrt_target_read(const struct xrt_target *t, uint64_t address, void *out,
                                size_t size, size_t *count)
{
    if (!count || (!out && size))
        return XRT_INVALID_ARGUMENT;
    *count = 0;
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_READ,
                                                     .args = {address, size},
                                                     .out = out,
                                                     .capacity = size,
                                                     .length = count});
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (!size)
        return XRT_OK;
    int32_t tid;
    TRY(xrt_target_stopped_tid(t, &tid));
    const enum xrt_status result = xrt_memory_read(tid, address, out, size, count);
    if (result != XRT_OK)
        return result == XRT_INVALID_ADDRESS ? result : XRT_MEMORY_UNREADABLE;
    uint8_t *bytes = out;
    for (size_t b = 0; b < t->breakpoint_count; ++b) {
        const struct xrt_breakpoint *p = &t->breakpoints[b];
        if (!p->patched || !p->width)
            continue;
        for (size_t i = 0; i < p->width; ++i) {
            const uint64_t at = p->address + i;
            if (at >= address && at - address < *count)
                bytes[at - address] = p->original[i];
        }
    }
    return XRT_OK;
}
enum xrt_status xrt_target_write(struct xrt_target *t, uint64_t address, const void *data,
                                 size_t size)
{
    if (t && t->connection)
        return xrt_remote_call(
            t,
            &(struct xrt_call){.op = XRT_RPC_WRITE, .args = {address}, .data = data, .size = size});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (size > 4096 || address > UINT64_MAX - size)
        return XRT_INVALID_ADDRESS;
    if (!data && size)
        return XRT_INVALID_ARGUMENT;
    int32_t tid;
    TRY(xrt_target_stopped_tid(t, &tid));
    const uint8_t *bytes = data;
    size_t written = 0;
    enum xrt_status result = XRT_OK;
    for (; written < size; ++written) {
        const uint64_t at = address + written;
        struct xrt_breakpoint *overlay = NULL;
        for (size_t i = 0; i < t->breakpoint_count; ++i) {
            struct xrt_breakpoint *p = &t->breakpoints[i];
            if (p->patched && p->width && at >= p->address && at - p->address < p->width) {
                overlay = p;
                break;
            }
        }
        if (!overlay) {
            size_t count;
            result = xrt_memory_patch(tid, at, &bytes[written], 1, &count);
            if (result != XRT_OK) {
                if (written)
                    result = XRT_PARTIAL_MEMORY_WRITE;
                break;
            }
        }
        if (overlay)
            overlay->original[at - overlay->address] = bytes[written];
    }
    if (written) {
        xrt_target_event(t, XRT_EVENT_MEMORY_WRITTEN, t->pid, (int64_t)written);
        t->events[t->event_count - 1].address = address;
    }
    return result;
}
static enum xrt_status admitted_native(const struct xrt_target *t)
{
    if (!t || !t->identity_admitted || !t->arch || t->arch != xrt_arch_native())
        return XRT_UNSUPPORTED_ARCHITECTURE;
    return XRT_OK;
}
static enum xrt_status prepare_probe(struct xrt_target *t, uint64_t address, uint8_t original[4],
                                     struct xrt_probe_encoding *encoding)
{
    uint8_t raw[4] = {0};
    size_t count = 0;
    const enum xrt_status read = xrt_target_read(t, address, raw, sizeof(raw), &count);
    if (read != XRT_OK)
        return read;
    const struct xrt_probe_request request = {.address = address,
                                              .isa_mode = t->arch->isa_mode,
                                              .bytes = raw,
                                              .size = count};
    const enum xrt_status prepared = xrt_arch_probe_prepare(t->arch, &request, encoding);
    if (prepared != XRT_OK)
        return prepared;
    if (count >= encoding->width && memcmp(raw, encoding->bytes, encoding->width) == 0)
        return XRT_EXISTING_TRAP_INSTRUCTION;
    memset(original, 0, 4);
    memcpy(original, raw, encoding->width);
    return XRT_OK;
}
static void store_encoding(struct xrt_breakpoint *p, uint64_t address, const uint8_t original[4],
                           const struct xrt_probe_encoding *encoding, bool patched)
{
    p->address = address;
    p->width = encoding->width;
    p->isa_mode = encoding->isa_mode;
    p->alignment = encoding->alignment;
    memset(p->original, 0, sizeof(p->original));
    memset(p->planted, 0, sizeof(p->planted));
    memcpy(p->original, original, encoding->width);
    memcpy(p->planted, encoding->bytes, encoding->width);
    p->pending = false;
    p->patched = patched;
}
static void clear_pending(struct xrt_breakpoint *p)
{
    p->address = 0;
    p->width = 0;
    p->isa_mode = 0;
    p->alignment = 0;
    memset(p->planted, 0, sizeof(p->planted));
    memset(p->original, 0, sizeof(p->original));
    p->patched = false;
    p->pending = true;
}
enum xrt_status xrt_target_breakpoint_set(struct xrt_target *t, uint64_t address, bool temporary,
                                          uint64_t *id)
{
    if (!id)
        return XRT_INVALID_ARGUMENT;
    if (t && t->connection)
        return xrt_remote_call(
            t, &(struct xrt_call){.op = XRT_RPC_BP_SET, .args = {address, temporary}, .value = id});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    if (t->plant_cleanup.active)
        return XRT_INVALID_STATE;
    const int existing = xrt_breakpoint_at(t, address);
    if (existing >= 0) {
        *id = t->breakpoints[existing].id;
        return XRT_OK;
    }
    /* UINT64_MAX is never allocated: the counter would wrap to the absent ID. */
    if (t->breakpoint_count == XRT_MAX_BREAKPOINTS || t->next_probe_id == UINT64_MAX)
        return XRT_BREAKPOINT_LIMIT;
    uint8_t original[4];
    struct xrt_probe_encoding encoding;
    TRY(prepare_probe(t, address, original, &encoding));
    TRY(xrt_target_commit_plant(t, address, &encoding, original));
    struct xrt_breakpoint p = {.id = t->next_probe_id, .enabled = true, .temporary = temporary};
    store_encoding(&p, address, original, &encoding, true);
    ++t->next_probe_id;
    t->breakpoints[t->breakpoint_count++] = p;
    xrt_target_event(t, XRT_EVENT_BREAKPOINT_SET, t->pid, (int64_t)p.id);
    t->events[t->event_count - 1].address = address;
    *id = p.id;
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_reserve(struct xrt_target *t, uint64_t *id)
{
    if (!id)
        return XRT_INVALID_ARGUMENT;
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_BP_RESERVE, .value = id});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    if (t->breakpoint_count == XRT_MAX_BREAKPOINTS || t->next_probe_id == UINT64_MAX)
        return XRT_BREAKPOINT_LIMIT;
    *id = t->next_probe_id++;
    t->breakpoints[t->breakpoint_count++] = (struct xrt_breakpoint){0};
    clear_pending(&t->breakpoints[t->breakpoint_count - 1]);
    t->breakpoints[t->breakpoint_count - 1].id = *id;
    t->breakpoints[t->breakpoint_count - 1].enabled = true;
    xrt_target_event(t, XRT_EVENT_BREAKPOINT_SET, t->pid, (int64_t)*id);
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_restore(struct xrt_target *t, uint64_t id, bool enabled)
{
    if (t && t->connection)
        return xrt_remote_call(t,
                               &(struct xrt_call){.op = XRT_RPC_BP_RESTORE, .args = {id, enabled}});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    if (!id || id == UINT64_MAX || xrt_breakpoint_index(t, id) >= 0)
        return XRT_INVALID_ARGUMENT;
    /* Breakpoints and watchpoints share one probe-ID namespace. */
    for (unsigned i = 0; i < XRT_MAX_WATCHPOINTS; ++i)
        if (t->watchpoints[i].present && t->watchpoints[i].id == id)
            return XRT_INVALID_ARGUMENT;
    if (t->breakpoint_count == XRT_MAX_BREAKPOINTS)
        return XRT_BREAKPOINT_LIMIT;
    t->breakpoints[t->breakpoint_count] = (struct xrt_breakpoint){0};
    clear_pending(&t->breakpoints[t->breakpoint_count]);
    t->breakpoints[t->breakpoint_count].id = id;
    t->breakpoints[t->breakpoint_count].enabled = enabled;
    ++t->breakpoint_count;
    if (t->next_probe_id <= id)
        t->next_probe_id = id + 1;
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_resolve(struct xrt_target *t, uint64_t id, uint64_t address)
{
    if (t && t->connection)
        return xrt_remote_call(t,
                               &(struct xrt_call){.op = XRT_RPC_BP_RESOLVE, .args = {id, address}});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    if (t->plant_cleanup.active)
        return XRT_INVALID_STATE;
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    struct xrt_breakpoint *p = &t->breakpoints[i];
    if (!p->pending)
        return XRT_BREAKPOINT_ALREADY_RESOLVED;
    if (xrt_breakpoint_at(t, address) >= 0)
        return XRT_BREAKPOINT_LOCATION_ALREADY_USED;
    uint8_t original[4];
    struct xrt_probe_encoding encoding;
    TRY(prepare_probe(t, address, original, &encoding));
    if (p->enabled)
        TRY(xrt_target_commit_plant(t, address, &encoding, original));
    store_encoding(p, address, original, &encoding, p->enabled);
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_withdraw(struct xrt_target *t, uint64_t id)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_BP_WITHDRAW, .args = {id}});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    struct xrt_breakpoint *p = &t->breakpoints[i];
    if (p->patched)
        TRY(xrt_target_commit_owned(t, p->address, p->original, p->planted, p->width));
    const bool enabled = p->enabled;
    const uint64_t kept = p->id;
    const bool internal = p->internal;
    clear_pending(p);
    p->id = kept;
    p->enabled = enabled;
    p->internal = internal;
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_enable(struct xrt_target *t, uint64_t id, bool enabled)
{
    if (t && t->connection)
        return xrt_remote_call(t,
                               &(struct xrt_call){.op = XRT_RPC_BP_ENABLE, .args = {id, enabled}});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    struct xrt_breakpoint *p = &t->breakpoints[i];
    if (p->enabled == enabled)
        return XRT_OK;
    if (!p->pending)
        TRY(xrt_target_commit_owned(t, p->address, enabled ? p->planted : p->original,
                                    enabled ? p->original : p->planted, p->width));
    p->enabled = enabled;
    p->patched = enabled && !p->pending;
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_internal(struct xrt_target *t, uint64_t id, bool internal)
{
    if (t && t->connection)
        return xrt_remote_call(
            t, &(struct xrt_call){.op = XRT_RPC_BP_INTERNAL, .args = {id, internal}});
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    t->breakpoints[i].internal = internal;
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_remove(struct xrt_target *t, uint64_t id)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_BP_REMOVE, .args = {id}});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    const struct xrt_breakpoint p = t->breakpoints[i];
    if (p.patched)
        TRY(xrt_target_commit_owned(t, p.address, p.original, p.planted, p.width));
    t->breakpoints[i] = t->breakpoints[--t->breakpoint_count];
    xrt_target_event(t, XRT_EVENT_BREAKPOINT_REMOVED, t->pid, (int64_t)id);
    return XRT_OK;
}
/* XO values are (word >> 1) & 1023. lqarx 276 and stqcx. 182 are the ISA forms
 * gdb uses; this host's llvm-mc rejected those mnemonics. st*cx. requires Rc. */
static int ppc_xo(uint32_t word)
{
    return (int)((word >> 1) & 1023u);
}
static int ppc_is_larx(uint32_t word)
{
    if ((word >> 26) != 31)
        return 0;
    switch (ppc_xo(word)) {
    case 20:  /* lwarx */
    case 52:  /* lbarx */
    case 84:  /* ldarx */
    case 116: /* lharx */
    case 276: /* lqarx */
        return 1;
    default:
        return 0;
    }
}
static int ppc_is_stcx(uint32_t word)
{
    if ((word >> 26) != 31 || (word & 1u) == 0)
        return 0;
    switch (ppc_xo(word)) {
    case 150: /* stwcx. */
    case 182: /* stqcx. */
    case 214: /* stdcx. */
    case 694: /* stbcx. */
    case 726: /* sthcx. */
        return 1;
    default:
        return 0;
    }
}
static int ppc_read_word(int32_t tid, uint64_t address, uint32_t *word)
{
    unsigned char buf[4];
    size_t n = 0;
    if ((address & 3u) != 0)
        return 0;
    if (xrt_memory_read(tid, address, buf, 4, &n) != XRT_OK || n != 4)
        return 0;
    *word = (uint32_t)buf[0] | ((uint32_t)buf[1] << 8) | ((uint32_t)buf[2] << 16) |
            ((uint32_t)buf[3] << 24);
    return 1;
}
/* A planted breakpoint hides the instruction. The scan must see the original
 * word, including when the step itself is standing on that breakpoint. */
static int ppc_word_at(const struct xrt_target *t, int32_t tid, uint64_t address, uint32_t *word)
{
    const int b = xrt_breakpoint_at(t, address);
    if (b >= 0 && t->breakpoints[b].patched && t->breakpoints[b].width == 4) {
        const unsigned char *o = t->breakpoints[b].original;
        if ((address & 3u) != 0)
            return 0;
        *word = (uint32_t)o[0] | ((uint32_t)o[1] << 8) | ((uint32_t)o[2] << 16) |
                ((uint32_t)o[3] << 24);
        return 1;
    }
    return ppc_read_word(tid, address, word);
}
static uint64_t ppc_bform_target(uint32_t word, uint64_t loc)
{
    const int32_t disp = ((int32_t)((word & 0xfffcu) << 16)) >> 16;
    if (word & 2u)
        return (uint64_t)(int64_t)disp;
    return loc + (uint64_t)(int64_t)disp;
}
static int ppc_record_exit(struct xrt_step *step, uint64_t address)
{
    uint8_t i;
    if (address == 0 || (address & 3u) != 0)
        return 0;
    for (i = 0; i < step->atomic_count; ++i)
        if (step->atomic_exit[i] == address)
            return 1;
    if (step->atomic_count >= 2)
        return 0;
    step->atomic_exit[step->atomic_count++] = address;
    return 1;
}
/* gdb ppc_deal_with_atomic_sequence: one conditional branch before the
 * store-conditional, then stop on the next instruction and on a branch
 * target that leaves [pc, stcx]. Anything else stays a hardware step. */
static int ppc_atomic_plan(struct xrt_target *t, int32_t tid, uint64_t pc, struct xrt_step *step)
{
    uint32_t word = 0;
    uint64_t loc = pc;
    uint64_t branch_target = 0;
    int have_branch = 0;
    int found = 0;
    int n;
    if (!t->arch || t->arch->machine != XRT_PPC64 || t->arch->trap_size != 4)
        return 0;
    if (!ppc_word_at(t, tid, pc, &word) || !ppc_is_larx(word))
        return 0;
    for (n = 0; n < 16; ++n) {
        loc += 4;
        if (!ppc_word_at(t, tid, loc, &word))
            return 0;
        if ((word >> 26) == 16) {
            if (have_branch)
                return 0;
            have_branch = 1;
            branch_target = ppc_bform_target(word, loc);
        } else if ((word >> 26) == 18 ||
                   ((word >> 26) == 19 &&
                    (ppc_xo(word) == 16 || ppc_xo(word) == 528 || ppc_xo(word) == 560))) {
            return 0;
        }
        if (ppc_is_stcx(word)) {
            found = 1;
            break;
        }
    }
    if (!found)
        return 0;
    if (!ppc_record_exit(step, loc + 4))
        return 0;
    if (have_branch && !(branch_target >= pc && branch_target <= loc) &&
        !ppc_record_exit(step, branch_target))
        return 0;
    return step->atomic_count > 0;
}
static enum xrt_status ppc_atomic_restore(struct xrt_target *t, struct xrt_step *step)
{
    uint8_t i;
    for (i = 0; i < step->atomic_count; ++i) {
        if (!step->atomic_owned[i])
            continue;
        TRY(xrt_patch_instruction(t, step->atomic_exit[i], step->atomic_original[i], 4));
        step->atomic_owned[i] = 0;
    }
    return XRT_OK;
}
static enum xrt_status ppc_atomic_plant(struct xrt_target *t, struct xrt_step *step)
{
    uint8_t kept = 0;
    uint8_t i;
    for (i = 0; i < step->atomic_count; ++i) {
        const uint64_t address = step->atomic_exit[i];
        const int existing = xrt_breakpoint_at(t, address);
        int32_t tid = 0;
        size_t n = 0;
        enum xrt_status status;
        if (existing >= 0 && t->breakpoints[existing].patched)
            continue;
        status = xrt_target_stopped_tid(t, &tid);
        if (status != XRT_OK)
            return status;
        status = xrt_memory_read(tid, address, step->atomic_original[kept], 4, &n);
        if (status != XRT_OK || n != 4) {
            step->atomic_count = kept;
            return status != XRT_OK ? status : XRT_MEMORY_UNREADABLE;
        }
        status = xrt_patch_instruction(t, address, t->arch->trap, 4);
        if (status != XRT_OK) {
            (void)xrt_patch_instruction(t, address, step->atomic_original[kept], 4);
            step->atomic_count = kept;
            return status;
        }
        step->atomic_exit[kept] = address;
        step->atomic_owned[kept] = 1;
        ++kept;
    }
    step->atomic_count = kept;
    return XRT_OK;
}
int xrt_atomic_step_exit(const struct xrt_target *t, uint64_t pc)
{
    uint8_t i;
    if (!t || !t->stepping)
        return 0;
    for (i = 0; i < t->step.atomic_count; ++i)
        if (t->step.atomic_owned[i] && t->step.atomic_exit[i] == pc)
            return 1;
    return 0;
}
static enum xrt_status unplant_overlay(struct xrt_target *t, uint64_t id)
{
    const int b = xrt_breakpoint_index(t, id);
    if (b < 0)
        return XRT_OK;
    struct xrt_breakpoint *p = &t->breakpoints[b];
    if (!p->patched)
        return XRT_OK;
    TRY(xrt_target_commit_owned(t, p->address, p->original, p->planted, p->width));
    p->patched = false;
    xrt_sync_shared_patch(t, id, false);
    return XRT_OK;
}
static enum xrt_status drop_owned_probe(struct xrt_target *t, uint64_t id, uint8_t owned)
{
    if (!id)
        return XRT_OK;
    if (owned == 1)
        return xrt_target_breakpoint_remove(t, id);
    if (owned == 2)
        return unplant_overlay(t, id);
    return XRT_OK;
}
static void restore_rearm(struct xrt_target *t, uint64_t rearm)
{
    if (!rearm)
        return;
    const int b = xrt_breakpoint_index(t, rearm);
    if (b < 0 || t->breakpoints[b].patched)
        return;
    struct xrt_breakpoint *p = &t->breakpoints[b];
    if (xrt_target_commit_owned(t, p->address, p->planted, p->original, p->width) == XRT_OK) {
        p->patched = true;
        xrt_sync_shared_patch(t, rearm, true);
    } else {
        t->inherited_rearm = true;
        ++t->generation;
    }
}
static enum xrt_status plant_one(struct xrt_target *t, uint64_t address, uint64_t *id,
                                 uint8_t *owned)
{
    *id = 0;
    *owned = 0;
    const int existing = xrt_breakpoint_at(t, address);
    if (existing >= 0) {
        struct xrt_breakpoint *p = &t->breakpoints[existing];
        if (!p->enabled) {
            /* A disabled user probe still needs a trap for this step. Plant
             * under the record and unplant it afterwards; do not delete it. */
            TRY(xrt_target_commit_owned(t, p->address, p->planted, p->original, p->width));
            p->patched = true;
            xrt_sync_shared_patch(t, p->id, true);
            *id = p->id;
            *owned = 2;
            return XRT_OK;
        }
        *id = p->id;
        return XRT_OK;
    }
    const enum xrt_status planted = xrt_target_breakpoint_set(t, address, true, id);
    if (planted == XRT_EXISTING_TRAP_INSTRUCTION) {
        /* A program break 0, including __builtin_trap, already stops here. */
        *id = 0;
        *owned = 0;
        return XRT_OK;
    }
    if (planted != XRT_OK)
        return planted;
    const enum xrt_status marked = xrt_target_breakpoint_internal(t, *id, true);
    if (marked != XRT_OK) {
        const enum xrt_status removed = xrt_target_breakpoint_remove(t, *id);
        *id = 0;
        return removed != XRT_OK ? removed : marked;
    }
    *owned = 1;
    return XRT_OK;
}
enum xrt_status xrt_software_plant(struct xrt_target *t, const uint64_t *pcs, uint8_t count,
                                   uint64_t ids[2], uint8_t owned[2])
{
    if (!t || !pcs || !ids || !owned || !count || count > 2)
        return XRT_INVALID_ARGUMENT;
    ids[0] = ids[1] = 0;
    owned[0] = owned[1] = 0;
    for (uint8_t i = 0; i < count; ++i) {
        if (i && pcs[i] == pcs[0]) {
            ids[i] = ids[0];
            continue;
        }
        const enum xrt_status status = plant_one(t, pcs[i], &ids[i], &owned[i]);
        if (status != XRT_OK) {
            const enum xrt_status rolled = drop_owned_probe(t, ids[0], owned[0]);
            ids[0] = ids[1] = 0;
            owned[0] = owned[1] = 0;
            return rolled != XRT_OK ? rolled : status;
        }
    }
    return XRT_OK;
}
static enum xrt_status read_word(struct xrt_target *t, uint64_t address, uint32_t *out)
{
    uint8_t buf[4];
    size_t count = 0;
    const enum xrt_status status = xrt_target_read(t, address, buf, 4, &count);
    if (status != XRT_OK)
        return status;
    if (count != 4)
        return XRT_MEMORY_UNREADABLE;
    *out = (uint32_t)buf[0] | ((uint32_t)buf[1] << 8) | ((uint32_t)buf[2] << 16) |
           ((uint32_t)buf[3] << 24);
    return XRT_OK;
}
static enum xrt_status loongarch_software_begin(struct xrt_target *t, int32_t tid, bool stop_after)
{
    TRY(xrt_target_settle_plant_cleanup(t, 0));
    TRY(xrt_rearm_inherited(t));
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(xrt_ensure_watches(t));
    const int i = xrt_thread_index(t, tid);
    if (i < 0)
        return XRT_UNKNOWN_THREAD;
    struct xrt_registers regs;
    TRY(xrt_target_registers(t, tid, &regs));
    uint64_t pc = 0;
    TRY(xrt_registers_pc(&regs, &pc));
    uint32_t insn = 0;
    TRY(read_word(t, pc, &insn));
    uint32_t forward[16];
    uint8_t nforward = 0;
    for (; nforward < 16; ++nforward) {
        if (pc > UINT64_MAX - 4ull * (nforward + 1))
            break;
        uint32_t word = 0;
        if (read_word(t, pc + 4ull * (nforward + 1), &word) != XRT_OK)
            break;
        forward[nforward] = word;
    }
    /* Architectural r0 is zero. The ptrace word is the kernel restart slot. */
    uint64_t gpr[32] = {0};
    uint32_t known = 0;
    for (uint16_t d = 1; d < 32; ++d) {
        uint64_t value = 0;
        if (xrt_registers_value_dwarf(&regs, d, &value) != XRT_OK)
            continue;
        gpr[d] = value;
        known |= 1u << d;
    }
    struct xrt_loongarch_plan plan;
    const enum xrt_status planned =
        xrt_loongarch_plan(pc, insn, gpr, known, nforward ? forward : NULL, nforward, &plan);
    if (planned != XRT_OK)
        return planned;
    /* rt_sigreturn does not resume at pc+4. Refuse before any plant. */
    if ((insn & 0xffff8000u) == 0x002b0000u && (known & (1u << 11)) && gpr[11] == 139)
        return XRT_UNSUPPORTED_CONTROL;
    if (plan.emulate) {
        t->threads[i].reason = XRT_STOP_SINGLE_STEP;
        t->threads[i].breakpoint_address = 0;
        t->stepping = false;
        xrt_target_event(t, XRT_EVENT_STEP_COMPLETE, tid, 0);
        t->events[t->event_count - 1].pc = pc;
        t->events[t->event_count - 1].pc_known = 1;
        return XRT_OK;
    }
    uint64_t rearm = 0;
    const int at = xrt_breakpoint_at(t, pc);
    if (at >= 0 && t->breakpoints[at].enabled && t->breakpoints[at].patched) {
        struct xrt_breakpoint *p = &t->breakpoints[at];
        TRY(xrt_target_commit_owned(t, p->address, p->original, p->planted, p->width));
        p->patched = false;
        xrt_sync_shared_patch(t, p->id, false);
        rearm = p->id;
    }
    uint64_t ids[2] = {0};
    uint8_t owned[2] = {0};
    const enum xrt_status planted = xrt_software_plant(t, plan.pc, plan.count, ids, owned);
    if (planted != XRT_OK) {
        restore_rearm(t, rearm);
        return planted;
    }
    const enum xrt_status resumed =
        xrt_trace(PTRACE_CONT, tid, 0, (uintptr_t)t->threads[i].signal);
    if (resumed != XRT_OK) {
        enum xrt_status rolled = drop_owned_probe(t, ids[0], owned[0]);
        if (owned[1]) {
            const enum xrt_status second = drop_owned_probe(t, ids[1], owned[1]);
            if (rolled == XRT_OK)
                rolled = second;
        }
        restore_rearm(t, rearm);
        return rolled != XRT_OK ? rolled : resumed;
    }
    t->step = (struct xrt_step){.tid = tid,
                                .rearm = rearm,
                                .stop_after = stop_after,
                                .has_exec_entry = t->threads[i].reason == XRT_STOP_EXEC,
                                .exec_entry_pc = pc,
                                .software = 1,
                                .successor_count = plan.count,
                                .probe_owned = {owned[0], owned[1]},
                                .successor_pc = {plan.pc[0], plan.pc[1]},
                                .probe_id = {ids[0], ids[1]}};
    t->threads[i].signal = 0;
    t->threads[i].reason = XRT_STOP_NONE;
    t->threads[i].state = XRT_RUNNING;
    t->stepping = true;
    t->want_run = false;
    t->state = XRT_RUNNING;
    xrt_target_event(t, XRT_EVENT_STEP_STARTED, tid, 0);
    return XRT_OK;
}
enum xrt_status xrt_software_step_hit(struct xrt_target *t, int thread_index, uint64_t pc,
                                      int *handled)
{
    if (!handled)
        return XRT_INVALID_ARGUMENT;
    *handled = 0;
    if (!t || thread_index < 0 || (size_t)thread_index >= t->thread_count)
        return XRT_INVALID_ARGUMENT;
    if (!t->stepping || !t->step.software || t->step.tid != t->threads[thread_index].tid)
        return XRT_OK;
    int which = -1;
    for (uint8_t s = 0; s < t->step.successor_count; ++s)
        if (t->step.successor_pc[s] == pc)
            which = (int)s;
    if (which < 0)
        return XRT_OK;
    /* The stop PC is already the successor. Do not write r0 or the PC. */
    const bool stop_after = t->step.stop_after;
    const int at = xrt_breakpoint_at(t, pc);
    const bool user_stop = at >= 0 && !t->breakpoints[at].internal;
    const uint64_t user_id = user_stop ? t->breakpoints[at].id : 0;
    TRY(xrt_finish_step(t, true));
    struct xrt_thread *thread = &t->threads[thread_index];
    thread->signal = 0;
    if (user_stop) {
        const int b = xrt_breakpoint_index(t, user_id);
        thread->reason = XRT_STOP_BREAKPOINT;
        thread->breakpoint_address = pc;
        if (b >= 0 && t->breakpoints[b].hit_count != UINT64_MAX)
            ++t->breakpoints[b].hit_count;
        xrt_target_event(t, XRT_EVENT_BREAKPOINT_HIT, thread->tid, (int64_t)user_id);
        t->events[t->event_count - 1].pc = pc;
        t->events[t->event_count - 1].pc_known = 1;
        *handled = 1;
        return XRT_OK;
    }
    thread->reason = XRT_STOP_SINGLE_STEP;
    thread->breakpoint_address = 0;
    xrt_target_event(t, XRT_EVENT_STEP_COMPLETE, thread->tid, 0);
    t->events[t->event_count - 1].pc = pc;
    t->events[t->event_count - 1].pc_known = 1;
    if (!stop_after) {
        thread->reason = XRT_STOP_NONE;
        t->state = XRT_STOPPED;
        TRY(xrt_target_continue(t));
        *handled = 2;
        return XRT_OK;
    }
    *handled = 1;
    return XRT_OK;
}
enum xrt_status xrt_begin_step(struct xrt_target *t, int32_t tid, bool stop_after)
{
    TRY(xrt_execution_allowed(t));
    /* Hardware step stays 0 on this row. Software successors run before the
       refusal, and only for LoongArch. Other rows still refuse before rearm. */
    if (t->arch && t->arch->machine == XRT_LOONGARCH && t->arch->hardware_step == 0)
        return loongarch_software_begin(t, tid, stop_after);
    if (!t->arch || t->arch->hardware_step == 0)
        return XRT_UNSUPPORTED_CONTROL;
    TRY(xrt_rearm_inherited(t));
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(xrt_ensure_watches(t));
    const int i = xrt_thread_index(t, tid);
    if (i < 0)
        return XRT_UNKNOWN_THREAD;
    struct xrt_registers regs;
    TRY(xrt_target_registers(t, tid, &regs));
    uint64_t pc = 0;
    const enum xrt_status pc_status = xrt_registers_pc(&regs, &pc);
    if (pc_status != XRT_OK)
        return pc_status;
    uint64_t rearm = 0;
    struct xrt_step atomic = {0};
    const int use_atomic = ppc_atomic_plan(t, tid, pc, &atomic);
    const int b = xrt_breakpoint_at(t, pc);
    if (b >= 0 && t->breakpoints[b].enabled) {
        struct xrt_breakpoint *p = &t->breakpoints[b];
        TRY(xrt_patch_instruction(t, p->address, p->original, p->width));
        p->patched = false;
        xrt_sync_shared_patch(t, p->id, false);
        rearm = p->id;
    }
    int atomic_run = 0;
    if (use_atomic) {
        const enum xrt_status planted = ppc_atomic_plant(t, &atomic);
        if (planted != XRT_OK) {
            (void)ppc_atomic_restore(t, &atomic);
            if (rearm && xrt_patch_instruction(t, t->breakpoints[b].address,
                                               t->breakpoints[b].planted,
                                               t->breakpoints[b].width) == XRT_OK) {
                t->breakpoints[b].patched = true;
                xrt_sync_shared_patch(t, rearm, true);
            } else if (rearm) {
                t->inherited_rearm = true;
                ++t->generation;
            }
            return planted;
        }
        /* count 0 means every exit is already a patched user breakpoint.
         * Continue so that breakpoint is the stop, instead of single-stepping
         * the larx and clearing the reservation. */
        atomic_run = 1;
    }
    const enum xrt_status status =
        xrt_trace(atomic_run ? PTRACE_CONT : PTRACE_SINGLESTEP, tid, 0,
                  (uintptr_t)t->threads[i].signal);
    if (status != XRT_OK) {
        (void)ppc_atomic_restore(t, &atomic);
        if (rearm && xrt_patch_instruction(t, t->breakpoints[b].address, t->breakpoints[b].planted,
                                           t->breakpoints[b].width) == XRT_OK) {
            t->breakpoints[b].patched = true;
            xrt_sync_shared_patch(t, rearm, true);
        }
        /* A failed repair must remain visible and must be retried before run. */
        else if (rearm) {
            t->inherited_rearm = true;
            ++t->generation;
        }
        return status;
    }
    t->step = (struct xrt_step){.tid = tid,
                                .rearm = rearm,
                                .stop_after = stop_after,
                                .has_exec_entry = t->threads[i].reason == XRT_STOP_EXEC,
                                .exec_entry_pc = pc,
                                .atomic_count = atomic_run ? atomic.atomic_count : 0};
    if (atomic_run) {
        memcpy(t->step.atomic_exit, atomic.atomic_exit, sizeof atomic.atomic_exit);
        memcpy(t->step.atomic_original, atomic.atomic_original, sizeof atomic.atomic_original);
        memcpy(t->step.atomic_owned, atomic.atomic_owned, sizeof atomic.atomic_owned);
    }
    t->threads[i].signal = 0;
    t->threads[i].reason = XRT_STOP_NONE;
    t->threads[i].state = XRT_RUNNING;
    t->stepping = true;
    t->want_run = false;
    t->state = XRT_RUNNING;
    xrt_target_event(t, XRT_EVENT_STEP_STARTED, tid, 0);
    return XRT_OK;
}
enum xrt_status xrt_target_step(struct xrt_target *t, int32_t tid)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_STEP, .args = {(uint32_t)tid}});
    return t->core ? XRT_READ_ONLY_CORE : xrt_begin_step(t, tid, true);
}
enum xrt_status xrt_finish_step(struct xrt_target *t, bool completed)
{
    if (!t->stepping)
        return XRT_OK;
    const struct xrt_step step = t->step;
    uint8_t ai;
    for (ai = 0; ai < step.atomic_count; ++ai) {
        if (!step.atomic_owned[ai])
            continue;
        TRY(xrt_patch_instruction(t, step.atomic_exit[ai], step.atomic_original[ai], 4));
        t->step.atomic_owned[ai] = 0;
    }
    if (step.software) {
        /* The stop is classified before the aggregate state is recomputed, so
         * a just-stopped single thread still looks RUNNING. Removal requires
         * the stopped state. Owned probes go before the user probe is replanted. */
        xrt_recompute_state(t);
        if (step.probe_owned[0] == 2 && step.probe_id[0]) {
            TRY(unplant_overlay(t, step.probe_id[0]));
            t->step.probe_owned[0] = 0;
        } else if (step.probe_owned[0] && step.probe_id[0]) {
            TRY(xrt_target_breakpoint_remove(t, step.probe_id[0]));
            t->step.probe_owned[0] = 0;
        }
        if (step.probe_owned[1] == 2 && step.probe_id[1] && step.probe_id[1] != step.probe_id[0]) {
            TRY(unplant_overlay(t, step.probe_id[1]));
            t->step.probe_owned[1] = 0;
        } else if (step.probe_owned[1] && step.probe_id[1] && step.probe_id[1] != step.probe_id[0]) {
            TRY(xrt_target_breakpoint_remove(t, step.probe_id[1]));
            t->step.probe_owned[1] = 0;
        }
    }
    const int b = step.rearm ? xrt_breakpoint_index(t, step.rearm) : -1;
    if (b >= 0) {
        bool live = false;
        for (size_t i = 0; i < t->thread_count; ++i)
            live |= t->threads[i].state != XRT_EXITED;
        if (live) {
            if (step.software) {
                TRY(xrt_target_settle_plant_cleanup(t, 0));
                TRY(xrt_target_commit_owned(t, t->breakpoints[b].address, t->breakpoints[b].planted,
                                            t->breakpoints[b].original, t->breakpoints[b].width));
            } else
                TRY(xrt_patch_instruction(t, t->breakpoints[b].address, t->breakpoints[b].planted,
                                          t->breakpoints[b].width));
            t->breakpoints[b].patched = true;
            xrt_sync_shared_patch(t, step.rearm, true);
        }
    }
    if (step.has_watch) {
        const int i = xrt_thread_index(t, step.tid);
        if (i >= 0 && t->threads[i].state == XRT_STOPPED) {
            const enum xrt_status status = xrt_configure_watches(t, step.tid);
            if (status != XRT_OK) {
                t->watchpoints_dirty = true;
                return status;
            }
        }
        xrt_publish_arm_watch(t, step.tid, &step.watch, completed);
    }
    t->stepping = false;
    return XRT_OK;
}
bool xrt_target_only_internal_stops(const struct xrt_target *t)
{
    if (!t)
        return false;
    bool hit = false;
    for (size_t i = 0; i < t->thread_count; ++i) {
        const struct xrt_thread *thread = &t->threads[i];
        if (thread->reason == XRT_STOP_NONE || thread->reason == XRT_STOP_INTERRUPT)
            continue;
        if (thread->reason != XRT_STOP_BREAKPOINT)
            return false;
        const int b = xrt_breakpoint_at(t, thread->breakpoint_address);
        if (b < 0 || !t->breakpoints[b].internal)
            return false;
        hit = true;
    }
    return hit;
}
