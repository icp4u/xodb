//! Read-only Redot/Godot 4 scene debugger peer.
//!
//! The engine is the TCP client.  We bind loopback on an ephemeral port before
//! launching it, accept one connection, and trust no message until `set_pid`
//! names the owned inferior.  The wire is a length-prefixed marshalled Variant.
const std = @import("std");

const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("sys/socket.h");
    @cInclude("arpa/inet.h");
    @cInclude("netinet/tcp.h");
});

extern "c" fn bind(c_int, *const c.sockaddr, c.socklen_t) c_int;
extern "c" fn accept4(c_int, ?*c.sockaddr, ?*c.socklen_t, c_int) c_int;
extern "c" fn getsockname(c_int, *c.sockaddr, *c.socklen_t) c_int;

const maximum_message = 8 * 1024 * 1024;
const maximum_values = 262_144;
const maximum_depth = 64;
const maximum_nodes = 65_536;
const maximum_properties = 16_384;
/// Bytes of preview text kept per property; the views clip far sooner.
const maximum_display = 512;
/// Leading elements of a packed array that are decoded; the rest is skipped.
const packed_head = 8;
const f64_flag: u32 = 1 << 16;

pub const State = enum { off, listening, connected, ready, closed, failed };

pub const Node = struct {
    depth: u16,
    child_count: u32,
    name: []const u8,
    type_name: []const u8,
    object_id: u64,
    scene_path: []const u8,
    script_path: ?[]const u8,
    view_flags: u8,
};

pub const Property = struct {
    name: []const u8,
    variant_type: []const u8,
    hint: i64,
    hint_string: []const u8,
    usage: u64,
    display: []const u8,
};

pub const Signal = struct { property: []const u8, display: []const u8 };

pub const Object = struct {
    id: u64 = 0,
    class_name: []const u8 = "",
    script_path: ?[]const u8 = null,
    properties: []const Property = &.{},
    signals: []const Signal = &.{},
};

pub const Snapshot = struct {
    state: State,
    diagnostic: ?[]const u8,
    revision: u64,
    peer_pid: ?i32,
    scene_pending: bool,
    scene_revision: u64,
    nodes: []const Node,
    selected_id: ?u64,
    object_pending: bool,
    object_revision: u64,
    object: Object,
};

const Pair = struct { key: Value, value: Value };
const NamedNumbers = struct { name: []const u8, values: []const f64 };
const Value = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    numbers: NamedNumbers,
    array: []const Value,
    /// A packed array: its element count and only its first few elements.
    packed_array: struct { name: []const u8, count: usize, head: []const Value },
    dictionary: []const Pair,
    object_id: u64,
    rid: u64,
    bytes: []const u8,
    signal: struct { name: []const u8, object_id: u64 },
    callable,
};

