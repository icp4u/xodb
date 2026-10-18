//! Burrito mode's detector: is it the microwave? Pure analysis of spectral
//! samples (any source that gives power per bin with a timestamp).
//!
//! A transformer microwave's magnetron runs on one half of each mains cycle:
//! bursts around 2.45 GHz at 50 or 60 Hz, roughly half duty. The detector
//! measures, in this order: which samples carry energy above the noise
//! floor, how that on/off series repeats (autocorrelation at the 50 and 60 Hz
//! periods and their second multiple), the duty cycle, the band the energy
//! occupies and the Wi-Fi channels it overlaps, and the shape of each
//! emission (narrow and hopping like Bluetooth, a 20 MHz block like Wi-Fi).
//! Confidence comes from those measurements. Continuous wideband energy
//! without the pulsing is reported as "pulsing not seen" (an inverter
//! microwave looks like that), never as "no microwave".
const std = @import("std");
const ath9k = @import("ath9k.zig");
const Sample = ath9k.Sample;

pub const Kind = enum {
    not_enough_data,
    quiet,
    microwave_pulsed,
    continuous_wideband,
    bluetooth_like,
    wifi_like,
    unclassified,
};

/// Measured from the samples; every figure the words cite is here.
pub const Verdict = struct {
    kind: Kind = .not_enough_data,
    confidence: f32 = 0,
    samples: u32 = 0,
    duration_s: f32 = 0,
    rate_hz: f32 = 0,
    /// Time slot of the on/off series, microseconds.
    slot_us: u32 = 0,
    /// Fraction of slots holding at least one sample.
    coverage: f32 = 0,
    /// Gaps between samples were treated as quiet (sparse delivery).
    presence: bool = false,
    /// Mains pulsing is resolvable at this sample rate.
    resolvable: bool = false,
    floor_dbm: f32 = 0,
    /// Fraction of samples with energy above the floor.
    active: f32 = 0,
    /// Autocorrelation of the on/off series at the 60 and 50 Hz periods and at twice them.
    r60: f32 = 0,
    r50: f32 = 0,
    r60x2: f32 = 0,
    r50x2: f32 = 0,
    /// ... and at half of them: a half-wave magnetron is off there (negative),
    /// a 100/120 Hz frame source is on again (positive).
    r60half: f32 = 0,
    r50half: f32 = 0,
    mains_hz: ?u8 = null,
    duty: ?f32 = null,
    observed_lo_mhz: f32 = 0,
    observed_hi_mhz: f32 = 0,
    band_lo_mhz: ?f32 = null,
    band_hi_mhz: ?f32 = null,
    /// Median occupied width of one active sample, MHz.
    width_mhz: f32 = 0,
    /// Spread (standard deviation) of the active samples' peak frequency, MHz.
    hop_mhz: f32 = 0,
    /// Wi-Fi 2.4 GHz channels 1..14 overlapped by the band (bit c).
    channels: u16 = 0,

    pub fn channelRange(self: *const Verdict) ?[2]u8 {
        if (self.channels == 0) return null;
        return .{ @ctz(self.channels), 15 - @clz(self.channels) };
    }

    /// The verdict in words.
    pub fn words(self: *const Verdict, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        self.write(&w) catch {};
        return w.buffered();
    }
    fn write(self: *const Verdict, w: *std.Io.Writer) !void {
        var cb: [32]u8 = undefined;
        const ch = self.channelText(&cb);
        const lo = self.band_lo_mhz orelse self.observed_lo_mhz;
        const hi = self.band_hi_mhz orelse self.observed_hi_mhz;
        switch (self.kind) {
            .not_enough_data => try w.print("not enough spectrum yet ({d} samples over {d:.1} s)", .{ self.samples, self.duration_s }),
            .quiet => try w.print("quiet: nothing above the noise floor ({d:.0} dBm)", .{self.floor_dbm}),
            .microwave_pulsed => try w.print("microwave-like interference: {d} Hz pulsing, ~{d:.0}% duty, {d:.0}-{d:.0} MHz{s}", .{ self.mains_hz.?, self.duty.? * 100, lo, hi, ch }),
            .continuous_wideband => try w.print("continuous wideband energy {d:.0}-{d:.0} MHz{s}; mains pulsing not seen (an inverter microwave, video sender or other continuous source)", .{ lo, hi, ch }),
            .bluetooth_like => try w.print("narrowband hopping {d:.0}-{d:.0} MHz (Bluetooth-like); no mains pulsing", .{ lo, hi }),
            .wifi_like => try w.print("Wi-Fi-like bursts {d:.0}-{d:.0} MHz{s}; no mains pulsing", .{ lo, hi, ch }),
            .unclassified => try w.print("activity {d:.0}-{d:.0} MHz in {d:.0}% of samples, no mains pulsing; not classified", .{ lo, hi, self.active * 100 }),
        }
        if (self.kind != .not_enough_data and !self.resolvable and self.kind != .quiet)
            try w.print("; {d:.0} samples/s is too slow to see mains pulsing", .{self.rate_hz});
        if (self.kind != .not_enough_data and self.observed_hi_mhz - self.observed_lo_mhz < 90)
            try w.print(" (observed {d:.0}-{d:.0} MHz only)", .{ self.observed_lo_mhz, self.observed_hi_mhz });
    }
    fn channelText(self: *const Verdict, buf: []u8) []const u8 {
        const r = self.channelRange() orelse return "";
        return (if (r[0] == r[1]) std.fmt.bufPrint(buf, " (Wi-Fi channel {d})", .{r[0]}) else std.fmt.bufPrint(buf, " (Wi-Fi channels {d}-{d})", .{ r[0], r[1] })) catch "";
    }
};

