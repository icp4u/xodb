const std = @import("std");
const runtime_api = @import("../target/runtime.zig");
const rt = runtime_api.c;
const c = @import("../c.zig").api;
const elf = @import("../binary/elf.zig");
const apk = @import("../binary/apk.zig");
const snapshot = @import("../binary/snapshot.zig");
const mapped_file = @import("../binary/mapped_file.zig");
const pe = @import("pe_images.zig");
const DebugInfo = @import("../debug/info.zig").Image;
pub const PeMapping = struct { id: u64, base: u64, path: []const u8 };
pub const Region = struct { start: u64, end: u64, offset: u64, inode: u64, device_major: u64, device_minor: u64, permissions: [4]u8, path: []const u8, file_source: mapped_file.Source = .unopened, full_image_deferred: bool = false, pe_image: ?PeMapping = null };
pub const Module = struct {
    id: u64,
    inode: u64,
    device_major: u64,
    device_minor: u64,
    path: [:0]const u8,
    image: elf.Image,
    bias: u64,
    start: u64,
    end: u64,
    debug: ?DebugInfo = null,
    perl_layout: ?c.struct_xpl_layout = null,
    python_layout: ?c.struct_xpy_layout = null,
    lua_layout: ?c.struct_xl_layout = null,
    elisp_layout: ?c.struct_xel_layout = null,
    ruby_layout: ?c.struct_xrb_layout = null,
    go_layout: ?c.struct_xgo_layout = null,
    go_value_layout: ?*c.struct_xgv_layout = null,
    go_map_layout: ?*c.struct_xgm_layout = null,
    javascript_dwarf: ?c.struct_xjs_dwarf_profile = null,
    debug_file: ?*const @import("../binary/debug_files.zig").File = null,
    debug_allocator: std.mem.Allocator = std.heap.page_allocator,
    file_offset: u64 = 0, // ELF entry offset in the backing file; zero for standalone ELF.
    mapping: []align(std.heap.page_size_min) u8,
    owns_mapping: bool = true,
    immutable: bool = false,
    file_source: mapped_file.Source = .unopened,
    pub fn debugInfo(self: *Module) !*DebugInfo {
        if (self.debug == null) self.debug = try DebugInfo.initWithCompanion(self.image, self.mapping, self.debug_file, self.debug_allocator);
        self.debug.?.allow_split = !self.immutable;
        return &self.debug.?;
    }
    pub fn symbols(self: *const Module) *const elf.Image {
        return if (self.debug_file) |file| &file.image else &self.image;
    }
    pub fn linkAddress(self: *const Module, runtime: u64) !u64 {
        if (runtime < self.bias) return error.UnmappedAddress;
        return runtime - self.bias;
    }
    pub fn runtimeAddress(self: *const Module, link: u64) !u64 {
        return std.math.add(u64, link, self.bias) catch error.InvalidAddress;
    }
};
pub const Symbol = struct { module_id: u64, name: []const u8, address: u64, size: u64, offset: u64 = 0, entry: u64 = 0 };
fn publishedSymbol(machine: elf.Machine, module_id: u64, symbol: elf.Symbol, address: u64) Symbol {
    const entry: u64 = if (machine == .ppc64 and symbol.type == .func) elf.ppc64LocalEntry(symbol.other) else 0;
    return .{ .module_id = module_id, .name = symbol.name, .address = address, .size = symbol.size, .entry = entry };
}
pub const Modules = struct {
    // These sealed sparse views contain symbols and placement metadata only.
    // Keep them outside Module so debug/unwind/code paths can never see holes.
    pub const FileKind = enum { elf, pe, other };
    const FileKey = struct { inode: u64, device_major: u64, device_minor: u64 };
    const max_file_kinds = 16384;
    const FileIdentity = struct {
        region: Region,
        identity: ?rt.struct_xrt_file_identity = null,
        remote_snapshot: bool = false,
        instances: std.ArrayList(struct { bias: u64, file_offset: u64, id: u64 }) = .empty,
        companion_owner: ?*@import("../binary/debug_files.zig").Files = null,
        companion_revision: u64 = 0,
        companion_automatic: bool = true,
        companion: ?union(enum) { absent, found: *const @import("../binary/debug_files.zig").File, failure: anyerror } = null,
        metadata_only: ?bool = null,
    };
    const SymbolImage = struct {
        region: Region,
        file: usize,
        bytes: snapshot.Bytes,
        image: elf.Image,
        retained: u64,
        last_used: u64 = 0,
    };
    pub const LoadFailure = struct { start: u64, end: u64, path: []const u8, diagnostic: []const u8 };
    target: ?*const rt.struct_xrt_target = null,
    // Worker-owned immutable snapshots must not read the owner's changing ISA.
    expected_machine: ?u16 = null,
    core_source: ?*const @import("../binary/core.zig").Core = null,
    core_ids: std.StringHashMapUnmanaged(union(enum) { id: []const u8, failure: anyerror }) = .empty,
    core_executable: ?struct { path: [:0]u8, id: []u8 } = null,
    allocator: std.mem.Allocator,
    regions: std.ArrayList(Region) = .empty,
    loaded: std.ArrayList(*Module) = .empty,
    next_id: u64 = 1,
    pe_images: pe.State = .{},
    file_kinds: std.AutoHashMapUnmanaged(FileKey, FileKind) = .empty,
    file_kind_reads: u64 = 0,
    maps_revision: u64 = 0,
    pe_scan_next: usize = 0,
    pid: i32 = 0,
    immutable: bool = false,
    snapshot_bytes: usize = 0,
    debug_files: ?*@import("../binary/debug_files.zig").Files = null,
    load_failures: std.ArrayList(LoadFailure) = .empty,
    budget_reported: ?struct { loaded: usize, deferred: usize } = null,
    identities: std.ArrayList(FileIdentity) = .empty,
    budget_dirty: bool = true,
    budget_generation: u64 = 0,
    budget_reported_generation: ?u64 = null,
    symbol_images: std.ArrayList(SymbolImage) = .empty,
    symbol_bytes: u64 = 0,
    symbol_limit: u64 = 128 * 1024 * 1024,
    symbol_clock: u64 = 0,
    symbol_evictions: u64 = 0,
    // Published labels can outlive a cache lookup. Keep their storage and
    // mapped-instance IDs independent of evictable section bytes.
    symbol_names: std.StringHashMapUnmanaged(void) = .empty,
    symbol_name_bytes: usize = 0,
    symbol_pending: ?struct { region: Region, job: *rt.struct_xrt_symbol_job, identity: rt.struct_xrt_file_identity } = null,
    pub fn init(a: std.mem.Allocator) Modules {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Modules) void {
        self.reportBudget();
        self.pe_images.deinit(self.allocator);
        self.file_kinds.deinit(self.allocator);
        self.cancelSymbolJob();
        for (self.symbol_images.items) |*item| {
            _ = c.munmap(item.bytes.ptr, item.bytes.len);
            self.allocator.free(item.region.path);
        }
        self.symbol_images.deinit(self.allocator);
        for (self.identities.items) |*file| {
            file.instances.deinit(self.allocator);
            self.allocator.free(file.region.path);
        }
        self.identities.deinit(self.allocator);
        var names = self.symbol_names.keyIterator();
        while (names.next()) |name| self.allocator.free(name.*);
        self.symbol_names.deinit(self.allocator);
        self.clearFailures();
        self.load_failures.deinit(self.allocator);
        var ids = self.core_ids.valueIterator();
        while (ids.next()) |value| switch (value.*) {
            .id => |id| self.allocator.free(id),
            .failure => {},
        };
        self.core_ids.deinit(self.allocator);
        if (self.core_executable) |exe| {
            self.allocator.free(exe.path);
            self.allocator.free(exe.id);
        }
        for (self.regions.items) |r| self.allocator.free(r.path);
        self.regions.deinit(self.allocator);
        for (self.loaded.items) |m| {
            if (m.go_value_layout) |layout| m.debug_allocator.destroy(layout);
            if (m.go_map_layout) |layout| m.debug_allocator.destroy(layout);
            if (m.debug) |*info| info.deinit();
            if (m.owns_mapping) _ = c.munmap(m.mapping.ptr, m.mapping.len);
            self.allocator.free(m.path);
            self.allocator.destroy(m);
        }
        self.loaded.deinit(self.allocator);
    }
    pub fn fromCore(self: *Modules, core: *const @import("../binary/core.zig").Core, executable: ?[]const u8) !void {
        self.core_source = core;
        self.immutable = true;
        if (executable) |name| {
            const z = try self.allocator.dupeZ(u8, name);
            defer self.allocator.free(z);
            const real = c.realpath(z, null) orelse return error.CoreExecutableUnavailable;
            defer c.free(real);
            const fd = c.open(real, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
            if (fd < 0) return error.CoreExecutableUnavailable;
            defer _ = c.close(fd);
            var stat: c.struct_stat = undefined;
            if (c.fstat(fd, &stat) != 0 or stat.st_size <= 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return error.CoreExecutableUnavailable;
            const data = try snapshot.readRange(fd, 0, @intCast(stat.st_size), snapshot.per_image_limit, null);
            defer _ = c.munmap(data.ptr, data.len);
            const image = try elf.Image.parse(data);
            const id = image.buildId() orelse return error.CoreExecutableBuildIdMissing;
            const path = try self.allocator.dupeZ(u8, std.mem.span(real));
            errdefer self.allocator.free(path);
            self.core_executable = .{ .path = path, .id = try self.allocator.dupe(u8, id) };
        }
        if (self.core_executable) |exe| {
            var matched = false;
            for (core.mappings.items) |mapping| if (mapping.offset == 0) {
                const id = self.coreId(mapping.path) catch continue;
                if (std.mem.eql(u8, id, exe.id)) {
                    matched = true;
                    break;
                }
            };
            if (!matched) return error.CoreExecutableBuildIdMismatch;
        }
        for (core.mappings.items) |mapping| {
            var permissions: [4]u8 = "---p".*;
            for (core.segments.items) |seg| if (mapping.start >= seg.start and mapping.start < seg.end) {
                if (seg.flags & 4 != 0) permissions[0] = 'r';
                if (seg.flags & 2 != 0) permissions[1] = 'w';
                if (seg.flags & 1 != 0) permissions[2] = 'x';
                break;
            };
            try self.regions.append(self.allocator, .{ .start = mapping.start, .end = mapping.end, .offset = mapping.offset, .inode = std.hash.Wyhash.hash(0, mapping.path), .device_major = 0, .device_minor = 0, .permissions = permissions, .path = try self.allocator.dupe(u8, mapping.path) });
        }
    }
    fn coreId(self: *Modules, path: []const u8) ![]const u8 {
        if (self.core_ids.get(path)) |value| return switch (value) {
            .id => |id| id,
            .failure => |err| err,
        };
        if (self.core_ids.count() >= 1024) return error.CoreModuleLimit;
        const core = self.core_source orelse return error.InvalidState;
        // Cache keys refer to immutable core metadata, never temporary requests.
        for (core.mappings.items) |mapping| if (mapping.offset == 0 and std.mem.eql(u8, mapping.path, path)) {
            const id = core.buildId(self.allocator, mapping) catch |err| {
                try self.core_ids.put(self.allocator, mapping.path, .{ .failure = err });
                return err;
            };
            errdefer self.allocator.free(id);
            try self.core_ids.put(self.allocator, mapping.path, .{ .id = id });
            return id;
        };
        return error.CoreModuleIdentityUnavailable;
    }
    pub fn refresh(self: *Modules, pid: i32) !void {
        if (self.core_source != null) return;
        if (pid <= 0) return;
        self.pid = pid;
        const request = std.mem.zeroInit(rt.struct_xrt_file_request, .{ .kind = rt.XRT_FILE_MAPS });
        var fd: c_int = -1;
        try runtime_api.check(if (self.target) |t| rt.xrt_target_file(t, &request, &fd) else rt.xrt_process_file(pid, &request, &fd));
        const file = c.fdopen(fd, "r") orelse {
            _ = c.close(fd);
            return error.ProcessMapsUnavailable;
        };
        defer _ = c.fclose(file);
        var new_regions: std.ArrayList(Region) = .empty;
        errdefer {
            for (new_regions.items) |r| self.allocator.free(r.path);
            new_regions.deinit(self.allocator);
        }
        var line: [*c]u8 = null;
        var capacity: usize = 0;
        defer c.free(line);
        while (true) {
            const len = c.getline(&line, &capacity, file);
            if (len < 0) break;
            var fields = std.mem.tokenizeAny(u8, line[0..@intCast(len)], " \t\n");
            const range = fields.next() orelse continue;
            const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
            const start = try std.fmt.parseInt(u64, range[0..dash], 16);
            const end = try std.fmt.parseInt(u64, range[dash + 1 ..], 16);
            const perms = fields.next() orelse continue;
            const offset = try std.fmt.parseInt(u64, fields.next() orelse continue, 16);
            const device = fields.next() orelse continue;
            const colon = std.mem.indexOfScalar(u8, device, ':') orelse continue;
            const device_major = try std.fmt.parseInt(u64, device[0..colon], 16);
            const device_minor = try std.fmt.parseInt(u64, device[colon + 1 ..], 16);
            const inode = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
            const name = std.mem.trim(u8, fields.rest(), " \t\n");
            if (perms.len != 4) return error.InvalidMaps;
            try new_regions.append(self.allocator, .{ .start = start, .end = end, .offset = offset, .inode = inode, .device_major = device_major, .device_minor = device_minor, .permissions = perms[0..4].*, .path = try self.allocator.dupe(u8, name) });
        }
        if (c.ferror(file) != 0) return error.ProcessMapsUnavailable;
        self.pruneFileKinds(new_regions.items);
        self.clearFailures();
        self.relabelRegions(new_regions.items);
        for (self.regions.items) |r| self.allocator.free(r.path);
        self.regions.deinit(self.allocator);
        self.regions = new_regions;
        self.budget_dirty = true;
        self.maps_revision +|= 1;
        self.pe_scan_next = 0;
    }
    fn relabelRegions(self: *const Modules, new_regions: []Region) void {
        for (new_regions) |*region| {
            for (self.regions.items) |old| if (old.full_image_deferred and sameFile(old, region.*)) {
                region.full_image_deferred = true;
                break;
            };
        }
        // Describe retained evidence after a maps refresh; no new file reads.
        for (new_regions) |*region| {
            for (self.loaded.items) |module| {
                if (module.inode == region.inode and module.device_major == region.device_major and
                    module.device_minor == region.device_minor and std.mem.eql(u8, module.path, region.path))
                {
                    region.file_source = module.file_source;
                    break;
                }
            }
            if (region.file_source == .unopened) for (self.symbol_images.items) |item| {
                if (sameFile(region.*, item.region)) {
                    region.file_source = item.region.file_source;
                    break;
                }
            };
        }
    }
    fn recordSource(self: *Modules, region: Region, source: mapped_file.Source) void {
        for (self.regions.items) |*item| if (sameFile(item.*, region)) {
            item.file_source = source;
        };
    }
    pub fn load(self: *Modules, region: Region) !*Module {
        if (region.path.len == 0 or region.path[0] != '/') return error.NoBinaryImage;
        return self.loadRange(region, false) catch |err| {
            self.noteFailure(region, err);
            return err;
        };
    }
    fn clearFailures(self: *Modules) void {
        for (self.load_failures.items) |failure| self.allocator.free(failure.path);
        self.load_failures.clearRetainingCapacity();
    }
    fn noteFailure(self: *Modules, region: Region, err: anyerror) void {
        if (err == error.NotElf or err == error.NoBinaryImage) return;
        if (err == error.BinarySnapshotLimit) {
            for (self.regions.items) |*item| if (sameFile(item.*, region)) {
                if (!item.full_image_deferred) self.budget_dirty = true;
                item.full_image_deferred = true;
            };
        }
        for (self.load_failures.items) |failure| if (std.mem.eql(u8, failure.path, region.path) and std.mem.eql(u8, failure.diagnostic, @errorName(err))) return;
        if (self.load_failures.items.len >= 64) return;
        const path = self.allocator.dupe(u8, region.path) catch return;
        self.load_failures.append(self.allocator, .{ .start = region.start, .end = region.end, .path = path, .diagnostic = @errorName(err) }) catch {
            self.allocator.free(path);
            return;
        };
        if (err != error.BinarySnapshotLimit)
            std.debug.print("xodb: module unavailable: {s}; {s} at 0x{x}\n", .{ @errorName(err), path, region.start });
    }
    /// Summarize full-image refusals once after a scan, with no per-file spam.
    /// Count mapped files independently of the bounded detailed failure list.
    pub fn beginStop(self: *Modules, generation: u64) void {
        self.budget_generation = generation;
    }
    pub fn reportBudget(self: *Modules) void {
        if (!self.budget_dirty or self.budget_reported_generation == self.budget_generation) return;
        self.budget_dirty = false;
        var deferred: usize = 0;
        for (self.regions.items, 0..) |region, i| {
            if (!region.full_image_deferred) continue;
            const duplicate = for (self.regions.items[0..i]) |old| {
                if (old.full_image_deferred and sameFile(old, region)) break true;
            } else false;
            if (!duplicate) deferred += 1;
        }
        if (deferred == 0) {
            self.budget_reported = null;
            return;
        }
        const counts = .{ .loaded = self.loaded.items.len, .deferred = deferred };
        self.budget_reported = .{ .loaded = counts.loaded, .deferred = counts.deferred };
        self.budget_reported_generation = self.budget_generation;
        std.debug.print("xodb: module budget: {d} full images loaded, {d} mapped files deferred\n", .{ counts.loaded, counts.deferred });
    }
    /// A perf record describes one range at one file offset, not the current
    /// collection of VMAs. Do not combine it with the opening/live map snapshot.
    pub fn loadObserved(self: *Modules, region: Region) !*Module {
        if (region.path.len == 0 or region.path[0] != '/') return error.NoBinaryImage;
        return self.loadRange(region, true);
    }
    fn pageSize(self: *const Modules) !u64 {
        const result = rt.xrt_target_page_size(self.target);
        if (result <= 0) return error.BadMapping;
        return @intCast(result);
    }
    fn sameFile(a: Region, b: Region) bool {
        return a.inode == b.inode and a.device_major == b.device_major and a.device_minor == b.device_minor and std.mem.eql(u8, a.path, b.path);
    }
    const Placement = struct { first: Region, end: u64, bias: u64 };
    fn placement(self: *Modules, image: *const elf.Image, file_offset: u64, region: Region, observed: bool) !Placement {
        if (region.offset < file_offset) return error.BadMapping;
        var relative = region;
        relative.offset -= file_offset;
        if (observed) return .{ .first = region, .end = region.end, .bias = try observedBias(image, relative) };
        const page = try self.pageSize();
        var first_segment: ?elf.Segment = null;
        for (0..image.header.segment_count) |i| {
            const segment = try image.segment(@intCast(i));
            if (segment.type == .load and (first_segment == null or segment.vaddr < first_segment.?.vaddr)) first_segment = segment;
        }
        const segment = first_segment orelse return error.NoLoadSegment;
        const header_offset = std.math.add(u64, file_offset, segment.offset - segment.offset % page) catch return error.BadMapping;
        var found: ?Placement = null;
        for (self.regions.items) |r| {
            if (!sameFile(r, region) or r.offset != header_offset) continue;
            const bias = image.loadBias(r.start, r.offset - file_offset) catch continue;
            if (!mappingFits(image, relative, bias, page)) continue;
            if (found != null and found.?.bias != bias) return error.AmbiguousLoadBias;
            found = .{ .first = r, .end = r.end, .bias = bias };
        }
        var result = found orelse return error.BadMapping;
        for (self.regions.items) |r| {
            if (!sameFile(r, region) or r.offset < file_offset) continue;
            var rel = r;
            rel.offset -= file_offset;
            if (!mappingFits(image, rel, result.bias, page)) continue;
            if (r.start < result.first.start) result.first = r;
            result.end = @max(result.end, r.end);
        }
        return result;
    }
    fn mappingFits(image: *const elf.Image, r: Region, bias: u64, page: u64) bool {
        if (r.end <= r.start) return false;
        for (0..image.header.segment_count) |i| {
            const segment = image.segment(@intCast(i)) catch continue;
            if (segment.type != .load or segment.file_size == 0) continue;
            if (r.permissions[2] == 'x' and segment.flags & elf.pf.x == 0) continue;
            if (r.permissions[1] == 'w' and segment.flags & elf.pf.w == 0) continue;
            const low = segment.offset - segment.offset % page;
            const segment_end = std.math.add(u64, segment.offset, segment.file_size) catch continue;
            const high = std.math.add(u64, segment_end, page - 1) catch continue;
            const file_end = high - high % page;
            if (r.offset < low or r.offset >= file_end or r.end - r.start > file_end - r.offset) continue;
            const virtual = std.math.sub(u64, segment.vaddr, segment.offset - low) catch continue;
            const address = std.math.add(u64, bias, virtual) catch continue;
            if ((std.math.add(u64, address, r.offset - low) catch continue) == r.start) return true;
        }
        return false;
    }
    fn cachedRange(self: *Modules, region: Region, observed: bool) ?*Module {
        for (self.loaded.items) |m| {
            if (m.inode != region.inode or m.device_major != region.device_major or m.device_minor != region.device_minor or (self.core_source == null and !std.mem.eql(u8, m.path, region.path))) continue;
            const p = self.placement(&m.image, m.file_offset, region, observed) catch continue;
            if (m.start == p.first.start and m.end >= p.end and m.bias == p.bias) return m;
        }
        return null;
    }
    fn loadRange(self: *Modules, region: Region, observed: bool) !*Module {
        if (self.cachedRange(region, observed)) |module| return module;
        const expected = if (self.core_source != null) try self.coreId(region.path) else null;
        const selected_path = if (self.core_executable) |exe| (if (expected != null and std.mem.eql(u8, expected.?, exe.id)) exe.path else region.path) else region.path;
        const path = try self.allocator.dupeZ(u8, selected_path);
        errdefer self.allocator.free(path);
        // Only read the inode actually mapped by the target. map_files can need
        // privileges unavailable to run-as, so exe/path retain inode checks.
        var source: mapped_file.Source = if (self.core_source != null) .core_path else .unopened;
        const fd = if (self.core_source != null) c.open(path, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK) else try mapped_file.openResolved(self.target, self.pid, region, null, &source);
        if (fd < 0) return error.BinaryIdentityUnavailable;
        defer _ = c.close(fd);
        try self.verifySymbolIdentity(region, fd);
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_size <= 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return error.BinaryUnavailable;
        var signature: [4]u8 = undefined;
        if (c.pread(fd, &signature, signature.len, 0) != signature.len) return error.NotElf;
        const entry: apk.Entry = if (std.mem.eql(u8, &signature, "\x7fELF")) .{ .offset = 0, .size = @intCast(stat.st_size) } else try apk.find(self.allocator, fd, @intCast(stat.st_size), region.offset);
        if (entry.offset % try self.pageSize() != 0) return error.ApkEntryNotPageAligned;
        if (self.core_source == null and !rt.xrt_target_is_remote(self.target)) {
            var identity: rt.struct_xrt_file_identity = undefined;
            try runtime_api.check(rt.xrt_file_identity(fd, &identity));
            try self.rememberMetadataIdentity(region, identity);
        }
        // MAP_PRIVATE still faults against the file after truncation. Parsed
        // ELF/libdw slices must only reference owned, bounded snapshots.
        const mapped = try snapshot.readRange(fd, entry.offset, entry.size, @min(snapshot.per_image_limit, snapshot.total_limit - self.snapshot_bytes), null);
        errdefer _ = c.munmap(mapped.ptr, mapped.len);
        // The source may change between the pre-read identity check and the
        // snapshot reader's own initial stat. Recheck the retained version too.
        try self.verifySymbolIdentity(region, fd);
        if (entry.offset != 0) {
            var after: c.struct_stat = undefined;
            if (c.fstat(fd, &after) != 0 or stat.st_size != after.st_size or
                stat.st_mtim.tv_sec != after.st_mtim.tv_sec or stat.st_mtim.tv_nsec != after.st_mtim.tv_nsec or
                stat.st_ctim.tv_sec != after.st_ctim.tv_sec or stat.st_ctim.tv_nsec != after.st_ctim.tv_nsec) return error.BinaryChangedDuringRead;
        }
        const image = try elf.Image.parse(mapped);
        if (expected) |id| if (!std.mem.eql(u8, id, image.buildId() orelse return error.CoreModuleBuildIdMissing)) return error.CoreModuleBuildIdMismatch;
        if (@intFromEnum(image.header.machine) != (self.expected_machine orelse rt.xrt_target_arch(self.target).*.machine)) return error.UnsupportedTargetArchitecture;
        const p = try self.placement(&image, entry.offset, region, observed);
        const module = try self.allocator.create(Module);
        errdefer self.allocator.destroy(module);
        module.* = .{ .id = try self.moduleId(region, p.bias, entry.offset), .inode = region.inode, .device_major = region.device_major, .device_minor = region.device_minor, .path = path, .image = image, .bias = p.bias, .start = p.first.start, .end = p.end, .mapping = mapped, .file_offset = entry.offset, .immutable = self.immutable };
        module.file_source = source;
        if (self.debug_files) |files| {
            module.debug_file = (if (entry.offset == 0) self.companionFor(region, &image, path) else files.matching(&image)) catch |err| blk: {
                std.debug.print("xodb: debug companion rejected: {s}; {s} offset=0x{x}\n", .{ @errorName(err), path, entry.offset });
                break :blk null;
            };
            if (module.debug_file) |file| std.debug.print("xodb: debug companion {s} matched {s} offset=0x{x}\n", .{ file.path, path, entry.offset });
        }
        try self.loaded.append(self.allocator, module);
        self.snapshot_bytes += mapped.len;
        self.budget_dirty = true;
        self.recordSource(region, source);
        for (self.regions.items) |*item| if (sameFile(item.*, region)) {
            item.full_image_deferred = false;
        };
        return module;
    }
    /// A later executable mapping need not be the ELF's first PT_LOAD. Accept
    /// only a unique bias from executable segments covering its file pages.
    pub fn observedBias(image: *const elf.Image, region: Region) !u64 {
        const page_result = c.sysconf(c._SC_PAGESIZE);
        if (page_result <= 0 or region.start >= region.end) return error.BadMapping;
        const page: u64 = @intCast(page_result);
        var found: ?u64 = null;
        var i: u32 = 0;
        while (i < image.header.segment_count) : (i += 1) {
            const segment = try image.segment(i);
            if (segment.type != .load or segment.flags & 1 == 0 or segment.file_size == 0) continue;
            const low = segment.offset - segment.offset % page;
            const file_end = std.math.add(u64, segment.offset, segment.file_size) catch continue;
            const padded = std.math.add(u64, file_end, page - 1) catch continue;
            const high = padded - padded % page;
            if (region.offset < low or region.offset >= high or region.end - region.start > high - region.offset) continue;
            const virtual = if (region.offset >= segment.offset)
                std.math.add(u64, segment.vaddr, region.offset - segment.offset) catch continue
            else
                std.math.sub(u64, segment.vaddr, segment.offset - region.offset) catch continue;
            if (region.start < virtual) continue;
            const bias = region.start - virtual;
            if (found != null and found.? != bias) return error.AmbiguousLoadBias;
            found = bias;
        }
        return found orelse error.BadMapping;
    }
    /// Match both mapped identity and placement without opening a target file.
    pub fn cachedAt(self: *Modules, address: u64) !*Module {
        for (self.regions.items) |region| if (address >= region.start and address < region.end)
            return self.cachedRange(region, false) orelse error.DebugMetadataNotLoaded;
        return error.UnmappedAddress;
    }
    pub fn at(self: *Modules, address: u64) !*Module {
        if (self.cachedAt(address)) |module| return module else |_| {}
        if (self.peAt(address)) |_| return error.PeDebugInfoUnavailable else |err| if (err != error.NotPe) return err;
        for (self.regions.items) |r| if (address >= r.start and address < r.end) return self.load(r);
        return error.UnmappedAddress;
    }
    /// Keep ordinary stripped-library stack frames on the bounded CFI path.
    /// Full DWARF (including verified companions) retains source/inline views.
    pub fn prefersUnwindMetadata(self: *Modules, address: u64) !bool {
        if (self.immutable or self.target == null or rt.xrt_target_is_remote(self.target)) return false;
        for (self.regions.items) |region| {
            if (address < region.start or address >= region.end) continue;
            if (self.cachedRange(region, false) != null) return false;
            const image = try self.symbolImage(region);
            const index = try self.fileIdentity(region);
            self.syncCompanionPolicy(index);
            if (self.identities.items[index].metadata_only) |decision| return decision;
            const has_dwarf = image.sectionByName(".debug_info") != null or image.sectionByName(".zdebug_info") != null or
                image.sectionByName(".debug_frame") != null or image.sectionByName(".zdebug_frame") != null;
            const full = has_dwarf or (self.companionFor(region, image, region.path) catch null) != null;
            self.identities.items[index].metadata_only = !full;
            return !full;
        }
        return error.UnmappedAddress;
    }
    fn identityIndex(self: *const Modules, region: Region) ?usize {
        for (self.identities.items, 0..) |file, i| if (sameFile(file.region, region)) return i;
        return null;
    }
    fn fileIdentity(self: *Modules, region: Region) !usize {
        if (self.identityIndex(region)) |index| return index;
        if (self.identities.items.len >= 1024) return error.SymbolSnapshotLimit;
        var saved = region;
        saved.path = try self.allocator.dupe(u8, region.path);
        errdefer self.allocator.free(saved.path);
        const index = self.identities.items.len;
        try self.identities.append(self.allocator, .{ .region = saved });
        return index;
    }
    fn syncCompanionPolicy(self: *Modules, index: usize) void {
        const file = &self.identities.items[index];
        const revision = if (self.debug_files) |files| files.lookup_revision else 0;
        const automatic = if (self.debug_files) |files| files.automatic else false;
        if (file.companion_owner != self.debug_files or file.companion_revision != revision or file.companion_automatic != automatic) {
            file.companion_owner = self.debug_files;
            file.companion_revision = revision;
            file.companion_automatic = automatic;
            file.companion = null;
            file.metadata_only = null;
        }
    }
    fn companionFor(self: *Modules, region: Region, image: *const elf.Image, path: []const u8) !?*const @import("../binary/debug_files.zig").File {
        const files = self.debug_files orelse return null;
        const index = try self.fileIdentity(region);
        self.syncCompanionPolicy(index);
        if (self.identities.items[index].companion) |decision| return switch (decision) {
            .absent => null,
            .found => |file| file,
            .failure => |err| err,
        };
        const found = files.discover(image, path) catch |err| {
            self.identities.items[index].companion = .{ .failure = err };
            return err;
        };
        self.identities.items[index].companion = if (found) |file| .{ .found = file } else .absent;
        return found;
    }
    /// File versions and mapped-instance IDs outlive both symbol and CFI data.
    pub fn rememberMetadataIdentity(self: *Modules, region: Region, identity: rt.struct_xrt_file_identity) !void {
        if (self.symbol_pending) |pending| if (sameFile(pending.region, region) and !std.meta.eql(pending.identity, identity)) return error.BinaryChangedDuringRead;
        const index = try self.fileIdentity(region);
        const file = &self.identities.items[index];
        if (file.identity) |original| {
            if (!std.meta.eql(original, identity)) return error.BinaryChangedDuringRead;
        } else if (file.remote_snapshot) return error.BinaryIdentityUnavailable;
        file.identity = identity;
    }
    pub fn findSymbol(self: *Modules, name: []const u8) !Symbol {
        defer self.reportBudget();
        if (rt.xrt_target_is_remote(self.target) or !self.immutable) {
            var cursor = SymbolCursor{};
            return self.symbolLookup(name, false, &cursor);
        }
        // APKs have no offset-zero ELF mapping. Executable VMAs identify their
        // embedded libraries; Modules.load deduplicates the other mappings.
        var failure: ?anyerror = null;
        for (self.regions.items) |r| {
            if ((r.offset != 0 and r.permissions[2] != 'x') or r.path.len == 0 or r.path[0] != '/') continue;
            const module = self.load(r) catch |err| {
                if (err != error.NotElf and err != error.NoBinaryImage and failure == null) failure = err;
                continue;
            };
            const symbol = module.symbols().findSymbol(name) orelse continue;
            if (!symbol.hasAddress()) continue;
            return publishedSymbol(module.image.header.machine, module.id, symbol, try module.runtimeAddress(symbol.value));
        }
        return failure orelse error.SymbolNotFound;
    }
    fn symbolImage(self: *Modules, region: Region) !*const elf.Image {
        for (self.symbol_images.items) |*item| if (sameFile(item.region, region)) {
            self.touchSymbols(item);
            return &item.image;
        };
        const file_index = try self.fileIdentity(region);
        const path = try self.allocator.dupeZ(u8, region.path);
        defer self.allocator.free(path);
        const request = std.mem.zeroInit(rt.struct_xrt_file_request, .{
            .kind = rt.XRT_FILE_MAPPED,
            .mapping = .{ .start = region.start, .end = region.end, .offset = region.offset, .device_major = region.device_major, .device_minor = region.device_minor, .inode = region.inode, .path = path.ptr },
        });
        var fd: c_int = -1;
        var resident: u64 = 0;
        var source: mapped_file.Source = .remote_snapshot;
        var identity: ?rt.struct_xrt_file_identity = null;
        if (rt.xrt_target_is_remote(self.target)) {
            try runtime_api.check(rt.xrt_remote_symbol_file(self.target, &request, &fd, &resident));
        } else {
            var pinned: rt.struct_xrt_file_identity = undefined;
            try self.localSymbolFile(region, &request, &fd, &resident, &source, &pinned, self.identities.items[file_index].identity);
            identity = pinned;
        }
        defer _ = c.close(fd);
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_size <= 0 or stat.st_blocks < 0) return error.BinaryUnavailable;
        // Sparse files may allocate a whole page for each tiny distant table.
        // Charge backing pages as well as copied bytes, never the hole extent.
        const retained = @max(resident, std.math.mul(u64, @intCast(stat.st_blocks), 512) catch return error.SymbolSnapshotLimit);
        if (retained > self.symbol_limit) return error.SymbolSnapshotLimit;
        const size: usize = @intCast(stat.st_size);
        const ptr = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
        if (ptr == c.MAP_FAILED) return error.OutOfMemory;
        const bytes: []align(std.heap.page_size_min) u8 = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(ptr)))[0..size];
        errdefer _ = c.munmap(bytes.ptr, bytes.len);
        const image = try elf.Image.parse(bytes);
        if (@intFromEnum(image.header.machine) != rt.xrt_target_arch(self.target).*.machine) return error.UnsupportedTargetArchitecture;
        try self.trimSymbols(retained);
        if (identity) |id| try self.rememberMetadataIdentity(region, id) else self.identities.items[file_index].remote_snapshot = true;
        var saved = region;
        saved.path = try self.allocator.dupe(u8, region.path);
        errdefer self.allocator.free(saved.path);
        saved.file_source = source;
        try self.symbol_images.append(self.allocator, .{ .region = saved, .file = file_index, .bytes = bytes, .image = image, .retained = retained });
        self.touchSymbols(&self.symbol_images.items[self.symbol_images.items.len - 1]);
        self.symbol_bytes += retained;
        self.recordSource(region, source);
        return &self.symbol_images.items[self.symbol_images.items.len - 1].image;
    }
    fn touchSymbols(self: *Modules, item: *SymbolImage) void {
        self.symbol_clock +|= 1;
        item.last_used = self.symbol_clock;
    }
    pub fn cachedSymbolCount(self: *const Modules) usize {
        return self.symbol_images.items.len;
    }
    fn trimSymbols(self: *Modules, needed: u64) !void {
        if (needed > self.symbol_limit) return error.SymbolSnapshotLimit;
        while (self.symbol_bytes > self.symbol_limit - needed) {
            var oldest: ?usize = null;
            // Remote symbol projections lack an original-file identity and
            // stay pinned; reopening could mix two versions under one ID.
            for (self.symbol_images.items, 0..) |item, i| if (self.identities.items[item.file].identity != null) {
                if (oldest == null or item.last_used < self.symbol_images.items[oldest.?].last_used) oldest = i;
            };
            const index = oldest orelse return error.SymbolSnapshotLimit;
            const item = self.symbol_images.swapRemove(index);
            _ = c.munmap(item.bytes.ptr, item.bytes.len);
            self.symbol_bytes -= item.retained;
            self.symbol_evictions +|= 1;
            var source: mapped_file.Source = .unopened;
            for (self.loaded.items) |module| {
                if (module.inode == item.region.inode and module.device_major == item.region.device_major and
                    module.device_minor == item.region.device_minor and std.mem.eql(u8, module.path, item.region.path))
                {
                    source = module.file_source;
                    break;
                }
            }
            self.recordSource(item.region, source);
            self.allocator.free(item.region.path);
        }
    }
    fn verifySymbolIdentity(self: *const Modules, region: Region, fd: c_int) !void {
        const index = self.identityIndex(region) orelse return;
        const expected = self.identities.items[index].identity orelse return;
        var current: rt.struct_xrt_file_identity = undefined;
        try runtime_api.check(rt.xrt_file_identity(fd, &current));
        if (!std.meta.eql(expected, current)) return error.BinaryChangedDuringRead;
    }
    fn retainSymbol(self: *Modules, value: Symbol) !Symbol {
        var result = value;
        if (self.symbol_names.getKey(value.name)) |key| {
            result.name = key;
            return result;
        }
        if (self.symbol_names.count() >= 65536 or value.name.len > 16 * 1024 * 1024 - self.symbol_name_bytes) return error.SymbolNameLimit;
        const name = try self.allocator.dupe(u8, value.name);
        errdefer self.allocator.free(name);
        try self.symbol_names.put(self.allocator, name, {});
        self.symbol_name_bytes += name.len;
        result.name = name;
        return result;
    }
    fn cancelSymbolJob(self: *Modules) void {
        if (self.symbol_pending) |pending| {
            rt.xrt_symbol_job_destroy(pending.job);
            self.allocator.free(pending.region.path);
            self.symbol_pending = null;
        }
    }
    fn localSymbolFile(self: *Modules, region: Region, request: *const rt.struct_xrt_file_request, fd: *c_int, resident: *u64, source: *mapped_file.Source, identity: *rt.struct_xrt_file_identity, expected: ?rt.struct_xrt_file_identity) !void {
        if (self.symbol_pending) |pending| {
            if (!sameFile(pending.region, region)) self.cancelSymbolJob();
        }
        if (self.symbol_pending == null) {
            var view: ?*rt.struct_xrt_file_view = null;
            try runtime_api.check(rt.xrt_target_file_view_open(self.target, request, &view));
            const pinned = rt.xrt_file_view_identity(view).*;
            if (expected) |old| if (!std.meta.eql(old, pinned)) {
                _ = rt.xrt_file_view_close(view);
                return error.BinaryChangedDuringRead;
            };
            // Ordinary local symbol lookups stay immediate while retaining only
            // metadata. Large files keep the existing cancellable worker path.
            if (rt.xrt_file_view_identity(view).*.size <= snapshot.per_image_limit) {
                defer _ = rt.xrt_file_view_close(view);
                try runtime_api.check(rt.xrt_local_symbol_file(view, fd, resident));
                source.* = mapped_file.Source.fromRuntime(rt.xrt_file_view_source(view));
                identity.* = pinned;
                return;
            }
            errdefer _ = rt.xrt_file_view_close(view);
            const path = try self.allocator.dupe(u8, region.path);
            errdefer self.allocator.free(path);
            var job: ?*rt.struct_xrt_symbol_job = null;
            try runtime_api.check(rt.xrt_symbol_job_start(view, &job));
            var saved = region;
            saved.path = path;
            saved.file_source = mapped_file.Source.fromRuntime(rt.xrt_file_view_source(view));
            self.symbol_pending = .{ .region = saved, .job = job.?, .identity = pinned };
        }
        const status = rt.xrt_symbol_job_poll(self.symbol_pending.?.job, fd, resident);
        if (status == rt.XRT_OK) {
            source.* = self.symbol_pending.?.region.file_source;
            identity.* = self.symbol_pending.?.identity;
        }
        if (status != rt.XRT_DISCOVERY_PENDING) self.cancelSymbolJob();
        try runtime_api.check(status);
    }
    // Reserve one ID per mapped instance. Loading its complete ELF/DWARF view
    // later must preserve the ID already cited by a remote symbol lookup.
    fn moduleId(self: *Modules, region: Region, bias: u64, file_offset: u64) !u64 {
        const index = try self.fileIdentity(region);
        const file = &self.identities.items[index];
        for (file.instances.items) |instance| if (instance.bias == bias and instance.file_offset == file_offset) return instance.id;
        if (file.instances.items.len >= 1024) return error.SymbolSnapshotLimit;
        const id = self.next_id;
        const next = std.math.add(u64, id, 1) catch return error.SymbolSnapshotLimit;
        try file.instances.append(self.allocator, .{ .bias = bias, .file_offset = file_offset, .id = id });
        self.next_id = next;
        return id;
    }
    /// Automatic lookup can span multiple passes. Completed immutable symbol
    /// views are reused; a policy stop must return immediately so the next pass
    /// can resume the same unfinished file.
    pub const SymbolCursor = struct { next: usize = 0, failure: ?anyerror = null };
    pub fn automaticSymbolAddress(self: *Modules, name: []const u8, cursor: *SymbolCursor) !u64 {
        defer self.reportBudget();
        const found = try self.symbolLookup(name, true, cursor);
        // ELFv2 function symbols are the global entry. Planting there misses a
        // local call, which skips the TOC setup. The local entry is inside the
        // same function, and a global call falls through it.
        return std.math.add(u64, found.address, found.entry) catch error.InvalidAddress;
    }
    /// Restoring an address needs image identity and load placement, not code
    /// or DWARF. Use the resumable symbol projection for remote files so the
    /// whole image cannot exceed an automatic-discovery slice's byte budget.
    pub fn restoredAddress(self: *Modules, region: Region, build_id: []const u8, offset: u64) !u64 {
        const symbols = if (rt.xrt_target_is_remote(self.target)) self.symbolImage(region) catch |err| blk: {
            // APKs keep their existing full-image reader and policy limits.
            if (err == error.UnsupportedMode) break :blk null;
            return err;
        } else null;
        if (symbols) |image| {
            const id = image.buildId() orelse return error.BreakpointImageHasNoBuildId;
            if (!std.mem.eql(u8, id, build_id)) return error.BreakpointBuildIdMismatch;
            const p = try self.placement(image, 0, region, false);
            return std.math.add(u64, offset, p.bias) catch error.InvalidAddress;
        }
        const module = try self.load(region);
        const id = module.image.buildId() orelse return error.BreakpointImageHasNoBuildId;
        if (!std.mem.eql(u8, id, build_id)) return error.BreakpointBuildIdMismatch;
        return module.runtimeAddress(offset);
    }
    fn symbolLookup(self: *Modules, name: []const u8, automatic: bool, cursor: *SymbolCursor) !Symbol {
        var failure = cursor.failure;
        defer cursor.failure = failure;
        regions: while (cursor.next < self.regions.items.len) : (cursor.next += 1) {
            const r = self.regions.items[cursor.next];
            // Reuse an existing full image (and its verified debug companion).
            for (self.loaded.items) |module| {
                if (r.inode != module.inode or r.device_major != module.device_major or
                    r.device_minor != module.device_minor or !std.mem.eql(u8, r.path, module.path)) continue;
                const p = self.placement(&module.image, module.file_offset, r, false) catch continue;
                if (p.bias != module.bias) continue;
                if (module.symbols().findSymbol(name)) |symbol| {
                    if (symbol.hasAddress()) return publishedSymbol(module.image.header.machine, module.id, symbol, try module.runtimeAddress(symbol.value));
                }
                continue :regions;
            }
            if ((r.offset != 0 and r.permissions[2] != 'x') or
                r.path.len == 0 or r.path[0] != '/' or
                std.mem.startsWith(u8, r.path, "/dev/") or
                std.mem.startsWith(u8, r.path, "/memfd:") or
                std.mem.endsWith(u8, r.path, " (deleted)")) continue;
            if (!rt.xrt_target_is_remote(self.target) and (self.immutable or self.target == null)) {
                if (automatic and r.permissions[2] != 'x') continue;
                const module = self.load(r) catch |err| {
                    if (err != error.NotElf and err != error.NoBinaryImage and failure == null) failure = err;
                    continue;
                };
                const symbol = module.symbols().findSymbol(name) orelse continue;
                if (symbol.hasAddress()) return publishedSymbol(module.image.header.machine, module.id, symbol, try module.runtimeAddress(symbol.value));
                continue;
            }
            if (r.offset == 0 and !rt.xrt_target_is_remote(self.target)) {
                if (self.peRegion(r)) |entry| {
                    if (try self.peFindSymbol(entry, name)) |found| return found;
                    continue;
                } else |err| switch (err) {
                    error.NotPe => {},
                    error.SymbolDiscoveryPending => return err,
                    else => {
                        if (failure == null) failure = err;
                        continue;
                    },
                }
            }
            // Offset-0 data mappings are admitted above for PE headers only.
            if ((automatic and r.permissions[2] != 'x') or self.file_kinds.get(fileKey(r)) == .pe) continue;
            const image = self.symbolImage(r) catch |err| {
                switch (err) {
                    error.SymbolDiscoveryPending, error.SymbolDiscoveryCancelled, error.SymbolDiscoveryBudgetExceeded => return err,
                    error.UnsupportedMode => {
                        // APKs retain the existing full-image path and limits.
                        const module = self.load(r) catch |load_err| {
                            if (failure == null) failure = load_err;
                            continue;
                        };
                        if (module.symbols().findSymbol(name)) |symbol| {
                            if (symbol.hasAddress()) return publishedSymbol(module.image.header.machine, module.id, symbol, try module.runtimeAddress(symbol.value));
                        }
                    },
                    error.NotElf, error.BinaryIdentityUnavailable => {},
                    else => if (failure == null) {
                        failure = err;
                    },
                }
                continue;
            };
            const symbols = if (self.debug_files != null) blk: {
                const companion = self.companionFor(r, image, r.path) catch null;
                break :blk if (companion) |file| &file.image else image;
            } else image;
            const symbol = symbols.findSymbol(name) orelse continue;
            if (!symbol.hasAddress()) continue;
            const p = self.placement(image, 0, r, false) catch |err| {
                if (failure == null) failure = err;
                continue;
            };
            return self.retainSymbol(publishedSymbol(symbols.header.machine, try self.moduleId(r, p.bias, 0), symbol, std.math.add(u64, symbol.value, p.bias) catch return error.InvalidAddress));
        }
        return failure orelse if (automatic) error.BreakpointSymbolNotLoaded else error.SymbolNotFound;
    }
    fn fileKey(region: Region) FileKey {
        return .{ .inode = region.inode, .device_major = region.device_major, .device_minor = region.device_minor };
    }
    /// Which reader, if any, applies to a mapped file. Decided once from its
    /// first bytes and shared by the ELF and PE paths, so a stop never
    /// reopens a file only to learn again that it is neither.
    fn fileKind(self: *Modules, region: Region) !FileKind {
        if (self.file_kinds.get(fileKey(region))) |kind| return kind;
        const path = try self.allocator.dupeZ(u8, region.path);
        defer self.allocator.free(path);
        const request = std.mem.zeroInit(rt.struct_xrt_file_request, .{
            .kind = rt.XRT_FILE_MAPPED,
            .mapping = .{ .start = region.start, .end = region.end, .offset = region.offset, .device_major = region.device_major, .device_minor = region.device_minor, .inode = region.inode, .path = path.ptr },
        });
        var view: ?*rt.struct_xrt_file_view = null;
        try runtime_api.check(rt.xrt_target_file_view_open(self.target, &request, &view));
        defer _ = rt.xrt_file_view_close(view);
        var magic: [4]u8 = @splat(0);
        const size: usize = @intCast(@min(@max(rt.xrt_file_view_identity(view).*.size, 0), magic.len));
        try runtime_api.check(rt.xrt_file_view_read(view, 0, &magic, size));
        const kind: FileKind = if (std.mem.eql(u8, &magic, "\x7fELF")) .elf else if (std.mem.eql(u8, magic[0..2], "MZ")) .pe else .other;
        if (self.file_kinds.count() >= max_file_kinds) self.file_kinds.clearRetainingCapacity();
        try self.file_kinds.put(self.allocator, fileKey(region), kind);
        self.file_kind_reads +|= 1;
        return kind;
    }
    /// A mapping pins its inode; once a file leaves the address space its
    /// number may name another file, so the decision is dropped with it.
    fn pruneFileKinds(self: *Modules, regions: []const Region) void {
        if (self.file_kinds.count() == 0) return;
        var mapped: std.AutoHashMapUnmanaged(FileKey, void) = .empty;
        defer mapped.deinit(self.allocator);
        for (regions) |region| if (region.inode != 0) mapped.put(self.allocator, fileKey(region), {}) catch {
            self.file_kinds.clearRetainingCapacity();
            return;
        };
        var it = self.file_kinds.keyIterator();
        while (it.next()) |key| if (!mapped.contains(key.*)) self.file_kinds.removeByPtr(key);
    }
    fn peRegion(self: *Modules, region: Region) !*pe.Entry {
        if (self.immutable or self.target == null or rt.xrt_target_is_remote(self.target)) return error.NotPe;
        if (region.offset != 0 or region.inode == 0 or region.path.len == 0 or region.path[0] != '/') return error.NotPe;
        if (try self.fileKind(region) != .pe) return error.NotPe;
        const entry = try self.pe_images.get(self.allocator, self.target, region);
        try self.pe_images.bind(entry, self.target.?, self.regions.items, self.maps_revision, &self.next_id);
        const image = entry.image().?;
        const size = c.xpe_info(image).*.image_size;
        for (self.regions.items) |*row| {
            if (row.start < entry.start or row.start - entry.start >= size or row.end - entry.start > size) continue;
            if (entry.contains(row.start)) row.pe_image = .{ .id = entry.id, .base = entry.start, .path = entry.path };
        }
        self.recordSource(region, entry.source);
        return entry;
    }
    pub fn peAt(self: *Modules, address: u64) !*pe.Entry {
        if (self.immutable or self.target == null or rt.xrt_target_is_remote(self.target)) return error.NotPe;
        for (self.pe_images.entries.items) |entry| {
            if (entry.verified_revision == self.maps_revision and entry.contains(address)) return entry;
        }
        const mapped = for (self.regions.items) |region| {
            if (address >= region.start and address < region.end) break region;
        } else return error.NotPe;
        if (mapped.path.len != 0 and mapped.path[0] != '/') return error.NotPe;
        var next = self.regions.items.len;
        var attempts: usize = 0;
        while (next > 0) {
            next -= 1;
            const region = self.regions.items[next];
            if (region.start > address) continue;
            if (address - region.start > std.math.maxInt(u32)) break;
            if (region.offset != 0 or region.inode == 0 or region.path.len == 0 or region.path[0] != '/') continue;
            if (mapped.inode != 0 and !sameFile(mapped, region)) continue;
            // Only a file not classified yet costs an open.
            if (!self.file_kinds.contains(fileKey(region))) {
                attempts += 1;
                if (attempts > 64) return error.PeDiscoveryLimit;
            }
            const entry = self.peRegion(region) catch |err| {
                if (err == error.NotPe) continue;
                return err;
            };
            if (entry.contains(address)) return entry;
        }
        return error.NotPe;
    }
    pub fn peDiscoveryPending(self: *const Modules) bool {
        return self.pe_images.pending != null or self.pe_scan_next < self.regions.items.len;
    }
    pub fn discoverPe(self: *Modules) void {
        if (self.immutable or self.target == null or rt.xrt_target_is_remote(self.target)) {
            self.pe_scan_next = self.regions.items.len;
            return;
        }
        self.pe_images.poll();
        var checked: usize = 0;
        while (self.pe_scan_next < self.regions.items.len and checked < 8) : (self.pe_scan_next += 1) {
            const region = self.regions.items[self.pe_scan_next];
            if (region.offset != 0 or region.inode == 0 or region.path.len == 0 or region.path[0] != '/' or
                std.mem.startsWith(u8, region.path, "/dev/") or std.mem.startsWith(u8, region.path, "/memfd:")) continue;
            checked += 1;
            _ = self.peRegion(region) catch |err| {
                if (err == error.SymbolDiscoveryPending) return;
                if (err != error.NotPe) self.noteFailure(region, err);
                continue;
            };
        }
    }
    fn peFindSymbol(self: *Modules, entry: *pe.Entry, name: []const u8) !?Symbol {
        var requested = name;
        if (std.mem.indexOfScalar(u8, name, '!')) |bang| {
            if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(entry.path), name[0..bang])) return null;
            requested = name[bang + 1 ..];
        }
        const z = try self.allocator.dupeZ(u8, requested);
        defer self.allocator.free(z);
        const image = entry.image() orelse return error.SymbolDiscoveryPending;
        const found = c.xpe_find_export(image, z) orelse return null;
        if (found.*.forwarder != null) return error.PeForwardedExportUnavailable;
        const address = std.math.add(u64, entry.start, found.*.rva) catch return error.InvalidAddress;
        if (!entry.contains(address)) return error.PeImagePlacementMismatch;
        const function = c.xpe_function_at(image, found.*.rva);
        const size: u64 = if (function != null and function.*.begin == found.*.rva) function.*.end - function.*.begin else 0;
        return try self.retainSymbol(.{ .module_id = entry.id, .name = requested, .address = address, .size = size });
    }
    fn peSymbolAt(self: *Modules, entry: *pe.Entry, address: u64) !Symbol {
        const image = entry.image() orelse return error.SymbolDiscoveryPending;
        const rva: u32 = @intCast(address - entry.start);
        const function = c.xpe_function_at(image, rva);
        const begin: u32 = if (function != null) function.*.begin else rva;
        const exported = c.xpe_export_name_at(image, begin);
        const label: ?[]const u8 = if (exported != null) std.mem.span(exported) else null;
        if (label == null and function == null) return error.SymbolNotFound;
        const text = if (label) |value|
            try std.fmt.allocPrint(self.allocator, "{s}!{s}", .{ std.fs.path.basename(entry.path), value })
        else
            try std.fmt.allocPrint(self.allocator, "{s}!sub_{x}", .{ std.fs.path.basename(entry.path), begin });
        defer self.allocator.free(text);
        return self.retainSymbol(.{ .module_id = entry.id, .name = text, .address = entry.start + begin, .size = if (function != null) function.*.end - begin else 0, .offset = rva - begin });
    }
    /// Symbols already retained by discovery; never fetch a library for a label.
    pub fn cachedSymbolAt(self: *Modules, address: u64) !Symbol {
        for (self.pe_images.entries.items) |entry| if (entry.verified_revision == self.maps_revision and entry.contains(address)) return self.peSymbolAt(entry, address);
        if (self.cachedAt(address)) |_| return self.symbolAt(address) else |_| {}
        for (self.regions.items) |region| {
            if (address < region.start or address >= region.end) continue;
            for (self.symbol_images.items) |*item| {
                if (!sameFile(item.region, region)) continue;
                self.touchSymbols(item);
                const p = try self.placement(&item.image, 0, region, false);
                if (address < p.bias) return error.InvalidAddress;
                const symbol = item.image.symbolAt(address - p.bias) orelse return error.SymbolNotFound;
                return self.retainSymbol(.{ .module_id = try self.moduleId(region, p.bias, 0), .name = symbol.symbol.name, .address = try std.math.add(u64, p.bias, symbol.symbol.value), .size = symbol.symbol.size, .offset = symbol.offset });
            }
            return error.DebugMetadataNotLoaded;
        }
        return error.UnmappedAddress;
    }
    pub fn symbolAt(self: *Modules, address: u64) !Symbol {
        if (self.peAt(address)) |entry| return self.peSymbolAt(entry, address) else |err| if (err != error.NotPe) return err;
        const module = try self.at(address);
        const symbol = module.symbols().symbolAt(try module.linkAddress(address)) orelse return error.SymbolNotFound;
        var found = publishedSymbol(module.image.header.machine, module.id, symbol.symbol, try module.runtimeAddress(symbol.symbol.value));
        found.offset = symbol.offset;
        return found;
    }
};

