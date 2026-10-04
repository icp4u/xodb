//! Strict decoder for task-scoped x86-64 perf uprobe records.
//! UAPI source: installed linux/perf_event.h and asm/perf_regs.h.
//! Decoding preserves raw registers; normalizedSample explicitly adapts native
//! System V function-entry/return probes using the verified host convention.
const std = @import("std");
const Kind = @import("allocation_lifetimes.zig").Kind;
const events = @import("allocation_events.zig");
const stacks = @import("allocation_stacks.zig");
pub const max_record_size = 4096;
pub const entry_sample_type = sample_type | (1 << 5) | (1 << 13); // CALLCHAIN, STACK_USER
pub const max_hooks = 16;
pub const sample_type: u64 = (1 << 1) | (1 << 2) | (1 << 6) | (1 << 12); // TID,TIME,ID,REGS_USER
pub const register_mask: u64 = (1 << 0) | (1 << 4) | (1 << 5) | (1 << 7) | (1 << 8); // AX,SI,DI,SP,IP
pub const Hook = struct { id: u16, kind: Kind, entry_id: u64, return_id: u64 };
pub const Identity = struct { pid: u32, tid: u32, hooks: []const Hook, callstacks: bool = false };
pub const Phase = enum { enter, leave };
pub const Registers = struct { ax: u64, si: u64, di: u64, sp: u64, ip: u64 };
pub const Record = struct {
    time_ns: u64,
    data: union(enum) {
        sample: struct { hook: u16, kind: Kind, phase: Phase, registers: Registers, stack: stacks.Stack = .{} },
        lost: u64,
        throttle,
        unthrottle,
        thread_exit,
        exec,
        rename,
        mapping_change: struct { name: [128]u8 = @splat(0), prot: u32, device: u64, inode: u64 },
        probe_mapping: struct { start: u64, end: u64 },
        fork: struct { pid: u32, tid: u32 },
    },
};
const Selected = struct { hook: Hook, phase: Phase };
pub fn validateIdentity(who: Identity) !void {
    if (who.pid == 0 or who.tid == 0 or who.pid > std.math.maxInt(i32) or who.tid > std.math.maxInt(i32) or who.hooks.len == 0 or who.hooks.len > max_hooks) return error.InvalidAllocationIdentity;
    for (who.hooks, 0..) |hook, i| {
        if (hook.entry_id == 0 or hook.return_id == 0 or hook.entry_id == hook.return_id) return error.InvalidAllocationHook;
        for (who.hooks[0..i]) |old| {
            if (old.id == hook.id or old.entry_id == hook.entry_id or old.entry_id == hook.return_id or old.return_id == hook.entry_id or old.return_id == hook.return_id) return error.InvalidAllocationHook;
        }
    }
}
fn select(who: Identity, id: u64) !Selected {
    for (who.hooks) |hook| {
        if (id == hook.entry_id) return .{ .hook = hook, .phase = .enter };
        if (id == hook.return_id) return .{ .hook = hook, .phase = .leave };
    }
    return error.AllocationEventIdentity;
}
fn number(comptime T: type, bytes: []const u8, at: usize) !T {
    if (at > bytes.len or @sizeOf(T) > bytes.len - at) return error.AllocationRecordTruncated;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
fn task(bytes: []const u8, at: usize, who: Identity) !void {
    if (try number(u32, bytes, at) != who.pid or try number(u32, bytes, at + 4) != who.tid) return error.AllocationTaskIdentity;
}
/// TID|TIME|ID|REGS_USER samples, TID|TIME|ID trailers on metadata.
/// Entry stacks optionally include a frame-pointer chain and one return-address
/// word at SP. Allocated-object contents are never sampled.
pub fn decode(bytes: []const u8, who: Identity) !Record {
    try validateIdentity(who);
    if (bytes.len < 8 or bytes.len != try number(u16, bytes, 6) or bytes.len % 8 != 0) return error.AllocationRecordSize;
    const typ = try number(u32, bytes, 0);
    const misc = try number(u16, bytes, 4);
    if (typ == 9) {
        if (misc & 7 != 2) return error.AllocationSampleMode;
        try task(bytes, 8, who);
        const selected = try select(who, try number(u64, bytes, 24));
        const with_stack = who.callstacks and selected.phase == .enter;
        var at: usize = 32;
        var chain: [stacks.max_frames + 2]u64 = undefined;
        var chain_count: usize = 0;
        if (with_stack) {
            const count = try number(u64, bytes, at);
            if (count > chain.len) return error.AllocationCallchainSize;
            at += 8;
            for (chain[0..@intCast(count)]) |*pc| {
                pc.* = try number(u64, bytes, at);
                at += 8;
            }
            chain_count = @intCast(count);
        }
        if (try number(u64, bytes, at) != 2) return error.AllocationRegisterAbi;
        at += 8;
        const regs = Registers{ .ax = try number(u64, bytes, at), .si = try number(u64, bytes, at + 8), .di = try number(u64, bytes, at + 16), .sp = try number(u64, bytes, at + 24), .ip = try number(u64, bytes, at + 32) };
        at += 40;
        var stack = stacks.Stack{};
        if (with_stack) {
            const size = try number(u64, bytes, at);
            at += 8;
            if (size != 0 and size != 8) return error.AllocationEntryStackSize;
            var caller: u64 = 0;
            if (size != 0) {
                const word = try number(u64, bytes, at);
                const dynamic = try number(u64, bytes, at + 8);
                if (dynamic > size) return error.AllocationEntryStackSize;
                if (dynamic == 8) caller = word;
                at += 16;
            }
            stack = entryStack(regs.ip, caller, chain[0..chain_count]);
        }
        if (at != bytes.len) return error.AllocationRegisterSize;
        return .{ .time_ns = try number(u64, bytes, 16), .data = .{ .sample = .{
            .hook = selected.hook.id,
            .kind = selected.hook.kind,
            .phase = selected.phase,
            .registers = regs,
            .stack = stack,
        } } };
    }
    if (bytes.len < 32) return error.AllocationRecordTruncated;
    const tail = bytes.len - 24;
    try task(bytes, tail, who);
    const trailer_id = try number(u64, bytes, tail + 16);
    _ = try select(who, trailer_id);
    const time = try number(u64, bytes, tail + 8);
    const data: @FieldType(Record, "data") = switch (typ) {
        2 => blk: {
            if (tail != 24 or try number(u64, bytes, 8) != trailer_id) return error.AllocationRecordIdentity;
            break :blk .{ .lost = try number(u64, bytes, 16) };
        },
        13 => blk: {
            if (tail != 16) return error.AllocationRecordSize;
            break :blk .{ .lost = try number(u64, bytes, 8) };
        },
        5, 6 => blk: {
            if (tail != 32 or try number(u64, bytes, 16) != trailer_id) return error.AllocationRecordIdentity;
            break :blk if (typ == 5) .throttle else .unthrottle;
        },
        4 => blk: {
            if (tail != 32 or try number(u32, bytes, 8) != who.pid or try number(u32, bytes, 16) != who.tid) return error.AllocationTaskIdentity;
            break :blk .thread_exit;
        },
        7 => blk: {
            if (tail != 32 or try number(u32, bytes, 12) != who.pid or try number(u32, bytes, 20) != who.tid) return error.AllocationTaskIdentity;
            const pid = try number(u32, bytes, 8);
            const tid = try number(u32, bytes, 16);
            if (pid == 0 or tid == 0) return error.AllocationTaskIdentity;
            break :blk .{ .fork = .{ .pid = pid, .tid = tid } };
        },
        1, 10 => blk: {
            try task(bytes, 8, who);
            const filename: usize = if (typ == 1) 40 else 72;
            if (tail <= filename) return error.AllocationRecordSize;
            const length = std.mem.indexOfScalar(u8, bytes[filename..tail], 0) orelse return error.AllocationRecordSize;
            const start = try number(u64, bytes, 16);
            const size = try number(u64, bytes, 24);
            const end = std.math.add(u64, start, size) catch return error.AllocationRecordSize;
            if (size == 0) return error.AllocationRecordSize;
            // Linux creates this special anonymous executable mapping on the
            // first probe hit. It is probe machinery, not a replaced ELF.
            // The owner still checks for overlap with opening symbol ranges.
            if (typ == 10 and misc & (1 << 14) == 0 and
                std.mem.eql(u8, bytes[filename..][0..length], "[uprobes]") and
                try number(u64, bytes, 32) == 0 and try number(u64, bytes, 40) == 0 and
                try number(u64, bytes, 48) == 0 and (try number(u32, bytes, 64)) & ~@as(u32, 1) == 4)
                break :blk .{ .probe_mapping = .{ .start = start, .end = end } };
            var change: @FieldType(@FieldType(Record, "data"), "mapping_change") = .{ .prot = if (typ == 10) try number(u32, bytes, 64) else 0, .device = if (typ == 10) try number(u64, bytes, 40) else 0, .inode = if (typ == 10) try number(u64, bytes, 48) else 0 };
            @memcpy(change.name[0..@min(length, 127)], bytes[filename..][0..@min(length, 127)]);
            break :blk .{ .mapping_change = change };
        },
        3 => blk: {
            try task(bytes, 8, who);
            if (tail < 24 or std.mem.indexOfScalar(u8, bytes[16..tail], 0) == null) return error.AllocationRecordSize;
            break :blk if (misc & (1 << 13) != 0) .exec else .rename;
        },
        else => return error.AllocationUnknownRecord,
    };
    return .{ .time_ns = time, .data = data };
}
// Kernel frame-pointer chains may omit the immediate caller at a function
// entry before its prologue. Preserve the return address independently from the
// captured entry SP, adding it only when the kernel did not include it already.
fn entryStack(ip: u64, caller: u64, chain: []const u64) stacks.Stack {
    var out = stacks.Stack{ .status = if (caller == 0 or caller >= 0x8000000000000000) .caller_missing else .prefix };
    if (ip != 0 and ip < 0x8000000000000000) {
        out.pcs[0] = ip;
        out.count = 1;
    }
    const has_caller = out.status == .prefix;
    if (has_caller) {
        out.pcs[out.count] = caller;
        out.count += 1;
    }
    var seen_ip = false;
    var first_caller = true;
    var chain_frames: usize = 0;
    for (chain) |pc| {
        if (pc >= 0x8000000000000000) continue; // perf context markers, never PCs
        if (pc == 0) break;
        chain_frames += 1;
        if (!seen_ip) {
            seen_ip = true;
            if (pc == ip) continue;
        }
        if (first_caller) {
            first_caller = false;
            if (has_caller and pc == caller) continue;
        }
        if (out.count == stacks.max_frames) {
            out.status = .depth_limit;
            break;
        }
        out.pcs[out.count] = pc;
        out.count += 1;
    }
    if (chain_frames >= stacks.max_frames) out.status = .depth_limit;
    if (out.count == 0) out.status = .missing;
    return out;
}
/// For native x86-64 System V allocator functions probed at their entry.
/// The verified return probe has SP after popping the eight-byte return
/// address: SP-8 matches the entry SP. This is not a convention for interior
/// probes, stack-switching functions or other architectures/ABIs. Pairing
/// still rejects mismatches and ambiguous tail-call/abandoned-frame entries.
/// The caller handles metadata/lifecycle records and owns source validation.
pub fn normalizedSample(record: Record) !events.Event {
    if (record.data != .sample) return error.AllocationExpectedSample;
    const sample = record.data.sample;
    const regs = sample.registers;
    const entering = sample.phase == .enter;
    const key = if (entering) regs.sp else std.math.sub(u64, regs.sp, 8) catch return error.AllocationStackKeyUnavailable;
    if (key == 0) return error.AllocationStackKeyUnavailable;
    return .{ .time_ns = record.time_ns, .data = .{ .sample = .{
        .phase = if (entering) .enter else .leave,
        .hook = sample.hook,
        .kind = sample.kind,
        .stack_key = key,
        .ip = regs.ip,
        .arg0 = if (entering) regs.di else 0,
        .arg1 = if (entering) regs.si else 0,
        .result = if (!entering) regs.ax else 0,
    } } };
}

pub fn retprobeMask(format: []const u8) !u64 {
    const text = std.mem.trim(u8, format, " \t\r\n");
    if (!std.mem.startsWith(u8, text, "config:")) return error.AllocationPmuFormat;
    const bit = std.fmt.parseInt(u6, text[7..], 10) catch return error.AllocationPmuFormat;
    return @as(u64, 1) << bit;
}

const hooks = [_]Hook{ .{ .id = 4, .kind = .malloc, .entry_id = 100, .return_id = 101 }, .{ .id = 9, .kind = .free, .entry_id = 102, .return_id = 103 } };
const identity = Identity{ .pid = 12, .tid = 13, .hooks = &hooks };
fn put(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}
fn header(bytes: []u8, typ: u32) void {
    @memset(bytes, 0);
    put(u32, bytes, 0, typ);
    put(u16, bytes, 6, @intCast(bytes.len));
}
fn trailer(bytes: []u8, id: u64) void {
    const at = bytes.len - 24;
    put(u32, bytes, at, identity.pid);
    put(u32, bytes, at + 4, identity.tid);
    put(u64, bytes, at + 8, 77);
    put(u64, bytes, at + 16, id);
}
fn testSample(id: u64) [80]u8 {
    var bytes: [80]u8 = undefined;
    header(&bytes, 9);
    put(u16, &bytes, 4, 2);
    put(u32, &bytes, 8, identity.pid);
    put(u32, &bytes, 12, identity.tid);
    put(u64, &bytes, 16, 77);
    put(u64, &bytes, 24, id);
    put(u64, &bytes, 32, 2);
    for (0..5) |i| put(u64, &bytes, 40 + i * 8, 0x1111 * (i + 1));
    return bytes;
}
test "sample identity routes hooks and preserves raw x86 register order" {
    for ([_]u64{ 100, 101, 102, 103 }) |id| {
        const record = try decode(&testSample(id), identity);
        const sample = record.data.sample;
        try std.testing.expectEqual(@as(u64, 77), record.time_ns);
        try std.testing.expectEqual(if (id % 2 == 0) Phase.enter else Phase.leave, sample.phase);
        try std.testing.expectEqual(if (id < 102) Kind.malloc else Kind.free, sample.kind);
        try std.testing.expectEqual(@as(u64, 0x1111), sample.registers.ax);
        try std.testing.expectEqual(@as(u64, 0x2222), sample.registers.si);
        try std.testing.expectEqual(@as(u64, 0x3333), sample.registers.di);
        try std.testing.expectEqual(@as(u64, 0x4444), sample.registers.sp);
        try std.testing.expectEqual(@as(u64, 0x5555), sample.registers.ip);
    }
}
test "foreign task, unknown event, unsupported register ABI and malformed samples fail closed" {
    var bytes = testSample(999);
    try std.testing.expectError(error.AllocationEventIdentity, decode(&bytes, identity));
    bytes = testSample(100);
    put(u32, &bytes, 12, 14);
    try std.testing.expectError(error.AllocationTaskIdentity, decode(&bytes, identity));
    bytes = testSample(100);
    put(u64, &bytes, 32, 1);
    try std.testing.expectError(error.AllocationRegisterAbi, decode(&bytes, identity));
    bytes = testSample(100);
    put(u16, &bytes, 4, 1);
    try std.testing.expectError(error.AllocationSampleMode, decode(&bytes, identity));
    // Every truncated prefix, including a forged self-consistent size, must fail.
    for (0..80) |n| {
        bytes = testSample(100);
        if (n >= 8) put(u16, &bytes, 6, @intCast(n));
        if (decode(bytes[0..n], identity)) |_| return error.TruncatedSampleAccepted else |_| {}
    }
}
test "loss and throttle records retain amounts and verify both IDs" {
    var lost: [48]u8 = undefined;
    header(&lost, 2);
    trailer(&lost, 100);
    put(u64, &lost, 8, 100);
    put(u64, &lost, 16, 33);
    try std.testing.expectEqual(@as(u64, 33), (try decode(&lost, identity)).data.lost);
    put(u64, &lost, 8, 101);
    try std.testing.expectError(error.AllocationRecordIdentity, decode(&lost, identity));
    var samples: [40]u8 = undefined;
    header(&samples, 13);
    trailer(&samples, 102);
    put(u64, &samples, 8, 4);
    try std.testing.expectEqual(@as(u64, 4), (try decode(&samples, identity)).data.lost);
    var throttle: [56]u8 = undefined;
    for ([_]u32{ 5, 6 }) |typ| {
        header(&throttle, typ);
        trailer(&throttle, 101);
        put(u64, &throttle, 16, 101);
        const expected: std.meta.Tag(@FieldType(Record, "data")) = if (typ == 5) .throttle else .unthrottle;
        try std.testing.expect((try decode(&throttle, identity)).data == expected);
    }
}
test "lifecycle identities distinguish exec and selected task exit from child creation" {
    var bytes: [56]u8 = undefined;
    header(&bytes, 4);
    trailer(&bytes, 100);
    put(u32, &bytes, 8, identity.pid);
    put(u32, &bytes, 16, identity.tid);
    try std.testing.expect((try decode(&bytes, identity)).data == .thread_exit);
    header(&bytes, 7);
    trailer(&bytes, 100);
    put(u32, &bytes, 8, 25);
    put(u32, &bytes, 16, 25);
    put(u32, &bytes, 12, identity.pid);
    put(u32, &bytes, 20, identity.tid);
    try std.testing.expectEqual(@as(u32, 25), (try decode(&bytes, identity)).data.fork.pid);
    put(u32, &bytes, 20, 123);
    try std.testing.expectError(error.AllocationTaskIdentity, decode(&bytes, identity));
    var comm: [48]u8 = undefined;
    header(&comm, 3);
    trailer(&comm, 100);
    put(u32, &comm, 8, identity.pid);
    put(u32, &comm, 12, identity.tid);
    @memcpy(comm[16..21], "child");
    try std.testing.expect((try decode(&comm, identity)).data == .rename);
    put(u16, &comm, 4, 1 << 13);
    try std.testing.expect((try decode(&comm, identity)).data == .exec);
}
test "only anonymous uprobe trampoline metadata bypasses mapping changes" {
    var bytes: [112]u8 = undefined;
    header(&bytes, 10);
    trailer(&bytes, 100);
    put(u32, &bytes, 8, identity.pid);
    put(u32, &bytes, 12, identity.tid);
    put(u64, &bytes, 16, 0x4000);
    put(u64, &bytes, 24, 4096);
    put(u32, &bytes, 64, 5);
    @memcpy(bytes[72..81], "[uprobes]");
    const mapping = (try decode(&bytes, identity)).data.probe_mapping;
    try std.testing.expectEqual(@as(u64, 0x5000), mapping.end);
    put(u32, &bytes, 64, 4); // Host kernel uses an execute-only XOL page.
    try std.testing.expect((try decode(&bytes, identity)).data == .probe_mapping);
    put(u64, &bytes, 48, 9); // A file named like the special mapping is not it.
    try std.testing.expect((try decode(&bytes, identity)).data == .mapping_change);
    put(u64, &bytes, 48, 0);
    bytes[73] = 'x';
    try std.testing.expect((try decode(&bytes, identity)).data == .mapping_change);
    put(u64, &bytes, 24, 0);
    try std.testing.expectError(error.AllocationRecordSize, decode(&bytes, identity));
}
test "ambiguous event identities and unsupported PMU bit formats are rejected" {
    try validateIdentity(identity);
    var duplicated = hooks;
    duplicated[1].return_id = hooks[0].entry_id;
    try std.testing.expectError(error.InvalidAllocationHook, validateIdentity(.{ .pid = 12, .tid = 13, .hooks = &duplicated }));
    try std.testing.expectEqual(@as(u64, 1), try retprobeMask("config:0\n"));
    try std.testing.expectEqual(@as(u64, 1) << 63, try retprobeMask("config:63"));
    for ([_][]const u8{ "config1:0", "config:64", "config:0-1", "config:", "config:0,2" }) |format|
        try std.testing.expectError(error.AllocationPmuFormat, retprobeMask(format));
}

// Register tuples from the single approved native-host probe, 2026-10-03.
// Its log did not retain timestamps or event IDs: those fields below are
// synthetic, so this is register-conversion/pairing replay, not raw perf replay.
test "observed host uprobe registers normalize into three complete allocation calls" {
    const a = std.testing.allocator;
    const tuples = [_]Registers{
        .{ .ax = 0x25, .di = 37, .si = 0x3cc4, .sp = 0x7ffc6081ab28, .ip = 0x55d4231922b9 },
        .{ .ax = 0x55d45b6e9540, .di = 4, .si = 0x55d45b6e9560, .sp = 0x7ffc6081ab30, .ip = 0x55d4231927a3 },
        .{ .ax = 0x4a, .di = 74, .si = 0xde8f650ef0564316, .sp = 0x7ffc6081ab28, .ip = 0x55d4231922b9 },
        .{ .ax = 0x55d45b6e9570, .di = 4, .si = 0x55d45b6e95c0, .sp = 0x7ffc6081ab30, .ip = 0x55d4231927a3 },
        .{ .ax = 0x6f, .di = 111, .si = 0xde8f650ef0564316, .sp = 0x7ffc6081ab28, .ip = 0x55d4231922b9 },
        .{ .ax = 0x55d45b6e95d0, .di = 4, .si = 0x55d45b6e9640, .sp = 0x7ffc6081ab30, .ip = 0x55d4231927a3 },
    };
    var store = try events.Store.init(1, 16);
    defer store.deinit(a);
    for (tuples, 0..) |regs, i| {
        const entry = i % 2 == 0;
        var bytes = testSample(if (entry) 100 else 101);
        put(u64, &bytes, 16, i + 1);
        const values = [_]u64{ regs.ax, regs.si, regs.di, regs.sp, regs.ip };
        for (values, 0..) |value, j| put(u64, &bytes, 40 + j * 8, value);
        const raw = try decode(&bytes, identity);
        const event = try normalizedSample(raw);
        try std.testing.expectEqual(regs.sp, raw.data.sample.registers.sp);
        try std.testing.expectEqual(@as(u64, 0x7ffc6081ab28), event.data.sample.stack_key);
        try std.testing.expectEqual(regs.ip, event.data.sample.ip);
        try std.testing.expectEqual(if (entry) regs.di else @as(u64, 0), event.data.sample.arg0);
        try std.testing.expectEqual(if (entry) regs.si else @as(u64, 0), event.data.sample.arg1);
        try std.testing.expectEqual(if (entry) @as(u64, 0) else regs.ax, event.data.sample.result);
        try store.feed(a, 0, event);
    }
    store.finish(false);
    const projected = try store.project(a);
    defer projected.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), projected.calls.len);
    for (projected.calls, 0..) |call, i| {
        try std.testing.expectEqual(@as(u64, (i + 1) * 37), call.arg0);
        try std.testing.expectEqual(tuples[i * 2 + 1].ax, call.result);
        const span = store.spans.items[projected.span_ids[i]];
        try std.testing.expectEqual(@as(?u32, @intCast(i * 2)), span.entry_record);
        try std.testing.expectEqual(@as(?u32, @intCast(i * 2 + 1)), span.return_record);
    }
}
test "normalization rejects absent stacks and retains mismatches for evidence gating" {
    const a = std.testing.allocator;
    var entry = try decode(&testSample(100), identity);
    entry.data.sample.registers.sp = 0;
    try std.testing.expectError(error.AllocationStackKeyUnavailable, normalizedSample(entry));
    var ret = try decode(&testSample(101), identity);
    for (0..9) |sp| {
        ret.data.sample.registers.sp = sp;
        try std.testing.expectError(error.AllocationStackKeyUnavailable, normalizedSample(ret));
    }
    try std.testing.expectError(error.AllocationExpectedSample, normalizedSample(.{ .time_ns = 77, .data = .thread_exit }));
    var store = try events.Store.init(1, 16);
    defer store.deinit(a);
    entry.data.sample.registers.sp = 0x1000;
    ret.data.sample.registers.sp = 0x1010;
    try store.feed(a, 0, try normalizedSample(entry));
    try store.feed(a, 0, try normalizedSample(ret));
    store.finish(false);
    try std.testing.expectError(error.AllocationEvidenceGap, store.project(a));
}

