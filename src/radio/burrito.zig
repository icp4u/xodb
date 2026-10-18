//! `xodb --burrito`: is it the microwave? A terminal run of burrito mode:
//! lists the cards, optionally takes an explicitly chosen spectral-capable
//! card (root, receive-only), listens for a while (or in timed phases, e.g.
//! microwave off/on/off) and prints the verdict per phase, with the link's
//! ping loss and the chosen card's TX counters before and after.
const std = @import("std");
const c = std.c;
const radio = @import("radio.zig");
const fsx = radio.fsx;

pub const usage =
    \\xodb --burrito [--radio IFACE[,IFACE] [--traffic IFACE] [--channel N | --focus LO-HI]] [--seconds N | --phases S,S,...] [--json] [--redact]
    \\  Is it the microwave? Listens to 2.4 GHz and your Wi-Fi link, receive-only, and says what it saw:
    \\  the verdict, and per Wi-Fi channel 1-14 how hard the interferer hits it ("channels 8-12 blasted").
    \\  Without --radio: lists the cards and reads the in-use link passively (signal, bitrate, retries,
    \\  channel survey). Nothing is reconfigured and nothing is sent.
    \\  --radio IFACE   use this spare card (or up to four, comma-separated) for spectrum: monitor mode and
    \\                  the ath9k spectral scan (background + trigger, never chanscan). Needs root. Refused for a
    \\                  card that is in use, managed by a network manager or switched off by rfkill. Its
    \\                  state is restored on exit, and at the next start after a crash. By default the sensors
    \\                  sweep the band: 20 MHz windows on channels 1/4/7/10/13/14, 600 ms each (shared out
    \\                  when there are several sensors).
    \\  --traffic IFACE count frames per channel on this spare monitor-capable card (receive-only: monitor
    \\                  mode and a packet socket that is only read; 500 ms per channel): frames/s, airtime,
    \\                  retries, bad-FCS frames and how many networks and stations (counts only; addresses
    \\                  are hashed in memory with a per-session key and never stored or printed)
    \\  --ping          ping your gateway at 50 Hz over the in-use Wi-Fi link (bound to it) to measure loss
    \\                  while the interferer runs. Off by default: this is the one thing xodb sends.
    \\  --channel N     one fixed 20 MHz window on channel N (1-14): the highest sample rate
    \\  --focus LO-HI   sweep only LO-HI MHz (one fixed window when it fits in 20 MHz)
    \\  --dwell-ms N    time per window when sweeping (default 600, the shortest that resolves 50/60 Hz)
    \\  --hop           sweep the band (the default; kept for older command lines)
    \\  --seconds N     listen for N seconds (default 20)
    \\  --phases S,...  timed phases, e.g. 30,60,30 for microwave off, on, off; prompts at each change
    \\  --spectral-period N  ath9k spectral_period (default 16, ~6.6k samples/s on an AR9271; 1 is fastest, ~25k/s)
    \\  --wait-enter    between phases, prompt and wait for Enter (default when stdin is a terminal);
    \\                  the wait is captured but kept out of the phases ("transition"). --no-wait: timed
    \\  --json          print the reports as JSON
    \\  --redact        hide the gateway address
    \\  --demo SCENE    SYNTHETIC spectrum and traffic (10 s quiet, 15 s SCENE, repeating) instead of cards:
    \\                  kitchen (access points, Bluetooth and a microwave), microwave60, microwave50,
    \\                  inverter, wifi, bluetooth, empty. Reads no radio. --demo-sensors N: N synthetic sensors.
    \\
;
pub const takes = [_][]const u8{ "--radio", "--channel", "--seconds", "--phases", "--demo", "--spectral-period", "--traffic", "--focus", "--dwell-ms", "--demo-sensors" };

/// "2440-2470" (MHz) as a focus request.
pub fn parseFocus(value: []const u8) ?radio.sweep.Request {
    const dash = std.mem.indexOfScalar(u8, value, '-') orelse return null;
    const lo = std.fmt.parseInt(u16, value[0..dash], 10) catch return null;
    const hi = std.fmt.parseInt(u16, value[dash + 1 ..], 10) catch return null;
    if (lo < 2400 or hi > 2500 or hi < lo + 5) return null;
    return .{ .mode = .focus, .lo_mhz = lo, .hi_mhz = hi };
}

