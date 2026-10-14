//! Bounded history of the system collector cache, for MCP observers and the
//! headless overview. One time axis: each owner tick that sampled a history
//! group appends one row; a series whose group was not sampled on that tick
//! holds NaN (not measured), never zero. Memory is fixed after the first row.
const std = @import("std");
const c = @import("../c_ui.zig").api;
const a = std.heap.c_allocator;

pub const rows = 1200; // 10 minutes at the 500 ms default interval
pub const max_cpus = 256;
pub const max_devices = 16;
pub const max_tracked = 64;
/// Processes tracked on every processes tick without being asked for.
pub const top_tracked = 8;
/// An explicitly requested process stays tracked this long after the request.
pub const track_ns: u64 = 600_000_000_000;

pub const Group = enum { cpu, per_cpu, memory, psi, disks, network, processes };

/// Fixed scalar series, with the group that answers for them.
pub const Scalar = enum {
    cpu_busy_pct,
    cpu_user_pct,
    cpu_system_pct,
    cpu_iowait_pct,
    load1,
    collector_cpu_pct,
    memory_used,
    memory_available,
    memory_cached,
    swap_used,
    zswap_pool,
    psi_cpu_some10,
    psi_cpu_full10,
    psi_memory_some10,
    psi_memory_full10,
    psi_io_some10,
    psi_io_full10,
    disk_read_bps,
    disk_write_bps,
    net_rx_bps,
    net_tx_bps,

    pub fn group(self: Scalar) Group {
        return switch (self) {
            .cpu_busy_pct, .cpu_user_pct, .cpu_system_pct, .cpu_iowait_pct, .load1, .collector_cpu_pct => .cpu,
            .memory_used, .memory_available, .memory_cached, .swap_used, .zswap_pool => .memory,
            .psi_cpu_some10, .psi_cpu_full10, .psi_memory_some10, .psi_memory_full10, .psi_io_some10, .psi_io_full10 => .psi,
            .disk_read_bps, .disk_write_bps => .disks,
            .net_rx_bps, .net_tx_bps => .network,
        };
    }
};
const scalar_count = @typeInfo(Scalar).@"enum".fields.len;
pub const disk_series = [_][]const u8{ "read_bps", "write_bps", "busy_pct" };
pub const net_series = [_][]const u8{ "rx_bps", "tx_bps" };
pub const process_series = [_][]const u8{ "cpu_pct", "rss" };

pub const Device = struct { name: [32]u8 = @splat(0), len: u8 = 0 };
pub const Tracked = struct {
    pid: i32 = 0,
    start: u64 = 0,
    comm: [16]u8 = @splat(0),
    /// Monotonic ns until which the slot is kept; renewed while in the top set.
    wanted_until: u64 = 0,
    explicit: bool = false,
};

/// Bits of the collector groups that feed history.
pub fn groups() u32 {
    var mask: u32 = 0;
    for ([_]c_uint{ c.XRT_SYS_G_SUMMARY, c.XRT_SYS_G_CPU, c.XRT_SYS_G_MEMORY, c.XRT_SYS_G_DISKS, c.XRT_SYS_G_NETWORK, c.XRT_SYS_G_PROCESSES }) |id|
        mask |= @as(u32, 1) << @intCast(id);
    return mask;
}

