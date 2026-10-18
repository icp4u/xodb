//! The live radio collector: one thread that reads the chosen cards'
//! spectral samples (ath9k debugfs relay files), a receive-only traffic
//! card's frames (radiotap over a packet socket), the in-use link's station
//! and survey (nl80211) and its gateway's ping (ICMP echo at 50 Hz), into
//! bounded rings on CLOCK_MONOTONIC. Spectral samples keep their device
//! clock (TSF, microseconds); the mapping to monotonic is the lower
//! envelope of (read time - TSF) per card, with its spread as the uncertainty.
//!
//! Where the sensors listen comes from the sweep planner (sweep.zig): by
//! default they step across the band; a focus request (the panel's drag,
//! `--focus`, `--channel`) retunes them at once. The traffic card hops the
//! channels of the same span, 250 ms each.
//!
//! Receive-only: chosen cards are put in monitor mode; the spectral scan runs
//! in `background` mode with `trigger` (never `chanscan`, which rides on
//! scans); channel changes are monitor channel changes; the packet socket is
//! only read. Every taken card's TX counters are read every second; if any
//! moves, every card is restored and the session stops. A card's previous
//! state is written to its own state file before anything changes, and
//! restored on exit, or at the next start after a crash.
const std = @import("std");
const linux = std.os.linux;
const fsx = @import("fsx.zig");
const nl = @import("nl80211.zig");
const cards = @import("cards.zig");
const ath9k = @import("ath9k.zig");
const detect = @import("detect.zig");
const sweep = @import("sweep.zig");
const radiotap = @import("radiotap.zig");

/// Short critical sections only (copies into and out of the rings).
pub const Lock = struct {
    m: std.atomic.Mutex = .unlocked,
    pub fn lock(self: *Lock) void {
        while (!self.m.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *Lock) void {
        self.m.unlock();
    }
};

pub fn Ring(comptime T: type) type {
    return struct {
        items: []T = &.{},
        head: usize = 0,
        len: usize = 0,
        total: u64 = 0,
        const Self = @This();
        pub fn init(a: std.mem.Allocator, n: usize) !Self {
            return .{ .items = try a.alloc(T, n) };
        }
        pub fn deinit(self: *Self, a: std.mem.Allocator) void {
            a.free(self.items);
        }
        pub fn push(self: *Self, v: T) void {
            if (self.items.len == 0) return;
            self.items[(self.head + self.len) % self.items.len] = v;
            if (self.len < self.items.len) self.len += 1 else self.head = (self.head + 1) % self.items.len;
            self.total += 1;
        }
        /// Pushes an entry that may be slightly older than the newest (several
        /// sensors deliver interleaved batches): it moves back into time order.
        pub fn pushOrdered(self: *Self, v: T, comptime time: fn (*const T) u64) void {
            if (self.items.len == 0) return;
            self.push(v);
            var i = self.len - 1;
            var steps: usize = 0;
            while (i > 0 and steps < 1024 and time(self.at(i - 1)) > time(self.at(i))) : (steps += 1) {
                std.mem.swap(T, &self.items[(self.head + i - 1) % self.items.len], &self.items[(self.head + i) % self.items.len]);
                i -= 1;
            }
        }
        pub fn at(self: *const Self, i: usize) *const T {
            return &self.items[(self.head + i) % self.items.len];
        }
        pub fn last(self: *const Self) ?*const T {
            return if (self.len == 0) null else self.at(self.len - 1);
        }
        fn first(self: *const Self, t: u64, comptime time: fn (*const T) u64) usize {
            var lo: usize = 0;
            var hi: usize = self.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (time(self.at(mid)) < t) lo = mid + 1 else hi = mid;
            }
            return lo;
        }
        /// Oldest-first copy of the entries in [from_ns, to_ns) (entries are time-ordered).
        pub fn since(self: *const Self, a: std.mem.Allocator, from_ns: u64, to_ns: u64, comptime time: fn (*const T) u64) ![]T {
            const lo = self.first(from_ns, time);
            const hi = @max(lo, self.first(to_ns, time));
            const out = try a.alloc(T, hi - lo);
            for (out, lo..) |*o, i| o.* = self.at(i).*;
            return out;
        }
    };
}

pub const LinkPoint = struct {
    mono_ns: u64,
    signal_dbm: ?i8 = null,
    /// Mbit/s.
    bitrate: ?f32 = null,
    /// Retries and failures per second over the last interval.
    retries_ps: ?f32 = null,
    failed_ps: ?f32 = null,
    /// Channel busy share over the last interval, 0..1.
    busy: ?f32 = null,
    noise_dbm: ?i8 = null,
};
pub const PingPoint = struct {
    mono_ns: u64,
    /// Round trip, microseconds; null = lost (no reply within 1 s).
    rtt_us: ?u32,
};
pub const Stamped = ath9k.Stamped;
fn stampedTime(x: *const Stamped) u64 {
    return x.mono_ns;
}
fn linkTime(x: *const LinkPoint) u64 {
    return x.mono_ns;
}
fn pingTime(x: *const PingPoint) u64 {
    return x.mono_ns;
}

/// What a chosen card looked like before xodb touched it.
pub const Saved = struct {
    iface: cards.Text(16) = .{},
    ifindex: u32 = 0,
    up: bool = false,
    iftype: u32 = nl.iftype.station,
    spectral_dir: cards.Text(96) = .{},
    ctl: cards.Text(16) = .{},
    count: u32 = 8,
    period: u32 = 0,
    fft_period: u32 = 0,
    short_repeat: u32 = 1,
    tx_packets: u64 = 0,
    tx_bytes: u64 = 0,
    /// The xodb process holding the card.
    pid: u32 = 0,
    /// /proc/sys/kernel/random/boot_id when written: a reboot resets the card anyway.
    boot: cards.Text(40) = .{},

    pub fn format(self: *const Saved, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "iface={s}\nifindex={d}\nup={d}\niftype={d}\nspectral_dir={s}\nctl={s}\ncount={d}\nperiod={d}\nfft_period={d}\nshort_repeat={d}\ntx_packets={d}\ntx_bytes={d}\npid={d}\nboot={s}\n", .{ self.iface.get(), self.ifindex, @intFromBool(self.up), self.iftype, self.spectral_dir.get(), self.ctl.get(), self.count, self.period, self.fft_period, self.short_repeat, self.tx_packets, self.tx_bytes, self.pid, self.boot.get() });
    }
    pub fn parse(text: []const u8) ?Saved {
        var s = Saved{};
        var seen: u32 = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
            const k = l[0..eq];
            const v = l[eq + 1 ..];
            const n = std.fmt.parseInt(u64, v, 10) catch 0;
            if (std.mem.eql(u8, k, "iface")) s.iface.set(v) else if (std.mem.eql(u8, k, "ifindex")) {
                s.ifindex = @intCast(@min(n, std.math.maxInt(u32)));
            } else if (std.mem.eql(u8, k, "up")) s.up = n != 0 else if (std.mem.eql(u8, k, "iftype")) {
                s.iftype = @intCast(@min(n, 12));
            } else if (std.mem.eql(u8, k, "spectral_dir")) s.spectral_dir.set(v) else if (std.mem.eql(u8, k, "ctl")) s.ctl.set(v) else if (std.mem.eql(u8, k, "count")) {
                s.count = @intCast(@min(n, 255));
            } else if (std.mem.eql(u8, k, "period")) {
                s.period = @intCast(@min(n, 255));
            } else if (std.mem.eql(u8, k, "fft_period")) {
                s.fft_period = @intCast(@min(n, 15));
            } else if (std.mem.eql(u8, k, "short_repeat")) {
                s.short_repeat = @intCast(@min(n, 1));
            } else if (std.mem.eql(u8, k, "pid")) {
                s.pid = @intCast(@min(n, std.math.maxInt(u32)));
            } else if (std.mem.eql(u8, k, "boot")) s.boot.set(v) else if (std.mem.eql(u8, k, "tx_packets")) s.tx_packets = n else if (std.mem.eql(u8, k, "tx_bytes")) s.tx_bytes = n else continue;
            seen += 1;
        }
        if (seen < 4 or s.iface.len == 0 or s.ifindex == 0) return null;
        // Only a card's own interface name and an ieee80211 debugfs directory are ever written.
        for (s.iface.get()) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return null;
        for (s.boot.get()) |ch| if (!std.ascii.isHex(ch) and ch != '-') return null;
        if (s.spectral_dir.len > 0 and (std.mem.indexOf(u8, s.spectral_dir.get(), "/ieee80211/phy") == null or std.mem.indexOf(u8, s.spectral_dir.get(), "..") != null)) return null;
        return s;
    }
};

/// Whether the xodb that wrote a state file still runs (then it owns the card).
pub fn ownerAlive(saved: *const Saved) bool {
    if (saved.pid == 0 or saved.pid == linux.getpid()) return false;
    var b: [32]u8 = undefined;
    const comm = fsx.line(&b, "/proc/{d}/comm", .{saved.pid}) orelse return false;
    return std.mem.eql(u8, comm, "xodb");
}

pub fn txCounters(roots: cards.Roots, iface: []const u8) [2]?u64 {
    return .{ fsx.number("{s}/class/net/{s}/statistics/tx_packets", .{ roots.sys, iface }), fsx.number("{s}/class/net/{s}/statistics/tx_bytes", .{ roots.sys, iface }) };
}

fn mkdirs(path: []const u8) void {
    var b: [512]u8 = undefined;
    var at: usize = 1;
    while (true) {
        const slash = std.mem.indexOfScalarPos(u8, path, at, '/') orelse path.len;
        const p = std.fmt.bufPrintZ(&b, "{s}", .{path[0..slash]}) catch return;
        _ = linux.mkdir(p, 0o755);
        if (slash >= path.len) return;
        at = slash + 1;
    }
}

/// Starts restore's answer when the card is not xodb's to put back.
pub const left_alone = "left alone: ";

