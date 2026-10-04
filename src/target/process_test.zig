const std = @import("std");
const linux = @import("linux.zig");
const c = @import("../c.zig").api;
const Modules = @import("../model/modules.zig").Modules;
const bp = @import("breakpoints.zig");
fn fixture() [:0]const u8 {
    return if (c.getenv("XODB_PROCESS_FIXTURE")) |path| std.mem.span(path) else "./zig-out/bin/xodb-process-fixture";
}
fn create() !*linux.Target {
    const target = try std.testing.allocator.create(linux.Target);
    target.* = .{};
    return target;
}
fn destroy(target: *linux.Target) void {
    target.deinit();
    std.testing.allocator.destroy(target);
}
fn waitBirth(parent: *linux.Target) !linux.Birth {
    const deadline = linux.now() + 3_000_000_000;
    while (linux.now() < deadline) {
        try parent.poll();
        if (parent.state == .stopped and parent.birth_count > 0 and parent.births[0].stopped) return parent.births[0];
        _ = c.usleep(1000);
    }
    return error.ChildBirthTimeout;
}
fn toExit(target: *linux.Target) !void {
    const deadline = linux.now() + 3_000_000_000;
    while (linux.now() < deadline) {
        try target.poll();
        if (target.state == .exited) {
            for (target.eventSlice()) |event| if (event.kind == .exit and event.tid == target.pid) {
                try std.testing.expectEqual(@as(i64, 0), event.detail);
                return;
            };
            return error.ExitStatusMissing;
        }
        if (target.state == .stopped) try target.continueExecution();
        _ = c.usleep(1000);
    }
    return error.ChildExitTimeout;
}
fn rawByte(tid: i32, address: u64) !u8 {
    std.c._errno().* = 0;
    const word = c.ptrace(c.PTRACE_PEEKTEXT, tid, address, @as(usize, 0));
    if (word == -1 and std.c._errno().* != 0) return error.PeekFailed;
    return @truncate(@as(u64, @bitCast(@as(i64, word))));
}
fn setup(parent: *linux.Target, modules: *Modules, mode: [:0]const u8) !u64 {
    try parent.launch(&.{ fixture(), mode });
    try parent.setFollowProcesses(true);
    try modules.refresh(parent.pid);
    const child = (try modules.findSymbol("tree_child")).address;
    _ = try parent.setBreakpoint(child, false);
    try parent.continueExecution();
    return child;
}

test "fork child inherits a breakpoint, independent patching, execution and cleanup" {
    try @import("../test_support.zig").requireLive();
    if (linux.architecture != .x86_64) return error.SkipZigTest;
    const parent = try create();
    defer destroy(parent);
    const child = try create();
    defer destroy(child);
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    const address = try setup(parent, &modules, "fork");
    const birth = try waitBirth(parent);
    try std.testing.expectEqual(linux.BirthKind.fork, birth.kind);
    try std.testing.expectError(error.ProcessBirthPending, parent.continueExecution());
    _ = try parent.adoptChild(birth.pid, child);
    try std.testing.expectEqual(@as(u8, 0xcc), try rawByte(child.pid, address));
    try child.continueExecution();
    try child.waitStopped();
    try std.testing.expectEqual(bp.StopReason.breakpoint, child.threads[0].reason);
    try child.removeBreakpoint(child.breakpoints[0].id);
    try std.testing.expectEqual(@as(u8, 0xcc), try rawByte(parent.pid, address));
    try std.testing.expect((try rawByte(child.pid, address)) != 0xcc);
    try toExit(child);
    try toExit(parent);
    try std.testing.expectEqual(@as(usize, 0), parent.birth_count);
}

test "vfork inherited trap step preserves parent's bytes and blocks independent mutation" {
    try @import("../test_support.zig").requireLive();
    if (linux.architecture != .x86_64) return error.SkipZigTest;
    for ([_][:0]const u8{ "vfork", "vfork-exec" }) |mode| {
        const parent = try create();
        defer destroy(parent);
        const child = try create();
        defer destroy(child);
        var modules = Modules.init(std.testing.allocator);
        defer modules.deinit();
        const address = try setup(parent, &modules, mode);
        const birth = try waitBirth(parent);
        _ = try parent.adoptChild(birth.pid, child);
        try std.testing.expect(parent.sharedVm() and child.sharedVm());
        try std.testing.expectError(error.VforkParentBlocked, parent.continueExecution());
        try std.testing.expectError(error.SharedAddressSpace, child.removeBreakpoint(child.breakpoints[0].id));
        try child.continueExecution();
        try child.waitStopped();
        try std.testing.expectEqual(bp.StopReason.breakpoint, child.threads[0].reason);
        try child.singleStep(child.pid);
        try child.waitStopped();
        try std.testing.expectEqual(@as(u8, 0xcc), try rawByte(parent.pid, address));
        try std.testing.expect(parent.breakpoints[0].patched and child.breakpoints[0].patched);
        try toExit(child);
        try std.testing.expect(!parent.sharedVm() and !child.sharedVm());
        try std.testing.expectEqual(@as(u8, 0xcc), try rawByte(parent.pid, address));
        try toExit(parent);
    }
}