pub const Adapter = struct {
    listener: c_int = -1,
    connection: c_int = -1,
    state: State = .off,
    port_: u16 = 0,
    peer_pid: ?i32 = null,
    peer_thread: i64 = 1,
    diagnostic: ?[]const u8 = null,
    revision: u64 = 0,
    scene_revision: u64 = 0,
    object_revision: u64 = 0,
    scene_pending: bool = false,
    object_pending: bool = false,
    selected_id: ?u64 = null,
    nodes: []const Node = &.{},
    object: Object = .{},
    receive: std.ArrayList(u8) = .empty,
    receive_start: usize = 0,
    transmit: std.ArrayList(u8) = .empty,
    transmit_start: usize = 0,
    wire_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    scene_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    object_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),

    pub fn listen(self: *Adapter) !u16 {
        if (self.state != .off) return error.RedotDebuggerAlreadyEnabled;
        const fd = c.socket(c.AF_INET, c.SOCK_STREAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
        if (fd < 0) return error.RedotDebuggerSocketFailed;
        errdefer _ = c.close(fd);
        var address: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
        address.sin_family = c.AF_INET;
        address.sin_port = 0;
        address.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x7f000001);
        if (bind(fd, @ptrCast(&address), @sizeOf(c.sockaddr_in)) < 0) return error.RedotDebuggerBindFailed;
        if (c.listen(fd, 1) < 0) return error.RedotDebuggerListenFailed;
        var bound: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
        var length: c.socklen_t = @sizeOf(c.sockaddr_in);
        if (getsockname(fd, @ptrCast(&bound), &length) < 0 or length != @sizeOf(c.sockaddr_in)) return error.RedotDebuggerAddressFailed;
        self.listener = fd;
        self.port_ = std.mem.bigToNative(u16, bound.sin_port);
        self.state = .listening;
        self.revision += 1;
        return self.port_;
    }

    pub fn port(self: *const Adapter) !u16 {
        if (self.state == .off) return error.RedotDebuggerNotEnabled;
        return self.port_;
    }

    pub fn snapshot(self: *const Adapter) Snapshot {
        return .{
            .state = self.state,
            .diagnostic = self.diagnostic,
            .revision = self.revision,
            .peer_pid = self.peer_pid,
            .scene_pending = self.scene_pending,
            .scene_revision = self.scene_revision,
            .nodes = self.nodes,
            .selected_id = self.selected_id,
            .object_pending = self.object_pending,
            .object_revision = self.object_revision,
            .object = self.object,
        };
    }

    pub fn requestScene(self: *Adapter) !void {
        try self.requireReady();
        if (self.scene_pending) return;
        try self.queue(.scene, 0);
        self.scene_pending = true;
        self.revision += 1;
    }

    pub fn inspect(self: *Adapter, object_id: u64) !void {
        try self.requireReady();
        if (self.object_pending and self.selected_id == object_id) return;
        try self.queue(.object, object_id);
        self.selected_id = object_id;
        self.object_pending = true;
        self.revision += 1;
    }

    fn requireReady(self: *const Adapter) !void {
        return switch (self.state) {
            .off => error.RedotDebuggerNotEnabled,
            .listening, .connected => error.RedotDebuggerPending,
            .ready => {},
            .closed => error.RedotDebuggerClosed,
            .failed => error.RedotDebuggerProtocolError,
        };
    }

    pub fn poll(self: *Adapter, expected_pid: i32) void {
        if (self.state == .off or self.state == .closed or self.state == .failed) return;
        if (self.peer_pid) |pid| if (pid != expected_pid) return self.fail(error.RedotDebuggerTargetChanged);
        if (self.state == .listening) self.acceptOne();
        if (self.connection < 0) return;
        self.flush() catch |err| return self.fail(err);
        self.read() catch |err| return self.fail(err);
        var count: usize = 0;
        while (count < 32) : (count += 1) {
            const available = self.receive.items[self.receive_start..];
            if (available.len < 4) break;
            const size = std.mem.readInt(u32, @ptrCast(available.ptr), .little);
            if (size == 0 or size > maximum_message) return self.fail(error.RedotDebuggerMessageLimit);
            if (available.len < 4 + size) break;
            self.handle(available[4 .. 4 + size], expected_pid) catch |err| return self.fail(err);
            self.receive_start += 4 + size;
        }
        if (self.receive_start > 0 and (self.receive_start == self.receive.items.len or self.receive_start > maximum_message)) {
            const rest = self.receive.items[self.receive_start..];
            std.mem.copyForwards(u8, self.receive.items[0..rest.len], rest);
            self.receive.items.len = rest.len;
            self.receive_start = 0;
        }
        self.flush() catch |err| self.fail(err);
    }

    fn acceptOne(self: *Adapter) void {
        const fd = accept4(self.listener, null, null, c.SOCK_CLOEXEC | c.SOCK_NONBLOCK);
        if (fd < 0) {
            const errno = std.c._errno().*;
            if (errno != c.EAGAIN and errno != c.EWOULDBLOCK and errno != c.EINTR) self.fail(error.RedotDebuggerAcceptFailed);
            return;
        }
        _ = c.close(self.listener);
        self.listener = -1;
        self.connection = fd;
        const yes: c_int = 1;
        _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_NODELAY, &yes, @sizeOf(c_int));
        self.state = .connected;
        self.revision += 1;
    }

    fn read(self: *Adapter) !void {
        var buffer: [64 * 1024]u8 = undefined;
        var total: usize = 0;
        while (total < maximum_message) {
            const got = c.read(self.connection, &buffer, buffer.len);
            if (got > 0) {
                try self.receive.appendSlice(std.heap.page_allocator, buffer[0..@intCast(got)]);
                total += @intCast(got);
                if (self.receive.items.len - self.receive_start > maximum_message + 4) return error.RedotDebuggerMessageLimit;
                continue;
            }
            if (got == 0) return error.RedotDebuggerClosed;
            const errno = std.c._errno().*;
            if (errno == c.EAGAIN or errno == c.EWOULDBLOCK) return;
            if (errno == c.EINTR) continue;
            return error.RedotDebuggerReadFailed;
        }
    }

    fn flush(self: *Adapter) !void {
        while (self.transmit_start < self.transmit.items.len) {
            const bytes = self.transmit.items[self.transmit_start..];
            const sent = c.send(self.connection, bytes.ptr, bytes.len, c.MSG_NOSIGNAL);
            if (sent > 0) {
                self.transmit_start += @intCast(sent);
                continue;
            }
            if (sent == 0) return error.RedotDebuggerClosed;
            const errno = std.c._errno().*;
            if (errno == c.EAGAIN or errno == c.EWOULDBLOCK) return;
            if (errno == c.EINTR) continue;
            return error.RedotDebuggerWriteFailed;
        }
        self.transmit.clearRetainingCapacity();
        self.transmit_start = 0;
    }

    const Request = enum { scene, object };
    fn queue(self: *Adapter, request: Request, object_id: u64) !void {
        if (self.transmit.items.len > 64 * 1024) return error.RedotDebuggerRequestLimit;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(std.heap.page_allocator);
        try encodeArrayHeader(&payload, 3);
        try encodeString(&payload, if (request == .scene) "scene:request_scene_tree" else "scene:inspect_objects");
        try encodeInteger(&payload, self.peer_thread);
        if (request == .scene) {
            try encodeArrayHeader(&payload, 0);
        } else {
            try encodeArrayHeader(&payload, 2);
            try encodeArrayHeader(&payload, 1);
            try encodeInteger(&payload, @bitCast(object_id));
            try encodeBool(&payload, false);
        }
        if (payload.items.len > maximum_message) return error.RedotDebuggerMessageLimit;
        var prefix: [4]u8 = undefined;
        std.mem.writeInt(u32, &prefix, @intCast(payload.items.len), .little);
        try self.transmit.appendSlice(std.heap.page_allocator, &prefix);
        try self.transmit.appendSlice(std.heap.page_allocator, payload.items);
    }

    fn handle(self: *Adapter, bytes: []const u8, expected_pid: i32) !void {
        _ = self.wire_arena.reset(.retain_capacity);
        var decoder = Decoder{ .bytes = bytes, .allocator = self.wire_arena.allocator() };
        const root = try decoder.value(0);
        if (decoder.offset != bytes.len or root != .array or root.array.len != 3) return error.RedotDebuggerMalformedMessage;
        const name = stringValue(root.array[0]) orelse return error.RedotDebuggerMalformedMessage;
        const thread = integerValue(root.array[1]) orelse return error.RedotDebuggerMalformedMessage;
        if (thread < 0) return error.RedotDebuggerMalformedMessage;
        if (root.array[2] != .array) return error.RedotDebuggerMalformedMessage;
        const data = root.array[2].array;
        if (self.state == .connected) {
            if (!std.mem.eql(u8, name, "set_pid") or data.len != 1) return error.RedotDebuggerPidRequired;
            const announced = integerValue(data[0]) orelse return error.RedotDebuggerMalformedMessage;
            if (announced <= 0 or announced > std.math.maxInt(i32) or announced != expected_pid) return error.RedotDebuggerPidMismatch;
            self.peer_pid = @intCast(announced);
            self.peer_thread = thread;
            self.state = .ready;
            self.revision += 1;
            try self.requestScene();
            return;
        }
        if (self.state != .ready) return;
        if (std.mem.eql(u8, name, "scene:scene_tree")) try self.receiveScene(data) else if (std.mem.eql(u8, name, "scene:inspect_objects") or std.mem.eql(u8, name, "scene:inspect_object")) try self.receiveObject(name, data) else if (std.mem.eql(u8, name, "remote_selection_invalidated")) {
            self.object = .{};
            self.object_pending = false;
            self.diagnostic = "RedotObjectNoLongerAvailable";
            self.revision += 1;
        }
    }

    fn receiveScene(self: *Adapter, data: []const Value) !void {
        if (data.len % 6 != 0 or data.len / 6 > maximum_nodes) return error.RedotDebuggerSceneLimit;
        self.nodes = &.{};
        _ = self.scene_arena.reset(.retain_capacity);
        const a = self.scene_arena.allocator();
        const nodes = try a.alloc(Node, data.len / 6);
        var depth: u32 = 0;
        var pending: [maximum_depth]u32 = @splat(0);
        for (nodes, 0..) |*node, index| {
            while (depth > 0 and pending[depth - 1] == 0) depth -= 1;
            if (depth > 0) pending[depth - 1] -= 1;
            const row = data[index * 6 ..][0..6];
            const child_count = integerValue(row[0]) orelse return error.RedotDebuggerMalformedScene;
            const object_id = integerValue(row[3]) orelse return error.RedotDebuggerMalformedScene;
            const flags = integerValue(row[5]) orelse return error.RedotDebuggerMalformedScene;
            if (child_count < 0 or child_count > maximum_nodes or object_id < 0 or flags < 0 or flags > 255 or depth >= maximum_depth) return error.RedotDebuggerMalformedScene;
            const name = stringValue(row[1]) orelse return error.RedotDebuggerMalformedScene;
            const type_name = stringValue(row[2]) orelse return error.RedotDebuggerMalformedScene;
            const scene_path = stringValue(row[4]) orelse return error.RedotDebuggerMalformedScene;
            node.* = .{
                .depth = @intCast(depth),
                .child_count = @intCast(child_count),
                .name = try a.dupe(u8, name),
                .type_name = try a.dupe(u8, type_name),
                .object_id = @bitCast(object_id),
                .scene_path = try a.dupe(u8, scene_path),
                .script_path = if (looksLikeScript(type_name)) try a.dupe(u8, type_name) else null,
                .view_flags = @intCast(flags),
            };
            if (child_count > 0) {
                pending[depth] = @intCast(child_count);
                depth += 1;
            }
        }
        self.nodes = nodes;
        self.scene_pending = false;
        self.scene_revision += 1;
        self.revision += 1;
        if (self.selected_id == null and nodes.len > 0) try self.inspect(nodes[0].object_id);
    }

    fn receiveObject(self: *Adapter, name: []const u8, data_: []const Value) !void {
        const data = if (std.mem.eql(u8, name, "scene:inspect_object")) one: {
            if (data_.len != 3) return error.RedotDebuggerMalformedObject;
            break :one data_;
        } else many: {
            if (data_.len != 1 or data_[0] != .array or data_[0].array.len == 0) return error.RedotDebuggerMalformedObject;
            break :many data_[0].array;
        };
        if (data.len != 3 or data[2] != .array or data[2].array.len > maximum_properties) return error.RedotDebuggerMalformedObject;
        const id = integerValue(data[0]) orelse return error.RedotDebuggerMalformedObject;
        const class_name = stringValue(data[1]) orelse return error.RedotDebuggerMalformedObject;
        // Selection can change while an earlier response is in flight.
        if (self.selected_id != null and @as(u64, @bitCast(id)) != self.selected_id.?) return;
        self.object = .{};
        _ = self.object_arena.reset(.retain_capacity);
        const a = self.object_arena.allocator();
        var properties: std.ArrayList(Property) = .empty;
        var signals: std.ArrayList(Signal) = .empty;
        var script_path: ?[]const u8 = null;
        for (data[2].array) |entry| {
            if (entry != .array or entry.array.len != 6) return error.RedotDebuggerMalformedObject;
            const property_name = stringValue(entry.array[0]) orelse return error.RedotDebuggerMalformedObject;
            const kind = integerValue(entry.array[1]) orelse return error.RedotDebuggerMalformedObject;
            const hint = integerValue(entry.array[2]) orelse return error.RedotDebuggerMalformedObject;
            const hint_string = stringValue(entry.array[3]) orelse return error.RedotDebuggerMalformedObject;
            const usage = integerValue(entry.array[4]) orelse return error.RedotDebuggerMalformedObject;
            if (kind < 0 or kind > 255 or usage < 0) return error.RedotDebuggerMalformedObject;
            const display = try displayValue(a, entry.array[5], 0);
            const type_name = variantName(@intCast(kind));
            const saved_name = try a.dupe(u8, property_name);
            try properties.append(a, .{ .name = saved_name, .variant_type = type_name, .hint = hint, .hint_string = try a.dupe(u8, hint_string), .usage = @intCast(usage), .display = display });
            if ((std.mem.eql(u8, property_name, "script") or std.mem.endsWith(u8, property_name, "/script")) and entry.array[5] == .string and looksLikeScript(entry.array[5].string)) script_path = try a.dupe(u8, entry.array[5].string);
            if (entry.array[5] == .signal) try signals.append(a, .{ .property = saved_name, .display = display });
        }
        self.object = .{ .id = @bitCast(id), .class_name = try a.dupe(u8, class_name), .script_path = script_path, .properties = try properties.toOwnedSlice(a), .signals = try signals.toOwnedSlice(a) };
        self.object_pending = false;
        self.diagnostic = null;
        self.object_revision += 1;
        self.revision += 1;
    }

    fn fail(self: *Adapter, err: anyerror) void {
        self.diagnostic = @errorName(err);
        self.state = if (err == error.RedotDebuggerClosed) .closed else .failed;
        self.scene_pending = false;
        self.object_pending = false;
        if (self.connection >= 0) _ = c.close(self.connection);
        if (self.listener >= 0) _ = c.close(self.listener);
        self.connection = -1;
        self.listener = -1;
        self.revision += 1;
    }

    pub fn deinit(self: *Adapter) void {
        if (self.connection >= 0) _ = c.close(self.connection);
        if (self.listener >= 0) _ = c.close(self.listener);
        self.receive.deinit(std.heap.page_allocator);
        self.transmit.deinit(std.heap.page_allocator);
        self.wire_arena.deinit();
        self.scene_arena.deinit();
        self.object_arena.deinit();
        self.* = undefined;
    }
};

