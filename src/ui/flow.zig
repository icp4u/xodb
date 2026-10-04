const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const model = @import("../model/session.zig");
const style = @import("style.zig");
const theme = style.theme;
const pitch: f32 = 119;
const card_height: f32 = 94;

pub const FlowView = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    function: ?model.FunctionGraph = null,
    diagnostic: ?[]const u8 = null,
    generation: u64 = std.math.maxInt(u64),
    anchor: u64 = 0,
    selected: usize = 0,
    scroll: f32 = 0,
    viewport: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn deinit(self: *FlowView) void {
        self.arena.deinit();
    }
    pub fn refresh(self: *FlowView, session: *model.Session, address: u64) void {
        if (self.generation == session.target.generation and self.anchor == address) return;
        self.generation = session.target.generation;
        self.anchor = address;
        _ = self.arena.reset(.retain_capacity);
        self.function = null;
        self.diagnostic = null;
        self.selected = 0;
        self.scroll = 0;
        if (session.target.state != .stopped or address == 0) return;
        self.function = session.functionGraph(self.arena.allocator(), address) catch |err| {
            self.diagnostic = @errorName(err);
            return;
        };
        self.selected = self.function.?.graph.blockAt(address) orelse 0;
        self.scroll = @as(f32, @floatFromInt(self.selected)) * pitch;
    }
    pub fn scrollBy(self: *FlowView, delta: i32) void {
        const f = self.function orelse return;
        const maximum = @max(0, @as(f32, @floatFromInt(f.graph.blocks.len)) * pitch - self.viewport.h);
        self.scroll = std.math.clamp(self.scroll + @as(f32, @floatFromInt(delta)) * 18, 0, maximum);
    }
    pub fn hit(self: *FlowView, x: f32, y: f32) ?u64 {
        const f = self.function orelse return null;
        if (x < self.viewport.x + 8 or x >= self.viewport.x + self.viewport.w - 49 or y < self.viewport.y or y >= self.viewport.y + self.viewport.h) return null;
        const offset = y - self.viewport.y + self.scroll - 8;
        if (offset < 0) return null;
        const index: usize = @intFromFloat(offset / pitch);
        if (index >= f.graph.blocks.len or offset - @as(f32, @floatFromInt(index)) * pitch >= card_height) return null;
        self.selected = index;
        return f.graph.blocks[index].address;
    }
    fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime format: []const u8, args: anytype) !void {
        var buffer: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, format, args) catch return;
        try r.textFit(font, x, y, width, text, color);
    }
    pub fn draw(self: *FlowView, r: *gpu.Renderer, font: *Font, bounds: gpu.Rect, pc: ?u64) !void {
        r.clip = bounds;
        if (self.function == null) {
            try r.textFit(font, bounds.x + 12, bounds.y + 12, bounds.w - 24, self.diagnostic orelse "Pause in a function to inspect flow", theme.weak);
            return;
        }
        const function = self.function.?;
        const graph = function.graph;
        try label(r, font, bounds.x + 12, bounds.y + 4, bounds.w - 24, theme.neutral, "{s}  /  {d} blocks", .{ function.symbol, graph.blocks.len });
        try r.textFit(font, bounds.x + 12, bounds.y + 25, bounds.w - 24, if (function.range_count > 1) "DWARF fragment / other ranges omitted" else if (graph.decoded_bytes < graph.size) "Partial decode / scroll / click block" else if (function.extent_source == .dwarf_subprogram) "DWARF bounds / scroll / click block" else "Static flow / scroll / click block", theme.weak);
        const details_h: f32 = @min(166, bounds.h * 0.40);
        self.viewport = .{ .x = bounds.x, .y = bounds.y + 49, .w = bounds.w, .h = @max(0, bounds.h - details_h - 49) };
        self.scrollBy(0);
        const view = self.viewport;
        r.clip = view;
        const card_x = view.x + 8;
        const card_w = view.w - 57;
        // Orthogonal edges stay in a narrow margin; loops run back up the same
        // address-ordered layout. Only visible geometry reaches the renderer.
        for (graph.edges, 0..) |edge, index| {
            if (edge.kind == .call) continue;
            const to = edge.to orelse continue;
            const y0 = view.y + 8 + @as(f32, @floatFromInt(edge.from)) * pitch - self.scroll + card_height - 14;
            const y1 = view.y + 8 + @as(f32, @floatFromInt(to)) * pitch - self.scroll + 14;
            const x = view.x + view.w - 8 - @as(f32, @floatFromInt(index % 4)) * 7;
            const color = style.fade(if (edge.kind == .taken) theme.good else if (edge.kind == .not_taken) theme.warm else theme.neutral, if (edge.from == self.selected) 0.95 else 0.35);
            try r.rect(.{ .x = card_x + card_w, .y = y0, .w = x - card_x - card_w, .h = 1 }, color);
            try r.rect(.{ .x = x, .y = @min(y0, y1), .w = 1, .h = @abs(y1 - y0) }, color);
            try r.rect(.{ .x = card_x + card_w, .y = y1, .w = x - card_x - card_w, .h = 1 }, color);
            if (y1 >= view.y and y1 + 14 < view.y + view.h) try r.text(font, card_x + card_w, y1 - 10, "<", color);
        }
        for (graph.blocks) |block| {
            const y = view.y + 8 + @as(f32, @floatFromInt(block.id)) * pitch - self.scroll;
            if (y + card_height < view.y or y > view.y + view.h) continue;
            const card = gpu.Rect{ .x = card_x, .y = y, .w = card_w, .h = card_height };
            const current = if (pc) |value| value >= block.address and value < block.end else false;
            try style.box(r, card, theme.header, if (current) theme.thread_main else theme.border, @splat(7));
            if (block.id == self.selected) try style.focus(r, card, 7, 1);
            try label(r, font, card_x + 9, y + 5, card_w - 18, if (current) theme.thread_main else theme.neutral, "B{d}  +0x{x} {s}", .{ block.id, block.address - graph.address, if (current) "PC" else "" });
            const first = graph.instructions[block.first];
            const last = graph.instructions[block.first + block.count - 1];
            const color = if (block.reachable) theme.text else theme.weak;
            try label(r, font, card_x + 9, y + 27, card_w - 18, color, "{s} {s}", .{ std.mem.sliceTo(&first.mnemonic, 0), std.mem.sliceTo(&first.operands, 0) });
            if (block.count > 1) try label(r, font, card_x + 9, y + 48, card_w - 18, color, "{s}{s} {s}", .{ if (block.count > 2) "... " else "", std.mem.sliceTo(&last.mnemonic, 0), std.mem.sliceTo(&last.operands, 0) });
            if (block.source) |site| try label(r, font, card_x + 9, y + 70, card_w - 18, theme.weak, "{s}:{d}", .{ std.fs.path.basename(site.path), site.line });
        }
        r.clip = bounds;
        const detail_y = view.y + view.h + 4;
        try r.rect(.{ .x = bounds.x, .y = detail_y, .w = bounds.w, .h = 1 }, theme.border);
        const selected = graph.blocks[self.selected];
        try label(r, font, bounds.x + 12, detail_y + 5, bounds.w - 24, theme.neutral, "B{d} / {d} instructions / G assembly", .{ selected.id, selected.count });
        var y = detail_y + 27;
        for (graph.edges) |edge| if (edge.from == self.selected) {
            if (edge.to) |to| try label(r, font, bounds.x + 12, y, bounds.w - 24, theme.weak, "{s} -> B{d}{s}", .{ @tagName(edge.kind), to, if (edge.assumed) " (assumed)" else "" }) else try label(r, font, bounds.x + 12, y, bounds.w - 24, theme.weak, "{s}: {s}", .{ @tagName(edge.kind), @tagName(edge.resolution) });
            y += 20;
        };
        for (graph.instructions[selected.first .. selected.first + selected.count]) |inst| {
            if (y + 20 > bounds.y + bounds.h) break;
            try label(r, font, bounds.x + 12, y, bounds.w - 24, theme.text, "{x}: {s} {s}", .{ inst.address, std.mem.sliceTo(&inst.mnemonic, 0), std.mem.sliceTo(&inst.operands, 0) });
            y += 20;
        }
    }
};
