//! Tiny raw-syscall file helpers for sysfs, procfs and debugfs: small reads,
//! writes, directory names and link targets, into caller buffers.
const std = @import("std");
const linux = std.os.linux;

pub fn read(buf: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    var pb: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pb, fmt, args) catch return null;
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var used: usize = 0;
    while (used < buf.len) {
        const n = linux.read(fd, buf[used..].ptr, buf.len - used);
        if (linux.errno(n) != .SUCCESS) return if (used > 0) buf[0..used] else null;
        if (n == 0) break;
        used += n;
    }
    return buf[0..used];
}
/// The file's first line, trimmed.
pub fn line(buf: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    const t = read(buf, fmt, args) orelse return null;
    const end = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return std.mem.trim(u8, t[0..end], " \t\r\x00");
}
pub fn number(comptime fmt: []const u8, args: anytype) ?u64 {
    var b: [64]u8 = undefined;
    const t = line(&b, fmt, args) orelse return null;
    if (std.mem.startsWith(u8, t, "0x")) return std.fmt.parseInt(u64, t[2..], 16) catch null;
    return std.fmt.parseInt(u64, t, 10) catch null;
}
pub fn exists(comptime fmt: []const u8, args: anytype) bool {
    var pb: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pb, fmt, args) catch return false;
    return linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS;
}
pub const WriteError = error{ Open, Write, Path };
pub fn write(text: []const u8, comptime fmt: []const u8, args: anytype) WriteError!void {
    var pb: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pb, fmt, args) catch return error.Path;
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Open;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.write(fd, text.ptr, text.len);
    if (linux.errno(n) != .SUCCESS or n != text.len) return error.Write;
}
/// Basename of a symlink's target.
pub fn linkBase(buf: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    var pb: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pb, fmt, args) catch return null;
    const n = linux.readlink(path, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    const t = buf[0..n];
    return t[(std.mem.lastIndexOfScalar(u8, t, '/') orelse return t) + 1 ..];
}
pub fn linkTarget(buf: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    var pb: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pb, fmt, args) catch return null;
    const n = linux.readlink(path, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return buf[0..n];
}

/// Calls `each(context, name)` for every entry but . and ..
pub fn list(comptime fmt: []const u8, args: anytype, context: anytype, comptime each: anytype) void {
    var pb: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pb, fmt, args) catch return;
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) return;
        var at: usize = 0;
        while (at < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(&buf[at]);
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[at + @offsetOf(linux.dirent64, "name")])), 0);
            at += d.reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (!each(context, name)) return;
        }
    }
}

pub fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
pub fn realtimeNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
pub fn isRoot() bool {
    return linux.geteuid() == 0;
}
