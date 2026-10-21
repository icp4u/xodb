//! The blast radius: what the 2.4 GHz band looks like per Wi-Fi channel,
//! 1-14, and what an interferer does to each. Pure.
//!
//! Spectral samples are grouped by the window they were taken in (one region
//! per tuned centre; a sweep revisits each). Each region gets the detector's
//! verdict, with its dwells joined end to end so mains pulsing is measured
//! within them. Per 1 MHz bucket the region says what is there (mains-pulsed,
//! continuous, hopping, Wi-Fi-like, other or quiet). Per channel (its
//! 22 MHz mask at its true centre, 5 MHz apart, overlapping) the window
//! centred nearest the channel gives power, floor, power over the floor and
//! the share of time occupied; the buckets an interferer holds inside the
//! mask say how hard it is hit: blasted, grazed or clean. Traffic from a
//! receive-only monitor card comes per channel from its dwells.
const std = @import("std");
const ath9k = @import("ath9k.zig");
const detect = @import("detect.zig");
const radiotap = @import("radiotap.zig");
const sweep = @import("sweep.zig");

pub const n_channels = 14;
/// A Wi-Fi channel's spectral mask is about 22 MHz wide.
pub const mask_half: u16 = 11;
/// A channel is measured only by a window that sees this much of its mask.
pub const min_seen_mhz: u16 = 12;
/// The interferer's in-channel power over the floor that blasts a channel
/// (a typical link has 25-45 dB of SNR), and that grazes it.
pub const blasted_db: f32 = 20;
pub const grazed_db: f32 = 6;
/// Samples more than this apart start a new dwell (joined when analysing).
const dwell_gap_ns: u64 = 50_000_000;

pub const Impact = enum { unseen, clean, grazed, blasted };
pub const Class = enum { unseen, quiet, wifi_like, hopping, mains_pulsed, continuous, other };

pub const Traffic = struct {
    watched_s: f32 = 0,
    dwells: u32 = 0,
    frames: u32 = 0,
    frames_ps: f32 = 0,
    /// Estimated share of the watched time the air carried frames (length / rate).
    airtime: f32 = 0,
    /// Retries among data and management frames.
    retry: ?f32 = null,
    bad_fcs: u32 = 0,
    bad_fcs_ps: f32 = 0,
    /// Distinct networks (BSSIDs) and stations seen; counted by keyed hash, never stored.
    networks: u32 = 0,
    stations: u32 = 0,
    /// The per-dwell sets overflowed: at least these many.
    at_least: bool = false,
    signal_dbm: ?f32 = null,
};

pub const Channel = struct {
    channel: u8,
    centre_mhz: u16,
    lo_mhz: u16,
    hi_mhz: u16,
    /// The window (its centre) that measured this channel, and how much of the mask it saw.
    window_mhz: ?u16 = null,
    seen_mhz: u16 = 0,
    samples: u32 = 0,
    watched_s: f32 = 0,
    /// Since the newest sample of that window.
    age_ms: ?u32 = null,
    power_dbm: ?f32 = null,
    floor_dbm: ?f32 = null,
    over_floor_db: ?f32 = null,
    /// 95th percentile of the channel power over the samples.
    peak_dbm: ?f32 = null,
    /// Share of samples with the channel's power 8 dB or more over its floor.
    occupied: ?f32 = null,
    /// MHz of the mask held by the interferer (mains-pulsed or continuous buckets).
    interferer_mhz: u16 = 0,
    /// The interferer's power inside the mask while it is on, and that over the floor.
    interferer_dbm: ?f32 = null,
    interferer_over_floor_db: ?f32 = null,
    /// Share of samples in which the interferer's part of the mask was 8 dB or more over the floor.
    interferer_time: ?f32 = null,
    /// Five-second windows which observed this channel, and those in which
    /// the localized interferer grazed or blasted it. Non-zero for a phase
    /// aggregate; a single-window report uses 0/1 or 1/1.
    observed_windows: u16 = 0,
    hit_windows: u16 = 0,
    impact: Impact = .unseen,
    mains_hz: ?u8 = null,
    traffic: ?Traffic = null,
};

pub const Region = struct {
    centre_mhz: u16,
    samples: u32,
    dwells: u32,
    watched_s: f32,
    age_ms: u32,
    kind: detect.Kind,
    mains_hz: ?u8,
    confidence: f32,
    r60: f32,
    r50: f32,
    duty: ?f32,
    band_lo_mhz: ?f32,
    band_hi_mhz: ?f32,
    floor_dbm: f32,
};

pub const Bucket = struct {
    class: Class = .unseen,
    /// The interferer's mean power in this MHz while on (mW), for mains-pulsed and continuous buckets.
    interferer_mw: f64 = 0,
    occupied: f32 = 0,
    power_dbm: ?f32 = null,
    age_ms: ?u32 = null,
};

pub const Blast = struct { kind: detect.Kind, mains_hz: ?u8, lo_mhz: u16, hi_mhz: u16, confidence: f32 };

pub const Report = struct {
    window_s: f32,
    samples: u32,
    channels: [n_channels]Channel,
    regions: []const Region,
    /// 1 MHz buckets from 2400 MHz.
    buckets: [detect.n_buckets]Bucket,
    blast: ?Blast,
    /// "microwave-like 60 Hz pulsing at 2447-2467 MHz: channels 8-12 blasted (...), 6-7 and 13 grazed, 1-5 and 14 clean"
    words: []const u8,
    /// Traffic on hit channels against clean ones, when a monitor card counted it.
    traffic_words: []const u8,
    /// The least affected of channels 1, 6 and 11, the usual AP choices.
    best_channel: ?u8,
    advice: []const u8,
    /// Whole-window pulsing and how often a five-second temporal view could
    /// localize it. These keep a phase honest when its carrier sweeps.
    pulsing: bool = false,
    pulse_mains_hz: ?u8 = null,
    location_windows_total: u16 = 0,
    location_windows_pulsing: u16 = 0,
    location_windows_located: u16 = 0,
};

pub const Span = struct { lo: usize, hi: usize, pulsed: bool };
/// The blast's 1 MHz buckets [lo, hi) from 2400 MHz. With mains pulsing: from
/// the first to the last mains-pulsed bucket, widened through the continuous
/// buckets that touch it (the oven's skirt); continuous energy apart from it is
/// another source and stays out. Without mains pulsing: the continuous span
/// (reported as continuous, never as a mains blast).
pub fn blastRange(buckets: []const Bucket) ?Span {
    var p0: ?usize = null;
    var p1: usize = 0;
    for (buckets, 0..) |b, k| if (b.class == .mains_pulsed) {
        if (p0 == null) p0 = k;
        p1 = k + 1;
    };
    if (p0) |first| {
        var lo = first;
        while (lo > 0 and buckets[lo - 1].class == .continuous) lo -= 1;
        var hi = p1;
        while (hi < buckets.len and buckets[hi].class == .continuous) hi += 1;
        return .{ .lo = lo, .hi = hi, .pulsed = true };
    }
    var c0: ?usize = null;
    var c1: usize = 0;
    for (buckets, 0..) |b, k| if (b.class == .continuous) {
        if (c0 == null) c0 = k;
        c1 = k + 1;
    };
    return if (c0) |first| .{ .lo = first, .hi = c1, .pulsed = false } else null;
}

