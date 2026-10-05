//! Self-contained invocation evidence. Saved paths are labels only: decoding
//! never opens target files, contacts a process, or resolves executable assets.
//! Calls are replayed from raw records and every stored citation is checked.
const std = @import("std");
const capture = @import("capture.zig");
const calls = @import("calls.zig");
const comparison = @import("comparison.zig");
const types = @import("types.zig");
const Budget = @import("../profile/archive_budget.zig").Budget;
const progress = @import("../profile/archive_progress.zig");
pub const Progress = progress.Progress;
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE"); // glibc's variadic fcntl wrappers cannot translate.
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("sys/stat.h");
    @cInclude("time.h");
    @cInclude("stdlib.h");
});

pub const magic = "XODBINVOC\x01\r\n";
pub const algorithm = "xodb-invocation-pairing-v1";
pub const max_bytes = 64 * 1024 * 1024;
pub const memory_limit = 256 * 1024 * 1024;
pub const max_path = 4096;
pub const max_recipe_bytes = 64 * 1024;
pub const Metadata = struct {
    identity: capture.Identity,
    producer: ?@import("../profile/producer.zig").Producer = null,
    started_ns: u64,
    ended_ns: u64,
    threads: []const capture.Thread,
    functions: []const capture.Function,
    config: capture.Config,
    stop_reason: ?capture.Stop,
    finish_reason: types.Reason,
    /// These are raw register values, never inferred C argument types.
    abi: enum { sysv_x86_64_raw_registers } = .sysv_x86_64_raw_registers,
    /// Historical input only. Opening never executes recipes or follows paths.
    recipe_json: ?[]const u8 = null,
    /// Analysis runs only on an explicit request, with the selected parameters.
    comparison_selection: ?comparison.Selection = null,
};
pub const Evidence = struct {
    metadata: Metadata,
    records: []const types.Record,
    calls: []const types.Call,
    first_gap: ?types.Gap,
    /// Also true when the collector reports a discarded suffix outside the raw
    /// stream; replay can prove some gaps but cannot disprove that diagnostic.
    unread_possible: bool,
    /// Source-side rejection attempts have no fabricated raw event citation.
    rejected: u64,
};
const Wire = struct { version: u32 = 1, pairing_algorithm: []const u8 = algorithm, evidence: Evidence };

pub const Opened = struct {
    budget: Budget,
    bytes: []u8 = &.{},
    parsed: ?std.json.Parsed(Wire) = null,
    store: calls.Store,
    pub fn evidence(self: *const Opened) Evidence {
        return self.parsed.?.value.evidence;
    }
    pub fn deinit(self: *Opened) void {
        const backing = self.budget.backing;
        self.store.deinit(self.budget.allocator());
        if (self.parsed) |parsed| parsed.deinit();
        self.budget.allocator().free(self.bytes);
        backing.destroy(self);
    }
};
pub const DecodeOptions = struct { memory_bytes: usize = memory_limit, progress: ?*Progress = null };