/// Why the card must not be put back, or null: its name now belongs to
/// another interface (replugged), something else changed its mode, or it is
/// in use now (a manager took it).
fn notOurs(saved: *const Saved, roots: cards.Roots, sock: *nl.Socket, why: []u8) ?[]const u8 {
    const iface = saved.iface.get();
    const ifindex = fsx.number("{s}/class/net/{s}/ifindex", .{ roots.sys, iface }) orelse
        return std.fmt.bufPrint(why, left_alone ++ "{s} is gone", .{iface}) catch left_alone;
    if (ifindex != saved.ifindex) return std.fmt.bufPrint(why, left_alone ++ "{s} is another interface now (ifindex {d}, was {d})", .{ iface, ifindex, saved.ifindex }) catch left_alone;
    const now = sock.interface(saved.ifindex) catch return null;
    if (now.iftype != nl.iftype.monitor and now.iftype != saved.iftype) return std.fmt.bufPrint(why, left_alone ++ "something else changed {s}'s mode", .{iface}) catch left_alone;
    var list = cards.enumerate(roots, sock);
    if (list.find(iface)) |card| if (card.role == .in_use)
        return std.fmt.bufPrint(why, left_alone ++ "{s} is in use now ({s})", .{ iface, card.why.get() }) catch left_alone;
    return null;
}

/// Puts a card back: spectral off with its old settings, the old interface
/// type, and the old up/down state. Returns null, what failed, or why the
/// card was left alone (starts with `left_alone`; its spectral scan is still disabled).
pub fn restore(saved: *const Saved, roots: cards.Roots, why: []u8) ?[]const u8 {
    var failed: ?[]const u8 = null;
    var sock = nl.Socket.open() catch return "nl80211 unavailable";
    defer sock.close();
    const dir = saved.spectral_dir.get();
    const mine = notOurs(saved, roots, &sock, why);
    if (mine != null and dir.len > 0) {
        // Only the scan xodb started is stopped; the card itself is not touched.
        fsx.write("disable", "{s}/spectral_scan_ctl", .{dir}) catch {};
        return mine;
    }
    if (dir.len > 0) {
        fsx.write("disable", "{s}/spectral_scan_ctl", .{dir}) catch {
            failed = "spectral_scan_ctl";
        };
        var nb: [8]u8 = undefined;
        fsx.write(std.fmt.bufPrint(&nb, "{d}", .{saved.count}) catch "8", "{s}/spectral_count", .{dir}) catch {};
        fsx.write(std.fmt.bufPrint(&nb, "{d}", .{saved.period}) catch "18", "{s}/spectral_period", .{dir}) catch {};
        fsx.write(std.fmt.bufPrint(&nb, "{d}", .{saved.fft_period}) catch "2", "{s}/spectral_fft_period", .{dir}) catch {};
        fsx.write(std.fmt.bufPrint(&nb, "{d}", .{saved.short_repeat}) catch "1", "{s}/spectral_short_repeat", .{dir}) catch {};
        if (saved.ctl.len > 0 and !std.mem.eql(u8, saved.ctl.get(), "disable") and !std.mem.eql(u8, saved.ctl.get(), "chanscan"))
            fsx.write(saved.ctl.get(), "{s}/spectral_scan_ctl", .{dir}) catch {};
    }
    if (mine) |m| return m;
    const iface = saved.iface.get();
    nl.setUp(iface, false) catch |e| {
        failed = std.fmt.bufPrint(why, "down: {s}", .{@errorName(e)}) catch "down";
    };
    const now = sock.interface(saved.ifindex) catch nl.Interface{ .iftype = 0 };
    if (now.iftype != saved.iftype) sock.setType(saved.ifindex, saved.iftype) catch |e| {
        failed = std.fmt.bufPrint(why, "type: {s}", .{@errorName(e)}) catch "type";
    };
    if (saved.up) nl.setUp(iface, true) catch |e| {
        failed = std.fmt.bufPrint(why, "up: {s}", .{@errorName(e)}) catch "up";
    };
    return failed;
}

/// How long the traffic card stays on each channel. Every channel change costs
/// the driver an RF calibration (rtw89: about 30 ms of busy kernel time), so
/// 500 ms keeps that near 7% of a core; 14 channels take 7 s.
pub const traffic_dwell_ms: u32 = 500;
/// The fastest focus requests (a drag, `f`, double-click) retune the cards:
/// a user clicking or key-repeating wildly gets at most 4 retunes a second.
pub const focus_min_ns: u64 = 250_000_000;

pub const Config = struct {
    /// Explicitly chosen spectral cards (`--radio NAME[,NAME...]`, up to four).
    radio: ?[]const u8 = null,
    /// Explicitly chosen card for receive-only traffic counts (`--traffic NAME`).
    traffic: ?[]const u8 = null,
    /// One fixed channel (`--channel N`); otherwise the sensors sweep the band.
    channel: ?u8 = null,
    /// Older option: sweep (now the default when no channel is given).
    hop: bool = false,
    /// A starting focus span (`--focus LO-HI`).
    focus: ?sweep.Request = null,
    dwell_ms: u32 = sweep.resolve_dwell_ms,
    roots: cards.Roots = .{},
    /// Directory for the restore state files (XDG state); null: no takeover allowed.
    state_dir: ?[]const u8 = null,
    /// Spectral period/fft_period (driver units; smaller is faster).
    period: u8 = 16,
    fft_period: u8 = 1,
    /// Ping a fixed IPv4 address instead of the link's gateway (tests).
    ping: ?[4]u8 = null,
    /// Ping the in-use link's gateway at 50 Hz (`--ping` / `--radio-ping`). Off by
    /// default: listening sends nothing. It is the one thing xodb sends, ordinary
    /// ICMP echo bound to the in-use interface, never from a card xodb holds.
    ping_gateway: bool = false,
    spectral_ring: usize = 1 << 19,
    /// Synthetic spectrum (and traffic) instead of cards (demos, GUI tests): off/on cycles of this scene.
    demo: ?detect.Synth.Scene = null,
    /// Synthetic sensors in the demo (the N-sensor planner without the hardware).
    demo_sensors: u8 = 1,
    /// Diagnostic: tune the spectral cards HT40+ (HT40- above channel 7) to see
    /// whether the driver delivers HT20/40 records (counted in `counts.ht40`).
    ht40: bool = false,

    /// The sweep request this configuration starts with.
    pub fn request(self: *const Config) sweep.Request {
        if (self.focus) |f| return f;
        if (self.channel) |c| {
            const f = sweep.channelMhz(c);
            return .{ .mode = .fixed, .lo_mhz = f - 10, .hi_mhz = f + 10, .dwell_ms = self.dwell_ms };
        }
        return .{ .dwell_ms = self.dwell_ms };
    }
};

const state_prefix = "radio-restore";
/// One restore file per taken card; R2 wrote a single `radio-restore`.
fn statePath(buf: []u8, dir: []const u8, iface: ?[]const u8) ?[:0]const u8 {
    if (iface) |i| return std.fmt.bufPrintZ(buf, "{s}/" ++ state_prefix ++ "-{s}", .{ dir, i }) catch null;
    return std.fmt.bufPrintZ(buf, "{s}/" ++ state_prefix, .{dir}) catch null;
}

/// Restores every card left in the state directory by an earlier session
/// (one that crashed or was killed). Returns what was done, or null with nothing to do.
pub fn recover(buf: []u8, state_dir: ?[]const u8, roots: cards.Roots) ?[]const u8 {
    const dir = state_dir orelse return null;
    var names: [8][64]u8 = undefined;
    var lens: [8]usize = undefined;
    var n: usize = 0;
    const Ctx = struct { names: *[8][64]u8, lens: *[8]usize, n: *usize };
    fsx.list("{s}", .{dir}, Ctx{ .names = &names, .lens = &lens, .n = &n }, struct {
        fn f(ctx: Ctx, name: []const u8) bool {
            if (!std.mem.startsWith(u8, name, state_prefix) or name.len > 64) return true;
            @memcpy(ctx.names[ctx.n.*][0..name.len], name);
            ctx.lens[ctx.n.*] = name.len;
            ctx.n.* += 1;
            return ctx.n.* < 8;
        }
    }.f);
    if (n == 0) return null;
    var w = std.Io.Writer.fixed(buf);
    for (names[0..n], lens[0..n], 0..) |*nm, len, k| {
        const sep = if (k > 0) "; " else "";
        var pb: [512]u8 = undefined;
        const path = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, nm[0..len] }) catch continue;
        var tb: [1024]u8 = undefined;
        const text = fsx.read(&tb, "{s}", .{path}) orelse continue;
        const saved = Saved.parse(text) orelse {
            w.print("{s}radio restore file {s} is unreadable; left in place", .{ sep, path }) catch {};
            continue;
        };
        if (ownerAlive(&saved)) {
            w.print("{s}{s} is held by xodb pid {d}; leaving it to that process", .{ sep, saved.iface.get(), saved.pid }) catch {};
            continue;
        }
        var bb: [64]u8 = undefined;
        if (saved.boot.len > 0) if (fsx.line(&bb, "{s}/sys/kernel/random/boot_id", .{roots.proc})) |boot| if (!std.mem.eql(u8, boot, saved.boot.get())) {
            _ = linux.unlink(path);
            w.print("{s}removed a restore file for {s} from before the last reboot (nothing to restore)", .{ sep, saved.iface.get() }) catch {};
            continue;
        };
        if (!fsx.isRoot()) {
            w.print("{s}an earlier session left {s} in monitor mode; run xodb as root once to restore it", .{ sep, saved.iface.get() }) catch {};
            continue;
        }
        var why: [200]u8 = undefined;
        const result = restore(&saved, roots, &why);
        const left = if (result) |r| std.mem.startsWith(u8, r, left_alone) else false;
        if (result == null or left) _ = linux.unlink(path);
        if (left) {
            w.print("{s}did not restore {s} from an earlier session's state file, {s}", .{ sep, saved.iface.get(), result.? }) catch {};
            continue;
        }
        w.print("{s}restored {s} from an earlier session's state file{s}{s}", .{ sep, saved.iface.get(), if (result != null) ": " else "", result orelse "" }) catch {};
    }
    const t = w.buffered();
    return if (t.len == 0) null else t;
}

/// The restore file of another live xodb that holds `iface`, if any.
fn heldByOther(dir: []const u8, iface: []const u8) ?Saved {
    for ([_]?[]const u8{ iface, null }) |name| {
        var pb: [512]u8 = undefined;
        var tb: [1024]u8 = undefined;
        const p = statePath(&pb, dir, name) orelse continue;
        const t = fsx.read(&tb, "{s}", .{p}) orelse continue;
        const other = Saved.parse(t) orelse continue;
        if (std.mem.eql(u8, other.iface.get(), iface)) return other;
    }
    return null;
}

