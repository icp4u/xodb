const std = @import("std");
const log = @import("../log.zig");
const runtime_api = @import("../target/runtime.zig");
const rt = runtime_api.c;
const c = @import("../c.zig").api;
const elf = @import("../binary/elf.zig");
const apk = @import("../binary/apk.zig");
const snapshot = @import("../binary/snapshot.zig");
const mapped_file = @import("../binary/mapped_file.zig");
const pe = @import("pe_images.zig");
const DebugInfo = @import("../debug/info.zig").Image;
// Process-wide, so exec/fork ownership changes cannot restart a burst.
const BudgetThrottle = struct {
    next: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fn allow(self: *BudgetThrottle, now: u64) bool {
        var old = self.next.load(.acquire);
        while (now >= old) old = self.next.cmpxchgWeak(old, now +| std.time.ns_per_s, .acq_rel, .acquire) orelse return true;
        return false;
    }
};
var budget_throttle: BudgetThrottle = .{};
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
    debug_sweep: bool = false,
    debug_refusal: ?snapshot.Refusal = null,
    debug_refusal_pending: bool = false,
    layouts: @import("../language/layouts.zig").Layouts = .{},
    debug_file: ?*const @import("../binary/debug_files.zig").File = null,
    debug_allocator: std.mem.Allocator = std.heap.page_allocator,
    file_offset: u64 = 0, // ELF entry offset in the backing file; zero for standalone ELF.
    mapping: []align(std.heap.page_size_min) u8,
    owns_mapping: bool = true,
    immutable: bool = false,
    explicit_gdb: bool = false,
    file_source: mapped_file.Source = .unopened,
    pub fn debugInfo(self: *Module) !*DebugInfo {
        if (self.debug == null) {
            self.debug_refusal = null;
            self.debug = DebugInfo.initWithBudget(self.image, self.mapping, self.debug_file, self.debug_allocator, self.debug_sweep, &self.debug_refusal) catch |err| {
                self.debug_refusal_pending = self.debug_refusal != null;
                return err;
            };
        }
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
    pub const FileKind = enum { elf, pe, macho, other };
    const FileKey = pe.FileKey;
    const max_file_kinds = 16384;
    const FileClassification = struct { kind: FileKind, identity: ?rt.struct_xrt_file_identity, checked_revision: u64, failure: ?anyerror = null, pe_headers_valid: ?bool = null };
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
        /// Size of a full image the per-image budget refused. A remote file
        /// crosses whole before that check; do not fetch it again to refuse.
        refused_size: ?u64 = null,
    };
    const SymbolImage = struct {
        region: Region,
        file: usize,
        bytes: snapshot.Bytes,
        image: elf.Image,
        retained: u64,
        last_used: u64 = 0,
    };
    /// `unexamined` is the first image whose symbols could not be read.
    pub const Definers = struct { modules: []const *Module, unexamined: ?anyerror };
    const DefinerScan = struct { name: []const u8 = "", revision: u64 = 0, cursor: SymbolCursor = .{}, done: bool = false, count: usize = 0, modules: [4]*Module = undefined };
    const Unsearched = struct { region: usize, revision: u64 };
    const NameScan = struct { name: ?[]u8 = null, revision: u64 = 0, cursor: SymbolCursor = .{}, unsearched: ?Unsearched = null };
    /// `detail` names the size and budget of an image refused in full.
    pub const LoadFailure = struct { start: u64, end: u64, path: []const u8, diagnostic: []const u8, detail: ?[]const u8 = null, budget: ?snapshot.Refusal = null };
    /// Local symbol views above this size use the cancellable worker.
    const symbol_immediate_limit = 256 * 1024 * 1024;
    /// What a name lookup may read in full of images that have no
    /// symbols-only view: one image, and all of them for one process.
    const lookup_image_limit = 256 * 1024 * 1024;
    const lookup_total_limit = 512 * 1024 * 1024;
    /// Why a name lookup wants an image in full; see `lookupRead`.
    const Unviewed = enum { no_reader, container, tables };
    /// Why an image is wanted in full; `allowance` turns it into a bound.
    ///   frame    a stack frame in it, or an address the user gave
    ///   name     a name lookup that has no symbols-only view of it
    ///   runtime  a language view found its runtime's symbol in it
    ///   restore  a saved breakpoint was set in it
    ///   sweep    a search of every mapped image: a source line, the start
    ///            of a capture, an observation recipe
    pub const Reason = enum { frame, name, runtime, restore, sweep };
    const Bound = struct { each: u64, pool: enum { lookups, sweeps }, which: @FieldType(snapshot.Refusal, "which") };
    /// A loaded image and one load bias its file is mapped at.
    pub const Instance = struct { module: *Module, bias: u64 };
    /// Images the sweeps since `beginSweep` left unread for a budget: how
    /// many files, and the first one's sentence (valid until the next one).
    pub const Skipped = struct { count: usize = 0, first: ?[]const u8 = null };
    /// The mappings of one file and, per image inside it, where each load
    /// bias places it. Built once per map revision, so placing every mapping
    /// of a file costs mappings x segments, not that squared.
    const FileRef = struct { inode: u64, device_major: u64, device_minor: u64, path: []const u8 };
    const FileRefContext = struct {
        pub fn hash(_: @This(), k: FileRef) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&[3]u64{ k.inode, k.device_major, k.device_minor }));
            h.update(k.path);
            return h.final();
        }
        pub fn eql(_: @This(), a: FileRef, b: FileRef) bool {
            return a.inode == b.inode and a.device_major == b.device_major and a.device_minor == b.device_minor and std.mem.eql(u8, a.path, b.path);
        }
    };
    /// `first` is a region index: the header mapping, or a lower one that fits.
    const Extent = struct { first: u32, start: u64, end: u64 };
    /// For one image in a file: what each load bias covers, and the bias of
    /// each mapping (by region index), or that two fit it.
    const Placed = struct {
        file_offset: u64,
        segments: u64,
        /// Why this image cannot be placed in this map, once that is known.
        refused: ?anyerror = null,
        biases: std.AutoHashMapUnmanaged(u64, Extent) = .empty,
        fits: std.AutoHashMapUnmanaged(u32, ?u64) = .empty,
        fn deinit(self: *Placed, a: std.mem.Allocator) void {
            self.biases.deinit(a);
            self.fits.deinit(a);
        }
    };
    const FileMaps = struct { regions: std.ArrayList(u32) = .empty, placed: std.ArrayList(Placed) = .empty };
    target: ?*const rt.struct_xrt_target = null,
    owner_target: ?*rt.struct_xrt_target = null,
    remote_boot: ?[36]u8 = null,
    remote_boot_checked: bool = false,
    // Worker-owned immutable snapshots must not read the owner's changing ISA.
    expected_machine: ?u16 = null,
    core_source: ?*const @import("../binary/core.zig").Core = null,
    core_ids: std.StringHashMapUnmanaged(union(enum) { id: []const u8, failure: anyerror }) = .empty,
    core_executable: ?struct { path: [:0]u8, id: []u8 } = null,
    /// Borrowed argv storage. Used only when a Linux GDB stub cannot list its
    /// images and the user supplied a fixed-address ELF with --exe.
    gdb_executable: ?[:0]const u8 = null,
    allocator: std.mem.Allocator,
    regions: std.ArrayList(Region) = .empty,
    loaded: std.ArrayList(*Module) = .empty,
    next_id: u64 = 1,
    pe_images: pe.State = .{},
    file_kinds: std.AutoHashMapUnmanaged(FileKey, FileClassification) = .empty,
    /// Files whose symbols-only view failed for good, for this map.
    /// Asking again would only restart a reader that must fail again.
    symbol_refusals: std.AutoHashMapUnmanaged(FileKey, anyerror) = .empty,
    /// The one file a name lookup may read in full when its symbol tables
    /// are too large for the symbols-only view: the main executable.
    name_fallback: ?FileKey = null,
    /// Region index of the first image the last findSymbol could not search
    /// by name, for this map.
    unsearched: ?Unsearched = null,
    /// Explicit name lookups resume across pending PE/ELF reads. At most 16
    /// unfinished names, each at most 64 KiB; no parsed image is pinned by one.
    name_scans: [16]NameScan = @splat(.{}),
    maps_revision: u64 = 0,
    pe_scan_next: usize = 0,
    pid: i32 = 0,
    immutable: bool = false,
    /// Full-image bytes this owner holds; the budget is the process-wide one.
    snapshot_bytes: usize = 0,
    /// The part of `snapshot_bytes` name lookups read under the fixed bounds.
    lookup_bytes: usize = 0,
    sweep_skipped: std.AutoHashMapUnmanaged(FileKey, void) = .empty,
    sweep_first: ?[]u8 = null,
    /// The executable's full read for a name, when it failed for this map.
    fallback_failure: ?struct { revision: u64, err: anyerror } = null,
    /// Mappings by file, with their placements; valid for `placed_for`.
    file_maps: std.HashMapUnmanaged(FileRef, FileMaps, FileRefContext, 80) = .empty,
    region_starts: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    placed_for: ?struct { revision: u64, regions: usize } = null,
    /// Placement steps spent on this map revision; see `placement_work`.
    placement_spent: u64 = 0,
    /// Why the load in progress was refused; noteFailure takes it.
    refusal: ?snapshot.Refusal = null,
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
    definer_scans: [2]DefinerScan = @splat(.{}),
    symbol_pending: ?struct { region: Region, job: *rt.struct_xrt_symbol_job, identity: rt.struct_xrt_file_identity } = null,
    pub fn init(a: std.mem.Allocator) Modules {
        return .{ .allocator = a };
    }
    /// Remote readers borrow the target. Drain them before its last handle,
    /// even when transport cancellation prevents a confirmed remote detach.
    pub fn drainRemoteReaders(self: *Modules) void {
        self.pe_images.deinit(self.allocator);
        self.cancelSymbolJob();
    }
    pub fn deinit(self: *Modules) void {
        self.reportBudget();
        self.clearNameScans();
        self.pe_images.deinit(self.allocator);
        self.file_kinds.deinit(self.allocator);
        self.symbol_refusals.deinit(self.allocator);
        self.beginSweep();
        self.sweep_skipped.deinit(self.allocator);
        self.dropPlacements();
        self.file_maps.deinit(self.allocator);
        self.region_starts.deinit(self.allocator);
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
            if (m.layouts.go_value) |layout| m.debug_allocator.destroy(layout);
            if (m.layouts.go_map) |layout| m.debug_allocator.destroy(layout);
            if (m.debug) |*info| info.deinit();
            if (m.owns_mapping) snapshot.free(m.mapping);
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
            const data = try snapshot.readRange(fd, 0, std.math.cast(usize, stat.st_size) orelse return error.BinarySnapshotLimit, snapshot.per_image_limit, null);
            defer snapshot.free(data);
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
    pub fn fromGdbExecutable(self: *Modules, name: []const u8, machine: u16, target: anytype) !void {
        if (self.loaded.items.len != 0) return;
        const name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(name_z);
        const real = c.realpath(name_z.ptr, null) orelse return error.GdbExecutableUnavailable;
        defer c.free(real);
        const fd = c.open(real, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) return error.GdbExecutableUnavailable;
        defer _ = c.close(fd);
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_size <= 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return error.GdbExecutableUnavailable;
        const mapped = try snapshot.readRange(fd, 0, std.math.cast(usize, stat.st_size) orelse return error.BinarySnapshotLimit, snapshot.per_image_limit, null);
        errdefer snapshot.free(mapped);
        var after: c.struct_stat = undefined;
        if (c.fstat(fd, &after) != 0 or stat.st_size != after.st_size or
            stat.st_mtim.tv_sec != after.st_mtim.tv_sec or stat.st_mtim.tv_nsec != after.st_mtim.tv_nsec or
            stat.st_ctim.tv_sec != after.st_ctim.tv_sec or stat.st_ctim.tv_nsec != after.st_ctim.tv_nsec) return error.BinaryChangedDuringRead;
        const image = try elf.Image.parse(mapped);
        if (image.header.type != .executable) return error.GdbExecutablePositionIndependentUnsupported;
        if (@intFromEnum(image.header.machine) != machine) return error.UnsupportedTargetArchitecture;
        // The stub cannot name its image. A rebuild can keep every code byte
        // and still change its DWARF, so the loaded GNU build ID must match.
        if (image.buildId()) |id| {
            const note_at: u64 = @intFromPtr(id.ptr) - @intFromPtr(mapped.ptr);
            // A note outside every PT_LOAD (added after linking) is not in
            // target memory; only the entry check then guards, as without one.
            const address: ?u64 = for (0..image.header.segment_count) |i| {
                const segment = try image.segment(@intCast(i));
                if (segment.type == .load and note_at >= segment.offset and note_at - segment.offset + id.len <= segment.file_size) break segment.vaddr + (note_at - segment.offset);
            } else null;
            var loaded: [64]u8 = undefined;
            if (address) |note| if (id.len > loaded.len or try target.readMemory(note, loaded[0..id.len]) != id.len or
                !std.mem.eql(u8, loaded[0..id.len], id)) return error.GdbExecutableMismatch;
        }
        const path = try self.allocator.dupeZ(u8, std.mem.span(real));
        errdefer self.allocator.free(path);
        const inode: u64 = @intCast(stat.st_ino);
        var start: u64 = std.math.maxInt(u64);
        var end: u64 = 0;
        var added: usize = 0;
        errdefer {
            while (added > 0) {
                const region = self.regions.pop().?;
                self.allocator.free(region.path);
                added -= 1;
            }
        }
        for (0..image.header.segment_count) |i| {
            const segment = try image.segment(@intCast(i));
            if (segment.type != .load) continue;
            start = @min(start, segment.vaddr);
            end = @max(end, std.math.add(u64, segment.vaddr, segment.mem_size) catch return error.InvalidAddress);
            if (segment.file_size == 0) continue;
            const file_end = std.math.add(u64, segment.vaddr, segment.file_size) catch return error.InvalidAddress;
            var permissions: [4]u8 = "---p".*;
            if (segment.flags & elf.pf.r != 0) permissions[0] = 'r';
            if (segment.flags & elf.pf.w != 0) permissions[1] = 'w';
            if (segment.flags & elf.pf.x != 0) permissions[2] = 'x';
            try self.regions.append(self.allocator, .{
                .start = segment.vaddr,
                .end = file_end,
                .offset = segment.offset,
                .inode = inode,
                .device_major = 0,
                .device_minor = 0,
                .permissions = permissions,
                .path = try self.allocator.dupe(u8, path),
                .file_source = .host_path,
            });
            added += 1;
        }
        if (added == 0 or start == std.math.maxInt(u64) or start >= end) return error.NoLoadSegment;
        const module = try self.allocator.create(Module);
        errdefer self.allocator.destroy(module);
        module.* = .{
            .id = self.next_id,
            .inode = inode,
            .device_major = 0,
            .device_minor = 0,
            .path = path,
            .image = image,
            .bias = 0,
            .start = start,
            .end = end,
            .mapping = mapped,
            .immutable = true,
            .explicit_gdb = true,
            .file_source = .host_path,
        };
        try self.loaded.append(self.allocator, module);
        self.next_id += 1;
        self.snapshot_bytes += mapped.len;
        self.maps_revision +|= 1;
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
        self.dropPlacements();
        self.clearFailures();
        self.relabelRegions(new_regions.items);
        for (self.regions.items) |r| self.allocator.free(r.path);
        self.regions.deinit(self.allocator);
        self.regions = new_regions;
        self.budget_dirty = true;
        self.symbol_refusals.clearRetainingCapacity();
        self.clearNameScans();
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
    pub fn load(self: *Modules, region: Region, why: Reason) !*Module {
        if (region.path.len == 0 or region.path[0] != '/') return error.NoBinaryImage;
        return self.loadRange(region, false, why, null) catch |err| {
            if (why == .sweep) self.noteSkipped(region, err);
            self.noteFailure(region, err);
            return err;
        };
    }
    /// Budget refusal discovered before an asynchronous image transfer starts.
    pub fn refuseImage(self: *Modules, region: Region, reason: snapshot.Refusal) void {
        self.refusal = reason;
        self.noteFailure(region, error.BinarySnapshotLimit);
    }
    /// A pinned, sealed main-runtime ELF view prepared by the owner metadata
    /// job. The caller proves the kernel PHDR mapping; this is not a name scan.
    pub fn loadMainImage(self: *Modules, region: Region, fd: c_int, why: enum { frame, sweep }) !*Module {
        defer self.reportBudget();
        return self.loadRange(region, false, if (why == .frame) .frame else .sweep, fd) catch |err| {
            self.noteFailure(region, err);
            return err;
        };
    }
    /// The one place that says how much of an image a reader may take, by
    /// why it asks. Null is the image budgets alone. An image this owner has
    /// loaded already never gets here: it costs nothing whoever asks.
    fn allowance(self: *Modules, why: Reason, r: Region) ?Bound {
        return switch (why) {
            // The user is stopped there, or named the address.
            .frame => null,
            // A saved breakpoint names its own image. Through a runtime
            // agent only a container entry gets here.
            .restore => if (rt.xrt_target_is_remote(self.target)) .{ .each = lookup_image_limit, .pool = .lookups, .which = .lookup } else null,
            // See lookupRead: the main executable, or an image with no
            // symbols-only view.
            .name => if (self.nameFallback(r)) null else .{ .each = lookup_image_limit, .pool = .lookups, .which = .lookup },
            .runtime => if (self.nameFallback(r)) null else .{ .each = lookup_image_limit, .pool = .lookups, .which = .runtime },
            // Every new image, including the executable, shares this bound.
            .sweep => .{ .each = if (self.mainExecutable(r)) snapshot.per_image_limit else snapshot.sweep_image_limit, .pool = .sweeps, .which = .sweep },
        };
    }
    /// Forget what earlier sweeps skipped; call before a search of every image.
    pub fn beginSweep(self: *Modules) void {
        self.sweep_skipped.clearRetainingCapacity();
        if (self.sweep_first) |text| self.allocator.free(text);
        self.sweep_first = null;
    }
    pub fn skipped(self: *const Modules) Skipped {
        return .{ .count = self.sweep_skipped.count(), .first = self.sweep_first };
    }
    fn noteSkipped(self: *Modules, region: Region, err: anyerror) void {
        if (err != error.BinarySnapshotLimit and err != error.CompressedDebugBudget) return;
        const entry = self.sweep_skipped.getOrPut(self.allocator, fileKey(region)) catch return;
        if (entry.found_existing or self.sweep_first != null) return;
        var text: [snapshot.refusal_text]u8 = undefined;
        if (self.refusal) |why| self.sweep_first = self.allocator.dupe(u8, why.write(&text, region.path)) catch null;
    }
    /// The image of `region`'s file that this owner holds, and the load bias
    /// `region` maps it at: every mapping of one file is searched through one
    /// image, however many times and wherever the target mapped it. `plain`
    /// is set when the file is one ELF image, so that a mapping of it which
    /// fits nowhere need not be tried on its own.
    pub fn instanceOf(self: *Modules, region: Region, plain: *bool) ?Instance {
        for (self.loaded.items) |m| {
            if (m.inode != region.inode or m.device_major != region.device_major or m.device_minor != region.device_minor or (self.core_source == null and !std.mem.eql(u8, m.path, region.path))) continue;
            if (m.file_offset == 0) plain.* = true;
            const p = self.placement(&m.image, m.file_offset, region, false) catch continue;
            return .{ .module = m, .bias = p.bias };
        }
        return null;
    }
    fn clearFailures(self: *Modules) void {
        for (self.load_failures.items) |failure| {
            self.allocator.free(failure.path);
            if (failure.detail) |detail| self.allocator.free(detail);
        }
        self.load_failures.clearRetainingCapacity();
    }
    fn noteFailure(self: *Modules, region: Region, err: anyerror) void {
        const why = self.refusal;
        self.refusal = null;
        if (err == error.NotElf or err == error.NoBinaryImage) return;
        if (err == error.BinarySnapshotLimit or err == error.CompressedDebugBudget) {
            for (self.regions.items) |*item| if (sameFile(item.*, region)) {
                if (!item.full_image_deferred) self.budget_dirty = true;
                item.full_image_deferred = true;
            };
        }
        var text: [snapshot.refusal_text]u8 = undefined;
        const detail = if ((err == error.BinarySnapshotLimit or err == error.CompressedDebugBudget) and why != null) self.allocator.dupe(u8, why.?.write(&text, region.path)) catch null else null;
        for (self.load_failures.items) |*failure| if (std.mem.eql(u8, failure.path, region.path) and std.mem.eql(u8, failure.diagnostic, @errorName(err))) {
            // One row per image; its sentence is the latest refusal's, which
            // is the one about what was just asked for.
            if (detail) |latest| {
                if (failure.detail) |old| self.allocator.free(old);
                failure.detail = latest;
                failure.budget = why;
            }
            return;
        };
        if (self.load_failures.items.len >= 64) {
            if (detail) |owned| self.allocator.free(owned);
            return;
        }
        const path = self.allocator.dupe(u8, region.path) catch {
            if (detail) |owned| self.allocator.free(owned);
            return;
        };
        self.load_failures.append(self.allocator, .{ .start = region.start, .end = region.end, .path = path, .diagnostic = @errorName(err), .detail = detail, .budget = if (detail != null) why else null }) catch {
            self.allocator.free(path);
            if (detail) |owned| self.allocator.free(owned);
            return;
        };
        if (err != error.BinarySnapshotLimit and err != error.CompressedDebugBudget)
            log.warn(.session, "xodb: module unavailable: {s}; {s} at 0x{x}\n", .{ @errorName(err), path, region.start });
    }
    /// DWARF opens lazily after the image was loaded. Record its refusal on
    /// the same surfaces as the initial read, including a source search.
    pub fn noteDebugFailure(self: *Modules, module: *Module, err: anyerror, why: Reason) void {
        if (err != error.CompressedDebugBudget) return;
        module.debug_refusal_pending = false;
        const region = Region{ .start = module.start, .end = module.end, .offset = module.file_offset, .inode = module.inode, .device_major = module.device_major, .device_minor = module.device_minor, .path = module.path, .permissions = "r-xp".* };
        self.refusal = module.debug_refusal;
        if (why == .sweep) self.noteSkipped(region, err);
        self.noteFailure(region, err);
    }
    /// Summarize full-image refusals once after a scan, with no per-file spam.
    /// Count mapped files independently of the bounded detailed failure list.
    pub fn beginStop(self: *Modules, generation: u64) void {
        self.budget_generation = generation;
    }
    pub fn reportBudget(self: *Modules) void {
        for (self.loaded.items) |module| if (module.debug_refusal_pending)
            self.noteDebugFailure(module, error.CompressedDebugBudget, if (module.debug_sweep) .sweep else .frame);
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
        const repeated = if (self.budget_reported) |old| old.loaded == counts.loaded and old.deferred == counts.deferred else false;
        self.budget_reported = .{ .loaded = counts.loaded, .deferred = counts.deferred };
        self.budget_reported_generation = self.budget_generation;
        // Details stay available through list_modules and the requesting tool,
        // even when stderr is suppressed. Identical stops do not print again.
        if (repeated or !budget_throttle.allow(rt.xrt_now())) return;
        if (self.budgetDetail(null)) |detail|
            log.warn(.session, "xodb: module budget: {d} full images loaded, {d} mapped files deferred; {s}\n", .{ counts.loaded, counts.deferred, detail })
        else
            log.warn(.session, "xodb: module budget: {d} full images loaded, {d} mapped files deferred\n", .{ counts.loaded, counts.deferred });
    }
    /// The image, its size and the budget for a full image refused at
    /// `address`, or for the first one refused when no address is given.
    /// Valid until the next map refresh.
    pub fn budgetDetail(self: *const Modules, address: ?u64) ?[]const u8 {
        return if (self.budgetFailure(address)) |failure| failure.detail else null;
    }
    pub fn budgetFailure(self: *const Modules, address: ?u64) ?LoadFailure {
        const path: ?[]const u8 = if (address) |at_| for (self.regions.items) |region| {
            if (at_ >= region.start and at_ < region.end) break region.path;
        } else return null else null;
        for (self.load_failures.items) |failure| {
            if (path) |wanted| if (!std.mem.eql(u8, wanted, failure.path)) continue;
            if (failure.detail != null) return failure;
        }
        return null;
    }
    /// A perf record describes one range at one file offset, not the current
    /// collection of VMAs. Do not combine it with the opening/live map snapshot.
    pub fn loadObserved(self: *Modules, region: Region) !*Module {
        if (region.path.len == 0 or region.path[0] != '/') return error.NoBinaryImage;
        return self.loadRange(region, true, .sweep, null) catch |err| {
            self.noteSkipped(region, err);
            return err;
        };
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
    /// Placement steps (mappings of a file x its segments) allowed per map
    /// revision. Measured at 5 to 15 ns a step, this is one to two seconds
    /// of work. A process with 60,000 mappings of an ordinary 13-segment
    /// image spends under a hundredth of it; reaching it takes tens of
    /// thousands of mappings of files with thousands of program headers.
    const placement_work = 1 << 27;
    const placement_free = 4096;
    fn dropPlacements(self: *Modules) void {
        var files = self.file_maps.valueIterator();
        while (files.next()) |file| {
            for (file.placed.items) |*item| item.deinit(self.allocator);
            file.placed.deinit(self.allocator);
            file.regions.deinit(self.allocator);
        }
        self.file_maps.clearRetainingCapacity();
        self.region_starts.clearRetainingCapacity();
        self.placed_for = null;
        self.placement_spent = 0;
    }
    /// Where each load bias places the image at `file_offset` of `region`'s
    /// file, from every mapping of that file in the current map.
    fn placedIn(self: *Modules, image: *const elf.Image, file_offset: u64, region: Region, page: u64) !*const Placed {
        const a = self.allocator;
        const current = self.placed_for;
        if (current == null or current.?.revision != self.maps_revision or current.?.regions != self.regions.items.len) {
            self.dropPlacements();
            if (self.regions.items.len > std.math.maxInt(u32)) return error.MappingLimit;
            errdefer self.dropPlacements();
            for (self.regions.items, 0..) |r, i| {
                try self.region_starts.put(a, r.start, @intCast(i));
                if (r.path.len == 0) continue;
                const entry = try self.file_maps.getOrPut(a, .{ .inode = r.inode, .device_major = r.device_major, .device_minor = r.device_minor, .path = r.path });
                if (!entry.found_existing) entry.value_ptr.* = .{};
                try entry.value_ptr.regions.append(a, @intCast(i));
            }
            self.placed_for = .{ .revision = self.maps_revision, .regions = self.regions.items.len };
        }
        const file = self.file_maps.getPtr(.{ .inode = region.inode, .device_major = region.device_major, .device_minor = region.device_minor, .path = region.path }) orelse return error.BadMapping;
        for (file.placed.items) |*old| if (old.file_offset == file_offset and old.segments == image.segment_print) {
            if (old.refused) |err| return err;
            return old;
        };
        var memo = Placed{ .file_offset = file_offset, .segments = image.segment_print };
        self.fillPlaced(&memo, image, file, page) catch |err| {
            memo.deinit(a);
            // Asked once per mapping; the answer is the same each time.
            if (err != error.MappingLimit and err != error.NoLoadSegment and err != error.BadMapping) return err;
            memo = .{ .file_offset = file_offset, .segments = image.segment_print, .refused = err };
            if (err == error.MappingLimit) self.noteFailure(region, err);
        };
        // One image per offset in practice; a changed file replaces its entry.
        const slot = for (file.placed.items) |*old| {
            if (old.file_offset == file_offset) {
                old.deinit(a);
                break old;
            }
        } else file.placed.addOne(a) catch |err| {
            memo.deinit(a);
            return err;
        };
        slot.* = memo;
        if (slot.refused) |err| return err;
        return slot;
    }
    fn fillPlaced(self: *Modules, memo: *Placed, image: *const elf.Image, file: *const FileMaps, page: u64) !void {
        const a = self.allocator;
        const file_offset = memo.file_offset;
        var first_segment: ?elf.Segment = null;
        for (0..image.header.segment_count) |i| {
            const segment = try image.segment(@intCast(i));
            if (segment.type == .load and (first_segment == null or segment.vaddr < first_segment.?.vaddr)) first_segment = segment;
        }
        const segment = first_segment orelse return error.NoLoadSegment;
        const lead = segment.offset % page;
        const header_offset = std.math.add(u64, file_offset, segment.offset - lead) catch return error.BadMapping;
        // The target chooses both counts. What is refused is real work, and
        // it is listed with the other images that could not be used.
        const work = std.math.mul(u64, file.regions.items.len, @max(image.header.segment_count, 1)) catch std.math.maxInt(u64);
        // An ordinary library is a few dozen steps. Small placements are
        // neither refused nor counted, so a file that spends the allowance
        // cannot take the names of the libraries beside it.
        if (work >= placement_free) {
            if (work > placement_work - self.placement_spent) return error.MappingLimit;
            self.placement_spent += work;
        }

        // A header mapping gives a bias, as Image.loadBias computes it.
        if (lead <= segment.vaddr and (segment.alignment <= 1 or lead < segment.alignment)) for (file.regions.items) |index| {
            const r = self.regions.items[index];
            if (r.offset == header_offset) try memo.biases.put(a, r.start -% (segment.vaddr - lead), .{ .first = index, .start = r.start, .end = r.end });
        };
        for (file.regions.items) |index| {
            var rel = self.regions.items[index];
            if (rel.offset < file_offset) continue;
            rel.offset -= file_offset;
            for (0..image.header.segment_count) |i| {
                const bias = fitBias(image.segment(@intCast(i)) catch continue, rel, page) orelse continue;
                const extent = memo.biases.getPtr(bias) orelse continue;
                if (rel.start < extent.start) extent.* = .{ .first = index, .start = rel.start, .end = extent.end };
                extent.end = @max(extent.end, rel.end);
                const fit = try memo.fits.getOrPut(a, index);
                if (!fit.found_existing) fit.value_ptr.* = bias else if (fit.value_ptr.* != bias) fit.value_ptr.* = null;
            }
        }
    }
    fn placement(self: *Modules, image: *const elf.Image, file_offset: u64, region: Region, observed: bool) !Placement {
        if (region.offset < file_offset) return error.BadMapping;
        var relative = region;
        relative.offset -= file_offset;
        if (observed) return .{ .first = region, .end = region.end, .bias = try observedBias(image, relative) };
        const page = try self.pageSize();
        const memo = try self.placedIn(image, file_offset, region, page);
        // The bias is one a header mapping gives and this mapping fits. For a
        // mapping of the current map that was settled when the file was placed.
        var found: ?u64 = null;
        const known: ?u32 = if (self.region_starts.get(region.start)) |index| blk: {
            const r = self.regions.items[index];
            break :blk if (r.end == region.end and r.offset == region.offset and std.mem.eql(u8, &r.permissions, &region.permissions) and sameFile(r, region)) index else null;
        } else null;
        if (known) |index| {
            found = (memo.fits.get(index) orelse return error.BadMapping) orelse return error.AmbiguousLoadBias;
        } else for (0..image.header.segment_count) |i| {
            const bias = fitBias(image.segment(@intCast(i)) catch continue, relative, page) orelse continue;
            if (!memo.biases.contains(bias)) continue;
            if (found != null and found.? != bias) return error.AmbiguousLoadBias;
            found = bias;
        }
        const bias = found orelse return error.BadMapping;
        const extent = memo.biases.get(bias).?;
        return .{ .first = self.regions.items[extent.first], .end = extent.end, .bias = bias };
    }
    /// The load bias under which `r` maps file pages of `segment`, if any.
    fn fitBias(segment: elf.Segment, r: Region, page: u64) ?u64 {
        if (r.end <= r.start or segment.type != .load or segment.file_size == 0) return null;
        if (r.permissions[2] == 'x' and segment.flags & elf.pf.x == 0) return null;
        if (r.permissions[1] == 'w' and segment.flags & elf.pf.w == 0) return null;
        const low = segment.offset - segment.offset % page;
        const segment_end = std.math.add(u64, segment.offset, segment.file_size) catch return null;
        const high = std.math.add(u64, segment_end, page - 1) catch return null;
        const file_end = high - high % page;
        if (r.offset < low or r.offset >= file_end or r.end - r.start > file_end - r.offset) return null;
        const virtual = std.math.sub(u64, segment.vaddr, segment.offset - low) catch return null;
        const address = std.math.sub(u64, r.start, r.offset - low) catch return null;
        return std.math.sub(u64, address, virtual) catch null;
    }
    fn cachedRange(self: *Modules, region: Region, observed: bool) ?*Module {
        for (self.loaded.items) |m| {
            if (m.inode != region.inode or m.device_major != region.device_major or m.device_minor != region.device_minor or (self.core_source == null and !std.mem.eql(u8, m.path, region.path))) continue;
            const p = self.placement(&m.image, m.file_offset, region, observed) catch continue;
            if (m.start == p.first.start and m.end >= p.end and m.bias == p.bias) return m;
        }
        return null;
    }
    fn loadRange(self: *Modules, region: Region, observed: bool, why: Reason, prepared: ?c_int) !*Module {
        self.refusal = null;
        if (self.cachedRange(region, observed)) |module| {
            if (why == .frame) module.debug_sweep = false;
            return module;
        }
        // Until the limit is raised, the answer is the same: refuse without reading.
        if (self.identityIndex(region)) |i| if (self.identities.items[i].refused_size) |size| if (size > snapshot.per_image_limit) {
            self.refusal = snapshot.refusal(size);
            return error.BinarySnapshotLimit;
        };
        const expected = if (self.core_source != null) try self.coreId(region.path) else null;
        const selected_path = if (self.core_executable) |exe| (if (expected != null and std.mem.eql(u8, expected.?, exe.id)) exe.path else region.path) else region.path;
        const path = try self.allocator.dupeZ(u8, selected_path);
        errdefer self.allocator.free(path);
        // Only read the inode actually mapped by the target. map_files can need
        // privileges unavailable to run-as, so exe/path retain inode checks.
        var source: mapped_file.Source = if (prepared != null) .remote_snapshot else if (self.core_source != null) .core_path else .unopened;
        var opened = std.mem.zeroes(rt.struct_xrt_file_identity);
        const fd = if (prepared) |ready| c.fcntl(ready, c.F_DUPFD_CLOEXEC, @as(c_int, 3)) else if (self.core_source != null) c.open(path, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK) else mapped_file.openResolved(self.target, self.pid, region, &opened, &source) catch |err| {
            // A runtime agent refuses whole files above its own fixed cap.
            if (err == error.BinarySnapshotLimit) {
                const agent = rt.xrt_target_remote_image_limit(self.target);
                self.refusal = .{ .size = 0, .limit = @min(agent, rt.XRT_REMOTE_SYNC_IMAGE_LIMIT), .which = .remote, .older_agent = agent < snapshot.remote_image_limit };
            }
            return err;
        };
        if (fd < 0) return error.BinaryIdentityUnavailable;
        defer _ = c.close(fd);
        // A prepared remote image was checked when its file view opened.
        if (prepared == null and self.core_source == null and rt.xrt_target_is_remote(self.target)) try self.rememberMetadataIdentity(region, opened);
        try self.verifySymbolIdentity(region, fd);
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_size <= 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return error.BinaryUnavailable;
        var signature: [4]u8 = undefined;
        if (c.pread(fd, &signature, signature.len, 0) != signature.len) return error.NotElf;
        const file_size = std.math.cast(usize, stat.st_size) orelse return error.BinarySnapshotLimit;
        const entry: apk.Entry = if (std.mem.eql(u8, &signature, "\x7fELF")) .{ .offset = 0, .size = file_size } else try apk.find(self.allocator, fd, file_size, region.offset);
        if (entry.offset % try self.pageSize() != 0) return error.ApkEntryNotPageAligned;
        // Some readers keep fixed bounds whatever the image budgets are.
        const bound: ?Bound = if (prepared != null and why == .sweep)
            .{ .each = snapshot.per_image_limit, .pool = .sweeps, .which = .sweep }
        else
            self.allowance(why, region);
        if (bound) |b| if (b.pool == .lookups) {
            const left = lookup_total_limit -| self.lookup_bytes;
            if (entry.size > b.each or entry.size > left) {
                self.refusal = .{ .size = entry.size, .limit = @min(b.each, left), .which = b.which, .stack_loads = if (b.which == .runtime) self.stackLoads(region) else null };
                return error.BinarySnapshotLimit;
            }
        };
        if (self.core_source == null and !rt.xrt_target_is_remote(self.target)) {
            var identity: rt.struct_xrt_file_identity = undefined;
            try runtime_api.check(rt.xrt_file_identity(fd, &identity));
            try self.rememberMetadataIdentity(region, identity);
        }
        // MAP_PRIVATE still faults against the file after truncation. Parsed
        // ELF/libdw slices must only reference owned, bounded snapshots.
        // The reader shares a version another owner holds and charges the
        // process-wide total for a new one; it says no before allocating.
        const remote = self.core_source == null and rt.xrt_target_is_remote(self.target);
        if (remote and !self.remote_boot_checked) {
            self.remote_boot = snapshot.bootIdTarget(self.target);
            self.remote_boot_checked = true;
        }
        const original: ?rt.struct_xrt_file_identity = if (remote) identity: {
            const index = self.identityIndex(region) orelse return error.BinaryIdentityUnavailable;
            break :identity self.identities.items[index].identity orelse return error.BinaryIdentityUnavailable;
        } else null;
        const mapped = (if (remote)
            snapshot.readRemoteRange(fd, entry.offset, entry.size, snapshot.per_image_limit, if (why == .sweep) @intCast(bound.?.each) else null, @bitCast(original.?), self.remote_boot)
        else if (why == .sweep)
            snapshot.readSweepRange(fd, entry.offset, entry.size, snapshot.per_image_limit, @intCast(bound.?.each))
        else
            snapshot.readRange(fd, entry.offset, entry.size, snapshot.per_image_limit, null)) catch |err| {
            if (err == error.SweepSnapshotLimit) {
                self.refusal = .{ .size = entry.size, .limit = @min(bound.?.each, snapshot.sweepLeft()), .which = .sweep, .sweep_each = bound.?.each };
                return error.BinarySnapshotLimit;
            }
            if (err == error.BinarySnapshotLimit) {
                self.refusal = snapshot.refusal(entry.size);
                if (entry.size > snapshot.per_image_limit) if (self.identityIndex(region)) |i| {
                    self.identities.items[i].refused_size = entry.size;
                };
            }
            return err;
        };
        errdefer snapshot.free(mapped);
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
        module.* = .{ .id = try self.moduleId(region, p.bias, entry.offset), .inode = region.inode, .device_major = region.device_major, .device_minor = region.device_minor, .path = path, .image = image, .bias = p.bias, .start = p.first.start, .end = p.end, .mapping = mapped, .file_offset = entry.offset, .immutable = self.immutable, .debug_sweep = why == .sweep };
        module.file_source = source;
        if (self.debug_files) |files| {
            module.debug_file = (if (entry.offset == 0) self.companionFor(region, &image, path) else files.matching(&image)) catch |err| blk: {
                log.warn(.session, "xodb: debug companion rejected: {s}; {s} offset=0x{x}\n", .{ @errorName(err), path, entry.offset });
                break :blk null;
            };
            if (module.debug_file) |file| log.info(.session, "xodb: debug companion {s} matched {s} offset=0x{x}\n", .{ file.path, path, entry.offset });
        }
        try self.loaded.append(self.allocator, module);
        self.snapshot_bytes += mapped.len;
        if (bound) |b| if (b.pool == .lookups) {
            self.lookup_bytes += mapped.len;
        };
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
        for (self.regions.items) |region| if (address >= region.start and address < region.end) {
            for (self.loaded.items) |module| if (module.explicit_gdb and address >= module.start and address < module.end) return module;
            const module = self.cachedRange(region, false) orelse return error.DebugMetadataNotLoaded;
            return module;
        };
        return error.UnmappedAddress;
    }
    pub fn at(self: *Modules, address: u64) !*Module {
        return self.atFor(address, .frame);
    }
    fn atFor(self: *Modules, address: u64, why: Reason) !*Module {
        if (self.cachedAt(address)) |module| {
            if (why == .frame) module.debug_sweep = false;
            return module;
        } else |_| {}
        if (self.peAt(address)) |_| return error.PeDebugInfoUnavailable else |err| if (err != error.NotPe) return err;
        for (self.regions.items) |r| if (address >= r.start and address < r.end) return self.load(r, why);
        return error.UnmappedAddress;
    }
    /// Whether a stack frame in the file loads it in full, which only an
    /// image with debug info does (see prefersUnwindMetadata); null when
    /// that is not known yet. Nothing is read to answer.
    fn stackLoads(self: *Modules, region: Region) ?bool {
        const index = self.identityIndex(region);
        if (index) |i| if (self.identities.items[i].metadata_only) |decision| return !decision;
        for (self.symbol_images.items) |*item| if (sameFile(item.region, region)) {
            if (item.image.sectionByName(".debug_info") != null or item.image.sectionByName(".zdebug_info") != null or
                item.image.sectionByName(".debug_frame") != null or item.image.sectionByName(".zdebug_frame") != null) return true;
            if (self.debug_files == null) return false;
            const decided = self.identities.items[index orelse return null].companion orelse return null;
            return decided == .found;
        };
        return null;
    }
    /// Keep ordinary stripped-library stack frames on the bounded CFI path.
    /// Full DWARF (including verified companions) retains source/inline views.
    /// A remote caller is classified for a full load only when it has
    /// .debug_frame and no usable .eh_frame. Usable .eh_frame stays on the
    /// bounded worker; Session.stack retries one full load when that frame
    /// does not cover the PC and the symbol view has .debug_frame.
    pub fn prefersUnwindMetadata(self: *Modules, address: u64) !bool {
        if (self.immutable or self.target == null) return false;
        const remote = rt.xrt_target_is_remote(self.target);
        for (self.regions.items) |region| {
            if (address < region.start or address >= region.end) continue;
            if (self.cachedRange(region, false) != null) return false;
            const image = try self.symbolImage(region);
            const index = try self.fileIdentity(region);
            self.syncCompanionPolicy(index);
            if (self.identities.items[index].metadata_only) |decision| return decision;
            if (remote) {
                const debug_frame = image.sectionByName(".debug_frame") != null or image.sectionByName(".zdebug_frame") != null;
                // -fno-unwind-tables still leaves a 4-byte terminator. That is
                // not unwind information; the bounded worker only reads .eh_frame.
                const eh_frame = if (image.sectionByName(".eh_frame")) |section| section.size > 4 else false;
                const full = debug_frame and !eh_frame;
                // Report a rejected automatic companion from this classification.
                // The result does not decide whether the caller is loaded.
                _ = self.companionFor(region, image, region.path) catch null;
                self.identities.items[index].metadata_only = !full;
                return !full;
            }
            const has_dwarf = image.sectionByName(".debug_info") != null or image.sectionByName(".zdebug_info") != null or
                image.sectionByName(".debug_frame") != null or image.sectionByName(".zdebug_frame") != null;
            const full = has_dwarf or (self.companionFor(region, image, region.path) catch null) != null;
            self.identities.items[index].metadata_only = !full;
            return !full;
        }
        return error.UnmappedAddress;
    }
    /// Whether the cached symbol view at `address` contains DWARF CFI.
    /// False when that view was not opened: do not full-load on a guess.
    pub fn symbolHasDebugFrame(self: *const Modules, address: u64) bool {
        for (self.regions.items) |region| {
            if (address < region.start or address >= region.end) continue;
            for (self.symbol_images.items) |*item| {
                if (!sameFile(item.region, region)) continue;
                return item.image.sectionByName(".debug_frame") != null or item.image.sectionByName(".zdebug_frame") != null;
            }
            return false;
        }
        return false;
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
    /// A remote symbol projection records the agent's identity of the file it
    /// read; later file views must match it, and the projection stays pinned.
    pub fn rememberMetadataIdentity(self: *Modules, region: Region, identity: rt.struct_xrt_file_identity) !void {
        if (self.symbol_pending) |pending| if (sameFile(pending.region, region) and !std.meta.eql(pending.identity, identity)) return error.BinaryChangedDuringRead;
        const index = try self.fileIdentity(region);
        const file = &self.identities.items[index];
        if (file.identity) |original| {
            if (!std.meta.eql(original, identity)) return error.BinaryChangedDuringRead;
        }
        file.identity = identity;
    }
    pub fn findSymbol(self: *Modules, name: []const u8) !Symbol {
        defer self.reportBudget();
        if (name.len > 64 * 1024) return error.SymbolNameLimit;
        var empty: ?usize = null;
        const saved: ?usize = for (&self.name_scans, 0..) |*item, i| {
            if (item.name != null and item.revision != self.maps_revision) self.clearNameScan(item);
            if (item.name) |retained| {
                if (std.mem.eql(u8, retained, name)) break i;
            } else if (empty == null) empty = i;
        } else null;
        // A pending answer retains a disposable cursor, not an active request
        // or an image pin. Under pressure retire the least recently polled
        // name, so an abandoned client cannot reserve every slot indefinitely.
        const index = saved orelse empty orelse self.name_scans.len - 1;
        if (saved == null) {
            const retained = try self.allocator.dupe(u8, name);
            self.clearNameScan(&self.name_scans[index]);
            self.name_scans[index] = .{ .name = retained, .revision = self.maps_revision };
        }
        const selected = self.name_scans[index];
        var moving = index;
        while (moving > 0) : (moving -= 1) self.name_scans[moving] = self.name_scans[moving - 1];
        self.name_scans[0] = selected;
        const scan = &self.name_scans[0];
        self.unsearched = scan.unsearched;
        const result = self.symbolLookup(name, false, true, .any, &scan.cursor) catch |err| {
            if (err == error.SymbolDiscoveryPending or err == error.SymbolDiscoveryBudgetExceeded) {
                scan.unsearched = self.unsearched;
            } else self.clearNameScan(scan);
            return err;
        };
        self.clearNameScan(scan);
        return result;
    }
    fn clearNameScan(self: *Modules, scan: *NameScan) void {
        if (scan.name) |name| self.allocator.free(name);
        scan.* = .{};
    }
    fn clearNameScans(self: *Modules) void {
        for (&self.name_scans) |*scan| self.clearNameScan(scan);
    }
    /// The mapped images defining `name`, each loaded in full within the
    /// bounds `definerRead` gives. Images without
    /// it are read through the bounded symbol views, so a runtime search does
    /// not spend the full-image budget on every library. An image whose
    /// tables are too large for that view is reported in `unexamined`, never
    /// read in full to look. The scan is kept for
    /// the current map snapshot: a repeated lookup neither reopens every file
    /// nor restarts a pending large-file read. `name` must outlive the session.
    pub fn definers(self: *Modules, name: []const u8) !Definers {
        defer self.reportBudget();
        const scan = for (&self.definer_scans) |*item| {
            if (item.name.len == 0 or std.mem.eql(u8, item.name, name)) break item;
        } else return error.SymbolDefinerLimit;
        if (scan.name.len == 0 or scan.revision != self.maps_revision) scan.* = .{ .name = name, .revision = self.maps_revision };
        scanning: while (!scan.done) {
            // These callers need native ELF modules for runtime layout/DWARF.
            // A PE export with the same spelling is not a second ELF runtime.
            const symbol = self.symbolLookup(name, false, false, .elf, &scan.cursor) catch |err| {
                if (scan.cursor.next < self.regions.items.len) return err;
                scan.done = true;
                break;
            };
            // The image that defines the name is wanted in full, and nobody
            // asked: see lookupRead. One more than the scan holds is not read.
            const module = self.cachedAt(symbol.address) catch blk: {
                if (scan.count == scan.modules.len) return error.SymbolDefinerLimit;
                break :blk try self.definerRead(symbol.address);
            };
            scan.cursor.next += 1;
            for (scan.modules[0..scan.count]) |old| if (old.id == module.id) continue :scanning;
            if (scan.count == scan.modules.len) return error.SymbolDefinerLimit;
            scan.modules[scan.count] = module;
            scan.count += 1;
        }
        return .{ .modules = scan.modules[0..scan.count], .unexamined = scan.cursor.failure };
    }
    /// The full image at `address` for a language view that found its
    /// runtime there. An automatic read of a file the target chose: the
    /// main executable under the image budgets, any other image within the
    /// fixed lookup bounds.
    fn definerRead(self: *Modules, address: u64) !*Module {
        return self.atFor(address, .runtime);
    }
    /// The same read for a language view that knows where its runtime must
    /// be without a scan: the image at an address the kernel reported, such
    /// as the main executable's program headers. An executable whose symbol
    /// tables are too large for the symbols-only view is found this way.
    pub fn runtimeAt(self: *Modules, address: u64) !*Module {
        defer self.reportBudget();
        return self.atFor(address, .runtime);
    }
    fn symbolImage(self: *Modules, region: Region) !*const elf.Image {
        for (self.symbol_images.items) |*item| if (sameFile(item.region, region)) {
            self.touchSymbols(item);
            return &item.image;
        };
        if (self.symbol_refusals.get(fileKey(region))) |refused| return refused;
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
        var projected = std.mem.zeroes(rt.struct_xrt_file_identity);
        if (rt.xrt_target_is_remote(self.target)) {
            try runtime_api.check(rt.xrt_remote_symbol_file(self.target, &request, &fd, &resident, &projected));
        } else {
            var pinned: rt.struct_xrt_file_identity = undefined;
            self.localSymbolFile(region, &request, &fd, &resident, &source, &pinned, self.identities.items[file_index].identity) catch |err| {
                // Every answer but "not finished yet" is final for this map
                // and is remembered: asking again would start the reader
                // again, answer Pending, and reach the same error, for ever.
                switch (err) {
                    error.SymbolDiscoveryPending, error.SymbolDiscoveryCancelled, error.SymbolDiscoveryBudgetExceeded => {},
                    else => self.symbol_refusals.put(self.allocator, fileKey(region), err) catch {},
                }
                return err;
            };
            identity = pinned;
        }
        defer _ = c.close(fd);
        // The reader finished; whatever refuses its view from here on (too
        // large, not a usable ELF, no memory for it) is final for this map too.
        errdefer |err| self.symbol_refusals.put(self.allocator, fileKey(region), err) catch {};
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_size <= 0 or stat.st_blocks < 0) return error.BinaryUnavailable;
        // Sparse files may allocate a whole page for each tiny distant table.
        // Charge backing pages as well as copied bytes, never the hole extent.
        const retained = @max(resident, std.math.mul(u64, @intCast(stat.st_blocks), 512) catch return error.SymbolSnapshotLimit);
        if (retained > self.symbol_limit) return error.SymbolSnapshotLimit;
        const size = std.math.cast(usize, stat.st_size) orelse return error.SymbolSnapshotLimit;
        const ptr = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
        if (ptr == c.MAP_FAILED) return error.OutOfMemory;
        const bytes: []align(std.heap.page_size_min) u8 = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(ptr)))[0..size];
        errdefer _ = c.munmap(bytes.ptr, bytes.len);
        const image = try elf.Image.parse(bytes);
        if (@intFromEnum(image.header.machine) != rt.xrt_target_arch(self.target).*.machine) return error.UnsupportedTargetArchitecture;
        try self.trimSymbols(retained);
        // A remote projection carries the agent's stat of the file it read,
        // so a later file view is compared with the version symbols came from.
        try self.rememberMetadataIdentity(region, identity orelse projected);
        if (identity == null) self.identities.items[file_index].remote_snapshot = true;
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
            // A remote symbol projection stays pinned. Reopening it could mix
            // two versions under one ID.
            for (self.symbol_images.items, 0..) |item, i| if (self.identities.items[item.file].identity != null and !self.identities.items[item.file].remote_snapshot) {
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
        // A remote file is a sealed host copy. Its host stat is not the
        // target's identity; the agent's identity is compared instead.
        if (self.core_source == null and rt.xrt_target_is_remote(self.target)) return;
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
            try self.openFileView(request, &view);
            const pinned = rt.xrt_file_view_identity(view).*;
            if (expected) |old| if (!std.meta.eql(old, pinned)) {
                _ = rt.xrt_file_view_close(view);
                return error.BinaryChangedDuringRead;
            };
            // Ordinary local symbol lookups stay immediate while retaining only
            // metadata. Large files keep the existing cancellable worker path.
            if (rt.xrt_file_view_identity(view).*.size <= symbol_immediate_limit) {
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
        return self.pendingSymbolAddress(name, cursor, false, .any);
    }
    /// The same resumable lookup for a name the user gave (`--break NAME`,
    /// a pending symbol breakpoint): it may read the main executable in full.
    pub fn breakpointSymbolAddress(self: *Modules, name: []const u8, cursor: *SymbolCursor) !u64 {
        return self.pendingSymbolAddress(name, cursor, true, .code);
    }
    const SymbolIntent = enum { any, code, elf };
    fn pendingSymbolAddress(self: *Modules, name: []const u8, cursor: *SymbolCursor, fallback: bool, intent: SymbolIntent) !u64 {
        defer self.reportBudget();
        const found = try self.symbolLookup(name, true, fallback, intent, cursor);
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
        // A saved breakpoint names its own image. Through a runtime agent
        // only a container entry gets here, under the lookup bounds.
        const module = try self.load(region, .restore);
        const id = module.image.buildId() orelse return error.BreakpointImageHasNoBuildId;
        if (!std.mem.eql(u8, id, build_id)) return error.BreakpointBuildIdMismatch;
        return module.runtimeAddress(offset);
    }
    /// Whether `r` is the main executable, the one image `lookupRead` may
    /// read in full for a name. Once one file has been chosen for this
    /// process image no other ever is.
    fn nameFallback(self: *Modules, r: Region) bool {
        return !self.immutable and self.mainExecutable(r);
    }
    /// The same question for a sweep, which a capture's own (immutable)
    /// module set asks of a live process too.
    fn mainExecutable(self: *Modules, r: Region) bool {
        const key = fileKey(r);
        if (self.name_fallback) |chosen| return std.meta.eql(chosen, key);
        if (self.pid <= 0 or self.core_source != null or rt.xrt_target_is_remote(self.target)) return false;
        if (!isExecutable(self.pid, r)) return false;
        self.name_fallback = key;
        return true;
    }
    extern fn xodb_mapped_file_matches(fd: c_int, pid: c_int, start: u64, end: u64, device_major: u64, device_minor: u64, inode: u64, strict: c_int) c_int;
    /// Whether mapping `r` of `pid` is the file `/proc/PID/exe` names: same
    /// device, inode and path. An inode number alone repeats across
    /// filesystems, and a path alone can be mounted over.
    fn isExecutable(pid: i32, r: Region) bool {
        var link: [32]u8 = undefined;
        const exe = std.fmt.bufPrintZ(&link, "/proc/{d}/exe", .{pid}) catch return false;
        var path: [4097]u8 = undefined;
        const n = c.readlink(exe.ptr, &path, path.len);
        if (n <= 0 or n >= path.len or !std.mem.eql(u8, path[0..@intCast(n)], r.path)) return false;
        const fd = c.open(exe.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) return false;
        defer _ = c.close(fd);
        return xodb_mapped_file_matches(fd, pid, r.start, r.end, r.device_major, r.device_minor, r.inode, 0) != 0;
    }
    /// The one place a name lookup decides to read an image in full. The
    /// target chooses what it maps and what those files say, so the rule is:
    ///
    /// 1. An image already loaded (a stack frame in it, say) is searched at
    ///    no cost; that is done before this is asked.
    /// 2. An image with a symbols-only view is never read in full to look,
    ///    except that a name someone asked for (`explicit`: find_symbol, a
    ///    breakpoint by symbol, --break NAME in the process it was given
    ///    for) may read one image whose tables are too large for that view:
    ///    the main executable, once per process image, under the image
    ///    budgets.
    /// 3. An image with no symbols-only view (an entry inside a container,
    ///    any image of a core or of another session without a live process)
    ///    is read in full by explicit and automatic lookups alike, but only
    ///    within lookup_image_limit each and lookup_total_limit per process.
    /// 4. The image a language view found its runtime in is wanted in full
    ///    with nobody asking (`definerRead`): the main executable under the
    ///    image budgets, any other image within the bounds of 3, and no
    ///    more images than a definer scan holds.
    ///
    /// Null means the rule says no. An error is a read that was tried.
    fn lookupRead(self: *Modules, r: Region, why: Unviewed, explicit: bool) !?*Module {
        if (why == .tables) {
            if (!explicit or !self.nameFallback(r)) return null;
            if (self.fallback_failure) |failed| if (failed.revision == self.maps_revision) return failed.err;
        }
        return self.load(r, .name) catch |err| {
            // A full read of the executable that failed is not repeated for this map.
            if (why == .tables and err != error.OutOfMemory) self.fallback_failure = .{ .revision = self.maps_revision, .err = err };
            return err;
        };
    }
    /// Says which image the last findSymbol could not search, when it ended
    /// without the name. Valid until the next map refresh.
    pub fn unsearchedDetail(self: *const Modules, buffer: []u8) ?[]const u8 {
        const missed = self.unsearched orelse return null;
        if (missed.revision != self.maps_revision or missed.region >= self.regions.items.len) return null;
        var name: [512]u8 = undefined;
        return std.fmt.bufPrint(buffer, "{s}: symbol tables too large to search by name until the image is loaded; only the main executable is read in full for a name", .{snapshot.printable(&name, self.regions.items[missed.region].path, name.len)}) catch null;
    }
    pub const unsearched_text = 512 + 160;
    fn symbolLookup(self: *Modules, name: []const u8, automatic: bool, fallback: bool, intent: SymbolIntent, cursor: *SymbolCursor) !Symbol {
        var failure = cursor.failure;
        defer cursor.failure = failure;
        var classified: usize = 0;
        regions: while (cursor.next < self.regions.items.len) : (cursor.next += 1) {
            const r = self.regions.items[cursor.next];
            // Reuse an existing full image (and its verified debug companion).
            for (self.loaded.items) |module| {
                if (r.inode != module.inode or r.device_major != module.device_major or
                    r.device_minor != module.device_minor or !std.mem.eql(u8, r.path, module.path)) continue;
                if (module.explicit_gdb) {
                    if (module.symbols().findSymbol(name)) |symbol| {
                        if (symbol.hasAddress()) return publishedSymbol(module.image.header.machine, module.id, symbol, symbol.value);
                    }
                    continue :regions;
                }
                const p = self.placement(&module.image, module.file_offset, r, false) catch continue;
                if (p.bias != module.bias) continue;
                if (module.symbols().findSymbol(name)) |symbol| {
                    if (symbol.hasAddress()) return publishedSymbol(module.image.header.machine, module.id, symbol, try module.runtimeAddress(symbol.value));
                }
                continue :regions;
            }
            if (r.offset != 0 and r.permissions[2] != 'x') continue;
            if (r.path.len == 0 or r.path[0] != '/' or
                std.mem.startsWith(u8, r.path, "/dev/") or
                std.mem.startsWith(u8, r.path, "/memfd:") or
                std.mem.endsWith(u8, r.path, " (deleted)"))
            {
                // File-backed executable bytes may hide a native runtime.
                // Anonymous code and ordinary data mappings are not definers.
                if (intent == .elf and r.inode != 0 and r.permissions[2] == 'x')
                    lookupFailure(&failure, intent, error.BinaryIdentityUnavailable);
                continue;
            }
            // A core, or a session without a live process, has no symbols-only reader.
            const no_reader = !rt.xrt_target_is_remote(self.target) and (self.immutable or self.target == null);
            if (intent == .elf and !no_reader) {
                // Each first look at a file is a round trip through a runtime
                // agent. A target chooses how many files it maps, so yield
                // between them; classified files are kept for this map.
                if (rt.xrt_target_is_remote(self.target) and !self.fileClassified(r)) {
                    if (classified == definer_slice_files) return error.SymbolDiscoveryPending;
                    classified += 1;
                }
                const kind = self.fileKind(r) catch |err| {
                    // A file that cannot be identified is not known to be
                    // harmless data: its header mapping alone may be all that
                    // is left of a runtime whose code now runs elsewhere.
                    lookupFailure(&failure, intent, err);
                    continue;
                };
                if (kind == .pe) {
                    const valid = self.nativePeHeaders(r) catch |err| {
                        if (r.permissions[2] == 'x') lookupFailure(&failure, intent, err);
                        continue;
                    };
                    if (!valid and r.permissions[2] == 'x') lookupFailure(&failure, intent, error.BinaryIdentityUnavailable);
                    continue;
                }
            }
            if (intent != .elf and !no_reader and r.offset == 0 and !rt.xrt_target_is_remote(self.target)) {
                if (self.peRegion(r)) |entry| {
                    const found = self.peFindSymbol(entry, name, intent == .code) catch |err| {
                        if (err == error.SymbolDiscoveryPending or err == error.OutOfMemory) return err;
                        lookupFailure(&failure, intent, err);
                        continue;
                    };
                    if (found) |symbol| return symbol;
                    continue;
                } else |err| switch (err) {
                    error.NotPe => {},
                    error.SymbolDiscoveryPending => return err,
                    else => {
                        lookupFailure(&failure, intent, err);
                        continue;
                    },
                }
            }
            // Offset-0 data mappings are admitted above for PE headers only.
            if (automatic and r.permissions[2] != 'x') continue;
            if (!no_reader and self.file_kinds.contains(fileKey(r)) and (self.fileKind(r) catch null) == .pe) continue;
            var why: Unviewed = .no_reader;
            const view: ?*const elf.Image = if (no_reader) null else self.symbolImage(r) catch |err| blk: {
                switch (err) {
                    error.SymbolDiscoveryPending, error.SymbolDiscoveryCancelled, error.SymbolDiscoveryBudgetExceeded => return err,
                    error.UnsupportedMode => why = .container,
                    error.BinarySnapshotLimit => why = .tables,
                    error.NotElf, error.BinaryIdentityUnavailable => {
                        if (intent == .elf and r.inode != 0 and r.permissions[2] == 'x')
                            lookupFailure(&failure, intent, error.BinaryIdentityUnavailable);
                        continue;
                    },
                    else => {
                        lookupFailure(&failure, intent, err);
                        continue;
                    },
                }
                break :blk null;
            };
            const image = view orelse {
                const module = (self.lookupRead(r, why, fallback) catch |err| {
                    if (err != error.NotElf and err != error.NoBinaryImage)
                        lookupFailure(&failure, intent, err)
                    else if (intent == .elf and r.inode != 0 and r.permissions[2] == 'x')
                        lookupFailure(&failure, intent, error.BinaryIdentityUnavailable);
                    continue;
                }) orelse {
                    lookupFailure(&failure, intent, error.BinarySnapshotLimit);
                    if (self.unsearched == null) self.unsearched = .{ .region = cursor.next, .revision = self.maps_revision };
                    continue;
                };
                const symbol = module.symbols().findSymbol(name) orelse continue;
                if (symbol.hasAddress()) return publishedSymbol(module.image.header.machine, module.id, symbol, try module.runtimeAddress(symbol.value));
                continue;
            };
            const symbols = if (self.debug_files != null) blk: {
                const companion = self.companionFor(r, image, r.path) catch null;
                break :blk if (companion) |file| &file.image else image;
            } else image;
            const symbol = symbols.findSymbol(name) orelse continue;
            if (!symbol.hasAddress()) continue;
            const p = self.placement(image, 0, r, false) catch |err| {
                lookupFailure(&failure, intent, err);
                continue;
            };
            return self.retainSymbol(publishedSymbol(symbols.header.machine, try self.moduleId(r, p.bias, 0), symbol, std.math.add(u64, symbol.value, p.bias) catch return error.InvalidAddress));
        }
        return failure orelse if (automatic) error.BreakpointSymbolNotLoaded else error.SymbolNotFound;
    }
    fn lookupFailure(failure: *?anyerror, intent: SymbolIntent, err: anyerror) void {
        // The language readers may tolerate a budget refusal after finding a
        // runtime. Such a refusal must not hide a later identity failure.
        const old_budget = if (failure.*) |old| old == error.BinarySnapshotLimit or old == error.SymbolSnapshotLimit else false;
        const new_budget = err == error.BinarySnapshotLimit or err == error.SymbolSnapshotLimit;
        if (failure.* == null or (intent == .elf and old_budget and !new_budget)) failure.* = err;
    }
    /// Files first examined through a runtime agent in one lookup call. A
    /// count, not a clock: an ordinary process never meets it, and a call
    /// that does always makes this much progress.
    const definer_slice_files = 128;
    /// Whether the native definer policy can answer for this file without
    /// opening it again in this map revision.
    fn fileClassified(self: *const Modules, region: Region) bool {
        const cached = self.file_kinds.get(fileKey(region)) orelse return false;
        if (cached.checked_revision != self.maps_revision) return false;
        return cached.failure != null or cached.kind != .pe or cached.pe_headers_valid != null;
    }
    fn readPeHeader(context: ?*anyopaque, offset: u64, out: ?*anyopaque, size: usize) callconv(.c) c.enum_xpe_status {
        const view: *rt.struct_xrt_file_view = @ptrCast(@alignCast(context.?));
        return if (rt.xrt_file_view_read(view, offset, out, size) == rt.XRT_OK) c.XPE_OK else c.XPE_IO;
    }
    /// MZ alone is not evidence that executable bytes cannot define an ELF
    /// runtime. Validate bounded structural PE headers, never its large tables.
    fn nativePeHeaders(self: *Modules, region: Region) !bool {
        const cached = self.file_kinds.getPtr(fileKey(region)).?;
        if (cached.pe_headers_valid) |valid| return valid;
        errdefer |err| if (err != error.OutOfMemory) {
            cached.failure = err;
        };
        const path = try self.allocator.dupeZ(u8, region.path);
        defer self.allocator.free(path);
        const request = std.mem.zeroInit(rt.struct_xrt_file_request, .{
            .kind = rt.XRT_FILE_MAPPED,
            .mapping = .{ .start = region.start, .end = region.end, .offset = region.offset, .device_major = region.device_major, .device_minor = region.device_minor, .inode = region.inode, .path = path.ptr },
        });
        var view: ?*rt.struct_xrt_file_view = null;
        try self.openFileView(&request, &view);
        defer _ = rt.xrt_file_view_close(view);
        if (!std.meta.eql(cached.identity.?, rt.xrt_file_view_identity(view).*)) {
            cached.failure = error.BinaryChangedDuringRead;
            return error.BinaryChangedDuringRead;
        }
        const source: c.struct_xpe_source = .{ .context = view, .size = @intCast(cached.identity.?.size), .layout = c.XPE_FILE, .read = readPeHeader };
        const status = c.xpe_probe_headers(&source);
        try runtime_api.check(rt.xrt_file_view_validate(view));
        if (status == c.XPE_NOMEM) return error.OutOfMemory;
        if (status == c.XPE_IO) return error.BinaryIdentityUnavailable;
        cached.pe_headers_valid = status == c.XPE_OK;
        return cached.pe_headers_valid.?;
    }
    fn fileKey(region: Region) FileKey {
        return .{ .inode = region.inode, .device_major = region.device_major, .device_minor = region.device_minor };
    }
    fn openFileView(self: *Modules, request: *const rt.struct_xrt_file_request, view: *?*rt.struct_xrt_file_view) !void {
        try runtime_api.check(if (self.owner_target) |target|
            rt.xrt_target_file_view_open_owner(target, request, view)
        else
            rt.xrt_target_file_view_open(self.target, request, view));
    }
    /// Classify bytes once per exact file identity, sharing the answer with
    /// both readers. Revalidate even a negative answer once per map revision:
    /// an inode can change between stops, but thousands of mappings of the
    /// same file must not each reopen and recheck its live VMA.
    fn fileKind(self: *Modules, region: Region) !FileKind {
        const key = fileKey(region);
        if (self.file_kinds.get(key)) |cached| if (cached.checked_revision == self.maps_revision) {
            if (cached.failure) |err| return err;
            return cached.kind;
        };
        // A failed revalidation also belongs to this observation; repeating it
        // for every alias must not turn a stale cached file into an I/O flood.
        errdefer |err| if (err != error.OutOfMemory) {
            if (self.file_kinds.getPtr(key)) |cached| {
                cached.checked_revision = self.maps_revision;
                cached.failure = err;
            } else {
                if (self.file_kinds.count() >= max_file_kinds) self.file_kinds.clearRetainingCapacity();
                self.file_kinds.put(self.allocator, key, .{ .kind = .other, .identity = null, .checked_revision = self.maps_revision, .failure = err }) catch {};
            }
        };
        const path = try self.allocator.dupeZ(u8, region.path);
        defer self.allocator.free(path);
        const request = std.mem.zeroInit(rt.struct_xrt_file_request, .{
            .kind = rt.XRT_FILE_MAPPED,
            .mapping = .{ .start = region.start, .end = region.end, .offset = region.offset, .device_major = region.device_major, .device_minor = region.device_minor, .inode = region.inode, .path = path.ptr },
        });
        var view: ?*rt.struct_xrt_file_view = null;
        try self.openFileView(&request, &view);
        defer _ = rt.xrt_file_view_close(view);
        const identity = rt.xrt_file_view_identity(view).*;
        if (self.file_kinds.getPtr(key)) |cached| {
            if (cached.identity != null and std.meta.eql(cached.identity.?, identity)) {
                cached.checked_revision = self.maps_revision;
                cached.failure = null;
                return cached.kind;
            }
        }
        // Eight bytes: a universal Mach-O shares its magic with a Java class file.
        var magic: [8]u8 = @splat(0);
        const size: usize = @intCast(@min(@max(rt.xrt_file_view_identity(view).*.size, 0), magic.len));
        try runtime_api.check(rt.xrt_file_view_read(view, 0, &magic, size));
        const kind: FileKind = if (std.mem.eql(u8, magic[0..4], "\x7fELF")) .elf else if (std.mem.eql(u8, magic[0..2], "MZ")) .pe else if (c.xmo_probe(&magic, size) != c.XMO_KIND_NONE) .macho else .other;
        if (self.file_kinds.count() >= max_file_kinds) self.file_kinds.clearRetainingCapacity();
        try self.file_kinds.put(self.allocator, key, .{ .kind = kind, .identity = identity, .checked_revision = self.maps_revision });
        return kind;
    }
    /// A mapping pins its inode; once a file leaves the address space its
    /// number may name another file, so the decision is dropped with it.
    fn pruneFileKinds(self: *Modules, regions: []const Region) void {
        if (self.file_kinds.count() == 0 and self.pe_images.files.items.len == 0) return;
        var mapped: std.AutoHashMapUnmanaged(FileKey, void) = .empty;
        defer mapped.deinit(self.allocator);
        for (regions) |region| if (region.inode != 0) mapped.put(self.allocator, fileKey(region), {}) catch {
            self.file_kinds.clearRetainingCapacity();
            return;
        };
        var it = self.file_kinds.keyIterator();
        while (it.next()) |key| if (!mapped.contains(key.*)) self.file_kinds.removeByPtr(key);
        self.pe_images.prune(self.allocator, regions, &mapped);
    }
    /// The pinned file behind a mapping whose bytes classify as Mach-O, for a
    /// read-only look at the file. The caller closes the view. This is not
    /// module discovery: nothing is bound to the process's regions.
    pub fn machoFileView(self: *Modules, address: u64) !struct { view: *rt.struct_xrt_file_view, path: []const u8 } {
        if (self.immutable or self.target == null) return error.NotMachO;
        const region = for (self.regions.items) |region| {
            if (address >= region.start and address < region.end) break region;
        } else return error.NotMachO;
        if (region.inode == 0 or region.path.len == 0 or region.path[0] != '/') return error.NotMachO;
        if (try self.fileKind(region) != .macho) return error.NotMachO;
        const path = try self.allocator.dupeZ(u8, region.path);
        defer self.allocator.free(path);
        const request = std.mem.zeroInit(rt.struct_xrt_file_request, .{
            .kind = rt.XRT_FILE_MAPPED,
            .mapping = .{ .start = region.start, .end = region.end, .offset = region.offset, .device_major = region.device_major, .device_minor = region.device_minor, .inode = region.inode, .path = path.ptr },
        });
        var view: ?*rt.struct_xrt_file_view = null;
        try self.openFileView(&request, &view);
        return .{ .view = view.?, .path = region.path };
    }
    fn peRegion(self: *Modules, region: Region) !*pe.Entry {
        if (self.immutable or self.target == null or rt.xrt_target_is_remote(self.target)) return error.NotPe;
        if (region.offset != 0 or region.inode == 0 or region.path.len == 0 or region.path[0] != '/') return error.NotPe;
        if (try self.fileKind(region) != .pe) return error.NotPe;
        // fileKind proved this identity for the revision. A malformed "MZ" file
        // mapped thousands of times must not be reopened for each mapping.
        const identity = self.file_kinds.get(fileKey(region)).?.identity orelse return error.BinaryIdentityUnavailable;
        self.pe_images.poll();
        _ = try self.pe_images.observeIdentity(fileKey(region), @bitCast(identity));
        if (self.pe_images.failed(identity)) |err| return err;
        const entry = self.pe_images.get(self.allocator, self.owner_target, region, @bitCast(identity)) catch |err| {
            // Cache even a change before the very first PE parse. Otherwise
            // aliases would reopen a file whose stop identity already failed.
            if (err == error.BinaryChangedDuringRead) self.file_kinds.getPtr(fileKey(region)).?.failure = err;
            return err;
        };
        // get revalidates the pinned file. Placement and map labels belong to
        // this revision and must not rescan every mapping on each lookup.
        if (entry.verified_revision == self.maps_revision) return entry;
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
            // Cached classifications prove file identity once per map revision.
            attempts += 1;
            if (attempts > 64) return error.PeDiscoveryLimit;
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
            if (self.pe_images.backgroundDeferred(region)) continue;
            checked += 1;
            _ = self.peRegion(region) catch |err| {
                if (err == error.SymbolDiscoveryPending) return;
                if (err != error.NotPe) self.noteFailure(region, err);
                continue;
            };
        }
    }
    fn peFindSymbol(self: *Modules, entry: *pe.Entry, name: []const u8, code_only: bool) !?Symbol {
        var requested = name;
        if (std.mem.indexOfScalar(u8, name, '!')) |bang| {
            if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(entry.path), name[0..bang])) return null;
            requested = name[bang + 1 ..];
        }
        const z = try self.allocator.dupeZ(u8, requested);
        defer self.allocator.free(z);
        const image = entry.image() orelse return error.SymbolDiscoveryPending;
        if (entry.pdb()) |pdb| if (c.xpdb_find_public(pdb, z)) |symbol| {
            if (code_only and (symbol.*.flags & 3 == 0 or !entry.executable(symbol.*.rva))) return error.BreakpointSymbolNotExecutable;
            const address = try std.math.add(u64, entry.start, symbol.*.rva);
            if (!entry.contains(address)) return error.PeImagePlacementMismatch;
            const function = c.xpe_function_at(image, symbol.*.rva);
            const size: u64 = if (function != null and function.*.begin == symbol.*.rva) function.*.end - symbol.*.rva else 0;
            return try self.retainSymbol(.{ .module_id = entry.id, .name = std.mem.span(symbol.*.name), .address = address, .size = size });
        };
        const found = c.xpe_find_export(image, z) orelse return null;
        if (found.*.forwarder != null) return error.PeForwardedExportUnavailable;
        if (code_only and !entry.executable(found.*.rva)) return error.BreakpointSymbolNotExecutable;
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
        var begin: u32 = if (function != null) function.*.begin else rva;
        const exported = c.xpe_export_name_at(image, begin);
        var label: ?[]const u8 = if (exported != null) std.mem.span(exported) else null;
        if (entry.pdb()) |pdb| if (c.xpdb_public_at(pdb, rva)) |symbol| {
            // Publics have no extent: never carry the nearest name across a
            // proven function boundary or through an unproved leaf/gap.
            if (symbol.*.flags & 3 != 0 and (symbol.*.rva == rva or (function != null and symbol.*.rva >= function.*.begin))) {
                begin = symbol.*.rva;
                label = std.mem.span(symbol.*.name);
            }
        };
        if (label == null and function == null) return error.SymbolNotFound;
        var generated: [32]u8 = undefined;
        const value = label orelse try std.fmt.bufPrint(&generated, "sub_{x}", .{begin});
        const text = try @import("image_label.zig").format(self.allocator, entry.path, value, null);
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
    defer modules.region_starts.deinit(std.testing.allocator);
    defer modules.file_maps.deinit(std.testing.allocator);
    defer modules.dropPlacements();
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

test "remote symbol projection records the first file view and stays pinned" {
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    modules.symbol_limit = 4096;
    const ptr = c.mmap(null, 4096, c.PROT_READ | c.PROT_WRITE, c.MAP_PRIVATE | c.MAP_ANONYMOUS, -1, 0);
    if (ptr == c.MAP_FAILED) return error.OutOfMemory;
    const bytes: snapshot.Bytes = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(ptr)))[0..4096];
    @memcpy(bytes[0..7], "\x7fELF\x02\x01\x01");
    std.mem.writeInt(u16, bytes[16..18], 3, .little);
    std.mem.writeInt(u16, bytes[18..20], 62, .little);
    std.mem.writeInt(u32, bytes[20..24], 1, .little);
    std.mem.writeInt(u16, bytes[52..54], 64, .little);
    const path = try modules.allocator.dupe(u8, "/owned-remote.so");
    const region = Region{ .start = 4096, .end = 8192, .offset = 0, .inode = 9, .device_major = 1, .device_minor = 1, .permissions = "r-xp".*, .path = path };
    const file = try modules.fileIdentity(region);
    modules.identities.items[file].remote_snapshot = true;
    try modules.symbol_images.append(modules.allocator, .{ .region = region, .file = file, .bytes = bytes, .image = try elf.Image.parse(bytes), .retained = 4096 });
    modules.symbol_bytes += 4096;
    var original = std.mem.zeroes(rt.struct_xrt_file_identity);
    original.size = 4096;
    try modules.rememberMetadataIdentity(region, original);
    try std.testing.expect(modules.identities.items[file].remote_snapshot);
    try std.testing.expect(std.meta.eql(modules.identities.items[file].identity.?, original));
    try modules.rememberMetadataIdentity(region, original);
    var changed = original;
    changed.size += 1;
    try std.testing.expectError(error.BinaryChangedDuringRead, modules.rememberMetadataIdentity(region, changed));
    try std.testing.expect(modules.identities.items[file].remote_snapshot);
    try std.testing.expect(std.meta.eql(modules.identities.items[file].identity.?, original));
    try std.testing.expectError(error.SymbolSnapshotLimit, modules.trimSymbols(1));
    try std.testing.expectEqual(@as(usize, 1), modules.symbol_images.items.len);
    try std.testing.expectEqual(@as(u64, 0), modules.symbol_evictions);
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

