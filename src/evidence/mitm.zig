//! Bounded reader for mitmproxy flow files. FlowWriter writes one typed
//! netstring (tnetstring) per flow. Values borrow the immutable input; the
//! stream retains only selected HTTP metadata and raw-content references.
const std = @import("std");

pub const decoder = "xodb-mitmproxy-flow";
pub const decoder_version: u32 = 1;
pub const max_flows = 1_000_000;
pub const max_depth = 64;
pub const max_nodes_per_flow = 65_536;
pub const max_headers = 256;

pub const Stop = enum { complete, truncated, corrupt, limit };
pub const Reason = enum { none, unsupported_flow, missing_request, invalid_timestamp };

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Message = struct {
    http_version: ?[]const u8 = null,
    headers: []Header = &.{},
    headers_dropped: u32 = 0,
    content: ?[]const u8 = null,
    content_sha256: ?[32]u8 = null,
    timestamp_start_ns: ?u64 = null,
    timestamp_end_ns: ?u64 = null,
};

pub const Request = struct {
    message: Message,
    host: ?[]const u8 = null,
    method: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: ?[]const u8 = null,
    port: ?u16 = null,
};

pub const Response = struct {
    message: Message,
    status_code: ?u16 = null,
    reason_text: ?[]const u8 = null,
};

pub const Record = struct {
    index: u32,
    offset: u64,
    length: u64,
    format_version: ?u32 = null,
    flow_type: ?[]const u8 = null,
    time_ns: ?u64 = null,
    reason: Reason = .none,
    request: ?Request = null,
    response: ?Response = null,
};

pub const Stream = struct {
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    id: u32 = 1,
    label: []const u8,
    bytes: []u8,
    records: []Record,
    stop: Stop = .complete,
    stop_offset: u64 = 0,
    stop_reason: []const u8 = "",
    unsupported: u64 = 0,
    first_time_ns: ?u64 = null,
    last_time_ns: ?u64 = null,

    /// Takes ownership of `bytes` (allocated with `a`).
    pub fn open(a: std.mem.Allocator, bytes: []u8, label: []const u8) !*Stream {
        const self = try a.create(Stream);
        errdefer a.destroy(self);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(a),
            .backing = a,
            .label = undefined,
            .bytes = bytes,
            .records = &.{},
        };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.label = try arena.dupe(u8, label);
        var records: std.ArrayList(Record) = .empty;
        var at: usize = 0;
        while (at < bytes.len) {
            if (records.items.len == max_flows) {
                self.stop = .limit;
                self.stop_offset = at;
                self.stop_reason = "flow limit";
                break;
            }
            const begin = at;
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            var parser = Parser{ .a = scratch.allocator(), .input = bytes, .at = at };
            const root = parser.value(0) catch |err| {
                self.stop = if (err == error.TruncatedTnetstring) .truncated else if (err == error.TnetstringLimit) .limit else .corrupt;
                self.stop_offset = begin;
                self.stop_reason = @errorName(err);
                break;
            };
            at = parser.at;
            const record = extract(arena, bytes, root, @intCast(records.items.len), begin, at - begin) catch |err| {
                self.stop = .corrupt;
                self.stop_offset = begin;
                self.stop_reason = @errorName(err);
                break;
            };
            if (record.reason != .none) self.unsupported += 1;
            if (record.time_ns) |time| {
                self.first_time_ns = @min(self.first_time_ns orelse time, time);
                self.last_time_ns = @max(self.last_time_ns orelse time, time);
            }
            try records.append(arena, record);
        }
        if (records.items.len == 0 and bytes.len != 0 and self.stop != .complete) return error.NotMitmproxyFlow;
        self.records = records.items;
        return self;
    }

    pub fn destroy(self: *Stream) void {
        const a = self.backing;
        // A mitmproxy file can contain plaintext bodies. Erase the owned copy.
        std.crypto.secureZero(u8, self.bytes);
        a.free(self.bytes);
        self.arena.deinit();
        a.destroy(self);
    }
};