test "the blast is the pulsed energy and its skirt, never a separate continuous source" {
    var b: [detect.n_buckets]Bucket = @splat(.{ .class = .quiet });
    try std.testing.expectEqual(@as(?Span, null), blastRange(&b));
    // A video sender at 2410-2420 alone: continuous, not pulsed.
    for (10..20) |k| b[k].class = .continuous;
    try std.testing.expectEqual(@as(?Span, .{ .lo = 10, .hi = 20, .pulsed = false }), blastRange(&b));
    // An oven at 2450-2470 with a continuous skirt 2445-2450 and 2470-2472.
    for (45..50) |k| b[k].class = .continuous;
    for (50..70) |k| b[k].class = .mains_pulsed;
    for (70..72) |k| b[k].class = .continuous;
    b[60].class = .wifi_like; // a Wi-Fi burst inside stays inside the span
    try std.testing.expectEqual(@as(?Span, .{ .lo = 45, .hi = 72, .pulsed = true }), blastRange(&b));
    // The separate sender (2410-2420) is not part of it.
    b[0].class = .continuous;
    b[b.len - 1].class = .mains_pulsed;
    const s = blastRange(&b).?;
    try std.testing.expect(s.pulsed and s.lo == 45 and s.hi == b.len);
}

pub fn maskOf(c: u8) [2]u16 {
    const f = sweep.channelMhz(c);
    return .{ f - mask_half, f + mask_half };
}
fn overlap(a: [2]u16, b: [2]u16) u16 {
    const lo = @max(a[0], b[0]);
    const hi = @min(a[1], b[1]);
    return if (hi > lo) hi - lo else 0;
}

const Group = struct { centre: u16, idx: std.ArrayList(u32) = .empty };

/// Analyses spectral samples and traffic dwells in [from_ns, to_ns) at `now_ns`
/// (CLOCK_MONOTONIC). Strings and slices live in `a`.
pub fn analyse(a: std.mem.Allocator, samples: []const ath9k.Stamped, dwells: []const radiotap.Dwell, from_ns: u64, to_ns: u64, now_ns: u64) !Report {
    return analyseKnown(a, samples, dwells, from_ns, to_ns, now_ns, null);
}

