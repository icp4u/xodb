//! Bounded syscall evidence. One ordered kernel ring per selected task.
//! Elapsed time includes descheduling and debugger stops. Arguments are discarded.
const std = @import("std");
pub const max_threads = 32;
pub const default_limit = 16384;
pub const max_limit = 65536;
pub const sample_type: u64 = (1 << 1) | (1 << 2) | (1 << 6) | (1 << 10);
pub const Reason = enum(u8) { complete, missing_entry, missing_exit, nested_entry, number_mismatch, time_reversed, loss, throttle, thread_exit, exec, truncated, decode_error };
pub const ReturnClass = enum { value, errno, restart_internal };
pub fn returnClass(value: i64) ReturnClass {
    if (value == -512 or value == -513 or value == -514 or value == -516) return .restart_internal;
    return if (value >= -4095 and value <= -1) .errno else .value;
}
pub fn name(nr: i64) ?[]const u8 {
    if (nr < 0) return null;
    const n = std.enums.fromInt(std.os.linux.syscalls.X64, @as(u64, @intCast(nr))) orelse return null;
    return @tagName(n);
}
pub const Span = struct {
    thread_index: u16,
    nr: i64,
    exit_nr: ?i64 = null,
    entry_ns: ?u64 = null,
    exit_ns: ?u64 = null,
    result: ?i64 = null,
    reason: Reason,
    pub fn elapsed(self: Span) ?u64 {
        return if (self.reason == .complete) self.exit_ns.? - self.entry_ns.? else null;
    }
    pub fn overlaps(self: Span, from: u64, to: u64) bool {
        const lo = self.entry_ns orelse self.exit_ns orelse return false;
        const hi = self.exit_ns orelse lo;
        return lo < to and hi >= from;
    }
};
const Pending = struct { nr: i64, time: u64 };
pub const Lane = struct {
    pending: ?Pending = null,
    last_ns: u64 = 0,
    closed: bool = false,
};
pub const Store = struct {
    items: std.ArrayList(Span) = .empty,
    lanes: [max_threads]Lane = @splat(.{}),
    limit: u32 = default_limit,
    enabled: bool = false,
    finished: bool = false,
    unread_possible: bool = false,
    lost: u64 = 0,
    throttles: u64 = 0,
    discarded: u64 = 0,
    invalid: u64 = 0,
    extent_ns: u64 = 0,
    pub fn deinit(self: *Store, a: std.mem.Allocator) void {
        self.items.deinit(a);
    }
    fn emit(self: *Store, a: std.mem.Allocator, span: Span) !void {
        if (self.items.items.len >= self.limit) {
            self.discarded +|= 1;
            return error.SyscallLimit;
        }
        if (self.items.items.len == self.items.capacity)
            try self.items.ensureTotalCapacityPrecise(a, @min(self.limit, @max(64, self.items.capacity * 2)));
        self.items.appendAssumeCapacity(span);
    }
    pub fn boundary(self: *Store, a: std.mem.Allocator, index: usize, reason: Reason) !void {
        const pending = self.lanes[index].pending;
        self.lanes[index].pending = null;
        if (reason == .thread_exit or reason == .exec) self.lanes[index].closed = true;
        if (pending) |p| try self.emit(a, .{ .thread_index = @intCast(index), .nr = p.nr, .entry_ns = p.time, .reason = reason });
    }
    pub fn feed(self: *Store, a: std.mem.Allocator, index: usize, event: Event) !void {
        if (index >= max_threads or self.finished or self.lanes[index].closed) {
            self.invalid +|= 1;
            return error.InvalidSyscallIdentity;
        }
        const lane = &self.lanes[index];
        switch (event) {
            .lost => |count| {
                self.lost +|= count;
                try self.boundary(a, index, .loss);
            },
            .throttle => {
                self.throttles +|= 1;
                try self.boundary(a, index, .throttle);
            },
            .unthrottle => try self.boundary(a, index, .throttle),
            .thread_exit => try self.boundary(a, index, .thread_exit),
            .exec => try self.boundary(a, index, .exec),
            .call => |call| {
                if (call.time < lane.last_ns) {
                    self.invalid +|= 1;
                    try self.boundary(a, index, .time_reversed);
                    return error.SyscallTimeReversed;
                }
                lane.last_ns = call.time;
                self.extent_ns = @max(self.extent_ns, call.time);
                if (call.enter) {
                    try self.boundary(a, index, .nested_entry);
                    lane.pending = .{ .nr = call.nr, .time = call.time };
                } else {
                    const p = lane.pending;
                    lane.pending = null;
                    try self.emit(a, .{ .thread_index = @intCast(index), .nr = if (p) |v| v.nr else call.nr, .exit_nr = call.nr, .entry_ns = if (p) |v| v.time else null, .exit_ns = call.time, .result = call.result, .reason = if (p) |v| (if (v.nr == call.nr) Reason.complete else Reason.number_mismatch) else Reason.missing_entry });
                }
            },
        }
    }
    pub fn finish(self: *Store, a: std.mem.Allocator, reason: Reason) !void {
        self.finished = true;
        var failure: ?anyerror = null;
        for (0..max_threads) |i| self.boundary(a, i, reason) catch |err| {
            failure = err;
        };
        if (failure) |err| return err;
    }
};
pub const Event = union(enum) {
    call: struct { enter: bool, nr: i64, result: ?i64, time: u64 },
    lost: u64,
    throttle,
    unthrottle,
    thread_exit,
    exec,
};
pub const Identity = struct { pid: i32, tid: i32, enter_id: u64, exit_id: u64, enter_type: u16, exit_type: u16 };
fn num(comptime T: type, data: []const u8, offset: usize) !T {
    if (offset > data.len or @sizeOf(T) > data.len - offset) return error.SyscallRecordTruncated;
    return std.mem.readInt(T, data[offset..][0..@sizeOf(T)], .little);
}
fn checkId(id: u64, who: Identity) !void {
    if (id != who.enter_id and id != who.exit_id) return error.SyscallEventId;
}
fn checkTask(bytes: []const u8, offset: usize, who: Identity) !void {
    if (try num(u32, bytes, offset) != @as(u32, @intCast(who.pid)) or
        try num(u32, bytes, offset + 4) != @as(u32, @intCast(who.tid))) return error.SyscallTaskIdentity;
}
/// PERF_SAMPLE_TID|TIME|ID|RAW; sample_id_all trailers have TID|TIME|ID.
/// Fields and byte order are accepted only after validateFormat on x86-64.
pub fn decode(bytes: []const u8, who: Identity) !?Event {
    if (bytes.len != try num(u16, bytes, 6) or bytes.len % 8 != 0) return error.SyscallRecordSize;
    const typ = try num(u32, bytes, 0);
    if (typ == 9) {
        try checkTask(bytes, 8, who);
        const time = try num(u64, bytes, 16);
        const id = try num(u64, bytes, 24);
        try checkId(id, who);
        const enter = id == who.enter_id;
        const raw_size = try num(u32, bytes, 32);
        const need: usize = if (enter) 64 else 24;
        if (raw_size < need or bytes.len < 36 or raw_size > bytes.len - 36 or bytes.len - 36 - raw_size >= 8) return error.SyscallPayloadSize;
        const raw = bytes[36..][0..raw_size];
        if (try num(u16, raw, 0) != (if (enter) who.enter_type else who.exit_type) or try num(i32, raw, 4) != who.tid) return error.SyscallRawIdentity;
        const nr = try num(i64, raw, 8);
        // -1 is meaningful for a syscall suppressed by ptrace; preserve it.
        return .{ .call = .{ .enter = enter, .nr = nr, .time = time, .result = if (enter) null else try num(i64, raw, 16) } };
    }
    if (bytes.len < 32) return error.SyscallRecordTruncated;
    const tail = bytes.len - 24;
    try checkTask(bytes, tail, who);
    try checkId(try num(u64, bytes, tail + 16), who);
    switch (typ) {
        2 => { // LOST: fixed body plus the sample-id trailer.
            if (tail != 24) return error.SyscallRecordSize;
            try checkId(try num(u64, bytes, 8), who);
            return .{ .lost = try num(u64, bytes, 16) };
        },
        5, 6 => {
            if (tail != 32) return error.SyscallRecordSize;
            try checkId(try num(u64, bytes, 16), who);
            return if (typ == 5) .throttle else .unthrottle;
        },
        4 => {
            if (tail != 32 or try num(i32, bytes, 8) != who.pid or try num(i32, bytes, 16) != who.tid) return error.SyscallTaskIdentity;
            return .thread_exit;
        },
        3 => { // COMM_EXEC closes the identity; ordinary renames are irrelevant.
            try checkTask(bytes, 8, who);
            if (tail < 24 or std.mem.indexOfScalar(u8, bytes[16..tail], 0) == null) return error.SyscallRecordSize;
            return if ((try num(u16, bytes, 4) & (1 << 13)) != 0) .exec else null;
        },
        7 => { // Parent reports creation; the capture owner handles scope changes.
            if (tail != 32) return error.SyscallRecordSize;
            return null;
        },
        else => return error.SyscallUnknownRecord,
    }
}
fn parseValue(line: []const u8, key: []const u8) !u32 {
    const start = (std.mem.indexOf(u8, line, key) orelse return error.SyscallFormat) + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, ';') orelse line.len;
    return std.fmt.parseInt(u32, std.mem.trim(u8, line[start..end], " \t\r\n"), 10) catch error.SyscallFormat;
}
/// Refuse unknown/duplicate fields, ID disagreement and widths/signedness changes.
pub fn validateFormat(text: []const u8, id: u32, enter: bool) !void {
    if (id == 0 or id > std.math.maxInt(u16)) return error.SyscallFormat;
    const fields = [_][]const u8{ "unsigned short common_type", "unsigned char common_flags", "unsigned char common_preempt_count", "int common_pid", "long id", if (enter) "unsigned long args[6]" else "long ret" };
    const offsets = [_]u32{ 0, 2, 3, 4, 8, 16 };
    const sizes = [_]u32{ 2, 1, 1, 4, 8, if (enter) 48 else 8 };
    const signed = [_]u32{ 0, 0, 0, 1, 1, if (enter) 0 else 1 };
    var seen: [6]bool = @splat(false);
    var seen_id = false;
    var seen_name = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "name:")) {
            if (seen_name or !std.mem.eql(u8, std.mem.trim(u8, line[5..], " \t"), if (enter) "sys_enter" else "sys_exit")) return error.SyscallFormat;
            seen_name = true;
        } else if (std.mem.startsWith(u8, line, "ID:")) {
            if (seen_id or try parseValue(line, "ID:") != id) return error.SyscallFormat;
            seen_id = true;
        } else if (std.mem.startsWith(u8, line, "field:")) {
            const end = std.mem.indexOfScalar(u8, line, ';') orelse return error.SyscallFormat;
            const field = std.mem.trim(u8, line[6..end], " \t");
            for (fields, 0..) |expected, i| {
                if (!std.mem.eql(u8, field, expected)) continue;
                if (seen[i] or try parseValue(line, "offset:") != offsets[i] or try parseValue(line, "size:") != sizes[i] or try parseValue(line, "signed:") != signed[i]) return error.SyscallFormat;
                seen[i] = true;
                break;
            } else return error.SyscallFormat;
        }
    }
    if (!seen_id or !seen_name) return error.SyscallFormat;
    for (seen) |yes| if (!yes) return error.SyscallFormat;
}