fn check(state: ?*Progress) !void {
    if (state) |p| if (p.cancel.load(.acquire)) return error.ArchiveCancelled;
}
fn validText(text: []const u8, limit: usize) bool {
    return text.len != 0 and text.len <= limit and std.mem.indexOfScalar(u8, text, 0) == null and std.unicode.utf8ValidateSlice(text);
}
fn validateRecipe(a: Allocator, json: []const u8) !void {
    if (json.len > max_recipe_bytes) return error.InvalidObservationRecipe;
    var scanner = std.json.Scanner.initCompleteInput(a, json);
    defer scanner.deinit();
    var depth: usize = 0;
    var first = true;
    while (true) {
        const token = scanner.next() catch |err| return if (err == error.OutOfMemory) err else error.InvalidObservationRecipe;
        if (first and token != .object_begin) return error.InvalidObservationRecipe;
        first = false;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > 64) return error.InvalidObservationRecipe;
            },
            .object_end, .array_end => depth -= 1,
            .end_of_document => return,
            else => {},
        }
    }
}
fn validateMetadata(a: Allocator, saved: Evidence) !void {
    const m = saved.metadata;
    try m.config.validate();
    if (m.identity.session_id == 0 or m.identity.capture_id == 0 or m.identity.process_id == 0 or m.identity.pid <= 0 or m.identity.generation == 0 or
        m.ended_ns < m.started_ns or m.threads.len == 0 or m.threads.len > 32 or m.functions.len == 0 or m.functions.len > 16 or
        m.finish_reason == .pending or m.finish_reason == .complete or saved.records.len > m.config.record_limit or saved.calls.len > saved.records.len)
        return error.InvalidObservationArchive;
    if (m.producer) |p| if (!p.supported()) return error.InvalidObservationArchive;
    for (m.threads, 0..) |thread, i| {
        if (thread.id == 0 or thread.tid <= 0) return error.InvalidObservationArchive;
        for (m.threads[0..i]) |old| if (old.id == thread.id or old.tid == thread.tid) return error.InvalidObservationArchive;
    }
    for (m.functions, 0..) |function, i| {
        const id = function.identity;
        if (function.id == 0 or !validText(function.name, 256) or !validText(function.path, max_path) or id.inode == 0 or id.size <= 0 or
            id.mtime_ns < 0 or id.mtime_ns >= 1000000000 or id.ctime_ns < 0 or id.ctime_ns >= 1000000000 or
            function.file_offset >= @as(u64, @intCast(id.size)) or function.runtime_address == 0 or function.runtime_address >= 0x8000000000000000 or function.link_address >= 0x8000000000000000)
            return error.InvalidObservationArchive;
        for (m.functions[0..i]) |old| if (old.id == function.id or
            (std.meta.eql(old.identity, function.identity) and old.file_offset == function.file_offset)) return error.InvalidObservationArchive;
    }
    if (saved.first_gap) |gap| {
        if (gap.reason == .pending or gap.reason == .complete) return error.InvalidObservationArchive;
        if (gap.record) |ordinal| if (ordinal >= saved.records.len) return error.InvalidObservationArchive;
    }
    if (m.recipe_json) |json| try validateRecipe(a, json);
    if (m.comparison_selection) |selection| try selection.validate();
}
fn validateRawRegisters(sample_: types.Sample) !void {
    // Normalized synthetic records may omit raw registers. When supplied, the
    // saved adaptation must agree with the authoritative perf decoder's ABI.
    const raw = sample_.raw_registers orelse return;
    if (raw.abi != 2 or raw.mask != @import("perf.zig").register_mask or sample_.ip != raw.ip)
        return error.InvalidObservationArchive;
    const entering = sample_.phase == .enter;
    const key = if (entering) raw.sp else std.math.sub(u64, raw.sp, 8) catch return error.InvalidObservationArchive;
    if (key == 0 or sample_.stack_key != key) return error.InvalidObservationArchive;
    const args: [types.max_arguments]u64 = if (entering) .{ raw.di, raw.si, raw.dx, raw.cx, raw.r8, raw.r9 } else @splat(0);
    if (sample_.arg_count != @as(u8, if (entering) types.max_arguments else 0) or
        !std.mem.eql(u64, &sample_.args, &args) or
        sample_.result != (if (entering) @as(?u64, null) else raw.ax)) return error.InvalidObservationArchive;
}
fn replay(a: Allocator, saved: Evidence, state: ?*Progress) !calls.Store {
    try validateMetadata(a, saved);
    var store = try calls.Store.init(saved.metadata.config.store());
    errdefer store.deinit(a);
    for (saved.records, 0..) |record, ordinal| {
        if (ordinal % 256 == 0) try progress.step(state, .decoding, ordinal);
        if (record.ordinal != ordinal) return error.InvalidObservationArchive;
        const event = record.event;
        for (saved.metadata.threads) |thread| {
            if (thread.id == event.thread_id and thread.tid == event.tid) break;
        } else return error.InvalidObservationArchive;
        if (event.data == .sample) {
            try validateRawRegisters(event.data.sample);
            for (saved.metadata.functions) |function| {
                if (function.id == event.data.sample.function_id) break;
            } else return error.InvalidObservationArchive;
        }
        store.feed(a, event) catch |err| return if (err == error.OutOfMemory) err else error.InvalidObservationArchive;
    }
    if (store.finished and store.finish_reason != saved.metadata.finish_reason) return error.InvalidObservationArchive;
    store.finish(saved.metadata.finish_reason);
    if (store.calls.items.len != saved.calls.len or !std.meta.eql(store.first_gap, saved.first_gap) or (store.unread_possible and !saved.unread_possible))
        return error.InvalidObservationArchive;
    for (store.calls.items, saved.calls) |derived, recorded| {
        if (!std.meta.eql(derived, recorded)) return error.InvalidObservationArchive;
    }
    // Rejections are source diagnostics; they are not used to derive durations,
    // pairings or loss totals. The unrecorded attempt cannot be replayed.
    store.rejected = saved.rejected;
    store.unread_possible = saved.unread_possible;
    try check(state);
    return store;
}
pub fn encode(a: Allocator, evidence: Evidence, state: ?*Progress) ![]u8 {
    try check(state);
    var budget = Budget{ .backing = a, .limit = memory_limit };
    const scratch = budget.allocator();
    var checked = try replay(scratch, evidence, state);
    defer checked.deinit(scratch);
    try progress.step(state, .encoding, 0);
    const body = try std.json.Stringify.valueAlloc(scratch, Wire{ .evidence = evidence }, .{});
    defer scratch.free(body);
    try check(state);
    return wrap(a, body);
}
fn wrap(a: Allocator, body: []const u8) ![]u8 {
    if (body.len > max_bytes - magic.len - 32) return error.ArchiveTooLarge;
    const bytes = try a.alloc(u8, magic.len + 32 + body.len);
    @memcpy(bytes[0..magic.len], magic);
    std.crypto.hash.sha2.Sha256.hash(body, bytes[magic.len..][0..32], .{});
    @memcpy(bytes[magic.len + 32 ..], body);
    return bytes;
}
pub fn decode(a: Allocator, bytes: []const u8, state: ?*Progress) !*Opened {
    return decodeWithOptions(a, bytes, .{ .progress = state });
}
pub fn decodeWithOptions(a: Allocator, bytes: []const u8, options: DecodeOptions) !*Opened {
    try check(options.progress);
    if (options.memory_bytes == 0 or options.memory_bytes > 512 * 1024 * 1024) return error.ArchiveMemoryLimit;
    if (bytes.len > max_bytes) return error.ArchiveTooLarge;
    if (bytes.len < magic.len + 32) return error.ArchiveTruncated;
    if (!std.mem.startsWith(u8, bytes, magic)) return error.InvalidObservationArchive;
    const body = bytes[magic.len + 32 ..];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[magic.len..][0..32])) return error.ArchiveChecksum;
    const self = try a.create(Opened);
    self.* = .{ .budget = .{ .backing = a, .limit = options.memory_bytes }, .store = try calls.Store.init(.{}) };
    errdefer self.deinit();
    decodeInto(self, bytes, options.progress) catch |err| return if (self.budget.denied) error.ArchiveMemoryLimit else err;
    return self;
}
fn decodeInto(self: *Opened, bytes: []const u8, state: ?*Progress) !void {
    try progress.step(state, .decoding, 0);
    const a = self.budget.allocator();
    self.bytes = try a.dupe(u8, bytes);
    self.parsed = try std.json.parseFromSlice(Wire, a, self.bytes[magic.len + 32 ..], .{ .max_value_len = max_recipe_bytes, .allocate = .alloc_always });
    const wire = self.parsed.?.value;
    if (wire.version != 1 or !std.mem.eql(u8, wire.pairing_algorithm, algorithm)) return error.ObservationArchiveVersion;
    self.store = try replay(a, wire.evidence, state);
}

