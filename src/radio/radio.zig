//! Burrito mode: is it the microwave? Radio evidence for the overview, MCP
//! and `xodb --burrito`. Receive-only, always (docs/RADIO.md).
//!
//! Sources: an explicitly chosen spectral-capable card (ath9k spectral scan,
//! root) and the in-use Wi-Fi link read passively (nl80211 station/survey,
//! gateway ping). The detector (detect.zig) is pure; this file joins its
//! verdicts with the link on one clock (CLOCK_MONOTONIC) and words them.
const std = @import("std");
pub const ath9k = @import("ath9k.zig");
pub const detect = @import("detect.zig");
pub const nl80211 = @import("nl80211.zig");
pub const cards = @import("cards.zig");
pub const monitor = @import("monitor.zig");
pub const fsx = @import("fsx.zig");
pub const sweep = @import("sweep.zig");
pub const channels = @import("channels.zig");
pub const radiotap = @import("radiotap.zig");
pub const Monitor = monitor.Monitor;

/// The process's radio collector, shared by the overview panel and MCP.
pub var global: ?*Monitor = null;
var global_lock: monitor.Lock = .{};
/// Settings for a collector started on demand (passive unless `radio` is set by the CLI).
pub var defaults: monitor.Config = .{};

/// The shared collector, starting a passive one (no card taken) if none runs.
pub fn ensure(gpa: std.mem.Allocator) ?*Monitor {
    global_lock.lock();
    defer global_lock.unlock();
    if (global == null) global = Monitor.start(gpa, defaults) catch null;
    return global;
}
pub fn shutdown() void {
    global_lock.lock();
    const m = global;
    global = null;
    global_lock.unlock();
    if (m) |x| x.deinit();
}

pub const chunk_ns: u64 = 2_000_000_000;

pub const Chunk = struct { from_s: f32, kind: []const u8, mains_hz: ?u8, confidence: f32 };
pub const Ping = struct {
    sent: u32 = 0,
    lost: u32 = 0,
    loss: ?f32 = null,
    rtt_median_ms: ?f32 = null,
    rtt_p95_ms: ?f32 = null,
    during_sent: u32 = 0,
    during_lost: u32 = 0,
    outside_sent: u32 = 0,
    outside_lost: u32 = 0,
};
pub const Link = struct {
    iface: ?[]const u8 = null,
    why: []const u8 = "",
    signal_dbm: ?i8 = null,
    bitrate_mbps: ?f32 = null,
    retries_ps: ?f32 = null,
    failed_ps: ?f32 = null,
    busy: ?f32 = null,
    noise_dbm: ?i8 = null,
    samples: u32 = 0,
    gateway: ?[]const u8 = null,
    ping_why: []const u8 = "",
};
pub const Spectral = struct {
    on: bool = false,
    iface: ?[]const u8 = null,
    freq_mhz: ?u32 = null,
    samples: u64 = 0,
    window_samples: u32 = 0,
    rate_hz: f32 = 0,
    skipped: u64 = 0,
    malformed: u64 = 0,
    clock: []const u8 = "device TSF (us), mapped to CLOCK_MONOTONIC by the lower envelope of read time",
    clock_uncertainty_ms: ?f32 = null,
    /// TSF steps the host-clock mapping re-anchored on this session, and the latest delivery lag.
    tsf_steps: u32 = 0,
    lag_ms: f32 = 0,
    /// Spectral stream health: seconds since the last sample (with a card taken),
    /// the watchdog's re-triggers and full re-arms, samples held back for a bad TSF.
    silent_s: f32 = 0,
    retriggers: u32 = 0,
    rearms: u32 = 0,
    rejected: u64 = 0,
    /// The ring's reach: verdicts cover at most this much of the requested window.
    ring_s: f32 = 0,
};

/// "no spectral samples for 4 s (re-triggered 3 times, re-armed once)", or "".
pub fn stallWords(buf: []u8, h: ?monitor.Monitor.Health) []const u8 {
    const x = h orelse return "";
    if (x.silent_ms < 2000) return "";
    var w = std.Io.Writer.fixed(buf);
    w.print("no spectral samples for {d:.0} s (re-triggered {d} times, re-armed {d} times)", .{ @as(f32, @floatFromInt(x.silent_ms)) / 1000, x.retriggers, x.rearms }) catch {};
    if (x.busy_ms >= 500) w.print("; the collector has waited {d:.1} s on the driver: {s}", .{ @as(f32, @floatFromInt(x.busy_ms)) / 1000, x.busy_op.get() }) catch {};
    return w.buffered();
}
pub const Tx = struct { iface: []const u8, packets_before: u64, bytes_before: u64, packets_now: ?u64, bytes_now: ?u64, flat: bool };

pub const Report = struct {
    window_s: f32,
    words: []const u8,
    status: []const u8,
    kind: []const u8,
    confidence: f32,
    verdict: detect.Verdict,
    /// Where (seconds into the window) mains pulsing or continuous energy was seen.
    interference_from_s: ?f32 = null,
    interference_to_s: ?f32 = null,
    chunks: []const Chunk,
    link: Link,
    ping: Ping,
    spectral: Spectral,
    /// The first taken card's TX counters (all of them in tx_cards).
    tx: ?Tx,
    tx_cards: []const Tx = &.{},
    /// Where the sensors listen: "sweep 2402-2494 MHz: 6 windows ..." or a focus.
    plan: []const u8 = "",
    receive_only: []const u8 = "monitor mode; the spectral scan in background mode with trigger; channel changes are monitor channel changes; no scans, probes, association or injection",
};

