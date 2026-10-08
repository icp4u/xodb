//! Session lifetimes and presentation over the C metadata workers.
const std = @import("std");
const c = @import("../c.zig").api;
const runtime = @import("../target/runtime.zig");
const Session = @import("session.zig").Session;
const Region = @import("modules.zig").Region;
const info = @import("../debug/info.zig");
const loc = @import("../debug/location.zig");
const A = std.heap.page_allocator;
const Kind = enum { javascript, unwind };
const Entry = struct {
    id: u64,
    kind: Kind,
    epoch: u64,
    region: Region,
    path: [:0]u8,
    job: *c.struct_xmd_job,
    retired: bool = false,
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
    kind: Kind,
    image: []const u8,
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
};
pub const Snapshot = struct {
    items: [6]JobStatus = undefined,
    count: usize = 0,
    pub fn jsonStringify(self: Snapshot, writer: anytype) !void {
        try writer.write(self.items[0..self.count]);
    }
};
pub const State = struct {
    entries: [6]?Entry = @splat(null),
    epoch: u64 = 0,
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
    fn get(self: *State, session: *Session, kind: Kind, region: Region) !*Entry {
        self.synchronize(session);
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            const old = entry.region;
            if (!entry.retired and entry.kind == kind and entry.epoch == self.epoch and
                old.start == region.start and old.end == region.end and old.offset == region.offset and
                old.inode == region.inode and old.device_major == region.device_major and old.device_minor == region.device_minor)
                return entry;
        };
        var unwind_count: usize = 0;
        for (self.entries) |slot| if (slot) |entry| {
            if (!entry.retired and entry.kind == .unwind) unwind_count += 1;
        };
        if (kind == .unwind and unwind_count == 4) return error.DebugMetadataJobLimit;
        const slot = for (&self.entries) |*item| {
            if (item.* == null) break item;
        } else return error.DebugMetadataJobLimit;
        const path = try A.dupeZ(u8, region.path);
        errdefer A.free(path);
        const request = c.struct_xrt_file_request{ .kind = c.XRT_FILE_MAPPED, .mapping = .{ .start = region.start, .end = region.end, .offset = region.offset, .inode = region.inode, .device_major = region.device_major, .device_minor = region.device_minor, .path = path } };
        var view: ?*c.struct_xrt_file_view = null;
        try runtime.check(@intCast(c.xrt_target_file_view_open(@ptrCast(session.target.handle), &request, &view)));
        errdefer _ = c.xrt_file_view_close(view);
        var job: ?*c.struct_xmd_job = null;
        const status = if (kind == .javascript) c.xmd_start_javascript_cached(view, &job) else c.xmd_start_cfi(view, &job);
        try check(status, null);
        slot.* = .{ .id = self.next_id, .kind = kind, .epoch = self.epoch, .region = region, .path = path, .job = job.? };
        slot.*.?.region.path = path;
        self.next_id +|= 1;
        self.revision +%= 1;
        return &slot.*.?;
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
            entry.checked_query = self.query;
        }
        const load_bias = try self.bias(session, entry);
        if (pc < load_bias) return error.InvalidAddress;
        return entry.cfi.?.unwind(a, pc - load_bias, .{ .registers = registers, .load_bias = load_bias, .user = session, .read = readUnwind });
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
                c.XMD_READY => "ready",
                c.XMD_CANCELLED => "cancelled",
                else => "failed",
            };
            out.items[out.count] = .{ .id = entry.id, .kind = entry.kind, .image = entry.path, .state = state, .reason = entry.verify_error orelse if (progress.reason) |why| std.mem.span(why) else null, .source_bytes = progress.source_bytes, .source_reads = progress.source_reads, .source_size = progress.object.source_size, .units = if (progress.state == c.XMD_INDEXING) progress.index.units else progress.scan.dwarf.units, .dies = if (progress.state == c.XMD_INDEXING) progress.index.dies else progress.scan.dwarf.dies, .retained_unwind_bytes = progress.unwind.retained_bytes, .cached_bytes = progress.cache_bytes, .index_file_bytes = progress.index.file_bytes, .candidate_units = progress.candidate_units, .accelerator_hits = progress.accelerator_hits };
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
