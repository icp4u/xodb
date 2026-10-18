//! ath9k / ath9k_htc spectral scan samples (drivers/net/wireless/ath/
//! spectral_common.h). The relay files `spectral_scan<cpu>` under
//! debugfs ieee80211/phyN/ath9k[_htc]/ carry TLV records; type 1 is one
//! HT20 FFT: 56 bins over the 20 MHz channel, the bins' exponent, the
//! signal (`rssi`, dB above `noise`), the noise floor (dBm) and the
//! device's TSF (microseconds, the radio's own clock). Pure: no I/O.
const std = @import("std");

pub const bins = 56;
/// Bin spacing of an HT20 FFT, MHz.
pub const bin_mhz: f32 = 20.0 / @as(f32, bins);
pub const type_ht20 = 1;
/// The HT20 payload after the 3-byte TLV header.
pub const ht20_len = 1 + 2 + 1 + 1 + 2 + 1 + 1 + 8 + bins;

/// One FFT, as power per bin in dBm (rounded, clamped to i8).
pub const Sample = struct {
    /// Device clock (TSF), microseconds. Comparable only within one card.
    tsf_us: u64,
    /// CLOCK_MONOTONIC when the batch holding it was read (0 in tests).
    read_ns: u64 = 0,
    /// Channel centre, MHz.
    freq_mhz: u16,
    rssi: i8,
    noise: i8,
    power: [bins]i8,

    /// Centre of bin `i`, MHz.
    pub fn binMhz(self: *const Sample, i: usize) f32 {
        return @as(f32, @floatFromInt(self.freq_mhz)) - 10 + (@as(f32, @floatFromInt(i)) + 0.5) * bin_mhz;
    }
    /// Total power over the channel, dBm (noise + rssi, as the hardware reports).
    pub fn total(self: *const Sample) f32 {
        return @as(f32, @floatFromInt(self.noise)) + @as(f32, @floatFromInt(self.rssi));
    }
};

/// A sample on the host clock: its TSF mapped to CLOCK_MONOTONIC, and which
/// sensor (spectral card) took it.
pub const Stamped = struct {
    s: Sample,
    mono_ns: u64,
    sensor: u8 = 0,
};

pub const Counts = struct {
    samples: u64 = 0,
    skipped: u64 = 0,
    malformed: u64 = 0,
    ht40: u64 = 0,
    /// The last skipped record's type and length (diagnostics).
    skipped_kind: u8 = 0,
    skipped_len: u16 = 0,
};
/// The HT20/40 record type (128 bins over 40 MHz); counted, not decoded yet.
pub const type_ht20_40 = 2;

/// Parses whole records from `bytes`, appending HT20 samples to `out` (at most
/// out.len). Returns the bytes consumed: a trailing partial record is left for
/// the next read. Other TLV types (HT20/40, ath10k) are counted as skipped.
pub fn parse(bytes: []const u8, read_ns: u64, out: []Sample, n_out: *usize, counts: *Counts) usize {
    var at: usize = 0;
    while (bytes.len - at >= 3) {
        const kind = bytes[at];
        const len = std.mem.readInt(u16, bytes[at + 1 ..][0..2], .big);
        // An impossible header (zero, absurd, or an HT20 record of the wrong length):
        // the stream is out of step. Find the next plausible record header rather
        // than dropping the rest, so a burst of corrupted records cannot stall it.
        if (kind == 0 or len == 0 or len > 1024 or (kind == type_ht20 and len != ht20_len)) {
            counts.malformed += 1;
            at = resync(bytes, at + 1);
            continue;
        }
        if (bytes.len - at - 3 < len) break;
        const body = bytes[at + 3 ..][0..len];
        at += 3 + len;
        if (kind != type_ht20 or len != ht20_len) {
            counts.skipped += 1;
            counts.ht40 += @intFromBool(kind == type_ht20_40);
            counts.skipped_kind = kind;
            counts.skipped_len = len;
            continue;
        }
        if (n_out.* >= out.len) {
            counts.skipped += 1;
            continue;
        }
        const s = decodeHt20(body, read_ns);
        // A corrupted record can still have the right type and length: a frequency
        // outside the 2.4 GHz band is not a sample (counted, skipped, the stream goes on).
        if (s.freq_mhz < 2300 or s.freq_mhz > 2600) {
            counts.malformed += 1;
            continue;
        }
        out[n_out.*] = s;
        n_out.* += 1;
        counts.samples += 1;
    }
    return at;
}

