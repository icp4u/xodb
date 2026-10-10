//! `xodb --overview`: a system overview with no debug target. The view keeps
//! history (ring buffers) and presentation state; samples come from a
//! Source (live collector or replay). Panels live in panels.zig.
const std = @import("std");
const gpu = @import("../../render/vulkan.zig");
const Font = @import("../../render/font.zig").Font;
const Window = @import("../../platform/wayland.zig").Window;
const m = @import("model.zig");
const h = @import("history.zig");
const draw = @import("draw.zig");
const themes = @import("theme.zig");
const win95 = @import("win95.zig");
const panels = @import("panels.zig");
pub const files_model = @import("files_model.zig");
pub const memmap = @import("memmap.zig");
pub const graph_model = @import("graph_model.zig");
pub const Ctx = draw.Ctx;
pub const Rect = draw.Rect;
pub const Color = draw.Color;
const fade = draw.fade;

pub const Panel = enum { summary, performance, processes, memory, disk, disk_space, network, connections, power, system, users, services, apps, files, memory_map, graph, galaxy, inheritance, treemap };
pub const panel_count = @typeInfo(Panel).@"enum".fields.len;
pub const titles = [panel_count][]const u8{ "Summary", "Performance", "Processes", "Memory", "Disk", "Disk Space", "Network", "Connections", "Power & Thermals", "System Info", "Users", "Services", "Installed Apps", "Files & IO", "Memory Map", "FD Graph", "FD Galaxy", "Parent/Child FDs", "FD Treemap" };
const keys = [panel_count][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "", "", "", "L", "M", "G", "Y", "I", "B" };

pub const Sort = enum { cpu, memory, disk, net, fds, threads, pid, name };
pub const sort_names = [_][]const u8{ "CPU", "Memory", "Disk", "Net", "FDs", "Threads", "PID", "Name" };

pub const actions = @import("actions.zig");
pub const ActionHook = *const fn (context: ?*anyopaque, request: actions.Request) anyerror!void;

pub const Row = struct { index: u32, depth: u16, children: u16, collapsed: bool };
pub const Identity = struct { pid: i32, start: u64 };

pub const History = struct {
    cpu_total: h.Ring = .{},
    cpu_user: h.Ring = .{},
    cpu_system: h.Ring = .{},
    cpus: [512]h.Ring = @splat(.{}),
    mem_used: h.Ring = .{},
    mem_cached: h.Ring = .{},
    swap_used: h.Ring = .{},
    zswap: h.Ring = .{},
    psi: [6]h.Ring = @splat(.{}), // cpu some/full, memory some/full, io some/full
    disk_read: h.Ring = .{},
    disk_write: h.Ring = .{},
    net_rx: h.Ring = .{},
    net_tx: h.Ring = .{},
    package_temp: h.Ring = .{},
    package_power: h.Ring = .{},
    view_cost: h.Ring = .{},
    collector_cost: h.Ring = .{},
    sample_cost: h.Ring = .{},
    total_cost: h.Ring = .{},
    selected_cpu: h.Ring = .{},
    selected_mem: h.Ring = .{},
    disks: h.Keyed(64, 4) = .{}, // read, write, busy, temp
    nets: h.Keyed(64, 2) = .{}, // rx, tx
    sensors: h.Keyed(256, 1) = .{},
    gpus: h.Keyed(8, 3) = .{}, // busy, power, temp
    scales: [16]h.Scale = @splat(.{}),
};
pub const ScaleId = enum { disk_total, net_total, mem_psi, disk_card, net_card };

