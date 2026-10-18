//! Per-channel traffic from a receive-only monitor interface: radiotap
//! headers and the first bytes of each 802.11 frame. Pure: no I/O.
//!
//! What is kept per dwell (one stay on one channel): frame counts by type,
//! retries, frames with a bad FCS, an airtime estimate from length and rate,
//! signal, and how many distinct networks (BSSIDs) and stations
//! (transmitters) were seen. Addresses are hashed with a per-session random
//! key the moment they are read and only the hashes are kept, in memory, to
//! count distinct ones; SSIDs and frame bodies are never parsed.
const std = @import("std");

pub const Kind = enum { mgmt, ctrl, data, other };

pub const Frame = struct {
    /// 802.11 frame length on air, bytes (without radiotap, with FCS if present).
    len: u32,
    freq_mhz: ?u16 = null,
    signal_dbm: ?i8 = null,
    bad_fcs: bool = false,
    kind: Kind = .other,
    subtype: u4 = 0,
    retry: bool = false,
    /// Transmitter (addr2) and BSSID when the frame carries them.
    ta: ?[6]u8 = null,
    bssid: ?[6]u8 = null,
    /// From an uplink data frame, a probe or (re)association request: a station.
    from_station: bool = false,
    beacon: bool = false,
    /// Estimated time on air, microseconds (preamble + bits / rate).
    airtime_us: u32 = 0,
    /// The rate the estimate used was reported (false: assumed 24 Mbit/s OFDM).
    rate_known: bool = false,
};

/// Radiotap fields 0..27: alignment and size (radiotap.org/fields/defined).
const fields = [_][2]u8{
    .{ 8, 8 }, .{ 1, 1 }, .{ 1, 1 }, .{ 2, 4 }, .{ 1, 2 }, .{ 1, 1 }, .{ 1, 1 }, .{ 2, 2 }, // 0-7
    .{ 2, 2 }, .{ 2, 2 }, .{ 1, 1 }, .{ 1, 1 }, .{ 1, 1 }, .{ 1, 1 }, .{ 2, 2 }, .{ 2, 2 }, // 8-15
    .{ 1, 1 }, .{ 1, 1 }, .{ 4, 8 }, .{ 1, 3 }, .{ 4, 8 }, .{ 2, 12 }, .{ 8, 12 }, .{ 2, 12 }, // 16-23
    .{ 2, 12 }, .{ 2, 6 }, .{ 1, 1 }, .{ 2, 4 }, // 24-27
};

