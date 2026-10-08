//! Presentation-only links backed by the language readers' segment anchors.
//! A segment link is not a claim of one-to-one logical/native frame identity.
const std = @import("std");
const model = @import("session.zig");
const Tab = @import("language_tabs.zig").Tab;
const Text = @import("probes.zig").Text;
const A = std.mem.Allocator;
pub const Native = struct { generation: u64, tid: i32, frame: usize };
pub const Logical = struct {
    generation: u64,
    tid: i32,
    language: Tab,
    segment: usize,
    frame: usize,
    native_anchor: ?usize,
    native_pc: ?u64,
    anchor_basis: enum { reader_segment, unproved },
    reason: ?Text = null,
};
pub const Offer = struct {
    language: Tab,
    segment: usize,
    first_frame: ?usize,
    native_anchor: usize,
    basis: []const u8 = "reader segment anchor; per-logical-frame native identity unproved",
    reason: ?Text = null,
};
pub const Offers = struct {
    items: [16]Offer = undefined,
    count: usize = 0,
    truncated: bool = false,
    diagnostic: ?Text = null,
    pub fn jsonStringify(self: Offers, writer: anytype) !void {
        try writer.write(.{ .items = self.items[0..self.count], .truncated = self.truncated, .diagnostic = self.diagnostic });
    }
};
pub fn Stack(comptime language: Tab) type {
    return switch (language) {
        .python => @import("../language/python.zig").Stack,
        .perl => @import("../language/perl.zig").Stack,
        .lua => @import("../language/lua.zig").Stack,
        .javascript => @import("../language/javascript.zig").Stack,
        .ruby => @import("../language/ruby.zig").Stack,
        else => @compileError("a language stack is required"),
    };
}
pub fn read(comptime language: Tab, session: *model.Session, a: A, tid: i32) !Stack(language) {
    return switch (language) {
        .python => @import("../language/python.zig").stack(session, a, tid, 0),
        .perl => @import("../language/perl.zig").stack(session, a, tid, 0),
        .lua => @import("../language/lua.zig").stack(session, a, tid, 0, null),
        .javascript => @import("../language/javascript.zig").stack(session, a, tid, 0),
        .ruby => @import("../language/ruby.zig").stack(session, a, tid, 0),
        else => unreachable,
    };
}
// One retained thread per process bounds lifetime and memory. A generation,
// image or metadata change invalidates every pointer before the next read.
const CacheKey = struct { generation: u64, epoch: u64, metadata: u64, tid: i32 };
pub const Cache = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    key: ?CacheKey = null,
    native: ?[]model.Frame = null,
    stacks: std.meta.Tuple(&.{ ?Stack(.python), ?Stack(.perl), ?Stack(.lua), ?Stack(.javascript), ?Stack(.ruby) }) = .{ null, null, null, null, null },
    errors: [5]?anyerror = @splat(null),
    pub fn deinit(self: *Cache) void {
        self.arena.deinit();
    }
    pub fn clear(self: *Cache) void {
        _ = self.arena.reset(.free_all);
        self.key = null;
        self.native = null;
        self.stacks = .{ null, null, null, null, null };
        self.errors = @splat(null);
    }
    fn prepare(self: *Cache, session: *model.Session, tid: i32) !void {
        const snapshot = session.target.snapshot();
        if (snapshot.state != .stopped) return error.NotStopped;
        const key = CacheKey{ .generation = snapshot.generation, .epoch = snapshot.image_epoch, .metadata = session.metadata.revision, .tid = tid };
        if (self.key == null or !std.meta.eql(self.key.?, key)) {
            self.clear();
            self.key = key;
        }
    }
};
fn cachedNative(session: *model.Session, tid: i32) ![]model.Frame {
    const cache = &session.language_tabs.cache;
    try cache.prepare(session, tid);
    if (cache.native == null) cache.native = try session.stack(cache.arena.allocator(), tid, 64);
    return cache.native.?;
}
/// Borrowed until the stop, thread, image or metadata changes. Presentation
/// callers that retain strings must copy them into their own frame arena.
pub fn cachedRead(comptime language: Tab, session: *model.Session, tid: i32) !Stack(language) {
    const cache = &session.language_tabs.cache;
    try cache.prepare(session, tid);
    const index = @intFromEnum(language) - 2;
    if (cache.errors[index]) |err| return err;
    if (cache.stacks[index] == null) {
        cache.stacks[index] = read(language, session, cache.arena.allocator(), tid) catch |err| {
            // Pending discovery may advance without a stopped-generation
            // change. Release partial allocations and let the next call retry.
            if (std.mem.endsWith(u8, @errorName(err), "Pending") or err == error.SymbolDiscoveryBudgetExceeded) cache.clear() else cache.errors[index] = err;
            return err;
        };
        try session.target.expectGeneration(cache.key.?.generation);
    }
    return cache.stacks[index].?;
}
fn diagnostic(reason: ?[]const u8) !?Text {
    return if (reason) |text| try Text.init(text) else null;
}
fn anchorPc(anchor: anytype) !u64 {
    if (@TypeOf(anchor.pc) == u64) return anchor.pc;
    return std.fmt.parseInt(u64, anchor.pc, 0) catch error.LanguageAnchorUnverified;
}
fn checkedAnchor(anchor: anytype, native: []const model.Frame) !usize {
    if (anchor.frame >= native.len or native[anchor.frame].index != anchor.frame or
        try anchorPc(anchor) != native[anchor.frame].pc) return error.LanguageAnchorUnverified;
    return anchor.frame;
}
fn matches(segment: anytype, index: usize, native: []const model.Frame, why: *?Text) bool {
    var matched = false;
    if (segment.anchor) |anchor| {
        if (checkedAnchor(anchor, native)) |found| {
            matched = found == index;
        } else |_| {
            why.* = Text.init("LanguageAnchorUnverified") catch unreachable;
        }
    }
    if (@hasField(@TypeOf(segment), "additional_anchors")) {
        for (segment.additional_anchors) |anchor| {
            if (checkedAnchor(anchor, native)) |found| {
                matched = matched or found == index;
            } else |_| {
                why.* = Text.init("LanguageAnchorUnverified") catch unreachable;
            }
        }
    }
    return matched;
}
fn appendOffers(offers: *Offers, language: Tab, stack: anytype, index: usize, native: []const model.Frame) !void {
    for (stack.segments, 0..) |segment, i| {
        if (!matches(segment, index, native, &offers.diagnostic)) continue;
        if (offers.count == offers.items.len) {
            offers.truncated = true;
            continue;
        }
        offers.items[offers.count] = .{ .language = language, .segment = i, .first_frame = if (segment.frames.len > 0) 0 else null, .native_anchor = index, .reason = try diagnostic(segment.reason) };
        offers.count += 1;
    }
}
pub fn selectNative(session: *model.Session, tid: i32, frame: usize) !void {
    if (frame >= 64) return error.InvalidFrame;
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    const generation = session.target.snapshot().generation;
    // Only index and PC are used below. Copy them before a reader can
    // invalidate the cache while advancing metadata discovery.
    var native_storage: [64]model.Frame = undefined;
    const borrowed_native = try cachedNative(session, tid);
    const native = native_storage[0..borrowed_native.len];
    @memcpy(native, borrowed_native);
    if (frame >= native.len) return error.InvalidFrame;
    var offers = Offers{};
    inline for (.{ Tab.python, Tab.perl, Tab.lua, Tab.javascript, Tab.ruby }) |language| {
        if (session.language_tabs.visible(language)) {
            if (cachedRead(language, session, tid)) |stack| {
                try appendOffers(&offers, language, stack, frame, native);
            } else |err| {
                if (offers.diagnostic == null) offers.diagnostic = try Text.init(@errorName(err));
            }
        }
    }
    try session.target.expectGeneration(generation);
    const state = &session.language_tabs;
    state.native_selection = .{ .generation = generation, .tid = tid, .frame = frame };
    state.logical_selection = null;
    state.offers = offers;
    // Expose a unique segment offer, never infer an activation when several
    // language segments share a native anchor.
    if (offers.count == 1 and !offers.truncated) {
        const offer = offers.items[0];
        // Native locals and registers remain where the user left them.
        if (@intFromEnum(state.selected) >= 2) state.selected = offer.language;
        if (offer.first_frame) |first| state.logical_selection = .{
            .generation = generation,
            .tid = tid,
            .language = offer.language,
            .segment = offer.segment,
            .frame = first,
            .native_anchor = frame,
            .native_pc = native[frame].pc,
            .anchor_basis = .reader_segment,
            .reason = offer.reason,
        };
    }
    state.revision +%= 1;
}
fn fromStack(session: *model.Session, language: Tab, tid: i32, stack: anytype, segment_index: usize, frame: usize, native: []const model.Frame) !void {
    if (segment_index >= stack.segments.len) return error.InvalidLanguageSegment;
    const segment = stack.segments[segment_index];
    if (frame >= segment.frames.len) return error.InvalidLanguageFrame;
    const generation = session.target.snapshot().generation;
    if (stack.generation != generation) return error.StaleSnapshot;
    var anchor: ?usize = null;
    var anchor_diagnostic: ?Text = null;
    if (session.language_tabs.native_selection) |selected| {
        if (selected.generation == generation and selected.tid == tid and matches(segment, selected.frame, native, &anchor_diagnostic)) anchor = selected.frame;
    }
    if (anchor == null) for (native, 0..) |_, i| {
        if (matches(segment, i, native, &anchor_diagnostic)) {
            anchor = i;
            break;
        }
    };
    const reason = if (anchor == null) (if (anchor_diagnostic) |value| value.slice() else "LanguageNativeAnchorUnproved") else segment.reason;
    const selected = Logical{ .generation = generation, .tid = tid, .language = language, .segment = segment_index, .frame = frame, .native_anchor = anchor, .native_pc = if (anchor) |index| native[index].pc else null, .anchor_basis = if (anchor != null) .reader_segment else .unproved, .reason = try diagnostic(reason) };
    try session.target.expectGeneration(generation);
    const state = &session.language_tabs;
    state.logical_selection = selected;
    state.offers = .{};
    state.selected = language;
    if (anchor) |index| state.native_selection = .{ .generation = generation, .tid = tid, .frame = index };
    state.revision +%= 1;
}
pub fn selectLogical(session: *model.Session, tid: i32, language: Tab, segment: usize, frame: usize) !void {
    if (segment >= 64 or frame >= 64) return error.InvalidArguments;
    if (!session.language_tabs.visible(language)) return error.LanguageTabUnavailable;
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    // Only index and PC are used below. Copy them before a reader can
    // invalidate the cache while advancing metadata discovery.
    var native_storage: [64]model.Frame = undefined;
    const borrowed_native = try cachedNative(session, tid);
    const native = native_storage[0..borrowed_native.len];
    @memcpy(native, borrowed_native);
    inline for (.{ Tab.python, Tab.perl, Tab.lua, Tab.javascript, Tab.ruby }) |candidate| {
        if (language == candidate) {
            const stack = try cachedRead(candidate, session, tid);
            return fromStack(session, candidate, tid, stack, segment, frame, native);
        }
    }
    return error.InvalidArguments;
}

