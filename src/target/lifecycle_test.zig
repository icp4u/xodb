const std = @import("std");
const c = @import("../c.zig").api;
const linux = @import("linux.zig");
const Session = @import("../model/session.zig").Session;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const fixture = "./zig-out/bin/xodb-lifecycle-fixture";

fn killReap(pid: c.pid_t) void {
    var status: c_int = 0;
    const ready = c.waitpid(pid, &status, c.WNOHANG | c.__WALL);
    if (ready < 0 or (ready > 0 and (c.WIFEXITED(status) or c.WIFSIGNALED(status)))) return;
    _ = c.kill(pid, c.SIGKILL);
    while (c.waitpid(pid, &status, c.__WALL) > 0) {
        if (c.WIFEXITED(status) or c.WIFSIGNALED(status)) break;
        _ = c.ptrace(c.PTRACE_CONT, pid, @as(usize, 0), @as(usize, c.SIGKILL));
    }
}
fn taskState(pid: c.pid_t) u8 {
    var path: [128]u8 = undefined;
    const name = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{pid}) catch return 0;
    const fd = c.open(name, c.O_RDONLY);
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    var bytes: [4096]u8 = undefined;
    const n = c.read(fd, &bytes, bytes.len);
    if (n <= 0) return 0;
    const end = std.mem.lastIndexOfScalar(u8, bytes[0..@intCast(n)], ')') orelse return 0;
    return if (end + 2 < n) bytes[end + 2] else 0;
}
fn waitExit(target: *linux.Target) !void {
    const deadline = linux.now() + 2_000_000_000;
    while (target.state != .exited and linux.now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try equal(linux.State.exited, target.state);
}

test "lifecycle: polling does not consume unrelated child exits" {
    try @import("../test_support.zig").requireLive();
    const foreign = c.fork();
    if (foreign == 0) c._exit(42);
    try expect(foreign > 0);
    defer killReap(foreign);
    var target = linux.Target{};
    defer target.deinit();
    try target.launch(&.{ fixture, "exit" });
    try target.continueExecution();
    try waitExit(&target);
    try target.poll();
    try equal(@as(i64, 23), target.eventSlice()[target.event_count - 1].detail);
    var status: c_int = 0;
    try equal(foreign, c.waitpid(foreign, &status, 0));
    try expect(c.WIFEXITED(status));
    try equal(@as(c_int, 42), c.WEXITSTATUS(status));
}

test "lifecycle: polling and cleanup leave foreign trace stops untouched" {
    try @import("../test_support.zig").requireLive();
    for ([_]bool{ false, true }) |cleanup| {
        var target = linux.Target{};
        defer target.deinit();
        try target.launch(&.{ fixture, "sleep" });
        try target.continueExecution();
        const foreign = c.fork();
        if (foreign == 0) {
            if (c.ptrace(c.PTRACE_TRACEME, @as(c_int, 0), @as(usize, 0), @as(usize, 0)) < 0) c._exit(125);
            _ = c.raise(c.SIGSTOP);
            c._exit(37);
        }
        try expect(foreign > 0);
        defer killReap(foreign);
        const deadline = linux.now() + 2_000_000_000;
        while (taskState(foreign) != 't' and linux.now() < deadline) _ = c.usleep(1000);
        try equal(@as(u8, 't'), taskState(foreign));
        if (cleanup) target.deinit() else try target.poll();
        try equal(@as(u8, 't'), taskState(foreign));
        for (target.threadSlice()) |t| try expect(t.tid != foreign);
        var status: c_int = 0;
        try equal(foreign, c.waitpid(foreign, &status, c.__WALL | c.WNOHANG));
        try expect(c.WIFSTOPPED(status));
        try equal(@as(c_int, c.SIGSTOP), c.WSTOPSIG(status));
    }
}

test "lifecycle: exited leader permits worker memory, maps, watchpoints and detach" {
    try @import("../test_support.zig").requireLive();
    var name: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&name, ".work/leader-exit-{d}-{d}.txt", .{ c.getpid(), linux.now() });
    defer _ = c.unlink(path);
    var session = Session.init();
    defer session.deinit();
    const target = &session.target;
    try target.launch(&.{ fixture, "leader-exit", path });
    const pid = target.pid;
    defer killReap(pid);
    try target.continueExecution();
    const deadline = linux.now() + 2_000_000_000;
    var leader_exited = false;
    while (!leader_exited and linux.now() < deadline) {
        try target.poll();
        for (target.threadSlice()) |t| if (t.tid == pid and t.state == .exited) {
            leader_exited = true;
        };
        _ = c.usleep(1000);
    }
    try expect(leader_exited);
    try target.interrupt();
    try target.waitStopped();
    try equal(linux.State.stopped, target.state);
    const worker = try target.stoppedTid();
    try expect(worker != pid);
    try expect((try target.registers(worker)).rip != 0);
    try session.refreshMaps();
    const symbol = try session.modules.findSymbol("xodb_marker");
    var bytes: [8]u8 = undefined;
    try equal(@as(usize, 8), try target.readMemory(symbol.address, &bytes));
    try equal(@as(u64, 0x1122334455667788), std.mem.readInt(u64, &bytes, .little));
    const watch = try target.setWatchpoint(symbol.address, 8, .write);
    try target.removeWatchpoint(watch);
    try target.continueExecution();
    try target.interrupt();
    try target.waitStopped();
    try target.detach();
    try equal(linux.State.idle, target.state);
    try equal(@as(c_int, 0), c.kill(pid, 0));
    _ = c.kill(pid, c.SIGKILL);
    const reap_deadline = linux.now() + 2_000_000_000;
    while (target.reap_count > 0 and linux.now() < reap_deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try equal(@as(usize, 0), target.reap_count);
}

test "lifecycle: nonleader exec retains only renamed survivor" {
    try @import("../test_support.zig").requireLive();
    var target = linux.Target{};
    defer target.deinit();
    try target.launch(&.{ fixture, "nonleader-exec" });
    const epoch = target.image_epoch;
    try target.continueExecution();
    const deadline = linux.now() + 2_000_000_000;
    while (target.image_epoch == epoch and linux.now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try equal(epoch + 1, target.image_epoch);
    try equal(@as(usize, 1), target.thread_count);
    try equal(target.pid, target.threads[0].tid);
    try expect(target.threads[0].id > 1);
    try equal(linux.State.stopped, target.state);
    _ = try target.registers(target.pid);
    try target.continueExecution();
    try target.interrupt();
    try target.waitStopped();
}

test "lifecycle: detached owned child is reaped without target events" {
    try @import("../test_support.zig").requireLive();
    var target = linux.Target{};
    defer target.deinit();
    try target.launch(&.{ fixture, "exit-soon" });
    const pid = target.pid;
    defer killReap(pid);
    try target.detach();
    const sequence = target.sequence;
    const deadline = linux.now() + 2_000_000_000;
    while (target.reap_count > 0 and linux.now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try equal(@as(usize, 0), target.reap_count);
    try equal(sequence, target.sequence);
    try equal(linux.State.idle, target.state);
    var status: c_int = 0;
    try equal(@as(c.pid_t, -1), c.waitpid(pid, &status, c.WNOHANG));
    try equal(@as(c_int, c.ECHILD), std.c._errno().*);
}

test "lifecycle: attaching after leader exit inspects surviving workers" {
    try @import("../test_support.zig").requireLive();
    var name: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&name, ".work/attach-leader-{d}-{d}.txt", .{ c.getpid(), linux.now() });
    defer _ = c.unlink(path);
    const pid = c.fork();
    if (pid == 0) {
        _ = c.execl(fixture, fixture, "leader-exit", path.ptr, @as(?[*:0]const u8, null));
        c._exit(127);
    }
    try expect(pid > 0);
    defer killReap(pid);
    const deadline = linux.now() + 2_000_000_000;
    while (taskState(pid) != 'Z' and linux.now() < deadline) _ = c.usleep(1000);
    try equal(@as(u8, 'Z'), taskState(pid));
    var target = linux.Target{};
    defer target.deinit();
    try target.attach(pid);
    try equal(linux.State.stopped, target.state);
    const worker = try target.stoppedTid();
    try expect(worker != pid);
    const regs = try target.registers(worker);
    var bytes: [8]u8 = undefined;
    try equal(@as(usize, 8), try target.readMemory(regs.rip, &bytes));
    try target.continueExecution();
    try target.interrupt();
    try target.waitStopped();
    try target.detach();
}

test "lifecycle: attach during thread creation covers every surviving task" {
    try @import("../test_support.zig").requireLive();
    for (0..20) |_| {
        const pid = c.fork();
        if (pid == 0) {
            _ = c.execl(fixture, fixture, "burst", @as(?[*:0]const u8, null));
            c._exit(127);
        }
        try expect(pid > 0);
        defer killReap(pid);
        _ = c.usleep(2000);
        var target = linux.Target{};
        defer target.deinit();
        try target.attach(pid);
        try equal(linux.State.stopped, target.state);
        var buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&buf, "/proc/{d}/task", .{pid});
        const dir = c.opendir(path) orelse return error.ProcessGone;
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |entry| {
            const name_buf = entry.*.d_name;
            const tid = std.fmt.parseInt(c.pid_t, std.mem.sliceTo(&name_buf, 0), 10) catch continue;
            var found = false;
            for (target.threadSlice()) |thread| if (thread.tid == tid) {
                found = true;
                try expect(thread.state == .stopped or thread.state == .exited);
            };
            try expect(found);
        }
        try target.detach();
    }
}
