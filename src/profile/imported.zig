//! Immutable, architecture-independent simpleperf evidence. Never a native Capture.
const std = @import("std");
const archive = @import("archive.zig");
const Budget = @import("archive_budget.zig").Budget;
const Progress = @import("archive_progress.zig").Progress;
const tree = @import("flame.zig");
pub const Filter = @import("timeline.zig").Filter;
pub const max_file_bytes = 64 * 1024 * 1024;
pub const memory_limit = 256 * 1024 * 1024;
pub const view_memory_limit = 64 * 1024 * 1024;
pub const max_samples = 65536;
pub const max_frames = 65536;
pub const max_sites = 1048576;
pub const max_nodes = 65536;
pub const algorithm = "simpleperf-period-flames-v1";
const a = std.heap.page_allocator;

pub const Module = struct { path: []const u8, build_id: ?[]const u8 };
pub const Frame = struct {
    module: u32,
    name: []const u8,
    resolved: bool,
    symbol_address: []const u8,
    symbol_size: []const u8,
    mapping_start: []const u8,
    mapping_end: []const u8,
    mapping_offset: []const u8,
};
pub const Site = struct { frame: u32, ip: []const u8, vaddr: []const u8 };
pub const Sample = struct {
    pid: u32,
    tid: u32,
    comm: []const u8,
    time_ns: []const u8,
    period: []const u8,
    cpu: u32,
    stack: []const Site,
};
pub const Source = struct {
    sha256: []const u8,
    bytes: u64,
    command: []const u8,
    metadata: std.json.ArrayHashMap([]const u8),
    labels: []const u8,
    unwind_status: []const u8,
};
pub const Wire = struct {
    format: []const u8,
    version: u32,
    architecture: []const u8,
    event: []const u8,
    unit: []const u8,
    clock: []const u8,
    source: Source,
    modules: []const Module,
    frames: []const Frame,
    samples: []const Sample,
};
pub const Thread = struct { tid: u32, name: []const u8, times: []u64 };
pub const Profile = struct {
    budget: Budget = .{ .backing = a, .limit = memory_limit },
    arena: std.heap.ArenaAllocator = undefined,
    wire: Wire = undefined,
    digest: [64]u8 = undefined,
    times: []u64 = &.{},
    periods: []u64 = &.{},
    threads: []Thread = &.{},
    first_ns: u64 = 0,
    extent_ns: u64 = 0,
    total_period: u64 = 0,
    unresolved_samples: usize = 0,
    pid: u32 = 0,

    pub fn deinit(self: *Profile) void {
        self.arena.deinit();
        a.destroy(self);
    }
    pub fn open(path: [:0]const u8, progress: ?*Progress) !*Profile {
        const bytes = try archive.readFile(a, path, max_file_bytes, progress);
        defer a.free(bytes);
        return decode(bytes, progress);
    }
    pub fn decode(bytes: []const u8, progress: ?*Progress) !*Profile {
        if (bytes.len > max_file_bytes) return error.ImportTooLarge;
        const self = try a.create(Profile);
        self.* = .{};
        self.arena = std.heap.ArenaAllocator.init(self.budget.allocator());
        errdefer self.deinit();
        try checkpoint(progress, .decoding, 0);
        self.wire = std.json.parseFromSliceLeaky(Wire, self.arena.allocator(), bytes, .{ .allocate = .alloc_always, .max_value_len = 65536 }) catch |err| return if (self.budget.denied) error.ImportMemoryLimit else err;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        self.digest = std.fmt.bytesToHex(hash, .lower);
        self.validate(progress) catch |err| return if (self.budget.denied) error.ImportMemoryLimit else err;
        return self;
    }
    fn validate(self: *Profile, progress: ?*Progress) !void {
        const w = self.wire;
        if (!eq(w.format, "xodb.simpleperf") or w.version != 1) return error.ImportVersionUnsupported;
        if (!eq(w.architecture, "aarch64") and !eq(w.architecture, "arm") and !eq(w.architecture, "x86_64") and !eq(w.architecture, "x86")) return error.ImportArchitectureUnsupported;
        if (eq(w.event, "cpu-cycles:u")) {
            if (!eq(w.unit, "cycles")) return error.ImportUnitMismatch;
        } else if (eq(w.event, "task-clock:u") or eq(w.event, "cpu-clock:u")) {
            if (!eq(w.unit, "nanoseconds")) return error.ImportUnitMismatch;
        } else return error.ImportEventUnsupported;
        try text(w.clock, 64);
        if (!eq(w.source.labels, "simpleperf_report_lib") or !eq(w.source.unwind_status, "not_exported")) return error.ImportProvenanceUnsupported;
        if (w.source.sha256.len != 64) return error.ImportInvalidDigest;
        var digest_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest_bytes, w.source.sha256) catch return error.ImportInvalidDigest;
        if (w.source.bytes > 256 * 1024 * 1024) return error.ImportTooLarge;
        try text(w.source.command, 65536);
        if (w.source.metadata.map.count() > 128) return error.ImportLimit;
        var metadata = w.source.metadata.map.iterator();
        while (metadata.next()) |entry| {
            try text(entry.key_ptr.*, 128);
            try text(entry.value_ptr.*, 65536);
        }
        inline for (.{ "trace_offcpu", "system_wide_collection" }) |key| {
            if (w.source.metadata.map.get(key)) |value| if (!eq(value, "false")) return error.ImportScopeUnsupported;
        }
        if (w.samples.len == 0) return error.ImportEmpty;
        if (w.samples.len > max_samples or w.frames.len > max_frames or w.modules.len > 4096) return error.ImportLimit;
        for (w.modules) |module| {
            try text(module.path, 4096);
            if (module.build_id) |id| {
                const hex = if (std.mem.startsWith(u8, id, "0x")) id[2..] else id;
                if (hex.len == 0 or hex.len > 128 or hex.len % 2 != 0) return error.ImportInvalidBuildId;
                var buffer: [64]u8 = undefined;
                _ = std.fmt.hexToBytes(&buffer, hex) catch return error.ImportInvalidBuildId;
            }
        }
        for (w.frames, 0..) |frame, i| {
            if (i % 256 == 0) try checkpoint(progress, .decoding, i);
            if (frame.module >= w.modules.len) return error.ImportReference;
            try text(frame.name, 4096);
            const start = try integer(frame.mapping_start);
            const end = try integer(frame.mapping_end);
            if (end < start) return error.ImportMapping;
            _ = try integer(frame.mapping_offset);
            const symbol = try integer(frame.symbol_address);
            const size = try integer(frame.symbol_size);
            _ = std.math.add(u64, symbol, size) catch return error.ImportOverflow;
        }
        const alloc = self.arena.allocator();
        self.times = try alloc.alloc(u64, w.samples.len);
        self.periods = try alloc.alloc(u64, w.samples.len);
        self.first_ns = std.math.maxInt(u64);
        var last_ns: u64 = 0;
        var sites: usize = 0;
        var tids: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        var threads: std.ArrayList(Thread) = .empty;
        var counts: [1024]usize = @splat(0);
        for (w.samples, 0..) |sample, i| {
            if (i % 128 == 0) try checkpoint(progress, .decoding, i);
            if (sample.pid == 0 or sample.pid > std.math.maxInt(i32) or sample.tid == 0 or sample.tid > std.math.maxInt(i32)) return error.ImportIdentity;
            if (self.pid == 0) self.pid = sample.pid;
            if (sample.pid != self.pid) return error.ImportScopeUnsupported;
            try text(sample.comm, 256);
            const time = try integer(sample.time_ns);
            const period = try integer(sample.period);
            if (period == 0) return error.ImportInvalidPeriod;
            self.total_period = std.math.add(u64, self.total_period, period) catch return error.ImportOverflow;
            self.times[i] = time;
            self.periods[i] = period;
            self.first_ns = @min(self.first_ns, time);
            last_ns = @max(last_ns, time);
            if (sample.stack.len == 0 or sample.stack.len > 256) return error.ImportStackLimit;
            sites += sample.stack.len;
            if (sites > max_sites) return error.ImportStackLimit;
            var unresolved = false;
            for (sample.stack) |site| {
                if (site.frame >= w.frames.len) return error.ImportReference;
                _ = try integer(site.ip);
                _ = try integer(site.vaddr);
                unresolved = unresolved or !w.frames[site.frame].resolved;
            }
            self.unresolved_samples += @intFromBool(unresolved);
            const entry = try tids.getOrPut(alloc, sample.tid);
            if (!entry.found_existing) {
                if (threads.items.len == counts.len) return error.ImportThreadLimit;
                entry.value_ptr.* = threads.items.len;
                try threads.append(alloc, .{ .tid = sample.tid, .name = sample.comm, .times = &.{} });
            }
            counts[entry.value_ptr.*] += 1;
        }
        self.extent_ns = std.math.add(u64, last_ns - self.first_ns, 1) catch return error.ImportOverflow;
        self.threads = try threads.toOwnedSlice(alloc);
        for (self.threads, 0..) |*thread, i| thread.times = try alloc.alloc(u64, counts[i]);
        @memset(&counts, 0);
        for (w.samples, self.times) |sample, absolute| {
            const index = tids.get(sample.tid).?;
            self.threads[index].times[counts[index]] = absolute - self.first_ns;
            counts[index] += 1;
        }
        for (self.threads) |thread| std.mem.sort(u64, thread.times, {}, std.sort.asc(u64));
    }
    pub fn validateFilter(self: *const Profile, filter: Filter) !void {
        try filter.validate();
        if (filter.tid) |tid| if (!self.hasThread(tid)) return error.InvalidProfileThread;
        for (filter.tids.slice()) |tid| if (!self.hasThread(tid)) return error.InvalidProfileThread;
    }
    fn hasThread(self: *const Profile, tid: u32) bool {
        for (self.threads) |thread| if (thread.tid == tid) return true;
        return false;
    }
    pub fn counter(self: *const Profile, key: []const u8) ?u64 {
        var fields = std.mem.splitScalar(u8, self.wire.source.metadata.map.get("record_stat") orelse return null, ',');
        var result: ?u64 = null;
        while (fields.next()) |field| {
            const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
            if (!eq(field[0..equals], key)) continue;
            if (result != null) return null;
            result = integer(field[equals + 1 ..]) catch return null;
        }
        return result;
    }
    pub fn viewId(self: *const Profile, filter: Filter) [64]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(&self.digest);
        hash.update(algorithm);
        var fields: [20]u8 = undefined;
        std.mem.writeInt(u32, fields[0..4], filter.tid orelse 0, .little);
        std.mem.writeInt(u64, fields[4..12], filter.from_ns, .little);
        std.mem.writeInt(u64, fields[12..20], filter.to_ns, .little);
        hash.update(&fields);
        filter.tids.hashInto(&hash);
        return std.fmt.bytesToHex(hash.finalResult(), .lower);
    }
};