test "fork during breakpoint stepping repairs the child's inherited unpatched instruction" {
    try @import("../test_support.zig").requireLive();
    if (linux.architecture != .x86_64) return error.SkipZigTest;
    const parent = try create();
    defer destroy(parent);
    const child = try create();
    defer destroy(child);
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    try parent.launch(&.{ fixture(), "step" });
    try parent.setFollowProcesses(true);
    try modules.refresh(parent.pid);
    const site = (try modules.findSymbol("tree_fork_instruction")).address;
    _ = try parent.setBreakpoint(site, false);
    try parent.continueExecution();
    try parent.waitStopped();
    try std.testing.expectEqual(bp.StopReason.breakpoint, parent.threads[0].reason);
    try parent.singleStep(parent.pid);
    const birth = try waitBirth(parent);
    try std.testing.expect(birth.unpatched_probe != null);
    _ = try parent.adoptChild(birth.pid, child);
    try std.testing.expectEqual(@as(u8, 0x0f), try rawByte(child.pid, site));
    try child.singleStep(child.pid);
    try child.waitStopped();
    try std.testing.expectEqual(@as(u8, 0xcc), try rawByte(child.pid, site));
    try toExit(child);
    try toExit(parent);
}

test "owned shutdown reaps an unadopted fork or vfork child" {
    try @import("../test_support.zig").requireLive();
    if (linux.architecture != .x86_64) return error.SkipZigTest;
    for ([_][:0]const u8{ "fork", "vfork" }) |mode| {
        const parent = try create();
        defer destroy(parent);
        var modules = Modules.init(std.testing.allocator);
        defer modules.deinit();
        _ = try setup(parent, &modules, mode);
        const birth = try waitBirth(parent);
        parent.deinit();
        var status: c_int = 0;
        try std.testing.expectEqual(@as(i32, -1), c.waitpid(birth.pid, &status, c.__WALL | c.WNOHANG));
        try std.testing.expectEqual(@as(c_int, c.ECHILD), std.c._errno().*);
    }
}

test "coordinated detach restores vfork traps before either member runs" {
    try @import("../test_support.zig").requireLive();
    if (linux.architecture != .x86_64) return error.SkipZigTest;
    const parent = try create();
    defer destroy(parent);
    const child = try create();
    defer destroy(child);
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    _ = try setup(parent, &modules, "vfork");
    const birth = try waitBirth(parent);
    const pid = parent.pid;
    _ = try parent.adoptChild(birth.pid, child);
    try child.detachProcessFamily();
    try std.testing.expectEqual(@as(i32, 0), parent.pid);
    try std.testing.expectEqual(@as(i32, 0), child.pid);
    var status: c_int = 0;
    const deadline = linux.now() + 3_000_000_000;
    while (c.waitpid(pid, &status, c.WNOHANG) == 0) {
        if (linux.now() >= deadline) {
            _ = c.kill(pid, c.SIGKILL);
            _ = c.waitpid(pid, &status, 0);
            return error.DetachedExitTimeout;
        }
        _ = c.usleep(1000);
    }
    try std.testing.expect(c.WIFEXITED(status));
    try std.testing.expectEqual(@as(i32, 0), c.WEXITSTATUS(status));
}

test "fork hardware watches are programmed independently and detach restores them" {
    try @import("../test_support.zig").requireLive();
    if (linux.architecture != .x86_64) return error.SkipZigTest;
    const parent = try create();
    defer destroy(parent);
    const child = try create();
    defer destroy(child);
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    try parent.launch(&.{ fixture(), "fork" });
    try parent.setFollowProcesses(true);
    try modules.refresh(parent.pid);
    const watched = (try modules.findSymbol("tree_value")).address;
    _ = try parent.setWatchpoint(watched, 4, .write);
    try parent.continueExecution();
    const birth = try waitBirth(parent);
    _ = try parent.adoptChild(birth.pid, child);
    try child.continueExecution();
    try child.waitStopped();
    try std.testing.expectEqual(bp.StopReason.watchpoint, child.threads[0].reason);
    try child.detach();
    // A second write after detach would SIGTRAP if xodb's DR7 were retained.
    try toExit(parent);
}