/// The next position at or after `from` that looks like an HT20 (or HT20/40)
/// record header with an in-band frequency, or bytes.len.
fn resync(bytes: []const u8, from: usize) usize {
    var p = from;
    while (p + 3 <= bytes.len) : (p += 1) {
        const kind = bytes[p];
        const len = std.mem.readInt(u16, bytes[p + 1 ..][0..2], .big);
        if (!((kind == type_ht20 and len == ht20_len) or (kind == type_ht20_40 and len == 152))) continue;
        if (p + 6 > bytes.len) return p;
        const freq = std.mem.readInt(u16, bytes[p + 4 ..][0..2], .big);
        if (freq >= 2300 and freq <= 2600) return p;
    }
    return bytes.len;
}

/// fft_eval's formula: bin dBm = noise + rssi + 20 log10(d << exp) - 10 log10(sum (d << exp)^2).
fn decodeHt20(b: []const u8, read_ns: u64) Sample {
    const max_exp: u5 = @intCast(@min(b[0], 15));
    var s = Sample{
        .tsf_us = std.mem.readInt(u64, b[9..17], .big),
        .read_ns = read_ns,
        .freq_mhz = std.mem.readInt(u16, b[1..3], .big),
        .rssi = @bitCast(b[3]),
        .noise = @bitCast(b[4]),
        .power = undefined,
    };
    const data = b[17..][0..bins];
    var sum: f64 = 0;
    for (data) |d| {
        const v: f64 = @floatFromInt(@max(@as(u32, d) << max_exp, 1));
        sum += v * v;
    }
    const base = @as(f64, @floatFromInt(s.noise)) + @as(f64, @floatFromInt(s.rssi)) - 10 * std.math.log10(sum);
    for (data, &s.power) |d, *p| {
        const v: f64 = @floatFromInt(@max(@as(u32, d) << max_exp, 1));
        p.* = @intFromFloat(std.math.clamp(@round(base + 20 * std.math.log10(v)), -128, 127));
    }
    return s;
}

/// Test and synthetic-data encoder: one HT20 record whose decoded bins match
/// `mw` (linear power per bin, milliwatts) as closely as 8-bit magnitudes allow.
pub fn encode(out: *[3 + ht20_len]u8, tsf_us: u64, freq_mhz: u16, noise: i8, mw: *const [bins]f64) void {
    var total: f64 = 0;
    var peak: f64 = 0;
    for (mw) |w| {
        total += w;
        peak = @max(peak, w);
    }
    const noise_mw = std.math.pow(f64, 10, @as(f64, @floatFromInt(noise)) / 10);
    const rssi = std.math.clamp(@round(10 * std.math.log10(@max(total, 1e-30) / noise_mw)), -128, 127);
    out[0] = type_ht20;
    std.mem.writeInt(u16, out[1..3], ht20_len, .big);
    const b = out[3..];
    b[0] = 0; // max_exp
    std.mem.writeInt(u16, b[1..3], freq_mhz, .big);
    b[3] = @bitCast(@as(i8, @intFromFloat(rssi)));
    b[4] = @bitCast(noise);
    std.mem.writeInt(u16, b[5..7], 0, .big);
    var max_index: u8 = 0;
    for (mw, 0..) |w, i| {
        // Magnitude is the square root of power; the strongest bin is 255.
        const mag = if (peak > 0) std.math.sqrt(w / peak) * 255 else 0;
        b[17 + i] = @intFromFloat(std.math.clamp(@round(mag), 0, 255));
        if (w == peak) max_index = @intCast(i);
    }
    b[7] = max_index;
    b[8] = 0;
    std.mem.writeInt(u64, b[9..17], tsf_us, .big);
}