test "APK placement keeps two entries and repeated load instances separate" {
    var bytes: [64 + 56 * 2]u8 = @splat(0);
    @memcpy(bytes[0..4], "\x7fELF");
    bytes[4] = 2;
    bytes[5] = 1;
    bytes[6] = 1;
    const wr = struct {
        fn put(b: []u8, comptime T: type, at: usize, v: T) void {
            std.mem.writeInt(T, b[at..][0..@sizeOf(T)], v, .little);
        }
    }.put;
    wr(&bytes, u16, 16, 3);
    wr(&bytes, u16, 18, 62);
    wr(&bytes, u32, 20, 1);
    wr(&bytes, u64, 32, 64);
    wr(&bytes, u16, 52, 64);
    wr(&bytes, u16, 54, 56);
    wr(&bytes, u16, 56, 2);
    for (0..2) |i| {
        const at = 64 + i * 56;
        wr(&bytes, u32, at, 1);
        wr(&bytes, u32, at + 4, if (i == 0) 4 else 5);
        wr(&bytes, u64, at + 8, i * 4096);
        wr(&bytes, u64, at + 16, i * 4096);
        wr(&bytes, u64, at + 32, 4096);
        wr(&bytes, u64, at + 40, 4096);
        wr(&bytes, u64, at + 48, 4096);
    }
    const image = try elf.Image.parse(&bytes);
    var regions: [6]Region = undefined;
    for (&regions, 0..) |*r, i| r.* = .{ .start = 0x100000 + (i / 2) * 0x10000 + (i % 2) * 4096, .end = 0x101000 + (i / 2) * 0x10000 + (i % 2) * 4096, .offset = (if (i < 4) @as(u64, 0x4000) else 0x10000) + (i % 2) * 4096, .inode = 7, .device_major = 1, .device_minor = 1, .permissions = if (i % 2 == 0) "r--p".* else "r-xp".*, .path = "/test.apk" };
    var modules = Modules.init(std.testing.allocator);
    modules.regions = .{ .items = &regions, .capacity = regions.len };
    for (0..3) |i| {
        const entry = if (i < 2) @as(u64, 0x4000) else 0x10000;
        const placed = try modules.placement(&image, entry, regions[i * 2 + 1], false);
        try std.testing.expectEqual(regions[i * 2].start, placed.bias);
        try std.testing.expectEqual(regions[i * 2].start, placed.first.start);
        try std.testing.expectEqual(regions[i * 2 + 1].end, placed.end);
        const observed = try modules.placement(&image, entry, regions[i * 2 + 1], true);
        try std.testing.expectEqual(placed.bias, observed.bias);
    }
    try std.testing.expectError(error.BadMapping, modules.placement(&image, 0x4000, regions[5], false));
}