pub const Publication = struct {
    state: enum { not_published, published } = .not_published,
    error_name: ?[]const u8 = null,
    cleanup_error: bool = false,
    bytes: usize = 0,
    sha256: [64]u8 = @splat('0'),
};
fn pathValid(path: [:0]const u8) bool {
    return path.len != 0 and path.len <= max_path and std.mem.indexOfScalar(u8, path, 0) == null;
}
/// Atomic, no-overwrite publication in the destination directory. Successful
/// publication survives a later cancellation; no durability sync is promised.
pub fn publish(path: [:0]const u8, bytes: []const u8, state: ?*Progress) Publication {
    var result = Publication{ .bytes = bytes.len };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    result.sha256 = std.fmt.bytesToHex(digest, .lower);
    publishInner(path, bytes, state, &result) catch |err| {
        result.error_name = @errorName(err);
    };
    return result;
}
fn publishInner(path: [:0]const u8, bytes: []const u8, state: ?*Progress, result: *Publication) !void {
    if (!pathValid(path)) return error.ArchivePathInvalid;
    if (bytes.len > max_bytes) return error.ArchiveTooLarge;
    try progress.step(state, .publishing, 0);
    var now: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &now) != 0) return error.ArchiveClockFailed;
    var buffer: [max_path + 96]u8 = undefined;
    const temporary = try std.fmt.bufPrintZ(&buffer, "{s}.xoi-{d}-{d}-{d}.tmp", .{ path, c.getpid(), now.tv_sec, now.tv_nsec });
    const fd = c.open(temporary.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o644));
    if (fd < 0) return error.ArchiveOpenFailed;
    defer if (c.unlink(temporary.ptr) != 0) {
        result.cleanup_error = true;
    };
    var closed = false;
    defer if (!closed) {
        _ = c.close(fd);
    };
    var offset: usize = 0;
    while (offset < bytes.len) {
        try progress.step(state, .publishing, offset);
        const n = c.write(fd, bytes.ptr + offset, @min(1024 * 1024, bytes.len - offset));
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return error.ArchiveWriteFailed;
        offset += @intCast(n);
    }
    closed = true; // Linux releases the descriptor even if close reports failure.
    if (c.close(fd) != 0) return error.ArchiveCloseFailed;
    try progress.step(state, .publishing, bytes.len);
    if (c.link(temporary.ptr, path.ptr) != 0) return if (std.c._errno().* == c.EEXIST) error.ArchiveExists else error.ArchivePublishFailed;
    result.state = .published;
}
pub fn save(a: Allocator, path: [:0]const u8, evidence: Evidence, state: ?*Progress) !Publication {
    const bytes = try encode(a, evidence, state);
    defer a.free(bytes);
    return publish(path, bytes, state);
}
pub fn readFile(a: Allocator, path: [:0]const u8, state: ?*Progress) ![]u8 {
    if (!pathValid(path)) return error.ArchivePathInvalid;
    try progress.step(state, .reading, 0);
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK | c.O_NOFOLLOW);
    if (fd < 0) return error.ArchiveOpenFailed;
    defer _ = c.close(fd);
    var before: c.struct_stat = undefined;
    if (c.fstat(fd, &before) != 0 or before.st_mode & c.S_IFMT != c.S_IFREG) return error.ArchiveNotRegular;
    if (before.st_size < 0 or before.st_size > max_bytes) return error.ArchiveTooLarge;
    const bytes = try a.alloc(u8, @intCast(before.st_size));
    errdefer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        try progress.step(state, .reading, offset);
        const n = c.read(fd, bytes.ptr + offset, @min(1024 * 1024, bytes.len - offset));
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return error.ArchiveTruncated;
        offset += @intCast(n);
    }
    var after: c.struct_stat = undefined;
    if (c.fstat(fd, &after) != 0 or before.st_size != after.st_size or before.st_mtim.tv_sec != after.st_mtim.tv_sec or before.st_mtim.tv_nsec != after.st_mtim.tv_nsec or before.st_ctim.tv_sec != after.st_ctim.tv_sec or before.st_ctim.tv_nsec != after.st_ctim.tv_nsec)
        return error.ArchiveChangedDuringRead;
    try check(state);
    return bytes;
}
pub fn open(a: Allocator, path: [:0]const u8, state: ?*Progress) !*Opened {
    const bytes = try readFile(a, path, state);
    defer a.free(bytes);
    return decode(a, bytes, state);
}

