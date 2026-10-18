//! Extra detector scenes and a streamed parser fuzz (R2 acceptance review):
//! other periodic and continuous 2.4 GHz sources must not read as an oven.
const std = @import("std");
const verbose = false;
const ath9k = @import("ath9k.zig");
const detect = @import("detect.zig");
const Sample = ath9k.Sample;

const Emit = struct { fc: f32, sigma: f32, dbm: f32 };

fn addShape(mw: *[ath9k.bins]f64, freq: u16, e: Emit) void {
    var shape: [ath9k.bins]f64 = undefined;
    var total: f64 = 0;
    const s0 = Sample{ .tsf_us = 0, .freq_mhz = freq, .rssi = 0, .noise = 0, .power = undefined };
    for (&shape, 0..) |*w, i| {
        const d = (s0.binMhz(i) - e.fc) / e.sigma;
        w.* = @exp(-0.5 * d * d);
        total += w.*;
    }
    if (total < 1e-9) return;
    const p = std.math.pow(f64, 10, e.dbm / 10);
    for (mw, shape) |*m, w| m.* += p * w / total;
}

/// Generates `seconds` of samples at ~rate; `scene(t_us, r, out)` returns emitters at t.
fn gen(a: std.mem.Allocator, seconds: f32, rate: f32, seed: u64, comptime scene: fn (f32, std.Random, *std.ArrayList(Emit)) void) ![]Sample {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var out: std.ArrayList(Sample) = .empty;
    errdefer out.deinit(a);
    var em: std.ArrayList(Emit) = .empty;
    defer em.deinit(a);
    try em.ensureTotalCapacity(a, 8);
    const n: usize = @intFromFloat(seconds * rate);
    const dt: f32 = 1e6 / rate;
    const noise: i8 = -95;
    const noise_mw = std.math.pow(f64, 10, @as(f64, @floatFromInt(noise)) / 10) / ath9k.bins;
    var t: f32 = 1000;
    for (0..n) |_| {
        t += dt * (0.9 + 0.2 * r.float(f32));
        var mw: [ath9k.bins]f64 = undefined;
        for (&mw) |*w| w.* = noise_mw * (0.7 + 0.6 * r.float(f64));
        em.clearRetainingCapacity();
        scene(t, r, &em);
        for (em.items) |e| addShape(&mw, 2457, e);
        var rec: [3 + ath9k.ht20_len]u8 = undefined;
        ath9k.encode(&rec, @intFromFloat(t), 2457, noise, &mw);
        var one: [1]Sample = undefined;
        var got: usize = 0;
        var counts = ath9k.Counts{};
        _ = ath9k.parse(&rec, 0, &one, &got, &counts);
        try out.append(a, one[0]);
    }
    return out.toOwnedSlice(a);
}

fn verdictOf(comptime name: []const u8, seconds: f32, comptime scene: fn (f32, std.Random, *std.ArrayList(Emit)) void) !detect.Verdict {
    const a = std.testing.allocator;
    const s = try gen(a, seconds, 6000, 3, scene);
    defer a.free(s);
    const v = try detect.analyse(a, s, .{});
    var b: [400]u8 = undefined;
    if (verbose) std.debug.print(" {s}: kind={s} conf={d:.2} r60={d:.2} r50={d:.2} r60x2={d:.2} r50x2={d:.2} duty={?d:.2} active={d:.2} width={d:.1} hop={d:.1}\n   words: {s}\n", .{ name, @tagName(v.kind), v.confidence, v.r60, v.r50, v.r60x2, v.r50x2, v.duty, v.active, v.width_mhz, v.hop_mhz, v.words(&b) });
    return v;
}

