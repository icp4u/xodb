//! `xodb --memdefrag`: the DOS DEFRAG homage in a terminal, over the shared
//! memory observer. Same conventions as lsof-top: plain termios and ANSI,
//! alternate screen, synchronized output, line-diffed frames, --once/--json
//! snapshots, NO_COLOR honoured. The screen itself is dos.zig's 80x25 grid.
const std = @import("std");
const c = @import("../c.zig").api;
const t = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("locale.h");
});
const model = @import("model.zig");
const dos = @import("dos.zig");
const vga = @import("vga.zig");

pub const usage =
    \\usage: xodb --memdefrag [options]
    \\  The memory "defrag" view in a terminal: an 80x25 MS-DOS DEFRAG-style map of one
    \\  process's virtual memory in 2 MiB blocks (THP, 4 KiB, file, swapped, unknown), its
    \\  THP coverage, and system-wide buddy fragmentation and THP/compaction activity.
    \\  Observer-only: page metadata at most once per second; no target memory, no PFNs.
    \\  --pid PID            map this process (default: system free memory by block size)
    \\  --start-ticks N      require this exact process start (pid + start is the identity)
    \\  --theme dos|plain    VGA colours (default) or plain attributes; NO_COLOR is honoured
    \\  --once               print one 80x25 frame after --samples publications and exit
    \\  --json               print the map as JSON (the replay schema) and exit
    \\  --stream             with --json, print every publication as one line (a replay file)
    \\  --samples N          publications before --once/--json (default 2: changes need two)
    \\  --ansi               colour codes in --once output even when not a terminal
    \\  --replay FILE        draw recorded maps (JSON lines) instead of the live system
    \\  --redact             hide process names and file paths
    \\Keys: arrows move  PgUp/PgDn scroll  +/- zoom  o select process  g legend  t theme
    \\      p pause  q quit
    \\
;

const Options = struct {
    pid: ?i32 = null,
    start: u64 = 0,
    plain: bool = false,
    once: bool = false,
    json: bool = false,
    stream: bool = false,
    samples: u32 = 2,
    ansi: bool = false,
    replay: ?[]const u8 = null,
    redact: bool = false,
};

fn parse(args: []const [:0]const u8) !Options {
    var o = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--memdefrag")) continue;
        if (std.mem.eql(u8, a, "--once")) o.once = true else if (std.mem.eql(u8, a, "--json")) o.json = true else if (std.mem.eql(u8, a, "--ansi")) o.ansi = true else if (std.mem.eql(u8, a, "--stream")) o.stream = true else if (std.mem.eql(u8, a, "--redact")) o.redact = true else {
            const takes = [_][]const u8{ "--pid", "--start-ticks", "--theme", "--samples", "--replay" };
            var known = false;
            for (takes) |k| known = known or std.mem.eql(u8, a, k);
            if (!known or i + 1 == args.len) {
                std.debug.print("xodb: --memdefrag does not accept {s}\n{s}", .{ a, usage });
                return error.Usage;
            }
            i += 1;
            const v = args[i];
            if (std.mem.eql(u8, a, "--pid")) o.pid = std.fmt.parseInt(i32, v, 10) catch return error.Usage;
            if (std.mem.eql(u8, a, "--start-ticks")) o.start = std.fmt.parseInt(u64, v, 10) catch return error.Usage;
            if (std.mem.eql(u8, a, "--samples")) o.samples = std.math.clamp(std.fmt.parseInt(u32, v, 10) catch return error.Usage, 1, 30);
            if (std.mem.eql(u8, a, "--replay")) o.replay = v;
            if (std.mem.eql(u8, a, "--theme")) {
                if (std.mem.eql(u8, v, "plain")) o.plain = true else if (!std.mem.eql(u8, v, "dos")) return error.Usage;
            }
        }
    }
    if (o.pid) |p| if (p <= 0) return error.Usage;
    if (o.start != 0 and o.pid == null) return error.Usage;
    if (o.replay != null and o.pid != null) return error.Usage;
    if (o.stream and (!o.json or o.replay != null)) return error.Usage;
    return o;
}