fn fixture(store: *const calls.Store) Evidence {
    return .{
        .metadata = .{
            .identity = .{ .session_id = 1, .capture_id = 2, .process_id = 3, .pid = 100, .image_epoch = 4, .generation = 5 },
            .started_ns = 10,
            .ended_ns = 100,
            .threads = &.{.{ .id = 1, .tid = 100 }},
            .functions = &.{.{ .id = 1, .name = "work", .path = "/untrusted/never-open-this", .identity = .{ .device = 1, .inode = 2, .size = 4096, .mtime_sec = 0, .mtime_ns = 0, .ctime_sec = 0, .ctime_ns = 0 }, .file_offset = 100, .link_address = 100, .runtime_address = 0x400100 }},
            .config = .{},
            .stop_reason = .manual,
            .finish_reason = store.finish_reason.?,
        },
        .records = store.records.items,
        .calls = store.calls.items,
        .first_gap = store.first_gap,
        .unread_possible = store.unread_possible,
        .rejected = store.rejected,
    };
}
fn sample(phase: types.Phase, time: u64) types.Event {
    return .{ .thread_id = 1, .tid = 100, .time_ns = time, .data = .{ .sample = .{ .phase = phase, .function_id = 1, .stack_key = 0x1000, .args = if (phase == .enter) .{ 1, 2, 3, 4, 5, 6 } else @splat(0), .arg_count = if (phase == .enter) 6 else 0, .result = if (phase == .leave) 7 else null } } };
}
test "observation archive deterministic roundtrip retains raw values and stable citations without assets" {
    const a = std.testing.allocator;
    var store = try calls.Store.init((capture.Config{}).store());
    defer store.deinit(a);
    try store.feed(a, sample(.enter, 20));
    try store.feed(a, sample(.leave, 30));
    store.finish(.capture_end);
    const first = try encode(a, fixture(&store), null);
    defer a.free(first);
    const opened = try decode(a, first, null);
    defer opened.deinit();
    const second = try encode(a, opened.evidence(), null);
    defer a.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expectEqual(@as(?u64, 10), opened.store.duration(opened.store.calls.items[0]));
    try std.testing.expectEqual(@as(u64, 6), opened.store.records.items[0].event.data.sample.args[5]);
    try std.testing.expectEqual(@as(?u64, 7), opened.store.records.items[1].event.data.sample.result);
    try std.testing.expectEqual(@as(?u32, 0), opened.store.calls.items[0].entry_record);
    try std.testing.expectEqualStrings("/untrusted/never-open-this", opened.evidence().metadata.functions[0].path);
}
fn perfSample(phase: types.Phase, time: u64) !types.Event {
    const perf = @import("perf.zig");
    var bytes: [112]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 9, .little);
    std.mem.writeInt(u16, bytes[4..6], 2, .little);
    std.mem.writeInt(u16, bytes[6..8], bytes.len, .little);
    std.mem.writeInt(u32, bytes[8..12], 100, .little);
    std.mem.writeInt(u32, bytes[12..16], 100, .little);
    std.mem.writeInt(u64, bytes[16..24], time, .little);
    std.mem.writeInt(u64, bytes[24..32], if (phase == .enter) 100 else 101, .little);
    std.mem.writeInt(u64, bytes[32..40], 2, .little);
    // Actual perf layout: AX,CX,DX,SI,DI,SP,IP,R8,R9. High bits are data.
    const words = [_]u64{ 0xfedcba9876543210, 4, 3, 2, 1, if (phase == .enter) 0x1000 else 0x1008, 0x400100, 0x8000000000000005, 6 };
    for (words, 0..) |word_, i| std.mem.writeInt(u64, bytes[40 + i * 8 ..][0..8], word_, .little);
    const decoded = try perf.decode(&bytes, .{ .pid = 100, .tid = 100, .hooks = &.{.{ .id = 1, .entry_id = 100, .return_id = 101 }} });
    return decoded.event(1, 100).?;
}
test "observation archive preserves authoritative perf register normalization" {
    const a = std.testing.allocator;
    var store = try calls.Store.init((capture.Config{}).store());
    defer store.deinit(a);
    try store.feed(a, try perfSample(.enter, 20));
    try store.feed(a, try perfSample(.leave, 30));
    store.finish(.capture_end);
    const bytes = try encode(a, fixture(&store), null);
    defer a.free(bytes);
    const opened = try decode(a, bytes, null);
    defer opened.deinit();
    try std.testing.expect(std.meta.eql(store.records.items[0], opened.store.records.items[0]));
    try std.testing.expect(std.meta.eql(store.records.items[1], opened.store.records.items[1]));
    try std.testing.expectEqual(@as(?u64, 10), opened.store.duration(opened.store.calls.items[0]));
    try std.testing.expectEqual(@as(u64, 0x8000000000000005), opened.store.records.items[0].event.data.sample.args[4]);
    try std.testing.expectEqual(@as(?u64, 0xfedcba9876543210), opened.store.records.items[1].event.data.sample.result);
}
fn rejectRawContradiction(a: Allocator, evidence: Evidence) !void {
    try std.testing.expectError(error.InvalidObservationArchive, encode(a, evidence, null));
    // Bypass encode's checks and recompute the checksum to model hostile data.
    const body = try std.json.Stringify.valueAlloc(a, Wire{ .evidence = evidence }, .{});
    defer a.free(body);
    const bytes = try wrap(a, body);
    defer a.free(bytes);
    try std.testing.expectError(error.InvalidObservationArchive, decode(a, bytes, null));
}
test "observation archive rejects contradictory raw register ABI arguments results and stack keys" {
    const a = std.testing.allocator;
    var store = try calls.Store.init((capture.Config{}).store());
    defer store.deinit(a);
    try store.feed(a, try perfSample(.enter, 20));
    try store.feed(a, try perfSample(.leave, 30));
    store.finish(.capture_end);
    var saved = fixture(&store);
    var records: [2]types.Record = undefined;
    saved.records = &records;
    for (0..6) |argument| {
        @memcpy(&records, store.records.items);
        records[0].event.data.sample.args[argument] ^= 1;
        try rejectRawContradiction(a, saved);
    }
    for (0..13) |change| {
        @memcpy(&records, store.records.items);
        const entry = &records[0].event.data.sample;
        const leave = &records[1].event.data.sample;
        switch (change) {
            0 => entry.raw_registers.?.abi = 1,
            1 => entry.raw_registers.?.mask ^= 1,
            2 => entry.ip ^= 1,
            3 => entry.raw_registers.?.sp ^= 1,
            4 => {
                entry.raw_registers.?.sp = 0;
                entry.stack_key = 0;
            },
            5 => entry.arg_count = 5,
            6 => entry.result = 0,
            7 => leave.arg_count = 1,
            8 => leave.args[0] = 1,
            9 => leave.result = null,
            10 => leave.result = leave.result.? ^ 1,
            11 => leave.raw_registers.?.sp ^= 1,
            12 => leave.ip ^= 1,
            else => unreachable,
        }
        try rejectRawContradiction(a, saved);
    }
    for (0..9) |sp| {
        @memcpy(&records, store.records.items);
        records[1].event.data.sample.raw_registers.?.sp = sp;
        records[1].event.data.sample.stack_key = 0;
        try rejectRawContradiction(a, saved);
    }
}
test "observation archive supports empty and interrupted captures without fabricated complete calls" {
    const a = std.testing.allocator;
    for ([_]types.Reason{ .capture_end, .cancelled, .unread, .record_limit, .memory_limit }) |reason| {
        for ([_]bool{ false, true }) |with_entry| {
            var store = try calls.Store.init((capture.Config{}).store());
            defer store.deinit(a);
            if (with_entry) try store.feed(a, sample(.enter, 20));
            store.finish(reason);
            const bytes = try encode(a, fixture(&store), null);
            defer a.free(bytes);
            const opened = try decode(a, bytes, null);
            defer opened.deinit();
            try std.testing.expectEqual(store.finish_reason, opened.store.finish_reason);
            try std.testing.expectEqual(store.unread_possible, opened.store.unread_possible);
            if (with_entry) {
                try std.testing.expectEqual(reason, opened.store.calls.items[0].reason);
                try std.testing.expectEqual(@as(?u64, null), opened.store.duration(opened.store.calls.items[0]));
            }
        }
    }
}
test "observation archive rejects malformed checksums versions citations scope and memory exhaustion" {
    const a = std.testing.allocator;
    var store = try calls.Store.init((capture.Config{}).store());
    defer store.deinit(a);
    try store.feed(a, sample(.enter, 20));
    try store.feed(a, sample(.leave, 30));
    store.finish(.capture_end);
    const bytes = try encode(a, fixture(&store), null);
    defer a.free(bytes);
    for ([_]usize{ 0, 1, magic.len, magic.len + 31 }) |len| try std.testing.expectError(error.ArchiveTruncated, decode(a, bytes[0..len], null));
    try std.testing.expectError(error.ArchiveChecksum, decode(a, bytes[0 .. bytes.len - 1], null));
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.ArchiveChecksum, decode(a, bytes, null));
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.ArchiveMemoryLimit, decodeWithOptions(a, bytes, .{ .memory_bytes = 1 }));
    var cancelled = Progress{};
    cancelled.cancel.store(true, .release);
    try std.testing.expectError(error.ArchiveCancelled, decode(a, bytes, &cancelled));
    try std.testing.expectError(error.ArchiveCancelled, encode(a, fixture(&store), &cancelled));
    var changed = fixture(&store);
    var bogus_calls = [_]types.Call{store.calls.items[0]};
    bogus_calls[0].entry_record = 1;
    changed.calls = &bogus_calls;
    try std.testing.expectError(error.InvalidObservationArchive, encode(a, changed, null));
    // Wrap bypasses the writer's own validation, modeling hostile JSON whose
    // checksum was recomputed by its author (the checksum is not a signature).
    const bad_body = try std.json.Stringify.valueAlloc(a, Wire{ .evidence = changed }, .{});
    defer a.free(bad_body);
    const bad_bytes = try wrap(a, bad_body);
    defer a.free(bad_bytes);
    try std.testing.expectError(error.InvalidObservationArchive, decode(a, bad_bytes, null));
    const version_body = try std.json.Stringify.valueAlloc(a, Wire{ .version = 2, .evidence = fixture(&store) }, .{});
    defer a.free(version_body);
    const version_bytes = try wrap(a, version_body);
    defer a.free(version_bytes);
    try std.testing.expectError(error.ObservationArchiveVersion, decode(a, version_bytes, null));
    changed = fixture(&store);
    changed.metadata.threads = &.{.{ .id = 2, .tid = 100 }};
    try std.testing.expectError(error.InvalidObservationArchive, encode(a, changed, null));
}

