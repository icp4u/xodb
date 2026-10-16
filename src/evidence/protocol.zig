//! Bounded HTTP/1 and DNS records derived from an immutable packet stream.
//! TCP byte order and provenance come from reassembly.zig, shared with TLS.
const std = @import("std");
const network = @import("stream.zig");
const decode = @import("decode.zig");
const reassembly = @import("reassembly.zig");

pub const decoder = "xodb-http1-dns";
pub const decoder_version: u32 = 1;
pub const max_records = 262_144;
pub const max_flow_bytes = 16 * 1024 * 1024;
pub const max_header_bytes = 64 * 1024;
pub const max_body_bytes = 16 * 1024 * 1024;
pub const max_private_text_bytes = 16 * 1024 * 1024;
/// Records searched backwards for a DNS response's query.
pub const max_dns_pair_scan = 1024;

pub const Kind = enum { http_request, http_response, dns_query, dns_response };
pub const Transport = enum { tcp, udp };
pub const Direction = enum { a_to_b, b_to_a };
pub const Reason = enum { none, malformed, truncated, header_limit, body_limit, unsupported_chunked, reassembly_gap };

pub const Record = struct {
    index: u32,
    flow_id: u32,
    direction: Direction,
    source_record: u32,
    time_ns: ?u64,
    transport: Transport,
    kind: Kind,
    reason: Reason = .none,
    request: ?u32 = null,
    latency_ns: ?u64 = null,
    method: ?[]const u8 = null,
    target: ?[]const u8 = null,
    http_version: ?[]const u8 = null,
    status: ?u16 = null,
    transaction_id: ?u16 = null,
    dns_name: ?[]const u8 = null,
    dns_type: ?u16 = null,
    dns_class: ?u16 = null,
    dns_opcode: ?u4 = null,
    dns_rcode: ?u4 = null,
};

