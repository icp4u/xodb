//! An evidence stream: immutable records read from one capture file, each
//! with its time and clock domain, its interface, a reference to its raw
//! bytes and a decoded summary, plus per-interface loss counters. Decoders
//! never rewrite records; an undecoded record stays in the stream with its
//! reason. Optional collector context (ECTX) adds the clock mapping into a
//! capture's CLOCK_MONOTONIC and the socket tables for correlation.
const std = @import("std");
pub const pcap = @import("pcap.zig");
pub const decode = @import("decode.zig");
pub const clock = @import("clock.zig");
pub const sockets = @import("sockets.zig");

pub const Kind = enum { network };
pub const max_flows = 65536;

pub const Flow = struct { key: decode.Flow, packets: u64 = 0, bytes: u64 = 0, first: u32, last: u32 };

pub const Stream = struct {
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    id: u32 = 1,
    kind: Kind = .network,
    label: []const u8,
    /// The whole file. Owned; records point into it.
    bytes: []const u8,
    parsed: pcap.Result,
    /// One per record, same index: the decoded summary reference.
    summaries: []decode.Summary,
    /// Flow id per record (index into `flows`), or null.
    flow_of: []?u32,
    flows: []Flow,
    flows_dropped: u64 = 0,
    undecoded: u64 = 0,
    domain: clock.Domain = .realtime,
    mapping: clock.Mapping = .{},
    context: ?sockets.Context = null,
    first_time_ns: ?u64 = null,
    last_time_ns: ?u64 = null,

    /// Takes ownership of `bytes` (allocated with `a`).
    pub fn open(a: std.mem.Allocator, bytes: []const u8, label: []const u8) !*Stream {
        const self = try a.create(Stream);
        errdefer a.destroy(self);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(a), .backing = a, .label = undefined, .bytes = bytes, .parsed = undefined, .summaries = &.{}, .flow_of = &.{}, .flows = &.{} };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.label = try arena.dupe(u8, label);
        self.parsed = try pcap.parse(arena, bytes, .{});
        const n = self.parsed.records.len;
        self.summaries = try arena.alloc(decode.Summary, n);
        self.flow_of = try arena.alloc(?u32, n);
        var index: std.AutoHashMapUnmanaged(decode.Flow, u32) = .empty;
        var flows: std.ArrayList(Flow) = .empty;
        for (self.parsed.records, self.summaries, self.flow_of, 0..) |r, *s, *f, i| {
            s.* = decode.decode(self.parsed.interfaces[r.interface].link_type, bytes[r.offset..][0..r.caplen]);
            if (s.undecoded()) self.undecoded += 1;
            if (r.time_known) {
                self.first_time_ns = @min(self.first_time_ns orelse r.time_ns, r.time_ns);
                self.last_time_ns = @max(self.last_time_ns orelse r.time_ns, r.time_ns);
            }
            f.* = null;
            const key = (s.flow() orelse continue).canonical();
            const got = index.get(key) orelse blk: {
                if (flows.items.len >= max_flows) {
                    self.flows_dropped += 1;
                    break :blk null;
                }
                const id: u32 = @intCast(flows.items.len);
                try index.put(arena, key, id);
                try flows.append(arena, .{ .key = key, .first = @intCast(i), .last = @intCast(i) });
                break :blk id;
            } orelse continue;
            f.* = got;
            const flow = &flows.items[got];
            flow.packets += 1;
            flow.bytes += r.origlen;
            flow.last = @intCast(i);
        }
        self.flows = flows.items;
        return self;
    }
    pub fn destroy(self: *Stream) void {
        const a = self.backing;
        a.free(self.bytes);
        self.arena.deinit();
        a.destroy(self);
    }
    /// Adds collector context from a capture archive (ECTX payload).
    pub fn attachContext(self: *Stream, payload: []const u8, usb_payload: ?[]const u8) !void {
        const ctx = try sockets.decodeContextWithUsb(self.arena.allocator(), payload, usb_payload);
        self.context = ctx;
        self.mapping = ctx.mapping();
    }

    pub const Time = struct {
        known: bool,
        /// In the stream's own domain (realtime ns since the epoch).
        stream_ns: u64,
        /// Mapped to the capture: ns since capture start; null when unaligned or before start.
        capture_ns: ?u64 = null,
        /// CLOCK_MONOTONIC when aligned.
        monotonic_ns: ?u64 = null,
        uncertainty_ns: ?u64 = null,
    };
    pub fn timeOf(self: *const Stream, i: usize) Time {
        const r = self.parsed.records[i];
        if (!r.time_known) return .{ .known = false, .stream_ns = 0 };
        var t = Time{ .known = true, .stream_ns = r.time_ns };
        if (self.mapping.map(r.time_ns)) |m| {
            t.monotonic_ns = m.ns;
            t.uncertainty_ns = m.uncertainty_ns;
            if (self.context) |ctx| if (m.ns >= ctx.capture_started_ns) {
                t.capture_ns = m.ns - ctx.capture_started_ns;
            };
        }
        return t;
    }
    pub fn raw(self: *const Stream, i: usize) []const u8 {
        return self.parsed.data(self.bytes, i);
    }
    pub fn correlate(self: *const Stream, i: usize) sockets.Join {
        const ctx = self.context orelse return .{ .reason = "no capture context: open with --open-capture an archive recorded with socket tables" };
        const flow = self.summaries[i].flow() orelse return .{ .reason = "record has no 5-tuple (undecoded, or not TCP/UDP)" };
        return sockets.correlate(&ctx, flow, self.timeOf(i).monotonic_ns);
    }

    pub const Clock = enum { stream, capture };
    pub const Filter = struct {
        clock: Clock = .stream,
        from_ns: ?u64 = null,
        to_ns: ?u64 = null,
        flow: ?u32 = null,
        interface: ?u32 = null,
        protocol: ?u8 = null,
        port: ?u16 = null,
        undecoded: ?bool = null,
    };
    /// Whether record `i` passes `filter`. Time bounds are half-open; a
    /// record without a time (or unaligned, for the capture clock) never
    /// passes a time bound.
    pub fn matches(self: *const Stream, i: usize, filter: Filter) bool {
        const s = &self.summaries[i];
        if (filter.flow) |f| if (self.flow_of[i] != f) return false;
        if (filter.interface) |f| if (self.parsed.records[i].interface != f) return false;
        if (filter.protocol) |p| if (s.layer != .transport or s.protocol != p) return false;
        if (filter.port) |p| if (!s.hasPorts() or (s.src_port != p and s.dst_port != p)) return false;
        if (filter.undecoded) |u| if (s.undecoded() != u) return false;
        if (filter.from_ns != null or filter.to_ns != null) {
            const t = self.timeOf(i);
            const v = switch (filter.clock) {
                .stream => if (t.known) t.stream_ns else return false,
                .capture => t.capture_ns orelse return false,
            };
            if (filter.from_ns) |from| if (v < from) return false;
            if (filter.to_ns) |to| if (v >= to) return false;
        }
        return true;
    }

    pub const Loss = struct { epb_drops: u64 = 0, isb_ifdrop: u64 = 0, isb_osdrop: u64 = 0, truncated_packets: u64 = 0, orphan_records: u64 = 0, file_stop: pcap.Stop = .complete };
    pub fn loss(self: *const Stream) Loss {
        var l = Loss{ .orphan_records = self.parsed.orphan_records, .file_stop = self.parsed.stop };
        for (self.parsed.interfaces) |iface| {
            l.epb_drops += iface.epb_drops;
            l.isb_ifdrop += iface.isb_ifdrop orelse 0;
            l.isb_osdrop += iface.isb_osdrop orelse 0;
            l.truncated_packets += iface.truncated_packets;
        }
        return l;
    }
};

