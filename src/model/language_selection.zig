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
        else => @compileError("a language stack is required"),
    };
}
pub fn read(comptime language: Tab, session: *model.Session, a: A, tid: i32) !Stack(language) {
    return switch (language) {
        .python => @import("../language/python.zig").stack(session, a, tid, 0),
        .perl => @import("../language/perl.zig").stack(session, a, tid, 0),
        .lua => @import("../language/lua.zig").stack(session, a, tid, 0, null),
        .javascript => @import("../language/javascript.zig").stack(session, a, tid, 0),
        else => unreachable,
    };
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
fn matches(segment: anytype, index: usize, native: []const model.Frame) !bool {
    if (segment.anchor) |anchor| if (try checkedAnchor(anchor, native) == index) return true;
    if (@hasField(@TypeOf(segment), "additional_anchors")) {
        for (segment.additional_anchors) |anchor| if (try checkedAnchor(anchor, native) == index) return true;
    }
    return false;
}
fn appendOffers(offers: *Offers, language: Tab, stack: anytype, index: usize, native: []const model.Frame) !void {
    for (stack.segments, 0..) |segment, i| {
        if (!try matches(segment, index, native)) continue;
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = try session.stack(a, tid, 64);
    if (frame >= native.len) return error.InvalidFrame;
    var offers = Offers{};
    inline for (.{ Tab.python, Tab.perl, Tab.lua, Tab.javascript }) |language| {
        if (session.language_tabs.visible(language)) {
            if (read(language, session, a, tid)) |stack| {
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
    if (offers.count == 1 and !offers.truncated and offers.diagnostic == null) {
        const offer = offers.items[0];
        state.selected = offer.language;
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
    if (session.language_tabs.native_selection) |selected| {
        if (selected.generation == generation and selected.tid == tid and try matches(segment, selected.frame, native)) anchor = selected.frame;
    }
    if (anchor == null) if (segment.anchor) |value| {
        anchor = try checkedAnchor(value, native);
    };
    const reason = if (anchor == null) "LanguageNativeAnchorUnproved" else segment.reason;
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = try session.stack(a, tid, 64);
    inline for (.{ Tab.python, Tab.perl, Tab.lua, Tab.javascript }) |candidate| {
        if (language == candidate) {
            const stack = try read(candidate, session, a, tid);
            return fromStack(session, candidate, tid, stack, segment, frame, native);
        }
    }
    return error.InvalidArguments;
}
