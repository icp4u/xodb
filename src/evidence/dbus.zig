//! Bounded offline decoder for dbus-monitor --pcap output (LINKTYPE_DBUS).
//! Messages borrow bytes from the immutable X1 parent stream.
const std = @import("std");
const evidence = @import("stream.zig");

pub const decoder = "xodb-dbus";
pub const decoder_version: u32 = 1;
pub const link_dbus: u16 = 231;
pub const stream_id: u32 = 5;
pub const max_records: usize = 1_048_576;
pub const max_arguments: usize = 4096;
pub const max_depth: usize = 32;
pub const max_array_bytes: usize = 1024 * 1024;
pub const max_identities: usize = 65_536;
pub const max_pending: usize = 65_536;
/// Typed argument nodes kept for the whole stream. A node is ~100 bytes, so
/// this caps decoded bodies near 400 MiB however small the input messages are.
pub const max_total_arguments: usize = 4 * 1024 * 1024;

pub const MessageType = enum { method_call, method_return, error_reply, signal, unknown };
pub const Reason = enum {
    none,
    truncated_header,
    invalid_endian,
    invalid_version,
    invalid_message_type,
    message_too_large,
    truncated_fields,
    malformed_fields,
    truncated_body,
    malformed_signature,
    argument_limit,
    depth_limit,
    array_limit,
    malformed_body,
};
pub const ArgumentKind = enum { byte, boolean, signed, unsigned, floating, string, object_path, signature, unix_fd, array, structure, dictionary, variant };

pub const Argument = struct {
    kind: ArgumentKind,
    signature: []const u8,
    signed: ?i64 = null,
    unsigned: ?u64 = null,
    floating_bits: ?u64 = null,
    text: ?[]const u8 = null,
    byte_length: ?u32 = null,
    byte_sha256: ?[32]u8 = null,
    children: []const Argument = &.{},
};

pub const Record = struct {
    source_record: u32,
    time_ns: ?u64,
    message_type: MessageType = .unknown,
    flags: u8 = 0,
    serial: u32 = 0,
    reply_serial: ?u32 = null,
    sender: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    body_signature: []const u8 = "",
    arguments: []const Argument = &.{},
    body_length: u32 = 0,
    peer_record: ?u32 = null,
    latency_ns: ?u64 = null,
    reason: Reason = .none,
};

pub const Identity = struct {
    name: []const u8,
    pid: u32,
    call_record: u32,
    reply_record: u32,
};

pub const Correlation = struct {
    pid: ?u32 = null,
    name: ?[]const u8 = null,
    identity: ?u32 = null,
    basis: []const u8 = "none",
    reason: []const u8 = "neither message endpoint has a captured GetConnectionUnixProcessID result",
};

