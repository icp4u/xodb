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

// Disjoint, uniquely owned intervals. Shared-cache LINKEDIT can overlap
// across images; no label may silently pick one of those owners.
fn uniqueRanges(alloc: std.mem.Allocator, ranges: []const Range, image_count: usize) ![]Range {
    const Edge = struct { address: u64, image: usize, begin: bool };
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(a);
    for (ranges) |range| {
        try edges.append(a, .{ .address = range.start, .image = range.image, .begin = true });
        try edges.append(a, .{ .address = range.end, .image = range.image, .begin = false });
    }
    std.mem.sort(Edge, edges.items, {}, struct {
        fn less(_: void, x: Edge, y: Edge) bool {
            return x.address < y.address;
        }
    }.less);
    const counts = try a.alloc(u32, image_count);
    defer a.free(counts);
    @memset(counts, 0);
    var owners: usize = 0;
    var owner: usize = 0;
    var cursor: u64 = 0;
    var result: std.ArrayList(Range) = .empty;
    errdefer result.deinit(alloc);
    var i: usize = 0;
    while (i < edges.items.len) {
        const address = edges.items[i].address;
        if (owners == 1 and address > cursor) {
            if (result.items.len > 0 and result.items[result.items.len - 1].end == cursor and result.items[result.items.len - 1].image == owner) {
                result.items[result.items.len - 1].end = address;
            } else try result.append(alloc, .{ .start = cursor, .end = address, .image = owner });
        }
        // Resolve all edges at the same address together. Endpoints carry
        // no bytes; adjacent segments of one image stay one interval.
        while (i < edges.items.len and edges.items[i].address == address) : (i += 1) {
            const edge = edges.items[i];
            if (edge.begin) {
                if (counts[edge.image] == 0) {
                    owners += 1;
                    owner ^= edge.image;
                }
                counts[edge.image] += 1;
            } else {
                counts[edge.image] -= 1;
                if (counts[edge.image] == 0) {
                    owners -= 1;
                    owner ^= edge.image;
                }
            }
        }
        cursor = address;
    }
    return result.toOwnedSlice(alloc);
}
fn regionOwner(ranges: []const Range, start: u64, end: u64) ?usize {
    var lo: usize = 0;
    var hi = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ranges[mid].start <= start) lo = mid + 1 else hi = mid;
    }
    if (lo == 0 or start >= ranges[lo - 1].end or end > ranges[lo - 1].end) return null;
    return ranges[lo - 1].image;
}

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
    region_ranges: []Range = &.{},
    anchors: std.AutoHashMapUnmanaged(u64, usize) = .empty,
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
        var mappings: std.ArrayList(Range) = .empty;
        var anchors: std.AutoHashMapUnmanaged(u64, usize) = .empty;
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
            const text = textAddress(image) orelse {
                // A reduced image list still identifies the mapping starting
                // exactly at its load address. It says nothing about later
                // mappings; only full segment geometry can label those.
                try anchors.put(alloc, image.load_address, i);
                continue;
            };
            for (image.segments[0..image.segment_count]) |segment| {
                // Frame labels require executable ranges; never use PAGEZERO
                // or shared, overlapping LINKEDIT ranges as code owners.
                if (segment.maxprot == 0 or segment.vmsize == 0 or std.mem.eql(u8, std.mem.sliceTo(&segment.name, 0), "__PAGEZERO")) continue;
                const start = relocated(image, text, segment.vmaddr) orelse return error.MachOImageRangeOverflow;
                const end = std.math.add(u64, start, segment.vmsize) catch return error.MachOImageRangeOverflow;
                if (mappings.items.len == 16384) return error.MachOImageRangeLimit;
                const range = Range{ .start = start, .end = end, .image = i };
                try mappings.append(alloc, range);
                if (segment.maxprot & 4 != 0) try ranges.append(alloc, range);
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
        const region_ranges = try uniqueRanges(alloc, mappings.items, count);
        const failures = try alloc.alloc(modules.Modules.LoadFailure, count + 1);
        self.symbols.prune(raw);
        if (self.arena) |*previous| previous.deinit();
        self.arena = arena;
        self.raw = raw;
        self.ids = ids;
        self.ranges = range_rows;
        self.region_ranges = region_ranges;
        self.anchors = anchors;
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
            if (regionOwner(self.region_ranges, region.start, region.start +| region.size) orelse self.anchors.get(region.start)) |image|
                path = std.mem.sliceTo(&self.raw[image].path, 0);
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
    const Located = struct { index: usize, text: u64, link: u64 };
    fn locate(self: *Map, lookup: u64) !?Located {
        if (self.list_failure) |failure| {
            if (std.mem.eql(u8, failure, "GdbListTooLarge")) return error.GdbListTooLarge;
            return error.GdbListUnavailable;
        }
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
        return .{ .index = index, .text = text, .link = link };
    }
    pub const Debug = struct {
        info: *@import("../debug/info.zig").Image,
        link: u64,
        job: *@import("../c.zig").api.struct_xmo_job,
        object: ?u32,
        load: u64,
        text: u64,
        pub fn runtimeAddress(self: *const Debug, address: u64) !u64 {
            var link = address;
            if (self.object) |index| {
                const c = @import("../c.zig").api;
                switch (c.xmo_job_object_address(self.job, index, address, &link)) {
                    c.XMO_OK => {},
                    c.XMO_CHANGED => return error.MachOObjectChanged,
                    else => return error.MachOObjectAddressUnavailable,
                }
            }
            return if (link >= self.text) std.math.add(u64, self.load, link - self.text) catch return error.MachOImageRangeOverflow else std.math.sub(u64, self.load, self.text - link) catch return error.MachOImageRangeOverflow;
        }
        pub fn imageAddress(user: *const anyopaque, address: u64) !u64 {
            const self: *const Debug = @ptrCast(@alignCast(user));
            return self.runtimeAddress(address);
        }
    };
    pub fn debugAt(self: *Map, address: u64, roots: []const [:0]const u8) !Debug {
        const found = try self.locate(address) orelse return error.UnmappedAddress;
        const image = &self.raw[found.index];
        const debug = try self.symbols.debugInfo(image, roots, found.text, found.link);
        return .{ .info = debug.info, .link = debug.pc, .job = debug.job, .object = debug.object, .load = image.load_address, .text = found.text };
    }
    pub fn unwind(self: *Map, allocator: std.mem.Allocator, address: u64, roots: []const [:0]const u8, context_: @import("../debug/location.zig").Context, mask: u64, top: bool) !@import("../debug/info.zig").Unwind {
        const found = try self.locate(address) orelse return error.UnmappedAddress;
        const image = &self.raw[found.index];
        const Relocation = struct {
            load: u64,
            text: u64,
            fn resolve(user: *const anyopaque, link: u64) !u64 {
                const self_: *const @This() = @ptrCast(@alignCast(user));
                return if (link >= self_.text) std.math.add(u64, self_.load, link - self_.text) catch return error.MachOImageRangeOverflow else std.math.sub(u64, self_.load, self_.text - link) catch return error.MachOImageRangeOverflow;
            }
        };
        const relocation = Relocation{ .load = image.load_address, .text = found.text };
        var context = context_;
        context.image_address = Relocation.resolve;
        context.image_user = &relocation;
        return self.symbols.unwind(allocator, image, roots, found.text, found.link, context, mask, top);
    }
    pub fn label(self: *Map, alloc: std.mem.Allocator, pc: u64, lookup: u64, roots: []const [:0]const u8) !?Label {
        const found = try self.locate(lookup) orelse return null;
        const index = found.index;
        const image = &self.raw[index];
        const text = found.text;
        const link = found.link;
        var diagnostic: ?[]const u8 = null;
        const symbol = self.symbols.symbol(alloc, image, roots, link, text) catch |err| blk: {
            diagnostic = @errorName(err);
            break :blk null;
        };
        const path = std.mem.sliceTo(&image.path, 0);
        if (symbol) |value| {
            const address = relocated(image, text, value.address) orelse return error.MachOImageRangeOverflow;
            return .{ .name = try @import("image_label.zig").format(alloc, path, value.name, pc -| address), .module = self.ids[index], .diagnostic = null };
        }
        return .{ .name = try @import("image_label.zig").format(alloc, path, null, pc -| image.load_address), .module = self.ids[index], .diagnostic = diagnostic orelse self.symbols.status(image) orelse "MachOSymbolUnavailable" };
    }
};