/// `analyse`, reusing a whole-window verdict when its caller already computed
/// one. The channel path still performs its per-frequency-region analyses.
pub fn analyseKnown(a: std.mem.Allocator, samples: []const ath9k.Stamped, dwells: []const radiotap.Dwell, from_ns: u64, to_ns: u64, now_ns: u64, known: ?*const detect.Verdict) !Report {
    var r = Report{ .window_s = @as(f32, @floatFromInt(to_ns -| from_ns)) / 1e9, .samples = @intCast(samples.len), .channels = undefined, .regions = &.{}, .buckets = @splat(.{}), .blast = null, .words = "", .traffic_words = "", .best_channel = null, .advice = "" };
    for (&r.channels, 1..) |*ch, c| {
        const m = maskOf(@intCast(c));
        ch.* = .{ .channel = @intCast(c), .centre_mhz = sweep.channelMhz(@intCast(c)), .lo_mhz = m[0], .hi_mhz = m[1] };
    }

    var computed = detect.Verdict{};
    const whole = if (known) |v| v else blk: {
        const xs = try a.alloc(ath9k.Sample, samples.len);
        for (xs, samples) |*out, x| {
            out.* = x.s;
            out.tsf_us = x.mono_ns / 1000;
        }
        computed = try detect.analyse(a, xs, .{});
        break :blk &computed;
    };
    r.pulsing = whole.kind == .microwave_pulsed;
    r.pulse_mains_hz = if (r.pulsing) whole.mains_hz else null;
    r.location_windows_total = @intFromBool(samples.len > 0);
    r.location_windows_pulsing = @intFromBool(r.pulsing);

    // Regions: samples by tuned centre.
    var groups: std.ArrayList(Group) = .empty;
    for (samples, 0..) |*x, i| {
        const f = x.s.freq_mhz;
        if (f < 2400 or f > 2500) continue;
        const g = for (groups.items) |*g| {
            if (g.centre == f) break g;
        } else blk: {
            if (groups.items.len >= 32) continue;
            try groups.append(a, .{ .centre = f });
            break :blk &groups.items[groups.items.len - 1];
        };
        try g.idx.append(a, @intCast(i));
    }
    std.mem.sortUnstable(Group, groups.items, {}, struct {
        fn lt(_: void, x: Group, y: Group) bool {
            return x.centre < y.centre;
        }
    }.lt);
    const regions = try a.alloc(Region, groups.items.len);
    const region_buckets = try a.alloc(detect.Buckets, groups.items.len);
    const region_class = try a.alloc(Classes, groups.items.len);
    for (groups.items, regions, region_buckets, region_class) |*g, *reg, *bk, *cls| {
        // Join the dwells end to end on the host clock (gaps become one median step).
        const joined = try a.alloc(ath9k.Sample, g.idx.items.len);
        var shift: u64 = 0;
        var n_dwells: u32 = 1;
        var watched: u64 = 0;
        var run_start = samples[g.idx.items[0]].mono_ns;
        var prev = run_start;
        for (g.idx.items, joined, 0..) |i, *out, k| {
            const t = samples[i].mono_ns;
            if (k > 0 and t -| prev > dwell_gap_ns) {
                watched += prev - run_start;
                shift += t - prev - 150_000; // ~one sample step at ~6.6k/s
                n_dwells += 1;
                run_start = t;
            }
            prev = t;
            out.* = samples[i].s;
            out.tsf_us = (t -| shift) / 1000;
        }
        watched += prev - run_start;
        bk.* = .{};
        const v = try detect.analyseBuckets(a, joined, .{}, bk);
        reg.* = .{
            .centre_mhz = g.centre,
            .samples = @intCast(g.idx.items.len),
            .dwells = n_dwells,
            .watched_s = @as(f32, @floatFromInt(watched)) / 1e9,
            .age_ms = @intCast(@min(std.math.maxInt(u32), (now_ns -| prev) / 1_000_000)),
            .kind = v.kind,
            .mains_hz = v.mains_hz,
            .confidence = v.confidence,
            .r60 = v.r60,
            .r50 = v.r50,
            .duty = v.duty,
            .band_lo_mhz = v.band_lo_mhz,
            .band_hi_mhz = v.band_hi_mhz,
            .floor_dbm = v.floor_dbm,
        };
        cls.* = try classify(a, samples, g.idx.items, &v, bk);
    }
    r.regions = regions;

    // Buckets: what each 1 MHz is, by the regions that saw it.
    var best_all: [detect.n_buckets]u32 = @splat(0);
    for (regions, region_buckets, region_class) |*reg, *bk, *cls| {
        for (0..detect.n_buckets) |k| {
            if (bk.all[k] == 0) continue;
            const b = &r.buckets[k];
            const occ = @as(f32, @floatFromInt(bk.hot[k])) / @as(f32, @floatFromInt(bk.all[k]));
            const class = cls.class[k];
            if (@intFromEnum(class) > @intFromEnum(b.class)) b.class = class;
            b.interferer_mw = @max(b.interferer_mw, cls.interferer_mw[k]);
            if (b.age_ms == null or reg.age_ms < b.age_ms.?) b.age_ms = reg.age_ms;
            // Power and occupancy from the region that covered the bucket most.
            if (bk.all[k] > best_all[k]) {
                best_all[k] = bk.all[k];
                b.occupied = occ;
                if (bk.bins[k] > 0) b.power_dbm = @floatCast(10 * std.math.log10(bk.mw[k] / @as(f64, @floatFromInt(bk.bins[k]))));
            }
        }
    }
    // The blast: buckets the interferer holds.
    const span = blastRange(&r.buckets);
    var in_blast: [detect.n_buckets]bool = @splat(false);
    if (span) |s| for (s.lo..s.hi) |k| {
        in_blast[k] = r.buckets[k].class == .mains_pulsed or r.buckets[k].class == .continuous;
    };
    const any_pulsed = if (span) |s| s.pulsed else false;
    if (span) |s| {
        const lo: u16 = @intCast(2400 + s.lo);
        const blast_hi: u16 = @intCast(2400 + s.hi);
        var best: ?*const Region = null;
        for (regions) |*reg| if ((reg.kind == .microwave_pulsed) == any_pulsed and (reg.kind == .microwave_pulsed or reg.kind == .continuous_wideband)) {
            if (best == null or reg.confidence > best.?.confidence) best = reg;
        };
        r.blast = .{ .kind = if (any_pulsed) .microwave_pulsed else .continuous_wideband, .mains_hz = if (best) |b| b.mains_hz else null, .lo_mhz = lo, .hi_mhz = blast_hi, .confidence = if (best) |b| b.confidence else 0 };
        if (any_pulsed) {
            r.pulsing = true;
            if (r.pulse_mains_hz == null) r.pulse_mains_hz = r.blast.?.mains_hz;
            r.location_windows_pulsing = 1;
            r.location_windows_located = 1;
        }
    }

    // Channels: the window centred nearest each channel measures it.
    var powers: std.ArrayList(f32) = .empty;
    var noises: std.ArrayList(f32) = .empty;
    for (&r.channels) |*ch| {
        const mask = [2]u16{ ch.lo_mhz, ch.hi_mhz };
        var pick: ?usize = null;
        for (regions, 0..) |*reg, i| {
            if (reg.samples < 50) continue;
            const seen = overlap(mask, .{ reg.centre_mhz - sweep.half, reg.centre_mhz + sweep.half });
            if (seen < min_seen_mhz) continue;
            if (pick == null) {
                pick = i;
                continue;
            }
            const d_new = @abs(@as(i32, reg.centre_mhz) - ch.centre_mhz);
            const d_old = @abs(@as(i32, regions[pick.?].centre_mhz) - ch.centre_mhz);
            if (d_new < d_old or (d_new == d_old and reg.samples > regions[pick.?].samples)) pick = i;
        }
        var inter_mw: f64 = 0;
        var blast_bucket: [detect.n_buckets]bool = @splat(false);
        for (ch.lo_mhz - 2400..@min(detect.n_buckets, ch.hi_mhz - 2400)) |k| {
            const b = r.buckets[k];
            if (!in_blast[k]) continue;
            ch.interferer_mhz += 1;
            inter_mw += b.interferer_mw;
            blast_bucket[k] = true;
        }
        const i = pick orelse continue;
        const reg = &regions[i];
        ch.window_mhz = reg.centre_mhz;
        ch.seen_mhz = overlap(mask, .{ reg.centre_mhz - sweep.half, reg.centre_mhz + sweep.half });
        var blast_seen: u16 = 0;
        for (@max(ch.lo_mhz, reg.centre_mhz - sweep.half) - 2400..@min(ch.hi_mhz, reg.centre_mhz + sweep.half) - 2400) |k| blast_seen += @intFromBool(blast_bucket[k]);
        var blast_mws: std.ArrayList(f32) = .empty;
        ch.samples = reg.samples;
        ch.watched_s = reg.watched_s;
        ch.age_ms = reg.age_ms;
        powers.clearRetainingCapacity();
        noises.clearRetainingCapacity();
        var sum_mw: f64 = 0;
        for (groups.items[i].idx.items) |si| {
            const s = &samples[si].s;
            var mw: f64 = 0;
            var mwb: f64 = 0;
            for (s.power, 0..) |p, b| {
                const f = s.binMhz(b);
                if (f >= @as(f32, @floatFromInt(mask[0])) and f < @as(f32, @floatFromInt(mask[1]))) {
                    const x = detect.linear[@as(u8, @bitCast(p))];
                    mw += x;
                    if (blast_bucket[@intFromFloat(f - 2400)]) mwb += x;
                }
            }
            sum_mw += mw;
            if (blast_seen > 0) try blast_mws.append(a, @floatCast(10 * std.math.log10(@max(mwb, 1e-15))));
            try powers.append(a, @floatCast(10 * std.math.log10(@max(mw, 1e-15))));
            try noises.append(a, @floatFromInt(s.noise));
        }
        const n = powers.items.len;
        std.mem.sortUnstable(f32, powers.items, {}, std.sort.asc(f32));
        std.mem.sortUnstable(f32, noises.items, {}, std.sort.asc(f32));
        // As the detector: the quieter tenth, capped by the card's own noise floor for this share of the window.
        const card_floor = noises.items[n / 2] + 10 * std.math.log10(@as(f32, @floatFromInt(ch.seen_mhz)) / 20) + 3;
        const floor = @min(powers.items[n / 10], card_floor);
        var on: usize = 0;
        for (powers.items) |p| on += @intFromBool(p >= floor + 8);
        ch.floor_dbm = floor;
        ch.power_dbm = @floatCast(10 * std.math.log10(@max(sum_mw / @as(f64, @floatFromInt(n)), 1e-15)));
        ch.over_floor_db = ch.power_dbm.? - floor;
        ch.peak_dbm = powers.items[@min(n - 1, n * 95 / 100)];
        ch.occupied = @as(f32, @floatFromInt(on)) / @as(f32, @floatFromInt(n));
        ch.impact = .clean;
        ch.observed_windows = 1;
        if (ch.interferer_mhz > 0 and inter_mw > 0) {
            ch.interferer_dbm = @floatCast(10 * std.math.log10(inter_mw));
            const over = ch.interferer_dbm.? - floor;
            ch.interferer_over_floor_db = over;
            if (blast_seen > 0) {
                // Its share of the floor is its share of the seen mask.
                const at = floor + 10 * std.math.log10(@as(f32, @floatFromInt(blast_seen)) / @as(f32, @floatFromInt(ch.seen_mhz))) + 8;
                var hits: usize = 0;
                for (blast_mws.items) |x| hits += @intFromBool(x >= at);
                ch.interferer_time = @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(blast_mws.items.len));
            }
            // A severity label requires at least one sample that met the same
            // time-share threshold printed beside it. Rare non-zero hits are
            // kept and printed as <1%; zero cannot read as "blasted 0%".
            const present = (ch.interferer_time orelse 0) > 0;
            ch.impact = if (!present) .clean else if (over >= blasted_db) .blasted else if (over >= grazed_db) .grazed else .clean;
            if (!present) {
                ch.interferer_mhz = 0;
                ch.interferer_dbm = null;
                ch.interferer_over_floor_db = null;
                ch.interferer_time = null;
            }
            ch.hit_windows = @intFromBool(ch.impact == .blasted or ch.impact == .grazed);
            if (r.blast != null and ch.hit_windows > 0) ch.mains_hz = r.blast.?.mains_hz;
        }
    }

    // Traffic per channel.
    var sets_n: std.ArrayList([]const u32) = .empty;
    var sets_s: std.ArrayList([]const u32) = .empty;
    for (&r.channels) |*ch| {
        var t = Traffic{};
        var watched: u64 = 0;
        var eligible: u32 = 0;
        var retries: u32 = 0;
        var air: u64 = 0;
        var sig: i64 = 0;
        var sig_n: u32 = 0;
        sets_n.clearRetainingCapacity();
        sets_s.clearRetainingCapacity();
        for (dwells) |*d| {
            if (d.channel != ch.channel or d.to_ns <= from_ns or d.from_ns >= to_ns) continue;
            t.dwells += 1;
            watched += d.to_ns -| d.from_ns;
            t.frames += d.frames;
            eligible += d.retry_eligible;
            retries += d.retries;
            t.bad_fcs += d.bad_fcs;
            air += d.airtime_us;
            sig += d.signal_sum;
            sig_n += d.signal_n;
            t.at_least = t.at_least or d.more;
            try sets_n.append(a, d.nets[0..d.n_nets]);
            try sets_s.append(a, d.stas[0..d.n_stas]);
        }
        if (t.dwells == 0) continue;
        t.watched_s = @as(f32, @floatFromInt(watched)) / 1e9;
        if (t.watched_s > 0) {
            t.frames_ps = @as(f32, @floatFromInt(t.frames)) / t.watched_s;
            t.bad_fcs_ps = @as(f32, @floatFromInt(t.bad_fcs)) / t.watched_s;
            t.airtime = @min(1, @as(f32, @floatFromInt(air)) / 1e6 / t.watched_s);
        }
        if (eligible > 0) t.retry = @as(f32, @floatFromInt(retries)) / @as(f32, @floatFromInt(eligible));
        if (sig_n > 0) t.signal_dbm = @as(f32, @floatFromInt(sig)) / @as(f32, @floatFromInt(sig_n));
        t.networks = try radiotap.distinct(a, sets_n.items);
        t.stations = try radiotap.distinct(a, sets_s.items);
        ch.traffic = t;
    }

    try writeWords(a, &r, samples.len > 0);

    try writeTrafficWords(a, &r, dwells, from_ns, to_ns);
    try writeAdvice(a, &r);
    return r;
}