/// One spectral sensor: a taken ath9k card, or a synthetic one in the demo.
const Sensor = struct {
    saved: Saved = .{},
    files: [64]i32 = undefined,
    n_files: usize = 0,
    carry: [64][128]u8 = undefined,
    carried: [64]usize = @splat(0),
    tsf_offset_ns: ?i128 = null,
    tsf_spread_ns: u64 = 0,
    last_sample_ns: u64 = 0,
    last_trigger: u64 = 0,
    /// Position in this sensor's plan assignment, and when to move on.
    at: usize = 0,
    next_hop: u64 = 0,
    freq_mhz: u32 = 0,
    /// Clock: TSF steps the mapping re-anchored on, and the latest sample's lag behind its read.
    tsf_steps: u32 = 0,
    lag_ns: u64 = 0,
    /// Samples held back: their TSF disagreed with the mapping (garbage, or a step not yet confirmed).
    rejected: u64 = 0,
    /// A candidate new offset (a TSF step), the read it was first seen at, and in how many reads.
    cand_off: ?i128 = null,
    cand_first: u64 = 0,
    cand_last: u64 = 0,
    cand_reads: u32 = 0,
    /// The watchdog: triggers written after silence, full re-arms after longer silence.
    retriggers: u32 = 0,
    rearms: u32 = 0,
    last_rearm: u64 = 0,
    /// Demo: the synthetic clock (us) and the next 100 ms step.
    demo_t: u64 = 0,
    demo_next: u64 = 0,
};

/// The receive-only traffic card: monitor mode, a packet socket, channel hopping.
const TrafficCard = struct {
    saved: Saved = .{},
    fd: i32 = -1,
    channels: [14]u8 = undefined,
    n: usize = 0,
    at: usize = 0,
    next_hop: u64 = 0,
    cur: radiotap.Dwell = .{},
    key: [16]u8 = undefined,
    demo: bool = false,
    demo_next: u64 = 0,
    seed: u64 = 1,
};

/// A sample delivered this much later than the envelope says is a TSF step.
pub const tsf_step_ns: i128 = 250_000_000;

pub const TxEntry = struct { iface: cards.Text(16), before: [2]u64, now: [2]?u64 };