pub const View = struct {
    gpa: std.mem.Allocator,
    palette: usize = 0,
    font_path: [:0]const u8 = @import("build_options").font_path ++ "",
    classic_menu: ?win95.Menu = null,
    classic_cursor: usize = 0,
    classic_scroll: ?win95.Scroll = null,
    classic_about: bool = false,
    minimize_requested: bool = false,
    maximize_requested: bool = false,
    panel: Panel = .summary,
    redact: bool = false,
    paused: bool = false,
    source_label: []const u8 = "live",
    files: files_model.State = .{},
    memmap: memmap.State = .{},
    graph: graph_model.State = .{},
    treemap: @import("treemap_model.zig").State = .{},
    /// The Memory map looks draw period-styled tooltips.
    tooltip_style: enum { overview, win9x, dos } = .overview,
    current: ?*m.Owned = null,
    previous: ?*m.Owned = null,
    /// Replay frames belong to the replay; live samples to the view.
    owns_samples: bool = true,
    /// Per group: the sample whose slow-group data is being carried.
    holders: [m.group_count]?*m.Owned = @splat(null),
    /// Eases run only when samples are at least this far apart.
    ease_ns: u64 = 250_000_000,
    sample_time: u64 = 0,
    samples: u64 = 0,
    hist: *History,
    // Processes.
    sort: Sort = .cpu,
    descending: bool = true,
    tree: bool = true,
    rows: std.ArrayList(Row) = .empty,
    collapsed: std.AutoHashMapUnmanaged(Identity, void) = .empty,
    selected: ?Identity = null,
    selected_row: usize = 0,
    rows_dirty: bool = true,
    /// Tree mode: per-process subtree totals of the sort key, so a busy
    /// branch rises with its busiest descendant.
    aggregate: []f64 = &.{},
    search: [64]u8 = undefined,
    search_len: usize = 0,
    searching: bool = false,
    scroll: [panel_count]usize = @splat(0),
    visible_rows: usize = 20,
    // Interaction.
    pointer: [2]f32 = .{ -1, -1 },
    hover_text: [512]u8 = undefined,
    hover_len: usize = 0,
    hover_rect: ?Rect = null,
    status: [160]u8 = undefined,
    status_len: usize = 0,
    status_time: u64 = 0,
    /// Clickable regions recorded while drawing, consumed by the next press.
    hits: [1536]Hit = undefined,
    hit_count: usize = 0,
    action_hook: ?ActionHook = null,
    pending_action: ?actions.Request = null,
    confirm_key: ?u32 = null,
    confirm_after: u64 = 0,
    layout: ?*draw.Layout = null,
    layout_reported: usize = std.math.maxInt(usize),
    layout_panel: Panel = .summary,
    layout_size: [2]f32 = .{ 0, 0 },
    process_ns_start: u64 = 0,
    total_pct: ?f64 = null,
    action_context: ?*anyopaque = null,
    // Cost accounting (thread CPU time spent drawing).
    view_ns_window: u64 = 0,
    collector_ns_window: u64 = 0,
    window_start: u64 = 0,
    view_pct: ?f64 = null,
    collector_pct: ?f64 = null,
    last_frame_ns: u64 = 0,
    frames: u64 = 0,
    width: f32 = 1280,
    height: f32 = 800,
    quit: bool = false,

    pub const Hit = struct { rect: Rect, action: Action };
    pub const Action = union(enum) { classic: win95.Action, classic_scroll: win95.Scroll, panel: Panel, sort: Sort, row: usize, attach, files, profile, confirm, cancel, tree, theme, pause, search, files_mode: files_model.Mode, files_row: usize, files_all, file_holders, events, stop_events, memmap: memmap.Click, graph_star: u32, graph_resource: u32, graph_all, graph_files, inheritance_files: Identity, treemap_node: u32, treemap_up, treemap_holder };

    pub fn init(gpa: std.mem.Allocator) !View {
        const hist = try gpa.create(History);
        hist.* = .{};
        return .{ .gpa = gpa, .hist = hist };
    }
    pub fn deinit(self: *View) void {
        self.files.deinit(self.gpa);
        self.memmap.deinit();
        self.graph.deinit();
        self.treemap.deinit();
        self.dropSamples();
        self.rows.deinit(self.gpa);
        self.collapsed.deinit(self.gpa);
        self.gpa.destroy(self.hist);
    }
    fn dropSamples(self: *View) void {
        if (self.owns_samples) {
            if (self.previous) |p| p.release();
            if (self.current) |c| c.release();
            for (&self.holders) |*hd| if (hd.*) |o| {
                o.release();
                hd.* = null;
            };
        }
        self.previous = null;
        self.current = null;
    }
    pub fn pal(self: *const View) *const themes.Palette {
        return &themes.all[self.palette];
    }
    pub fn snap(self: *const View) ?*const m.Snapshot {
        return if (self.current) |c| &c.snap else null;
    }
    pub fn prev(self: *const View) ?*const m.Snapshot {
        return if (self.previous) |p| &p.snap else null;
    }

    /// Which collector groups the visible panel needs (bit per m.Group). The
    /// sidebar always needs the cheap whole-system groups.
    /// Fast ticks take only the cheap whole-system groups; `slow` ticks
    /// (1 Hz) add what the visible panel needs, such as processes.
    pub fn groups(self: *const View, slow: bool) u32 {
        var mask: u32 = 0;
        for ([_]m.Group{ .summary, .cpu, .memory, .disks, .network, .power, .sysinfo }) |g| mask |= @as(u32, 1) << @intFromEnum(g);
        const extra: []const m.Group = switch (self.panel) {
            .summary => &.{ .processes, .filesystems },
            .processes, .memory_map => &.{.processes},
            .disk_space => &.{.filesystems},
            .connections => &.{ .connections, .processes },
            .users => &.{.users},
            .services => &.{.services},
            .apps => &.{.apps},
            else => &.{},
        };
        if (!slow) return mask;
        for (extra) |g| mask |= @as(u32, 1) << @intFromEnum(g);
        return mask;
    }

    /// Takes a new sample: updates history and keeps the previous one for
    /// eased transitions.
    pub fn accept(self: *View, sample: *m.Owned, now: u64) void {
        if (self.owns_samples) self.carry(sample);
        if (self.owns_samples) if (self.previous) |p| p.release();
        self.previous = self.current;
        self.current = sample;
        self.sample_time = now;
        self.samples += 1;
        if (sample.snap.fresh[@intFromEnum(m.Group.processes)]) self.rows_dirty = true;
        if (sample.snap.memory_map) |map| self.memmap.acceptReplay(map, sample.snap.memory_viewports, now);
        self.record(&sample.snap);
    }

    /// Groups sampled less often than the rest (processes at 1 Hz,
    /// connections only while visible) are carried from the sample that
    /// last collected them, marked not fresh, instead of reading as empty.
    fn carry(self: *View, sample: *m.Owned) void {
        const s = &sample.snap;
        inline for (.{ m.Group.processes, m.Group.connections, m.Group.filesystems, m.Group.users, m.Group.services, m.Group.apps }) |g| {
            const i = @intFromEnum(g);
            const collected = !std.mem.eql(u8, s.groups[i].reason, "not collected");
            if (collected) {
                if (self.holders[i]) |o| o.release();
                self.holders[i] = sample.retain();
            } else if (self.holders[i]) |o| {
                const from = &o.snap;
                s.groups[i] = from.groups[i];
                s.fresh[i] = false;
                switch (g) {
                    .processes => {
                        s.processes = from.processes;
                        s.processes_truncated = from.processes_truncated;
                    },
                    .connections => {
                        s.connections = from.connections;
                        s.connections_truncated = from.connections_truncated;
                        s.owners_unresolved = from.owners_unresolved;
                    },
                    .filesystems => s.mounts = from.mounts,
                    .users => s.users = from.users,
                    .services => {
                        s.services = from.services;
                        s.service_manager = from.service_manager;
                    },
                    .apps => {
                        s.apps_manager = from.apps_manager;
                        s.apps_count = from.apps_count;
                        s.apps_bytes = from.apps_bytes;
                        s.packages = from.packages;
                    },
                    else => {},
                }
            }
        }
    }

    fn record(self: *View, s: *const m.Snapshot) void {
        const H = self.hist;
        H.cpu_total.push(s.cpu_total.get());
        H.cpu_user.push(s.cpu_user.get());
        H.cpu_system.push(s.cpu_system.get());
        for (H.cpus[0..@min(512, s.cpus.len)], s.cpus[0..@min(512, s.cpus.len)]) |*ring, cpu| ring.push(cpu.total.get());
        const total = s.memory.total.get();
        H.mem_used.push(pct(s.memory.used.get(), total));
        H.mem_cached.push(pct(s.memory.cached.get(), total));
        H.swap_used.push(if (s.memory.swap_total.get()) |t| if (t == 0) null else pct(s.memory.swap_used.get(), t) else null);
        H.zswap.push(if (s.memory.zswap_pool.get()) |v| @floatFromInt(v) else null);
        const psis = [6]m.F{ s.psi_cpu.some10, s.psi_cpu.full10, s.psi_memory.some10, s.psi_memory.full10, s.psi_io.some10, s.psi_io.full10 };
        for (&H.psi, psis) |*ring, v| ring.push(v.get());
        // A total is measured only when every part is; a partial sum is not a total.
        var read: ?f64 = if (s.disks.len > 0) 0 else null;
        var write: ?f64 = if (s.disks.len > 0) 0 else null;
        for (s.disks) |d| {
            read = if (read != null and d.read_bps.get() != null) read.? + d.read_bps.get().? else null;
            write = if (write != null and d.write_bps.get() != null) write.? + d.write_bps.get().? else null;
            if (H.disks.slot(d.name)) |i| {
                H.disks.rings[i][0].push(d.read_bps.get());
                H.disks.rings[i][1].push(d.write_bps.get());
                H.disks.rings[i][2].push(d.busy.get());
                H.disks.rings[i][3].push(d.temp_c.get());
            }
        }
        H.disk_read.push(read);
        H.disk_write.push(write);
        // The collector's own aggregate only; an unavailable total stays unavailable.
        const rx = s.net_rx_bps.get();
        const tx = s.net_tx_bps.get();
        for (s.nets) |n| {
            if (H.nets.slot(n.name)) |i| {
                H.nets.rings[i][0].push(n.rx_bps.get());
                H.nets.rings[i][1].push(n.tx_bps.get());
            }
        }
        H.net_rx.push(rx);
        H.net_tx.push(tx);
        H.package_temp.push(s.cpu_package_temp.get());
        H.package_power.push(s.cpu_package_power.get());
        var name_buf: [96]u8 = undefined;
        for (s.sensors) |sensor| {
            const k = std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ sensor.chip, sensor.label }) catch continue;
            if (H.sensors.slot(k)) |i| H.sensors.rings[i][0].push(sensor.value.get());
        }
        for (s.gpus) |g| if (H.gpus.slot(g.card)) |i| {
            H.gpus.rings[i][0].push(g.busy.get());
            H.gpus.rings[i][1].push(g.power_w.get());
            H.gpus.rings[i][2].push(g.temp_c.get());
        };
        H.collector_cost.push(s.cost.cpu_pct.get());
        if (self.selected) |id| if (s.fresh[@intFromEnum(m.Group.processes)]) {
            if (self.findProcess(id)) |p| {
                H.selected_cpu.push(p.cpu.get());
                H.selected_mem.push(if (p.rss.get()) |v| @floatFromInt(v) else null);
            } else {
                H.selected_cpu.push(null);
                H.selected_mem.push(null);
            }
        };
    }

    pub fn findProcess(self: *const View, id: Identity) ?*const m.Process {
        const s = self.snap() orelse return null;
        for (s.processes) |*p| if (p.pid == id.pid and p.start == id.start) return p;
        return null;
    }

    /// Animation progress of the latest sample, 0..1 (eased).
    pub fn ease(self: *const View, now: u64) f32 {
        if (self.samples < 2 or self.ease_ns == 0) return 1;
        const t = @as(f32, @floatFromInt(now -| self.sample_time)) / @as(f32, @floatFromInt(self.ease_ns));
        const x = std.math.clamp(t, 0, 1);
        return 1 - (1 - x) * (1 - x) * (1 - x);
    }
    pub fn animating(self: *const View, now: u64) bool {
        return self.ease(now) < 1 or (self.panel == .files and !self.paused and self.files.flowing(now)) or (self.panel == .memory_map and self.memmap.animating(now)) or ((self.panel == .graph or self.panel == .galaxy) and !self.paused and self.graph.flowing(now));
    }

    pub fn setStatus(self: *View, comptime fmt: []const u8, args: anytype, now: u64) void {
        const s = std.fmt.bufPrint(&self.status, fmt, args) catch return;
        self.status_len = s.len;
        self.status_time = now;
    }
    pub fn hover(self: *View, rect: Rect, comptime fmt: []const u8, args: anytype) void {
        if (!draw.inside(rect, self.pointer[0], self.pointer[1])) return;
        const s = std.fmt.bufPrint(&self.hover_text, fmt, args) catch return;
        self.hover_len = s.len;
        self.hover_rect = rect;
    }
    pub fn hit(self: *View, rect: Rect, action: Action) void {
        if (self.hit_count == self.hits.len) return;
        self.hits[self.hit_count] = .{ .rect = rect, .action = action };
        self.hit_count += 1;
    }

    // --- Input -----------------------------------------------------------

    pub fn input(self: *View, w: *Window, now: u64) void {
        defer self.windowActions(w);
        if (w.pointer_x != self.pointer[0] or w.pointer_y != self.pointer[1]) {
            self.pointer = .{ w.pointer_x, w.pointer_y };
            w.dirty = true;
            if (self.classic_scroll != null) win95.drag(self) else if (self.deepMap()) memmap.deepmap.motion(self);
        }
        if (w.scroll != 0) {
            if (self.classic_menu == null and !self.classic_about and self.pending_action == null) self.wheel(w.scroll);
            w.scroll = 0;
            w.dirty = true;
        }
        while (w.input.next()) |event| {
            switch (event.kind) {
                .press, .repeat => {
                    w.dirty = true;
                    const was_pending = self.pending_action != null;
                    self.key(event, now);
                    if (!was_pending and self.pending_action != null) self.confirm_key = event.code;
                },
                .release => {
                    if (self.confirm_key == event.code) self.confirm_key = null;
                },
                .button_press => {
                    w.dirty = true;
                    // The deep map's field and minimap take presses (drag, select, jump).
                    if (event.code == 272 and !(self.deepMap() and self.pending_action == null and self.classic_menu == null and !self.classic_about and memmap.deepmap.press(self, event.x, event.y))) self.click(event.x, event.y, now);
                },
                .button_release => if (event.code == 272) {
                    if (self.classic_scroll != null) {
                        self.pointer = .{ event.x, event.y };
                        win95.drag(self);
                    }
                    self.classic_scroll = null;
                    if (self.deepMap()) {
                        w.dirty = true;
                        memmap.deepmap.release(self, event.x, event.y);
                    }
                },
            }
            if (self.quit) {
                w.closing = true;
                w.close_reason = .quit_key;
                return;
            }
        }
    }

    fn windowActions(self: *View, w: *Window) void {
        const c = @import("../../c.zig").api;
        if (w.top) |top| {
            if (self.minimize_requested) c.xdg_toplevel_set_minimized(top);
            // The compositor owns this state: it may maximize or restore by other means.
            if (self.maximize_requested) {
                if (w.maximized) c.xdg_toplevel_unset_maximized(top) else c.xdg_toplevel_set_maximized(top);
            }
        }
        self.minimize_requested = false;
        self.maximize_requested = false;
    }

    fn deepMap(self: *const View) bool {
        return self.panel == .memory_map and self.memmap.look == .deep and !self.memmap.legend and !self.memmap.picker_open;
    }
    fn wheel(self: *View, lines: i32) void {
        if (self.panel == .memory_map and self.memmap.look == .deep) return memmap.deepmap.wheel(self, lines);
        if (self.panel == .files) {
            if (lines > 0) self.files.top += @intCast(lines) else self.files.top -|= @intCast(-lines);
            return;
        }
        const s = &self.scroll[@intFromEnum(self.panel)];
        if (lines > 0) s.* += @intCast(lines) else s.* -|= @intCast(-lines);
    }

    fn key(self: *View, event: @import("../../platform/input.zig").Event, now: u64) void {
        const sym = event.sym;
        const shortcut = event.shortcut;
        if (self.pending_action != null) {
            if (event.kind != .press) return;
            if (sym == 0xff1b) self.pending_action = null;
            if (sym == 0xff0d or sym == 0xff8d) self.confirmAction(now);
            return;
        }
        if (self.pal().win95 and win95.key(self, event, now)) return;
        if (event.kind == .press and event.plain() and event.shortcut == 'e' and self.files.exact_active) {
            self.files.stopCapture();
            return;
        }
        if (self.panel == .inheritance and (sym == 0xff0d or sym == 0xff8d)) return;
        if (self.panel == .treemap and @import("treemap_panel.zig").key(self, event)) return;
        if (self.panel == .files and self.filesKey(event, now)) return;
        if ((self.panel == .graph or self.panel == .galaxy) and @import("graph_panel.zig").key(self, event)) return;
        if (self.panel == .memory_map and !self.searching and memmap.key(self, event, now)) return;
        if (self.searching) {
            switch (sym) {
                0xff1b => {
                    self.searching = false;
                    self.search_len = 0;
                    self.rows_dirty = true;
                },
                0xff0d, 0xff8d => self.searching = false,
                0xff08 => if (self.search_len > 0) {
                    self.search_len -= 1;
                    while (self.search_len > 0 and self.search[self.search_len] & 0xc0 == 0x80) self.search_len -= 1;
                    self.rows_dirty = true;
                },
                else => {
                    const t = event.text();
                    if (t.len > 0 and self.search_len + t.len <= self.search.len) {
                        @memcpy(self.search[self.search_len..][0..t.len], t);
                        self.search_len += t.len;
                        self.rows_dirty = true;
                    }
                },
            }
            return;
        }
        if (!event.plain()) return;
        // One input batch can contain a search, Return, navigation and an
        // action before the next draw. Resolve them against the new rows.
        if (self.panel == .processes) self.buildRows() catch {
            self.setStatus("Process rows unavailable", .{}, now);
            return;
        };
        if (event.kind == .repeat and (sym == 0xff0d or sym == 0xff8d or shortcut == 'l' or shortcut == 'f')) return;
        switch (sym) {
            0xff09 => return self.cycle(1), // Tab
            0xfe20 => return self.cycle(-1), // Shift+Tab
            0xff52 => return self.move(-1),
            0xff54 => return self.move(1),
            0xff55 => return self.move(-@as(i32, @intCast(@max(1, self.visible_rows -| 1)))),
            0xff56 => return self.move(@intCast(@max(1, self.visible_rows -| 1))),
            0xff50 => return self.move(-1_000_000),
            0xff57 => return self.move(1_000_000),
            0xff51 => return self.expand(false),
            0xff53 => return self.expand(true),
            0xff0d, 0xff8d => return self.requestAttach(now),
            0xff1b => {
                if (self.search_len > 0) {
                    self.search_len = 0;
                    self.rows_dirty = true;
                }
                return;
            },
            else => {},
        }
        switch (shortcut) {
            '1'...'9' => self.show(@enumFromInt(shortcut - '1')),
            '0' => self.show(.system),
            'q' => self.quit = true,
            't' => {
                self.palette = (self.palette + 1) % themes.all.len;
                self.setStatus("Theme: {s}", .{self.pal().name}, now);
            },
            'p', ' ' => {
                self.paused = !self.paused;
                self.setStatus("{s}", .{if (self.paused) "Paused view; MCP cache may still update" else "Resumed"}, now);
            },
            '/' => {
                if (self.panel != .processes) self.show(.processes);
                self.searching = true;
            },
            's' => if (event.mods.shift) {
                self.descending = !self.descending;
                self.rows_dirty = true;
            } else self.cycleSort(),
            'r' => {
                self.descending = !self.descending;
                self.rows_dirty = true;
            },
            'l' => if (self.panel == .processes) self.requestAction(.files, now) else self.show(.files),
            'f' => self.requestAction(.profile, now),
            'g' => self.show(.graph),
            'y' => self.show(.galaxy),
            'i' => self.show(.inheritance),
            'b' => self.show(.treemap),
            'm' => if (self.panel == .processes) memmap.openSelected(self, now) else self.show(.memory_map),
            'v' => {
                self.tree = !self.tree;
                self.rows_dirty = true;
            },
            'x' => if (!self.redact) {
                // Redaction can be turned on while recording, never off.
                self.redact = true;
                self.rows_dirty = true;
                self.files.dirty = true;
                self.files.query_len = 0;
                self.files.searching = false;
                self.memmap.reader.reset();
                self.setStatus("Redaction on: hostnames, users, addresses and arguments hidden (restart to show)", .{}, now);
            },
            else => {},
        }
    }
    pub fn show(self: *View, panel: Panel) void {
        self.classic_menu = null;
        self.classic_scroll = null;
        self.panel = panel;
        self.searching = false;
        self.files.searching = false;
        if (panel == .files) self.files.dirty = true;
    }
    fn filesKey(self: *View, event: @import("../../platform/input.zig").Event, now: u64) bool {
        const f = &self.files;
        if (f.searching) {
            switch (event.sym) {
                0xff1b => {
                    f.searching = false;
                    f.query_len = 0;
                },
                0xff0d, 0xff8d => f.searching = false,
                0xff08 => if (f.query_len > 0) {
                    f.query_len -= 1;
                    while (f.query_len > 0 and f.query[f.query_len] & 0xc0 == 0x80) f.query_len -= 1;
                },
                else => {
                    const value = event.text();
                    if (value.len > 0 and f.query_len + value.len <= f.query.len) {
                        @memcpy(f.query[f.query_len..][0..value.len], value);
                        f.query_len += value.len;
                    }
                },
            }
            f.dirty = true;
            return true;
        }
        if (!event.plain()) return false;
        f.rebuild(self.gpa, self.redact) catch {
            self.setStatus("Descriptor list unavailable: out of memory", .{}, now);
            return true;
        };
        if (event.sym == 0xff1b or event.sym == 0xff08) {
            f.all();
            return true;
        }
        if (event.sym == 0xff0d or event.sym == 0xff8d) {
            if (event.kind == .press) if (f.current()) |selected| f.scope(selected.owner);
            return true;
        }
        switch (event.shortcut) {
            '/' => f.searching = true,
            's' => {
                f.sort = @enumFromInt((@intFromEnum(f.sort) + 1) % 3);
                f.dirty = true;
            },
            'r' => {
                f.reverse = !f.reverse;
                f.dirty = true;
            },
            '[' => f.show(@enumFromInt((@intFromEnum(f.mode) + 3) % 4)),
            ']' => f.show(@enumFromInt((@intFromEnum(f.mode) + 1) % 4)),
            'h' => self.fileHolders(),
            'e' => if (event.kind == .press) {
                if (f.event_authorized or f.exact_active) f.stopCapture() else self.requestAction(.events, now);
            },
            'a' => if (event.kind == .press) self.requestAction(.attach, now),
            'f' => if (event.kind == .press) self.requestAction(.profile, now),
            else => return false,
        }
        return true;
    }
    fn fileHolders(self: *View) void {
        const f = &self.files;
        f.rebuild(self.gpa, self.redact) catch return;
        const s = f.snapshot orelse return;
        if (f.current() == null or f.selected_row >= f.rows.items.len) return;
        const row = f.rows.items[f.selected_row];
        if (row != .descriptor or row.descriptor.fd >= s.fd_count) return;
        const fd = s.fds[row.descriptor.fd];
        if (fd.flags & @import("../../c.zig").api.XRT_FD_STAT == 0) return;
        f.filter = null;
        f.file_filter = .{ .device = fd.device, .inode = fd.inode };
        f.query_len = 0;
        f.show(.files);
    }
    fn cycle(self: *View, by: i32) void {
        const n: i32 = panel_count;
        self.show(@enumFromInt(@as(u32, @intCast(@mod(@as(i32, @intFromEnum(self.panel)) + by, n)))));
    }
    fn cycleSort(self: *View) void {
        self.sort = @enumFromInt((@intFromEnum(self.sort) + 1) % sort_names.len);
        self.descending = self.sort != .name and self.sort != .pid;
        self.rows_dirty = true;
    }
    fn move(self: *View, by: i32) void {
        if (self.panel == .files) return self.files.move(by);
        if (self.panel != .processes) {
            const s = &self.scroll[@intFromEnum(self.panel)];
            if (by > 0) s.* += @intCast(by) else s.* -|= @intCast(-by);
            return;
        }
        if (self.rows.items.len == 0) return;
        const last: i64 = @intCast(self.rows.items.len - 1);
        const at = std.math.clamp(@as(i64, @intCast(self.selected_row)) + by, 0, last);
        self.selectRow(@intCast(at));
    }
    pub fn selectRow(self: *View, row: usize) void {
        const s = self.snap() orelse return;
        if (row >= self.rows.items.len) return;
        const p = s.processes[self.rows.items[row].index];
        const id = Identity{ .pid = p.pid, .start = p.start };
        if (self.selected == null or !std.meta.eql(self.selected.?, id)) {
            self.hist.selected_cpu = .{};
            self.hist.selected_mem = .{};
        }
        self.selected = id;
        self.selected_row = row;
        const top = &self.scroll[@intFromEnum(Panel.processes)];
        if (row < top.*) top.* = row;
        if (row >= top.* + self.visible_rows) top.* = row + 1 - self.visible_rows;
        self.auditProcessSelection();
    }
    fn expand(self: *View, open: bool) void {
        if (self.panel != .processes or !self.tree) return;
        const id = self.selected orelse return;
        if (open) _ = self.collapsed.remove(id) else self.collapsed.put(self.gpa, id, {}) catch {};
        self.rows_dirty = true;
    }
    pub fn requestAttach(self: *View, now: u64) void {
        self.requestAction(.attach, now);
    }
    pub fn requestAction(self: *View, kind: actions.Kind, now: u64) void {
        if (self.panel != .processes and self.panel != .files) return;
        if (self.panel == .processes) self.buildRows() catch {
            self.setStatus("Process rows unavailable", .{}, now);
            return;
        };
        const id: Identity = if (self.panel == .files) blk: {
            // A scoped process remains selectable after an empty capture stops.
            const owner = if (self.files.current()) |selected| selected.owner else self.files.filter orelse {
                self.setStatus("Select a process or descriptor first", .{}, now);
                return;
            };
            break :blk .{ .pid = owner.pid, .start = owner.start };
        } else self.selected orelse return;
        if (self.panel == .processes and self.findProcess(id) == null) {
            self.setStatus("Process {d} exited; nothing to open", .{id.pid}, now);
            return;
        }
        if (self.action_hook == null) {
            self.setStatus("Replay: process actions require a live process", .{}, now);
            return;
        }
        if (self.redact and (kind == .attach or kind == .profile)) {
            self.setStatus("Attach and Profile are unavailable in redaction mode: debugger windows cannot redact", .{}, now);
            return;
        }
        self.pending_action = .{ .kind = kind, .id = .{ .pid = id.pid, .start = id.start } };
        self.confirm_key = null;
        self.confirm_after = now + 250_000_000;
    }
    fn confirmAction(self: *View, now: u64) void {
        if (self.confirm_key != null or now < self.confirm_after) return;
        const request = self.pending_action orelse return;
        self.pending_action = null;
        if (request.kind == .files or request.kind == .events) {
            @import("../../model/process_identity.zig").validate(request.id) catch |err| {
                self.setStatus("Cannot open process: {s}", .{@errorName(err)}, now);
                return;
            };
            self.files.scope(.{ .pid = request.id.pid, .start = request.id.start });
            if (request.kind == .events) {
                self.files.event_target = .{ .pid = request.id.pid, .start = request.id.start };
                self.files.event_authorized = true;
                self.files.stop_requested = false;
                self.files.show(.events);
            }
            self.show(.files);
            self.setStatus("Opened {s} for pid {d}", .{ @tagName(request.kind), request.id.pid }, now);
            return;
        }
        const hook = self.action_hook orelse return;
        hook(self.action_context, request) catch |err| {
            self.setStatus("Cannot open process: {s}", .{@errorName(err)}, now);
            return;
        };
        self.setStatus("Opened {s} for pid {d} (start {d})", .{ @tagName(request.kind), request.id.pid, request.id.start }, now);
    }

    fn click(self: *View, x: f32, y: f32, now: u64) void {
        var i = self.hit_count;
        while (i > 0) {
            i -= 1;
            const target = self.hits[i];
            if (!draw.inside(target.rect, x, y)) continue;
            const action = target.action;
            self.pointer = .{ x, y };
            self.classic_menu = null;
            self.activate(action, now);
            return;
        }
    }

    pub fn activate(self: *View, action: Action, now: u64) void {
        switch (action) {
            .classic_scroll => |scroll| {
                self.classic_scroll = scroll;
                self.classic_scroll.?.grab = self.pointer[1] - scroll.thumb_y;
            },
            .classic => |which| switch (which) {
                .file, .view, .panels, .help, .start => {
                    const menu: win95.Menu = @enumFromInt(@intFromEnum(which));
                    self.classic_menu = menu;
                    self.classic_cursor = 0;
                },
                .close_menu => self.classic_menu = null,
                .quit => self.quit = true,
                .minimize => self.minimize_requested = true,
                .maximize => self.maximize_requested = true,
                .redact => {
                    self.redact = true;
                    self.rows_dirty = true;
                    self.files.dirty = true;
                },
                .about => self.classic_about = true,
                .dismiss => self.classic_about = false,
                .scroll_up => self.wheel(-1),
                .scroll_down => self.wheel(1),
                .page_up => self.wheel(-@as(i32, @intCast(@min(if (self.panel == .files) self.files.visible else self.visible_rows, 1024)))),
                .page_down => self.wheel(@intCast(@min(if (self.panel == .files) self.files.visible else self.visible_rows, 1024))),
            },
            .panel => |p| self.show(p),
            .sort => |s| {
                if (self.sort == s) self.descending = !self.descending else {
                    self.sort = s;
                    self.descending = s != .name and s != .pid;
                }
                self.rows_dirty = true;
            },
            .row => |r| self.selectRow(r),
            .attach => self.requestAttach(now),
            .files => self.requestAction(.files, now),
            .profile => self.requestAction(.profile, now),
            .confirm => self.confirmAction(now),
            .cancel => self.pending_action = null,
            .tree => {
                self.tree = !self.tree;
                self.rows_dirty = true;
            },
            .theme => self.palette = (self.palette + 1) % themes.all.len,
            .pause => self.paused = !self.paused,
            .search => self.searching = true,
            .files_mode => |mode| if (mode == .events) self.requestAction(.events, now) else self.files.show(mode),
            .files_row => |row| self.files.select(row),
            .files_all => self.files.all(),
            .file_holders => self.fileHolders(),
            .events => self.requestAction(.events, now),
            .stop_events => self.files.stopCapture(),
            .memmap => |what| memmap.click(self, what, now),
            .inheritance_files => |id| {
                self.files.scope(.{ .pid = id.pid, .start = id.start });
                self.show(.files);
            },
            .treemap_node => |node| self.treemap.select(node),
            .treemap_up => self.treemap.up(),
            .treemap_holder => @import("treemap_panel.zig").holder(self),
            .graph_star => |index| self.graph.focusStar(index),
            .graph_resource => |node| @import("graph_panel.zig").openResource(self, node),
            .graph_all => self.graph.all(),
            .graph_files => if (self.graph.focus) |id| {
                self.files.scope(.{ .pid = id.pid, .start = id.start });
                self.show(.files);
            },
        }
    }

    // --- Redaction ---------------------------------------------------------

    /// Applies the view's own redaction on top of the source's: a replay or a
    /// non-redacted sample still hides private text when --redact is on.
    pub fn private(self: *const View, t: m.Text) m.Text {
        if (!self.redact or !t.ok()) return t;
        return m.Text.missing("redacted");
    }
    /// The distribution name and kernel release identify a machine in a
    /// recording; with --redact they read as neutral placeholders.
    pub fn osText(self: *const View, t: m.Text) []const u8 {
        return if (self.redact or !t.ok()) "Linux" else t.s;
    }
    pub fn kernelText(self: *const View, t: m.Text) m.Text {
        return if (self.redact) m.Text.of("kernel hidden") else t;
    }
    /// Mount points: system paths stay, anything under a home or media root is hidden.
    pub fn mountPath(self: *const View, t: m.Text) m.Text {
        if (!self.redact or !t.ok()) return t;
        const public = [_][]const u8{ "/", "/boot", "/efi", "/boot/efi", "/usr", "/var", "/tmp", "/opt", "/srv", "/home", "/nix", "/data" };
        for (public) |p| if (std.mem.eql(u8, t.s, p)) return t;
        if (std.mem.startsWith(u8, t.s, "/var/") or std.mem.startsWith(u8, t.s, "/sys/") or std.mem.startsWith(u8, t.s, "/proc/")) return t;
        return m.Text.missing("redacted");
    }
    /// Loopback and wildcard endpoints stay; every other address is hidden.
    /// Unix sockets stay only under system runtime directories.
    pub fn address(self: *const View, t: m.Text) m.Text {
        if (!self.redact or !t.ok() or t.s.len == 0) return t;
        if (t.s[0] == '/') {
            const system = [_][]const u8{ "/run/", "/var/run/", "/tmp/.X11-unix/", "/dev/" };
            const personal = [_][]const u8{ "/run/user/", "/var/run/user/", "/run/media/" };
            for (personal) |pfx| if (std.mem.startsWith(u8, t.s, pfx)) return m.Text.missing("redacted");
            for (system) |pfx| if (std.mem.startsWith(u8, t.s, pfx)) return t;
            return m.Text.missing("redacted");
        }
        if (publicHost(hostPart(t.s))) return t;
        return m.Text.missing("redacted");
    }

    // --- Process rows -------------------------------------------------------

    pub fn searchText(self: *const View) []const u8 {
        return self.search[0..self.search_len];
    }

    fn keyAt(self: *const View, procs: []const m.Process, i: u32) f64 {
        return if (i < self.aggregate.len) self.aggregate[i] else ownKey(self.sort, &procs[i]);
    }
    fn ownKey(sort: Sort, p: *const m.Process) f64 {
        return switch (sort) {
            .cpu => p.cpu.get() orelse -1,
            .memory => if (p.rss.get()) |v| @floatFromInt(v) else -1,
            .disk => if (p.read_bps.get() == null or p.write_bps.get() == null) -1 else p.read_bps.get().? + p.write_bps.get().?,
            .net => p.net_bps.get() orelse -1,
            .fds => if (p.fds.get()) |v| @floatFromInt(v) else -1,
            .threads => if (p.threads.get()) |v| @floatFromInt(v) else -1,
            .pid => @floatFromInt(p.pid),
            .name => 0,
        };
    }
    fn before(self: *const View, procs: []const m.Process, a: u32, b: u32) bool {
        const pa = &procs[a];
        const pb = &procs[b];
        if (self.sort == .name) {
            var na: [24]u8 = undefined;
            var nb: [24]u8 = undefined;
            const order = std.ascii.orderIgnoreCase(processName(self, pa, &na), processName(self, pb, &nb));
            if (order != .eq) return (order == .lt) == !self.descending;
            return pa.pid < pb.pid;
        }
        const ka = self.keyAt(procs, a);
        const kb = self.keyAt(procs, b);
        if (ka != kb) return if (self.descending) ka > kb else ka < kb;
        return pa.pid < pb.pid;
    }
    fn matches(self: *const View, p: *const m.Process) bool {
        const q = self.searchText();
        if (q.len == 0) return true;
        // Under redaction, search sees only the alias, so it cannot reveal names.
        var nb: [24]u8 = undefined;
        if (std.ascii.indexOfIgnoreCase(processName(self, p, &nb), q) != null) return true;
        var buf: [16]u8 = undefined;
        if (std.mem.startsWith(u8, std.fmt.bufPrint(&buf, "{d}", .{p.pid}) catch "", q)) return true;
        if (self.redact) return false;
        const cmd = self.private(p.cmdline);
        return cmd.ok() and std.ascii.indexOfIgnoreCase(cmd.s, q) != null;
    }

    /// Rebuilds the visible process rows: sorted flat list, or a tree whose
    /// siblings are sorted. A search keeps matches and their ancestors.
    pub fn buildRows(self: *View) !void {
        if (!self.rows_dirty) return;
        defer self.auditProcessSelection();
        self.rows_dirty = false;
        errdefer {
            self.rows_dirty = true;
            self.selected = null;
            self.rows.clearRetainingCapacity();
        }
        self.rows.clearRetainingCapacity();
        const s = self.snap() orelse return;
        const procs = s.processes;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const keep = try a.alloc(bool, procs.len);
        for (procs, keep) |*p, *k| k.* = self.matches(p);
        if (!self.tree) {
            var order: std.ArrayList(u32) = .empty;
            for (procs, 0..) |_, i| if (keep[i]) try order.append(a, @intCast(i));
            std.mem.sort(u32, order.items, Sorter{ .view = self, .procs = procs }, Sorter.less);
            for (order.items) |i| try self.rows.append(self.gpa, .{ .index = i, .depth = 0, .children = 0, .collapsed = false });
        } else {
            var by_pid: std.AutoHashMapUnmanaged(i32, u32) = .empty;
            for (procs, 0..) |p, i| try by_pid.put(a, p.pid, @intCast(i));
            const parent = try a.alloc(?u32, procs.len);
            for (procs, parent) |p, *par| par.* = if (p.ppid != p.pid) by_pid.get(p.ppid) else null;
            // A search keeps every ancestor of a match so the tree stays readable.
            if (self.search_len > 0) for (0..procs.len) |i| if (keep[i]) {
                var at = parent[i];
                var guard: usize = 0;
                while (at) |pi| : (guard += 1) {
                    if (guard > procs.len or keep[pi]) break;
                    keep[pi] = true;
                    at = parent[pi];
                }
            };
            const children = try a.alloc(std.ArrayList(u32), procs.len);
            @memset(children, .empty);
            var roots: std.ArrayList(u32) = .empty;
            for (0..procs.len) |i| {
                if (!keep[i]) continue;
                if (parent[i]) |pi| if (keep[pi]) {
                    try children[pi].append(a, @intCast(i));
                    continue;
                };
                try roots.append(a, @intCast(i));
            }
            // Subtree totals for summable keys (bounded walk up each chain).
            const summable = self.sort != .pid and self.sort != .name;
            const totals = try a.alloc(f64, procs.len);
            for (procs, totals) |*p, *t| t.* = ownKey(self.sort, p);
            if (summable) for (0..procs.len) |i| {
                const own = ownKey(self.sort, &procs[i]);
                if (own <= 0) continue;
                var at = parent[i];
                var guard: usize = 0;
                while (at) |pi| : (guard += 1) {
                    if (guard > 256) break;
                    totals[pi] = @max(totals[pi], 0) + own;
                    at = parent[pi];
                }
            };
            self.aggregate = totals;
            defer self.aggregate = &.{};
            const sorter = Sorter{ .view = self, .procs = procs };
            std.mem.sort(u32, roots.items, sorter, Sorter.less);
            for (children) |*list| std.mem.sort(u32, list.items, sorter, Sorter.less);
            const Walk = struct {
                fn visit(view: *View, kids: []std.ArrayList(u32), ps: []const m.Process, i: u32, depth: u16) !void {
                    const id = Identity{ .pid = ps[i].pid, .start = ps[i].start };
                    const closed = view.collapsed.contains(id) and view.search_len == 0;
                    try view.rows.append(view.gpa, .{ .index = i, .depth = depth, .children = @intCast(@min(kids[i].items.len, 65535)), .collapsed = closed });
                    if (closed or depth > 200) return;
                    for (kids[i].items) |child| try visit(view, kids, ps, child, depth + 1);
                }
            };
            for (roots.items) |r| try Walk.visit(self, children, procs, r, 0);
        }
        // Start with the top row selected so its identity and the debugger
        // hand-off are visible at once.
        if (self.selected == null and self.rows.items.len > 0) {
            const p = procs[self.rows.items[0].index];
            self.selected = .{ .pid = p.pid, .start = p.start };
        }
        // Keep the selection on the same identity when rows move.
        if (self.selected) |id| {
            for (self.rows.items, 0..) |row, i| if (procs[row.index].pid == id.pid and procs[row.index].start == id.start) {
                self.selected_row = i;
                return;
            };
        }
        self.selected_row = @min(self.selected_row, self.rows.items.len -| 1);
        // A filtered-out identity must not remain the action target. In
        // particular an empty search result cannot open the old selection.
        if (self.rows.items.len == 0) self.selected = null else self.selectRow(self.selected_row);
    }
    fn auditProcessSelection(self: *const View) void {
        if (@import("../../c.zig").api.getenv("XODB_OVERVIEW_AUDIT") == null) return;
        const query_pid = std.fmt.parseInt(i32, self.searchText(), 10) catch 0;
        var query_row: i64 = -1;
        if (self.snap()) |snapshot| for (self.rows.items, 0..) |row, i| {
            if (snapshot.processes[row.index].pid == query_pid) {
                query_row = @intCast(i);
                break;
            }
        };
        std.debug.print("xodb: process selection query_pid={d} query_row={d} rows={d} selected_pid={d} start={d}\n", .{
            query_pid, query_row, self.rows.items.len, if (self.selected) |id| id.pid else 0, if (self.selected) |id| id.start else 0,
        });
    }
    const Sorter = struct {
        view: *const View,
        procs: []const m.Process,
        fn less(self: Sorter, a: u32, b: u32) bool {
            return self.view.before(self.procs, a, b);
        }
    };

    // --- Frame ----------------------------------------------------------------

    pub fn frame(self: *View, r: *gpu.Renderer, font: *Font, w: *Window, now: u64) !void {
        const started = threadNs();
        defer self.account(threadNs() -| started, now);
        self.width = @floatFromInt(w.width);
        self.height = @floatFromInt(w.height);
        self.hover_len = 0;
        self.hover_rect = null;
        self.hit_count = 0;
        self.tooltip_style = .overview;
        const p = self.pal();
        try font.selectOverview(self.gpa, self.font_path, p.win95);
        if (!p.win95) {
            self.classic_menu = null;
            self.classic_about = false;
        }
        if (p.win95) self.tooltip_style = .win9x;
        if (self.layout) |l| l.count = 0;
        var ctx = Ctx{ .r = r, .font = font, .p = p, .layout = self.layout };
        try r.rect(.{ .x = 0, .y = 0, .w = self.width, .h = self.height }, p.background);
        if (p.glow > 0.5) try r.shape(.{ .x = self.width * 0.1, .y = self.height * 0.05, .w = self.width * 0.8, .h = self.height * 0.9 }, fade(p.accent, 0.035), .{ .radii = @splat(self.height * 0.3), .softness = self.height * 0.2 });
        const compact = self.width < 1500;
        const header_h: f32 = 52;
        const footer_h: f32 = 28;
        const nav_w: f32 = if (compact) 196 else 236;
        const content = if (p.win95) try win95.chrome(self, ctx) else blk: {
            try self.header(ctx, .{ .x = 0, .y = 0, .w = self.width, .h = header_h }, now);
            try self.nav(ctx, .{ .x = 0, .y = header_h, .w = nav_w, .h = self.height - header_h - footer_h });
            break :blk Rect{ .x = nav_w + 10, .y = header_h + 8, .w = self.width - nav_w - 20, .h = self.height - header_h - footer_h - 14 };
        };
        const saved = r.clip;
        r.clip = draw.intersect(saved, content);
        if (self.snap()) |s| {
            if (content.w > 0 and content.h > 0) panels.render(self, ctx, content, s, now) catch |err| {
                r.clip = saved;
                if (err != error.VertexBufferFull) return err;
                try ctx.text(content.x + 12, content.y + 12, "This panel exceeded the frame's geometry budget; enlarge rows or narrow the window", p.crit);
            };
        } else {
            try ctx.glowText(content.x + 24, content.y + 24, "Waiting for the first sample…", p.dim);
        }
        r.clip = saved;
        if (p.win95) {
            if (self.width >= 640 and self.height >= 120) try self.footer(ctx, .{ .x = 8, .y = self.height - 72, .w = self.width - 16, .h = footer_h }, now);
        } else try self.footer(ctx, .{ .x = 0, .y = self.height - footer_h, .w = self.width, .h = footer_h }, now);
        if (self.layout) |l| {
            var first: [6][]const u8 = @splat("");
            const n = l.overlaps(&first);
            if (n != self.layout_reported or self.panel != self.layout_panel or self.layout_size[0] != self.width or self.layout_size[1] != self.height) {
                self.layout_size = .{ self.width, self.height };
                std.debug.print("xodb: overview layout {d}x{d} panel={s} overlaps={d} first=\"{s}\"/\"{s}\" \"{s}\"/\"{s}\" \"{s}\"/\"{s}\"\n", .{ @as(u32, @intFromFloat(self.width)), @as(u32, @intFromFloat(self.height)), @tagName(self.panel), n, first[0], first[1], first[2], first[3], first[4], first[5] });
                self.layout_reported = n;
                self.layout_panel = self.panel;
            }
        }
        ctx.layout = null;
        if (p.win95) {
            self.tooltip_style = .win9x;
            try win95.popup(self, ctx);
            try win95.about(self, ctx);
        }
        if (self.pending_action == null and !self.classic_about) try self.tooltip(ctx);
        try self.overlay(ctx);
        try self.actionDialog(ctx);
    }

    fn account(self: *View, ns: u64, now: u64) void {
        self.frames += 1;
        self.last_frame_ns = ns;
        self.view_ns_window += ns;
        self.roll(now);
    }
    /// Closes a one-second cost window, also when no frame was drawn in it.
    pub fn roll(self: *View, now: u64) void {
        if (self.window_start == 0) {
            self.window_start = now;
            self.process_ns_start = processNs();
        }
        const span = now -| self.window_start;
        if (span >= 1_000_000_000) {
            self.view_pct = @as(f64, @floatFromInt(self.view_ns_window)) * 100 / @as(f64, @floatFromInt(span));
            self.collector_pct = @as(f64, @floatFromInt(self.collector_ns_window)) * 100 / @as(f64, @floatFromInt(span));
            self.hist.view_cost.push(self.view_pct);
            // Every thread of the process: drawing, sampling, and the GPU driver's own threads.
            const p_now = processNs();
            self.hist.total_cost.push(@as(f64, @floatFromInt(p_now -| self.process_ns_start)) * 100 / @as(f64, @floatFromInt(span)));
            self.process_ns_start = p_now;
            self.hist.sample_cost.push(self.collector_pct);
            // Show 4 s means: process lists refresh every 1.5-2 s.
            self.view_pct = mean(&self.hist.view_cost, 4);
            self.collector_pct = mean(&self.hist.sample_cost, 4);
            self.total_pct = mean(&self.hist.total_cost, 4);
            self.view_ns_window = 0;
            self.collector_ns_window = 0;
            self.window_start = now;
        }
    }
    /// The source's sampling cost, measured on this thread.
    pub fn sourceCost(self: *View, ns: u64) void {
        self.collector_ns_window += ns;
    }

    fn header(self: *View, ctx: Ctx, rect: Rect, now: u64) !void {
        const p = ctx.p;
        try ctx.r.shape(rect, p.panel, .{ .colors = .{ p.raised, p.raised, p.panel, p.panel } });
        try ctx.r.rect(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, p.border);
        // Wordmark: a small VFD glyph block and the name.
        try ctx.r.shape(.{ .x = 14, .y = 12, .w = 28, .h = 28 }, fade(p.accent, 0.14), .{ .radii = @splat(6) });
        _ = try ctx.vfd(19, 17, 18, "88", fade(p.accent, 0.25));
        _ = try ctx.vfd(19, 17, 18, "0", p.accent);
        try ctx.glowText(52, 7, "xodb overview", p.text);
        const s = self.snap();
        var buf: [256]u8 = undefined;
        var b2: [32]u8 = undefined;
        if (s) |snapshot| {
            const host = self.private(snapshot.hostname);
            const kernel = self.kernelText(snapshot.kernel);
            const line = std.fmt.bufPrint(&buf, "{s}  ·  {s}  ·  up {s}", .{ if (host.ok()) host.s else "host hidden", if (kernel.ok()) kernel.s else "kernel ?", if (snapshot.uptime_s.get()) |u| m.duration(&b2, u) else "?" }) catch "";
            const chips_w = @as(f32, @floatFromInt(headerChips(rect.w))) * 178 + ctx.measure(if (self.paused) "PAUSED" else self.source_label) + 50;
            try ctx.textFit(52, 27, @max(0, rect.w - chips_w - 62), line, p.dim);
            if (!host.ok()) self.hover(.{ .x = 52, .y = 27, .w = 120, .h = 20 }, "Hostname: {s}", .{host.why});
        }
        // Live stat chips with sparklines, right-aligned.
        var x = rect.w - 14;
        const badge = if (self.paused) "PAUSED" else self.source_label;
        const bw = ctx.measure(badge) + 18;
        x -= bw;
        try ctx.r.shape(.{ .x = x, .y = 14, .w = bw, .h = 24 }, fade(if (self.paused) p.warn else p.accent, 0.14), .{ .radii = @splat(12) });
        try ctx.r.shape(.{ .x = x, .y = 14, .w = bw, .h = 24 }, fade(if (self.paused) p.warn else p.accent, 0.6), .{ .radii = @splat(12), .border = 1 });
        try ctx.text(x + 9, 16, badge, if (self.paused) p.warn else p.accent);
        self.hit(.{ .x = x, .y = 14, .w = bw, .h = 24 }, .pause);
        x -= 10;
        const shown = headerChips(rect.w);
        if (shown == 0) return;
        const H = self.hist;
        const chips = [_]struct { label: []const u8, ring: *const h.Ring, kind: Kind, max: f32 }{
            .{ .label = "NET", .ring = &H.net_rx, .kind = .rate, .max = 0 },
            .{ .label = "DISK", .ring = &H.disk_write, .kind = .rate, .max = 0 },
            .{ .label = "MEM", .ring = &H.mem_used, .kind = .percent, .max = 100 },
            .{ .label = "CPU", .ring = &H.cpu_total, .kind = .percent, .max = 100 },
        };
        for (chips[chips.len - shown ..], chips.len - shown..) |chip, i| {
            const cw: f32 = 170;
            x -= cw + 8;
            const cr = Rect{ .x = x, .y = 8, .w = cw, .h = 36 };
            try ctx.r.shape(cr, fade(p.raised, 0.9), .{ .radii = @splat(6) });
            try ctx.text(cr.x + 8, cr.y + 1, chip.label, p.dim);
            var vb: [32]u8 = undefined;
            const value: []const u8 = if (i == 0) blk: {
                const rx = H.net_rx.last();
                const tx = H.net_tx.last();
                break :blk if (rx == null or tx == null) "—" else m.rate(&vb, rx.? + tx.?);
            } else if (i == 1) blk: {
                const rd = H.disk_read.last();
                const wr = H.disk_write.last();
                break :blk if (rd == null or wr == null) "—" else m.rate(&vb, rd.? + wr.?);
            } else format(&vb, chip.kind, chip.ring.last());
            try ctx.text(cr.x + 8, cr.y + 17, value, p.text);
            const max = if (chip.max > 0) chip.max else h.nice(@max(1024, chip.ring.max(40)));
            try spark(ctx, .{ .x = cr.x + 92, .y = cr.y + 5, .w = cw - 100, .h = 26 }, chip.ring, max, if (i == 0) p.accent3 else if (i == 1) p.accent2 else p.accent, 40, self.ease(now));
        }
    }

    fn nav(self: *View, ctx: Ctx, rect: Rect) !void {
        const p = ctx.p;
        try ctx.r.rect(rect, p.panel);
        try ctx.r.rect(.{ .x = rect.x + rect.w - 1, .y = rect.y, .w = 1, .h = rect.h }, p.border);
        const item_h = @min(54, @floor((rect.h - 16) / panel_count));
        const s = self.snap();
        for (0..panel_count) |i| {
            const panel: Panel = @enumFromInt(i);
            const row = Rect{ .x = rect.x + 8, .y = rect.y + 8 + @as(f32, @floatFromInt(i)) * item_h, .w = rect.w - 16, .h = item_h - 4 };
            const on = panel == self.panel;
            const hot = draw.inside(row, self.pointer[0], self.pointer[1]);
            if (on) {
                try ctx.r.shape(row, p.selection, .{ .radii = @splat(6) });
                try ctx.r.shape(.{ .x = row.x, .y = row.y + 6, .w = 3, .h = row.h - 12 }, p.accent, .{ .radii = @splat(1.5) });
                if (p.glow > 0) try ctx.r.shape(.{ .x = row.x - 6, .y = row.y, .w = 14, .h = row.h }, fade(p.accent, 0.25 * p.glow), .{ .radii = @splat(6), .softness = 5 });
            } else if (hot) try ctx.r.shape(row, fade(p.selection, 0.5), .{ .radii = @splat(6) });
            self.hit(row, .{ .panel = panel });
            const ty = row.y + (if (item_h >= 48) @as(f32, 4) else (row.h - 20) / 2);
            if (keys[i].len > 0) {
                try ctx.r.shape(.{ .x = row.x + 10, .y = ty + 1, .w = 18, .h = 18 }, fade(p.dim, 0.14), .{ .radii = @splat(4) });
                try ctx.text(row.x + 14, ty, keys[i], if (on) p.accent else p.dim);
            }
            try ctx.textFit(row.x + 36, ty, row.w - 40, titles[i], if (on) p.text else mixText(p, 0.75));
            if (item_h < 48) continue;
            // Second line: a live value and a sparkline where history exists.
            var vb: [48]u8 = undefined;
            const H = self.hist;
            var detail: struct { text: []const u8, ring: ?*const h.Ring = null, max: f32 = 100 } = if (s) |snapshot| switch (panel) {
                .summary, .performance => .{ .text = format(&vb, .percent, H.cpu_total.last()), .ring = &H.cpu_total },
                .processes => .{ .text = if (snapshot.process_count.get()) |n| std.fmt.bufPrint(&vb, "{d} processes", .{n}) catch "" else "—" },
                .memory => .{ .text = format(&vb, .percent, H.mem_used.last()), .ring = &H.mem_used },
                .disk => .{ .text = if (H.disk_read.last() == null or H.disk_write.last() == null) snapshot.group(.disks).reason else m.rate(&vb, H.disk_read.last().? + H.disk_write.last().?), .ring = &H.disk_write, .max = h.nice(@max(1 << 20, H.disk_write.max(40))) },
                .disk_space => .{ .text = fullest(&vb, snapshot) },
                .network => .{ .text = if (H.net_rx.last() == null or H.net_tx.last() == null) (if (snapshot.net_rx_bps.get() == null) snapshot.net_rx_bps.reason else snapshot.net_tx_bps.reason) else m.rate(&vb, H.net_rx.last().? + H.net_tx.last().?), .ring = &H.net_rx, .max = h.nice(@max(64 << 10, H.net_rx.max(40))) },
                .connections => .{ .text = if (snapshot.group(.connections).status == .ok) std.fmt.bufPrint(&vb, "{d} sockets", .{snapshot.connections.len}) catch "" else snapshot.group(.connections).reason },
                .power => .{ .text = if (snapshot.cpu_package_temp.get()) |t| std.fmt.bufPrint(&vb, "CPU {d:.0} °C", .{t}) catch "" else snapshot.cpu_package_temp.reason, .ring = &H.package_temp, .max = 100 },
                .system => .{ .text = self.osText(snapshot.os) },
                .users => .{ .text = if (snapshot.group(.users).status == .ok) std.fmt.bufPrint(&vb, "{d} sessions", .{snapshot.users.len}) catch "" else snapshot.group(.users).reason },
                .services => .{ .text = if (snapshot.services.len > 0) std.fmt.bufPrint(&vb, "{d} services", .{snapshot.services.len}) catch "" else snapshot.group(.services).reason },
                .apps => .{ .text = if (snapshot.apps_count.get()) |n| std.fmt.bufPrint(&vb, "{d} packages", .{n}) catch "" else snapshot.apps_count.reason },
                .files => .{ .text = if (self.files.snapshot) |fds| std.fmt.bufPrint(&vb, "{d} descriptors", .{fds.fd_count}) catch "" else "sampled when shown" },
                .treemap => .{ .text = if (self.treemap.tree) |tree| std.fmt.bufPrint(&vb, "{d} handles", .{tree.fd_count}) catch "" else "sampled when shown" },
                .inheritance => .{ .text = if (self.graph.inheritance) |rows| std.fmt.bufPrint(&vb, "{d} sampled matches", .{rows.matched}) catch "" else "sampled when shown" },
                .graph, .galaxy => .{ .text = if (self.graph.graph) |g| std.fmt.bufPrint(&vb, "{d} processes · {d} fds", .{ g.processes, g.member_count }) catch "" else "sampled when shown" },
                .memory_map => .{ .text = if (self.memmap.map()) |mm| switch (memmap.md.coverage(mm)) {
                    .value => |cov| std.fmt.bufPrint(&vb, "{d:.0}% {s}", .{ cov.fraction * 100, if (mm.process == null) "free contiguous" else "THP" }) catch "",
                    .none => "nothing eligible",
                    .unknown => "coverage unknown",
                } else "THP map when shown" },
            } else .{ .text = "" };
            const spark_w: f32 = if (detail.ring != null) 64 else 0;
            // Per-panel groups are sampled only while their panel is open.
            if (std.mem.eql(u8, detail.text, "not collected")) detail.text = "sampled when shown";
            try ctx.textFit(row.x + 36, ty + 21, row.w - 44 - spark_w, detail.text, p.dim);
            if (detail.ring) |ring| try spark(ctx, .{ .x = row.x + row.w - spark_w - 6, .y = ty + 20, .w = spark_w, .h = 20 }, ring, detail.max, p.accent, 30, 1);
        }
    }

    fn footer(self: *View, ctx: Ctx, rect: Rect, now: u64) !void {
        const p = ctx.p;
        try ctx.r.rect(rect, p.panel);
        try ctx.r.rect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 }, p.border);
        // The overhead indicator: always visible, bottom-right.
        var buf: [160]u8 = undefined;
        const s = self.snap();
        _ = s;
        // Both shares are thread CPU time measured here over the last second:
        // drawing, and sampling plus conversion (the collector's own `self`
        // report is on System Info).
        const live = std.mem.eql(u8, self.source_label, "live");
        // Total is the whole process's CPU time (all threads, driver included).
        const overhead = if (self.view_pct) |v| std.fmt.bufPrint(&buf, "overhead (4 s)  draw {d:.1}%  {s} {d:.1}%  total {d:.1}% of a core", .{ v, if (live) "collector" else "replay", self.collector_pct orelse 0, self.total_pct orelse v + (self.collector_pct orelse 0) }) catch "" else "overhead  measuring (first second)";
        const ow = ctx.measure(overhead) + 20;
        const orect = Rect{ .x = rect.w - ow - 8, .y = rect.y + 3, .w = ow, .h = rect.h - 6 };
        if (p.win95) try ctx.bevel(orect, true) else try ctx.r.shape(orect, fade(p.accent, 0.10), .{ .radii = @splat(5) });
        try ctx.text(orect.x + 10, rect.y + 4, overhead, p.dim);
        self.hover(orect, "Overhead over the last second, % of one core: drawing, sampling, and total for the whole process (all threads)", .{});
        // Left: hover reason, status, or key hints.
        const left_w = orect.x - 16;
        if (self.files.exact_active) {
            try ctx.textFit(12, rect.y + 4, left_w, "EXACT ACTIVE · all syscalls ~10% slower · E stops", p.warn);
        } else if (self.hover_len > 0) {
            try ctx.textFit(12, rect.y + 4, left_w, self.hover_text[0..self.hover_len], p.text);
        } else if (self.status_len > 0 and now -| self.status_time < 6_000_000_000) {
            try ctx.textFit(12, rect.y + 4, left_w, self.status[0..self.status_len], p.accent);
        } else {
            const hints = if (self.panel == .memory_map and self.memmap.look == .deep) "t look  wheel/+/- zoom  drag/arrows pan  0 fit  [ ] VMA  click select  o process  g legend  d details  p pause" else if (self.panel == .memory_map) "t look  [ ] process  o select  arrows cell  +/- zoom  g legend  d details  Esc stop  p pause  m from Processes" else if (self.panel == .files) "↑↓ select  Enter process files  [ ] view  / search  s sort  h holders  e events  a attach  Esc all  p pause" else if (self.panel == .processes) "↑↓ select  ←→ fold  Enter open in debugger  / search  s sort  r reverse  v tree  t theme  p pause  q quit" else "1-9 0 Tab panels  ↑↓ scroll  L files  / search processes  t theme  p pause  x redact  q quit";
            try ctx.textFit(12, rect.y + 4, left_w, hints, p.dim);
        }
    }

    fn tooltip(self: *View, ctx: Ctx) !void {
        if (self.hover_len == 0) return;
        const p = ctx.p;
        const text = self.hover_text[0..self.hover_len];
        const w = @min(ctx.measure(text) + 20, self.width * 0.5);
        var x = self.pointer[0] + 14;
        var y = self.pointer[1] + 18;
        if (x + w > self.width - 8) x = self.width - 8 - w;
        if (y + 28 > self.height - 30) y = self.pointer[1] - 34;
        const rect = Rect{ .x = x, .y = y, .w = w, .h = 26 };
        switch (self.tooltip_style) {
            .overview => {},
            .win9x => {
                // Yellow 9x tooltip with a hard black frame.
                try ctx.r.rect(rect, draw.Color{ 1, 1, 0.882, 1 });
                try ctx.r.shape(rect, draw.Color{ 0, 0, 0, 1 }, .{ .border = 1 });
                try ctx.textFit(x + 8, y + 3, w - 16, text, draw.Color{ 0, 0, 0, 1 });
                return;
            },
            .dos => {
                try ctx.r.rect(rect, draw.Color{ 0, 0, 0, 1 });
                try ctx.r.rect(draw.inset(rect, 2), draw.Color{ 0, 0.667, 0.667, 1 });
                try ctx.textFit(x + 8, y + 3, w - 16, text, draw.Color{ 0, 0, 0, 1 });
                return;
            },
        }
        try ctx.r.shape(.{ .x = rect.x - 4, .y = rect.y - 2, .w = rect.w + 12, .h = rect.h + 10 }, fade(.{ 0, 0, 0, 1 }, 0.35), .{ .radii = @splat(8), .softness = 4 });
        try ctx.r.shape(rect, p.raised, .{ .radii = @splat(5) });
        try ctx.r.shape(rect, p.border, .{ .radii = @splat(5), .border = 1 });
        try ctx.textFit(x + 10, y + 3, w - 18, text, p.text);
    }

    /// CRT treatment for phosphor themes: scanlines and vignette over everything.
    fn actionDialog(self: *View, ctx: Ctx) !void {
        const request = self.pending_action orelse return;
        self.hit_count = 0;
        self.hover_len = 0;
        const p = ctx.p;
        try ctx.r.rect(.{ .x = 0, .y = 0, .w = self.width, .h = self.height }, .{ 0, 0, 0, 0.7 });
        const w = @min(900, self.width - 60);
        const box = Rect{ .x = (self.width - w) / 2, .y = (self.height - 280) / 2, .w = w, .h = 280 };
        if (p.win95) {
            try ctx.bevel(box, false);
            try win95.title(ctx, .{ .x = box.x + 4, .y = box.y + 4, .w = box.w - 8, .h = 28 }, "Confirm action");
        } else try ctx.r.shape(box, p.panel, .{ .radii = @splat(10) });
        var buf: [128]u8 = undefined;
        if (p.win95) {
            const ix = box.x + 22;
            const iy = box.y + 41;
            try ctx.r.rect(.{ .x = ix, .y = iy, .w = 16, .h = 16 }, p.accent);
            try ctx.text(ix + 4, iy - 1, "!", .{ 1, 1, 1, 1 });
        }
        try ctx.textFit(box.x + (if (p.win95) @as(f32, 46) else 20), box.y + (if (p.win95) @as(f32, 34) else 16), w - 40, std.fmt.bufPrint(&buf, "Open {s}: pid {d}, start {d}", .{ @tagName(request.kind), request.id.pid, request.id.start }) catch "", p.text);
        const lines: [4][]const u8 = switch (request.kind) {
            .files => .{ "Read-only descriptors in this window's Files & IO pane.", "Cost: shared scan once per second, 10 ms soft budget; no target pause.", "Access: your account's /proc permissions; denied fields stay unavailable.", "The view pins the sampled process identity. No privilege escalation." },
            .profile => .{ "Attach, start a 99 Hz CPU capture for 10 seconds, then resume.", "Cost: briefly stops all threads; perf buffers up to 64 MiB, plus symbols.", "Access: ptrace and perf_event permissions; denial is reported.", "The target is checked before and after attach. No privilege escalation." },
            .attach => .{ "Open this process in a separate debugger window.", "Cost: attaches and stops all threads until you continue or detach.", "Access: ptrace permission (same user or CAP_SYS_PTRACE).", "The target is checked before and after attach. No privilege escalation." },
            .events => .{ "exact mode slows all syscalls on this machine by roughly 10 % while active", "Syscall-heavy targets can slow much more; up to 64 perf fds and 2 MiB rings.", "Access: native x86-64 tracepoints and perf permission; no ptrace stop.", "E stops. Pausing or leaving this pane stops capture. FD numbers span reuse." },
        };
        for (lines, 0..) |line, i| try ctx.textFit(box.x + 20, box.y + 58 + @as(f32, @floatFromInt(i)) * 30, w - 40, line, p.dim);
        const cancel = Rect{ .x = box.x + 20, .y = box.y + 222, .w = 190, .h = 36 };
        const confirm = Rect{ .x = box.x + w - 240, .y = box.y + 222, .w = 220, .h = 36 };
        if (p.win95) {
            try ctx.bevel(cancel, false);
            try ctx.bevel(confirm, false);
        } else {
            try ctx.r.shape(cancel, fade(p.accent, 0.15), .{ .radii = @splat(6) });
            try ctx.r.shape(confirm, fade(p.accent, 0.3), .{ .radii = @splat(6) });
        }
        try ctx.text(cancel.x + 12, cancel.y + 8, "Cancel  Esc", p.text);
        try ctx.text(confirm.x + 12, confirm.y + 8, if (p.win95) "OK  Enter again" else "Confirm  Enter again", p.text);
        self.hit(cancel, .cancel);
        self.hit(confirm, .confirm);
    }

    fn overlay(self: *View, ctx: Ctx) !void {
        const p = ctx.p;
        if (p.scanlines > 0) {
            var y: f32 = 0;
            while (y < self.height) : (y += 3) try ctx.r.rect(.{ .x = 0, .y = y, .w = self.width, .h = 1 }, .{ 0, 0, 0, p.scanlines });
        }
        if (p.vignette > 0) {
            const dark = Color{ 0, 0, 0, p.vignette * 0.6 };
            const clear = Color{ 0, 0, 0, 0 };
            const band = @min(self.width, self.height) * 0.12;
            try ctx.r.shape(.{ .x = 0, .y = 0, .w = self.width, .h = band }, dark, .{ .colors = .{ dark, dark, clear, clear } });
            try ctx.r.shape(.{ .x = 0, .y = self.height - band, .w = self.width, .h = band }, dark, .{ .colors = .{ clear, clear, dark, dark } });
            try ctx.r.shape(.{ .x = 0, .y = 0, .w = band, .h = self.height }, dark, .{ .colors = .{ dark, clear, dark, clear } });
            try ctx.r.shape(.{ .x = self.width - band, .y = 0, .w = band, .h = self.height }, dark, .{ .colors = .{ clear, dark, clear, dark } });
        }
    }
};

