//! Local socket endpoints observed at capture time, and the join from a
//! packet's 5-tuple to the process that held the socket.
//!
//! The collector (src/profile/net_context.zig) reads the target's
//! /proc/PID/fd socket inodes and its network namespace's /proc/PID/net
//! tables at capture start and stop, together with bracketed realtime/
//! monotonic clock pairs. This file holds the pure parts: the /proc/net
//! table parser, the archive encoding (ECTX section) and the join.
const std = @import("std");
const decode = @import("decode.zig");
const clock = @import("clock.zig");

pub const Protocol = enum(u8) { tcp = 6, udp = 17 };
pub const Socket = struct {
    pid: i32,
    fd: i32,
    inode: u64,
    protocol: Protocol,
    family: decode.Family,
    local: [16]u8,
    local_port: u16,
    remote: [16]u8,
    remote_port: u16,
    /// Kernel socket state as /proc/net prints it (TCP: 1 established, 10 listen; UDP: 7 unconnected, 1 connected).
    state: u8,
    /// Written under --redact: the address is a keyed tag (src/redact.zig `tag16`)
    /// whose key was never stored. It matches no packet.
    local_tagged: bool = false,
    remote_tagged: bool = false,

    pub fn connected(self: Socket) bool {
        return self.remote_port != 0 and !std.mem.allEqual(u8, &self.remote, 0);
    }
};
pub const Process = struct { pid: i32, comm: [16]u8 = @splat(0) };
/// A process descriptor whose symlink was exactly /dev/bus/usb/BBB/DDD.
/// Only the numeric kernel device identity is archived; no path text is kept.
pub const UsbFd = struct { pid: i32, fd: i32, bus: u16, device: u16 };
pub const When = enum(u8) { start, stop };
pub const Table = struct {
    when: When,
    /// CLOCK_MONOTONIC when the table was read.
    sampled_ns: u64,
    processes: []const Process,
    sockets: []const Socket,
    usb_fds: []const UsbFd = &.{},
    /// Rows or descriptors not read: permission, a vanished process, the row limit.
    unreadable: u32 = 0,
    truncated: bool = false,
};
pub const max_sockets = 65536;
pub const max_usb_fds = 65536;
pub const max_processes = 1024;
pub const max_tables = 8;
pub const max_pairs = 8;

/// Collector evidence stored beside a capture (archive section ECTX).
pub const Context = struct {
    capture_started_ns: u64,
    pid: i32,
    pairs: []const clock.Pair,
    tables: []const Table,
    /// Written under --redact (schema 2): private addresses are tags, names masked.
    redacted: bool = false,

    pub fn mapping(self: *const Context) clock.Mapping {
        return clock.fromPairs(self.pairs);
    }
};

// ------------------------------------------------------------- /proc/net

pub const Row = struct { inode: u64, family: decode.Family, local: [16]u8, local_port: u16, remote: [16]u8, remote_port: u16, state: u8 };

/// Parses one /proc/net/{tcp,tcp6,udp,udp6} table. Addresses are printed as
/// 32-bit words in host byte order; ports in hexadecimal. Malformed lines
/// are counted, never guessed.
pub fn parseTable(text: []const u8, family: decode.Family, out: []Row, bad: *u32) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        if (n == out.len) {
            bad.* += 1;
            continue;
        }
        if (parseRow(line, family)) |row| {
            out[n] = row;
            n += 1;
        } else bad.* += 1;
    }
    return n;
}
fn parseRow(line: []const u8, family: decode.Family) ?Row {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    _ = fields.next() orelse return null; // sl
    const local = fields.next() orelse return null;
    const remote = fields.next() orelse return null;
    const state = fields.next() orelse return null;
    // tx:rx, tr:when, retrnsmt, uid, timeout, then inode.
    for (0..5) |_| _ = fields.next() orelse return null;
    const inode = fields.next() orelse return null;
    var row = Row{ .inode = std.fmt.parseInt(u64, inode, 10) catch return null, .family = family, .local = undefined, .local_port = 0, .remote = undefined, .remote_port = 0, .state = std.fmt.parseInt(u8, state, 16) catch return null };
    endpoint(local, family, &row.local, &row.local_port) orelse return null;
    endpoint(remote, family, &row.remote, &row.remote_port) orelse return null;
    return row;
}
fn endpoint(text: []const u8, family: decode.Family, addr: *[16]u8, port: *u16) ?void {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const hex = text[0..colon];
    const words: usize = if (family == .ipv4) 1 else 4;
    if (hex.len != words * 8) return null;
    addr.* = @splat(0);
    for (0..words) |i| {
        const word = std.fmt.parseInt(u32, hex[i * 8 ..][0..8], 16) catch return null;
        // The kernel prints each 32-bit word of the network-order address as a host integer.
        std.mem.writeInt(u32, addr[i * 4 ..][0..4], word, @import("builtin").cpu.arch.endian());
    }
    port.* = std.fmt.parseInt(u16, text[colon + 1 ..], 16) catch return null;
}