var stop_flag = std.atomic.Value(bool).init(false);
fn onSignal(_: std.posix.SIG) callconv(.c) void {
    stop_flag.store(true, .release);
}

/// $XDG_STATE_HOME/xodb, else $HOME/.local/state/xodb.
pub fn stateDir(a: std.mem.Allocator) ?[]const u8 {
    if (c.getenv("XDG_STATE_HOME")) |d| if (d[0] == '/') return std.fmt.allocPrint(a, "{s}/xodb", .{std.mem.span(d)}) catch null;
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.allocPrint(a, "{s}/.local/state/xodb", .{std.mem.span(home)}) catch null;
}

fn out(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const t = std.fmt.allocPrint(a, fmt, args) catch return;
    var done: usize = 0;
    while (done < t.len) {
        const n = c.write(1, t.ptr + done, t.len - done);
        if (n <= 0) break;
        done += @intCast(n);
    }
}
fn say(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const t = std.fmt.allocPrint(a, fmt, args) catch return;
    _ = c.write(2, t.ptr, t.len);
}

pub fn main(args: []const [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = radio.monitor.Config{ .state_dir = stateDir(a) };
    var phases: std.ArrayList(u32) = .empty;
    var as_json = false;
    var redact = false;
    // Phase changes wait for Enter when a person is at the terminal (they walk to the microwave).
    var wait_enter = std.c.isatty(0) != 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, arg, "--burrito")) continue;
        if (std.mem.eql(u8, arg, "--wait-enter")) wait_enter = true else if (std.mem.eql(u8, arg, "--no-wait")) wait_enter = false else if (std.mem.eql(u8, arg, "--json")) as_json = true else if (std.mem.eql(u8, arg, "--hop")) cfg.hop = true else if (std.mem.eql(u8, arg, "--redact")) redact = true else if (std.mem.eql(u8, arg, "--radio") and value.len > 0) {
            cfg.radio = value;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--ping")) {
            cfg.ping_gateway = true;
        } else if (std.mem.eql(u8, arg, "--ht40")) {
            cfg.ht40 = true;
        } else if (std.mem.eql(u8, arg, "--traffic") and value.len > 0) {
            cfg.traffic = value;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--focus") and value.len > 0) {
            cfg.focus = parseFocus(value) orelse {
                say(a, "xodb: --focus takes LO-HI in MHz within 2400-2500, at least 5 MHz wide (e.g. 2440-2470)\n", .{});
                return error.InvalidRadioOption;
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--dwell-ms") and value.len > 0) {
            cfg.dwell_ms = std.fmt.parseInt(u32, value, 10) catch 0;
            if (cfg.dwell_ms < 200 or cfg.dwell_ms > 10_000) {
                say(a, "xodb: --dwell-ms takes 200..10000\n", .{});
                return error.InvalidRadioOption;
            }
            i += 1;
        } else if (std.mem.eql(u8, arg, "--demo-sensors") and value.len > 0) {
            cfg.demo_sensors = std.fmt.parseInt(u8, value, 10) catch 0;
            if (cfg.demo_sensors < 1 or cfg.demo_sensors > radio.sweep.max_sensors) {
                say(a, "xodb: --demo-sensors takes 1..4\n", .{});
                return error.InvalidRadioOption;
            }
            i += 1;
        } else if (std.mem.eql(u8, arg, "--demo") and value.len > 0) {
            cfg.demo = std.meta.stringToEnum(radio.detect.Synth.Scene, value) orelse {
                say(a, "xodb: --demo takes kitchen, microwave60, microwave50, inverter, wifi, bluetooth or empty\n", .{});
                return error.InvalidRadioOption;
            };
            i += 1;
        } else if (std.mem.eql(u8, arg, "--spectral-period") and value.len > 0) {
            cfg.period = std.fmt.parseInt(u8, value, 10) catch 0;
            if (cfg.period < 1) {
                say(a, "xodb: --spectral-period takes 1..255\n", .{});
                return error.InvalidRadioOption;
            }
            i += 1;
        } else if (std.mem.eql(u8, arg, "--channel") and value.len > 0) {
            const ch = std.fmt.parseInt(u8, value, 10) catch 0;
            if (ch < 1 or ch > 14) {
                say(a, "xodb: --channel takes 1..14\n{s}", .{usage});
                return error.InvalidRadioOption;
            }
            cfg.channel = ch;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--seconds") and value.len > 0) {
            const s = std.fmt.parseInt(u32, value, 10) catch 0;
            if (s < 1 or s > 3600) {
                say(a, "xodb: --seconds takes 1..3600\n{s}", .{usage});
                return error.InvalidRadioOption;
            }
            phases.clearRetainingCapacity();
            try phases.append(a, s);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--phases") and value.len > 0) {
            phases.clearRetainingCapacity();
            var it = std.mem.splitScalar(u8, value, ',');
            while (it.next()) |p| {
                const s = std.fmt.parseInt(u32, p, 10) catch 0;
                if (s < 3 or s > 1800 or phases.items.len >= 8) {
                    say(a, "xodb: --phases takes up to 8 comma-separated durations of 3..1800 s\n{s}", .{usage});
                    return error.InvalidRadioOption;
                }
                try phases.append(a, s);
            }
            i += 1;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            out(a, "{s}", .{usage});
            return;
        } else {
            say(a, "xodb: --burrito does not accept {s}\n{s}", .{ arg, usage });
            return error.InvalidRadioOption;
        }
    }
    if (phases.items.len == 0) try phases.append(a, 20);
    for ([_]std.posix.SIG{ .INT, .TERM, .HUP }) |sig| std.posix.sigaction(sig, &.{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 }, null);

    const list = try radio.radios(a, cfg.roots);
    if (!as_json) {
        out(a, "Wi-Fi cards:\n", .{});
        for (list.cards) |card| {
            out(a, "  {s} ({s}, {s} {s}): {s} - {s}\n      contributes: {s}\n", .{ card.interface, card.phy, card.driver, card.bus, @tagName(std.meta.stringToEnum(radio.cards.Role, card.role).?), card.why, card.contributes });
        }
        out(a, "  {s}\n", .{list.needs});
    }
    radio.defaults = cfg;
    const m = radio.ensure(std.heap.c_allocator) orelse return error.RadioMonitorFailed;
    defer radio.shutdown();
    // Let the collector take the card (or refuse) before the first phase.
    sleepMs(300);
    var sb: [400]u8 = undefined;
    if (!as_json) out(a, "{s}\n", .{m.statusText(&sb)});
    if (m.recovered.len > 0 and !as_json) out(a, "{s}\n", .{m.recovered.get()});

    var reports: std.ArrayList(radio.Report) = .empty;
    var channel_reports: std.ArrayList(radio.ChannelsOut) = .empty;
    var transitions: std.ArrayList(f32) = .empty;
    for (phases.items, 0..) |secs, k| {
        if (stop_flag.load(.acquire)) break;
        if (k > 0 and wait_enter) {
            // Still capturing while the person walks; this time belongs to no phase.
            say(a, "\n{s}", .{if (k % 2 == 1) "Turn the microwave ON now, come back, and press Enter: " else "Turn the microwave OFF now, come back, and press Enter: "});
            const t0 = fsx.monotonicNs();
            waitEnter();
            const waited = @as(f32, @floatFromInt(fsx.monotonicNs() - t0)) / 1e9;
            try transitions.append(a, waited);
            if (!as_json) out(a, "transition {d}: {d:.1} s waiting for Enter (captured, not in any phase)\n", .{ k, waited });
            if (stop_flag.load(.acquire)) break;
        }
        const label = if (k % 2 == 1) "microwave ON" else "microwave OFF";
        if (phases.items.len > 1) say(a, "\n=== phase {d}/{d}, {d} s: {s} ===\n", .{ k + 1, phases.items.len, secs, if (wait_enter or k == 0) label else if (k % 2 == 1) "switch the microwave ON now" else "switch the microwave OFF now" });
        const from = fsx.monotonicNs();
        const end = from + @as(u64, secs) * 1_000_000_000;
        var next_line = from + 5_000_000_000;
        while (fsx.monotonicNs() < end and !stop_flag.load(.acquire)) {
            sleepMs(100);
            if (fsx.monotonicNs() >= next_line and !as_json) {
                next_line += 5_000_000_000;
                var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer scratch.deinit();
                const r = radio.report(scratch.allocator(), m, 5_000_000_000, redact) catch continue;
                say(a, "  [{d:>4.0} s] {d} samples ({d:.0}/s, lag {d:.0} ms; clock: {d} TSF steps, {d} held back; watchdog: {d} re-triggers, {d} re-arms; {d} malformed) pings {d}/{d} lost: {s}\n", .{ @as(f32, @floatFromInt(fsx.monotonicNs() - from)) / 1e9, r.spectral.window_samples, r.spectral.rate_hz, r.spectral.lag_ms, r.spectral.tsf_steps, r.spectral.rejected, r.spectral.retriggers, r.spectral.rearms, r.spectral.malformed, r.ping.lost, r.ping.sent, r.words });
                // The channels over the last full sweeps (two revisits, at least 8 s).
                const t = fsx.monotonicNs();
                const span = @max(8_000_000_000, 2 * @as(u64, m.planInfo().plan.revisitMs()) * 1_000_000);
                if (r.spectral.window_samples > 0) if (radio.channelsBetween(scratch.allocator(), m, @max(from, t -| span), t, null)) |cr| {
                    say(a, "         channels: {s}\n", .{cr.words});
                } else |_| {};
            }
        }
        const to = @min(fsx.monotonicNs(), end);
        const r = try radio.reportBetween(a, m, from, to, redact);
        try reports.append(a, r);
        const cr = try radio.channelsBetween(a, m, from, to, null);
        try channel_reports.append(a, cr);
        if (!as_json) {
            out(a, "phase {d}: {s}\n  kind={s} confidence={d:.2} samples={d} rate={d:.0}/s r60={d:.2} r50={d:.2} half={d:.2} active={d:.2} floor={d:.0}dBm width={d:.1}MHz hop={d:.1}MHz coverage={d:.2} pings sent={d} lost={d}\n", .{ k + 1, r.words, r.kind, r.confidence, r.spectral.window_samples, r.spectral.rate_hz, r.verdict.r60, r.verdict.r50, if (r.verdict.r60 >= r.verdict.r50) r.verdict.r60half else r.verdict.r50half, r.verdict.active, r.verdict.floor_dbm, r.verdict.width_mhz, r.verdict.hop_mhz, r.verdict.coverage, r.ping.sent, r.ping.lost });
            printChannels(a, k + 1, &cr);
        }
    }
    // Restore the card, then report its TX counters across the session.
    m.halt();
    if (cfg.ht40 and !as_json) out(a, "HT40 check: {d} HT20 samples decoded, {d} HT20/40 records (type 2), {d} other records skipped (last: type {d}, length {d}), {d} malformed\n", .{ m.counts.samples, m.counts.ht40, m.counts.skipped - m.counts.ht40, m.counts.skipped_kind, m.counts.skipped_len, m.counts.malformed });
    const tx_cards = try radio.txList(a, m);
    for (tx_cards) |*t| t.flat = t.flat and t.packets_now != null and t.bytes_now != null;
    const tx: ?radio.Tx = if (tx_cards.len > 0) tx_cards[0] else null;
    if (as_json) {
        out(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, .{ .radios = list, .phases = reports.items, .channels = channel_reports.items, .transitions_s = transitions.items, .tx = tx, .tx_cards = tx_cards }, .{})});
    } else {
        // The verdict the user came for, once more at the end: the phase where the interferer was strongest.
        var best: ?*const radio.ChannelsOut = null;
        for (channel_reports.items) |*cr| if (cr.blast) |b| {
            if (best == null or best.?.blast == null or b.confidence > best.?.blast.?.confidence) best = cr;
        };
        if (best) |cr| out(a, "\nCHANNEL VERDICT: {s}\n  {s}\n", .{ cr.words, cr.advice }) else if (channel_reports.items.len > 0 and channel_reports.items[0].samples > 0) out(a, "\nCHANNEL VERDICT: {s}\n", .{channel_reports.items[channel_reports.items.len - 1].words});
        const note = m.recovered.get();
        for (tx_cards) |t| {
            const left = std.mem.startsWith(u8, note, radio.monitor.left_alone) and std.mem.indexOf(u8, note, t.iface) != null;
            if (left) out(a, "{s} was not restored, {s}\n", .{ t.iface, note });
            out(a, "{s} {s}; TX counters: packets {d} -> {?d}, bytes {d} -> {?d}: {s}\n", .{ t.iface, if (left) "released" else "restored", t.packets_before, t.packets_now, t.bytes_before, t.bytes_now, if (t.flat) "flat (receive-only held)" else "MOVED" });
        }
    }
    for (tx_cards) |t| if (!t.flat) return error.RadioTransmitted;
}