/// Parses one captured packet: radiotap header then the 802.11 frame.
/// `wire_len` is the packet's full length (the capture may be truncated).
pub fn parse(bytes: []const u8, wire_len: usize) ?Frame {
    if (bytes.len < 8 or bytes[0] != 0) return null;
    const rt_len = std.mem.readInt(u16, bytes[2..4], .little);
    if (rt_len < 8 or rt_len > bytes.len or rt_len > wire_len) return null;
    // Every presence word comes first (bit 31 chains); the first word's fields follow.
    var words: usize = 1;
    while (std.mem.readInt(u32, bytes[4 + 4 * (words - 1) ..][0..4], .little) & (1 << 31) != 0) {
        words += 1;
        if (8 + 4 * words > rt_len) return null;
    }
    const present = std.mem.readInt(u32, bytes[4..8], .little);
    var f = Frame{ .len = @intCast(wire_len - rt_len) };
    var at: usize = 4 + 4 * words;
    var flags: u8 = 0;
    var legacy_kbps: ?u32 = null;
    var rate_kbps: ?u32 = null;
    var preamble_us: u32 = 20;
    for (fields, 0..) |fa, bit| {
        if (present & (@as(u32, 1) << @intCast(bit)) == 0) continue;
        const al: usize = fa[0];
        at = (at + al - 1) / al * al;
        if (at + fa[1] > rt_len) return null;
        const d = bytes[at..][0..fa[1]];
        switch (bit) {
            1 => flags = d[0],
            2 => if (d[0] != 0) {
                legacy_kbps = @as(u32, d[0]) * 500;
            },
            3 => f.freq_mhz = std.mem.readInt(u16, d[0..2], .little),
            5 => f.signal_dbm = @bitCast(d[0]),
            19 => { // MCS: known, flags, index
                const bw40 = d[1] & 3 == 1;
                const sgi = d[1] & 4 != 0;
                const mcs = d[2];
                const ht = [8]u32{ 6500, 13000, 19500, 26000, 39000, 52000, 58500, 65000 };
                var r: u64 = ht[mcs % 8] * (@as(u64, mcs / 8) + 1);
                if (bw40) r = r * 27 / 13;
                if (sgi) r = r * 10 / 9;
                rate_kbps = @intCast(@min(r, std.math.maxInt(u32)));
                preamble_us = 36;
            },
            21 => { // VHT: known(2) flags(1) bandwidth(1) mcs_nss[4] ...
                const sgi = d[2] & 4 != 0;
                const bw: u64 = switch (d[3]) {
                    0 => 10,
                    1...3 => 21,
                    4...10 => 45,
                    else => 90,
                };
                const mcs = d[4] >> 4;
                const nss: u64 = @max(1, d[4] & 0xf);
                const vht = [10]u64{ 6500, 13000, 19500, 26000, 39000, 52000, 58500, 65000, 78000, 86700 };
                var r = vht[@min(mcs, 9)] * nss * bw / 10;
                if (sgi) r = r * 10 / 9;
                rate_kbps = @intCast(@min(r, std.math.maxInt(u32)));
                preamble_us = 40;
            },
            23 => { // HE: data1..data6
                const data3 = std.mem.readInt(u16, d[4..6], .little);
                const data5 = std.mem.readInt(u16, d[8..10], .little);
                const data6 = std.mem.readInt(u16, d[10..12], .little);
                const mcs = (data3 >> 8) & 0xf;
                const nss: u64 = @max(1, data6 & 0xf);
                const bw: u64 = switch (data5 & 0xf) {
                    1 => 20,
                    2 => 41,
                    3 => 82,
                    else => 10,
                };
                const gi: u64 = switch ((data5 >> 4) & 3) {
                    1 => 944,
                    2 => 889,
                    else => 1000,
                };
                const he = [12]u64{ 8600, 17200, 25800, 34400, 51600, 68800, 77400, 86000, 103200, 114700, 129000, 143400 };
                const r = he[@min(mcs, 11)] * nss * bw / 10 * gi / 1000;
                rate_kbps = @intCast(@min(r, std.math.maxInt(u32)));
                preamble_us = 48;
            },
            else => {},
        }
        at += fa[1];
    }
    f.bad_fcs = flags & 0x40 != 0;
    if (rate_kbps == null) if (legacy_kbps) |l| {
        rate_kbps = l;
        // DSSS/CCK rates carry a long (192 us) or short (96 us) preamble.
        if (l == 1000 or l == 2000 or l == 5500 or l == 11000) preamble_us = if (flags & 0x02 != 0) 96 else 192;
    };
    f.rate_known = rate_kbps != null;
    const kbps = rate_kbps orelse 24000;
    f.airtime_us = preamble_us + @as(u32, @intCast(@min(@as(u64, f.len) * 8000 / @max(kbps, 1), 100_000)));

    // 802.11 header: frame control, duration, addr1, addr2, addr3.
    const h = bytes[rt_len..];
    if (h.len < 2) return f;
    const fc0 = h[0];
    const fc1 = h[1];
    f.kind = switch ((fc0 >> 2) & 3) {
        0 => .mgmt,
        1 => .ctrl,
        2 => .data,
        else => .other,
    };
    f.subtype = @intCast(fc0 >> 4);
    // Retry is meaningless on ACK/CTS; count it on data and management frames.
    f.retry = fc1 & 0x08 != 0 and (f.kind == .data or f.kind == .mgmt);
    // Garbage headers (bad FCS) must not count as networks or stations.
    if (f.bad_fcs) return f;
    const to_ds = fc1 & 1 != 0;
    const from_ds = fc1 & 2 != 0;
    const a1: ?[6]u8 = if (h.len >= 10) h[4..10].* else null;
    const a2: ?[6]u8 = if (h.len >= 16) h[10..16].* else null;
    const a3: ?[6]u8 = if (h.len >= 22) h[16..22].* else null;
    switch (f.kind) {
        .mgmt => {
            f.ta = a2;
            f.bssid = a3;
            f.beacon = f.subtype == 8 or f.subtype == 5;
            // Probe, association and reassociation requests come from stations.
            f.from_station = f.subtype == 4 or f.subtype == 0 or f.subtype == 2;
            if (!f.beacon and !f.from_station) f.bssid = null;
        },
        .data => {
            f.ta = a2;
            f.bssid = if (!to_ds and !from_ds) a3 else if (to_ds and !from_ds) a1 else if (!to_ds and from_ds) a2 else null;
            f.from_station = to_ds and !from_ds;
        },
        // RTS, PS-Poll, BlockAck(Req) carry a transmitter; ACK and CTS do not.
        .ctrl => f.ta = if (f.subtype == 11 or f.subtype == 10 or f.subtype == 8 or f.subtype == 9) a2 else null,
        .other => {},
    }
    return f;
}

