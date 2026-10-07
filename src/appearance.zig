//! Startup-only themes. Parsing returns owned colors for all GUI views.
const std = @import("std");
const c = @import("c.zig").api;
pub const Color = [4]f32;
pub const max_bytes = 64 * 1024;
pub fn rgb(hex: u24) Color {
    return .{ @as(f32, @floatFromInt(hex >> 16)) / 255, @as(f32, @floatFromInt((hex >> 8) & 0xff)) / 255, @as(f32, @floatFromInt(hex & 0xff)) / 255, 1 };
}
pub const Colors = struct {
    // Preserve xodb's original palette. RAD-derived roles retain the attribution
    // in ui/style.zig (RAD Debugger 2933143b, raddbg.mdesk:1616-1685, MIT).
    background: Color = rgb(0x0a0d12),
    surface: Color = rgb(0x0f131a),
    header: Color = rgb(0x151b25),
    border: Color = rgb(0x232d3b),
    text: Color = rgb(0xc9d4e3),
    weak: Color = rgb(0x6e829c),
    good: Color = rgb(0x7ad4a3),
    neutral: Color = rgb(0x7ab0f0),
    warm: Color = rgb(0xf5b36e),
    focus: Color = rgb(0x2392eb),
    thread_main: Color = rgb(0xebb624),
    thread_other: Color = rgb(0x26d0d2),
    breakpoint: Color = rgb(0xe0452c),
    shadow: Color = .{ 0, 0, 0, 0.5 },
    pop: Color = rgb(0x675331),
    good_pop: Color = rgb(0x2c5b36),
    bad_pop: Color = rgb(0x803425),
    fresh: Color = rgb(0x3d3631),
    stripe: Color = .{ 1, 1, 1, 0.022 },
    overlay: Color = .{ 0, 0, 0, 0.65 },
    highlight: Color = .{ 1, 1, 1, 1 },
    chip_fill: Color = .{ 1, 1, 1, 0.04 },
    chip_border: Color = .{ 1, 1, 1, 0.10 },
    status_border: Color = .{ 1, 1, 1, 0.06 },
    flame_low: Color = .{ 0.63, 0.25, 0.16, 1 },
    flame_high: Color = .{ 0.86, 0.49, 0.23, 1 },
    flame_root: Color = .{ 0.22, 0.34, 0.46, 1 },
    flame_unknown: Color = .{ 0.32, 0.33, 0.37, 1 },
    flame_import_unknown: Color = .{ 0.33, 0.35, 0.40, 1 },
    flame_text: Color = .{ 1, 0.95, 0.88, 1 },
};
pub const Theme = struct {
    font: struct { pixel: bool = false } = .{},
    block_selection: bool = false,
    colors: Colors = .{},
    threads: [16]Color = .{ rgb(0xebb624), rgb(0x26d0d2), rgb(0xb48ef0), rgb(0xf078b4), rgb(0xa4d65e), rgb(0xf59a52), rgb(0x5eb5f7), rgb(0x5ee0b0) } ++ .{rgb(0x26d0d2)} ** 8,
    thread_count: usize = 8,
    id: [65]u8 = @splat(0),
    pub fn name(self: *const Theme) []const u8 {
        return std.mem.sliceTo(&self.id, 0);
    }
};
pub const Diagnostic = struct {
    path: [160]u8 = @splat(0),
    fn field(self: *Diagnostic, section: []const u8, key: []const u8) void {
        @memset(&self.path, 0);
        _ = std.fmt.bufPrint(self.path[0 .. self.path.len - 1], "{s}{s}{s}", .{ section, if (section.len > 0 and key.len > 0) "." else "", key }) catch {};
    }
    pub fn text(self: *const Diagnostic) []const u8 {
        return std.mem.sliceTo(&self.path, 0);
    }
};
pub fn builtin(name: []const u8) !Theme {
    var theme = Theme{};
    if (std.mem.eql(u8, name, "builtin:light")) {
        theme.colors = .{
            .background = rgb(0xe9edf2),
            .surface = rgb(0xf8fafc),
            .header = rgb(0xdce4ee),
            .border = rgb(0x9aa8ba),
            .text = rgb(0x172536),
            .weak = rgb(0x4c5d70),
            .good = rgb(0x14613c),
            .neutral = rgb(0x185795),
            .warm = rgb(0x874600),
            .focus = rgb(0x075cb5),
            .thread_main = rgb(0x835b00),
            .thread_other = rgb(0x006973),
            .breakpoint = rgb(0xb52621),
            .shadow = .{ 0, 0, 0, 0.18 },
            .pop = rgb(0xf1d8aa),
            .good_pop = rgb(0xc5e6d0),
            .bad_pop = rgb(0xf3c9c7),
            .fresh = rgb(0xeee0ca),
            .stripe = .{ 0, 0, 0, 0.025 },
            .overlay = .{ 0, 0, 0, 0.35 },
            .highlight = rgb(0xffffff),
            .chip_fill = .{ 0, 0, 0, 0.025 },
            .chip_border = .{ 0, 0, 0, 0.16 },
            .status_border = .{ 0, 0, 0, 0.16 },
            .flame_low = rgb(0xf0ba8a),
            .flame_high = rgb(0xf7d6a0),
            .flame_root = rgb(0xb4c9e3),
            .flame_unknown = rgb(0xc8cdd5),
            .flame_import_unknown = rgb(0xc8cdd5),
            .flame_text = rgb(0x272015),
        };
        theme.threads = .{ rgb(0x835b00), rgb(0x006973), rgb(0x7149a3), rgb(0xa6386d), rgb(0x4c7019), rgb(0x9b4e16), rgb(0x226da6), rgb(0x217353) } ++ .{rgb(0x006973)} ** 8;
    } else if (std.mem.eql(u8, name, "builtin:contrast")) {
        theme.colors = .{
            .background = rgb(0x000000),
            .surface = rgb(0x090909),
            .header = rgb(0x181818),
            .border = rgb(0x9b9b9b),
            .text = rgb(0xffffff),
            .weak = rgb(0xc5c5c5),
            .good = rgb(0x8cffba),
            .neutral = rgb(0x99cdff),
            .warm = rgb(0xffd486),
            .focus = rgb(0x67c1ff),
            .thread_main = rgb(0xffdf60),
            .thread_other = rgb(0x69edf5),
            .breakpoint = rgb(0xff786e),
            .shadow = .{ 0, 0, 0, 0.8 },
            .pop = rgb(0x554119),
            .good_pop = rgb(0x184324),
            .bad_pop = rgb(0x60211e),
            .fresh = rgb(0x403624),
            .stripe = .{ 1, 1, 1, 0.05 },
            .overlay = .{ 0, 0, 0, 0.7 },
            .flame_low = rgb(0x703011),
            .flame_high = rgb(0x80521a),
            .flame_root = rgb(0x264360),
            .flame_unknown = rgb(0x3b3b3b),
            .flame_import_unknown = rgb(0x3b3b3b),
            .flame_text = rgb(0xffffff),
        };
    } else if (std.mem.eql(u8, name, "builtin:vga")) {
        theme.font.pixel = true;
        theme.block_selection = true;
        theme.colors = .{
            .background = rgb(0x0000aa),
            .surface = rgb(0x0000aa),
            .header = rgb(0x000000),
            .border = rgb(0x55ffff),
            .text = rgb(0xaaaaaa),
            .weak = rgb(0xaaaaaa),
            .good = rgb(0x55ff55),
            .neutral = rgb(0x55ffff),
            .warm = rgb(0xffff55),
            .focus = rgb(0x55ffff),
            .thread_main = rgb(0xffff55),
            .thread_other = rgb(0x55ffff),
            .breakpoint = rgb(0xff5555),
            .shadow = .{ 0, 0, 0, 0 },
            .pop = rgb(0x000000),
            .good_pop = rgb(0x000000),
            .bad_pop = rgb(0x000000),
            .fresh = rgb(0x000000),
            .stripe = .{ 0, 0, 0, 0 },
            .overlay = rgb(0x000000),
            .highlight = rgb(0xffffff),
            .chip_fill = rgb(0x000000),
            .chip_border = rgb(0xaaaaaa),
            .status_border = rgb(0x55ffff),
            .flame_low = rgb(0x0000aa),
            .flame_high = rgb(0xaa0000),
            .flame_root = rgb(0x000000),
            .flame_unknown = rgb(0x555555),
            .flame_import_unknown = rgb(0x555555),
            .flame_text = rgb(0xffffff),
        };
        theme.thread_count = 7;
        theme.threads = .{ rgb(0xffff55), rgb(0x55ffff), rgb(0xff55ff), rgb(0x55ff55), rgb(0x00aaaa), rgb(0xffffff), rgb(0xaaaaaa) } ++ .{rgb(0x55ffff)} ** 9;
    } else if (!std.mem.eql(u8, name, "builtin:dark")) return error.UnknownThemeBase;
    @memcpy(theme.id[0..name.len], name);
    theme.threads[0] = theme.colors.thread_main;
    theme.threads[1] = theme.colors.thread_other;
    return theme;
}
fn color(value: std.json.Value) !Color {
    if (value != .string) return error.InvalidThemeColor;
    const s = value.string;
    if ((s.len != 7 and s.len != 9) or s[0] != '#') return error.InvalidThemeColor;
    var result: Color = .{ 0, 0, 0, 1 };
    for (0..(s.len - 1) / 2) |i| {
        for (s[1 + i * 2 .. 3 + i * 2]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidThemeColor;
        result[i] = @as(f32, @floatFromInt(try std.fmt.parseInt(u8, s[1 + i * 2 .. 3 + i * 2], 16))) / 255;
    }
    return result;
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8, diagnostic: *Diagnostic) !Theme {
    diagnostic.field("$", "");
    if (bytes.len > max_bytes) return error.ThemeTooLarge;
    const json = try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .max_value_len = max_bytes });
    defer json.deinit();
    if (json.value != .object) return error.InvalidThemeObject;
    const object = json.value.object;
    var fields = object.iterator();
    while (fields.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "version") and !std.mem.eql(u8, key, "id") and !std.mem.eql(u8, key, "base") and !std.mem.eql(u8, key, "colors") and !std.mem.eql(u8, key, "palettes") and !std.mem.eql(u8, key, "font")) {
            diagnostic.field("", key);
            return error.UnknownThemeField;
        }
    }
    diagnostic.field("", "version");
    const version = object.get("version") orelse return error.MissingThemeVersion;
    if (version != .integer or version.integer != 1) return error.UnsupportedThemeVersion;
    diagnostic.field("", "base");
    const base = object.get("base") orelse std.json.Value{ .string = "builtin:dark" };
    if (base != .string) return error.InvalidThemeBase;
    var theme = try builtin(base.string);
    if (object.get("id")) |id| {
        diagnostic.field("", "id");
        if (id != .string or id.string.len == 0 or id.string.len > 64) return error.InvalidThemeId;
        for (id.string) |ch| if (ch < 0x21 or ch > 0x7e) return error.InvalidThemeId;
        @memset(&theme.id, 0);
        @memcpy(theme.id[0..id.string.len], id.string);
    }
    if (object.get("font")) |font| {
        diagnostic.field("", "font");
        if (font != .object) return error.InvalidThemeFont;
        var it = font.object.iterator();
        while (it.next()) |entry| {
            diagnostic.field("font", entry.key_ptr.*);
            if (!std.mem.eql(u8, entry.key_ptr.*, "pixel")) return error.UnknownThemeFontField;
            if (entry.value_ptr.* != .bool) return error.InvalidThemeFont;
            theme.font.pixel = entry.value_ptr.bool;
        }
    }
    if (object.get("colors")) |colors| {
        diagnostic.field("", "colors");
        if (colors != .object) return error.InvalidThemeColors;
        var it = colors.object.iterator();
        while (it.next()) |entry| {
            diagnostic.field("colors", entry.key_ptr.*);
            var found = false;
            inline for (std.meta.fields(Colors)) |field| {
                if (std.mem.eql(u8, field.name, entry.key_ptr.*)) {
                    @field(theme.colors, field.name) = try color(entry.value_ptr.*);
                    found = true;
                }
            }
            if (!found) return error.UnknownThemeColor;
        }
    }
    theme.threads[0] = theme.colors.thread_main;
    theme.threads[1] = theme.colors.thread_other;
    if (object.get("palettes")) |palettes| {
        diagnostic.field("", "palettes");
        if (palettes != .object) return error.InvalidThemePalettes;
        var it = palettes.object.iterator();
        while (it.next()) |entry| {
            diagnostic.field("palettes", entry.key_ptr.*);
            if (!std.mem.eql(u8, entry.key_ptr.*, "threads")) return error.UnknownThemePalette;
            const list = entry.value_ptr.*;
            if (list != .array or list.array.items.len == 0 or list.array.items.len > theme.threads.len) return error.InvalidThemePalette;
            theme.thread_count = list.array.items.len;
            for (list.array.items, 0..) |item, i| theme.threads[i] = try color(item);
        }
    }
    diagnostic.* = .{};
    return theme;
}
pub fn load(a: std.mem.Allocator, selection: [:0]const u8, diagnostic: *Diagnostic) !Theme {
    if (std.mem.startsWith(u8, selection, "builtin:")) return builtin(selection);
    diagnostic.field("$", "");
    const fd = c.open(selection.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return error.ThemeOpenFailed;
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return error.ThemeNotRegular;
    if (stat.st_size < 0 or stat.st_size > max_bytes) return error.ThemeTooLarge;
    const bytes = try a.alloc(u8, max_bytes + 1);
    defer a.free(bytes);
    var n: usize = 0;
    while (n < bytes.len) {
        const count = c.read(fd, bytes.ptr + n, bytes.len - n);
        if (count < 0 and std.c._errno().* == c.EINTR) continue;
        if (count < 0) return error.ThemeReadFailed;
        if (count == 0) return parse(a, bytes[0..n], diagnostic);
        n += @intCast(count);
    }
    return error.ThemeTooLarge;
}

// Initialized before any GUI work, then read-only for the lifetime of the process.
pub var active: Theme = .{};
pub fn init(selection: ?[:0]const u8) void {
    active = builtin("builtin:dark") catch unreachable;
    const selected = selection orelse return;
    var diagnostic = Diagnostic{};
    active = load(std.heap.page_allocator, selected, &diagnostic) catch |err| {
        std.debug.print("xodb: Theme failed: {s} / {s}; using built-in dark; {s}\n", .{ @errorName(err), diagnostic.text(), selected });
        return;
    };
}

test "theme values own names and colors after JSON storage is freed" {
    var d = Diagnostic{};
    const a = std.testing.allocator;
    const theme = try parse(a, "{\"version\":1,\"id\":\"user.test\",\"base\":\"builtin:light\",\"colors\":{\"focus\":\"#1234aB80\"},\"palettes\":{\"threads\":[\"#112233\",\"#aabbcc\"]}}", &d);
    try std.testing.expectEqualStrings("user.test", theme.name());
    try std.testing.expectEqual((try builtin("builtin:light")).colors.surface, theme.colors.surface);
    try std.testing.expectEqual(@as(f32, 128.0 / 255.0), theme.colors.focus[3]);
    try std.testing.expectEqual(@as(f32, 171.0 / 255.0), theme.colors.focus[2]);
    try std.testing.expectEqual(@as(usize, 2), theme.thread_count);
    try std.testing.expectEqual(rgb(0x112233), theme.threads[0]);
    try std.testing.expectEqualStrings("", d.text());
}

test "theme schema rejects invalid versions fields types colors and palettes" {
    const Case = struct { json: []const u8, err: anyerror, field: []const u8 };
    const cases = [_]Case{
        .{ .json = "[]", .err = error.InvalidThemeObject, .field = "$" },
        .{ .json = "{}", .err = error.MissingThemeVersion, .field = "version" },
        .{ .json = "{\"version\":2}", .err = error.UnsupportedThemeVersion, .field = "version" },
        .{ .json = "{\"version\":1.0}", .err = error.UnsupportedThemeVersion, .field = "version" },
        .{ .json = "{\"version\":1,\"colours\":{}}", .err = error.UnknownThemeField, .field = "colours" },
        .{ .json = "{\"version\":1,\"base\":\"./other.json\"}", .err = error.UnknownThemeBase, .field = "base" },
        .{ .json = "{\"version\":1,\"id\":\"bad\\nname\"}", .err = error.InvalidThemeId, .field = "id" },
        .{ .json = "{\"version\":1,\"colors\":[]}", .err = error.InvalidThemeColors, .field = "colors" },
        .{ .json = "{\"version\":1,\"colors\":{\"txt\":\"#ffffff\"}}", .err = error.UnknownThemeColor, .field = "colors.txt" },
        .{ .json = "{\"version\":1,\"colors\":{\"text\":\"#fff\"}}", .err = error.InvalidThemeColor, .field = "colors.text" },
        .{ .json = "{\"version\":1,\"colors\":{\"text\":\"#ggffff\"}}", .err = error.InvalidThemeColor, .field = "colors.text" },
        .{ .json = "{\"version\":1,\"colors\":{\"text\":\"#+1ffff\"}}", .err = error.InvalidThemeColor, .field = "colors.text" },
        .{ .json = "{\"version\":1,\"colors\":{\"text\":null}}", .err = error.InvalidThemeColor, .field = "colors.text" },
        .{ .json = "{\"version\":1,\"palettes\":{\"threads\":[]}}", .err = error.InvalidThemePalette, .field = "palettes.threads" },
        .{ .json = "{\"version\":1,\"palettes\":{\"frames\":[]}}", .err = error.UnknownThemePalette, .field = "palettes.frames" },
    };
    for (cases) |case| {
        var d = Diagnostic{};
        try std.testing.expectError(case.err, parse(std.testing.allocator, case.json, &d));
        try std.testing.expectEqualStrings(case.field, d.text());
    }
}

test "theme input caps and duplicate fields are enforced" {
    var d = Diagnostic{};
    const huge = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, ' ');
    try std.testing.expectError(error.ThemeTooLarge, parse(std.testing.allocator, huge, &d));
    try std.testing.expectError(error.DuplicateField, parse(std.testing.allocator, "{\"version\":1,\"version\":1}", &d));
    try std.testing.expectError(error.DuplicateField, parse(std.testing.allocator, "{\"version\":1,\"colors\":{\"text\":\"#ffffff\",\"text\":\"#000000\"}}", &d));
    const many = "{\"version\":1,\"palettes\":{\"threads\":[" ++ "\"#112233\"," ** 16 ++ "\"#112233\"]}}";
    try std.testing.expectError(error.InvalidThemePalette, parse(std.testing.allocator, many, &d));
}

