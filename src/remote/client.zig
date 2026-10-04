//! One worker owns the transport and RPC stream. The GUI owns taken snapshots.
const std = @import("std");
const transport = @import("transport.zig");
const c = transport.c;
const wire = @import("view.zig");
const a = std.heap.page_allocator;
const Value = std.json.Value;
pub const Snapshot = std.json.Parsed(wire.View);
pub const Endpoint = union(enum) { tcp: []const u8, ssh: struct { host: []const u8, args: []const [:0]const u8 } };
pub const State = enum { connecting, ready, disconnected };
pub const Client = struct {
    endpoint: Endpoint,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    mutex: std.atomic.Mutex = .unlocked,
    state: State = .connecting,
    busy: bool = true,
    status: [256]u8 = @splat(0),
    pending: ?[]u8 = null,
    published: ?Snapshot = null,
    tid: i32 = 0,
    frame: usize = 0,
    selection: u64 = 0,
    fn lock(self: *Client) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn start(self: *Client) !void {
        self.thread = try unsupportedThread(.{}, run, .{self});
    }
    pub fn deinit(self: *Client) void {
        self.stop.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.published) |snapshot| snapshot.deinit();
        if (self.pending) |bytes| a.free(bytes);
    }
    pub fn take(self: *Client) ?Snapshot {
        self.lock();
        defer self.mutex.unlock();
        const result = self.published;
        self.published = null;
        return result;
    }
    pub fn facts(self: *Client) struct { state: State, busy: bool, status: [256]u8 } {
        self.lock();
        defer self.mutex.unlock();
        return .{ .state = self.state, .busy = self.busy or self.published != null, .status = self.status };
    }
    pub fn select(self: *Client, tid: i32, frame: usize) void {
        self.lock();
        defer self.mutex.unlock();
        self.tid = tid;
        self.frame = frame;
        self.selection +%= 1;
        self.busy = true;
    }
    pub fn action(self: *Client, name: []const u8, args: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(a, .{ .name = name, .arguments = args }, .{});
        errdefer a.free(bytes);
        self.lock();
        defer self.mutex.unlock();
        if (self.state != .ready) return error.RemoteDisconnected;
        if (self.busy or self.pending != null) return error.RemoteBusy;
        self.pending = bytes;
        self.busy = true;
        self.status = @splat(0);
    }
    fn message(self: *Client, text: []const u8) void {
        self.lock();
        defer self.mutex.unlock();
        self.status = @splat(0);
        @memcpy(self.status[0..@min(text.len, self.status.len - 1)], text[0..@min(text.len, self.status.len - 1)]);
    }
    fn run(self: *Client) void {
        self.work() catch |err| {
            if (err != error.Cancelled) {
                self.message(@errorName(err));
                @import("../m68k_log.zig").print("xodb: remote connection ended: {s}; target cleanup is unconfirmed\n", .{@errorName(err)});
            }
        };
        self.lock();
        defer self.mutex.unlock();
        self.state = .disconnected;
        self.busy = false;
    }
    fn work(self: *Client) !void {
        var stream = switch (self.endpoint) {
            .tcp => |endpoint| try transport.Stream.tcp(endpoint, &self.stop),
            .ssh => |ssh| try transport.Stream.ssh(ssh.host, ssh.args),
        };
        defer stream.close();
        const rpc = try a.create(Rpc);
        defer a.destroy(rpc);
        rpc.* = .{ .fd = stream.fd, .cancel = &self.stop };
        {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const mem = arena.allocator();
            const hello = try rpc.call(mem, "initialize", .{ .protocolVersion = "2025-06-18", .capabilities = struct {}{}, .clientInfo = .{ .name = "xodb-gui", .version = "1" } });
            if (!std.mem.eql(u8, string(field(hello, "protocolVersion")), "2025-06-18")) return error.RemoteProtocolVersionMismatch;
            try rpc.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n");
            const catalog = try rpc.call(mem, "tools/list", struct {}{});
            var found = false;
            const tools = field(catalog, "tools");
            if (tools == .array) for (tools.array.items) |tool| {
                if (std.mem.eql(u8, string(field(tool, "name")), "get_debug_view")) found = true;
            };
            if (!found) return error.RemoteServerNeedsDebugViewUpdate;
        }
        var generation: u64 = std.math.maxInt(u64);
        var session_id: u64 = 0;
        var selection: u64 = std.math.maxInt(u64);
        while (!self.stop.load(.acquire)) {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const mem = arena.allocator();
            self.lock();
            const command = self.pending;
            self.pending = null;
            const chosen_tid = self.tid;
            const chosen_frame = self.frame;
            const chosen_selection = self.selection;
            self.mutex.unlock();
            if (command) |bytes| {
                defer a.free(bytes);
                const args = try std.json.parseFromSlice(Value, mem, bytes, .{});
                _ = rpc.call(mem, "tools/call", args.value) catch |err| blk: {
                    if (err != error.RemoteToolFailed) return err;
                    self.message(std.mem.sliceTo(&rpc.diagnostic, 0));
                    @import("../m68k_log.zig").print("xodb: remote action {s} rejected: {s}\n", .{ string(field(args.value, "name")), std.mem.sliceTo(&rpc.diagnostic, 0) });
                    break :blk Value.null;
                };
                generation = std.math.maxInt(u64);
            }
            const session = try rpc.tool(mem, "get_debug_view", .{ .summary_only = true });
            const next_gen = try integer(field(session, "generation"));
            const next_id = try integer(field(session, "session_id"));
            if (session_id != 0 and next_id != session_id) return error.RemoteSessionReplaced;
            session_id = next_id;
            if (next_gen != generation or chosen_selection != selection) {
                const view = rpc.tool(mem, "get_debug_view", .{ .generation = next_gen, .tid = chosen_tid, .frame = chosen_frame }) catch |err| {
                    if (err == error.RemoteToolFailed and std.mem.eql(u8, std.mem.sliceTo(&rpc.diagnostic, 0), "StaleSnapshot")) continue;
                    return err;
                };
                const snapshot = try std.json.parseFromValue(wire.View, a, view, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
                if (snapshot.value.schema != 1 or snapshot.value.generation != next_gen or snapshot.value.session_id != session_id or snapshot.value.frames.len > 64 or snapshot.value.threads.len > 256) {
                    snapshot.deinit();
                    return error.InvalidRemoteView;
                }
                @import("../m68k_log.zig").print("xodb: remote {s} pid={d} state={s} generation={d} tid={d} frame={d} symbol={s} line={d}\n", .{
                    snapshot.value.architecture,                                                                                                  snapshot.value.pid,                                                                                                                             snapshot.value.state, snapshot.value.generation, snapshot.value.tid, snapshot.value.frame,
                    if (snapshot.value.frame < snapshot.value.frames.len) snapshot.value.frames[snapshot.value.frame].symbol orelse "?" else "?", if (snapshot.value.frame < snapshot.value.frames.len) (if (snapshot.value.frames[snapshot.value.frame].source) |site| site.line else 0) else 0,
                });
                self.lock();
                const old = self.published;
                self.published = snapshot;
                self.state = .ready;
                // A UI action/selection arriving during this read stays pending.
                self.busy = self.pending != null or self.selection != chosen_selection;
                self.mutex.unlock();
                if (old) |previous| previous.deinit();
                generation = next_gen;
                selection = chosen_selection;
            }
            var i: usize = 0;
            while (i < 6 and !self.stop.load(.acquire)) : (i += 1) {
                self.lock();
                const wake = self.pending != null or self.selection != selection;
                self.mutex.unlock();
                if (wake) break;
                _ = c.poll(null, 0, 25);
            }
        }
    }
};
pub fn field(value: Value, name: []const u8) Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}
pub fn string(value: Value) []const u8 {
    return if (value == .string) value.string else "";
}
fn integer(value: Value) !u64 {
    if (value != .integer or value.integer < 0) return error.InvalidRemoteResponse;
    return @intCast(value.integer);
}
pub const Rpc = struct {
    fd: c_int,
    cancel: *const std.atomic.Value(bool),
    id: u64 = 0,
    input: [1048576]u8 = undefined,
    used: usize = 0,
    diagnostic: [256]u8 = @splat(0),
    fn wait(self: *Rpc, events: c_short, deadline: u64) !void {
        while (true) {
            if (self.cancel.load(.acquire)) return error.Cancelled;
            if (transport.now() >= deadline) return error.RemoteTimeout;
            var p = c.pollfd{ .fd = self.fd, .events = events, .revents = 0 };
            const ready = c.poll(&p, 1, 25);
            if (ready < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                return error.RemoteIoFailed;
            }
            if (ready > 0) {
                if (p.revents & events != 0) return;
                if (p.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return error.RemoteDisconnected;
            }
        }
    }
    pub fn send(self: *Rpc, bytes: []const u8) !void {
        var sent: usize = 0;
        const deadline = transport.now() + 15_000_000_000;
        while (sent < bytes.len) {
            try self.wait(c.POLLOUT, deadline);
            const n = c.send(self.fd, bytes[sent..].ptr, bytes.len - sent, c.MSG_NOSIGNAL);
            if (n < 0) {
                if (std.c._errno().* == c.EAGAIN or std.c._errno().* == c.EINTR) continue;
                return error.RemoteDisconnected;
            }
            if (n == 0) return error.RemoteDisconnected;
            sent += @intCast(n);
        }
    }
    pub fn call(self: *Rpc, mem: std.mem.Allocator, method: []const u8, params: anytype) !Value {
        self.id += 1;
        const request = try std.json.Stringify.valueAlloc(mem, .{ .jsonrpc = "2.0", .id = self.id, .method = method, .params = params }, .{});
        try self.send(try std.fmt.allocPrint(mem, "{s}\n", .{request}));
        const deadline = transport.now() + 15_000_000_000;
        var notifications: usize = 0;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.input[0..self.used], '\n')) |end| {
                const parsed = try std.json.parseFromSlice(Value, mem, self.input[0..end], .{ .allocate = .alloc_always, .max_value_len = self.input.len });
                std.mem.copyForwards(u8, &self.input, self.input[end + 1 .. self.used]);
                self.used -= end + 1;
                const response = parsed.value;
                if (!std.mem.eql(u8, string(field(response, "jsonrpc")), "2.0")) return error.InvalidRemoteResponse;
                const id = field(response, "id");
                if (id == .null and field(response, "method") == .string) {
                    notifications += 1;
                    if (notifications > 64) return error.TooManyRemoteNotifications;
                    continue;
                }
                if (try integer(id) != self.id) return error.RemoteResponseIdMismatch;
                if (field(response, "error") != .null) return error.RemoteRpcFailed;
                const result = field(response, "result");
                if (result == .null) return error.InvalidRemoteResponse;
                const is_error = field(result, "isError");
                if (is_error == .bool and is_error.bool) {
                    self.diagnostic = @splat(0);
                    const content = field(result, "content");
                    const message = if (content == .array and content.array.items.len > 0) string(field(content.array.items[0], "text")) else "RemoteToolFailed";
                    @memcpy(self.diagnostic[0..@min(message.len, 255)], message[0..@min(message.len, 255)]);
                    return error.RemoteToolFailed;
                }
                return result;
            }
            if (self.used == self.input.len) return error.RemoteResponseTooLarge;
            try self.wait(c.POLLIN, deadline);
            const n = c.read(self.fd, self.input[self.used..].ptr, self.input.len - self.used);
            if (n == 0) return error.RemoteDisconnected;
            if (n < 0) {
                if (std.c._errno().* == c.EAGAIN or std.c._errno().* == c.EINTR) continue;
                return error.RemoteIoFailed;
            }
            self.used += @intCast(n);
        }
    }
    fn tool(self: *Rpc, mem: std.mem.Allocator, name: []const u8, args: anytype) !Value {
        return field(try self.call(mem, "tools/call", .{ .name = name, .arguments = args }), "structuredContent");
    }
};