test "observation archive validates loss and terminal replay rather than trusting stored totals" {
    const a = std.testing.allocator;
    var store = try calls.Store.init((capture.Config{}).store());
    defer store.deinit(a);
    try store.feed(a, sample(.enter, 20));
    try store.feed(a, .{ .thread_id = 1, .tid = 100, .time_ns = 21, .data = .{ .lost = 9 } });
    try store.feed(a, sample(.leave, 30));
    try store.feed(a, .{ .thread_id = 1, .tid = 100, .time_ns = 40, .data = .exec });
    const bytes = try encode(a, fixture(&store), null);
    defer a.free(bytes);
    const opened = try decode(a, bytes, null);
    defer opened.deinit();
    try std.testing.expectEqual(@as(u64, 9), opened.store.lost);
    try std.testing.expectEqual(@as(?types.Reason, .exec), opened.store.finish_reason);
    for (opened.store.calls.items) |call| try std.testing.expect(call.reason != .complete);
    var changed = fixture(&store);
    changed.first_gap = null;
    try std.testing.expectError(error.InvalidObservationArchive, encode(a, changed, null));
    changed = fixture(&store);
    changed.metadata.finish_reason = .capture_end;
    try std.testing.expectError(error.InvalidObservationArchive, encode(a, changed, null));
    changed = fixture(&store);
    changed.unread_possible = true; // Collector discarded data after terminal exec.
    const conservative = try encode(a, changed, null);
    defer a.free(conservative);
    const partial = try decode(a, conservative, null);
    defer partial.deinit();
    try std.testing.expect(partial.store.unread_possible);

    var unread = try calls.Store.init((capture.Config{}).store());
    defer unread.deinit(a);
    unread.finish(.unread);
    changed = fixture(&unread);
    changed.unread_possible = false;
    try std.testing.expectError(error.InvalidObservationArchive, encode(a, changed, null));
}