pub const Monitor = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    mutex: Lock = .{},
    thread: ?std.Thread = null,
    /// The traffic card runs on its own thread: its channel changes (an RF
    /// calibration in the driver) must never hold up reading the spectral relays.
    traffic_thread: ?std.Thread = null,
    traffic_stop: std.atomic.Value(bool) = .init(false),
    traffic_replan: std.atomic.Value(u32) = .init(0),
    /// The blocking driver call each thread is in, and since when (0: none):
    /// a stall names its cause.
    busy_op: cards.Text(64) = .{},
    busy_since: u64 = 0,
    traffic_busy_op: cards.Text(64) = .{},
    traffic_busy_since: u64 = 0,
    stop: std.atomic.Value(bool) = .init(false),
    started_ns: u64 = 0,
    status: cards.Text(400) = .{},
    recovered: cards.Text(400) = .{},

    // Spectral sensors.
    sensors: [sweep.max_sensors]Sensor = @splat(.{}),
    n_sensors: usize = 0,
    spectral_on: bool = false,
    demo_on: bool = false,
    spectral_iface: cards.Text(64) = .{},
    /// The first sensor's current window centre.
    freq_mhz: u32 = 0,
    samples: Ring(Stamped) = .{},
    counts: ath9k.Counts = .{},
    tsf_offset_ns: ?i128 = null,
    tsf_spread_ns: u64 = 0,
    // The plan, and focus requests from the panel or CLI.
    request: sweep.Request = .{},
    plan: sweep.Plan = .{},
    plan_generation: u64 = 0,
    pending: ?sweep.Request = null,
    pending_generation: u64 = 0,
    allowed: u16 = sweep.all_channels,

    // Traffic card.
    traffic: TrafficCard = .{},
    traffic_on: bool = false,
    traffic_iface: cards.Text(16) = .{},
    traffic_status: cards.Text(200) = .{},
    dwells: Ring(radiotap.Dwell) = .{},
    traffic_counts: struct { packets: u64 = 0, unparsed: u64 = 0, other_channel: u64 = 0 } = .{},

    tx_moved: bool = false,
    /// Every card taken this session, with its TX counters at take time and now.
    taken: [sweep.max_sensors + 1]?Saved = @splat(null),
    tx_now: [sweep.max_sensors + 1][2]?u64 = @splat(.{ null, null }),
    /// A taken card already put back (a take that failed half way): the
    /// per-second checks leave it alone; it is only reported.
    put_back: [sweep.max_sensors + 1]bool = @splat(false),

    // Passive link (in-use card).
    link_iface: cards.Text(16) = .{},
    link_ifindex: u32 = 0,
    link_why: cards.Text(160) = .{},
    links: Ring(LinkPoint) = .{},
    pings: Ring(PingPoint) = .{},
    gateway: ?[4]u8 = null,
    ping_why: cards.Text(120) = .{},

    pub fn start(gpa: std.mem.Allocator, cfg: Config) !*Monitor {
        const self = try gpa.create(Monitor);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .cfg = cfg, .started_ns = fsx.monotonicNs() };
        self.links = try Ring(LinkPoint).init(gpa, 4096);
        self.pings = try Ring(PingPoint).init(gpa, 50 * 600);
        self.request = cfg.request();
        var rb: [400]u8 = undefined;
        if (recover(&rb, cfg.state_dir, cfg.roots)) |r| self.recovered.set(r);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    /// Stops the thread; the chosen cards are restored before this returns.
    pub fn halt(self: *Monitor) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }
    pub fn deinit(self: *Monitor) void {
        self.halt();
        self.links.deinit(self.gpa);
        self.pings.deinit(self.gpa);
        self.samples.deinit(self.gpa);
        self.dwells.deinit(self.gpa);
        self.gpa.destroy(self);
    }
    fn setStatus(self: *Monitor, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.status.len = 0;
        self.status.add(fmt, args);
    }
    fn addStatus(self: *Monitor, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.status.add(fmt, args);
    }
    pub fn statusText(self: *Monitor, buf: []u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const t = self.status.get();
        const n = @min(t.len, buf.len);
        @memcpy(buf[0..n], t[0..n]);
        return buf[0..n];
    }

    // --- Focus (panel, CLI, tests) --------------------------------------------------

    /// Asks the collector to retune: a focus span, or null for the full sweep.
    /// Applied by the collector thread at once (receive-only channel changes).
    pub fn focus(self: *Monitor, req: ?sweep.Request) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var r = req orelse sweep.Request{};
        r.dwell_ms = self.cfg.dwell_ms;
        self.pending = r;
        self.pending_generation +%= 1;
    }
    pub const PlanInfo = struct { plan: sweep.Plan, request: sweep.Request, generation: u64, sensors: usize, centres: [sweep.max_sensors]u32 };
    pub fn planInfo(self: *Monitor) PlanInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        var info = PlanInfo{ .plan = self.plan, .request = self.request, .generation = self.plan_generation, .sensors = self.n_sensors, .centres = @splat(0) };
        for (self.sensors[0..self.n_sensors], 0..) |*s, i| info.centres[i] = s.freq_mhz;
        return info;
    }
    /// The sample ring has wrapped: older samples are gone.
    pub fn ringFull(self: *Monitor) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.samples.items.len > 0 and self.samples.len == self.samples.items.len;
    }
    pub const Clock = struct { steps: u32, lag_ms: f32 };
    /// TSF steps re-anchored on (all sensors) and the first sensor's latest delivery lag.
    pub fn clock(self: *Monitor) Clock {
        self.mutex.lock();
        defer self.mutex.unlock();
        var steps: u32 = 0;
        for (&self.sensors) |*s| steps += s.tsf_steps;
        return .{ .steps = steps, .lag_ms = @as(f32, @floatFromInt(self.sensors[0].lag_ns)) / 1e6 };
    }
    /// Changes whenever a sample or a traffic dwell lands (for redraw decisions).
    pub fn generation(self: *Monitor) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.samples.total +% (self.dwells.total << 32) +% self.traffic.cur.frames;
    }

    // --- Taking cards ---------------------------------------------------------------

    /// Writes the restore file and records the card; nothing is changed yet.
    fn save(self: *Monitor, card: *const cards.Card, spectral: bool) !Saved {
        var rb: [400]u8 = undefined;
        if (card.refusal(&rb)) |why| {
            self.addStatus("{s}", .{why});
            return error.Refused;
        }
        if (spectral and card.spectral != .ath9k) {
            self.addStatus("{s} ({s}) has no spectral scan xodb can read", .{ card.iface.get(), card.driver.get() });
            return error.Refused;
        }
        if (!spectral and !(card.monitor orelse false)) {
            self.addStatus("{s} ({s}) does not support monitor mode", .{ card.iface.get(), card.driver.get() });
            return error.Refused;
        }
        if (!fsx.isRoot()) {
            self.addStatus("{s} needs root: run xodb as root with --{s} {s}", .{ if (spectral) "spectrum" else "traffic", if (spectral) "radio" else "traffic", card.iface.get() });
            return error.Refused;
        }
        if (spectral and !card.spectral_checked) {
            self.addStatus("{s}: no spectral_scan_ctl in debugfs (is debugfs mounted at {s}?)", .{ card.iface.get(), self.cfg.roots.debug });
            return error.Refused;
        }
        const dir = self.cfg.state_dir orelse {
            self.addStatus("no state directory for the restore file: refusing to change {s}", .{card.iface.get()});
            return error.Refused;
        };
        if (heldByOther(dir, card.iface.get())) |other| {
            self.addStatus("{s} is held by another xodb (pid {d}); not taking it", .{ other.iface.get(), other.pid });
            return error.Refused;
        }
        var s = Saved{ .ifindex = card.ifindex, .up = card.up, .iftype = card.iftype orelse nl.iftype.station, .pid = @intCast(linux.getpid()) };
        s.iface.set(card.iface.get());
        var bb: [64]u8 = undefined;
        s.boot.set(fsx.line(&bb, "{s}/sys/kernel/random/boot_id", .{self.cfg.roots.proc}) orelse "");
        if (spectral) {
            s.spectral_dir.set(card.spectral_dir.get());
            var b: [32]u8 = undefined;
            s.ctl.set(fsx.line(&b, "{s}/spectral_scan_ctl", .{s.spectral_dir.get()}) orelse "disable");
            s.count = @intCast(@min(255, fsx.number("{s}/spectral_count", .{s.spectral_dir.get()}) orelse 8));
            s.period = @intCast(@min(255, fsx.number("{s}/spectral_period", .{s.spectral_dir.get()}) orelse 18));
            s.fft_period = @intCast(@min(15, fsx.number("{s}/spectral_fft_period", .{s.spectral_dir.get()}) orelse 2));
            s.short_repeat = @intCast(@min(1, fsx.number("{s}/spectral_short_repeat", .{s.spectral_dir.get()}) orelse 1));
        }
        const tx = txCounters(self.cfg.roots, s.iface.get());
        if (tx[0] == null or tx[1] == null) {
            self.addStatus("{s} has no readable TX counters, so receive-only cannot be checked: not taking it", .{s.iface.get()});
            return error.Refused;
        }
        s.tx_packets = tx[0].?;
        s.tx_bytes = tx[1].?;
        // The state file goes first: a crash from here on is recoverable.
        mkdirs(dir);
        var pb: [512]u8 = undefined;
        const path = statePath(&pb, dir, s.iface.get()) orelse return error.Refused;
        var fb: [1024]u8 = undefined;
        {
            // Exclusive: of two xodbs starting at once, one holds the card.
            const text = try s.format(&fb);
            const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
            if (linux.errno(rc) == .EXIST) {
                self.addStatus("a restore file {s} already exists (another xodb, or unreadable): not taking {s}", .{ path, s.iface.get() });
                return error.Refused;
            }
            if (linux.errno(rc) != .SUCCESS) {
                self.addStatus("cannot write the restore file {s}: refusing to change {s}", .{ path, s.iface.get() });
                return error.Refused;
            }
            const n = linux.write(@intCast(rc), text.ptr, text.len);
            const synced = linux.errno(linux.fsync(@intCast(rc))) == .SUCCESS;
            _ = linux.close(@intCast(rc));
            if (linux.errno(n) != .SUCCESS or n != text.len or !synced) {
                _ = linux.unlink(path);
                self.addStatus("cannot write the restore file {s}: refusing to change {s}", .{ path, s.iface.get() });
                return error.Refused;
            }
        }
        self.mutex.lock();
        for (&self.taken) |*t| if (t.* == null) {
            t.* = s;
            break;
        };
        self.mutex.unlock();
        return s;
    }
    /// Monitor mode, up, on its first channel. On failure the card is restored.
    fn toMonitor(self: *Monitor, sock: *nl.Socket, s: *const Saved, mhz: u32) !void {
        errdefer self.restoreOne(s);
        const iface = s.iface.get();
        try nl.setUp(iface, false);
        try sock.setType(s.ifindex, nl.iftype.monitor);
        nl.setUp(iface, true) catch |e| {
            self.addStatus("{s}: could not bring it up in monitor mode ({s}); restored", .{ iface, @errorName(e) });
            return e;
        };
        try sock.setFreqType(s.ifindex, mhz, self.channelType(s.spectral_dir.len > 0, mhz));
    }
    fn channelType(self: *const Monitor, spectral: bool, mhz: u32) u32 {
        return if (spectral and self.cfg.ht40) (if (mhz > 2442) @as(u32, 2) else 3) else 0;
    }
    fn takeSensor(self: *Monitor, sock: *nl.Socket, card: *const cards.Card) !void {
        const s = try self.save(card, true);
        const k = self.n_sensors;
        if (self.samples.items.len == 0) {
            const ring_ = try Ring(Stamped).init(self.gpa, self.cfg.spectral_ring);
            self.mutex.lock();
            self.samples = ring_;
            self.mutex.unlock();
        }
        const mhz = self.plan.per[k].centres[0];
        try self.toMonitor(sock, &s, if (mhz != 0) mhz else 2457);
        errdefer self.restoreOne(&s);
        var nb: [8]u8 = undefined;
        const sd = s.spectral_dir.get();
        try fsx.write("1", "{s}/spectral_short_repeat", .{sd});
        try fsx.write(try std.fmt.bufPrint(&nb, "{d}", .{self.cfg.period}), "{s}/spectral_period", .{sd});
        try fsx.write(try std.fmt.bufPrint(&nb, "{d}", .{self.cfg.fft_period}), "{s}/spectral_fft_period", .{sd});
        // Background (endless), then trigger. Never chanscan.
        try fsx.write("background", "{s}/spectral_scan_ctl", .{sd});
        try fsx.write("trigger", "{s}/spectral_scan_ctl", .{sd});
        const sensor = &self.sensors[k];
        sensor.* = .{ .saved = s, .freq_mhz = if (mhz != 0) mhz else 2457, .last_trigger = fsx.monotonicNs() };
        sensor.n_files = openRelays(sd, &sensor.files);
        self.mutex.lock();
        self.n_sensors += 1;
        self.spectral_on = true;
        if (self.spectral_iface.len > 0) self.spectral_iface.add("{s}", .{s.iface.get()}) else self.spectral_iface.set(s.iface.get());
        if (k == 0) self.freq_mhz = sensor.freq_mhz;
        self.mutex.unlock();
    }
    fn takeTraffic(self: *Monitor, sock: *nl.Socket, card: *const cards.Card) !void {
        const s = try self.save(card, false);
        if (self.dwells.items.len == 0) {
            const ring_ = try Ring(radiotap.Dwell).init(self.gpa, 4096);
            self.mutex.lock();
            self.dwells = ring_;
            self.mutex.unlock();
        }
        const t = &self.traffic;
        t.* = .{ .saved = s };
        self.trafficChannels();
        try self.toMonitor(sock, &s, sweep.channelMhz(t.channels[0]));
        errdefer self.restoreOne(&s);
        // A packet socket only receives: xodb never writes to it.
        const rc = linux.socket(linux.AF.PACKET, linux.SOCK.RAW | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, std.mem.nativeToBig(u16, 3));
        if (linux.errno(rc) != .SUCCESS) return error.PacketSocket;
        t.fd = @intCast(rc);
        const size: i32 = 4 << 20;
        _ = linux.setsockopt(t.fd, linux.SOL.SOCKET, linux.SO.RCVBUF, std.mem.asBytes(&size), 4);
        var ll = linux.sockaddr.ll{ .protocol = std.mem.nativeToBig(u16, 3), .ifindex = @intCast(s.ifindex), .hatype = 0, .pkttype = 0, .halen = 0, .addr = @splat(0) };
        if (linux.errno(linux.bind(t.fd, @ptrCast(&ll), @sizeOf(linux.sockaddr.ll))) != .SUCCESS) {
            _ = linux.close(t.fd);
            t.fd = -1;
            return error.PacketSocket;
        }
        _ = linux.getrandom(&t.key, t.key.len, 0);
        self.startDwell(fsx.monotonicNs());
        self.mutex.lock();
        self.traffic_on = true;
        self.traffic_iface.set(s.iface.get());
        self.mutex.unlock();
    }
    /// The traffic card hops the channels the plan's span covers (all 14 by default).
    fn trafficChannels(self: *Monitor) void {
        const t = &self.traffic;
        t.n = 0;
        self.mutex.lock();
        const req = self.request;
        const allowed = self.allowed;
        self.mutex.unlock();
        const lo = if (req.mode == .sweep) sweep.band_lo else req.lo_mhz;
        const hi = if (req.mode == .sweep) sweep.band_hi else req.hi_mhz;
        for (1..15) |c| {
            const f = sweep.channelMhz(@intCast(c));
            if (f + 11 > lo and f - 11 < hi and allowed & (@as(u16, 1) << @intCast(c)) != 0) {
                t.channels[t.n] = @intCast(c);
                t.n += 1;
            }
        }
        if (t.n == 0) {
            t.channels[0] = 6;
            t.n = 1;
        }
        t.at = 0;
    }
    fn startDwell(self: *Monitor, now: u64) void {
        const t = &self.traffic;
        self.mutex.lock();
        t.cur = .{ .channel = t.channels[t.at], .from_ns = now, .to_ns = now };
        self.mutex.unlock();
        t.next_hop = now + @as(u64, traffic_dwell_ms) * 1_000_000;
    }
    fn endDwell(self: *Monitor, now: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.traffic.cur.to_ns = now;
        self.dwells.push(self.traffic.cur);
    }

    fn restoreOne(self: *Monitor, s: *const Saved) void {
        var why: [200]u8 = undefined;
        const failed = restore(s, self.cfg.roots, &why);
        const left = if (failed) |f| std.mem.startsWith(u8, f, left_alone) else false;
        const tx = txCounters(self.cfg.roots, s.iface.get());
        self.mutex.lock();
        for (self.taken, 0..) |t, i| if (t != null and t.?.ifindex == s.ifindex) {
            self.tx_now[i] = tx;
            self.put_back[i] = true;
        };
        if (left) self.recovered.set(failed.?);
        self.mutex.unlock();
        if (failed == null or left) if (self.cfg.state_dir) |dir| {
            var pb: [512]u8 = undefined;
            if (statePath(&pb, dir, s.iface.get())) |p| _ = linux.unlink(p);
        };
    }
    /// Restores every taken card and removes their state files.
    fn release(self: *Monitor) void {
        self.mutex.lock();
        const n = self.n_sensors;
        const had_traffic = self.traffic_on;
        self.spectral_on = false;
        self.traffic_on = false;
        self.n_sensors = 0;
        self.mutex.unlock();
        for (self.sensors[0..n]) |*s| {
            for (s.files[0..s.n_files]) |fd| _ = linux.close(fd);
            s.n_files = 0;
            if (!self.demo_on) self.restoreOne(&s.saved);
        }
        if (self.traffic_thread) |th| {
            self.traffic_stop.store(true, .release);
            th.join();
            self.traffic_thread = null;
        }
        if (had_traffic) {
            if (self.traffic.fd >= 0) _ = linux.close(self.traffic.fd);
            self.traffic.fd = -1;
            if (!self.traffic.demo) self.restoreOne(&self.traffic.saved);
        }
    }

    /// TX counters of every card taken this session, at take time and now.
    pub fn txReports(self: *Monitor, out: []TxEntry) []TxEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.taken, self.tx_now) |t, now| if (t) |s| {
            if (n == out.len) break;
            out[n] = .{ .iface = s.iface, .before = .{ s.tx_packets, s.tx_bytes }, .now = now };
            n += 1;
        };
        return out[0..n];
    }

    // --- Planning ---------------------------------------------------------------------

    fn replan(self: *Monitor, req: sweep.Request, sensors: usize) void {
        var r = req;
        r.allowed = self.allowed;
        const p = sweep.plan(r, @intCast(@max(1, sensors)));
        self.mutex.lock();
        self.request = r;
        self.plan = p;
        self.plan_generation +%= 1;
        self.mutex.unlock();
    }
    fn busy(self: *Monitor, op: *cards.Text(64), since: *u64, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        op.len = 0;
        op.add(fmt, args);
        since.* = fsx.monotonicNs();
    }
    fn idle(self: *Monitor, since: *u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        since.* = 0;
    }
    /// Moves sensor `k` to `mhz`; a channel the card refuses leaves the plan.
    fn tune(self: *Monitor, sock: ?*nl.Socket, k: usize, mhz: u32, now: u64) bool {
        const s = &self.sensors[k];
        if (!self.demo_on) {
            const sk = sock orelse return false;
            self.busy(&self.busy_op, &self.busy_since, "retune {s} to {d} MHz", .{ s.saved.iface.get(), mhz });
            defer self.idle(&self.busy_since);
            sk.setFreqType(s.saved.ifindex, mhz, self.channelType(true, mhz)) catch {
                // The traffic thread reads `allowed` too.
                self.mutex.lock();
                defer self.mutex.unlock();
                if (sweep.channelOf(@intCast(mhz))) |c| self.allowed &= ~(@as(u16, 1) << @intCast(c));
                return false;
            };
            fsx.write("trigger", "{s}/spectral_scan_ctl", .{s.saved.spectral_dir.get()}) catch {};
            s.last_trigger = now;
        }
        s.freq_mhz = mhz;
        if (k == 0) {
            self.mutex.lock();
            self.freq_mhz = mhz;
            self.mutex.unlock();
        }
        return true;
    }
    /// Puts every sensor on the first window of its (new) assignment.
    fn applyPlan(self: *Monitor, sock: ?*nl.Socket, now: u64) void {
        var tries: usize = 0;
        while (tries < 3) : (tries += 1) {
            var ok = true;
            for (0..self.n_sensors) |k| {
                const a = &self.plan.per[k];
                const s = &self.sensors[k];
                s.at = 0;
                s.next_hop = now + @as(u64, self.plan.dwell_ms) * 1_000_000;
                if (a.n == 0) continue;
                if (!self.tune(sock, k, a.centres[0], now)) ok = false;
            }
            if (ok) break;
            self.replan(self.request, self.n_sensors);
        }
        if (self.traffic_on) {
            if (self.traffic_thread != null) {
                _ = self.traffic_replan.fetchAdd(1, .release);
            } else {
                self.endDwell(now);
                self.trafficChannels();
                self.hopTraffic(sock, now, true);
            }
        }
    }

    /// The traffic card's own loop: frames into dwells, and the next channel after each.
    fn trafficLoop(self: *Monitor) void {
        var sock_storage: nl.Socket = undefined;
        const sock: ?*nl.Socket = if (nl.Socket.open()) |s| blk: {
            sock_storage = s;
            break :blk &sock_storage;
        } else |_| null;
        defer if (sock) |s| s.close();
        var applied: u32 = 0;
        while (!self.traffic_stop.load(.acquire)) {
            const now = fsx.monotonicNs();
            const want = self.traffic_replan.load(.acquire);
            if (want != applied) {
                applied = want;
                self.endDwell(now);
                self.trafficChannels();
                self.hopTraffic(sock, now, true);
            }
            self.readTraffic(sock, now);
            const ts = linux.timespec{ .sec = 0, .nsec = 2_000_000 };
            _ = linux.nanosleep(&ts, null);
        }
    }

    // --- The loop -------------------------------------------------------------------

    fn run(self: *Monitor) void {
        var sock_storage: nl.Socket = undefined;
        const sock: ?*nl.Socket = if (nl.Socket.open()) |s| blk: {
            sock_storage = s;
            break :blk &sock_storage;
        } else |_| null;
        defer if (sock) |s| s.close();
        var list = cards.enumerate(self.cfg.roots, sock);
        if (self.cfg.radio) |want| {
            var names = std.mem.tokenizeScalar(u8, want, ',');
            var wanted: usize = 0;
            while (names.next()) |_| wanted += 1;
            self.replan(self.request, @min(wanted, sweep.max_sensors));
            names = std.mem.tokenizeScalar(u8, want, ',');
            while (names.next()) |name| {
                if (self.n_sensors == sweep.max_sensors) break;
                if (list.find(name)) |card| {
                    if (sock) |s| self.takeSensor(s, card) catch {} else self.addStatus("nl80211 unavailable: cannot use {s}", .{name});
                } else self.addStatus("--radio {s}: no such Wi-Fi interface", .{name});
            }
            // Plan for the sensors actually taken.
            if (self.n_sensors > 0 and self.n_sensors != wanted) {
                self.replan(self.request, self.n_sensors);
                self.applyPlan(sock, fsx.monotonicNs());
            }
        } else if (self.cfg.demo) |scene| {
            const n = std.math.clamp(self.cfg.demo_sensors, 1, sweep.max_sensors);
            self.samples = Ring(Stamped).init(self.gpa, self.cfg.spectral_ring) catch .{};
            self.demo_on = true;
            self.replan(self.request, n);
            const now = fsx.monotonicNs();
            for (0..n) |k| {
                const mhz = self.plan.per[k].centres[0];
                self.sensors[k] = .{ .freq_mhz = mhz, .next_hop = now + @as(u64, self.plan.dwell_ms) * 1_000_000, .demo_next = now, .demo_t = 1000 + k * 7_000_000_000 };
            }
            self.n_sensors = n;
            self.freq_mhz = self.sensors[0].freq_mhz;
            self.spectral_iface.set("demo");
            self.setStatus("SYNTHETIC demo spectrum and traffic ({s}, 10 s off / 15 s on, {d} sensor{s}): no radio is read", .{ @tagName(scene), n, if (n == 1) "" else "s" });
            self.dwells = Ring(radiotap.Dwell).init(self.gpa, 4096) catch .{};
            self.traffic = .{ .demo = true, .key = @splat(0x5a) };
            self.trafficChannels();
            self.startDwell(now);
            self.traffic.demo_next = now;
            self.traffic_on = true;
            self.traffic_iface.set("demo");
        } else self.setStatus("passive: no card chosen for spectrum (--radio NAME)", .{});
        if (self.cfg.traffic) |want| {
            if (list.find(want)) |card| {
                if (sock) |s| self.takeTraffic(s, card) catch |e| {
                    if (e != error.Refused) self.addStatus("{s}: traffic capture failed ({s}); restored", .{ want, @errorName(e) });
                } else self.addStatus("nl80211 unavailable: cannot use {s}", .{want});
            } else self.addStatus("--traffic {s}: no such Wi-Fi interface", .{want});
        }
        if (self.spectral_on or self.traffic_on) {
            var pb: [240]u8 = undefined;
            const plan_text = self.plan.describe(&pb);
            if (!self.demo_on) {
                var b: [400]u8 = undefined;
                var w = std.Io.Writer.fixed(&b);
                if (self.spectral_on) w.print("spectral scan on {s}, {s}, monitor mode, receive-only", .{ self.spectral_iface.get(), plan_text }) catch {};
                if (self.traffic_on) w.print("{s}traffic counts on {s} (receive-only monitor, {d} ms per channel)", .{ if (self.spectral_on) "; " else "", self.traffic_iface.get(), traffic_dwell_ms }) catch {};
                const prior = self.status.get();
                var pr: [400]u8 = undefined;
                const keep = pr[0..prior.len];
                @memcpy(keep, prior);
                self.setStatus("{s}{s}{s}", .{ w.buffered(), if (keep.len > 0) "; " else "", keep });
            }
        }
        if (self.traffic_on) self.traffic_thread = std.Thread.spawn(.{}, trafficLoop, .{self}) catch null;
        self.pickLink(&list);

        var ping = Ping.open(self);
        defer ping.close();
        var last_link: u64 = 0;
        var last_tx: u64 = 0;
        var prev_station: ?nl.Station = null;
        var prev_survey: ?nl.Survey = null;
        var prev_link_ns: u64 = 0;
        var buf: [65536]u8 = undefined;
        var batch: [1024]ath9k.Sample = undefined;
        var applied: u64 = 0;
        var last_focus: u64 = 0;
        while (!self.stop.load(.acquire)) {
            const now = fsx.monotonicNs();
            // A focus request: replan and retune at once, but at most every
            // focus_min_ns (each retune costs the cards an RF calibration); requests
            // in between collapse into the newest.
            self.mutex.lock();
            const due = now -| last_focus >= focus_min_ns;
            const want = if (due and self.pending_generation != applied) self.pending else null;
            if (due) applied = self.pending_generation;
            self.mutex.unlock();
            if (want != null) last_focus = now;
            if (want) |req| if (self.n_sensors > 0 or self.traffic_on) {
                self.replan(req, self.n_sensors);
                self.applyPlan(sock, now);
            };
            for (self.sensors[0..self.n_sensors], 0..) |*sensor, k| {
                if (!self.demo_on) {
                    self.readSensor(k, &buf, &batch);
                    self.watchdog(sock, k, now);
                } else if (self.cfg.demo) |scene| if (now >= sensor.demo_next) {
                    // 100 ms of synthetic samples per step, quiet for 10 s then the scene for 15 s.
                    const on = (sensor.demo_t / 100_000) % 250 >= 100;
                    const synth = if (scene == .kitchen)
                        detect.Synth{ .scene = .kitchen, .mains_on = on, .freq_mhz = @intCast(sensor.freq_mhz), .seconds = 0.1, .seed = sensor.demo_t + 1 }
                    else
                        detect.Synth{ .scene = if (on) scene else .empty, .freq_mhz = @intCast(sensor.freq_mhz), .seconds = 0.1, .seed = sensor.demo_t + 1 };
                    if (synth.generate(self.gpa)) |chunk| {
                        defer self.gpa.free(chunk);
                        for (chunk) |*x| x.tsf_us = x.tsf_us - 1000 + sensor.demo_t;
                        self.store(k, chunk, now);
                    } else |_| {}
                    sensor.demo_t += 100_000;
                    sensor.demo_next += 100_000_000;
                };
                // Sweeping: the next window after each dwell.
                const a = &self.plan.per[k];
                if (a.n > 1 and now >= sensor.next_hop) {
                    sensor.next_hop = now + @as(u64, self.plan.dwell_ms) * 1_000_000;
                    sensor.at = (sensor.at + 1) % a.n;
                    if (!self.tune(sock, k, a.centres[sensor.at], now)) {
                        self.replan(self.request, self.n_sensors);
                        self.applyPlan(sock, now);
                    }
                }
            }
            if (self.traffic_on and self.traffic_thread == null) self.readTraffic(sock, now);
            // TX counters of every taken card: any movement ends the session.
            if ((self.spectral_on or self.traffic_on) and self.taken[0] != null and now - last_tx >= 1_000_000_000) {
                last_tx = now;
                var moved = false;
                var unreadable = false;
                var held: [sweep.max_sensors + 1]?Saved = undefined;
                self.mutex.lock();
                // Only cards still held: one whose take failed was already put back.
                for (self.taken, &self.tx_now, self.put_back, &held) |t, *tn, back, *h| {
                    h.* = if (back) null else t;
                    const s = h.* orelse continue;
                    const tx = txCounters(self.cfg.roots, s.iface.get());
                    tn.* = tx;
                    if (tx[0] == null or tx[1] == null) unreadable = true else if (tx[0].? != s.tx_packets or tx[1].? != s.tx_bytes) moved = true;
                }
                self.mutex.unlock();
                // A held card out of monitor mode: something else (a network manager) took it.
                var taken_away: ?[]const u8 = null;
                if (!moved and !unreadable and !self.demo_on) if (sock) |sk| for (&held) |*t| if (t.*) |*s| {
                    self.busy(&self.busy_op, &self.busy_since, "check {s}'s mode", .{s.iface.get()});
                    defer self.idle(&self.busy_since);
                    const kind = if (sk.interface(s.ifindex)) |i| i.iftype else |_| nl.iftype.monitor;
                    if (kind != nl.iftype.monitor) taken_away = s.iface.get();
                };
                if (moved) {
                    self.tx_moved = true;
                    self.release();
                    self.setStatus("TX counters moved on a taken card: restored every card and stopped (receive-only)", .{});
                } else if (unreadable) {
                    // No counters, no proof of receive-only: stop.
                    self.release();
                    self.setStatus("TX counters unreadable on a taken card: stopped and put the cards back", .{});
                } else if (taken_away) |name| {
                    var nb: [16]u8 = undefined;
                    const n = @min(name.len, nb.len);
                    @memcpy(nb[0..n], name[0..n]);
                    self.release();
                    self.setStatus("{s} left monitor mode (something else took it): stopped and left it alone", .{nb[0..n]});
                }
            }
            // Passive link: station and survey at 2 Hz.
            if (self.link_ifindex != 0 and now - last_link >= 500_000_000) {
                last_link = now;
                if (sock) |s| {
                    var p = LinkPoint{ .mono_ns = now };
                    const st = s.station(self.link_ifindex) catch null;
                    const sv = s.surveyInUse(self.link_ifindex) catch null;
                    const dt_s = @as(f32, @floatFromInt(now -| prev_link_ns)) / 1e9;
                    if (st) |x| {
                        p.signal_dbm = x.signal_avg_dbm orelse x.signal_dbm;
                        if (x.tx_bitrate) |r| p.bitrate = @as(f32, @floatFromInt(r)) / 10;
                        if (prev_station) |q| if (prev_link_ns > 0 and dt_s > 0) {
                            if (x.tx_retries != null and q.tx_retries != null) p.retries_ps = @as(f32, @floatFromInt(x.tx_retries.? -% q.tx_retries.?)) / dt_s;
                            if (x.tx_failed != null and q.tx_failed != null) p.failed_ps = @as(f32, @floatFromInt(x.tx_failed.? -% q.tx_failed.?)) / dt_s;
                        };
                    }
                    if (sv) |x| {
                        p.noise_dbm = x.noise_dbm;
                        if (prev_survey) |q| if (x.time_ms != null and q.time_ms != null and x.busy_ms != null and q.busy_ms != null and x.time_ms.? > q.time_ms.?) {
                            p.busy = @as(f32, @floatFromInt(x.busy_ms.? -| q.busy_ms.?)) / @as(f32, @floatFromInt(x.time_ms.? - q.time_ms.?));
                        };
                    }
                    prev_station = st;
                    prev_survey = sv;
                    prev_link_ns = now;
                    self.mutex.lock();
                    self.links.push(p);
                    self.mutex.unlock();
                }
            }
            ping.tick(self, now);
            const ts = linux.timespec{ .sec = 0, .nsec = 2_000_000 };
            _ = linux.nanosleep(&ts, null);
        }
        self.release();
    }

    /// Reads every relay file of sensor `k` once: whole records, carrying a partial tail.
    pub fn readSensor(self: *Monitor, k: usize, buf: []u8, batch: []ath9k.Sample) void {
        const sensor = &self.sensors[k];
        for (sensor.files[0..sensor.n_files], 0..) |fd, f| {
            @memcpy(buf[0..sensor.carried[f]], sensor.carry[f][0..sensor.carried[f]]);
            const rc = linux.read(fd, buf[sensor.carried[f]..].ptr, buf.len - sensor.carried[f]);
            if (linux.errno(rc) != .SUCCESS or rc == 0) continue;
            const have = sensor.carried[f] + rc;
            const read_ns = fsx.monotonicNs();
            var n: usize = 0;
            var counts = ath9k.Counts{};
            var used: usize = 0;
            while (used < have) {
                n = 0;
                const got = ath9k.parse(buf[used..have], read_ns, batch, &n, &counts);
                self.store(k, batch[0..n], read_ns);
                if (got == 0) break;
                used += got;
                if (n < batch.len) break;
            }
            const tail = have - used;
            sensor.carried[f] = if (tail <= sensor.carry[f].len) tail else 0;
            @memcpy(sensor.carry[f][0..sensor.carried[f]], buf[used..][0..sensor.carried[f]]);
            self.mutex.lock();
            self.counts.samples += counts.samples;
            self.counts.skipped += counts.skipped;
            self.counts.malformed += counts.malformed;
            self.counts.ht40 += counts.ht40;
            if (counts.skipped > 0) {
                self.counts.skipped_kind = counts.skipped_kind;
                self.counts.skipped_len = counts.skipped_len;
            }
            self.mutex.unlock();
        }
    }

    /// Background mode is endless, but the scan can stop (a card reset, or the
    /// firmware under a strong signal). After 1 s without samples: trigger again.
    /// After 3 s: re-arm it from scratch (disable, settings, background, trigger)
    /// and re-tune the channel, at most every 3 s. Both are counted and shown.
    fn watchdog(self: *Monitor, sock: ?*nl.Socket, k: usize, now: u64) void {
        const sensor = &self.sensors[k];
        const sd = sensor.saved.spectral_dir.get();
        const silent = now -| @max(sensor.last_sample_ns, self.started_ns);
        if (silent > 3_000_000_000 and now -| sensor.last_rearm > 3_000_000_000) {
            self.busy(&self.busy_op, &self.busy_since, "re-arm the spectral scan on {s}", .{sensor.saved.iface.get()});
            defer self.idle(&self.busy_since);
            sensor.last_rearm = now;
            sensor.last_trigger = now;
            // Silence can mean a manager took the card: never re-arm or retune a
            // card out of monitor mode (the per-second check then lets it go).
            if (sock) |sk| {
                const kind = if (sk.interface(sensor.saved.ifindex)) |i| i.iftype else |_| nl.iftype.monitor;
                if (kind != nl.iftype.monitor) return;
            }
            var nb: [8]u8 = undefined;
            fsx.write("disable", "{s}/spectral_scan_ctl", .{sd}) catch {};
            fsx.write("1", "{s}/spectral_short_repeat", .{sd}) catch {};
            fsx.write(std.fmt.bufPrint(&nb, "{d}", .{self.cfg.period}) catch "16", "{s}/spectral_period", .{sd}) catch {};
            fsx.write(std.fmt.bufPrint(&nb, "{d}", .{self.cfg.fft_period}) catch "1", "{s}/spectral_fft_period", .{sd}) catch {};
            if (sock) |sk| sk.setFreqType(sensor.saved.ifindex, sensor.freq_mhz, self.channelType(true, sensor.freq_mhz)) catch {};
            fsx.write("background", "{s}/spectral_scan_ctl", .{sd}) catch {};
            fsx.write("trigger", "{s}/spectral_scan_ctl", .{sd}) catch {};
            self.mutex.lock();
            sensor.rearms += 1;
            self.mutex.unlock();
        } else if (silent > 1_000_000_000 and now -| sensor.last_trigger > 1_000_000_000) {
            self.busy(&self.busy_op, &self.busy_since, "trigger the spectral scan on {s}", .{sensor.saved.iface.get()});
            defer self.idle(&self.busy_since);
            fsx.write("trigger", "{s}/spectral_scan_ctl", .{sd}) catch {};
            sensor.last_trigger = now;
            self.mutex.lock();
            sensor.retriggers += 1;
            self.mutex.unlock();
        }
    }
    pub const Health = struct { silent_ms: u64, retriggers: u32, rearms: u32, rejected: u64, steps: u32, malformed: u64, busy_ms: u64 = 0, busy_op: cards.Text(64) = .{} };
    /// How the spectral stream is doing: the longest silence now across sensors, and the watchdog's counts.
    pub fn health(self: *Monitor) ?Health {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.spectral_on or self.demo_on) return null;
        const now = fsx.monotonicNs();
        var h = Health{ .silent_ms = 0, .retriggers = 0, .rearms = 0, .rejected = 0, .steps = 0, .malformed = self.counts.malformed };
        if (self.busy_since != 0) {
            h.busy_ms = (now -| self.busy_since) / 1_000_000;
            h.busy_op = self.busy_op;
        }
        for (self.sensors[0..self.n_sensors]) |*s| {
            h.silent_ms = @max(h.silent_ms, (now -| @max(s.last_sample_ns, self.started_ns)) / 1_000_000);
            h.retriggers += s.retriggers;
            h.rearms += s.rearms;
            h.rejected += s.rejected;
            h.steps += s.tsf_steps;
        }
        return h;
    }

    /// Traffic: received frames into the current dwell, and the next channel after each dwell.
    fn readTraffic(self: *Monitor, sock: ?*nl.Socket, now: u64) void {
        const t = &self.traffic;
        if (t.demo) {
            if (now >= t.demo_next) {
                self.demoFrames(now);
                t.demo_next = now + 20_000_000;
            }
        } else {
            var pkt: [256]u8 = undefined;
            var got: usize = 0;
            while (got < 4096) : (got += 1) {
                const rc = linux.recvfrom(t.fd, &pkt, pkt.len, linux.MSG.TRUNC, null, null);
                if (linux.errno(rc) != .SUCCESS) break;
                const wire: usize = rc;
                self.traffic_counts.packets += 1;
                const f = radiotap.parse(pkt[0..@min(wire, pkt.len)], wire) orelse {
                    self.traffic_counts.unparsed += 1;
                    continue;
                };
                // Frames still queued from the previous channel are not this dwell's.
                if (f.freq_mhz) |mhz| if (sweep.channelOf(mhz) != t.cur.channel) {
                    self.traffic_counts.other_channel += 1;
                    continue;
                };
                self.mutex.lock();
                t.cur.add(&f, &t.key);
                t.cur.to_ns = now;
                self.mutex.unlock();
            }
        }
        if (now >= t.next_hop) self.hopTraffic(sock, now, false);
    }
    fn hopTraffic(self: *Monitor, sock: ?*nl.Socket, now: u64, restart: bool) void {
        const t = &self.traffic;
        if (!restart) {
            self.endDwell(now);
            t.at = (t.at + 1) % t.n;
        }
        if (!t.demo) if (sock) |sk| {
            self.busy(&self.traffic_busy_op, &self.traffic_busy_since, "retune {s} to channel {d}", .{ t.saved.iface.get(), t.channels[t.at] });
            sk.setFreq(t.saved.ifindex, sweep.channelMhz(t.channels[t.at])) catch {};
            self.idle(&self.traffic_busy_since);
            // Drop what was queued on the previous channel.
            var pkt: [64]u8 = undefined;
            while (linux.errno(linux.recvfrom(t.fd, &pkt, pkt.len, linux.MSG.TRUNC, null, null)) == .SUCCESS) {}
        };
        self.startDwell(fsx.monotonicNs());
    }

    /// SYNTHETIC traffic for the demo: access points on 1, 6 and 11 with their
    /// stations; while the demo microwave runs, the channels it hits lose
    /// frames and retry. Frames go through the real radiotap parser.
    fn demoFrames(self: *Monitor, now: u64) void {
        const t = &self.traffic;
        const c = t.cur.channel;
        const on = (self.sensors[0].demo_t / 100_000) % 250 >= 100 and self.cfg.demo != null and self.cfg.demo.? != .empty and self.cfg.demo.? != .wifi and self.cfg.demo.? != .bluetooth and self.cfg.demo.? != .wifi_beacons;
        // Frames per second heard on this channel, and how many networks and stations.
        const per = [15][3]u16{ .{ 0, 0, 0 }, .{ 140, 2, 5 }, .{ 30, 1, 2 }, .{ 12, 1, 1 }, .{ 25, 1, 2 }, .{ 60, 2, 3 }, .{ 260, 3, 9 }, .{ 70, 2, 3 }, .{ 20, 1, 1 }, .{ 15, 1, 1 }, .{ 40, 1, 2 }, .{ 110, 1, 3 }, .{ 30, 1, 1 }, .{ 8, 1, 1 }, .{ 0, 0, 0 } };
        const hit = on and c >= 6 and c <= 13;
        var prng = std.Random.DefaultPrng.init(t.seed);
        t.seed +%= 0x9e3779b97f4a7c15;
        const r = prng.random();
        const rate: f32 = @as(f32, @floatFromInt(per[c][0])) * (if (hit) @as(f32, 0.45) else 1);
        var n: usize = @intFromFloat(rate * 0.02 + r.float(f32));
        if (hit) n += r.uintLessThan(usize, 2); // corrupted frames still arrive, with a bad FCS
        var b: [64]u8 = undefined;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (0..n) |_| {
            const nets = @max(1, per[c][1]);
            const stas = @max(1, per[c][2]);
            var s = radiotap.Synth{ .freq_mhz = sweep.channelMhz(c), .signal = -40 - @as(i8, @intCast(r.uintLessThan(u8, 40))), .body = @intCast(60 + r.uintLessThan(u16, 1400)), .rate_500k = if (hit) 12 else 108 };
            s.a1 = .{ 0x02, 0xd0, 0, 0, c, @intCast(r.uintLessThan(u16, nets)) };
            s.a2 = .{ 0x02, 0x5a, 0, 0, c, @intCast(r.uintLessThan(u16, stas)) };
            s.retry = r.float(f32) < (if (hit) @as(f32, 0.38) else 0.06);
            s.bad_fcs = hit and r.float(f32) < 0.2;
            if (r.float(f32) < 0.1) {
                s.kind = .mgmt;
                s.subtype = 8;
                s.to_ds = false;
                s.a3 = s.a1;
                s.rate_500k = 2;
            }
            const e = s.encode(&b);
            if (radiotap.parse(e.bytes, e.wire)) |f| t.cur.add(&f, &t.key);
        }
        t.cur.to_ns = now;
    }

    pub fn store(self: *Monitor, k: usize, batch: []const ath9k.Sample, read_ns: u64) void {
        if (batch.len == 0) return;
        const sensor = &self.sensors[k];
        self.mutex.lock();
        defer self.mutex.unlock();
        // Lower envelope of (read - tsf): samples are read after they happen. Per sensor:
        // every card has its own TSF; all are mapped to the host clock, each sample
        // with the mapping as it stands when it is seen.
        //
        // A sample far (over 250 ms) off the envelope is held back. One alone is a
        // garbage TSF (a corrupted record: a saturating magnetron makes them) and is
        // dropped; R2 let it re-anchor the whole batch, which put samples hours away
        // and out of time order in the ring, and the views stopped. Late delivery
        // passes too: normal samples come back in between. Only a new offset that
        // holds over several reads and half a second is a TSF step (a chip reset
        // restores the TSF approximately); then the mapping re-anchors.
        var stored = false;
        for (batch) |s| {
            const off = @as(i128, read_ns) - @as(i128, s.tsf_us) * 1000;
            const o = sensor.tsf_offset_ns orelse off;
            if (sensor.tsf_offset_ns == null) sensor.tsf_offset_ns = off;
            if (off - o > tsf_step_ns or o - off > tsf_step_ns) {
                if (sensor.cand_off) |c| if (@abs(off - c) <= 50_000_000) {
                    if (read_ns != sensor.cand_last) sensor.cand_reads += 1;
                    sensor.cand_last = read_ns;
                    sensor.cand_off = @min(c, off);
                } else {
                    sensor.cand_off = null;
                };
                if (sensor.cand_off == null) {
                    sensor.cand_off = off;
                    sensor.cand_first = read_ns;
                    sensor.cand_last = read_ns;
                    sensor.cand_reads = 1;
                }
                if (sensor.cand_reads < 3 or read_ns -| sensor.cand_first < 500_000_000) {
                    sensor.rejected += 1;
                    continue;
                }
                sensor.tsf_offset_ns = sensor.cand_off;
                sensor.tsf_spread_ns = 0;
                sensor.tsf_steps += 1;
                sensor.cand_off = null;
            } else {
                sensor.cand_off = null;
                if (off < o) {
                    sensor.tsf_spread_ns = @intCast(@min(std.math.maxInt(u64), @as(u128, @intCast(@max(0, o - off))) + sensor.tsf_spread_ns));
                    sensor.tsf_offset_ns = off;
                } else sensor.tsf_spread_ns = @max(sensor.tsf_spread_ns, @as(u64, @intCast(@min(std.math.maxInt(u64), off - o))) / 64);
            }
            const m = @as(i128, s.tsf_us) * 1000 + sensor.tsf_offset_ns.?;
            self.samples.pushOrdered(.{ .s = s, .mono_ns = @intCast(std.math.clamp(m, 0, std.math.maxInt(u64))), .sensor = @intCast(k) }, stampedTime);
            sensor.lag_ns = @intCast(std.math.clamp(@as(i128, read_ns) - m, 0, std.math.maxInt(u64)));
            stored = true;
        }
        if (stored) sensor.last_sample_ns = read_ns;
        if (k == 0) {
            self.tsf_offset_ns = sensor.tsf_offset_ns;
            self.tsf_spread_ns = sensor.tsf_spread_ns;
        }
    }

    fn pickLink(self: *Monitor, list: *const cards.List) void {
        for (list.items()) |*c| if (c.role == .in_use and c.associated()) {
            self.link_iface.set(c.iface.get());
            self.link_ifindex = c.ifindex;
            self.link_why.set(c.why.get());
            self.gateway = gatewayOf(self.cfg.roots, c.iface.get());
            return;
        };
        self.link_why.set("no associated Wi-Fi link");
    }

    // --- Reads for the panel, MCP and CLI ---------------------------------------------

    pub const Window = struct {
        from_ns: u64,
        to_ns: u64,
        samples: []Stamped,
        links: []LinkPoint,
        pings: []PingPoint,
        pub fn deinit(self: *Window, a: std.mem.Allocator) void {
            a.free(self.samples);
            a.free(self.links);
            a.free(self.pings);
        }
    };
    /// The last `span_ns`.
    pub fn window(self: *Monitor, a: std.mem.Allocator, span_ns: u64) !Window {
        const now = fsx.monotonicNs();
        return self.between(a, now -| span_ns, now);
    }
    pub const Lanes = struct { links: []LinkPoint, pings: []PingPoint };
    /// Link and ping entries in [from_ns, to_ns) (no spectral copy).
    pub fn lanes(self: *Monitor, a: std.mem.Allocator, from: u64, to: u64) !Lanes {
        self.mutex.lock();
        defer self.mutex.unlock();
        const links = try self.links.since(a, from, to, linkTime);
        errdefer a.free(links);
        return .{ .links = links, .pings = try self.pings.since(a, from, to, pingTime) };
    }
    /// Entries in [from_ns, to_ns), CLOCK_MONOTONIC.
    pub fn between(self: *Monitor, a: std.mem.Allocator, from: u64, to: u64) !Window {
        self.mutex.lock();
        defer self.mutex.unlock();
        var w = Window{ .from_ns = from, .to_ns = to, .samples = &.{}, .links = &.{}, .pings = &.{} };
        w.samples = try self.samples.since(a, from, to, stampedTime);
        errdefer a.free(w.samples);
        w.links = try self.links.since(a, from, to, linkTime);
        errdefer a.free(w.links);
        w.pings = try self.pings.since(a, from, to, pingTime);
        return w;
    }
    /// Finished traffic dwells ending in [from_ns, to_ns).
    pub fn finishedDwells(self: *Monitor, a: std.mem.Allocator, from: u64, to: u64) ![]radiotap.Dwell {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.dwells.since(a, from, to, dwellTime);
    }
    /// Traffic dwells ending in [from_ns, to_ns), plus the one in progress.
    pub fn dwellsBetween(self: *Monitor, a: std.mem.Allocator, from: u64, to: u64) ![]radiotap.Dwell {
        self.mutex.lock();
        defer self.mutex.unlock();
        const done = try self.dwells.since(a, from, to, dwellTime);
        if (!self.traffic_on or self.traffic.cur.from_ns >= to) return done;
        const out = try a.realloc(done, done.len + 1);
        out[done.len] = self.traffic.cur;
        return out;
    }
};
fn dwellTime(x: *const radiotap.Dwell) u64 {
    return x.to_ns;
}

