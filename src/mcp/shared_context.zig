const std = @import("std");
const Session = @import("../model/session.zig").Session;
const linux = @import("../target/linux.zig");
pub const c = @import("../service/lease.zig").c;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
pub const definitions = @embedFile("session_tools.json");

pub fn check(result: c.enum_xsvc_result) !void {
    switch (result) {
        c.XSVC_OK => {},
        c.XSVC_BAD_REQUEST => return error.InvalidArguments,
        c.XSVC_NO_CLIENT => return error.UnknownSessionClient,
        c.XSVC_SCOPE_DENIED => return error.ScopeDenied,
        c.XSVC_CONTROLLER_BUSY => return error.ControllerBusy,
        c.XSVC_CONTROL_REQUIRED => return error.ControlLeaseRequired,
        c.XSVC_LIMIT => return error.SessionLimit,
        else => return error.SessionServiceFailed,
    }
}
pub const Access = enum { observer, controller, mutator, lease };
/// Target read-only hints do not describe ownership of retained host jobs.
/// Missing or invalid classifications fail closed instead of inferring from names.
pub fn access(definition: Value) !Access {
    if (definition != .object) return error.MissingToolSessionAccess;
    const annotations = definition.object.get("annotations") orelse return error.MissingToolSessionAccess;
    if (annotations != .object) return error.InvalidToolSessionAccess;
    const value = annotations.object.get("xodbSessionAccess") orelse return error.MissingToolSessionAccess;
    if (value != .string) return error.InvalidToolSessionAccess;
    const required = std.meta.stringToEnum(Access, value.string) orelse return error.InvalidToolSessionAccess;
    if (!try readOnly(definition) and required == .observer) return error.InvalidToolSessionAccess;
    return required;
}
pub fn readOnly(definition: Value) !bool {
    if (definition != .object) return error.InvalidToolSessionAccess;
    const annotations = definition.object.get("annotations") orelse return error.InvalidToolSessionAccess;
    if (annotations != .object) return error.InvalidToolSessionAccess;
    const value = annotations.object.get("readOnlyHint") orelse return error.InvalidToolSessionAccess;
    if (value != .bool) return error.InvalidToolSessionAccess;
    return value.bool;
}
pub const Policy = struct {
    required: Access,
    read_only: bool,
    pub fn fromDefinition(definition: Value) !Policy {
        return .{ .required = try access(definition), .read_only = try readOnly(definition) };
    }
    pub fn localAllowed(self: Policy, scope: @import("../model/session.zig").AgentScope) bool {
        // Read-only retained jobs are private to a stdio session. Shared clients
        // additionally obey xodbSessionAccess ownership even for read-only tools.
        if (self.read_only) return true;
        return switch (self.required) {
            .controller => scope != .observe,
            .mutator => scope == .mutate,
            .observer, .lease => false,
        };
    }
};
pub fn localAllowed(scope: @import("../model/session.zig").AgentScope, definition: Value) !bool {
    return (try Policy.fromDefinition(definition)).localAllowed(scope);
}

fn number(args: Value, key: []const u8, default: ?u64) !u64 {
    const value = args.object.get(key) orelse return default orelse error.InvalidArguments;
    if (value != .integer or value.integer < 0) return error.InvalidArguments;
    return @intCast(value.integer);
}
fn asValue(a: Allocator, value: anytype) !Value {
    return (try std.json.parseFromSlice(Value, a, try std.json.Stringify.valueAlloc(a, value, .{}), .{ .allocate = .alloc_always })).value;
}
pub fn handles(name: []const u8) bool {
    inline for (.{ "get_session_clients", "claim_session_control", "release_session_control", "get_session_events" }) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}