/// Every taken card's TX counters at take time and now.
pub fn txList(a: std.mem.Allocator, m: *Monitor) ![]Tx {
    var buf: [8]monitor.TxEntry = undefined;
    const list = m.txReports(&buf);
    const out = try a.alloc(Tx, list.len);
    for (list, out) |r, *t| t.* = .{ .iface = try a.dupe(u8, r.iface.get()), .packets_before = r.before[0], .bytes_before = r.before[1], .packets_now = r.now[0], .bytes_now = r.now[1], .flat = (r.now[0] orelse r.before[0]) == r.before[0] and (r.now[1] orelse r.before[1]) == r.before[1] };
    return out;
}

/// Spectral samples for the detector: one card keeps its own clock (TSF);
/// several are put on the host clock they were mapped to.
fn detectorSamples(a: std.mem.Allocator, w: []const ath9k.Stamped) ![]ath9k.Sample {
    const out = try a.alloc(ath9k.Sample, w.len);
    // The host clock the samples were mapped to: one clock across sensors, and
    // continuous across a card's TSF steps (which the mapping re-anchors on).
    for (out, w) |*s, x| {
        s.* = x.s;
        s.tsf_us = x.mono_ns / 1000;
    }
    return out;
}

fn interfering(k: detect.Kind) bool {
    return k == .microwave_pulsed or k == .continuous_wideband;
}

