//! Camera and picking math. Geometry projection belongs to the vertex shader.
//! Matrices are column-major; perspective uses Vulkan depth [0,1] and Y down.
const std = @import("std");
pub const Vec3 = [3]f32;
pub const Vec4 = [4]f32;
pub const Mat4 = [16]f32;
pub fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
pub fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
pub fn scale(a: Vec3, s: f32) Vec3 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}
pub fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
pub fn normalized(v: Vec3) ?Vec3 {
    const n = dot(v, v);
    if (!std.math.isFinite(n) or n < 1e-12) return null;
    return scale(v, 1 / @sqrt(n));
}
pub fn identity() Mat4 {
    return .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
}
pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = @splat(0);
    for (0..4) |col| for (0..4) |row| {
        for (0..4) |k| out[col * 4 + row] += a[k * 4 + row] * b[col * 4 + k];
    };
    return out;
}
pub fn transform(m: Mat4, p: Vec4) Vec4 {
    var out: Vec4 = @splat(0);
    for (0..4) |row| for (0..4) |col| {
        out[row] += m[col * 4 + row] * p[col];
    };
    return out;
}
pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) ?Mat4 {
    const f = normalized(sub(target, eye)) orelse return null;
    const r = normalized(cross(f, up)) orelse return null;
    const u = cross(r, f);
    return .{ r[0], u[0], -f[0], 0, r[1], u[1], -f[1], 0, r[2], u[2], -f[2], 0, -dot(r, eye), -dot(u, eye), dot(f, eye), 1 };
}
pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) ?Mat4 {
    for ([_]f32{ fovy, aspect, near, far }) |v| if (!std.math.isFinite(v)) return null;
    if (fovy <= 0 or fovy >= std.math.pi or aspect <= 0 or near <= 0 or far <= near) return null;
    const f = 1 / @tan(fovy / 2);
    const result: Mat4 = .{ f / aspect, 0, 0, 0, 0, -f, 0, 0, 0, 0, far / (near - far), -1, 0, 0, far * near / (near - far), 0 };
    for (result) |v| if (!std.math.isFinite(v)) return null;
    return result;
}
pub fn inverse(m: Mat4) ?Mat4 {
    var rows: [4][8]f32 = undefined;
    for (0..4) |r| for (0..4) |c| {
        const v = m[c * 4 + r];
        if (!std.math.isFinite(v)) return null;
        rows[r][c] = v;
        rows[r][c + 4] = if (r == c) 1 else 0;
    };
    for (0..4) |col| {
        var pivot = col;
        for (col + 1..4) |r| if (@abs(rows[r][col]) > @abs(rows[pivot][col])) {
            pivot = r;
        };
        if (@abs(rows[pivot][col]) < 1e-9) return null;
        std.mem.swap([8]f32, &rows[col], &rows[pivot]);
        const divisor = rows[col][col];
        for (&rows[col]) |*v| v.* /= divisor;
        for (0..4) |r| {
            if (r == col) continue;
            const factor = rows[r][col];
            for (0..8) |k| rows[r][k] -= factor * rows[col][k];
        }
    }
    var out: Mat4 = undefined;
    for (0..4) |r| for (0..4) |c| {
        const v = rows[r][c + 4];
        if (!std.math.isFinite(v)) return null;
        out[c * 4 + r] = v;
    };
    return out;
}
pub const Ray = struct {
    origin: Vec3,
    direction: Vec3,
    pub fn box(self: Ray, minimum: Vec3, maximum: Vec3) ?f32 {
        const length2 = dot(self.direction, self.direction);
        if (!std.math.isFinite(length2) or length2 < 1e-12) return null;
        var first: f32 = 0;
        var last: f32 = std.math.inf(f32);
        for (0..3) |i| {
            if (!std.math.isFinite(self.origin[i]) or !std.math.isFinite(minimum[i]) or !std.math.isFinite(maximum[i]) or minimum[i] > maximum[i]) return null;
            if (@abs(self.direction[i]) < 1e-8) {
                if (self.origin[i] < minimum[i] or self.origin[i] > maximum[i]) return null;
            } else {
                const a = (minimum[i] - self.origin[i]) / self.direction[i];
                const b = (maximum[i] - self.origin[i]) / self.direction[i];
                first = @max(first, @min(a, b));
                last = @min(last, @max(a, b));
                if (last < first) return null;
            }
        }
        return first;
    }
};
/// x/y are normalized panel coordinates in [-1,1], with y increasing downward.
pub fn ray(inv_view_projection: Mat4, x: f32, y: f32) ?Ray {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
    const a = transform(inv_view_projection, .{ x, y, 0, 1 });
    const b = transform(inv_view_projection, .{ x, y, 1, 1 });
    if (@abs(a[3]) < 1e-9 or @abs(b[3]) < 1e-9) return null;
    const origin: Vec3 = .{ a[0] / a[3], a[1] / a[3], a[2] / a[3] };
    const end: Vec3 = .{ b[0] / b[3], b[1] / b[3], b[2] / b[3] };
    return .{ .origin = origin, .direction = normalized(sub(end, origin)) orelse return null };
}

test "Vulkan camera depth, inverse and ray agree" {
    const projection = perspective(std.math.pi / 2.0, 2, 0.1, 100).?;
    const near = transform(projection, .{ 0, 0, -0.1, 1 });
    const far = transform(projection, .{ 0, 0, -100, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), near[2] / near[3], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), far[2] / far[3], 1e-5);
    const vp = mul(projection, lookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }).?);
    const inv = inverse(vp).?;
    const product = mul(vp, inv);
    for (product, identity()) |actual, expected| try std.testing.expectApproxEqAbs(expected, actual, 1e-4);
    const center = ray(inv, 0, 0).?;
    try std.testing.expectApproxEqAbs(@as(f32, 4.9), center.origin[2], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -1), center.direction[2], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 3.9), center.box(.{ -1, -1, -1 }, .{ 1, 1, 1 }).?, 1e-4);
    try std.testing.expect(ray(inv, 0, -0.5).?.direction[1] > 0);
    try std.testing.expect(center.box(.{ 2, -1, -1 }, .{ 3, 1, 1 }) == null);
}
test "degenerate cameras and singular matrices refuse" {
    try std.testing.expect(lookAt(.{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }) == null);
    try std.testing.expect(lookAt(.{ 0, 0, 1 }, .{ 0, 0, 0 }, .{ 0, 0, 1 }) == null);
    try std.testing.expect(perspective(1, 0, 0.1, 10) == null);
    try std.testing.expect(perspective(1e-40, 1, 0.1, 10) == null);
    try std.testing.expect(inverse(@splat(0)) == null);
    try std.testing.expect(ray(identity(), std.math.nan(f32), 0) == null);
}