/// The host of "a.b.c.d:port", "[v6]:port", "a.b.c.d/len" or "v6/len".
pub fn hostPart(s: []const u8) []const u8 {
    if (s.len > 0 and s[0] == '[') return if (std.mem.indexOfScalar(u8, s, ']')) |e| s[1..e] else s[1..];
    const no_len = if (std.mem.indexOfScalar(u8, s, '/')) |e| s[0..e] else s;
    if (std.mem.count(u8, no_len, ":") == 1) return no_len[0..std.mem.indexOfScalar(u8, no_len, ':').?];
    return no_len;
}
/// Exact loopback and wildcard hosts only.
pub fn publicHost(host: []const u8) bool {
    const exact = [_][]const u8{ "::1", "::", "0.0.0.0", "*", "localhost", "0:0:0:0:0:0:0:1", "::ffff:127.0.0.1" };
    for (exact) |e| if (std.ascii.eqlIgnoreCase(host, e)) return true;
    if (std.mem.startsWith(u8, host, "127.") or std.mem.startsWith(u8, host, "::ffff:127.")) {
        for (host) |ch| if (!(std.ascii.isDigit(ch) or ch == '.' or ch == ':' or ch == 'f')) return false;
        return true;
    }
    return false;
}

/// Display name of a process. With --redact, processes not owned by root
/// (and not kernel threads) get a stable alias derived from pid + start, so
/// a video shows structure without names.
pub fn processName(view: *const View, p: *const m.Process, buf: *[24]u8) []const u8 {
    if (!view.redact or p.kernel or (p.uid.get() orelse 1) == 0) return p.name;
    return alias(buf, p.pid, p.start);
}
pub fn alias(buf: *[24]u8, pid: i32, start: u64) []const u8 {
    var key: [12]u8 = undefined;
    std.mem.writeInt(i32, key[0..4], pid, .little);
    std.mem.writeInt(u64, key[4..12], start, .little);
    const hv: u32 = @truncate(std.hash.Wyhash.hash(0x0a26, &key));
    return std.fmt.bufPrint(buf, "proc-{x:0>5}", .{hv & 0xfffff}) catch "proc";
}
/// Owner of a socket by pid, aliased like its process under --redact.
pub fn ownerName(view: *const View, pid: i32, comm: []const u8, buf: *[24]u8) []const u8 {
    if (!view.redact) return comm;
    if (view.snap()) |s| for (s.processes) |*p| if (p.pid == pid) return processName(view, p, buf);
    return alias(buf, pid, 0);
}

