//! Named-binding results; readers and presentation share these value records.
const Tab = @import("types.zig").Tab;
pub const Child = struct { key: []const u8, type: []const u8, display: []const u8, address: ?u64, diagnostic: ?[]const u8, advisory: bool };
pub const Value = struct {
    count: ?u64 = null,
    type: []const u8,
    display: []const u8,
    diagnostic: ?[]const u8 = null,
    advisory: bool = false,
    truncated: bool = false,
    children: []const Child = &.{},
};
pub const Row = struct {
    name: []const u8,
    name_diagnostic: ?[]const u8 = null,
    scope: enum { local, parameter, upvalue, cell, free, context, state, vararg, dynamic, lexical, member },
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
    identity: ?@import("types.zig").Identity = null,
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
    rows: []const Row,
    diagnostic: ?[]const u8,
    runtime_version: []const u8,
    runtime_build_id: []const u8,
    basis: []const u8,
    memory_reads: usize,
    memory_bytes: usize,
};