fn luminance(value: Color) f32 {
    var linear: [3]f32 = undefined;
    for (&linear, value[0..3]) |*out, channel| out.* = if (channel <= 0.04045) channel / 12.92 else std.math.pow(f32, (channel + 0.055) / 1.055, 2.4);
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
}
fn contrast(a: Color, b: Color) f32 {
    const x = luminance(a);
    const y = luminance(b);
    return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
}
test "built-in themes keep ordinary and flame labels readable" {
    for ([_][]const u8{ "builtin:dark", "builtin:light", "builtin:contrast" }) |name| {
        const theme = try builtin(name);
        for ([_]Color{ theme.colors.background, theme.colors.surface, theme.colors.header }) |background| {
            try std.testing.expect(contrast(theme.colors.text, background) >= 7);
            if (!std.mem.eql(u8, name, "builtin:dark")) try std.testing.expect(contrast(theme.colors.weak, background) >= 4.5);
        }
        // The original dark flame palette is preserved, including its contrast limits.
        if (!std.mem.eql(u8, name, "builtin:dark")) {
            for ([_]Color{ theme.colors.flame_low, theme.colors.flame_high, theme.colors.flame_root, theme.colors.flame_unknown }) |background| try std.testing.expect(contrast(theme.colors.flame_text, background) >= 4.5);
        }
    }
}

