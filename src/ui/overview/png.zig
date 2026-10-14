//! A bounded PNG reader for small icons (the distro logo): 8-bit gray, RGB,
//! palette, gray+alpha and RGBA, not interlaced. Inflate is Zig's std.
const std = @import("std");

pub const max_side = 1024;
pub const max_file = 4 << 20;

pub const Image = struct {
    w: u32,
    h: u32,
    /// RGBA8, row-major.
    rgba: []u8,
    pub fn deinit(self: *Image, a: std.mem.Allocator) void {
        a.free(self.rgba);
        self.* = undefined;
    }
    pub fn at(self: *const Image, x: u32, y: u32) [4]u8 {
        const i = (@as(usize, y) * self.w + x) * 4;
        return self.rgba[i..][0..4].*;
    }
};

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

pub fn decode(a: std.mem.Allocator, file: []const u8) !Image {
    if (file.len > max_file or file.len < 8 or !std.mem.eql(u8, file[0..8], "\x89PNG\r\n\x1a\n")) return error.NotPng;
    var w: u32 = 0;
    var h: u32 = 0;
    var color: u8 = 0;
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(a);
    var at: usize = 8;
    while (at + 12 <= file.len) {
        const len = be32(file[at..]);
        if (len > file.len - at - 12) return error.PngTruncated;
        const kind = file[at + 4 ..][0..4];
        const data = file[at + 8 ..][0..len];
        at += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.PngHeader;
            w = be32(data);
            h = be32(data[4..]);
            color = data[9];
            // depth 8, deflate, adaptive filters, no interlace
            if (data[8] != 8 or data[10] != 0 or data[11] != 0 or data[12] != 0) return error.PngUnsupported;
            if (w == 0 or h == 0 or w > max_side or h > max_side) return error.PngSize;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            for (0..@min(256, len / 3)) |i| palette[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            if (color == 3) for (0..@min(256, len)) |i| {
                palette[i][3] = data[i];
            };
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(a, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (w == 0) return error.PngHeader;
    const channels: usize = switch (color) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.PngUnsupported,
    };
    const stride = w * channels;
    const raw = try a.alloc(u8, (stride + 1) * h);
    defer a.free(raw);
    var in: std.Io.Reader = .fixed(idat.items);
    var decompress: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    var out: std.Io.Writer = .fixed(raw);
    const got = decompress.reader.streamRemaining(&out) catch |err| switch (err) {
        error.WriteFailed => return error.PngTooLong,
        else => return error.PngInflate,
    };
    if (got != raw.len) return error.PngTruncated;
    // Unfilter in place, row by row.
    const bpp = channels;
    for (0..h) |y| {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        const up: ?[]const u8 = if (y > 0) raw[(y - 1) * (stride + 1) + 1 ..][0..stride] else null;
        const filter = raw[y * (stride + 1)];
        for (row, 0..) |*byte, i| {
            const left: u8 = if (i >= bpp) row[i - bpp] else 0;
            const above: u8 = if (up) |u| u[i] else 0;
            const corner: u8 = if (up != null and i >= bpp) up.?[i - bpp] else 0;
            byte.* +%= switch (filter) {
                0 => 0,
                1 => left,
                2 => above,
                3 => @intCast((@as(u16, left) + above) / 2),
                4 => paeth(left, above, corner),
                else => return error.PngFilter,
            };
        }
    }
    const rgba = try a.alloc(u8, @as(usize, w) * h * 4);
    errdefer a.free(rgba);
    for (0..h) |y| {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        for (0..w) |x| {
            const s = row[x * channels ..][0..channels];
            rgba[(y * w + x) * 4 ..][0..4].* = switch (color) {
                0 => .{ s[0], s[0], s[0], 255 },
                2 => .{ s[0], s[1], s[2], 255 },
                3 => palette[s[0]],
                4 => .{ s[0], s[0], s[0], s[1] },
                else => .{ s[0], s[1], s[2], s[3] },
            };
        }
    }
    return .{ .w = w, .h = h, .rgba = rgba };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

/// The mean colour of a `side`-square block of an image of `cols` x `rows` blocks.
pub fn block(img: *const Image, cols: u32, rows: u32, cx: u32, cy: u32) [4]u8 {
    const x0 = cx * img.w / cols;
    const x1 = @max(x0 + 1, (cx + 1) * img.w / cols);
    const y0 = cy * img.h / rows;
    const y1 = @max(y0 + 1, (cy + 1) * img.h / rows);
    var sum: [4]u64 = @splat(0);
    for (y0..y1) |y| for (x0..x1) |x| {
        const p = img.at(@intCast(x), @intCast(y));
        // Premultiply so transparent pixels do not darken edges.
        for (0..3) |k| sum[k] += @as(u64, p[k]) * p[3];
        sum[3] += p[3];
    };
    const n: u64 = (y1 - y0) * (x1 - x0);
    if (sum[3] == 0) return .{ 0, 0, 0, 0 };
    return .{ @intCast(sum[0] / sum[3]), @intCast(sum[1] / sum[3]), @intCast(sum[2] / sum[3]), @intCast(sum[3] / n) };
}

/// The logo's dominant colour: the hue bucket with the most saturated, opaque
/// coverage (grays, outlines and near-black are skipped), as its mean colour.
/// Null for a gray logo.
pub fn dominant(img: *const Image) ?[3]u8 {
    var weight: [512]u64 = @splat(0);
    var sum: [512][3]u64 = @splat(@splat(0));
    const step = @max(1, @max(img.w, img.h) / 256);
    var y: u32 = 0;
    while (y < img.h) : (y += step) {
        var x: u32 = 0;
        while (x < img.w) : (x += step) {
            const p = img.at(x, y);
            const hi = @max(p[0], p[1], p[2]);
            const chroma = hi - @min(p[0], p[1], p[2]);
            if (p[3] < 128 or hi < 48 or chroma < 40) continue;
            const k = @as(usize, p[0] >> 5) << 6 | @as(usize, p[1] >> 5) << 3 | p[2] >> 5;
            weight[k] += chroma;
            for (0..3) |i| sum[k][i] += @as(u64, p[i]) * chroma;
        }
    }
    const best = std.sort.argMax(u64, &weight, {}, std.sort.asc(u64)).?;
    if (weight[best] == 0) return null;
    return .{ @intCast(sum[best][0] / weight[best]), @intCast(sum[best][1] / weight[best]), @intCast(sum[best][2] / weight[best]) };
}

/// A test PNG with stored (uncompressed) deflate blocks.
pub fn encodeStored(a: std.mem.Allocator, w: u32, h: u32, rgba: []const u8, filter: u8) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    for (0..h) |y| {
        try raw.append(a, filter);
        const row = rgba[y * w * 4 ..][0 .. w * 4];
        for (row, 0..) |byte, i| try raw.append(a, if (filter == 1 and i >= 4) byte -% row[i - 4] else byte);
    }
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(a);
    try z.appendSlice(a, &.{ 0x78, 0x01, 0x01 });
    const n: u16 = @intCast(raw.items.len);
    try z.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, n)));
    try z.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~n)));
    try z.appendSlice(a, raw.items);
    try z.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw.items))));
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    for ([_]struct { []const u8, []const u8 }{ .{ "IHDR", &ihdr }, .{ "IDAT", z.items }, .{ "IEND", "" } }) |chunk| {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(chunk[1].len), .big);
        try out.appendSlice(a, &len);
        try out.appendSlice(a, chunk[0]);
        try out.appendSlice(a, chunk[1]);
        try out.appendSlice(a, &.{ 0, 0, 0, 0 }); // CRC is not checked
    }
    return out.toOwnedSlice(a);
}