fn integerValue(value: Value) ?i64 {
    return if (value == .integer) value.integer else null;
}
fn stringValue(value: Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}
fn looksLikeScript(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "res://") and (std.mem.endsWith(u8, text, ".gd") or std.mem.endsWith(u8, text, ".cs"));
}

fn variantName(kind: u8) []const u8 {
    return switch (kind) {
        0 => "Nil",
        1 => "bool",
        2 => "int",
        3 => "float",
        4 => "String",
        5 => "Vector2",
        6 => "Vector2i",
        7 => "Rect2",
        8 => "Rect2i",
        9 => "Vector3",
        10 => "Vector3i",
        11 => "Transform2D",
        12 => "Vector4",
        13 => "Vector4i",
        14 => "Plane",
        15 => "Quaternion",
        16 => "AABB",
        17 => "Basis",
        18 => "Transform3D",
        19 => "Projection",
        20 => "Color",
        21 => "StringName",
        22 => "NodePath",
        23 => "RID",
        24 => "Object",
        25 => "Callable",
        26 => "Signal",
        27 => "Dictionary",
        28 => "Array",
        29 => "PackedByteArray",
        30 => "PackedInt32Array",
        31 => "PackedInt64Array",
        32 => "PackedFloat32Array",
        33 => "PackedFloat64Array",
        34 => "PackedStringArray",
        35 => "PackedVector2Array",
        36 => "PackedVector3Array",
        37 => "PackedColorArray",
        38 => "PackedVector4Array",
        else => "Variant",
    };
}

