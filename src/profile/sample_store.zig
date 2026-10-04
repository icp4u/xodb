//! Compact retained CPU samples, adapted from Claude's T15 prototype.
//!
//! Each sample becomes a 56-byte core record in fixed-size chunks (stable
//! ordinals, no reallocation copies of sample data) plus a reference to an
//! interned callchain. Callchains are interned by exact content: every item's
//! marker flag, context and both values are kept, so recursion, markers and
//! zero/unknown distinctions survive, and `get` reconstructs the original
//! `records.Sample` exactly (frames beyond `frame_count` are the default, as
//! the decoder produces them).
//!
//! All memory is charged against `budget_bytes` before it is allocated:
//! chunks, the chain table, frame pools and the intern index, including the
//! moment during growth when old and new buffers coexist. A sample that does
//! not fit is refused (`error.SampleBudget` / `error.SampleLimit`), counted,
//! and leaves the retained samples unchanged. Nothing is ever evicted.
const std = @import("std");
const records = @import("records.zig");
const Allocator = std.mem.Allocator;
const Budget = @import("archive_budget.zig").Budget;

pub const core_chunk = 4096;
pub const pool_chunk = 16 * 1024;
/// Holds 16,384 worst-case samples (64 distinct frames each), so the default
/// never refuses before today's sample-count limit does.
pub const default_budget_bytes: usize = 32 * 1024 * 1024;

const has_ip = 1;
const ip_exact = 2;
const has_tid = 4;
const has_time = 8;
const has_period = 16;
const has_weight = 32;

pub const Core = struct {
    time_ns: u64,
    ip: u64,
    period: u64,
    weight: u64,
    pid: u32,
    tid: u32,
    /// Interned chain ID plus one; zero means no frames.
    chain: u32,
    user_state: u32,
    flags: u16,
    cpu_mode: records.CpuMode,
    callchain: records.Callchain,
    pub fn timePresent(self: Core) bool {
        return self.flags & has_time != 0;
    }
    pub fn tidPresent(self: Core) bool {
        return self.flags & has_tid != 0;
    }
};
// Item tag: bit 7 marker, bit 6 "wide" (the field not selected by the marker is nonzero,
// two values stored), low six bits the context code.
const marker_bit = 0x80;
const wide_bit = 0x40;
const Chain = struct { value_pool: u32, value_offset: u32, tag_pool: u32, tag_offset: u32, items: u16, next: u32 };
const no_chain = std.math.maxInt(u32);