test "placing many mappings of one file is linear, and the work bound is reported" {
    var bytes: [64 + 2 * 56]u8 align(std.heap.page_size_min) = @splat(0);
    const wr = struct {
        fn f(buffer: []u8, comptime T: type, at_: usize, value: T) void {
            std.mem.writeInt(T, buffer[at_..][0..@sizeOf(T)], value, .little);
        }
    }.f;
    @memcpy(bytes[0..4], "\x7fELF");
    bytes[4] = 2;
    bytes[5] = 1;
    bytes[6] = 1;
    wr(&bytes, u16, 16, 3);
    wr(&bytes, u16, 18, 62);
    wr(&bytes, u32, 20, 1);
    wr(&bytes, u64, 32, 64);
    wr(&bytes, u16, 52, 64);
    wr(&bytes, u16, 54, 56);
    wr(&bytes, u16, 56, 2);
    for (0..2) |i| {
        const at_ = 64 + i * 56;
        wr(&bytes, u32, at_, 1);
        wr(&bytes, u32, at_ + 4, if (i == 0) 4 else 5);
        wr(&bytes, u64, at_ + 8, i * 4096);
        wr(&bytes, u64, at_ + 16, i * 4096);
        wr(&bytes, u64, at_ + 32, 4096);
        wr(&bytes, u64, at_ + 40, 4096);
        wr(&bytes, u64, at_ + 48, 4096);
    }
    const image = try elf.Image.parse(&bytes);
    // 20,000 copies of the header page and one text page after the last.
    const count = 20000;
    const regions = try std.testing.allocator.alloc(Region, count + 1);
    defer std.testing.allocator.free(regions);
    for (regions[0..count], 0..) |*r, i| r.* = .{ .start = 0x100000 + i * 0x10000, .end = 0x101000 + i * 0x10000, .offset = 0, .inode = 7, .device_major = 1, .device_minor = 2, .permissions = "r--p".*, .path = "/many" };
    regions[count] = .{ .start = regions[count - 1].start + 4096, .end = regions[count - 1].start + 8192, .offset = 4096, .inode = 7, .device_major = 1, .device_minor = 2, .permissions = "r-xp".*, .path = "/many" };
    var modules = Modules.init(std.testing.allocator);
    modules.regions = .{ .items = regions, .capacity = regions.len };
    defer {
        modules.clearFailures();
        modules.load_failures.deinit(std.testing.allocator);
        modules.dropPlacements();
        modules.file_maps.deinit(std.testing.allocator);
        modules.region_starts.deinit(std.testing.allocator);
    }
    // Every mapping is placed; the file's mappings are walked once, not once each.
    for (regions[0..count], 0..) |r, i| {
        const p = try modules.placement(&image, 0, r, false);
        try std.testing.expectEqual(r.start, p.bias);
        try std.testing.expectEqual(if (i == count - 1) regions[count].end else r.end, p.end);
    }
    try std.testing.expectEqual(regions[count - 1].start, (try modules.placement(&image, 0, regions[count], false)).bias);
    // One walk of the file's mappings, whatever the number of questions.
    try std.testing.expectEqual(@as(u64, (count + 1) * 2), modules.placement_spent);
    // An ordinary library is a handful of steps: placed, and not counted.
    var other = regions[0];
    other.path = "/other";
    regions[0] = other;
    modules.maps_revision += 1;
    try std.testing.expectEqual(other.start, (try modules.placement(&image, 0, other, false)).bias);
    try std.testing.expectEqual(@as(u64, 0), modules.placement_spent);
    // With the allowance used up, a file whose placement is real work is
    // refused, and the refusal is listed with the other unusable images.
    modules.placement_spent = Modules.placement_work;
    try std.testing.expectError(error.MappingLimit, modules.placement(&image, 0, regions[1], false));
    try std.testing.expectEqual(@as(usize, 1), modules.load_failures.items.len);
    try std.testing.expectEqualStrings("MappingLimit", modules.load_failures.items[0].diagnostic);
    try std.testing.expectEqualStrings("/many", modules.load_failures.items[0].path);
    // The small file beside it is still placed when nothing is left.
    var third = regions[2];
    third.path = "/third";
    regions[2] = third;
    modules.maps_revision += 1;
    _ = try modules.placement(&image, 0, other, false);
    modules.placement_spent = Modules.placement_work;
    try std.testing.expectEqual(third.start, (try modules.placement(&image, 0, third, false)).bias);
    try std.testing.expectEqual(@as(u64, Modules.placement_work), modules.placement_spent);
}

