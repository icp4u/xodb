//! Immutable PE file assets retained at the opening stopped snapshot. These
//! readers cannot access a live target after construction.
const std = @import("std");
const c = @import("../c.zig").api;
const runtime = @import("../target/runtime.zig");
const rt = runtime.c;
const pe = @import("../model/pe_images.zig");
const snapshot = @import("../binary/snapshot.zig");
const windows = @import("../debug/windows.zig");
pub const metadata_limit: usize = 256 * 1024 * 1024;
pub const Placement = struct { device_major: u64, device_minor: u64, inode: u64, bias: u64, start: u64, end: u64 };
pub const Asset = struct {
    id: u64,
    path: [:0]const u8,
    placement: Placement,
    bias: u64,
    mapping: snapshot.Bytes,
    image: *c.struct_xpe_image,
    pub fn fromBytes(a: std.mem.Allocator, id: u64, path: []const u8, placement: Placement, bytes: snapshot.Bytes) !*Asset {
        const self = try a.create(Asset);
        errdefer a.destroy(self);
        self.* = .{ .id = id, .path = try a.dupeZ(u8, path), .placement = placement, .bias = placement.bias, .mapping = bytes, .image = undefined };
        errdefer a.free(self.path);
        var image: ?*c.struct_xpe_image = null;
        const source = c.struct_xpe_source{ .context = self, .size = bytes.len, .layout = c.XPE_FILE, .read = read };
        try pe.check(c.xpe_load(&source, &image));
        self.image = image.?;
        errdefer c.xpe_destroy(self.image);
        const end = std.math.add(u64, placement.bias, c.xpe_info(self.image).*.image_size) catch return error.PeImagePlacementMismatch;
        if (placement.start != placement.bias or placement.end != end) return error.PeImagePlacementMismatch;
        // Ownership of the immutable bytes transfers only on success.
        return self;
    }
    pub fn deinit(self: *Asset, a: std.mem.Allocator) void {
        c.xpe_destroy(self.image);
        _ = c.munmap(self.mapping.ptr, self.mapping.len);
        a.free(self.path);
        a.destroy(self);
    }
    fn read(ptr: ?*anyopaque, at: u64, raw: ?*anyopaque, n: usize) callconv(.c) c.enum_xpe_status {
        const self: *const Asset = @ptrCast(@alignCast(ptr.?));
        if (at > self.mapping.len or n > self.mapping.len - at) return c.XPE_MALFORMED;
        @memcpy(@as([*]u8, @ptrCast(raw.?))[0..n], self.mapping[@intCast(at)..][0..n]);
        return c.XPE_OK;
    }
    pub fn linkAddress(self: *const Asset, pc: u64) !u32 {
        if (pc < self.bias or pc - self.bias >= c.xpe_info(self.image).*.image_size) return error.PeImagePlacementMismatch;
        return @intCast(pc - self.bias);
    }
    pub const Symbol = struct { name: []const u8, address: u64, size: u64, truncated: bool };
    pub fn symbol(self: *const Asset, pc: u64, buffer: []u8) ?Symbol {
        const rva = self.linkAddress(pc) catch return null;
        if (!windows.executable(self.image, rva)) return null;
        const function = c.xpe_function_at(self.image, rva);
        const begin = if (function) |f| f.*.begin else rva;
        const exported = c.xpe_export_name_at(self.image, begin);
        const name: ?[]const u8 = if (exported != null) std.mem.span(exported) else null;
        var suffix: [32]u8 = undefined;
        const label = name orelse if (function != null) std.fmt.bufPrint(&suffix, "sub_{x}", .{begin}) catch unreachable else return null;
        var used: usize = 0;
        var total: usize = 0;
        for ([_][]const u8{ std.fs.path.basename(self.path), "!", label }) |piece| {
            const n = @min(buffer.len - used, piece.len);
            @memcpy(buffer[used..][0..n], piece[0..n]);
            used += n;
            total += piece.len;
        }
        return .{ .name = buffer[0..used], .truncated = used < total, .address = self.bias + begin, .size = if (function) |f| f.*.end - f.*.begin else 0 };
    }
};
pub const Assets = struct {
    entries: std.ArrayList(*Asset) = .empty,
    metadata_bytes: usize = 0,
    /// Worker snapshots borrow immutable assets from their pinned source.
    owns_assets: bool = true,
    pub fn deinit(self: *Assets, a: std.mem.Allocator) void {
        if (self.owns_assets) for (self.entries.items) |asset| asset.deinit(a);
        self.entries.deinit(a);
        self.* = .{};
    }
    pub fn append(self: *Assets, a: std.mem.Allocator, asset: *Asset) !void {
        const retained = c.xpe_info(asset.image).*.retained_bytes;
        if (retained > metadata_limit - self.metadata_bytes) return error.PeMetadataBudgetLimit;
        try self.entries.append(a, asset);
        self.metadata_bytes += @intCast(retained);
    }
    pub fn byId(self: *const Assets, id: u64) ?*const Asset {
        if (id == 0) return null;
        for (self.entries.items) |asset| if (asset.id == id) return asset;
        return null;
    }
};
/// Capture the exact pinned file version and prove its stopped placement again.
/// Later code reads use this immutable file; in-place code changes during the
/// capture have the same explicit coverage limitation as ELF CFI attribution.
pub fn retain(a: std.mem.Allocator, target: *const rt.struct_xrt_target, entry: *const pe.Entry, id: u64, limit: usize) !*Asset {
    if (rt.xrt_target_is_remote(target)) return error.PeRemoteMetadataUnavailable;
    if (rt.xrt_target_shared_vm(target)) return error.PeSharedVmUnavailable;
    var context = TargetReader{ .target = target, .base = entry.start };
    rt.xrt_target_view(target, &context.expected);
    try context.unchanged();
    const request = c.struct_xrt_file_request{ .kind = c.XRT_FILE_MAPPED, .mapping = .{ .start = entry.start, .end = entry.end, .offset = 0, .device_major = entry.device_major, .device_minor = entry.device_minor, .inode = entry.inode, .path = entry.path } };
    var fd: c_int = -1;
    var identity: c.struct_xrt_file_identity = undefined;
    try runtime.check(@intCast(c.xrt_target_file_open(@ptrCast(target), &request, &fd, &identity)));
    defer _ = c.close(fd);
    if (!std.meta.eql(identity, entry.identity)) return error.BinaryChangedDuringRead;
    const bytes = try snapshot.read(fd, @min(snapshot.per_image_limit, limit), null);
    var owned_bytes = true;
    errdefer if (owned_bytes) {
        _ = c.munmap(bytes.ptr, bytes.len);
    };
    try runtime.check(@intCast(c.xrt_file_unchanged(fd, &entry.identity)));
    const original = entry.image() orelse return error.SymbolDiscoveryPending;
    const size = c.xpe_info(original).*.image_size;
    const placement = Placement{ .start = entry.start, .end = try std.math.add(u64, entry.start, size), .bias = entry.start, .device_major = entry.device_major, .device_minor = entry.device_minor, .inode = entry.inode };
    const asset = try Asset.fromBytes(a, id, entry.path, placement, bytes);
    owned_bytes = false;
    errdefer asset.deinit(a);
    const source = c.struct_xpe_source{ .context = &context, .size = size, .layout = c.XPE_MEMORY, .read = TargetReader.read };
    try pe.check(c.xpe_validate_loaded_headers(asset.image, &source));
    var verifier = Verifier{ .asset = asset, .target = &context };
    try verifier.verify();
    try context.unchanged();
    return asset;
}
const TargetReader = struct {
    target: *const rt.struct_xrt_target,
    base: u64,
    expected: rt.struct_xrt_target_view = undefined,
    fn unchanged(self: *const TargetReader) !void {
        var current: rt.struct_xrt_target_view = undefined;
        rt.xrt_target_view(self.target, &current);
        if (current.state != rt.XRT_STOPPED or current.pid != self.expected.pid or current.generation != self.expected.generation or current.image_epoch != self.expected.image_epoch) return error.PeImageChanged;
    }
    fn read(ptr: ?*anyopaque, rva: u64, raw: ?*anyopaque, n: usize) callconv(.c) c.enum_xpe_status {
        const self: *TargetReader = @ptrCast(@alignCast(ptr.?));
        self.unchanged() catch return c.XPE_CHANGED;
        const address = std.math.add(u64, self.base, rva) catch return c.XPE_MALFORMED;
        var count: usize = 0;
        if (rt.xrt_target_read(self.target, address, raw, n, &count) != rt.XRT_OK or count != n) return c.XPE_IO;
        self.unchanged() catch return c.XPE_CHANGED;
        return c.XPE_OK;
    }
};
const Verifier = struct {
    asset: *const Asset,
    target: *TargetReader,
    bytes: usize = 0,
    failure: ?anyerror = null,
    fn compare(ptr: ?*anyopaque, rva: u32, raw: ?*anyopaque, n: usize) callconv(.c) c_int {
        const self: *Verifier = @ptrCast(@alignCast(ptr.?));
        var loaded: [4096]u8 = undefined;
        if (n > loaded.len or n > c.XPE_MAX_READ_BYTES - self.bytes) {
            self.failure = error.PeMetadataLimit;
            return 0;
        }
        self.bytes += n;
        pe.check(c.xpe_read_range(self.asset.image, rva, raw, n)) catch |err| {
            self.failure = err;
            return 0;
        };
        pe.check(TargetReader.read(self.target, rva, &loaded, n)) catch |err| {
            self.failure = err;
            return 0;
        };
        if (!std.mem.eql(u8, loaded[0..n], @as([*]const u8, @ptrCast(raw.?))[0..n])) {
            self.failure = error.PeUnwindMetadataChanged;
            return 0;
        }
        return 1;
    }
    fn verify(self: *Verifier) !void {
        const count = c.xpe_info(self.asset.image).*.function_count;
        if (count == 0) return;
        // Retained rows keep their table position; empty rows between them
        // were left out by the reader but are still part of the compared span.
        const first = c.xpe_function(self.asset.image, 0).*.record_rva;
        const total: usize = (c.xpe_function(self.asset.image, count - 1).*.record_rva - first) / 12 + 1;
        var row: usize = 0;
        var buffer: [4080]u8 = undefined;
        while (row < total) {
            const rows: usize = @min(total - row, buffer.len / 12);
            if (compare(self, @intCast(first + row * 12), &buffer, rows * 12) == 0) return self.failure orelse error.PeMetadataUnavailable;
            row += rows;
        }
        const source = c.struct_xpu_source{ .context = self, .image_size = c.xpe_info(self.asset.image).*.image_size, .metadata = compare, .code = null, .stack = null };
        for (0..count) |i| {
            const f = c.xpe_function(self.asset.image, @intCast(i)).*;
            const function = c.struct_xpu_function{ .begin = f.begin, .end = f.end, .unwind = f.unwind };
            // Unsupported/malformed records will still refuse during analysis.
            // Every record which can produce a caller has now been compared.
            _ = c.xpu_validate(&source, &function);
            if (self.failure) |err| return err;
        }
    }
};
