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
    var last_error: ?anyerror = null;
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
        var issue: ?anyerror = null;
        session.poll() catch |err| {
            // Observation problems keep the session; a dead private stream
            // ends it so the window reports DISCONNECTED, not a ready target.
            if (session.linkLost()) return err;
            issue = err;
        };
        // A requested launch breakpoint is part of startup. Do not expose
        // an actionable dyld stop while its symbol job is still pending.
        if (!session.ready()) {
            _ = c.poll(null, 0, 25);
            continue;
        }
        if (revision != session.revision or selection != selected or issue != last_error or last_error != null) {
            const observed = try observe(&session, mem, tid, frame);
            var view = observed.view;
            issue = issue orelse observed.issue;
            if (issue) |err| {
                self.message(@errorName(err));
                const diagnostics = try mem.alloc(wire.Diagnostic, view.diagnostics.len + 1);
                diagnostics[0] = .{ .component = "native observation", .message = @errorName(err) };
                @memcpy(diagnostics[1..], view.diagnostics);
                view.diagnostics = diagnostics;
                if (issue != last_error) log.warn(.runtime, "xodb: native observation unavailable: {s}; session retained\n", .{@errorName(err)});
            }
            // Retry failed observations without redrawing the same failure.
            if (revision == session.revision and selection == selected and issue == last_error) {
                _ = c.poll(null, 0, 25);
                continue;
            }
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
            last_error = issue;
            if (session.detached) {
                self.message("Detached; target released");
                return; // No polling or target reads after the detach publication.
            }
        }
        _ = c.poll(null, 0, 25);
    }
}

fn observe(session: anytype, mem: std.mem.Allocator, tid: i32, frame: usize) !struct { view: wire.View, issue: ?anyerror = null } {
    const view = session.snapshot(mem, tid, frame) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .view = try session.summary(mem, tid), .issue = err };
    };
    return .{ .view = view };
}

test "remote native missing PC retains a controllable summary and recovers" {
    const Fake = struct {
        missing: bool = true,
        fn snapshot(self: *@This(), mem: std.mem.Allocator, tid: i32, frame: usize) !wire.View {
            _ = frame;
            if (self.missing) return error.ProgramCounterUnavailable;
            return self.summary(mem, tid);
        }
        fn summary(_: *@This(), _: std.mem.Allocator, tid: i32) !wire.View {
            return .{ .session_id = 1, .pid = 7, .generation = 3, .architecture = "aarch64", .owned = false, .state = "stopped", .scope = "control", .tid = tid };
        }
        fn retained(view: wire.View) !void {
            if (!std.mem.eql(u8, view.state, "stopped") or view.pid != 7 or !std.mem.eql(u8, view.scope, "control")) return error.SessionLost;
        }
    };
    var fake: Fake = .{};
    const unavailable = try observe(&fake, std.testing.allocator, 42, 0);
    try std.testing.expectEqual(error.ProgramCounterUnavailable, unavailable.issue.?);
    try std.testing.expectEqualStrings("control", unavailable.view.scope);
    try std.testing.expectEqual(@as(i32, 42), unavailable.view.tid);
    try std.testing.expectEqual(@as(usize, 0), unavailable.view.registers.len);
    fake.missing = false;
    const recovered = try observe(&fake, std.testing.allocator, 42, 0);
    try std.testing.expect(recovered.issue == null);
    try Fake.retained(unavailable.view);
    var wrong = unavailable.view;
    wrong.state = "detached";
    try std.testing.expectError(error.SessionLost, Fake.retained(wrong));
}

fn action(session: *native.Session, mem: std.mem.Allocator, bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, mem, bytes, .{});
    const decoded = try @import("../model/json_command.zig").decode(client.string(client.field(parsed.value, "name")), client.field(parsed.value, "arguments"));
    if (decoded.operation.needsObservation() and decoded.generation != session.revision) return error.StaleSnapshot;
    try session.execute(decoded.operation);
}