pub const location_window_ns: u64 = 5_000_000_000;

/// A phase location is the union of the locations independently supported by
/// its five-second views. This preserves a swept carrier instead of letting a
/// long-window average collapse it to one peak bucket.
pub fn analyseWindowed(a: std.mem.Allocator, samples: []const ath9k.Stamped, dwells: []const radiotap.Dwell, from_ns: u64, to_ns: u64, now_ns: u64, known: ?*const detect.Verdict) !Report {
    var r = try analyseKnown(a, samples, dwells, from_ns, to_ns, now_ns, known);
    if (to_ns -| from_ns <= location_window_ns or samples.len == 0) return r;

    var total: u16 = 0;
    var pulsing: u16 = 0;
    var located: u16 = 0;
    var lo_mhz: u16 = std.math.maxInt(u16);
    var hi_mhz: u16 = 0;
    var best_confidence: f32 = -1;
    var best_hz: ?u8 = r.pulse_mains_hz;
    var observed: [n_channels]u16 = @splat(0);
    var hit: [n_channels]u16 = @splat(0);
    var worst: [n_channels]Impact = @splat(.unseen);
    var max_over: [n_channels]f32 = @splat(-std.math.inf(f32));
    var max_dbm: [n_channels]f32 = @splat(-std.math.inf(f32));
    var max_mhz: [n_channels]u16 = @splat(0);
    var time_sum: [n_channels]f32 = @splat(0);

    var si: usize = 0;
    var start = from_ns;
    while (start < to_ns) : (start += location_window_ns) {
        const stop = @min(to_ns, start +| location_window_ns);
        // A very short phase tail cannot resolve 20 mains periods and should
        // not dilute the location-window denominator.
        if (stop - start < 1_000_000_000) break;
        while (si < samples.len and samples[si].mono_ns < start) si += 1;
        var end = si;
        while (end < samples.len and samples[end].mono_ns < stop) end += 1;
        total +|= 1;
        {
            // A phase can contain hundreds of windows. Only their scalar
            // location evidence survives this block; release each window's
            // detector arrays before analysing the next one.
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const part = try analyseKnown(scratch.allocator(), samples[si..end], &.{}, start, stop, now_ns, null);
            const part_pulsed = part.pulsing or (part.blast != null and part.blast.?.kind == .microwave_pulsed);
            if (part_pulsed) pulsing +|= 1;
            const part_located = part.blast != null and part.blast.?.kind == .microwave_pulsed;
            if (part_located) {
                located +|= 1;
                const b = part.blast.?;
                lo_mhz = @min(lo_mhz, b.lo_mhz);
                hi_mhz = @max(hi_mhz, b.hi_mhz);
                if (b.confidence > best_confidence) {
                    best_confidence = b.confidence;
                    best_hz = b.mains_hz orelse part.pulse_mains_hz;
                }
                for (part.buckets, &r.buckets) |src, *dst| if (src.class == .mains_pulsed) {
                    dst.class = .mains_pulsed;
                    dst.interferer_mw = @max(dst.interferer_mw, src.interferer_mw);
                };
            }
            for (part.channels, 0..) |ch, k| {
                if (ch.impact == .unseen) continue;
                observed[k] +|= 1;
                if (!part_located or (ch.impact != .blasted and ch.impact != .grazed)) continue;
                hit[k] +|= 1;
                time_sum[k] += ch.interferer_time orelse 0;
                if (@intFromEnum(ch.impact) > @intFromEnum(worst[k])) worst[k] = ch.impact;
                if (ch.interferer_over_floor_db) |x| max_over[k] = @max(max_over[k], x);
                if (ch.interferer_dbm) |x| max_dbm[k] = @max(max_dbm[k], x);
                max_mhz[k] = @max(max_mhz[k], ch.interferer_mhz);
            }
        }
        si = end;
    }

    r.location_windows_total = total;
    r.location_windows_pulsing = pulsing;
    r.location_windows_located = located;
    r.pulsing = r.pulsing or pulsing > 0;
    if (best_hz != null) r.pulse_mains_hz = best_hz;
    if (!r.pulsing) return r;

    if (located > 0) {
        r.blast = .{ .kind = .microwave_pulsed, .mains_hz = best_hz, .lo_mhz = lo_mhz, .hi_mhz = hi_mhz, .confidence = @max(0, best_confidence) };
    } else {
        r.blast = null;
    }
    for (&r.channels, 0..) |*ch, k| {
        ch.observed_windows = observed[k];
        ch.hit_windows = hit[k];
        if (observed[k] == 0) {
            ch.impact = .unseen;
        } else if (hit[k] == 0) {
            ch.impact = .clean;
            ch.interferer_mhz = 0;
            ch.interferer_dbm = null;
            ch.interferer_over_floor_db = null;
            ch.interferer_time = null;
            ch.mains_hz = null;
        } else {
            ch.impact = worst[k];
            ch.interferer_mhz = max_mhz[k];
            ch.interferer_dbm = max_dbm[k];
            ch.interferer_over_floor_db = max_over[k];
            ch.interferer_time = time_sum[k] / @as(f32, @floatFromInt(observed[k]));
            ch.mains_hz = best_hz;
        }
    }
    try writeWords(a, &r, true);
    try writeTrafficWords(a, &r, dwells, from_ns, to_ns);
    try writeAdvice(a, &r);
    return r;
}