/// "socket:[12345]" -> 12345.
pub fn socketInode(link: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, link, "socket:[") or !std.mem.endsWith(u8, link, "]")) return null;
    return std.fmt.parseInt(u64, link[8 .. link.len - 1], 10) catch null;
}

/// Exact Linux usbfs node syntax. Suffixes, relative paths and other /dev
/// nodes are deliberately rejected so an archive cannot make a guessed join.
pub fn usbDevicePath(link: []const u8) ?struct { bus: u16, device: u16 } {
    const prefix = "/dev/bus/usb/";
    if (!std.mem.startsWith(u8, link, prefix)) return null;
    const rest = link[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash == 0 or slash + 1 == rest.len or std.mem.indexOfScalar(u8, rest[slash + 1 ..], '/') != null) return null;
    const bus = std.fmt.parseInt(u16, rest[0..slash], 10) catch return null;
    const device = std.fmt.parseInt(u16, rest[slash + 1 ..], 10) catch return null;
    if (bus == 0 or device == 0) return null;
    return .{ .bus = bus, .device = device };
}

// ------------------------------------------------------------- join

pub const Basis = enum(u8) {
    /// Protocol and both endpoints equal a connected socket that the process
    /// held, and the packet's aligned time is bracketed by tables that both
    /// show that same socket (same inode and tuple), or lies within the clock
    /// uncertainty of one that does.
    exact,
    /// The same 5-tuple match, but no tables bracket the packet's time with
    /// that socket (it was seen only before or only after, the packet is
    /// outside the tables, or the stream is unaligned): another socket or
    /// process may have held the tuple then.
    sampled,
    /// Only the local endpoint matched a listening or unconnected socket.
    inferred,
    none,
};
pub const Join = struct {
    basis: Basis = .none,
    socket: ?Socket = null,
    table: ?usize = null,
    /// True when the packet's source is the socket's local end.
    outbound: bool = false,
    process: ?Process = null,
    reason: []const u8 = "no socket in the capture's tables matches this packet",
};

pub const UsbJoin = struct {
    basis: Basis = .none,
    device_fd: ?UsbFd = null,
    table: ?usize = null,
    process: ?Process = null,
    reason: []const u8 = "no USB device descriptor in the capture's tables matches this bus and device address",
};

/// Join a usbmon record to a usbfs descriptor sampled in ECTX. usbmon does
/// not name the URB submitter: kernel drivers and every other holder of the
/// device share its traffic. So a join is never `exact`. A descriptor held in
/// the tables that bracket the record's time is `sampled`; a one-sided or
/// unaligned observation is `inferred`.
pub fn correlateUsb(ctx: *const Context, bus: u16, device: u16, time: ?u64) UsbJoin {
    var best = UsbJoin{};
    for (ctx.tables, 0..) |table, ti| for (table.usb_fds) |fd| {
        if (fd.bus != bus or fd.device != device) continue;
        const within = if (time) |t| usbHeldAt(ctx, fd, t) else false;
        const basis: Basis = if (within) .sampled else .inferred;
        if (@intFromEnum(basis) < @intFromEnum(best.basis)) best = .{
            .basis = basis,
            .device_fd = fd,
            .table = ti,
            .process = processOf(table, fd.pid),
            .reason = if (within)
                "the process held a usbfs descriptor for this bus and device address in the tables that bracket the record's time; usbmon does not say which holder (or kernel driver) submitted the URB"
            else if (time == null)
                "bus and device address equal a sampled usbfs descriptor, but the stream is not aligned to the capture clock; addresses can be reused"
            else
                "bus and device address equal a sampled usbfs descriptor, but no tables holding it bracket the record's time; addresses can be reused",
        };
    };
    return best;
}

