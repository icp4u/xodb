const std = @import("std");
const records = @import("records");

const tid_time = records.Bits.tid | records.Bits.time;
const tid_time_id_cpu = tid_time | records.Bits.id | records.Bits.cpu;
const with_ident = tid_time | records.Bits.cpu | records.Bits.identifier;

fn input(bits: u64, all: bool) records.DecodeInput {
    return .{ .sample_type = bits, .sample_id_all = all, .stack_cap = 8, .max_frames = 8 };
}

const W = struct {
    b: [512]u8 = undefined,
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
    fn cstr(self: *W, text: []const u8) void {
        self.raw(text);
        self.raw(&.{0});
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

fn idTail(w: *W, pid: u32, tid: u32, time_ns: u64) void {
    w.putU32(pid);
    w.putU32(tid);
    w.putU64(time_ns);
}

fn switchRec(misc: u16, pid: u32, tid: u32, time_ns: u64) W {
    var w = W{};
    w.begin(records.Type.context_switch, misc);
    idTail(&w, pid, tid, time_ns);
    _ = w.finish();
    return w;
}

fn switchWide(misc: u16, other_pid: u32, other_tid: u32, pid: u32, tid: u32, time_ns: u64) W {
    var w = W{};
    w.begin(records.Type.context_switch_cpu_wide, misc);
    w.putU32(other_pid);
    w.putU32(other_tid);
    idTail(&w, pid, tid, time_ns);
    _ = w.finish();
    return w;
}

fn expectOk(report: records.Report) !void {
    try std.testing.expectEqual(records.Status.ok, report.status);
}

test "per-task switch direction, preemption, and absent other task" {
    const out_misc: u16 = records.Misc.switch_out | records.Misc.switch_out_preempt | records.Misc.user;
    const leaving = switchRec(out_misc, 20, 21, 1000);
    const entering = switchRec(records.Misc.switch_out_preempt | records.Misc.user, 20, 21, 2000);
    var ring: [128]u8 = [_]u8{0} ** 128;
    place(&ring, 0, leaving.b[0..leaving.n]);
    place(&ring, leaving.n, entering.b[0..entering.n]);
    var samples: [2]records.Sample = undefined;
    var sides: [4]records.Side = undefined;
    const report = go(&ring, 0, leaving.n + entering.n, input(tid_time, true), &samples, &sides);
    try expectOk(report);
    try std.testing.expectEqual(@as(usize, 2), report.sides);
    try std.testing.expect(sides[0].switch_out and sides[0].preempt_present and sides[0].preempted);
    try std.testing.expect(sides[0].task_present and sides[0].time_present);
    try std.testing.expectEqual(@as(u32, 20), sides[0].pid);
    try std.testing.expectEqual(@as(u32, 21), sides[0].tid);
    try std.testing.expectEqual(@as(u64, 1000), sides[0].time_ns);
    try std.testing.expect(!sides[0].other_task_present);
    try std.testing.expectEqual(@as(u32, 0), sides[0].other_pid);
    try std.testing.expect(!sides[0].cpu_present);
    // The preempt bit on a switch-in is not a preemption of the incoming task.
    try std.testing.expect(!sides[1].switch_out);
    try std.testing.expect(!sides[1].preempt_present);
    try std.testing.expect(!sides[1].preempted);
    try std.testing.expectEqual(@as(u64, 2000), sides[1].time_ns);
}

test "switch without sample id keeps identity and time absent" {
    var w = W{};
    w.begin(records.Type.context_switch, records.Misc.switch_out);
    const rec = w.finish();
    var ring: [32]u8 = [_]u8{0} ** 32;
    place(&ring, 0, rec);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    const report = go(&ring, 0, rec.len, input(tid_time, false), &samples, &sides);
    try expectOk(report);
    try std.testing.expect(sides[0].switch_out and sides[0].preempt_present and !sides[0].preempted);
    try std.testing.expect(!sides[0].task_present and !sides[0].time_present);
    try std.testing.expectEqual(@as(u32, 0), sides[0].pid);
    try std.testing.expectEqual(@as(u32, 0), sides[0].tid);
}

test "time-only sample id does not invent a task" {
    var w = W{};
    w.begin(records.Type.context_switch, records.Misc.user);
    w.putU64(77);
    const rec = w.finish();
    var ring: [32]u8 = [_]u8{0} ** 32;
    place(&ring, 0, rec);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    const report = go(&ring, 0, rec.len, input(records.Bits.time, true), &samples, &sides);
    try expectOk(report);
    try std.testing.expect(!sides[0].task_present and sides[0].time_present);
    try std.testing.expectEqual(@as(u64, 77), sides[0].time_ns);
    try std.testing.expectEqual(@as(u32, 0), sides[0].tid);
}

test "cpu-wide switch keeps the other task distinct, including idle zero" {
    const rec = switchWide(records.Misc.switch_out, 0, 0, 9, 9, 50);
    var ring: [64]u8 = [_]u8{0} ** 64;
    place(&ring, 0, rec.b[0..rec.n]);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    const report = go(&ring, 0, rec.n, input(tid_time, true), &samples, &sides);
    try expectOk(report);
    try std.testing.expect(sides[0].other_task_present and sides[0].task_present);
    try std.testing.expectEqual(@as(u32, 0), sides[0].other_pid);
    try std.testing.expectEqual(@as(u32, 0), sides[0].other_tid);
    try std.testing.expectEqual(@as(u32, 9), sides[0].pid);
    try std.testing.expectEqual(@as(u32, 9), sides[0].tid);
    try std.testing.expect(sides[0].switch_out and !sides[0].preempted);
}

test "sample id cpu and id stay aligned" {
    var w = W{};
    w.begin(records.Type.context_switch, records.Misc.user);
    w.putU32(3);
    w.putU32(4);
    w.putU64(80);
    w.putU64(0x1111);
    w.putU32(7);
    w.putU32(0);
    const rec = w.finish();
    var ring: [64]u8 = [_]u8{0} ** 64;
    place(&ring, 0, rec);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    const report = go(&ring, 0, rec.len, input(tid_time_id_cpu, true), &samples, &sides);
    try expectOk(report);
    try std.testing.expectEqual(@as(u32, 4), sides[0].tid);
    try std.testing.expectEqual(@as(u64, 80), sides[0].time_ns);
    try std.testing.expect(sides[0].cpu_present);
    try std.testing.expectEqual(@as(u32, 7), sides[0].cpu);
}

test "identifier after cpu does not shift the cpu field" {
    var w = W{};
    w.begin(records.Type.context_switch, records.Misc.user);
    w.putU32(1);
    w.putU32(2);
    w.putU64(9);
    w.putU32(5);
    w.putU32(0);
    w.putU64(0xabcdef);
    const rec = w.finish();
    var ring: [64]u8 = [_]u8{0} ** 64;
    place(&ring, 0, rec);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    const report = go(&ring, 0, rec.len, input(with_ident, true), &samples, &sides);
    try expectOk(report);
    try std.testing.expectEqual(@as(u32, 5), sides[0].cpu);
    try std.testing.expectEqual(@as(u32, 2), sides[0].tid);
}

test "short and padded switch bodies are rejected and not consumed" {
    var short = W{};
    short.begin(records.Type.context_switch, 0);
    short.putU64(1);
    const short_rec = short.finish();
    var ring: [64]u8 = [_]u8{0} ** 64;
    place(&ring, 0, short_rec);
    var samples: [1]records.Sample = undefined;
    var sides: [2]records.Side = undefined;
    const bad = go(&ring, 0, short_rec.len, input(tid_time, true), &samples, &sides);
    try std.testing.expectEqual(records.Status.malformed, bad.status);
    try std.testing.expectEqual(@as(u64, 0), bad.consumed);

    var padded = W{};
    padded.begin(records.Type.context_switch_cpu_wide, 0);
    padded.putU32(1);
    padded.putU32(2);
    idTail(&padded, 3, 4, 5);
    padded.putU64(9);
    const padded_rec = padded.finish();
    var ring2: [64]u8 = [_]u8{0} ** 64;
    place(&ring2, 0, padded_rec);
    const bad2 = go(&ring2, 0, padded_rec.len, input(tid_time, true), &samples, &sides);
    try std.testing.expectEqual(records.Status.malformed, bad2.status);
    try std.testing.expectEqual(@as(u64, 0), bad2.consumed);
}

test "wrapped switch matches a linear switch" {
    const rec = switchRec(records.Misc.switch_out, 8, 8, 42);
    var ring: [32]u8 = [_]u8{0} ** 32;
    const at: u64 = 28;
    place(&ring, at, rec.b[0..rec.n]);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    const report = go(&ring, at, at + rec.n, input(tid_time, true), &samples, &sides);
    try expectOk(report);
    try std.testing.expect(sides[0].switch_out and sides[0].task_present);
    try std.testing.expectEqual(@as(u64, 42), sides[0].time_ns);
    try std.testing.expectEqual(@as(u32, 8), sides[0].tid);
}

test "mixed sample, mmap2, loss, and switch stream keeps order" {
    var sample = W{};
    sample.begin(records.Type.sample, records.Misc.user);
    sample.putU64(0x1000);
    sample.putU32(4);
    sample.putU32(5);
    sample.putU64(10);
    sample.putU64(1);
    const sample_rec = sample.finish();

    var map = W{};
    map.begin(records.Type.mmap2, records.Misc.user);
    map.putU32(4);
    map.putU32(5);
    map.putU64(0x400000);
    map.putU64(0x1000);
    map.putU64(0);
    map.putU32(8);
    map.putU32(1);
    map.putU64(99);
    map.putU64(1);
    map.putU32(5);
    map.putU32(2);
    map.cstr("a");
    idTail(&map, 4, 5, 11);
    const map_rec = map.finish();

    var lost = W{};
    lost.begin(records.Type.lost, 0);
    lost.putU64(7);
    lost.putU64(3);
    idTail(&lost, 4, 5, 12);
    const lost_rec = lost.finish();

    const sw = switchRec(records.Misc.user, 4, 5, 13);
    var unknown = W{};
    unknown.begin(99, 0);
    unknown.putU64(1);
    idTail(&unknown, 4, 5, 14);
    const unknown_rec = unknown.finish();
    const wide = switchWide(records.Misc.switch_out, 6, 6, 4, 5, 15);

    var built: [512]u8 = undefined;
    var n: usize = 0;
    const parts = [_][]const u8{ sample_rec, map_rec, lost_rec, sw.b[0..sw.n], unknown_rec, wide.b[0..wide.n] };
    for (parts) |part| {
        @memcpy(built[n..][0..part.len], part);
        n += part.len;
    }
    var ring: [512]u8 = [_]u8{0} ** 512;
    place(&ring, 0, built[0..n]);
    var samples: [2]records.Sample = undefined;
    var sides: [8]records.Side = undefined;
    const sample_bits = records.Bits.ip | records.Bits.tid | records.Bits.time | records.Bits.period;
    const report = go(&ring, 0, n, input(sample_bits, true), &samples, &sides);
    try expectOk(report);
    try std.testing.expectEqual(@as(usize, 1), report.samples);
    try std.testing.expectEqual(@as(u64, 0x1000), samples[0].ip);
    try std.testing.expectEqual(@as(usize, 4), report.sides);
    try std.testing.expectEqual(@as(u32, 1), report.skipped_unknown);
    try std.testing.expectEqual(records.SideKind.mmap, sides[0].kind);
    try std.testing.expectEqual(records.SideKind.lost, sides[1].kind);
    try std.testing.expectEqual(@as(u64, 3), sides[1].lost_count);
    try std.testing.expectEqual(records.SideKind.context_switch, sides[2].kind);
    try std.testing.expect(!sides[2].other_task_present);
    try std.testing.expectEqual(@as(u64, 13), sides[2].time_ns);
    try std.testing.expect(sides[3].other_task_present and sides[3].switch_out);
    try std.testing.expectEqual(@as(u32, 6), sides[3].other_tid);
    try std.testing.expectEqual(@as(u64, 15), sides[3].time_ns);
}

test "side capacity leaves the rest of the ring queued" {
    const first = switchRec(records.Misc.user, 1, 1, 1);
    const second = switchRec(records.Misc.switch_out, 1, 1, 2);
    var ring: [128]u8 = [_]u8{0} ** 128;
    place(&ring, 0, first.b[0..first.n]);
    place(&ring, first.n, second.b[0..second.n]);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    const held = go(&ring, 0, first.n + second.n, input(tid_time, true), &samples, &sides);
    try std.testing.expectEqual(records.Status.capacity, held.status);
    try std.testing.expectEqual(first.n, held.consumed);
    try std.testing.expectEqual(@as(usize, 1), held.sides);
    try std.testing.expectEqual(@as(u64, 1), sides[0].time_ns);
    var more: [1]records.Side = undefined;
    const rest = go(&ring, held.consumed, first.n + second.n, input(tid_time, true), &samples, &more);
    try expectOk(rest);
    try std.testing.expect(more[0].switch_out);
    try std.testing.expectEqual(@as(u64, 2), more[0].time_ns);
}
