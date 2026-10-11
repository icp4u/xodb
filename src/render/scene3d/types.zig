//! GPU instance records. Capacities are ceilings; buffers grow on demand.
const math = @import("math.zig");
pub const max_instances = 262144;
pub const max_glyphs = 16384;
pub const Box = extern struct { center: [3]f32, emission: f32 = 0, half: [3]f32, wire_only: f32 = 0, color: [4]f32 };
pub const Point = extern struct { position: [3]f32, pixels: f32, color: [4]f32 };
pub const Line = extern struct { a: [3]f32, pad: f32 = 0, b: [3]f32, emission: f32 = 0, color: [4]f32 };
pub const Glyph = extern struct { anchor: [4]f32, rect: [4]f32, uv: [4]f32, color: [4]f32 };
pub const Push = extern struct { view_projection: math.Mat4, viewport: [2]f32, mode: f32 = 0, exposure: f32 = 1 };
comptime {
    if (@sizeOf(Box) != 48 or @sizeOf(Point) != 32 or @sizeOf(Line) != 48 or @sizeOf(Glyph) != 64 or @sizeOf(Push) != 80)
        @compileError("scene instance or push layout drift");
}