pub const Stream = struct {
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    id: u32 = stream_id,
    parent: *evidence.Stream,
    label: []const u8,
    records: []Record,
    identities: []Identity,
    identity_index: std.StringHashMapUnmanaged(u32) = .empty,
    malformed: u64 = 0,
    paired: u64 = 0,
    orphan_replies: u64 = 0,
    pending_calls: u64 = 0,
    no_reply_calls: u64 = 0,
    pending_dropped: u64 = 0,
    derived_dropped: u64 = 0,

    pub fn open(a: std.mem.Allocator, parent: *evidence.Stream) !?*Stream {
        var compatible = false;
        for (parent.parsed.interfaces) |iface| if (iface.link_type == link_dbus) {
            compatible = true;
            break;
        };
        if (!compatible) return null;
        const self = try a.create(Stream);
        errdefer a.destroy(self);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(a), .backing = a, .parent = parent, .label = undefined, .records = &.{}, .identities = &.{} };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.label = try std.fmt.allocPrint(arena, "D-Bus: {s}", .{parent.label});
        var records: std.ArrayList(Record) = .empty;
        var pending: std.StringHashMapUnmanaged(u32) = .empty;
        var identities: std.ArrayList(Identity) = .empty;
        var argument_budget: usize = max_total_arguments;
        for (parent.parsed.records, 0..) |source, source_index| {
            if (parent.parsed.interfaces[source.interface].link_type != link_dbus) continue;
            if (records.items.len == max_records) {
                self.derived_dropped += 1;
                continue;
            }
            var record = try decodeRecord(arena, parent.raw(source_index), &argument_budget);
            record.source_record = @intCast(source_index);
            const time = parent.timeOf(source_index);
            record.time_ns = if (time.known) time.stream_ns else null;
            const record_index: u32 = @intCast(records.items.len);
            if (record.message_type == .method_call and record.reason == .none and expectsReply(record.flags)) {
                if (record.sender) |sender| {
                    if (pending.count() < max_pending) {
                        const key = try pairKey(arena, sender, record.serial);
                        if (try pending.fetchPut(arena, key, record_index)) |_| self.pending_dropped += 1;
                    } else self.pending_dropped += 1;
                }
            } else if (record.message_type == .method_call and record.reason == .none) {
                self.no_reply_calls += 1;
            } else if ((record.message_type == .method_return or record.message_type == .error_reply) and record.reply_serial != null and record.destination != null) {
                const key = try pairKey(arena, record.destination.?, record.reply_serial.?);
                if (pending.fetchRemove(key)) |entry| {
                    const call = &records.items[entry.value];
                    record.peer_record = entry.value;
                    call.peer_record = record_index;
                    if (call.time_ns != null and record.time_ns != null and record.time_ns.? >= call.time_ns.?) {
                        record.latency_ns = record.time_ns.? - call.time_ns.?;
                        call.latency_ns = record.latency_ns;
                    }
                    self.paired += 1;
                    if (identityFrom(call.*, record, entry.value, record_index)) |found_identity| {
                        try putIdentity(arena, &identities, &self.identity_index, found_identity);
                    }
                } else self.orphan_replies += 1;
            }
            if (record.reason != .none) self.malformed += 1;
            try records.append(arena, record);
        }
        self.pending_calls = pending.count();
        self.records = records.items;
        self.identities = identities.items;
        return self;
    }

    pub fn destroy(self: *Stream) void {
        const a = self.backing;
        self.arena.deinit();
        a.destroy(self);
    }

    pub fn correlate(self: *const Stream, index: usize) Correlation {
        const record = self.records[index];
        if (record.sender) |sender| if (self.identity(sender)) |found| return .{ .pid = found[1].pid, .name = sender, .identity = found[0], .basis = "dbus_daemon", .reason = "sender unique name has a paired GetConnectionUnixProcessID reply from the bus daemon" };
        if (record.destination) |destination| if (self.identity(destination)) |found| return .{ .pid = found[1].pid, .name = destination, .identity = found[0], .basis = "dbus_daemon", .reason = "destination unique name has a paired GetConnectionUnixProcessID reply from the bus daemon" };
        return .{};
    }

    fn identity(self: *const Stream, name: []const u8) ?struct { u32, Identity } {
        const index = self.identity_index.get(name) orelse return null;
        return .{ index, self.identities[index] };
    }
};

fn expectsReply(flags: u8) bool {
    return flags & 0x1 == 0; // D-Bus NO_REPLY_EXPECTED
}

fn pairKey(a: std.mem.Allocator, name: []const u8, serial: u32) ![]const u8 {
    const key = try a.alloc(u8, name.len + 5);
    @memcpy(key[0..name.len], name);
    key[name.len] = 0;
    std.mem.writeInt(u32, key[name.len + 1 ..][0..4], serial, .little);
    return key;
}

fn identityFrom(call: Record, reply: Record, call_index: u32, reply_index: u32) ?Identity {
    if (!same(call.interface, "org.freedesktop.DBus") or !same(call.member, "GetConnectionUnixProcessID")) return null;
    // Only the bus daemon is authoritative; any peer can implement this
    // interface name on its own connection and answer with a forged PID.
    if (!same(call.destination, "org.freedesktop.DBus") or !same(reply.sender, "org.freedesktop.DBus")) return null;
    if (call.arguments.len != 1 or call.arguments[0].kind != .string or call.arguments[0].text == null) return null;
    if (reply.message_type != .method_return or reply.arguments.len != 1 or reply.arguments[0].unsigned == null) return null;
    const pid = std.math.cast(u32, reply.arguments[0].unsigned.?) orelse return null;
    return .{ .name = call.arguments[0].text.?, .pid = pid, .call_record = call_index, .reply_record = reply_index };
}

fn putIdentity(a: std.mem.Allocator, identities: *std.ArrayList(Identity), index: *std.StringHashMapUnmanaged(u32), identity: Identity) !void {
    if (index.get(identity.name)) |existing| {
        identities.items[existing] = identity;
        return;
    }
    if (identities.items.len == max_identities) return;
    try index.put(a, identity.name, @intCast(identities.items.len));
    try identities.append(a, identity);
}

fn same(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |text| std.mem.eql(u8, text, expected) else false;
}

const Header = struct {
    endian: std.builtin.Endian,
    body_length: u32,
    fields_length: u32,
    body_offset: usize,
};