/// Formats a non-zero time share without turning a real, short hit into 0%.
pub fn timeShareText(buf: []u8, share: f32) []const u8 {
    if (share > 0 and share < 0.005) return "<1%";
    return std.fmt.bufPrint(buf, "{d:.0}%", .{share * 100}) catch "";
}

test "a short real hit never prints as zero percent" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("<1%", timeShareText(&b, 0.004));
    try std.testing.expectEqualStrings("0%", timeShareText(&b, 0));
}

fn writeWords(a: std.mem.Allocator, r: *Report, have_samples: bool) !void {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    const resolved = r.blast != null and r.blast.?.kind == .microwave_pulsed;
    if (r.pulsing and !resolved) {
        try w.print("microwave-like {d} Hz pulsing seen; location unresolved this window", .{r.pulse_mains_hz orelse 0});
    } else if (r.blast) |b| {
        if (b.kind == .microwave_pulsed) {
            try w.print("microwave-like {d} Hz pulsing {s}{d}-{d} MHz", .{ b.mains_hz orelse 0, if (r.location_windows_total > 1) "swept across " else "at ", b.lo_mhz, b.hi_mhz });
            if (r.location_windows_total > 1)
                try w.print(" (location resolved in {d}/{d} pulsing five-second windows; pulsing in {d}/{d})", .{ r.location_windows_located, r.location_windows_pulsing, r.location_windows_pulsing, r.location_windows_total });
            try w.print(": ", .{});
        } else {
            try w.print("continuous wideband energy at {d}-{d} MHz (mains pulsing not seen): ", .{ b.lo_mhz, b.hi_mhz });
        }
        var first = true;
        for ([_]Impact{ .blasted, .grazed, .clean }) |imp| {
            var list: [64]u8 = undefined;
            const ranges = rangeText(&list, &r.channels, imp);
            if (ranges.len == 0) continue;
            try w.print("{s}{s} {s}", .{ if (first) "channels " else ", ", ranges, @tagName(imp) });
            first = false;
            if (imp != .clean) {
                var over: f32 = -1000;
                var occ: f32 = 0;
                var k: f32 = 0;
                for (r.channels) |ch| if (ch.impact == imp) {
                    over = @max(over, ch.interferer_over_floor_db.?);
                    if (ch.interferer_time) |t| {
                        occ += t;
                        k += 1;
                    }
                };
                try w.print(" ({s}{d:.0} dB over the floor", .{ if (imp == .blasted) "up to " else "", over });
                if (k > 0) {
                    var pb: [16]u8 = undefined;
                    try w.print(", {s} of the time", .{timeShareText(&pb, occ / k)});
                }
                try w.print(")", .{});
            }
        }
        // Continuous energy apart from the pulsed blast is another source.
        var in_blast: [detect.n_buckets]bool = @splat(false);
        if (blastRange(&r.buckets)) |span| for (span.lo..span.hi) |k| {
            in_blast[k] = r.buckets[k].class == .mains_pulsed or r.buckets[k].class == .continuous;
        };
        var o_lo: ?usize = null;
        var o_hi: usize = 0;
        for (r.buckets, 0..) |bk, k| if (bk.class == .continuous and !in_blast[k]) {
            if (o_lo == null) o_lo = k;
            o_hi = k + 1;
        };
        if (o_lo) |ol| try w.print("; other continuous energy at {d}-{d} MHz (not mains-pulsed, not counted in the blast)", .{ 2400 + ol, 2400 + o_hi });
    } else if (have_samples) {
        var busiest: ?*const Channel = null;
        for (&r.channels) |*ch| if (ch.occupied) |o| {
            if (busiest == null or o > busiest.?.occupied.?) busiest = ch;
        };
        try w.print("no microwave-like interference in the band", .{});
        if (busiest) |bc| try w.print("; busiest channel {d} ({d:.0}% occupied, {d:.0} dB over the floor)", .{ bc.channel, bc.occupied.? * 100, bc.over_floor_db.? });
    }
    var list: [64]u8 = undefined;
    const ranges = rangeText(&list, &r.channels, .unseen);
    if (have_samples and ranges.len > 0) try w.print("; channel{s} {s} not watched in this window", .{ if (std.mem.indexOfAny(u8, ranges, "-a") != null) "s" else "", ranges });
    r.words = out.written();
}

fn writeTrafficWords(a: std.mem.Allocator, r: *Report, dwells: []const radiotap.Dwell, from_ns: u64, to_ns: u64) !void {
    r.traffic_words = "";
    var any = false;
    for (r.channels) |ch| any = any or ch.traffic != null;
    if (!any) return;
    var tw: std.Io.Writer.Allocating = .init(a);
    const hit = sumTraffic(&r.channels, .blasted, .grazed);
    const clean = sumTraffic(&r.channels, .clean, .clean);
    if (r.blast != null and hit.watched > 0) {
        try tw.writer.print("traffic on hit channels: {d:.0} frames/s, {d:.0}% retries, {d:.1} bad-FCS frames/s", .{ hit.frames / hit.watched, pct(hit.retries, hit.eligible), hit.bad / hit.watched });
        if (clean.watched > 0) try tw.writer.print("; on clean channels: {d:.0} frames/s, {d:.0}% retries, {d:.1} bad-FCS frames/s", .{ clean.frames / clean.watched, pct(clean.retries, clean.eligible), clean.bad / clean.watched });
    } else {
        // An access point is heard on its neighbours' channels too: count it once.
        var sets: std.ArrayList([]const u32) = .empty;
        for (dwells) |*d| if (d.to_ns > from_ns and d.from_ns < to_ns) try sets.append(a, d.nets[0..d.n_nets]);
        const nets = try radiotap.distinct(a, sets.items);
        var busiest: ?*const Channel = null;
        for (&r.channels) |*ch| if (ch.traffic) |t| {
            if (busiest == null or t.airtime > busiest.?.traffic.?.airtime) busiest = ch;
        };
        try tw.writer.print("traffic: {d} network{s} seen", .{ nets, if (nets == 1) "" else "s" });
        if (busiest) |bc| try tw.writer.print("; busiest channel {d} ({d:.0} frames/s, ~{d:.0}% airtime)", .{ bc.channel, bc.traffic.?.frames_ps, bc.traffic.?.airtime * 100 });
    }
    r.traffic_words = tw.written();
}