pub const Options = struct {
    /// dB above the floor that counts as energy.
    on_db: f32 = 8,
    min_samples: u32 = 200,
};

/// dBm (i8) to milliwatts.
pub const linear = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]f64 = undefined;
    for (0..256) |i| t[i] = std.math.pow(f64, 10, @as(f64, @floatFromInt(@as(i8, @bitCast(@as(u8, @intCast(i)))))) / 10);
    break :blk t;
};

/// Wi-Fi channel centre, MHz (2.4 GHz band).
pub fn channelMhz(c: u8) f32 {
    return if (c == 14) 2484 else 2407 + 5 * @as(f32, @floatFromInt(c));
}

/// Per 1 MHz bucket from 2400 MHz: what the samples showed there. Filled by
/// `analyseBuckets` for the channel view (channels.zig).
pub const n_buckets = 100;
pub const Buckets = struct {
    /// Samples whose window covered the bucket.
    all: [n_buckets]u32 = @splat(0),
    /// Active samples (energy above the floor) whose emission covered the bucket
    /// (within 10 dB of the sample's peak): the detector's occupied band.
    hot: [n_buckets]u32 = @splat(0),
    /// Sum of bin power (mW) and bin count in the bucket, for mean power.
    mw: [n_buckets]f64 = @splat(0),
    bins: [n_buckets]u32 = @splat(0),
    /// The floor the detector used for these samples, dBm.
    floor_dbm: f32 = 0,
};

/// Analyses `samples` (oldest first, one card's clock). `scratch` holds
/// temporary arrays; nothing is retained.
pub fn analyse(scratch: std.mem.Allocator, samples: []const Sample, o: Options) !Verdict {
    return analyseBuckets(scratch, samples, o, null);
}