fn decodeRecord(a: std.mem.Allocator, bytes: []const u8, budget: *usize) !Record {
    var out = Record{ .source_record = 0, .time_ns = null };
    if (bytes.len < 16) return failed(&out, .truncated_header);
    const endian: std.builtin.Endian = switch (bytes[0]) {
        'l' => .little,
        'B' => .big,
        else => return failed(&out, .invalid_endian),
    };
    out.message_type = switch (bytes[1]) {
        1 => .method_call,
        2 => .method_return,
        3 => .error_reply,
        4 => .signal,
        else => .unknown,
    };
    if (out.message_type == .unknown) out.reason = .invalid_message_type;
    out.flags = bytes[2];
    if (bytes[3] != 1 and out.reason == .none) out.reason = .invalid_version;
    out.body_length = std.mem.readInt(u32, bytes[4..8], endian);
    out.serial = std.mem.readInt(u32, bytes[8..12], endian);
    const fields_length = std.mem.readInt(u32, bytes[12..16], endian);
    if (fields_length > max_array_bytes) return failed(&out, .message_too_large);
    const fields_end = 16 + @as(usize, fields_length);
    if (fields_end > bytes.len) return failed(&out, .truncated_fields);
    const body_offset = alignForward(fields_end, 8) orelse return failed(&out, .message_too_large);
    if (body_offset > bytes.len or out.body_length > bytes.len - body_offset) return failed(&out, .truncated_body);
    var fields = Cursor{ .bytes = bytes[16..fields_end], .endian = endian };
    while (fields.at < fields.bytes.len) {
        fields.alignTo(8) catch return failed(&out, .malformed_fields);
        if (fields.at == fields.bytes.len) break;
        const code = fields.byte() catch return failed(&out, .malformed_fields);
        const signature = fields.signature() catch return failed(&out, .malformed_fields);
        if (signature.len != 1) return failed(&out, .malformed_fields);
        switch (signature[0]) {
            's', 'o' => {
                fields.alignTo(4) catch return failed(&out, .malformed_fields);
                const text = fields.string32() catch return failed(&out, .malformed_fields);
                switch (code) {
                    1 => out.path = text,
                    2 => out.interface = text,
                    3 => out.member = text,
                    4 => out.error_name = text,
                    6 => out.destination = text,
                    7 => out.sender = text,
                    else => {},
                }
            },
            'g' => {
                const value = fields.signature() catch return failed(&out, .malformed_fields);
                if (code == 8) out.body_signature = value;
            },
            'u' => {
                fields.alignTo(4) catch return failed(&out, .malformed_fields);
                const value = fields.int(u32) catch return failed(&out, .malformed_fields);
                if (code == 5) out.reply_serial = value;
            },
            else => return failed(&out, .malformed_fields),
        }
    }
    if (out.reason != .none) return out;
    if (out.body_signature.len == 0) {
        if (out.body_length != 0) out.reason = .malformed_body;
        return out;
    }
    var body = Cursor{ .bytes = bytes[body_offset..][0..out.body_length], .endian = endian };
    var state = ParseState{ .a = a, .budget = budget };
    out.arguments = parseArguments(&state, &body, out.body_signature, 0) catch |err| {
        out.reason = switch (err) {
            error.ArgumentLimit => .argument_limit,
            error.DepthLimit => .depth_limit,
            error.ArrayLimit => .array_limit,
            error.MalformedSignature => .malformed_signature,
            else => .malformed_body,
        };
        return out;
    };
    if (body.at != body.bytes.len) out.reason = .malformed_body;
    return out;
}

fn failed(out: *Record, reason: Reason) Record {
    out.reason = reason;
    return out.*;
}

const ParseState = struct {
    a: std.mem.Allocator,
    budget: *usize,
    count: usize = 0,

    /// Charges one node to the message and to the stream. Nodes of a body that
    /// later fails stay charged: their arena memory is not reclaimed.
    fn take(self: *ParseState) !void {
        if (self.count == max_arguments or self.budget.* == 0) return error.ArgumentLimit;
        self.count += 1;
        self.budget.* -= 1;
    }
};

fn parseArguments(state: *ParseState, cursor: *Cursor, signature: []const u8, depth: usize) anyerror![]const Argument {
    if (depth > max_depth) return error.DepthLimit;
    var out: std.ArrayList(Argument) = .empty;
    var at: usize = 0;
    while (at < signature.len) {
        const end = signatureEnd(signature, at, depth) orelse return error.MalformedSignature;
        try state.take();
        try out.append(state.a, try parseOne(state, cursor, signature[at..end], depth));
        at = end;
    }
    return out.items;
}

