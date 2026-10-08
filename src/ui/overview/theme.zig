//! Overview palettes. The overview owns its colors so `t` can cycle them
//! without touching the debugger's startup theme (see docs/THEMES.md).
const std = @import("std");
const Color = [4]f32;
const rgb = @import("../../appearance.zig").rgb;

pub const Palette = struct {
    name: []const u8,
    background: Color,
    panel: Color,
    raised: Color,
    grid: Color,
    border: Color,
    text: Color,
    dim: Color,
    /// Primary and secondary series (read/write, rx/tx, user/system).
    accent: Color,
    accent2: Color,
    accent3: Color,
    ok: Color,
    warn: Color,
    crit: Color,
    /// Unavailable hatching and its text.
    hatch: Color,
    selection: Color,
    /// Phosphor treatment: halo around traces and headline digits, scanline
    /// strength and vignette. Zero for flat themes.
    glow: f32 = 0,
    scanlines: f32 = 0,
    vignette: f32 = 0,
    /// Unlit segments of VFD digits.
    ghost: f32 = 0.07,
    /// True when hue carries no meaning: series differ by brightness and fill.
    monochrome: bool = false,
};

fn shade(hex: u24, alpha: f32) Color {
    var c = rgb(hex);
    c[3] = alpha;
    return c;
}

pub const all = [_]Palette{
    .{
        .name = "dark",
        .background = rgb(0x080b10),
        .panel = rgb(0x0e131b),
        .raised = rgb(0x151c27),
        .grid = shade(0x8aa4c8, 0.08),
        .border = rgb(0x222c3a),
        .text = rgb(0xd5deea),
        .dim = rgb(0x7f91a8),
        .accent = rgb(0x4cc2ff),
        .accent2 = rgb(0xff9f43),
        .accent3 = rgb(0xb48ef0),
        .ok = rgb(0x6fdc9a),
        .warn = rgb(0xf5c45e),
        .crit = rgb(0xff6b5e),
        .hatch = rgb(0x5a6678),
        .selection = shade(0x4cc2ff, 0.16),
        .glow = 0.35,
        .vignette = 0.25,
    },
    .{
        .name = "light",
        .background = rgb(0xe8edf3),
        .panel = rgb(0xfbfcfe),
        .raised = rgb(0xf0f3f8),
        .grid = shade(0x2a3a52, 0.09),
        .border = rgb(0xc3ccd8),
        .text = rgb(0x152234),
        .dim = rgb(0x4d5e73),
        .accent = rgb(0x0a60a8),
        .accent2 = rgb(0xb85a00),
        .accent3 = rgb(0x6c3fb0),
        .ok = rgb(0x17733f),
        .warn = rgb(0x8a5a00),
        .crit = rgb(0xb3261e),
        .hatch = rgb(0x8d99aa),
        .selection = shade(0x0b6fc2, 0.13),
        .ghost = 0.05,
    },
    .{
        .name = "green",
        .background = rgb(0x010802),
        .panel = rgb(0x031105),
        .raised = rgb(0x05190a),
        .grid = shade(0x33ff66, 0.07),
        .border = rgb(0x0e3a19),
        .text = rgb(0x5cff8a),
        .dim = rgb(0x2a9c4c),
        .accent = rgb(0x66ff99),
        .accent2 = rgb(0x2fbf5f),
        .accent3 = rgb(0xb8ffcc),
        .ok = rgb(0x66ff99),
        .warn = rgb(0xd8ff8a),
        .crit = rgb(0xffffff),
        .hatch = rgb(0x1f6b35),
        .selection = shade(0x33ff66, 0.14),
        .glow = 1,
        .scanlines = 0.12,
        .vignette = 0.55,
        .ghost = 0.09,
        .monochrome = true,
    },
    .{
        .name = "amber",
        .background = rgb(0x0a0500),
        .panel = rgb(0x140a01),
        .raised = rgb(0x1d0f02),
        .grid = shade(0xffb000, 0.07),
        .border = rgb(0x3d2304),
        .text = rgb(0xffb43c),
        .dim = rgb(0xbf7d1a),
        .accent = rgb(0xffc04d),
        .accent2 = rgb(0xc77d10),
        .accent3 = rgb(0xffe0a0),
        .ok = rgb(0xffc04d),
        .warn = rgb(0xffe0a0),
        .crit = rgb(0xffffff),
        .hatch = rgb(0x6b440c),
        .selection = shade(0xffb000, 0.14),
        .glow = 1,
        .scanlines = 0.12,
        .vignette = 0.55,
        .ghost = 0.09,
        .monochrome = true,
    },
    .{
        .name = "blue",
        .background = rgb(0x00060c),
        .panel = rgb(0x020d18),
        .raised = rgb(0x041424),
        .grid = shade(0x4fd2ff, 0.07),
        .border = rgb(0x0b3150),
        .text = rgb(0x7fe0ff),
        .dim = rgb(0x2f86b0),
        .accent = rgb(0x8ae8ff),
        .accent2 = rgb(0x3aa3d6),
        .accent3 = rgb(0xd0f6ff),
        .ok = rgb(0x8ae8ff),
        .warn = rgb(0xd0f6ff),
        .crit = rgb(0xffffff),
        .hatch = rgb(0x1b5878),
        .selection = shade(0x4fd2ff, 0.14),
        .glow = 1,
        .scanlines = 0.10,
        .vignette = 0.5,
        .ghost = 0.09,
        .monochrome = true,
    },
    .{
        .name = "mono",
        .background = rgb(0x000000),
        .panel = rgb(0x0b0b0b),
        .raised = rgb(0x161616),
        .grid = shade(0xffffff, 0.08),
        .border = rgb(0x3a3a3a),
        .text = rgb(0xf2f2f2),
        .dim = rgb(0xa0a0a0),
        .accent = rgb(0xffffff),
        .accent2 = rgb(0x9a9a9a),
        .accent3 = rgb(0xd0d0d0),
        .ok = rgb(0xffffff),
        .warn = rgb(0xffffff),
        .crit = rgb(0xffffff),
        .hatch = rgb(0x5a5a5a),
        .selection = shade(0xffffff, 0.12),
        .ghost = 0.06,
        .monochrome = true,
    },
};