/// `analyse`, also filling `out` (per-bucket coverage, occupancy and power).
pub fn analyseBuckets(scratch: std.mem.Allocator, samples: []const Sample, o: Options, out: ?*Buckets) !Verdict {
    var v = Verdict{ .samples = @intCast(samples.len) };
    if (samples.len == 0) return v;
    v.observed_lo_mhz = std.math.floatMax(f32);
    v.observed_hi_mhz = 0;
    for (samples) |*s| {
        v.observed_lo_mhz = @min(v.observed_lo_mhz, @as(f32, @floatFromInt(s.freq_mhz)) - 10);
        v.observed_hi_mhz = @max(v.observed_hi_mhz, @as(f32, @floatFromInt(s.freq_mhz)) + 10);
    }
    // Times on the device clock. Per-CPU relay files interleave slightly out
    // of order, so sort; a TSF that steps back by over 10 s (a card reset) starts over.
    const ordered = try scratch.dupe(Sample, samples);
    defer scratch.free(ordered);
    sortByTsf(ordered);
    // A TSF jump forward by over 10 minutes (more than the ring holds) is a
    // bad record or a reset too: starting over keeps the slot arrays bounded.
    var first: usize = 0;
    for (samples[1..], 1..) |s, i| if (s.tsf_us +| 10_000_000 < samples[i - 1].tsf_us or s.tsf_us -| samples[i - 1].tsf_us > 600_000_000) {
        first = i;
    };
    if (first > 0) {
        // Keep only what came after the reset, in arrival order, then sorted.
        const after = samples[first..];
        @memcpy(ordered[0..after.len], after);
        sortByTsf(ordered[0..after.len]);
    }
    const use = ordered[0 .. samples.len - first];
    v.samples = @intCast(use.len);
    const t0 = use[0].tsf_us;
    const span_us = use[use.len - 1].tsf_us - t0;
    v.duration_s = @as(f32, @floatFromInt(span_us)) / 1e6;
    if (use.len < o.min_samples or span_us < 500_000) return v;
    v.rate_hz = @as(f32, @floatFromInt(use.len - 1)) / v.duration_s;

    // Floor: the quieter tenth of total power, capped by the hardware's noise floor.
    const totals = try scratch.alloc(f32, use.len);
    defer scratch.free(totals);
    const noises = try scratch.alloc(f32, use.len);
    defer scratch.free(noises);
    for (use, totals, noises) |*s, *t, *nz| {
        t.* = s.total();
        nz.* = @floatFromInt(s.noise);
    }
    const sorted = try scratch.dupe(f32, totals);
    defer scratch.free(sorted);
    std.mem.sortUnstable(f32, sorted, {}, std.sort.asc(f32));
    std.mem.sortUnstable(f32, noises, {}, std.sort.asc(f32));
    v.floor_dbm = @min(sorted[sorted.len / 10], noises[noises.len / 2] + 3);
    const on_at = v.floor_dbm + o.on_db;
    const bin_floor = v.floor_dbm - 10 * std.math.log10(@as(f32, ath9k.bins)) + 6;
    if (out) |b| {
        b.floor_dbm = v.floor_dbm;
        for (use) |*s| {
            var covered: [n_buckets]bool = @splat(false);
            for (s.power, 0..) |p, i| {
                const f = s.binMhz(i);
                if (f < 2400 or f >= 2500) continue;
                const k: usize = @intFromFloat(f - 2400);
                covered[k] = true;
                b.mw[k] += linear[@as(u8, @bitCast(p))];
                b.bins[k] += 1;
            }
            for (covered, &b.all) |cv, *x| x.* += @intFromBool(cv);
        }
    }

    // Shape of each active sample: bins within 10 dB of its peak and above the floor.
    const buckets = 100; // 1 MHz from 2400
    var hot: [buckets]u32 = @splat(0);
    var seen: [buckets]u32 = @splat(0);
    const widths = try scratch.alloc(f32, use.len);
    defer scratch.free(widths);
    var n_on: usize = 0;
    var peak_sum: f64 = 0;
    var peak_sq: f64 = 0;
    for (use, totals) |*s, t| {
        if (t < on_at) continue;
        var top: i8 = -128;
        var top_i: usize = 0;
        for (s.power, 0..) |p, i| if (p > top) {
            top = p;
            top_i = i;
        };
        var count: u32 = 0;
        var marked: [buckets]bool = @splat(false);
        var covered: [buckets]bool = @splat(false);
        for (s.power, 0..) |p, i| {
            const f = s.binMhz(i);
            if (f < 2400 or f >= 2500) continue;
            const b: usize = @intFromFloat(f - 2400);
            covered[b] = true;
            if (@as(f32, @floatFromInt(p)) >= @max(@as(f32, @floatFromInt(top)) - 10, bin_floor)) {
                count += 1;
                marked[b] = true;
            }
        }
        for (marked, covered, &hot, &seen) |mk, cv, *hh, *ss| {
            hh.* += @intFromBool(mk);
            ss.* += @intFromBool(cv);
        }
        if (out) |b| for (marked, &b.hot) |mk, *x| {
            x.* += @intFromBool(mk);
        };
        widths[n_on] = @as(f32, @floatFromInt(count)) * ath9k.bin_mhz;
        // Relative to the window centre, so hopping across channels does not read as spread.
        const pf: f64 = s.binMhz(top_i) - @as(f32, @floatFromInt(s.freq_mhz));
        peak_sum += pf;
        peak_sq += pf * pf;
        n_on += 1;
    }
    v.active = @as(f32, @floatFromInt(n_on)) / @as(f32, @floatFromInt(use.len));
    if (n_on > 0) {
        std.mem.sortUnstable(f32, widths[0..n_on], {}, std.sort.asc(f32));
        v.width_mhz = widths[n_on / 2];
        const mean = peak_sum / @as(f64, @floatFromInt(n_on));
        v.hop_mhz = @floatCast(std.math.sqrt(@max(0, peak_sq / @as(f64, @floatFromInt(n_on)) - mean * mean)));
        for (hot, seen, 0..) |hh, ss, b| {
            if (ss == 0 or @as(f32, @floatFromInt(hh)) < 0.10 * @as(f32, @floatFromInt(ss))) continue;
            const f: f32 = 2400 + @as(f32, @floatFromInt(b));
            if (v.band_lo_mhz == null) v.band_lo_mhz = f;
            v.band_hi_mhz = f + 1;
        }
        if (v.band_lo_mhz) |lo| for (1..15) |c| {
            const cf = channelMhz(@intCast(c));
            const overlap = @min(cf + 10, v.band_hi_mhz.?) - @max(cf - 10, lo);
            if (overlap >= 2) v.channels |= @as(u16, 1) << @intCast(c);
        };
    }

    // The on/off series in slots; mains periods must span several slots.
    const gaps = try scratch.alloc(u64, use.len - 1);
    defer scratch.free(gaps);
    for (gaps, 0..) |*g, i| g.* = use[i + 1].tsf_us - use[i].tsf_us;
    std.mem.sortUnstable(u64, gaps, {}, std.sort.asc(u64));
    const median_gap = gaps[gaps.len / 2];
    v.slot_us = @intCast(std.math.clamp(2 * median_gap, 250, 1_000_000));
    v.resolvable = v.slot_us <= 4000;
    const slots: usize = @intCast(span_us / v.slot_us + 1);
    if (slots > 1 << 24) return v;
    const sum = try scratch.alloc(f32, slots);
    defer scratch.free(sum);
    const cnt = try scratch.alloc(u16, slots);
    defer scratch.free(cnt);
    @memset(sum, 0);
    @memset(cnt, 0);
    for (use, totals) |*s, t| {
        const k: usize = @intCast((s.tsf_us - t0) / v.slot_us);
        sum[k] += @floatFromInt(@intFromBool(t >= on_at));
        cnt[k] +|= 1;
    }
    var filled: usize = 0;
    for (cnt) |c| filled += @intFromBool(c > 0);
    v.coverage = @as(f32, @floatFromInt(filled)) / @as(f32, @floatFromInt(slots));
    // Two readings of the series: gaps unknown (dense delivery), and gaps
    // quiet (hardware that reports mostly when there is energy). The one
    // with the stronger mains periodicity is used, and the verdict says which.
    const x = try scratch.alloc(f32, slots);
    defer scratch.free(x);
    var pick = Periodicity{};
    for ([_]bool{ false, true }) |presence| {
        if (presence and v.coverage >= 0.95) break;
        for (x, sum, cnt) |*xx, s, c| xx.* = if (presence) @floatFromInt(@intFromBool(s > 0)) else if (c > 0) s / @as(f32, @floatFromInt(c)) else std.math.nan(f32);
        const got = periodicity(x, v.slot_us, v.resolvable);
        if (!presence or @max(got.r60, got.r50) > @max(pick.r60, pick.r50) + 0.1) {
            pick = got;
            v.presence = presence;
        }
    }
    v.r60 = pick.r60;
    v.r50 = pick.r50;
    v.r60x2 = pick.r60x2;
    v.r50x2 = pick.r50x2;
    v.r60half = pick.r60half;
    v.r50half = pick.r50half;
    const duty = pick.duty;

    // Classify from the measurements, mains pulsing first.
    const best60 = v.r60 >= v.r50;
    const best = @max(v.r60, v.r50);
    const other = @min(v.r60, v.r50);
    const harmonic = if (best60) v.r60x2 else v.r50x2;
    const half = if (best60) v.r60half else v.r50half;
    const period_s: f32 = if (best60) 1.0 / 60.0 else 1.0 / 50.0;
    const periods = v.duration_s / period_s;
    const occupied = if (v.band_lo_mhz) |lo| v.band_hi_mhz.? - lo else 0;
    // Delivery quality: real AR9271 delivery fills ~70% of slots, which is plenty.
    const quality: f32 = if (v.presence) 0.9 else @min(1, v.coverage / 0.6);
    if (v.active < 0.02 or n_on < 10) {
        v.kind = .quiet;
        v.confidence = @min(1, v.duration_s / 5) * quality;
    } else if (v.resolvable and best >= 0.35 and best - other >= 0.15 and harmonic >= 0.2 and half < 0.5 * best and periods >= 20 and duty >= 0.1 and duty <= 0.9) {
        v.kind = .microwave_pulsed;
        v.mains_hz = if (best60) 60 else 50;
        v.duty = duty;
        // Calibrated on a real transformer microwave through a floor (r60 0.69 vs r50 0.28):
        // a clear peak (r >= 0.6) well above the other mains period, over 60 periods, reads 1.
        v.confidence = std.math.clamp((best - 0.2) / 0.4, 0, 1) * std.math.clamp((best - other) / 0.3, 0, 1) * @min(1, periods / 60) * quality * (if (occupied >= 4) @as(f32, 1) else 0.6);
    } else if (v.active >= 0.85 and v.width_mhz >= 3 and occupied >= 5) {
        v.kind = .continuous_wideband;
        v.confidence = std.math.clamp(0.5 + (v.active - 0.85) / 0.3, 0, 1) * @min(1, v.duration_s / 3);
    } else if (v.width_mhz <= 2.5 and v.hop_mhz >= 2.5) {
        v.kind = .bluetooth_like;
        v.confidence = std.math.clamp(@as(f32, @floatFromInt(n_on)) / 200, 0, 1) * std.math.clamp(v.hop_mhz / 5, 0, 1);
    } else if (v.width_mhz >= 8 and v.active < 0.85) {
        v.kind = .wifi_like;
        v.confidence = std.math.clamp(@as(f32, @floatFromInt(n_on)) / 200, 0, 1) * std.math.clamp(v.width_mhz / 16, 0, 1);
    } else {
        v.kind = .unclassified;
        v.confidence = 0;
    }
    return v;
}