fn displayValue(a: std.mem.Allocator, value: Value, depth: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try appendDisplay(a, &out, value, depth);
    if (out.items.len > maximum_display) {
        var end: usize = maximum_display;
        while (end > 0 and out.items[end] & 0xc0 == 0x80) end -= 1;
        out.shrinkRetainingCapacity(end);
        try out.appendSlice(a, "…");
    }
    return out.toOwnedSlice(a);
}

fn appendDisplay(a: std.mem.Allocator, out: *std.ArrayList(u8), value: Value, depth: usize) !void {
    if (out.items.len > maximum_display) return;
    if (depth >= 4) return out.appendSlice(a, "…");
    switch (value) {
        .nil => try out.appendSlice(a, "null"),
        .boolean => |v| try out.appendSlice(a, if (v) "true" else "false"),
        .integer => |v| try out.print(a, "{d}", .{v}),
        .float => |v| try out.print(a, "{d}", .{v}),
        .string => |v| {
            try out.append(a, '"');
            var end = @min(v.len, 96);
            while (end < v.len and end > 0 and v[end] & 0xc0 == 0x80) end -= 1;
            try out.appendSlice(a, v[0..end]);
            if (v.len > end) try out.appendSlice(a, "…");
            try out.append(a, '"');
        },
        .numbers => |v| {
            try out.print(a, "{s}(", .{v.name});
            for (v.values[0..@min(v.values.len, 8)], 0..) |number, i| {
                if (i != 0) try out.appendSlice(a, ", ");
                try out.print(a, "{d}", .{number});
            }
            if (v.values.len > 8) try out.appendSlice(a, ", …");
            try out.append(a, ')');
        },
        .array => |items| {
            try out.print(a, "Array({d}) [", .{items.len});
            for (items[0..@min(items.len, 8)], 0..) |item, i| {
                if (i != 0) try out.appendSlice(a, ", ");
                try appendDisplay(a, out, item, depth + 1);
            }
            if (items.len > 8) try out.appendSlice(a, ", …");
            try out.append(a, ']');
        },
        .packed_array => |v| {
            try out.print(a, "{s}({d}) [", .{ v.name, v.count });
            for (v.head, 0..) |item, i| {
                if (i != 0) try out.appendSlice(a, ", ");
                try appendDisplay(a, out, item, depth + 1);
            }
            if (v.count > v.head.len) try out.appendSlice(a, ", …");
            try out.append(a, ']');
        },
        .dictionary => |items| {
            try out.print(a, "Dictionary({d}) {{", .{items.len});
            for (items[0..@min(items.len, 6)], 0..) |item, i| {
                if (i != 0) try out.appendSlice(a, ", ");
                try appendDisplay(a, out, item.key, depth + 1);
                try out.appendSlice(a, ": ");
                try appendDisplay(a, out, item.value, depth + 1);
            }
            if (items.len > 6) try out.appendSlice(a, ", …");
            try out.append(a, '}');
        },
        .object_id => |id| try out.print(a, "Object#{d}", .{id}),
        .rid => |id| try out.print(a, "RID({d})", .{id}),
        .bytes => |bytes| try out.print(a, "PackedByteArray({d})", .{bytes.len}),
        .signal => |signal| try out.print(a, "Signal({s} on #{d})", .{ signal.name, signal.object_id }),
        .callable => try out.appendSlice(a, "Callable"),
    }
}