pub const History = struct {
    times: [rows]u64 = @splat(0),
    head: usize = 0, // next row to write
    len: usize = 0,
    cpus: usize = 0,
    /// Column-major: column k is values[k * rows ..][0..rows].
    values: []f32 = &.{},
    disks: [max_devices]Device = @splat(.{}),
    disk_count: usize = 0,
    nets: [max_devices]Device = @splat(.{}),
    net_count: usize = 0,
    tracked: [max_tracked]Tracked = @splat(.{}),

    pub fn deinit(self: *History) void {
        if (self.values.len > 0) a.free(self.values);
        self.* = .{};
    }

    fn columns(cpus: usize) usize {
        return scalar_count + cpus + max_devices * (disk_series.len + net_series.len) + max_tracked * process_series.len;
    }
    pub fn scalarColumn(_: *const History, s: Scalar) usize {
        return @intFromEnum(s);
    }
    pub fn cpuColumn(_: *const History, i: usize) usize {
        return scalar_count + i;
    }
    pub fn diskColumn(self: *const History, slot: usize, series: usize) usize {
        return scalar_count + self.cpus + slot * disk_series.len + series;
    }
    pub fn netColumn(self: *const History, slot: usize, series: usize) usize {
        return scalar_count + self.cpus + max_devices * disk_series.len + slot * net_series.len + series;
    }
    pub fn processColumn(self: *const History, slot: usize, series: usize) usize {
        return scalar_count + self.cpus + max_devices * (disk_series.len + net_series.len) + slot * process_series.len + series;
    }
    fn column(self: *History, k: usize) []f32 {
        return self.values[k * rows ..][0..rows];
    }
    fn put(self: *History, k: usize, row: usize, value: ?f64) void {
        self.column(k)[row] = if (value) |v| @floatCast(v) else std.math.nan(f32);
    }
    pub fn bytes(self: *const History) usize {
        return self.values.len * @sizeOf(f32) + @sizeOf(History);
    }
    /// Newest row time, or null before the first row.
    pub fn newest(self: *const History) ?u64 {
        if (self.len == 0) return null;
        return self.times[(self.head + rows - 1) % rows];
    }
    pub fn oldest(self: *const History) ?u64 {
        if (self.len == 0) return null;
        return self.times[(self.head + rows - self.len) % rows];
    }

    /// Appends one row from the cache groups sampled in `mask` at `now`.
    pub fn record(self: *History, snap: *const c.struct_xrt_sys_snapshot, mask: u32, now: u64) !void {
        if (mask & groups() == 0) return;
        if (self.values.len == 0) {
            const configured: usize = @intCast(@max(0, c.sysconf(c._SC_NPROCESSORS_CONF)));
            self.cpus = @min(@max(snap.cpu.count, configured), max_cpus);
            self.values = try a.alloc(f32, columns(self.cpus) * rows);
            @memset(self.values, std.math.nan(f32));
        }
        const row = self.head;
        self.times[row] = now;
        for (0..columns(self.cpus)) |k| self.column(k)[row] = std.math.nan(f32);
        const has = struct {
            fn bit(m: u32, id: c_uint) bool {
                return m & (@as(u32, 1) << @intCast(id)) != 0;
            }
        }.bit;
        self.put(@intFromEnum(Scalar.collector_cpu_pct), row, f(snap.self.cpu_pct_of_core));
        if (has(mask, c.XRT_SYS_G_SUMMARY)) {
            self.put(@intFromEnum(Scalar.load1), row, f(snap.summary.load1));
            self.put(@intFromEnum(Scalar.cpu_busy_pct), row, f(snap.summary.cpu_busy_pct));
        }
        if (has(mask, c.XRT_SYS_G_CPU)) {
            const cpu = &snap.cpu;
            if (f(cpu.total.busy)) |busy| self.put(@intFromEnum(Scalar.cpu_busy_pct), row, busy);
            self.put(@intFromEnum(Scalar.cpu_user_pct), row, f(cpu.total.user));
            self.put(@intFromEnum(Scalar.cpu_system_pct), row, f(cpu.total.system));
            self.put(@intFromEnum(Scalar.cpu_iowait_pct), row, f(cpu.total.iowait));
            self.put(@intFromEnum(Scalar.psi_cpu_some10), row, f(cpu.psi.some_avg10));
            self.put(@intFromEnum(Scalar.psi_cpu_full10), row, f(cpu.psi.full_avg10));
            for (0..@min(self.cpus, cpu.count)) |i| self.put(self.cpuColumn(i), row, f(cpu.cpu[i].t.busy));
        }
        if (has(mask, c.XRT_SYS_G_MEMORY)) {
            const m = &snap.memory;
            self.put(@intFromEnum(Scalar.memory_used), row, u(m.used));
            self.put(@intFromEnum(Scalar.memory_available), row, u(m.available));
            self.put(@intFromEnum(Scalar.memory_cached), row, u(m.cached));
            self.put(@intFromEnum(Scalar.swap_used), row, u(m.swap_used));
            self.put(@intFromEnum(Scalar.zswap_pool), row, u(m.zswap_pool));
            self.put(@intFromEnum(Scalar.psi_memory_some10), row, f(m.psi.some_avg10));
            self.put(@intFromEnum(Scalar.psi_memory_full10), row, f(m.psi.full_avg10));
        }
        if (has(mask, c.XRT_SYS_G_DISKS)) {
            const d = &snap.disks;
            self.put(@intFromEnum(Scalar.psi_io_some10), row, f(d.psi.some_avg10));
            self.put(@intFromEnum(Scalar.psi_io_full10), row, f(d.psi.full_avg10));
            var read: ?f64 = null;
            var write: ?f64 = null;
            for (d.disk[0..@min(d.count, c.XRT_SYS_MAX_DISKS)]) |*disk| {
                if (f(disk.read_bps)) |v| read = (read orelse 0) + v;
                if (f(disk.write_bps)) |v| write = (write orelse 0) + v;
                const slot = slotFor(&self.disks, &self.disk_count, std.mem.sliceTo(&disk.name, 0)) orelse continue;
                self.put(self.diskColumn(slot, 0), row, f(disk.read_bps));
                self.put(self.diskColumn(slot, 1), row, f(disk.write_bps));
                self.put(self.diskColumn(slot, 2), row, f(disk.busy_pct));
            }
            self.put(@intFromEnum(Scalar.disk_read_bps), row, read);
            self.put(@intFromEnum(Scalar.disk_write_bps), row, write);
        }
        if (has(mask, c.XRT_SYS_G_NETWORK)) {
            const n = &snap.network;
            self.put(@intFromEnum(Scalar.net_rx_bps), row, f(n.rx_bps));
            self.put(@intFromEnum(Scalar.net_tx_bps), row, f(n.tx_bps));
            for (n.iface[0..@min(n.count, c.XRT_SYS_MAX_IFACES)]) |*iface| {
                const slot = slotFor(&self.nets, &self.net_count, std.mem.sliceTo(&iface.name, 0)) orelse continue;
                self.put(self.netColumn(slot, 0), row, f(iface.rx_bps));
                self.put(self.netColumn(slot, 1), row, f(iface.tx_bps));
            }
        }
        if (has(mask, c.XRT_SYS_G_PROCESSES) and snap.processes.proc != null) {
            const procs = snap.processes.proc[0..snap.processes.count];
            self.trackTop(procs, now);
            for (&self.tracked, 0..) |*t, slot| {
                if (t.pid == 0) continue;
                const p = find(procs, t.pid, t.start) orelse continue;
                self.put(self.processColumn(slot, 0), row, f(p.cpu_pct));
                self.put(self.processColumn(slot, 1), row, u(p.rss));
            }
        }
        self.head = (self.head + 1) % rows;
        self.len = @min(self.len + 1, rows);
    }

    /// Keeps the top CPU and RSS processes tracked; explicit requests are
    /// kept until they expire. Evicts the slot that expired first.
    fn trackTop(self: *History, procs: []const c.struct_xrt_sys_proc, now: u64) void {
        inline for (.{ "cpu_pct", "rss" }) |field| {
            var best: [top_tracked]?usize = @splat(null);
            for (procs, 0..) |*p, i| {
                const key = measured(@field(p, field)) orelse continue;
                if (key <= 0) continue;
                var k: usize = top_tracked;
                while (k > 0 and (best[k - 1] == null or measured(@field(procs[best[k - 1].?], field)).? < key)) k -= 1;
                if (k == top_tracked) continue;
                var j: usize = top_tracked - 1;
                while (j > k) : (j -= 1) best[j] = best[j - 1];
                best[k] = i;
            }
            for (best) |entry| if (entry) |i| {
                _ = self.track(&procs[i], now, now + 30_000_000_000, false);
            };
        }
    }

    /// Tracks a process from the next processes row. Returns its slot.
    pub fn track(self: *History, p: *const c.struct_xrt_sys_proc, now: u64, until: u64, explicit: bool) ?usize {
        var victim: ?usize = null;
        for (&self.tracked, 0..) |*t, slot| {
            if (t.pid == p.pid and t.start == p.start_ticks) {
                t.wanted_until = @max(t.wanted_until, until);
                t.explicit = t.explicit or explicit;
                return slot;
            }
        }
        for (self.tracked, 0..) |t, slot| {
            if (t.pid == 0) {
                victim = slot;
                break;
            }
            if (t.wanted_until >= now) continue;
            if (victim == null or t.wanted_until < self.tracked[victim.?].wanted_until) victim = slot;
        }
        const slot = victim orelse return null;
        self.tracked[slot] = .{ .pid = p.pid, .start = p.start_ticks, .wanted_until = until, .explicit = explicit };
        const comm = std.mem.sliceTo(&p.comm, 0);
        const n = @min(comm.len, self.tracked[slot].comm.len - 1);
        @memcpy(self.tracked[slot].comm[0..n], comm[0..n]);
        if (self.values.len > 0) for (0..process_series.len) |series| @memset(self.column(self.processColumn(slot, series)), std.math.nan(f32));
        return slot;
    }

    /// Averages column `k` into `out.len` buckets of `step` ns ending at
    /// `end`; a bucket without a measured row is null.
    pub fn buckets(self: *History, k: usize, end: u64, step: u64, out: []?f64) void {
        var sum: [max_points]f64 = undefined;
        var count: [max_points]u32 = undefined;
        const n = @min(out.len, max_points);
        @memset(sum[0..n], 0);
        @memset(count[0..n], 0);
        const span = step * n;
        const col = self.column(k);
        for (0..self.len) |back| {
            const row = (self.head + rows - 1 - back) % rows;
            const t = self.times[row];
            if (t > end) continue;
            const age = end - t;
            if (age >= span) break;
            const v = col[row];
            if (std.math.isNan(v)) continue;
            const b = n - 1 - @as(usize, @intCast(age / step));
            sum[b] += v;
            count[b] += 1;
        }
        for (out[0..n], sum[0..n], count[0..n]) |*o, s, cnt| o.* = if (cnt == 0) null else s / @as(f64, @floatFromInt(cnt));
    }
};
pub const max_points = 600;