/// Live stat chips in the header: as many as fit beside the host line.
fn headerChips(width: f32) usize {
    return @intFromFloat(std.math.clamp((width * 0.6 - 120) / 178, 0, 4));
}

fn mixText(p: *const themes.Palette, t: f32) Color {
    return draw.mix(p.dim, p.text, t);
}
fn fullest(buf: []u8, s: *const m.Snapshot) []const u8 {
    var best: ?f64 = null;
    for (s.mounts) |mount| if (mount.used_pct.get()) |v| {
        best = @max(best orelse 0, v);
    };
    return if (best) |v| std.fmt.bufPrint(buf, "fullest {d:.0}%", .{v}) catch "" else s.group(.filesystems).reason;
}
pub fn pct(part: ?u64, total: ?u64) ?f64 {
    const t = total orelse return null;
    const v = part orelse return null;
    if (t == 0) return null;
    return @as(f64, @floatFromInt(v)) * 100 / @as(f64, @floatFromInt(t));
}
fn mean(ring: *const h.Ring, n: usize) ?f64 {
    var sum: f64 = 0;
    var k: usize = 0;
    for (0..n) |i| if (ring.back(i)) |x| {
        sum += x;
        k += 1;
    };
    return if (k == 0) null else sum / @as(f64, @floatFromInt(k));
}
pub fn processNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.PROCESS_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
pub fn threadNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.THREAD_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub const Kind = enum { percent, rate, bytes, celsius, watts, mhz, count, rpm, volts, amps, plain };
pub fn format(buf: []u8, kind: Kind, value: ?f32) []const u8 {
    const v: f64 = value orelse return "—";
    return switch (kind) {
        .percent => std.fmt.bufPrint(buf, "{d:.1}%", .{v}),
        .rate => return m.rate(buf, v),
        .bytes => return m.bytes(buf, v),
        .celsius => std.fmt.bufPrint(buf, "{d:.1} °C", .{v}),
        .watts => std.fmt.bufPrint(buf, "{d:.1} W", .{v}),
        .mhz => std.fmt.bufPrint(buf, "{d:.0} MHz", .{v}),
        .count => std.fmt.bufPrint(buf, "{d:.0}", .{v}),
        .rpm => std.fmt.bufPrint(buf, "{d:.0} RPM", .{v}),
        .volts => std.fmt.bufPrint(buf, "{d:.3} V", .{v}),
        .amps => std.fmt.bufPrint(buf, "{d:.2} A", .{v}),
        .plain => std.fmt.bufPrint(buf, "{d:.2}", .{v}),
    } catch "?";
}

