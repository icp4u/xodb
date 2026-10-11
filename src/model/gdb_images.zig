//! Memory regions and loaded images of a Darwin target behind a GDB remote
//! stub (Apple's debugserver). The ELF module pipeline cannot read Mach-O, so
//! images are listed as typed load failures and regions carry only what the
//! stub reports. All text comes from the remote and is display-only: no path
//! here is ever opened on this host.
const std = @import("std");
const linux = @import("../target/linux.zig");
const rt = @import("../target/runtime.zig").c;
const modules = @import("modules.zig");

pub const image_diagnostic = "MachOImageUnsupported";
pub const image_detail = "Mach-O symbols, source and unwind data are not read by this build";

pub const Map = struct {
    arena: ?std.heap.ArenaAllocator = null,
    generation: u64 = std.math.maxInt(u64),
    regions: []modules.Region = &.{},
    images: []modules.Modules.LoadFailure = &.{},

    pub fn deinit(self: *Map) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
    /// A running target keeps the last stopped snapshot, as the ELF map does.
    pub fn refresh(self: *Map, target: *linux.Target) !void {
        const snapshot = target.snapshot();
        if (snapshot.state != .stopped) return if (self.arena == null) error.NotStopped else {};
        if (self.arena != null and self.generation == snapshot.generation) return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const scratch = std.heap.page_allocator;
        const raw_regions = try scratch.alloc(rt.struct_xrt_gdb_region, rt.XRT_GDB_REGIONS_MAX);
        defer scratch.free(raw_regions);
        const raw_images = try scratch.alloc(rt.struct_xrt_gdb_image, rt.XRT_GDB_IMAGES_MAX);
        defer scratch.free(raw_images);
        const region_count = try target.gdbRegions(raw_regions);
        var images: std.ArrayList(modules.Modules.LoadFailure) = .empty;
        var image_count: usize = 0;
        if (target.gdbImages(raw_images)) |count| {
            image_count = count;
        } else |err| switch (err) {
            // Regions stay useful without the image list; say why it is absent.
            // Anything else (a malformed reply, a lost link) is the caller's error.
            error.GdbListUnavailable, error.GdbListTooLarge => try images.append(a, .{ .start = 0, .end = 0, .path = "", .diagnostic = @errorName(err), .detail = if (target.gdbRemoteInfo()) |info| try a.dupe(u8, info.last_reason) else null }),
            else => return err,
        }
        var regions: std.ArrayList(modules.Region) = .empty;
        for (raw_regions[0..region_count]) |*r| {
            if (!r.mapped) continue;
            var path: []const u8 = std.mem.sliceTo(&r.name, 0);
            for (raw_images[0..image_count]) |*image| if (image.load_address == r.start) {
                path = std.mem.sliceTo(&image.path, 0);
            };
            const kind = std.mem.sliceTo(&r.type, 0);
            const text = if (path.len != 0) try a.dupe(u8, path) else if (kind.len != 0) try std.fmt.allocPrint(a, "[{s}]", .{kind}) else "";
            try regions.append(a, .{ .start = r.start, .end = r.start +| r.size, .offset = 0, .inode = 0, .device_major = 0, .device_minor = 0, .permissions = .{ if (r.read) 'r' else '-', if (r.write) 'w' else '-', if (r.execute) 'x' else '-', 'p' }, .path = text });
        }
        for (raw_images[0..image_count]) |*image| {
            var end = image.load_address;
            for (regions.items) |region| if (region.start == image.load_address) {
                end = region.end;
            };
            try images.append(a, .{ .start = image.load_address, .end = end, .path = try a.dupe(u8, std.mem.sliceTo(&image.path, 0)), .diagnostic = image_diagnostic, .detail = if (image.path_truncated) "Path cut at 255 bytes. " ++ image_detail else image_detail });
        }
        const region_rows = try regions.toOwnedSlice(a);
        const image_rows = try images.toOwnedSlice(a);
        if (self.arena) |*old| old.deinit();
        // Moved only after its last allocation: the copy owns every row.
        self.* = .{ .arena = arena, .generation = snapshot.generation, .regions = region_rows, .images = image_rows };
    }
};
