//! Questions about one analysed function, answered from its xsg graph: which
//! ops a PC or source line names (candidates, never a guess), what feeds a
//! value (slice) and what controls an op (control dependences). The same
//! answer serves MCP and the GUI. Every answer carries the producer's
//! qualification and the "static possibilities" label; observed values are a
//! separate kind of answer and are never merged into it.
const std = @import("std");
const host = @import("host.zig");
const c = host.c;
const Session = @import("../model/session.zig").Session;
const Allocator = std.mem.Allocator;

pub const Site = struct { path: []const u8, line: u32 };
pub const OpRef = struct { op: u32, opcode: []const u8, address: u64, link_address: u64, call: ?[]const u8 = null, source: ?Site = null };
pub const ValueRef = struct { id: u32, role: []const u8, space: []const u8, offset: u64, size: u32, register: ?[]const u8 = null, param: ?i32 = null };
pub const Input = struct { index: u32, value: ValueRef, sliceable: bool };
pub const Candidate = struct { op: OpRef, output: ?ValueRef, inputs: []const Input };
pub const Trust = struct {
    static: bool = true,
    note: []const u8 = host.banner,
    level: []const u8,
    reasons: []const u8,
    artifact_id: []const u8,
    result_trust: []const u8,
    verified_semantics: bool = false,
};
pub const Parameter = struct { index: i32, registers: []const u8, relevance: []const u8 };
pub const Contribution = struct { value: ValueRef, certainty: []const u8, step: []const u8, defined_by: ?OpRef, read_by: ?OpRef };
pub const Citation = struct { address: u64, link_address: u64, certainty: []const u8, source: ?Site };
pub const Boundary = struct { kind: []const u8, certainty: []const u8, op: ?OpRef, value: ?ValueRef };
pub const Control = struct { branch: OpRef, condition: ValueRef, condition_defined_by: ?OpRef, edge: []const u8, controlled_block: u32, relation: []const u8, certainty: []const u8, nontermination_sensitive: bool, condition_parameters: []const Parameter };
pub const Stats = struct { nodes: u32, edges: u64, work: u64, elapsed_ns: u64 };

pub const Slice = struct {
    trust: Trust,
    query: struct { op: OpRef, input: ?u32, value: ValueRef, data_only: bool },
    status: []const u8,
    limit: []const u8,
    message: []const u8,
    exhaustive: bool,
    memory_complete: bool,
    parameters: []const Parameter,
    parameters_basis: []const u8 = "relevance of each graph input the decompiler's prototype names as a parameter (by ABI storage); irrelevant is claimed only for an exhaustive slice; a parameter with no input varnode in the graph is not listed",
    contributions: []const Contribution,
    contributions_total: u32,
    instructions: []const Citation,
    boundaries: []const Boundary,
    frontier: u32,
    frontier_complete: bool,
    stats: Stats,
};
pub const Controls = struct {
    trust: Trust,
    query: struct { op: OpRef },
    status: []const u8,
    limit: []const u8,
    message: []const u8,
    controls: []const Control,
    controls_total: u32,
    frontier: u32,
    frontier_complete: bool,
    stats: Stats,
};

pub const Selector = union(enum) {
    op: u32,
    pc: u64,
    /// `addresses` are the debugger line table's rows for the line (runtime).
    /// An op belongs to the line when one of those rows starts at its
    /// address, or when the address's own best row names the line; rows at
    /// inlined code therefore select the containing function's ops.
    line: struct { path: []const u8, line: u32, addresses: []const u64 = &.{} },
};

/// A C array and its count; an empty array may be a null pointer.
pub fn items(pointer: anytype, count: anytype) []const @typeInfo(@TypeOf(pointer)).pointer.child {
    return if (count == 0) &.{} else pointer[0..count];
}

fn graph(analysis: *host.Analysis) *const c.struct_xsq_graph {
    return &analysis.graph;
}
fn func(analysis: *host.Analysis) c.struct_xsq_func {
    return analysis.graph.funcs[analysis.func];
}
fn text(g: *const c.struct_xsq_graph, offset: u32) []const u8 {
    return std.mem.span(c.xsq_string(g, offset));
}