fn writeAdvice(a: std.mem.Allocator, r: *Report) !void {
    r.best_channel = null;
    r.advice = "";
    var best: ?*const Channel = null;
    for ([_]u8{ 1, 6, 11 }) |c| {
        const ch = &r.channels[c - 1];
        if (ch.impact == .unseen) continue;
        if (best == null or better(ch, best.?)) best = ch;
    }
    if (best) |b| {
        r.best_channel = b.channel;
        r.advice = try std.fmt.allocPrint(a, "least affected of channels 1/6/11{s}: {d} ({s}, {d:.0}% occupied{s})", .{ if (r.blast != null) " while it runs" else "", b.channel, @tagName(b.impact), b.occupied.? * 100, if (b.traffic) |t| try std.fmt.allocPrint(a, ", ~{d:.0}% airtime", .{t.airtime * 100}) else "" });
    }
}

fn kindClass(k: detect.Kind, occ: f32) Class {
    return switch (k) {
        .microwave_pulsed => .mains_pulsed,
        .continuous_wideband => .continuous,
        .bluetooth_like => if (occ >= 0.02) .hopping else .quiet,
        .wifi_like => if (occ >= 0.05) .wifi_like else .quiet,
        .unclassified => if (occ >= 0.05) .other else .quiet,
        .quiet, .not_enough_data => .quiet,
    };
}

/// What each bucket of one region is. In a mains-pulsed region a bucket is
/// the interferer's only when its energy follows the mains half-cycle: each
/// dwell's samples are folded over the mains period, the half-cycle holding
/// the most energy is "on", and the bucket must be hot clearly more often on
/// than off. The other buckets take the verdict of the off-phase samples
/// (the access points and Bluetooth the microwave shares the window with).
const Classes = struct { class: [detect.n_buckets]Class = @splat(.unseen), interferer_mw: [detect.n_buckets]f64 = @splat(0) };

fn classify(a: std.mem.Allocator, samples: []const ath9k.Stamped, idx: []const u32, v: *const detect.Verdict, bk: *const detect.Buckets) !Classes {
    var out = Classes{};
    const pulsed = v.kind == .microwave_pulsed and v.mains_hz != null;
    if (!pulsed) {
        for (&out.class, 0..) |*c, k| if (bk.all[k] > 0) {
            const occ = @as(f32, @floatFromInt(bk.hot[k])) / @as(f32, @floatFromInt(bk.all[k]));
            const f: f32 = 2400 + @as(f32, @floatFromInt(k)) + 0.5;
            const in_band = v.band_lo_mhz != null and f >= v.band_lo_mhz.? and f < v.band_hi_mhz.?;
            c.* = if (v.kind == .continuous_wideband and !in_band) (if (occ >= 0.05) .other else .quiet) else kindClass(v.kind, occ);
            if (c.* == .continuous) out.interferer_mw[k] = bk.mw[k] / @as(f64, @floatFromInt(bk.all[k]));
        };
        return out;
    }
    var mw_on: [detect.n_buckets]f64 = @splat(0);
    var mw_off: [detect.n_buckets]f64 = @splat(0);
    var sq_on: [detect.n_buckets]f64 = @splat(0);
    var sq_off: [detect.n_buckets]f64 = @splat(0);
    const period_ns: u64 = 1_000_000_000 / @as(u64, v.mains_hz.?);
    const phases = 24;
    const on_at = v.floor_dbm + 8;
    const bin_hot = v.floor_dbm - 10 * std.math.log10(@as(f32, ath9k.bins)) + 10;
    var hot_on: [detect.n_buckets]u32 = @splat(0);
    var all_on: [detect.n_buckets]u32 = @splat(0);
    var hot_off: [detect.n_buckets]u32 = @splat(0);
    var all_off: [detect.n_buckets]u32 = @splat(0);
    var off: std.ArrayList(ath9k.Sample) = .empty;
    defer off.deinit(a);
    var start: usize = 0;
    while (start < idx.len) {
        var end = start + 1;
        while (end < idx.len and samples[idx[end]].mono_ns -| samples[idx[end - 1]].mono_ns <= dwell_gap_ns) end += 1;
        // Fold this dwell's active samples over the mains period.
        var energy: [phases]u32 = @splat(0);
        for (idx[start..end]) |i| if (samples[i].s.total() >= on_at) {
            energy[@intCast((samples[i].mono_ns % period_ns) * phases / period_ns)] += 1;
        };
        var best: usize = 0;
        var best_sum: u32 = 0;
        for (0..phases) |b| {
            var sum: u32 = 0;
            for (0..phases / 2) |j| sum += energy[(b + j) % phases];
            if (sum > best_sum) {
                best_sum = sum;
                best = b;
            }
        }
        for (idx[start..end]) |i| {
            const x = &samples[i];
            const ph: usize = @intCast((x.mono_ns % period_ns) * phases / period_ns);
            const on = (ph + phases - best) % phases < phases / 2;
            if (!on) try off.append(a, x.s);
            var top: [detect.n_buckets]i8 = @splat(-128);
            var cov: [detect.n_buckets]bool = @splat(false);
            var mw: [detect.n_buckets]f64 = @splat(0);
            for (x.s.power, 0..) |p, b| {
                const f = x.s.binMhz(b);
                if (f < 2400 or f >= 2500) continue;
                const k: usize = @intFromFloat(f - 2400);
                cov[k] = true;
                top[k] = @max(top[k], p);
                mw[k] += detect.linear[@as(u8, @bitCast(p))];
            }
            for (0..detect.n_buckets) |k| if (cov[k]) {
                if (on) {
                    mw_on[k] += mw[k];
                    sq_on[k] += mw[k] * mw[k];
                } else {
                    mw_off[k] += mw[k];
                    sq_off[k] += mw[k] * mw[k];
                }
            };
            for (0..detect.n_buckets) |k| if (cov[k]) {
                const hot = @as(f32, @floatFromInt(top[k])) >= bin_hot;
                if (on) {
                    all_on[k] += 1;
                    hot_on[k] += @intFromBool(hot);
                } else {
                    all_off[k] += 1;
                    hot_off[k] += @intFromBool(hot);
                }
            };
        }
        start = end;
    }
    // The off-phase samples hold what shares the window with the interferer.
    var rest = detect.Kind.quiet;
    if (off.items.len > 0) {
        std.mem.sortUnstable(ath9k.Sample, off.items, {}, struct {
            fn lt(_: void, x: ath9k.Sample, y: ath9k.Sample) bool {
                return x.tsf_us < y.tsf_us;
            }
        }.lt);
        const ov = try detect.analyse(a, off.items, .{});
        rest = if (ov.kind == .microwave_pulsed or ov.kind == .continuous_wideband or ov.kind == .not_enough_data) .unclassified else ov.kind;
    }
    for (&out.class, 0..) |*c, k| if (bk.all[k] > 0) {
        const occ = @as(f32, @floatFromInt(bk.hot[k])) / @as(f32, @floatFromInt(bk.all[k]));
        const on_share = if (all_on[k] > 0) @as(f32, @floatFromInt(hot_on[k])) / @as(f32, @floatFromInt(all_on[k])) else 0;
        const off_share = if (all_off[k] > 0) @as(f32, @floatFromInt(hot_off[k])) / @as(f32, @floatFromInt(all_off[k])) else 0;
        // Its power is the synchronous excess, on-phase minus off-phase (what shares
        // the bucket), counted only when it stands 3 standard errors clear of the
        // bursts of whatever else is there.
        var excess: f64 = 0;
        if (all_on[k] > 1 and all_off[k] > 1) {
            const no: f64 = @floatFromInt(all_on[k]);
            const nf: f64 = @floatFromInt(all_off[k]);
            const mo = mw_on[k] / no;
            const mf = mw_off[k] / nf;
            const se = @sqrt(@max(0, sq_on[k] / no - mo * mo) / no + @max(0, sq_off[k] / nf - mf * mf) / nf);
            if (mo - mf > 3 * se) excess = mo - mf;
        }
        c.* = if (excess > 0 and on_share >= 0.10 and on_share >= 2 * off_share + 0.05) .mains_pulsed else kindClass(rest, occ);
        if (c.* == .mains_pulsed) out.interferer_mw[k] = excess;
    };
    return out;
}