fn usbHeldAt(ctx: *const Context, fd: UsbFd, t: u64) bool {
    const u = slack(ctx);
    var before: ?Table = null;
    var after: ?Table = null;
    for (ctx.tables) |table| {
        const shows = holdsUsb(table, fd);
        if (shows and t +| u >= table.sampled_ns and t <= table.sampled_ns +| u) return true;
        if (table.sampled_ns <= t and (before == null or table.sampled_ns > before.?.sampled_ns)) before = table;
        if (table.sampled_ns >= t and (after == null or table.sampled_ns < after.?.sampled_ns)) after = table;
    }
    return before != null and after != null and holdsUsb(before.?, fd) and holdsUsb(after.?, fd);
}

fn holdsUsb(table: Table, fd: UsbFd) bool {
    for (table.usb_fds) |other| if (other.pid == fd.pid and other.fd == fd.fd and other.bus == fd.bus and other.device == fd.device) return true;
    return false;
}

/// `time` is the packet time already mapped to the capture's monotonic clock, or null.
pub fn correlate(ctx: *const Context, flow: decode.Flow, time: ?u64) Join {
    const protocol: Protocol = switch (flow.protocol) {
        6 => .tcp,
        17 => .udp,
        else => return .{ .reason = "only TCP and UDP flows have socket endpoints" },
    };
    var best = Join{};
    for (ctx.tables, 0..) |table, ti| for (table.sockets) |s| {
        // A tag (redacted archive) names no address a packet could carry.
        if (s.protocol != protocol or s.family != flow.family or s.local_tagged) continue;
        for ([_]bool{ true, false }) |outbound| {
            const here = if (outbound) flow else flow.reversed();
            if (!sameAddress(s.local, here.src, s.family) or s.local_port != here.src_port) continue;
            if (s.connected()) {
                if (s.remote_tagged) continue;
                if (!std.mem.eql(u8, &s.remote, &here.dst) or s.remote_port != here.dst_port) continue;
                const within = if (time) |t| heldAt(ctx, s, t) else false;
                const basis: Basis = if (within) .exact else .sampled;
                if (@intFromEnum(basis) < @intFromEnum(best.basis)) best = .{ .basis = basis, .socket = s, .table = ti, .outbound = outbound, .process = processOf(table, s.pid), .reason = if (within) "protocol and both endpoints equal a connected socket held by the process in the tables that bracket the packet's time" else if (time == null) "endpoints equal a connected socket, but the stream is not aligned to the capture clock" else "endpoints equal a connected socket, but no tables holding that socket bracket the packet's time: another socket or process may have held the tuple then" };
            } else if (@intFromEnum(Basis.inferred) < @intFromEnum(best.basis)) {
                best = .{ .basis = .inferred, .socket = s, .table = ti, .outbound = outbound, .process = processOf(table, s.pid), .reason = "local endpoint only: a listening or unconnected socket; the remote end is not part of its identity" };
            }
        }
    };
    return best;
}
fn sameAddress(local: [16]u8, packet: [16]u8, family: decode.Family) bool {
    // A socket bound to the wildcard address accepts any local address.
    const n: usize = if (family == .ipv4) 4 else 16;
    return std.mem.allEqual(u8, local[0..n], 0) or std.mem.eql(u8, local[0..n], packet[0..n]);
}
fn processOf(table: Table, pid: i32) ?Process {
    for (table.processes) |p| if (p.pid == pid) return p;
    return null;
}
/// Whether socket `s` (same pid, inode and tuple) provably held its tuple at
/// `t`: a table within the clock uncertainty of `t` shows it, or the nearest
/// tables before and after `t` both show it (tables are snapshots; a socket in
/// only one of them may have been opened or closed, and its tuple reused, in
/// between).
fn heldAt(ctx: *const Context, s: Socket, t: u64) bool {
    const u = slack(ctx);
    var before: ?Table = null;
    var after: ?Table = null;
    for (ctx.tables) |table| {
        const shows = holds(table, s);
        if (shows and t +| u >= table.sampled_ns and t <= table.sampled_ns +| u) return true;
        if (table.sampled_ns <= t and (before == null or table.sampled_ns > before.?.sampled_ns)) before = table;
        if (table.sampled_ns >= t and (after == null or table.sampled_ns < after.?.sampled_ns)) after = table;
    }
    return before != null and after != null and holds(before.?, s) and holds(after.?, s);
}
fn holds(table: Table, s: Socket) bool {
    for (table.sockets) |o| if (o.pid == s.pid and o.inode == s.inode and o.protocol == s.protocol and o.family == s.family and std.mem.eql(u8, &o.local, &s.local) and o.local_port == s.local_port and std.mem.eql(u8, &o.remote, &s.remote) and o.remote_port == s.remote_port) return true;
    return false;
}
fn slack(ctx: *const Context) u64 {
    return ctx.mapping().uncertainty_ns;
}