fn sortByTsf(xs: []Sample) void {
    var sorted = true;
    for (xs[1..], 1..) |x, i| if (x.tsf_us < xs[i - 1].tsf_us) {
        sorted = false;
        break;
    };
    if (sorted) return;
    std.mem.sortUnstable(Sample, xs, {}, struct {
        fn lt(_: void, x: Sample, y: Sample) bool {
            return x.tsf_us < y.tsf_us;
        }
    }.lt);
}

const Periodicity = struct { r60: f32 = 0, r50: f32 = 0, r60x2: f32 = 0, r50x2: f32 = 0, r60half: f32 = 0, r50half: f32 = 0, duty: f32 = 0 };
fn periodicity(x: []const f32, slot_us: u32, resolvable: bool) Periodicity {
    // Duty within the active stretches: 100 ms blocks that hold any energy,
    // so quiet time (or hopping to other channels) does not dilute it.
    const block: usize = @max(1, 100_000 / slot_us);
    var on: f64 = 0;
    var defined: f64 = 0;
    var start: usize = 0;
    while (start < x.len) : (start += block) {
        var bo: f64 = 0;
        var bd: f64 = 0;
        for (x[start..@min(x.len, start + block)]) |xx| if (!std.math.isNan(xx)) {
            bo += xx;
            bd += 1;
        };
        if (bd == 0 or bo / bd < 0.05) continue;
        on += bo;
        defined += bd;
    }
    var p = Periodicity{ .duty = if (defined > 0) @floatCast(on / defined) else 0 };
    if (!resolvable) return p;
    p.r60 = acfAt(x, 1e6 / 60.0, slot_us);
    p.r50 = acfAt(x, 1e6 / 50.0, slot_us);
    p.r60x2 = acfAt(x, 2e6 / 60.0, slot_us);
    p.r50x2 = acfAt(x, 2e6 / 50.0, slot_us);
    p.r60half = acfAt(x, 0.5e6 / 60.0, slot_us);
    p.r50half = acfAt(x, 0.5e6 / 50.0, slot_us);
    return p;
}