fn measured(x: anytype) ?f64 {
    return if (@TypeOf(x) == c.struct_xrt_sys_f64) f(x) else u(x);
}
fn f(x: c.struct_xrt_sys_f64) ?f64 {
    return if (x.st == c.XRT_SYS_OK) x.v else null;
}
fn u(x: c.struct_xrt_sys_u64) ?f64 {
    return if (x.st == c.XRT_SYS_OK) @floatFromInt(x.v) else null;
}
fn slotFor(list: *[max_devices]Device, count: *usize, name: []const u8) ?usize {
    const key = name[0..@min(name.len, 31)];
    for (list[0..count.*], 0..) |*d, i| if (std.mem.eql(u8, d.name[0..d.len], key)) return i;
    if (count.* == max_devices or key.len == 0) return null;
    @memcpy(list[count.*].name[0..key.len], key);
    list[count.*].len = @intCast(key.len);
    count.* += 1;
    return count.* - 1;
}
/// Rows are sorted by pid.
pub fn find(procs: []const c.struct_xrt_sys_proc, pid: i32, start: u64) ?*const c.struct_xrt_sys_proc {
    var lo: usize = 0;
    var hi: usize = procs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (procs[mid].pid < pid) lo = mid + 1 else hi = mid;
    }
    if (lo < procs.len and procs[lo].pid == pid and (start == 0 or procs[lo].start_ticks == start)) return &procs[lo];
    return null;
}