fn parseOne(state: *ParseState, cursor: *Cursor, signature: []const u8, depth: usize) anyerror!Argument {
    const code = signature[0];
    try cursor.alignTo(typeAlignment(code));
    var out = Argument{ .kind = .byte, .signature = signature };
    switch (code) {
        'y' => out.unsigned = try cursor.byte(),
        'b' => {
            out.kind = .boolean;
            const value = try cursor.int(u32);
            if (value > 1) return error.MalformedBody;
            out.unsigned = value;
        },
        'n' => {
            out.kind = .signed;
            out.signed = try cursor.int(i16);
        },
        'q' => {
            out.kind = .unsigned;
            out.unsigned = try cursor.int(u16);
        },
        'i' => {
            out.kind = .signed;
            out.signed = try cursor.int(i32);
        },
        'u' => {
            out.kind = .unsigned;
            out.unsigned = try cursor.int(u32);
        },
        'x' => {
            out.kind = .signed;
            out.signed = try cursor.int(i64);
        },
        't' => {
            out.kind = .unsigned;
            out.unsigned = try cursor.int(u64);
        },
        'd' => {
            out.kind = .floating;
            out.floating_bits = try cursor.int(u64);
        },
        'h' => {
            out.kind = .unix_fd;
            out.unsigned = try cursor.int(u32);
        },
        's', 'o' => {
            out.kind = if (code == 's') .string else .object_path;
            out.text = try cursor.string32();
        },
        'g' => {
            out.kind = .signature;
            out.text = try cursor.signature();
        },
        'a' => {
            out.kind = .array;
            const size = try cursor.int(u32);
            if (size > max_array_bytes) return error.ArrayLimit;
            const element = signature[1..];
            try cursor.alignTo(typeAlignment(element[0]));
            if (size > cursor.bytes.len - cursor.at) return error.Truncated;
            const end = cursor.at + size;
            if (element.len == 1 and element[0] == 'y') {
                const bytes = try cursor.take(size);
                out.byte_length = size;
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
                out.byte_sha256 = digest;
                return out;
            }
            var children: std.ArrayList(Argument) = .empty;
            while (cursor.at < end) {
                try state.take();
                try children.append(state.a, try parseOne(state, cursor, element, depth + 1));
                if (cursor.at > end) return error.MalformedBody;
            }
            if (cursor.at != end) return error.MalformedBody;
            out.children = children.items;
        },
        '(' => {
            out.kind = .structure;
            out.children = try parseArguments(state, cursor, signature[1 .. signature.len - 1], depth + 1);
        },
        '{' => {
            out.kind = .dictionary;
            out.children = try parseArguments(state, cursor, signature[1 .. signature.len - 1], depth + 1);
        },
        'v' => {
            out.kind = .variant;
            const variant_signature = try cursor.signature();
            const end = signatureEnd(variant_signature, 0, depth + 1) orelse return error.MalformedSignature;
            if (end != variant_signature.len) return error.MalformedSignature;
            try state.take();
            const child = try state.a.alloc(Argument, 1);
            child[0] = try parseOne(state, cursor, variant_signature, depth + 1);
            out.children = child;
        },
        else => return error.MalformedSignature,
    }
    return out;
}

fn signatureEnd(signature: []const u8, start: usize, depth: usize) ?usize {
    if (start >= signature.len or depth > max_depth) return null;
    return switch (signature[start]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h', 'v' => start + 1,
        'a' => signatureEnd(signature, start + 1, depth + 1),
        '(', '{' => |open| blk: {
            const close: u8 = if (open == '(') ')' else '}';
            var at = start + 1;
            var count: usize = 0;
            while (at < signature.len and signature[at] != close) {
                at = signatureEnd(signature, at, depth + 1) orelse return null;
                count += 1;
            }
            // Empty structures are invalid D-Bus; allowing them would let an
            // array of zero-size elements spin without consuming bytes.
            if (at >= signature.len or (open == '{' and count != 2) or count == 0) return null;
            break :blk at + 1;
        },
        else => null,
    };
}