/// Normalised autocorrelation of `x` (NaN = no sample) at a lag of
/// `period_us`, best of the slots around it.
fn acfAt(x: []const f32, period_us: f64, slot_us: u32) f32 {
    const lag = period_us / @as(f64, @floatFromInt(slot_us));
    const base: usize = @intFromFloat(@floor(lag));
    var best: f32 = -1;
    var l = base -| 1;
    while (l <= base + 1) : (l += 1) {
        if (l == 0) continue;
        best = @max(best, acf(x, l));
    }
    return best;
}
fn acf(x: []const f32, lag: usize) f32 {
    if (lag >= x.len) return 0;
    var sa: f64 = 0;
    var sb: f64 = 0;
    var n: f64 = 0;
    for (x[0 .. x.len - lag], x[lag..]) |a, b| {
        if (std.math.isNan(a) or std.math.isNan(b)) continue;
        sa += a;
        sb += b;
        n += 1;
    }
    if (n < 16) return 0;
    const ma = sa / n;
    const mb = sb / n;
    var num: f64 = 0;
    var da: f64 = 0;
    var db: f64 = 0;
    for (x[0 .. x.len - lag], x[lag..]) |a, b| {
        if (std.math.isNan(a) or std.math.isNan(b)) continue;
        num += (a - ma) * (b - mb);
        da += (a - ma) * (a - ma);
        db += (b - mb) * (b - mb);
    }
    if (da <= 0 or db <= 0) return 0;
    return @floatCast(num / std.math.sqrt(da * db));
}