pub const Stream = struct {
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    id: u32,
    parent_id: u32,
    label: []const u8,
    records: []Record,
    http_records: u64 = 0,
    dns_records: u64 = 0,
    records_dropped: u64 = 0,
    reassembly_gaps: u64 = 0,
    reassembly_limits: u64 = 0,
    private_text_bytes: u64 = 0,

    pub fn open(a: std.mem.Allocator, source: *const network.Stream, id: u32) !*Stream {
        const self = try a.create(Stream);
        errdefer a.destroy(self);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(a),
            .backing = a,
            .id = id,
            .parent_id = source.id,
            .label = undefined,
            .records = &.{},
        };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.label = try std.fmt.allocPrint(arena, "protocols from {s}", .{source.label});
        var records: std.ArrayList(Record) = .empty;

        var starts = try a.alloc(usize, source.flows.len + 1);
        defer a.free(starts);
        @memset(starts, 0);
        for (source.flow_of) |flow| if (flow) |f| {
            starts[f + 1] += 1;
        };
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        const by_flow = try a.alloc(u32, starts[source.flows.len]);
        defer a.free(by_flow);
        const fill = try a.dupe(usize, starts[0..source.flows.len]);
        defer a.free(fill);
        for (source.flow_of, 0..) |flow, record_index| if (flow) |f| {
            by_flow[fill[f]] = @intCast(record_index);
            fill[f] += 1;
        };

        for (source.flows, 0..) |flow, flow_index| {
            const flow_start = records.items.len;
            const flow_id: u32 = @intCast(flow_index);
            const indices = by_flow[starts[flow_index]..starts[flow_index + 1]];
            if (flow.key.protocol == 6) {
                var joined = try reassembly.reassemble(a, source, indices, flow.key, max_flow_bytes);
                defer joined.deinit(a);
                self.reassembly_gaps += @as(u64, @intFromBool(joined.a.gap)) + @intFromBool(joined.b.gap);
                self.reassembly_limits += @as(u64, @intFromBool(joined.a.limited)) + @intFromBool(joined.b.limited);
                if (flow.key.src_port == 53 or flow.key.dst_port == 53) {
                    try self.dnsTcp(arena, &records, source, flow_id, .a_to_b, &joined.a);
                    try self.dnsTcp(arena, &records, source, flow_id, .b_to_a, &joined.b);
                } else {
                    try self.http(arena, &records, source, flow_id, .a_to_b, &joined.a);
                    try self.http(arena, &records, source, flow_id, .b_to_a, &joined.b);
                }
            } else if (flow.key.protocol == 17 and (flow.key.src_port == 53 or flow.key.dst_port == 53)) {
                for (indices) |record_index| {
                    const summary = source.summaries[record_index];
                    const payload = reassembly.transportPayload(source.parsed.interfaces[source.parsed.records[record_index].interface].link_type, source.raw(record_index), summary) orelse continue;
                    const direction: Direction = if (std.mem.eql(u8, &summary.src, &flow.key.src) and summary.src_port == flow.key.src_port) .a_to_b else .b_to_a;
                    try self.dns(arena, &records, source, flow_id, direction, .udp, @intCast(record_index), payload);
                }
            }
            std.mem.sort(Record, records.items[flow_start..], {}, struct {
                fn less(_: void, lhs: Record, rhs: Record) bool {
                    return lhs.source_record < rhs.source_record;
                }
            }.less);
            pair(records.items, flow_id);
        }
        for (records.items, 0..) |*record, index| record.index = @intCast(index);
        self.records = records.items;
        return self;
    }

    pub fn destroy(self: *Stream) void {
        const a = self.backing;
        self.arena.deinit();
        a.destroy(self);
    }

    fn add(self: *Stream, records: *std.ArrayList(Record), a: std.mem.Allocator, record: Record) !bool {
        if (records.items.len >= max_records) {
            self.records_dropped += 1;
            return false;
        }
        try records.append(a, record);
        switch (record.kind) {
            .http_request, .http_response => self.http_records += 1,
            .dns_query, .dns_response => self.dns_records += 1,
        }
        return true;
    }

    fn retain(self: *Stream, a: std.mem.Allocator, text: []const u8, limit: usize) !?[]const u8 {
        if (text.len > limit or self.private_text_bytes + text.len > max_private_text_bytes) return null;
        const copy = try a.dupe(u8, text);
        self.private_text_bytes += text.len;
        return copy;
    }

    fn http(self: *Stream, a: std.mem.Allocator, records: *std.ArrayList(Record), source: *const network.Stream, flow_id: u32, direction: Direction, bytes: *const reassembly.Direction) !void {
        var at: usize = 0;
        while (at < bytes.bytes.items.len) {
            const rest = bytes.bytes.items[at..];
            const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse return;
            const line = rest[0..line_end];
            const parsed = parseStartLine(line) orelse return;
            const header_relative = std.mem.indexOf(u8, rest[0..@min(rest.len, max_header_bytes)], "\r\n\r\n") orelse {
                if (rest.len >= max_header_bytes) _ = try self.add(records, a, baseRecord(source, flow_id, direction, .tcp, bytes.source(at), parsed.kind, .header_limit));
                return;
            };
            const header_end = header_relative + 4;
            // A message with no header fields ends at its start line's CRLF.
            const framing = httpFraming(if (header_relative > line_end) rest[line_end + 2 .. header_relative] else "");
            var reason: Reason = .none;
            var message_end = header_end;
            if (framing.chunked) {
                reason = .unsupported_chunked;
            } else if (framing.content_length) |length| {
                if (length > max_body_bytes) {
                    reason = .body_limit;
                } else if (length > rest.len - header_end) {
                    reason = .truncated;
                } else message_end += length;
            }
            const source_record = bytes.source(at);
            var record = baseRecord(source, flow_id, direction, .tcp, source_record, parsed.kind, reason);
            record.method = if (parsed.method) |method| try self.retain(a, method, 32) else null;
            record.target = if (parsed.target) |target| try self.retain(a, target, 4096) else null;
            record.http_version = try self.retain(a, parsed.version, 16);
            record.status = parsed.status;
            if (!try self.add(records, a, record)) return;
            if (reason != .none) return;
            at += message_end;
        }
    }

    fn dnsTcp(self: *Stream, a: std.mem.Allocator, records: *std.ArrayList(Record), source: *const network.Stream, flow_id: u32, direction: Direction, bytes: *const reassembly.Direction) !void {
        var at: usize = 0;
        while (bytes.bytes.items.len - at >= 2) {
            const length = @as(usize, std.mem.readInt(u16, bytes.bytes.items[at..][0..2], .big));
            if (length == 0) return;
            if (length > bytes.bytes.items.len - at - 2) return;
            try self.dns(a, records, source, flow_id, direction, .tcp, bytes.source(at + 2), bytes.bytes.items[at + 2 ..][0..length]);
            at += 2 + length;
        }
    }

    fn dns(self: *Stream, a: std.mem.Allocator, records: *std.ArrayList(Record), source: *const network.Stream, flow_id: u32, direction: Direction, transport: Transport, source_record: u32, bytes: []const u8) !void {
        if (bytes.len < 12) return;
        const flags = std.mem.readInt(u16, bytes[2..4], .big);
        const kind: Kind = if (flags & 0x8000 == 0) .dns_query else .dns_response;
        var record = baseRecord(source, flow_id, direction, transport, source_record, kind, .none);
        record.transaction_id = std.mem.readInt(u16, bytes[0..2], .big);
        record.dns_opcode = @truncate((flags >> 11) & 15);
        record.dns_rcode = @truncate(flags & 15);
        const questions = std.mem.readInt(u16, bytes[4..6], .big);
        if (questions != 0) {
            var name_buffer: [256]u8 = undefined;
            var end: usize = 12;
            const name = dnsName(bytes, 12, &end, &name_buffer) orelse {
                record.reason = .malformed;
                _ = try self.add(records, a, record);
                return;
            };
            if (bytes.len - end < 4) record.reason = .truncated else {
                record.dns_name = try self.retain(a, name, 255);
                record.dns_type = std.mem.readInt(u16, bytes[end..][0..2], .big);
                record.dns_class = std.mem.readInt(u16, bytes[end + 2 ..][0..2], .big);
            }
        }
        _ = try self.add(records, a, record);
    }
};