const Value = union(enum) {
    bytes: []const u8,
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null,
    list: []Value,
    map: []Entry,

    fn text(self: Value) ?[]const u8 {
        return switch (self) {
            .bytes => |v| v,
            .string => |v| v,
            else => null,
        };
    }
    fn object(self: Value) ?[]Entry {
        return switch (self) {
            .map => |v| v,
            else => null,
        };
    }
};
const Entry = struct { key: []const u8, value: Value };
const ParseError = error{ OutOfMemory, TruncatedTnetstring, InvalidTnetstring, TnetstringLimit };

const Parser = struct {
    a: std.mem.Allocator,
    input: []const u8,
    at: usize = 0,
    nodes: usize = 0,

    fn value(self: *Parser, depth: usize) ParseError!Value {
        if (depth >= max_depth or self.nodes == max_nodes_per_flow) return error.TnetstringLimit;
        self.nodes += 1;
        if (self.at >= self.input.len) return error.TruncatedTnetstring;
        const digits = self.at;
        while (self.at < self.input.len and std.ascii.isDigit(self.input[self.at])) self.at += 1;
        if (self.at == digits or self.at - digits > 12) return error.InvalidTnetstring;
        if (self.input[digits] == '0' and self.at - digits != 1) return error.InvalidTnetstring;
        if (self.at >= self.input.len or self.input[self.at] != ':') return error.InvalidTnetstring;
        const length = std.fmt.parseInt(usize, self.input[digits..self.at], 10) catch return error.InvalidTnetstring;
        self.at += 1;
        if (length > self.input.len - self.at) return error.TruncatedTnetstring;
        const payload = self.input[self.at..][0..length];
        self.at += length;
        if (self.at >= self.input.len) return error.TruncatedTnetstring;
        const tag = self.input[self.at];
        self.at += 1;
        return switch (tag) {
            ',' => .{ .bytes = payload },
            ';' => blk: {
                if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidTnetstring;
                break :blk .{ .string = payload };
            },
            '#' => .{ .integer = std.fmt.parseInt(i64, payload, 10) catch return error.InvalidTnetstring },
            '^' => .{ .float = std.fmt.parseFloat(f64, payload) catch return error.InvalidTnetstring },
            '!' => if (std.mem.eql(u8, payload, "true")) .{ .boolean = true } else if (std.mem.eql(u8, payload, "false")) .{ .boolean = false } else error.InvalidTnetstring,
            '~' => if (payload.len == 0) .null else error.InvalidTnetstring,
            ']' => try self.container(payload, depth, false),
            '}' => try self.container(payload, depth, true),
            else => error.InvalidTnetstring,
        };
    }

    fn container(self: *Parser, payload: []const u8, depth: usize, comptime is_map: bool) ParseError!Value {
        var nested = Parser{ .a = self.a, .input = payload, .nodes = self.nodes };
        if (is_map) {
            var out: std.ArrayList(Entry) = .empty;
            while (nested.at < payload.len) {
                const key_value = try nested.value(depth + 1);
                const key = key_value.text() orelse return error.InvalidTnetstring;
                if (nested.at == payload.len) return error.InvalidTnetstring;
                try out.append(self.a, .{ .key = key, .value = try nested.value(depth + 1) });
            }
            self.nodes = nested.nodes;
            return .{ .map = out.items };
        }
        var out: std.ArrayList(Value) = .empty;
        while (nested.at < payload.len) try out.append(self.a, try nested.value(depth + 1));
        self.nodes = nested.nodes;
        return .{ .list = out.items };
    }
};

fn field(object: []const Entry, name: []const u8) ?Value {
    for (object) |entry| if (std.mem.eql(u8, entry.key, name)) return entry.value;
    return null;
}

fn textField(object: []const Entry, name: []const u8) ?[]const u8 {
    const value_ = field(object, name) orelse return null;
    return value_.text();
}

fn integerField(object: []const Entry, name: []const u8) ?i64 {
    const value_ = field(object, name) orelse return null;
    return switch (value_) {
        .integer => |v| v,
        else => null,
    };
}

