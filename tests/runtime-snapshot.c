#include "target_internal.h"
#include "wire_target.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void)
{
    uint8_t *bytes = malloc(XRT_WIRE_MAX_BODY);
    assert(bytes);
    struct xrt_target *source = xrt_target_create(), *decoded = xrt_target_create();
    assert(source && decoded);
    source->arch = xrt_arch_get(XRT_X86_64);
    source->state = XRT_STOPPED;
    source->thread_count = XRT_MAX_THREADS;
    source->event_count = XRT_MAX_EVENTS;
    source->breakpoint_count = XRT_MAX_BREAKPOINTS;
    source->birth_count = XRT_MAX_THREADS;
    source->next_thread_id = XRT_MAX_THREADS + 1;
    source->next_probe_id = XRT_MAX_BREAKPOINTS + 1;
    source->generation = UINT64_C(0x1020304050607080);
    source->sequence = XRT_MAX_EVENTS;
    for (size_t i = 0; i < source->thread_count; ++i)
        source->threads[i] = (struct xrt_thread){.id = i + 1,
                                                 .tid = (int32_t)i + 100,
                                                 .state = XRT_STOPPED,
                                                 .reason = XRT_STOP_SIGNAL,
                                                 .signal = 11};
    for (size_t i = 0; i < source->event_count; ++i)
        source->events[i] = (struct xrt_event){.sequence = i + 1,
                                               .time_ns = i * 1000,
                                               .kind = XRT_EVENT_STOP,
                                               .tid = 100,
                                               .detail = -1,
                                               .pc = UINT64_MAX - 1,
                                               .pc_known = 1};
    for (size_t i = 0; i < source->breakpoint_count; ++i)
        source->breakpoints[i] = (struct xrt_breakpoint){.id = i + 1,
                                                        .address = 4096 + i,
                                                        .enabled = true,
                                                        .patched = true,
                                                        .width = 1,
                                                        .isa_mode = XRT_ISA_MODE_ORDINARY,
                                                        .alignment = 1,
                                                        .planted = {0xcc}};
    for (size_t i = 0; i < source->birth_count; ++i)
        source->births[i] = (struct xrt_birth){
            .pid = 2000 + (int32_t)i, .parent_tid = 100, .kind = XRT_BIRTH_FORK, .vm_errno = 13};
    struct xrt_codec out = xrt_codec(bytes, XRT_WIRE_MAX_BODY, false);
    xrt_wire_target(&out, source);
    assert(out.ok && out.at < XRT_WIRE_MAX_BODY);
    const size_t size = out.at;
    struct xrt_codec in = xrt_codec(bytes, size, true);
    xrt_wire_target(&in, decoded);
    assert(in.ok && in.at == size && decoded->generation == source->generation);
    assert(decoded->thread_count == XRT_MAX_THREADS && decoded->event_count == XRT_MAX_EVENTS &&
           decoded->breakpoint_count == XRT_MAX_BREAKPOINTS);
    assert(decoded->events[XRT_MAX_EVENTS - 1].pc == UINT64_MAX - 1 &&
           decoded->events[0].detail == -1);
    assert(decoded->births[XRT_MAX_THREADS - 1].vm_errno == 13);
    for (size_t i = 0; i < size; i += 7919) {
        memset(decoded, 0, sizeof(*decoded));
        in = xrt_codec(bytes, i, true);
        xrt_wire_target(&in, decoded);
        assert(!in.ok && in.at <= i);
    }
    /* Snapshot ISA and event continuity cannot be silently reinterpreted. */
    bytes[0] = 255;
    bytes[1] = 255;
    memset(decoded, 0, sizeof(*decoded));
    in = xrt_codec(bytes, size, true);
    xrt_wire_target(&in, decoded);
    assert(!in.ok);
    bytes[0] = 0;
    bytes[1] = XRT_X86_64;
    source->events[23].sequence += 1;
    out = xrt_codec(bytes, XRT_WIRE_MAX_BODY, false);
    xrt_wire_target(&out, source);
    assert(out.ok);
    memset(decoded, 0, sizeof(*decoded));
    in = xrt_codec(bytes, out.at, true);
    xrt_wire_target(&in, decoded);
    assert(!in.ok);
    /* Cross-ISA register snapshots use descriptors, never host union layout. */
    struct xrt_registers regs = {
        .abi = xrt_arch_abi(xrt_arch_get(XRT_AARCH64)),
        .values.arm = {.x0 = UINT64_MAX, .pc = UINT64_C(0x0102030405060708)}};
    struct xrt_registers got = {0};
    out = xrt_codec(bytes, XRT_WIRE_MAX_BODY, false);
    xrt_wire_registers(&out, &regs);
    assert(out.ok && bytes[0] == 0 && bytes[1] == XRT_AARCH64);
    in = xrt_codec(bytes, out.at, true);
    xrt_wire_registers(&in, &got);
    assert(in.ok && got.abi.machine == XRT_AARCH64 && got.values.arm.x0 == UINT64_MAX &&
           got.values.arm.pc == regs.values.arm.pc);
    /* Synthetic handles deliberately contain fake PIDs; don't run teardown. */
    free(source);
    free(decoded);
    free(bytes);
    puts("C snapshots: full-capacity round trip, truncation, ISA validation, sequence gaps and "
         "cross-ISA registers passed");
    return 0;
}