// ------------------------------------------------------------- ECTX encoding

pub const schema: u8 = 1;
/// Schema 2: redacted; each socket carries a byte saying which ends are tags.
pub const schema_redacted: u8 = 2;
/// Schemas 3/4 were briefly used to append USB descriptor rows to ECTX.
/// Decoders retain them for compatibility, but archives now put those rows in
/// a separate ignorable EUSB section so 2.9 readers can still decode ECTX.
pub const schema_usb: u8 = 3;
pub const schema_usb_redacted: u8 = 4;
pub const usb_schema: u8 = 1;

/// An address for display: a tag prints as ip-XXXXXXXX (its first 4 bytes).
pub fn formatEnd(buf: *[64]u8, family: decode.Family, addr: [16]u8, tagged: bool) []const u8 {
    if (!tagged) return decode.formatAddress(buf, family, addr);
    return std.fmt.bufPrint(buf, "ip-{s}", .{&std.fmt.bytesToHex(addr[0..4].*, .lower)}) catch unreachable;
}
pub const max_bytes = 16 * 1024 * 1024;

pub fn encode(a: std.mem.Allocator, ctx: Context) ![]u8 {
    if (ctx.pairs.len > max_pairs or ctx.tables.len > max_tables) return error.EvidenceContextLimit;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const W = struct {
        fn int(o: *std.ArrayList(u8), al: std.mem.Allocator, comptime T: type, v: T) !void {
            var buf: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &buf, v, .little);
            try o.appendSlice(al, &buf);
        }
    };
    const version: u8 = if (ctx.redacted) schema_redacted else schema;
    try out.append(a, version);
    try W.int(&out, a, u64, ctx.capture_started_ns);
    try W.int(&out, a, i32, ctx.pid);
    try out.append(a, @intCast(ctx.pairs.len));
    for (ctx.pairs) |p| for ([_]u64{ p.monotonic_before_ns, p.realtime_ns, p.monotonic_after_ns }) |v| try W.int(&out, a, u64, v);
    try out.append(a, @intCast(ctx.tables.len));
    for (ctx.tables) |t| {
        if (t.processes.len > max_processes or t.sockets.len > max_sockets or t.usb_fds.len > max_usb_fds) return error.EvidenceContextLimit;
        try out.append(a, @intFromEnum(t.when));
        try W.int(&out, a, u64, t.sampled_ns);
        try W.int(&out, a, u32, t.unreadable);
        try out.append(a, @intFromBool(t.truncated));
        try W.int(&out, a, u32, @intCast(t.processes.len));
        for (t.processes) |p| {
            try W.int(&out, a, i32, p.pid);
            try out.appendSlice(a, &p.comm);
        }
        try W.int(&out, a, u32, @intCast(t.sockets.len));
        for (t.sockets) |s| {
            try W.int(&out, a, i32, s.pid);
            try W.int(&out, a, i32, s.fd);
            try W.int(&out, a, u64, s.inode);
            try out.append(a, @intFromEnum(s.protocol));
            try out.append(a, @intFromEnum(s.family));
            try out.appendSlice(a, &s.local);
            try W.int(&out, a, u16, s.local_port);
            try out.appendSlice(a, &s.remote);
            try W.int(&out, a, u16, s.remote_port);
            try out.append(a, s.state);
            if (ctx.redacted) try out.append(a, @as(u8, @intFromBool(s.local_tagged)) | @as(u8, @intFromBool(s.remote_tagged)) << 1);
        }
    }
    return out.toOwnedSlice(a);
}

/// USB descriptor rows for archive section EUSB. Table identity and all
/// non-USB fields remain in ECTX; the table count binds the two payloads.
pub fn encodeUsb(a: std.mem.Allocator, ctx: Context) ![]u8 {
    if (ctx.tables.len > max_tables) return error.EvidenceContextLimit;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const W = struct {
        fn int(o: *std.ArrayList(u8), al: std.mem.Allocator, comptime T: type, v: T) !void {
            var buf: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &buf, v, .little);
            try o.appendSlice(al, &buf);
        }
    };
    try out.append(a, usb_schema);
    try out.append(a, @intCast(ctx.tables.len));
    for (ctx.tables) |table| {
        if (table.usb_fds.len > max_usb_fds) return error.EvidenceContextLimit;
        try W.int(&out, a, u32, @intCast(table.usb_fds.len));
        for (table.usb_fds) |fd| {
            try W.int(&out, a, i32, fd.pid);
            try W.int(&out, a, i32, fd.fd);
            try W.int(&out, a, u16, fd.bus);
            try W.int(&out, a, u16, fd.device);
        }
    }
    return out.toOwnedSlice(a);
}

