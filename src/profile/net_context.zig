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
const redact = @import("../redact.zig");

pub const Recorder = struct {
    arena: std.heap.ArenaAllocator,
    pid: i32,
    started_ns: u64,
    /// A remote target's /proc belongs to the agent host and is unavailable
    /// here. Keep an empty recorder so its archive still carries valid ECTX.
    remote: bool = false,
    pairs: [2]clock.Pair = undefined,
    pair_count: u8 = 0,
    tables: [2]sockets.Table = undefined,
    table_count: u8 = 0,

    pub fn begin(a: std.mem.Allocator, pid: i32, started_ns: u64) Recorder {
        var self = Recorder{ .arena = std.heap.ArenaAllocator.init(a), .pid = pid, .started_ns = started_ns };
        self.sample(.start);
        return self;
    }
    pub fn beginRemote(a: std.mem.Allocator, pid: i32, started_ns: u64) Recorder {
        return .{ .arena = std.heap.ArenaAllocator.init(a), .pid = pid, .started_ns = started_ns, .remote = true };
    }
    pub fn deinit(self: *Recorder) void {
        self.arena.deinit();
    }
    pub fn sample(self: *Recorder, when: sockets.When) void {
        if (self.remote) return;
        if (self.pair_count < self.pairs.len) {
            self.pairs[self.pair_count] = pair();
            self.pair_count += 1;
        }
        if (self.table_count < self.tables.len) {
            self.tables[self.table_count] = read(self.arena.allocator(), self.pid, when) catch return;
            self.table_count += 1;
        }
    }
    /// The ECTX payload, allocated with `a`; redacted under `policy` (the
    /// archive's own key).
    pub fn encode(self: *const Recorder, a: std.mem.Allocator, policy: ?*const redact.Policy) ![]u8 {
        const ctx = sockets.Context{ .capture_started_ns = self.started_ns, .pid = self.pid, .pairs = self.pairs[0..self.pair_count], .tables = self.tables[0..self.table_count], .collection = if (self.remote) .not_collected_remote else .collected };
        const p = policy orelse return sockets.encode(a, ctx);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        return sockets.encode(a, try redacted(arena.allocator(), ctx, p));
    }
    pub fn encodeUsb(self: *const Recorder, a: std.mem.Allocator, policy: ?*const redact.Policy) ![]u8 {
        const ctx = sockets.Context{ .capture_started_ns = self.started_ns, .pid = self.pid, .pairs = self.pairs[0..self.pair_count], .tables = self.tables[0..self.table_count], .collection = if (self.remote) .not_collected_remote else .collected };
        const p = policy orelse return sockets.encodeUsb(a, ctx);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        return sockets.encodeUsb(a, try redacted(arena.allocator(), ctx, p));
    }
    pub fn hasUsb(self: *const Recorder) bool {
        for (self.tables[0..self.table_count]) |table| if (table.usb_fds.len != 0) return true;
        return false;
    }
};

test "remote recorder emits a valid empty ECTX in both archive modes" {
    const a = std.testing.allocator;
    var recorder = Recorder.beginRemote(a, 17, 1_000);
    defer recorder.deinit();
    recorder.sample(.stop);
    try std.testing.expectEqual(@as(u8, 0), recorder.pair_count);
    try std.testing.expectEqual(@as(u8, 0), recorder.table_count);

    const plain = try recorder.encode(a, null);
    defer a.free(plain);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const plain_context = try sockets.decodeContext(arena.allocator(), plain);
    try std.testing.expectEqual(sockets.schema, plain[0]);
    try std.testing.expectEqual(@as(usize, 0), plain_context.pairs.len);
    try std.testing.expectEqual(@as(usize, 0), plain_context.tables.len);
    try std.testing.expectEqual(sockets.Collection.not_collected_remote, plain_context.collection);

    const policy = redact.Policy.init(@splat(3));
    const masked = try recorder.encode(a, &policy);
    defer a.free(masked);
    const masked_context = try sockets.decodeContext(arena.allocator(), masked);
    try std.testing.expectEqual(sockets.schema_redacted, masked[0]);
    try std.testing.expect(masked_context.redacted);
    try std.testing.expectEqual(@as(usize, 0), masked_context.pairs.len);
    try std.testing.expectEqual(@as(usize, 0), masked_context.tables.len);
    try std.testing.expectEqualStrings("not collected: remote", masked_context.collection.reason().?);
}

