//! Logical symbols and verified-image offsets that survive loader changes/restart.
const std = @import("std");
const policy = @import("probes.zig");
const bp = @import("../target/breakpoints.zig");
const A = std.heap.page_allocator;
const runtime = @import("../target/runtime.zig");
const rt = runtime.c;
pub const Entry = struct {
    id: u64,
    symbol: policy.Text = .{},
    path: []const u8 = "",
    build_id: [64]u8 = @splat(0),
    build_id_len: usize = 0,
    offset: u64 = 0,
    diagnostic: ?[]const u8 = null,
    enabled: bool = true,
    cursor: @import("modules.zig").Modules.SymbolCursor = .{},
    fn deinit(self: Entry) void {
        if (self.path.len > 0) A.free(self.path);
    }
    pub fn jsonStringify(self: Entry, writer: anytype) !void {
        try writer.write(.{ .id = self.id, .symbol = self.symbol, .path = self.path, .offset = self.offset, .diagnostic = self.diagnostic });
    }
};

test "a yielded install or image read keeps resolution pending until retried" {
    const modules = @import("modules.zig");
    const MockTarget = struct {
        handle: ?*rt.struct_xrt_target = null,
        site: [1]bp.Breakpoint = .{.{ .id = 1, .address = 0, .original = @splat(0), .pending = true }},
        failure: ?anyerror = null,
        pub fn breakpointSlice(self: *@This()) []const bp.Breakpoint {
            return &self.site;
        }
        pub fn resolveBreakpoint(self: *@This(), _: u64, address: u64) !void {
            if (self.failure) |err| return err;
            self.site[0].address = address;
            self.site[0].pending = false;
        }
    };
    const MockModules = struct {
        regions: struct { items: []const modules.Region } = .{ .items = &.{.{
            .start = 0x1000,
            .end = 0x2000,
            .offset = 0,
            .inode = 1,
            .device_major = 0,
            .device_minor = 0,
            .permissions = "r-xp".*,
            .path = "fixture",
        }} },
        pub fn automaticSymbolAddress(_: *@This(), _: []const u8, _: *modules.Modules.SymbolCursor) !u64 {
            return 0x1234;
        }
        pub fn restoredAddress(_: *@This(), _: modules.Region, _: []const u8, _: u64) !u64 {
            return error.SymbolDiscoveryPending;
        }
    };
    const MockSession = struct {
        target: MockTarget = .{},
        modules: MockModules = .{},
        pub fn refreshMaps(_: *@This()) !void {}
    };
    var manager = Manager{};
    defer manager.deinit();
    try manager.entries.append(A, .{ .id = 1, .symbol = try policy.Text.init("fixture_hit") });
    var session = MockSession{};
    for ([_]anyerror{ error.SymbolDiscoveryPending, error.SymbolDiscoveryBudgetExceeded }) |err| {
        session.target.failure = err;
        try manager.resolve(&session);
        try std.testing.expect(manager.resolving);
        try std.testing.expect(session.target.site[0].pending);
        try std.testing.expectEqualStrings(@errorName(err), manager.entries.items[0].diagnostic.?);
    }
    session.target.failure = null;
    try manager.resolve(&session);
    try std.testing.expect(!manager.resolving);
    try std.testing.expect(!session.target.site[0].pending);
    try std.testing.expectEqual(@as(u64, 0x1234), session.target.site[0].address);
    try std.testing.expect(manager.entries.items[0].diagnostic == null);
    // Restoring an address by build ID has the same scheduling obligation.
    session.target.site[0].pending = true;
    manager.entries.items[0].symbol = .{};
    manager.entries.items[0].build_id_len = 1;
    manager.entries.items[0].path = try A.dupe(u8, "fixture");
    try manager.resolve(&session);
    try std.testing.expect(manager.resolving);
    try std.testing.expectEqualStrings("SymbolDiscoveryPending", manager.entries.items[0].diagnostic.?);
}
pub const Manager = struct {
    entries: std.ArrayList(Entry) = .empty,
    hook: ?u64 = null,
    debug_address: ?u64 = null,
    loader_status: []const u8 = "not requested",
    epoch: u64 = 0,
    observed: u64 = 0,
    resolving: bool = false,
    loader_attempt: u64 = 0,
    file_reads: rt.struct_xrt_file_budget = std.mem.zeroes(rt.struct_xrt_file_budget),
    cancel: ?*const volatile @import("../c.zig").api.sig_atomic_t = null,
    loader_reads: rt.struct_xrt_loader = std.mem.zeroes(rt.struct_xrt_loader),
    pub fn deinit(self: *Manager) void {
        for (self.entries.items) |item| item.deinit();
        self.entries.deinit(A);
    }
    /// Discard this logical probe after removing its physical site, or after
    /// the target address space ended. Other probes retain their identities.
    pub fn forget(self: *Manager, id: u64) void {
        for (self.entries.items, 0..) |item, i| if (item.id == id) {
            item.deinit();
            _ = self.entries.swapRemove(i);
            return;
        };
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
        out.cancel = self.cancel;
    }
    pub fn entry(self: *Manager, id: u64) ?*Entry {
        for (self.entries.items) |*v| if (v.id == id) return v;
        return null;
    }
    pub fn probe(session: anytype, id: u64) ?bp.Breakpoint {
        for (session.target.breakpointSlice()) |v| if (v.id == id) return v;
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
        self.epoch = session.target.snapshot().image_epoch;
        if (!self.resolving) self.file_reads = std.mem.zeroes(rt.struct_xrt_file_budget);
        try self.resolve(session);
        self.installHook(session);
        self.observed = session.target.snapshot().generation;
        return id;
    }
    /// Capture ordinary physical breakpoints before restart or a loader deletion.
    pub fn remember(self: *Manager, session: anytype) !void {
        self.prune(session);
        if (session.target.snapshot().breakpoint_count == 0) return;
        try session.refreshMaps();
        for (session.target.breakpointSlice()) |v| {
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
        // Resuming a planted breakpoint needs a hardware step or software
        // successors. Skip discovery when the row has neither. Symbols already
        // in the maps still resolve.
        var step_resources = std.mem.zeroes(rt.struct_xrt_step_resources);
        const step_status = rt.xrt_arch_step_resources(session.target.arch().descriptor(), rt.XRT_ISA_MODE_ORDINARY, &step_resources);
        if (step_status != rt.XRT_OK or (step_resources.hardware_step == 0 and step_resources.software_probes == 0)) {
            self.loader_status = "loader rendezvous needs a hardware or software step";
            return;
        }
        // Retry incomplete bootstrap metadata at later stops, at most once
        // per second. No symbol search across mapped files belongs here.
        const now = @import("../target/linux.zig").now();
        if (self.loader_attempt != 0 and now -| self.loader_attempt < 1_000_000_000) return;
        self.loader_attempt = now;
        var budget = std.mem.zeroInit(rt.struct_xrt_file_budget, .{ .limit_bytes = 128 * 1024, .deadline_ns = now + 2_000_000_000, .cancel = self.cancel });
        rt.xrt_target_file_budget(session.target.handle, &budget);
        defer rt.xrt_target_file_budget(session.target.handle, null);
        runtime.check(rt.xrt_target_loader(session.target.handle, &self.loader_reads, self.cancel)) catch |err| {
            self.loader_status = if (err == error.InvalidArgument and rt.xrt_target_is_remote(session.target.handle)) "agent needs updating: loader metadata unsupported" else @errorName(err);
            return;
        };
        const function = self.loader_reads.break_address;
        const debug = self.loader_reads.debug_address;
        if (function == 0 or debug == 0) {
            self.loader_status = "loader not initialized; resolve at ordinary stops";
            return;
        }
        for (session.target.breakpointSlice()) |v| if (!v.pending and v.address == function) {
            self.loader_status = "loader address already has a user breakpoint";
            return;
        };
        const id = session.target.setBreakpoint(function, false) catch |err| {
            self.loader_status = @errorName(err);
            return;
        };
        session.target.markBreakpointInternal(id, true) catch return;
        self.hook = id;
        self.debug_address = debug;
        self.loader_status = "glibc loader rendezvous";
        self.loader_attempt = 0;
    }
    /// A yielded lookup, image read or install leaves the same item unfinished.
    /// Never publish a completed pass or allow its queued continue in this case.
    fn resolutionError(self: *Manager, item: *Entry, err: anyerror) !bool {
        item.diagnostic = @errorName(err);
        switch (err) {
            error.SymbolDiscoveryPending, error.SymbolDiscoveryBudgetExceeded => {
                self.resolving = true;
                return true;
            },
            error.SymbolDiscoveryCancelled => return err,
            else => return false,
        }
    }
    fn resolve(self: *Manager, session: anytype) !void {
        self.resolving = false;
        var pending = false;
        for (self.entries.items) |item| if (probe(session, item.id)) |current| {
            if (current.pending) {
                pending = true;
                break;
            }
        };
        if (!pending) return;
        try session.refreshMaps();
        var slice = std.mem.zeroInit(rt.struct_xrt_file_budget, .{
            .limit_bytes = 128 * 1024,
            .deadline_ns = @import("../target/linux.zig").now() + 25_000_000,
            .cancel = self.cancel,
        });
        rt.xrt_target_file_budget(session.target.handle, &slice);
        defer {
            rt.xrt_target_file_budget(session.target.handle, null);
            self.file_reads.bytes +|= slice.bytes;
            self.file_reads.files +|= slice.files;
            self.file_reads.negative_hits +|= slice.negative_hits;
            self.file_reads.skipped +|= slice.skipped;
            self.file_reads.resumed_bytes = @max(self.file_reads.resumed_bytes, slice.resumed_bytes);
        }
        for (self.entries.items) |*item| {
            const current = probe(session, item.id) orelse continue;
            if (!current.pending) continue;
            var address: ?u64 = null;
            if (item.symbol.len > 0) {
                if (session.modules.automaticSymbolAddress(item.symbol.slice(), &item.cursor)) |resolved| address = resolved else |err| {
                    if (try self.resolutionError(item, err)) return;
                    continue;
                }
            } else if (item.build_id_len > 0) {
                for (session.modules.regions.items) |region| {
                    if (region.permissions[2] != 'x' or !std.mem.eql(u8, region.path, item.path)) continue;
                    address = session.modules.restoredAddress(region, item.build_id[0..item.build_id_len], item.offset) catch |err| {
                        if (try self.resolutionError(item, err)) return;
                        continue;
                    };
                    break;
                }
                if (address == null) {
                    if (item.diagnostic == null) item.diagnostic = "BreakpointImageNotLoaded";
                    continue;
                }
            } else continue;
            session.target.resolveBreakpoint(item.id, address.?) catch |err| {
                if (try self.resolutionError(item, err)) return;
                continue;
            };
            item.diagnostic = null;
        }
    }
    pub fn poll(self: *Manager, session: anytype) !void {
        if (session.target.snapshot().state != .stopped or session.target.snapshot().stepping != null or session.target.sharedVm() or session.target.snapshot().detach_pending) {
            self.resolving = false;
            return;
        }
        if (self.epoch == session.target.snapshot().image_epoch) for (self.entries.items) |*item| {
            if (probe(session, item.id)) |current| item.enabled = current.enabled;
        };
        if (self.epoch != session.target.snapshot().image_epoch) {
            self.hook = null;
            self.debug_address = null;
            self.loader_attempt = 0;
            self.epoch = session.target.snapshot().image_epoch;
            // Exec invalidated physical locations; preserve logical identities.
            for (self.entries.items) |item| if (probe(session, item.id) == null) {
                if (session.target.snapshot().breakpoint_count == 128) return error.BreakpointLimit;
                try session.target.restoreBreakpoint(item.id, item.enabled);
            };
        }
        self.prune(session);
        if (self.entries.items.len == 0) {
            self.resolving = false;
            if (self.hook) |id| {
                try session.target.removeBreakpoint(id);
                self.hook = null;
                self.debug_address = null;
            }
            return;
        }
        if (self.observed == session.target.snapshot().generation and !self.resolving) return;
        const continuing = self.observed == session.target.snapshot().generation and self.resolving;
        if (!continuing) {
            self.file_reads = std.mem.zeroes(rt.struct_xrt_file_budget);
            for (self.entries.items) |*item| item.cursor = .{};
        }
        self.observed = session.target.snapshot().generation;
        defer self.observed = session.target.snapshot().generation;
        if (continuing) {
            try self.resolve(session);
            return;
        }
        self.installHook(session);
        var loader_hit = false;
        if (self.hook) |id| for (session.target.threadSlice()) |thread| {
            if (thread.reason == .breakpoint and probe(session, id) != null and thread.breakpoint_address == probe(session, id).?.address) loader_hit = true;
        };
        if (loader_hit) {
            var bytes: [32]u8 = undefined;
            if (try session.target.readMemory(self.debug_address.?, &bytes) != bytes.len) return error.LoaderRendezvousUnreadable;
            const offset: usize = if (session.target.arch().addressBytes() == 4) 12 else 24;
            const state = std.mem.readInt(u32, bytes[offset..][0..4], session.target.arch().endian());
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
        self.observed = session.target.snapshot().generation;
    }
};