test "the main executable is identified by device as well as inode and path" {
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    const pid: i32 = @intCast(c.getpid());
    try modules.refresh(pid);
    var path: [4097]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &path, path.len);
    try std.testing.expect(n > 0);
    const exe = for (modules.regions.items) |r| {
        if (r.offset == 0 and std.mem.eql(u8, r.path, path[0..@intCast(n)])) break r;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(Modules.isExecutable(pid, exe));
    var other = exe;
    other.device_minor +%= 1;
    try std.testing.expect(!Modules.isExecutable(pid, other));
    other = exe;
    other.device_major +%= 1;
    try std.testing.expect(!Modules.isExecutable(pid, other));
    other = exe;
    other.inode +%= 1;
    try std.testing.expect(!Modules.isExecutable(pid, other));
    // Another mapped file is not the executable whatever its numbers say.
    for (modules.regions.items) |r| if (r.path.len > 0 and r.path[0] == '/' and !std.mem.eql(u8, r.path, exe.path)) {
        try std.testing.expect(!Modules.isExecutable(pid, r));
        break;
    };
}

test "cached file kinds revalidate PE and other answers once per map revision" {
    const native = @cImport({
        @cDefine("_GNU_SOURCE", "1");
        @cInclude("target_internal.h");
        @cInclude("stdlib.h");
        @cInclude("sys/mman.h");
        @cInclude("sys/sysmacros.h");
        @cInclude("sys/stat.h");
    });
    const a = std.testing.allocator;
    const fd = native.memfd_create("mapped-kind", native.MFD_CLOEXEC);
    try std.testing.expect(fd >= 0);
    defer _ = native.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), native.ftruncate(fd, 4096));
    const address = native.mmap(null, 4096, native.PROT_READ, native.MAP_PRIVATE, fd, 0);
    try std.testing.expect(address != native.MAP_FAILED);
    defer _ = native.munmap(address, 4096);
    var st: native.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), native.fstat(fd, &st));
    const path = try std.fmt.allocPrint(a, "/proc/self/fd/{d}", .{fd});
    defer a.free(path);
    var target = std.mem.zeroes(native.struct_xrt_target);
    target.pid = native.getpid();
    target.state = native.XRT_STOPPED;
    defer native.xodb_maps_free(&target.maps);
    var modules = Modules.init(a);
    defer modules.deinit();
    modules.target = @ptrCast(&target);
    modules.owner_target = @ptrCast(&target);
    const region = Region{ .start = @intFromPtr(address), .end = @intFromPtr(address) + 4096, .offset = 0, .inode = st.st_ino, .device_major = native.major(st.st_dev), .device_minor = native.minor(st.st_dev), .permissions = "r--p".*, .path = path };
    const cases = [_]struct { magic: []const u8, kind: Modules.FileKind }{
        .{ .magic = "data", .kind = .other },                             .{ .magic = "MZ00", .kind = .pe },
        .{ .magic = "\x7fELF", .kind = .elf },                            .{ .magic = "none", .kind = .other },
        // Thin 64-bit, universal with two slices, and the Java class file
        // (version 52.0) that shares the universal magic.
        .{ .magic = "\xcf\xfa\xed\xfe", .kind = .macho },                 .{ .magic = "\xca\xfe\xba\xbe\x00\x00\x00\x02", .kind = .macho },
        .{ .magic = "\xca\xfe\xba\xbe\x00\x00\x00\x34", .kind = .other }, .{ .magic = "\xca\xfe\xba\xbf\x00\x00\x00\x01", .kind = .macho },
        .{ .magic = "\xfe\xed\xfa\xcf", .kind = .macho },
    };
    for (cases, 0..) |item, i| {
        // A size change makes the identity change deterministic on coarse clocks.
        try std.testing.expectEqual(@as(c_int, 0), native.ftruncate(fd, @intCast(4096 + i)));
        try std.testing.expectEqual(@as(isize, @intCast(item.magic.len)), native.pwrite(fd, item.magic.ptr, item.magic.len, 0));
        // The prior observation is stable within one stop, even after a file
        // change. A new map revision must prove the changed identity again.
        if (i != 0) try std.testing.expectEqual(cases[i - 1].kind, try modules.fileKind(region));
        modules.maps_revision += 1;
        try std.testing.expectEqual(item.kind, try modules.fileKind(region));
        try std.testing.expectEqual(item.kind, try modules.fileKind(region));
    }
    modules.pruneFileKinds(&.{});
    try std.testing.expectEqual(@as(u32, 0), modules.file_kinds.count());
}