pub const Context = struct {
    service: *c.struct_xsvc,
    client_id: u64,
    pub fn state(self: Context) !c.struct_xsvc_state {
        var result: c.struct_xsvc_state = undefined;
        try check(c.xsvc_state(self.service, &result));
        return result;
    }
    pub fn tick(self: Context, root: *Session) !void {
        try check(c.xsvc_tick(self.service, linux.now(), @intFromEnum(root.agent_scope)));
    }
    pub fn authorize(self: Context, mutate: bool) !void {
        // The C service is authoritative for both lease ownership and scope.
        const result = c.xsvc_authorize(self.service, self.client_id, if (mutate) c.XSVC_MUTATE else c.XSVC_CONTROL, linux.now());
        if (result == c.XSVC_SCOPE_DENIED) return error.AgentScopeDenied;
        try check(result);
    }
    pub fn visible(self: Context, required: Access) !bool {
        if (required == .observer or required == .lease) return true;
        const s = try self.state();
        return s.controller == self.client_id and s.scope >= c.XSVC_CONTROL and
            (required != .mutator or s.scope == c.XSVC_MUTATE);
    }
    fn clients(self: Context, a: Allocator) !Value {
        const s = try self.state();
        var peers: [c.XSVC_MAX_PEERS]c.struct_xsvc_peer = undefined;
        var ids: [c.XSVC_MAX_PEERS]struct { id: u64 } = undefined;
        const count = c.xsvc_peers(self.service, &peers, peers.len);
        for (peers[0..count], 0..) |peer, i| ids[i] = .{ .id = peer.id };
        return asValue(a, .{ .client_id = self.client_id, .controller_id = if (s.controller == 0) @as(?u64, null) else s.controller, .lease_remaining_ms = (s.expires_ns -| linux.now()) / 1_000_000, .scope = @tagName(@as(@import("../model/session.zig").AgentScope, @enumFromInt(s.scope))), .clients = ids[0..count], .accept_error_count = s.accept_error_count, .last_accept_errno = s.last_accept_errno, .event_sequence = s.latest_sequence, .oldest_event_sequence = s.oldest_sequence });
    }
    pub fn call(self: Context, a: Allocator, root: *Session, name: []const u8, args: Value) !Value {
        try self.tick(root);
        var fields = args.object.iterator();
        while (fields.next()) |field| {
            const key = field.key_ptr.*;
            const allowed = if (std.mem.eql(u8, name, "claim_session_control"))
                std.mem.eql(u8, key, "generation") or std.mem.eql(u8, key, "ttl_ms")
            else if (std.mem.eql(u8, name, "get_session_events"))
                std.mem.eql(u8, key, "after") or std.mem.eql(u8, key, "limit")
            else
                false;
            if (!allowed) return error.InvalidArguments;
        }
        if (std.mem.eql(u8, name, "claim_session_control")) {
            _ = try number(args, "generation", 0); // Legacy argument: claims change the lease, not the target.
            const ttl = try number(args, "ttl_ms", 30000);
            if (ttl < c.XSVC_MIN_TTL_MS or ttl > c.XSVC_MAX_TTL_MS) return error.InvalidArguments;
            try check(c.xsvc_claim(self.service, self.client_id, @intCast(ttl), linux.now()));
        } else if (std.mem.eql(u8, name, "release_session_control")) {
            try check(c.xsvc_release(self.service, self.client_id, linux.now()));
        } else if (std.mem.eql(u8, name, "get_session_events")) {
            const after = try number(args, "after", 0);
            const limit = try number(args, "limit", 32);
            if (limit == 0 or limit > c.XSVC_EVENT_CAPACITY) return error.InvalidArguments;
            var rows: [c.XSVC_EVENT_CAPACITY]c.struct_xsvc_event = undefined;
            var count: usize = 0;
            var gap: bool = false;
            try check(c.xsvc_events(self.service, after, &rows, @intCast(limit), &count, &gap));
            const Event = struct { sequence: u64, time_ns: u64, client_id: u64, kind: []const u8 };
            var events: [c.XSVC_EVENT_CAPACITY]Event = undefined;
            for (rows[0..count], 0..) |row, i| events[i] = .{ .sequence = row.sequence, .time_ns = row.time_ns, .client_id = row.client_id, .kind = switch (row.kind) {
                c.XSVC_CONNECTED => "connected",
                c.XSVC_DISCONNECTED => "disconnected",
                c.XSVC_ACQUIRED => "acquired",
                c.XSVC_RELEASED => "released",
                c.XSVC_EXPIRED => "expired",
                c.XSVC_SCOPE_CHANGED => "scope_changed",
                c.XSVC_REVOKED => "revoked",
                else => return error.SessionServiceFailed,
            } };
            const s = try self.state();
            return asValue(a, .{ .events = events[0..count], .gap = gap, .oldest_available = s.oldest_sequence, .latest_sequence = s.latest_sequence, .next = if (count > 0) rows[count - 1].sequence else after });
        } else if (!std.mem.eql(u8, name, "get_session_clients")) return error.UnknownTool;
        return self.clients(a);
    }
};

test "session access classification is mandatory and independent of readOnlyHint" {
    const a = std.testing.allocator;
    const missing = try std.json.parseFromSlice(Value, a, "{\"annotations\":{\"readOnlyHint\":true}}", .{});
    defer missing.deinit();
    try std.testing.expectError(error.MissingToolSessionAccess, access(missing.value));
    const invalid = try std.json.parseFromSlice(Value, a, "{\"annotations\":{\"xodbSessionAccess\":\"guess\"}}", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidToolSessionAccess, access(invalid.value));
    const job = try std.json.parseFromSlice(Value, a, "{\"annotations\":{\"readOnlyHint\":true,\"xodbSessionAccess\":\"controller\"}}", .{});
    defer job.deinit();
    try std.testing.expectEqual(Access.controller, try access(job.value));
}

test "local scope comes from policy and invalid state-changing observers fail closed" {
    const a = std.testing.allocator;
    const Scope = @import("../model/session.zig").AgentScope;
    inline for (.{ "controller", "mutator" }) |required| {
        const parsed = try std.json.parseFromSlice(Value, a, "{\"name\":\"arbitrary_name\",\"annotations\":{\"readOnlyHint\":false,\"xodbSessionAccess\":\"" ++ required ++ "\"}}", .{});
        defer parsed.deinit();
        try std.testing.expect(!try localAllowed(.observe, parsed.value));
        try std.testing.expectEqual(std.mem.eql(u8, required, "controller"), try localAllowed(.control, parsed.value));
        try std.testing.expect(try localAllowed(.mutate, parsed.value));
    }
    const retained = try std.json.parseFromSlice(Value, a, "{\"annotations\":{\"readOnlyHint\":true,\"xodbSessionAccess\":\"controller\"}}", .{});
    defer retained.deinit();
    for (std.enums.values(Scope)) |scope| try std.testing.expect(try localAllowed(scope, retained.value));
    try std.testing.expectEqual(Access.controller, try access(retained.value));
    inline for (.{
        "{\"annotations\":{\"readOnlyHint\":false,\"xodbSessionAccess\":\"observer\"}}",
        "{\"annotations\":{\"xodbSessionAccess\":\"controller\"}}",
        "{\"annotations\":{\"readOnlyHint\":\"false\",\"xodbSessionAccess\":\"controller\"}}",
    }) |text| {
        const invalid = try std.json.parseFromSlice(Value, a, text, .{});
        defer invalid.deinit();
        try std.testing.expectError(error.InvalidToolSessionAccess, access(invalid.value));
        try std.testing.expectError(error.InvalidToolSessionAccess, localAllowed(.mutate, invalid.value));
    }
}
