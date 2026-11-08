//! Bounded, owner-prepared kernel inventory. Drawing never reads a target.
const std = @import("std");
const inventory = @import("kernel_aware.zig");
const modules = @import("modules.zig");
const redact = @import("../redact.zig");
const Allocator = std.mem.Allocator;
pub const Section = enum { tasks, cpus, modules, waits };
pub const max_tasks = 4096;
pub const max_modules = 576;
pub const max_cpus = 4096;
pub const max_waits = 256;
pub const Task = struct { pid: i32, tid: ?i32, name: []const u8, state: ?u32, cpu: ?u32, address: []const u8 };
pub const Cpu = struct { cpu: usize, current_task: ?[]const u8, pid: ?i32, name: []const u8 };
pub const Module = struct { name: []const u8, start: []const u8, end: []const u8, status: enum { loaded, load_failure }, reason: ?[]const u8 = null, detail: ?[]const u8 = null };
pub const Wait = struct { pid: i32, name: []const u8, hops: []const inventory.WaitHop, end: inventory.ChainEnd };
pub const View = struct {
    enabled: bool = false,
    prepared: bool = false,
    generation: u64 = 0,
    reason: ?[]const u8 = null,
    truncated: bool = false,
    tasks: []const Task = &.{},
    cpus: []const Cpu = &.{},
    modules: []const Module = &.{},
    waits: []const Wait = &.{},
    pub fn count(self: View, section: Section) usize {
        return switch (section) {
            .tasks => self.tasks.len,
            .cpus => self.cpus.len,
            .modules => self.modules.len,
            .waits => self.waits.len,
        };
    }
};

fn clean(a: Allocator, text: []const u8) ![]const u8 {
    if (redact.active()) |policy| return policy.scrubAlloc(a, text);
    return a.dupe(u8, text);
}
fn hex(a: Allocator, address: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "0x{x}", .{address});
}
pub fn capture(a: Allocator, session: anytype, wanted: bool) !View {
    const snapshot = session.target.snapshot();
    if (wanted and session.modules.measure_kernel_slide and snapshot.state == .stopped)
        _ = session.modules.kernelTaskRows();
    return collect(a, &session.modules, session.target.threadSlice(), snapshot.generation, snapshot.state == .stopped, wanted);
}
fn collect(a: Allocator, source: *const modules.Modules, threads: anytype, generation: u64, stopped: bool, wanted: bool) !View {
    var view: View = .{ .enabled = source.measure_kernel_slide, .generation = generation };
    if (!wanted or !view.enabled) return view;
    view.prepared = true;
    if (!stopped) {
        view.reason = "TargetRunning";
        return view;
    }
    if (source.kernel_note_len > 0) view.reason = try clean(a, source.kernel_note[0..source.kernel_note_len]);
    const tasks = source.kernel_tasks[0..@min(source.kernel_tasks.len, max_tasks)];
    view.truncated = tasks.len != source.kernel_tasks.len;
    var task_rows: std.ArrayList(Task) = .empty;
    var wait_rows: std.ArrayList(Wait) = .empty;
    for (tasks) |task| {
        const name = try clean(a, task.comm[0..task.comm_len]);
        try task_rows.append(a, .{ .pid = task.pid, .tid = source.taskTid(task, threads), .name = name, .state = task.state, .cpu = task.cpu, .address = try hex(a, task.address) });
        var hops: [4]inventory.WaitHop = undefined;
        var end: inventory.ChainEnd = .complete;
        const count = inventory.chainHopsEnd(source.kernel_waits, source.kernel_tasks, task.address, &hops, &end);
        if (count > 0) {
            if (wait_rows.items.len == max_waits) {
                view.truncated = true;
                continue;
            }
            // Names inside the fixed-size hop representation obey the same policy.
            if (redact.active()) |policy| for (hops[0..count]) |*hop| policy.mask(hop.owner[0..hop.owner_len]);
            try wait_rows.append(a, .{ .pid = task.pid, .name = name, .hops = try a.dupe(inventory.WaitHop, hops[0..count]), .end = end });
        }
    }
    view.tasks = task_rows.items;
    view.waits = wait_rows.items;
    var cpus: std.ArrayList(Cpu) = .empty;
    var cpu_count: usize = @min(source.kernel_current.len, max_cpus);
    for (tasks) |task| if (task.cpu) |cpu| {
        if (cpu >= max_cpus) view.truncated = true else cpu_count = @max(cpu_count, @as(usize, cpu) + 1);
    };
    for (0..cpu_count) |cpu| {
        const current = if (cpu < source.kernel_current.len) source.kernel_current[cpu] else 0;
        var observed = false;
        var row: Cpu = .{ .cpu = cpu, .current_task = null, .pid = null, .name = "unresolved current task" };
        for (tasks) |task| {
            if (task.cpu == @as(u32, @intCast(cpu))) observed = true;
            if (current != 0 and task.address == current) {
                observed = true;
                row.pid = task.pid;
                row.name = try clean(a, task.comm[0..task.comm_len]);
                break;
            }
        }
        // Possible-CPU storage includes uninitialized/offline slots. A nonzero
        // word alone (often poison) is not evidence of another CPU. Task CPU
        // assignments also provide rows on kernels without current_task.
        if (!observed) continue;
        if (current != 0) row.current_task = try hex(a, current);
        try cpus.append(a, row);
    }
    view.cpus = cpus.items;
    if (source.kernel_current.len > max_cpus) view.truncated = true;
    var images: std.ArrayList(Module) = .empty;
    for (source.loaded.items) |module| {
        if (!module.kernel) continue;
        if (images.items.len == max_modules) {
            view.truncated = true;
            break;
        }
        try images.append(a, .{ .name = try clean(a, std.fs.path.basename(module.path)), .start = try hex(a, module.start), .end = try hex(a, module.end), .status = .loaded });
    }
    for (source.load_failures.items) |failure| {
        if (images.items.len == max_modules) {
            view.truncated = true;
            break;
        }
        try images.append(a, .{ .name = try clean(a, std.fs.path.basename(failure.path)), .start = try hex(a, failure.start), .end = try hex(a, failure.end), .status = .load_failure, .reason = try clean(a, failure.diagnostic), .detail = if (failure.detail) |detail| try clean(a, detail) else null });
    }
    view.modules = images.items;
    return view;
}

