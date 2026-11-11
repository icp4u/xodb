//! Read-only breakout work-log window; no debugger session or target.
const std = @import("std");
const model = @import("../profile/agent_time.zig");
const tree = @import("../profile/flame.zig");
const gpu = @import("../render/vulkan.zig");
const Window = @import("../platform/window.zig").Window;
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const log = @import("../log.zig");
const redact = @import("../redact.zig");
const focus = @import("../profile/agent_time_focus.zig");
const theme = @import("style.zig").theme;
const a = std.heap.page_allocator;
const Browser = @import("agent_time_browser.zig").Browser;
const Chronological = @import("agent_time_chart.zig").View;
pub const takes = [_][]const u8{ "--agent-log", "--agent-kind", "--agent-time-out" };
const Hit = struct { rect: gpu.Rect, id: u32 };
const Mark = focus.Mark;

const View = struct {
    show_browser: bool = false,
    chronological: bool = false,
    chart: Chronological = .{},
    tokens: bool = false,
    tasks: bool = false,
    cache_overlay: bool = false,
    live: bool = false,
    live_status: []const u8 = "off",
    zoom: u32 = 0,
    selected: u32 = 0,
    scroll: f32 = 0,
    // Focus/selection carried across the first live snapshot.
    kept: ?[2]Mark = null,
    kept_chart: ?focus.ChartMark = null,
    searching: bool = false,
    query: [128]u8 = @splat(0),
    query_len: usize = 0,
    hits: [8192]Hit = undefined,
    hit_count: usize = 0,

    fn graph(self: *const View, p: *model.Profile) *tree.Graph {
        return if (self.tasks) (if (self.tokens) &p.task_tokens else &p.task_wall) else if (self.tokens) &p.tokens else &p.wall;
    }
    fn remember(self: *View, p: *model.Profile) void {
        const g = self.graph(p);
        self.kept = .{ Mark.of(g, self.zoom), Mark.of(g, self.selected) };
        self.kept_chart = focus.ChartMark.of(if (self.tokens) p.chart.tokens.items else p.chart.wall.items, self.chart.selected);
    }
    fn restore(self: *View, p: *model.Profile) void {
        const g = self.graph(p);
        if (self.kept) |kept| {
            self.zoom = kept[0].resolve(g);
            self.selected = kept[1].resolve(g);
        }
        if (self.kept_chart) |kept| self.chart.selected = kept.resolve(if (self.tokens) p.chart.tokens.items else p.chart.wall.items);
        self.kept = null;
        self.kept_chart = null;
        self.hit_count = 0;
        self.chart.hit_count = 0;
    }
    fn audit(self: *const View, p: *model.Profile, reason: []const u8) void {
        // Debug only: labels are turn titles (prompt text) and command summaries.
        if (!log.on(.profile, .debug)) return;
        const g = self.graph(p);
        const spans = if (self.tokens) p.chart.tokens.items else p.chart.wall.items;
        const selected = if (self.chronological) (if (self.chart.selected < spans.len) spans[self.chart.selected].label else "none") else g.nodes.items[self.selected].frame.name;
        const zoom = if (self.chronological) (if (self.chart.focus != null) "fixed interval" else "all") else g.nodes.items[self.zoom].frame.name;
        var selected_buffer: [256]u8 = undefined;
        var zoom_buffer: [256]u8 = undefined;
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        std.json.Stringify.value(.{
            .reason = reason,
            .layout = if (self.chronological) "chart" else "flame",
            .tokens = self.tokens,
            .selected = auditLabel(&selected_buffer, selected),
            .zoom = auditLabel(&zoom_buffer, zoom),
            .focused = if (self.chronological) self.chart.focus != null else self.zoom != 0,
            .start = if (self.chart.focus) |f| f.start else p.chart.start,
            .end = if (self.chart.focus) |f| f.end else p.chart.end,
        }, .{}, &writer) catch return;
        log.debug(.profile, "xodb: agent-time view {s}\n", .{writer.buffered()});
    }
    fn input(self: *View, window: *Window, p: ?*model.Profile) void {
        while (window.input.next()) |event| {
            defer if (p) |profile| {
                if (event.kind == .button_press or event.kind == .press or event.kind == .repeat) self.audit(profile, "input");
            };
            window.dirty = true;
            if (event.kind == .button_press and event.code == 0x110) {
                if (self.chronological) {
                    self.chart.select(event.x, event.y);
                    continue;
                }
                for (self.hits[0..self.hit_count]) |hit| if (event.x >= hit.rect.x and event.x < hit.rect.x + hit.rect.w and event.y >= hit.rect.y and event.y < hit.rect.y + hit.rect.h) {
                    self.selected = hit.id;
                    break;
                };
                continue;
            }
            if (event.kind != .press and event.kind != .repeat) continue;
            if (self.searching) {
                switch (event.sym) {
                    keys.sym.escape, 0xff0d => self.searching = false,
                    0xff08 => if (self.query_len > 0) {
                        self.query_len -= 1;
                        while (self.query_len > 0 and self.query[self.query_len] & 0xc0 == 0x80) self.query_len -= 1;
                    },
                    else => {
                        const text = event.text();
                        if (self.query_len + text.len <= self.query.len) {
                            @memcpy(self.query[self.query_len..][0..text.len], text);
                            self.query_len += text.len;
                        }
                    },
                }
                continue;
            }
            if (!event.plain()) continue;
            switch (event.shortcut) {
                'q' => {
                    window.closing = true;
                },
                'b' => self.show_browser = true,
                'l' => {
                    self.tasks = false;
                    self.zoom = 0;
                    self.selected = 0;
                    self.chronological = !self.chronological;
                    self.scroll = 0;
                    self.hit_count = 0;
                },
                'p' => {
                    self.tasks = !self.tasks;
                    self.chronological = false;
                    self.zoom = 0;
                    self.selected = 0;
                    self.scroll = 0;
                    self.hit_count = 0;
                },
                'c' => {
                    self.cache_overlay = !self.cache_overlay;
                    self.tokens = true;
                    self.zoom = 0;
                    self.selected = 0;
                    self.hit_count = 0;
                    self.chart.selected = 0;
                    self.kept_chart = null;
                },
                't' => {
                    self.live = !self.live;
                    self.live_status = if (self.live) "starting" else "off";
                },
                'w' => {
                    self.tokens = !self.tokens;
                    self.zoom = 0;
                    self.selected = 0;
                    self.hit_count = 0;
                    self.chart.selected = 0;
                    self.kept_chart = null;
                },
                'z', 0xff0d => {
                    if (self.chronological) {
                        if (p) |profile| self.chart.zoom(&profile.chart, self.tokens);
                        continue;
                    }
                    self.zoom = self.selected;
                    self.scroll = 0;
                },
                0xff08 => if (p) |profile| {
                    if (self.chronological) {
                        self.chart.focus = null;
                        continue;
                    }
                    self.zoom = self.graph(profile).nodes.items[self.zoom].parent orelse 0;
                },
                'x' => {
                    self.zoom = 0;
                    self.scroll = 0;
                    self.chart.focus = null;
                },
                '/' => {
                    self.searching = true;
                    self.query_len = 0;
                },
                keys.sym.up => self.scroll = @max(0, self.scroll - 24),
                keys.sym.down => self.scroll += 24,
                else => {},
            }
        }
        if (window.scroll != 0) {
            self.scroll = @max(0, self.scroll + @as(f32, @floatFromInt(window.scroll)) * 24);
            window.scroll = 0;
            window.dirty = true;
        }
    }
    fn draw(self: *View, r: *gpu.Renderer, font: *Font, window: *Window, job: *model.Job) !void {
        const width: f32 = @floatFromInt(window.width);
        const height: f32 = @floatFromInt(window.height);
        const all = gpu.Rect{ .x = 0, .y = 0, .w = width, .h = height };
        r.clip = all;
        try r.rect(all, theme.background);
        try label(r, font, 12, 10, width - 24, theme.good, "xodb / Agent time / {s} / {s} / live: {s}", .{ if (self.tokens) "TOKEN BURN" else "WALL / AGENT TIME", if (self.tasks) "TASK PACKETS (inferred)" else "sessions", self.live_status });
        try label(r, font, 12, height - 25, width - 24, theme.weak, "W weights   L layout   P tasks   C cache   T live   B browser   Z focus   Backspace out   / search   X reset   Q quit", .{});
        if (self.searching or self.query_len > 0) try label(r, font, 12, height - 49, width - 24, theme.good, "Search: {s}{s}", .{ self.query[0..self.query_len], if (self.searching) "_" else "" });
        if (!job.done.load(.acquire)) {
            try label(r, font, 12, 50, width - 24, theme.text, "Loading work log on worker…", .{});
            return;
        }
        if (job.failure) |err| {
            try label(r, font, 12, 50, width - 24, theme.warm, "Work log unavailable: {s}", .{@errorName(err)});
            // First-live failure has no previous view: say how to get one back.
            if (self.live and job.profile == null) try label(r, font, 12, 74, width - 24, theme.weak, "Live retries every 2 s / T stops live and reloads offline / B returns to sessions", .{});
            return;
        }
        const p = job.profile orelse {
            try label(r, font, 12, 50, width - 24, theme.text, "Starting live view… previous snapshot released", .{});
            try label(r, font, 12, 74, width - 24, theme.weak, "T cancels live startup and reloads the log offline", .{});
            return;
        };
        const doc = p.doc;
        try label(r, font, 12, 38, width - 24, theme.text, "{s} / {s}", .{ model.text(model.field(doc, "agent")), model.text(model.field(doc, "title")) });
        const turns = if (model.field(doc, "display_turn_count") != .null) @as(usize, @intFromFloat(model.number(model.field(doc, "display_turn_count")))) else model.array(model.field(doc, "turns")).len;
        try label(r, font, 12, 62, width - 24, theme.text, "Wall {d:.2}s / agent {d:.2}s / {d} turns / model gaps include overhead", .{ model.number(model.field(doc, "wall_seconds")), model.number(model.field(doc, "tree_agent_seconds")), turns });
        const counts = model.field(doc, "tree_counts");
        var omitted: f64 = 0;
        for ([_][]const u8{ "limited_spans", "oversize", "limited_tokens", "limited_turns", "limited_children", "limited_sessions", "failed_sessions" }) |key| omitted += model.number(model.field(counts, key));
        try label(r, font, 12, 86, width - 24, theme.weak, "Records {d:.0} / bad {d:.0} / unknown {d:.0} / unfinished {d:.0} / omitted {d:.0} / unlinked {d:.0}", .{ model.number(model.field(counts, "records")), model.number(model.field(counts, "malformed")) + model.number(model.field(counts, "missing_timestamps")), model.number(model.field(counts, "unknown")), model.number(model.field(counts, "unfinished_tools")), omitted, model.number(model.field(counts, "unlinked_subagents")) });
        const graph_ = self.graph(p);
        if (self.tokens and model.field(doc, "token_available") == .bool and !model.field(doc, "token_available").bool) {
            try label(r, font, 12, 116, width - 24, theme.warm, "Token usage unavailable in this log", .{});
            return;
        }
        if (self.chronological) {
            self.chart.cache_overlay = self.cache_overlay;
            try self.chart.draw(r, font, &p.chart, self.tokens, .{ .x = 12, .y = 142, .w = width - 24, .h = @max(0, height - 226) }, self.scroll, self.query[0..self.query_len]);
            return;
        }
        const root = graph_.nodes.items[self.zoom];
        const selected = graph_.nodes.items[self.selected];
        const shares = if (self.tasks) p.task_cache else p.cache;
        if (self.tokens and self.cache_overlay) {
            const share = shares[self.selected];
            try label(r, font, 12, 110, width - 24, theme.text, "Cache read {d}/{d} input ({d:.1}%) / {s}", .{ share.read, share.input, share.ratio() * 100, selected.frame.name });
        } else try label(r, font, 12, 110, width - 24, theme.text, "Selected: {s} / {d} {s} / excluded weight {d}", .{ if (selected.frame.mapping_note.len > 0) selected.frame.mapping_note else selected.frame.name, selected.inclusive, if (self.tokens) "tokens" else "us", graph_.rejected_weight });
        const bounds = gpu.Rect{ .x = 12, .y = 142, .w = width - 24, .h = @max(0, height - 198) };
        r.clip = bounds;
        self.hit_count = 0;
        if (root.inclusive == 0) return;
        for (graph_.nodes.items) |node| {
            if (node.depth < root.depth or node.x < root.x or node.x >= root.x + root.inclusive) continue;
            const x = bounds.x + bounds.w * @as(f32, @floatFromInt(node.x - root.x)) / @as(f32, @floatFromInt(root.inclusive));
            const w = bounds.w * @as(f32, @floatFromInt(node.inclusive)) / @as(f32, @floatFromInt(root.inclusive));
            const y = bounds.y + @as(f32, @floatFromInt(node.depth - root.depth)) * 27 - self.scroll;
            if (w < 1 or y < bounds.y or y + 25 > bounds.y + bounds.h) continue;
            const rect = gpu.Rect{ .x = x, .y = y, .w = @max(0, w - 1), .h = 25 };
            const match = self.query_len > 0 and std.ascii.indexOfIgnoreCase(node.frame.name, self.query[0..self.query_len]) != null;
            const hash = std.hash.Wyhash.hash(1, node.frame.name);
            const color: gpu.Color = if (match or node.id == self.selected) .{ 0.9, 0.65, 0.25, 1 } else .{ 0.08 + @as(f32, @floatFromInt(hash % 16)) / 100, 0.10 + @as(f32, @floatFromInt((hash >> 8) % 16)) / 100, 0.16, 1 };
            try r.rect(rect, color);
            if (self.tokens and self.cache_overlay) try r.rect(.{ .x = x, .y = y + 22, .w = rect.w * shares[node.id].ratio(), .h = 3 }, theme.good);
            try r.textFit(font, x + 4, y + 4, @max(0, w - 8), node.frame.name, if (match or node.id == self.selected) .{ 0.05, 0.05, 0.05, 1 } else theme.text);
            if (self.hit_count < self.hits.len) {
                self.hits[self.hit_count] = .{ .rect = rect, .id = node.id };
                self.hit_count += 1;
            }
        }
    }
};
fn auditLabel(buffer: []u8, name: []const u8) []const u8 {
    // --redact: a stable identity, never the text (titles are free prompt text).
    if (redact.active() != null) return std.fmt.bufPrint(buffer, "#{x:0>16}", .{std.hash.Wyhash.hash(0, name)}) catch "#";
    var value = name[0..@min(name.len, buffer.len)];
    while (value.len > 0 and !std.unicode.utf8ValidateSlice(value)) value = value[0 .. value.len - 1];
    return value;
}

fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [2048]u8 = undefined;
    const value = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    try r.textFit(font, x, y, @max(0, width), value, color);
}

pub fn main(args: []const [:0]const u8, io: std.Io) !void {
    var path: ?[]const u8 = null;
    var agent: []const u8 = "codex";
    var frames: u64 = 0;
    var output: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--agent-time")) continue;
        if (std.mem.eql(u8, arg, "--redact")) {
            @import("../redact.zig").enable();
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            log.required(.profile, "xodb --agent-time [--agent-kind codex|claude|grok|archive --agent-log FILE] [--redact] [--agent-time-out NEWFILE]\nNo file opens the session browser. W weights; L chronology; B browser; Z focus; / search. No target is attached.\n", .{});
            return;
        }
        if (i + 1 >= args.len) return error.MissingAgentTimeOptionValue;
        i += 1;
        if (std.mem.eql(u8, arg, "--agent-log")) path = args[i] else if (std.mem.eql(u8, arg, "--agent-kind")) agent = args[i] else if (std.mem.eql(u8, arg, "--agent-time-out")) output = args[i] else if (std.mem.eql(u8, arg, "--frames")) frames = try std.fmt.parseInt(u64, args[i], 10) else if (std.mem.eql(u8, arg, "--platform") or std.mem.eql(u8, arg, "--vk-device")) {} else return error.UnknownAgentTimeOption;
    }
    var job: ?*model.Job = if (path) |p| try model.Job.start(io, agent, p) else null;
    defer if (job) |j| j.deinit();
    var catalog_job: ?*model.Job = if (path == null) try model.Job.start(io, "catalog", "") else null;
    defer if (catalog_job) |j| j.deinit();
    var index_job: ?*model.Job = null;
    defer if (index_job) |j| j.deinit();
    var live_reader = model.LiveReader{};
    defer live_reader.stop(io);
    var refresh_job: ?*model.Job = null;
    defer if (refresh_job) |j| j.deinit();
    var next_refresh: i64 = 0;
    var live_started = false;
    var indexing: ?usize = null;
    var window = Window{};
    try window.init();
    defer window.deinit();
    window.setMinSize(640, 360);
    window.setTitle("xodb / Agent time");
    var renderer = gpu.Renderer{};
    try renderer.init(&window);
    defer renderer.deinit();
    const font = try a.create(Font);
    defer a.destroy(font);
    font.* = .{};
    try font.init(@import("build_options").font_path ++ "");
    defer font.deinit();
    var view = View{ .show_browser = path == null };
    var browser = Browser{};
    var count: u64 = 0;
    var completed = false;
    var catalog_completed = false;
    while (!window.closing and (frames == 0 or count < frames)) {
        try window.pump(50);
        const ready = if (job) |j| j.done.load(.acquire) else false;
        if (job) |j| if (ready != completed) {
            completed = ready;
            window.dirty = true;
            if (j.profile) |profile| if (output) |out| {
                try profile.save(io, out);
                log.info(.profile, "xodb: agent-time archive saved\n", .{});
                output = null;
            };
            if (j.profile) |profile| {
                view.restore(profile);
                view.audit(profile, "ready");
            }
            // Keep the completion marker last, after restoring/auditing view state.
            if (j.failure) |err| log.err(.profile, "xodb: agent-time failed: {s}\n", .{@errorName(err)}) else log.info(.profile, "xodb: agent-time ready turns={d} wall_nodes={d} token_nodes={d}\n", .{ model.array(model.field(j.profile.?.doc, "turns")).len, j.profile.?.wall.nodes.items.len, j.profile.?.tokens.nodes.items.len });
        };
        var catalog: ?*model.Catalog = null;
        var catalog_failure: ?anyerror = null;
        if (catalog_job) |j| if (j.done.load(.acquire)) {
            catalog = j.catalog;
            catalog_failure = j.failure;
            if (!catalog_completed) {
                catalog_completed = true;
                window.dirty = true;
                log.info(.profile, "xodb: agent-time catalog ready sessions={d}\n", .{if (catalog) |c| c.entries.len else 0});
            }
        };
        if (index_job) |j| if (j.done.load(.acquire)) {
            if (catalog) |c| if (indexing) |index| {
                if (j.summary) |summary| try c.update(index, summary.value) else {
                    c.entries[index].indexed = true;
                    c.entries[index].failure = if (j.failure) |err| @errorName(err) else "Unavailable";
                }
            };
            j.deinit();
            index_job = null;
            indexing = null;
            window.dirty = true;
        };
        if (view.show_browser) {
            if (catalog_job == null) catalog_job = try model.Job.start(io, "catalog", "");
            if (browser.input(&window, catalog)) |index| {
                browser.fleet_requested = false;
                const entry = catalog.?.entries[index];
                if (index_job) |j| j.deinit();
                index_job = null;
                indexing = null;
                if (job) |j| j.deinit();
                job = null;
                job = try model.Job.start(io, entry.agent, entry.path);
                completed = false;
                view = View{};
            } else if (browser.fleet_requested and catalog != null and !window.closing) {
                browser.fleet_requested = false;
                const options = try browser.fleetOptions(a, catalog.?);
                defer a.free(options);
                if (index_job) |j| j.deinit();
                index_job = null;
                indexing = null;
                if (job) |j| j.deinit();
                job = null;
                job = try model.Job.start(io, "fleet", options);
                completed = false;
                view = .{};
            } else if (index_job == null and !window.closing) if (catalog) |c| {
                var next: ?usize = null;
                if (browser.selected < c.entries.len and !c.entries[browser.selected].indexed and browser.matches(c.entries[browser.selected])) next = browser.selected;
                if (next == null) for (c.entries, 0..) |entry, index| if (!entry.indexed and browser.matches(entry)) {
                    next = index;
                    break;
                };
                if (next) |index| {
                    const entry = c.entries[index];
                    index_job = try model.Job.startIndex(io, entry.agent, entry.path);
                    indexing = index;
                }
            };
        } else if (job) |j| view.input(&window, if (ready) j.profile else null);
        // First-live activation frees the offline snapshot before constructing
        // the live one. Later refreshes retain the last complete live view.
        if (!view.live or view.show_browser or window.closing) {
            if (refresh_job) |j| j.deinit();
            refresh_job = null;
            live_reader.stop(io);
            if (live_started and !view.show_browser and !window.closing) if (job) |j| {
                if (j.profile == null) {
                    const reload = try model.Job.start(io, j.agent, j.path);
                    j.deinit();
                    job = reload;
                    completed = false;
                    window.dirty = true;
                    log.info(.profile, "xodb: agent-time cancelled initial live load; reloading offline\n", .{});
                }
            };
            live_started = false;
            if (view.show_browser) view.live_status = "off";
        } else if (job) |j| {
            if (std.mem.eql(u8, j.agent, "archive") or std.mem.eql(u8, j.agent, "fleet")) {
                view.live = false;
                view.live_status = "single log only";
                window.dirty = true;
            } else if (j.done.load(.acquire)) {
                if (!live_started) {
                    live_started = true;
                    if (j.profile) |old| {
                        view.remember(old);
                        old.deinit();
                        j.profile = null;
                        log.info(.profile, "xodb: agent-time live initial view released\n", .{});
                    }
                    j.failure = null;
                    view.zoom = 0;
                    view.selected = 0;
                    view.hit_count = 0;
                    view.chart.hit_count = 0;
                    next_refresh = 0;
                    window.dirty = true;
                }
                if (refresh_job) |refresh| {
                    if (refresh.done.load(.acquire)) {
                        const status = if (refresh.failure) |err| @errorName(err) else "watching";
                        if (!std.mem.eql(u8, view.live_status, status)) window.dirty = true;
                        view.live_status = status;
                        if (j.profile == null) j.failure = refresh.failure;
                        if (refresh.profile != null) {
                            if (j.profile) |old| {
                                view.remember(old);
                                old.deinit();
                            }
                            j.profile = refresh.profile;
                            j.failure = null;
                            refresh.profile = null;
                            view.restore(j.profile.?);
                            view.audit(j.profile.?, "live");
                            window.dirty = true;
                            log.info(.profile, "xodb: agent-time live updated mode={s} read_bytes={d:.0}\n", .{ model.text(model.field(j.profile.?.doc, "live_mode")), model.number(model.field(j.profile.?.doc, "live_read_bytes")) });
                        }
                        refresh.deinit();
                        refresh_job = null;
                        next_refresh = std.Io.Clock.awake.now(io).toMilliseconds() + 2000;
                    }
                } else if (std.Io.Clock.awake.now(io).toMilliseconds() >= next_refresh) {
                    refresh_job = try model.Job.startTail(io, j.agent, j.path, &live_reader);
                    if (std.mem.eql(u8, view.live_status, "starting") or std.mem.eql(u8, view.live_status, "off")) {
                        window.dirty = true;
                        view.live_status = "watching";
                    }
                }
            }
        }
        if (!window.dirty and frames == 0) continue;
        _ = try font.setScale(window.scale());
        if (!try renderer.begin(window.width, window.height, window.scale())) continue;
        if (view.show_browser) try browser.draw(&renderer, font, &window, catalog, catalog_failure, indexing) else if (job) |j| try view.draw(&renderer, font, &window, j);
        if (!try renderer.end(font)) continue;
        window.dirty = false;
        if (ready or (view.show_browser and catalog_completed)) count += 1;
    }
}