test "region ownership excludes ambiguity and gaps, merges one owner's segments" {
    const alloc = std.testing.allocator;
    const ranges = try uniqueRanges(alloc, &.{
        .{ .start = 100, .end = 200, .image = 0 },
        .{ .start = 120, .end = 150, .image = 0 },
        .{ .start = 200, .end = 300, .image = 0 },
        .{ .start = 180, .end = 220, .image = 1 },
        .{ .start = 310, .end = 320, .image = 2 },
    }, 3);
    defer alloc.free(ranges);
    try std.testing.expectEqual(@as(?usize, 0), regionOwner(ranges, 100, 180));
    try std.testing.expectEqual(@as(?usize, null), regionOwner(ranges, 170, 190));
    try std.testing.expectEqual(@as(?usize, null), regionOwner(ranges, 180, 181));
    try std.testing.expectEqual(@as(?usize, 0), regionOwner(ranges, 220, 300));
    try std.testing.expectEqual(@as(?usize, null), regionOwner(ranges, 299, 311));
    try std.testing.expectEqual(@as(?usize, 2), regionOwner(ranges, 310, 320));
    const adjacent = try uniqueRanges(alloc, &.{ .{ .start = 10, .end = 20, .image = 0 }, .{ .start = 20, .end = 30, .image = 0 } }, 1);
    defer alloc.free(adjacent);
    try std.testing.expectEqual(@as(?usize, 0), regionOwner(adjacent, 10, 30));
}