const Decoder = struct {
    bytes: []const u8,
    offset: usize = 0,
    values: usize = 0,
    reserved: usize = 0,
    allocator: std.mem.Allocator,

    /// Charges a container's claimed element count before anything is
    /// allocated for it: the claim must fit the bytes still unread, and all
    /// claims in one message share the value budget.
    fn reserve(self: *Decoder, count: usize, element_bytes: usize) !void {
        if (count > (self.bytes.len -| self.offset) / element_bytes) return error.RedotDebuggerTruncatedMessage;
        if (count > maximum_values - self.reserved) return error.RedotDebuggerVariantLimit;
        self.reserved += count;
    }

    fn take(self: *Decoder, count: usize) ![]const u8 {
        if (count > self.bytes.len -| self.offset) return error.RedotDebuggerTruncatedMessage;
        const result = self.bytes[self.offset..][0..count];
        self.offset += count;
        return result;
    }
    fn readU32(self: *Decoder) !u32 {
        const bytes = try self.take(4);
        return std.mem.readInt(u32, @ptrCast(bytes.ptr), .little);
    }
    fn readI32(self: *Decoder) !i32 {
        return @bitCast(try self.readU32());
    }
    fn readU64(self: *Decoder) !u64 {
        const bytes = try self.take(8);
        return std.mem.readInt(u64, @ptrCast(bytes.ptr), .little);
    }
    fn readI64(self: *Decoder) !i64 {
        return @bitCast(try self.readU64());
    }
    fn readF32(self: *Decoder) !f32 {
        return @bitCast(try self.readU32());
    }
    fn readF64(self: *Decoder) !f64 {
        return @bitCast(try self.readU64());
    }
    fn rawString(self: *Decoder) ![]const u8 {
        const length = try self.readU32();
        if (length > maximum_message) return error.RedotDebuggerStringLimit;
        const text = try self.take(length);
        _ = try self.take((4 - length % 4) % 4);
        return text;
    }
    fn string(self: *Decoder) ![]const u8 {
        const text = try self.rawString();
        if (!std.unicode.utf8ValidateSlice(text)) return error.RedotDebuggerInvalidUtf8;
        return self.allocator.dupe(u8, text);
    }
    fn customType(self: *Decoder, kind: u2) !void {
        switch (kind) {
            0 => {},
            1 => _ = try self.readU32(),
            2, 3 => _ = try self.string(),
        }
    }
    fn numberVector(self: *Decoder, name: []const u8, count: usize, wide: bool) !Value {
        const values = try self.allocator.alloc(f64, count);
        for (values) |*number| number.* = if (wide) try self.readF64() else try self.readF32();
        return .{ .numbers = .{ .name = name, .values = values } };
    }
    fn integerVector(self: *Decoder, name: []const u8, count: usize) !Value {
        const values = try self.allocator.alloc(f64, count);
        for (values) |*number| number.* = @floatFromInt(try self.readI32());
        return .{ .numbers = .{ .name = name, .values = values } };
    }
    fn value(self: *Decoder, depth: usize) !Value {
        if (depth >= maximum_depth or self.values >= maximum_values) return error.RedotDebuggerVariantLimit;
        self.values += 1;
        const header = try self.readU32();
        const kind: u8 = @truncate(header);
        const wide = header & f64_flag != 0;
        return switch (kind) {
            0 => .nil,
            1 => .{ .boolean = try self.readU32() != 0 },
            2 => .{ .integer = if (wide) try self.readI64() else try self.readI32() },
            3 => .{ .float = if (wide) try self.readF64() else try self.readF32() },
            4, 21 => .{ .string = try self.string() },
            5 => try self.numberVector("Vector2", 2, wide),
            6 => try self.integerVector("Vector2i", 2),
            7 => try self.numberVector("Rect2", 4, wide),
            8 => try self.integerVector("Rect2i", 4),
            9 => try self.numberVector("Vector3", 3, wide),
            10 => try self.integerVector("Vector3i", 3),
            11 => try self.numberVector("Transform2D", 6, wide),
            12 => try self.numberVector("Vector4", 4, wide),
            13 => try self.integerVector("Vector4i", 4),
            14 => try self.numberVector("Plane", 4, wide),
            15 => try self.numberVector("Quaternion", 4, wide),
            16 => try self.numberVector("AABB", 6, wide),
            17 => try self.numberVector("Basis", 9, wide),
            18 => try self.numberVector("Transform3D", 12, wide),
            19 => try self.numberVector("Projection", 16, wide),
            20 => try self.numberVector("Color", 4, false),
            22 => node_path: {
                const count_word = try self.readU32();
                if (count_word & 0x80000000 == 0) {
                    self.offset -= 4;
                    break :node_path .{ .string = try self.string() };
                }
                const names = count_word & 0x7fffffff;
                const subnames = try self.readU32();
                const flags = try self.readU32();
                try self.reserve(@as(usize, names) + subnames, 4);
                var text: std.ArrayList(u8) = .empty;
                if (flags & 1 != 0) try text.append(self.allocator, '/');
                for (0..names + subnames) |i| {
                    const part = try self.string();
                    if (i != 0 or i >= names) try text.append(self.allocator, if (i < names) '/' else ':');
                    try text.appendSlice(self.allocator, part);
                }
                break :node_path .{ .string = try text.toOwnedSlice(self.allocator) };
            },
            23 => .{ .rid = try self.readU64() },
            24 => object: {
                if (wide) break :object .{ .object_id = try self.readU64() };
                const class_name = try self.string();
                if (class_name.len == 0) break :object .nil;
                const count = try self.readU32();
                if (count > maximum_properties) return error.RedotDebuggerVariantLimit;
                try self.reserve(count, 8);
                const pairs = try self.allocator.alloc(Pair, count);
                for (pairs) |*pair| pair.* = .{ .key = .{ .string = try self.string() }, .value = try self.value(depth + 1) };
                break :object .{ .dictionary = pairs };
            },
            25 => .callable,
            26 => .{ .signal = .{ .name = try self.string(), .object_id = try self.readU64() } },
            27 => dictionary: {
                try self.customType(@truncate(header >> 16));
                try self.customType(@truncate(header >> 18));
                const count = (try self.readU32()) & 0x7fffffff;
                try self.reserve(count, 8);
                const pairs = try self.allocator.alloc(Pair, count);
                for (pairs) |*pair| pair.* = .{ .key = try self.value(depth + 1), .value = try self.value(depth + 1) };
                break :dictionary .{ .dictionary = pairs };
            },
            28 => array: {
                try self.customType(@truncate(header >> 16));
                const count = (try self.readU32()) & 0x7fffffff;
                try self.reserve(count, 4);
                const items = try self.allocator.alloc(Value, count);
                for (items) |*item| item.* = try self.value(depth + 1);
                break :array .{ .array = items };
            },
            29 => bytes: {
                const count = try self.readU32();
                const bytes = try self.take(count);
                _ = try self.take((4 - count % 4) % 4);
                break :bytes .{ .bytes = bytes };
            },
            30...38 => packed_value: {
                // Only the leading elements are kept; the rest is walked or
                // skipped, so a large array costs no allocation.
                const count: usize = try self.readU32();
                const real: usize = if (wide) 8 else 4;
                const head = try self.allocator.alloc(Value, @min(count, packed_head));
                for (head) |*item| item.* = switch (kind) {
                    30 => .{ .integer = try self.readI32() },
                    31 => .{ .integer = try self.readI64() },
                    32 => .{ .float = try self.readF32() },
                    33 => .{ .float = try self.readF64() },
                    34 => .{ .string = try self.string() },
                    35 => try self.numberVector("", 2, wide),
                    36 => try self.numberVector("", 3, wide),
                    37 => try self.numberVector("", 4, false),
                    38 => try self.numberVector("", 4, wide),
                    else => unreachable,
                };
                const rest = count - head.len;
                if (kind == 34) {
                    for (0..rest) |_| _ = try self.rawString();
                } else _ = try self.take(rest * @as(usize, switch (kind) {
                    30, 32 => 4,
                    31, 33 => 8,
                    35 => 2 * real,
                    36 => 3 * real,
                    37 => 16,
                    38 => 4 * real,
                    else => unreachable,
                }));
                break :packed_value .{ .packed_array = .{ .name = variantName(kind), .count = count, .head = head } };
            },
            else => error.RedotDebuggerUnsupportedVariant,
        };
    }
};