// --- Synthetic spectra -----------------------------------------------------------

/// Generates spectral samples for tests and the demo: a 20 MHz window,
/// the noise floor, and the chosen emitters. Deterministic for a seed.
pub const Synth = struct {
    /// `kitchen` is the whole band at once: access points on channels 1, 6
    /// and 11, a Bluetooth device, and a 60 Hz microwave while `mains_on`.
    pub const Scene = enum { empty, microwave60, microwave50, inverter, wifi, bluetooth, wifi_beacons, kitchen };
    scene: Scene,
    freq_mhz: u16 = 2457,
    rate_hz: f32 = 4000,
    seconds: f32 = 3,
    noise: i8 = -95,
    /// Deliver only samples with energy plus a few noise samples (sparse hardware).
    sparse: bool = false,
    seed: u64 = 1,
    /// kitchen: the microwave runs.
    mains_on: bool = true,

    pub fn generate(self: Synth, a: std.mem.Allocator) ![]Sample {
        var prng = std.Random.DefaultPrng.init(self.seed);
        const r = prng.random();
        var out: std.ArrayList(Sample) = .empty;
        errdefer out.deinit(a);
        const dt: f32 = 1e6 / self.rate_hz;
        const n: usize = @intFromFloat(self.seconds * self.rate_hz);
        const noise_mw = std.math.pow(f64, 10, @as(f64, @floatFromInt(self.noise)) / 10) / ath9k.bins;
        // Wi-Fi bursts and Bluetooth slots as (start, end, centre).
        var burst_end: f32 = 0;
        var next_burst: f32 = 0;
        var bt_slot: i64 = -1;
        var bt_on = false;
        var bt_f: f32 = 0;
        // kitchen: three access points (centre, dBm, mean gap between bursts in us).
        const aps = [3][3]f32{ .{ 2412, -60, 9000 }, .{ 2437, -52, 3500 }, .{ 2462, -63, 14000 } };
        var ap_end: [3]f32 = @splat(0);
        var ap_next: [3]f32 = .{ 100, 1700, 3100 };
        var t: f32 = 1000;
        for (0..n) |_| {
            t += dt * (0.9 + 0.2 * r.float(f32));
            var mw: [ath9k.bins]f64 = undefined;
            for (&mw) |*w| w.* = noise_mw * (0.7 + 0.6 * r.float(f64));
            var energy = false;
            const s0 = Sample{ .tsf_us = 0, .freq_mhz = self.freq_mhz, .rssi = 0, .noise = 0, .power = undefined };
            switch (self.scene) {
                .empty => {},
                .microwave60, .microwave50 => {
                    const period: f32 = if (self.scene == .microwave60) 1e6 / 60.0 else 1e6 / 50.0;
                    const phase = @mod(t, period) / period;
                    if (phase < 0.48) {
                        // The carrier sweeps upward through the half cycle, with a pedestal.
                        const fc = 2450 + 14 * phase / 0.48;
                        add(&mw, &s0, fc, 1.5, -48);
                        add(&mw, &s0, 2457, 8, -72);
                        energy = true;
                    }
                },
                .inverter => {
                    add(&mw, &s0, 2452 + 12 * r.float(f32), 2, -52);
                    add(&mw, &s0, 2457, 8, -70);
                    energy = true;
                },
                .wifi, .wifi_beacons => {
                    if (self.scene == .wifi and t >= next_burst) {
                        burst_end = t + 200 + 1300 * r.float(f32);
                        next_burst = burst_end + 500 + 6000 * r.float(f32);
                    }
                    if (self.scene == .wifi_beacons and @mod(t, 102400) < 400) burst_end = t + 1;
                    if (t < burst_end) {
                        flat(&mw, &s0, 2462, 8.3, -58);
                        energy = true;
                    }
                },
                .kitchen => {
                    for (aps, &ap_end, &ap_next) |ap, *end, *next| {
                        if (t >= next.*) {
                            end.* = t + 150 + 1200 * r.float(f32);
                            next.* = end.* + ap[2] * (0.3 + 1.4 * r.float(f32));
                        }
                        if (t < end.* and @abs(ap[0] - @as(f32, @floatFromInt(self.freq_mhz))) < 20) {
                            flat(&mw, &s0, ap[0], 8.3, ap[1]);
                            energy = true;
                        }
                    }
                    const slot: i64 = @intFromFloat(t / 625);
                    if (slot != bt_slot) {
                        bt_slot = slot;
                        bt_on = r.float(f32) < 0.25;
                        bt_f = 2402 + @as(f32, @floatFromInt(r.uintLessThan(u8, 79)));
                    }
                    if (bt_on and @abs(bt_f - @as(f32, @floatFromInt(self.freq_mhz))) < 10) {
                        add(&mw, &s0, bt_f, 0.4, -62);
                        energy = true;
                    }
                    if (self.mains_on and @mod(t, 1e6 / 60.0) / (1e6 / 60.0) < 0.48) {
                        const phase = @mod(t, 1e6 / 60.0) / (1e6 / 60.0);
                        add(&mw, &s0, 2450 + 14 * phase / 0.48, 1.5, -46);
                        add(&mw, &s0, 2457, 8, -70);
                        energy = true;
                    }
                },
                .bluetooth => {
                    const slot: i64 = @intFromFloat(t / 625);
                    if (slot != bt_slot) {
                        bt_slot = slot;
                        bt_on = r.float(f32) < 0.6;
                        bt_f = 2402 + @as(f32, @floatFromInt(r.uintLessThan(u8, 79)));
                    }
                    if (bt_on and @abs(bt_f - @as(f32, @floatFromInt(self.freq_mhz))) < 10) {
                        add(&mw, &s0, bt_f, 0.4, -55);
                        energy = true;
                    }
                },
            }
            if (self.sparse and !energy and r.float(f32) > 0.02) continue;
            var rec: [3 + ath9k.ht20_len]u8 = undefined;
            ath9k.encode(&rec, @intFromFloat(t), self.freq_mhz, self.noise, &mw);
            var one: [1]Sample = undefined;
            var got: usize = 0;
            var counts = ath9k.Counts{};
            _ = ath9k.parse(&rec, 0, &one, &got, &counts);
            try out.append(a, one[0]);
        }
        return out.toOwnedSlice(a);
    }
    fn add(mw: *[ath9k.bins]f64, s: *const Sample, fc: f32, sigma: f32, dbm: f32) void {
        var shape: [ath9k.bins]f64 = undefined;
        for (&shape, 0..) |*w, i| {
            const d = (s.binMhz(i) - fc) / sigma;
            w.* = @exp(-0.5 * d * d);
        }
        // The emitter's whole power over its full width: a window sees only its share.
        const total: f64 = sigma * @sqrt(2 * std.math.pi) / ath9k.bin_mhz;
        const p = std.math.pow(f64, 10, dbm / 10);
        for (mw, shape) |*m, w| m.* += p * w / total;
    }
    fn flat(mw: *[ath9k.bins]f64, s: *const Sample, fc: f32, half: f32, dbm: f32) void {
        const k: f64 = 2 * half / ath9k.bin_mhz;
        const p = std.math.pow(f64, 10, dbm / 10) / k;
        for (mw, 0..) |*m, i| if (@abs(s.binMhz(i) - fc) <= half) {
            m.* += p;
        };
    }
};