test "symbol eviction preserves published labels and mapped instance IDs" {
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    modules.symbol_limit = 8192;
    const label = "retained_function";
    for (0..3) |i| {
        const ptr = c.mmap(null, 4096, c.PROT_READ | c.PROT_WRITE, c.MAP_PRIVATE | c.MAP_ANONYMOUS, -1, 0);
        if (ptr == c.MAP_FAILED) return error.OutOfMemory;
        const bytes: snapshot.Bytes = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(ptr)))[0..4096];
        @memcpy(bytes[0..7], "\x7fELF\x02\x01\x01");
        std.mem.writeInt(u16, bytes[16..18], 3, .little);
        std.mem.writeInt(u16, bytes[18..20], 62, .little);
        std.mem.writeInt(u32, bytes[20..24], 1, .little);
        std.mem.writeInt(u16, bytes[52..54], 64, .little);
        @memcpy(bytes[128..][0..label.len], label);
        const path = try modules.allocator.dupe(u8, "/owned.so");
        const region = Region{ .start = 4096, .end = 8192, .offset = 0, .inode = i + 1, .device_major = 1, .device_minor = 1, .permissions = "r-xp".*, .path = path };
        try modules.rememberMetadataIdentity(region, std.mem.zeroes(rt.struct_xrt_file_identity));
        try modules.symbol_images.append(modules.allocator, .{ .region = region, .file = modules.identityIndex(region).?, .bytes = bytes, .image = try elf.Image.parse(bytes), .retained = 4096 });
        modules.touchSymbols(&modules.symbol_images.items[i]);
        modules.symbol_bytes += 4096;
    }
    const file_index = modules.symbol_images.items[1].file;
    const region = modules.identities.items[file_index].region;
    const id = try modules.moduleId(region, 4096, 0);
    const borrowed = modules.symbol_images.items[1].bytes[128..][0..label.len];
    const published = try modules.retainSymbol(.{ .module_id = id, .name = borrowed, .address = 4112, .size = 16 });
    try std.testing.expect(published.name.ptr != borrowed.ptr);
    modules.touchSymbols(&modules.symbol_images.items[0]);
    try modules.trimSymbols(0);
    try std.testing.expectEqual(@as(u64, 8192), modules.symbol_bytes);
    try std.testing.expectEqual(@as(u64, 1), modules.symbol_evictions);
    try std.testing.expectEqual(@as(usize, 2), modules.symbol_images.items.len);
    for (modules.symbol_images.items) |item| try std.testing.expect(item.file != file_index);
    try std.testing.expectEqualStrings(label, published.name);
    try std.testing.expectEqual(id, try modules.moduleId(region, 4096, 0));
    try std.testing.expectEqual(@as(u64, 4112), published.address);
    const fd = c.memfd_create("symbol-version-test", c.MFD_CLOEXEC);
    if (fd < 0) return error.OutOfMemory;
    defer _ = c.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(fd, 4096));
    var original: rt.struct_xrt_file_identity = undefined;
    try runtime_api.check(rt.xrt_file_identity(fd, &original));
    modules.identities.items[file_index].identity = original;
    try modules.verifySymbolIdentity(region, fd);
    try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(fd, 8192));
    try std.testing.expectError(error.BinaryChangedDuringRead, modules.verifySymbolIdentity(region, fd));
}