const StartLine = struct { kind: Kind, method: ?[]const u8 = null, target: ?[]const u8 = null, version: []const u8, status: ?u16 = null };

fn parseStartLine(line: []const u8) ?StartLine {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const first = fields.next() orelse return null;
    const second = fields.next() orelse return null;
    const third = fields.next() orelse return null;
    if (std.mem.startsWith(u8, first, "HTTP/1.")) {
        if (second.len != 3) return null;
        const status = std.fmt.parseInt(u16, second, 10) catch return null;
        return .{ .kind = .http_response, .version = first, .status = status };
    }
    if (!std.mem.startsWith(u8, third, "HTTP/1.") or first.len == 0 or first.len > 32) return null;
    for (first) |byte| if (!(byte >= 'A' and byte <= 'Z') and byte != '-') return null;
    return .{ .kind = .http_request, .method = first, .target = second, .version = third };
}

const Framing = struct { content_length: ?usize = null, chunked: bool = false };
fn httpFraming(headers: []const u8) Framing {
    var out = Framing{};
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) out.content_length = std.fmt.parseInt(usize, value, 10) catch null;
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.indexOfIgnoreCase(value, "chunked") != null) out.chunked = true;
    }
    return out;
}

fn dnsName(message: []const u8, start: usize, end: *usize, out: *[256]u8) ?[]const u8 {
    var at = start;
    var written: usize = 0;
    var jumped = false;
    var hops: u8 = 0;
    while (true) {
        if (at >= message.len or hops == 64) return null;
        hops += 1;
        const length = message[at];
        if (length == 0) {
            if (!jumped) end.* = at + 1;
            return out[0..written];
        }
        if (length & 0xc0 == 0xc0) {
            if (message.len - at < 2) return null;
            const pointer = (@as(usize, length & 0x3f) << 8) | message[at + 1];
            if (pointer >= message.len) return null;
            if (!jumped) end.* = at + 2;
            jumped = true;
            at = pointer;
            continue;
        }
        if (length > 63 or message.len - at - 1 < length) return null;
        if (written != 0) {
            if (written == out.len) return null;
            out[written] = '.';
            written += 1;
        }
        if (written + length > out.len) return null;
        for (message[at + 1 ..][0..length]) |byte| {
            if (byte < 0x21 or byte > 0x7e) return null;
            out[written] = std.ascii.toLower(byte);
            written += 1;
        }
        at += 1 + length;
        if (!jumped) end.* = at;
    }
}