/// The default IPv4 gateway of `iface` from /proc/net/route.
pub fn gatewayOf(roots: cards.Roots, iface: []const u8) ?[4]u8 {
    var b: [16384]u8 = undefined;
    const t = fsx.read(&b, "{s}/net/route", .{roots.proc}) orelse return null;
    var lines = std.mem.splitScalar(u8, t, '\n');
    _ = lines.next();
    while (lines.next()) |l| {
        var f = std.mem.tokenizeAny(u8, l, " \t");
        const name = f.next() orelse continue;
        const dest = f.next() orelse continue;
        const gw = f.next() orelse continue;
        if (!std.mem.eql(u8, name, iface) or !std.mem.eql(u8, dest, "00000000")) continue;
        const v = std.fmt.parseInt(u32, gw, 16) catch continue;
        if (v == 0) continue;
        return @bitCast(v); // /proc prints it in host order of network bytes
    }
    return null;
}

fn openRelays(dir: []const u8, out: *[64]i32) usize {
    const Ctx = struct { dir: []const u8, out: *[64]i32, n: *usize };
    var n: usize = 0;
    fsx.list("{s}", .{dir}, Ctx{ .dir = dir, .out = out, .n = &n }, struct {
        fn f(ctx: Ctx, name: []const u8) bool {
            if (!std.mem.startsWith(u8, name, "spectral_scan") or name.len == "spectral_scan".len or !std.ascii.isDigit(name["spectral_scan".len])) return true;
            var pb: [256]u8 = undefined;
            const p = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ ctx.dir, name }) catch return true;
            const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) return true;
            ctx.out[ctx.n.*] = @intCast(rc);
            ctx.n.* += 1;
            return ctx.n.* < ctx.out.len;
        }
    }.f);
    return n;
}