/// Small area sparkline of the newest `count` samples; gaps stay gaps.
pub fn spark(ctx: Ctx, rect: Rect, ring: *const h.Ring, max: f32, color: Color, count: usize, t: f32) !void {
    var pts: [h.capacity + 2]?[2]f32 = undefined;
    const n = @min(count, h.capacity);
    const dx = rect.w / @as(f32, @floatFromInt(n - 1));
    const shift = (1 - t) * dx;
    var used: usize = 0;
    for (0..n + 1) |i| {
        const v = ring.back(i);
        pts[n - i] = if (v) |value| .{ rect.x + rect.w - @as(f32, @floatFromInt(i)) * dx + shift, rect.y + rect.h - std.math.clamp(value / @max(max, 0.0001), 0, 1) * rect.h } else null;
        used += 1;
    }
    const saved = ctx.r.clip;
    ctx.r.clip = draw.intersect(saved, rect);
    defer ctx.r.clip = saved;
    try ctx.area(pts[0 .. n + 1], rect.y + rect.h, rect.y, color, 0.35);
    for (1..n + 1) |i| if (pts[i - 1] != null and pts[i] != null) try ctx.line(pts[i - 1].?, pts[i].?, 1.5, color);
}

test "panel groups always include the sidebar's whole-system groups" {
    var v = try View.init(std.testing.allocator);
    defer v.deinit();
    const base = v.groups(true);
    try std.testing.expect(v.groups(false) & (1 << @intFromEnum(m.Group.processes)) == 0);
    try std.testing.expect(base & (1 << @intFromEnum(m.Group.cpu)) != 0);
    try std.testing.expect(base & (1 << @intFromEnum(m.Group.connections)) == 0); // costly owner scan only when shown
    v.show(.memory);
    try std.testing.expect(v.groups(true) & (1 << @intFromEnum(m.Group.processes)) == 0);
    v.show(.processes);
    try std.testing.expect(v.groups(true) & (1 << @intFromEnum(m.Group.processes)) != 0);
}

