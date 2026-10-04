//! Bounded coherent debugger view for a remote GUI. Source sharing is explicit.
const std = @import("std");
const c = @import("../c.zig").api;
const model = @import("../model/session.zig");
const wire = @import("../remote/view.zig");
const Value = std.json.Value;
const A = std.mem.Allocator;
fn number(args: Value, key: []const u8, default: u64) !u64 {
    const value = args.object.get(key) orelse return default;
    if (value != .integer or value.integer < 0) return error.InvalidArguments;
    return @intCast(value.integer);
}
pub fn handles(name: []const u8) bool {
    return std.mem.eql(u8, name, "get_debug_view") or std.mem.eql(u8, name, "detach");
}
pub fn call(a: A, session: *model.Session, name: []const u8, args: Value, source: ?[:0]const u8) !Value {
    if (args != .object) return error.InvalidArguments;
    const detach = std.mem.eql(u8, name, "detach");
    var fields = args.object.iterator();
    while (fields.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "generation")) continue;
        if (!detach and (std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "frame") or std.mem.eql(u8, key, "summary_only"))) continue;
        return error.InvalidArguments;
    }
    if (session.offline) return error.OfflineSession;
    if (detach) {
        if (args.object.get("generation") == null) return error.GenerationRequired;
        try session.authorize(.agent, .execution, try number(args, "generation", 0));
        session.cancelStep();
        try session.detach();
        session.record(.agent, "detach");
        return asValue(a, session.snapshot());
    }
    const generation = try number(args, "generation", session.target.generation);
    if (generation != session.target.generation) return error.StaleSnapshot;
    const frame_index = try number(args, "frame", 0);
    const tid_number = try number(args, "tid", 0);
    if (frame_index >= 64 or tid_number > std.math.maxInt(i32)) return error.InvalidArguments;
    var view = wire.View{ .session_id = session.id, .generation = generation, .pid = session.target.pid, .architecture = @tagName(@import("../target/arch.zig").native), .state = @tagName(session.target.state), .scope = @tagName(session.agent_scope), .owned = session.target.owned, .frame = @intCast(frame_index) };
    if (args.object.get("summary_only")) |summary| {
        if (summary != .bool) return error.InvalidArguments;
        if (summary.bool) return asValue(a, view);
    }
    const threads = session.target.threadSlice();
    var rows: std.ArrayList(wire.Thread) = .empty;
    for (threads[0..@min(threads.len, 256)]) |t| try rows.append(a, .{ .id = t.id, .tid = t.tid, .state = @tagName(t.state), .reason = @tagName(t.reason) });
    view.threads = rows.items;
    view.threads_truncated = rows.items.len != threads.len;
    view.tid = if (tid_number == 0) defaultThread(threads) else @intCast(tid_number);
    var diagnostics: std.ArrayList(wire.Diagnostic) = .empty;
    if (session.step_diagnostic) |d| try diagnostics.append(a, .{ .component = "step", .message = d });
    if (session.target.state == .stopped and view.tid != 0) {
        inspect(a, session, &view, &diagnostics) catch |err| try diagnostics.append(a, .{ .component = "inspection", .message = @errorName(err) });
        // Only a file explicitly supplied by the server operator is shared.
        if (source) |path| {
            view.source = readSource(a, path) catch |err| blk: {
                try diagnostics.append(a, .{ .component = "source", .message = @errorName(err) });
                break :blk null;
            };
        }
    }
    view.diagnostics = diagnostics.items;
    return asValue(a, view);
}
fn defaultThread(threads: []const @import("../target/linux.zig").Thread) i32 {
    // Peers interrupted for all-stop are inspection fallbacks. Follow the
    // thread that actually hit a probe, completed a step or received a signal.
    for (threads) |t| if (t.state == .stopped) switch (t.reason) {
        .breakpoint, .watchpoint, .single_step, .signal, .exec => return t.tid,
        else => {},
    };
    for (threads) |t| if (t.state == .stopped) return t.tid;
    return if (threads.len > 0) threads[0].tid else 0;
}
fn inspect(a: A, session: *model.Session, view: *wire.View, diagnostics: *std.ArrayList(wire.Diagnostic)) !void {
    view.watch_slots = session.target.watchpointCapacity() catch |err| blk: {
        try diagnostics.append(a, .{ .component = "watchpoints", .message = @errorName(err) });
        break :blk null;
    };
    view.watch_execute = @import("../target/linux.zig").architecture == .x86_64;
    var watches: std.ArrayList(wire.Watchpoint) = .empty;
    for (session.target.watchpoints) |maybe| if (maybe) |watch| {
        try watches.append(a, .{ .id = watch.id, .address = watch.address, .length = watch.length, .kind = @tagName(watch.kind) });
    };
    view.watchpoints = watches.items;
    var hits: std.ArrayList(wire.WatchHit) = .empty;
    const events = session.target.eventSlice();
    var index = events.len;
    var at_watch_stop = false;
    for (session.target.threadSlice()) |thread| if (thread.reason == .watchpoint) {
        at_watch_stop = true;
    };
    while (at_watch_stop and index > 0 and hits.items.len < 4) {
        index -= 1;
        const e = events[index];
        if (e.kind == .continued or e.kind == .image_replaced or e.kind == .watchpoint_removed or (hits.items.len > 0 and e.kind == .step_started)) break;
        if (e.kind != .watchpoint_hit) continue;
        try hits.append(a, .{ .tid = e.tid, .id = @intCast(e.detail), .address = e.address, .pc = e.pc, .trap_pc = e.trap_pc, .trap_address = e.trap_address, .before = if (e.before_valid) e.before else null, .after = if (e.after_valid) e.after else null, .phase = @tagName(e.watch_phase), .attribution = @tagName(e.watch_attribution) });
    }
    view.watch_hits = hits.items;
    const regs = try session.target.registers(view.tid);
    const register_rows = try a.alloc(wire.Register, @typeInfo(@TypeOf(regs)).@"struct".field_names.len);
    inline for (@typeInfo(@TypeOf(regs)).@"struct".field_names, 0..) |field, i| register_rows[i] = .{ .name = field, .value = @field(regs, field) };
    view.registers = register_rows;
    const frames = session.stack(a, view.tid, 64) catch |err| blk: {
        try diagnostics.append(a, .{ .component = "stack", .message = @errorName(err) });
        break :blk &.{};
    };
    const frame_rows = try a.alloc(wire.Frame, frames.len);
    for (frames, frame_rows) |frame, *row| row.* = .{ .index = frame.index, .pc = frame.lookup_pc, .symbol = frame.symbol, .source = if (frame.source) |s| .{ .path = s.path, .line = s.line } else null, .diagnostic = frame.diagnostic };
    view.frames = frame_rows;
    if (view.frame >= frames.len) view.frame = 0;
    const locals = session.locals(a, view.tid, view.frame) catch |err| blk: {
        try diagnostics.append(a, .{ .component = "locals", .message = @errorName(err) });
        break :blk &.{};
    };
    const local_rows = try a.alloc(wire.Local, @min(locals.len, 128));
    for (locals[0..local_rows.len], local_rows) |local, *row| {
        const summary = try session.summarize(a, local.value);
        row.* = .{ .name = local.name[0..@min(local.name.len, 256)], .type = summary.type[0..@min(summary.type.len, 256)], .display = summary.display[0..@min(summary.display.len, 1024)], .availability = @tagName(summary.availability), .address = summary.address, .size = summary.size };
    }
    view.locals = local_rows;
    view.locals_truncated = local_rows.len != locals.len;
    const pc = if (frames.len > 0) frames[view.frame].lookup_pc else @import("../target/linux.zig").programCounter(regs);
    var bytes: [256]u8 = undefined;
    var decoded: [32]@import("../model/disassembly.zig").Instruction = undefined;
    const n = try session.target.readMemory(pc, &bytes);
    const count = try @import("../model/disassembly.zig").decode(bytes[0..n], pc, &decoded);
    const instructions = try a.alloc(wire.Instruction, count);
    for (decoded[0..count], instructions) |inst, *row| row.* = .{ .address = inst.address, .mnemonic = try a.dupe(u8, std.mem.sliceTo(&inst.mnemonic, 0)), .operands = try a.dupe(u8, std.mem.sliceTo(&inst.operands, 0)) };
    view.instructions = instructions;
    var probes: std.ArrayList(wire.Breakpoint) = .empty;
    for (session.target.breakpoints[0..session.target.breakpoint_count]) |probe| {
        if (probe.temporary) continue;
        const site = session.sourceAt(a, probe.address) catch null;
        try probes.append(a, .{ .id = probe.id, .address = probe.address, .source = if (site) |s| .{ .path = s.path, .line = s.line } else null });
    }
    view.breakpoints = probes.items;
}
fn readSource(a: A, path: [:0]const u8) !wire.Source {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return error.SourceFileUnavailable;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG) return error.SourceMustBeRegularFile;
    const bytes = try a.alloc(u8, 48 * 1024);
    var used: usize = 0;
    while (used < bytes.len) {
        const n = c.read(fd, bytes[used..].ptr, bytes.len - used);
        if (n == 0) break;
        if (n < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return error.SourceReadFailed;
        }
        used += @intCast(n);
    }
    // A truncation may split the last UTF-8 character.
    if (used == bytes.len) while (used > 0 and !std.unicode.utf8ValidateSlice(bytes[0..used])) : (used -= 1) {
        if (bytes.len - used > 3) return error.SourceNotUtf8;
    };
    if (!std.unicode.utf8ValidateSlice(bytes[0..used])) return error.SourceNotUtf8;
    return .{ .path = path, .text = bytes[0..used], .truncated = st.st_size > used };
}
fn asValue(a: A, object: anytype) !Value {
    return (try std.json.parseFromSlice(Value, a, try std.json.Stringify.valueAlloc(a, object, .{}), .{ .allocate = .alloc_always })).value;
}

test "remote default follows a worker stop ahead of interrupted peers" {
    const Thread = @import("../target/linux.zig").Thread;
    var threads = [_]Thread{
        .{ .id = 1, .tid = 100, .state = .stopped, .reason = .interrupt },
        .{ .id = 2, .tid = 101, .state = .stopped, .reason = .breakpoint },
    };
    for ([_]@import("../target/breakpoints.zig").StopReason{ .breakpoint, .watchpoint, .single_step, .signal }) |reason| {
        threads[1].reason = reason;
        try std.testing.expectEqual(@as(i32, 101), defaultThread(&threads));
    }
    threads[1].reason = .interrupt;
    try std.testing.expectEqual(@as(i32, 100), defaultThread(&threads));
    threads[0].state = .exited;
    try std.testing.expectEqual(@as(i32, 101), defaultThread(&threads));
    try std.testing.expectEqual(@as(i32, 0), defaultThread(&.{}));
}