pub const Store = struct {
    cores: std.ArrayList(*[core_chunk]Core) = .empty,
    count: usize = 0,
    chains: std.ArrayList(Chain) = .empty,
    values: std.ArrayList(*[pool_chunk]u64) = .empty,
    tags: std.ArrayList(*[pool_chunk]u8) = .empty,
    value_used: usize = pool_chunk,
    tag_used: usize = pool_chunk,
    /// Content hash to the newest chain with that hash; `Chain.next` links collisions.
    index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    budget_bytes: usize = default_budget_bytes,
    max_samples: usize = std.math.maxInt(usize),
    used_bytes: usize = 0,
    peak_bytes: usize = 0,
    refused: u64 = 0,

    pub fn deinit(self: *Store, a: Allocator) void {
        for (self.cores.items) |chunk| a.destroy(chunk);
        for (self.values.items) |chunk| a.destroy(chunk);
        for (self.tags.items) |chunk| a.destroy(chunk);
        self.cores.deinit(a);
        self.values.deinit(a);
        self.tags.deinit(a);
        self.chains.deinit(a);
        self.index.deinit(a);
        self.* = .{ .budget_bytes = self.budget_bytes, .max_samples = self.max_samples };
    }
    /// Copy storage directly without re-hashing every callchain. All arrays and
    /// intern state are independent; raw sample ordinals and values are stable.
    pub fn clone(self: *const Store, backing: Allocator) !Store {
        var budget = Budget{ .backing = backing, .limit = self.budget_bytes };
        var out = self.cloneInner(budget.allocator()) catch |err| return if (budget.denied) error.SampleBudget else err;
        out.used_bytes = budget.used;
        out.peak_bytes = budget.peak;
        return out;
    }
    fn cloneInner(self: *const Store, a: Allocator) !Store {
        var out = Store{ .budget_bytes = self.budget_bytes, .max_samples = self.max_samples };
        errdefer out.deinit(a);
        try out.cores.ensureTotalCapacityPrecise(a, self.cores.items.len);
        for (self.cores.items) |chunk| {
            const copied = try a.create([core_chunk]Core);
            @memcpy(copied, chunk);
            out.cores.appendAssumeCapacity(copied);
        }
        try out.values.ensureTotalCapacityPrecise(a, self.values.items.len);
        for (self.values.items) |chunk| {
            const copied = try a.create([pool_chunk]u64);
            @memcpy(copied, chunk);
            out.values.appendAssumeCapacity(copied);
        }
        try out.tags.ensureTotalCapacityPrecise(a, self.tags.items.len);
        for (self.tags.items) |chunk| {
            const copied = try a.create([pool_chunk]u8);
            @memcpy(copied, chunk);
            out.tags.appendAssumeCapacity(copied);
        }
        try out.chains.ensureTotalCapacityPrecise(a, self.chains.items.len);
        out.chains.appendSliceAssumeCapacity(self.chains.items);
        out.index = try self.index.clone(a);
        out.count = self.count;
        out.value_used = self.value_used;
        out.tag_used = self.tag_used;
        out.refused = self.refused;
        return out;
    }
    pub fn len(self: *const Store) usize {
        return self.count;
    }
    pub fn core(self: *const Store, ordinal: usize) *const Core {
        return &self.cores.items[ordinal / core_chunk][ordinal % core_chunk];
    }
    pub fn coreMut(self: *Store, ordinal: usize) *Core {
        return &self.cores.items[ordinal / core_chunk][ordinal % core_chunk];
    }
    pub fn chainCount(self: *const Store) usize {
        return self.chains.items.len;
    }
    fn reserve(_: *Store, a: Allocator, comptime T: type, list: *std.ArrayList(T), extra: usize) !void {
        if (list.items.len + extra <= list.capacity) return;
        try list.ensureTotalCapacityPrecise(a, @max(8, list.capacity * 2, list.items.len + extra));
    }

    /// The budget allocator observes actual allocation requests, including hash
    /// metadata/alignment and simultaneous old/new buffers during growth. It is
    /// scoped to this call: no allocator pointer escapes into the stored data.
    pub fn append(self: *Store, backing: Allocator, sample: records.Sample) !void {
        var budget = Budget{ .backing = backing, .limit = self.budget_bytes, .used = self.used_bytes, .peak = self.peak_bytes };
        defer {
            self.used_bytes = budget.used;
            self.peak_bytes = budget.peak;
        }
        self.appendInner(budget.allocator(), sample) catch |err| {
            const failure = if (err == error.OutOfMemory and budget.denied) error.SampleBudget else err;
            return self.refuse(failure);
        };
    }
    fn appendInner(self: *Store, a: Allocator, sample: records.Sample) !void {
        if (self.count >= self.max_samples) return error.SampleLimit;
        if (sample.frame_count > records.max_frames) return error.InvalidSample;
        if (self.count == self.cores.items.len * core_chunk) {
            try self.reserve(a, *[core_chunk]Core, &self.cores, 1);
            const chunk = try a.create([core_chunk]Core);
            self.cores.appendAssumeCapacity(chunk);
        }
        const chain: u32 = if (sample.frame_count == 0) 0 else (try self.intern(a, sample.frames[0..sample.frame_count])) + 1;
        const flags: u16 = @as(u16, @intFromBool(sample.ip_present)) * has_ip | @as(u16, @intFromBool(sample.ip_exact)) * ip_exact | @as(u16, @intFromBool(sample.tid_present)) * has_tid | @as(u16, @intFromBool(sample.time_present)) * has_time | @as(u16, @intFromBool(sample.period_present)) * has_period | @as(u16, @intFromBool(sample.weight_present)) * has_weight;
        self.cores.items[self.count / core_chunk][self.count % core_chunk] = .{ .time_ns = sample.time_ns, .ip = sample.ip, .period = sample.period, .weight = sample.weight, .pid = sample.pid, .tid = sample.tid, .chain = chain, .user_state = sample.user_state, .flags = flags, .cpu_mode = sample.cpu_mode, .callchain = sample.callchain };
        self.count += 1;
    }
    fn refuse(self: *Store, err: anyerror) anyerror {
        if (err == error.SampleBudget or err == error.SampleLimit) self.refused += 1;
        return err;
    }
    fn tagOf(item: records.ChainItem) u8 {
        const wide = if (item.marker) item.address != 0 else item.raw_marker != 0;
        return (if (item.marker) @as(u8, marker_bit) else 0) | (if (wide) @as(u8, wide_bit) else 0) | @as(u8, @intFromEnum(item.context));
    }
    fn hashItems(items: []const records.ChainItem) u64 {
        var h = std.hash.Wyhash.init(0x7815);
        for (items) |item| {
            h.update(&.{tagOf(item)});
            h.update(std.mem.asBytes(&item.address));
            h.update(std.mem.asBytes(&item.raw_marker));
        }
        return h.final();
    }
    fn same(self: *const Store, chain: Chain, items: []const records.ChainItem) bool {
        if (chain.items != items.len) return false;
        var buffer: [records.max_frames]records.ChainItem = undefined;
        const decoded = self.decodeChain(chain, &buffer);
        for (decoded, items) |x, y| if (x.marker != y.marker or x.context != y.context or x.address != y.address or x.raw_marker != y.raw_marker) return false;
        return true;
    }
    fn intern(self: *Store, a: Allocator, items: []const records.ChainItem) !u32 {
        const hash = hashItems(items);
        const head = self.index.get(hash);
        var probe = head orelse no_chain;
        while (probe != no_chain) : (probe = self.chains.items[probe].next) {
            if (self.same(self.chains.items[probe], items)) return probe;
        }
        // Reserve every allocation before publishing a new chain or sample.
        try self.index.ensureUnusedCapacity(a, 1);
        try self.reserve(a, Chain, &self.chains, 1);
        var values_needed: usize = 0;
        for (items) |item| values_needed += @as(usize, 1) + @intFromBool(tagOf(item) & wide_bit != 0);
        if (pool_chunk - self.value_used < values_needed) try self.newChunk(a, u64, &self.values, &self.value_used);
        if (pool_chunk - self.tag_used < items.len) try self.newChunk(a, u8, &self.tags, &self.tag_used);
        const chain = Chain{ .value_pool = @intCast(self.values.items.len - 1), .value_offset = @intCast(self.value_used), .tag_pool = @intCast(self.tags.items.len - 1), .tag_offset = @intCast(self.tag_used), .items = @intCast(items.len), .next = head orelse no_chain };
        const value_chunk = self.values.items[chain.value_pool];
        const tag_chunk = self.tags.items[chain.tag_pool];
        var v = self.value_used;
        for (items, 0..) |item, i| {
            const tag = tagOf(item);
            tag_chunk[self.tag_used + i] = tag;
            if (tag & wide_bit != 0) {
                value_chunk[v] = item.address;
                value_chunk[v + 1] = item.raw_marker;
                v += 2;
            } else {
                value_chunk[v] = if (item.marker) item.raw_marker else item.address;
                v += 1;
            }
        }
        self.value_used = v;
        self.tag_used += items.len;
        const id: u32 = @intCast(self.chains.items.len);
        self.chains.appendAssumeCapacity(chain);
        self.index.putAssumeCapacity(hash, id);
        return id;
    }
    fn newChunk(self: *Store, a: Allocator, comptime T: type, list: *std.ArrayList(*[pool_chunk]T), used: *usize) !void {
        try self.reserve(a, *[pool_chunk]T, list, 1);
        const chunk = try a.create([pool_chunk]T);
        list.appendAssumeCapacity(chunk);
        used.* = 0;
    }
    fn decodeChain(self: *const Store, chain: Chain, out: *[records.max_frames]records.ChainItem) []records.ChainItem {
        const value_chunk = self.values.items[chain.value_pool];
        const tag_chunk = self.tags.items[chain.tag_pool];
        var v: usize = chain.value_offset;
        for (out[0..chain.items], 0..) |*item, i| {
            const tag = tag_chunk[chain.tag_offset + i];
            item.* = .{ .marker = tag & marker_bit != 0, .context = @enumFromInt(tag & 0x3f) };
            if (tag & wide_bit != 0) {
                item.address = value_chunk[v];
                item.raw_marker = value_chunk[v + 1];
                v += 2;
            } else {
                if (item.marker) item.raw_marker = value_chunk[v] else item.address = value_chunk[v];
                v += 1;
            }
        }
        return out[0..chain.items];
    }
    /// The original sample, reconstructed.
    pub fn get(self: *const Store, ordinal: usize) records.Sample {
        const c = self.core(ordinal);
        var sample = records.Sample{ .ip = c.ip, .ip_present = c.flags & has_ip != 0, .ip_exact = c.flags & ip_exact != 0, .pid = c.pid, .tid = c.tid, .tid_present = c.flags & has_tid != 0, .time_ns = c.time_ns, .time_present = c.flags & has_time != 0, .period = c.period, .period_present = c.flags & has_period != 0, .weight = c.weight, .weight_present = c.flags & has_weight != 0, .cpu_mode = c.cpu_mode, .callchain = c.callchain, .user_state = c.user_state };
        if (c.chain != 0) sample.frame_count = @intCast(self.decodeChain(self.chains.items[c.chain - 1], &sample.frames).len);
        return sample;
    }
    /// Exchange two retained samples (fixtures model out-of-order delivery).
    pub fn swap(self: *Store, i: usize, j: usize) void {
        const x = self.cores.items[i / core_chunk];
        const y = self.cores.items[j / core_chunk];
        std.mem.swap(Core, &x[i % core_chunk], &y[j % core_chunk]);
    }
};