fn decodeAllocationFailure(a: Allocator, bytes: []const u8) !void {
    const opened = try decode(a, bytes, null);
    defer opened.deinit();
}
fn encodeAllocationFailure(a: Allocator, evidence: Evidence) !void {
    const bytes = try encode(a, evidence, null);
    defer a.free(bytes);
}
test "observation archive frees partial decoding and encoding at every allocator failure" {
    const a = std.testing.allocator;
    var store = try calls.Store.init((capture.Config{}).store());
    defer store.deinit(a);
    try store.feed(a, sample(.enter, 20));
    try store.feed(a, sample(.leave, 30));
    store.finish(.capture_end);
    const evidence = fixture(&store);
    const bytes = try encode(a, evidence, null);
    defer a.free(bytes);
    try std.testing.checkAllAllocationFailures(a, decodeAllocationFailure, .{bytes});
    try std.testing.checkAllAllocationFailures(a, encodeAllocationFailure, .{evidence});
}

test "observation archive publication preserves existing files and cleans temporary files on failure" {
    const a = std.testing.allocator;
    var template = "/tmp/xodb-observation-archive-XXXXXX".*;
    const directory = c.mkdtemp(@ptrCast(&template)) orelse return error.ArchiveOpenFailed;
    defer {
        _ = c.rmdir(directory);
    }
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(directory, 0o755));
    var path_buffer: [max_path]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/evidence.xoi", .{std.mem.span(directory)});
    defer {
        _ = c.unlink(path.ptr);
    }
    var store = try calls.Store.init((capture.Config{}).store());
    defer store.deinit(a);
    store.finish(.capture_end);
    const bytes = try encode(a, fixture(&store), null);
    defer a.free(bytes);
    const first = publish(path, bytes, null);
    try std.testing.expectEqual(.published, first.state);
    try std.testing.expectEqual(@as(?[]const u8, null), first.error_name);
    try std.testing.expect(!first.cleanup_error);
    const reopened = try open(a, path, null);
    defer reopened.deinit();
    try std.testing.expectEqualSlices(u8, bytes, reopened.bytes);
    const again = publish(path, "must not replace evidence", null);
    try std.testing.expectEqual(.not_published, again.state);
    try std.testing.expectEqualStrings("ArchiveExists", again.error_name.?);
    try std.testing.expect(!again.cleanup_error);
    const retained = try readFile(a, path, null);
    defer a.free(retained);
    try std.testing.expectEqualSlices(u8, bytes, retained);
    var cancelled = Progress{};
    cancelled.cancel.store(true, .release);
    var cancelled_buffer: [max_path]u8 = undefined;
    const cancelled_path = try std.fmt.bufPrintZ(&cancelled_buffer, "{s}/cancelled.xoi", .{std.mem.span(directory)});
    const interrupted = publish(cancelled_path, bytes, &cancelled);
    try std.testing.expectEqualStrings("ArchiveCancelled", interrupted.error_name.?);
    try std.testing.expectEqual(.not_published, interrupted.state);
    try std.testing.expectEqual(@as(c_int, -1), c.access(cancelled_path.ptr, c.F_OK));
    try std.testing.expectError(error.ArchiveCancelled, open(a, path, &cancelled));
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(path.ptr));
    // rmdir succeeds only if both failed publications removed temporary files.
    try std.testing.expectEqual(@as(c_int, 0), c.rmdir(directory));
}