test "VGA palette keeps semantic labels and monochrome font settings explicit" {
    const vga = try builtin("builtin:vga");
    try std.testing.expect(vga.font.pixel and vga.block_selection);
    const roles = [_]Color{ vga.colors.text, vga.colors.weak, vga.colors.good, vga.colors.neutral, vga.colors.warm, vga.colors.focus };
    for ([_]Color{ vga.colors.background, vga.colors.surface, vga.colors.header, vga.colors.pop, vga.colors.good_pop, vga.colors.bad_pop, vga.colors.fresh }) |bg| {
        for (roles) |fg| try std.testing.expect(contrast(fg, bg) >= 4.5);
        try std.testing.expect(contrast(vga.colors.breakpoint, bg) >= 3);
        for (vga.threads[0..vga.thread_count]) |fg| try std.testing.expect(contrast(fg, bg) >= 4.5);
    }
    for ([_]Color{ vga.colors.flame_low, vga.colors.flame_high, vga.colors.flame_root, vga.colors.flame_unknown, vga.colors.flame_import_unknown }) |bg| try std.testing.expect(contrast(vga.colors.flame_text, bg) >= 4.5);
    try std.testing.expect(!std.meta.eql(vga.colors.good, vga.colors.warm));
    try std.testing.expect(!std.meta.eql(vga.colors.breakpoint, vga.colors.neutral));
    inline for (std.meta.fields(Colors)) |field| {
        const color_value = @field(vga.colors, field.name);
        for (color_value[0..3]) |channel| {
            const byte: u8 = @intFromFloat(@round(channel * 255));
            try std.testing.expect(byte == 0 or byte == 85 or byte == 170 or byte == 255);
        }
    }
    var diagnostic = Diagnostic{};
    const custom = try parse(std.testing.allocator, "{\"version\":1,\"base\":\"builtin:vga\",\"font\":{\"pixel\":false}}", &diagnostic);
    try std.testing.expect(!custom.font.pixel and custom.block_selection);
    try std.testing.expect(!(try builtin("builtin:dark")).font.pixel);
    try std.testing.expectError(error.InvalidThemeFont, parse(std.testing.allocator, "{\"version\":1,\"font\":{\"pixel\":1}}", &diagnostic));
    try std.testing.expectEqualStrings("font.pixel", diagnostic.text());
    try std.testing.expectError(error.UnknownThemeFontField, parse(std.testing.allocator, "{\"version\":1,\"font\":{\"size\":32}}", &diagnostic));
}