const verbose = false;
fn run(scene: Synth.Scene, tweak: anytype) !Verdict {
    const a = std.testing.allocator;
    var synth = Synth{ .scene = scene };
    inline for (@typeInfo(@TypeOf(tweak)).@"struct".fields) |f| @field(synth, f.name) = @field(tweak, f.name);
    const samples = try synth.generate(a);
    defer a.free(samples);
    const v = try analyse(a, samples, .{});
    var b: [400]u8 = undefined;
    if (verbose) std.debug.print("{s}: {s}\n  conf={d:.2} r60={d:.2} r50={d:.2} active={d:.2} width={d:.1} hop={d:.1} cov={d:.2}", .{ @tagName(scene), v.words(&b), v.confidence, v.r60, v.r50, v.active, v.width_mhz, v.hop_mhz, v.coverage });
    return v;
}

test "60 Hz pulsed microwave" {
    const v = try run(.microwave60, .{});
    try std.testing.expectEqual(Kind.microwave_pulsed, v.kind);
    try std.testing.expectEqual(@as(?u8, 60), v.mains_hz);
    try std.testing.expect(@abs(v.duty.? - 0.48) < 0.08);
    try std.testing.expect(v.confidence > 0.6);
    try std.testing.expect(v.band_lo_mhz.? >= 2447 and v.band_hi_mhz.? <= 2467);
    const r = v.channelRange().?;
    try std.testing.expect(r[0] >= 7 and r[1] <= 13);
    var b: [400]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, v.words(&b), "microwave-like interference: 60 Hz pulsing, ~"));
}

