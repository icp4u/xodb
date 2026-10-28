//! Session lifetimes and presentation over the C metadata workers.
const std = @import("std");
const c = @import("../c.zig").api;
const runtime = @import("../target/runtime.zig");
const Session = @import("session.zig").Session;
const Region = @import("modules.zig").Region;
const Modules = @import("modules.zig").Modules;
const Coverage = @import("../binary/snapshot.zig").Completeness;
const info = @import("../debug/info.zig");
const loc = @import("../debug/location.zig");
const A = std.heap.page_allocator;
const Kind = enum { javascript, unwind, image };
const max_unwind_jobs = 64;
// Slots kept for the rest of a remote session: two image views, two
// JavaScript views, one symbol file, two temporary opens, and the maps/auxv
// read. A smaller table keeps half its slots for unwind instead: one job
// cannot walk even an executable and one library. An older agent omits the
// count; keep the historical cap of sixteen.
const remote_file_headroom = 8;
const max_remote_unwind_jobs = 16;
fn remoteUnwindLimit(slots: u32) usize {
    if (slots == 0) return max_remote_unwind_jobs;
    const room: usize = @max(slots -| remote_file_headroom, slots / 2, 1);
    return @min(room, max_unwind_jobs);
}
const max_jobs = max_unwind_jobs + 4;
const unwind_budget: u64 = 128 * 1024 * 1024;
const Entry = struct {
    id: u64,
    session_id: u64,
    kind: Kind,
    coverage: Coverage = .sections,
    epoch: u64,
    region: Region,
    path: [:0]u8,
    job: *c.struct_xmd_job,
    retired: bool = false,
    touched_query: u64 = 0,
    last_state: c_uint = c.XMD_PREPARING,
    cfi: ?info.Cfi = null,
    checked_query: u64 = 0,
    bias: ?u64 = null,
    layout: ?c.struct_xjs_layout = null,
    verified_generation: u64 = 0,
    verify_generation: u64 = 0,
    verify_pending: bool = false,
    verify_error: ?[]const u8 = null,
    fn deinit(self: *Entry) void {
        if (self.cfi) |*decoder| decoder.deinit();
        c.xmd_destroy(self.job);
        A.free(self.path);
    }
};
pub const JobStatus = struct {
    id: u64,
    session_id: u64,
    image_epoch: u64,
    kind: Kind,
    image: []const u8,
    image_truncated: bool,
    state: []const u8,
    reason: ?[]const u8,
    source_bytes: u64,
    source_reads: u64,
    source_size: u64,
    units: u64,
    dies: u64,
    retained_unwind_bytes: u64,
    cached_bytes: u64,
    index_file_bytes: u64,
    candidate_units: u64,
    accelerator_hits: u64,
    image_bytes: u64 = 0,
    image_total: u64 = 0,
};
pub const Snapshot = struct {
    items: [max_jobs]JobStatus = undefined,
    count: usize = 0,
    pub fn jsonStringify(self: Snapshot, writer: anytype) !void {
        try writer.write(self.items[0..self.count]);
    }
};
/// A main-image job refused before it started. Remembered for the image epoch
/// so an owner poll does not reopen the remote file to learn the same answer.
const ImageRefusal = struct { epoch: u64, region: Region, size: u64, identity: runtime.c.struct_xrt_file_identity, reason: @import("../binary/snapshot.zig").Refusal };
pub const State = struct {
    entries: [max_jobs]?Entry = @splat(null),
    image_refusals: [2]?ImageRefusal = @splat(null),
    image_refusal_next: usize = 0,
    epoch: u64 = 0,
    session_id: u64 = 0,
    kernel: ?runtime.c.struct_xrt_auxv = null,
    revision: u64 = 0,
    next_id: u64 = 1,
    query: u64 = 0,

    pub fn invalidate(self: *State) void {
        self.kernel = null;
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            entry.retired = true;
            entry.verify_pending = false;
            c.xmd_cancel(entry.job);
        };
        self.revision +%= 1;
    }
    pub fn deinit(self: *State) void {
        self.invalidate();
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            entry.deinit();
            slot.* = null;
        };
    }
    fn synchronize(self: *State, session: *Session) void {
        self.session_id = session.id;
        const snapshot_ = session.target.snapshot();
        const epoch = snapshot_.image_epoch;
        if (self.epoch != epoch) {
            self.invalidate();
            self.epoch = epoch;
        }
        if (snapshot_.state == .idle or snapshot_.state == .exited) {
            for (self.entries) |slot| if (slot) |entry| {
                if (!entry.retired) {
                    self.invalidate();
                    break;
                }
            };
        }
    }
    fn placement(self: *State, session: *Session) !runtime.c.struct_xrt_auxv {
        self.synchronize(session);
        if (self.kernel == null) {
            var kernel: runtime.c.struct_xrt_auxv = undefined;
            try runtime.check(runtime.c.xrt_target_auxv(session.target.handle, &kernel));
            self.kernel = kernel;
        }
        return self.kernel.?;
    }
    pub fn mainPhdr(self: *State, session: *Session) !u64 {
        return (try self.placement(session)).main_phdr;
    }
    fn get(self: *State, session: *Session, kind: Kind, region: Region) !*Entry {
        self.synchronize(session);
        return self.getFor(&session.modules, kind, region, .sections, .frame);
    }
    /// Rebound by the live session before module queries. Jobs remain owned
    /// here, never by a temporary module reader or a background worker.
    pub fn bind(self: *State, session: *Session) void {
        self.synchronize(session);
        // Generic asynchronous transfer belongs to the remote transport only.
        // Local image reads retain their synchronous contract.
        if (!runtime.c.xrt_target_is_remote(session.target.handle)) {
            session.modules.image_jobs = null;
            return;
        }
        session.modules.image_jobs = .{ .context = self, .prepare = prepareFile, .release = releaseFile };
    }
    fn getFor(self: *State, modules: *Modules, kind: Kind, region: Region, coverage: Coverage, why: Modules.Reason) !*Entry {
        const complete_file = coverage == .full;
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            const old = entry.region;
            if (!entry.retired and entry.kind == kind and entry.coverage == coverage and entry.epoch == self.epoch and
                ((kind == .image and coverage == .full) or (old.start == region.start and old.end == region.end and old.offset == region.offset)) and
                old.inode == region.inode and old.device_major == region.device_major and old.device_minor == region.device_minor)
            {
                entry.touched_query = self.query;
                return entry;
            }
        };
        if (kind == .image) for (self.image_refusals) |slot| if (slot) |old| {
            const r = old.region;
            if (old.epoch != self.epoch or r.start != region.start or r.end != region.end or r.offset != region.offset or
                r.inode != region.inode or r.device_major != region.device_major or r.device_minor != region.device_minor) continue;
            // Cap refusals hold for the epoch; the total may have freed up since.
            const image_budget = @import("../binary/snapshot.zig");
            const reason = if (old.reason.which == .remote or old.reason.which == .image) old.reason else if (old.size > image_budget.remaining() and !modules.sharesRemoteImage(old.identity, coverage)) image_budget.refusal(old.size) else break;
            if (complete_file) modules.refusal = reason else modules.refuseImage(region, reason);
            return error.BinarySnapshotLimit;
        };
        if (kind == .unwind) {
            try self.reserveUnwind(runtime.c.xrt_target_is_remote(modules.target), runtime.c.xrt_target_file_slots(modules.target));
        } else {
            var count: usize = 0;
            for (self.entries) |slot| if (slot) |entry| {
                if (entry.kind == kind) count += 1;
            };
            if (count >= 2) {
                // A parsed module owns its mapping. Finished image workers
                // need not pin file handles and starve later source/name scans.
                if (kind == .image) for (&self.entries) |*item| {
                    if (item.*) |*entry| {
                        if (entry.kind != .image or c.xmd_join(entry.job) != c.XBO_OK) continue;
                        var progress: c.struct_xmd_snapshot = undefined;
                        c.xmd_poll(entry.job, &progress);
                        if (progress.state != c.XMD_READY) continue;
                        entry.deinit();
                        item.* = null;
                        count -= 1;
                        break;
                    }
                };
                if (count >= 2) return if (kind == .image) error.DebugMetadataPending else error.DebugMetadataJobLimit;
            }
        }
        const slot = for (&self.entries) |*item| {
            if (item.* == null) break item;
        } else return error.DebugMetadataJobLimit;
        const path = try A.dupeZ(u8, region.path);
        errdefer A.free(path);
        const request = c.struct_xrt_file_request{ .kind = c.XRT_FILE_MAPPED, .mapping = .{ .start = region.start, .end = region.end, .offset = region.offset, .inode = region.inode, .device_major = region.device_major, .device_minor = region.device_minor, .path = path } };
        var view: ?*c.struct_xrt_file_view = null;
        try modules.openFileView(@ptrCast(&request), @ptrCast(&view));
        errdefer _ = c.xrt_file_view_close(view);
        const local = c.xrt_file_view_remote(view) == 0;
        const identity = c.xrt_file_view_identity(view).*;
        if (kind == .image) {
            const image_budget = @import("../binary/snapshot.zig");
            const limit = runtime.c.xrt_target_remote_image_limit(modules.target);
            if (identity.size <= 0) return error.BinaryIdentityUnavailable;
            const size: u64 = @intCast(identity.size);
            // Container budgets apply to one ELF entry, not to the ZIP. The
            // bounded worker preserves it for the existing entry parser.
            var magic: [4]u8 = undefined;
            if (complete_file and size >= magic.len) try runtime.check(@intCast(c.xrt_file_view_read(view, 0, &magic, magic.len)));
            const container = complete_file and size >= magic.len and std.mem.eql(u8, &magic, "PK\x03\x04");
            const shared = modules.sharesRemoteImage(@bitCast(identity), coverage);
            if (complete_file and !container) try modules.checkImageAllowance(region, size, why, shared);
            const refused: ?image_budget.Refusal = if (size > limit)
                .{ .size = size, .limit = limit, .which = .remote, .older_agent = limit < image_budget.remote_image_limit }
            else if (!container and (size > image_budget.per_image_limit or (!shared and size > image_budget.remaining()))) image_budget.refusal(size) else null;
            if (refused) |reason| {
                // Region.path is borrowed from the map snapshot; matching uses identity fields only.
                self.image_refusals[self.image_refusal_next] = .{ .epoch = self.epoch, .region = region, .size = size, .identity = @bitCast(identity), .reason = reason };
                self.image_refusal_next = (self.image_refusal_next + 1) % self.image_refusals.len;
                if (complete_file) modules.refusal = reason else modules.refuseImage(region, reason);
                return error.BinarySnapshotLimit;
            }
            // Another owner holds this version in full. The synchronous open
            // answers from those bytes after FILE_OPEN, so no worker copies it.
            if (complete_file and !container and shared and size <= runtime.c.XRT_REMOTE_SYNC_IMAGE_LIMIT) return error.RemoteImageHeld;
        }
        // The worker notices a change only while its view is open. A view
        // reopened over the agent must match the identity stored for this file.
        try modules.rememberMetadataIdentity(region, @bitCast(identity));
        var job: ?*c.struct_xmd_job = null;
        const status = if (kind == .image and complete_file)
            (if (modules.cachedTypes(region) != null) c.xmd_start_file_cached(view, &job) else c.xmd_start_file(view, &job))
        else if (kind == .image and coverage == .types)
            c.xmd_start_types(view, &job)
        else if (kind == .image)
            c.xmd_start_image(view, &job)
        else if (kind == .javascript)
            c.xmd_start_javascript_cached(view, &job)
        else if (local and identity.size > 0 and identity.size <= c.XMD_LOCAL_CFI_LIMIT)
            c.xmd_start_cfi_local(view, &job)
        else
            c.xmd_start_cfi(view, &job);
        try check(status, null);
        slot.* = .{ .id = self.next_id, .session_id = self.session_id, .kind = kind, .coverage = coverage, .epoch = self.epoch, .region = region, .path = path, .job = job.?, .touched_query = self.query };
        slot.*.?.region.path = path;
        self.next_id +|= 1;
        self.revision +%= 1;
        return &slot.*.?;
    }
    fn prepareFile(context: *anyopaque, modules: *Modules, region: Region, why: Modules.Reason) !c_int {
        const self: *State = @ptrCast(@alignCast(context));
        if (modules.cachedTypes(region) != null) {
            // A cancelled upgrade stays cancelled until retried; it does not
            // take the language view's projection with it.
            for (self.entries) |slot| if (slot) |full| {
                const old = full.region;
                if (full.retired or full.epoch != self.epoch or full.kind != .image or full.coverage != .full or old.inode != region.inode or
                    old.device_major != region.device_major or old.device_minor != region.device_minor) continue;
                var state: c.struct_xmd_snapshot = undefined;
                c.xmd_poll(full.job, &state);
                if (state.state == c.XMD_CANCELLED) return error.DebugMetadataCancelled;
            };
        }
        if (modules.cachedTypes(region) != null) {
            modules.releaseTypesForUpgrade(region);
            // The worker's descriptor also pins the projection's pages.
            for (&self.entries) |*slot| if (slot.*) |*entry| {
                const old = entry.region;
                if (entry.retired or entry.epoch != self.epoch or entry.kind != .image or entry.coverage != .types or old.inode != region.inode or
                    old.device_major != region.device_major or old.device_minor != region.device_minor) continue;
                entry.deinit();
                slot.* = null;
                self.revision +%= 1;
            };
        }
        const entry = self.getFor(modules, .image, region, .full, why) catch |err| switch (err) {
            error.SymbolDiscoveryPending, error.SymbolDiscoveryBudgetExceeded => return error.DebugMetadataPending,
            else => return err,
        };
        var progress: c.struct_xmd_snapshot = undefined;
        c.xmd_poll(entry.job, &progress);
        if (progress.state == c.XMD_CANCELLED) return error.DebugMetadataCancelled;
        var fd: c_int = -1;
        try check(c.xmd_image_result(entry.job, &fd), if (progress.reason) |reason| std.mem.span(reason) else null);
        return fd;
    }
    fn releaseFile(context: *anyopaque, region: Region) void {
        const self: *State = @ptrCast(@alignCast(context));
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            const old = entry.region;
            if (entry.retired or entry.epoch != self.epoch or entry.kind != .image or entry.coverage != .full or old.inode != region.inode or
                old.device_major != region.device_major or old.device_minor != region.device_minor) continue;
            // The borrower has mapped the sealed descriptor or refused it.
            // Do not retain uncharged backing after the snapshot is released.
            entry.deinit();
            slot.* = null;
            self.revision +%= 1;
            return;
        };
    }
    /// Only the kernel-proved main image takes the runtime's full-image budget.
    /// The context adapter checks PHDR before entering this asynchronous path.
    pub fn mainImage(self: *State, session: *Session, address: u64, why: enum { frame, sweep }) !*@import("modules.zig").Module {
        const region = try mapped(session, address);
        if (session.modules.cachedTypes(region) != null) return session.modules.load(region, if (why == .frame) .frame else .sweep);
        const entry = try self.get(session, .image, region);
        var progress: c.struct_xmd_snapshot = undefined;
        c.xmd_poll(entry.job, &progress);
        if (progress.state == c.XMD_CANCELLED) return error.DebugMetadataCancelled;
        var fd: c_int = -1;
        try check(c.xmd_image_result(entry.job, &fd), if (progress.reason) |reason| std.mem.span(reason) else null);
        return session.modules.loadMainImage(region, fd, if (why == .frame) .frame else .sweep);
    }
    /// Layout-only projection. Ordinary module queries never see this image.
    pub fn mainTypes(self: *State, session: *Session, address: u64) !*@import("modules.zig").Module {
        self.synchronize(session);
        const region = try mapped(session, address);
        if (session.modules.cachedTypes(region)) |module| {
            if (!module.preparing_full) return module;
            // An upgrade cancelled or refused after the projection was given
            // up: rebuild the projection into the same module slot (below).
            const rebuilding = for (self.entries) |slot| {
                const types = slot orelse continue;
                if (!types.retired and types.epoch == self.epoch and types.kind == .image and types.coverage == .types and types.region.inode == region.inode and
                    types.region.device_major == region.device_major and types.region.device_minor == region.device_minor) break true;
            } else false;
            if (!rebuilding) if (session.modules.load(region, .frame)) |full| return full else |err| switch (err) {
                error.DebugMetadataCancelled => {
                    // Cancellation is visible before the worker finishes its
                    // last RPC. Rebuild only after it releases the cache lease;
                    // try-join yields Pending, never blocks the owner.
                    for (self.entries) |slot| if (slot) |full| {
                        if (!full.retired and full.epoch == self.epoch and full.kind == .image and full.coverage == .full and full.region.inode == region.inode and
                            full.region.device_major == region.device_major and full.region.device_minor == region.device_minor)
                        {
                            try check(c.xmd_join(full.job), null);
                            // A ready result can be cancelled before adoption;
                            // validate retires its lease on that path too.
                            check(c.xmd_validate(full.job), null) catch |cause| {
                                if (cause != error.DebugMetadataCancelled) return cause;
                            };
                        }
                    };
                },
                error.BinarySnapshotLimit => {},
                else => return err,
            };
        }
        const entry = try self.getFor(&session.modules, .image, region, .types, .frame);
        var progress: c.struct_xmd_snapshot = undefined;
        c.xmd_poll(entry.job, &progress);
        if (progress.state == c.XMD_CANCELLED) return error.DebugMetadataCancelled;
        var fd: c_int = -1;
        try check(c.xmd_image_result(entry.job, &fd), if (progress.reason) |reason| std.mem.span(reason) else null);
        return session.modules.loadTypes(region, fd);
    }
    /// Drops the oldest finished unwind job from an earlier query, closing
    /// its agent file view. False when no such job exists.
    pub fn releaseIdleUnwind(self: *State) bool {
        var oldest: ?usize = null;
        for (self.entries, 0..) |slot, i| if (slot) |entry| {
            if (entry.kind != .unwind or entry.touched_query == self.query or c.xmd_join(entry.job) != c.XBO_OK) continue;
            if (oldest == null or entry.touched_query < self.entries[oldest.?].?.touched_query) oldest = i;
        };
        const victim = oldest orelse return false;
        self.entries[victim].?.deinit();
        self.entries[victim] = null;
        self.revision +%= 1;
        return true;
    }
    fn reserveUnwind(self: *State, remote: bool, slots: u32) !void {
        const limit: usize = if (remote) remoteUnwindLimit(slots) else max_unwind_jobs;
        while (true) {
            var used: u64 = 0;
            var count: usize = 0;
            var free = false;
            var waiting = false;
            for (self.entries) |slot| {
                const entry = slot orelse {
                    free = true;
                    continue;
                };
                if (entry.kind != .unwind) continue;
                count += 1;
                if (c.xmd_join(entry.job) == c.XBO_OK) {
                    var progress: c.struct_xmd_snapshot = undefined;
                    c.xmd_poll(entry.job, &progress);
                    used +|= progress.unwind.retained_bytes;
                } else {
                    // Reserve the maximum while a worker can still allocate.
                    used +|= c.XCF_MAX_BYTES;
                    waiting = true;
                }
            }
            if (free and count < limit and used <= unwind_budget - c.XCF_MAX_BYTES) return;
            var oldest: ?usize = null;
            for (self.entries, 0..) |slot, i| if (slot) |entry| {
                // Finished jobs from earlier queries are eligible whether the
                // file view is local or remote. This query's jobs stay.
                if (entry.kind != .unwind or entry.touched_query == self.query or c.xmd_join(entry.job) != c.XBO_OK) continue;
                if (oldest == null or entry.touched_query < self.entries[oldest.?].?.touched_query) oldest = i;
            };
            const victim = oldest orelse return if (waiting) error.DebugMetadataPending else if (count >= limit) error.DebugMetadataJobLimit else error.DebugMetadataBudgetLimit;
            // Unwind results contain owned register values, never decoder
            // pointers. Destroy libdw before the backing job bytes.
            self.entries[victim].?.deinit();
            self.entries[victim] = null;
            self.revision +%= 1;
        }
    }
    fn mapped(session: *Session, address: u64) !Region {
        try session.refreshMaps();
        for (session.modules.regions.items) |region| {
            if (address >= region.start and address < region.end and region.inode != 0 and std.mem.startsWith(u8, region.path, "/")) return region;
        }
        return error.DebugMetadataMappingUnavailable;
    }
    fn bias(_: *State, session: *Session, entry: *Entry) !u64 {
        if (entry.bias) |value| return value;
        const page = runtime.c.xrt_target_page_size(session.target.handle);
        if (page <= 0) return error.DebugMetadataMappingUnavailable;
        const r = entry.region;
        const permissions: c_uint = (if (r.permissions[1] == 'w') @as(c_uint, 2) else 0) | (if (r.permissions[2] == 'x') @as(c_uint, 1) else 0);
        var value: u64 = 0;
        try check(c.xmd_mapping_bias(entry.job, r.start, r.end, r.offset, @intCast(page), permissions, &value), null);
        entry.bias = value;
        return value;
    }
    pub fn beginQuery(self: *State) void {
        self.query +%= 1;
        if (self.query == 0) {
            for (&self.entries) |*slot| if (slot.*) |*entry| {
                entry.checked_query = 0;
                entry.touched_query = 0;
            };
            self.query = 1;
        }
    }
    pub fn unwind(self: *State, session: *Session, a: std.mem.Allocator, pc: u64, registers: loc.RegisterSet) !info.Unwind {
        const region = try mapped(session, pc);
        const entry = try self.get(session, .unwind, region);
        if (entry.cfi == null or entry.checked_query != self.query) {
            var bytes: [*c]u8 = null;
            var length: usize = 0;
            var snapshot_: c.struct_xmd_snapshot = undefined;
            c.xmd_poll(entry.job, &snapshot_);
            try check(c.xmd_cfi_result(entry.job, &bytes, &length), if (snapshot_.reason) |why| std.mem.span(why) else null);
            c.xmd_poll(entry.job, &snapshot_);
            if (snapshot_.machine != @intFromEnum(session.target.arch()) or snapshot_.address_size != session.target.arch().addressBytes() or
                (snapshot_.little_endian != 0) != (session.target.arch().endian() == .little)) return error.DebugMetadataArchitectureMismatch;
            if (entry.cfi == null) entry.cfi = try info.Cfi.init(session.target.arch(), bytes[0..length]);
            // The decoder borrows the copied unwind bytes, not the file view.
            // Releasing frees the agent slot; the next query still revalidates
            // by reopening the same file version.
            c.xmd_release_view(entry.job);
            entry.checked_query = self.query;
        }
        const load_bias = try self.bias(session, entry);
        if (pc < load_bias) return error.InvalidAddress;
        return entry.cfi.?.unwind(a, pc - load_bias, .{ .registers = registers, .load_bias = load_bias, .insn_pac_mask = session.target.pacInsnMask(), .user = session, .read = readUnwind });
    }
    pub fn javascript(self: *State, session: *Session) !c.struct_xjs_layout {
        if (session.target.snapshot().state != .stopped) return error.NotStopped;
        if (session.target.arch() != .x86_64) return error.JavaScriptArchitectureUnsupported;
        const kernel = try self.placement(session);
        const entry = try self.get(session, .javascript, try mapped(session, kernel.main_phdr));
        var snapshot_: c.struct_xmd_snapshot = undefined;
        c.xmd_poll(entry.job, &snapshot_);
        if (snapshot_.state != c.XMD_READY) {
            try check(snapshot_.status, if (snapshot_.reason) |why| std.mem.span(why) else null);
            return error.DebugMetadataPending;
        }
        try check(c.xmd_join(entry.job), null);
        const generation = session.target.snapshot().generation;
        if (entry.verified_generation == generation) {
            try check(c.xmd_validate(entry.job), null);
            if (entry.verify_error) |why| return namedError(why);
            if (entry.layout) |layout| return layout;
        }
        entry.layout = null;
        entry.verify_error = null;
        entry.verify_generation = generation;
        entry.verify_pending = true;
        return error.DebugMetadataPending;
    }
    pub fn poll(self: *State, session: *Session) void {
        self.synchronize(session);
        var reaped = false;
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            if (entry.retired) {
                // A close may be one remote RPC. Retire at most one per tick.
                if (!reaped and c.xmd_join(entry.job) == c.XBO_OK) {
                    entry.deinit();
                    slot.* = null;
                    reaped = true;
                }
                continue;
            }
            var snapshot_: c.struct_xmd_snapshot = undefined;
            c.xmd_poll(entry.job, &snapshot_);
            if (snapshot_.state != entry.last_state) {
                entry.last_state = snapshot_.state;
                self.revision +%= 1;
            }
            if (!entry.verify_pending or session.target.snapshot().state != .stopped) continue;
            if (entry.verify_generation != session.target.snapshot().generation) {
                entry.verify_pending = false;
                continue;
            }
            if (snapshot_.state != c.XMD_READY or c.xmd_join(entry.job) != c.XBO_OK) continue;
            const load_bias = self.bias(session, entry) catch |err| {
                entry.verify_error = @errorName(err);
                entry.verify_pending = false;
                entry.verified_generation = entry.verify_generation;
                self.revision +%= 1;
                continue;
            };
            var reader = c.struct_xjs_reader{ .context = session, .read = readJavaScript };
            var layout: c.struct_xjs_layout = undefined;
            var why: [*c]const u8 = null;
            const status = c.xmd_verify_javascript(entry.job, load_bias, entry.verify_generation, &reader, &layout, &why);
            if (status == c.XBO_AGAIN) continue;
            entry.verify_pending = false;
            entry.verified_generation = entry.verify_generation;
            if (status == c.XBO_OK) entry.layout = layout else entry.verify_error = if (why != null) std.mem.span(why) else "JavaScriptMetadataUnavailable";
            self.revision +%= 1;
        };
    }
    pub fn cancel(self: *State, id: u64) !void {
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            if (entry.retired or entry.id != id) continue;
            c.xmd_cancel(entry.job);
            entry.verify_pending = false;
            entry.layout = null;
            entry.checked_query = 0;
            self.revision +%= 1;
            return;
        };
        return error.UnknownMetadataJob;
    }
    pub fn retry(self: *State, id: u64) !void {
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            if (entry.retired or entry.id != id) continue;
            c.xmd_cancel(entry.job);
            entry.retired = true;
            entry.verify_pending = false;
            self.revision +%= 1;
            return;
        };
        return error.UnknownMetadataJob;
    }
    pub fn snapshot(self: *const State) Snapshot {
        var out: Snapshot = .{};
        for (self.entries) |slot| if (slot) |entry| {
            if (entry.retired) continue;
            var progress: c.struct_xmd_snapshot = undefined;
            c.xmd_poll(entry.job, &progress);
            const state = if (entry.verify_error != null) "failed" else if (entry.verify_pending) "verifying" else switch (progress.state) {
                c.XMD_PREPARING => "preparing",
                c.XMD_SYMBOLS => "symbols",
                c.XMD_CHECKING => "dwarf",
                c.XMD_UNWIND => "unwind",
                c.XMD_INDEXING => "indexing",
                c.XMD_LOOKUP => "lookup",
                c.XMD_IMAGE => "image",
                c.XMD_READY => "ready",
                c.XMD_CANCELLED => "cancelled",
                else => "failed",
            };
            // Up to 66 rows fit the bounded MCP reply even with escaped paths.
            // Full mapping paths remain available through paged list_modules.
            var path_end = @min(entry.path.len, 512);
            while (path_end < entry.path.len and path_end > 0 and entry.path[path_end] & 0xc0 == 0x80) path_end -= 1;
            // Report the creation stamp, not the session displaying this row:
            // a mistakenly inherited job must retain its original owner.
            out.items[out.count] = .{ .id = entry.id, .session_id = entry.session_id, .image_epoch = entry.epoch, .kind = entry.kind, .image = entry.path[0..path_end], .image_truncated = path_end != entry.path.len, .state = state, .reason = entry.verify_error orelse if (progress.reason) |why| std.mem.span(why) else null, .source_bytes = progress.source_bytes, .source_reads = progress.source_reads, .source_size = progress.object.source_size, .units = if (progress.state == c.XMD_INDEXING) progress.index.units else progress.scan.dwarf.units, .dies = if (progress.state == c.XMD_INDEXING) progress.index.dies else progress.scan.dwarf.dies, .retained_unwind_bytes = progress.unwind.retained_bytes, .cached_bytes = progress.cache_bytes, .index_file_bytes = progress.index.file_bytes, .candidate_units = progress.candidate_units, .accelerator_hits = progress.accelerator_hits, .image_bytes = progress.image_bytes, .image_total = progress.image_total };
            out.count += 1;
        };
        return out;
    }
};
fn readUnwind(ptr: *anyopaque, address: u64, out: []u8) !usize {
    const session: *Session = @ptrCast(@alignCast(ptr));
    return session.target.readMemory(address, out);
}
fn readJavaScript(ptr: ?*anyopaque, address: u64, out: ?*anyopaque, size: usize) callconv(.c) c_int {
    const session: *Session = @ptrCast(@alignCast(ptr.?));
    const bytes: [*]u8 = @ptrCast(out.?);
    return if ((session.target.readMemory(address, bytes[0..size]) catch return -1) == size) 0 else -1;
}
fn namedError(name: []const u8) anyerror {
    inline for (.{ error.DebugMetadataBuildIdLimit, error.DebugMetadataBuildIdUnavailable, error.DebugMetadataCacheUnavailable, error.DebugMetadataIndexUnavailable, error.DebugMetadataIndexMalformed, error.DebugMetadataIndexLimit, error.DebugMetadataCacheDirectoryUnavailable, error.DebugMetadataCacheBusy, error.DebugMetadataCacheQuota, error.DebugMetadataCancelled, error.DebugMetadataFileChanged, error.DebugMetadataLimit, error.DebugMetadataOutOfMemory, error.DebugMetadataUnavailable, error.DebugUnwindLimit, error.DebugUnwindMalformed, error.DebugUnwindUnavailable, error.JavaScriptBuildIdMismatch, error.JavaScriptBuildIdUnavailable, error.JavaScriptCompressedPointersUnsupported, error.JavaScriptDwarfConstantUnsupported, error.JavaScriptDwarfDepthLimit, error.JavaScriptDwarfFileChanged, error.JavaScriptDwarfLayoutMismatch, error.JavaScriptDwarfLimit, error.JavaScriptDwarfMalformed, error.JavaScriptDwarfPending, error.JavaScriptDwarfUnavailable, error.JavaScriptDwarfUnitLimit, error.JavaScriptDwarfWorkLimit, error.JavaScriptImageUnsupported, error.JavaScriptInvalidAddress, error.JavaScriptMetadataCancelled, error.JavaScriptMetadataFileChanged, error.JavaScriptMetadataInconsistent, error.JavaScriptMetadataMismatch, error.JavaScriptMetadataPending, error.JavaScriptMetadataUnavailable, error.JavaScriptRuntimeUnavailable, error.JavaScriptVersionMismatch, error.JavaScriptVersionUnavailable, error.JavaScriptVersionUnsupported }) |err| {
        if (std.mem.eql(u8, name, @errorName(err))) return err;
    }
    return error.DebugMetadataUnavailable;
}
fn check(status: c_uint, reason: ?[]const u8) !void {
    if (status == c.XBO_OK) return;
    if (status == c.XBO_AGAIN) return error.DebugMetadataPending;
    if (reason) |name| return namedError(name);
    return switch (status) {
        c.XBO_AGAIN => error.DebugMetadataPending,
        c.XBO_CANCELLED => error.DebugMetadataCancelled,
        c.XBO_CHANGED => error.DebugMetadataFileChanged,
        c.XBO_LIMIT => error.DebugMetadataLimit,
        c.XBO_NOMEM => error.OutOfMemory,
        c.XBO_MALFORMED => error.DebugMetadataMalformed,
        c.XBO_NOT_FOUND => error.DebugMetadataUnavailable,
        else => error.DebugMetadataUnavailable,
    };
}

test "remote unwind budget keeps file-slot headroom" {
    try std.testing.expectEqual(@as(usize, 16), remoteUnwindLimit(0));
    try std.testing.expectEqual(@as(usize, 24), remoteUnwindLimit(32));
    try std.testing.expectEqual(@as(usize, 8), remoteUnwindLimit(16));
    try std.testing.expectEqual(@as(usize, 4), remoteUnwindLimit(9));
    try std.testing.expectEqual(@as(usize, 4), remoteUnwindLimit(8));
    try std.testing.expectEqual(@as(usize, 2), remoteUnwindLimit(4));
    try std.testing.expectEqual(@as(usize, 1), remoteUnwindLimit(1));
    try std.testing.expectEqual(@as(usize, 64), remoteUnwindLimit(72));
    try std.testing.expectEqual(@as(usize, 64), remoteUnwindLimit(80));
}