/// Analyses the last `span_ns` of `m`. Strings live in `a` (an arena).
pub fn report(a: std.mem.Allocator, m: *Monitor, span_ns: u64, redact: bool) !Report {
    const now = fsx.monotonicNs();
    return reportBetween(a, m, now -| span_ns, now, redact);
}
/// Analyses [from_ns, to_ns) of `m` (CLOCK_MONOTONIC).
pub fn reportBetween(a: std.mem.Allocator, m: *Monitor, from_ns: u64, to_ns: u64, redact: bool) !Report {
    return reportBetweenMode(a, m, from_ns, to_ns, redact, false);
}
/// A phase report whose location is the union of its five-second views.
pub fn reportPhaseBetween(a: std.mem.Allocator, m: *Monitor, from_ns: u64, to_ns: u64, redact: bool) !Report {
    return reportBetweenMode(a, m, from_ns, to_ns, redact, true);
}
fn reportBetweenMode(a: std.mem.Allocator, m: *Monitor, from_ns: u64, to_ns: u64, redact: bool, windowed_location: bool) !Report {
    const span_ns = to_ns - from_ns;
    const w = try m.between(a, from_ns, to_ns);
    const samples = try detectorSamples(a, w.samples);
    var verdict = try detect.analyse(a, samples, .{});
    // Per-chunk verdicts on the monotonic clock.
    var chunks: std.ArrayList(Chunk) = .empty;
    var first_hit: ?usize = null;
    var last_hit: ?usize = null;
    var hit_kind: ?detect.Kind = null;
    var lo: usize = 0;
    var t = w.from_ns;
    while (t < w.to_ns) : (t += chunk_ns) {
        var hi = lo;
        while (hi < w.samples.len and w.samples[hi].mono_ns < t + chunk_ns) hi += 1;
        const v = try detect.analyse(a, samples[lo..hi], .{});
        try chunks.append(a, .{ .from_s = @as(f32, @floatFromInt(t - w.from_ns)) / 1e9, .kind = @tagName(v.kind), .mains_hz = v.mains_hz, .confidence = v.confidence });
        if (interfering(v.kind) and (hit_kind == null or v.kind == .microwave_pulsed)) {
            if (hit_kind != null and hit_kind.? != v.kind) first_hit = null;
            hit_kind = v.kind;
            if (first_hit == null) first_hit = lo;
            last_hit = hi;
        }
        lo = hi;
    }
    // Interference in part of the window: the verdict of that part, and where it was.
    var from_s: ?f32 = null;
    var to_s: ?f32 = null;
    var on_from: u64 = 0;
    var on_to: u64 = 0;
    if (first_hit) |f| {
        // Duty and confidence come from where the detection held, not diluted
        // by the quiet part of the window.
        const part = try detect.analyse(a, samples[f..last_hit.?], .{});
        if (interfering(part.kind) and (part.kind == .microwave_pulsed or verdict.kind != .microwave_pulsed)) verdict = part;
        on_from = w.samples[f].mono_ns;
        on_to = w.samples[last_hit.? - 1].mono_ns;
        from_s = @as(f32, @floatFromInt(on_from -| w.from_ns)) / 1e9;
        to_s = @as(f32, @floatFromInt(on_to -| w.from_ns)) / 1e9;
    }
    if (!interfering(verdict.kind)) {
        from_s = null;
        to_s = null;
    }
    // Sweeping: the window holds every emitter in the band, so the band and the
    // channels come from where the interferer's own energy is (channels.zig).
    var centres: u32 = 0;
    for (w.samples, 0..) |x, i| centres += @intFromBool(i == 0 or x.s.freq_mhz != w.samples[i - 1].s.freq_mhz);
    if (interfering(verdict.kind) and centres > 1) {
        const cr = if (windowed_location)
            try channels.analyseWindowed(a, w.samples, &.{}, from_ns, to_ns, to_ns, &verdict)
        else
            try channels.analyseKnown(a, w.samples, &.{}, from_ns, to_ns, to_ns, &verdict);
        verdict.location_windows_total = cr.location_windows_total;
        verdict.location_windows_pulsing = cr.location_windows_pulsing;
        verdict.location_windows_located = cr.location_windows_located;
        const located_same_source = if (cr.blast) |b| b.kind == verdict.kind else false;
        if (located_same_source) {
            const b = cr.blast.?;
            verdict.band_lo_mhz = @floatFromInt(b.lo_mhz);
            verdict.band_hi_mhz = @floatFromInt(b.hi_mhz);
            verdict.channels = 0;
            for (cr.channels) |ch| if (ch.impact == .blasted or ch.impact == .grazed) {
                verdict.channels |= @as(u16, 1) << @intCast(ch.channel);
            };
        } else if (verdict.kind == .microwave_pulsed) {
            verdict.location_resolved = false;
            verdict.band_lo_mhz = null;
            verdict.band_hi_mhz = null;
            verdict.channels = 0;
        }
    }

    // Ping, split by the interference interval.
    var ping = Ping{};
    var rtts: std.ArrayList(u32) = .empty;
    for (w.pings) |p| {
        ping.sent += 1;
        const lost = p.rtt_us == null;
        ping.lost += @intFromBool(lost);
        if (p.rtt_us) |r| try rtts.append(a, r);
        if (from_s != null and p.mono_ns >= on_from and p.mono_ns <= on_to) {
            ping.during_sent += 1;
            ping.during_lost += @intFromBool(lost);
        } else {
            ping.outside_sent += 1;
            ping.outside_lost += @intFromBool(lost);
        }
    }
    if (ping.sent > 0) ping.loss = @as(f32, @floatFromInt(ping.lost)) / @as(f32, @floatFromInt(ping.sent));
    if (rtts.items.len > 0) {
        std.mem.sortUnstable(u32, rtts.items, {}, std.sort.asc(u32));
        ping.rtt_median_ms = @as(f32, @floatFromInt(rtts.items[rtts.items.len / 2])) / 1000;
        ping.rtt_p95_ms = @as(f32, @floatFromInt(rtts.items[rtts.items.len * 95 / 100])) / 1000;
    }

    m.mutex.lock();
    var link = Link{ .why = try a.dupe(u8, m.link_why.get()), .ping_why = try a.dupe(u8, m.ping_why.get()), .samples = @intCast(w.links.len) };
    if (m.link_ifindex != 0) link.iface = try a.dupe(u8, m.link_iface.get());
    if (m.gateway) |g| link.gateway = if (redact) "redacted" else try std.fmt.allocPrint(a, "{d}.{d}.{d}.{d}", .{ g[0], g[1], g[2], g[3] });
    var spectral = Spectral{ .on = m.spectral_on, .samples = m.counts.samples, .skipped = m.counts.skipped, .malformed = m.counts.malformed, .window_samples = @intCast(w.samples.len), .rate_hz = verdict.rate_hz };
    if (m.spectral_iface.len > 0) spectral.iface = try a.dupe(u8, m.spectral_iface.get());
    if (m.freq_mhz != 0) spectral.freq_mhz = m.freq_mhz;
    if (m.tsf_offset_ns != null) spectral.clock_uncertainty_ms = @as(f32, @floatFromInt(m.tsf_spread_ns)) / 1e6;
    for (m.sensors[0..m.n_sensors]) |*sn| spectral.tsf_steps += sn.tsf_steps;
    spectral.lag_ms = @as(f32, @floatFromInt(m.sensors[0].lag_ns)) / 1e6;
    const status = try a.dupe(u8, m.status.get());
    const recovered = try a.dupe(u8, m.recovered.get());
    m.mutex.unlock();
    const tx_cards = try txList(a, m);
    const health = m.health();
    if (health) |h| {
        spectral.silent_s = @as(f32, @floatFromInt(h.silent_ms)) / 1000;
        spectral.retriggers = h.retriggers;
        spectral.rearms = h.rearms;
        spectral.rejected = h.rejected;
    }
    if (w.samples.len > 1 and w.samples[0].mono_ns > from_ns + 2_000_000_000 and m.ringFull()) spectral.ring_s = @as(f32, @floatFromInt(to_ns - w.samples[0].mono_ns)) / 1e9;
    const tx: ?Tx = if (tx_cards.len > 0) tx_cards[0] else null;
    const info = m.planInfo();
    var pb: [240]u8 = undefined;
    const plan = if (info.sensors > 0) try a.dupe(u8, info.plan.describe(&pb)) else "";
    if (w.links.len > 0) {
        const lp = w.links[w.links.len - 1];
        link.signal_dbm = lp.signal_dbm;
        link.bitrate_mbps = lp.bitrate;
        link.noise_dbm = lp.noise_dbm;
        var rs: f32 = 0;
        var fs: f32 = 0;
        var bs: f32 = 0;
        var n: f32 = 0;
        var nb: f32 = 0;
        for (w.links) |p| {
            if (p.retries_ps) |x| {
                rs += x;
                fs += p.failed_ps orelse 0;
                n += 1;
            }
            if (p.busy) |x| {
                bs += x;
                nb += 1;
            }
        }
        if (n > 0) {
            link.retries_ps = rs / n;
            link.failed_ps = fs / n;
        }
        if (nb > 0) link.busy = bs / nb;
    }

    // Words.
    var out: std.Io.Writer.Allocating = .init(a);
    const ww = &out.writer;
    var vb: [512]u8 = undefined;
    if (recovered.len > 0) try ww.print("{s}. ", .{recovered});
    var stall_buf: [240]u8 = undefined;
    const stall = stallWords(&stall_buf, health);
    if (stall.len > 0) try ww.print("{s}; ", .{stall});
    if (w.samples.len == 0) {
        try ww.print("no spectrum ({s})", .{status});
        if (ping.loss) |l| try ww.print("; link: {d:.0}% ping loss over the last {d:.0} s; a link-only view is consistent with interference but cannot name its source", .{ l * 100, @as(f32, @floatFromInt(span_ns)) / 1e9 });
    } else {
        try ww.print("{s}", .{verdict.words(&vb)});
        if (from_s) |f| try ww.print("; seen {d:.0}-{d:.0} s into the last {d:.0} s", .{ f, to_s.?, @as(f32, @floatFromInt(span_ns)) / 1e9 });
        if (info.sensors > 0 and info.plan.revisitMs() > 0) try ww.print("; {s}", .{plan});
        if (from_s != null and ping.during_sent >= 20) {
            const d = @as(f32, @floatFromInt(ping.during_lost)) / @as(f32, @floatFromInt(ping.during_sent));
            try ww.print("; your link lost {d:.0}% of pings while it ran", .{d * 100});
            if (ping.outside_sent >= 20) try ww.print(" ({d:.0}% otherwise)", .{@as(f32, @floatFromInt(ping.outside_lost)) * 100 / @as(f32, @floatFromInt(ping.outside_sent))});
        }
    }
    if (spectral.ring_s > 0) try ww.print("; spectrum covers only the last {d:.0} s of the {d:.0} s asked (the sample ring's reach)", .{ spectral.ring_s, @as(f32, @floatFromInt(span_ns)) / 1e9 });
    for (tx_cards) |x| if (!x.flat) try ww.print("; WARNING: {s} TX counters moved", .{x.iface});

    return .{
        .window_s = @as(f32, @floatFromInt(span_ns)) / 1e9,
        .words = out.written(),
        .status = status,
        .kind = if (w.samples.len == 0) "no_spectrum" else @tagName(verdict.kind),
        .confidence = if (w.samples.len == 0) 0 else verdict.confidence,
        .verdict = verdict,
        .interference_from_s = from_s,
        .interference_to_s = to_s,
        .chunks = chunks.items,
        .link = link,
        .ping = ping,
        .spectral = spectral,
        .tx = tx,
        .tx_cards = tx_cards,
        .plan = plan,
    };
}