/// Hashes an address with the session key; the address itself is not kept.
pub fn hashAddress(key: *const [16]u8, mac: [6]u8) u32 {
    const h = std.hash.SipHash64(2, 4).toInt(&mac, key);
    return @truncate(h | 1); // 0 is never a hash
}

pub const max_nets = 32;
pub const max_stas = 64;

/// One stay on one channel.
pub const Dwell = struct {
    channel: u8 = 0,
    from_ns: u64 = 0,
    to_ns: u64 = 0,
    frames: u32 = 0,
    data: u32 = 0,
    mgmt: u32 = 0,
    ctrl: u32 = 0,
    beacons: u32 = 0,
    /// Retries among data and management frames, and how many those were.
    retries: u32 = 0,
    retry_eligible: u32 = 0,
    bad_fcs: u32 = 0,
    airtime_us: u64 = 0,
    rate_known: u32 = 0,
    signal_sum: i32 = 0,
    signal_n: u32 = 0,
    /// Hashes of distinct BSSIDs and station transmitters (session key; counts only).
    nets: [max_nets]u32 = @splat(0),
    n_nets: u8 = 0,
    stas: [max_stas]u32 = @splat(0),
    n_stas: u8 = 0,
    /// More distinct addresses than the sets hold.
    more: bool = false,

    pub fn add(self: *Dwell, f: *const Frame, key: *const [16]u8) void {
        self.frames += 1;
        switch (f.kind) {
            .data => self.data += 1,
            .mgmt => self.mgmt += 1,
            .ctrl => self.ctrl += 1,
            .other => {},
        }
        self.beacons += @intFromBool(f.beacon);
        if (f.kind == .data or f.kind == .mgmt) {
            self.retry_eligible += 1;
            self.retries += @intFromBool(f.retry);
        }
        self.bad_fcs += @intFromBool(f.bad_fcs);
        self.airtime_us += f.airtime_us;
        self.rate_known += @intFromBool(f.rate_known);
        if (f.signal_dbm) |s| {
            self.signal_sum += s;
            self.signal_n += 1;
        }
        if (f.bssid) |b| if (!isGroup(b)) {
            self.more = insert(&self.nets, &self.n_nets, hashAddress(key, b)) or self.more;
        };
        if (f.from_station) if (f.ta) |t| if (!isGroup(t)) {
            self.more = insert(&self.stas, &self.n_stas, hashAddress(key, t)) or self.more;
        };
    }
    pub fn seconds(self: *const Dwell) f32 {
        return @as(f32, @floatFromInt(self.to_ns -| self.from_ns)) / 1e9;
    }
};

fn isGroup(mac: [6]u8) bool {
    return mac[0] & 1 != 0;
}
/// Adds `h` to a small set; returns true when the set is full and `h` is new.
fn insert(set: []u32, n: *u8, h: u32) bool {
    for (set[0..n.*]) |x| if (x == h) return false;
    if (n.* >= set.len) return true;
    set[n.*] = h;
    n.* += 1;
    return false;
}

/// Distinct hashes across several dwells' sets (counts only).
pub fn distinct(a: std.mem.Allocator, sets: []const []const u32) !u32 {
    var all: std.ArrayList(u32) = .empty;
    defer all.deinit(a);
    for (sets) |s| try all.appendSlice(a, s);
    std.mem.sortUnstable(u32, all.items, {}, std.sort.asc(u32));
    var n: u32 = 0;
    for (all.items, 0..) |x, i| n += @intFromBool(i == 0 or x != all.items[i - 1]);
    return n;
}

// --- Synthetic frames (tests and the demo) ----------------------------------------