/// Decodes into `a` (an arena). Every count and enum is checked; trailing bytes fail.
pub fn decodeContext(a: std.mem.Allocator, bytes: []const u8) !Context {
    if (bytes.len > max_bytes) return error.EvidenceContextLimit;
    var r = Reader{ .bytes = bytes };
    const version = try r.byte();
    if (version != schema and version != schema_redacted and version != schema_usb and version != schema_usb_redacted) return error.EvidenceContextSchema;
    const is_redacted = version == schema_redacted or version == schema_usb_redacted;
    const has_usb = version == schema_usb or version == schema_usb_redacted;
    const started = try r.int(u64);
    const pid = try r.int(i32);
    const pair_count = try r.byte();
    if (pair_count > max_pairs) return error.EvidenceContextLimit;
    const pairs = try a.alloc(clock.Pair, pair_count);
    for (pairs) |*p| p.* = .{ .monotonic_before_ns = try r.int(u64), .realtime_ns = try r.int(u64), .monotonic_after_ns = try r.int(u64) };
    const table_count = try r.byte();
    if (table_count > max_tables) return error.EvidenceContextLimit;
    const tables = try a.alloc(Table, table_count);
    for (tables) |*t| {
        const when = std.enums.fromInt(When, try r.byte()) orelse return error.EvidenceContextValue;
        const sampled = try r.int(u64);
        const unreadable = try r.int(u32);
        const truncated = switch (try r.byte()) {
            0 => false,
            1 => true,
            else => return error.EvidenceContextValue,
        };
        const pc = try r.int(u32);
        if (pc > max_processes or pc * 20 > r.left()) return error.EvidenceContextLimit;
        const processes = try a.alloc(Process, pc);
        for (processes) |*p| {
            p.pid = try r.int(i32);
            p.comm = (try r.take(16))[0..16].*;
        }
        const sc = try r.int(u32);
        if (sc > max_sockets or sc * @as(usize, if (is_redacted) 56 else 55) > r.left()) return error.EvidenceContextLimit;
        const sockets = try a.alloc(Socket, sc);
        for (sockets) |*s| {
            s.pid = try r.int(i32);
            s.fd = try r.int(i32);
            s.inode = try r.int(u64);
            s.protocol = std.enums.fromInt(Protocol, try r.byte()) orelse return error.EvidenceContextValue;
            s.family = std.enums.fromInt(decode.Family, try r.byte()) orelse return error.EvidenceContextValue;
            if (s.family == .none) return error.EvidenceContextValue;
            s.local = (try r.take(16))[0..16].*;
            s.local_port = try r.int(u16);
            s.remote = (try r.take(16))[0..16].*;
            s.remote_port = try r.int(u16);
            s.state = try r.byte();
            s.local_tagged = false;
            s.remote_tagged = false;
            if (is_redacted) {
                const tags = try r.byte();
                if (tags > 3) return error.EvidenceContextValue;
                s.local_tagged = tags & 1 != 0;
                s.remote_tagged = tags & 2 != 0;
            }
        }
        const usb_fds = if (has_usb) blk: {
            const count = try r.int(u32);
            if (count > max_usb_fds or count * 12 > r.left()) return error.EvidenceContextLimit;
            const fds = try a.alloc(UsbFd, count);
            for (fds) |*fd| fd.* = .{ .pid = try r.int(i32), .fd = try r.int(i32), .bus = try r.int(u16), .device = try r.int(u16) };
            break :blk fds;
        } else &.{};
        t.* = .{ .when = when, .sampled_ns = sampled, .unreadable = unreadable, .truncated = truncated, .processes = processes, .sockets = sockets, .usb_fds = usb_fds };
    }
    if (r.left() != 0) return error.EvidenceContextTrailingBytes;
    return .{ .capture_started_ns = started, .pid = pid, .pairs = pairs, .tables = tables, .redacted = is_redacted };
}

