//! Adapted from Grok's T10 decoder fixtures; production buffer-boundary regressions follow.
const std = @import("std");
const records = @import("records.zig");

const base_bits = records.Bits.ip | records.Bits.tid | records.Bits.time | records.Bits.period;
const user_bits = base_bits | records.Bits.regs_user | records.Bits.stack_user;
const sp_ip = (@as(u64, 1) << 7) | (@as(u64, 1) << 8);

const W = struct {
    b: []u8,
    n: usize = 0,
    fn putU16(self: *W, v: u16) void {
        self.raw(std.mem.asBytes(&v));
    }
    fn putU32(self: *W, v: u32) void {
        self.raw(std.mem.asBytes(&v));
    }
    fn putU64(self: *W, v: u64) void {
        self.raw(std.mem.asBytes(&v));
    }
    fn raw(self: *W, bytes: []const u8) void {
        @memcpy(self.b[self.n..][0..bytes.len], bytes);
        self.n += bytes.len;
    }
    fn pad(self: *W) void {
        while (self.n % 8 != 0) self.raw(&.{0});
    }
    fn finish(self: *W) []u8 {
        self.pad();
        const size: u16 = @intCast(self.n);
        @memcpy(self.b[6..8], std.mem.asBytes(&size));
        return self.b[0..self.n];
    }
    fn begin(self: *W, typ: u32, misc: u16) void {
        self.putU32(typ);
        self.putU16(misc);
        self.putU16(0);
    }
};

fn place(ring: []u8, at: u64, bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) ring[@intCast((at + i) % ring.len)] = bytes[i];
}

fn go(ring: []u8, tail: u64, head: u64, in: records.DecodeInput, samples: []records.Sample, sides: []records.Side) records.Report {
    return records.decode(ring, head, tail, in, samples, sides);
}

fn input(bits: u64, mask: u64, request: u32, states: []records.UserState, stack: []u8) records.DecodeInput {
    return .{
        .sample_type = bits,
        .sample_id_all = true,
        .max_frames = 8,
        .user_regs_mask = mask,
        .user_stack_request = request,
        .user_states = states,
        .user_stack = stack,
    };
}

fn sampleHead(w: *W, ip: u64) void {
    w.begin(records.Type.sample, records.Misc.user);
    w.putU64(ip);
    w.putU32(40);
    w.putU32(41);
    w.putU64(1000);
    w.putU64(7);
}

fn expectOk(report: records.Report) !void {
    try std.testing.expectEqual(records.Status.ok, report.status);
}

test "abi 64 stack lands in the register slots and the retention buffer" {
    var mem: [256]u8 = undefined;
    var w = W{ .b = &mem };
    sampleHead(&w, 0x1000);
    w.putU64(records.regs_abi_64);
    w.putU64(0x70);
    w.putU64(0x1000);
    w.putU64(32);
    w.raw(&@as([32]u8, @splat(0x11)));
    w.putU64(32);
    const rec = w.finish();
    var ring: [256]u8 = @as([256]u8, @splat(0));
    place(&ring, 0, rec);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [1]records.UserState = undefined;
    var stack: [64]u8 = undefined;
    const report = go(&ring, 0, rec.len, input(user_bits, sp_ip, 32, &states, &stack), &samples, &sides);
    try expectOk(report);
    try std.testing.expectEqual(@as(usize, 1), report.samples);
    try std.testing.expectEqual(@as(u32, 1), samples[0].user_state);
    try std.testing.expectEqual(@as(u64, 0x1000), samples[0].ip);
    try std.testing.expect(states[0].regs_present);
    try std.testing.expectEqual(records.regs_abi_64, states[0].abi);
    try std.testing.expectEqual(@as(u64, 0x70), states[0].regs[7]);
    try std.testing.expectEqual(@as(u64, 0x1000), states[0].regs[8]);
    try std.testing.expectEqual(@as(u64, 0), states[0].regs[0]);
    try std.testing.expect(states[0].stack_present);
    try std.testing.expect(!states[0].stack_short);
    try std.testing.expectEqual(@as(u32, 32), states[0].stack_len);
    try std.testing.expectEqual(@as(u8, 0x11), stack[0]);
    try std.testing.expectEqual(@as(u32, 32), report.user_stack_bytes);
}

