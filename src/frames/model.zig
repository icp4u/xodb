//! Immutable C evidence owners. Public row copies belong to the requesting host
//! allocator; no borrowed C accessor strings escape through those rows.
const std = @import("std");
pub const c = @import("c.zig").api;
const Budget = @import("../profile/archive_budget.zig").Budget;
pub const memory_limit = 256 * 1024 * 1024;
pub const algorithm = "xlf-aggregate-v1";
pub const max_sources = c.XFB_MAX_SOURCES;
pub const max_input = c.XFB_MAX_INPUT;
pub const Kind = enum(u32) { logical = 1, jfr, thread_dump, thread_print, coroutines, jitdump, perfmap };
pub const Metadata = struct {
    algorithm: []const u8 = algorithm,
    selected_thread: ?u32 = null,
    jvm_kind: ?u32 = null,
    jit: ?@import("jit.zig").Declaration = null,
};
pub fn check(status: c.enum_xlf_status) !void {
    switch (status) {
        c.XLF_OK => {},
        c.XLF_E_MEMORY => return error.FrameMemoryLimit,
        c.XLF_E_LIMIT => return error.FrameInputLimit,
        c.XLF_E_CANCELLED => return error.FrameCancelled,
        c.XLF_E_IO => return error.FrameReadFailed,
        c.XLF_E_UTF8 => return error.FrameInvalidUtf8,
        c.XLF_E_CLOCK => return error.FrameInvalidClock,
        c.XLF_E_IDENTITY => return error.FrameInvalidIdentity,
        c.XLF_E_VERSION => return error.FrameVersionUnsupported,
        c.XLF_E_EMPTY => return error.FrameEmpty,
        else => return error.FrameSchemaInvalid,
    }
}
pub fn bundleCheck(status: c.enum_xfb_status) !void {
    switch (status) {
        c.XFB_OK => {},
        c.XFB_MEMORY => return error.FrameMemoryLimit,
        c.XFB_LIMIT => return error.FrameInputLimit,
        c.XFB_CANCELLED => return error.FrameCancelled,
        c.XFB_IO => return error.FrameReadFailed,
        c.XFB_CHECKSUM => return error.FrameChecksum,
        c.XFB_VERSION => return error.FrameVersionUnsupported,
        else => return error.FrameBundleInvalid,
    }
}
pub fn poll(cancel: ?*c.struct_xlf_cancel) !void {
    if (cancel) |token| if (c.xlf_cancel_requested(token)) return error.FrameCancelled;
}
pub fn decimal(a: std.mem.Allocator, count: c.struct_xlf_count) ![]const u8 {
    var buf: [40]u8 = undefined;
    const n = c.xlf_count_format(count, &buf);
    return a.dupe(u8, buf[0..n]);
}
/// All these component structs contain values and optional strings only.
/// The generic conversion intentionally rejects other pointer types.
pub fn Owned(comptime T: type) type {
    @setEvalBranchQuota(20000);
    if (T == c.struct_xlf_str) return ?[]const u8;
    if (T == c.struct_xlf_count) return []const u8;
    if (T == c.struct_xlf_opt_u64) return ?u64;
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.child == u8) ?[]const u8 else @compileError("unowned C pointer"),
        .@"struct" => |s| blk: {
            var types: [s.fields.len]type = undefined;
            for (s.fields, 0..) |f, i| types[i] = Owned(f.type);
            break :blk @Struct(.auto, null, std.meta.fieldNames(T), &types, &@splat(.{}));
        },
        else => T,
    };
}
pub fn own(a: std.mem.Allocator, value: anytype) !Owned(@TypeOf(value)) {
    return ownBounded(a, value, std.math.maxInt(usize));
}
/// UI previews copy bounded strings; full rows and original citations remain
/// available to the MCP accessors. Never cut a UTF-8 continuation byte.
pub fn preview(bytes: []const u8, limit: usize) []const u8 {
    var n = @min(bytes.len, limit);
    while (n > 0 and n < bytes.len and bytes[n] & 0xc0 == 0x80) n -= 1;
    return bytes[0..n];
}
pub fn ownBounded(a: std.mem.Allocator, value: anytype, max_string: usize) !Owned(@TypeOf(value)) {
    const T = @TypeOf(value);
    if (T == c.struct_xlf_str) return if (value.ptr == null) null else try a.dupe(u8, preview(value.ptr[0..value.len], max_string));
    if (T == c.struct_xlf_count) return decimal(a, value);
    if (T == c.struct_xlf_opt_u64) return if (value.known) value.value else null;
    switch (@typeInfo(T)) {
        .pointer => return if (value == null) null else try a.dupe(u8, preview(std.mem.span(value), max_string)),
        .@"struct" => |s| {
            var out: Owned(T) = undefined;
            inline for (s.fields) |f| @field(out, f.name) = try ownBounded(a, @field(value, f.name), max_string);
            return out;
        },
        else => return value,
    }
}
pub const Aggregate = struct {
    thread: ?u32,
    total: []const u8,
    partial: []const u8,
    marker: []const u8,
    unknown_leaf: []const u8,
    stacks: u64,
    partial_stacks: u64,
    input_incomplete: bool,
    self: [][]const u8,
    inclusive: [][]const u8,
    order: []u32,
    peak: usize,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *Aggregate) void {
        self.arena.deinit();
    }
};
pub const Source = struct {
    input: c.struct_xfb_input = std.mem.zeroes(c.struct_xfb_input),
    kind: Kind,
    metadata: Metadata = .{},
    saved_metadata: ?[]const u8 = null,
    metadata_changed: bool = false,
    id: [64]u8 = undefined,
    budget: Budget,
    arena: std.heap.ArenaAllocator = undefined,
    // These are OWNED immutable component objects, never borrowed accessors.
    jit_owner: ?*c.struct_xodb_jit_model = null,
    doc_owner: ?*c.struct_xlf_doc = null,
    jvm_owner: ?*c.struct_jvm_evidence = null,
    external: usize = @sizeOf(Source),
    peak: usize = 0,
    aggregate: ?Aggregate = null,
    aggregate_stale: bool = false,
    selection_stale: bool = false,
    diagnostic: c.struct_xlf_error = std.mem.zeroes(c.struct_xlf_error),
    pub fn doc(self: *const Source) *const c.struct_xlf_doc {
        return if (self.jvm_owner) |j| c.jvm_evidence_doc(j) else self.doc_owner.?;
    }
    pub fn retained(self: *const Source) usize {
        return self.external + self.budget.used;
    }
    pub fn remaining(self: *const Source) usize {
        return self.budget.limit - self.budget.used;
    }
    fn charge(self: *Source, n: usize) !void {
        if (n > self.remaining()) return error.FrameMemoryLimit;
        self.external += n;
        self.budget.limit -= n;
        self.peak = @max(self.peak, self.retained());
    }
    pub fn create(kind: Kind, available: usize) !*Source {
        if (available < @sizeOf(Source)) return error.FrameMemoryLimit;
        const self = std.heap.page_allocator.create(Source) catch return error.FrameMemoryLimit;
        self.* = .{ .kind = kind, .budget = .{ .backing = std.heap.page_allocator, .limit = available - @sizeOf(Source) } };
        self.arena = .init(self.budget.allocator());
        return self;
    }
    pub fn read(self: *Source, path: [:0]const u8, input_limit: usize, cancel: *c.struct_xlf_cancel) !void {
        try bundleCheck(c.xfb_read(path, @min(input_limit, self.remaining()), cancel, &self.input));
        try self.charge(@max(1, self.input.size));
    }
    pub fn restore(self: *Source, source: c.struct_xfb_source, cancel: *c.struct_xlf_cancel) !void {
        try poll(cancel);
        const meta = std.json.parseFromSlice(Metadata, self.arena.allocator(), source.metadata[0..source.metadata_size], .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| return if (err == error.OutOfMemory) error.FrameMemoryLimit else error.FrameBundleInvalid;
        self.metadata = meta.value;
        self.saved_metadata = try self.arena.allocator().dupe(u8, source.metadata[0..source.metadata_size]);
        // The arena owns the parsed strings; deinit with Source.
        try self.charge(@max(1, source.size));
        self.input.bytes = @ptrCast(c.malloc(@max(1, source.size)) orelse return error.FrameMemoryLimit);
        self.input.size = source.size;
        self.input.stability = source.stability;
        self.input.sha256 = source.sha256;
        var at: usize = 0;
        while (at < source.size) {
            try poll(cancel);
            const end = @min(source.size, at + 65536);
            @memcpy(self.input.bytes[at..end], source.bytes[at..end]);
            at = end;
        }
    }
    pub fn decode(self: *Source, cancel: *c.struct_xlf_cancel, jit_cancel: *c.struct_xodb_jit_cancel) !void {
        if (self.remaining() == 0) return error.FrameMemoryLimit;
        var err: c.struct_xlf_error = std.mem.zeroes(c.struct_xlf_error);
        errdefer if (err.status != c.XLF_OK) {
            self.diagnostic = err;
        };
        if ((self.metadata.jit != null) != (self.kind == .jitdump or self.kind == .perfmap)) return error.JitMetadataInvalid;
        if (self.kind == .logical) {
            if (self.metadata.jvm_kind != null) return error.FrameSelectionInvalid;
            var limits: c.struct_xlf_limits = undefined;
            c.xlf_default_limits(&limits);
            limits.max_input_bytes = max_input;
            limits.max_memory = self.remaining();
            self.doc_owner = c.xlf_decode(self.input.bytes, self.input.size, &limits, cancel, &err);
            if (self.doc_owner == null) {
                try check(err.status);
                return error.FrameSchemaInvalid;
            }
            self.peak = @max(self.peak, self.retained() + self.doc_owner.?.decode_peak_bytes);
            try self.charge(self.doc_owner.?.retained_bytes);
        } else if (@intFromEnum(self.kind) <= @intFromEnum(Kind.coroutines)) {
            var limits: c.struct_jvm_evidence_limits = undefined;
            c.jvm_evidence_default_limits(&limits);
            limits.max_total_bytes = self.remaining();
            limits.import.max_bytes = max_input;
            var selection: c.struct_jvm_query = std.mem.zeroes(c.struct_jvm_query);
            if (self.metadata.jvm_kind) |kind| {
                if (kind >= c.JVM_KIND_COUNT) return error.FrameSelectionInvalid;
                selection.has_kind = 1;
                selection.kind = kind;
            }
            try check(c.jvm_evidence_import_bytes(self.input.bytes, self.input.size, "retained source", @intFromEnum(self.kind) - 2, &selection, &limits, cancel, &self.jvm_owner, &err));
            var usage: c.struct_jvm_evidence_usage = undefined;
            c.jvm_evidence_usage(self.jvm_owner, &usage);
            self.peak = @max(self.peak, self.retained() + usage.whole_peak);
            try self.charge(usage.retained_bytes);
        } else {
            const declaration = self.metadata.jit orelse return error.JitMetadataRequired;
            var limits: c.struct_xodb_jit_limits = undefined;
            c.xodb_jit_limits_default(&limits);
            const owner = self.arena.allocator().create(c.struct_xodb_jit_model) catch return error.FrameMemoryLimit;
            if (self.remaining() <= @import("jit.zig").scratch_bytes) return error.FrameMemoryLimit;
            limits.max_input_bytes = max_input;
            limits.max_memory_bytes = self.remaining() - @import("jit.zig").scratch_bytes;
            c.xodb_jit_model_init(owner, &limits);
            self.jit_owner = owner;
            try @import("jit.zig").add(owner, declaration, &self.input.sha256, self.raw(), self.kind == .perfmap, jit_cancel);
            self.peak = @max(self.peak, self.retained() + owner.memory_peak + @import("jit.zig").scratch_bytes);
            try self.charge(owner.memory);
        }
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(self.input.sha256[0..64]);
        var key: [8]u8 = undefined;
        std.mem.writeInt(u32, key[0..4], @intFromEnum(self.kind), .little);
        std.mem.writeInt(u32, key[4..8], self.metadata.jvm_kind orelse c.XLF_NONE, .little);
        hash.update(&key);
        if (self.metadata.jit) |meta| {
            const bytes = std.json.Stringify.valueAlloc(self.arena.allocator(), meta, .{}) catch return error.FrameMemoryLimit;
            hash.update(bytes);
        }
        self.id = std.fmt.bytesToHex(hash.finalResult(), .lower);
        self.aggregate_stale = !std.mem.eql(u8, self.metadata.algorithm, if (self.jit_owner != null) "xodb-jit-code-lifetime/3" else algorithm);
        if (self.jit_owner == null) {
            self.selection_stale = if (self.metadata.selected_thread) |index| index >= self.doc().thread_count else false;
            self.aggregate_stale = self.aggregate_stale or self.selection_stale;
            if (!self.aggregate_stale) self.aggregate = try self.query(self.metadata.selected_thread, cancel);
        }
    }
    pub fn encodeMetadata(self: *const Source, allocator: std.mem.Allocator) ![]const u8 {
        if (self.saved_metadata) |bytes| {
            if (!self.metadata_changed) return bytes;
            // Preserve unknown optional fields when updating our derived view.
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
            defer parsed.deinit();
            var value = parsed.value;
            if (value != .object) return error.FrameBundleInvalid;
            try value.object.put(allocator, "algorithm", .{ .string = self.metadata.algorithm });
            try value.object.put(allocator, "selected_thread", if (self.metadata.selected_thread) |thread| .{ .integer = thread } else .null);
            return std.json.Stringify.valueAlloc(allocator, value, .{});
        }
        return std.json.Stringify.valueAlloc(allocator, self.metadata, .{});
    }
    pub fn query(self: *Source, thread: ?u32, cancel: *c.struct_xlf_cancel) !Aggregate {
        const document = self.doc();
        if (thread) |index| if (index >= document.thread_count) return error.FrameThreadInvalid;
        if (self.remaining() == 0) return error.FrameMemoryLimit;
        var limits = c.struct_xlf_query_limits{ .max_query_bytes = self.remaining(), .max_combined_bytes = self.remaining() + document.retained_bytes };
        var result: c.struct_xlf_aggregate = std.mem.zeroes(c.struct_xlf_aggregate);
        var err: c.struct_xlf_error = std.mem.zeroes(c.struct_xlf_error);
        errdefer self.diagnostic = err;
        try check(c.xlf_aggregate(document, thread orelse c.XLF_NONE, &limits, cancel, &result, &err));
        defer c.xlf_aggregate_free(&result);
        self.peak = @max(self.peak, self.retained() + result.query_peak_bytes);
        try self.charge(result.result_bytes);
        defer {
            self.external -= result.result_bytes;
            self.budget.limit += result.result_bytes;
        }
        var arena = std.heap.ArenaAllocator.init(self.budget.allocator());
        errdefer arena.deinit();
        const a = arena.allocator();
        const own_self = a.alloc([]const u8, result.function_count) catch return error.FrameMemoryLimit;
        const own_inclusive = a.alloc([]const u8, result.function_count) catch return error.FrameMemoryLimit;
        for (0..result.function_count) |i| {
            try poll(cancel);
            own_self[i] = decimal(a, result.self[i]) catch return error.FrameMemoryLimit;
            own_inclusive[i] = decimal(a, result.inclusive[i]) catch return error.FrameMemoryLimit;
        }
        const order = a.alloc(u32, result.function_count) catch return error.FrameMemoryLimit;
        for (order, 0..) |*index, i| index.* = @intCast(i);
        std.mem.sort(u32, order, own_inclusive, struct {
            fn less(counts: [][]const u8, left: u32, right: u32) bool {
                const l = counts[left];
                const r = counts[right];
                if (l.len != r.len) return l.len > r.len;
                const cmp = std.mem.order(u8, l, r);
                return if (cmp == .eq) left < right else cmp == .gt;
            }
        }.less);
        var copied = Aggregate{ .thread = thread, .total = decimal(a, result.total_weight) catch return error.FrameMemoryLimit, .partial = decimal(a, result.partial_weight) catch return error.FrameMemoryLimit, .marker = decimal(a, result.marker_weight) catch return error.FrameMemoryLimit, .unknown_leaf = decimal(a, result.unknown_leaf_weight) catch return error.FrameMemoryLimit, .stacks = result.stacks, .partial_stacks = result.partial_stacks, .input_incomplete = result.input_incomplete, .self = own_self, .inclusive = own_inclusive, .order = order, .peak = self.peak, .arena = arena };
        self.peak = @max(self.peak, self.retained());
        copied.peak = self.peak;
        return copied;
    }
    pub fn raw(self: *const Source) []const u8 {
        return self.input.bytes[0..self.input.size];
    }
    pub fn deinit(self: *Source) void {
        if (self.aggregate) |*agg| agg.deinit();
        if (self.jit_owner) |j| c.xodb_jit_model_free(j);
        if (self.jvm_owner) |j| c.jvm_evidence_free(j);
        if (self.doc_owner) |d| c.xlf_free(d);
        c.xfb_input_free(&self.input);
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

fn budgetFixture(available: usize) !usize {
    const bytes =
        \\{"type":"header","format":"xodb.logical-frames","version":1,"draft":"C05-1","producer":{"name":"t","version":"1","kind":"cooperating_in_process","sha256":null},"source_kind":"cooperative_sample","runtime":{"language":"python","implementation":"cpython","version":"3","build":null,"executable":{"path":null,"sha256":null,"gnu_build_id":null,"unavailable":"test"},"library":null},"process":{"pid":null,"start_ticks":null,"boot_id":null,"unavailable":"test"},"clock":null,"clock_unavailable":"test","command":null,"collection":{"method":"m","trigger":"t","interval_ns":null,"atomicity":"single_thread"},"frame_order":"innermost_first","weight_unit":"observation","weight_semantics":"test"}
        \\{"type":"end","records":1,"acquisitions":0,"stacks":0,"status":"complete"}
        \\
    ;
    const source = try Source.create(.logical, available);
    defer source.deinit();
    const cancel = c.xlf_cancel_create() orelse return error.FrameMemoryLimit;
    defer c.xlf_cancel_destroy(cancel);
    var jit_cancel: c.struct_xodb_jit_cancel = .{ .requested = 0 };
    var record = std.mem.zeroes(c.struct_xfb_source);
    record.kind = c.XFB_LOGICAL;
    record.stability = c.XLF_STABILITY_LEASED;
    record.bytes = bytes.ptr;
    record.size = bytes.len;
    record.metadata = "{}";
    record.metadata_size = 2;
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sha, .{});
    @memcpy(record.sha256[0..64], &std.fmt.bytesToHex(sha, .lower));
    try source.restore(record, cancel);
    try source.decode(cancel, &jit_cancel);
    try std.testing.expect(source.retained() <= available);
    try std.testing.expect(source.peak <= available);
    try std.testing.expectEqualStrings("0", source.aggregate.?.total);
    return source.peak;
}
test "frame host accounts raw evidence, decoder scratch and copied aggregates together" {
    _ = try budgetFixture(1024 * 1024);
    // Find the exact admission threshold independently of the reported peak:
    // every smaller allowance must fail with a typed memory limit.
    var low: usize = 0;
    var high: usize = 1024 * 1024;
    while (high - low > 1) {
        const middle = low + (high - low) / 2;
        if (budgetFixture(middle)) |_| {
            high = middle;
        } else |err| {
            try std.testing.expectEqual(error.FrameMemoryLimit, err);
            low = middle;
        }
    }
    _ = try budgetFixture(high);
    try std.testing.expectError(error.FrameMemoryLimit, budgetFixture(high - 1));
}