fn encodeU32(out: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(std.heap.page_allocator, &bytes);
}
fn encodeU64(out: *std.ArrayList(u8), value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try out.appendSlice(std.heap.page_allocator, &bytes);
}
fn encodeArrayHeader(out: *std.ArrayList(u8), count: u32) !void {
    try encodeU32(out, 28);
    try encodeU32(out, count);
}
fn encodeInteger(out: *std.ArrayList(u8), value: i64) !void {
    try encodeU32(out, 2 | f64_flag);
    try encodeU64(out, @bitCast(value));
}
fn encodeBool(out: *std.ArrayList(u8), value: bool) !void {
    try encodeU32(out, 1);
    try encodeU32(out, @intFromBool(value));
}
fn encodeString(out: *std.ArrayList(u8), value: []const u8) !void {
    try encodeU32(out, 4);
    try encodeU32(out, @intCast(value.len));
    try out.appendSlice(std.heap.page_allocator, value);
    try out.appendNTimes(std.heap.page_allocator, 0, (4 - value.len % 4) % 4);
}

test "decodes a bounded scene tree payload" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.heap.page_allocator);
    try encodeArrayHeader(&bytes, 3);
    try encodeString(&bytes, "scene:scene_tree");
    try encodeInteger(&bytes, 1);
    try encodeArrayHeader(&bytes, 12);
    try encodeInteger(&bytes, 1);
    try encodeString(&bytes, "root");
    try encodeString(&bytes, "Window");
    try encodeInteger(&bytes, 10);
    try encodeString(&bytes, "res://main.tscn");
    try encodeInteger(&bytes, 0);
    try encodeInteger(&bytes, 0);
    try encodeString(&bytes, "player");
    try encodeString(&bytes, "res://player.gd");
    try encodeInteger(&bytes, 11);
    try encodeString(&bytes, "");
    try encodeInteger(&bytes, 6);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var decoder = Decoder{ .bytes = bytes.items, .allocator = arena.allocator() };
    const message = try decoder.value(0);
    try std.testing.expectEqual(@as(usize, 3), message.array.len);
    var adapter = Adapter{};
    defer adapter.deinit();
    adapter.state = .ready;
    try adapter.receiveScene(message.array[2].array);
    try std.testing.expectEqual(@as(usize, 2), adapter.nodes.len);
    try std.testing.expectEqual(@as(u16, 1), adapter.nodes[1].depth);
    try std.testing.expectEqualStrings("res://player.gd", adapter.nodes[1].script_path.?);
}