/// Accepts the overview names, `builtin:NAME`, and the debugger's built-in
/// names that have an obvious counterpart (contrast and vga map to mono and blue).
pub fn find(selection: []const u8) ?usize {
    const name = if (std.mem.startsWith(u8, selection, "builtin:")) selection["builtin:".len..] else selection;
    for (all, 0..) |palette, i| if (std.mem.eql(u8, palette.name, name)) return i;
    if (std.mem.eql(u8, name, "contrast")) return 5;
    if (std.mem.eql(u8, name, "vga")) return 4;
    if (std.mem.eql(u8, name, "phosphor")) return 2;
    return null;
}

fn luminance(value: Color) f32 {
    var linear: [3]f32 = undefined;
    for (&linear, value[0..3]) |*out, channel| out.* = if (channel <= 0.04045) channel / 12.92 else std.math.pow(f32, (channel + 0.055) / 1.055, 2.4);
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
}
pub fn contrast(a: Color, b: Color) f32 {
    const x = luminance(a);
    const y = luminance(b);
    return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
}

test "overview palettes keep text and dim labels legible on every surface" {
    for (all) |p| {
        for ([_]Color{ p.background, p.panel, p.raised }) |bg| {
            try std.testing.expect(contrast(p.text, bg) >= 7);
            try std.testing.expect(contrast(p.dim, bg) >= 4.5);
            try std.testing.expect(contrast(p.accent, bg) >= 4.5);
            try std.testing.expect(contrast(p.hatch, bg) >= 2);
        }
    }
    try std.testing.expectEqual(@as(?usize, 2), find("builtin:green"));
    try std.testing.expectEqual(@as(?usize, 0), find("dark"));
    try std.testing.expectEqual(@as(?usize, null), find("builtin:nope"));
}
