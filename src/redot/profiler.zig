//! Bounded engine timing history. Frame numbers, not socket receive times,
//! join engine timings to explicitly captured native/script stop samples.
const std = @import("std");
const Value = @import("protocol.zig").Value;
const a = std.heap.page_allocator;
pub const frame_limit = 256;
pub const sample_limit = 128;
/// Progress reported by the explicit sampling client, not inferred from frames.
pub const Capture = struct {
    pub const Phase = enum { idle, sampling, ready, failed };
    phase: Phase = .idle,
    completed: u32 = 0,
    total: u32 = 0,
    message: [512]u8 = @splat(0),
    message_len: usize = 0,

    pub fn diagnostic(self: *const Capture) []const u8 {
        return self.message[0..self.message_len];
    }
    pub fn set(self: *Capture, phase: Phase, completed: u32, total: u32, message: []const u8) void {
        self.* = .{ .phase = phase, .completed = completed, .total = total };
        var n = @min(message.len, self.message.len);
        while (n < message.len and n > 0 and message[n] & 0xc0 == 0x80) n -= 1;
        @memcpy(self.message[0..n], message[0..n]);
        self.message_len = n;
    }
};
pub const Function = struct { signature: []const u8, calls: u64, self_ms: f64, total_ms: f64, internal_ms: f64 };
pub const Server = struct { server: []const u8, function: []const u8, ms: f64 };
pub const Frame = struct {
    number: u64,
    frame_ms: f64,
    process_ms: f64,
    physics_ms: f64,
    physics_step_ms: f64,
    script_ms: f64,
    functions: []const Function,
    servers: []const Server,
};
pub const Native = struct { index: usize, pc: []const u8, symbol: ?[]const u8, display: ?[]const u8 };
pub const Script = struct { name: []const u8, file: ?[]const u8, line: ?u32, owner_id: ?[]const u8, native_frame: ?usize, reason: ?[]const u8 };
pub const Sample = struct {
    frame_number: u64,
    physics_frame: u64,
    in_physics: bool,
    generation: u64,
    tid: i32,
    captured_ns: u64,
    inspection_ns: u64,
    native: []const Native,
    script: []const Script,
    source: []const u8 = "stopped_memory_dwarf",
};
pub fn Owned(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(a),
        data: T = undefined,
        pub fn create() !*@This() {
            const out = try a.create(@This());
            out.* = .{};
            return out;
        }
        pub fn destroy(self: *@This()) void {
            self.arena.deinit();
            a.destroy(self);
        }
    };
}
pub const State = struct {
    capture: Capture = .{},
    enabled: bool = false,
    revision: u64 = 0,
    signatures: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    frames: [frame_limit]?*Owned(Frame) = @splat(null),
    count: usize = 0,
    next: usize = 0,
    dropped: u64 = 0,
    samples: [sample_limit]?*Owned(Sample) = @splat(null),
    sample_count: usize = 0,
    sample_next: usize = 0,
    pub fn deinit(self: *State) void {
        for (self.frames) |frame| if (frame) |f| f.destroy();
        for (self.samples) |sample| if (sample) |s| s.destroy();
        var it = self.signatures.valueIterator();
        while (it.next()) |name| a.free(name.*);
        self.signatures.deinit(a);
        self.* = .{};
    }
    pub fn at(self: *const State, index: usize) *const Frame {
        return &self.frames[(self.next + frame_limit - self.count + index) % frame_limit].?.data;
    }
    pub fn find(self: *const State, number: u64) ?*const Frame {
        for (0..self.count) |i| if (self.at(i).number == number) return self.at(i);
        return null;
    }
    pub fn sampleAt(self: *const State, index: usize) *const Sample {
        return &self.samples[(self.sample_next + sample_limit - self.sample_count + index) % sample_limit].?.data;
    }
    pub fn addSample(self: *State, sample: *Owned(Sample)) void {
        if (self.samples[self.sample_next]) |old| old.destroy();
        self.samples[self.sample_next] = sample;
        self.sample_next = (self.sample_next + 1) % sample_limit;
        self.sample_count = @min(sample_limit, self.sample_count + 1);
        self.revision +%= 1;
    }
    pub fn signature(self: *State, data: []const Value) !void {
        if (data.len != 2 or data[0] != .string) return error.RedotProfilerMalformed;
        const id = try integer(data[1]);
        if (!self.signatures.contains(id) and self.signatures.count() >= 4096) return error.RedotProfilerSignatureLimit;
        const name = try a.dupe(u8, data[0].string[0..@min(data[0].string.len, 2048)]);
        errdefer a.free(name);
        if (try self.signatures.fetchPut(a, id, name)) |old| a.free(old.value);
    }
    pub fn receive(self: *State, data: []const Value) !void {
        if (!self.enabled) return;
        if (data.len < 8) return error.RedotProfilerMalformed;
        const owned = try Owned(Frame).create();
        errdefer owned.destroy();
        const mem = owned.arena.allocator();
        owned.data = .{ .number = try integer(data[0]), .frame_ms = try milliseconds(data[1]), .process_ms = try milliseconds(data[2]), .physics_ms = try milliseconds(data[3]), .physics_step_ms = try milliseconds(data[4]), .script_ms = try milliseconds(data[5]), .functions = &.{}, .servers = &.{} };
        var servers: std.ArrayList(Server) = .empty;
        const n = try integer(data[6]);
        if (n > 256) return error.RedotProfilerMalformed;
        var index: usize = 7;
        for (0..@intCast(n)) |_| {
            if (data.len - index < 2 or data[index] != .string) return error.RedotProfilerMalformed;
            const name = data[index].string;
            const fields = try integer(data[index + 1]);
            index += 2;
            if (fields % 2 != 0 or fields > data.len - index or fields / 2 + servers.items.len > 1024) return error.RedotProfilerMalformed;
            for (0..@intCast(fields / 2)) |_| {
                if (data[index] != .string) return error.RedotProfilerMalformed;
                try servers.append(mem, .{ .server = try mem.dupe(u8, name[0..@min(name.len, 256)]), .function = try mem.dupe(u8, data[index].string[0..@min(data[index].string.len, 256)]), .ms = try milliseconds(data[index + 1]) });
                index += 2;
            }
        }
        if (index == data.len) return error.RedotProfilerMalformed;
        const fields = try integer(data[index]);
        index += 1;
        if (fields % 5 != 0 or fields != data.len - index or fields / 5 > 256) return error.RedotProfilerMalformed;
        const functions = try mem.alloc(Function, @intCast(fields / 5));
        for (functions) |*f| {
            const id = try integer(data[index]);
            f.* = .{ .signature = try mem.dupe(u8, self.signatures.get(id) orelse "<signature unavailable>"), .calls = try integer(data[index + 1]), .self_ms = try milliseconds(data[index + 2]), .total_ms = try milliseconds(data[index + 3]), .internal_ms = try milliseconds(data[index + 4]) };
            index += 5;
        }
        owned.data.functions = functions;
        owned.data.servers = try servers.toOwnedSlice(mem);
        if (self.frames[self.next]) |old| {
            old.destroy();
            self.dropped +%= 1;
        }
        self.frames[self.next] = owned;
        self.next = (self.next + 1) % frame_limit;
        self.count = @min(frame_limit, self.count + 1);
        self.revision +%= 1;
    }
};
fn integer(value: Value) !u64 {
    if (value != .integer or value.integer < 0) return error.RedotProfilerMalformed;
    return @intCast(value.integer);
}
fn milliseconds(value: Value) !f64 {
    const v: f64 = switch (value) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        else => return error.RedotProfilerMalformed,
    };
    if (!std.math.isFinite(v) or v < 0 or v > 1e9) return error.RedotProfilerMalformed;
    return v * 1000;
}
pub fn scriptPath(signature_: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, signature_, "::") orelse return null;
    return signature_[0..end];
}