test "syscall missing boundaries, loss, reuse protection and storage limits" {
    const a = std.testing.allocator;
    var store = Store{ .enabled = true, .limit = 5 };
    defer store.deinit(a);
    try store.feed(a, 0, .{ .call = .{ .enter = false, .nr = 0, .time = 10, .result = 1 } });
    try store.feed(a, 0, .{ .call = .{ .enter = true, .nr = 0, .time = 20, .result = null } });
    try store.feed(a, 0, .{ .lost = 7 });
    try store.feed(a, 0, .{ .call = .{ .enter = false, .nr = 0, .time = 30, .result = -512 } });
    try store.feed(a, 0, .{ .call = .{ .enter = true, .nr = 0, .time = 40, .result = null } });
    try store.feed(a, 0, .{ .call = .{ .enter = false, .nr = 0, .time = 90, .result = 1 } });
    try store.feed(a, 0, .{ .call = .{ .enter = true, .nr = 231, .time = 100, .result = null } });
    try store.feed(a, 0, .thread_exit);
    try std.testing.expectError(error.InvalidSyscallIdentity, store.feed(a, 0, .{ .call = .{ .enter = true, .nr = 0, .time = 110, .result = null } }));
    try std.testing.expectEqual(7, store.lost);
    try std.testing.expectEqual(Reason.missing_entry, store.items.items[0].reason);
    try std.testing.expectEqual(Reason.loss, store.items.items[1].reason);
    try std.testing.expectEqual(ReturnClass.restart_internal, returnClass(store.items.items[2].result.?));
    try std.testing.expectEqual(50, store.items.items[3].elapsed().?);
    try std.testing.expectEqual(Reason.thread_exit, store.items.items[4].reason);
    try std.testing.expect(store.items.items[4].elapsed() == null);
    try std.testing.expectError(error.SyscallLimit, store.feed(a, 1, .{ .call = .{ .enter = false, .nr = 0, .time = 110, .result = 1 } }));
    try std.testing.expectEqual(1, store.discarded);
    try std.testing.expectEqualStrings("read", name(0).?);
    try std.testing.expect(name(0x40000000) == null);
}