test "automatic PE runtime data lookup has independent breakpoint intent" {
    const native = @cImport({
        @cDefine("_GNU_SOURCE", "1");
        @cInclude("target_internal.h");
        @cInclude("stdlib.h");
        @cInclude("sys/mman.h");
        @cInclude("sys/sysmacros.h");
        @cInclude("sys/stat.h");
    });
    const a = std.testing.allocator;
    const fd = native.memfd_create("runtime-pe", native.MFD_CLOEXEC);
    try std.testing.expect(fd >= 0);
    defer _ = native.close(fd);
    const bytes = @import("../binary/pe_fixture.zig").dataExport();
    try std.testing.expectEqual(@as(isize, bytes.len), native.write(fd, &bytes, bytes.len));
    const address = native.mmap(null, bytes.len, native.PROT_READ, native.MAP_PRIVATE, fd, 0);
    try std.testing.expect(address != native.MAP_FAILED);
    defer _ = native.munmap(address, bytes.len);
    var st: native.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), native.fstat(fd, &st));
    var target = std.mem.zeroes(native.struct_xrt_target);
    target.pid = native.getpid();
    target.state = native.XRT_STOPPED;
    target.thread_count = 1;
    target.threads[0].tid = native.getpid();
    target.threads[0].state = native.XRT_STOPPED;
    defer native.xodb_maps_free(&target.maps);
    var modules = Modules.init(a);
    defer modules.deinit();
    modules.target = @ptrCast(&target);
    modules.owner_target = @ptrCast(&target);
    modules.maps_revision = 1;
    const path = try std.fmt.allocPrint(a, "/proc/self/fd/{d}", .{fd});
    try modules.regions.append(a, .{ .start = @intFromPtr(address), .end = @intFromPtr(address) + bytes.len, .offset = 0, .inode = st.st_ino, .device_major = native.major(st.st_dev), .device_minor = native.minor(st.st_dev), .permissions = "r--p".*, .path = path });
    var load: f64 = 0;
    _ = native.getloadavg(&load, 1);
    const cpus: f64 = @floatFromInt(@max(1, native.sysconf(native._SC_NPROCESSORS_ONLN)));
    const deadline = native.xrt_now() + @as(u64, @intFromFloat(10 * std.time.ns_per_s * @max(1, load / cpus)));
    var cursor = Modules.SymbolCursor{};
    const found = while (true) {
        const value = modules.automaticSymbolAddress("_PyRuntime", &cursor) catch |err| {
            if (err != error.SymbolDiscoveryPending) return err;
            if (native.xrt_now() > deadline) return error.TestJobTimeout;
            _ = native.usleep(100);
            continue;
        };
        break value;
    };
    try std.testing.expectEqual(@intFromPtr(address) + @as(u64, if (c.getenv("XODB_TEST_WRONG_PE_INTENT") != null) 0x381 else 0x380), found);
    cursor = .{};
    try std.testing.expectError(error.BreakpointSymbolNotExecutable, modules.breakpointSymbolAddress("_PyRuntime", &cursor));
    try std.testing.expectEqual(found, (try modules.findSymbol("_PyRuntime")).address);
    try std.testing.expectEqual(@as(u8, 0), @as([*]const u8, @ptrCast(address))[0x380]);
    const native_definers = try modules.definers("_PyRuntime");
    try std.testing.expectEqual(@as(usize, 0), native_definers.modules.len);
    try std.testing.expectEqual(@as(?anyerror, null), native_definers.unexamined);
}