/// Decodes ECTX and, when present, attaches its optional EUSB rows.
pub fn decodeContextWithUsb(a: std.mem.Allocator, bytes: []const u8, usb_bytes: ?[]const u8) !Context {
    const ctx = try decodeContext(a, bytes);
    const payload = usb_bytes orelse return ctx;
    if (payload.len > max_bytes) return error.EvidenceContextLimit;
    var r = Reader{ .bytes = payload };
    if (try r.byte() != usb_schema) return error.EvidenceContextSchema;
    const count = try r.byte();
    if (count != ctx.tables.len) return error.EvidenceContextValue;
    const tables: []Table = @constCast(ctx.tables);
    for (tables) |*table| {
        const n = try r.int(u32);
        if (n > max_usb_fds or n * 12 > r.left()) return error.EvidenceContextLimit;
        const fds = try a.alloc(UsbFd, n);
        for (fds) |*fd| fd.* = .{ .pid = try r.int(i32), .fd = try r.int(i32), .bus = try r.int(u16), .device = try r.int(u16) };
        table.usb_fds = fds;
    }
    if (r.left() != 0) return error.EvidenceContextTrailingBytes;
    return ctx;
}
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    fn left(self: *const Reader) usize {
        return self.bytes.len - self.at;
    }
    fn take(self: *Reader, n: usize) ![]const u8 {
        if (self.left() < n) return error.EvidenceContextTruncated;
        defer self.at += n;
        return self.bytes[self.at..][0..n];
    }
    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    fn int(self: *Reader, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
};

// ------------------------------------------------------------- tests

test "proc net tables parse both families" {
    const v4text =
        \\  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        \\   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 4242 1 0000000000000000 100 0 0 10 0
        \\   1: 0100007F:9C40 0100007F:1F90 01 00000000:00000000 00:00000000 00000000  1000        0 4343 1 0000000000000000 20 4 30 10 -1
        \\   2: garbage
    ;
    var rows: [8]Row = undefined;
    var bad: u32 = 0;
    const n = parseTable(v4text, .ipv4, &rows, &bad);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 1), bad);
    try std.testing.expectEqual(@as(u16, 8080), rows[0].local_port);
    try std.testing.expectEqual(@as(u8, 0x0a), rows[0].state);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, rows[1].local[0..4]);
    try std.testing.expectEqual(@as(u64, 4343), rows[1].inode);
    const v6text =
        \\  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        \\   0: 00000000000000000000000001000000:0035 00000000000000000000000000000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 77 2 0000000000000000 0
    ;
    const m = parseTable(v6text, .ipv6, &rows, &bad);
    try std.testing.expectEqual(@as(usize, 1), m);
    var expect: [16]u8 = @splat(0);
    expect[15] = 1;
    try std.testing.expectEqualSlices(u8, &expect, &rows[0].local);
    try std.testing.expectEqual(@as(u16, 53), rows[0].local_port);
    try std.testing.expectEqual(@as(?u64, 99), socketInode("socket:[99]"));
    try std.testing.expectEqual(@as(?u64, null), socketInode("pipe:[99]"));
    try std.testing.expectEqual(@as(u16, 12), usbDevicePath("/dev/bus/usb/012/034").?.bus);
    try std.testing.expectEqual(@as(u16, 34), usbDevicePath("/dev/bus/usb/012/034").?.device);
    try std.testing.expect(usbDevicePath("/dev/bus/usb/012/034/deleted") == null);
    try std.testing.expect(usbDevicePath("/dev/hidraw0") == null);
}

test "USB descriptors use an optional extension and join only when sampled" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var comm: [16]u8 = @splat(0);
    @memcpy(comm[0..7], "fixture");
    const held = UsbFd{ .pid = 17, .fd = 9, .bus = 3, .device = 5 };
    const tables = [_]Table{
        .{ .when = .start, .sampled_ns = 1_000, .processes = &.{.{ .pid = 17, .comm = comm }}, .sockets = &.{}, .usb_fds = &.{held} },
        .{ .when = .stop, .sampled_ns = 5_000, .processes = &.{.{ .pid = 17, .comm = comm }}, .sockets = &.{}, .usb_fds = &.{held} },
    };
    const ctx = Context{ .capture_started_ns = 1_000, .pid = 17, .pairs = &.{.{ .monotonic_before_ns = 10, .realtime_ns = 100, .monotonic_after_ns = 12 }}, .tables = &tables };
    const bytes = try encode(a, ctx);
    defer a.free(bytes);
    try std.testing.expectEqual(schema, bytes[0]);
    const usb_bytes = try encodeUsb(a, ctx);
    defer a.free(usb_bytes);
    const legacy = try decodeContext(arena.allocator(), bytes);
    try std.testing.expectEqual(@as(usize, 0), legacy.tables[0].usb_fds.len);
    const back = try decodeContextWithUsb(arena.allocator(), bytes, usb_bytes);
    try std.testing.expectEqual(@as(usize, 1), back.tables[0].usb_fds.len);
    try std.testing.expectEqual(@as(i32, 9), back.tables[0].usb_fds[0].fd);
    const bracketed = correlateUsb(&back, 3, 5, 3_000);
    try std.testing.expectEqual(Basis.sampled, bracketed.basis);
    try std.testing.expectEqual(@as(i32, 17), bracketed.process.?.pid);
    try std.testing.expectEqual(Basis.inferred, correlateUsb(&back, 3, 5, null).basis);
    try std.testing.expectEqual(Basis.none, correlateUsb(&back, 3, 6, 3_000).basis);
}