pub fn main(args: []const [:0]const u8) u8 {
    for (args) |a| if (std.mem.eql(u8, a, "--help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    };
    const o = parse(args) catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    var app = App{ .o = o };
    defer app.deinit();
    return app.run() catch |err| {
        app.restore();
        std.debug.print("xodb: memdefrag failed: {s}\n", .{@errorName(err)});
        return 1;
    };
}

var signalled: c.sig_atomic_t = 0;
var resized: c.sig_atomic_t = 0;
fn onSignal(sig: c_int) callconv(.c) void {
    if (sig == c.SIGWINCH) resized = 1 else signalled = sig;
}

const Proc = struct { pid: i32, start: u64, rss: u64, name: [16]u8 = @splat(0), name_len: u8 = 0 };
const Color = enum { none, ansi16, truecolor };
const zooms = [_]u64{ 2 << 20, 512 << 10, 128 << 10, 32 << 10, 8 << 10, 4 << 10 };

const App = struct {
    o: Options,
    gpa: std.mem.Allocator = std.heap.c_allocator,
    observer: ?*c.struct_xrt_memobserver = null,
    reader: model.Reader = .{},
    current: ?*model.Owned = null,
    previous: ?*model.Owned = null,
    replay_arena: ?std.heap.ArenaAllocator = null,
    frames: []model.Map = &.{},
    frame_index: usize = 0,
    replay_shown: ?model.Map = null,
    target: ?model.Identity = null,
    target_since: u64 = 0,
    zoom: usize = 0,
    cursor: ?usize = null,
    scroll: usize = 0,
    paused: bool = false,
    plain: bool = false,
    legend: bool = false,
    picking: bool = false,
    procs: std.ArrayList(Proc) = .empty,
    labels: std.ArrayList([]const u8) = .empty,
    label_arena: ?std.heap.ArenaAllocator = null,
    pick: usize = 0,
    tty_saved: ?t.struct_termios = null,
    color: Color = .ansi16,
    cols: usize = 80,
    lines: usize = 25,
    shown: [vga.rows]std.ArrayList(u8) = @splat(.empty),
    out: std.ArrayList(u8) = .empty,
    cost_text: [48]u8 = undefined,
    cost_len: usize = 0,
    cost_wall: u64 = 0,
    cost_cpu: u64 = 0,
    publications: u32 = 0,
    replay_next: u64 = 0,
    counted: u64 = 0,

    fn deinit(self: *App) void {
        self.restore();
        if (self.observer) |p| c.xrt_memobserver_close(p);
        if (self.current) |p| p.destroy();
        if (self.previous) |p| p.destroy();
        if (self.replay_arena) |*a| a.deinit();
        if (self.label_arena) |*a| a.deinit();
        self.procs.deinit(self.gpa);
        self.labels.deinit(self.gpa);
        for (&self.shown) |*s| s.deinit(self.gpa);
        self.out.deinit(self.gpa);
    }
    fn map(self: *const App) model.Map {
        if (self.replay_shown) |m| return m;
        return if (self.current) |p| p.map else .{};
    }

    fn run(self: *App) !u8 {
        self.plain = self.o.plain;
        if (self.o.pid) |pid| {
            const start = if (self.o.start != 0) self.o.start else startTicks(pid) orelse {
                std.debug.print("xodb: memdefrag: process {d} not found\n", .{pid});
                return 1;
            };
            if (self.o.start != 0) if (startTicks(pid)) |actual| if (actual != self.o.start) {
                std.debug.print("xodb: memdefrag: process {d} has start {d}, not {d}\n", .{ pid, actual, self.o.start });
                return 1;
            };
            self.target = .{ .pid = pid, .start = start };
        }
        if (self.o.replay) |path| try self.loadReplay(path) else self.observer = c.xrt_memobserver_open(null, null) orelse return error.ObserverUnavailable;
        self.target_since = now();
        self.cost_wall = now();
        self.cost_cpu = processNs();
        const interactive = !self.o.once and !self.o.json;
        if (!interactive) return self.snapshotOut();
        if (c.isatty(0) == 0 or c.isatty(1) == 0) {
            std.debug.print("xodb: memdefrag needs a terminal; use --once or --json for snapshots\n", .{});
            return 2;
        }
        const term = c.getenv("TERM");
        if (term == null or std.mem.eql(u8, std.mem.span(term.?), "dumb")) return self.snapshotOut();
        self.color = colorDepth(self.plain);
        try self.raw();
        defer self.restore();
        for ([_]c_int{ c.SIGINT, c.SIGTERM, c.SIGHUP, c.SIGWINCH }) |sig| _ = c.signal(sig, onSignal);
        self.size();
        var last_draw: u64 = 0;
        var dirty = true;
        var phase: u64 = 0;
        while (signalled == 0) {
            const at = now();
            if (resized != 0) {
                resized = 0;
                self.size();
                for (&self.shown) |*s| s.clearRetainingCapacity();
                try self.write("\x1b[2J");
                dirty = true;
            }
            if (self.poll(at)) dirty = true;
            const p = at / vga.blink_half_ns;
            if (p != phase) {
                phase = p;
                dirty = true;
            }
            if (dirty or at -| last_draw > 1_000_000_000) {
                self.costUpdate(at);
                try self.draw(at, p % 2 == 0 or self.paused);
                last_draw = at;
                dirty = false;
            }
            var fds = [1]c.struct_pollfd{.{ .fd = 0, .events = c.POLLIN, .revents = 0 }};
            if (c.poll(&fds, 1, 60) > 0) {
                var buf: [64]u8 = undefined;
                const n = c.read(0, &buf, buf.len);
                if (n <= 0) break;
                if (self.keys(buf[0..@intCast(n)])) break;
                dirty = true;
            }
        }
        return 0;
    }

    /// --once / --json: wait for enough publications, then print once.
    fn snapshotOut(self: *App) !u8 {
        // Expensive maps refresh every few seconds (cost-limited), so wait for that.
        const deadline = now() + (15 + 8 * @as(u64, self.o.samples)) * 1_000_000_000;
        if (self.o.replay == null) {
            var streamed: u32 = 0;
            while (self.publications < self.o.samples and now() < deadline) {
                _ = self.poll(now());
                if (self.o.stream and self.publications > streamed) {
                    streamed = self.publications;
                    const m = self.map();
                    const bytes = try model.toJson(self.gpa, &m);
                    defer self.gpa.free(bytes);
                    try self.out.appendSlice(self.gpa, bytes);
                    try self.out.append(self.gpa, '\n');
                    try self.flush();
                }
                var ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 50_000_000 };
                _ = c.nanosleep(&ts, null);
            }
            if (self.publications == 0) {
                std.debug.print("xodb: memdefrag: no publication within the deadline\n", .{});
                return 1;
            }
        } else self.replay_shown = self.frames[self.frames.len - 1];
        self.out.clearRetainingCapacity();
        if (self.o.stream) return 0;
        if (self.o.json) {
            const m = self.map();
            const bytes = try model.toJson(self.gpa, &m);
            defer self.gpa.free(bytes);
            try self.out.appendSlice(self.gpa, bytes);
            try self.out.append(self.gpa, '\n');
        } else {
            self.color = if (self.o.ansi and !self.plain) colorDepth(false) else .none;
            self.costUpdate(now());
            var scr: dos.Screen = .{};
            self.compose(&scr, now(), true);
            for (0..vga.rows) |y| {
                var line: std.ArrayList(u8) = .empty;
                defer line.deinit(self.gpa);
                try self.rowBytes(&line, &scr, y, self.o.ansi);
                var n = line.items.len;
                if (self.color == .none) {
                    while (n > 0 and line.items[n - 1] == ' ') n -= 1;
                }
                try self.out.appendSlice(self.gpa, line.items[0..n]);
                try self.out.append(self.gpa, '\n');
            }
        }
        try self.flush();
        return 0;
    }

    fn loadReplay(self: *App, path: []const u8) !void {
        self.replay_arena = std.heap.ArenaAllocator.init(self.gpa);
        const a = self.replay_arena.?.allocator();
        const bytes = try readFile(a, path);
        var list: std.ArrayList(model.Map) = .empty;
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        while (lines.next()) |text| {
            const line = std.mem.trim(u8, text, " \t\r");
            if (line.len == 0) continue;
            const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{ .allocate = .alloc_always });
            const inner = if (v == .object) v.object.get("memory_map") orelse v else v;
            var m = try model.fromValue(a, inner);
            if (self.o.redact) m = try redactMap(a, m);
            try list.append(a, m);
        }
        if (list.items.len == 0) return error.EmptyReplay;
        self.frames = list.items;
        self.replay_shown = self.frames[0];
        self.publications = @intCast(self.frames.len);
    }

    /// New publication (live) or the next frame (replay, 1 Hz). True when shown data changed.
    fn poll(self: *App, at: u64) bool {
        if (self.paused) return false;
        if (self.o.replay != null) {
            if (at < self.replay_next) return false;
            self.replay_next = at + 1_000_000_000;
            self.frame_index = (self.frame_index + 1) % self.frames.len;
            self.replay_shown = self.frames[self.frame_index];
            return true;
        }
        const obs = self.observer orelse return false;
        const req = model.Request{ .cell_bytes = zooms[self.zoom], .anchor = self.anchor(), .redact = self.o.redact };
        self.reader.renew(obs, self.target, req, at) catch return false;
        const got = (self.reader.read(self.gpa, obs, self.target, req) catch null) orelse return false;
        if (self.target != null and got.map.process == null) {
            // Only the system strip so far: keep it, but do not count a scan.
            if (self.current) |p| if (p.map.process != null) {
                got.destroy();
                return false;
            };
        } else if (!got.map.pending and (got.map.process == null or got.map.sequence != self.counted)) {
            // Count scans of the target (or system publications), not the
            // interleaved system-counter refreshes of a process view.
            self.counted = got.map.sequence;
            self.publications += 1;
        }
        if (self.previous) |p| p.destroy();
        self.previous = self.current;
        self.current = got;
        return true;
    }
    fn anchor(self: *const App) u64 {
        if (self.zoom == 0) return 0;
        const m = self.map();
        if (self.cursor) |i| if (i < m.cells.len) return m.cells[i].start;
        return if (m.cells.len > 0) m.cells[0].start else 0;
    }

    fn costUpdate(self: *App, at: u64) void {
        const cpu = processNs();
        if (self.o.once and self.o.replay != null) {
            const s = std.fmt.bufPrint(&self.cost_text, "replay", .{}) catch "";
            self.cost_len = s.len;
            return;
        }
        if (self.o.once and self.cost_wall != 0) {
            // One snapshot: the whole run's cost.
            const pct = @as(f64, @floatFromInt(cpu -| self.cost_cpu)) * 100 / @as(f64, @floatFromInt(@max(1, at -| self.cost_wall)));
            const s = std.fmt.bufPrint(&self.cost_text, "cost {d:.1}% of a core", .{pct}) catch "";
            self.cost_len = s.len;
            return;
        }
        if (self.cost_wall != 0 and at -| self.cost_wall >= 1_000_000_000) {
            const pct = @as(f64, @floatFromInt(cpu -| self.cost_cpu)) * 100 / @as(f64, @floatFromInt(at -| self.cost_wall));
            const s = std.fmt.bufPrint(&self.cost_text, "cost {d:.1}% of a core", .{pct}) catch "";
            self.cost_len = s.len;
        }
        if (self.cost_wall == 0 or at -| self.cost_wall >= 1_000_000_000) {
            self.cost_wall = at;
            self.cost_cpu = cpu;
        }
        if (self.cost_len == 0) {
            const s = std.fmt.bufPrint(&self.cost_text, "cost: measuring", .{}) catch "";
            self.cost_len = s.len;
        }
    }

    fn compose(self: *App, scr: *dos.Screen, at: u64, blink_on: bool) void {
        const m = self.map();
        var lb: [64]u8 = undefined;
        var ab: [24]u8 = undefined;
        const label = if (m.process) |p| (std.fmt.bufPrint(&lb, "pid {d} {s}", .{ p.pid, model.processLabel(&ab, p) }) catch "") else if (self.target) |id| (std.fmt.bufPrint(&lb, "pid {d}", .{id.pid}) catch "") else "System memory";
        const elapsed: f64 = @as(f64, @floatFromInt(at -| self.target_since)) / 1e9;
        const k = model.cadence(&m, if (self.o.replay == null) at else null);
        var cb: [48]u8 = undefined;
        var gb: [24]u8 = undefined;
        var right: [96]u8 = undefined;
        const cost = std.fmt.bufPrint(&right, "{s} · {s}", .{ model.ageText(&gb, k), self.cost_text[0..self.cost_len] }) catch "";
        const r = dos.compose(scr, &m, .{
            .label = label,
            .elapsed_s = elapsed,
            .blink_on = blink_on,
            .cursor = self.cursor,
            .scroll = self.scroll,
            .cost = cost,
            .cadence = model.cadenceText(&cb, k),
            .paused = self.paused,
            .waiting = self.target != null and m.process == null,
            .picker = if (self.picking) .{ .labels = self.labels.items, .selected = self.pick } else null,
            .legend = self.legend,
        });
        if (self.cursor) |cur| if (cur >= r.cells) {
            self.cursor = if (r.cells == 0) null else r.cells - 1;
        };
        if (self.scroll + dos.map_rows > r.rows) self.scroll = r.rows -| dos.map_rows;
    }

    fn draw(self: *App, at: u64, blink_on: bool) !void {
        var scr: dos.Screen = .{};
        self.compose(&scr, at, blink_on);
        self.out.clearRetainingCapacity();
        if (self.cols < vga.cols or self.lines < vga.rows) {
            try self.out.appendSlice(self.gpa, "\x1b[H\x1b[2J");
            try self.out.print(self.gpa, "xodb --memdefrag needs an 80x25 terminal (this one is {d}x{d}); q quits", .{ self.cols, self.lines });
            for (&self.shown) |*s| s.clearRetainingCapacity();
            return self.flush();
        }
        const ox = (self.cols - vga.cols) / 2;
        const oy = (self.lines - vga.rows) / 2;
        try self.out.appendSlice(self.gpa, "\x1b[?2026h");
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.gpa);
        for (0..vga.rows) |y| {
            line.clearRetainingCapacity();
            try self.rowBytes(&line, &scr, y, true);
            if (std.mem.eql(u8, line.items, self.shown[y].items)) continue;
            try self.out.print(self.gpa, "\x1b[{d};{d}H", .{ oy + y + 1, ox + 1 });
            try self.out.appendSlice(self.gpa, line.items);
            self.shown[y].clearRetainingCapacity();
            try self.shown[y].appendSlice(self.gpa, line.items);
        }
        try self.out.appendSlice(self.gpa, "\x1b[0m\x1b[?2026l");
        try self.flush();
    }

    /// One screen row with SGR changes only where attributes change.
    fn rowBytes(self: *App, line: *std.ArrayList(u8), scr: *const dos.Screen, y: usize, attrs: bool) !void {
        var fg: i16 = -1;
        var bg: i16 = -1;
        var rev: bool = false;
        for (scr.cells[y]) |cell| {
            if (attrs) switch (self.color) {
                .none => {
                    const want = cell.bg != vga.blue;
                    if (want != rev) {
                        try line.appendSlice(self.gpa, if (want) "\x1b[7m" else "\x1b[27m");
                        rev = want;
                    }
                },
                .ansi16, .truecolor => {
                    if (cell.fg != fg or cell.bg != bg) {
                        try sgr(self.gpa, line, self.color, cell.fg, cell.bg);
                        fg = cell.fg;
                        bg = cell.bg;
                    }
                },
            };
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.ch, &enc) catch 1;
            try line.appendSlice(self.gpa, enc[0..n]);
        }
        if (attrs and (self.color != .none or rev)) try line.appendSlice(self.gpa, "\x1b[0m");
    }

    fn keys(self: *App, bytes: []const u8) bool {
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            const b = bytes[i];
            if (b == 0x1b and i + 2 < bytes.len and bytes[i + 1] == '[') {
                const k = bytes[i + 2];
                i += 2;
                if ((k == '5' or k == '6') and i + 1 < bytes.len and bytes[i + 1] == '~') i += 1;
                switch (k) {
                    'A' => self.move(-@as(i64, dos.map_cols)),
                    'B' => self.move(dos.map_cols),
                    'C' => self.move(1),
                    'D' => self.move(-1),
                    '5' => self.scrollBy(-@as(i64, dos.map_rows)),
                    '6' => self.scrollBy(dos.map_rows),
                    else => {},
                }
                continue;
            }
            if (self.picking) {
                switch (b) {
                    0x1b => self.picking = false,
                    '\r', '\n' => self.choose(),
                    'k' => self.pick -|= 1,
                    'j' => self.pick = @min(self.pick + 1, self.labels.items.len -| 1),
                    'q' => return true,
                    else => {},
                }
                continue;
            }
            switch (b) {
                'q', 'Q', 3 => return true,
                0x1b => if (self.legend) {
                    self.legend = false;
                } else {
                    self.cursor = null;
                },
                'p', ' ' => self.paused = !self.paused,
                't' => self.plain = !self.plain,
                'g', '?' => self.legend = !self.legend,
                '+', '=' => self.setZoom(@min(self.zoom + 1, zooms.len - 1)),
                '-', '_' => self.setZoom(self.zoom -| 1),
                'o' => self.openPicker(),
                'h' => self.move(-1),
                'l' => self.move(1),
                'k' => self.move(-@as(i64, dos.map_cols)),
                'j' => self.move(dos.map_cols),
                else => {},
            }
            if (b == 't') {
                self.color = colorDepth(self.plain);
                for (&self.shown) |*s| s.clearRetainingCapacity();
            }
        }
        return false;
    }
    fn move(self: *App, by: i64) void {
        if (self.picking) {
            if (by < 0) self.pick -|= 1 else self.pick = @min(self.pick + 1, self.labels.items.len -| 1);
            return;
        }
        const m = self.map();
        const count = if (m.process == null) dos.map_capacity else m.cells.len;
        if (count == 0) return;
        const at: i64 = if (self.cursor) |cur| @as(i64, @intCast(cur)) + by else 0;
        self.cursor = @intCast(std.math.clamp(at, 0, @as(i64, @intCast(count - 1))));
        const row = self.cursor.? / dos.map_cols;
        if (row < self.scroll) self.scroll = row;
        if (row >= self.scroll + dos.map_rows) self.scroll = row + 1 - dos.map_rows;
    }
    fn scrollBy(self: *App, by: i64) void {
        const s: i64 = @as(i64, @intCast(self.scroll)) + by;
        self.scroll = @intCast(@max(0, s));
    }
    fn setZoom(self: *App, z: usize) void {
        if (z == self.zoom or self.o.replay != null) return;
        self.zoom = z;
        // Rebuild at the new cell size from the next publication.
        self.reader.seen_any = false;
        self.scroll = 0;
    }
    fn openPicker(self: *App) void {
        if (self.o.replay != null) return;
        self.scanProcs() catch return;
        self.picking = true;
        self.pick = 0;
    }
    fn choose(self: *App) void {
        self.picking = false;
        const id: ?model.Identity = if (self.pick == 0) null else blk: {
            const p = self.procs.items[self.pick - 1];
            break :blk .{ .pid = p.pid, .start = p.start };
        };
        self.target = id;
        self.target_since = now();
        self.reader.reset();
        self.cursor = null;
        self.scroll = 0;
        self.zoom = 0;
        if (self.current) |p| p.destroy();
        if (self.previous) |p| p.destroy();
        self.current = null;
        self.previous = null;
    }
    fn scanProcs(self: *App) !void {
        self.procs.clearRetainingCapacity();
        const dir = c.opendir("/proc") orelse return error.ProcUnavailable;
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |entry| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            const pid = std.fmt.parseInt(i32, name, 10) catch continue;
            const p = readStat(pid) orelse continue;
            if (p.rss == 0) continue;
            try self.procs.append(self.gpa, p);
        }
        std.mem.sort(Proc, self.procs.items, {}, struct {
            fn less(_: void, a: Proc, b: Proc) bool {
                return a.rss > b.rss;
            }
        }.less);
        if (self.procs.items.len > 40) self.procs.shrinkRetainingCapacity(40);
        if (self.label_arena) |*a| a.deinit();
        self.label_arena = std.heap.ArenaAllocator.init(self.gpa);
        const a = self.label_arena.?.allocator();
        self.labels.clearRetainingCapacity();
        try self.labels.append(self.gpa, "System memory (free blocks by size)");
        for (self.procs.items) |p| {
            var ab: [24]u8 = undefined;
            const shown = if (self.o.redact) model.alias(&ab, p.pid, p.start) else p.name[0..p.name_len];
            var mb: [32]u8 = undefined;
            const rss = bytesShort(&mb, p.rss);
            try self.labels.append(self.gpa, try std.fmt.allocPrint(a, "{d:>7}  {s:<20} {s:>10}", .{ p.pid, shown, rss }));
        }
    }

    fn raw(self: *App) !void {
        var tio: t.struct_termios = undefined;
        if (t.tcgetattr(0, &tio) != 0) return error.TerminalUnavailable;
        self.tty_saved = tio;
        var r = tio;
        r.c_lflag &= ~@as(t.tcflag_t, t.ICANON | t.ECHO | t.ISIG | t.IEXTEN);
        r.c_iflag &= ~@as(t.tcflag_t, t.IXON | t.ICRNL);
        r.c_cc[t.VMIN] = 0;
        r.c_cc[t.VTIME] = 0;
        if (t.tcsetattr(0, t.TCSAFLUSH, &r) != 0) return error.TerminalUnavailable;
        try self.write("\x1b[?1049h\x1b[?25l\x1b[2J");
    }
    fn restore(self: *App) void {
        if (self.tty_saved) |tio| {
            self.write("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
            _ = t.tcsetattr(0, t.TCSAFLUSH, &tio);
            self.tty_saved = null;
        }
    }
    fn size(self: *App) void {
        var ws: t.struct_winsize = undefined;
        if (t.ioctl(1, t.TIOCGWINSZ, &ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
            self.cols = ws.ws_col;
            self.lines = ws.ws_row;
        }
    }
    fn write(self: *App, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
        try self.flush();
    }
    fn flush(self: *App) !void {
        var done: usize = 0;
        while (done < self.out.items.len) {
            const n = c.write(1, self.out.items.ptr + done, self.out.items.len - done);
            if (n < 0 and std.c._errno().* == c.EINTR) continue;
            if (n <= 0) return error.WriteFailed;
            done += @intCast(n);
        }
        self.out.clearRetainingCapacity();
    }
};

fn sgr(gpa: std.mem.Allocator, line: *std.ArrayList(u8), color: Color, fg: u4, bg: u4) !void {
    switch (color) {
        .none => {},
        .truecolor => {
            const f = vga.palette[fg];
            const b = vga.palette[bg];
            try line.print(gpa, "\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{ f >> 16, (f >> 8) & 0xff, f & 0xff, b >> 16, (b >> 8) & 0xff, b & 0xff });
        },
        .ansi16 => {
            const f = vga.ansi(fg);
            const b = vga.ansi(bg);
            try line.print(gpa, "\x1b[{d};{d}m", .{ @as(u32, if (f.bright) 90 else 30) + f.n, @as(u32, if (b.bright) 100 else 40) + b.n });
        },
    }
}
fn colorDepth(plain: bool) Color {
    if (plain) return .none;
    if (c.getenv("NO_COLOR")) |v| if (v[0] != 0) return .none;
    if (c.getenv("COLORTERM")) |v| {
        const s = std.mem.span(v);
        if (std.mem.eql(u8, s, "truecolor") or std.mem.eql(u8, s, "24bit")) return .truecolor;
    }
    return .ansi16;
}

/// Strips private text from a recorded map (replay with --redact).
fn redactMap(a: std.mem.Allocator, m: model.Map) !model.Map {
    var out = m;
    out.redacted = true;
    if (out.process) |*p| p.name = null;
    const vmas = try a.dupe(model.Vma, m.vmas);
    for (vmas) |*v| if (v.kind == .anon or v.kind == .file or v.kind == .special or v.kind == .hugetlb) {
        v.path = null;
    };
    out.vmas = vmas;
    return out;
}

fn readStat(pid: i32) ?Proc {
    var path: [32]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{pid}) catch return null;
    const fd = c.open(p.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var buf: [1024]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    const s = buf[0..@intCast(n)];
    const open = std.mem.indexOfScalar(u8, s, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, s, ')') orelse return null;
    var out = Proc{ .pid = pid, .start = 0, .rss = 0 };
    const comm = s[open + 1 .. close];
    out.name_len = @intCast(@min(comm.len, 15));
    for (comm[0..out.name_len], 0..) |ch, i| out.name[i] = if (ch < 32 or ch > 126) '?' else ch;
    var fields = std.mem.tokenizeScalar(u8, s[@min(close + 2, s.len)..], ' ');
    var k: usize = 3;
    while (fields.next()) |f| : (k += 1) {
        if (k == 22) out.start = std.fmt.parseInt(u64, f, 10) catch return null;
        if (k == 24) {
            out.rss = (std.fmt.parseInt(u64, f, 10) catch return null) * @as(u64, @intCast(@max(1, c.sysconf(c._SC_PAGESIZE))));
            break;
        }
    }
    return if (out.start != 0) out else null;
}
pub fn startTicks(pid: i32) ?u64 {
    const p = readStat(pid) orelse return null;
    return p.start;
}
fn bytesShort(buf: []u8, v: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var x: f64 = @floatFromInt(v);
    var i: usize = 0;
    while (x >= 1024 and i + 1 < units.len) : (i += 1) x /= 1024;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ x, units[i] }) catch "?";
}
fn readFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var pb: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&pb, "{s}", .{path}) catch return error.ReplayPath;
    const fd = c.open(z.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.ReplayOpenFailed;
    defer _ = c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n < 0) return error.ReplayReadFailed;
        if (n == 0) break;
        try list.appendSlice(a, chunk[0..@intCast(n)]);
        if (list.items.len > 64 << 20) return error.ReplayTooLarge;
    }
    return list.items;
}
fn now() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
fn processNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_PROCESS_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

test "memdefrag options are strict" {
    const ok = try parse(&.{ "xodb", "--memdefrag", "--pid", "42", "--theme", "plain", "--once" });
    try std.testing.expectEqual(@as(?i32, 42), ok.pid);
    try std.testing.expect(ok.plain and ok.once);
    try std.testing.expectError(error.Usage, parse(&.{ "xodb", "--memdefrag", "--theme", "neon" }));
    try std.testing.expectError(error.Usage, parse(&.{ "xodb", "--memdefrag", "--start-ticks", "5" }));
    try std.testing.expectError(error.Usage, parse(&.{ "xodb", "--memdefrag", "--attach", "5" }));
}
