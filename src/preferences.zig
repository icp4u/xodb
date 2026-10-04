//! Provisional, explicitly loaded preferences. No implicit files or write-back.
const std = @import("std");
const c = @import("c.zig").api;
const Config = @import("profile/capture.zig").Config;
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
pub const Symbols = struct { automatic: bool = true, auto_file_bytes: u32 = 64 * 1024 * 1024, auto_total_bytes: u32 = 128 * 1024 * 1024 };
pub const Preferences = struct { profile: Profile = .{}, allocations: @import("profile/allocation_live.zig").Config = .{}, symbols: Symbols = .{} };
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Preferences {
    if (bytes.len > max_bytes) return error.PreferencesTooLarge;
    const parsed = try std.json.parseFromSlice(Preferences, a, bytes, .{});
    defer parsed.deinit();
    try parsed.value.profile.config().validate();
    try parsed.value.allocations.validate();
    if (parsed.value.symbols.auto_file_bytes == 0 or parsed.value.symbols.auto_file_bytes > 256 * 1024 * 1024 or parsed.value.symbols.auto_total_bytes == 0 or parsed.value.symbols.auto_total_bytes > 512 * 1024 * 1024) return error.InvalidSymbolBudget;
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