test "budget summary counts files beyond detailed failure cap and repeated VMAs" {
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    for (0..200) |i| {
        const path = try std.fmt.allocPrint(modules.allocator, "/owned-{d}.so", .{i / 2});
        try modules.regions.append(modules.allocator, .{ .start = i * 4096, .end = (i + 1) * 4096, .offset = i % 2 * 4096, .inode = i / 2 + 1, .device_major = 1, .device_minor = 1, .permissions = "r-xp".*, .path = path });
    }
    for (modules.regions.items) |region| modules.noteFailure(region, error.BinarySnapshotLimit);
    try std.testing.expectEqual(@as(usize, 64), modules.load_failures.items.len);
    modules.reportBudget();
    try std.testing.expectEqual(@as(usize, 100), modules.budget_reported.?.deferred);
    try std.testing.expectEqual(@as(usize, 0), modules.budget_reported.?.loaded);
    modules.reportBudget(); // No second line without a changed count.
    try std.testing.expectEqual(@as(usize, 100), modules.budget_reported.?.deferred);
    for (modules.regions.items) |*region| region.full_image_deferred = false;
    modules.budget_dirty = true;
    modules.reportBudget(); // Same stop cannot print a changed-count series.
    try std.testing.expectEqual(@as(usize, 100), modules.budget_reported.?.deferred);
    try std.testing.expect(modules.budget_dirty);
    modules.beginStop(1);
    modules.reportBudget();
    try std.testing.expect(modules.budget_reported == null);
    try std.testing.expect(!modules.budget_dirty);
}

