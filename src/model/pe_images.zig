//! Session-owned PE file metadata, validated against a stopped loaded image.
const std = @import("std");
const runtime = @import("../target/runtime.zig");
const rt = runtime.c;
const c = @import("../c.zig").api;
const Source = @import("../binary/mapped_file.zig").Source;
const max_entries = 1024;
const max_jobs = 256;
const byte_limit = 256 * 1024 * 1024;
const reserve_bytes = c.XPE_JOB_MAX_BYTES;

const File = struct {
    identity: c.struct_xrt_file_identity,
    job: ?*c.struct_xpe_job = null,
    retained: u64 = 0,
    used: u64 = 0,
    failure: ?anyerror = null,
};
pub const Entry = struct {
    start: u64,
    end: u64,
    inode: u64,
    device_major: u64,
    device_minor: u64,
    path: [:0]const u8,
    file: *File,
    source: Source,
    id: u64 = 0,
    verified_revision: u64 = 0,
    pub fn image(self: *const Entry) ?*c.struct_xpe_image {
        return if (self.file.job) |job| c.xpe_job_image(job) else null;
    }
    pub fn pdb(self: *const Entry) ?*const c.struct_xpdb {
        const job = self.file.job orelse return null;
        check(c.xpe_job_validate(job)) catch return null;
        return c.xpe_job_pdb(job);
    }
    pub fn sourceAt(self: *const Entry, a: std.mem.Allocator, address: u64) !@import("../debug/info.zig").Site {
        if (address < self.start or address - self.start > std.math.maxInt(u32)) return error.InvalidAddress;
        const symbols = self.pdb() orelse {
            const job = self.file.job orelse return error.SymbolDiscoveryPending;
            const status = std.mem.span(c.xpe_job_pdb_status(job));
            if (std.mem.eql(u8, status, "mismatch")) return error.PePdbIdentityMismatch;
            if (std.mem.eql(u8, status, "changed")) return error.PePdbChanged;
            if (std.mem.eql(u8, status, "unsupported")) return error.PePdbUnsupported;
            if (std.mem.eql(u8, status, "malformed")) return error.PePdbMalformed;
            if (std.mem.eql(u8, status, "limit")) return error.PePdbLimit;
            return error.PePdbUnavailable;
        };
        const line = c.xpdb_line_at(symbols, @intCast(address - self.start)) orelse return error.NoSourceLocation;
        return .{ .path = try a.dupe(u8, std.mem.span(line.*.path)), .line = line.*.line, .column = line.*.column,
            .address = try std.math.add(u64, self.start, line.*.rva), .is_statement = line.*.statement != 0,
            .prologue_end = false, .discriminator = 0 };
    }
    pub fn contains(self: *const Entry, address: u64) bool {
        const image_ = self.image() orelse return false;
        if (address < self.start or address - self.start >= c.xpe_info(image_).*.image_size) return false;
        const rva = address - self.start;
        for (0..c.xpe_info(image_).*.section_count) |i| {
            const section = c.xpe_section(image_, @intCast(i)).*;
            if (rva >= section.rva and rva - section.rva < @max(section.virtual_size, section.raw_size)) return true;
        }
        return rva < c.xpe_info(image_).*.headers_size;
    }
    pub fn unwind(self: *Entry, target: *const rt.struct_xrt_target, pc: u64, registers: @import("../debug/location.zig").RegisterSet) !@import("../debug/info.zig").Unwind {
        const image_ = self.image() orelse return error.SymbolDiscoveryPending;
        if (rt.xrt_target_is_remote(target)) return error.PeRemoteMetadataUnavailable;
        if (rt.xrt_target_shared_vm(target)) return error.PeSharedVmUnavailable;
        try check(c.xpe_job_validate(self.file.job.?));
        var context = Reader{ .target = target, .base = self.start };
        rt.xrt_target_view(target, &context.expected);
        try context.unchanged();
        const reader = @import("../debug/windows.zig").Reader{ .user = &context, .read = Reader.readBytes };
        const result = try @import("../debug/windows.zig").unwind(image_, self.start, pc, registers, reader, reader);
        try check(c.xpe_job_validate(self.file.job.?));
        try context.unchanged();
        return result;
    }
};
pub const State = struct {
    entries: std.ArrayList(*Entry) = .empty,
    files: std.ArrayList(*File) = .empty,
    pending: ?*File = null,
    bytes: u64 = 0,
    clock: u64 = 0,
    evictions: u64 = 0,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            a.free(entry.path);
            a.destroy(entry);
        }
        self.entries.deinit(a);
        for (self.files.items) |file| {
            if (file.job) |job| c.xpe_job_destroy(job);
            a.destroy(file);
        }
        self.files.deinit(a);
        self.* = .{};
    }
    pub const Snapshot = struct { identity_count: usize = 0, mapping_count: usize = 0, resident_images: usize = 0, retained_bytes: u64 = 0, reserved_bytes: u64 = 0, evictions: u64 = 0, active_worker: bool = false };
    pub fn snapshot(self: *const State) Snapshot {
        var count: usize = 0;
        for (self.files.items) |entry| if (entry.job != null and self.pending != entry) {
            count += 1;
        };
        const reserved = if (self.pending) |entry| entry.retained else 0;
        return .{ .identity_count = self.files.items.len, .mapping_count = self.entries.items.len, .resident_images = count, .retained_bytes = self.bytes - reserved, .reserved_bytes = reserved, .evictions = self.evictions, .active_worker = self.pending != null };
    }
    fn touch(self: *State, entry: *File) void {
        self.clock +|= 1;
        entry.used = self.clock;
    }
    fn trim(self: *State) !void {
        while (true) {
            var count: usize = 0;
            var oldest: ?*File = null;
            for (self.files.items) |entry| {
                if (entry.job == null) continue;
                count += 1;
                if (self.pending == entry) continue;
                if (oldest == null or entry.used < oldest.?.used) oldest = entry;
            }
            if (count < max_jobs and self.bytes <= byte_limit - reserve_bytes) return;
            const victim = oldest orelse return error.PeMetadataBudgetLimit;
            self.evict(victim);
        }
    }
    fn evict(self: *State, victim: *File) void {
        c.xpe_job_destroy(victim.job.?);
        victim.job = null;
        self.bytes -= victim.retained;
        victim.retained = 0;
        for (self.entries.items) |entry| if (entry.file == victim) {
            entry.verified_revision = 0;
        };

        self.evictions +|= 1;
    }
    /// Nonblocking publication; the worker owns file I/O until join succeeds.
    pub fn poll(self: *State) void {
        const entry = self.pending orelse return;
        const job = entry.job.?;
        const joined = c.xpe_job_join(job);
        if (joined == 0) return;
        self.pending = null;
        self.bytes -= entry.retained;
        entry.retained = 0;
        if (joined < 0) {
            entry.failure = error.PeMetadataUnavailable;
            return;
        }
        var progress: c.struct_xpe_job_snapshot = undefined;
        c.xpe_job_poll(job, &progress);
        check(progress.status) catch |err| {
            entry.failure = err;
            c.xpe_job_destroy(job);
            entry.job = null;
            return;
        };
        _ = c.xpe_job_image(job) orelse {
            entry.failure = error.PeMetadataUnavailable;
            return;
        };
        entry.retained = c.xpe_job_retained_bytes(job);
        self.bytes += entry.retained;
        self.touch(entry);
    }
    fn sameAnchor(entry: *const Entry, region: anytype) bool {
        return entry.start == region.start and entry.end == region.end and entry.inode == region.inode and
            entry.device_major == region.device_major and entry.device_minor == region.device_minor and std.mem.eql(u8, entry.path, region.path);
    }
    pub fn backgroundDeferred(self: *const State, region: anytype) bool {
        for (self.entries.items) |entry| if (sameAnchor(entry, region)) {
            return entry.id != 0 and entry.file.job == null;
        };
        return false;
    }
    /// A parse failure belongs to an exact file identity. A caller that has
    /// proved that identity for the current stop reuses the answer for every
    /// other mapping of the file; `get` would reopen the file to find it.
    pub fn failed(self: *const State, identity: anytype) ?anyerror {
        for (self.files.items) |file| {
            if (std.mem.eql(u8, std.mem.asBytes(&file.identity), std.mem.asBytes(&identity))) return file.failure;
        }
        return null;
    }
    /// Mapping instances share one parsed image for each exact pinned file
    /// identity. Eviction drops the file metadata, retaining instance IDs.
    pub fn get(self: *State, a: std.mem.Allocator, target: ?*rt.struct_xrt_target, region: anytype) !*Entry {
        if (target == null or rt.xrt_target_is_remote(target)) return error.PeRemoteMetadataUnavailable;
        if (region.offset != 0 or region.inode == 0 or region.path.len == 0 or region.path[0] != '/') return error.NotPe;
        self.poll();
        var existing: ?*Entry = null;
        for (self.entries.items) |entry| if (sameAnchor(entry, region)) {
            if (entry.file.failure) |err| return err;
            if (self.pending == entry.file) return error.SymbolDiscoveryPending;
            if (entry.image() != null) {
                try check(c.xpe_job_validate(entry.file.job.?));
                self.touch(entry.file);
                return entry;
            }
            existing = entry;
            break;
        };
        if (self.pending != null) return error.SymbolDiscoveryPending;
        if (existing == null and self.entries.items.len >= max_entries) return error.PeMetadataIdentityLimit;
        const path = try a.dupeZ(u8, region.path);
        defer a.free(path);
        const request = c.struct_xrt_file_request{ .kind = c.XRT_FILE_MAPPED, .mapping = .{
            .start = region.start,
            .end = region.end,
            .offset = 0,
            .inode = region.inode,
            .device_major = region.device_major,
            .device_minor = region.device_minor,
            .path = path,
        } };
        var view: ?*c.struct_xrt_file_view = null;
        try runtime.check(@intCast(c.xrt_target_file_view_open_owner(@ptrCast(target), &request, &view)));
        defer if (view != null) {
            _ = c.xrt_file_view_close(view);
        };
        const identity = c.xrt_file_view_identity(view).*;
        if (existing) |entry| if (!std.meta.eql(entry.file.identity, identity)) {
            entry.file.failure = error.BinaryChangedDuringRead;
            return error.BinaryChangedDuringRead;
        };
        var known: ?*File = null;
        for (self.files.items) |file| if (std.meta.eql(file.identity, identity)) {
            known = file;
            break;
        };
        const file = known orelse blk: {
            if (self.files.items.len >= max_entries) return error.PeMetadataIdentityLimit;
            if (identity.size < 2) return error.NotPe;
            var signature: [2]u8 = undefined;
            try runtime.check(@intCast(c.xrt_file_view_read(view, 0, &signature, signature.len)));
            if (!std.mem.eql(u8, &signature, "MZ")) return error.NotPe;
            const item = try a.create(File);
            errdefer a.destroy(item);
            item.* = .{ .identity = identity };
            try self.files.append(a, item);
            break :blk item;
        };
        if (file.failure) |err| return err;
        const entry = existing orelse blk: {
            const item = try a.create(Entry);
            errdefer a.destroy(item);
            item.* = .{ .start = region.start, .end = region.end, .inode = region.inode, .device_major = region.device_major, .device_minor = region.device_minor, .path = try a.dupeZ(u8, path), .file = file, .source = Source.fromRuntime(@intCast(c.xrt_file_view_source(view))) };
            errdefer a.free(item.path);
            try self.entries.append(a, item);
            break :blk item;
        };
        if (file.job) |job| {
            try check(c.xpe_job_validate(job));
            self.touch(file);
            return entry;
        }
        try self.trim();
        var job: ?*c.struct_xpe_job = null;
        var target_view: rt.struct_xrt_target_view = undefined;
        rt.xrt_target_view(target.?, &target_view);
        try check(c.xpe_job_start(view, target_view.pid, path, &job));
        view = null;
        file.job = job.?;
        file.retained = reserve_bytes;
        self.bytes += reserve_bytes;
        self.pending = file;
        self.touch(file);
        return error.SymbolDiscoveryPending;
    }
    pub fn bind(self: *State, entry: *Entry, target: *const rt.struct_xrt_target, regions: anytype, revision: u64, next_id: *u64) !void {
        if (entry.verified_revision == revision) return;
        const image_ = entry.image() orelse return error.SymbolDiscoveryPending;
        try check(c.xpe_job_validate(entry.file.job.?));
        var context = Reader{ .target = target, .base = entry.start };
        rt.xrt_target_view(target, &context.expected);
        if (context.expected.state != rt.XRT_STOPPED) return error.NotStopped;
        if (rt.xrt_target_shared_vm(target)) return error.PeSharedVmUnavailable;
        const info = c.xpe_info(image_).*;
        _ = std.math.add(u64, entry.start, info.image_size) catch return error.PeImagePlacementMismatch;
        const source = c.struct_xpe_source{ .context = &context, .size = info.image_size, .layout = c.XPE_MEMORY, .read = Reader.read };
        try check(c.xpe_validate_loaded_headers(image_, &source));
        var anchor = false;
        for (regions) |region| if (sameAnchor(entry, region) and region.offset == 0) {
            anchor = true;
            break;
        };
        if (!anchor) return error.PeImagePlacementMismatch;
        try covered(entry, regions, 0, info.headers_size, false);
        for (0..info.section_count) |i| {
            const section = c.xpe_section(image_, @intCast(i)).*;
            const extent = @max(section.virtual_size, section.raw_size);
            if (extent != 0) try covered(entry, regions, section.rva, extent, section.characteristics & 0x20000000 != 0);
        }
        try check(c.xpe_job_validate(entry.file.job.?));
        try context.unchanged();
        if (entry.id == 0) {
            const following = std.math.add(u64, next_id.*, 1) catch return error.PeMetadataIdentityLimit;
            entry.id = next_id.*;
            next_id.* = following;
        }
        entry.verified_revision = revision;
        self.touch(entry.file);
    }
};
fn covered(entry: *const Entry, regions: anytype, rva: u64, size: u64, executable: bool) !void {
    var address = std.math.add(u64, entry.start, rva) catch return error.PeImagePlacementMismatch;
    const end = std.math.add(u64, address, size) catch return error.PeImagePlacementMismatch;
    for (regions) |region| {
        if (region.end <= address) continue;
        if (region.start > address) break;
        const owned_file = region.inode == entry.inode and region.device_major == entry.device_major and region.device_minor == entry.device_minor and std.mem.eql(u8, region.path, entry.path);
        const anonymous = region.inode == 0 and region.path.len == 0;
        if ((!owned_file and !anonymous) or (executable and region.permissions[2] != 'x')) return error.PeImagePlacementMismatch;
        address = @min(end, region.end);
        if (address == end) return;
    }
    return error.PeImagePlacementMismatch;
}
const Reader = struct {
    target: *const rt.struct_xrt_target,
    base: u64,
    expected: rt.struct_xrt_target_view = undefined,
    fn unchanged(self: *const Reader) !void {
        var current: rt.struct_xrt_target_view = undefined;
        rt.xrt_target_view(self.target, &current);
        if (current.state != rt.XRT_STOPPED or current.pid != self.expected.pid or current.generation != self.expected.generation or current.image_epoch != self.expected.image_epoch) return error.PeImageChanged;
    }
    fn readBytes(ptr: *anyopaque, address: u64, out: []u8) !usize {
        const self: *Reader = @ptrCast(@alignCast(ptr));
        try self.unchanged();
        var count: usize = 0;
        try runtime.check(rt.xrt_target_read(self.target, address, out.ptr, out.len, &count));
        try self.unchanged();
        return count;
    }
    fn read(ptr: ?*anyopaque, offset: u64, out: ?*anyopaque, size: usize) callconv(.c) c.enum_xpe_status {
        const self: *Reader = @ptrCast(@alignCast(ptr orelse return c.XPE_MALFORMED));
        self.unchanged() catch return c.XPE_CHANGED;
        const address = std.math.add(u64, self.base, offset) catch return c.XPE_MALFORMED;
        var count: usize = 0;
        const status = rt.xrt_target_read(self.target, address, out, size, &count);
        if (status != rt.XRT_OK or count != size) return c.XPE_IO;
        self.unchanged() catch return c.XPE_CHANGED;
        return c.XPE_OK;
    }
};
pub fn check(status: c.enum_xpe_status) !void {
    return switch (status) {
        c.XPE_OK => {},
        c.XPE_NOT_PE => error.NotPe,
        c.XPE_UNSUPPORTED => error.PeFormatUnsupported,
        c.XPE_MALFORMED => error.PeMetadataMalformed,
        c.XPE_LIMIT => error.PeMetadataLimit,
        c.XPE_IO => error.PeMetadataUnavailable,
        c.XPE_CHANGED => error.PeImageChanged,
        c.XPE_CANCELLED => error.PeMetadataCancelled,
        c.XPE_NOMEM => error.OutOfMemory,
        c.XPE_NOT_FOUND => error.SymbolNotFound,
        else => error.PeMetadataUnavailable,
    };
}