fn mw50(t: f32, _: std.Random, e: *std.ArrayList(Emit)) void {
    const p: f32 = 1e6 / 50.0;
    const ph = @mod(t, p) / p;
    if (ph < 0.48) e.appendAssumeCapacity(.{ .fc = 2450 + 14 * ph / 0.48, .sigma = 1.5, .dbm = -50 });
}
fn twoInPhase(t: f32, _: std.Random, e: *std.ArrayList(Emit)) void {
    const p: f32 = 1e6 / 60.0;
    const ph = @mod(t, p) / p;
    if (ph < 0.48) {
        e.appendAssumeCapacity(.{ .fc = 2450 + 14 * ph / 0.48, .sigma = 1.5, .dbm = -48 });
        e.appendAssumeCapacity(.{ .fc = 2460 - 8 * ph / 0.48, .sigma = 1.5, .dbm = -55 });
    }
}
fn twoOpposite(t: f32, _: std.Random, e: *std.ArrayList(Emit)) void {
    // Split-phase supply: one oven on each half cycle -> energy nearly all the time.
    const p: f32 = 1e6 / 60.0;
    const ph = @mod(t, p) / p;
    if (ph < 0.48) e.appendAssumeCapacity(.{ .fc = 2450 + 14 * ph / 0.48, .sigma = 1.5, .dbm = -48 });
    if (ph >= 0.5 and ph < 0.98) e.appendAssumeCapacity(.{ .fc = 2452 + 10 * (ph - 0.5) / 0.48, .sigma = 1.5, .dbm = -52 });
}
fn videoSender(_: f32, r: std.Random, e: *std.ArrayList(Emit)) void {
    // Analog FM video sender: continuous, ~15 MHz wide.
    e.appendAssumeCapacity(.{ .fc = 2458 + r.float(f32), .sigma = 4, .dbm = -60 });
}
fn cwCarrier(_: f32, _: std.Random, e: *std.ArrayList(Emit)) void {
    // Analog baby monitor: a steady narrow carrier.
    e.appendAssumeCapacity(.{ .fc = 2455, .sigma = 0.3, .dbm = -62 });
}
fn tdd100(t: f32, r: std.Random, e: *std.ArrayList(Emit)) void {
    // Digital baby monitor / cordless: a 2.5 ms burst every 10 ms (100 Hz frames).
    _ = r;
    if (@mod(t, 10_000) < 2500) e.appendAssumeCapacity(.{ .fc = 2456, .sigma = 1.0, .dbm = -58 });
}
fn tdd120(t: f32, r: std.Random, e: *std.ArrayList(Emit)) void {
    _ = r;
    if (@mod(t, 1e6 / 120.0) < 4000) e.appendAssumeCapacity(.{ .fc = 2456, .sigma = 3.0, .dbm = -58 });
}
fn btHeadset(t: f32, r: std.Random, e: *std.ArrayList(Emit)) void {
    // eSCO-like: a pair of 625 us slots every 3.75 ms, a new hop each time; 20 of 79 MHz visible.
    _ = r;
    const k: u32 = @intFromFloat(t / 3750);
    if (@mod(t, 3750) < 1250) {
        var h = std.hash.Wyhash.init(k);
        h.update("bt");
        const f: f32 = 2402 + @as(f32, @floatFromInt(h.final() % 79));
        if (@abs(f - 2457) < 10) e.appendAssumeCapacity(.{ .fc = f, .sigma = 0.4, .dbm = -55 });
    }
}

test "50 Hz oven is reported as 50 Hz (any country)" {
    const v = try verdictOf("mw50", 4, mw50);
    try std.testing.expectEqual(detect.Kind.microwave_pulsed, v.kind);
    try std.testing.expectEqual(@as(?u8, 50), v.mains_hz);
}
test "two ovens" {
    const a = try verdictOf("two-in-phase", 4, twoInPhase);
    try std.testing.expectEqual(detect.Kind.microwave_pulsed, a.kind);
    const b = try verdictOf("two-opposite", 4, twoOpposite);
    try std.testing.expect(b.kind != .quiet);
}
test "continuous carriers are never mains-pulsed" {
    const a = try verdictOf("video-sender", 4, videoSender);
    try std.testing.expect(a.kind != .microwave_pulsed);
    const b = try verdictOf("cw-carrier", 4, cwCarrier);
    try std.testing.expect(b.kind != .microwave_pulsed);
}
test "100/120 Hz frame sources are not mains-pulsed ovens" {
    const a = try verdictOf("tdd100", 4, tdd100);
    const b = try verdictOf("tdd120", 4, tdd120);
    try std.testing.expect(a.kind != .microwave_pulsed);
    try std.testing.expect(b.kind != .microwave_pulsed);
}
test "Bluetooth headset bursts" {
    const v = try verdictOf("bt-headset", 4, btHeadset);
    try std.testing.expect(v.kind != .microwave_pulsed);
}