test "metadata-only identity survives without resident symbol bytes" {
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    const region = Region{ .start = 4096, .end = 8192, .offset = 0, .inode = 7, .device_major = 1, .device_minor = 1, .permissions = "r-xp".*, .path = "/owned-metadata.so" };
    var original = std.mem.zeroes(rt.struct_xrt_file_identity);
    original.size = 4096;
    try modules.rememberMetadataIdentity(region, original);
    try modules.rememberMetadataIdentity(region, original);
    try std.testing.expectEqual(@as(usize, 1), modules.identities.items.len);
    try std.testing.expectEqual(@as(usize, 0), modules.symbol_images.items.len);
    try std.testing.expectEqual(@as(usize, 0), modules.cachedSymbolCount());
    original.size += 1;
    try std.testing.expectError(error.BinaryChangedDuringRead, modules.rememberMetadataIdentity(region, original));
}

test "module relabel preserves exact provenance at process-scale mapping counts" {
    var header: [64]u8 = @splat(0);
    @memcpy(header[0..7], "\x7fELF\x02\x01\x01");
    std.mem.writeInt(u16, header[16..18], 3, .little);
    std.mem.writeInt(u16, header[18..20], 62, .little);
    std.mem.writeInt(u32, header[20..24], 1, .little);
    std.mem.writeInt(u16, header[52..54], 64, .little);
    const fixture_image = try elf.Image.parse(&header);
    const a = std.testing.allocator;
    var modules = Modules.init(a);
    defer modules.deinit();
    for (0..2600) |i| {
        const path = try std.fmt.allocPrint(a, "/owned/image-{d}.so", .{i % 200});
        try modules.regions.append(a, .{ .start = 0x10000 + i * 4096, .end = 0x11000 + i * 4096, .offset = (i / 200) * 4096, .inode = i % 200 + 1, .device_major = 1, .device_minor = 2, .permissions = "r--p".*, .path = path });
    }
    for (0..200) |i| {
        const r = modules.regions.items[i];
        if (i < 100) {
            const module = try a.create(Module);
            module.* = .{ .id = i + 1, .inode = r.inode, .device_major = r.device_major, .device_minor = r.device_minor, .path = try a.dupeZ(u8, r.path), .image = fixture_image, .mapping = &.{}, .owns_mapping = false, .bias = 0, .start = r.start, .end = r.end, .file_source = .target_root };
            try modules.loaded.append(a, module);
        } else {
            const ptr = c.mmap(null, 4096, c.PROT_READ | c.PROT_WRITE, c.MAP_PRIVATE | c.MAP_ANONYMOUS, -1, 0);
            if (ptr == c.MAP_FAILED) return error.OutOfMemory;
            const bytes: snapshot.Bytes = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(ptr)))[0..4096];
            @memcpy(bytes[0..header.len], &header);
            var saved = r;
            saved.path = try a.dupe(u8, r.path);
            saved.file_source = .host_path;
            try modules.symbol_images.append(a, .{ .region = saved, .file = try modules.fileIdentity(r), .bytes = bytes, .image = try elf.Image.parse(bytes), .retained = 4096 });
            modules.symbol_bytes += 4096;
        }
    }
    const fresh = try a.dupe(Region, modules.regions.items);
    defer a.free(fresh); // Paths remain borrowed from the original map rows.
    const Usage = struct {
        fn cpu() !u64 {
            var stamp: c.struct_timespec = undefined;
            if (c.clock_gettime(c.CLOCK_PROCESS_CPUTIME_ID, &stamp) != 0) return error.ClockUnavailable;
            return @as(u64, @intCast(stamp.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(stamp.tv_nsec));
        }
        fn rss() !u64 {
            const fd = c.open("/proc/self/statm", c.O_RDONLY | c.O_CLOEXEC);
            if (fd < 0) return error.UsageUnavailable;
            defer _ = c.close(fd);
            var bytes: [128]u8 = undefined;
            const n = c.read(fd, &bytes, bytes.len);
            if (n <= 0) return error.UsageUnavailable;
            var fields = std.mem.tokenizeAny(u8, bytes[0..@intCast(n)], " \n");
            _ = fields.next();
            const pages = try std.fmt.parseInt(u64, fields.next() orelse return error.UsageUnavailable, 10);
            const page = c.sysconf(c._SC_PAGESIZE);
            if (page <= 0) return error.UsageUnavailable;
            return pages * @as(u64, @intCast(page));
        }
    };
    for ([_]bool{ false, true }) |deferred| {
        for (modules.regions.items) |*region| region.full_image_deferred = deferred and region.inode == 8;
        for (fresh) |*region| {
            region.file_source = .unopened;
            region.full_image_deferred = false;
        }
        const before_rss = try Usage.rss();
        const before_cpu = try Usage.cpu();
        modules.relabelRegions(fresh);
        const after_cpu = try Usage.cpu();
        const after_rss = try Usage.rss();
        for (fresh, 0..) |region, i| {
            try std.testing.expectEqual(if (i % 200 < 100) mapped_file.Source.target_root else mapped_file.Source.host_path, region.file_source);
            try std.testing.expectEqual(deferred and region.inode == 8, region.full_image_deferred);
        }
        var loads: [3]f64 = undefined;
        try std.testing.expectEqual(@as(c_int, 3), c.getloadavg(&loads, 3));
        std.debug.print("module relabel: maps=2600 loaded=100 symbols=100 deferred={} cpu_ns={d} rss_before={d} rss_after={d} load={d:.2} cpus={d}\n", .{ deferred, after_cpu - before_cpu, before_rss, after_rss, loads[0], c.sysconf(c._SC_NPROCESSORS_ONLN) });
    }
    // Neither a changed inode nor another path on the same inode inherits an
    // unrelated module's source or full-image refusal.
    fresh[0].inode = 9999;
    fresh[1].path = "/owned/other.so";
    fresh[2].device_minor = 3;
    for (fresh[0..3]) |*region| {
        region.file_source = .unopened;
        region.full_image_deferred = false;
    }
    modules.relabelRegions(fresh);
    for (fresh[0..3]) |region| try std.testing.expectEqual(mapped_file.Source.unopened, region.file_source);
    for (modules.regions.items) |*region| region.full_image_deferred = false;
}