test "engine object reply envelope and selection preserve script and property values" {
    const property = [_]Value{ .{ .string = "script" }, .{ .integer = 24 }, .{ .integer = 0 }, .{ .string = "" }, .{ .integer = 6 }, .{ .string = "res://player.gd" } };
    const properties = [_]Value{.{ .array = &property }};
    const object = [_]Value{ .{ .integer = 11 }, .{ .string = "Node2D" }, .{ .array = &properties } };
    const envelope = [_]Value{.{ .array = &object }};
    var adapter = Adapter{};
    defer adapter.deinit();
    adapter.selected_id = 11;
    try adapter.receiveObject("scene:inspect_objects", &envelope);
    try std.testing.expectEqualStrings("res://player.gd", adapter.object.script_path.?);
    try std.testing.expectEqual(@as(u64, 11), adapter.object.id);
    adapter.selected_id = 12;
    adapter.object_pending = true;
    try adapter.receiveObject("scene:inspect_objects", &envelope);
    try std.testing.expect(adapter.object_pending);
}

test "protocol preview keeps integer identity and complete UTF-8 characters" {
    const a = std.testing.allocator;
    const value = try displayValue(a, .{ .rid = 0xffffffffffffffff }, 0);
    defer a.free(value);
    try std.testing.expectEqualStrings("RID(18446744073709551615)", value);
    const unicode = try displayValue(a, .{ .string = "x" ** 95 ++ "éfin" }, 0);
    defer a.free(unicode);
    try std.testing.expect(std.unicode.utf8ValidateSlice(unicode));
    try std.testing.expectEqualStrings("\"" ++ "x" ** 95 ++ "…\"", unicode);
}