test "stream decodes, groups flows and correlates" {
    const a = std.testing.allocator;
    var w = pcap.TestWriter{ .a = a };
    defer w.deinit();
    try w.shb();
    try w.idb(decode.link_ethernet, 9, "lo");
    try w.idb(147, 9, "user0");
    const lo = decode.v4(127, 0, 0, 1);
    var buf: [128]u8 = undefined;
    const base: u64 = 1_700_000_000_000_000_000;
    try w.epb(0, base + 10, decode.testFrame(&buf, .ipv4, 6, lo, lo, 40000, 5000, 0x02, ""), 54, null);
    try w.epb(0, base + 20, decode.testFrame(&buf, .ipv4, 6, lo, lo, 5000, 40000, 0x12, ""), 54, null);
    try w.epb(1, base + 30, "opaque", 6, null);
    try w.isb(0, 0, 4);
    const bytes = try a.dupe(u8, w.out.items);
    const s = try Stream.open(a, bytes, "test");
    defer s.destroy();
    try std.testing.expectEqual(@as(usize, 3), s.parsed.records.len);
    try std.testing.expectEqual(@as(usize, 1), s.flows.len);
    try std.testing.expectEqual(@as(u64, 2), s.flows[0].packets);
    try std.testing.expectEqual(@as(u64, 1), s.undecoded);
    try std.testing.expectEqual(decode.Reason.unknown_link_type, s.summaries[2].reason);
    try std.testing.expectEqual(@as(u64, 4), s.loss().isb_osdrop);
    try std.testing.expect(s.matches(2, .{ .undecoded = true }));
    try std.testing.expect(!s.matches(0, .{ .undecoded = true }));
    try std.testing.expect(s.matches(1, .{ .port = 5000, .protocol = 6 }));
    try std.testing.expect(!s.matches(1, .{ .clock = .capture, .from_ns = 0 }));
    try std.testing.expect(s.matches(1, .{ .from_ns = base + 15, .to_ns = base + 21 }));
    try std.testing.expectEqual(sockets.Basis.none, s.correlate(0).basis);

    // Capture started at monotonic 1000; realtime base maps to monotonic 1000.
    const table_sockets = [_]sockets.Socket{.{ .pid = 9, .fd = 5, .inode = 77, .protocol = .tcp, .family = .ipv4, .local = lo, .local_port = 40000, .remote = lo, .remote_port = 5000, .state = 1 }};
    const tables = [_]sockets.Table{ .{ .when = .start, .sampled_ns = 1_000, .processes = &.{.{ .pid = 9 }}, .sockets = &table_sockets }, .{ .when = .stop, .sampled_ns = 5_000, .processes = &.{.{ .pid = 9 }}, .sockets = &table_sockets } };
    const payload = try sockets.encode(a, .{ .capture_started_ns = 1_000, .pid = 9, .pairs = &.{.{ .monotonic_before_ns = 999, .realtime_ns = base, .monotonic_after_ns = 1_001 }}, .tables = &tables });
    defer a.free(payload);
    try s.attachContext(payload, null);
    try std.testing.expectEqual(@as(?u64, 10), s.timeOf(0).capture_ns);
    try std.testing.expectEqual(@as(?u64, 1), s.timeOf(0).uncertainty_ns);
    const join = s.correlate(1);
    try std.testing.expectEqual(sockets.Basis.exact, join.basis);
    try std.testing.expectEqual(@as(i32, 9), join.socket.?.pid);
    try std.testing.expect(!join.outbound);
    try std.testing.expect(s.correlate(0).outbound);
    try std.testing.expect(s.matches(1, .{ .clock = .capture, .from_ns = 15, .to_ns = 21 }));
}