const MockReply = struct {
    fd: c_int,
    bytes: []const u8,
    fragment: usize = 7,
    fn run(self: MockReply) void {
        defer {
            _ = c.shutdown(self.fd, c.SHUT_WR);
        }
        var sent: usize = 0;
        while (sent < self.bytes.len) {
            const count = @min(self.fragment, self.bytes.len - sent);
            const n = c.send(self.fd, self.bytes[sent..].ptr, count, c.MSG_NOSIGNAL);
            if (n <= 0) return;
            sent += @intCast(n);
            if (self.fragment < 128) _ = c.poll(null, 0, 1);
        }
    }
};
fn mockRpc(mem: std.mem.Allocator, bytes: []const u8, fragment: usize) !Value {
    var fds: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &fds) < 0) return error.SocketFailed;
    defer _ = c.close(fds[1]);
    const thread = try unsupportedThread(.{}, MockReply.run, .{MockReply{ .fd = fds[1], .bytes = bytes, .fragment = fragment }});
    defer thread.join();
    defer {
        _ = c.shutdown(fds[0], c.SHUT_RDWR);
        _ = c.close(fds[0]);
    }
    try transport.nonblock(fds[0]);
    var cancel = std.atomic.Value(bool).init(false);
    const rpc = try mem.create(Rpc);
    rpc.* = .{ .fd = fds[0], .cancel = &cancel };
    return rpc.call(mem, "ping", struct {}{});
}
test "remote RPC reconstructs fragmented messages and skips notifications" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try mockRpc(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n", 7);
    try std.testing.expect(field(result, "ok").bool);
}
test "remote RPC rejects wrong ids, incomplete EOF and oversized lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mem = arena.allocator();
    try std.testing.expectError(error.RemoteResponseIdMismatch, mockRpc(mem, "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}\n", 64));
    try std.testing.expectError(error.RemoteDisconnected, mockRpc(mem, "{\"jsonrpc\":", 64));
    const large = try mem.alloc(u8, 1048577);
    @memset(large, 'x');
    try std.testing.expectError(error.RemoteResponseTooLarge, mockRpc(mem, large, 32768));
}
test "remote cancellation interrupts I/O and a second action is not queued" {
    var cancel = std.atomic.Value(bool).init(true);
    const rpc = try std.testing.allocator.create(Rpc);
    defer std.testing.allocator.destroy(rpc);
    rpc.* = .{ .fd = -1, .cancel = &cancel };
    try std.testing.expectError(error.Cancelled, rpc.send("x"));
    var client = Client{ .endpoint = .{ .tcp = "127.0.0.1:1" }, .state = .ready, .busy = false };
    defer client.deinit();
    try client.action("continue", .{ .generation = 1 });
    try std.testing.expectError(error.RemoteBusy, client.action("continue", .{ .generation = 1 }));
}

test "remote RPC accepts MCP text mirrors larger than 64 KiB within the frame cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mem = arena.allocator();
    const mirror = try mem.alloc(u8, 80 * 1024);
    @memset(mirror, 'x');
    const object = try std.json.Stringify.valueAlloc(mem, .{ .jsonrpc = "2.0", .id = 1, .result = .{ .content = .{.{ .type = "text", .text = mirror }}, .structuredContent = .{ .schema = 1 } } }, .{});
    const reply = try std.fmt.allocPrint(mem, "{s}\n", .{object});
    const result = try mockRpc(mem, reply, 32768);
    try std.testing.expectEqual(@as(usize, 80 * 1024), field(field(result, "content").array.items[0], "text").string.len);
    try std.testing.expectEqual(@as(u64, 1), try integer(field(field(result, "structuredContent"), "schema")));
}

fn unsupportedThread(_: anytype, _: anytype, _: anytype) error{ThreadsUnavailable}!std.Thread { return error.ThreadsUnavailable; }
