//! Small static live probe of the same collector, for disposable lab guests.
const std = @import("std");
const census = @import("census");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/mount.h");
    @cInclude("sys/stat.h");
});
fn blocked(fd: c_int) void {
    var byte: u8 = 0;
    _ = c.read(fd, &byte, 1);
}
fn cpu() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.PROCESS_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
fn rss() !u64 {
    const fd = c.open("/proc/self/status", c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.RssUnavailable;
    defer _ = c.close(fd);
    var buf: [4096]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return error.RssUnavailable;
    var lines = std.mem.splitScalar(u8, buf[0..@intCast(n)], '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "VmRSS:")) {
        var words = std.mem.tokenizeAny(u8, line[6..], " \t");
        return std.fmt.parseInt(u64, words.next() orelse return error.RssUnavailable, 10);
    };
    return error.RssUnavailable;
}
pub fn main() !void {
    const init = c.getpid() == 1;
    if (init) {
        _ = c.mkdir("/proc", 0o555);
        if (c.mount("proc", "/proc", "proc", 0, null) != 0) return error.ProcMountFailed;
    }
    const pid: i32 = if (std.c.getenv("CENSUS_PID")) |text| try std.fmt.parseInt(i32, std.mem.span(text), 10) else c.getpid();
    if (pid <= 0) return error.OwnedPidRequired;
    var pipe: [2]c_int = undefined;
    if (c.pipe(&pipe) != 0) return error.PipeFailed;
    defer _ = c.close(pipe[0]);
    const one = try std.Thread.spawn(.{}, blocked, .{pipe[0]});
    const two = try std.Thread.spawn(.{}, blocked, .{pipe[0]});
    defer {
        _ = c.close(pipe[1]);
        one.join();
        two.join();
    }
    var root = try census.Dir.open("/proc");
    defer root.close();
    var stop = std.atomic.Value(bool).init(false);
    const before_cpu = cpu();
    const before_rss = try rss();
    var snapshot = try census.collect(root, pid, &stop);
    defer snapshot.deinit();
    const deadline = census.now() + 10 * std.time.ns_per_s;
    if (pid == c.getpid()) while (true) {
        const ready = for (snapshot.groups.items) |g| {
            if (g.status == .ready and g.count >= 2 and std.mem.indexOf(u8, g.stack, "pipe_read") != null) break true;
        } else false;
        if (ready) break;
        if (snapshot.denied > 0) return error.StackAccessDenied;
        if (census.now() > deadline) return error.WorkerStacksMissing;
        var delay = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.c.nanosleep(&delay, null);
        const next = try census.collect(root, pid, &stop);
        snapshot.deinit();
        snapshot = next;
    };
    const after_cpu = cpu();
    const after_rss = try rss();
    const text = try std.json.Stringify.valueAlloc(std.heap.c_allocator, .{
        .tasks = snapshot.tasks.items,
        .groups = snapshot.groups.items,
        .denied = snapshot.denied,
        .unreadable = snapshot.unreadable,
        .truncated = snapshot.truncated,
        .failure = snapshot.failure,
        .elapsed_ns = snapshot.finished_ns -| snapshot.started_ns,
        .cpu_ns = after_cpu -| before_cpu,
        .rss_before_kib = before_rss,
        .rss_after_kib = after_rss,
    }, .{});
    defer std.heap.c_allocator.free(text);
    var written: usize = 0;
    while (written < text.len) {
        const n = std.c.write(1, text[written..].ptr, text.len - written);
        if (n <= 0) return error.OutputFailed;
        written += @intCast(n);
    }
    _ = std.c.write(1, "\n", 1);
    if (init) while (true) {
        _ = c.pause();
    };
}