test "redaction hides private text even when the source did not" {
    var v = try View.init(std.testing.allocator);
    defer v.deinit();
    try std.testing.expect(v.private(m.Text.of("demo-host")).ok());
    v.redact = true;
    try std.testing.expectEqualStrings("redacted", v.private(m.Text.of("demo-host")).why);
    try std.testing.expect(v.mountPath(m.Text.of("/")).ok());
    try std.testing.expect(!v.mountPath(m.Text.of("/home/demo/media")).ok());
    try std.testing.expect(v.address(m.Text.of("127.0.0.1:631")).ok());
    try std.testing.expect(!v.address(m.Text.of("192.0.2.7:443")).ok());
    try std.testing.expect(!v.address(m.Text.of("::1234/64")).ok());
    try std.testing.expect(!v.address(m.Text.of("[::1234]:22")).ok());
    try std.testing.expect(v.address(m.Text.of("[::1]:631")).ok());
    try std.testing.expect(v.address(m.Text.of("::1/128")).ok());
    try std.testing.expect(v.address(m.Text.of("0.0.0.0:22")).ok());
    try std.testing.expect(!v.address(m.Text.of("127.0.0.1.example:1")).ok());
    try std.testing.expect(!v.address(m.Text.of("/home/private-user/SECRET.sock")).ok());
    try std.testing.expect(!v.address(m.Text.of("/run/user/1000/bus")).ok());
    try std.testing.expect(v.address(m.Text.of("/run/dbus/system_bus_socket")).ok());
    var b: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    const user_proc = m.Process{ .pid = 42, .start = 7, .name = "secret-tool", .uid = m.U.of(1000) };
    const root_proc = m.Process{ .pid = 1, .start = 1, .name = "init", .uid = m.U.of(0) };
    try std.testing.expect(std.mem.startsWith(u8, processName(&v, &user_proc, &b), "proc-"));
    try std.testing.expectEqualStrings(processName(&v, &user_proc, &b), alias(&b2, 42, 7));
    try std.testing.expectEqualStrings("init", processName(&v, &root_proc, &b));
}