test "syscall decoder rejects foreign identities and malformed records" {
    const who = Identity{ .pid = 10, .tid = 11, .enter_id = 100, .exit_id = 101, .enter_type = 200, .exit_type = 201 };
    var record: [104]u8 = @splat(0);
    std.mem.writeInt(u32, record[0..4], 9, .little);
    std.mem.writeInt(u16, record[6..8], record.len, .little);
    std.mem.writeInt(u32, record[8..12], 10, .little);
    std.mem.writeInt(u32, record[12..16], 11, .little);
    std.mem.writeInt(u64, record[16..24], 123, .little);
    std.mem.writeInt(u64, record[24..32], 100, .little);
    std.mem.writeInt(u32, record[32..36], 64, .little);
    std.mem.writeInt(u16, record[36..38], 200, .little);
    std.mem.writeInt(i32, record[40..44], 11, .little);
    std.mem.writeInt(i64, record[44..52], 0, .little);
    const event = (try decode(&record, who)).?;
    try std.testing.expect(event.call.enter and event.call.time == 123 and event.call.nr == 0);
    std.mem.writeInt(u64, record[24..32], 999, .little);
    try std.testing.expectError(error.SyscallEventId, decode(&record, who));
    std.mem.writeInt(u64, record[24..32], 100, .little);
    std.mem.writeInt(i32, record[40..44], 12, .little);
    try std.testing.expectError(error.SyscallRawIdentity, decode(&record, who));
    std.mem.writeInt(i32, record[40..44], 11, .little);
    std.mem.writeInt(u32, record[32..36], 63, .little);
    try std.testing.expectError(error.SyscallPayloadSize, decode(&record, who));
    try std.testing.expectError(error.SyscallRecordSize, decode(record[0..100], who));
}