// ------------------------------------------------------------ tests

const testing = std.testing;
pub fn sameSample(x: records.Sample, y: records.Sample) bool {
    return std.meta.eql(x, y);
}
fn chainSample(time: u64, tid: u32, ip: u64, callers: []const u64) records.Sample {
    var sample = records.Sample{ .ip = ip, .ip_present = true, .pid = 7, .tid = tid, .tid_present = true, .time_ns = time, .time_present = true, .cpu_mode = .user, .callchain = .complete };
    sample.frames[0] = .{ .marker = true, .context = .user, .raw_marker = records.context_user };
    sample.frames[1] = .{ .context = .user, .address = ip };
    for (callers, 2..) |caller, i| sample.frames[i] = .{ .context = .user, .address = caller };
    sample.frame_count = @intCast(2 + callers.len);
    return sample;
}

test "exact reconstruction: absence, zero values, markers, recursion and wide items" {
    const a = testing.allocator;
    var store = Store{};
    defer store.deinit(a);
    var cases: [7]records.Sample = undefined;
    cases[0] = .{};
    cases[1] = .{ .ip = 0, .ip_present = true, .tid = 0, .tid_present = true, .time_ns = 0, .time_present = true, .period = 0, .period_present = true, .weight = 0, .weight_present = true };
    cases[2] = .{ .ip = 5, .tid = 9, .time_ns = 11, .period = 13, .weight = 17, .cpu_mode = .kernel, .callchain = .truncated, .user_state = 3 }; // values without presence
    cases[3] = chainSample(100, 1, 0x1000, &.{ 0x2001, 0x2001, 0x2001, 0x3001 }); // recursion
    cases[4] = chainSample(100, 1, 0x1000, &.{ 0x2001, 0x2001, 0x2001, 0x3001 }); // equal time, same chain
    cases[5] = chainSample(101, 2, 0x1000, &.{ 0x2001, 0x2001, 0x3001 }); // one level shorter: distinct
    cases[6] = chainSample(102, 2, 0x1000, &.{});
    cases[6].frames[2] = .{ .marker = true, .context = .kernel, .address = 0xdead, .raw_marker = records.context_kernel }; // wide
    cases[6].frames[3] = .{ .context = .unknown, .address = 0 };
    cases[6].frame_count = 4;
    for (cases) |sample| try store.append(a, sample);
    for (cases, 0..) |sample, i| try testing.expect(sameSample(sample, store.get(i)));
    // Identical chains share storage; recursion depth stays distinct.
    try testing.expectEqual(@as(usize, 3), store.chainCount());
}