/// ICMP echo to the link's gateway at 50 Hz over an unprivileged ping socket.
const Ping = struct {
    fd: i32 = -1,
    to: linux.sockaddr.in = undefined,
    seq: u16 = 0,
    sent: [256]u64 = @splat(0),
    next_ns: u64 = 0,
    const interval_ns = 20_000_000;
    const timeout_ns = 1_000_000_000;

    fn open(m: *Monitor) Ping {
        var p = Ping{};
        if (m.cfg.ping == null and !m.cfg.ping_gateway) {
            m.ping_why.set("gateway ping off (--ping turns it on: 50 Hz echo to your gateway, the one thing xodb sends)");
            return p;
        }
        const target = m.cfg.ping orelse m.gateway orelse {
            m.ping_why.set(if (m.link_ifindex == 0) "no associated Wi-Fi link to ping through" else "the link has no IPv4 default gateway");
            return p;
        };
        const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, linux.IPPROTO.ICMP);
        if (linux.errno(rc) != .SUCCESS) {
            m.ping_why.set("ping sockets not permitted (net.ipv4.ping_group_range)");
            return p;
        }
        p.fd = @intCast(rc);
        // Bound to the in-use interface: with two default routes it must not leave by another link.
        if (m.cfg.ping == null) {
            const name = m.link_iface.get();
            if (linux.errno(linux.setsockopt(p.fd, linux.SOL.SOCKET, linux.SO.BINDTODEVICE, name.ptr, @intCast(name.len))) != .SUCCESS) {
                _ = linux.close(p.fd);
                p.fd = -1;
                m.ping_why.set("could not bind the gateway ping to the Wi-Fi interface (needs root or CAP_NET_RAW here): not pinging");
                return p;
            }
        }
        p.to = .{ .port = 0, .addr = @bitCast(target) };
        m.mutex.lock();
        m.gateway = target;
        m.mutex.unlock();
        return p;
    }
    fn close(self: *Ping) void {
        if (self.fd >= 0) _ = linux.close(self.fd);
    }
    fn tick(self: *Ping, m: *Monitor, now: u64) void {
        if (self.fd < 0) return;
        // Replies.
        var rb: [128]u8 = undefined;
        while (true) {
            const rc = linux.recvfrom(self.fd, &rb, rb.len, 0, null, null);
            if (linux.errno(rc) != .SUCCESS or rc < 8) break;
            if (rb[0] != 0) continue; // echo reply
            const seq = std.mem.readInt(u16, rb[6..8], .big);
            const at = self.sent[seq % self.sent.len];
            if (at == 0) continue;
            self.sent[seq % self.sent.len] = 0;
            const t = fsx.monotonicNs();
            m.mutex.lock();
            m.pings.push(.{ .mono_ns = at, .rtt_us = @intCast(@min(std.math.maxInt(u32), (t - at) / 1000)) });
            m.mutex.unlock();
        }
        // Timeouts become losses, in send order.
        for (&self.sent) |*s| if (s.* != 0 and now - s.* > timeout_ns) {
            m.mutex.lock();
            m.pings.push(.{ .mono_ns = s.*, .rtt_us = null });
            m.mutex.unlock();
            s.* = 0;
        };
        if (now < self.next_ns) return;
        self.next_ns = now + interval_ns;
        self.seq +%= 1;
        var pkt: [16]u8 = @splat(0);
        pkt[0] = 8; // echo request; the kernel sets id and checksum on ping sockets
        std.mem.writeInt(u16, pkt[6..8], self.seq, .big);
        const rc = linux.sendto(self.fd, &pkt, pkt.len, 0, @ptrCast(&self.to), @sizeOf(linux.sockaddr.in));
        if (linux.errno(rc) == .SUCCESS) self.sent[self.seq % self.sent.len] = now;
    }
};

