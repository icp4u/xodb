//! Collector step for network evidence correlation: at capture start and
//! stop, record a bracketed realtime/monotonic clock pair and the target
//! process's socket endpoints (fd -> socket inode from /proc/PID/fd, joined
//! to its network namespace's /proc/PID/net/{tcp,tcp6,udp,udp6} rows).
//! Unprivileged reads of the debugger's own target only; local targets only
//! (a remote target's /proc is on another host). Encoded as the archive's
//! optional ECTX section; see docs/NETWORK_EVIDENCE.md.
const std = @import("std");
const c = @import("../c.zig").api;
const sockets = @import("../evidence/sockets.zig");
const clock = @import("../evidence/clock.zig");

pub const Recorder = struct {
    arena: std.heap.ArenaAllocator,
    pid: i32,
    started_ns: u64,
    pairs: [2]clock.Pair = undefined,
    pair_count: u8 = 0,
    tables: [2]sockets.Table = undefined,
    table_count: u8 = 0,

    pub fn begin(a: std.mem.Allocator, pid: i32, started_ns: u64) Recorder {
        var self = Recorder{ .arena = std.heap.ArenaAllocator.init(a), .pid = pid, .started_ns = started_ns };
        self.sample(.start);
        return self;
    }
    pub fn deinit(self: *Recorder) void {
        self.arena.deinit();
    }
    pub fn sample(self: *Recorder, when: sockets.When) void {
        if (self.pair_count < self.pairs.len) {
            self.pairs[self.pair_count] = pair();
            self.pair_count += 1;
        }
        if (self.table_count < self.tables.len) {
            self.tables[self.table_count] = read(self.arena.allocator(), self.pid, when) catch return;
            self.table_count += 1;
        }
    }
    /// The ECTX payload, allocated with `a`.
    pub fn encode(self: *const Recorder, a: std.mem.Allocator) ![]u8 {
        return sockets.encode(a, .{ .capture_started_ns = self.started_ns, .pid = self.pid, .pairs = self.pairs[0..self.pair_count], .tables = self.tables[0..self.table_count] });
    }
};

fn now(id: c_int) u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(id, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
/// Realtime read between two monotonic reads; the bracket width bounds the error.
pub fn pair() clock.Pair {
    const before = now(c.CLOCK_MONOTONIC);
    const real = now(c.CLOCK_REALTIME);
    return .{ .monotonic_before_ns = before, .realtime_ns = real, .monotonic_after_ns = now(c.CLOCK_MONOTONIC) };
}

const Held = struct { fd: i32, inode: u64 };
const max_rows = 16384;

pub fn read(a: std.mem.Allocator, pid: i32, when: sockets.When) !sockets.Table {
    var table = sockets.Table{ .when = when, .sampled_ns = now(c.CLOCK_MONOTONIC), .processes = &.{}, .sockets = &.{} };
    var path: [64]u8 = undefined;
    var process = sockets.Process{ .pid = pid };
    if (readSmall(try std.fmt.bufPrintZ(&path, "/proc/{d}/comm", .{pid}), &process.comm)) |n| {
        const name = std.mem.trimEnd(u8, process.comm[0..n], "\n");
        @memset(process.comm[name.len..], 0);
    } else table.unreadable += 1;
    const processes = try a.alloc(sockets.Process, 1);
    processes[0] = process;
    table.processes = processes;
    // Socket inodes this process holds.
    var held: std.ArrayList(Held) = .empty;
    const dir = c.opendir((try std.fmt.bufPrintZ(&path, "/proc/{d}/fd", .{pid})).ptr) orelse {
        table.unreadable += 1;
        return table;
    };
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.*.d_name)), 0);
        const fd = std.fmt.parseInt(i32, name, 10) catch continue;
        var link: [64]u8 = undefined;
        const n = c.readlink((try std.fmt.bufPrintZ(&path, "/proc/{d}/fd/{d}", .{ pid, fd })).ptr, &link, link.len);
        if (n <= 0) continue;
        const inode = sockets.socketInode(link[0..@intCast(n)]) orelse continue;
        if (held.items.len >= sockets.max_sockets) {
            table.truncated = true;
            break;
        }
        try held.append(a, .{ .fd = fd, .inode = inode });
    }
    // Rows of the process's network namespace, joined by inode.
    var out: std.ArrayList(sockets.Socket) = .empty;
    const rows = try a.alloc(sockets.Row, max_rows);
    const text = try a.alloc(u8, 4 * 1024 * 1024);
    for ([_]struct { []const u8, sockets.Protocol, @import("../evidence/decode.zig").Family }{
        .{ "tcp", .tcp, .ipv4 }, .{ "tcp6", .tcp, .ipv6 }, .{ "udp", .udp, .ipv4 }, .{ "udp6", .udp, .ipv6 },
    }) |kind| {
        const len = readSmall(try std.fmt.bufPrintZ(&path, "/proc/{d}/net/{s}", .{ pid, kind[0] }), text) orelse {
            table.unreadable += 1;
            continue;
        };
        if (len == text.len) table.truncated = true;
        var bad: u32 = 0;
        const count = sockets.parseTable(text[0..len], kind[2], rows, &bad);
        table.unreadable += bad;
        for (rows[0..count]) |row| for (held.items) |h| if (h.inode == row.inode) {
            try out.append(a, .{ .pid = pid, .fd = h.fd, .inode = row.inode, .protocol = kind[1], .family = row.family, .local = row.local, .local_port = row.local_port, .remote = row.remote, .remote_port = row.remote_port, .state = row.state });
        };
    }
    table.sockets = out.items;
    return table;
}

fn readSmall(path: [:0]const u8, buffer: []u8) ?usize {
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var used: usize = 0;
    while (used < buffer.len) {
        const n = c.read(fd, buffer.ptr + used, buffer.len - used);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n < 0) return null;
        if (n == 0) break;
        used += @intCast(n);
    }
    return used;
}

test "records this process's own loopback socket" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sc = std.c;
    const s = sc.socket(sc.AF.INET, sc.SOCK.DGRAM | sc.SOCK.CLOEXEC, 0);
    try std.testing.expect(s >= 0);
    defer _ = sc.close(s);
    var addr = sc.sockaddr.in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    try std.testing.expectEqual(@as(c_int, 0), sc.bind(s, @ptrCast(&addr), @sizeOf(sc.sockaddr.in)));
    var len: sc.socklen_t = @sizeOf(sc.sockaddr.in);
    try std.testing.expectEqual(@as(c_int, 0), sc.getsockname(s, @ptrCast(&addr), &len));
    const port = std.mem.bigToNative(u16, addr.port);
    const table = try read(arena.allocator(), c.getpid(), .start);
    var found = false;
    for (table.sockets) |sock| {
        if (sock.fd == s) {
            try std.testing.expectEqual(port, sock.local_port);
            try std.testing.expectEqual(sockets.Protocol.udp, sock.protocol);
            found = true;
        }
    }
    try std.testing.expect(found);
    const p = pair();
    try std.testing.expect(p.monotonic_after_ns >= p.monotonic_before_ns);
}