test "PE aliases share parsed identity and eviction reloads only on demand" {
    const native = @cImport({
        @cDefine("_GNU_SOURCE", "1");
        @cInclude("target_internal.h");
        @cInclude("sys/mman.h");
        @cInclude("sys/sysmacros.h");
        @cInclude("sys/stat.h");
    });
    const a = std.testing.allocator;
    const fd = native.memfd_create("shared-pe", native.MFD_CLOEXEC);
    try std.testing.expect(fd >= 0);
    defer _ = native.close(fd);
    const fixture_bytes = @import("../binary/pe_fixture.zig").binary(1);
    try std.testing.expectEqual(@as(isize, fixture_bytes.len), native.write(fd, &fixture_bytes, fixture_bytes.len));
    try std.testing.expectEqual(@as(c_int, 0), native.ftruncate(fd, 4096));
    var st: native.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), native.fstat(fd, &st));
    const path = try std.fmt.allocPrint(a, "/proc/self/fd/{d}", .{fd});
    defer a.free(path);
    var target = std.mem.zeroes(native.struct_xrt_target);
    target.pid = native.getpid();
    target.state = native.XRT_STOPPED;
    defer native.xodb_maps_free(&target.maps);
    var state = State{};
    defer state.deinit(a);
    var addresses: [32]?*anyopaque = @splat(null);
    defer for (addresses) |address| {
        if (address != null) _ = native.munmap(address, 4096);
    };
    var regions: [32]@import("modules.zig").Region = undefined;
    const begun = native.xrt_now();
    for (&addresses, &regions, 0..) |*address, *region, i| {
        address.* = native.mmap(null, 4096, native.PROT_READ, native.MAP_PRIVATE, fd, 0);
        try std.testing.expect(address.* != native.MAP_FAILED);
        target.generation += 1;
        region.* = .{ .start = @intFromPtr(address.*), .end = @intFromPtr(address.*) + 4096, .offset = 0, .inode = st.st_ino, .device_major = native.major(st.st_dev), .device_minor = native.minor(st.st_dev), .permissions = "r--p".*, .path = path };
        const entry = while (true) {
            const result = state.get(a, @ptrCast(&target), region.*) catch |err| {
                if (err != error.SymbolDiscoveryPending) return err;
                if (native.xrt_now() - begun > 5 * std.time.ns_per_s) return error.TestJobTimeout;
                _ = native.usleep(100);
                continue;
            };
            break result;
        };
        entry.id = i + 1;
        try std.testing.expect(entry.file == state.entries.items[0].file);
        try std.testing.expect(entry.image() == state.entries.items[0].image());
    }
    const stats = state.snapshot();
    try std.testing.expectEqual(@as(usize, 32), stats.mapping_count);
    try std.testing.expectEqual(@as(usize, if (c.getenv("XODB_TEST_WRONG_PE_CACHE") != null) 2 else 1), stats.identity_count);
    try std.testing.expectEqual(@as(usize, 1), stats.resident_images);
    try std.testing.expectEqual(c.xpe_info(state.entries.items[0].image()).*.retained_bytes, state.bytes);
    state.evict(state.files.items[0]);
    try std.testing.expectEqual(@as(u64, 0), state.bytes);
    for (regions) |region| try std.testing.expect(state.backgroundDeferred(region));
    try std.testing.expect(state.pending == null);
    try std.testing.expectError(error.SymbolDiscoveryPending, state.get(a, @ptrCast(&target), regions[7]));
    while (state.pending != null) {
        state.poll();
        if (native.xrt_now() - begun > 5 * std.time.ns_per_s) return error.TestJobTimeout;
        _ = native.usleep(100);
    }
    const reloaded = try state.get(a, @ptrCast(&target), regions[7]);
    try std.testing.expectEqual(@as(u64, 8), reloaded.id);
    for (state.entries.items) |entry| try std.testing.expect(entry.image() == reloaded.image());
    try std.testing.expectEqual(@as(c_int, 0), native.ftruncate(fd, 4097));
    try std.testing.expectError(error.PeImageChanged, state.get(a, @ptrCast(&target), regions[0]));
}
