//! Leveled diagnostics. Every line xodb writes to stderr goes through here
//! with a level and a topic; -qq/-q/-v/-vv, --log=VALUE and XODB_LOG=VALUE
//! pick what is shown, and --log-file PATH sends it to a file instead.
//!
//! error, warn and info lines are written exactly as the caller formats them:
//! scripts and tests match those bytes. debug and trace lines get
//! "xodb[topic] +12.345s " in front (monotonic seconds since start). At every
//! level the caller's format ends in "\n".
//!
//! Nothing here allocates; a line that is not shown costs one load and a
//! branch. Lines up to the buffer size reach the descriptor in one write.
//! src/runtime/log.c is the C half and reads the same XODB_LOG.
const std = @import("std");

pub const Level = enum(u8) { @"error", warn, info, debug, trace };
pub const Topic = enum(u8) { render, window, runtime, agent, session, mcp, sidecar, semq, overview, redot, profile };
const topic_count = @typeInfo(Topic).@"enum".fields.len;
const Table = [topic_count]Level;

var levels: Table = @splat(.info);
var fd: c_int = 2;
var epoch: u64 = 0;
var value_buffer: [256]u8 = undefined;
var value_len: usize = 0;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub inline fn on(topic: Topic, level: Level) bool {
    return @intFromEnum(level) <= @intFromEnum(levels[@intFromEnum(topic)]);
}
pub fn err(topic: Topic, comptime fmt: []const u8, args: anytype) void {
    if (on(topic, .@"error")) emit(topic, .@"error", fmt, args);
}
pub fn warn(topic: Topic, comptime fmt: []const u8, args: anytype) void {
    if (on(topic, .warn)) emit(topic, .warn, fmt, args);
}
pub fn info(topic: Topic, comptime fmt: []const u8, args: anytype) void {
    if (on(topic, .info)) emit(topic, .info, fmt, args);
}
pub fn debug(topic: Topic, comptime fmt: []const u8, args: anytype) void {
    if (on(topic, .debug)) emit(topic, .debug, fmt, args);
}
pub fn trace(topic: Topic, comptime fmt: []const u8, args: anytype) void {
    if (on(topic, .trace)) emit(topic, .trace, fmt, args);
}
/// A line that would repeat: written at most once per `period_ns`. The state
/// belongs to the format string, so two calls with the same text share it.
/// True when the line was written, for a caller that pairs it with another.
pub fn every(period_ns: u64, comptime level: Level, topic: Topic, comptime fmt: []const u8, args: anytype) bool {
    if (!on(topic, level)) return false;
    const site = Site(fmt);
    const current = now() | 1;
    const last = site.last.load(.monotonic);
    if (last != 0 and current -| last < period_ns) return false;
    site.last.store(current, .monotonic);
    emit(topic, level, fmt, args);
    return true;
}
/// Written the first time only.
pub fn once(comptime level: Level, topic: Topic, comptime fmt: []const u8, args: anytype) void {
    _ = every(std.math.maxInt(u64), level, topic, fmt, args);
}
fn Site(comptime fmt: []const u8) type {
    return struct {
        const text = fmt;
        var last = std.atomic.Value(u64).init(0);
    };
}

/// True when lines go to --log-file rather than stderr.
pub fn toFile() bool {
    return fd != 2;
}
/// The setting as XODB_LOG text for a process xodb starts on another
/// machine; null when everything is at the default.
pub fn value() ?[:0]const u8 {
    for (levels) |level| if (level != .info) return value_buffer[0..value_len :0];
    return null;
}

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
fn put(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}
fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    put(w.buffer[0..w.end]);
    w.end = 0;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        put(bytes);
        n += bytes.len;
    }
    for (0..splat) |_| put(data[data.len - 1]);
    return n + splat * data[data.len - 1].len;
}
fn emit(topic: Topic, level: Level, comptime fmt: []const u8, args: anytype) void {
    @branchHint(.cold);
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &buffer };
    if (@intFromEnum(level) >= @intFromEnum(Level.debug)) {
        const ms = (now() -| epoch) / std.time.ns_per_ms;
        w.print("xodb[{s}] +{d}.{d:0>3}s ", .{ @tagName(topic), ms / 1000, ms % 1000 }) catch {};
    }
    if (@import("redact.zig").active()) |policy| {
        // --redact: the whole line, every level, before it reaches the file.
        var line: [4096]u8 = undefined;
        var raw = std.Io.Writer.fixed(&line);
        raw.print(fmt, args) catch {};
        policy.scrub(&w, raw.buffered()) catch {};
    } else w.print(fmt, args) catch {};
    w.flush() catch {};
}