fn timestamp(object: []const Entry, name: []const u8) ?u64 {
    const value_ = field(object, name) orelse return null;
    const seconds: f64 = switch (value_) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        else => return null,
    };
    // 2^64 ns is about 18446744073.7 s; f64 rounding at that edge can reach
    // 2^64 exactly, which @intFromFloat rejects with a panic.
    if (!std.math.isFinite(seconds) or seconds < 0 or seconds >= 18_446_744_073.0) return null;
    return @intFromFloat(seconds * 1_000_000_000.0);
}

fn message(a: std.mem.Allocator, object: []const Entry) !Message {
    var out = Message{
        .http_version = textField(object, "http_version"),
        .timestamp_start_ns = timestamp(object, "timestamp_start"),
        .timestamp_end_ns = timestamp(object, "timestamp_end"),
    };
    if (field(object, "content")) |content| switch (content) {
        .bytes => |body| {
            out.content = body;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
            out.content_sha256 = digest;
        },
        .null => {},
        else => return error.InvalidMitmproxyMessage,
    };
    if (field(object, "headers")) |headers| switch (headers) {
        .list => |list| {
            const kept = @min(list.len, max_headers);
            const copy = try a.alloc(Header, kept);
            var used: usize = 0;
            for (list[0..kept]) |pair| {
                const values = switch (pair) {
                    .list => |v| v,
                    else => continue,
                };
                if (values.len != 2) continue;
                const name = values[0].text() orelse continue;
                const value_ = values[1].text() orelse continue;
                copy[used] = .{ .name = name, .value = value_ };
                used += 1;
            }
            out.headers = copy[0..used];
            out.headers_dropped = @intCast(list.len - kept);
        },
        else => return error.InvalidMitmproxyMessage,
    };
    return out;
}

fn extract(a: std.mem.Allocator, file: []const u8, root: Value, index: u32, offset: usize, length: usize) !Record {
    _ = file;
    const object = root.object() orelse return error.InvalidMitmproxyFlow;
    var out = Record{ .index = index, .offset = offset, .length = length };
    if (integerField(object, "version")) |version| {
        if (version >= 0) out.format_version = std.math.cast(u32, version);
    }
    out.flow_type = textField(object, "type");
    if (out.flow_type == null or !std.mem.eql(u8, out.flow_type.?, "http")) {
        out.reason = .unsupported_flow;
        out.time_ns = timestamp(object, "timestamp_created");
        return out;
    }
    const request_value = field(object, "request") orelse {
        out.reason = .missing_request;
        return out;
    };
    const request_object = request_value.object() orelse return error.InvalidMitmproxyFlow;
    var request = Request{
        .message = try message(a, request_object),
        .host = textField(request_object, "host"),
        .method = textField(request_object, "method"),
        .scheme = textField(request_object, "scheme"),
        .authority = textField(request_object, "authority"),
        .path = textField(request_object, "path"),
    };
    if (integerField(request_object, "port")) |port| {
        if (port >= 0) request.port = std.math.cast(u16, port);
    }
    out.time_ns = request.message.timestamp_start_ns orelse timestamp(object, "timestamp_created");
    if (out.time_ns == null) out.reason = .invalid_timestamp;
    out.request = request;
    if (field(object, "response")) |response_value| switch (response_value) {
        .null => {},
        .map => |response_object| {
            var response = Response{
                .message = try message(a, response_object),
                .reason_text = textField(response_object, "reason"),
            };
            if (integerField(response_object, "status_code")) |status| {
                if (status >= 0) response.status_code = std.math.cast(u16, status);
            }
            out.response = response;
        },
        else => return error.InvalidMitmproxyFlow,
    };
    return out;
}

fn appendTnet(a: std.mem.Allocator, out: *std.ArrayList(u8), tag: u8, payload: []const u8) !void {
    try out.*.print(a, "{d}:{s}{c}", .{ payload.len, payload, tag });
}