test "png decodes RGBA with sub filter and rejects bad input" {
    const a = std.testing.allocator;
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 40 };
    for ([_]u8{ 0, 1 }) |filter| {
        const file = try encodeStored(a, 2, 2, &pixels, filter);
        defer a.free(file);
        var img = try decode(a, file);
        defer img.deinit(a);
        try std.testing.expectEqual(@as(u32, 2), img.w);
        try std.testing.expectEqualSlices(u8, &pixels, img.rgba);
        try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, block(&img, 2, 2, 0, 0));
        try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, block(&img, 2, 2, 0, 1));
    }
    var gray = Image{ .w = 1, .h = 1, .rgba = @constCast(&[_]u8{ 128, 128, 128, 255 }) };
    try std.testing.expect(dominant(&gray) == null);
    var logo = Image{ .w = 2, .h = 2, .rgba = @constCast(&[_]u8{ 250, 10, 10, 255, 0, 0, 0, 255, 240, 0, 20, 255, 0, 200, 0, 255 }) };
    try std.testing.expectEqual([3]u8{ 245, 5, 15 }, dominant(&logo).?);
    try std.testing.expectError(error.NotPng, decode(a, "GIF89a.."));
    const file = try encodeStored(a, 2, 2, &pixels, 0);
    defer a.free(file);
    try std.testing.expectError(error.PngTruncated, decode(a, file[0 .. file.len - 20]));
}