fn baseRecord(source: *const network.Stream, flow_id: u32, direction: Direction, transport: Transport, source_record: u32, kind: Kind, reason: Reason) Record {
    const time = source.timeOf(source_record);
    return .{ .index = 0, .flow_id = flow_id, .direction = direction, .source_record = source_record, .time_ns = if (time.known) time.stream_ns else null, .transport = transport, .kind = kind, .reason = reason };
}

fn pair(records: []Record, flow_id: u32) void {
    var next_http: usize = 0;
    for (records, 0..) |*response, response_index| {
        if (response.flow_id != flow_id) continue;
        if (response.kind == .http_response) {
            while (next_http < response_index) : (next_http += 1) {
                const request = &records[next_http];
                if (request.flow_id != flow_id or request.kind != .http_request or request.direction == response.direction) continue;
                response.request = @intCast(next_http);
                response.latency_ns = latency(request.time_ns, response.time_ns);
                next_http += 1;
                break;
            }
        } else if (response.kind == .dns_response) {
            // Bounded: unmatched responses on one flow must not cost O(n^2).
            var index = response_index;
            const oldest = response_index -| max_dns_pair_scan;
            while (index > oldest) {
                index -= 1;
                const request = &records[index];
                if (request.flow_id == flow_id and request.kind == .dns_query and request.direction != response.direction and request.transaction_id == response.transaction_id) {
                    response.request = @intCast(index);
                    response.latency_ns = latency(request.time_ns, response.time_ns);
                    break;
                }
            }
        }
    }
}

fn latency(start: ?u64, stop: ?u64) ?u64 {
    if (start == null or stop == null or stop.? < start.?) return null;
    return stop.? - start.?;
}

fn setSequence(frame: []u8, sequence: u32) void {
    std.mem.writeInt(u32, frame[14 + 20 + 4 ..][0..4], sequence, .big);
}

fn dnsFixture(out: []u8, response: bool) []const u8 {
    @memset(out[0..12], 0);
    std.mem.writeInt(u16, out[0..2], 0x1234, .big);
    std.mem.writeInt(u16, out[2..4], if (response) 0x8180 else 0x0100, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big);
    var at: usize = 12;
    for ([_][]const u8{ "unit", "test" }) |label| {
        out[at] = @intCast(label.len);
        at += 1;
        @memcpy(out[at..][0..label.len], label);
        at += label.len;
    }
    out[at] = 0;
    at += 1;
    std.mem.writeInt(u16, out[at..][0..2], 1, .big);
    std.mem.writeInt(u16, out[at + 2 ..][0..2], 1, .big);
    return out[0 .. at + 4];
}