pub fn trust(a: Allocator, analysis: *host.Analysis) !Trust {
    var codes: std.ArrayList(u8) = .empty;
    for (analysis.reasons, 0..) |r, i| {
        if (i > 0) try codes.append(a, ',');
        try codes.appendSlice(a, r.code);
    }
    return .{ .level = analysis.level, .reasons = codes.items, .artifact_id = analysis.artifact_id, .result_trust = try std.fmt.allocPrint(a, "graph_{s}", .{analysis.level}) };
}

fn site(a: Allocator, session: ?*Session, address: u64) ?Site {
    const s = session orelse return null;
    const found = s.sourceAt(a, address) catch return null;
    return .{ .path = found.path, .line = found.line };
}

fn opRef(a: Allocator, session: ?*Session, analysis: *host.Analysis, index: u32) !OpRef {
    const g = graph(analysis);
    const op = &g.ops[index];
    var call: ?[]const u8 = null;
    for (items(g.calls, g.call_count)) |cl| if (cl.op == index and cl.name != 0) {
        call = text(g, cl.name);
    };
    const address = analysis.function.runtime(op.address);
    return .{ .op = op.id, .opcode = std.mem.span(c.xsq_opcode_name(g, op)), .address = address, .link_address = op.address, .call = call, .source = site(a, session, address) };
}

fn valueRef(analysis: *host.Analysis, index: u32) ValueRef {
    const g = graph(analysis);
    const vn = &g.vns[index];
    return .{ .id = vn.id, .role = std.mem.span(c.xsq_vn_role(g, index)), .space = text(g, g.spaces[vn.space].name), .offset = vn.offset, .size = vn.size, .register = if (vn.name != 0) text(g, vn.name) else null, .param = if (vn.param >= 0) vn.param else null };
}

/// Ops of the analysed function at a PC, on a source line, or by id. More than
/// one candidate is an ambiguous selection; the caller shows them all.
pub fn candidates(a: Allocator, session: ?*Session, analysis: *host.Analysis, selector: Selector, opcode: ?[]const u8) ![]Candidate {
    const g = graph(analysis);
    const f = func(analysis);
    var out: std.ArrayList(Candidate) = .empty;
    var line_cache: std.AutoHashMapUnmanaged(u64, bool) = .empty;
    for (f.op_first..f.op_first + f.op_count) |i| {
        const op = &g.ops[i];
        const chosen = switch (selector) {
            .op => |id| op.id == id,
            .pc => |pc| analysis.function.runtime(op.address) == pc,
            .line => |want| blk: {
                const address = analysis.function.runtime(op.address);
                if (std.mem.indexOfScalar(u64, want.addresses, address) != null) break :blk true;
                if (line_cache.get(address)) |hit| break :blk hit;
                const here = site(a, session, address);
                const hit = here != null and here.?.line == want.line and samePath(here.?.path, want.path);
                try line_cache.put(a, address, hit);
                break :blk hit;
            },
        };
        if (!chosen) continue;
        if (opcode) |name| if (!std.ascii.eqlIgnoreCase(name, std.mem.span(c.xsq_opcode_name(g, op)))) continue;
        var inputs: std.ArrayList(Input) = .empty;
        for (0..op.in_count) |k| {
            const v = g.inputs[op.in_first + k];
            if (v == c.XSQ_NONE) continue; // INDIRECT op reference
            const ref = valueRef(analysis, v);
            const sliceable = g.vns[v].flags & c.XSQ_VN_ANNOTATION == 0 and !std.mem.eql(u8, ref.role, "constant");
            try inputs.append(a, .{ .index = @intCast(k), .value = ref, .sliceable = sliceable });
        }
        try out.append(a, .{ .op = try opRef(a, session, analysis, @intCast(i)), .output = if (op.out != c.XSQ_NONE) valueRef(analysis, op.out) else null, .inputs = inputs.items });
    }
    return out.items;
}

