const std = @import("std");
const Session = @import("../model/session.zig").Session;
const wire = @import("profile.zig");
const profiler = @import("../redot/profiler.zig");
const Value = std.json.Value;
pub fn handles(name: []const u8) bool {
    return std.mem.eql(u8, name, "set_redot_capture_status") or std.mem.eql(u8, name, "set_redot_profiling") or std.mem.eql(u8, name, "get_redot_profile") or std.mem.eql(u8, name, "capture_redot_sample");
}
fn value(a: std.mem.Allocator, data: anytype) !Value {
    return (try std.json.parseFromSlice(Value, a, try std.json.Stringify.valueAlloc(a, data, .{}), .{ .allocate = .alloc_always })).value;
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: Value) !Value {
    const state = &session.redot.profiler;
    if (std.mem.eql(u8, name, "set_redot_capture_status")) {
        try wire.fields(args, &.{ "phase", "completed", "total", "diagnostic", "generation" });
        try session.authorize(.agent, .execution, try wire.number(args, "generation", null));
        const phase_value = args.object.get("phase") orelse return error.InvalidArguments;
        if (phase_value != .string) return error.InvalidArguments;
        const phase = std.meta.stringToEnum(profiler.Capture.Phase, phase_value.string) orelse return error.InvalidArguments;
        const completed = try wire.number(args, "completed", 0);
        const total = try wire.number(args, "total", 0);
        if (completed > total or total > profiler.sample_limit) return error.InvalidArguments;
        const diagnostic = args.object.get("diagnostic") orelse Value{ .string = "" };
        if (diagnostic != .string) return error.InvalidArguments;
        state.capture.set(phase, @intCast(completed), @intCast(total), diagnostic.string);
        state.revision +%= 1;
        session.redot.revision +%= 1;
        session.record(.agent, "set_redot_capture_status");
        return value(a, .{ .phase = phase, .completed = completed, .total = total });
    }
    if (std.mem.eql(u8, name, "set_redot_profiling")) {
        try wire.fields(args, &.{ "enabled", "generation" });
        const enabled = args.object.get("enabled") orelse return error.InvalidArguments;
        if (enabled != .bool) return error.InvalidArguments;
        try session.authorize(.agent, .execution, try wire.number(args, "generation", null));
        try session.redot.profiling(enabled.bool);
        session.record(.agent, "set_redot_profiling");
        return value(a, .{ .enabled = state.enabled, .retained_frames = state.count });
    }
    if (std.mem.eql(u8, name, "capture_redot_sample")) {
        try wire.fields(args, &.{ "tid", "generation" });
        try session.target.expectGeneration(try wire.number(args, "generation", null));
        const tid = try wire.number(args, "tid", @intCast(@max(0, session.target.snapshot().pid)));
        if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
        return value(a, try @import("../redot/sampling.zig").capture(session, @intCast(tid)));
    }
    try wire.fields(args, &.{ "start", "limit", "frame_number" });
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 64);
    if (start > state.count or limit == 0 or limit > 256) return error.InvalidArguments;
    const end = @min(state.count, start + limit);
    const Summary = struct { number: u64, frame_ms: f64, process_ms: f64, physics_ms: f64, physics_step_ms: f64, script_ms: f64, functions: usize, samples: usize };
    const rows = try a.alloc(Summary, end - start);
    for (rows, @intCast(start)..) |*row, i| {
        const frame = state.at(i);
        var count: usize = 0;
        for (0..state.sample_count) |s| if (state.sampleAt(s).frame_number == frame.number) {
            count += 1;
        };
        row.* = .{ .number = frame.number, .frame_ms = frame.frame_ms, .process_ms = frame.process_ms, .physics_ms = frame.physics_ms, .physics_step_ms = frame.physics_step_ms, .script_ms = frame.script_ms, .functions = frame.functions.len, .samples = count };
    }
    const number = try wire.number(args, "frame_number", if (state.count > 0) state.at(state.count - 1).number else 0);
    const selected = state.find(number);
    var samples: std.ArrayList(profiler.Sample) = .empty;
    for (0..state.sample_count) |i| {
        const sample = state.sampleAt(i);
        if (sample.frame_number == number) try samples.append(a, sample.*);
    }
    const Cost = struct { object_id: []const u8, name: []const u8, script_path: []const u8, script_self_ms: f64, script_instances: usize, attribution: []const u8 };
    var costs: std.ArrayList(Cost) = .empty;
    var scripts: std.StringHashMapUnmanaged(struct { instances: usize = 0, ms: f64 = 0 }) = .empty;
    for (session.redot.nodes) |node| if (node.script_path) |path| {
        const entry = try scripts.getOrPut(a, path);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.instances += 1;
    };
    if (selected) |frame| for (frame.functions) |function| {
        if (profiler.scriptPath(function.signature)) |path| if (scripts.getPtr(path)) |entry| {
            entry.ms += function.self_ms;
        };
    };
    if (selected) |frame| for (session.redot.nodes) |node| {
        _ = frame;
        const script = node.script_path orelse continue;
        if (costs.items.len == 512) break;
        const cost = scripts.get(script).?;
        try costs.append(a, .{ .object_id = try std.fmt.allocPrint(a, "{d}", .{node.object_id}), .name = node.name, .script_path = script, .script_self_ms = cost.ms, .script_instances = cost.instances, .attribution = if (cost.instances == 1) "unique_script_in_retained_scene" else "shared_script_cost_not_per_instance" });
    };
    return value(a, .{ .source = "engine_debugger_protocol", .enabled = state.enabled, .state = session.redot.state, .diagnostic = session.redot.diagnostic, .revision = state.revision, .total = state.count, .dropped_frames = state.dropped, .start = start, .next = if (end < state.count) end else null, .frames = rows, .selected = selected, .node_costs = costs.items, .native_samples = samples.items, .retained_samples = state.sample_count, .native_basis = "Explicit stopped-memory samples joined by Engine process-frame counter; owner IDs and CallLevel/native-frame binding from DWARF. Stops perturb wall timings; no statistical per-node CPU estimate.", .timing_basis = "Engine per-process-frame seconds converted to milliseconds, physics time and physics step retained. Script self times include reported native calls; shared script costs are not per-instance costs." });
}