test "pending name lookup slots evict abandoned names and clear on completion or map change" {
    const a = std.testing.allocator;
    var modules = Modules.init(a);
    defer modules.deinit();
    for (&modules.name_scans, 0..) |*scan, i| {
        scan.* = .{ .name = try std.fmt.allocPrint(a, "pending-{d}", .{i}), .revision = modules.maps_revision };
    }
    try std.testing.expectError(if (c.getenv("XODB_TEST_WRONG_SYMBOL_SCAN_LIMIT") != null) error.SymbolLookupLimit else error.SymbolNotFound, modules.findSymbol("new-name"));
    for (modules.name_scans) |scan| if (scan.name) |name| try std.testing.expect(!std.mem.eql(u8, name, "pending-15"));
    try std.testing.expectError(error.SymbolNotFound, modules.findSymbol("pending-0"));
    try std.testing.expectEqual(@as(?[]u8, null), modules.name_scans[0].name);
    try std.testing.expectError(error.SymbolNotFound, modules.findSymbol("new-name"));
    modules.maps_revision += 1;
    try std.testing.expectError(error.SymbolNotFound, modules.findSymbol("new-revision"));
    for (modules.name_scans) |scan| try std.testing.expectEqual(@as(?[]u8, null), scan.name);
    const oversized = try a.alloc(u8, 64 * 1024 + 1);
    defer a.free(oversized);
    try std.testing.expectError(error.SymbolNameLimit, modules.findSymbol(oversized));
}