fn testContext(sockets: []const Socket, processes: []const Process, pairs: []const clock.Pair) Context {
    const S = struct {
        var tables: [1]Table = undefined;
    };
    S.tables[0] = .{ .when = .stop, .sampled_ns = 2_000, .processes = processes, .sockets = sockets };
    return .{ .capture_started_ns = 1_000, .pid = 7, .pairs = pairs, .tables = &S.tables };
}

test "join basis: exact, sampled, inferred, none" {
    const lo = decode.v4(127, 0, 0, 1);
    var comm: [16]u8 = @splat(0);
    @memcpy(comm[0..4], "peer");
    const sockets = [_]Socket{
        .{ .pid = 7, .fd = 3, .inode = 11, .protocol = .tcp, .family = .ipv4, .local = lo, .local_port = 40000, .remote = lo, .remote_port = 5000, .state = 1 },
        .{ .pid = 7, .fd = 4, .inode = 12, .protocol = .udp, .family = .ipv4, .local = decode.v4(0, 0, 0, 0), .local_port = 6000, .remote = decode.v4(0, 0, 0, 0), .remote_port = 0, .state = 7 },
    };
    const ctx = testContext(&sockets, &.{.{ .pid = 7, .comm = comm }}, &.{.{ .monotonic_before_ns = 100, .realtime_ns = 10_000, .monotonic_after_ns = 102 }});
    const tcp = decode.Flow{ .family = .ipv4, .protocol = 6, .src = lo, .dst = lo, .src_port = 5000, .dst_port = 40000 };
    // One table: exact only within the clock uncertainty of its read.
    const j = correlate(&ctx, tcp, 2_001);
    try std.testing.expectEqual(Basis.exact, j.basis);
    try std.testing.expect(!j.outbound);
    try std.testing.expectEqual(@as(i32, 7), j.process.?.pid);
    try std.testing.expectEqual(Basis.sampled, correlate(&ctx, tcp, 1_500).basis);
    try std.testing.expectEqual(Basis.sampled, correlate(&ctx, tcp, 9_000).basis);
    try std.testing.expectEqual(Basis.sampled, correlate(&ctx, tcp, null).basis);
    const udp = decode.Flow{ .family = .ipv4, .protocol = 17, .src = lo, .dst = lo, .src_port = 1234, .dst_port = 6000 };
    try std.testing.expectEqual(Basis.inferred, correlate(&ctx, udp, 1_500).basis);
    var other = tcp;
    other.dst_port = 40001;
    try std.testing.expectEqual(Basis.none, correlate(&ctx, other, 1_500).basis);

    // Two tables: a socket seen at both brackets the packet (exact); one seen
    // only at stop, or replaced by another inode with the same tuple, does not.
    var reopened = sockets[0];
    reopened.inode = 99;
    const tables = [_]Table{
        .{ .when = .start, .sampled_ns = 1_000, .processes = &.{}, .sockets = sockets[0..1] },
        .{ .when = .stop, .sampled_ns = 5_000, .processes = &.{}, .sockets = &.{ sockets[0], sockets[1] } },
    };
    const two = Context{ .capture_started_ns = 1_000, .pid = 7, .pairs = ctx.pairs, .tables = &tables };
    try std.testing.expectEqual(Basis.exact, correlate(&two, tcp, 3_000).basis);
    const swapped = [_]Table{ tables[0], .{ .when = .stop, .sampled_ns = 5_000, .processes = &.{}, .sockets = &.{reopened} } };
    const reuse = Context{ .capture_started_ns = 1_000, .pid = 7, .pairs = ctx.pairs, .tables = &swapped };
    try std.testing.expectEqual(Basis.sampled, correlate(&reuse, tcp, 3_000).basis);
    const late = [_]Table{ .{ .when = .start, .sampled_ns = 1_000, .processes = &.{}, .sockets = &.{} }, tables[1] };
    const opened_late = Context{ .capture_started_ns = 1_000, .pid = 7, .pairs = ctx.pairs, .tables = &late };
    try std.testing.expectEqual(Basis.sampled, correlate(&opened_late, tcp, 3_000).basis);
    try std.testing.expectEqual(Basis.exact, correlate(&opened_late, tcp, 5_001).basis);
}

