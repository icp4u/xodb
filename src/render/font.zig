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
    pub fn init(self: *Font, path: [:0]const u8) !void {
        if (c.FT_Init_FreeType(&self.library) != 0) return error.FontLibraryFailed;
        errdefer _ = c.FT_Done_FreeType(self.library);
        if (c.FT_New_Face(self.library, path.ptr, 0, &self.face) != 0) return error.FontNotFound;
        errdefer _ = c.FT_Done_Face(self.face);
        if (c.FT_Set_Pixel_Sizes(self.face, 0, 16) != 0) return error.FontSizeFailed;
        self.hb = c.hb_ft_font_create_referenced(self.face) orelse return error.FontShapeFailed;
        self.buffer = c.hb_buffer_create() orelse return error.FontShapeFailed;
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
        if (c.FT_Load_Glyph(self.face, id, c.FT_LOAD_RENDER) != 0) return error.GlyphFailed;
        const slot = self.face.*.glyph.*;
        const bitmap = slot.bitmap;
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
            @memcpy(self.pixels[start..][0..bitmap.width], src[0..bitmap.width]);
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