test "process rows sort, nest, search and keep selection identity" {
    var v = try View.init(std.testing.allocator);
    defer v.deinit();
    const o = try m.Owned.create(std.testing.allocator);
    const procs = try o.arena.allocator().dupe(m.Process, &.{
        .{ .pid = 1, .start = 10, .ppid = 0, .name = "init", .cpu = m.F.of(0.5) },
        .{ .pid = 20, .start = 11, .ppid = 1, .name = "shell", .cpu = m.F.of(1) },
        .{ .pid = 30, .start = 12, .ppid = 20, .name = "burner", .cpu = m.F.of(99) },
        .{ .pid = 40, .start = 13, .ppid = 1, .name = "idle", .cpu = m.F.missing("first sample") },
    });
    o.snap.processes = procs;
    v.accept(o, 1);
    try v.buildRows();
    try std.testing.expectEqual(@as(usize, 4), v.rows.items.len);
    try std.testing.expectEqual(@as(u16, 2), v.rows.items[2].depth); // init > shell > burner
    try std.testing.expectEqual(@as(u32, 3), v.rows.items[3].index); // unmeasured sorts last
    v.tree = false;
    v.rows_dirty = true;
    try v.buildRows();
    try std.testing.expectEqual(@as(u32, 2), v.rows.items[0].index);
    v.selectRow(0);
    v.sort = .pid;
    v.descending = false;
    v.rows_dirty = true;
    try v.buildRows();
    try std.testing.expectEqual(@as(usize, 2), v.selected_row);
    v.tree = true;
    @memcpy(v.search[0..4], "burn");
    v.search_len = 4;
    v.rows_dirty = true;
    try v.buildRows();
    try std.testing.expectEqual(@as(usize, 3), v.rows.items.len); // match plus ancestors
}