test "detector survives hostile TSF values" {
    const a = std.testing.allocator;
    const s = try gen(a, 2, 4000, 5, mw50);
    defer a.free(s);
    // One garbage record with a TSF near the top, one far forward, one zero.
    s[100].tsf_us = std.math.maxInt(u64) - 5;
    s[200].tsf_us = s[199].tsf_us + 86_400_000_000; // a day ahead
    s[300].tsf_us = 0;
    _ = try detect.analyse(a, s, .{});
    s[s.len - 1].tsf_us = std.math.maxInt(u64);
    _ = try detect.analyse(a, s, .{});
}

test "parser fuzz, structured and streamed" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    var buf: [65536]u8 = undefined;
    var out: [1024]Sample = undefined;
    var total: u64 = 0;
    for (0..3000) |_| {
        // Build a stream of mixed records: valid HT20, wrong types, wrong lengths, huge lengths, zeros.
        var at: usize = 0;
        while (at + 1100 < buf.len and r.uintLessThan(u32, 200) != 0) {
            switch (r.uintLessThan(u8, 6)) {
                0, 1 => {
                    var mw: [ath9k.bins]f64 = undefined;
                    for (&mw) |*w| w.* = r.float(f64) * 1e-6;
                    var rec: [3 + ath9k.ht20_len]u8 = undefined;
                    ath9k.encode(&rec, r.int(u64), r.int(u16), r.int(i8), &mw);
                    rec[3] = r.int(u8); // max_exp anything
                    @memcpy(buf[at..][0..rec.len], &rec);
                    at += rec.len;
                },
                2 => { // other type, valid length
                    const len = r.uintAtMost(u16, 1024);
                    buf[at] = r.intRangeAtMost(u8, 2, 255);
                    std.mem.writeInt(u16, buf[at + 1 ..][0..2], len, .big);
                    r.bytes(buf[at + 3 ..][0..len]);
                    at += 3 + len;
                },
                3 => { // type 1 with the wrong length
                    const len = r.uintAtMost(u16, 1024);
                    buf[at] = 1;
                    std.mem.writeInt(u16, buf[at + 1 ..][0..2], len, .big);
                    r.bytes(buf[at + 3 ..][0..len]);
                    at += 3 + len;
                },
                4 => { // huge length
                    buf[at] = r.int(u8);
                    std.mem.writeInt(u16, buf[at + 1 ..][0..2], r.intRangeAtMost(u16, 1025, 65535), .big);
                    at += 3;
                },
                else => { // raw garbage
                    const len = r.uintAtMost(usize, 300);
                    r.bytes(buf[at..][0..len]);
                    at += len;
                },
            }
        }
        // Stream it in random cuts with the monitor's carry rule (tail <= 128 kept).
        var carry: [128]u8 = undefined;
        var carried: usize = 0;
        var pos: usize = 0;
        var work: [65536 + 128]u8 = undefined;
        while (pos < at) {
            const cut = @min(at - pos, r.uintAtMost(usize, 4096) + 1);
            @memcpy(work[0..carried], carry[0..carried]);
            @memcpy(work[carried..][0..cut], buf[pos..][0..cut]);
            pos += cut;
            const have = carried + cut;
            var used: usize = 0;
            var counts = ath9k.Counts{};
            while (used < have) {
                var n: usize = 0;
                const got = ath9k.parse(work[used..have], 0, out[0..r.uintAtMost(usize, out.len)], &n, &counts);
                total += n;
                for (out[0..n]) |s| for (s.power) |p| std.debug.assert(p >= -128);
                if (got == 0) break;
                try std.testing.expect(got <= have - used);
                used += got;
            }
            const tail = have - used;
            carried = if (tail <= carry.len) tail else 0;
            @memcpy(carry[0..carried], work[used..][0..carried]);
        }
    }
    try std.testing.expect(total > 0);
}