/// Why a line selected no op: its rows inside the analysed function, and for
/// each the inlined subroutines (innermost first) that the address lies in.
pub const LineRow = struct { address: u64, inlined: []const []const u8 };
pub const LineMiss = struct { reason: []const u8, rows: []const LineRow };
pub fn lineMiss(a: Allocator, session: *Session, analysis: *host.Analysis, addresses: []const u64) !LineMiss {
    const entry = analysis.function.runtime(analysis.function.key.entry);
    var rows: std.ArrayList(LineRow) = .empty;
    var inlined = false;
    for (addresses) |address| {
        if (address < entry or address - entry >= analysis.function.key.size) continue;
        var names: std.ArrayList([]const u8) = .empty;
        if (session.modules.at(address)) |module| {
            if (module.debugInfo()) |debug| {
                const frames = debug.inlineAt(a, module.linkAddress(address) catch address) catch &.{};
                var i = frames.len;
                while (i > 0) : (i -= 1) try names.append(a, frames[i - 1].name);
            } else |_| {}
        } else |_| {}
        if (names.items.len > 0) inlined = true;
        try rows.append(a, .{ .address = address, .inlined = names.items });
    }
    return .{ .reason = if (rows.items.len == 0) "no_line_row_in_function" else if (inlined) "inlined_no_direct_op" else "no_op_at_line_rows", .rows = rows.items };
}

/// A bare file name matches any path ending in it; otherwise paths must match.
fn samePath(have: []const u8, want: []const u8) bool {
    if (std.mem.eql(u8, have, want)) return true;
    if (std.mem.indexOfScalar(u8, want, '/') == null) return std.mem.eql(u8, std.fs.path.basename(have), want);
    return std.mem.endsWith(u8, have, want) and have.len > want.len and have[have.len - want.len - 1] == '/';
}

pub const Budget = struct { max_ms: u32 = 2000, rows: u32 = 64 };

fn budget(b: Budget) c.struct_xsq_budget {
    var out: c.struct_xsq_budget = undefined;
    c.xsq_budget_default(&out);
    out.max_ns = @as(u64, b.max_ms) * std.time.ns_per_ms;
    out.max_bytes = 64 << 20;
    return out;
}

fn relevanceRank(name: c.enum_xsq_relevance) u8 {
    return switch (name) {
        c.XSQ_REL_DIRECT => 0,
        c.XSQ_REL_POSSIBLE => 1,
        c.XSQ_REL_CONTROL => 2,
        c.XSQ_REL_UNKNOWN => 3,
        else => 4,
    };
}

/// Per prototype parameter: the strongest relevance over its input varnodes;
/// "irrelevant" only when every one of them is (which needs an exhaustive slice).
fn parameters(a: Allocator, analysis: *host.Analysis, result: *const c.struct_xsq_result) ![]Parameter {
    const g = graph(analysis);
    const f = func(analysis);
    var out: std.ArrayList(Parameter) = .empty;
    var best: std.ArrayList(u8) = .empty;
    for (f.vn_first..f.vn_first + f.vn_count) |i| {
        const vn = &g.vns[i];
        if (vn.flags & c.XSQ_VN_PARAM == 0 or vn.param < 0) continue;
        var node: u32 = undefined;
        const rel = c.xsq_relevance(result, @intCast(i), &node);
        const name = if (vn.name != 0) text(g, vn.name) else "?";
        for (out.items, best.items) |*p, *rank| {
            if (p.index != vn.param) continue;
            p.registers = try std.fmt.allocPrint(a, "{s},{s}", .{ p.registers, name });
            if (relevanceRank(rel) < rank.*) {
                rank.* = relevanceRank(rel);
                p.relevance = std.mem.span(c.xsq_relevance_name(rel));
            }
            break;
        } else {
            try out.append(a, .{ .index = vn.param, .registers = name, .relevance = std.mem.span(c.xsq_relevance_name(rel)) });
            try best.append(a, relevanceRank(rel));
        }
    }
    std.mem.sort(Parameter, out.items, {}, struct {
        fn less(_: void, l: Parameter, r: Parameter) bool {
            return l.index < r.index;
        }
    }.less);
    return out.items;
}

fn stats(r: *const c.struct_xsq_result) Stats {
    return .{ .nodes = r.node_count, .edges = r.edges, .work = r.work, .elapsed_ns = r.ns };
}