pub const View = struct {
    budget: Budget = .{ .backing = a, .limit = view_memory_limit },
    arena: std.heap.ArenaAllocator = undefined,
    graph: tree.Graph = undefined,
    filter: Filter,
    id: [64]u8,
    samples: usize = 0,
    total_period: u64 = 0,
    excluded_period: u64 = 0,
    unresolved_samples: usize = 0,
    examples: []usize = &.{},
    pub fn deinit(self: *View) void {
        self.arena.deinit();
        a.destroy(self);
    }
    pub fn build(profile: *const Profile, filter: Filter, progress: ?*Progress) !*View {
        return buildWithLimit(profile, filter, progress, max_nodes);
    }
    fn buildWithLimit(profile: *const Profile, filter: Filter, progress: ?*Progress, node_limit: usize) !*View {
        try profile.validateFilter(filter);
        const self = try a.create(View);
        self.* = .{ .filter = filter, .id = profile.viewId(filter) };
        self.arena = std.heap.ArenaAllocator.init(self.budget.allocator());
        errdefer self.deinit();
        self.buildInner(profile, progress, node_limit) catch |err| return if (self.budget.denied) error.ImportViewMemoryLimit else err;
        return self;
    }
    fn buildInner(self: *View, profile: *const Profile, progress: ?*Progress, node_limit: usize) !void {
        const alloc = self.arena.allocator();
        self.graph = try tree.Graph.init(alloc);
        self.graph.limit = node_limit;
        self.examples = try alloc.alloc(usize, max_nodes);
        @memset(self.examples, std.math.maxInt(usize));
        var path: [257]tree.Frame = undefined;
        for (profile.wire.samples, 0..) |sample, ordinal| {
            if (ordinal % 128 == 0) try checkpoint(progress, .annotations, ordinal);
            if (!self.filter.contains(sample.tid, profile.times[ordinal] - profile.first_ns)) continue;
            const weight = profile.periods[ordinal];
            self.samples += 1;
            self.total_period += weight; // validated capture total bounds every subset
            var label: []const u8 = sample.comm;
            for (profile.threads) |thread| if (thread.tid == sample.tid) {
                label = thread.name;
                break;
            };
            path[0] = .{ .kind = .thread, .address = sample.tid, .name = label };
            var unresolved = false;
            for (sample.stack, 1..) |site, i| {
                const frame = profile.wire.frames[site.frame];
                // In this separate graph model `address` is a dictionary key,
                // never exposed as a machine PC. Sample sites retain the PCs.
                path[i] = .{ .kind = if (frame.resolved) .code else .unknown, .address = site.frame, .module_id = frame.module, .name = frame.name, .module = profile.wire.modules[frame.module].path };
                unresolved = unresolved or !frame.resolved;
            }
            self.unresolved_samples += @intFromBool(unresolved);
            const old_rejected = self.graph.rejected;
            const old_nodes = self.graph.nodes.items.len;
            try self.graph.addWeighted(path[0 .. sample.stack.len + 1], weight);
            if (self.graph.rejected != old_rejected) {
                self.excluded_period += weight;
                continue;
            }
            if (self.examples[0] == std.math.maxInt(usize)) self.examples[0] = ordinal;
            for (old_nodes..self.graph.nodes.items.len) |i| self.examples[i] = ordinal;
        }
        try checkpoint(progress, .annotations, profile.wire.samples.len);
        try self.graph.layout();
    }
};

fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn text(value: []const u8, limit: usize) !void {
    if (value.len > limit or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.ImportInvalidText;
}
pub fn integer(value: []const u8) !u64 {
    if (value.len == 0 or value.len > 20 or value[0] == '+' or value[0] == '-') return error.ImportInvalidInteger;
    return std.fmt.parseInt(u64, value, if (std.mem.startsWith(u8, value, "0x")) 0 else 10) catch error.ImportInvalidInteger;
}
fn checkpoint(progress: ?*Progress, phase: @import("archive_progress.zig").Phase, units: usize) !void {
    if (progress) |p| try p.step(phase, units);
}

test "import node limit excludes whole samples with their exact period weights" {
    const profile = try Profile.decode(@embedFile("imported_fixture.json"), null);
    defer profile.deinit();
    const view = try View.buildWithLimit(profile, .{}, null, 3);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 3), view.samples);
    try std.testing.expectEqual(@as(u64, 2), view.graph.rejected);
    try std.testing.expectEqual(@as(u64, 18), view.excluded_period);
    try std.testing.expectEqual(@as(u64, 13), view.graph.nodes.items[0].inclusive);
    try std.testing.expectEqual(@as(u64, 31), view.total_period);
    for (view.graph.nodes.items) |node| try std.testing.expectEqual(@as(usize, 2), view.examples[node.id]);
}