fn better(x: *const Channel, y: *const Channel) bool {
    if (@intFromEnum(x.impact) != @intFromEnum(y.impact)) return @intFromEnum(x.impact) < @intFromEnum(y.impact);
    const bx = x.occupied.? + if (x.traffic) |t| t.airtime else 0;
    const by = y.occupied.? + if (y.traffic) |t| t.airtime else 0;
    return bx < by;
}
fn pct(n: f32, d: f32) f32 {
    return if (d > 0) n / d * 100 else 0;
}
const Sum = struct { frames: f32 = 0, retries: f32 = 0, eligible: f32 = 0, bad: f32 = 0, watched: f32 = 0 };
fn sumTraffic(chs: *const [n_channels]Channel, a: Impact, b: Impact) Sum {
    var s = Sum{};
    for (chs) |ch| if (ch.impact == a or ch.impact == b) if (ch.traffic) |t| {
        s.frames += @floatFromInt(t.frames);
        s.bad += @floatFromInt(t.bad_fcs);
        s.watched += t.watched_s;
        if (t.retry) |x| {
            // Weight by frames: eligible frames are not kept per channel, frames are close.
            s.retries += x * @as(f32, @floatFromInt(t.frames));
            s.eligible += @floatFromInt(t.frames);
        }
    };
    return s;
}

/// "8-12", "6-7 and 13", "1-5 and 14" for the channels with this impact.
fn rangeText(buf: []u8, chs: *const [n_channels]Channel, imp: Impact) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    var runs: [n_channels][2]u8 = undefined;
    var n: usize = 0;
    for (chs) |ch| if (ch.impact == imp) {
        if (n > 0 and runs[n - 1][1] + 1 == ch.channel) runs[n - 1][1] = ch.channel else {
            runs[n] = .{ ch.channel, ch.channel };
            n += 1;
        }
    };
    for (runs[0..n], 0..) |run, i| {
        const sep = if (i == 0) "" else if (i + 1 == n) " and " else ", ";
        if (run[0] == run[1]) w.print("{s}{d}", .{ sep, run[0] }) catch {} else w.print("{s}{d}-{d}", .{ sep, run[0], run[1] }) catch {};
    }
    return w.buffered();
}

const verbose = false;

// --- Synthetic data for tests and the demo ------------------------------------------

/// A sweep of the `kitchen` scene: `seconds` per visit to each window, `rounds` times.
pub fn synthSweep(a: std.mem.Allocator, centres: []const u16, seconds: f32, rounds: usize, mains_on: bool, seed: u64) ![]ath9k.Stamped {
    var all: std.ArrayList(ath9k.Stamped) = .empty;
    var t0: u64 = 1_000_000_000;
    for (0..rounds) |round| for (centres, 0..) |f, k| {
        const seg = try (detect.Synth{ .scene = .kitchen, .freq_mhz = f, .seconds = seconds, .mains_on = mains_on, .seed = seed + round * 31 + k }).generate(a);
        defer a.free(seg);
        for (seg) |s| try all.append(a, .{ .s = s, .mono_ns = t0 + s.tsf_us * 1000 });
        t0 += @as(u64, @intFromFloat(seconds * 1e9)) + 20_000_000;
    };
    return all.toOwnedSlice(a);
}