test "abi none omits the register array and size zero omits dyn_size" {
    var mem: [128]u8 = undefined;
    var w = W{ .b = &mem };
    sampleHead(&w, 0x2000);
    w.putU64(records.regs_abi_none);
    w.putU64(0);
    const rec = w.finish();
    var ring: [128]u8 = @as([128]u8, @splat(0));
    place(&ring, 0, rec);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [1]records.UserState = undefined;
    var stack: [8]u8 = undefined;
    const report = go(&ring, 0, rec.len, input(user_bits, sp_ip, 64, &states, &stack), &samples, &sides);
    try expectOk(report);
    try std.testing.expect(!states[0].regs_present);
    try std.testing.expectEqual(@as(u64, 0), states[0].regs[7]);
    try std.testing.expect(!states[0].stack_present);
    try std.testing.expect(!states[0].stack_short);
    try std.testing.expectEqual(@as(u32, 0), states[0].stack_len);
    try std.testing.expectEqual(@as(u32, 0), report.user_stack_bytes);
}

test "short dyn_size keeps only the trusted prefix" {
    var mem: [256]u8 = undefined;
    var w = W{ .b = &mem };
    sampleHead(&w, 0x3000);
    w.putU64(records.regs_abi_64);
    w.putU64(0x80);
    w.putU64(0x3000);
    w.putU64(64);
    w.raw(&@as([16]u8, @splat(0xaa)));
    w.raw(&@as([48]u8, @splat(0xbb)));
    w.putU64(16);
    const rec = w.finish();
    var ring: [256]u8 = @as([256]u8, @splat(0));
    place(&ring, 0, rec);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [1]records.UserState = undefined;
    var stack: [64]u8 = @as([64]u8, @splat(0));
    const report = go(&ring, 0, rec.len, input(user_bits, sp_ip, 64, &states, &stack), &samples, &sides);
    try expectOk(report);
    try std.testing.expect(states[0].stack_short);
    try std.testing.expectEqual(@as(u64, 64), states[0].stack_size);
    try std.testing.expectEqual(@as(u64, 16), states[0].stack_dyn);
    try std.testing.expectEqual(@as(u32, 16), states[0].stack_len);
    try std.testing.expectEqual(@as(u8, 0xaa), stack[0]);
    try std.testing.expectEqual(@as(u8, 0), stack[16]);
}

test "dyn_size past the field and an unaligned size are not consumed" {
    var mem: [256]u8 = undefined;
    var w = W{ .b = &mem };
    sampleHead(&w, 0x4000);
    w.putU64(records.regs_abi_64);
    w.putU64(1);
    w.putU64(2);
    w.putU64(32);
    w.raw(&@as([32]u8, @splat(0)));
    w.putU64(64);
    const over = w.finish();
    var ring: [256]u8 = @as([256]u8, @splat(0));
    place(&ring, 0, over);
    var samples: [2]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [2]records.UserState = undefined;
    var stack: [64]u8 = undefined;
    const bad = go(&ring, 0, over.len, input(user_bits, sp_ip, 32, &states, &stack), &samples, &sides);
    try std.testing.expectEqual(records.Status.malformed, bad.status);
    try std.testing.expectEqual(@as(u64, 0), bad.consumed);
    try std.testing.expectEqualStrings("dyn_size exceeds the stack field", bad.reason);

    var mem2: [256]u8 = undefined;
    var u = W{ .b = &mem2 };
    sampleHead(&u, 0x4001);
    u.putU64(records.regs_abi_64);
    u.putU64(1);
    u.putU64(2);
    u.putU64(4);
    u.raw(&[_]u8{ 1, 2, 3, 4 });
    u.putU64(4);
    const odd = u.finish();
    var ring2: [256]u8 = @as([256]u8, @splat(0));
    place(&ring2, 0, odd);
    const odd_report = go(&ring2, 0, odd.len, input(user_bits, sp_ip, 64, &states, &stack), &samples, &sides);
    try std.testing.expectEqual(records.Status.malformed, odd_report.status);
    try std.testing.expectEqual(@as(u64, 0), odd_report.consumed);
    try std.testing.expectEqualStrings("user stack size is not 8-byte aligned", odd_report.reason);
}

