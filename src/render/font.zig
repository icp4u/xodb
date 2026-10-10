const std = @import("std");
const c = @import("../c.zig").api;
pub const atlas_size = 1024;
pub const Glyph = struct { id: u32, x: u32, y: u32, w: u32, h: u32, left: i32, top: i32 };
pub const Font = struct {
    library: c.FT_Library = null,
    face: c.FT_Face = null,
    hb: ?*c.hb_font_t = null,
    buffer: ?*c.hb_buffer_t = null,
    pixels: [atlas_size * atlas_size]u8 = @splat(0),
    glyphs: [2048]Glyph = undefined,
    slots: [65536]u16 = @splat(0), // glyph id -> index + 1
    count: usize = 0,
    x: u32 = 2,
    y: u32 = 2,
    row_height: u32 = 0,
    dirty: bool = true,
    degraded: bool = false,
    pixel: bool = false,
    retro: bool = false,
    pub fn init(self: *Font, path: [:0]const u8) !void {
        return self.initMode(path, false);
    }
    /// Startup selection only. The original smooth path keeps its exact flags.
    pub fn initSelected(self: *Font, path: [:0]const u8, fallback: [:0]const u8) !void {
        const pixel = @import("../appearance.zig").active.font.pixel;
        self.initMode(path, pixel) catch |err| {
            std.debug.print("xodb: Font failed: {s}; using default font; {s}\n", .{ @errorName(err), path });
            self.* = .{};
            try self.initMode(fallback, pixel);
        };
    }
    pub fn initMode(self: *Font, path: [:0]const u8, pixel: bool) !void {
        self.pixel = pixel;
        if (c.FT_Init_FreeType(&self.library) != 0) return error.FontLibraryFailed;
        errdefer _ = c.FT_Done_FreeType(self.library);
        if (c.FT_New_Face(self.library, path.ptr, 0, &self.face) != 0) return error.FontNotFound;
        errdefer _ = c.FT_Done_Face(self.face);
        try self.prepare();
    }
    /// Embedded, freely redistributable bitmap face; independent of host fonts.
    pub fn initRetro(self: *Font) !void {
        const data = retro_bdf;
        self.pixel = true;
        self.retro = true;
        if (c.FT_Init_FreeType(&self.library) != 0) return error.FontLibraryFailed;
        errdefer _ = c.FT_Done_FreeType(self.library);
        if (c.FT_New_Memory_Face(self.library, data.ptr, data.len, 0, &self.face) != 0) return error.FontNotFound;
        errdefer _ = c.FT_Done_Face(self.face);
        try self.prepare();
    }
    /// Build the replacement before releasing the active atlas. Call between frames.
    pub fn selectOverview(self: *Font, gpa: std.mem.Allocator, path: [:0]const u8, retro: bool) !void {
        if (self.retro == retro) return;
        const next = try gpa.create(Font);
        defer gpa.destroy(next);
        next.* = .{};
        if (retro) try next.initRetro() else try next.initMode(path, false);
        self.deinit();
        self.* = next.*;
    }
    fn prepare(self: *Font) !void {
        if (c.FT_Set_Pixel_Sizes(self.face, 0, 16) != 0) return error.FontSizeFailed;
        self.hb = c.hb_ft_font_create_referenced(self.face) orelse return error.FontShapeFailed;
        errdefer c.hb_font_destroy(self.hb);
        if (self.pixel) c.hb_ft_font_set_load_flags(self.hb, c.FT_LOAD_TARGET_MONO | c.FT_LOAD_MONOCHROME);
        self.buffer = c.hb_buffer_create() orelse return error.FontShapeFailed;
        errdefer c.hb_buffer_destroy(self.buffer);
        self.pixels[0] = 255;
        // Reserve the missing-glyph box before source text can fill the cache.
        _ = try self.glyph(0);
    }
    pub fn deinit(self: *Font) void {
        c.hb_buffer_destroy(self.buffer);
        c.hb_font_destroy(self.hb);
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.library);
    }
    pub fn glyph(self: *Font, id: u32) !Glyph {
        if (id >= self.slots.len) return error.GlyphFailed;
        if (self.slots[id] != 0) return self.glyphs[self.slots[id] - 1];
        if (self.count == self.glyphs.len) return error.GlyphCacheFull;
        const flags: c_int = @as(c_int, c.FT_LOAD_RENDER) | (if (self.pixel) @as(c_int, c.FT_LOAD_TARGET_MONO | c.FT_LOAD_MONOCHROME) else @as(c_int, 0));
        if (c.FT_Load_Glyph(self.face, id, flags) != 0) return error.GlyphFailed;
        const slot = self.face.*.glyph.*;
        const bitmap = slot.bitmap;
        if (bitmap.width > 0 and bitmap.rows > 0 and (self.pixel or bitmap.pixel_mode != c.FT_PIXEL_MODE_GRAY) and bitmap.pixel_mode != c.FT_PIXEL_MODE_MONO) return error.FontBitmapUnsupported;
        if (bitmap.width + 3 >= atlas_size or bitmap.rows + 3 >= atlas_size) return error.GlyphAtlasFull;
        if (self.x + bitmap.width + 1 >= atlas_size) {
            self.x = 2;
            self.y += self.row_height + 1;
            self.row_height = 0;
        }
        if (self.y + bitmap.rows + 1 >= atlas_size) return error.GlyphAtlasFull;
        const g = Glyph{ .id = id, .x = self.x, .y = self.y, .w = bitmap.width, .h = bitmap.rows, .left = slot.bitmap_left, .top = slot.bitmap_top };
        for (0..bitmap.rows) |row| {
            const source_row = if (bitmap.pitch >= 0) row else bitmap.rows - 1 - row;
            const src = bitmap.buffer + source_row * @as(usize, @intCast(@abs(bitmap.pitch)));
            const start = (self.y + row) * atlas_size + self.x;
            if (bitmap.pixel_mode == c.FT_PIXEL_MODE_MONO) {
                for (0..bitmap.width) |col| self.pixels[start + col] = if (src[col / 8] & (@as(u8, 0x80) >> @as(u3, @intCast(col % 8))) != 0) 255 else 0;
            } else {
                @memcpy(self.pixels[start..][0..bitmap.width], src[0..bitmap.width]);
            }
        }
        self.x += bitmap.width + 1;
        self.row_height = @max(self.row_height, bitmap.rows);
        self.glyphs[self.count] = g;
        self.count += 1;
        self.slots[id] = @intCast(self.count);
        self.dirty = true;
        return g;
    }
};