test "capture progress and bounded startup diagnostic" {
    var capture = Capture{};
    capture.set(.sampling, 3, 12, "");
    try std.testing.expectEqual(Capture.Phase.sampling, capture.phase);
    try std.testing.expectEqual(@as(u32, 3), capture.completed);
    try std.testing.expectEqual(@as(u32, 12), capture.total);
    const message = "x" ** 511 ++ "\u{e9}";
    capture.set(.failed, 3, 12, message);
    try std.testing.expectEqual(@as(usize, 511), capture.diagnostic().len);
    capture.set(.ready, 12, 12, "");
    try std.testing.expectEqualStrings("", capture.diagnostic());
}

test "engine frame times keep units signatures and bounded history" {
    var state = State{ .enabled = true };
    defer state.deinit();
    try state.signature(&.{ .{ .string = "res://slow.gd::10::burn" }, .{ .integer = 4 } });
    var frame = [_]Value{ .{ .integer = 9 }, .{ .float = 0.025 }, .{ .float = 0.020 }, .{ .float = 0.003 }, .{ .float = 1.0 / 60.0 }, .{ .float = 0.019 }, .{ .integer = 1 }, .{ .string = "physics" }, .{ .integer = 2 }, .{ .string = "step" }, .{ .float = 0.003 }, .{ .integer = 5 }, .{ .integer = 4 }, .{ .integer = 2 }, .{ .float = 0.012 }, .{ .float = 0.019 }, .{ .float = 0.007 } };
    try state.receive(&frame);
    const parsed = state.at(0);
    try std.testing.expectEqual(@as(u64, 9), parsed.number);
    try std.testing.expectApproxEqAbs(@as(f64, 25), parsed.frame_ms, 0.00001);
    try std.testing.expectEqualStrings("res://slow.gd::10::burn", parsed.functions[0].signature);
    try std.testing.expectEqual(@as(u64, 2), parsed.functions[0].calls);
    try std.testing.expectApproxEqAbs(@as(f64, 3), parsed.servers[0].ms, 0.00001);
    // A deliberately wrong unit conversion must not pass this oracle.
    try std.testing.expect(parsed.frame_ms != 0.025);
    for (0..frame_limit) |i| {
        frame[0] = .{ .integer = @intCast(10 + i) };
        try state.receive(&frame);
    }
    try std.testing.expectEqual(@as(usize, frame_limit), state.count);
    try std.testing.expect(state.find(9) == null);
    try std.testing.expectEqual(@as(u64, 1), state.dropped);
    state.enabled = false;
    try state.receive(&frame);
    try std.testing.expectEqual(@as(u64, 1), state.dropped);
}