test "a wrapped user sample matches the linear decode" {
    var mem: [256]u8 = undefined;
    var w = W{ .b = &mem };
    sampleHead(&w, 0x55);
    w.putU64(records.regs_abi_64);
    w.putU64(0x10);
    w.putU64(0x55);
    w.putU64(16);
    w.raw(&@as([16]u8, @splat(9)));
    w.putU64(16);
    const rec = w.finish();
    var linear: [256]u8 = @as([256]u8, @splat(0));
    var wrapped: [256]u8 = @as([256]u8, @splat(0));
    place(&linear, 0, rec);
    const at: u64 = wrapped.len - 8;
    place(&wrapped, at, rec);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [1]records.UserState = undefined;
    var stack_a: [32]u8 = undefined;
    var stack_b: [32]u8 = undefined;
    const a = go(&linear, 0, rec.len, input(user_bits, sp_ip, 16, &states, &stack_a), &samples, &sides);
    const state_a = states[0];
    const b = go(&wrapped, at, at + rec.len, input(user_bits, sp_ip, 16, &states, &stack_b), &samples, &sides);
    try expectOk(a);
    try expectOk(b);
    try std.testing.expectEqual(state_a.regs[7], states[0].regs[7]);
    try std.testing.expectEqual(state_a.stack_len, states[0].stack_len);
    try std.testing.expectEqualSlices(u8, stack_a[0..16], stack_b[0..16]);
}

test "stack retention backpressure leaves the record queued" {
    var mem: [512]u8 = undefined;
    var first = W{ .b = mem[0..] };
    sampleHead(&first, 0x61);
    first.putU64(records.regs_abi_64);
    first.putU64(1);
    first.putU64(0x61);
    first.putU64(32);
    first.raw(&@as([32]u8, @splat(1)));
    first.putU64(32);
    const rec1 = first.finish();
    const n1 = rec1.len;
    var second = W{ .b = mem[n1..] };
    sampleHead(&second, 0x62);
    second.putU64(records.regs_abi_64);
    second.putU64(2);
    second.putU64(0x62);
    second.putU64(32);
    second.raw(&@as([32]u8, @splat(2)));
    second.putU64(32);
    const rec2 = second.finish();
    const total = n1 + rec2.len;
    var ring: [512]u8 = @as([512]u8, @splat(0));
    place(&ring, 0, mem[0..total]);
    var samples: [2]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [2]records.UserState = undefined;
    var stack: [32]u8 = undefined;
    const report = go(&ring, 0, total, input(user_bits, sp_ip, 32, &states, &stack), &samples, &sides);
    try std.testing.expectEqual(records.Status.capacity, report.status);
    try std.testing.expectEqual(@as(usize, 1), report.samples);
    try std.testing.expectEqual(@as(u64, n1), report.consumed);
    try std.testing.expectEqual(@as(u32, 32), report.user_stack_bytes);
    try std.testing.expectEqual(@as(u64, 0x61), samples[0].ip);
    const again = go(&ring, n1, total, input(user_bits, sp_ip, 32, &states, &stack), &samples, &sides);
    try expectOk(again);
    try std.testing.expectEqual(@as(u64, 0x62), samples[0].ip);
    try std.testing.expectEqual(@as(u64, 2), states[0].regs[7]);
}

test "a record above 8192 stays malformed until the limit is raised" {
    const header = 8 + 32 + 24 + 8 + 8192 + 8;
    try std.testing.expect(header > 8192 and header < 16384);
    const raw = try std.testing.allocator.alloc(u8, 16384);
    defer std.testing.allocator.free(raw);
    var w = W{ .b = raw };
    sampleHead(&w, 0x70);
    w.putU64(records.regs_abi_64);
    w.putU64(9);
    w.putU64(0x70);
    w.putU64(8192);
    w.raw(&@as([8192]u8, @splat(0x5a)));
    w.putU64(8192);
    const rec = w.finish();
    try std.testing.expectEqual(header, rec.len);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [1]records.UserState = undefined;
    const stack = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(stack);
    const limited = go(raw, 0, rec.len, input(user_bits, sp_ip, 8192, &states, stack), &samples, &sides);
    try std.testing.expectEqual(records.Status.malformed, limited.status);
    try std.testing.expectEqualStrings("record exceeds 8192-byte bound", limited.reason);
    try std.testing.expectEqual(@as(u64, 0), limited.consumed);
    var wide = input(user_bits, sp_ip, 8192, &states, stack);
    wide.record_limit = 16384;
    const accepted = go(raw, 0, rec.len, wide, &samples, &sides);
    try expectOk(accepted);
    try std.testing.expectEqual(@as(u32, 8192), states[0].stack_len);
    try std.testing.expectEqual(@as(u8, 0x5a), stack[8191]);
}