test "state file round trip and hostile content" {
    var s = Saved{ .ifindex = 5, .up = false, .iftype = 2, .count = 8, .period = 18, .fft_period = 2, .short_repeat = 1, .tx_packets = 3, .tx_bytes = 400 };
    s.iface.set("wlan1");
    s.spectral_dir.set("/sys/kernel/debug/ieee80211/phy1/ath9k_htc");
    s.ctl.set("disable");
    var b: [1024]u8 = undefined;
    const text = try s.format(&b);
    const back = Saved.parse(text).?;
    try std.testing.expectEqualStrings("wlan1", back.iface.get());
    try std.testing.expectEqual(@as(u32, 18), back.period);
    try std.testing.expectEqual(@as(u64, 400), back.tx_bytes);
    try std.testing.expect(!back.up);
    try std.testing.expectEqual(@as(?Saved, null), Saved.parse("iface=../../x\nifindex=3\nup=1\niftype=2\n"));
    try std.testing.expectEqual(@as(?Saved, null), Saved.parse("iface=wlan1\nifindex=3\nup=1\nspectral_dir=/etc\n"));
    try std.testing.expectEqual(@as(?Saved, null), Saved.parse("garbage"));
}

test "a restore file from before a reboot is dropped, never applied" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    try temporary.dir.createDirPath(std.testing.io, "proc/sys/kernel/random");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "proc/sys/kernel/random/boot_id", .data = "1111-2222\n" });
    var s = Saved{ .ifindex = 5, .pid = 1 };
    s.iface.set("wlan1");
    s.boot.set("aaaa-bbbb");
    var b: [1024]u8 = undefined;
    for ([_][]const u8{ "radio-restore", "radio-restore-wlan1" }) |name| {
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = try s.format(&b) });
        var pb: [256]u8 = undefined;
        const proc = try std.fmt.bufPrint(&pb, "{s}/proc", .{dir});
        var mb: [400]u8 = undefined;
        const msg = recover(&mb, dir, .{ .proc = proc, .sys = "/nonexistent" }).?;
        try std.testing.expect(std.mem.indexOf(u8, msg, "before the last reboot") != null);
        try std.testing.expect(!fsx.exists("{s}/{s}", .{ dir, name }));
    }
    try std.testing.expectEqual(@as(?Saved, null), Saved.parse("iface=wlan1\nifindex=3\nup=1\niftype=2\nboot=../x\n"));
}