pub const TrafficInfo = struct {
    on: bool,
    iface: ?[]const u8,
    why: []const u8,
    dwell_ms: u32,
    packets: u64,
    privacy: []const u8 = "counts only: addresses are hashed with a per-session random key as they are read, kept in memory to count distinct ones, and never stored or returned; SSIDs and frame bodies are not parsed",
};
pub const SweepInfo = struct { mode: []const u8, windows_mhz: []const u16, dwell_ms: u32, revisit_ms: u32, sensors: usize, watch_share: f32 };
pub const ChannelsOut = struct {
    window_s: f32,
    words: []const u8,
    traffic_words: []const u8,
    advice: []const u8,
    best_channel: ?u8,
    blast: ?channels.Blast,
    channels: []const channels.Channel,
    regions: []const channels.Region,
    plan: []const u8,
    sweep: ?SweepInfo,
    samples: u32,
    location_windows_total: u16,
    location_windows_pulsing: u16,
    location_windows_located: u16,
    status: []const u8,
    traffic: TrafficInfo,
    tx: []const Tx,
    receive_only: []const u8 = "monitor mode; channel changes are monitor channel changes; the packet socket is only read; no scans, probes, association or injection",
};

/// Per-channel power, occupancy, traffic and interferer impact over [from_ns, to_ns).
/// `full` keeps the per-bucket spectrum (the panel); MCP leaves it out.
pub fn channelsBetween(a: std.mem.Allocator, m: *Monitor, from_ns: u64, to_ns: u64, report_out: ?*channels.Report) !ChannelsOut {
    return channelsBetweenMode(a, m, from_ns, to_ns, report_out, false);
}
/// A phase channel report whose location is the union of five-second views.
pub fn channelsPhaseBetween(a: std.mem.Allocator, m: *Monitor, from_ns: u64, to_ns: u64, report_out: ?*channels.Report) !ChannelsOut {
    return channelsBetweenMode(a, m, from_ns, to_ns, report_out, true);
}
fn channelsBetweenMode(a: std.mem.Allocator, m: *Monitor, from_ns: u64, to_ns: u64, report_out: ?*channels.Report, windowed_location: bool) !ChannelsOut {
    const w = try m.between(a, from_ns, to_ns);
    const dwells = try m.dwellsBetween(a, from_ns, to_ns);
    const r = if (windowed_location)
        try channels.analyseWindowed(a, w.samples, dwells, from_ns, to_ns, fsx.monotonicNs(), null)
    else
        try channels.analyse(a, w.samples, dwells, from_ns, to_ns, fsx.monotonicNs());
    if (report_out) |o| o.* = r;
    const info = m.planInfo();
    var pb: [240]u8 = undefined;
    m.mutex.lock();
    const status = try a.dupe(u8, m.status.get());
    const t_on = m.traffic_on;
    const t_iface: ?[]const u8 = if (m.traffic_iface.len > 0) try a.dupe(u8, m.traffic_iface.get()) else null;
    const packets = m.traffic_counts.packets;
    m.mutex.unlock();
    var words = if (w.samples.len == 0) try std.fmt.allocPrint(a, "no spectrum ({s})", .{status}) else r.words;
    if (w.samples.len > 1 and w.samples[0].mono_ns > from_ns + 2_000_000_000 and m.ringFull())
        words = try std.fmt.allocPrint(a, "{s}; spectrum covers only the last {d:.0} s of the {d:.0} s asked (the sample ring's reach)", .{ words, @as(f32, @floatFromInt(to_ns - w.samples[0].mono_ns)) / 1e9, @as(f32, @floatFromInt(to_ns - from_ns)) / 1e9 });
    return .{
        .window_s = r.window_s,
        .words = words,
        .traffic_words = if (dwells.len == 0) (if (t_on) "traffic: no dwell finished yet" else "traffic: no card counting frames (--traffic NAME, a spare monitor-capable card, root)") else r.traffic_words,
        .advice = r.advice,
        .best_channel = r.best_channel,
        .blast = r.blast,
        .channels = try a.dupe(channels.Channel, &r.channels),
        .regions = r.regions,
        .plan = if (info.sensors > 0) try a.dupe(u8, info.plan.describe(&pb)) else "",
        .sweep = if (info.sensors > 0) .{ .mode = @tagName(info.plan.mode), .windows_mhz = try a.dupe(u16, info.plan.windows.list()), .dwell_ms = info.plan.dwell_ms, .revisit_ms = info.plan.revisitMs(), .sensors = info.sensors, .watch_share = info.plan.watchShare() } else null,
        .samples = r.samples,
        .location_windows_total = r.location_windows_total,
        .location_windows_pulsing = r.location_windows_pulsing,
        .location_windows_located = r.location_windows_located,
        .status = status,
        .traffic = .{ .on = t_on, .iface = t_iface, .why = if (t_on) "" else "no traffic card chosen (--traffic NAME)", .dwell_ms = monitor.traffic_dwell_ms, .packets = packets },
        .tx = try txList(a, m),
    };
}