test "sample bits without user fields leave user_state clear" {
    var mem: [64]u8 = undefined;
    var w = W{ .b = &mem };
    sampleHead(&w, 0x80);
    const rec = w.finish();
    var ring: [64]u8 = @as([64]u8, @splat(0));
    place(&ring, 0, rec);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    const report = go(&ring, 0, rec.len, .{ .sample_type = base_bits, .sample_id_all = true }, &samples, &sides);
    try expectOk(report);
    try std.testing.expectEqual(@as(u32, 0), samples[0].user_state);
    try std.testing.expectEqual(@as(u64, 0x80), samples[0].ip);
}

test "callchain and a lost side stay beside the user stack" {
    var mem: [256]u8 = undefined;
    var lost = W{ .b = &mem };
    lost.begin(records.Type.lost, 0);
    lost.putU64(3);
    lost.putU64(4);
    lost.putU32(40);
    lost.putU32(41);
    lost.putU64(900);
    const rec_lost = lost.finish();
    const n1 = rec_lost.len;
    var w = W{ .b = mem[n1..] };
    w.begin(records.Type.sample, records.Misc.user);
    w.putU64(0x90);
    w.putU32(40);
    w.putU32(41);
    w.putU64(1000);
    w.putU64(7);
    w.putU64(3);
    w.putU64(records.context_user);
    w.putU64(0x1111);
    w.putU64(0x2222);
    w.putU64(records.regs_abi_64);
    w.putU64(0x42);
    w.putU64(0x90);
    w.putU64(16);
    w.raw(&@as([16]u8, @splat(7)));
    w.putU64(16);
    const rec_sample = w.finish();
    const total = n1 + rec_sample.len;
    var ring: [256]u8 = @as([256]u8, @splat(0));
    place(&ring, 0, mem[0..total]);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [1]records.UserState = undefined;
    var stack: [16]u8 = undefined;
    const bits = user_bits | records.Bits.callchain;
    const report = go(&ring, 0, total, input(bits, sp_ip, 16, &states, &stack), &samples, &sides);
    try expectOk(report);
    try std.testing.expectEqual(@as(usize, 1), report.sides);
    try std.testing.expectEqual(records.SideKind.lost, sides[0].kind);
    try std.testing.expectEqual(@as(u64, 4), sides[0].lost_count);
    try std.testing.expectEqual(@as(u32, 1), samples[0].user_state);
    try std.testing.expect(samples[0].frame_count >= 2);
    try std.testing.expectEqual(@as(u64, 0x1111), samples[0].frames[1].address);
    try std.testing.expectEqual(@as(u64, 0x42), states[0].regs[7]);
    try std.testing.expectEqual(@as(u8, 7), stack[0]);
}

test "empty or undersized output buffers apply backpressure without consuming a record" {
    var mem: [128]u8 = undefined;
    var w = W{ .b = &mem };
    sampleHead(&w, 0xa0);
    w.putU64(records.regs_abi_64);
    w.putU64(1);
    w.putU64(2);
    w.putU64(16);
    w.raw(&@as([16]u8, @splat(0)));
    w.putU64(16);
    const rec = w.finish();
    var ring: [128]u8 = @as([128]u8, @splat(0));
    place(&ring, 0, rec);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    const missing = go(&ring, 0, rec.len, input(user_bits, sp_ip, 16, &.{}, &.{}), &samples, &sides);
    try std.testing.expectEqual(records.Status.capacity, missing.status);
    try std.testing.expectEqual(@as(u64, 0), missing.consumed);
    var states: [1]records.UserState = undefined;
    var tiny: [8]u8 = undefined;
    const huge = go(&ring, 0, rec.len, input(user_bits, sp_ip, 16, &states, &tiny), &samples, &sides);
    try std.testing.expectEqual(records.Status.capacity, huge.status);
    try std.testing.expectEqual(@as(u32, 0), huge.user_states);
    try std.testing.expectEqual(@as(u64, 0), huge.consumed);
}