pub const Synth = struct {
    kind: Kind = .data,
    subtype: u4 = 0,
    to_ds: bool = true,
    from_ds: bool = false,
    retry: bool = false,
    bad_fcs: bool = false,
    freq_mhz: u16 = 2437,
    rate_500k: u8 = 48, // 24 Mbit/s
    signal: i8 = -60,
    a1: [6]u8 = .{ 0x02, 0, 0, 0, 0, 1 },
    a2: [6]u8 = .{ 0x02, 0, 0, 0, 0, 2 },
    a3: [6]u8 = .{ 0x02, 0, 0, 0, 0, 3 },
    body: u16 = 200,

    /// Radiotap (flags, rate, channel, signal) + a 24-byte 802.11 header; returns
    /// the captured bytes (the body is not written) and the wire length.
    pub fn encode(self: Synth, out: *[64]u8) struct { bytes: []const u8, wire: usize } {
        @memset(out, 0);
        out[0] = 0;
        std.mem.writeInt(u16, out[2..4], 16, .little);
        std.mem.writeInt(u32, out[4..8], (1 << 1) | (1 << 2) | (1 << 3) | (1 << 5), .little);
        out[8] = if (self.bad_fcs) 0x40 | 0x10 else 0x10;
        out[9] = self.rate_500k;
        std.mem.writeInt(u16, out[10..12], self.freq_mhz, .little);
        std.mem.writeInt(u16, out[12..14], 0x00c0, .little);
        out[14] = @bitCast(self.signal);
        const h = out[16..];
        const t: u8 = switch (self.kind) {
            .mgmt => 0,
            .ctrl => 1,
            .data => 2,
            .other => 3,
        };
        h[0] = (t << 2) | (@as(u8, self.subtype) << 4);
        h[1] = @as(u8, @intFromBool(self.to_ds)) | (@as(u8, @intFromBool(self.from_ds)) << 1) | (@as(u8, @intFromBool(self.retry)) << 3);
        @memcpy(h[4..10], &self.a1);
        @memcpy(h[10..16], &self.a2);
        @memcpy(h[16..22], &self.a3);
        return .{ .bytes = out[0 .. 16 + 24], .wire = 16 + 24 + @as(usize, self.body) + 4 };
    }
};

test "radiotap + 802.11 header: rate, channel, signal, retry, BSSID and station" {
    var b: [64]u8 = undefined;
    const e = (Synth{ .retry = true, .freq_mhz = 2462, .signal = -71, .body = 1476 }).encode(&b);
    const f = parse(e.bytes, e.wire).?;
    try std.testing.expectEqual(@as(?u16, 2462), f.freq_mhz);
    try std.testing.expectEqual(@as(?i8, -71), f.signal_dbm);
    try std.testing.expectEqual(Kind.data, f.kind);
    try std.testing.expect(f.retry and f.from_station and f.rate_known and !f.bad_fcs);
    try std.testing.expectEqual(@as(u32, 1504), f.len);
    // 20 us preamble + 1504 bytes at 24 Mbit/s.
    try std.testing.expectEqual(@as(u32, 20 + 1504 * 8 / 24), f.airtime_us);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0, 0, 0, 0, 1 }, &f.bssid.?); // to-DS: addr1
    const beacon = parse((Synth{ .kind = .mgmt, .subtype = 8, .to_ds = false, .rate_500k = 2 }).encode(&b).bytes, 300).?;
    try std.testing.expect(beacon.beacon and !beacon.from_station);
    try std.testing.expect(beacon.airtime_us > 192); // DSSS long preamble at 1 Mbit/s
    const ack = parse((Synth{ .kind = .ctrl, .subtype = 13, .to_ds = false, .retry = true }).encode(&b).bytes, 16 + 14).?;
    try std.testing.expect(ack.ta == null and !ack.retry);
    const bad = parse((Synth{ .bad_fcs = true }).encode(&b).bytes, 200).?;
    try std.testing.expect(bad.bad_fcs and bad.ta == null and bad.bssid == null);
}

test "radiotap with chained presence words, MCS and HE fields" {
    // present word 0: TSFT, flags, channel, signal, MCS, ext; word 1: anything.
    var b: [64]u8 = @splat(0);
    std.mem.writeInt(u32, b[4..8], (1 << 0) | (1 << 1) | (1 << 3) | (1 << 5) | (1 << 19) | (1 << 31), .little);
    std.mem.writeInt(u32, b[8..12], 0x20, .little);
    // fields start at 12 -> TSFT aligned to 16
    b[24] = 0; // flags
    std.mem.writeInt(u16, b[26..28], 2412, .little); // channel (aligned 2)
    b[30] = @bitCast(@as(i8, -55)); // signal
    b[31] = 0x07; // MCS known
    b[32] = 0x01; // 40 MHz
    b[33] = 7; // MCS 7
    std.mem.writeInt(u16, b[2..4], 34, .little);
    const f = parse(b[0..40], 34 + 1000).?;
    try std.testing.expectEqual(@as(?u16, 2412), f.freq_mhz);
    try std.testing.expectEqual(@as(?i8, -55), f.signal_dbm);
    try std.testing.expect(f.rate_known);
    try std.testing.expectEqual(@as(u32, 36 + 1000 * 8000 / 135000), f.airtime_us);
    // HE: MCS 11, 2 streams, 80 MHz.
    var he: [64]u8 = @splat(0);
    std.mem.writeInt(u32, he[4..8], 1 << 23, .little);
    std.mem.writeInt(u16, he[8 + 4 ..][0..2], 11 << 8, .little);
    std.mem.writeInt(u16, he[8 + 8 ..][0..2], 2, .little);
    std.mem.writeInt(u16, he[8 + 10 ..][0..2], 2, .little);
    std.mem.writeInt(u16, he[2..4], 20, .little);
    const g = parse(he[0..24], 20 + 2000).?;
    try std.testing.expect(g.rate_known and g.airtime_us < 100);
}