test "native definer scan knows which files need no further agent round trip" {
    const a = std.testing.allocator;
    var modules = Modules.init(a);
    defer modules.deinit();
    modules.maps_revision = 7;
    const region = Region{ .start = 4096, .end = 8192, .offset = 0, .inode = 9, .device_major = 1, .device_minor = 2, .permissions = "r-xp".*, .path = "/owned" };
    const wrong = c.getenv("XODB_TEST_WRONG_DEFINER_SLICE") != null;
    try std.testing.expect(!modules.fileClassified(region));
    try modules.file_kinds.put(a, Modules.fileKey(region), .{ .kind = .other, .identity = null, .checked_revision = 6 });
    // An answer from an earlier stop must be revalidated: that is a round trip.
    try std.testing.expectEqual(wrong, modules.fileClassified(region));
    modules.file_kinds.getPtr(Modules.fileKey(region)).?.checked_revision = 7;
    try std.testing.expect(modules.fileClassified(region));
    // "MZ" is settled only after its bounded header probe, or by a failure.
    modules.file_kinds.getPtr(Modules.fileKey(region)).?.kind = .pe;
    try std.testing.expect(!modules.fileClassified(region));
    modules.file_kinds.getPtr(Modules.fileKey(region)).?.pe_headers_valid = false;
    try std.testing.expect(modules.fileClassified(region));
    modules.file_kinds.getPtr(Modules.fileKey(region)).?.pe_headers_valid = null;
    modules.file_kinds.getPtr(Modules.fileKey(region)).?.failure = error.BinaryChangedDuringRead;
    try std.testing.expect(modules.fileClassified(region));
}

test "native definer identity refusals cannot be hidden behind a budget exception" {
    for ([_]anyerror{ error.BinarySnapshotLimit, error.SymbolSnapshotLimit }) |budget| {
        var failure: ?anyerror = budget;
        Modules.lookupFailure(&failure, .elf, error.BinaryIdentityUnavailable);
        try std.testing.expectEqual(@as(?anyerror, if (c.getenv("XODB_TEST_WRONG_DEFINER_POLICY") != null) budget else error.BinaryIdentityUnavailable), failure);
        Modules.lookupFailure(&failure, .elf, budget);
        try std.testing.expectEqual(@as(?anyerror, error.BinaryIdentityUnavailable), failure);
    }
}

test "budget stderr admits one notice per interval across stops and owners" {
    var throttle: BudgetThrottle = .{};
    try std.testing.expect(throttle.allow(100));
    for (101..10001) |now| try std.testing.expect(!throttle.allow(now));
    // Burst, silence, then one notice; no backlog is printed.
    try std.testing.expect(throttle.allow(2 * std.time.ns_per_s));
    try std.testing.expect(!throttle.allow(2 * std.time.ns_per_s));
}
