//! Immutable normalized association evidence; no collector or path access.
const std = @import("std");
const assoc = @import("associations.zig");
const comparison = @import("comparison.zig");
const calls = @import("calls.zig");
const Budget = @import("../profile/archive_budget.zig").Budget;
const Producer = @import("../profile/producer.zig").Producer;
pub const algorithm = "xodb-temporal-association-v1";
// Largest interval records fit the owner arena; analysis and file bytes have
// independent limits and may reject unusually large invocation sets.
pub const max_records = 262144;
pub const max_streams = 3;
pub const memory_limit = 64 * 1024 * 1024;
pub const Source = struct {
    stream_id: u64,
    kind: assoc.Kind,
    capture_id: u64,
    revision: u64,
    started_ns: u64,
    ended_ns: u64,
    stored_records: usize,
    included_records: usize = 0,
    excluded_metadata_records: usize = 0,
    incomplete_records: usize = 0,
    scope_untrusted_records: usize = 0,
    identity_trusted_before_ns: ?u64 = null,
    lost_records: u64 = 0,
    lost_samples: u64 = 0,
    throttles: u64 = 0,
    loss_basis: []const u8,
    discarded_records: u64 = 0,
    unread_possible: bool = false,
    producer: ?Producer,
    pub fn coverageIncomplete(self: Source) bool {
        return self.incomplete_records != 0 or self.scope_untrusted_records != 0 or self.lost_records != 0 or self.lost_samples != 0 or self.throttles != 0 or self.discarded_records != 0 or self.unread_possible;
    }
};

