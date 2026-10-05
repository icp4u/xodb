//! Strict Linux x86-64 function-uprobe record decoding. Raw register evidence is
//! retained independently from the narrowly documented SysV entry/return adapter.
const std = @import("std");
const types = @import("types.zig");
pub const max_sources = 16;
pub const max_record_size = 4096;
pub const register_mask: u64 = 0x301bd;
pub const Hook = struct { id: u16, entry_id: u64, return_id: u64 };
pub const Identity = struct { pid: u32, tid: u32, hooks: []const Hook, callstacks: bool = false };
pub const Record = struct {
    time_ns: u64,
    data: union(enum) {
        sample: types.Sample,
        lost: u64,
        throttle,
        unthrottle,
        thread_exit,
        exec,
        rename,
        mapping_change,
        probe_mapping: struct { start: u64, end: u64 },
        fork,
    },
    pub fn event(self: Record, thread_id: u64, tid: u32) ?types.Event {
        const data: @FieldType(types.Event, "data") = switch (self.data) {
            .sample => |v| .{ .sample = v },
            .lost => |v| .{ .lost = v },
            .throttle => .throttle,
            .unthrottle => .unthrottle,
            .thread_exit => .thread_exit,
            .exec => .exec,
            .mapping_change => .mapping_change,
            .fork => .fork,
            .rename, .probe_mapping => return null,
        };
        return .{ .thread_id = thread_id, .tid = tid, .time_ns = self.time_ns, .data = data };
    }
};
pub fn validateIdentity(who: Identity) !void {
    if (who.pid == 0 or who.tid == 0 or who.pid > std.math.maxInt(i32) or who.tid > std.math.maxInt(i32) or who.hooks.len == 0 or who.hooks.len > max_sources) return error.InvalidFunctionIdentity;
    for (who.hooks, 0..) |hook, i| {
        if (hook.id == 0 or hook.entry_id == 0 or hook.return_id == 0 or hook.entry_id == hook.return_id) return error.InvalidFunctionHook;
        for (who.hooks[0..i]) |old| if (hook.id == old.id or hook.entry_id == old.entry_id or hook.entry_id == old.return_id or hook.return_id == old.entry_id or hook.return_id == old.return_id) return error.InvalidFunctionHook;
    }
}
fn selected(who: Identity, id: u64) !struct { hook: Hook, phase: types.Phase } {
    for (who.hooks) |hook| {
        if (id == hook.entry_id) return .{ .hook = hook, .phase = .enter };
        if (id == hook.return_id) return .{ .hook = hook, .phase = .leave };
    }
    return error.FunctionEventIdentity;
}
fn number(comptime T: type, bytes: []const u8, at: usize) !T {
    if (at > bytes.len or @sizeOf(T) > bytes.len - at) return error.FunctionRecordTruncated;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
fn task(bytes: []const u8, at: usize, who: Identity) !void {
    if (try number(u32, bytes, at) != who.pid or try number(u32, bytes, at + 4) != who.tid) return error.FunctionTaskIdentity;
}
fn append(stack: *types.Stack, pc: u64) void {
    if (pc == 0 or pc >= 0x8000000000000000) return;
    if (stack.len == types.max_stack_pcs) {
        stack.truncated = true;
        return;
    }
    stack.pcs[stack.len] = pc;
    stack.len += 1;
}
fn capturedStack(ip: u64, caller: ?u64, chain: []const u64) types.Stack {
    var stack = types.Stack{};
    append(&stack, ip);
    if (caller) |pc| append(&stack, pc);
    var first_pc = true;
    var first_caller = true;
    var captured: usize = 0;
    for (chain) |pc| {
        if (pc >= 0x8000000000000000) continue;
        if (pc == 0) break;
        captured += 1;
        if (first_pc) {
            first_pc = false;
            if (pc == ip) continue;
        }
        if (first_caller) {
            first_caller = false;
            if (caller != null and pc == caller.?) continue;
        }
        append(&stack, pc);
    }
    if (captured >= types.max_stack_pcs) stack.truncated = true;
    return stack;
}
/// Samples: TID,TIME,ID,[CALLCHAIN],ABI,AX,CX,DX,SI,DI,SP,IP,R8,R9,[STACK_USER].
/// Metadata: TID,TIME,ID trailers. Only entries have optional captured stacks.
/// This ABI adapter applies to ordinary SysV function entries, not interior
/// probes, stack-switching functions, FP/vector/aggregate arguments or tail calls.
pub fn decode(bytes: []const u8, who: Identity) !Record {
    try validateIdentity(who);
    if (bytes.len < 8 or bytes.len > max_record_size or bytes.len != try number(u16, bytes, 6) or bytes.len % 8 != 0) return error.FunctionRecordSize;
    const kind = try number(u32, bytes, 0);
    const misc = try number(u16, bytes, 4);
    if (kind == 9) {
        if (misc & 7 != 2) return error.FunctionSampleMode;
        try task(bytes, 8, who);
        const chosen = try selected(who, try number(u64, bytes, 24));
        const stacks = who.callstacks and chosen.phase == .enter;
        var at: usize = 32;
        var chain: [types.max_stack_pcs + 2]u64 = undefined;
        var count: usize = 0;
        if (stacks) {
            const n = try number(u64, bytes, at);
            if (n > chain.len) return error.FunctionCallchainSize;
            at += 8;
            count = @intCast(n);
            for (chain[0..count]) |*pc| {
                pc.* = try number(u64, bytes, at);
                at += 8;
            }
        }
        const abi = try number(u64, bytes, at);
        if (abi != 2) return error.FunctionRegisterAbi;
        at += 8;
        const raw = types.RawRegisters{
            .abi = abi,
            .mask = register_mask,
            .ax = try number(u64, bytes, at),
            .cx = try number(u64, bytes, at + 8),
            .dx = try number(u64, bytes, at + 16),
            .si = try number(u64, bytes, at + 24),
            .di = try number(u64, bytes, at + 32),
            .sp = try number(u64, bytes, at + 40),
            .ip = try number(u64, bytes, at + 48),
            .r8 = try number(u64, bytes, at + 56),
            .r9 = try number(u64, bytes, at + 64),
        };
        at += 72;
        const entering = chosen.phase == .enter;
        const key = if (entering) raw.sp else std.math.sub(u64, raw.sp, 8) catch return error.FunctionStackKeyUnavailable;
        if (key == 0) return error.FunctionStackKeyUnavailable;
        var sample = types.Sample{
            .phase = chosen.phase,
            .function_id = chosen.hook.id,
            .stack_key = key,
            .ip = raw.ip,
            .raw_registers = raw,
            .args = if (entering) .{ raw.di, raw.si, raw.dx, raw.cx, raw.r8, raw.r9 } else @splat(0),
            .arg_count = if (entering) 6 else 0,
            .result = if (entering) null else raw.ax,
        };
        if (stacks) {
            const size = try number(u64, bytes, at);
            at += 8;
            if (size != 0 and size != 8) return error.FunctionEntryStackSize;
            sample.stack_word_size = @intCast(size);
            if (size != 0) {
                const word = try number(u64, bytes, at);
                const valid = try number(u64, bytes, at + 8);
                if (valid > size) return error.FunctionEntryStackSize;
                std.mem.writeInt(u64, &sample.stack_word, word, .little);
                sample.stack_word_valid = @intCast(valid);
                at += 16;
            }
            const caller = if (sample.stack_word_valid == 8) std.mem.readInt(u64, &sample.stack_word, .little) else null;
            sample.stack = capturedStack(raw.ip, caller, chain[0..count]);
        }
        if (at != bytes.len) return error.FunctionRegisterSize;
        return .{ .time_ns = try number(u64, bytes, 16), .data = .{ .sample = sample } };
    }
    if (bytes.len < 32) return error.FunctionRecordTruncated;
    const tail = bytes.len - 24;
    try task(bytes, tail, who);
    const id = try number(u64, bytes, tail + 16);
    _ = try selected(who, id);
    const data: @FieldType(Record, "data") = switch (kind) {
        2 => blk: {
            if (tail != 24 or try number(u64, bytes, 8) != id) return error.FunctionRecordIdentity;
            break :blk .{ .lost = try number(u64, bytes, 16) };
        },
        13 => blk: {
            if (tail != 16) return error.FunctionRecordSize;
            break :blk .{ .lost = try number(u64, bytes, 8) };
        },
        5, 6 => blk: {
            if (tail != 32 or try number(u64, bytes, 16) != id) return error.FunctionRecordIdentity;
            break :blk if (kind == 5) .throttle else .unthrottle;
        },
        4 => blk: {
            if (tail != 32 or try number(u32, bytes, 8) != who.pid or try number(u32, bytes, 16) != who.tid) return error.FunctionTaskIdentity;
            break :blk .thread_exit;
        },
        7 => blk: {
            if (tail != 32 or try number(u32, bytes, 12) != who.pid or try number(u32, bytes, 20) != who.tid) return error.FunctionTaskIdentity;
            const pid = try number(u32, bytes, 8);
            const tid = try number(u32, bytes, 16);
            if (pid == 0 or tid == 0 or pid > std.math.maxInt(i32) or tid > std.math.maxInt(i32)) return error.FunctionTaskIdentity;
            break :blk .fork;
        },
        1, 10 => blk: {
            try task(bytes, 8, who);
            const filename: usize = if (kind == 1) 40 else 72;
            if (tail <= filename) return error.FunctionRecordSize;
            const length = std.mem.indexOfScalar(u8, bytes[filename..tail], 0) orelse return error.FunctionRecordSize;
            const start = try number(u64, bytes, 16);
            const size = try number(u64, bytes, 24);
            const end = std.math.add(u64, start, size) catch return error.FunctionRecordSize;
            if (size == 0) return error.FunctionRecordSize;
            if (kind == 10 and misc & (1 << 14) == 0 and
                std.mem.eql(u8, bytes[filename..][0..length], "[uprobes]") and
                try number(u64, bytes, 32) == 0 and try number(u64, bytes, 40) == 0 and
                try number(u64, bytes, 48) == 0 and (try number(u32, bytes, 64)) & ~@as(u32, 1) == 4)
                break :blk .{ .probe_mapping = .{ .start = start, .end = end } };
            break :blk .mapping_change;
        },
        3 => blk: {
            try task(bytes, 8, who);
            if (tail < 24 or std.mem.indexOfScalar(u8, bytes[16..tail], 0) == null) return error.FunctionRecordSize;
            break :blk if (misc & (1 << 13) != 0) .exec else .rename;
        },
        else => return error.FunctionUnknownRecord,
    };
    return .{ .time_ns = try number(u64, bytes, tail + 8), .data = data };
}
fn put(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}
fn header(bytes: []u8, kind: u32) void {
    @memset(bytes, 0);
    put(u32, bytes, 0, kind);
    put(u16, bytes, 4, 2);
    put(u16, bytes, 6, @intCast(bytes.len));
}
const hooks = [_]Hook{.{ .id = 91, .entry_id = 100, .return_id = 101 }};
const identity = Identity{ .pid = 12, .tid = 13, .hooks = &hooks };
fn trailer(bytes: []u8, id: u64) void {
    const at = bytes.len - 24;
    put(u32, bytes, at, 12);
    put(u32, bytes, at + 4, 13);
    put(u64, bytes, at + 8, 10);
    put(u64, bytes, at + 16, id);
}
fn testSample(id: u64) [112]u8 {
    var bytes: [112]u8 = undefined;
    header(&bytes, 9);
    put(u32, &bytes, 8, 12);
    put(u32, &bytes, 12, 13);
    put(u64, &bytes, 16, 10);
    put(u64, &bytes, 24, id);
    put(u64, &bytes, 32, 2);
    const regs = [_]u64{ 0xf000000000000001, 44, 33, 22, 11, if (id == 100) 0x1000 else 0x1008, 0x4000, 55, 66 };
    for (regs, 0..) |v, i| put(u64, &bytes, 40 + i * 8, v);
    return bytes;
}
test "function samples retain all raw registers and explicit six-word SysV adaptation" {
    const entry = (try decode(&testSample(100), identity)).data.sample;
    try std.testing.expectEqualSlices(u64, &.{ 11, 22, 33, 44, 55, 66 }, &entry.args);
    try std.testing.expectEqual(@as(u64, 0xf000000000000001), entry.raw_registers.?.ax);
    try std.testing.expect(entry.result == null and entry.arg_count == 6 and entry.stack_key == 0x1000);
    const leave = (try decode(&testSample(101), identity)).data.sample;
    try std.testing.expectEqual(@as(u64, 0xf000000000000001), leave.result.?);
    try std.testing.expect(leave.arg_count == 0 and leave.stack_key == entry.stack_key and leave.raw_registers.?.sp == 0x1008);
}
test "function record identity ABI bounds and return SP underflow fail explicitly" {
    var bytes = testSample(100);
    for (0..bytes.len) |n| {
        if (n >= 8) put(u16, &bytes, 6, @intCast(n));
        if (decode(bytes[0..n], identity)) |_| return error.TruncatedFunctionAccepted else |_| {}
    }
    bytes = testSample(101);
    for (0..9) |sp| {
        put(u64, &bytes, 80, sp);
        try std.testing.expectError(error.FunctionStackKeyUnavailable, decode(&bytes, identity));
    }
    bytes = testSample(100);
    put(u64, &bytes, 32, 1);
    try std.testing.expectError(error.FunctionRegisterAbi, decode(&bytes, identity));
    put(u64, &bytes, 32, 2);
    put(u64, &bytes, 24, 999);
    try std.testing.expectError(error.FunctionEventIdentity, decode(&bytes, identity));
    var duplicate = [_]Hook{ hooks[0], .{ .id = 92, .entry_id = 101, .return_id = 102 } };
    try std.testing.expectError(error.InvalidFunctionHook, validateIdentity(.{ .pid = 12, .tid = 13, .hooks = &duplicate }));
}
test "function entry preserves partial SP bytes without manufacturing a caller PC" {
    var bytes: [160]u8 = @splat(0);
    const base = testSample(100);
    @memcpy(bytes[0..32], base[0..32]);
    put(u16, &bytes, 6, bytes.len);
    put(u64, &bytes, 32, 2);
    put(u64, &bytes, 40, @bitCast(@as(i64, -512)));
    put(u64, &bytes, 48, 0x4000);
    @memcpy(bytes[56..136], base[32..112]);
    put(u64, &bytes, 136, 8);
    put(u64, &bytes, 144, 0x1234);
    put(u64, &bytes, 152, 4);
    var who = identity;
    who.callstacks = true;
    const partial = (try decode(&bytes, who)).data.sample;
    try std.testing.expectEqual(@as(u8, 4), partial.stack_word_valid);
    try std.testing.expectEqual(@as(u8, 1), partial.stack.len);
    put(u64, &bytes, 152, 8);
    const full = (try decode(&bytes, who)).data.sample;
    try std.testing.expectEqualSlices(u64, &.{ 0x4000, 0x1234 }, full.stack.pcs[0..full.stack.len]);
    put(u64, &bytes, 152, 9);
    try std.testing.expectError(error.FunctionEntryStackSize, decode(&bytes, who));
    put(u64, &bytes, 32, std.math.maxInt(u64));
    try std.testing.expectError(error.FunctionCallchainSize, decode(&bytes, who));
    const leave = (try decode(&testSample(101), who)).data.sample;
    try std.testing.expect(leave.stack_word_size == 0 and leave.stack.len == 0);
}
test "function metadata preserves loss and scope boundaries and only ignores verified uprobes mapping" {
    var loss: [48]u8 = undefined;
    header(&loss, 2);
    trailer(&loss, 100);
    put(u64, &loss, 8, 100);
    put(u64, &loss, 16, 4);
    try std.testing.expectEqual(@as(u64, 4), (try decode(&loss, identity)).data.lost);
    var mmap: [112]u8 = undefined;
    header(&mmap, 10);
    trailer(&mmap, 100);
    put(u32, &mmap, 8, 12);
    put(u32, &mmap, 12, 13);
    put(u64, &mmap, 16, 0x5000);
    put(u64, &mmap, 24, 4096);
    put(u32, &mmap, 64, 4);
    @memcpy(mmap[72..81], "[uprobes]");
    try std.testing.expect((try decode(&mmap, identity)).data == .probe_mapping);
    put(u64, &mmap, 48, 3);
    try std.testing.expect((try decode(&mmap, identity)).data == .mapping_change);
    put(u64, &mmap, 16, std.math.maxInt(u64));
    try std.testing.expectError(error.FunctionRecordSize, decode(&mmap, identity));
    var fork: [56]u8 = undefined;
    header(&fork, 7);
    trailer(&fork, 100);
    put(u32, &fork, 8, 19);
    put(u32, &fork, 12, 12);
    put(u32, &fork, 16, 19);
    put(u32, &fork, 20, 13);
    try std.testing.expect((try decode(&fork, identity)).event(7, 13).?.data == .fork);
    var comm: [48]u8 = undefined;
    header(&comm, 3);
    trailer(&comm, 100);
    put(u32, &comm, 8, 12);
    put(u32, &comm, 12, 13);
    try std.testing.expect((try decode(&comm, identity)).event(7, 13) == null);
    put(u16, &comm, 4, 1 << 13);
    try std.testing.expect((try decode(&comm, identity)).event(7, 13).?.data == .exec);
}
