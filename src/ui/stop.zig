//! Current stop evidence, shared by live and read-only core sessions.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const Session = @import("../model/session.zig").Session;
const style = @import("style.zig");
const theme = style.theme;
pub const Panel = struct {
    open: bool = false,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    pub fn key(self: *Panel, event: keys.Event) bool {
        if (!self.open) return false;
        if (event.kind != .press and event.kind != .repeat) return true;
        if (!event.plain()) return true;
        if (event.shortcut == 'c' or event.shortcut == keys.sym.escape) {
            self.open = false;
            return true;
        }
        return false;
    }
    pub fn press(self: *Panel, x: f32, y: f32) void {
        const b = self.bounds;
        if (x < b.x or x > b.x + b.w or y < b.y or y > b.y + b.h) self.open = false;
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32, session: *Session, tid: i32) !void {
        if (!self.open) return;
        self.bounds = .{ .x = 20, .y = 96, .w = width - 40, .h = height - 136 };
        const b = self.bounds;
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = height - 110 }, .{ 0, 0, 0, 0.65 });
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        try r.textFit(font, b.x + 14, b.y + 10, b.w - 28, "STOP / CRASH DETAILS   C / Esc close", theme.text);
        const info = session.target.stopInfo(tid) catch |err| {
            try r.textFit(font, b.x + 14, b.y + 45, b.w - 28, @errorName(err), theme.weak);
            return;
        };
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var y = b.y + 44;
        const rows = [_][]const u8{
            try std.fmt.allocPrint(a, "{s}   tid {d}   {s}", .{ if (info.read_only) "Recorded core" else "Live stop", tid, @tagName(info.reason) }),
            try std.fmt.allocPrint(a, "Signal: {s} ({d})   code: {?d}   errno: {?d}", .{ info.signal_name, info.signal, info.code, info.errno }),
            try std.fmt.allocPrint(a, "Instruction: 0x{?x}", .{info.pc}),
            if (info.fault_address) |address| try std.fmt.allocPrint(a, "Fault address: 0x{x}", .{address}) else "Fault address: not reported for this stop",
        };
        for (rows) |row| {
            try r.textFit(font, b.x + 14, y, b.w - 28, row, theme.text);
            y += 27;
        }
        if (info.pc) |pc| {
            const site = session.sourceAt(a, pc) catch null;
            if (site) |source| {
                try r.textFit(font, b.x + 14, y, b.w - 28, try std.fmt.allocPrint(a, "{s}:{d}", .{ source.path, source.line }), theme.weak);
                y += 27;
            }
        }
        if (info.fault_address) |address| {
            var mapped = false;
            if (session.target.core) |*core| {
                for (core.segments.items) |segment| if (address >= segment.start and address < segment.end) {
                    mapped = true;
                    try r.textFit(font, b.x + 14, y, b.w - 28, if (address - segment.start < segment.stored) "Fault address lies in captured memory" else "Fault address mapped; bytes omitted from core", theme.weak);
                    break;
                };
            } else {
                session.refreshMaps() catch {};
                for (session.modules.regions.items) |region| if (address >= region.start and address < region.end) {
                    mapped = true;
                    try r.textFit(font, b.x + 14, y, b.w - 28, try std.fmt.allocPrint(a, "Fault mapping: {s} {s}", .{ &region.permissions, region.path }), theme.weak);
                    break;
                };
            }
            if (!mapped) try r.textFit(font, b.x + 14, y, b.w - 28, "Fault address has no mapping in the available map snapshot", theme.warm);
            y += 27;
        }
        if (info.diagnostic) |message| {
            try r.textFit(font, b.x + 14, y, b.w - 28, message, theme.warm);
            y += 27;
        }
        try r.textFit(font, b.x + 14, b.y + b.h - 54, b.w - 28, if (info.read_only) "Read-only dump: no execution, target writes or live process attachment" else if (info.pending_delivery) "Continue forwards this pending signal to the target" else "Continue has no pending application signal to forward", theme.weak);
        try r.textFit(font, b.x + 14, b.y + b.h - 28, b.w - 28, "Signal evidence identifies the stop; it does not establish the root cause", theme.weak);
    }
};
