//! An explicit stopped sample. Never interrupts or resumes a target itself.
const std = @import("std");
const model = @import("../model/session.zig");
const gdscript = @import("../language/gdscript.zig");
const profiler = @import("profiler.zig");

pub fn capture(session: *model.Session, tid: i32) !*const profiler.Sample {
    if (session.redot.state != .ready) return error.RedotDebuggerNotReady;
    const generation = session.target.snapshot().generation;
    const began = @import("../target/linux.zig").now();
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    const counters = try gdscript.frameCounters(&session.languageContext());
    const owned = try profiler.Owned(profiler.Sample).create();
    errdefer owned.destroy();
    const a = owned.arena.allocator();
    const native = try session.stack(a, tid, 64);
    const stack = try gdscript.stackWithNative(&session.languageContext(), a, tid, 0, native);
    const frames = try a.alloc(profiler.Native, native.len);
    for (native, frames) |frame, *out| out.* = .{
        .index = frame.index,
        .pc = try std.fmt.allocPrint(a, "0x{x}", .{frame.pc}),
        .symbol = if (frame.symbol) |s| try a.dupe(u8, s) else null,
        .display = if (frame.symbol) |s| try a.dupe(u8, try @import("../debug/demangle.zig").display(a, s)) else null,
    };
    var scripts: std.ArrayList(profiler.Script) = .empty;
    for (stack.segments) |segment| for (segment.frames) |frame| try scripts.append(a, .{
        .name = frame.name,
        .file = frame.file,
        .line = frame.line,
        .owner_id = if (frame.owner_id) |id| try std.fmt.allocPrint(a, "{d}", .{id}) else null,
        .native_frame = if (frame.native_binding) |binding| binding.frame else null,
        .reason = frame.reason orelse segment.reason,
    });
    try session.target.expectGeneration(generation);
    owned.data = .{ .frame_number = counters.process, .physics_frame = counters.physics, .in_physics = counters.in_physics, .generation = generation, .tid = tid, .captured_ns = began, .inspection_ns = @import("../target/linux.zig").now() -| began, .native = frames, .script = try scripts.toOwnedSlice(a) };
    session.redot.profiler.addSample(owned);
    session.redot.revision +%= 1;
    return &owned.data;
}
