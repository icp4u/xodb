//! Provisional, explicitly loaded preferences. No implicit files or write-back.
const std = @import("std");
const c = @import("c_ui.zig").api;
const Config = @import("profile/capture.zig").Config;
const snapshot = @import("binary/snapshot.zig");
pub const max_bytes = 64 * 1024;
pub const Profile = struct {
    sample_limit: u32 = (Config{}).sample_limit,
    frequency_hz: u32 = (Config{}).frequency_hz,
    duration_ms: u32 = (Config{}).duration_ms,
    context_switch: bool = false,
    syscall_timing: bool = false,
    syscall_limit: u32 = (Config{}).syscall_limit,
    follow_threads: bool = true,
    ring_budget_bytes: u32 = (Config{}).ring_budget_bytes,
    user_stack_bytes: u32 = 0,
    user_stack_budget_bytes: u32 = (Config{}).user_stack_budget_bytes,
    pub fn config(self: Profile) Config {
        return .{ .sample_limit = self.sample_limit, .follow_threads = self.follow_threads, .ring_budget_bytes = self.ring_budget_bytes, .frequency_hz = self.frequency_hz, .duration_ms = self.duration_ms, .context_switch = self.context_switch, .syscall_timing = self.syscall_timing, .syscall_limit = self.syscall_limit, .user_stack_bytes = self.user_stack_bytes, .user_stack_budget_bytes = self.user_stack_budget_bytes };
    }
};
/// `image_bytes` and `image_total_bytes` bound full ELF images read for code,
/// source and types; null keeps the defaults (see binary/snapshot.zig).
pub const Symbols = struct { automatic: bool = true, auto_file_bytes: u32 = 64 * 1024 * 1024, auto_total_bytes: u32 = 128 * 1024 * 1024, image_bytes: ?u64 = null, image_total_bytes: ?u64 = null };
/// Inline storage keeps a parsed preference independent of the JSON arena.
pub const ThemePath = struct {
    bytes: [4096]u8 = @splat(0),
    len: usize = 0,
    pub fn slice(self: *const ThemePath) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ThemePath {
        const value = try std.json.innerParse([]const u8, a, source, options);
        if (value.len >= 4096) return error.ValueTooLong;
        if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidCharacter;
        var result = ThemePath{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = value.len;
        return result;
    }
};
/// Which language views may run. A view that is off does no work at all:
/// no runtime search, no file read and no target memory read on its behalf.
/// `enabled` false turns every one of them off.
pub const Languages = struct {
    enabled: bool = true,
    python: bool = true,
    perl: bool = true,
    lua: bool = true,
    javascript: bool = true,
    ruby: bool = true,
    go: bool = true,
    elisp: bool = true,
    gdscript: bool = true,
    /// In language tab order.
    pub const Name = enum { python, perl, lua, javascript, ruby, go, elisp, gdscript };
    pub fn on(self: Languages, name: Name) bool {
        return self.enabled and switch (name) {
            inline else => |which| @field(self, @tagName(which)),
        };
    }
    pub fn require(self: Languages, name: Name) error{LanguageDisabled}!void {
        if (!self.on(name)) return error.LanguageDisabled;
    }
    /// `all` or one language name, as the command line spells it.
    pub fn turnOff(self: *Languages, name: []const u8) !void {
        if (std.mem.eql(u8, name, "all")) {
            self.enabled = false;
            return;
        }
        switch (std.meta.stringToEnum(Name, name) orelse return error.UnknownLanguage) {
            inline else => |which| @field(self, @tagName(which)) = false,
        }
    }
};
pub const Gibson = struct {
    flight_speed: f32 = 1.5,
    film_speed: f32 = 4.2,
    film: bool = false,
    street_names: bool = true,
    facts: bool = true,
    facts_alpha: f32 = 0.38,
    pub fn validate(self: Gibson) !void {
        inline for (.{ .{ self.flight_speed, 0.4, 5.0 }, .{ self.film_speed, 0.4, 5.0 }, .{ self.facts_alpha, 0.0, 1.0 } }) |range| {
            if (!std.math.isFinite(range[0]) or range[0] < range[1] or range[0] > range[2]) return error.InvalidGibsonLook;
        }
    }
};
pub const Galaxy = struct {
    additive: bool = true,
    cloud_size: f32 = 1.6,
    cloud_lod: bool = true,
    cloud_pixel_limit: f32 = 4,
    brightness: f32 = 0.85,
    camera_zoom: f32 = 1.35,
    easing_ms: f32 = 450,
    max_stars: u32 = 512,
    unfold: bool = true,
    pan_speed: f32 = 340,
    zoom_speed: f32 = 1.2,
    rotate_speed: f32 = 0.45,
    tour_seconds: f32 = 5,
    tour_drift: bool = true,
    tour_drift_speed: f32 = 0.025,
    pub fn validate(self: Galaxy) !void {
        inline for (.{ .{ self.cloud_size, 0.5, 3.0 }, .{ self.brightness, 0.1, 2.0 }, .{ self.camera_zoom, 1.0, 2.5 }, .{ self.easing_ms, 50.0, 2000.0 } }) |range| {
            if (!std.math.isFinite(range[0]) or range[0] < range[1] or range[0] > range[2]) return error.InvalidGalaxyLook;
        }
        if (self.max_stars < 8 or self.max_stars > 1024) return error.InvalidGalaxyLook;
        if (!std.math.isFinite(self.cloud_pixel_limit) or self.cloud_pixel_limit < 1 or self.cloud_pixel_limit > 8) return error.InvalidGalaxyLook;
        inline for (.{ .{ self.pan_speed, 20.0, 2000.0 }, .{ self.zoom_speed, 1.01, 2.0 }, .{ self.rotate_speed, 0.01, 3.0 }, .{ self.tour_seconds, 1.0, 60.0 }, .{ self.tour_drift_speed, 0.0, 0.3 } }) |range| {
            if (!std.math.isFinite(range[0]) or range[0] < range[1] or range[0] > range[2]) return error.InvalidGalaxyLook;
        }
    }
};
pub const Preferences = struct {
    wine: struct { hide_internal_threads: bool = false } = .{},
    profile: Profile = .{},
    allocations: @import("profile/allocation_live.zig").Config = .{},
    symbols: Symbols = .{},
    appearance: struct {
        theme: ThemePath = .{},
        /// Device pixels per UI unit. Null follows the window system.
        ui_scale: ?f32 = null,
        density: @import("look.zig").Density = .auto,
    } = .{},
    languages: Languages = .{},
    decompiler: struct {
        prestart: bool = true,
        /// Eagerly import shared libraries no larger than this. The main
        /// executable is always eligible; larger libraries load on demand.
        eager_library_bytes: u64 = 1024 * 1024,
    } = .{},
    galaxy: Galaxy = .{},
    gibson: Gibson = .{},
};

/// CLI wins. File references in preferences are relative to that config file.
pub fn themeSelection(a: std.mem.Allocator, prefs: *const Preferences, config: ?[:0]const u8, cli: ?[:0]const u8) !?[:0]const u8 {
    if (cli) |path| return path;
    const path = prefs.appearance.theme.slice();
    if (path.len == 0) return null;
    if (std.mem.startsWith(u8, path, "builtin:") or std.fs.path.isAbsolute(path)) return try a.dupeZ(u8, path);
    const joined = try std.fs.path.join(a, &.{ if (config) |file| std.fs.path.dirname(file) orelse "." else ".", path });
    defer a.free(joined);
    return try a.dupeZ(u8, joined);
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Preferences {
    if (bytes.len > max_bytes) return error.PreferencesTooLarge;
    const parsed = try std.json.parseFromSlice(Preferences, a, bytes, .{});
    defer parsed.deinit();
    try parsed.value.profile.config().validate();
    try parsed.value.allocations.validate();
    try parsed.value.galaxy.validate();
    try parsed.value.gibson.validate();
    if (parsed.value.symbols.auto_file_bytes == 0 or parsed.value.symbols.auto_file_bytes > 256 * 1024 * 1024 or parsed.value.symbols.auto_total_bytes == 0 or parsed.value.symbols.auto_total_bytes > 512 * 1024 * 1024) return error.InvalidSymbolBudget;
    for ([_]?u64{ parsed.value.symbols.image_bytes, parsed.value.symbols.image_total_bytes }) |value| if (value) |n| {
        if (n < snapshot.min_limit or n > snapshot.max_limit) return error.InvalidImageBudget;
    };
    if (parsed.value.appearance.ui_scale) |scale| _ = @import("platform/window.zig").validateScale(scale) catch return error.InvalidUiScale;
    if (parsed.value.decompiler.eager_library_bytes > 1024 * 1024 * 1024) return error.InvalidDecompilerBudget;
    return parsed.value;
}
pub fn load(a: std.mem.Allocator, path: [:0]const u8) !Preferences {
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return error.PreferencesOpenFailed;
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return error.PreferencesNotRegular;
    if (stat.st_size < 0 or stat.st_size > max_bytes) return error.PreferencesTooLarge;
    // Read to EOF, with an extra byte to detect growth past the cap.
    const bytes = try a.alloc(u8, max_bytes + 1);
    defer a.free(bytes);
    var used: usize = 0;
    while (used < bytes.len) {
        const n = c.read(fd, bytes.ptr + used, bytes.len - used);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n < 0) return error.PreferencesReadFailed;
        if (n == 0) return parse(a, bytes[0..used]);
        used += @intCast(n);
    }
    return error.PreferencesTooLarge;
}
test "Gibson film and signage preferences validate finite bounded values" {
    const prefs = try parse(std.testing.allocator, "{\"gibson\":{\"film\":true,\"film_speed\":4.5,\"facts\":false,\"facts_alpha\":0.2}}");
    try std.testing.expect(prefs.gibson.film and prefs.gibson.film_speed == 4.5 and !prefs.gibson.facts);
    try std.testing.expectError(error.InvalidGibsonLook, parse(std.testing.allocator, "{\"gibson\":{\"film_speed\":6}}"));
    try std.testing.expectError(error.InvalidGibsonLook, parse(std.testing.allocator, "{\"gibson\":{\"facts_alpha\":-1}}"));
}

test "galaxy look preferences retain defaults and accept deliberate overrides" {
    const defaults = try parse(std.testing.allocator, "{}");
    try std.testing.expect(defaults.galaxy.unfold and defaults.galaxy.additive and defaults.galaxy.max_stars == 512);
    const custom = try parse(std.testing.allocator, "{\"galaxy\":{\"cloud_size\":2,\"brightness\":0.5,\"camera_zoom\":1,\"easing_ms\":800,\"max_stars\":128,\"unfold\":false,\"additive\":false}}");
    try std.testing.expect(custom.galaxy.cloud_size == 2 and custom.galaxy.brightness == 0.5 and custom.galaxy.camera_zoom == 1 and !custom.galaxy.unfold and !custom.galaxy.additive);
}

test "language views default on, turn off one at a time or all at once, and refuse unknown keys" {
    const a = std.testing.allocator;
    const defaults = try parse(a, "{}");
    inline for (@typeInfo(Languages.Name).@"enum".fields) |field| try std.testing.expect(defaults.languages.on(@enumFromInt(field.value)));
    try defaults.languages.require(.perl);
    const one = try parse(a, "{\"languages\":{\"python\":false}}");
    try std.testing.expectError(error.LanguageDisabled, one.languages.require(.python));
    inline for (.{ .perl, .lua, .javascript, .ruby, .go, .elisp, .gdscript }) |name| try one.languages.require(name);
    // The master switch wins over a language left, or set, on.
    const none = try parse(a, "{\"languages\":{\"enabled\":false,\"perl\":true}}");
    inline for (@typeInfo(Languages.Name).@"enum".fields) |field| try std.testing.expectError(error.LanguageDisabled, none.languages.require(@enumFromInt(field.value)));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"languages\":{\"pyton\":false}}"));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"language\":{\"python\":false}}"));
    try std.testing.expectError(error.UnexpectedToken, parse(a, "{\"languages\":{\"python\":0}}"));
    var cli = Languages{};
    try cli.turnOff("ruby");
    try std.testing.expect(!cli.on(.ruby) and cli.on(.go));
    try cli.turnOff("all");
    try std.testing.expect(!cli.on(.go));
    try std.testing.expectError(error.UnknownLanguage, cli.turnOff("cobol"));
}