pub const CardJson = struct {
    phy: []const u8,
    interface: []const u8,
    driver: []const u8,
    bus: []const u8,
    role: []const u8,
    why: []const u8,
    up: bool,
    associated: bool,
    default_route: bool,
    managed_by: ?[]const u8,
    iftype: ?[]const u8,
    freq_mhz: ?u32,
    rfkill_soft: bool,
    rfkill_hard: bool,
    spectral: []const u8,
    spectral_checked: []const u8,
    monitor_capable: ?bool,
    contributes: []const u8,
    refusal: ?[]const u8,
};
pub const Radios = struct { cards: []const CardJson, needs: []const u8, connman_running: bool, root: bool, chosen: ?[]const u8, status: ?[]const u8 };

pub fn radios(a: std.mem.Allocator, roots: cards.Roots) !Radios {
    var sock_storage: nl80211.Socket = undefined;
    const sock: ?*nl80211.Socket = if (nl80211.Socket.open()) |s| blk: {
        sock_storage = s;
        break :blk &sock_storage;
    } else |_| null;
    defer if (sock) |s| s.close();
    const list = cards.enumerate(roots, sock);
    const out = try a.alloc(CardJson, list.len);
    for (list.items(), out) |*c, *o| {
        var b1: [400]u8 = undefined;
        var b2: [400]u8 = undefined;
        o.* = .{
            .phy = try a.dupe(u8, c.phy.get()),
            .interface = try a.dupe(u8, c.iface.get()),
            .driver = try a.dupe(u8, c.driver.get()),
            .bus = try a.dupe(u8, c.bus.get()),
            .role = @tagName(c.role),
            .why = try a.dupe(u8, c.why.get()),
            .up = c.up,
            .associated = c.associated(),
            .default_route = c.default_route,
            .managed_by = c.managed_by,
            .iftype = if (c.iftype) |t| switch (t) {
                1 => "adhoc",
                2 => "managed",
                3 => "ap",
                6 => "monitor",
                7 => "mesh",
                else => "other",
            } else null,
            .freq_mhz = c.freq_mhz,
            .rfkill_soft = c.soft_blocked,
            .rfkill_hard = c.hard_blocked,
            .spectral = switch (c.spectral) {
                .ath9k => "ath9k spectral scan (HT20, 56 bins)",
                .other_driver => "driver has spectral scan; not read by xodb yet",
                .none => "none",
            },
            .spectral_checked = if (c.spectral != .ath9k) "n/a" else if (c.spectral_checked) "debugfs control present" else if (fsx.isRoot()) "debugfs control not found" else "needs root to check",
            .monitor_capable = c.monitor,
            .contributes = try a.dupe(u8, c.contributes(&b1)),
            .refusal = if (c.refusal(&b2)) |r| try a.dupe(u8, r) else null,
        };
    }
    var nb: [300]u8 = undefined;
    var status: ?[]const u8 = null;
    var chosen: ?[]const u8 = null;
    if (global) |m| {
        var sb: [400]u8 = undefined;
        status = try a.dupe(u8, m.statusText(&sb));
        if (m.cfg.radio) |r| chosen = r;
    }
    _ = &chosen;
    return .{ .cards = out, .needs = try a.dupe(u8, list.needs(&nb)), .connman_running = list.connman, .root = fsx.isRoot(), .chosen = chosen, .status = status };
}

