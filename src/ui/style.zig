//! Visual vocabulary for the workspace: theme colors, animation, and drawn widgets.
//!
//! The semantic color slots and several treatments (drop shadow, hover lift, pressed
//! inset, focus overlay, thread line and glow, breakpoint dot, state-colored status
//! bar, row striping, scroll fade) are adapted from RAD Debugger (MIT license,
//! EpicGamesExt/raddebugger at 2933143b). No code was copied; constants are cited
//! where they come from that source.

const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;

pub const rgb = @import("../appearance.zig").rgb;
pub fn fade(color: gpu.Color, alpha: f32) gpu.Color {
    return .{ color[0], color[1], color[2], color[3] * alpha };
}
pub fn mix(a: gpu.Color, b: gpu.Color, t: f32) gpu.Color {
    var out: gpu.Color = undefined;
    for (&out, a, b) |*channel, from, to| channel.* = from + (to - from) * t;
    return out;
}

const appearance = @import("../appearance.zig");
pub const theme = &appearance.active.colors;

/// Thread identities keep the same palette index in every view.
pub fn threadColor(id: u64) gpu.Color {
    return appearance.active.threads[(id -| 1) % appearance.active.thread_count];
}

/// Moves `value` toward `target` by a fraction that depends only on elapsed time.
/// `halvings` is how many times per second the remaining distance halves (RAD Debugger
/// uses 60 for hover and press, 30 to 50 for slower fades). Returns true while moving.
pub fn approach(value: *f32, target: f32, halvings: f32, dt: f32) bool {
    value.* += (target - value.*) * (1 - std.math.pow(f32, 2, -halvings * dt));
    if (@abs(target - value.*) > 0.004) return true;
    value.* = target;
    return false;
}

/// Soft shadow behind a box: grown 8px, shifted (4, 4), softness 8 (raddbg_core.c:9539-9540).
pub fn shadow(r: *gpu.Renderer, rect: gpu.Rect, radius: f32, strength: f32) !void {
    try r.shape(.{ .x = rect.x - 4, .y = rect.y - 4, .w = rect.w + 16, .h = rect.h + 16 }, fade(theme.shadow, strength), .{ .radii = @splat(radius + 4), .softness = 8 });
}

/// Filled box with a one-pixel border.
pub fn box(r: *gpu.Renderer, rect: gpu.Rect, fill: gpu.Color, edge: gpu.Color, radii: [4]f32) !void {
    try r.shape(rect, fill, .{ .radii = radii });
    try r.shape(rect, edge, .{ .radii = radii, .border = 1 });
}

/// Selection: translucent focus overlay plus a focus-colored border, scaled by `t`
/// (overlay alpha 0x14/255 as in RAD Debugger's `focus overlay`).
pub fn focus(r: *gpu.Renderer, rect: gpu.Rect, radius: f32, t: f32) !void {
    try r.shape(rect, fade(theme.focus, 0.11 * t), .{ .radii = @splat(radius) });
    try r.shape(rect, fade(theme.focus, 0.75 * t), .{ .radii = @splat(radius), .border = 1 });
}

/// Small rounded label for a key binding; returns its width.
pub fn chip(r: *gpu.Renderer, font: *Font, x: f32, y: f32, label: []const u8, color: gpu.Color) !f32 {
    const w = r.measure(font, label) + 12;
    try box(r, .{ .x = x, .y = y, .w = w, .h = 21 }, theme.chip_fill, theme.chip_border, @splat(8));
    try r.text(font, x + 6, y + 1, label, color);
    return w;
}

/// Toolbar button. `hot` and `active` are animated 0..1 values for hover and press.
/// Hover lifts the button on a shadow and brightens it; press sinks it with an inset
/// shade at the top and a faint highlight at the bottom (raddbg_core.c:9574-9672).
pub fn button(r: *gpu.Renderer, font: *Font, rect: gpu.Rect, label: []const u8, key: []const u8, color: gpu.Color, hot: f32, active: f32) !void {
    const radii: [4]f32 = @splat(rect.h / 2);
    if (hot > 0.01) try shadow(r, rect, rect.h / 2, 0.7 * hot * (1 - active));
    try box(r, rect, mix(theme.header, theme.highlight, 0.035 + 0.05 * hot), mix(theme.border, color, 0.25 + 0.45 * hot), radii);
    if (active > 0.01) {
        const depth = @min(rect.h * 0.6 * active, 16);
        const dark = fade(theme.shadow, active);
        try r.shape(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = depth + rect.h / 2 }, dark, .{ .radii = radii, .colors = .{ dark, dark, fade(dark, 0), fade(dark, 0) } });
        const light = fade(theme.highlight, 0.08 * active);
        try r.shape(.{ .x = rect.x, .y = rect.y + rect.h - depth, .w = rect.w, .h = depth }, light, .{ .radii = radii, .colors = .{ fade(light, 0), fade(light, 0), light, light } });
    }
    const key_width = r.measure(font, key) + 12;
    try r.textFit(font, rect.x + 13, rect.y + 5 + active, rect.w - key_width - 21, label, color);
    _ = try chip(r, font, rect.x + rect.w - key_width - 6, rect.y + 4 + active, key, theme.weak);
}

/// Marks a line as a thread's next instruction: a thin line in the thread's color that
/// shoots out along the top of the row as `alive` goes 0..1, over a faint glow that
/// fades to the right (raddbg_widgets.c:1150-1201: 0.25em line, 22em glow at alpha 0.1).
pub fn threadLine(r: *gpu.Renderer, row: gpu.Rect, color: gpu.Color, alive: f32, em: f32) !void {
    const none = fade(color, 0);
    const glow = fade(color, 0.16);
    try r.shape(.{ .x = row.x, .y = row.y, .w = @min(row.w, em * 30 * alive), .h = row.h }, glow, .{ .colors = .{ glow, none, glow, none } });
    try r.shape(.{ .x = row.x, .y = row.y - 1, .w = @min(row.w, em * 260 * alive), .h = 2 }, color, .{ .colors = .{ color, none, color, none } });
}

/// Filled disc, used for breakpoints (solid) and the hover preview (ghost).
pub fn disc(r: *gpu.Renderer, cx: f32, cy: f32, radius: f32, color: gpu.Color) !void {
    try r.shape(.{ .x = cx - radius - 1, .y = cy - radius - 1, .w = radius * 2 + 2, .h = radius * 2 + 2 }, color, .{ .radii = @splat(radius) });
}

/// Darkens the bottom of a scrollable area that has more content below it.
pub fn fadeBottom(r: *gpu.Renderer, rect: gpu.Rect, strength: f32) !void {
    const h = @max(18, rect.h * 0.05);
    const dark = fade(theme.shadow, strength);
    try r.shape(.{ .x = rect.x, .y = rect.y + rect.h - h, .w = rect.w, .h = h }, dark, .{ .colors = .{ fade(dark, 0), fade(dark, 0), dark, dark } });
}