pub const Error = error{ OpNotFound, InputOutOfRange, NoOutput, StaticQueryFailed, OutOfMemory };

/// What feeds input `input` of op id `op` (or its output when null).
pub fn slice(a: Allocator, session: ?*Session, analysis: *host.Analysis, op_id: u32, input: ?u32, data_only: bool, limits: Budget) !Slice {
    const g = graph(analysis);
    const index = c.xsq_find_op(g, op_id);
    if (index == c.XSQ_NONE) return error.OpNotFound;
    const op = &g.ops[index];
    if (input) |k| {
        if (k >= op.in_count) return error.InputOutOfRange;
    } else if (op.out == c.XSQ_NONE) return error.NoOutput;
    const root_vn = if (input) |k| g.inputs[op.in_first + k] else op.out;
    if (root_vn == c.XSQ_NONE) return error.InputOutOfRange;
    var b = budget(limits);
    var result = std.mem.zeroes(c.struct_xsq_result);
    defer c.xsq_result_free(&result);
    const status = c.xsq_slice(g, .{ .op_id = op_id, .vn_id = c.XSQ_NONE, .input = if (input) |k| @intCast(k) else -1, .flags = if (data_only) c.XSQ_SLICE_DATA_ONLY else 0 }, &b, &result);
    switch (status) {
        c.XSQ_OK, c.XSQ_PARTIAL, c.XSQ_CANCELLED => {},
        else => return error.StaticQueryFailed,
    }
    var rows: std.ArrayList(Contribution) = .empty;
    for (items(result.nodes, result.node_count), 0..) |node, i| {
        if (i >= limits.rows) break;
        const def = g.vns[node.vn].def;
        try rows.append(a, .{ .value = valueRef(analysis, node.vn), .certainty = std.mem.span(c.xsq_certainty_name(node.certainty)), .step = std.mem.span(c.xsq_step_name(node.step)), .defined_by = if (def != c.XSQ_NONE) try opRef(a, session, analysis, def) else null, .read_by = if (node.via_op != c.XSQ_NONE) try opRef(a, session, analysis, node.via_op) else null });
    }
    // Instruction citations: defining ops of contributing values, strongest certainty first.
    var cites: std.ArrayList(Citation) = .empty;
    for (items(result.nodes, result.node_count)) |node| {
        const def = g.vns[node.vn].def;
        if (def == c.XSQ_NONE) continue;
        const link = g.ops[def].address;
        const certainty = std.mem.span(c.xsq_certainty_name(node.certainty));
        for (cites.items) |*cite| {
            if (cite.link_address != link) continue;
            if (node.certainty == c.XSQ_DIRECT) cite.certainty = certainty;
            break;
        } else try cites.append(a, .{ .address = analysis.function.runtime(link), .link_address = link, .certainty = certainty, .source = null });
    }
    std.mem.sort(Citation, cites.items, {}, struct {
        fn less(_: void, l: Citation, r: Citation) bool {
            return l.link_address < r.link_address;
        }
    }.less);
    if (cites.items.len > limits.rows) cites.items.len = limits.rows;
    for (cites.items) |*cite| cite.source = site(a, session, cite.address);
    var bounds: std.ArrayList(Boundary) = .empty;
    for (items(result.boundaries, @min(result.boundary_count, limits.rows))) |bd| try bounds.append(a, .{ .kind = std.mem.span(c.xsq_boundary_name(bd.kind)), .certainty = std.mem.span(c.xsq_certainty_name(bd.certainty)), .op = if (bd.op != c.XSQ_NONE) try opRef(a, session, analysis, bd.op) else null, .value = if (bd.vn != c.XSQ_NONE) valueRef(analysis, bd.vn) else null });
    return .{
        .trust = try trust(a, analysis),
        .query = .{ .op = try opRef(a, session, analysis, index), .input = input, .value = valueRef(analysis, root_vn), .data_only = data_only },
        .status = std.mem.span(c.xsq_status_name(status)),
        .limit = std.mem.span(c.xsq_limit_name(result.limit)),
        .message = try a.dupe(u8, std.mem.sliceTo(&result.message, 0)),
        .exhaustive = result.exhaustive != 0,
        .memory_complete = result.memory_complete != 0,
        .parameters = try parameters(a, analysis, &result),
        .contributions = rows.items,
        .contributions_total = result.node_count,
        .instructions = cites.items,
        .boundaries = bounds.items,
        .frontier = result.frontier_count,
        .frontier_complete = result.frontier_complete != 0,
        .stats = stats(&result),
    };
}