fn decodeBytes(bytes: []const u8) !Value {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var decoder = Decoder{ .bytes = bytes, .allocator = arena.allocator() };
    const value = try decoder.value(0);
    // Tests only look at the tag: the payload dies with the arena.
    return switch (value) {
        .packed_array => |v| .{ .integer = @intCast(v.count) },
        else => .nil,
    };
}

fn words(comptime list: anytype) [list.len * 4]u8 {
    var out: [list.len * 4]u8 = undefined;
    inline for (list, 0..) |word, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], word, .little);
    return out;
}

test "malformed frames are refused before any large allocation" {
    // Container and string lengths far beyond the bytes that follow.
    try std.testing.expectError(error.RedotDebuggerTruncatedMessage, decodeBytes(&words(.{ 28, 0x7fffffff })));
    try std.testing.expectError(error.RedotDebuggerTruncatedMessage, decodeBytes(&words(.{ 27, 200_000 })));
    try std.testing.expectError(error.RedotDebuggerStringLimit, decodeBytes(&words(.{ 4, 0xffffffff })));
    try std.testing.expectError(error.RedotDebuggerTruncatedMessage, decodeBytes(&words(.{ 4, 64, 0 })));
    try std.testing.expectError(error.RedotDebuggerTruncatedMessage, decodeBytes(&words(.{ 29, 0xfffffffd })));
    try std.testing.expectError(error.RedotDebuggerTruncatedMessage, decodeBytes(&words(.{ 33, 0xffffffff, 0 })));
    try std.testing.expectError(error.RedotDebuggerTruncatedMessage, decodeBytes(&words(.{ 34, 0xffffffff, 0 })));
    try std.testing.expectError(error.RedotDebuggerTruncatedMessage, decodeBytes(&words(.{ 22, 0xffffffff, 0xffffffff, 1 })));
    try std.testing.expectError(error.RedotDebuggerUnsupportedVariant, decodeBytes(&words(.{200})));
    try std.testing.expectError(error.RedotDebuggerTruncatedMessage, decodeBytes(&.{ 2, 0 }));
    // Arrays nested past the depth limit end in a refusal, not deep recursion.
    var nested: [(maximum_depth + 8) * 8]u8 = undefined;
    for (0..maximum_depth + 8) |i| nested[i * 8 ..][0..8].* = words(.{ 28, 1 });
    try std.testing.expectError(error.RedotDebuggerVariantLimit, decodeBytes(&nested));
    // A packed array longer than the kept head decodes, and keeps its count.
    var floats: [8 + 4 * 1000]u8 = @splat(0);
    floats[0..8].* = words(.{ 32, 1000 });
    try std.testing.expectEqual(@as(i64, 1000), (try decodeBytes(&floats)).integer);
}

test "adapter refuses bad frames and a wrong pid without spinning" {
    var adapter = Adapter{};
    defer adapter.deinit();
    adapter.state = .connected;
    // Not an [name, thread, data] envelope.
    try std.testing.expectError(error.RedotDebuggerMalformedMessage, adapter.handle(&words(.{0}), 100));
    var hello: std.ArrayList(u8) = .empty;
    defer hello.deinit(std.heap.page_allocator);
    try encodeArrayHeader(&hello, 3);
    try encodeString(&hello, "set_pid");
    try encodeInteger(&hello, 1);
    try encodeArrayHeader(&hello, 1);
    try encodeInteger(&hello, 101);
    try std.testing.expectError(error.RedotDebuggerPidMismatch, adapter.handle(hello.items, 100));
    try std.testing.expectEqual(State.connected, adapter.state);
    // A scene whose child counts nest past the limit, and a ragged one.
    adapter.state = .ready;
    var rows: [(maximum_depth + 1) * 6]Value = undefined;
    for (0..maximum_depth + 1) |i| rows[i * 6 ..][0..6].* = .{ .{ .integer = 1 }, .{ .string = "n" }, .{ .string = "Node" }, .{ .integer = 1 }, .{ .string = "" }, .{ .integer = 0 } };
    try std.testing.expectError(error.RedotDebuggerMalformedScene, adapter.receiveScene(&rows));
    try std.testing.expectError(error.RedotDebuggerSceneLimit, adapter.receiveScene(rows[0..5]));
    try std.testing.expectEqual(@as(usize, 0), adapter.nodes.len);
}

test "property previews are capped" {
    const a = std.testing.allocator;
    const huge = [_]Value{.{ .float = 1.7e308 }} ** 8;
    const level = [_]Value{.{ .array = &huge }} ** 8;
    const text = try displayValue(a, .{ .array = &level }, 0);
    defer a.free(text);
    try std.testing.expect(text.len <= maximum_display + 3 and std.unicode.utf8ValidateSlice(text));
}