test "history rows mark unsampled groups as not measured and bucket by time" {
    const snap = try std.testing.allocator.create(c.struct_xrt_sys_snapshot);
    defer std.testing.allocator.destroy(snap);
    snap.* = std.mem.zeroes(c.struct_xrt_sys_snapshot);
    snap.cpu.count = 2;
    var procs = [_]c.struct_xrt_sys_proc{ std.mem.zeroes(c.struct_xrt_sys_proc), std.mem.zeroes(c.struct_xrt_sys_proc) };
    procs[0].pid = 10;
    procs[0].start_ticks = 5;
    procs[1].pid = 20;
    procs[1].start_ticks = 6;
    snap.processes.proc = &procs;
    snap.processes.count = 2;
    var h = History{};
    defer h.deinit();
    const bit = struct {
        fn of(id: c_uint) u32 {
            return @as(u32, 1) << @intCast(id);
        }
    }.of;
    for (0..10) |i| {
        snap.cpu.total.busy = .{ .v = @floatFromInt(i * 10), .st = c.XRT_SYS_OK, .why = 0 };
        snap.memory.used = .{ .v = 1000, .st = c.XRT_SYS_OK, .why = 0 };
        procs[1].cpu_pct = .{ .v = 50, .st = c.XRT_SYS_OK, .why = 0 };
        procs[1].rss = .{ .v = 4096, .st = c.XRT_SYS_OK, .why = 0 };
        const mask = bit(c.XRT_SYS_G_CPU) | bit(c.XRT_SYS_G_PROCESSES) | (if (i % 2 == 0) bit(c.XRT_SYS_G_MEMORY) else 0);
        try h.record(snap, mask, (i + 1) * 1_000_000_000);
    }
    try std.testing.expectEqual(10, h.len);
    try std.testing.expectEqual(10_000_000_000, h.newest().?);
    var out: [5]?f64 = undefined;
    h.buckets(h.scalarColumn(.cpu_busy_pct), h.newest().?, 2_000_000_000, &out);
    try std.testing.expectEqual(@as(?f64, 85), out[4]); // rows at 9 s and 10 s
    try std.testing.expectEqual(@as(?f64, 5), out[0]);
    h.buckets(h.scalarColumn(.memory_used), h.newest().?, 1_000_000_000, &out);
    try std.testing.expect(out[4] == null); // memory not sampled on that tick
    try std.testing.expectEqual(@as(?f64, 1000), out[3]);
    h.buckets(h.scalarColumn(.psi_io_some10), h.newest().?, 1_000_000_000, &out);
    try std.testing.expect(out[4] == null);
    // pid 20 is the only process with CPU and RSS, so it is tracked unasked
    var slot: ?usize = null;
    for (h.tracked, 0..) |t, i| if (t.pid == 20) {
        slot = i;
    };
    h.buckets(h.processColumn(slot.?, 1), h.newest().?, 1_000_000_000, &out);
    try std.testing.expectEqual(@as(?f64, 4096), out[4]);
    try std.testing.expect(find(&procs, 20, 7) == null);
    try std.testing.expect(find(&procs, 10, 5) != null);
}