test "Ghidra eager startup and library byte bound are validated" {
    const defaults = try parse(std.testing.allocator, "{}");
    try std.testing.expect(defaults.decompiler.prestart);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), defaults.decompiler.eager_library_bytes);
    const changed = try parse(std.testing.allocator, "{\"decompiler\":{\"prestart\":false,\"eager_library_bytes\":8388608}}");
    try std.testing.expect(!changed.decompiler.prestart);
    try std.testing.expectEqual(@as(u64, 8 * 1024 * 1024), changed.decompiler.eager_library_bytes);
    try std.testing.expectError(error.InvalidDecompilerBudget, parse(std.testing.allocator, "{\"decompiler\":{\"eager_library_bytes\":1073741825}}"));
}

test "preferences partial defaults, custom and unlimited durations, typo and type errors" {
    const a = std.testing.allocator;
    const defaults = try parse(a, "{}");
    try std.testing.expectEqual(@as(u32, 60000), defaults.profile.duration_ms);
    const prefs = try parse(a, "{\"profile\":{\"duration_ms\":0,\"context_switch\":true}}");
    try std.testing.expectEqual(@as(u32, 99), prefs.profile.frequency_hz);
    try std.testing.expectEqual(@as(u32, 0), prefs.profile.duration_ms);
    try std.testing.expect(prefs.profile.context_switch);
    _ = try parse(a, "{\"profile\":{\"duration_ms\":300000}}");
    _ = try parse(a, "{\"profile\":{\"duration_ms\":4294967295}}");
    try std.testing.expectError(error.UnknownField, parse(a, "{\"profile\":{\"duraton_ms\":1}}"));
    try std.testing.expectError(error.InvalidProfileConfig, parse(a, "{\"profile\":{\"frequency_hz\":1001}}"));
    try std.testing.expectError(error.Overflow, parse(a, "{\"profile\":{\"duration_ms\":4294967296}}"));
    try std.testing.expectError(error.UnexpectedToken, parse(a, "{\"profile\":{\"context_switch\":0}}"));
}

