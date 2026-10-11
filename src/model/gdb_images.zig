//! Stopped Darwin image/region snapshots. Stub paths are display-only; local
//! symbols come from explicitly configured files matched by UUID.
const std = @import("std");
const linux = @import("../target/linux.zig");
const rt = @import("../target/runtime.zig").c;
const modules = @import("modules.zig");
const symbols = @import("macho_images.zig");
const a = std.heap.page_allocator;
pub const image_diagnostic = "MachOImageUnsupported";
pub const image_detail = "The stub did not provide the UUID and segment data needed for Mach-O labels";
const Range = struct { start: u64, end: u64, image: usize };
const absent = std.math.maxInt(u64);

pub const Map = struct {
    arena: ?std.heap.ArenaAllocator = null,
    region_arena: ?std.heap.ArenaAllocator = null,
    generation: u64 = absent,
    region_generation: u64 = absent,
    regions: []modules.Region = &.{},
    images: []modules.Modules.LoadFailure = &.{},
    failure_buffer: []modules.Modules.LoadFailure = &.{},
    raw: []rt.struct_xrt_gdb_image = &.{},
    ids: []u64 = &.{},
    ranges: []Range = &.{},
    next_id: u64 = 1,
    list_failure: ?[]const u8 = null,
    geometry_failure: ?[]const u8 = null,
    symbols: symbols.State = .{},

    pub fn deinit(self: *Map) void {
        self.symbols.deinit();
        if (self.arena) |*arena| arena.deinit();
        if (self.region_arena) |*arena| arena.deinit();
        self.* = .{};
    }
    fn textAddress(image: *const rt.struct_xrt_gdb_image) ?u64 {
        var text: ?u64 = null;
        for (image.segments[0..image.segment_count]) |segment| {
            if (!std.mem.eql(u8, std.mem.sliceTo(&segment.name, 0), "__TEXT")) continue;
            if (text != null) return null;
            text = segment.vmaddr;
        }
        return text;
    }
    fn relocated(image: *const rt.struct_xrt_gdb_image, text: u64, value: u64) ?u64 {
        return if (value >= text) std.math.add(u64, image.load_address, value - text) catch null else std.math.sub(u64, image.load_address, text - value) catch null;
    }
    pub fn refreshImages(self: *Map, target: *linux.Target) !void {
        const snapshot = target.snapshot();
        if (snapshot.state != .stopped) return if (self.arena == null) error.NotStopped else {};
        if (self.arena != null and self.generation == snapshot.generation) return;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const scratch = try a.alloc(rt.struct_xrt_gdb_image, rt.XRT_GDB_IMAGES_MAX);
        defer a.free(scratch);
        var list_failure: ?[]const u8 = null;
        const count = target.gdbImages(scratch) catch |err| switch (err) {
            error.GdbListUnavailable, error.GdbListTooLarge => blk: {
                list_failure = @errorName(err);
                break :blk 0;
            },
            else => return err,
        };
        const raw = try alloc.dupe(rt.struct_xrt_gdb_image, scratch[0..count]);
        const ids = try alloc.alloc(u64, count);
        var old: std.AutoHashMapUnmanaged(u64, usize) = .empty;
        defer old.deinit(a);
        for (self.raw, 0..) |image, i| try old.put(a, image.load_address, i);
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer seen.deinit(a);
        var ranges: std.ArrayList(Range) = .empty;
        var geometry_failure: ?[]const u8 = null;
        for (raw, 0..) |*image, i| {
            const present = try seen.getOrPut(a, image.load_address);
            if (present.found_existing) return error.MachODuplicateImageAddress;
            ids[i] = 0;
            if (old.get(image.load_address)) |previous| if (image.has_uuid and self.raw[previous].has_uuid and std.mem.eql(u8, &image.uuid, &self.raw[previous].uuid)) {
                ids[i] = self.ids[previous];
            };
            if (ids[i] == 0) {
                if (self.next_id == absent) return error.MachOImageIdentityLimit;
                ids[i] = self.next_id;
                self.next_id += 1;
            }
            const text = textAddress(image) orelse continue;
            for (image.segments[0..image.segment_count]) |segment| {
                // Frame labels require executable ranges; never use PAGEZERO
                // or shared, overlapping LINKEDIT ranges as code owners.
                if (segment.maxprot & 4 == 0 or segment.vmsize == 0) continue;
                const start = relocated(image, text, segment.vmaddr) orelse return error.MachOImageRangeOverflow;
                const end = std.math.add(u64, start, segment.vmsize) catch return error.MachOImageRangeOverflow;
                if (ranges.items.len == 16384) return error.MachOImageRangeLimit;
                try ranges.append(alloc, .{ .start = start, .end = end, .image = i });
            }
        }
        std.mem.sort(Range, ranges.items, {}, struct {
            fn less(_: void, x: Range, y: Range) bool {
                return x.start < y.start;
            }
        }.less);
        var last_end: u64 = 0;
        for (ranges.items) |range| {
            if (range.start < last_end) geometry_failure = "MachOAmbiguousImageRange";
            last_end = @max(last_end, range.end);
        }
        const range_rows = try ranges.toOwnedSlice(alloc);
        const failures = try alloc.alloc(modules.Modules.LoadFailure, count + 1);
        self.symbols.prune(raw);
        if (self.arena) |*previous| previous.deinit();
        self.arena = arena;
        self.raw = raw;
        self.ids = ids;
        self.ranges = range_rows;
        self.failure_buffer = failures;
        self.generation = snapshot.generation;
        self.list_failure = list_failure;
        self.geometry_failure = geometry_failure;
        self.refreshFailures();
    }
    pub fn refreshFailures(self: *Map) void {
        var count: usize = 0;
        if (self.list_failure orelse self.geometry_failure) |failure| {
            self.failure_buffer[count] = .{ .start = 0, .end = 0, .path = "", .diagnostic = failure, .detail = if (std.mem.eql(u8, failure, "GdbListTooLarge")) "GDB loaded-image list exceeds the packet limit" else null };
            count += 1;
        }
        for (self.raw) |*image| {
            const diagnostic = if (!image.has_uuid or !image.has_header or textAddress(image) == null) image_diagnostic else self.symbols.status(image) orelse continue;
            var end = image.load_address;
            for (self.ranges) |range| if (&self.raw[range.image] == image) {
                end = @max(end, range.end);
            };
            self.failure_buffer[count] = .{ .start = image.load_address, .end = end, .path = std.mem.sliceTo(&image.path, 0), .diagnostic = diagnostic, .detail = if (std.mem.eql(u8, diagnostic, image_diagnostic)) image_detail else null };
            count += 1;
        }
        self.images = self.failure_buffer[0..count];
    }
    pub fn refresh(self: *Map, target: *linux.Target) !void {
        try self.refreshImages(target);
        self.refreshFailures();
        const snapshot = target.snapshot();
        if (snapshot.state != .stopped or self.region_generation == snapshot.generation) return;
        const raw_regions = try a.alloc(rt.struct_xrt_gdb_region, rt.XRT_GDB_REGIONS_MAX);
        defer a.free(raw_regions);
        const count = try target.gdbRegions(raw_regions);
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var regions: std.ArrayList(modules.Region) = .empty;
        for (raw_regions[0..count]) |*region| {
            if (!region.mapped) continue;
            var path: []const u8 = std.mem.sliceTo(&region.name, 0);
            for (self.raw) |*image| if (image.load_address == region.start) {
                path = std.mem.sliceTo(&image.path, 0);
            };
            const kind = std.mem.sliceTo(&region.type, 0);
            const region_label = if (path.len != 0) try alloc.dupe(u8, path) else if (kind.len != 0) try std.fmt.allocPrint(alloc, "[{s}]", .{kind}) else "";
            try regions.append(alloc, .{ .start = region.start, .end = region.start +| region.size, .offset = 0, .inode = 0, .device_major = 0, .device_minor = 0, .permissions = .{ if (region.read) 'r' else '-', if (region.write) 'w' else '-', if (region.execute) 'x' else '-', 'p' }, .path = region_label });
        }
        const rows = try regions.toOwnedSlice(alloc);
        if (self.region_arena) |*previous| previous.deinit();
        self.region_arena = arena;
        self.regions = rows;
        self.region_generation = snapshot.generation;
    }
    pub const Label = struct { name: []const u8, module: u64, diagnostic: ?[]const u8 };
    pub fn label(self: *Map, alloc: std.mem.Allocator, pc: u64, lookup: u64, roots: []const [:0]const u8) !?Label {
        if (self.geometry_failure != null) return error.MachOAmbiguousImageRange;
        var lo: usize = 0;
        var hi = self.ranges.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.ranges[mid].start <= lookup) lo = mid + 1 else hi = mid;
        }
        if (lo == 0 or lookup >= self.ranges[lo - 1].end) return null;
        const index = self.ranges[lo - 1].image;
        const image = &self.raw[index];
        const text = textAddress(image).?;
        const link = if (lookup >= image.load_address) std.math.add(u64, text, lookup - image.load_address) catch return error.MachOImageRangeOverflow else std.math.sub(u64, text, image.load_address - lookup) catch return error.MachOImageRangeOverflow;
        var diagnostic: ?[]const u8 = null;
        const symbol = self.symbols.symbol(alloc, image, roots, link, text) catch |err| blk: {
            diagnostic = @errorName(err);
            break :blk null;
        };
        // The stub chose this name. '!' separates image from symbol, so it
        // must not supply one: an unsymbolised address would read as a symbol.
        const base = try alloc.dupe(u8, std.fs.path.basename(std.mem.sliceTo(&image.path, 0)));
        defer alloc.free(base);
        std.mem.replaceScalar(u8, base, '!', '?');
        if (symbol) |found| {
            const address = relocated(image, text, found.address) orelse return error.MachOImageRangeOverflow;
            return .{ .name = try std.fmt.allocPrint(alloc, "{s}!{s}+0x{x}", .{ base, found.name, pc -| address }), .module = self.ids[index], .diagnostic = null };
        }
        return .{ .name = try std.fmt.allocPrint(alloc, "{s}+0x{x}", .{ base, pc -| image.load_address }), .module = self.ids[index], .diagnostic = diagnostic orelse self.symbols.status(image) orelse "MachOSymbolUnavailable" };
    }
};