test {
    _ = sweep;
    _ = channels;
    _ = radiotap;
    _ = ath9k;
    _ = detect;
    _ = @import("detect_cases.zig");
    _ = nl80211;
    _ = cards;
    _ = monitor;
}

test "report on a monitor fed with synthetic microwave samples" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const m = try Monitor.start(a, .{ .roots = .{ .sys = "/nonexistent", .proc = "/nonexistent" } });
    defer m.deinit();
    m.samples = try monitor.Ring(monitor.Stamped).init(a, 1 << 16);
    // 3 s quiet, then 4 s of 60 Hz pulsing, on the monitor's clock.
    const quiet = try (detect.Synth{ .scene = .empty, .seconds = 3, .seed = 3 }).generate(a);
    defer a.free(quiet);
    const pulsed = try (detect.Synth{ .scene = .microwave60, .seconds = 4, .seed = 4 }).generate(a);
    defer a.free(pulsed);
    const now = fsx.monotonicNs();
    const base = now - 8_000_000_000;
    m.mutex.lock();
    for (quiet) |s| m.samples.push(.{ .s = s, .mono_ns = base + s.tsf_us * 1000 });
    for (pulsed) |s0| {
        var s = s0;
        s.tsf_us += 3_000_000;
        m.samples.push(.{ .s = s, .mono_ns = base + s.tsf_us * 1000 });
    }
    m.mutex.unlock();
    const r = try report(arena.allocator(), m, 10_000_000_000, true);
    try std.testing.expectEqualStrings("microwave_pulsed", r.kind);
    try std.testing.expectEqual(@as(?u8, 60), r.verdict.mains_hz);
    try std.testing.expect(@abs(r.verdict.duty.? - 0.48) < 0.08);
    try std.testing.expect(r.confidence > 0.8);
    try std.testing.expect(r.interference_from_s.? > 4 and r.interference_from_s.? < 6.5);
    try std.testing.expect(std.mem.indexOf(u8, r.words, "60 Hz pulsing") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.words, "seen ") != null);
    _ = try std.json.Stringify.valueAlloc(arena.allocator(), r, .{});
}

test "a five-second headline and channel report use one localized interval" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const m = try Monitor.start(a, .{ .roots = .{ .sys = "/nonexistent", .proc = "/nonexistent" } });
    defer m.deinit();
    m.samples = try monitor.Ring(monitor.Stamped).init(a, 1 << 16);
    const p = sweep.plan(.{}, 1);
    const xs = try channels.synthSweep(aa, p.windows.list(), 0.7, 1, true, 91);
    m.mutex.lock();
    for (xs) |x| m.samples.push(x);
    m.mutex.unlock();
    const from = xs[0].mono_ns;
    const to = xs[xs.len - 1].mono_ns + 1;
    const headline = try reportBetween(aa, m, from, to, true);
    const channel = try channelsBetween(aa, m, from, to, null);
    try std.testing.expectEqualStrings("microwave_pulsed", headline.kind);
    try std.testing.expect(headline.verdict.location_resolved);
    try std.testing.expectEqual(@as(f32, @floatFromInt(channel.blast.?.lo_mhz)), headline.verdict.band_lo_mhz.?);
    try std.testing.expectEqual(@as(f32, @floatFromInt(channel.blast.?.hi_mhz)), headline.verdict.band_hi_mhz.?);
    var mask: u16 = 0;
    for (channel.channels) |ch| {
        if (ch.impact == .blasted or ch.impact == .grazed) mask |= @as(u16, 1) << @intCast(ch.channel);
    }
    try std.testing.expectEqual(mask, headline.verdict.channels);
}