test "one invalid anchor does not discard a separate valid offer" {
    const Anchor = struct { frame: usize, pc: []const u8 };
    const Segment = struct { anchor: ?Anchor, additional_anchors: []const Anchor = &.{}, frames: []const u8 = "x", reason: ?[]const u8 = null };
    var native: [2]model.Frame = undefined;
    native[0].index = 0;
    native[0].pc = 10;
    native[1].index = 1;
    native[1].pc = 20;
    const segments = [_]Segment{
        .{ .anchor = .{ .frame = 99, .pc = "0xa" } },
        .{ .anchor = .{ .frame = 0, .pc = "0xa" } },
        .{ .anchor = .{ .frame = 1, .pc = "malformed" }, .additional_anchors = &.{.{ .frame = 0, .pc = "0xa" }} },
        .{ .anchor = .{ .frame = 1, .pc = "0xa" } },
    };
    var offers = Offers{};
    try appendOffers(&offers, .lua, .{ .segments = &segments }, 0, &native);
    try std.testing.expectEqual(@as(usize, 2), offers.count);
    try std.testing.expectEqual(@as(usize, 1), offers.items[0].segment);
    try std.testing.expectEqual(@as(usize, 2), offers.items[1].segment);
    try std.testing.expectEqualStrings("LanguageAnchorUnverified", offers.diagnostic.?.slice());
}
