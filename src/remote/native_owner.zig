//! Native local owner loop on the client's worker. Only the macOS entry point
//! imports this file, so the shared client and UI never reach the session.
const std = @import("std");
const log = @import("../log.zig");
const client = @import("client.zig");
const c = @import("transport.zig").c;
const wire = @import("view.zig");
const native = @import("../model/macos_session.zig");
const a = std.heap.page_allocator;

pub const Owner = struct {
    options: native.Options,
    pub fn endpoint(self: *Owner) client.Endpoint {
        return .{ .local = .{ .context = self, .run = run } };
    }
};

fn run(context: *anyopaque, self: *client.Client) !void {
    const owner: *Owner = @ptrCast(@alignCast(context));
    var session = native.Session{ .options = owner.options };
    try session.open();
    defer session.close();
    var revision: u64 = 0;
    var selection: u64 = std.math.maxInt(u64);
    while (!self.stop.load(.acquire)) {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const mem = arena.allocator();
        self.lock();
        const pending = self.pending;
        self.pending = null;
        const tid = self.tid;
        const frame = self.frame;
        const selected = self.selection;
        self.mutex.unlock();
        if (pending) |bytes| {
            defer a.free(bytes);
            action(&session, mem, bytes) catch |err| self.message(@errorName(err));
            revision = 0; // Publish the same state after a refused action.
        }
        try session.poll();
        // A requested launch breakpoint is part of startup. Do not expose
        // an actionable dyld stop while its symbol job is still pending.
        if (!session.ready()) {
            _ = c.poll(null, 0, 25);
            continue;
        }
        if (revision != session.revision or selection != selected) {
            const view = try session.snapshot(mem, tid, frame);
            const json = try std.json.Stringify.valueAlloc(mem, view, .{});
            const output = if (@import("../redact.zig").active()) |policy| try policy.scrubJson(mem, json, null) else json;
            const snapshot = try std.json.parseFromSlice(wire.View, a, output, .{ .allocate = .alloc_always });
            log.info(.runtime, "xodb: native pid={d} state={s} generation={d} threads={d} frames={d} registers={d} breakpoints={d}\n", .{ view.pid, view.state, view.generation, view.threads.len, view.frames.len, view.registers.len, view.breakpoints.len });
            self.lock();
            const old = self.published;
            self.published = snapshot;
            self.state = .ready;
            self.busy = self.pending != null or self.selection != selected;
            self.mutex.unlock();
            if (old) |previous| previous.deinit();
            revision = session.revision;
            selection = selected;
        }
        _ = c.poll(null, 0, 25);
    }
}

fn action(session: *native.Session, mem: std.mem.Allocator, bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, mem, bytes, .{});
    const decoded = try @import("../model/json_command.zig").decode(client.string(client.field(parsed.value, "name")), client.field(parsed.value, "arguments"));
    if (decoded.operation.needsObservation() and decoded.generation != session.revision) return error.StaleSnapshot;
    try session.execute(decoded.operation);
}