test "action confirmation requires release, arm delay and a fresh press" {
    var v = try View.init(std.testing.allocator);
    defer v.deinit();
    var calls: usize = 0;
    const Hook = struct {
        fn launch(context: ?*anyopaque, _: actions.Request) !void {
            const n: *usize = @ptrCast(@alignCast(context.?));
            n.* += 1;
        }
    };
    v.action_hook = Hook.launch;
    v.action_context = &calls;
    v.pending_action = .{ .kind = .attach, .id = .{ .pid = 123, .start = 456 } };
    v.confirm_key = 28;
    v.confirm_after = 250_000_000;
    v.key(.{ .kind = .repeat, .code = 28, .sym = 0xff0d }, 1_000_000_000);
    v.key(.{ .kind = .press, .code = 28, .sym = 0xff0d }, 1_000_000_000);
    try std.testing.expectEqual(0, calls);
    v.confirm_key = null;
    v.key(.{ .kind = .press, .code = 28, .sym = 0xff0d }, 100_000_000);
    v.key(.{ .kind = .repeat, .code = 28, .sym = 0xff0d }, 1_000_000_000);
    try std.testing.expectEqual(0, calls);
    v.key(.{ .kind = .press, .code = 28, .sym = 0xff0d }, 1_000_000_000);
    try std.testing.expectEqual(1, calls);
    try std.testing.expect(v.pending_action == null);
}

test "queued search and actions cannot use a filtered-out process identity" {
    var v = try View.init(std.testing.allocator);
    defer v.deinit();
    const o = try m.Owned.create(std.testing.allocator);
    o.snap.processes = try o.arena.allocator().dupe(m.Process, &.{
        .{ .pid = 123, .start = 10, .name = "old", .cpu = m.F.of(90) },
        .{ .pid = 456, .start = 20, .name = "wanted", .cpu = m.F.of(1) },
    });
    v.accept(o, 1);
    v.show(.processes);
    v.tree = false;
    try v.buildRows();
    try std.testing.expectEqual(123, v.selected.?.pid);
    const Hook = struct {
        fn launch(_: ?*anyopaque, _: actions.Request) !void {}
    };
    v.action_hook = Hook.launch;
    // No intervening draw: the next arrow and L must use the new filter.
    @memcpy(v.search[0..3], "456");
    v.search_len = 3;
    v.rows_dirty = true;
    v.key(.{ .kind = .press, .code = 108, .sym = 0xff54 }, 2);
    try std.testing.expectEqual(456, v.selected.?.pid);
    v.requestAction(.files, 3);
    try std.testing.expectEqual(456, v.pending_action.?.id.pid);
    v.pending_action = null;
    @memcpy(v.search[0..3], "999");
    v.rows_dirty = true;
    v.requestAction(.files, 4);
    try std.testing.expect(v.pending_action == null and v.selected == null);
    try std.testing.expectEqual(0, v.rows.items.len);
    // A subsequent publication can introduce the searched-for identity.
    const n = try m.Owned.create(std.testing.allocator);
    n.snap.processes = try n.arena.allocator().dupe(m.Process, &.{.{ .pid = 999, .start = 30, .name = "new" }});
    n.snap.fresh[@intFromEnum(m.Group.processes)] = true;
    v.accept(n, 5);
    v.requestAction(.files, 6);
    try std.testing.expectEqual(999, v.pending_action.?.id.pid);
}

test "every panel draws through a resize from 0x0 to half screen with the pointer anywhere" {
    const a = std.testing.allocator;
    const font = try a.create(Font);
    defer a.destroy(font);
    font.* = .{};
    try font.init("/usr/share/fonts/TTF/DejaVuSansMono.ttf");
    defer font.deinit();
    const buffer = try a.alignedAlloc(u8, .@"16", 8 * 1024 * 1024);
    defer a.free(buffer);
    var r = gpu.Renderer{};
    r.mapped = buffer.ptr;
    var v = try View.init(a);
    defer v.deinit();
    v.accept(try m.Owned.create(a), 1);
    // A process map with cells, VMAs and a coverage value reaches every grid and bar.
    const B: u64 = 2 << 20;
    var cells: [300]memmap.md.Cell = undefined;
    for (&cells, 0..) |*cell, i| cell.* = .{ .start = i * B, .end = (i + 1) * B, .vma = @intCast(i % 2), .mapped = B, .observed = B, .present = B, .huge = if (i % 3 == 0) B else 0 };
    const vmas = [_]memmap.md.Vma{ .{ .start = 0, .end = 150 * B }, .{ .start = 150 * B, .end = 300 * B } };
    const map = memmap.md.Map{ .process = .{ .pid = 7, .start_ticks = 1, .coverage_numerator = 1, .coverage_denominator = 3 }, .vmas = &vmas, .cells = &cells };
    v.memmap.replay_current = &map;
    var w = Window{};
    const sizes = [_][2]u32{ .{ 0, 0 }, .{ 1, 1 }, .{ 40, 20 }, .{ 120, 60 }, .{ 300, 200 }, .{ 480, 540 }, .{ 700, 300 }, .{ 960, 1080 }, .{ 3000, 30 }, .{ 30, 2000 }, .{ 1, 1 } };
    const pointers = [_][2]f32{ .{ -1, -1 }, .{ 0, 0 }, .{ 5, 5 }, .{ 300, 200 }, .{ 1e6, 1e6 }, .{ -1e6, 5 } };
    // Fast component lane: both chrome paths share the original resize oracle.
    for ([_]usize{ 0, themes.find("win95").? }) |palette| {
        v.palette = palette;
        for (std.enums.values(Panel)) |panel| {
            v.panel = panel;
            for (std.enums.values(memmap.Look)) |look| for ([_]bool{ false, true }) |compact| {
                if (panel != .memory_map and (look != .win9x or compact)) continue;
                v.memmap.look = look;
                v.memmap.compact = compact;
                for (sizes) |size| for (pointers) |pointer| {
                    w.width = size[0];
                    w.height = size[1];
                    v.pointer = pointer;
                    r.vertices = 0;
                    r.clip = .{ .x = 0, .y = 0, .w = @floatFromInt(size[0]), .h = @floatFromInt(size[1]) };
                    v.frame(&r, font, &w, 2_000_000_000) catch |err| if (err != error.VertexBufferFull) return err;
                    if (palette == themes.find("win95").? and panel == .summary) {
                        const menus = comptime std.enums.values(win95.Menu);
                        for (0..menus.len + 2) |overlay| {
                            v.classic_menu = if (overlay < menus.len) menus[overlay] else null;
                            v.classic_about = overlay == menus.len;
                            v.pending_action = if (overlay == menus.len + 1) .{ .kind = .files, .id = .{ .pid = 7, .start = 1 } } else null;
                            r.vertices = 0;
                            v.frame(&r, font, &w, 2_000_000_000) catch |err| if (err != error.VertexBufferFull) return err;
                        }
                        v.classic_menu = null;
                        v.classic_about = false;
                        v.pending_action = null;
                    }
                };
            };
        }
    }
}

// Fast component lane: keyboard capture and modal ordering are state properties.
test "classic menus consume shortcuts and preserve text-entry and confirmations" {
    var v = try View.init(std.testing.allocator);
    defer v.deinit();
    v.palette = themes.find("win95").?;
    const f10 = @import("../../platform/input.zig").Event{ .kind = .press, .sym = 0xffc7 };
    v.key(f10, 1);
    try std.testing.expectEqual(win95.Menu.file, v.classic_menu.?);
    v.key(.{ .kind = .press, .sym = 'q', .shortcut = 'q' }, 2);
    try std.testing.expect(!v.quit);
    v.key(.{ .kind = .press, .sym = 0xff54 }, 3);
    v.key(.{ .kind = .press, .sym = 0xff0d }, 4);
    try std.testing.expectEqual(Panel.processes, v.panel);
    try std.testing.expect(v.classic_menu == null);
    v.searching = true;
    v.key(f10, 5);
    try std.testing.expect(v.classic_menu == null);
    v.searching = false;
    v.pending_action = .{ .kind = .attach, .id = .{ .pid = 123, .start = 456 } };
    v.key(f10, 6);
    try std.testing.expect(v.classic_menu == null);
    v.key(.{ .kind = .press, .sym = 0xff1b }, 7);
    try std.testing.expect(v.pending_action == null);
    v.activate(.{ .classic = .redact }, 8);
    v.activate(.{ .classic = .redact }, 9);
    try std.testing.expect(v.redact);
}

// Fast component lane: dragging reaches both ends and remains bounded.
test "classic scrollbar clamps dragging and routes files separately" {
    var v = try View.init(std.testing.allocator);
    defer v.deinit();
    v.panel = .processes;
    v.classic_scroll = .{ .track = .{ .x = 10, .y = 100, .w = 16, .h = 200 }, .thumb_h = 20, .thumb_y = 100, .grab = 5, .max = 90 };
    v.pointer = .{ 10, 195 };
    win95.drag(&v);
    try std.testing.expectEqual(@as(usize, 45), v.scroll[@intFromEnum(Panel.processes)]);
    v.pointer[1] = -1e6;
    win95.drag(&v);
    try std.testing.expectEqual(@as(usize, 0), v.scroll[@intFromEnum(Panel.processes)]);
    v.pointer[1] = 1e6;
    win95.drag(&v);
    try std.testing.expectEqual(@as(usize, 90), v.scroll[@intFromEnum(Panel.processes)]);
    v.panel = .files;
    win95.drag(&v);
    try std.testing.expectEqual(@as(usize, 90), v.files.top);
}

// Fast component lane: geometry properties, no renderer.
test "classic pull-downs stay inside the window at every size" {
    for (std.enums.values(win95.Menu)) |menu| {
        var width: f32 = 80;
        while (width <= 4000) : (width += if (width < 400) 1 else 37) {
            for ([_]f32{ 100, 101, 180, 274, 300, 480, 720, 1080, 2160 }) |height| {
                const place = win95.popupRect(menu, width, height);
                const q = place.rect;
                try std.testing.expect(q.x >= 0 and q.y >= 0);
                try std.testing.expect(q.x + q.w <= width and q.y + q.h <= height + 0.01);
                try std.testing.expect(q.w == @min(258, width) and place.row > 0);
                // Roomy windows keep the period position under the menu title.
                if (width >= 600 and height >= 720 and menu != .start) try std.testing.expectEqual(@as(f32, 12 + @as(f32, @floatFromInt(@intFromEnum(menu))) * 72), q.x);
            }
        }
    }
}

test "classic scrollbar geometry does not grow with the trough height" {
    const a = std.testing.allocator;
    const font = try a.create(Font);
    defer a.destroy(font);
    font.* = .{};
    try font.initRetro();
    defer font.deinit();
    const buffer = try a.alignedAlloc(u8, .@"16", 1024 * 1024);
    defer a.free(buffer);
    var r = gpu.Renderer{};
    r.mapped = buffer.ptr;
    var v = try View.init(a);
    defer v.deinit();
    v.palette = themes.find("win95").?;
    var used: [2]usize = undefined;
    for ([_]f32{ 200, 4000 }, &used) |height, *n| {
        r.vertices = 0;
        r.clip = .{ .x = 0, .y = 0, .w = 100, .h = height };
        v.hit_count = 0;
        try win95.scrollbar(&v, .{ .r = &r, .font = font, .p = v.pal() }, .{ .x = 10, .y = 0, .w = 16, .h = height }, 5, 1000, 20);
        n.* = r.vertices;
    }
    try std.testing.expect(used[0] > 0);
    try std.testing.expectEqual(used[0], used[1]);
}

test "maximize state follows the compositor's configure states" {
    const state = @import("../../platform/wayland.zig").hasState;
    const none = [_]u32{};
    try std.testing.expect(!state(&none, 1));
    try std.testing.expect(!state(&[_]u32{ 4, 5, 6 }, 1)); // activated and tiled edges only
    try std.testing.expect(state(&[_]u32{ 4, 1 }, 1));
}
