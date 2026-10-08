//! MCP surface of in-debugger static analysis (src/semq/host.zig). All four
//! tools are observer reads: they never touch the target; the worker is a
//! separate supervised process tree. Answers are static possibilities with the
//! producer's qualification; observed values come back in a separate field.
const std = @import("std");
const Session = @import("../model/session.zig").Session;
const host = @import("../semq/host.zig");
const answer = @import("../semq/answer.zig");
const wire = @import("profile.zig");
const V = std.json.Value;
const Allocator = std.mem.Allocator;
pub const definitions = @embedFile("static_tools.json");

pub fn handles(name: []const u8) bool {
    for ([_][]const u8{ "analyze_function", "slice_value", "control_dependencies", "cancel_static_analysis" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

/// Addresses and offsets as hex strings: JSON consumers often use doubles.
fn hexWords(a: Allocator, value: *V) !void {
    switch (value.*) {
        .array => |*array| for (array.items) |*item| try hexWords(a, item),
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                const word = for ([_][]const u8{ "address", "link_address", "offset", "pc", "entry", "link_entry", "target" }) |name| {
                    if (std.mem.eql(u8, key, name)) break true;
                } else false;
                const n: ?u64 = if (!word) null else switch (entry.value_ptr.*) {
                    .integer => |i| if (i >= 0) @intCast(i) else null,
                    .number_string => |digits| try std.fmt.parseInt(u64, digits, 10),
                    else => null,
                };
                // Format first: assigning in place would retag the union before the read.
                if (n) |word_value| {
                    const hex_text = try std.fmt.allocPrint(a, "0x{x}", .{word_value});
                    entry.value_ptr.* = .{ .string = hex_text };
                } else try hexWords(a, entry.value_ptr);
            }
        },
        else => {},
    }
}
fn out(a: Allocator, object: anytype) !V {
    var value = try wire.value(a, object);
    try hexWords(a, &value);
    return value;
}

fn hex(args: V, key: []const u8) !?u64 {
    const v = args.object.get(key) orelse return null;
    if (v != .string) return error.InvalidArguments;
    const digits = if (std.mem.startsWith(u8, v.string, "0x")) v.string[2..] else v.string;
    return std.fmt.parseInt(u64, digits, 16) catch error.InvalidArguments;
}
fn text(args: V, key: []const u8) !?[]const u8 {
    const v = args.object.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else error.InvalidArguments;
}
fn flag(args: V, key: []const u8) !bool {
    const v = args.object.get(key) orelse return false;
    return if (v == .bool) v.bool else error.InvalidArguments;
}

pub fn jobValue(job: *host.Job) struct { id: u64, state: []const u8, function: []const u8, entry: u64, size: u64, elapsed_ms: u64, deadline_ms: u32, cancel_requested: bool, failure: ?host.Failure } {
    const state: []const u8 = if (job.running()) "running" else if (job.failure) |f| (if (std.mem.eql(u8, f.code, "cancelled")) "cancelled" else "failed") else "completed";
    return .{ .id = job.id, .state = state, .function = job.function.name, .entry = job.function.runtime(job.function.key.entry), .size = job.function.key.size, .elapsed_ms = job.elapsedMs(), .deadline_ms = job.deadline_ms, .cancel_requested = job.cancelRequested(), .failure = if (job.running()) null else job.failure };
}

fn summary(a: Allocator, analysis: *host.Analysis) !V {
    const g = &analysis.graph;
    const f = g.funcs[analysis.func];
    const Param = struct { index: i32, register: []const u8 };
    var params: std.ArrayList(Param) = .empty;
    for (g.vns[f.vn_first .. f.vn_first + f.vn_count]) |vn| if (vn.flags & host.c.XSQ_VN_PARAM != 0 and vn.param >= 0)
        try params.append(a, .{ .index = vn.param, .register = if (vn.name != 0) std.mem.span(host.c.xsq_string(g, vn.name)) else "?" });
    const Call = struct { op: u32, address: u64, name: ?[]const u8, target: ?u64, inputs: u32 };
    var calls: std.ArrayList(Call) = .empty;
    for (answer.items(g.calls, g.call_count)) |site| {
        const op = g.ops[site.op];
        try calls.append(a, .{ .op = op.id, .address = analysis.function.runtime(op.address), .name = if (site.name != 0) std.mem.span(host.c.xsq_string(g, site.name)) else null, .target = if (site.known != 0) site.target else null, .inputs = op.in_count });
    }
    const Reason = struct { code: []const u8, level: []const u8, detail: []const u8, address: ?u64 };
    const reasons = try a.alloc(Reason, analysis.reasons.len);
    for (analysis.reasons, reasons) |r, *o| o.* = .{ .code = r.code, .level = r.level, .detail = r.detail, .address = if (r.address) |x| analysis.function.runtime(x) else null };
    const t = try answer.trust(a, analysis);
    return out(a, .{
        .artifact_id = analysis.artifact_id,
        .function = analysis.function.name,
        .entry = analysis.function.runtime(analysis.function.key.entry),
        .link_entry = analysis.function.key.entry,
        .size = analysis.function.key.size,
        .bounds_source = analysis.function.bounds_source,
        .module = analysis.function.module_path,
        .image = .{ .sha256 = &analysis.function.key.image_sha256, .build_id = analysis.function.build_id, .basis = "SHA-256 of the session's own snapshot of the mapped image; the worker read exactly these bytes" },
        .producer = .{ .schema_version = analysis.schema_version, .contract = analysis.contract, .worker_ms = analysis.worker_ms },
        .qualification = .{ .level = analysis.level, .reasons = reasons },
        .trust = t,
        .graph = .{ .blocks = f.block_count, .ops = f.op_count, .varnodes = f.vn_count, .cfg_incomplete = f.cfg_incomplete != 0 },
        .parameters = params.items,
        .calls = calls.items,
    });
}

const Resolved = union(enum) { status: V, analysis: *host.Analysis };

/// The analysis for `address`, or the status value to return instead.
fn analysisAt(a: Allocator, session: *Session, address: u64, opts: host.Options) !Resolved {
    return switch (try session.static_analysis.request(a, session, address, opts)) {
        .unavailable => |u| .{ .status = try out(a, .{ .status = "unavailable", .static_analysis = .{ .available = false, .reason = u.reason, .detail = u.detail, .how_to_build = host.how_to_build } }) },
        .running => |job| .{ .status = try out(a, .{ .status = "running", .job = jobValue(job), .poll = "call again with the same arguments" }) },
        .failed => |job| .{ .status = try out(a, .{ .status = jobValue(job).state, .job = jobValue(job), .retry = "pass retry:true to start a new job" }) },
        .ready => |analysis| .{ .analysis = analysis },
    };
}

fn options(session: *Session, args: V) !host.Options {
    return .{ .deadline_ms = @intCast(@min(try wire.number(args, "deadline_ms", host.default_deadline_ms), host.max_deadline_ms)), .retry = try flag(args, "retry"), .owner = .{ .agent = session.agent_client_id } };
}

pub fn call(a: Allocator, session: *Session, name: []const u8, args: V) !V {
    if (std.mem.eql(u8, name, "cancel_static_analysis")) {
        try wire.fields(args, &.{"job_id"});
        const job = try session.static_analysis.cancel(try wire.number(args, "job_id", null), .{ .agent = .{ .client = session.agent_client_id, .controller = session.agent_controller } });
        return out(a, .{ .status = if (job.running()) "cancelling" else jobValue(job).state, .job = jobValue(job) });
    }
    if (std.mem.eql(u8, name, "analyze_function")) {
        try wire.fields(args, &.{ "address", "symbol", "retry", "deadline_ms" });
        const address = try functionAddress(session, args) orelse return error.InvalidArguments;
        return switch (try analysisAt(a, session, address, try options(session, args))) {
            .status => |v| v,
            .analysis => |analysis| out(a, .{ .status = "completed", .analysis = try summary(a, analysis) }),
        };
    }
    const is_slice = std.mem.eql(u8, name, "slice_value");
    try wire.fields(args, if (is_slice)
        &.{ "address", "symbol", "pc", "file", "line", "op", "opcode", "input", "data_only", "tid", "frame", "rows", "max_ms", "deadline_ms" }
    else
        &.{ "address", "symbol", "pc", "file", "line", "op", "opcode", "rows", "max_ms", "deadline_ms" });
    const pc = try hex(args, "pc");
    const file = try text(args, "file");
    const line = args.object.get("line") != null;
    const op_given = args.object.get("op") != null;
    if (@as(u8, @intFromBool(pc != null)) + @intFromBool(file != null) + @intFromBool(op_given) != 1 or file != null and !line or line and file == null) return error.InvalidArguments;
    const limits = answer.Budget{ .rows = @intCast(@min(try wire.number(args, "rows", 64), 256)), .max_ms = @intCast(@min(try wire.number(args, "max_ms", 2000), 10_000)) };
    if (limits.rows == 0 or limits.max_ms == 0) return error.InvalidArguments;
    var selector: answer.Selector = undefined;
    var address: u64 = undefined;
    var line_addresses: []const u64 = &.{};
    if (pc) |value| {
        selector = .{ .pc = value };
        address = value;
    } else if (file) |path| {
        const number = try wire.number(args, "line", null);
        if (number == 0 or number > std.math.maxInt(u32)) return error.InvalidArguments;
        const addresses = session.sourceAddresses(a, path, @intCast(number)) catch |err| switch (err) {
            error.NoCodeForSourceLine => &.{},
            else => return err,
        };
        selector = .{ .line = .{ .path = path, .line = @intCast(number), .addresses = addresses } };
        line_addresses = addresses;
        if (addresses.len == 0) return out(a, .{ .status = "no_selection", .reason = "the debugger's line table has no code for this line" });
        // A line inlined or split into several functions is a choice for the caller.
        var entries: std.ArrayList(struct { function: []const u8, entry: u64 }) = .empty;
        for (addresses) |at| {
            const f = session.static_analysis.resolve(a, session, at) catch continue;
            const entry = f.runtime(f.key.entry);
            for (entries.items) |e| {
                if (e.entry == entry) break;
            } else try entries.append(a, .{ .function = f.name, .entry = entry });
        }
        if (entries.items.len == 0) return error.FunctionBoundsUnavailable;
        if (entries.items.len > 1) return out(a, .{ .status = "ambiguous", .reason = "the line has code in more than one function; pass address or symbol with op or pc", .functions = entries.items });
        address = entries.items[0].entry;
    } else {
        const id = try wire.number(args, "op", null);
        if (id > std.math.maxInt(u32)) return error.InvalidArguments;
        selector = .{ .op = @intCast(id) };
        address = try functionAddress(session, args) orelse return error.InvalidArguments;
    }
    const analysis = switch (try analysisAt(a, session, address, try options(session, args))) {
        .status => |v| return v,
        .analysis => |found| found,
    };
    const opcode = try text(args, "opcode");
    const found = try answer.candidates(a, session, analysis, selector, opcode);
    const brief = .{ .artifact_id = analysis.artifact_id, .function = analysis.function.name, .entry = analysis.function.runtime(analysis.function.key.entry), .qualification = analysis.level };
    if (found.len == 0 and selector == .line) {
        // The line has code in this function, but no exported op is cited at
        // its rows: say whether those rows are inlined code, never "no code".
        const miss = try answer.lineMiss(a, session, analysis, line_addresses);
        return out(a, .{ .status = "no_selection", .reason = miss.reason, .detail = "the debugger's line table maps this line to the rows below; no op of the analysed graph is cited at them (inlined or optimized code whose p-code did not survive)", .line_rows = miss.rows, .analysis = brief, .candidates = found, .candidates_total = 0 });
    }
    if (found.len != 1) return out(a, .{ .status = if (found.len == 0) "no_selection" else "ambiguous", .reason = if (found.len == 0) "no op of the analysed graph is cited at this selection (the instruction may have no surviving p-code)" else "several ops are cited at this selection; choose one by op id (and input)", .analysis = brief, .candidates = found[0..@min(found.len, limits.rows)], .candidates_total = found.len });
    const chosen = found[0].op.op;
    if (is_slice) {
        const input: ?u32 = if (args.object.get("input") != null) std.math.cast(u32, try wire.number(args, "input", null)) orelse return error.InvalidArguments else null;
        const result = try answer.slice(a, session, analysis, chosen, input, try flag(args, "data_only"), limits);
        var observed: ?answer.Observed = null;
        if (args.object.get("tid") != null) {
            const tid = try wire.number(args, "tid", null);
            const frame = try wire.number(args, "frame", 0);
            if (tid == 0 or tid > std.math.maxInt(i32) or frame >= 64) return error.InvalidArguments;
            observed = try answer.observed(a, session, analysis, @intCast(tid), @intCast(frame));
        }
        return out(a, .{ .status = "completed", .analysis = brief, .candidate = found[0], .slice = result, .observed_now = observed });
    }
    return out(a, .{ .status = "completed", .analysis = brief, .candidate = found[0], .controls = try answer.controls(a, session, analysis, chosen, limits) });
}

fn functionAddress(session: *Session, args: V) !?u64 {
    const address = try hex(args, "address");
    const symbol = try text(args, "symbol");
    if (address != null and symbol != null) return error.InvalidArguments;
    if (symbol) |s| {
        try session.refreshMaps();
        return (try session.modules.findSymbol(s)).address;
    }
    return address;
}

test "static starters require controller while cached reads remain observers" {
    const parsed = try std.json.parseFromSlice(V, std.testing.allocator, definitions, .{});
    defer parsed.deinit();
    for (parsed.value.array.items) |definition| {
        try std.testing.expect(handles(definition.object.get("name").?.string));
        const annotations = definition.object.get("annotations").?;
        try std.testing.expect(annotations.object.get("readOnlyHint").?.bool);
        const name = definition.object.get("name").?.string;
        const starter = std.mem.eql(u8, name, "analyze_function") or std.mem.eql(u8, name, "slice_value") or std.mem.eql(u8, name, "control_dependencies");
        try std.testing.expectEqualStrings(if (starter) "controller" else "observer", annotations.object.get("xodbSessionAccess").?.string);
    }
}