/// Marks the overview draws that the upstream face lacks (tree twisties and the
/// check mark), in the same 8x16 cell. They are appended to the embedded BDF at
/// compile time, so shaping and the atlas treat them like any other glyph.
const retro_extra =
    \\STARTCHAR BLACK RIGHT-POINTING SMALL TRIANGLE
    \\ENCODING 9656
    \\SWIDTH 500 0
    \\DWIDTH 8 0
    \\BBX 8 16 0 -4
    \\BITMAP
    \\00
    \\00
    \\00
    \\00
    \\00
    \\20
    \\30
    \\38
    \\3C
    \\38
    \\30
    \\20
    \\00
    \\00
    \\00
    \\00
    \\ENDCHAR
    \\STARTCHAR BLACK DOWN-POINTING SMALL TRIANGLE
    \\ENCODING 9662
    \\SWIDTH 500 0
    \\DWIDTH 8 0
    \\BBX 8 16 0 -4
    \\BITMAP
    \\00
    \\00
    \\00
    \\00
    \\00
    \\00
    \\7C
    \\7C
    \\38
    \\38
    \\10
    \\00
    \\00
    \\00
    \\00
    \\00
    \\ENDCHAR
    \\STARTCHAR CHECK MARK
    \\ENCODING 10003
    \\SWIDTH 500 0
    \\DWIDTH 8 0
    \\BBX 8 16 0 -4
    \\BITMAP
    \\00
    \\00
    \\00
    \\00
    \\03
    \\06
    \\06
    \\0C
    \\CC
    \\78
    \\78
    \\30
    \\00
    \\00
    \\00
    \\00
    \\ENDCHAR
;
const retro_extra_count = 3;
const retro_bdf = blk: {
    @setEvalBranchQuota(200_000);
    const base = @embedFile("assets/spleen-8x16.bdf");
    const key = "\nCHARS ";
    const at = std.mem.indexOf(u8, base[0..4096], key).? + key.len;
    const eol = std.mem.indexOfScalarPos(u8, base, at, '\n').?;
    const end = std.mem.lastIndexOf(u8, base[base.len - 64 ..], "ENDFONT").? + base.len - 64;
    const total = (std.fmt.parseInt(u32, base[at..eol], 10) catch unreachable) + retro_extra_count;
    break :blk base[0..at] ++ std.fmt.comptimePrint("{d}", .{total}) ++ base[eol..end] ++ retro_extra ++ "\nENDFONT\n";
};