test "observation archive default record ceiling and full raw values fit independent budgets" {
    const a = std.testing.allocator;
    const config = capture.Config{};
    var store = try calls.Store.init(config.store());
    defer store.deinit(a);
    for (0..config.record_limit / 2) |i| {
        var entry = sample(.enter, 20 + i * 2);
        entry.data.sample.args = @splat(std.math.maxInt(u64));
        entry.data.sample.stack.len = types.max_stack_pcs;
        entry.data.sample.stack.pcs = @splat(0x7fff12345678);
        try store.feed(a, entry);
        try store.feed(a, sample(.leave, 21 + i * 2));
    }
    store.finish(.capture_end);
    var evidence = fixture(&store);
    evidence.metadata.ended_ns = 100 + config.record_limit;
    const bytes = try encode(a, evidence, null);
    defer a.free(bytes);
    const opened = try decode(a, bytes, null);
    defer opened.deinit();
    try std.testing.expectEqual(config.record_limit, opened.store.records.items.len);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), opened.store.records.items[0].event.data.sample.args[5]);
    try std.testing.expectEqual(@as(u64, 0x7fff12345678), opened.store.records.items[0].event.data.sample.stack.pcs[types.max_stack_pcs - 1]);
    try std.testing.expect(opened.budget.peak <= memory_limit);
    std.debug.print("observation archive budget: records={d} bytes={d} decode_peak={d}\n", .{ store.records.items.len, bytes.len, opened.budget.peak });
}