test "invalid fields following a user stack commit no side data" {
    var raw: [256]u8 = undefined;
    var w = W{ .b = &raw };
    sampleHead(&w, 0x1000);
    w.putU64(records.regs_abi_64);
    w.putU64(0x7000);
    w.putU64(0x1000);
    w.putU64(16);
    w.raw(&(@as([16]u8, @splat(7))));
    w.putU64(16);
    const rec = w.finish();
    var ring: [256]u8 = @splat(0);
    place(&ring, 0, rec);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [1]records.UserState = undefined;
    var stack: [16]u8 = undefined;
    const missing_weight = go(&ring, 0, rec.len, input(user_bits | records.Bits.weight, sp_ip, 16, &states, &stack), &samples, &sides);
    try std.testing.expectEqual(records.Status.malformed, missing_weight.status);
    try std.testing.expectEqual(@as(u64, 0), missing_weight.consumed);
    try std.testing.expectEqual(@as(usize, 0), missing_weight.samples);
    try std.testing.expectEqual(@as(u32, 0), missing_weight.user_states);
    try std.testing.expectEqual(@as(u32, 0), missing_weight.user_stack_bytes);

    w.putU64(99);
    const extra = w.finish();
    place(&ring, 0, extra);
    const trailing = go(&ring, 0, extra.len, input(user_bits, sp_ip, 16, &states, &stack), &samples, &sides);
    try std.testing.expectEqual(records.Status.malformed, trailing.status);
    try std.testing.expectEqual(@as(u32, 0), trailing.user_states);
    try std.testing.expectEqual(@as(u32, 0), trailing.user_stack_bytes);
    const valid = go(&ring, 0, extra.len, input(user_bits | records.Bits.weight, sp_ip, 16, &states, &stack), &samples, &sides);
    try expectOk(valid);
    try std.testing.expectEqual(@as(u32, 1), valid.user_states);
    try std.testing.expectEqual(@as(u64, 99), samples[0].weight);
}

test "user-state offset overflow and unsupported ABI reject cleanly" {
    var raw: [256]u8 = undefined;
    var w = W{ .b = &raw };
    sampleHead(&w, 0x1000);
    const abi_at = w.n;
    w.putU64(records.regs_abi_64);
    w.putU64(0x7000);
    w.putU64(0x1000);
    w.putU64(16);
    w.raw(&(@as([16]u8, @splat(7))));
    w.putU64(16);
    const rec = w.finish();
    var ring: [256]u8 = @splat(0);
    place(&ring, 0, rec);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [1]records.UserState = undefined;
    var stack: [16]u8 = undefined;
    const normal = input(user_bits, sp_ip, 16, &states, &stack);
    var bad = normal;
    bad.user_state_base = std.math.maxInt(u32);
    var report = go(&ring, 0, rec.len, bad, &samples, &sides);
    try std.testing.expectEqual(records.Status.malformed, report.status);
    try std.testing.expectEqual(@as(u64, 0), report.consumed);
    bad = normal;
    bad.user_stack_base = std.math.maxInt(u32) - 7;
    report = go(&ring, 0, rec.len, bad, &samples, &sides);
    try std.testing.expectEqual(records.Status.malformed, report.status);
    try std.testing.expectEqual(@as(u32, 0), report.user_states);
    std.mem.writeInt(u64, ring[abi_at..][0..8], 3, .little);
    report = go(&ring, 0, rec.len, normal, &samples, &sides);
    try std.testing.expectEqual(records.Status.malformed, report.status);
    try std.testing.expectEqual(@as(u64, 0), report.consumed);
}

test "bounded callchain preserves user state and still requires trailing weight" {
    var raw: [256]u8 = undefined;
    var w = W{ .b = &raw };
    sampleHead(&w, 0x1000);
    w.putU64(2);
    w.putU64(0x1000);
    w.putU64(0x2000);
    w.putU64(records.regs_abi_64);
    w.putU64(0x7000);
    w.putU64(0x1000);
    w.putU64(16);
    w.raw(&(@as([16]u8, @splat(7))));
    w.putU64(16);
    const missing = w.finish();
    var ring: [256]u8 = @splat(0);
    place(&ring, 0, missing);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [1]records.UserState = undefined;
    var stack: [16]u8 = undefined;
    var config = input(user_bits | records.Bits.callchain | records.Bits.weight, sp_ip, 16, &states, &stack);
    config.max_frames = 1;
    const rejected = go(&ring, 0, missing.len, config, &samples, &sides);
    try std.testing.expectEqual(records.Status.malformed, rejected.status);
    try std.testing.expectEqual(@as(u64, 0), rejected.consumed);
    try std.testing.expectEqual(@as(u32, 0), rejected.user_states);
    w.putU64(99);
    const complete = w.finish();
    place(&ring, 0, complete);
    const accepted = go(&ring, 0, complete.len, config, &samples, &sides);
    try expectOk(accepted);
    try std.testing.expectEqual(records.Callchain.truncated, samples[0].callchain);
    try std.testing.expectEqual(@as(u32, 1), samples[0].user_state);
    try std.testing.expectEqual(@as(u64, 99), samples[0].weight);
}
