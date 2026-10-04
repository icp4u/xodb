//! Logical symbols and verified-image offsets that survive loader changes/restart.
const std = @import("std");
const policy = @import("probes.zig");
const bp = @import("../target/breakpoints.zig");
const A = std.heap.page_allocator;
pub const Entry = struct {
    id: u64,
    symbol: policy.Text = .{},
    path: []const u8 = "",
    build_id: [64]u8 = @splat(0),
    build_id_len: usize = 0,
    offset: u64 = 0,
    diagnostic: ?[]const u8 = null,
    enabled: bool = true,
    fn deinit(self: Entry) void {
        if (self.path.len > 0) A.free(self.path);
    }
    pub fn jsonStringify(self: Entry, writer: anytype) !void {
        try writer.write(.{ .id = self.id, .symbol = self.symbol, .path = self.path, .offset = self.offset, .diagnostic = self.diagnostic });
    }
};
pub const Manager = struct {
    entries: std.ArrayList(Entry) = .empty,
    hook: ?u64 = null,
    debug_address: ?u64 = null,
    loader_status: []const u8 = "not requested",
    epoch: u64 = 0,
    observed: u64 = 0,
    pub fn deinit(self: *Manager) void {
        for (self.entries.items) |item| item.deinit();
        self.entries.deinit(A);
    }
    pub fn copyForFork(self: *const Manager, out: *Manager) !void {
        std.debug.assert(out.entries.items.len == 0);
        try out.entries.ensureTotalCapacityPrecise(A, self.entries.items.len);
        for (self.entries.items) |item| {
            var copy = item;
            if (item.path.len > 0) copy.path = try A.dupe(u8, item.path);
            out.entries.appendAssumeCapacity(copy);
        }
        out.hook = self.hook;
        out.debug_address = self.debug_address;
        out.loader_status = self.loader_status;
        out.epoch = self.epoch;
    }
    pub fn entry(self: *Manager, id: u64) ?*Entry {
        for (self.entries.items) |*v| if (v.id == id) return v;
        return null;
    }
    pub fn probe(session: anytype, id: u64) ?*bp.Breakpoint {
        for (session.target.breakpoints[0..session.target.breakpoint_count]) |*v| if (v.id == id) return v;
        return null;
    }
    fn prune(self: *Manager, session: anytype) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (probe(session, self.entries.items[i].id) == null) {
                self.entries.items[i].deinit();
                _ = self.entries.swapRemove(i);
            } else i += 1;
        }
        if (self.hook) |id| if (probe(session, id) == null) {
            self.hook = null;
            self.debug_address = null;
        };
    }
    pub fn addSymbol(self: *Manager, session: anytype, name: []const u8) !u64 {
        if (name.len == 0) return error.InvalidSymbol;
        const text = try policy.Text.init(name);
        self.prune(session);
        for (self.entries.items) |v| if (std.mem.eql(u8, v.symbol.slice(), name)) return v.id;
        if (self.entries.items.len >= 128) return error.BreakpointLimit;
        try self.entries.ensureUnusedCapacity(A, 1);
        try session.refreshMaps();
        const id = try session.target.reserveBreakpoint();
        errdefer session.target.removeBreakpoint(id) catch {};
        self.entries.appendAssumeCapacity(.{ .id = id, .symbol = text });
        errdefer _ = self.entries.pop();
        self.epoch = session.target.image_epoch;
        try self.resolve(session);
        self.installHook(session);
        return id;
    }
    /// Capture ordinary physical breakpoints before restart or a loader deletion.
    pub fn remember(self: *Manager, session: anytype) !void {
        self.prune(session);
        if (session.target.breakpoint_count == 0) return;
        try session.refreshMaps();
        for (session.target.breakpoints[0..session.target.breakpoint_count]) |v| {
            if (v.internal or v.temporary or self.entry(v.id) != null) continue;
            if (session.run_to) |run| if (run.owns_probe and run.probe == v.id) continue;
            var item = Entry{ .id = v.id, .enabled = v.enabled };
            if (session.modules.at(v.address)) |module| {
                if (module.image.buildId()) |id| {
                    if (id.len <= item.build_id.len) {
                        @memcpy(item.build_id[0..id.len], id);
                        item.build_id_len = id.len;
                        item.offset = try module.linkAddress(v.address);
                        item.path = try A.dupe(u8, module.path);
                    } else item.diagnostic = "BuildIdTooLong";
                } else item.diagnostic = "BreakpointImageHasNoBuildId";
            } else |_| item.diagnostic = "BreakpointAddressNotRestorable";
            errdefer item.deinit();
            try self.entries.append(A, item);
        }
    }
    fn installHook(self: *Manager, session: anytype) void {
        if (self.hook != null or self.entries.items.len == 0) return;
        session.refreshMaps() catch {
            self.loader_status = "maps unavailable";
            return;
        };
        const debug = session.modules.findSymbol("_r_debug") catch {
            self.loader_status = "no loader rendezvous; resolve at ordinary stops";
            return;
        };
        // The exported bootstrap function is available before r_brk is initialized.
        const function = session.modules.findSymbol("_dl_debug_state") catch {
            self.loader_status = "no glibc loader hook; resolve at ordinary stops";
            return;
        };
        for (session.target.breakpoints[0..session.target.breakpoint_count]) |v| if (!v.pending and v.address == function.address) {
            self.loader_status = "loader address already has a user breakpoint";
            return;
        };
        const id = session.target.setBreakpoint(function.address, false) catch |err| {
            self.loader_status = @errorName(err);
            return;
        };
        probe(session, id).?.internal = true;
        self.hook = id;
        self.debug_address = debug.address;
        self.loader_status = "glibc loader rendezvous";
    }
    fn resolve(self: *Manager, session: anytype) !void {
        try session.refreshMaps();
        for (self.entries.items) |*item| {
            const current = probe(session, item.id) orelse continue;
            if (!current.pending) continue;
            var address: ?u64 = null;
            if (item.symbol.len > 0) {
                if (session.modules.findSymbol(item.symbol.slice())) |symbol| address = symbol.address else |err| {
                    item.diagnostic = @errorName(err);
                    continue;
                }
            } else if (item.build_id_len > 0) {
                for (session.modules.regions.items) |region| {
                    if (region.permissions[2] != 'x' or !std.mem.eql(u8, region.path, item.path)) continue;
                    const module = session.modules.load(region) catch continue;
                    const id = module.image.buildId() orelse continue;
                    if (!std.mem.eql(u8, id, item.build_id[0..item.build_id_len])) {
                        item.diagnostic = "BreakpointBuildIdMismatch";
                        continue;
                    }
                    address = try module.runtimeAddress(item.offset);
                    break;
                }
                if (address == null) {
                    if (item.diagnostic == null) item.diagnostic = "BreakpointImageNotLoaded";
                    continue;
                }
            } else continue;
            session.target.resolveBreakpoint(item.id, address.?) catch |err| {
                item.diagnostic = @errorName(err);
                continue;
            };
            item.diagnostic = null;
        }
    }
    pub fn poll(self: *Manager, session: anytype) !void {
        if (session.target.state != .stopped or session.target.stepping != null or session.target.sharedVm() or session.target.detach_pending) return;
        if (self.epoch == session.target.image_epoch) for (self.entries.items) |*item| {
            if (probe(session, item.id)) |current| item.enabled = current.enabled;
        };
        if (self.epoch != session.target.image_epoch) {
            self.hook = null;
            self.debug_address = null;
            self.epoch = session.target.image_epoch;
            // Exec invalidated physical locations; preserve logical identities.
            for (self.entries.items) |item| if (probe(session, item.id) == null) {
                if (session.target.breakpoint_count == session.target.breakpoints.len) return error.BreakpointLimit;
                session.target.breakpoints[session.target.breakpoint_count] = .{ .id = item.id, .address = 0, .original = @splat(0), .pending = true, .patched = false, .enabled = item.enabled };
                session.target.breakpoint_count += 1;
            };
        }
        self.prune(session);
        if (self.entries.items.len == 0) {
            if (self.hook) |id| {
                try session.target.removeBreakpoint(id);
                self.hook = null;
                self.debug_address = null;
            }
            return;
        }
        if (self.observed == session.target.generation) return;
        self.observed = session.target.generation;
        self.installHook(session);
        var loader_hit = false;
        if (self.hook) |id| for (session.target.threadSlice()) |thread| {
            if (thread.reason == .breakpoint and probe(session, id) != null and thread.breakpoint_address == probe(session, id).?.address) loader_hit = true;
        };
        if (loader_hit) {
            var bytes: [20]u8 = undefined;
            if (try session.target.readMemory(self.debug_address.?, &bytes) != bytes.len) return error.LoaderRendezvousUnreadable;
            const state = std.mem.readInt(u32, bytes[12..16], .big);
            if (state == 2) {
                try self.remember(session);
                for (self.entries.items) |item| if (probe(session, item.id)) |current| {
                    if (!current.pending) try session.target.withdrawBreakpoint(item.id);
                };
                return;
            }
            if (state != 0) return;
        }
        try self.resolve(session);
        self.observed = session.target.generation;
    }
};