test "detach releases unadopted fork and vfork with original bytes restored" {
    try @import("../test_support.zig").requireLive();
    if (linux.architecture != .x86_64) return error.SkipZigTest;
    for ([_][:0]const u8{ "fork", "vfork" }) |mode| {
        const parent = try create();
        defer destroy(parent);
        var modules = Modules.init(std.testing.allocator);
        defer modules.deinit();
        _ = try setup(parent, &modules, mode);
        _ = try waitBirth(parent);
        const pid = parent.pid;
        try parent.detachProcessFamily();
        var status: c_int = 0;
        const deadline = linux.now() + 3_000_000_000;
        while (c.waitpid(pid, &status, c.WNOHANG) == 0) {
            if (linux.now() >= deadline) {
                _ = c.kill(pid, c.SIGKILL);
                _ = c.waitpid(pid, &status, 0);
                return error.DetachedExitTimeout;
            }
            _ = c.usleep(1000);
        }
        try std.testing.expect(c.WIFEXITED(status));
        try std.testing.expectEqual(@as(i32, 0), c.WEXITSTATUS(status));
    }
}

test "fork event with shared CLONE_VM is held, identified and safely detached" {
    try @import("../test_support.zig").requireLive();
    if (linux.architecture != .x86_64) return error.SkipZigTest;
    const parent = try create();
    defer destroy(parent);
    const child = try create();
    defer destroy(child);
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    _ = try setup(parent, &modules, "clone-vm");
    const birth = try waitBirth(parent);
    try std.testing.expectEqual(linux.BirthKind.fork, birth.kind);
    try std.testing.expectError(error.SharedCloneRequiresCoordination, parent.adoptChild(birth.pid, child));
    try std.testing.expectEqual(@as(i32, 0), child.pid);
    try std.testing.expectEqual(@as(usize, 1), parent.birth_count);
    const pid = parent.pid;
    try parent.detachProcessFamily();
    var status: c_int = 0;
    const deadline = linux.now() + 3_000_000_000;
    while (c.waitpid(pid, &status, c.WNOHANG) == 0) {
        if (linux.now() >= deadline) {
            _ = c.kill(pid, c.SIGKILL);
            _ = c.waitpid(pid, &status, 0);
            return error.DetachedExitTimeout;
        }
        _ = c.usleep(1000);
    }
    try std.testing.expect(c.WIFEXITED(status));
    try std.testing.expectEqual(@as(i32, 0), c.WEXITSTATUS(status));
}

test "partial family detach blocks resume until trap restoration can complete" {
    try @import("../test_support.zig").requireLive();
    if (linux.architecture != .x86_64) return error.SkipZigTest;
    const parent = try create();
    defer destroy(parent);
    const child = try create();
    defer destroy(child);
    var modules = Modules.init(std.testing.allocator);
    defer modules.deinit();
    try parent.launch(&.{ fixture(), "vfork" });
    try parent.setFollowProcesses(true);
    try modules.refresh(parent.pid);
    const address = (try modules.findSymbol("tree_child")).address;
    _ = try parent.setBreakpoint(address, false);
    _ = try parent.setBreakpoint((try modules.findSymbol("tree_ready")).address, false);
    try parent.continueExecution();
    try parent.waitStopped();
    try parent.continueExecution();
    const birth = try waitBirth(parent);
    _ = try parent.adoptChild(birth.pid, child);
    const saved = parent.breakpoints[1].address;
    parent.breakpoints[1].address = 1; // Inject a failed restoration after the first byte was restored.
    try std.testing.expectError(error.MemoryUnreadable, child.detachProcessFamily());
    try std.testing.expect((try rawByte(child.pid, address)) != 0xcc);
    try std.testing.expectError(error.DetachIncomplete, child.continueExecution());
    try std.testing.expectError(error.DetachIncomplete, parent.continueExecution());
    parent.breakpoints[1].address = saved;
    const pid = parent.pid;
    try parent.detachProcessFamily();
    var status: c_int = 0;
    const deadline = linux.now() + 3_000_000_000;
    while (c.waitpid(pid, &status, c.WNOHANG) == 0) {
        if (linux.now() >= deadline) {
            _ = c.kill(pid, c.SIGKILL);
            _ = c.waitpid(pid, &status, 0);
            return error.DetachedExitTimeout;
        }
        _ = c.usleep(1000);
    }
    try std.testing.expect(c.WIFEXITED(status));
    try std.testing.expectEqual(@as(i32, 0), c.WEXITSTATUS(status));
}