pub const Snapshot = struct {
    association_algorithm: []const u8,
    payload_version: u32 = 2,
    analysis_origin: enum { live, restored, reanalysed } = .live,
    origin: assoc.Origin,
    selection: comparison.Selection,
    sources: []const Source,
    streams: []const assoc.Stream,
    derived: assoc.Result,
    pub fn rowsTruncated(self: Snapshot) bool {
        return self.derived.omitted_rows != 0;
    }
    pub fn callsTruncated(self: Snapshot) bool {
        return self.derived.omitted_calls != 0;
    }
};
/// A borrowed view. All slices remain valid until this owner is destroyed.
pub const Owned = struct {
    budget: Budget,
    arena: std.heap.ArenaAllocator,
    snapshot: Snapshot,
    pub fn create(a: std.mem.Allocator, view: Snapshot) !*Owned {
        try limits(view);
        const self = try a.create(Owned);
        self.* = .{ .budget = .{ .backing = a, .limit = memory_limit }, .arena = undefined, .snapshot = undefined };
        self.arena = std.heap.ArenaAllocator.init(self.budget.allocator());
        errdefer self.deinit();
        self.snapshot = clone(Snapshot, self.arena.allocator(), view) catch |err| return budgetError(&self.budget, err);
        return self;
    }
    pub fn deinit(self: *Owned) void {
        const a = self.budget.backing;
        self.arena.deinit();
        a.destroy(self);
    }
};
pub fn budgetError(budget: *const Budget, err: anyerror) anyerror {
    return if (budget.denied) error.ObservationAssociationMemoryLimit else err;
}
/// Only value types and slices occur in this schema. Clone into a caller arena.
pub fn clone(comptime T: type, a: std.mem.Allocator, value: T) std.mem.Allocator.Error!T {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) @compileError("snapshot pointers must be slices");
            const out = try a.alloc(p.child, value.len);
            for (out, value) |*dst, src| dst.* = try clone(p.child, a, src);
            return out;
        },
        .@"struct" => |info| {
            var out: T = undefined;
            inline for (info.fields) |f| @field(out, f.name) = try clone(f.type, a, @field(value, f.name));
            return out;
        },
        .optional => |o| return if (value) |v| try clone(o.child, a, v) else null,
        .@"union" => |info| {
            inline for (info.fields) |f| if (std.meta.activeTag(value) == @field(info.tag_type.?, f.name)) return @unionInit(T, f.name, try clone(f.type, a, @field(value, f.name)));
            unreachable;
        },
        else => return value,
    }
}
pub fn equal(comptime T: type, left: T, right: T) bool {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (left.len != right.len) return false;
            for (left, right) |l, r| if (!equal(p.child, l, r)) return false;
            return true;
        },
        .@"struct" => |info| {
            inline for (info.fields) |f| if (!equal(f.type, @field(left, f.name), @field(right, f.name))) return false;
            return true;
        },
        .optional => |o| return if (left) |l| (if (right) |r| equal(o.child, l, r) else false) else right == null,
        .@"union" => |info| {
            if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
            inline for (info.fields) |f| if (std.meta.activeTag(left) == @field(info.tag_type.?, f.name)) return equal(f.type, @field(left, f.name), @field(right, f.name));
            unreachable;
        },
        else => return std.meta.eql(left, right),
    }
}
pub fn limits(view: Snapshot) !void {
    if (view.payload_version != 2 or view.association_algorithm.len == 0 or view.association_algorithm.len > 128 or !std.unicode.utf8ValidateSlice(view.association_algorithm) or std.mem.indexOfScalar(u8, view.association_algorithm, 0) != null) return error.InvalidSavedAssociations;
    try view.selection.validate();
    if (view.sources.len == 0 or view.sources.len > max_streams or view.sources.len != view.streams.len) return error.InvalidSavedAssociations;
    if (view.derived.streams.len != view.sources.len or view.derived.rows.len > 128 or view.derived.calls.len > 16) return error.InvalidSavedAssociations;
    for (view.derived.calls) |call| if (call.citations.len > 4) return error.InvalidSavedAssociations;
    var count: usize = 0;
    for (view.streams) |stream| {
        if (stream.points.len > max_records - count) return error.ObservationAssociationRecordLimit;
        count += stream.points.len;
        if (stream.intervals.len > max_records - count) return error.ObservationAssociationRecordLimit;
        count += stream.intervals.len;
    }
}
pub fn uncertainty(target: ?Producer, source: ?Producer) !u64 {
    if ((target == null) != (source == null)) return error.ObservationAssociationProducer;
    if (target) |left| {
        const right = source.?;
        if (!left.supported() or !right.supported() or left.machine != right.machine or left.address_bits != right.address_bits or left.little_endian != right.little_endian or !std.meta.eql(left.boot_id, right.boot_id)) return error.ObservationAssociationProducer;
        return std.math.add(u64, left.uncertainty_ns, right.uncertainty_ns) catch error.ObservationAssociationClockOverflow;
    }
    return 0;
}
/// Metadata is generic to avoid coupling immutable evidence to a live Capture.
pub fn validate(a: std.mem.Allocator, view: Snapshot, metadata: anytype, store: *const calls.Store, cancel: ?*const std.atomic.Value(bool)) !void {
    try limits(view);
    const id = metadata.identity;
    const expected = assoc.Origin{ .origin_id = id.capture_id, .session_id = id.session_id, .process_id = id.process_id, .image_epoch = id.image_epoch, .producer_id = id.session_id, .clock_id = 1 };
    if (!std.meta.eql(view.origin, expected)) return error.InvalidSavedAssociations;
    for (view.sources, view.streams, 0..) |source, stream, si| {
        if (cancel) |flag| if (flag.load(.acquire)) return error.ObservationAnalysisCancelled;
        for (view.streams[0..si]) |prior| if (prior.id == stream.id or (prior.origin.origin_id == stream.origin.origin_id and prior.kind == stream.kind)) return error.InvalidSavedAssociations;
        if (source.capture_id == 0 or source.revision == 0 or source.stream_id != stream.id or source.kind != stream.kind or source.ended_ns < source.started_ns or source.loss_basis.len > 512) return error.InvalidSavedAssociations;
        const expected_id: u64 = switch (source.kind) {
            .cpu => 1,
            .syscall => 2,
            .allocation => 3,
        };
        if (source.stream_id != expected_id) return error.InvalidSavedAssociations;
        var origin = expected;
        origin.origin_id = source.capture_id;
        if (!std.meta.eql(origin, stream.origin)) return error.InvalidSavedAssociations;
        const delta = try uncertainty(metadata.producer, source.producer);
        const proof: assoc.ClockProof = if (source.producer == null) .same_domain else .{ .correlated = .{ .proof_id = stream.id, .source_producer_id = origin.producer_id, .target_producer_id = expected.producer_id, .source_clock_id = 1, .target_clock_id = 1, .offset_ns = 0, .uncertainty_ns = delta, .valid_start_ns = source.started_ns, .valid_end_ns = source.ended_ns } };
        if (!std.meta.eql(proof, stream.clock)) return error.InvalidSavedAssociations;
        const count = stream.points.len + stream.intervals.len;
        if (source.included_records != count or source.excluded_metadata_records > source.stored_records or count != source.stored_records - source.excluded_metadata_records or source.incomplete_records > count or source.scope_untrusted_records > count) return error.InvalidSavedAssociations;
        if ((source.kind == .syscall and stream.points.len != 0) or (source.kind != .syscall and stream.intervals.len != 0)) return error.InvalidSavedAssociations;
        var prior: ?u64 = null;
        for (stream.points, 0..) |p, i| {
            if (i % 256 == 0) if (cancel) |flag| if (flag.load(.acquire)) return error.ObservationAnalysisCancelled;
            if (p.ordinal >= source.stored_records or (prior != null and p.ordinal <= prior.?)) return error.InvalidSavedAssociations;
            prior = p.ordinal;
        }
        prior = null;
        for (stream.intervals, 0..) |p, i| {
            if (i % 256 == 0) if (cancel) |flag| if (flag.load(.acquire)) return error.ObservationAnalysisCancelled;
            if (p.ordinal >= source.stored_records or (prior != null and p.ordinal <= prior.?)) return error.InvalidSavedAssociations;
            prior = p.ordinal;
        }
    }
    // Unknown algorithms retain source evidence but their classifications are
    // opaque historical claims. Explicit reanalysis uses the current algorithm.
    if (!std.mem.eql(u8, view.association_algorithm, algorithm)) return;
    var derived = try assoc.build(a, store, view.origin, view.streams, .{ .selection = view.selection }, cancel);
    defer derived.deinit(a);
    if (!equal(assoc.Result, derived, view.derived)) return error.InvalidSavedAssociations;
}
