const std = @import("std");
const perf = @import("perf");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
    @cInclude("dirent.h");
    @cInclude("linux/perf_event.h");
    @cInclude("asm/perf_regs.h");
});
const gprs: u64 = 0x1ff | (0xff << 16);
fn now() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
fn fds() usize {
    const dir = c.opendir("/proc/self/fd") orelse unreachable;
    defer _ = c.closedir(dir);
    var n: usize = 0;
    while (c.readdir(dir)) |_| n += 1;
    return n;
}
fn open(config: perf.Config) !*perf.Collector {
    return switch (try perf.start(std.testing.allocator, config)) {
        .collector => |collector| collector,
        .failed => |failure| {
            std.debug.print("open failure: kind={s} syscall={s} errno={d} detail={s}\n", .{ @tagName(failure.kind), failure.syscall, failure.errno, failure.detail });
            return error.CollectorOpenFailed;
        },
    };
}
fn check(stack_bytes: u32) !void {
    const fd_before = fds();
    {
        var gate: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.pipe2(&gate, c.O_CLOEXEC));
        const child = c.fork();
        if (child < 0) {
            _ = c.close(gate[0]);
            _ = c.close(gate[1]);
            return error.ForkFailed;
        }
        if (child == 0) {
            _ = c.close(gate[1]);
            var token: u8 = 0;
            if (c.read(gate[0], &token, 1) != 1) c._exit(2);
            _ = c.close(gate[0]);
            const until = now() + 2_000_000_000;
            while (now() < until) {
                for (0..10000) |_| asm volatile ("" ::: .{ .memory = true });
            }
            c._exit(0);
        }
        _ = c.close(gate[0]);
        defer _ = c.close(gate[1]);
        defer {
            _ = c.kill(child, c.SIGKILL);
            var status: c_int = 0;
            _ = c.waitpid(child, &status, 0);
        }
        const mask: u64 = if (stack_bytes == 0) 0 else gprs;
        const collector = try open(.{ .tids = &.{child}, .frequency_hz = 997, .data_pages = 64, .user_regs_mask = mask, .user_stack_bytes = stack_bytes });
        defer collector.close();
        const accepted = collector.acceptance();
        try std.testing.expectEqual(mask, accepted.user_regs_mask);
        try std.testing.expectEqual(stack_bytes, accepted.user_stack_bytes);
        try std.testing.expectEqual(stack_bytes != 0, accepted.sample_type & c.PERF_SAMPLE_STACK_USER != 0);
        const token: u8 = 1;
        try std.testing.expectEqual(@as(isize, 1), c.write(gate[1], &token, 1));
        const end = now() + 350_000_000;
        var count: usize = 0;
        var with_state: usize = 0;
        var with_stack: usize = 0;
        var retained: usize = 0;
        var lost: u64 = 0;
        var passes: usize = 0;
        var stopped = false;
        while (passes < 256) : (passes += 1) {
            if (!stopped and now() >= end) {
                try std.testing.expect(collector.stop() == null);
                stopped = true;
            }
            const batch = collector.drain();
            if (batch.status != .ok and batch.status != .capacity) {
                std.debug.print("drain failure: {s} {s}\n", .{ @tagName(batch.status), batch.reason });
                return error.InvalidDrain;
            }
            for (batch.sides) |side| if (side.kind == .lost or side.kind == .lost_samples) {
                lost += side.lost_count;
            };
            for (batch.samples) |sample| {
                count += 1;
                try std.testing.expectEqual(@as(u32, @intCast(child)), sample.tid);
                if (stack_bytes == 0) {
                    try std.testing.expectEqual(@as(u32, 0), sample.user_state);
                    continue;
                }
                try std.testing.expect(sample.user_state > 0 and sample.user_state <= batch.user_states.len);
                const state = batch.user_states[sample.user_state - 1];
                with_state += 1;
                try std.testing.expectEqual(gprs, state.regs_mask);
                try std.testing.expect(state.abi == c.PERF_SAMPLE_REGS_ABI_NONE or state.abi == c.PERF_SAMPLE_REGS_ABI_64);
                try std.testing.expectEqual(state.abi != c.PERF_SAMPLE_REGS_ABI_NONE, state.regs_present);
                try std.testing.expect(state.stack_dyn <= state.stack_size and state.stack_size <= stack_bytes);
                try std.testing.expectEqual(state.stack_dyn, state.stack_len);
                try std.testing.expect(@as(usize, state.stack_off) + state.stack_len <= batch.user_stack.len);
                if (state.stack_len != 0) {
                    with_stack += 1;
                    try std.testing.expect(state.regs_present and state.regs[c.PERF_REG_X86_SP] != 0);
                }
                retained += state.stack_len;
            }
            if (stopped and batch.status == .ok) break;
            if (batch.status == .ok) _ = c.usleep(5000);
        }
        try std.testing.expect(stopped);
        try std.testing.expect(count > 0);
        if (stack_bytes != 0) {
            try std.testing.expectEqual(count, with_state);
            try std.testing.expect(with_stack > 0);
        }
        std.debug.print("sampled-state live: requested={d} samples={d} states={d} stacks={d} bytes={d} lost={d} drains={d}\n", .{ stack_bytes, count, with_state, with_stack, retained, lost, passes + 1 });
    }
    try std.testing.expectEqual(fd_before, fds());
}
test "owned task captures user registers and bounded stacks with clean descriptors" {
    try std.testing.expectEqual(@as(c_int, 7), c.PERF_REG_X86_SP);
    try std.testing.expectEqual(@as(c_int, 8), c.PERF_REG_X86_IP);
    try std.testing.expectEqual(@as(c_int, 24), c.PERF_REG_X86_64_MAX);
    for ([_]u32{ 0, 64, 4096, 8192 }) |bytes| try check(bytes);
}