test "sampled stack preferences bound per-sample and total retention independently" {
    const a = std.testing.allocator;
    const defaults = try parse(a, "{}");
    try std.testing.expectEqual(@as(u32, 0), defaults.profile.user_stack_bytes);
    try std.testing.expectEqual(@as(u32, 33554432), defaults.profile.user_stack_budget_bytes);
    const custom = try parse(a, "{\"profile\":{\"user_stack_bytes\":4096,\"user_stack_budget_bytes\":0}}");
    try std.testing.expectEqual(@as(u32, 0), custom.profile.config().user_stack_budget_bytes);
    for ([_][]const u8{ "{\"profile\":{\"user_stack_bytes\":8}}", "{\"profile\":{\"user_stack_bytes\":65}}", "{\"profile\":{\"user_stack_bytes\":8200}}", "{\"profile\":{\"user_stack_budget_bytes\":67108865}}" }) |invalid| try std.testing.expectError(error.InvalidProfileConfig, parse(a, invalid));
}

test "dynamic thread preferences retain fixed-scope opt-out and bounded ring memory" {
    const a = std.testing.allocator;
    const defaults = try parse(a, "{}");
    try std.testing.expect(defaults.profile.config().follow_threads);
    try std.testing.expectEqual(@as(u32, 67108864), defaults.profile.config().ring_budget_bytes);
    const custom = try parse(a, "{\"profile\":{\"follow_threads\":false,\"ring_budget_bytes\":1048576}}");
    try std.testing.expect(!custom.profile.config().follow_threads);
    try std.testing.expectEqual(@as(u32, 1048576), custom.profile.config().ring_budget_bytes);
    try std.testing.expectError(error.UnexpectedToken, parse(a, "{\"profile\":{\"follow_threads\":1}}"));
    for ([_][]const u8{ "{\"profile\":{\"ring_budget_bytes\":0}}", "{\"profile\":{\"ring_budget_bytes\":268435457}}" }) |invalid| try std.testing.expectError(error.InvalidProfileConfig, parse(a, invalid));
}