test "an in-use card is never taken, even when chosen" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir);
    try cards.writeTestTree(dir);
    var rb: [4][160]u8 = undefined;
    const roots = try cards.testRoots(&rb, dir);
    var sb: [512]u8 = undefined;
    const state = try std.fmt.bufPrint(&sb, "{s}/state", .{dir});
    for ([_][]const u8{ "wlp1s0", "wlan2" }) |name| {
        const m = try Monitor.start(a, .{ .radio = name, .roots = roots, .state_dir = state });
        // The collector decides on its own thread; wait (bounded) for its verdict on the card.
        var b: [400]u8 = undefined;
        var status: []const u8 = "";
        for (0..500) |_| {
            status = m.statusText(&b);
            if (status.len > 0) break;
            const ts = std.os.linux.timespec{ .sec = 0, .nsec = 10_000_000 };
            _ = std.os.linux.nanosleep(&ts, null);
        }
        m.deinit();
        // Refused before anything is touched: no saved state, no restore file.
        try std.testing.expect(std.mem.indexOf(u8, status, if (std.mem.eql(u8, name, "wlp1s0")) "is in use" else "rfkill") != null);
        try std.testing.expect(!fsx.exists("{s}/radio-restore", .{state}));
    }
}

test "demo collector: two synthetic sensors sweep, a focus retunes at once, traffic dwells land" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const m = try Monitor.start(a, .{ .demo = .kitchen, .demo_sensors = 2, .dwell_ms = 200, .roots = .{ .sys = "/nonexistent", .proc = "/nonexistent" } });
    defer m.deinit();
    const ts = std.os.linux.timespec{ .sec = 1, .nsec = 500_000_000 };
    _ = std.os.linux.nanosleep(&ts, null);
    const t0 = fsx.monotonicNs();
    var w = try m.window(arena.allocator(), 10_000_000_000);
    var centres: u32 = 0;
    var by_sensor: [2]u32 = .{ 0, 0 };
    for (w.samples, 0..) |x, i| {
        by_sensor[x.sensor] += 1;
        if (i == 0 or x.s.freq_mhz != w.samples[i - 1].s.freq_mhz) centres += 1;
        if (i > 0) try std.testing.expect(x.mono_ns >= w.samples[i - 1].mono_ns);
    }
    try std.testing.expect(by_sensor[0] > 1000 and by_sensor[1] > 1000);
    try std.testing.expect(centres >= 4);
    const info = m.planInfo();
    try std.testing.expectEqual(@as(usize, 2), info.sensors);
    try std.testing.expectEqual(sweep.Mode.sweep, info.plan.mode);
    // Focus on one window: both sensors park on channel 10 at once.
    m.focus(.{ .mode = .focus, .lo_mhz = 2449, .hi_mhz = 2466 });
    const ts2 = std.os.linux.timespec{ .sec = 0, .nsec = 400_000_000 };
    _ = std.os.linux.nanosleep(&ts2, null);
    const after = m.planInfo();
    try std.testing.expectEqual(sweep.Mode.fixed, after.plan.mode);
    try std.testing.expectEqual(@as(u32, 2457), after.centres[0]);
    try std.testing.expectEqual(@as(u32, 2457), after.centres[1]);
    w = try m.window(arena.allocator(), 150_000_000);
    try std.testing.expect(w.samples.len > 100);
    for (w.samples) |x| try std.testing.expectEqual(@as(u16, 2457), x.s.freq_mhz);
    // Traffic: dwells on several channels; the channel report counts them.
    const now = fsx.monotonicNs();
    const dwells = try m.dwellsBetween(arena.allocator(), t0 -| 5_000_000_000, now);
    try std.testing.expect(dwells.len >= 4);
    const cr = try channelsBetween(arena.allocator(), m, t0 -| 5_000_000_000, now, null);
    try std.testing.expect(cr.traffic.on);
    var counted: u32 = 0;
    for (cr.channels) |ch| if (ch.traffic) |t| {
        counted += t.frames;
    };
    try std.testing.expect(counted > 0);
    _ = try std.json.Stringify.valueAlloc(arena.allocator(), cr, .{});
    // The demo never takes a card.
    var tx: [4]monitor.TxEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), m.txReports(&tx).len);
}