test "kitchen sweep: the microwave blasts channels 6-13, grazes 14, spares 1-5" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = sweep.plan(.{}, 1);
    const xs = try synthSweep(a, p.windows.list(), 0.6, 3, true, 5);
    const end = xs[xs.len - 1].mono_ns + 1;
    const r = try analyse(a, xs, &.{}, xs[0].mono_ns, end, end);
    try std.testing.expect(r.blast != null);
    try std.testing.expectEqual(detect.Kind.microwave_pulsed, r.blast.?.kind);
    try std.testing.expectEqual(@as(?u8, 60), r.blast.?.mains_hz);
    if (verbose) for (r.channels) |ch| std.debug.print("ch{d:>2} win {?d} seen {d} floor {?d:.1} power {?d:.1} occ {?d:.2} | int {d} MHz {?d:.1} dBm over {?d:.1} time {?d:.2} -> {s}\n", .{ ch.channel, ch.window_mhz, ch.seen_mhz, ch.floor_dbm, ch.power_dbm, ch.occupied, ch.interferer_mhz, ch.interferer_dbm, ch.interferer_over_floor_db, ch.interferer_time, @tagName(ch.impact) });
    if (verbose) for (r.buckets, 0..) |b, k| if (b.class == .mains_pulsed) std.debug.print("{d}:{d:.1} ", .{ 2400 + k, 10 * std.math.log10(b.interferer_mw) });
    for (r.channels) |ch| {
        // The synthetic magnetron: a -46 dBm carrier sweeping 2450-2464 MHz and a
        // -70 dBm pedestal 8 MHz wide (sigma) around 2457, on half of each cycle.
        // Its synchronous energy is 2445-2470 MHz (the carrier at about -57 dBm per MHz,
        // the skirts falling off), plus a faint tail that reaches channel 14's window.
        const want: Impact = switch (ch.channel) {
            1...5 => .clean,
            6...13 => .blasted,
            else => .grazed,
        };
        if (ch.impact != want) std.debug.print("channel {d}: {s} (interferer {d} MHz, {?d:.1} dB over the floor, {?d:.2} of the time) want {s}\n{s}\n", .{ ch.channel, @tagName(ch.impact), ch.interferer_mhz, ch.interferer_over_floor_db, ch.interferer_time, @tagName(want), r.words });
        try std.testing.expectEqual(want, ch.impact);
        if (ch.impact == .blasted or ch.impact == .grazed) try std.testing.expect(ch.interferer_time.? > 0);
    }
    try std.testing.expect(std.mem.startsWith(u8, r.words, "microwave-like 60 Hz pulsing at 24"));
    try std.testing.expect(std.mem.indexOf(u8, r.words, "channels 6-13 blasted (up to ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.words, "14 grazed (") != null);
    try std.testing.expect(std.mem.endsWith(u8, r.words, "1-5 clean"));
    try std.testing.expect(r.blast.?.lo_mhz >= 2440 and r.blast.?.lo_mhz <= 2448);
    // The access points that share the microwave's windows are not painted as microwave.
    try std.testing.expect(r.buckets[2437 - 2400].class != .mains_pulsed);
    // Half-cycle pulsing: the interferer holds a blasted channel about half the time.
    try std.testing.expect(@abs(r.channels[9].interferer_time.? - 0.48) < 0.12);
    // The access points read as Wi-Fi where the microwave is not.
    try std.testing.expectEqual(Class.wifi_like, r.buckets[2412 - 2400].class);
    try std.testing.expect(r.best_channel.? == 1 or r.best_channel.? == 6);
    for (r.regions) |reg| try std.testing.expect(reg.dwells == 3);
}

test "kitchen sweep without the microwave: no blast, every channel clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = sweep.plan(.{}, 1);
    const xs = try synthSweep(a, p.windows.list(), 0.6, 2, false, 9);
    const end = xs[xs.len - 1].mono_ns + 1;
    const r = try analyse(a, xs, &.{}, xs[0].mono_ns, end, end);
    try std.testing.expectEqual(@as(?Blast, null), r.blast);
    for (r.channels) |ch| try std.testing.expectEqual(Impact.clean, ch.impact);
    try std.testing.expect(std.mem.startsWith(u8, r.words, "no microwave-like interference in the band; busiest channel "));
}

test "phase location is the five-second union of a swept carrier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = sweep.plan(.{}, 1);
    const from: u64 = 1_000_000_000;
    var xs: std.ArrayList(ath9k.Stamped) = .empty;
    const offsets = [_]f32{ -12, 0, 10 };
    for (offsets, 0..) |offset, window| {
        const window_start = from + window * location_window_ns;
        for (p.windows.list(), 0..) |f, dwell| {
            const seg = try (detect.Synth{ .scene = .kitchen, .freq_mhz = f, .rate_hz = 1200, .seconds = 0.7, .mains_on = true, .microwave_offset_mhz = offset, .seed = 200 + window * 17 + dwell }).generate(a);
            for (seg) |s| try xs.append(a, .{ .s = s, .mono_ns = window_start + dwell * 750_000_000 + s.tsf_us * 1000 });
        }
    }
    // The final 500 ms models a phase ending between scheduled lines. It is
    // too short to resolve mains pulsing and must not count as a fourth view.
    const to = from + offsets.len * location_window_ns + 500_000_000;
    const r = try analyseWindowed(a, xs.items, &.{}, from, to, to, null);
    try std.testing.expectEqual(@as(u16, 3), r.location_windows_total);
    try std.testing.expectEqual(@as(u16, 3), r.location_windows_pulsing);
    // One deliberately marginal shifted window stays unresolved; the phase
    // reports that instead of inventing a location for it.
    try std.testing.expectEqual(@as(u16, 2), r.location_windows_located);
    try std.testing.expect(r.blast.?.lo_mhz <= 2440);
    try std.testing.expect(r.blast.?.hi_mhz >= 2472);
    try std.testing.expect(r.channels[5].impact != .clean); // lower sweep reaches channel 6
    try std.testing.expect(r.channels[12].impact != .clean); // upper sweep reaches channel 13
    try std.testing.expect(std.mem.indexOf(u8, r.words, "swept across") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.words, "2/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.words, "pulsing in 3/3") != null);
}

test "whole-window pulse with no bucket proof reports unresolved location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = sweep.plan(.{}, 1);
    const xs = try synthSweep(a, p.windows.list(), 0.2, 1, true, 71);
    const end = xs[xs.len - 1].mono_ns + 1;
    const known = detect.Verdict{ .kind = .microwave_pulsed, .mains_hz = 60, .duty = 0.45 };
    const r = try analyseKnown(a, xs, &.{}, xs[0].mono_ns, end, end, &known);
    try std.testing.expect(r.pulsing);
    try std.testing.expectEqual(@as(?Blast, null), r.blast);
    try std.testing.expect(std.mem.indexOf(u8, r.words, "location unresolved this window") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.words, "no microwave-like") == null);
}

test "a fixed window leaves far channels unwatched, and says so" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const xs = try synthSweep(a, &.{2457}, 2, 1, true, 3);
    const end = xs[xs.len - 1].mono_ns + 1;
    const r = try analyse(a, xs, &.{}, xs[0].mono_ns, end, end);
    try std.testing.expectEqual(Impact.unseen, r.channels[0].impact);
    try std.testing.expectEqual(Impact.blasted, r.channels[9].impact);
    try std.testing.expect(std.mem.indexOf(u8, r.words, "channels 1-8 and 12-14 not watched in this window") != null);
}

test "traffic per channel: rates, retries, bad FCS and distinct counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key: [16]u8 = @splat(1);
    var dwells: [4]radiotap.Dwell = undefined;
    var b: [64]u8 = undefined;
    for (&dwells, 0..) |*d, i| {
        d.* = .{ .channel = if (i < 2) 6 else 11, .from_ns = i * 250_000_000, .to_ns = (i + 1) * 250_000_000 };
        for (0..50) |j| {
            var s = radiotap.Synth{ .retry = i >= 2 and j % 2 == 0, .bad_fcs = i >= 2 and j % 10 == 0 };
            s.a2[5] = @intCast(j % 4);
            const e = s.encode(&b);
            d.add(&radiotap.parse(e.bytes, e.wire).?, &key);
        }
    }
    const r = try analyse(a, &.{}, &dwells, 0, 1_000_000_000, 1_000_000_000);
    const t6 = r.channels[5].traffic.?;
    try std.testing.expectEqual(@as(u32, 100), t6.frames);
    try std.testing.expect(@abs(t6.frames_ps - 200) < 0.1);
    try std.testing.expectEqual(@as(?f32, 0), t6.retry);
    try std.testing.expectEqual(@as(u32, 4), t6.stations);
    try std.testing.expectEqual(@as(u32, 1), t6.networks);
    const t11 = r.channels[10].traffic.?;
    try std.testing.expect(t11.retry.? > 0.4 and t11.bad_fcs == 10);
    try std.testing.expectEqual(@as(?Traffic, null), r.channels[0].traffic);
    try std.testing.expect(std.mem.startsWith(u8, r.traffic_words, "traffic: "));
}