test "malformed profile frames are refused" {
    var state = State{ .enabled = true };
    defer state.deinit();
    const head = [_]Value{ .{ .integer = 1 }, .{ .float = 0 }, .{ .float = 0 }, .{ .float = 0 }, .{ .float = 0 }, .{ .float = 0 } };
    // Short frame; server count past the data; odd and overlong server fields;
    // function fields not a multiple of five or not the rest of the frame.
    const tails = [_][]const Value{
        &.{.{ .integer = 0 }},
        &.{ .{ .integer = 0 }, .{ .integer = -5 } },
        &.{ .{ .integer = 200 }, .{ .integer = 0 } },
        &.{ .{ .integer = 1 }, .{ .string = "s" }, .{ .integer = 3 }, .{ .integer = 0 } },
        &.{ .{ .integer = 1 }, .{ .string = "s" }, .{ .integer = 1 << 40 }, .{ .integer = 0 } },
        &.{ .{ .integer = 1 }, .{ .string = "s" }, .{ .integer = 2 }, .{ .string = "f" }, .{ .float = 0 } },
        &.{ .{ .integer = 0 }, .{ .integer = 4 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 0 } },
        &.{ .{ .integer = 0 }, .{ .integer = 10 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .float = 0 }, .{ .float = 0 }, .{ .float = 0 } },
        &.{ .{ .integer = 0 }, .{ .integer = 5 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .float = std.math.inf(f64) }, .{ .float = 0 }, .{ .float = 0 } },
    };
    for (tails) |tail| {
        var data: [16]Value = undefined;
        @memcpy(data[0..head.len], &head);
        @memcpy(data[head.len..][0..tail.len], tail);
        try std.testing.expectError(error.RedotProfilerMalformed, state.receive(data[0 .. head.len + tail.len]));
    }
    try std.testing.expectEqual(@as(usize, 0), state.count);
    try std.testing.expectError(error.RedotProfilerMalformed, state.signature(&.{ .{ .string = "x" }, .{ .integer = -1 } }));
}