test "dwell counts distinct networks and stations by keyed hash only" {
    const key: [16]u8 = @splat(7);
    var d = Dwell{ .channel = 6 };
    var b: [64]u8 = undefined;
    for (0..10) |i| {
        var s = Synth{ .retry = i % 5 == 0 };
        s.a2[5] = @intCast(10 + i % 3); // three stations
        s.a1[5] = @intCast(1 + i % 2); // two BSSIDs
        const e = s.encode(&b);
        d.add(&parse(e.bytes, e.wire).?, &key);
    }
    const e = (Synth{ .bad_fcs = true }).encode(&b);
    d.add(&parse(e.bytes, e.wire).?, &key);
    try std.testing.expectEqual(@as(u32, 11), d.frames);
    try std.testing.expectEqual(@as(u32, 2), d.retries);
    try std.testing.expectEqual(@as(u32, 1), d.bad_fcs);
    try std.testing.expectEqual(@as(u8, 2), d.n_nets);
    try std.testing.expectEqual(@as(u8, 3), d.n_stas);
    // No address bytes are kept anywhere in the dwell.
    const raw = std.mem.asBytes(&d);
    try std.testing.expect(std.mem.indexOf(u8, raw, &[_]u8{ 0x02, 0, 0, 0, 0, 12 }) == null);
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 3), try distinct(a, &.{ d.stas[0..d.n_stas], d.stas[0..1] }));
}

test "hostile packets never crash the parser" {
    var prng = std.Random.DefaultPrng.init(0x8852be);
    const r = prng.random();
    var buf: [128]u8 = undefined;
    for (0..20000) |_| {
        r.bytes(&buf);
        if (r.boolean()) buf[0] = 0;
        if (r.boolean()) std.mem.writeInt(u16, buf[2..4], r.uintAtMost(u16, 64), .little);
        const n = r.uintAtMost(usize, buf.len);
        _ = parse(buf[0..n], n + r.uintAtMost(usize, 3000));
    }
}

test "structured hostile radiotap: chained presence words, every field, every cut" {
    var prng = std.Random.DefaultPrng.init(0x271);
    const r = prng.random();
    var buf: [256]u8 = undefined;
    for (0..20000) |_| {
        r.bytes(&buf);
        buf[0] = 0;
        // 1-8 presence words, the chain bit set on all but (usually) the last.
        const words = 1 + r.uintLessThan(usize, 8);
        for (0..words) |w| {
            var p = r.int(u32) | if (r.boolean()) @as(u32, 0x0fff_ffff) else 0;
            if (w + 1 < words or r.uintLessThan(u8, 8) == 0) p |= 1 << 31 else p &= ~(@as(u32, 1) << 31);
            std.mem.writeInt(u32, buf[4 + 4 * w ..][0..4], p, .little);
        }
        // Header length: plausible, at the words' end, or absurd.
        const rt: u16 = switch (r.uintLessThan(u8, 4)) {
            0 => @intCast(4 + 4 * words),
            1 => r.uintAtMost(u16, buf.len),
            2 => 0xffff,
            else => r.int(u16),
        };
        std.mem.writeInt(u16, buf[2..4], rt, .little);
        const n = r.uintAtMost(usize, buf.len);
        for ([_]usize{ n, n + 1, n + r.uintAtMost(usize, 70000), 0xffff_ffff }) |wire| {
            if (parse(buf[0..n], wire)) |f| {
                try std.testing.expect(f.airtime_us <= 100_000 + 192);
                if (f.freq_mhz) |_| {}
            }
        }
    }
}
