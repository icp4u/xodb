//! Explicit private-test controls. Disabled unless a test supplies a directory;
//! files observe an admitted command, its peer disposal and dispatch separately.
const std = @import("std");
const boundary = @import("remote_owner.zig");
const c = @import("../c.zig").api;
const a = std.heap.page_allocator;

pub const Probes = struct {
    directory: ?[:0]const u8 = null,
    sequence: ?u64 = null,
    admitted_ns: u64 = 0,
    disconnected: bool = false,
    released: bool = false,

    pub fn environment() ?[:0]const u8 {
        const private = c.getenv("XODB_TEST_PRIVATE_DISPLAY") orelse return null;
        if (!std.mem.eql(u8, std.mem.span(private), "1")) return null;
        return if (c.getenv("XODB_TEST_REMOTE_DIR")) |path| std.mem.span(path) else null;
    }
    fn exists(self: *const Probes, name: []const u8) !bool {
        const directory = self.directory orelse return false;
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ directory, name }, 0);
        defer a.free(path);
        if (c.access(path, c.F_OK) != 0) {
            if (c.__errno_location().* == c.ENOENT) return false;
            return error.TestProbeAccessFailed;
        }
        return true;
    }
    fn record(self: *const Probes, name: []const u8, value: anytype) !void {
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.directory.?, name }, 0);
        defer a.free(path);
        const temporary = try std.fmt.allocPrintSentinel(a, "{s}.new", .{path}, 0);
        defer a.free(temporary);
        const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
        defer a.free(bytes);
        const fd = c.open(temporary, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o644));
        if (fd < 0) return error.TestProbeWriteFailed;
        defer _ = c.close(fd);
        var done: usize = 0;
        while (done < bytes.len) {
            const n = c.write(fd, bytes.ptr + done, bytes.len - done);
            if (n < 0 and c.__errno_location().* == c.EINTR) continue;
            if (n <= 0) return error.TestProbeWriteFailed;
            done += @intCast(n);
        }
        if (c.rename(temporary, path) != 0) return error.TestProbeRenameFailed;
    }
    pub fn dispatchAllowed(self: *Probes, command: *const boundary.Command, peer_present: bool, now: u64) !bool {
        if (self.directory == null or self.released) return true;
        if (self.sequence == null) {
            if (command.request.action != .mcp or command.request.actor != .agent or command.request.actor.agent.client == 0 or
                !std.mem.eql(u8, command.request.action.mcp.name, "write_memory") or !try self.exists("arm")) return true;
            self.sequence = command.sequence;
            self.admitted_ns = now;
            try self.record("admitted.json", .{ .sequence = command.sequence, .stamp = command.request.stamp, .client = command.request.actor.agent.client, .lease = command.request.actor.agent.lease });
        }
        std.debug.assert(self.sequence == command.sequence);
        if (!peer_present and !self.disconnected) {
            try self.record("disconnected.json", .{ .sequence = command.sequence, .client = command.request.actor.agent.client });
            self.disconnected = true;
        }
        if (try self.exists("release")) {
            try self.record("dispatch.json", .{ .sequence = command.sequence, .disconnected = self.disconnected });
            self.released = true;
            return true;
        }
        if (now -| self.admitted_ns > 30 * std.time.ns_per_s) return error.TestAdmissionBarrierDeadline;
        return false;
    }
    pub fn completed(self: *Probes, command: *const boundary.Command, disposed: bool) void {
        if (self.sequence != command.sequence or self.directory == null) return;
        self.record("finished.json", .{ .sequence = command.sequence, .disposed = disposed, .dispatched = self.released }) catch {};
    }
    pub fn failPublication(self: *const Probes) !bool {
        return self.exists("fail-publication");
    }
};