test "syscall pairing refuses reordering and labels mismatches" {
    var store = Store{};
    const a = std.testing.allocator;
    defer store.deinit(a);
    try store.feed(a, 0, .{ .call = .{ .enter = true, .nr = 1, .time = 20, .result = null } });
    try store.feed(a, 0, .{ .call = .{ .enter = false, .nr = 2, .time = 30, .result = 0 } });
    try std.testing.expectEqual(Reason.number_mismatch, store.items.items[0].reason);
    try std.testing.expect(store.items.items[0].elapsed() == null);
    try store.feed(a, 0, .{ .call = .{ .enter = true, .nr = 0, .time = 40, .result = null } });
    try std.testing.expectError(error.SyscallTimeReversed, store.feed(a, 0, .{ .call = .{ .enter = false, .nr = 0, .time = 39, .result = 1 } }));
    try std.testing.expectEqual(Reason.time_reversed, store.items.items[1].reason);
    try std.testing.expect(store.items.items[1].elapsed() == null);
}

test "syscall formats require complete exact field contracts" {
    const format =
        \\name: sys_exit
        \\ID: 201
        \\format:
        \\ field:unsigned short common_type; offset:0; size:2; signed:0;
        \\ field:unsigned char common_flags; offset:2; size:1; signed:0;
        \\ field:unsigned char common_preempt_count; offset:3; size:1; signed:0;
        \\ field:int common_pid; offset:4; size:4; signed:1;
        \\ field:long id; offset:8; size:8; signed:1;
        \\ field:long ret; offset:16; size:8; signed:1;
    ;
    try validateFormat(format, 201, false);
    try std.testing.expectError(error.SyscallFormat, validateFormat(format, 202, false));
    try std.testing.expectError(error.SyscallFormat, validateFormat(format, 201, true));
    const a = std.testing.allocator;
    inline for (.{ .{ "field:long ret", "field:unsigned long ret" }, .{ "offset:16", "offset:17" }, .{ "size:8", "size:4" }, .{ "signed:1", "signed:0" } }) |change| {
        const invalid = try std.mem.replaceOwned(u8, a, format, change[0], change[1]);
        defer a.free(invalid);
        try std.testing.expectError(error.SyscallFormat, validateFormat(invalid, 201, false));
    }
    try std.testing.expectError(error.SyscallFormat, validateFormat(format ++ "\nfield:long ret; offset:16; size:8; signed:1;", 201, false));
}