test "closed kernel view is lazy; open view preserves task fields and module refusals" {
    const a = std.testing.allocator;
    var source = modules.Modules.init(a);
    defer source.deinit();
    source.measure_kernel_slide = true;
    source.kernel_tasks = try a.dupe(inventory.TaskRow, &.{.{ .address = 0x1000, .pid = 7, .comm = "owned-task".* ++ @as([6]u8, @splat(0)), .comm_len = 10, .state = 2, .cpu = 3 }});
    source.kernel_current = try a.dupe(u64, &.{ 0, 0, 0, 0x1000, 0xcccccccccccccccc });
    try source.load_failures.append(a, .{ .start = 0x2000, .end = 0x3000, .path = try a.dupe(u8, "kernel/owned.ko"), .diagnostic = "KernelModuleUnverified" });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const closed = try collect(arena.allocator(), &source, &[_]struct { tid: i32 }{}, 4, true, false);
    try std.testing.expect(closed.enabled and closed.tasks.len == 0 and closed.modules.len == 0);
    try std.testing.expectEqual(@as(usize, 0), arena.queryCapacity());
    const open = try collect(arena.allocator(), &source, &[_]struct { tid: i32 }{}, 4, true, true);
    try std.testing.expectEqual(@as(?u32, 2), open.tasks[0].state);
    try std.testing.expectEqual(@as(?u32, 3), open.tasks[0].cpu);
    try std.testing.expectEqual(@as(?i32, 7), open.cpus[0].pid);
    try std.testing.expectEqual(@as(usize, 1), open.cpus.len);
    try std.testing.expectEqualStrings("KernelModuleUnverified", open.modules[0].reason.?);
    const running = try collect(arena.allocator(), &source, &[_]struct { tid: i32 }{}, 5, false, true);
    try std.testing.expectEqualStrings("TargetRunning", running.reason.?);
    try std.testing.expectEqual(@as(usize, 0), running.tasks.len);
    source.kernel_current[3] = 0;
    const without_current = try collect(arena.allocator(), &source, &[_]struct { tid: i32 }{}, 4, true, true);
    try std.testing.expectEqual(@as(usize, 1), without_current.cpus.len);
    try std.testing.expectEqual(@as(usize, 3), without_current.cpus[0].cpu);
    try std.testing.expect(without_current.cpus[0].current_task == null);
}

test "kernel inventory caps report truncation and preserve the last fitting row" {
    const a = std.testing.allocator;
    var source = modules.Modules.init(a);
    defer source.deinit();
    source.measure_kernel_slide = true;
    source.kernel_tasks = try a.alloc(inventory.TaskRow, max_tasks + 1);
    @memset(source.kernel_tasks, .{ .address = 0x1000, .pid = 7, .comm = @splat(0), .comm_len = 0 });
    source.kernel_current = try a.alloc(u64, max_cpus + 1);
    @memset(source.kernel_current, 0x1000);
    for (0..max_modules + 1) |_| try source.load_failures.append(a, .{ .start = 0x2000, .end = 0x3000, .path = try a.dupe(u8, "owned.ko"), .diagnostic = "KernelModuleUnverified" });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const view = try collect(arena.allocator(), &source, &[_]struct { tid: i32 }{}, 1, true, true);
    try std.testing.expect(view.truncated);
    try std.testing.expectEqual(@as(usize, max_tasks), view.tasks.len);
    try std.testing.expectEqual(@as(usize, max_cpus), view.cpus.len);
    try std.testing.expectEqual(@as(usize, max_modules), view.modules.len);
    try std.testing.expectEqualStrings("KernelModuleUnverified", view.modules[max_modules - 1].reason.?);
}