/// "LEVEL" sets every topic, "topic=level" one; commas join several and a
/// later item wins.
pub fn parse(table: *Table, text: []const u8) error{InvalidLogValue}!void {
    var items = std.mem.splitScalar(u8, text, ',');
    while (items.next()) |item| {
        if (std.mem.indexOfScalar(u8, item, '=')) |eq| {
            const topic = std.meta.stringToEnum(Topic, item[0..eq]) orelse return error.InvalidLogValue;
            table[@intFromEnum(topic)] = std.meta.stringToEnum(Level, item[eq + 1 ..]) orelse return error.InvalidLogValue;
        } else table.* = @splat(std.meta.stringToEnum(Level, item) orelse return error.InvalidLogValue);
    }
}
fn describe(table: *const Table, out: []u8) usize {
    var w: std.Io.Writer = .fixed(out);
    const uniform = for (table) |level| {
        if (level != table[0]) break false;
    } else true;
    if (uniform) w.writeAll(@tagName(table[0])) catch unreachable else for (table, 0..) |level, i|
        w.print("{s}{s}={s}", .{ if (i == 0) "" else ",", @tagName(@as(Topic, @enumFromInt(i))), @tagName(level) }) catch unreachable;
    w.writeByte(0) catch unreachable;
    return w.end - 1;
}
fn refuse(option: []const u8, text: []const u8) noreturn {
    const names = comptime blk: {
        var joined: []const u8 = "";
        for (@typeInfo(Topic).@"enum".fields) |field| joined = joined ++ (if (joined.len == 0) "" else ", ") ++ field.name;
        break :blk joined;
    };
    std.debug.print("xodb: {s} {s}: expected error, warn, info, debug or trace, or topic=level[,topic=level...] with a topic from " ++ names ++ "\n", .{ option, text });
    std.process.exit(2);
}
fn environment(name: [*:0]const u8) ?[:0]const u8 {
    const text = std.mem.span(std.c.getenv(name) orelse return null);
    return if (text.len == 0) null else text;
}

/// Reads XODB_LOG, then the options up to "--" (they win), and returns `args`
/// without those options so that no later parser has to know them. Only an
/// argument in option position counts: `takesValue` names the options of the
/// other parsers that are followed by a value, and that value is passed over
/// whatever it looks like ("--break -v" keeps its "-v"). An invalid value is a
/// usage error: one line and exit status 2. A setting made by option is put in
/// the environment for the processes xodb starts.
pub fn init(args: [][:0]const u8, takesValue: *const fn ([]const u8) bool) [][:0]const u8 {
    epoch = now();
    var table: Table = @splat(.info);
    if (environment("XODB_LOG")) |text| parse(&table, text) catch refuse("XODB_LOG", text);
    var file = environment("XODB_LOG_FILE");
    var chosen = false;
    var out: usize = @min(args.len, 1);
    var i: usize = out;
    while (i < args.len and !std.mem.eql(u8, args[i], "--")) : (i += 1) {
        const arg = args[i];
        const wants_value = std.mem.eql(u8, arg, "--log") or std.mem.eql(u8, arg, "--log-file");
        if (wants_value and i + 1 == args.len) refuse(arg, "needs a value");
        if (std.mem.eql(u8, arg, "-qq")) table = @splat(.@"error") else if (std.mem.eql(u8, arg, "-q")) table = @splat(.warn) else if (std.mem.eql(u8, arg, "-v")) table = @splat(.debug) else if (std.mem.eql(u8, arg, "-vv")) table = @splat(.trace) else if (std.mem.startsWith(u8, arg, "--log=")) parse(&table, arg["--log=".len..]) catch refuse("--log", arg["--log=".len..]) else if (std.mem.startsWith(u8, arg, "--log-file=")) {
            file = arg["--log-file=".len..];
        } else if (wants_value) {
            i += 1;
            if (arg.len == "--log".len) parse(&table, args[i]) catch refuse(arg, args[i]) else file = args[i];
        } else {
            args[out] = arg;
            out += 1;
            if (takesValue(arg) and i + 1 < args.len) {
                i += 1;
                args[out] = args[i];
                out += 1;
            }
            continue;
        }
        chosen = true;
    }
    for (args[i..]) |arg| {
        args[out] = arg;
        out += 1;
    }
    levels = table;
    value_len = describe(&table, &value_buffer);
    if (chosen) _ = setenv("XODB_LOG", value_buffer[0..value_len :0], 1);
    if (file) |path| {
        const opened = std.c.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        if (opened < 0) {
            std.debug.print("xodb: --log-file {s}: cannot open for append (errno {d})\n", .{ path, std.c._errno().* });
            std.process.exit(2);
        }
        fd = opened;
        // A started process may run in another directory.
        var absolute: [std.c.PATH_MAX]u8 = undefined;
        if (std.c.realpath(path, &absolute)) |resolved| _ = setenv("XODB_LOG_FILE", resolved, 1);
    }
    return args[0..out];
}

