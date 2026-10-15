//! Bounded TCP byte-stream reconstruction shared by protocol decoders.
//! Captured bytes are never invented: a gap stops that direction at the
//! first missing sequence range, retransmissions contribute only new tails,
//! and every output span retains its source packet.
const std = @import("std");
const network = @import("stream.zig");
const decode = @import("decode.zig");

pub const Segment = struct { seq: u32, record: u32, bytes: []const u8 };
pub const Span = struct { first: usize, last: usize, record: u32 };

pub const Direction = struct {
    bytes: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    anchor: ?u32 = null,
    gap: bool = false,
    limited: bool = false,

    pub fn deinit(self: *Direction, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
        self.spans.deinit(a);
        self.segments.deinit(a);
    }

    pub fn source(self: *const Direction, offset: usize) u32 {
        const spans = self.spans.items;
        if (spans.len == 0) return 0;
        var low: usize = 0;
        var high: usize = spans.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (spans[mid].last <= offset) low = mid + 1 else high = mid;
        }
        return if (low < spans.len and offset >= spans[low].first) spans[low].record else spans[spans.len - 1].record;
    }
};

pub const Result = struct {
    a: Direction = .{},
    b: Direction = .{},

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.a.deinit(allocator);
        self.b.deinit(allocator);
    }

    /// A gap or the byte limit stopped either direction early.
    pub fn incomplete(self: *const Result) bool {
        return self.a.gap or self.b.gap or self.a.limited or self.b.limited;
    }
};

pub fn reassemble(a: std.mem.Allocator, source: *const network.Stream, flow_records: []const u32, key: decode.Flow, max_bytes: usize) !Result {
    var out = Result{};
    errdefer out.deinit(a);
    for (flow_records) |record_index| {
        const summary = source.summaries[record_index];
        if (summary.protocol != 6) continue;
        const a_to_b = std.mem.eql(u8, &summary.src, &key.src) and summary.src_port == key.src_port;
        const direction = if (a_to_b) &out.a else &out.b;
        if (summary.tcp_flags & 0x02 != 0) direction.anchor = summary.seq +% 1;
        if (summary.payload_captured == 0) continue;
        const bytes = transportPayload(source.parsed.interfaces[source.parsed.records[record_index].interface].link_type, source.raw(record_index), summary) orelse continue;
        if (bytes.len == 0) continue;
        try direction.segments.append(a, .{ .seq = summary.seq, .record = @intCast(record_index), .bytes = bytes });
    }
    try linearize(a, &out.a, max_bytes);
    try linearize(a, &out.b, max_bytes);
    return out;
}

fn linearize(a: std.mem.Allocator, direction: *Direction, max_bytes: usize) !void {
    if (direction.segments.items.len == 0) return;
    const anchor = direction.anchor orelse blk: {
        var low = direction.segments.items[0].seq;
        for (direction.segments.items[1..]) |segment| if (@as(i32, @bitCast(segment.seq -% low)) < 0) {
            low = segment.seq;
        };
        break :blk low;
    };
    const Ctx = struct {
        anchor: u32,
        fn less(ctx: @This(), lhs: Segment, rhs: Segment) bool {
            return lhs.seq -% ctx.anchor < rhs.seq -% ctx.anchor;
        }
    };
    std.mem.sort(Segment, direction.segments.items, Ctx{ .anchor = anchor }, Ctx.less);
    var expected: usize = 0;
    for (direction.segments.items) |segment| {
        const relative_u32 = segment.seq -% anchor;
        if (relative_u32 > std.math.maxInt(i32)) continue;
        const relative: usize = relative_u32;
        if (relative > expected) {
            direction.gap = true;
            break;
        }
        const overlap = expected - relative;
        if (overlap >= segment.bytes.len) continue;
        const tail = segment.bytes[overlap..];
        if (direction.bytes.items.len + tail.len > max_bytes) {
            direction.limited = true;
            break;
        }
        const first = direction.bytes.items.len;
        try direction.bytes.appendSlice(a, tail);
        expected += tail.len;
        try direction.spans.append(a, .{ .first = first, .last = direction.bytes.items.len, .record = segment.record });
    }
}

/// Return the captured transport payload described by `summary`.
pub fn transportPayload(link_type: u16, frame: []const u8, summary: decode.Summary) ?[]const u8 {
    var at: usize = switch (link_type) {
        decode.link_ethernet => 14 + @as(usize, summary.vlan_count) * 4,
        decode.link_sll => 16,
        decode.link_sll2 => 20,
        decode.link_null => 4,
        decode.link_raw, decode.link_ipv4, decode.link_ipv6 => 0,
        else => return null,
    };
    if (at >= frame.len) return null;
    switch (summary.family) {
        .ipv4 => {
            if (frame.len - at < 20) return null;
            const header = @as(usize, frame[at] & 0x0f) * 4;
            if (header < 20 or header > frame.len - at) return null;
            at += header;
        },
        .ipv6 => {
            if (frame.len - at < 40) return null;
            var next = frame[at + 6];
            at += 40;
            var count: u8 = 0;
            while (next == 0 or next == 43 or next == 44 or next == 60 or next == 51 or next == 135) {
                if (count == decode.max_extension_headers or frame.len - at < 8) return null;
                count += 1;
                const length: usize = switch (next) {
                    44 => 8,
                    51 => (@as(usize, frame[at + 1]) + 2) * 4,
                    else => (@as(usize, frame[at + 1]) + 1) * 8,
                };
                next = frame[at];
                if (length > frame.len - at) return null;
                at += length;
            }
        },
        .none => return null,
    }
    const header: usize = switch (summary.protocol) {
        6 => blk: {
            if (frame.len - at < 20) return null;
            const size = @as(usize, frame[at + 12] >> 4) * 4;
            if (size < 20 or size > frame.len - at) return null;
            break :blk size;
        },
        17 => 8,
        else => return null,
    };
    if (header > frame.len - at) return null;
    at += header;
    const length = @min(@as(usize, summary.payload_captured), frame.len - at);
    return frame[at..][0..length];
}

test "sequence order, retransmissions, gaps and bounds stay explicit" {
    const a = std.testing.allocator;
    var direction = Direction{};
    defer direction.deinit(a);
    try direction.segments.append(a, .{ .seq = 104, .record = 2, .bytes = "efgh" });
    try direction.segments.append(a, .{ .seq = 100, .record = 1, .bytes = "abcd" });
    try direction.segments.append(a, .{ .seq = 102, .record = 3, .bytes = "cdef" });
    direction.anchor = 100;
    try linearize(a, &direction, 32);
    try std.testing.expectEqualStrings("abcdefgh", direction.bytes.items);
    try std.testing.expectEqual(@as(u32, 1), direction.source(1));
    try std.testing.expectEqual(@as(u32, 3), direction.source(4));
    try std.testing.expect(!direction.gap and !direction.limited);

    var gap = Direction{};
    defer gap.deinit(a);
    try gap.segments.append(a, .{ .seq = 10, .record = 1, .bytes = "ab" });
    try gap.segments.append(a, .{ .seq = 14, .record = 2, .bytes = "ef" });
    gap.anchor = 10;
    try linearize(a, &gap, 32);
    try std.testing.expect(gap.gap);
    try std.testing.expectEqualStrings("ab", gap.bytes.items);

    var limited = Direction{};
    defer limited.deinit(a);
    try limited.segments.append(a, .{ .seq = 0, .record = 1, .bytes = "too-long" });
    limited.anchor = 0;
    try linearize(a, &limited, 4);
    try std.testing.expect(limited.limited);
    try std.testing.expectEqual(@as(usize, 0), limited.bytes.items.len);
}