test "refusal at the byte and count budgets leaves retained samples unchanged" {
    const a = testing.allocator;
    var store = Store{ .budget_bytes = 1024 * 1024 };
    defer store.deinit(a);
    var prng = std.Random.DefaultPrng.init(1);
    var accepted: usize = 0;
    var refused = false;
    var first: records.Sample = undefined;
    for (0..20000) |i| {
        var callers: [62]u64 = undefined;
        for (&callers) |*c| c.* = prng.random().int(u64) | 1;
        const sample = chainSample(i, 1, 0x1000 + i, &callers);
        if (i == 0) first = sample;
        store.append(a, sample) catch |err| {
            try testing.expectEqual(error.SampleBudget, err);
            refused = true;
            break;
        };
        accepted += 1;
    }
    try testing.expect(refused and accepted > 0);
    try testing.expectEqual(accepted, store.len());
    try testing.expect(store.used_bytes <= store.budget_bytes and store.peak_bytes <= store.budget_bytes);
    try testing.expect(sameSample(first, store.get(0)));
    // A repeated chain still fits after a unique one was refused: no eviction,
    // no partial state.
    try testing.expectEqual(@as(u64, 1), store.refused);
    var limited = Store{ .max_samples = 2 };
    defer limited.deinit(a);
    try limited.append(a, .{});
    try limited.append(a, .{});
    try testing.expectError(error.SampleLimit, limited.append(a, .{}));
    try testing.expectEqual(@as(usize, 2), limited.len());
}