test "50 Hz pulsed microwave, also with sparse delivery" {
    const v = try run(.microwave50, .{});
    try std.testing.expectEqual(Kind.microwave_pulsed, v.kind);
    try std.testing.expectEqual(@as(?u8, 50), v.mains_hz);
    const s = try run(.microwave50, .{ .sparse = true, .seed = 7 });
    try std.testing.expect(s.presence);
    try std.testing.expectEqual(Kind.microwave_pulsed, s.kind);
    try std.testing.expectEqual(@as(?u8, 50), s.mains_hz);
}

test "inverter microwave: continuous, pulsing not seen" {
    const v = try run(.inverter, .{});
    try std.testing.expectEqual(Kind.continuous_wideband, v.kind);
    try std.testing.expectEqual(@as(?u8, null), v.mains_hz);
    var b: [400]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, v.words(&b), "mains pulsing not seen") != null);
}

test "Wi-Fi only, and beacons, are not mains pulsing" {
    const v = try run(.wifi, .{});
    try std.testing.expectEqual(Kind.wifi_like, v.kind);
    try std.testing.expect(v.width_mhz >= 10);
    try std.testing.expect(v.channels & (1 << 11) != 0);
    const beacons = try run(.wifi_beacons, .{ .seconds = 4 });
    try std.testing.expect(beacons.kind != .microwave_pulsed);
}

test "Bluetooth-like hopping" {
    const v = try run(.bluetooth, .{});
    try std.testing.expectEqual(Kind.bluetooth_like, v.kind);
    try std.testing.expect(v.width_mhz <= 2.5);
}

test "empty band, too few samples, too slow to resolve" {
    const v = try run(.empty, .{});
    try std.testing.expectEqual(Kind.quiet, v.kind);
    const short = try run(.microwave60, .{ .seconds = 0.02 });
    try std.testing.expectEqual(Kind.not_enough_data, short.kind);
    const slow = try run(.microwave60, .{ .rate_hz = 150, .seconds = 6 });
    try std.testing.expect(!slow.resolvable);
    try std.testing.expect(slow.kind != .microwave_pulsed);
    var b: [400]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, slow.words(&b), "too slow to see mains pulsing") != null);
}

test "hopping across five channels still finds 60 Hz pulsing and the band" {
    const a = std.testing.allocator;
    var all: std.ArrayList(Sample) = .empty;
    defer all.deinit(a);
    const centres = [_]u16{ 2412, 2427, 2442, 2457, 2472 };
    var tsf: u64 = 0;
    for (0..2) |round| for (centres, 0..) |f, k| {
        // The magnetron sits near 2450-2464 MHz: visible only in the 2442 and 2457 windows.
        const scene: Synth.Scene = if (f == 2442 or f == 2457) .microwave60 else .empty;
        const seg = try (Synth{ .scene = scene, .freq_mhz = f, .seconds = 1.5, .seed = round * 10 + k }).generate(a);
        defer a.free(seg);
        for (seg) |s0| {
            var s = s0;
            s.tsf_us += tsf;
            try all.append(a, s);
        }
        tsf += 1_500_000;
    };
    const v = try analyse(a, all.items, .{});
    var b: [400]u8 = undefined;
    if (verbose) std.debug.print("hop: {s} r60={d:.2} r50={d:.2} r60x2={d:.2} active={d:.2} duty={?d:.2} band={?d}-{?d}\n", .{ v.words(&b), v.r60, v.r50, v.r60x2, v.active, v.duty, v.band_lo_mhz, v.band_hi_mhz });
    try std.testing.expectEqual(Kind.microwave_pulsed, v.kind);
    try std.testing.expectEqual(@as(?u8, 60), v.mains_hz);
    try std.testing.expect(v.observed_lo_mhz <= 2402 and v.observed_hi_mhz >= 2482);
    try std.testing.expect(v.band_lo_mhz.? >= 2430 and v.band_hi_mhz.? <= 2470);
    try std.testing.expect(@abs(v.duty.? - 0.48) < 0.08);
}
