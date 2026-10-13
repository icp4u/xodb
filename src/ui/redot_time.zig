//! Frame selection and a script/native drill-down. Timing totals are never
//! presented as per-node costs when several scene nodes share the script.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const style = @import("style.zig");
const p = @import("../redot/profiler.zig");
const protocol = @import("../redot/protocol.zig");
const Event = @import("../platform/input.zig").Event;

pub const Panel = struct {
    number: ?u64 = null,
    function: usize = 0,
    function_first: usize = 0,
    plot: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    rows_y: f32 = 0,
    pub fn selected(self: *Panel, state: *const p.State) ?*const p.Frame {
        if (self.number) |number| if (state.find(number)) |frame| return frame;
        return if (state.count > 0) state.at(state.count - 1) else null;
    }
    pub fn input(self: *Panel, event: Event, state: *const p.State, focused: bool) bool {
        if (state.count == 0) return false;
        if (event.kind == .button_press and event.code == 272 and event.x >= self.plot.x and event.x < self.plot.x + self.plot.w) {
            if (event.y >= self.plot.y and event.y < self.plot.y + self.plot.h) {
                const index: usize = @intFromFloat((event.x - self.plot.x) / self.plot.w * @as(f32, @floatFromInt(state.count)));
                self.number = state.at(@min(index, state.count - 1)).number;
                self.function = 0;
                return true;
            }
            if (event.y >= self.rows_y and event.y < self.rows_y + 6 * 24) {
                self.function = self.function_first + @as(usize, @intFromFloat((event.y - self.rows_y) / 24));
                return true;
            }
        }
        if (!event.plain() or (event.kind != .press and event.kind != .repeat)) return false;
        if (focused and (event.shortcut == 0xff52 or event.shortcut == 0xff54)) {
            const frame = self.selected(state) orelse return false;
            self.function = if (event.shortcut == 0xff52) self.function -| 1 else @min(frame.functions.len -| 1, self.function + 1);
            return true;
        }
        if (event.shortcut == 'f') {
            var peak = state.at(0);
            for (0..state.count) |i| if (state.at(i).frame_ms > peak.frame_ms) {
                peak = state.at(i);
            };
            self.number = peak.number;
            self.function = 0;
            return true;
        }
        if (event.shortcut == 'l') {
            self.number = null;
            return true;
        }
        if (event.shortcut == 0xff51 or event.shortcut == 0xff53) {
            const frame = self.selected(state) orelse return false;
            for (0..state.count) |i| if (state.at(i).number == frame.number) {
                self.number = state.at(if (event.shortcut == 0xff51) i -| 1 else @min(state.count - 1, i + 1)).number;
                self.function = 0;
                break;
            };
            return true;
        }
        return false;
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, b: gpu.Rect, state: *const p.State, node: ?protocol.Node) !void {
        const theme = style.theme;
        var text: [1024]u8 = undefined;
        const capture = &state.capture;
        const status: ?[]const u8 = switch (capture.phase) {
            .sampling => try std.fmt.bufPrint(&text, "Sampling... {d} of {d}", .{ capture.completed, capture.total }),
            .failed => try std.fmt.bufPrint(&text, "Scene startup: {s}", .{capture.diagnostic()}),
            else => null,
        };
        try r.textFit(font, b.x, b.y, b.w, if (state.count > 0) status orelse "FRAME TIME / click bar  F slowest  L latest  Left/Right frame" else "FRAME TIME", if (capture.phase == .failed) theme.warm else theme.good);
        const frame = self.selected(state) orelse {
            try r.textFit(font, b.x, b.y + 35, b.w, status orelse if (state.enabled) "Sampling... waiting for engine frames." else "Start with demo-redot time or MCP set_redot_profiling.", theme.text);
            return;
        };
        self.plot = .{ .x = b.x, .y = b.y + 30, .w = b.w, .h = 78 };
        var max_ms: f64 = 1;
        for (0..state.count) |i| max_ms = @max(max_ms, state.at(i).frame_ms);
        const width = b.w / @as(f32, @floatFromInt(state.count));
        for (0..state.count) |i| {
            const item = state.at(i);
            const h: f32 = @floatCast(item.frame_ms / max_ms * 70);
            const x = b.x + @as(f32, @floatFromInt(i)) * width;
            var sampled = false;
            for (0..state.sample_count) |s| if (state.sampleAt(s).frame_number == item.number) {
                sampled = true;
                break;
            };
            try r.rect(.{ .x = x, .y = self.plot.y + 76 - h, .w = @max(1, width - 1), .h = @max(1, h) }, if (item.number == frame.number) theme.good else if (sampled) theme.warm else theme.focus);
            // The selected bar still shows that its wall time includes a stop.
            if (sampled and item.number == frame.number) try r.rect(.{ .x = x, .y = self.plot.y + 76 - @max(4, h), .w = @max(1, width - 1), .h = 4 }, theme.warm);
        }
        try r.textFit(font, b.x, b.y + 114, b.w, try std.fmt.bufPrint(&text, "Process frame #{d}: {d:.2} ms | process {d:.2} physics {d:.2} script {d:.2}", .{ frame.number, frame.frame_ms, frame.process_ms, frame.physics_ms, frame.script_ms }), theme.text);
        var self_ms: f64 = 0;
        if (node) |n| if (n.script_path) |script| for (frame.functions) |function| {
            if (p.scriptPath(function.signature)) |path| if (std.mem.eql(u8, script, path)) {
                self_ms += function.self_ms;
            };
        };
        try r.textFit(font, b.x, b.y + 138, b.w, try std.fmt.bufPrint(&text, "Script-wide self {d:.2} ms / physics step {d:.2} ms (not per-instance)", .{ self_ms, frame.physics_step_ms }), theme.weak);
        try r.textFit(font, b.x, b.y + 166, b.w, "FUNCTIONS  self / inclusive ms / calls  (click to inspect native sample)", theme.good);
        self.rows_y = b.y + 193;
        self.function = @min(self.function, frame.functions.len -| 1);
        if (self.function < self.function_first) self.function_first = self.function;
        if (self.function >= self.function_first + 6) self.function_first = self.function - 5;
        self.function_first = @min(self.function_first, frame.functions.len);
        for (frame.functions[self.function_first..][0..@min(6, frame.functions.len - self.function_first)], 0..) |function, i| {
            const y = self.rows_y + @as(f32, @floatFromInt(i)) * 24;
            if (i + self.function_first == self.function) try style.focus(r, .{ .x = b.x - 3, .y = y - 2, .w = b.w, .h = 24 }, 2, 1);
            const signature = function.signature[0..@min(650, function.signature.len)];
            try r.textFit(font, b.x, y, b.w, try std.fmt.bufPrint(&text, "{d:.2} / {d:.2} / {d}   {s}", .{ function.self_ms, function.total_ms, function.calls, signature }), theme.text);
        }
        const native_y = b.y + 347;
        var chosen: ?*const p.Sample = null;
        var bound: ?usize = null;
        var owner: ?[]const u8 = null;
        for (0..state.sample_count) |i| {
            const sample = state.sampleAt(i);
            if (sample.frame_number != frame.number) continue;
            if (frame.functions.len > 0) for (sample.script) |script| {
                const signature = frame.functions[self.function].signature;
                if (script.file != null and std.mem.startsWith(u8, signature, script.file.?) and std.mem.endsWith(u8, signature, script.name) and script.native_frame != null and script.reason == null) {
                    chosen = sample;
                    bound = script.native_frame;
                    owner = script.owner_id;
                    break;
                }
            };
            if (chosen != null) break;
        }
        try r.textFit(font, b.x, native_y, b.w, "NATIVE FRAMES / explicit stopped sample / same engine frame number", theme.good);
        if (chosen) |sample| {
            try r.textFit(font, b.x, native_y + 24, b.w, try std.fmt.bufPrint(&text, "Owner #{s} / physics #{d} / {s} / inspection {d:.1} ms", .{ owner orelse "unknown", sample.physics_frame, if (sample.in_physics) "physics callback" else "process callback", @as(f64, @floatFromInt(sample.inspection_ns)) / 1e6 }), theme.weak);
            for (sample.native[0..@min(sample.native.len, (bound orelse 0) + 1)], 0..) |native, i| {
                const y = native_y + 50 + @as(f32, @floatFromInt(i)) * 22;
                if (y + 22 > b.y + b.h) break;
                try r.textFit(font, b.x, y, b.w, try std.fmt.bufPrint(&text, "#{d} {s}", .{ native.index, (native.display orelse native.pc)[0..@min((native.display orelse native.pc).len, 900)] }), theme.text);
            }
        } else try r.textFit(font, b.x, native_y + 30, b.w, "No native sample for this function in this frame. No attribution inferred.", theme.weak);
    }
};