fn appendPair(a: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try appendTnet(a, out, ';', key);
    try out.appendSlice(a, value);
}

test "mitmproxy tnetstring flow borrows body and preserves unsupported records" {
    const a = std.testing.allocator;
    var body: [37]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5833);
    prng.random().bytes(&body);
    var request_body: std.ArrayList(u8) = .empty;
    defer request_body.deinit(a);
    try appendPair(a, &request_body, "http_version", "8:HTTP/1.1,");
    try appendPair(a, &request_body, "host", "9:localhost;");
    try appendPair(a, &request_body, "method", "3:GET,");
    try appendPair(a, &request_body, "scheme", "5:https,");
    try appendPair(a, &request_body, "authority", "0:,");
    try appendPair(a, &request_body, "path", "1:/,");
    try appendPair(a, &request_body, "port", "3:443#");
    try appendPair(a, &request_body, "timestamp_start", "3:1.5^");
    try appendPair(a, &request_body, "timestamp_end", "3:1.6^");
    try appendPair(a, &request_body, "headers", "0:]");
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(a);
    try appendTnet(a, &content, ',', &body);
    try appendPair(a, &request_body, "content", content.items);
    var flow_body: std.ArrayList(u8) = .empty;
    defer flow_body.deinit(a);
    try appendPair(a, &flow_body, "version", "2:21#");
    try appendPair(a, &flow_body, "type", "4:http;");
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(a);
    try appendTnet(a, &request, '}', request_body.items);
    try appendPair(a, &flow_body, "request", request.items);
    try appendPair(a, &flow_body, "response", "0:~");
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(a);
    try appendTnet(a, &file, '}', flow_body.items);
    var unsupported: std.ArrayList(u8) = .empty;
    defer unsupported.deinit(a);
    try appendPair(a, &unsupported, "version", "2:21#");
    try appendPair(a, &unsupported, "type", "3:tcp;");
    try appendTnet(a, &file, '}', unsupported.items);
    const owned = try a.dupe(u8, file.items);
    const stream = try Stream.open(a, owned, "owned.mitm");
    defer stream.destroy();
    try std.testing.expectEqual(Stop.complete, stream.stop);
    try std.testing.expectEqual(@as(usize, 2), stream.records.len);
    try std.testing.expectEqual(@as(?u64, 1_500_000_000), stream.records[0].time_ns);
    try std.testing.expectEqualSlices(u8, &body, stream.records[0].request.?.message.content.?);
    try std.testing.expect(stream.records[0].request.?.message.content_sha256 != null);
    try std.testing.expectEqual(Reason.unsupported_flow, stream.records[1].reason);
}

test "mitmproxy reader bounds nesting and retains earlier flows on truncation" {
    const a = std.testing.allocator;
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(a);
    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(a);
    try appendPair(a, &first, "version", "2:21#");
    try appendPair(a, &first, "type", "3:tcp;");
    try appendTnet(a, &file, '}', first.items);
    try file.appendSlice(a, "10:short");
    const owned = try a.dupe(u8, file.items);
    const stream = try Stream.open(a, owned, "cut.mitm");
    defer stream.destroy();
    try std.testing.expectEqual(@as(usize, 1), stream.records.len);
    try std.testing.expectEqual(Stop.truncated, stream.stop);
}

test "mitmproxy timestamps at the u64 nanosecond edge are rejected, not trapped" {
    const edges = [_][]const u8{ "18446744073.709553", "18446744073.709551615", "1e300", "18446744072.5" };
    for (edges) |edge| {
        var buf: [64]u8 = undefined;
        var parser = Parser{ .a = std.testing.allocator, .input = try std.fmt.bufPrint(&buf, "{d}:{s}^", .{ edge.len, edge }) };
        const entries = [_]Entry{.{ .key = "t", .value = try parser.value(0) }};
        const got = timestamp(&entries, "t");
        if (edge[0] == '1' and edge[1] == '8' and edge[10] == '2') try std.testing.expect(got != null) else try std.testing.expect(got == null);
    }
}