test "decodes an HT20 record and keeps a partial tail" {
    var mw: [bins]f64 = @splat(1e-12);
    mw[20] = 1e-6; // -60 dBm in one bin
    var rec: [3 + ht20_len]u8 = undefined;
    encode(&rec, 123456, 2457, -95, &mw);
    var buf: [2 * rec.len + 10]u8 = undefined;
    @memcpy(buf[0..rec.len], &rec);
    @memcpy(buf[rec.len .. 2 * rec.len], &rec);
    buf[2 * rec.len] = 9; // unknown type, whole
    std.mem.writeInt(u16, buf[2 * rec.len + 1 ..][0..2], 2, .big);
    buf[2 * rec.len + 5] = type_ht20; // a partial header
    var out: [4]Sample = undefined;
    var n: usize = 0;
    var counts = Counts{};
    const used = parse(buf[0 .. 2 * rec.len + 7], 7, &out, &n, &counts);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 2 * rec.len + 5), used);
    try std.testing.expectEqual(@as(u64, 1), counts.skipped);
    const s = out[0];
    try std.testing.expectEqual(@as(u64, 123456), s.tsf_us);
    try std.testing.expectEqual(@as(u16, 2457), s.freq_mhz);
    try std.testing.expectEqual(@as(u64, 7), s.read_ns);
    // Total -60 dBm: rssi 35 over -95; the bin holds it, the rest is far below.
    try std.testing.expectEqual(@as(i8, 35), s.rssi);
    try std.testing.expect(@abs(@as(i32, s.power[20]) + 60) <= 1);
    try std.testing.expect(s.power[0] < -100);
    try std.testing.expect(@abs(s.binMhz(28) - 2457.18) < 0.01);
}

test "hostile bytes never crash" {
    var prng = std.Random.DefaultPrng.init(0xa79271);
    const r = prng.random();
    var buf: [600]u8 = undefined;
    var out: [8]Sample = undefined;
    for (0..2000) |_| {
        r.bytes(&buf);
        if (r.boolean()) buf[0] = type_ht20;
        var n: usize = 0;
        var counts = Counts{};
        const used = parse(buf[0..r.uintAtMost(usize, buf.len)], 0, &out, &n, &counts);
        try std.testing.expect(used <= buf.len);
    }
}

test "resync fuzz: corrupted headers, absurd lengths and cuts: bounded, only in-band samples" {
    var prng = std.Random.DefaultPrng.init(0x9271);
    const r = prng.random();
    var rec: [3 + ht20_len]u8 = undefined;
    var mw: [bins]f64 = @splat(1e-9);
    mw[20] = 1e-6;
    encode(&rec, 1234, 2437, -95, &mw);
    var stream: [4096]u8 = undefined;
    var out: [64]Sample = undefined;
    for (0..5000) |_| {
        // Garbage (including fake HT20 headers with bogus frequencies), then one clean record.
        const g = r.uintAtMost(usize, 600);
        r.bytes(stream[0..g]);
        var k: usize = 0;
        while (k + 3 <= g) : (k += 1 + r.uintLessThan(usize, 40)) {
            switch (r.uintLessThan(u8, 4)) {
                0 => {
                    stream[k] = type_ht20;
                    std.mem.writeInt(u16, stream[k + 1 ..][0..2], ht20_len, .big);
                },
                1 => {
                    stream[k] = r.int(u8);
                    std.mem.writeInt(u16, stream[k + 1 ..][0..2], 0xffff, .big);
                },
                2 => std.mem.writeInt(u16, stream[k + 1 ..][0..2], 0, .big),
                else => {},
            }
        }
        @memcpy(stream[g..][0..rec.len], &rec);
        const total = g + rec.len;
        var n: usize = 0;
        var counts = Counts{};
        const used = parse(stream[0..total], 0, &out, &n, &counts);
        try std.testing.expect(used <= total);
        for (out[0..n]) |s| try std.testing.expect(s.freq_mhz >= 2300 and s.freq_mhz <= 2600);
        // Every cut point is safe too.
        const cut = r.uintAtMost(usize, total);
        n = 0;
        try std.testing.expect(parse(stream[0..cut], 0, &out, &n, &counts) <= cut);
    }
}
