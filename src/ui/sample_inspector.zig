//! One sample's recorded and reconstructed stacks (T16; proposed
//! `src/ui/sample_inspector.zig`). Reads the capture's recorded evidence and
//! an optional immutable per-sample unwind result from the existing stack job.
//! Recorded kernel callchain and derived callers stay in separate columns; no
//! source context is shown (names come only from verified ELF symbols).
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const style = @import("style.zig");
const theme = style.theme;
const profile = @import("../profile/capture.zig");
const records = @import("../profile/records.zig");
const unwind = @import("../profile/unwind.zig");

pub const Stack = union(enum) {
    /// Reconstruction was not requested (capture still collecting, stacks off).
    not_available: []const u8,
    pending,
    /// Another worker job (flame view, save) runs first.
    waiting: []const u8,
    failed: []const u8,
    ready: *const unwind.Result,
};
pub const Inspector = struct {
    open: bool = false,
    ordinal: usize = 0,
    scroll: usize = 0,
    max_scroll: usize = 0,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn scrollBy(self: *Inspector, delta: i32) void {
        self.scroll = @intCast(std.math.clamp(@as(i64, @intCast(self.scroll)) + delta, 0, @as(i64, @intCast(self.max_scroll))));
    }

    pub fn sync(self: *Inspector, capture: *const profile.Capture, filter: profile.Filter) void {
        if (self.ordinal < capture.samples.len() and matches(capture, filter, self.ordinal)) return;
        self.ordinal = first(capture, filter) orelse capture.samples.len();
        self.scroll = 0;
    }
    /// Next or previous sample matching the filter, in ordinal order.
    pub fn step(self: *Inspector, capture: *const profile.Capture, filter: profile.Filter, delta: i32) void {
        const n = capture.samples.len();
        if (n == 0) return;
        var i: i64 = @intCast(@min(self.ordinal, n - 1));
        var moved: usize = 0;
        while (moved < n) : (moved += 1) {
            i += delta;
            if (i < 0 or i >= n) return;
            if (matches(capture, filter, @intCast(i))) {
                self.ordinal = @intCast(i);
                self.scroll = 0;
                return;
            }
        }
    }
    pub fn matches(capture: *const profile.Capture, filter: profile.Filter, ordinal: usize) bool {
        const sample = capture.samples.core(ordinal);
        if (!sample.timePresent() or !sample.tidPresent() or sample.time_ns < capture.started_ns) return false;
        if (sample.tid > std.math.maxInt(i32) or !capture.includesThread(@intCast(sample.tid))) return false;
        return filter.contains(sample.tid, sample.time_ns - capture.started_ns);
    }
    /// First sample matching the filter, for opening without a selection.
    pub fn first(capture: *const profile.Capture, filter: profile.Filter) ?usize {
        for (0..capture.samples.len()) |i| if (matches(capture, filter, i)) return i;
        return null;
    }

    pub fn draw(self: *Inspector, r: *gpu.Renderer, font: *Font, bounds: gpu.Rect, capture: *const profile.Capture, stack: Stack) !void {
        self.bounds = bounds;
        if (!self.open) return;
        const saved = r.clip;
        defer r.clip = saved;
        r.clip = bounds;
        try style.shadow(r, bounds, 8, 0.7);
        try style.box(r, bounds, theme.surface, theme.border, @splat(8));
        var buffer: [512]u8 = undefined;
        const n = capture.samples.len();
        if (self.ordinal >= n) {
            try r.textFit(font, bounds.x + 14, bounds.y + 10, bounds.w - 28, "SAMPLE: none in the current selection (I / Esc closes)", theme.weak);
            return;
        }
        const sample = capture.samples.get(self.ordinal);
        const w = bounds.w - 28;
        var y = bounds.y + 9;
        try label(r, font, bounds.x + 14, y, w, theme.text, "SAMPLE {d}/{d}   capture #{d} rev {d}   [ ] samples; I closes", .{ self.ordinal, n, capture.id, capture.revision });
        y += 22;
        const offset = sample.time_ns -| capture.started_ns;
        try label(r, font, bounds.x + 14, y, w, theme.weak, "TID {d}   +{d}.{d:0>6} ms   {s}   recorded callchain: {s}", .{ sample.tid, offset / 1_000_000, offset % 1_000_000, @tagName(sample.cpu_mode), @tagName(sample.callchain) });
        y += 20;
        try r.textFit(font, bounds.x + 14, y, w, stateText(&buffer, capture, sample), theme.weak);
        y += 20;
        try label(r, font, bounds.x + 14, y, w, theme.text, "Sampled PC 0x{x}{s} (leaf lookup uses this exact PC; callers use return PC - 1)", .{ sample.ip, if (sample.ip_present) "" else " (absent)" });
        y += 24;
        try r.rect(.{ .x = bounds.x + 10, .y = y, .w = bounds.w - 20, .h = 1 }, theme.border);
        y += 6;
        const half = (bounds.w - 36) / 2;
        const left = bounds.x + 14;
        const right = left + half + 8;
        try r.textFit(font, left, y, half, "RECORDED kernel callchain", theme.neutral);
        try r.textFit(font, right, y, half, "DERIVED from saved stack + CFI", theme.neutral);
        y += 22;
        const rows: usize = @intFromFloat(@max(0, (bounds.y + bounds.h - y - 66) / 20));
        const derived_count: usize = if (stack == .ready) stack.ready.count else 0;
        self.max_scroll = @max(sample.frame_count, derived_count) -| @max(1, rows);
        self.scroll = @min(self.scroll, self.max_scroll);
        const recorded_start = @min(self.scroll, sample.frame_count);
        const derived_start = @min(self.scroll, derived_count);
        try label(r, font, left, bounds.y + bounds.h - 64, half, theme.weak, "{d}-{d} / {d} frames", .{ recorded_start, @min(sample.frame_count, recorded_start + rows), sample.frame_count });
        try label(r, font, right, bounds.y + bounds.h - 64, half, theme.weak, "{d}-{d} / {d} frames", .{ derived_start, @min(derived_count, derived_start + rows), derived_count });
        try r.textFit(font, left, bounds.y + bounds.h - 24, w, "Wheel / Up / Down: frames   [ ]: samples   I / Esc: close", theme.weak);
        // Recorded: the original kernel items in order, markers included.
        var shown: usize = 0;
        for (sample.frames[recorded_start..sample.frame_count], recorded_start..) |item, i| {
            if (shown == rows) break;
            const text = if (item.marker) std.fmt.bufPrint(&buffer, "{d: >2} [context {s}]", .{ i, @tagName(item.context) }) catch "" else std.fmt.bufPrint(&buffer, "{d: >2} 0x{x} {s}", .{ i, item.address, @tagName(item.context) }) catch "";
            try r.textFit(font, left, y + @as(f32, @floatFromInt(shown)) * 20, half, text, if (item.marker) theme.weak else theme.text);
            shown += 1;
        }
        if (sample.frame_count == 0) try r.textFit(font, left, y, half, "(no kernel callchain recorded)", theme.weak);
        switch (stack) {
            .ready => |result| {
                for (result.frames[derived_start..result.count], derived_start..) |frame, i| {
                    if (i - derived_start == rows) break;
                    const name = if (frame.name_len > 0) frame.name[0..frame.name_len] else "(no symbol)";
                    const text = std.fmt.bufPrint(&buffer, "{d: >2} {s}  pc 0x{x}{s} {s}", .{ i, name, frame.pc, if (i == 0) " leaf" else " lookup -1", frame.method orelse "" }) catch "";
                    try r.textFit(font, right, y + @as(f32, @floatFromInt(i - derived_start)) * 20, half, text, if (frame.name_len > 0) theme.text else theme.weak);
                }
                const end_y = bounds.y + bounds.h - 44;
                const complete = result.reason == .complete;
                try label(r, font, right, end_y, half, if (complete) theme.good else theme.warm, "{s}{s}{s}{s}", .{ if (complete) "CFI reached outermost frame" else "Unknown callers: ", if (complete) "" else @tagName(result.reason), if (result.detail != null) " / " else "", result.detail orelse "" });
            },
            .pending => try r.textFit(font, right, y, half, "Reconstructing on the worker...", theme.good),
            .waiting => |why| try label(r, font, right, y, half, theme.weak, "Queued: {s}", .{why}),
            .failed => |why| try label(r, font, right, y, half, theme.warm, "Failed: {s} (not retried)", .{why}),
            .not_available => |why| try r.textFit(font, right, y, half, why, theme.weak),
        }
    }
};
fn stateText(buffer: []u8, capture: *const profile.Capture, sample: records.Sample) []const u8 {
    if (capture.config.user_stack_bytes == 0) return "Sampled state: stack capture was off for this capture";
    if (sample.user_state == 0 or sample.user_state > capture.user_state.count) return "Sampled state: missing (no registers or stack recorded for this sample)";
    const entry = capture.user_state.entries[sample.user_state - 1];
    const state = entry.state;
    return std.fmt.bufPrint(buffer, "Registers {s} / stack {s}: {d} of {d} bytes retained (kernel valid {d}){s}", .{ if (state.regs_present) "present" else "absent", if (entry.status == .budget) "budget gap" else if (state.stack_len == 0) "absent" else "captured", state.stack_len, state.stack_size, state.stack_dyn, if (state.stack_short) ", short" else "" }) catch "";
}
fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime fmt: []const u8, args: anytype) !void {
    if (width <= 0) return;
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    try r.textFit(font, x, y, width, text, color);
}