fn typeAlignment(code: u8) usize {
    return switch (code) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

fn alignForward(value: usize, alignment: usize) ?usize {
    const added = std.math.add(usize, value, alignment - 1) catch return null;
    return added & ~(alignment - 1);
}

const Cursor = struct {
    bytes: []const u8,
    endian: std.builtin.Endian,
    at: usize = 0,

    fn alignTo(self: *Cursor, alignment: usize) !void {
        const next = alignForward(self.at, alignment) orelse return error.Truncated;
        if (next > self.bytes.len) return error.Truncated;
        self.at = next;
    }
    fn take(self: *Cursor, length: usize) ![]const u8 {
        if (length > self.bytes.len - self.at) return error.Truncated;
        defer self.at += length;
        return self.bytes[self.at..][0..length];
    }
    fn byte(self: *Cursor) !u8 {
        return (try self.take(1))[0];
    }
    fn int(self: *Cursor, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], self.endian);
    }
    fn string32(self: *Cursor) ![]const u8 {
        const length = try self.int(u32);
        if (length > max_array_bytes) return error.ArrayLimit;
        const text = try self.take(length);
        if (try self.byte() != 0 or !std.unicode.utf8ValidateSlice(text)) return error.MalformedBody;
        return text;
    }
    fn signature(self: *Cursor) ![]const u8 {
        const length = try self.byte();
        const text = try self.take(length);
        if (try self.byte() != 0 or !validSignature(text)) return error.MalformedSignature;
        return text;
    }
};

fn validSignature(signature: []const u8) bool {
    if (signature.len > 255) return false;
    var at: usize = 0;
    while (at < signature.len) at = signatureEnd(signature, at, 0) orelse return false;
    return true;
}

test "D-Bus typed body parser is bounded" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body = [_]u8{ 3, 0, 0, 0, 'o', 'n', 'e', 0, 7, 0, 0, 0 };
    var cursor = Cursor{ .bytes = &body, .endian = .little };
    var budget: usize = max_total_arguments;
    var state = ParseState{ .a = arena.allocator(), .budget = &budget };
    const args = try parseArguments(&state, &cursor, "su", 0);
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("one", args[0].text.?);
    try std.testing.expectEqual(@as(u64, 7), args[1].unsigned.?);
    var bad = Cursor{ .bytes = &.{ 0xff, 0xff, 0xff, 0x7f }, .endian = .little };
    state.count = 0;
    try std.testing.expectError(error.ArrayLimit, parseArguments(&state, &bad, "as", 0));
}

test "D-Bus rejects empty structures and forged PID identities" {
    try std.testing.expect(!validSignature("a()"));
    try std.testing.expect(!validSignature("()"));
    try std.testing.expect(validSignature("a(y)"));
    const call = Record{ .source_record = 0, .time_ns = null, .message_type = .method_call, .interface = "org.freedesktop.DBus", .member = "GetConnectionUnixProcessID", .destination = ":1.3", .arguments = &.{.{ .kind = .string, .signature = "s", .text = ":1.9" }} };
    const reply = Record{ .source_record = 1, .time_ns = null, .message_type = .method_return, .sender = ":1.3", .arguments = &.{.{ .kind = .unsigned, .signature = "u", .unsigned = 1 }} };
    try std.testing.expect(identityFrom(call, reply, 0, 1) == null);
    var daemon_call = call;
    daemon_call.destination = "org.freedesktop.DBus";
    var daemon_reply = reply;
    daemon_reply.sender = "org.freedesktop.DBus";
    try std.testing.expectEqual(@as(u32, 1), identityFrom(daemon_call, daemon_reply, 0, 1).?.pid);
}

test "D-Bus argument nodes are charged to a stream budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var budget: usize = 2;
    var state = ParseState{ .a = arena.allocator(), .budget = &budget };
    var cursor = Cursor{ .bytes = &.{ 1, 2, 3 }, .endian = .little };
    try std.testing.expectError(error.ArgumentLimit, parseArguments(&state, &cursor, "yyy", 0));
    try std.testing.expectEqual(@as(usize, 0), budget);
}

test "D-Bus byte arrays are summarized without one node per byte" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const length: u32 = 5000;
    const body = try a.alloc(u8, 4 + length);
    defer a.free(body);
    std.mem.writeInt(u32, body[0..4], length, .little);
    @memset(body[4..], 0xa5);
    var cursor = Cursor{ .bytes = body, .endian = .little };
    var budget: usize = 1;
    var state = ParseState{ .a = arena.allocator(), .budget = &budget };
    const args = try parseArguments(&state, &cursor, "ay", 0);
    try std.testing.expectEqual(@as(usize, 1), args.len);
    try std.testing.expectEqual(length, args[0].byte_length.?);
    try std.testing.expect(args[0].byte_sha256 != null);
    try std.testing.expectEqual(@as(usize, 0), args[0].children.len);
    try std.testing.expectEqual(@as(usize, 0), budget);
}

test "D-Bus NO_REPLY_EXPECTED calls are not pending" {
    try std.testing.expect(expectsReply(0));
    try std.testing.expect(!expectsReply(1));
    try std.testing.expect(!expectsReply(3));
}
