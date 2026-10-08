//! Named stopped-language bindings; layout and value decoding stay in C.
const std = @import("std");
const Session = @import("session.zig").Session;
const Tab = @import("language_tabs.zig").Tab;
pub const Child = struct { key: []const u8, type: []const u8, display: []const u8, address: ?u64, diagnostic: ?[]const u8, advisory: bool };
pub const Value = struct {
    count: ?u64 = null,
    type: []const u8,
    display: []const u8,
    diagnostic: ?[]const u8 = null,
    advisory: bool = false,
    truncated: bool = false,
    children: []Child = &.{},
};
pub const Row = struct {
    name: []const u8,
    name_diagnostic: ?[]const u8 = null,
    scope: enum { local, parameter, upvalue, cell, free, context, state, vararg },
    context_depth: ?usize = null,
    context_address: ?u64 = null,
    context_parameter: ?bool = null,
    provenance: ?[]const u8 = null,
    ordinal: usize,
    address: ?u64,
    slot_address: ?u64 = null,
    hidden: bool = false,
    immediate: bool = false,
    storage_lifetime: []const u8 = "this retained stop only; resolve again after resume",
    value: Value,
};
pub const Result = struct {
    view_kind: enum { named_locals, context_storage } = .named_locals,
    lexical_visibility: ?[]const u8 = null,
    generation: u64,
    tid: i32,
    language: Tab,
    segment: usize,
    frame: usize,
    start: usize,
    total: usize,
    truncated: bool,
    rows: []Row,
    diagnostic: ?[]const u8,
    runtime_version: []const u8,
    runtime_build_id: []const u8,
    basis: []const u8,
    memory_reads: usize,
    memory_bytes: usize,
};
pub fn supported(language: Tab) bool {
    return language == .lua or language == .perl or language == .python or language == .javascript;
}
pub fn read(session: *Session, a: std.mem.Allocator, language: Tab, tid: i32, segment: usize, frame: usize, start: usize, limit: usize) !Result {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    if (tid <= 0 or segment >= 64 or frame >= 64 or start > 4096 or limit == 0 or limit > 32) return error.InvalidArguments;
    return switch (language) {
        .lua => @import("../language/lua.zig").readLocals(session, a, tid, segment, frame, start, limit),
        .perl => @import("../language/perl.zig").readLocals(session, a, tid, segment, frame, start, limit),
        .python => @import("../language/python.zig").readLocals(session, a, tid, segment, frame, start, limit),
        .javascript => @import("../language/javascript.zig").readContext(session, a, tid, segment, frame, start, limit),
        else => error.InvalidArguments,
    };
}

/// Only memory-backed language operations are allowed; each runtime decides its
/// supported expression subset. No interpreter evaluation or target calls.
pub fn evaluate(session: *Session, a: std.mem.Allocator, language: Tab, tid: i32, segment: usize, frame: usize, text: []const u8) !Result {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    if (tid <= 0 or segment >= 64 or frame >= 64 or text.len == 0 or text.len > 128 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidArguments;
    return switch (language) {
        .lua => @import("../language/lua.zig").evaluateLocal(session, a, tid, segment, frame, text),
        .perl => @import("../language/perl.zig").evaluateLocal(session, a, tid, segment, frame, text),
        .python => @import("../language/python.zig").evaluateLocal(session, a, tid, segment, frame, text),
        .javascript => @import("../language/javascript.zig").evaluateLocal(session, tid, segment, frame),
        else => error.InvalidArguments,
    };
}