test "the host-clock mapping drops garbage TSFs and re-anchors only on a real step" {
    const a = std.testing.allocator;
    const m = try Monitor.start(a, .{ .roots = .{ .sys = "/nonexistent", .proc = "/nonexistent" } });
    defer m.deinit();
    m.samples = try monitor.Ring(monitor.Stamped).init(a, 1 << 14);
    var batch: [50]ath9k.Sample = undefined;
    const r0: u64 = 100_000_000_000;
    var tsf: u64 = 5_000_000;
    var read = r0;
    const feed = struct {
        fn f(mm: *Monitor, b: *[50]ath9k.Sample, t: *u64, r: *u64, garbage: ?usize) void {
            for (b, 0..) |*s, i| {
                s.* = .{ .tsf_us = t.* + i * 150, .freq_mhz = 2457, .rssi = 0, .noise = -95, .power = @splat(-110) };
                if (garbage == i) s.tsf_us = 0xffff_ffff_ffff;
            }
            t.* += 50 * 150;
            r.* += 7_500_000;
            mm.store(0, b, r.* + 2_000_000);
        }
    }.f;
    // Normal batches with one garbage TSF in the middle of each: dropped, never re-anchoring.
    for (0..20) |_| feed(m, &batch, &tsf, &read, 25);
    try std.testing.expectEqual(@as(u32, 0), m.clock().steps);
    try std.testing.expectEqual(@as(u64, 20), m.sensors[0].rejected);
    var w = try m.between(a, 0, std.math.maxInt(u64));
    for (w.samples, 0..) |x, i| {
        try std.testing.expect(x.mono_ns <= read + 2_000_000);
        if (i > 0) try std.testing.expect(x.mono_ns >= w.samples[i - 1].mono_ns);
    }
    try std.testing.expectEqual(@as(usize, 20 * 49), w.samples.len);
    w.deinit(a);
    // The card's TSF steps back 3 s and stays there: after half a second the mapping follows.
    tsf -= 3_000_000;
    for (0..120) |_| feed(m, &batch, &tsf, &read, null);
    try std.testing.expectEqual(@as(u32, 1), m.clock().steps);
    const last = m.samples.last().?.mono_ns;
    try std.testing.expect(last > read - 50_000_000 and last <= read + 2_000_000);
    w = try m.between(a, read - 100_000_000, read + 10_000_000);
    defer w.deinit(a);
    try std.testing.expect(w.samples.len >= 600);
}

test "stress: saturated, malformed and garbage-TSF records at twice the real rate never stall the stream" {
    const a = std.testing.allocator;
    const linux = std.os.linux;
    const m = try Monitor.start(a, .{ .roots = .{ .sys = "/nonexistent", .proc = "/nonexistent" } });
    defer m.deinit();
    m.samples = try monitor.Ring(monitor.Stamped).init(a, 1 << 16);
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })));
    defer _ = linux.close(fds[1]);
    m.sensors[0].files[0] = fds[0];
    m.sensors[0].n_files = 1;
    defer m.sensors[0].n_files = 0;
    defer _ = linux.close(fds[0]);
    var prng = std.Random.DefaultPrng.init(0x2b);
    const r = prng.random();
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(a);
    const base_tsf: u64 = 50_000_000;
    var mw: [ath9k.bins]f64 = @splat(1e-9);
    var rec: [3 + ath9k.ht20_len]u8 = undefined;
    // 3 s at ~13k records/s (twice the AR9271's rate), the magnetron's worst.
    const n_stress = 40_000;
    for (0..n_stress) |i| {
        ath9k.encode(&rec, base_tsf + i * 75, 2457, -95, &mw);
        const b = rec[3..];
        b[0] = 15; // max_exp at its limit
        b[3] = 127; // rssi saturated
        @memset(b[17..], 255); // every bin saturated
        switch (r.uintLessThan(u32, 100)) {
            0, 1 => std.mem.writeInt(u64, b[9..17], r.int(u64), .big), // garbage TSF
            2 => std.mem.writeInt(u16, b[1..3], r.int(u16) | 0x8000, .big), // garbage frequency
            3 => {
                // A wrong-length record of the right type, then garbage.
                try stream.appendSlice(a, &.{ 1, 0, 100 });
                for (0..100) |_| try stream.append(a, r.int(u8));
                continue;
            },
            4 => try stream.appendSlice(a, &.{ 0, 0, 0 }), // a zero TLV: the rest of that read is dropped
            else => {},
        }
        try stream.appendSlice(a, &rec);
    }
    // Then 1 s of clean records.
    const n_clean = 6_000;
    const clean_tsf = base_tsf + n_stress * 75;
    for (0..n_clean) |i| {
        ath9k.encode(&rec, clean_tsf + i * 150, 2457, -95, &mw);
        try stream.appendSlice(a, &rec);
    }
    var buf: [65536]u8 = undefined;
    var batch: [1024]ath9k.Sample = undefined;
    var at: usize = 0;
    var clean_reads: usize = 0;
    while (at < stream.items.len or clean_reads < 3) {
        if (at < stream.items.len) {
            const chunk = @min(stream.items.len - at, 1 + r.uintLessThan(usize, 6000));
            const rc = linux.write(fds[1], stream.items[at..].ptr, chunk);
            if (linux.errno(rc) == .SUCCESS) at += rc;
        } else clean_reads += 1;
        m.readSensor(0, &buf, &batch);
    }
    const now = fsx.monotonicNs();
    var w = try m.between(a, 0, std.math.maxInt(u64));
    defer w.deinit(a);
    try std.testing.expect(w.samples.len > n_stress / 2);
    for (w.samples, 0..) |x, i| {
        try std.testing.expect(x.mono_ns <= now);
        try std.testing.expect(x.s.freq_mhz == 2457);
        if (i > 0) try std.testing.expect(x.mono_ns >= w.samples[i - 1].mono_ns);
    }
    // The clean second after the storm arrives whole: nothing stalled.
    var clean: usize = 0;
    for (w.samples) |x| clean += @intFromBool(x.s.tsf_us >= clean_tsf);
    try std.testing.expect(clean >= n_clean - 200);
    try std.testing.expect(m.sensors[0].rejected > 0);
    try std.testing.expect(m.counts.malformed > 0);
    try std.testing.expectEqual(@as(u32, 0), m.sensors[0].tsf_steps);
}