test "pixel glyph atlas has binary nonempty coverage" {
    const font = try std.testing.allocator.create(Font);
    defer std.testing.allocator.destroy(font);
    font.* = .{};
    try font.initMode(@import("build_options").font_path ++ "", true);
    defer font.deinit();
    for ("Aa@0123") |ch| _ = try font.glyph(c.FT_Get_Char_Index(font.face, ch));
    var ink: usize = 0;
    for (font.pixels) |value| {
        try std.testing.expect(value == 0 or value == 255);
        if (value == 255) ink += 1;
    }
    try std.testing.expect(ink > 1);
}

// Fast component lane: bundled glyphs and transactional switching.
test "bundled bitmap font switches atomically and restores the overview font" {
    const a = std.testing.allocator;
    const font = try a.create(Font);
    defer a.destroy(font);
    font.* = .{};
    try font.initRetro();
    defer font.deinit();
    for ("xodb 0123456789CPU") |ch| {
        const id = c.FT_Get_Char_Index(font.face, ch);
        try std.testing.expect(id != 0);
        _ = try font.glyph(id);
    }
    var ink: usize = 0;
    for (font.pixels) |value| {
        try std.testing.expect(value == 0 or value == 255);
        if (value == 255) ink += 1;
    }
    try std.testing.expect(ink > 100);
    const face = font.face;
    try std.testing.expectError(error.FontNotFound, font.selectOverview(a, "missing-overview-font", false));
    try std.testing.expect(font.face == face and font.retro);
    try font.selectOverview(a, @import("build_options").font_path ++ "", false);
    try std.testing.expect(!font.retro and !font.pixel);
    try font.selectOverview(a, "missing-overview-font", true);
    try std.testing.expect(font.retro and font.pixel and font.dirty);
}

// Non-ASCII marks in overview source that the bundled face must cover, so the
// classic skin never shows a missing-glyph box for its own labels.
test "bundled bitmap font covers every mark the overview source draws" {
    const a = std.testing.allocator;
    const font = try a.create(Font);
    defer a.destroy(font);
    font.* = .{};
    try font.initRetro();
    defer font.deinit();
    const sources = [_][]const u8{
        @embedFile("../ui/overview/actions.zig"),     @embedFile("../ui/overview/deepmap.zig"),
        @embedFile("../ui/overview/draw.zig"),        @embedFile("../ui/overview/files_model.zig"),
        @embedFile("../ui/overview/files_panel.zig"), @embedFile("../ui/overview/graph_model.zig"),
        @embedFile("../ui/overview/graph_panel.zig"), @embedFile("../ui/overview/history.zig"),
        @embedFile("../ui/overview/inheritance_panel.zig"), @embedFile("../ui/overview/memmap.zig"),
        @embedFile("../ui/overview/model.zig"),       @embedFile("../ui/overview/panels.zig"),
        @embedFile("../ui/overview/sysstat.zig"),     @embedFile("../ui/overview/theme.zig"),
        @embedFile("../ui/overview/treemap_model.zig"), @embedFile("../ui/overview/treemap_panel.zig"),
        @embedFile("../ui/overview/view.zig"),        @embedFile("../ui/overview/win95.zig"),
    };
    var seen: usize = 0;
    for (sources) |source| {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            // Comments are not drawn; a trailing one ends the scanned text.
            const code = line[0 .. std.mem.indexOf(u8, line, "//") orelse line.len];
            var it = std.unicode.Utf8View.initUnchecked(code).iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp < 0x80) continue;
                seen += 1;
                if (c.FT_Get_Char_Index(font.face, cp) == 0) {
                    std.debug.print("bundled font lacks U+{X:0>4} in: {s}\n", .{ cp, std.mem.trim(u8, line, " ") });
                    return error.MissingGlyph;
                }
            }
        }
    }
    try std.testing.expect(seen > 50);
    // The added marks have ink and stay inside the 8x16 cell.
    for ([_]u21{ 0x25B8, 0x25BE, 0x2713 }) |cp| {
        const g = try font.glyph(c.FT_Get_Char_Index(font.face, cp));
        try std.testing.expect(g.w > 0 and g.w <= 8 and g.h > 0 and g.h <= 16);
    }
}