test "companion decisions follow explicit lookup policy changes" {
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    var files = @import("../binary/debug_files.zig").Files{ .allocator = std.testing.allocator };
    defer files.deinit();
    modules.debug_files = &files;
    const region = Region{ .start = 4096, .end = 8192, .offset = 0, .inode = 7, .device_major = 1, .device_minor = 1, .permissions = "r-xp".*, .path = "/owned.so" };
    const index = try modules.fileIdentity(region);
    modules.syncCompanionPolicy(index);
    modules.identities.items[index].companion = .absent;
    modules.identities.items[index].metadata_only = true;
    modules.syncCompanionPolicy(index);
    try std.testing.expectEqual(@as(?bool, true), modules.identities.items[index].metadata_only);
    try files.addRoot("/owned-debug");
    modules.syncCompanionPolicy(index);
    try std.testing.expect(modules.identities.items[index].companion == null);
    try std.testing.expect(modules.identities.items[index].metadata_only == null);
}

test "identity ledger distinguishes embedded images with equal load bias" {
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    const region = Region{ .start = 4096, .end = 8192, .offset = 0, .inode = 7, .device_major = 1, .device_minor = 1, .permissions = "r-xp".*, .path = "/owned.apk" };
    const first = try modules.moduleId(region, 0x40000, 0x4000);
    const second = try modules.moduleId(region, 0x40000, 0x10000);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(first, try modules.moduleId(region, 0x40000, 0x4000));
}