/// Which branches decide whether op id `op` executes, and which parameters
/// feed each direct condition (a data-only slice of the condition).
pub fn controls(a: Allocator, session: ?*Session, analysis: *host.Analysis, op_id: u32, limits: Budget) !Controls {
    const g = graph(analysis);
    const index = c.xsq_find_op(g, op_id);
    if (index == c.XSQ_NONE) return error.OpNotFound;
    var b = budget(limits);
    var result = std.mem.zeroes(c.struct_xsq_result);
    defer c.xsq_result_free(&result);
    const status = c.xsq_controls(g, op_id, &b, &result);
    switch (status) {
        c.XSQ_OK, c.XSQ_PARTIAL, c.XSQ_CANCELLED => {},
        else => return error.StaticQueryFailed,
    }
    var rows: std.ArrayList(Control) = .empty;
    for (items(result.controls, @min(result.control_count, limits.rows))) |ctl| {
        const edge = g.edges[ctl.edge];
        const def = g.vns[ctl.condition_vn].def;
        var feeds: []Parameter = &.{};
        if (ctl.depth == 0) {
            var cb = budget(limits);
            var cond = std.mem.zeroes(c.struct_xsq_result);
            defer c.xsq_result_free(&cond);
            const s = c.xsq_slice(g, .{ .op_id = c.XSQ_NONE, .vn_id = g.vns[ctl.condition_vn].id, .input = -2, .flags = c.XSQ_SLICE_DATA_ONLY }, &cb, &cond);
            if (s == c.XSQ_OK or s == c.XSQ_PARTIAL) feeds = try parameters(a, analysis, &cond);
        }
        try rows.append(a, .{
            .branch = try opRef(a, session, analysis, ctl.branch_op),
            .condition = valueRef(analysis, ctl.condition_vn),
            .condition_defined_by = if (def != c.XSQ_NONE) try opRef(a, session, analysis, def) else null,
            .edge = std.mem.span(c.xsq_edge_kind_name(edge.kind)),
            .controlled_block = g.blocks[ctl.controlled_block].id,
            .relation = if (ctl.depth == 0) "direct" else "transitive",
            .certainty = if (ctl.certainty == c.XSQ_DIRECT) "direct" else "possible",
            .nontermination_sensitive = ctl.nontermination != 0,
            .condition_parameters = feeds,
        });
    }
    return .{
        .trust = try trust(a, analysis),
        .query = .{ .op = try opRef(a, session, analysis, index) },
        .status = std.mem.span(c.xsq_status_name(status)),
        .limit = std.mem.span(c.xsq_limit_name(result.limit)),
        .message = try a.dupe(u8, std.mem.sliceTo(&result.message, 0)),
        .controls = rows.items,
        .controls_total = result.control_count,
        .frontier = result.frontier_count,
        .frontier_complete = result.frontier_complete != 0,
        .stats = stats(&result),
    };
}

/// Observed now: the stopped frame's DWARF parameters, kept apart from the
/// static answer. Only offered when the frame is inside the analysed function.
pub const Observed = struct {
    kind: []const u8 = "observed_now",
    note: []const u8 = "values read from the stopped target at this generation; not part of the static answer",
    generation: u64,
    tid: i32,
    frame: usize,
    pc: u64,
    parameters: []const struct { name: []const u8, value: []const u8, type: []const u8, available: bool },
};