test "HTTP split streams and DNS datagrams produce known pairs and latency" {
    const a = std.testing.allocator;
    var writer = network.pcap.TestWriter{ .a = a };
    defer writer.deinit();
    try writer.shb();
    try writer.idb(decode.link_ethernet, 9, "lo");
    const lo = decode.v4(127, 0, 0, 1);
    var frame: [512]u8 = undefined;
    var packet = decode.testFrame(&frame, .ipv4, 6, lo, lo, 41000, 8080, 0x02, "");
    setSequence(packet, 99);
    try writer.epb(0, 100, packet, @intCast(packet.len), null);
    packet = decode.testFrame(&frame, .ipv4, 6, lo, lo, 8080, 41000, 0x12, "");
    setSequence(packet, 199);
    try writer.epb(0, 101, packet, @intCast(packet.len), null);
    packet = decode.testFrame(&frame, .ipv4, 6, lo, lo, 41000, 8080, 0x18, "GET /ow");
    setSequence(packet, 100);
    try writer.epb(0, 110, packet, @intCast(packet.len), null);
    packet = decode.testFrame(&frame, .ipv4, 6, lo, lo, 41000, 8080, 0x18, "ned HTTP/1.1\r\nHost: loop\r\n\r\n");
    setSequence(packet, 107);
    try writer.epb(0, 120, packet, @intCast(packet.len), null);
    packet = decode.testFrame(&frame, .ipv4, 6, lo, lo, 8080, 41000, 0x18, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n");
    setSequence(packet, 200);
    try writer.epb(0, 150, packet, @intCast(packet.len), null);

    var dns: [128]u8 = undefined;
    packet = decode.testFrame(&frame, .ipv4, 17, lo, lo, 42000, 53, 0, dnsFixture(&dns, false));
    try writer.epb(0, 200, packet, @intCast(packet.len), null);
    packet = decode.testFrame(&frame, .ipv4, 17, lo, lo, 53, 42000, 0, dnsFixture(&dns, true));
    try writer.epb(0, 225, packet, @intCast(packet.len), null);

    const bytes = try a.dupe(u8, writer.out.items);
    const source = try network.Stream.open(a, bytes, "owned-loopback");
    defer source.destroy();
    const derived = try Stream.open(a, source, 2);
    defer derived.destroy();
    try std.testing.expectEqual(@as(usize, 4), derived.records.len);
    const request = derived.records[0];
    const response = derived.records[1];
    try std.testing.expectEqual(Kind.http_request, request.kind);
    try std.testing.expectEqualStrings("GET", request.method.?);
    try std.testing.expectEqualStrings("/owned", request.target.?);
    try std.testing.expectEqual(@as(?u16, 204), response.status);
    try std.testing.expectEqual(@as(?u32, 0), response.request);
    try std.testing.expectEqual(@as(?u64, 40), response.latency_ns);
    const query = derived.records[2];
    const answer = derived.records[3];
    try std.testing.expectEqualStrings("unit.test", query.dns_name.?);
    try std.testing.expectEqual(@as(?u16, 1), query.dns_type);
    try std.testing.expectEqual(@as(?u32, 2), answer.request);
    try std.testing.expectEqual(@as(?u64, 25), answer.latency_ns);
    try std.testing.expectEqual(@as(u64, 2), derived.http_records);
    try std.testing.expectEqual(@as(u64, 2), derived.dns_records);
}

fn decodeOne(a: std.mem.Allocator, protocol: u8, port: u16, payloads: []const []const u8) !*Stream {
    var writer = network.pcap.TestWriter{ .a = a };
    defer writer.deinit();
    try writer.shb();
    try writer.idb(decode.link_ethernet, 9, "lo");
    const lo = decode.v4(127, 0, 0, 1);
    var frame: [2048]u8 = undefined;
    var sequence: u32 = 1000;
    var packet = decode.testFrame(&frame, .ipv4, protocol, lo, lo, 41000, port, 0x02, "");
    if (protocol == 6) {
        setSequence(packet, sequence - 1);
        try writer.epb(0, 1, packet, @intCast(packet.len), null);
    }
    for (payloads, 0..) |payload, i| {
        packet = decode.testFrame(&frame, .ipv4, protocol, lo, lo, 41000, port, 0x18, payload);
        if (protocol == 6) setSequence(packet, sequence);
        sequence +%= @intCast(payload.len);
        try writer.epb(0, 10 + i, packet, @intCast(packet.len), null);
    }
    const bytes = try a.dupe(u8, writer.out.items);
    const source = try network.Stream.open(a, bytes, "fuzz");
    defer source.destroy();
    return Stream.open(a, source, 2);
}

test "HTTP/1 messages without header fields decode" {
    const a = std.testing.allocator;
    const derived = try decodeOne(a, 6, 8080, &.{ "GET / HTTP/1.0\r\n\r\n", "HTTP/1.0 200 OK\r\n\r\n" });
    defer derived.destroy();
    try std.testing.expectEqual(@as(usize, 2), derived.records.len);
    try std.testing.expectEqualStrings("/", derived.records[0].target.?);
    try std.testing.expectEqual(@as(?u16, 200), derived.records[1].status);
}

test "HTTP/1 and DNS decoders survive mutated input" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5832);
    const random = prng.random();
    const http_seeds = [_][]const u8{
        "GET /a HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabcPOST /b HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 18446744073709551616\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: -1\r\nContent-Length: 2\r\n\r\nok",
        "PUT /x HTTP/1.1\r\n\r\n\r\n\r\n",
    };
    var dns_seed: [128]u8 = undefined;
    const dns_base = dnsFixture(&dns_seed, true);
    var buffer: [1400]u8 = undefined;
    for (0..3000) |round| {
        const http = round % 2 == 0;
        const seed: []const u8 = if (http) http_seeds[random.uintLessThan(usize, http_seeds.len)] else dns_base;
        var len: usize = @min(seed.len, buffer.len);
        @memcpy(buffer[0..len], seed[0..len]);
        for (0..random.uintAtMost(usize, 6)) |_| switch (random.uintLessThan(u8, 4)) {
            0 => if (len != 0) {
                buffer[random.uintLessThan(usize, len)] = random.int(u8);
            },
            1 => len = random.uintAtMost(usize, len),
            2 => if (len >= 14) {
                // DNS compression pointer into or past the message.
                const at = 12 + random.uintLessThan(usize, len - 13);
                buffer[at] = 0xc0 | random.uintLessThan(u8, 0x40);
                buffer[at + 1] = random.int(u8);
            },
            else => if (len < buffer.len) {
                buffer[len] = "\r\n:0 "[random.uintLessThan(usize, 5)];
                len += 1;
            },
        };
        const parts = [_][]const u8{ buffer[0 .. len / 2], buffer[len / 2 .. len] };
        const derived = if (http) try decodeOne(a, 6, 8080, &parts) else try decodeOne(a, 17, 53, &.{buffer[0..len]});
        derived.destroy();
    }
    // A pointer that loops back onto itself is refused, not followed forever.
    var looped: [256]u8 = undefined;
    var end: usize = 0;
    const loop = [_]u8{ 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xc0, 12 };
    try std.testing.expect(dnsName(&loop, 12, &end, &looped) == null);
    const past = [_]u8{ 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xc0, 200 };
    try std.testing.expect(dnsName(&past, 12, &end, &looped) == null);
}

test "maximum TCP DNS length advances without narrow integer overflow" {
    const a = std.testing.allocator;
    const body = try a.alloc(u8, std.math.maxInt(u16));
    defer a.free(body);
    @memset(body, 0);
    const framed = try a.alloc(u8, body.len + 2);
    defer a.free(framed);
    std.mem.writeInt(u16, framed[0..2], std.math.maxInt(u16), .big);
    @memcpy(framed[2..], body);

    const part_size = 1024;
    const part_count = (framed.len + part_size - 1) / part_size;
    const parts = try a.alloc([]const u8, part_count);
    defer a.free(parts);
    for (parts, 0..) |*part, i| {
        const start = i * part_size;
        part.* = framed[start..@min(start + part_size, framed.len)];
    }

    const derived = try decodeOne(a, 6, 53, parts);
    defer derived.destroy();
    try std.testing.expectEqual(@as(usize, 1), derived.records.len);
    try std.testing.expectEqual(@as(?u16, 0), derived.records[0].transaction_id);
}