test "allocation entry stacks own callchain and caller evidence and reject malformed payloads" {
    var bytes: [144]u8 = @splat(0);
    const base = testSample(100);
    @memcpy(bytes[0..32], base[0..32]);
    put(u16, &bytes, 6, bytes.len);
    put(u64, &bytes, 32, 4);
    put(u64, &bytes, 40, @bitCast(@as(i64, -512))); // PERF_CONTEXT_USER
    put(u64, &bytes, 48, 0x5555);
    put(u64, &bytes, 56, 0x1234);
    put(u64, &bytes, 64, 0x2222);
    @memcpy(bytes[72..120], base[32..80]);
    put(u64, &bytes, 120, 8);
    put(u64, &bytes, 128, 0x1234);
    put(u64, &bytes, 136, 8);
    var who = identity;
    who.callstacks = true;
    const stack = (try decode(&bytes, who)).data.sample.stack;
    try std.testing.expectEqualSlices(u64, &.{ 0x5555, 0x1234, 0x2222 }, stack.addresses());
    try std.testing.expectEqual(stacks.Status.prefix, stack.status);
    // A kernel chain that skipped the entry caller gets the saved SP word.
    put(u64, &bytes, 56, 0x3333);
    const added = (try decode(&bytes, who)).data.sample.stack;
    try std.testing.expectEqualSlices(u64, &.{ 0x5555, 0x1234, 0x3333, 0x2222 }, added.addresses());
    put(u64, &bytes, 136, 0);
    try std.testing.expectEqual(stacks.Status.caller_missing, (try decode(&bytes, who)).data.sample.stack.status);
    put(u64, &bytes, 136, 9);
    try std.testing.expectError(error.AllocationEntryStackSize, decode(&bytes, who));
    put(u64, &bytes, 136, 8);
    for (0..bytes.len) |n| {
        if (n >= 8) put(u16, &bytes, 6, @intCast(n));
        if (decode(bytes[0..n], who)) |_| return error.TruncatedStackAccepted else |_| {}
    }
    put(u16, &bytes, 6, bytes.len);
    put(u64, &bytes, 32, std.math.maxInt(u64));
    try std.testing.expectError(error.AllocationCallchainSize, decode(&bytes, who));
    // Return probes deliberately keep the small original payload.
    try std.testing.expectEqual(stacks.Status.disabled, (try decode(&testSample(101), who)).data.sample.stack.status);
}