/// A copy of `ctx` for a shared archive: addresses outside loopback and the
/// documentation ranges become tags under `policy`'s key (one per archive,
/// never stored: stable within the archive, unlinkable across archives) and
/// process names are masked. Allocates in `a` (an arena).
pub fn redacted(a: std.mem.Allocator, ctx: sockets.Context, policy: *const redact.Policy) !sockets.Context {
    const tables = try a.alloc(sockets.Table, ctx.tables.len);
    for (ctx.tables, tables) |t, *out| {
        const processes = try a.dupe(sockets.Process, t.processes);
        for (processes) |*p| policy.mask(&p.comm);
        const socks = try a.dupe(sockets.Socket, t.sockets);
        for (socks) |*sock| {
            const v6 = sock.family == .ipv6;
            if (!sock.local_tagged and redact.privateAddress(v6, sock.local)) {
                sock.local = policy.tag16("ip", &sock.local);
                sock.local_tagged = true;
            }
            if (!sock.remote_tagged and redact.privateAddress(v6, sock.remote)) {
                sock.remote = policy.tag16("ip", &sock.remote);
                sock.remote_tagged = true;
            }
        }
        out.* = t;
        out.processes = processes;
        out.sockets = socks;
    }
    var copy = ctx;
    copy.tables = tables;
    copy.redacted = true;
    return copy;
}

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
    var usb_fds: std.ArrayList(sockets.UsbFd) = .empty;
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
        const target = link[0..@intCast(n)];
        if (sockets.usbDevicePath(target)) |usb| {
            if (usb_fds.items.len >= sockets.max_usb_fds) {
                table.truncated = true;
                break;
            }
            try usb_fds.append(a, .{ .pid = pid, .fd = fd, .bus = usb.bus, .device = usb.device });
        }
        const inode = sockets.socketInode(target) orelse continue;
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
    table.usb_fds = usb_fds.items;
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

test "redacted context: private ends tagged with the archive key, loopback and names" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const decode = @import("../evidence/decode.zig");
    const lo = decode.v4(127, 0, 0, 1);
    const lan = decode.v4(10, 20, 30, 40);
    const peer = decode.v4(172, 16, 9, 9);
    var comm: [16]u8 = @splat(0);
    @memcpy(comm[0..10], "zed-client");
    const socks = [_]sockets.Socket{
        .{ .pid = 7, .fd = 3, .inode = 11, .protocol = .tcp, .family = .ipv4, .local = lo, .local_port = 1, .remote = lo, .remote_port = 2, .state = 1 },
        .{ .pid = 7, .fd = 4, .inode = 12, .protocol = .tcp, .family = .ipv4, .local = lan, .local_port = 3, .remote = peer, .remote_port = 443, .state = 1 },
    };
    const tables = [_]sockets.Table{.{ .when = .stop, .sampled_ns = 2_000, .processes = &.{.{ .pid = 7, .comm = comm }}, .sockets = &socks }};
    const ctx = sockets.Context{ .capture_started_ns = 1_000, .pid = 7, .pairs = &.{}, .tables = &tables };
    var policy = redact.Policy.init(@splat(3));
    policy.add(.user, "zed");
    const bytes = try sockets.encode(a, try redacted(arena.allocator(), ctx, &policy));
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, lan[0..4]) == null and std.mem.indexOf(u8, bytes, peer[0..4]) == null and std.mem.indexOf(u8, bytes, "zed") == null);
    const back = try sockets.decodeContext(arena.allocator(), bytes);
    const s = back.tables[0].sockets;
    try std.testing.expect(back.redacted and !s[0].local_tagged and s[1].local_tagged and s[1].remote_tagged);
    try std.testing.expectEqualSlices(u8, &lo, &s[0].local);
    try std.testing.expectEqualSlices(u8, &policy.tag16("ip", &peer), &s[1].remote);
    // Another archive, another key: the same peer is not linkable.
    const other = policy.rekeyed(@splat(4));
    try std.testing.expect(!std.mem.eql(u8, &other.tag16("ip", &peer), &s[1].remote));
}