test "sample ceiling is opt-in, bounded, and passed through preferences" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 16384), (try parse(a, "{}")).profile.config().sample_limit);
    try std.testing.expectEqual(@as(u32, 65536), (try parse(a, "{\"profile\":{\"sample_limit\":65536}}")).profile.config().sample_limit);
    _ = try parse(a, "{\"profile\":{\"sample_limit\":1}}");
    for ([_][]const u8{ "{\"profile\":{\"sample_limit\":0}}", "{\"profile\":{\"sample_limit\":65537}}" }) |invalid| try std.testing.expectError(error.InvalidProfileConfig, parse(a, invalid));
}

test "allocation preferences bound evidence memory and record retention independently" {
    const a = std.testing.allocator;
    const defaults = try parse(a, "{}");
    try std.testing.expectEqual(@as(u32, 32768), defaults.allocations.record_limit);
    try std.testing.expectEqual(@as(u32, 33554432), defaults.allocations.memory_limit);
    const custom = try parse(a, "{\"allocations\":{\"duration_ms\":0,\"record_limit\":131072,\"memory_limit\":134217728}}");
    try std.testing.expectEqual(@as(u32, 0), custom.allocations.duration_ms);
    for ([_][]const u8{ "{\"allocations\":{\"record_limit\":1}}", "{\"allocations\":{\"record_limit\":131073}}", "{\"allocations\":{\"memory_limit\":134217729}}" }) |invalid| try std.testing.expectError(error.InvalidAllocationConfig, parse(a, invalid));
}