test "ECTX round trip and validation" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const lo = decode.v4(127, 0, 0, 1);
    const sockets = [_]Socket{.{ .pid = 7, .fd = 3, .inode = 11, .protocol = .tcp, .family = .ipv4, .local = lo, .local_port = 1, .remote = lo, .remote_port = 2, .state = 1 }};
    const ctx = testContext(&sockets, &.{.{ .pid = 7 }}, &.{.{ .monotonic_before_ns = 1, .realtime_ns = 2, .monotonic_after_ns = 3 }});
    const bytes = try encode(a, ctx);
    defer a.free(bytes);
    const back = try decodeContext(arena.allocator(), bytes);
    try std.testing.expectEqual(@as(u64, 1_000), back.capture_started_ns);
    try std.testing.expectEqual(@as(usize, 1), back.tables[0].sockets.len);
    try std.testing.expectEqual(@as(u64, 11), back.tables[0].sockets[0].inode);
    for (0..bytes.len) |cut| try std.testing.expect(std.meta.isError(decodeContext(arena.allocator(), bytes[0..cut])));
    const trailing = try std.mem.concat(a, u8, &.{ bytes, "x" });
    defer a.free(trailing);
    try std.testing.expectError(error.EvidenceContextTrailingBytes, decodeContext(arena.allocator(), trailing));
}

test "redacted ECTX: tagged ends round-trip and match no packet, loopback stays" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const lo = decode.v4(127, 0, 0, 1);
    const lan = decode.v4(10, 20, 30, 40);
    const peer = decode.v4(172, 16, 9, 9);
    var tagged = Socket{ .pid = 7, .fd = 4, .inode = 12, .protocol = .tcp, .family = .ipv4, .local = lan, .local_port = 3, .remote = peer, .remote_port = 443, .state = 1 };
    tagged.local_tagged = true;
    tagged.remote_tagged = true;
    const sockets = [_]Socket{
        .{ .pid = 7, .fd = 3, .inode = 11, .protocol = .tcp, .family = .ipv4, .local = lo, .local_port = 1, .remote = lo, .remote_port = 2, .state = 1 },
        tagged,
    };
    var ctx = testContext(&sockets, &.{.{ .pid = 7 }}, &.{.{ .monotonic_before_ns = 100, .realtime_ns = 10_000, .monotonic_after_ns = 102 }});
    ctx.redacted = true;
    const bytes = try encode(a, ctx);
    defer a.free(bytes);
    try std.testing.expectEqual(schema_redacted, bytes[0]);
    const back = try decodeContext(arena.allocator(), bytes);
    try std.testing.expect(back.redacted);
    const s = back.tables[0].sockets;
    try std.testing.expect(!s[0].local_tagged and !s[0].remote_tagged and s[1].local_tagged and s[1].remote_tagged);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ip-ac100909", formatEnd(&buf, .ipv4, s[1].remote, true));
    const loop = decode.Flow{ .family = .ipv4, .protocol = 6, .src = lo, .dst = lo, .src_port = 2, .dst_port = 1 };
    try std.testing.expectEqual(Basis.exact, correlate(&back, loop, 2_001).basis);
    // A packet that carries the tag's bytes is still not that socket.
    const out = decode.Flow{ .family = .ipv4, .protocol = 6, .src = lan, .dst = peer, .src_port = 3, .dst_port = 443 };
    try std.testing.expectEqual(Basis.none, correlate(&back, out, 2_001).basis);
    for (0..bytes.len) |cut| try std.testing.expect(std.meta.isError(decodeContext(arena.allocator(), bytes[0..cut])));
    var bad = try a.dupe(u8, bytes);
    defer a.free(bad);
    bad[bad.len - 1] = 4;
    try std.testing.expectError(error.EvidenceContextValue, decodeContext(arena.allocator(), bad));
}