pub fn observed(a: Allocator, session: *Session, analysis: *host.Analysis, tid: i32, frame: usize) !?Observed {
    if (session.target.snapshot().state != .stopped) return null;
    const frames = try session.stack(a, tid, frame + 1);
    if (frame >= frames.len) return null;
    const pc = frames[frame].lookup_pc;
    const entry = analysis.function.runtime(analysis.function.key.entry);
    if (pc < entry or pc >= entry + analysis.function.key.size) return null;
    const locals = try session.locals(a, tid, frame);
    const Row = @typeInfo(@FieldType(Observed, "parameters")).pointer.child;
    var rows: std.ArrayList(Row) = .empty;
    for (locals) |local| if (local.parameter) {
        const summary = session.summarize(a, local.value) catch continue;
        try rows.append(a, .{ .name = local.name, .value = summary.display, .type = summary.type, .available = summary.availability == .available });
    };
    return .{ .generation = session.target.snapshot().generation, .tid = tid, .frame = frame, .pc = pc, .parameters = rows.items };
}

fn fixtureAnalysis(a: Allocator) !*host.Analysis {
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("adapter_fixture.json"), .{});
    const xsg = (try @import("adapter.zig").convert(a, doc, "00")).xsg;
    const analysis = try a.create(host.Analysis);
    analysis.* = .{ .arena = .init(std.heap.page_allocator), .function = .{ .key = .{ .image_sha256 = @splat('0'), .entry = 0x4012e0, .size = 0x5b }, .name = "qx_alloc", .module_id = 1, .module_path = "/fixtures/qx-gcc-O2", .bias = 0, .bounds_source = "elf_symbol", .build_id = null }, .artifact_id = "fixture", .contract = "", .schema_version = "0.4.1", .level = "qualified", .reasons = &.{.{ .code = "tail_call_inferred", .level = "qualified", .detail = "", .address = null }}, .export_path = "", .worker_ms = 0 };
    var b = c.struct_xsq_load_budget{ .max_bytes = 0, .cancel = null };
    try std.testing.expect(c.xsq_load_buffer_budget(xsg.ptr, xsg.len, &b, &analysis.graph) == c.XSQ_OK);
    return analysis;
}

test "qx_alloc: count and size feed malloc's size, flag does not, and the guard reads count only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const analysis = try fixtureAnalysis(a);
    defer c.xsq_free(&analysis.graph);
    // The guard's compare and branch share one PC: the PC alone is ambiguous.
    const at_guard = try candidates(a, null, analysis, .{ .pc = 0x4012e6 }, null);
    try std.testing.expect(at_guard.len > 1);
    try std.testing.expectEqual(@as(usize, 1), (try candidates(a, null, analysis, .{ .pc = 0x4012e6 }, "CBRANCH")).len);
    const calls = try candidates(a, null, analysis, .{ .pc = 0x4012fd }, "call");
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("malloc", calls[0].op.call.?);
    const s = try slice(a, null, analysis, calls[0].op.op, 1, true, .{});
    try std.testing.expect(s.exhaustive);
    try std.testing.expectEqualStrings("qualified", s.trust.level);
    try std.testing.expectEqualStrings("graph_qualified", s.trust.result_trust);
    try std.testing.expect(!s.trust.verified_semantics);
    try std.testing.expectEqual(@as(usize, 3), s.parameters.len);
    try std.testing.expectEqualStrings("direct", s.parameters[0].relevance);
    try std.testing.expectEqualStrings("direct", s.parameters[1].relevance);
    try std.testing.expectEqualStrings("irrelevant", s.parameters[2].relevance);
    try std.testing.expect(s.instructions.len >= 3);
    const ctl = try controls(a, null, analysis, calls[0].op.op, .{});
    try std.testing.expect(ctl.controls.len >= 1);
    const guard = ctl.controls[0];
    try std.testing.expectEqualStrings("direct", guard.relation);
    try std.testing.expectEqualStrings("direct", guard.condition_parameters[0].relevance);
    for (guard.condition_parameters[1..]) |p| try std.testing.expectEqualStrings("irrelevant", p.relevance);
    try std.testing.expectError(error.InputOutOfRange, slice(a, null, analysis, calls[0].op.op, 99, true, .{}));
    try std.testing.expectError(error.OpNotFound, slice(a, null, analysis, 999999, 0, true, .{}));
}