test "theme preferences own their path and resolve against config with CLI precedence" {
    const a = std.testing.allocator;
    const prefs = try parse(a, "{\"profile\":{\"frequency_hz\":77},\"appearance\":{\"theme\":\"themes/ember.json\"}}");
    try std.testing.expectEqual(@as(u32, 77), prefs.profile.frequency_hz);
    try std.testing.expectEqualStrings("themes/ember.json", prefs.appearance.theme.slice());
    const selected = (try themeSelection(a, &prefs, "/example/config/settings.json", null)).?;
    defer a.free(selected);
    try std.testing.expectEqualStrings("/example/config/themes/ember.json", selected);
    try std.testing.expectEqualStrings("builtin:contrast", (try themeSelection(a, &prefs, "/example/config/settings.json", "builtin:contrast")).?);
    const built = try parse(a, "{\"appearance\":{\"theme\":\"builtin:light\"}}");
    const name = (try themeSelection(a, &built, "/example/config/settings.json", null)).?;
    defer a.free(name);
    try std.testing.expectEqualStrings("builtin:light", name);
    try std.testing.expectError(error.InvalidCharacter, parse(a, "{\"appearance\":{\"theme\":\"\"}}"));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"appearance\":{\"thme\":\"x\"}}"));
    try std.testing.expectError(error.InvalidCharacter, parse(a, "{\"appearance\":{\"theme\":\"a\\u0000b\"}}"));
}

test "UI scale preference follows the compositor by default and is bounded" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(?f32, null), (try parse(a, "{}")).appearance.ui_scale);
    inline for (.{ 1.0, 1.5, 2.0 }) |scale| {
        var buffer: [64]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{{\"appearance\":{{\"ui_scale\":{d}}}}}", .{scale});
        try std.testing.expectEqual(@as(?f32, scale), (try parse(a, json)).appearance.ui_scale);
    }
    for ([_][]const u8{ "{\"appearance\":{\"ui_scale\":0.49}}", "{\"appearance\":{\"ui_scale\":4.01}}" }) |json|
        try std.testing.expectError(error.InvalidUiScale, parse(a, json));
}

test "image budget preferences default to unset and refuse values outside the range" {
    const a = std.testing.allocator;
    const defaults = try parse(a, "{}");
    try std.testing.expect(defaults.symbols.image_bytes == null and defaults.symbols.image_total_bytes == null);
    const custom = try parse(a, "{\"symbols\":{\"image_bytes\":3221225472,\"image_total_bytes\":6442450944}}");
    try std.testing.expectEqual(@as(?u64, 3 << 30), custom.symbols.image_bytes);
    try std.testing.expectEqual(@as(?u64, 6 << 30), custom.symbols.image_total_bytes);
    try std.testing.expectEqual(@as(u32, 128 * 1024 * 1024), custom.symbols.auto_total_bytes); // automatic budgets are separate
    for ([_][]const u8{ "{\"symbols\":{\"image_bytes\":0}}", "{\"symbols\":{\"image_bytes\":4096}}", "{\"symbols\":{\"image_total_bytes\":1048575}}", "{\"symbols\":{\"image_total_bytes\":1099511627777}}" }) |invalid|
        try std.testing.expectError(error.InvalidImageBudget, parse(a, invalid));
    try std.testing.expectError(error.Overflow, parse(a, "{\"symbols\":{\"image_bytes\":-1}}"));
    try std.testing.expectError(error.InvalidCharacter, parse(a, "{\"symbols\":{\"image_bytes\":\"2G\"}}"));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"symbols\":{\"image_byte\":1048576}}"));
}

test "Wine thread suppression is explicit and type checked" {
    try std.testing.expect(!(try parse(std.testing.allocator, "{}")).wine.hide_internal_threads);
    try std.testing.expect((try parse(std.testing.allocator, "{\"wine\":{\"hide_internal_threads\":true}}")).wine.hide_internal_threads);
    try std.testing.expectError(error.UnexpectedToken, parse(std.testing.allocator, "{\"wine\":{\"hide_internal_threads\":1}}"));
}