/// The per-phase channel verdict and a compact table: 14 channels, their power,
/// floor, occupancy, interferer impact and traffic.
fn printChannels(a: std.mem.Allocator, phase: usize, cr: *const radio.ChannelsOut) void {
    out(a, "  channels (phase {d}): {s}\n", .{ phase, cr.words });
    if (cr.plan.len > 0) out(a, "  sensors: {s}\n", .{cr.plan});
    if (cr.samples == 0 and !cr.traffic.on) return;
    out(a, "    ch   MHz  power  floor  busy  interferer         impact   | frames/s  air  retry  badFCS/s nets stas\n", .{});
    for (cr.channels) |ch| {
        var p: [8]u8 = undefined;
        var f: [8]u8 = undefined;
        var o: [8]u8 = undefined;
        var it: [24]u8 = undefined;
        var bz: [8]u8 = undefined;
        var tr: [64]u8 = undefined;
        const inter = if (ch.interferer_over_floor_db) |d| std.fmt.bufPrint(&it, "+{d:.0} dB {d:.0}%", .{ d, (ch.interferer_time orelse 0) * 100 }) catch "" else "-";
        const traffic = if (ch.traffic) |t| std.fmt.bufPrint(&tr, "{d:>8.0} {d:>3.0}% {s:>5} {d:>8.1} {d:>4}{s} {d:>3}", .{ t.frames_ps, t.airtime * 100, if (t.retry) |x| (std.fmt.bufPrint(&o, "{d:.0}%", .{x * 100}) catch "") else "-", t.bad_fcs_ps, t.networks, if (t.at_least) "+" else " ", t.stations }) catch "" else "      (not watched)";
        out(a, "    {d:>2}  {d}  {s:>5}  {s:>5}  {s:>4}  {s:<17}  {s:<7}  |{s}\n", .{
            ch.channel,
            ch.centre_mhz,
            if (ch.power_dbm) |x| std.fmt.bufPrint(&p, "{d:.0}", .{x}) catch "" else "-",
            if (ch.floor_dbm) |x| std.fmt.bufPrint(&f, "{d:.0}", .{x}) catch "" else "-",
            if (ch.occupied) |x| std.fmt.bufPrint(&bz, "{d:.0}%", .{x * 100}) catch "" else "-",
            inter,
            @tagName(ch.impact),
            traffic,
        });
    }
    if (cr.traffic_words.len > 0) out(a, "  {s}\n", .{cr.traffic_words});
    if (cr.advice.len > 0) out(a, "  {s}\n", .{cr.advice});
}

/// Blocks until a line (or end of input, or a signal) arrives on stdin.
fn waitEnter() void {
    // An Enter typed early (or twice) must not skip the walk: drop pending terminal input.
    if (std.c.isatty(0) != 0) _ = std.os.linux.ioctl(0, 0x540B, 0); // TCFLSH, TCIFLUSH (asm-generic and x86)
    var b: [256]u8 = undefined;
    while (!stop_flag.load(.acquire)) {
        const n = std.c.read(0, &b, b.len);
        if (n < 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
        if (n <= 0) return;
        if (std.mem.indexOfScalar(u8, b[0..@intCast(n)], '\n') != null) return;
    }
}

fn sleepMs(ms: u64) void {
    const ts = std.os.linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = std.os.linux.nanosleep(&ts, null);
}