test "a level sets every topic and topic=level one of them" {
    var table: Table = @splat(.info);
    try parse(&table, "debug");
    for (table) |level| try std.testing.expectEqual(Level.debug, level);
    try parse(&table, "warn,render=trace,sidecar=error");
    try std.testing.expectEqual(Level.trace, table[@intFromEnum(Topic.render)]);
    try std.testing.expectEqual(Level.@"error", table[@intFromEnum(Topic.sidecar)]);
    try std.testing.expectEqual(Level.warn, table[@intFromEnum(Topic.mcp)]);
    var text: [256]u8 = undefined;
    var again: Table = @splat(.info);
    try parse(&again, text[0..describe(&table, &text)]);
    try std.testing.expectEqualSlices(Level, &table, &again);
    try std.testing.expectEqualStrings("trace", text[0..describe(&@as(Table, @splat(.trace)), &text)]);
}
test "an unknown level, topic or empty item is refused" {
    var table: Table = @splat(.info);
    for ([_][]const u8{ "", "loud", "render", "render=", "paint=debug", "debug,", "render=debug=trace" }) |text|
        try std.testing.expectError(error.InvalidLogValue, parse(&table, text));
}
test "options are removed up to the program separator and win over the table" {
    const saved = levels;
    defer {
        levels = saved;
        _ = setenv("XODB_LOG", "info", 1);
    }
    var args = [_][:0]const u8{ "xodb", "-v", "--headless", "--log=render=trace", "--log", "mcp=warn", "--", "program", "-q" };
    const rest = init(&args, testTakesValue);
    try std.testing.expectEqual(@as(usize, 5), rest.len);
    try std.testing.expectEqualStrings("--headless", rest[1]);
    try std.testing.expectEqualStrings("-q", rest[4]);
    try std.testing.expect(on(.render, .trace) and on(.session, .debug) and !on(.session, .trace) and !on(.mcp, .info));
    try std.testing.expect(value() != null);
}
fn testTakesValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--break") or std.mem.eql(u8, arg, "--source");
}
test "the value of another option is never a log option" {
    const saved = levels;
    defer {
        levels = saved;
        _ = setenv("XODB_LOG", "info", 1);
    }
    var args = [_][:0]const u8{ "xodb", "--break", "-v", "--source", "--log=loud", "--break", "--log-file", "--break", "--log", "-q", "--break", "-qq", "--break" };
    const rest = init(&args, testTakesValue);
    const kept = [_][]const u8{ "xodb", "--break", "-v", "--source", "--log=loud", "--break", "--log-file", "--break", "--log", "--break", "-qq", "--break" };
    try std.testing.expectEqual(kept.len, rest.len);
    for (kept, rest) |want, got| try std.testing.expectEqualStrings(want, got);
    // Only the "-q" in option position was read.
    try std.testing.expect(on(.render, .warn) and !on(.render, .info));
}
test "debug lines carry the topic and time, and a repeating line is written once per period" {
    const saved = .{ levels, fd };
    defer {
        levels = saved[0];
        fd = saved[1];
    }
    var ends: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&ends));
    defer _ = std.c.close(ends[0]);
    fd = ends[1];
    levels = @splat(.info);
    levels[@intFromEnum(Topic.render)] = .debug;
    for (0..3) |n| {
        once(.debug, .render, "first only {d}\n", .{n});
        try std.testing.expectEqual(n == 0, every(std.time.ns_per_hour, .info, .mcp, "xodb: hourly {d}\n", .{n}));
        try std.testing.expect(every(0, .debug, .render, "each {d}\n", .{n}));
        try std.testing.expect(!every(0, .debug, .mcp, "never {d}\n", .{n}));
        once(.debug, .mcp, "not shown {d}\n", .{n});
    }
    trace(.render, "not shown\n", .{});
    _ = std.c.close(ends[1]);
    var text: [512]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const n = std.c.read(ends[0], text[len..].ptr, text.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    var lines = std.mem.splitScalar(u8, text[0..len], '\n');
    const expected = [_][]const u8{ "first only 0", "xodb: hourly 0", "each 0", "each 1", "each 2" };
    inline for (expected) |want| {
        const line = lines.next().?;
        if (comptime std.mem.startsWith(u8, want, "xodb: ")) try std.testing.expectEqualStrings(want, line) else {
            try std.testing.expect(std.mem.startsWith(u8, line, "xodb[render] +0."));
            try std.testing.expect(std.mem.endsWith(u8, line, "s " ++ want));
        }
    }
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expect(lines.next() == null);
}
