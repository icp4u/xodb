const std = @import("std");
const Server = @import("server.zig").Server;
const Session = @import("../model/session.zig").Session;
const context = @import("shared_context.zig");
const c = context.c;
const linux = @import("../target/linux.zig");
const allocator = std.heap.page_allocator;

// C owns the socket, peer identity and controller policy. Zig adapts each peer
// to the existing MCP codec on the one target-owner thread.
pub const Endpoint = struct {
    service: *c.struct_xsvc,
    clients: [c.XSVC_MAX_PEERS]?Client = @splat(null),
    source_path: ?[:0]const u8,
    const Client = struct { id: u64, server: *Server, accepted: u64, progressed: u64 };
    pub fn init(path: [:0]const u8, source: ?[:0]const u8) !Endpoint {
        const service = c.xsvc_open(path.ptr) orelse {
            std.debug.print("xodb: cannot open shared session socket {s}: errno={d}\n", .{ path, std.c._errno().* });
            return error.SessionSocketUnavailable;
        };
        return .{ .service = service, .source_path = source };
    }
    pub fn deinit(self: *Endpoint) void {
        for (&self.clients) |*slot| if (slot.*) |client| {
            client.server.deinit();
            allocator.destroy(client.server);
            slot.* = null;
        };
        c.xsvc_close(self.service);
    }
    fn drop(self: *Endpoint, slot: *?Client) void {
        const client = slot.* orelse return;
        client.server.deinit();
        _ = c.xsvc_drop(self.service, client.id, linux.now());
        allocator.destroy(client.server);
        slot.* = null;
    }
    pub fn revoke(self: *Endpoint) !void {
        // Human F8 may toggle twice in a queued input batch. A final scope
        // comparison alone must never resurrect the prior controller lease.
        try context.check(c.xsvc_revoke(self.service, linux.now()));
    }
    pub fn state(self: *Endpoint, root: *Session) !c.struct_xsvc_state {
        try context.check(c.xsvc_tick(self.service, linux.now(), @intFromEnum(root.agent_scope)));
        var result: c.struct_xsvc_state = undefined;
        try context.check(c.xsvc_state(self.service, &result));
        return result;
    }
    pub fn pump(self: *Endpoint, root: *Session) !void {
        try context.check(c.xsvc_tick(self.service, linux.now(), @intFromEnum(root.agent_scope)));
        // Bound accept work even when the listener is being flooded.
        for (0..c.XSVC_MAX_PEERS) |_| {
            var peer: c.struct_xsvc_peer = undefined;
            const accepted = c.xsvc_accept(self.service, linux.now(), &peer);
            if (accepted < 0) return error.SessionAcceptFailed;
            if (accepted == 0) break;
            const server = allocator.create(Server) catch {
                _ = c.xsvc_drop(self.service, peer.id, linux.now());
                continue;
            };
            server.* = .{ .input_fd = peer.fd, .output_fd = peer.fd, .source_path = self.source_path, .shared = .{ .service = self.service, .client_id = peer.id }, .request_limit = 1 };
            server.init() catch {
                allocator.destroy(server);
                _ = c.xsvc_drop(self.service, peer.id, linux.now());
                continue;
            };
            var stored = false;
            for (&self.clients) |*slot| if (slot.* == null) {
                slot.* = .{ .id = peer.id, .server = server, .accepted = linux.now(), .progressed = linux.now() };
                stored = true;
                break;
            };
            if (!stored) {
                server.deinit();
                allocator.destroy(server);
                _ = c.xsvc_drop(self.service, peer.id, linux.now());
                return error.SessionPeerInvariant;
            }
        }
        for (&self.clients) |*slot| {
            const client = if (slot.*) |*value| value else continue;
            const server = client.server;
            const before = server.transmitted;
            server.pump(root) catch |err| {
                std.debug.print("xodb: session client #{d} closed: {s}\n", .{ client.id, @errorName(err) });
                self.drop(slot);
                continue;
            };
            const now = linux.now();
            if (server.transmitted != before or server.queued == 0) client.progressed = now;
            if ((server.closed and server.queued == 0) or
                (!server.initialized and now -| client.accepted >= 5 * std.time.ns_per_s) or
                (server.queued != 0 and now -| client.progressed >= 10 * std.time.ns_per_s)) self.drop(slot);
        }
    }
};