test "allocation failure at every point leaves a consistent store" {
    const a = testing.allocator;
    var fail_index: usize = 0;
    while (fail_index < 40) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        var store = Store{};
        defer store.deinit(fa);
        var appended: usize = 0;
        for (0..300) |i| {
            store.append(fa, chainSample(i, 1, 0x1000 + i % 37, &.{ 0x2000 + i % 11, 0x3000 })) catch break;
            appended += 1;
        }
        try testing.expectEqual(appended, store.len());
        for (0..appended) |i| try testing.expectEqual(@as(u64, i), store.get(i).time_ns);
        // Accounting matches the real allocations still held.
        try testing.expect(store.used_bytes <= store.budget_bytes);
    }
}

test "both chain fields survive when the selected value is zero" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    var sample = records.Sample{ .frame_count = 4 };
    sample.frames[0] = .{ .marker = true, .address = 123, .raw_marker = 0 };
    sample.frames[1] = .{ .marker = false, .address = 0, .raw_marker = 456 };
    sample.frames[2] = .{ .marker = false, .address = 789, .raw_marker = 456 };
    sample.frames[3] = .{ .marker = true, .address = 789, .raw_marker = 456 };
    try store.append(testing.allocator, sample);
    try store.append(testing.allocator, sample);
    try testing.expectEqualDeep(sample, store.get(0));
    try testing.expectEqualDeep(sample, store.get(1));
    try testing.expectEqual(@as(usize, 1), store.chainCount());
}

test "exact allocation accounting and default budget hold maximum unique wide chains" {
    var measured = Budget{ .backing = testing.allocator, .limit = default_budget_bytes };
    const a = measured.allocator();
    var store = Store{ .max_samples = 16384 };
    defer store.deinit(a);
    var sample = records.Sample{ .frame_count = records.max_frames };
    var first: records.Sample = undefined;
    for (0..store.max_samples) |i| {
        sample.time_ns = i;
        sample.user_state = @intCast(i + 1);
        for (&sample.frames, 0..) |*frame, j| frame.* = .{
            .marker = j % 2 == 0,
            .context = .unknown,
            .address = 1 + i * records.max_frames + j,
            .raw_marker = 1 + j,
        };
        if (i == 0) first = sample;
        try store.append(a, sample);
        try testing.expectEqual(measured.used, store.used_bytes);
        try testing.expectEqual(measured.peak, store.peak_bytes);
    }
    try testing.expectEqualDeep(first, store.get(0));
    try testing.expectEqualDeep(sample, store.get(store.len() - 1));
    try testing.expectError(error.SampleLimit, store.append(a, sample));
    try testing.expectEqual(@as(u64, 1), store.refused);
    @import("../m68k_log.zig").print("compact wide-chain budget: samples={d} used={d} peak={d} limit={d}\n", .{ store.len(), store.used_bytes, store.peak_bytes, store.budget_bytes });
}

fn allocationFailure(a: Allocator) !void {
    var measured = Budget{ .backing = a, .limit = default_budget_bytes };
    var store = Store{};
    defer {
        std.debug.assert(measured.used == store.used_bytes);
        store.deinit(measured.allocator());
        std.debug.assert(measured.used == 0);
    }
    // Cross the core-chunk boundary as well as chain/index/pool growth.
    for (0..core_chunk + 1) |i| try store.append(measured.allocator(), chainSample(i, 1, 1 + i, &.{ 7, 7, 9 }));
}

test "every allocation failure through chunk growth cleans up exactly" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailure, .{});
}

fn cloneFailure(a: Allocator, source: *const Store) !void {
    var measured = Budget{ .backing = a, .limit = default_budget_bytes };
    defer std.debug.assert(measured.used == 0);
    var copy = try source.clone(measured.allocator());
    defer copy.deinit(measured.allocator());
    try testing.expectEqual(measured.used, copy.used_bytes);
    try testing.expectEqual(source.len(), copy.len());
    for (0..source.len()) |i| try testing.expectEqualDeep(source.get(i), copy.get(i));
    const retained = copy.get(0);
    try copy.append(measured.allocator(), retained);
    try testing.expectEqual(measured.used, copy.used_bytes);
    copy.coreMut(0).ip = 0;
    try testing.expectEqualDeep(retained, source.get(0));
}

test "compact snapshot clone owns every chunk and cleans up allocation failures" {
    var source = Store{};
    defer source.deinit(testing.allocator);
    for (0..core_chunk + 1) |i| try source.append(testing.allocator, chainSample(i, 1, i + 1, &.{ 7, 7, i + 9 }));
    try testing.checkAllAllocationFailures(testing.allocator, cloneFailure, .{&source});
}
