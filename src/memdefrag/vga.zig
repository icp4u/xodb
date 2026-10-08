//! VGA text-mode constants for the DOS DEFRAG look, in one place so a later
//! VGA geometry pass can adjust them: the canonical 16-colour palette, the
//! 80x25 grid of 9x16 character cells, the display aspect and blink rate,
//! and which glyph and colours draw each cell state.
const std = @import("std");
const model = @import("model.zig");

pub const palette = [16]u24{
    0x000000, 0x0000aa, 0x00aa00, 0x00aaaa, 0xaa0000, 0xaa00aa, 0xaa5500, 0xaaaaaa,
    0x555555, 0x5555ff, 0x55ff55, 0x55ffff, 0xff5555, 0xff55ff, 0xffff55, 0xffffff,
};
pub const black: u4 = 0;
pub const blue: u4 = 1;
pub const green: u4 = 2;
pub const cyan: u4 = 3;
pub const red: u4 = 4;
pub const magenta: u4 = 5;
pub const brown: u4 = 6;
pub const light_grey: u4 = 7;
pub const dark_grey: u4 = 8;
pub const light_blue: u4 = 9;
pub const light_green: u4 = 10;
pub const light_cyan: u4 = 11;
pub const light_red: u4 = 12;
pub const light_magenta: u4 = 13;
pub const yellow: u4 = 14;
pub const white: u4 = 15;

pub const cols = 80;
pub const rows = 25;
/// One character cell of 720x400 text mode.
pub const cell_w: f32 = 9;
pub const cell_h: f32 = 16;
/// 720x400 was shown on a 4:3 tube, so pixels were taller than wide. The
/// GUI keeps square pixels by default (1.0); set 1.35 for tube proportions.
pub const pixel_aspect: f32 = 1.0;
/// Attribute blink: 16 frames on, 16 off at 70 Hz.
pub const blink_half_ns: u64 = 228_571_429;

pub fn rgb(index: u4) [4]f32 {
    const v = palette[index];
    return .{ @as(f32, @floatFromInt(v >> 16)) / 255, @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255, @as(f32, @floatFromInt(v & 0xff)) / 255, 1 };
}
/// ANSI SGR colour number (0-7) and brightness of a VGA index: VGA orders
/// bits blue, green, red; ANSI orders red, green, blue.
pub fn ansi(index: u4) struct { n: u8, bright: bool } {
    const low: u8 = index & 7;
    return .{ .n = ((low & 1) << 2) | (low & 2) | ((low & 4) >> 2), .bright = index & 8 != 0 };
}

pub const Glyph = struct { ch: u21, fg: u4, bg: u4 = blue, blink: bool = false };

/// The map glyph of one cell. Unknown is a grey hatch, never a state.
pub fn glyph(look: model.Look, write_like: bool) Glyph {
    var g: Glyph = switch (look.state) {
        .unmapped => .{ .ch = '░', .fg = black },
        .gap => .{ .ch = '≈', .fg = dark_grey },
        .reserved => .{ .ch = '≈', .fg = light_blue },
        .unknown => .{ .ch = '▒', .fg = dark_grey, .bg = light_grey },
        .not_present => .{ .ch = '░', .fg = light_blue },
        .swapped => .{ .ch = '▓', .fg = light_grey },
        .file => .{ .ch = '▓', .fg = yellow },
        .anon => .{ .ch = '▓', .fg = cyan },
        .mixed => .{ .ch = '▓', .fg = light_cyan },
        .thp => .{ .ch = '█', .fg = light_cyan },
        .unmovable => .{ .ch = '■', .fg = light_red },
        .free_contig => .{ .ch = '█', .fg = light_cyan },
        .free_frag => .{ .ch = '░', .fg = light_cyan },
        .zero => .{ .ch = '░', .fg = white },
    };
    if (look.partial and look.state != .unknown) g.bg = dark_grey;
    switch (look.change) {
        .none => {},
        .changed => g = .{ .ch = if (write_like) 'W' else 'r', .fg = white, .bg = green, .blink = true },
        .collapsed => g = .{ .ch = '█', .fg = white, .bg = g.bg },
        .split => g = .{ .ch = '▓', .fg = light_red, .bg = red },
    }
    return g;
}

test "VGA palette is the canonical sixteen and ANSI order swaps red and blue" {
    try std.testing.expectEqual(@as(u24, 0x0000aa), palette[blue]);
    try std.testing.expectEqual(@as(u24, 0xaa5500), palette[brown]);
    try std.testing.expectEqual(@as(u8, 4), ansi(blue).n);
    try std.testing.expectEqual(@as(u8, 1), ansi(red).n);
    try std.testing.expect(ansi(yellow).bright and ansi(yellow).n == 3);
    // Every state and change draws something distinct from unknown.
    const unknown = glyph(.{ .state = .unknown }, false);
    inline for (@typeInfo(model.State).@"enum".fields) |f| {
        const s: model.State = @enumFromInt(f.value);
        if (s != .unknown) try std.testing.expect(!std.meta.eql(glyph(.{ .state = s }, false), unknown));
    }
    const changed = glyph(.{ .state = .thp, .change = .changed }, true);
    const collapsed = glyph(.{ .state = .thp, .change = .collapsed }, false);
    const split = glyph(.{ .state = .anon, .change = .split }, false);
    try std.testing.expect(changed.ch == 'W' and changed.blink);
    try std.testing.expect(!std.meta.eql(collapsed, split) and !std.meta.eql(collapsed, glyph(.{ .state = .thp }, false)));
}