test "random corruption of a stream never crashes and stays typed" {
    const a = std.testing.allocator;
    var w = pcap.TestWriter{ .a = a };
    defer w.deinit();
    try w.shb();
    try w.idb(decode.link_ethernet, null, "lo");
    try w.idb(decode.link_sll2, 9, "");
    var buf: [128]u8 = undefined;
    const lo = decode.v4(127, 0, 0, 1);
    for (0..6) |i| try w.epb(@intCast(i % 2), i, decode.testFrame(&buf, if (i % 3 == 0) .ipv6 else .ipv4, if (i % 2 == 0) 6 else 17, lo, lo, @intCast(1000 + i), 80, 0x18, "payload"), 80, null);
    try w.isb(0, 1, 1);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    for (0..3000) |_| {
        const bytes = try a.dupe(u8, w.out.items);
        for (0..random.uintAtMost(usize, 6)) |_| bytes[random.uintLessThan(usize, bytes.len)] = random.int(u8);
        const cut = random.uintAtMost(usize, bytes.len);
        const shrunk = try a.realloc(bytes, @max(cut, 1));
        const s = Stream.open(a, shrunk, "fuzz") catch |err| {
            try std.testing.expect(err == error.NotACapture);
            a.free(shrunk);
            continue;
        };
        defer s.destroy();
        for (0..s.parsed.records.len) |i| {
            _ = s.matches(i, .{ .port = 80, .from_ns = 1 });
            _ = s.correlate(i);
            try std.testing.expect(s.raw(i).len == s.parsed.records[i].caplen);
        }
    }
}

test {
    _ = pcap;
    _ = decode;
    _ = clock;
    _ = sockets;
}
