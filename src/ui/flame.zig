const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const perf = @import("../profile/linux_perf.zig");
const profile = @import("../profile/capture.zig");
const tree = @import("../profile/flame.zig");
const display = @import("../model/profile_view.zig");
const timeline = @import("../profile/timeline.zig");
const info = @import("../debug/info.zig");
const disasm = @import("../model/disassembly.zig");
const style = @import("style.zig");
const timeline_view = @import("timeline.zig");
const capture_setup = @import("capture_setup.zig");
const capture_panel = @import("capture_panel.zig");
const theme = style.theme;
const now = @import("../target/linux.zig").now;
const Hit = struct { rect: gpu.Rect, node: u32 };
const derived = @import("../profile/derived.zig");
pub const Basis = display.Basis;
const ViewStatus = display.ViewStatus;
pub const FlameView = struct {
    view: display.View = .{},
    capture_key: ?display.Key = null,
    selected_path: display.Path = .{},
    zoom_path: display.Path = .{},
    graph: ?display.Graph = null,
    capture_id: u64 = 0,
    revision: u64 = 0,
    view_id: ?[64]u8 = null,
    view_status: ViewStatus = .ready,
    clone_failure: ?[]const u8 = null,
    mapping_revision: u64 = 0,
    selection: timeline.Selection = .{},
    built_filter: profile.Filter = .{},
    sample_count: usize = 0,
    trusted_before_ns: u64 = std.math.maxInt(u64),
    refreshed_ns: u64 = 0,
    selected: u32 = 0,
    zoom: u32 = 0,
    scroll: f32 = 0,
    source: ?info.Site = null,
    instructions: []const disasm.Instruction = &.{},
    diagnostic: ?[]const u8 = null,
    hits: [512]Hit = undefined,
    hit_count: usize = 0,
    duration_button: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    scheduling_button: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    viewport: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Recorded kernel callchains, or the reconstructed view (B).
    basis: Basis = .recorded,
    derived_identity: [64]u8 = @splat(0),
    derived_failed_identity: ?[64]u8 = null,
    derived_counts: derived.Counts = .{},
    derived_examples: []const u32 = &.{},

    pub fn deinit(_: *FlameView) void {}
    pub fn request(self: *const FlameView, enabled: bool) ?display.Request {
        if (!enabled) return null;
        return .{ .key = self.capture_key, .basis = self.basis, .filter = self.selection.filter, .selected = self.selected_path };
    }
    pub fn present(self: *FlameView, value: display.View) void {
        self.view = .{};
        self.derived_examples = &.{};
        self.graph = null;
        self.source = null;
        self.instructions = &.{};
        self.diagnostic = null;
        self.hit_count = 0;
        const request_ = value.request orelse {
            self.view = .{};
            return;
        };
        if (request_.basis != self.basis) return;
        if (value.key) |key| {
            const replaced = self.capture_key == null or self.capture_key.?.session != key.session or self.capture_id != key.capture;
            if (replaced) {
                self.selection = .{};
                self.selection.bind(key.capture, value.extent_ns);
                self.selection.filter = request_.filter;
            } else if (!std.meta.eql(request_.filter, self.selection.filter)) return;
            const reset = replaced or self.mapping_revision != key.mapping_revision or (key.trusted_before_ns != std.math.maxInt(u64) and self.revision != key.revision);
            if (reset) {
                self.selected_path = .{};
                self.zoom_path = .{};
                self.scroll = 0;
            }
            self.capture_key = key;
            self.capture_id = key.capture;
            self.revision = key.revision;
            self.mapping_revision = key.mapping_revision;
            self.trusted_before_ns = key.trusted_before_ns;
        } else self.capture_key = null;
        self.view = value;
        self.graph = value.graph;
        self.view_id = value.view_id;
        self.view_status = value.view_status;
        self.sample_count = value.sample_count;
        self.built_filter = value.built_filter;
        self.derived_counts = value.derived_counts;
        self.derived_examples = value.derived_examples;
        self.selected = if (self.graph) |graph| self.selected_path.restore(&graph) else 0;
        self.zoom = if (self.graph) |graph| self.zoom_path.restore(&graph) else 0;
        if (self.graph != null) {
            self.selected_path = display.Path.save(self.graph, self.selected);
            self.zoom_path = display.Path.save(self.graph, self.zoom);
        }
        if (std.meta.eql(self.selected_path, value.detail_path)) {
            self.source = value.source;
            self.instructions = value.instructions;
            self.diagnostic = value.diagnostic;
        } else self.diagnostic = "Preparing selected frame";
    }
    pub fn setFilter(self: *FlameView, filter: profile.Filter) !void {
        try filter.validate();
        try self.selection.set(filter);
        self.hit_count = 0;
        self.selected_path = .{};
        self.zoom_path = .{};
        self.selected = 0;
        self.zoom = 0;
        self.scroll = 0;
    }
    pub fn select(self: *FlameView, node: u32) void {
        const graph = self.graph orelse return;
        if (node >= graph.nodes.items.len) return;
        self.selected = node;
        self.selected_path = display.Path.save(graph, node);
        self.source = null;
        self.instructions = &.{};
        self.diagnostic = "Preparing selected frame";
    }
    pub fn selectedFrame(self: *const FlameView) ?tree.Frame {
        const graph = self.graph orelse return null;
        if (self.selected >= graph.nodes.items.len) return null;
        return graph.nodes.items[self.selected].frame;
    }
    pub fn hit(self: *const FlameView, x: f32, y: f32) ?u32 {
        for (self.hits[0..self.hit_count]) |item| if (inside(item.rect, x, y)) return item.node;
        return null;
    }
    /// The header button that opens next-capture setup (S).
    pub fn setupHit(self: *const FlameView, x: f32, y: f32) bool {
        return inside(self.scheduling_button, x, y);
    }
    pub fn cycleDuration(next: *profile.Config) void {
        const presets = [_]u32{ 10000, 30000, 60000, 300000, 0 };
        // A custom duration advances to the next larger preset.
        for (presets) |duration| if (duration > next.duration_ms and next.duration_ms != 0) {
            next.duration_ms = duration;
            return;
        };
        next.duration_ms = if (next.duration_ms == 0) presets[0] else 0;
    }
    pub fn durationHit(self: *const FlameView, x: f32, y: f32) bool {
        return inside(self.duration_button, x, y);
    }
    fn durationText(buffer: []u8, ms: u32) []const u8 {
        if (ms == 0) return "until stopped";
        if (ms > 60000 and ms % 60000 == 0) return std.fmt.bufPrint(buffer, "{d} min", .{ms / 60000}) catch "";
        if (ms % 1000 == 0) return std.fmt.bufPrint(buffer, "{d} s", .{ms / 1000}) catch "";
        return std.fmt.bufPrint(buffer, "{d} ms", .{ms}) catch "";
    }
    pub fn zoomSelected(self: *FlameView) void {
        self.zoom = self.selected;
        self.zoom_path = self.selected_path;
        self.scroll = 0;
    }
    pub fn zoomOut(self: *FlameView) void {
        const graph = self.graph orelse return;
        self.zoom = graph.nodes.items[self.zoom].parent orelse 0;
        self.zoom_path = display.Path.save(graph, self.zoom);
        self.scroll = 0;
    }
    pub fn scrollBy(self: *FlameView, delta: i32) void {
        const graph = self.graph orelse return;
        var deepest: u16 = 0;
        for (graph.nodes.items) |node| deepest = @max(deepest, node.depth);
        const maximum = @max(0, @as(f32, @floatFromInt(deepest + 1 -| graph.nodes.items[self.zoom].depth)) * 24 - self.viewport.h);
        self.scroll = std.math.clamp(self.scroll + @as(f32, @floatFromInt(delta)) * 18, 0, maximum);
    }
    /// The timeline selection the graph was built with, for the status line.
    fn scopeText(buffer: []u8, filter: profile.Filter) []const u8 {
        if (std.meta.eql(filter, profile.Filter{})) return "";
        var thread: [24]u8 = undefined;
        const tid = if (filter.tid) |t| std.fmt.bufPrint(&thread, "  TID {d}", .{t}) catch "" else if (filter.tids.len > 0) std.fmt.bufPrint(&thread, "  {d} threads", .{filter.tids.len}) catch "" else "";
        if (filter.from_ns == 0 and filter.to_ns == std.math.maxInt(u64)) return std.fmt.bufPrint(buffer, "  /  graph:{s}", .{tid}) catch "";
        var a: [32]u8 = undefined;
        var b: [32]u8 = undefined;
        return std.fmt.bufPrint(buffer, "  /  graph: [{s}, {s}){s}", .{ timeline_view.duration(&a, filter.from_ns), timeline_view.duration(&b, filter.to_ns), tid }) catch "";
    }
    fn inside(rect: gpu.Rect, x: f32, y: f32) bool {
        return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
    }
    fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime fmt: []const u8, args: anytype) !void {
        var buffer: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
        try r.textFit(font, x, y, width, text, color);
    }
    /// Switch bases. The other basis's tree, zoom and selection never carry over.
    pub fn setBasis(self: *FlameView, basis: Basis) void {
        if (basis == self.basis) return;
        self.basis = basis;
        self.selected_path = .{};
        self.zoom_path = .{};
        self.source = null;
        self.instructions = &.{};
        self.graph = null;
        self.selected = 0;
        self.zoom = 0;
        self.scroll = 0;
        self.hit_count = 0;
        self.capture_id = 0;
        self.revision = 0;
        self.view_id = null;
        self.clone_failure = null;
        self.view_status = .ready;
        self.derived_identity = @splat(0);
        self.derived_failed_identity = null;
        self.derived_examples = &.{};
        self.diagnostic = null;
    }
    /// The sample that first reached the selected reconstructed node.
    pub fn selectedExample(self: *const FlameView) ?u32 {
        if (self.basis != .reconstructed or self.selected >= self.derived_examples.len) return null;
        const ordinal = self.derived_examples[self.selected];
        return if (ordinal == std.math.maxInt(u32)) null else ordinal;
    }
    pub fn draw(self: *FlameView, r: *gpu.Renderer, font: *Font, bounds: gpu.Rect) !void {
        const next = self.view.next;
        const start_error = self.view.start_error;
        const failure = self.view.start_failure;
        const requested_threads = self.view.requested_threads;
        const waiting = self.view.waiting;
        self.hit_count = 0;
        r.clip = bounds;
        try style.box(r, bounds, theme.surface, theme.border, @splat(8));
        try r.textFit(font, bounds.x + 14, bounds.y + 9, 175, "FLAMES / B: basis", theme.text);
        const offline = if (self.view.facts) |facts| facts.offline else false;
        const active = if (self.view.facts) |facts| facts.collecting else false;
        try style.button(r, font, .{ .x = bounds.x + 205, .y = bounds.y + 5, .w = 170, .h = 28 }, if (offline) "Offline" else if (active) "Stop capture" else "New capture", if (offline) "" else "P", if (active) theme.warm else theme.good, 0, 0);
        try style.button(r, font, .{ .x = bounds.x + 390, .y = bounds.y + 5, .w = 140, .h = 28 }, "Zoom", "Z", theme.text, 0, 0);
        try style.button(r, font, .{ .x = bounds.x + 545, .y = bounds.y + 5, .w = 160, .h = 28 }, "Parent", "BKSP", theme.text, 0, 0);
        try style.button(r, font, .{ .x = bounds.x + 720, .y = bounds.y + 5, .w = 240, .h = 28 }, if (offline) "Location" else "Browse source", "ENTER", theme.text, 0, 0);
        self.scheduling_button = .{ .x = bounds.x + 975, .y = bounds.y + 5, .w = @max(0, bounds.w - 989), .h = 28 };
        if (self.scheduling_button.w >= 180) {
            try style.button(r, font, self.scheduling_button, if (offline) "Capture details" else if (next.context_switch) "Setup / sched on" else "Setup / sched off", "S", theme.text, 0, 0);
        } else self.scheduling_button.w = 0;
        self.duration_button = .{ .x = bounds.x + 975, .y = bounds.y + 37, .w = @max(0, bounds.w - 989), .h = 24 };
        var duration_buffer: [32]u8 = undefined;
        const next_duration = durationText(&duration_buffer, next.duration_ms);
        if (!offline and self.duration_button.w >= 180) {
            var text_buffer: [64]u8 = undefined;
            const text = try std.fmt.bufPrint(&text_buffer, "Next: {s}", .{next_duration});
            try style.button(r, font, self.duration_button, text, "T", theme.text, 0, 0);
        } else self.duration_button.w = 0;
        const status_width = if (self.duration_button.w > 0) @min(bounds.w - 28, 947) else bounds.w - 28;
        if (start_error) |message| {
            // A failed start is not a capture outcome; any earlier capture is unchanged.
            var buffer: [256]u8 = undefined;
            const failed = capture_setup.startFailure(&buffer, message, failure, requested_threads, .{});
            try label(r, font, bounds.x + 14, bounds.y + 38, status_width, theme.warm, "Did not start: {s}. {s}. S shows details.", .{ failed.title, failed.next });
        } else if (self.view.facts) |facts| {
            var scope: [96]u8 = undefined;
            var line: [512]u8 = undefined;
            const filtered = !std.meta.eql(self.built_filter, profile.Filter{});
            const why = capture_setup.reason(facts.status);
            const color = if (filtered or why.severity != .normal) theme.warm else theme.weak;
            try label(r, font, bounds.x + 14, bounds.y + 38, status_width, color, "{s}{s}", .{ capture_panel.headerLine(&line, facts, .{}, .{ .now_ns = now() }), scopeText(&scope, self.built_filter) });
        } else {
            try r.textFit(font, bounds.x + 14, bounds.y + 48, status_width, "Pause after program initialization, press P, then Space to run. P stops collection; F returns to source.", theme.weak);
            try label(r, font, bounds.x + 14, bounds.y + 79, bounds.w - 28, theme.weak, "Next: {d} Hz / {s}. S sets duration, rate, scheduling and threads (up to {d}); T cycles duration.", .{ next.frequency_hz, next_duration, perf.max_threads });
            return;
        }
        if (self.basis == .reconstructed) {
            const c = self.derived_counts;
            if (waiting == null) {
                const coverage_color = if (c.partial + c.leaf_only + c.unavailable + c.excluded > 0) theme.warm else theme.good;
                if (bounds.w < 900) {
                    try label(r, font, bounds.x + 14, bounds.y + 62, bounds.w - 28, coverage_color, "{d} samples: {d} complete / {d} partial", .{ c.filtered, c.complete, c.partial });
                    try label(r, font, bounds.x + 14, bounds.y + 84, bounds.w - 28, coverage_color, "{d} leaf / {d} no stack / {d} excluded   I: sample", .{ c.leaf_only, c.unavailable, c.excluded });
                } else {
                    try label(r, font, bounds.x + 14, bounds.y + 62, bounds.w - 28, coverage_color, "Reconstructed of {d} samples in selection: {d} complete / {d} partial / {d} leaf only / {d} no stack / {d} over node limit", .{ c.filtered, c.complete, c.partial, c.leaf_only, c.unavailable, c.excluded });
                    try r.textFit(font, bounds.x + 14, bounds.y + 84, bounds.w - 28, "Partial: callers above [callers unknown] are unknown, not absent. Saved stacks + CFI; recorded callchains unchanged. B: recorded. I: inspect sample.", theme.weak);
                }
            } else try r.textFit(font, bounds.x + 14, bounds.y + 62, bounds.w - 28, waiting.?, theme.warm);
            if (waiting != null) return;
        } else if (self.view.cpu_activity) |cpu| {
            const facts = self.view.facts.?;
            if (cpu.user_ms != null and cpu.kernel_ms != null) {
                try label(r, font, bounds.x + 14, bounds.y + 62, bounds.w - 28, theme.weak, "CPU totals: user {d} ms / kernel {d} ms / wall {d} ms / {d}/{d} threads accounted. Graph samples user CPU only.", .{ cpu.user_ms.?, cpu.kernel_ms.?, (facts.ended_ns.? -| facts.started_ns) / 1_000_000, cpu.available_threads, facts.selected_threads });
            } else try r.textFit(font, bounds.x + 14, bounds.y + 62, bounds.w - 28, "CPU totals unavailable (tasks exited or counters inaccessible). Graph samples user CPU only; excludes kernel and I/O waits.", theme.weak);
        } else try r.textFit(font, bounds.x + 14, bounds.y + 62, bounds.w - 28, "Samples cover user CPU only. Kernel work and I/O waits are absent. Click selects; Z zooms; wheel scrolls depth.", theme.weak);
        if (self.basis == .recorded and self.view.facts != null) {
            if (!offline) {
                // Routine snapshot refreshes are progress, so keep their color
                // neutral. Reserve warning emphasis for a failed view build.
                // Pad ready/building equally so each refresh does not shift
                // the rest of the status line sideways.
                try label(r, font, bounds.x + 14, bounds.y + 84, bounds.w - 28, if (self.view_status == .failed) theme.warm else theme.weak, "View r{d}: {d}/{d} samples / {s: <8}. Current r{d}. Maps {d}; unobserved map/code edits can invalidate symbols.", .{ self.revision, self.sample_count, self.view.current_samples, self.view_status.text(), self.view.current_revision, self.view.recorded_changes });
            } else try label(r, font, bounds.x + 14, bounds.y + 84, bounds.w - 28, theme.weak, "Maps {d} / unresolved {d}. Unreported munmap/mremap and code edits can invalidate symbols.", .{ self.view.recorded_changes, self.view.unresolved_mappings });
        }
        const graph = self.graph orelse {
            if (self.diagnostic) |diagnostic| try r.textFit(font, bounds.x + 14, bounds.y + 92, bounds.w - 28, diagnostic, theme.warm);
            return;
        };
        const root = graph.nodes.items[self.zoom];
        const compact = bounds.h < 380;
        self.viewport = .{ .x = bounds.x + 10, .y = bounds.y + 111, .w = bounds.w - 20, .h = @max(0, bounds.h - @as(f32, if (compact) 145 else 267)) };
        self.scrollBy(0);
        const view = self.viewport;
        r.clip = view;
        if (root.inclusive == 0) try r.textFit(font, view.x + 10, view.y + 12, view.w - 20, "No user CPU samples. Resume a stopped target; kernel-heavy copying or I/O waits can also leave this view empty.", theme.weak);
        for (graph.nodes.items) |node| {
            if (node.depth < root.depth or node.x < root.x or node.x + node.inclusive > root.x + root.inclusive or root.inclusive == 0) continue;
            // Interval containment alone also admits a zero-width neighbor;
            // only positive samples have drawable rectangles.
            if (node.inclusive == 0) continue;
            const denominator: f32 = @floatFromInt(root.inclusive);
            const x = view.x + @as(f32, @floatFromInt(node.x - root.x)) / denominator * view.w;
            const width = @as(f32, @floatFromInt(node.inclusive)) / denominator * view.w;
            const y = view.y + view.h - @as(f32, @floatFromInt(node.depth - root.depth + 1)) * 24 + self.scroll;
            if (width < 1 or y + 23 <= view.y or y >= view.y + view.h) continue;
            if (self.hit_count == self.hits.len) break;
            const rect = gpu.Rect{ .x = x, .y = @max(y, view.y), .w = width, .h = @min(y + 23, view.y + view.h) - @max(y, view.y) };
            self.hits[self.hit_count] = .{ .rect = rect, .node = node.id };
            self.hit_count += 1;
            const tone: f32 = @as(f32, @floatFromInt(graph.colors[node.id])) / 100;
            const color: gpu.Color = switch (node.frame.kind) {
                .code => style.mix(theme.flame_low, theme.flame_high, tone),
                .root, .thread => theme.flame_root,
                else => theme.flame_unknown,
            };
            try r.rect(.{ .x = x + 0.5, .y = y, .w = @max(0, width - 1), .h = 23 }, color);
            if (node.id == self.selected) try style.focus(r, .{ .x = x, .y = y, .w = width, .h = 23 }, 2, 1);
            if (width > 35) try r.textFit(font, x + 5, y + 2, width - 10, node.frame.name, theme.flame_text);
        }
        r.clip = bounds;
        const y = view.y + view.h + 8;
        try r.rect(.{ .x = bounds.x + 10, .y = y, .w = bounds.w - 20, .h = 1 }, theme.border);
        const node = graph.nodes.items[self.selected];
        const total: f64 = @floatFromInt(@max(1, graph.nodes.items[0].inclusive));
        if (self.basis == .reconstructed) {
            try label(r, font, bounds.x + 14, y + 7, bounds.w - 28, theme.warm, "{s} / inclusive {d} ({d:.1}%) / self {d} / reconstructed", .{ node.frame.name, node.inclusive, @as(f64, @floatFromInt(node.inclusive)) * 100 / total, node.self });
        } else try label(r, font, bounds.x + 14, y + 7, bounds.w - 28, theme.warm, "{s}  /  inclusive {d} ({d:.1}%)  /  self {d}  /  partial {d} / unverified {d} / excluded {d}", .{ node.frame.name, node.inclusive, @as(f64, @floatFromInt(node.inclusive)) * 100 / total, node.self, graph.partial_samples, graph.unverified_samples, graph.rejected });
        if (compact) return; // Leave visible graph rows at small window heights.
        if (self.source) |site| {
            try label(r, font, bounds.x + 14, y + 30, bounds.w - 28, theme.neutral, "{s}:{d}  /  representative sample/caller location", .{ site.path, site.line });
        } else try r.textFit(font, bounds.x + 14, y + 30, bounds.w - 28, if (node.frame.kind == .code) "No source line available for this frame" else "Select a symbolized frame to inspect source and assembly", theme.weak);
        for (self.instructions[0..@min(3, self.instructions.len)], 0..) |instruction, i| {
            try label(r, font, bounds.x + 14, y + 54 + @as(f32, @floatFromInt(i)) * 22, bounds.w - 28, if (node.frame.lookup_address >= instruction.address and node.frame.lookup_address < instruction.address + instruction.size) theme.warm else theme.text, "{x}  {s} {s}", .{ instruction.address, std.mem.sliceTo(&instruction.mnemonic, 0), std.mem.sliceTo(&instruction.operands, 0) });
        }
        if (self.diagnostic) |diagnostic| try r.textFit(font, bounds.x + 14, y + 54, bounds.w - 28, diagnostic, theme.weak);
        if (self.view.facts != null and self.view.facts.?.status == .thread_scope_changed and self.view.facts.?.scope_change != null) {
            const change = self.view.facts.?.scope_change.?;
            try label(r, font, bounds.x + 14, bounds.y + bounds.h - 23, bounds.w - 28, theme.warm, "Capture stopped: new {s}, PID {d} / TID {d}. Task outside capture scope.", .{ if (change.pid == self.view.facts.?.pid) "thread" else "child process", change.pid, change.tid });
        } else if (self.view.capture_diagnostic.len > 0) {
            try label(r, font, bounds.x + 14, bounds.y + bounds.h - 23, bounds.w - 28, theme.warm, "{s}: {s}", .{ if (active) "Capture" else "Capture stopped", self.view.capture_diagnostic });
        } else try r.textFit(font, bounds.x + 14, bounds.y + bounds.h - 23, bounds.w - 28, if (offline) "Recorded labels/locations; assembly needs verified ELF assets. Historical source text is not bundled." else "Assembly: retained ELF bytes. Enter browses the live stopped image when its identity matches; execution and registers stay unchanged.", theme.weak);
    }
};

test "capture duration presets include a manual deadline and preserve other settings" {
    var next = profile.Config{ .frequency_hz = 199, .context_switch = true };
    for ([_]u32{ 300000, 0, 10000, 30000, 60000 }) |expected| {
        FlameView.cycleDuration(&next);
        try std.testing.expectEqual(expected, next.duration_ms);
        try std.testing.expect(next.context_switch and next.frequency_hz == 199);
    }
    next.duration_ms = 125;
    FlameView.cycleDuration(&next);
    try std.testing.expectEqual(@as(u32, 10000), next.duration_ms);
}