test "observation archive retains bounded recipes and selected cohorts without evaluating them" {
    const a = std.testing.allocator;
    var store = try calls.Store.init((capture.Config{}).store());
    defer store.deinit(a);
    store.finish(.capture_end);
    var evidence = fixture(&store);
    const recipe = "{\"executable\":\"/never/open/or/run\",\"cohort\":{\"threshold_ns\":18446744073709551615}}";
    evidence.metadata.recipe_json = recipe;
    evidence.metadata.comparison_selection = .{ .threshold_ns = std.math.maxInt(u64), .argument = .{ .index = 5, .value = std.math.maxInt(u64) }, .return_value = 0x8000000000000000 };
    const bytes = try encode(a, evidence, null);
    defer a.free(bytes);
    const opened = try decode(a, bytes, null);
    defer opened.deinit();
    try std.testing.expectEqualStrings(recipe, opened.evidence().metadata.recipe_json.?);
    try std.testing.expect(std.meta.eql(evidence.metadata.comparison_selection, opened.evidence().metadata.comparison_selection));
    for ([_][]const u8{ "", "[]", "null", "{", "{}{}", "{\"value\":NaN}" }) |invalid| {
        evidence.metadata.recipe_json = invalid;
        try std.testing.expectError(error.InvalidObservationRecipe, encode(a, evidence, null));
    }
    evidence.metadata.recipe_json = "{}";
    evidence.metadata.comparison_selection.?.memory_limit = 0;
    try std.testing.expectError(error.InvalidObservationSelection, encode(a, evidence, null));
    evidence.metadata.comparison_selection = .{ .threshold_ns = 1, .argument = .{ .index = 6, .value = 0 } };
    try std.testing.expectError(error.InvalidObservationSelection, encode(a, evidence, null));
    evidence.metadata.comparison_selection = null;
    var deep: [132]u8 = undefined;
    @memcpy(deep[0..5], "{\"x\":");
    @memset(deep[5..68], '[');
    @memset(deep[68..131], ']');
    deep[131] = '}';
    evidence.metadata.recipe_json = &deep; // Root object plus 63 arrays is accepted.
    const nested = try encode(a, evidence, null);
    defer a.free(nested);
    var too_deep: [134]u8 = undefined;
    @memcpy(too_deep[0..5], "{\"x\":");
    @memset(too_deep[5..69], '[');
    @memset(too_deep[69..133], ']');
    too_deep[133] = '}';
    evidence.metadata.recipe_json = &too_deep;
    try std.testing.expectError(error.InvalidObservationRecipe, encode(a, evidence, null));
    const oversized = try a.alloc(u8, max_recipe_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    oversized[0] = '{';
    oversized[oversized.len - 1] = '}';
    evidence.metadata.recipe_json = oversized;
    try std.testing.expectError(error.InvalidObservationRecipe, encode(a, evidence, null));
    evidence.metadata.recipe_json = oversized[0..max_recipe_bytes];
    oversized[max_recipe_bytes - 1] = '}';
    const largest = try encode(a, evidence, null);
    defer a.free(largest);
    const reopened = try decode(a, largest, null);
    defer reopened.deinit();
    try std.testing.expectEqual(max_recipe_bytes, reopened.evidence().metadata.recipe_json.?.len);
}

test "observation archive rejects negative process identity and kernel addresses while preserving unsigned identity bits" {
    const a = std.testing.allocator;
    var store = try calls.Store.init((capture.Config{}).store());
    defer store.deinit(a);
    store.finish(.capture_end);
    var evidence = fixture(&store);
    evidence.metadata.identity.pid = -1;
    try std.testing.expectError(error.InvalidObservationArchive, encode(a, evidence, null));
    evidence = fixture(&store);
    evidence.metadata.threads = &.{.{ .id = 1, .tid = -1 }};
    try std.testing.expectError(error.InvalidObservationArchive, encode(a, evidence, null));
    evidence = fixture(&store);
    var functions = [_]capture.Function{evidence.metadata.functions[0]};
    evidence.metadata.functions = &functions;
    functions[0].identity.size = -1;
    try std.testing.expectError(error.InvalidObservationArchive, encode(a, evidence, null));
    functions[0].identity.size = 4096;
    functions[0].runtime_address = 0x8000000000000000;
    try std.testing.expectError(error.InvalidObservationArchive, encode(a, evidence, null));
    functions[0].runtime_address = 0x400100;
    functions[0].identity.device = std.math.maxInt(u64);
    functions[0].identity.inode = std.math.maxInt(u64);
    evidence.metadata.identity.session_id = std.math.maxInt(u64);
    evidence.metadata.identity.image_epoch = std.math.maxInt(u64);
    const bytes = try encode(a, evidence, null);
    defer a.free(bytes);
    const opened = try decode(a, bytes, null);
    defer opened.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), opened.evidence().metadata.identity.session_id);
    try std.testing.expectEqual(std.math.maxInt(u64), opened.evidence().metadata.functions[0].identity.inode);
    var external = Budget{ .backing = a, .limit = 128 };
    try std.testing.expectError(error.OutOfMemory, decode(external.allocator(), bytes, null));
    try std.testing.expectEqual(@as(usize, 0), external.used);
    try std.testing.expectError(error.ArchiveMemoryLimit, decodeWithOptions(a, bytes, .{ .memory_bytes = bytes.len + 128 }));
    try std.testing.expectError(error.ArchiveMemoryLimit, decodeWithOptions(a, bytes, .{ .memory_bytes = 512 * 1024 * 1024 + 1 }));
}