test "ring keeps the newest entries and windows by time" {
    const a = std.testing.allocator;
    var r = try Ring(PingPoint).init(a, 4);
    defer r.deinit(a);
    for (0..6) |i| r.push(.{ .mono_ns = i * 10, .rtt_us = @intCast(i) });
    try std.testing.expectEqual(@as(usize, 4), r.len);
    try std.testing.expectEqual(@as(u64, 20), r.at(0).mono_ns);
    const w = try r.since(a, 35, 1000, pingTime);
    defer a.free(w);
    try std.testing.expectEqual(@as(usize, 2), w.len);
    try std.testing.expectEqual(@as(u64, 40), w[0].mono_ns);
}

test "gateway from a route table" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "net");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "net/route", .data = "Iface\tDestination\tGateway\nwlp1s0\t00000000\t0101A8C0\t0003\n" });
    const dir = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const gw = gatewayOf(.{ .proc = dir }, "wlp1s0").?;
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 1, 1 }, &gw);
    try std.testing.expectEqual(@as(?[4]u8, null), gatewayOf(.{ .proc = dir }, "eth9"));
}

test "ping loop measures loopback round trips" {
    const a = std.testing.allocator;
    const m = try Monitor.start(a, .{ .ping = .{ 127, 0, 0, 1 }, .roots = .{ .sys = "/nonexistent", .proc = "/nonexistent" } });
    const ts = linux.timespec{ .sec = 0, .nsec = 300_000_000 };
    _ = linux.nanosleep(&ts, null);
    var w = try m.window(a, 10_000_000_000);
    defer w.deinit(a);
    m.deinit();
    // Ping sockets may be disallowed for this group; then the reason is set and nothing is sent.
    if (w.pings.len == 0) return;
    try std.testing.expect(w.pings.len >= 1);
    for (w.pings) |p| try std.testing.expect(p.rtt_us != null);
}
