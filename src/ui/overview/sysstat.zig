//! Live source: the system collector (src/runtime/xrt_sysstat.h, ABI 1)
//! copied into the overview model. This adapter is the only overview code
//! that knows the C layout.
const std = @import("std");
const m = @import("model.zig");
pub const c = @import("../../c.zig").api;

comptime {
    if (c.XRT_SYS_ABI != 1) @compileError("overview adapter expects xrt_sysstat ABI 1");
}

pub const Live = struct {
    collector: *@import("../../model/system.zig").Collector,
    converted: [m.group_count]u64 = @splat(0),
    pub fn sample(self: *Live, gpa: std.mem.Allocator) !*m.Owned {
        const source = try self.collector.snapshot();
        const owned = try m.Owned.create(gpa);
        errdefer owned.destroy();
        // Carry unchanged slow arrays in the view instead of allocating and
        // copying thousands of process/package strings on every fast frame.
        const selected = try gpa.create(c.struct_xrt_sys_snapshot);
        defer gpa.destroy(selected); // borrowed C pointers: do not snapshot_free
        selected.* = source.*;
        inline for (.{ .{ m.Group.processes, "processes" }, .{ m.Group.connections, "connections" }, .{ m.Group.filesystems, "filesystems" }, .{ m.Group.users, "users" }, .{ m.Group.services, "services" }, .{ m.Group.apps, "apps" } }) |entry| {
            const i = @intFromEnum(entry[0]);
            if (self.converted[i] == self.collector.sampled[i]) {
                @field(selected, entry[1]) = std.mem.zeroes(@TypeOf(@field(selected, entry[1])));
                selected.group[i].st = c.XRT_SYS_UNAVAILABLE;
                selected.group[i].why = c.XRT_SYS_WHY_NOT_COLLECTED;
            }
        }
        try convert(owned.arena.allocator(), selected, &owned.snap);
        for (&owned.snap.fresh, 0..) |*fresh, i| fresh.* = self.converted[i] != self.collector.sampled[i];
        self.converted = self.collector.sampled;
        return owned;
    }
};

fn reason(why: u8) []const u8 {
    return std.mem.span(c.xrt_sys_reason_text(why));
}
fn f(x: c.struct_xrt_sys_f64) m.F {
    return switch (x.st) {
        c.XRT_SYS_OK => m.F.of(x.v),
        c.XRT_SYS_STALE => .{ .status = .stale, .value = x.v, .reason = reason(x.why) },
        else => m.F.missing(if (x.st == c.XRT_SYS_UNSET) "not collected" else reason(x.why)),
    };
}
fn u(x: c.struct_xrt_sys_u64) m.U {
    return switch (x.st) {
        c.XRT_SYS_OK => m.U.of(x.v),
        c.XRT_SYS_STALE => .{ .status = .stale, .value = x.v, .reason = reason(x.why) },
        else => m.U.missing(if (x.st == c.XRT_SYS_UNSET) "not collected" else reason(x.why)),
    };
}
fn chars(a: std.mem.Allocator, s: anytype) ![]const u8 {
    return a.dupe(u8, std.mem.sliceTo(@as([]const u8, &s), 0));
}
fn name(a: std.mem.Allocator, x: anytype) !m.Text {
    return switch (x.st) {
        c.XRT_SYS_OK, c.XRT_SYS_STALE => m.Text.of(try chars(a, x.s)),
        else => m.Text.missing(if (x.st == c.XRT_SYS_UNSET) "not collected" else reason(x.why)),
    };
}
fn pressure(p: c.struct_xrt_sys_psi) m.Pressure {
    return .{ .some10 = f(p.some_avg10), .some60 = f(p.some_avg60), .full10 = f(p.full_avg10), .full60 = f(p.full_avg60) };
}
fn kind(k: u8) m.SensorKind {
    return switch (k) {
        c.XRT_SYS_TEMP => .temp,
        c.XRT_SYS_FAN => .fan,
        c.XRT_SYS_VOLTAGE => .voltage,
        c.XRT_SYS_CURRENT => .current,
        c.XRT_SYS_POWER_W => .power,
        c.XRT_SYS_ENERGY_J => .energy,
        c.XRT_SYS_FREQ_MHZ => .freq,
        c.XRT_SYS_HUMIDITY => .humidity,
        c.XRT_SYS_PWM_PCT => .pwm,
        else => .other,
    };
}
fn small(v: m.U) u32 {
    return @intCast(@min(v.get() orelse 0, std.math.maxInt(u32)));
}

pub fn convert(a: std.mem.Allocator, src: *const c.struct_xrt_sys_snapshot, s: *m.Snapshot) !void {
    s.time_ns = @intCast(@max(0, src.monotonic_ns));
    s.interval_s = f(src.interval_s);
    s.sequence = src.sequence;
    s.redacted = src.redacted != 0;
    for (&s.groups, src.group[0..m.group_count]) |*g, x| g.* = .{
        .status = if (x.st == c.XRT_SYS_OK) .ok else if (x.st == c.XRT_SYS_STALE) .stale else .unavailable,
        .reason = if (x.st == c.XRT_SYS_OK) "" else if (x.st == c.XRT_SYS_UNSET) "not collected" else reason(x.why),
        .detail = try chars(a, x.detail),
        .cost_ns = x.cost_ns,
    };
    const sum = &src.summary;
    s.uptime_s = f(sum.uptime_s);
    s.load1 = f(sum.load1);
    s.load5 = f(sum.load5);
    s.load15 = f(sum.load15);
    s.boot_time = u(sum.boot_time_s);
    s.process_count = u(sum.processes);
    s.thread_count = u(sum.threads);
    s.running = u(sum.running);
    s.blocked = u(sum.blocked);
    s.context_switches_ps = f(sum.context_switches_ps);
    s.interrupts_ps = f(sum.interrupts_ps);
    s.forks_ps = f(sum.forks_ps);
    s.cpu_total = f(sum.cpu_busy_pct);

    const cpu = &src.cpu;
    if (s.cpu_total.get() == null) s.cpu_total = f(cpu.total.busy);
    s.cpu_user = f(cpu.total.user);
    s.cpu_system = f(cpu.total.system);
    s.cpu_iowait = f(cpu.total.iowait);
    s.cpu_model = try name(a, cpu.model);
    s.freq_driver = try name(a, cpu.freq_driver);
    s.governor = try name(a, cpu.governor);
    s.cpu_package_temp = f(cpu.package_temp_c);
    s.psi_cpu = pressure(cpu.psi);
    const cpus = try a.alloc(m.Cpu, @min(cpu.count, c.XRT_SYS_MAX_CPUS));
    for (cpus, cpu.cpu[0..cpus.len]) |*o, x| o.* = .{
        .id = @intCast(@max(0, x.id)),
        .core = small(u(x.core_id)),
        .package = small(u(x.package_id)),
        .cache = small(u(x.l3_id)),
        .smt = small(u(x.smt_index)),
        .topology_why = m.firstMissing(&.{ u(x.package_id), u(x.core_id), u(x.l3_id), u(x.smt_index) }),
        .online = if (u(x.online).get()) |on| on != 0 else null,
        .online_why = u(x.online).reason,
        .total = f(x.t.busy),
        .user = f(x.t.user),
        .system = f(x.t.system),
        .iowait = f(x.t.iowait),
        .irq = f(x.t.irq),
        .steal = f(x.t.steal),
        .mhz = f(x.freq_mhz),
        .max_mhz = f(x.freq_max_mhz),
        .temp_c = f(x.temp_c),
    };
    s.cpus = cpus;
    const temps = try a.alloc(m.Sensor, @min(cpu.temp_count, cpu.temps.len));
    for (temps, cpu.temps[0..temps.len]) |*o, x| o.* = .{ .chip = try chars(a, x.chip), .label = try chars(a, x.label), .kind = .temp, .value = f(x.value) };
    s.cpu_temps = temps;

    const mem = &src.memory;
    s.memory = .{
        .total = u(mem.total),
        .used = u(mem.used),
        .free = u(mem.free),
        .available = u(mem.available),
        .cached = u(mem.cached),
        .buffers = u(mem.buffers),
        .shared = u(mem.shmem),
        .slab = u(mem.slab_reclaimable),
        .dirty = u(mem.dirty),
        .writeback = u(mem.writeback),
        .committed = u(mem.committed),
        .commit_limit = u(mem.commit_limit),
        .swap_total = u(mem.swap_total),
        .swap_used = u(mem.swap_used),
        .zswap_pool = u(mem.zswap_pool),
        .zswap_stored = u(mem.zswap_stored),
        .major_faults_ps = f(mem.major_faults_ps),
        .swap_in_ps = f(mem.swap_in_ps),
        .swap_out_ps = f(mem.swap_out_ps),
    };
    s.psi_memory = pressure(mem.psi);

    s.psi_io = pressure(src.disks.psi);
    const disks = try a.alloc(m.Disk, @min(src.disks.count, c.XRT_SYS_MAX_DISKS));
    for (disks, src.disks.disk[0..disks.len]) |*o, x| o.* = .{
        .name = try chars(a, x.name),
        .model = try name(a, x.model),
        .size = u(x.size_bytes),
        .rotational = (u(x.rotational).get() orelse 0) != 0,
        .read_bps = f(x.read_bps),
        .write_bps = f(x.write_bps),
        .read_iops = f(x.read_iops),
        .write_iops = f(x.write_iops),
        .busy = f(x.busy_pct),
        .queue = f(x.queue_depth),
        .latency_ms = f(x.avg_latency_ms),
        .temp_c = f(x.temp_c),
    };
    s.disks = disks;

    const mounts = try a.alloc(m.Mount, @min(src.filesystems.count, c.XRT_SYS_MAX_FILESYSTEMS));
    for (mounts, src.filesystems.fs[0..mounts.len]) |*o, x| o.* = .{
        .path = try name(a, x.mount),
        .device = try name(a, x.source),
        .fstype = try chars(a, x.fstype),
        .total = u(x.total),
        .used = u(x.used),
        .available = u(x.avail),
        .used_pct = f(x.used_pct),
        .inodes_total = u(x.inodes_total),
        .inodes_free = u(x.inodes_free),
        .read_only = (u(x.read_only).get() orelse 0) != 0,
    };
    s.mounts = mounts;

    s.net_rx_bps = f(src.network.rx_bps);
    s.net_tx_bps = f(src.network.tx_bps);
    const nets = try a.alloc(m.Net, @min(src.network.count, c.XRT_SYS_MAX_IFACES));
    for (nets, src.network.iface[0..nets.len]) |*o, *x| {
        const addrs = try a.alloc(m.Text, @min(x.addr_count, c.XRT_SYS_MAX_ADDRS));
        for (addrs, x.addr[0..addrs.len]) |*t, ad| t.* = try name(a, ad);
        o.* = .{
            .name = try chars(a, x.name),
            .state = try name(a, x.operstate),
            .loopback = (u(x.loopback).get() orelse 0) != 0,
            .rx_bps = f(x.rx_bps),
            .tx_bps = f(x.tx_bps),
            .rx_pps = f(x.rx_pps),
            .tx_pps = f(x.tx_pps),
            .errors_ps = f(x.rx_errors_ps),
            .drops_ps = f(x.rx_drops_ps),
            .speed_mbps = u(x.speed_mbps),
            .mtu = u(x.mtu),
            .mac = try name(a, x.mac),
            .addresses = addrs,
        };
    }
    s.nets = nets;

    const cs = &src.connections;
    s.connections_truncated = cs.truncated;
    s.owners_unresolved = u(cs.owners_unresolved);
    const conns = try a.alloc(m.Connection, if (cs.conn == null) 0 else cs.count);
    for (conns, 0..) |*o, i| {
        const x = &cs.conn[i];
        const pid = u(x.pid);
        o.* = .{
            .proto = switch (x.proto) {
                c.XRT_SYS_TCP => "tcp",
                c.XRT_SYS_UDP => "udp",
                c.XRT_SYS_UNIX => "unix",
                else => "?",
            },
            .family = x.family,
            .state = try chars(a, x.state),
            .local = try name(a, x.local),
            .remote = try name(a, x.remote),
            .pid = .{ .status = pid.status, .value = @intCast(@min(pid.value, std.math.maxInt(i32))), .reason = pid.reason },
            .owner = if (pid.get() != null) try chars(a, x.comm) else "",
            .rx_queue = u(x.rx_queue),
            .tx_queue = u(x.tx_queue),
        };
    }
    s.connections = conns;

    const pw = &src.power;
    s.cpu_package_power = f(pw.cpu_package_w);
    s.battery_pct = f(pw.battery_pct);
    const sensors = try a.alloc(m.Sensor, @min(pw.sensor_count, c.XRT_SYS_MAX_SENSORS));
    for (sensors, pw.sensor[0..sensors.len]) |*o, x| o.* = .{ .chip = try chars(a, x.chip), .label = try chars(a, x.label), .kind = kind(x.kind), .value = f(x.value), .max = f(x.max), .crit = f(x.crit) };
    s.sensors = sensors;
    const gpus = try a.alloc(m.Gpu, @min(pw.gpu_count, c.XRT_SYS_MAX_GPUS));
    for (gpus, pw.gpu[0..gpus.len]) |*o, x| o.* = .{ .card = try chars(a, x.card), .driver = try chars(a, x.driver), .name = try name(a, x.name), .busy = f(x.busy_pct), .power_w = f(x.power_w), .temp_c = f(x.temp_c), .vram_used = u(x.vram_used), .vram_total = u(x.vram_total), .graphics_mhz = f(x.graphics_mhz), .memory_mhz = f(x.memory_mhz) };
    s.gpus = gpus;

    const users = try a.alloc(m.UserSession, @min(src.users.count, c.XRT_SYS_MAX_USERS));
    for (users, src.users.user[0..users.len]) |*o, x| o.* = .{ .name = try name(a, x.user), .line = try chars(a, x.line), .from = try name(a, x.host), .pid = u(x.pid), .login_s = u(x.login_time_s) };
    s.users = users;

    s.service_manager = try name(a, src.services.manager);
    const services = try a.alloc(m.Service, @min(src.services.count, c.XRT_SYS_MAX_SERVICES));
    for (services, src.services.service[0..services.len]) |*o, x| o.* = .{
        .name = try chars(a, x.name), .state = try name(a, x.state), .pid = u(x.pid),
        .start = u(x.start_ticks), .uid = u(x.uid), .user = try name(a, x.user),
        .uptime = f(x.uptime_s), .cpu = f(x.cpu_pct), .rss = u(x.rss), .cgroup = try name(a, x.cgroup),
    };
    s.services = services;

    const apps = &src.apps;
    s.apps_manager = try name(a, apps.manager);
    s.apps_count = u(apps.count);
    s.apps_bytes = u(apps.total_size);
    const packages = try a.alloc(m.Package, if (apps.list == null) 0 else apps.list_count);
    for (packages, 0..) |*o, i| o.* = .{ .name = try chars(a, apps.list[i].name), .version = try chars(a, apps.list[i].version), .size = u(apps.list[i].size) };
    s.packages = packages;

    const ps = &src.processes;
    s.processes_truncated = ps.truncated;
    const procs = try a.alloc(m.Process, if (ps.proc == null) 0 else ps.count);
    for (procs, 0..) |*o, i| {
        const x = &ps.proc[i];
        const nice = u(x.nice);
        o.* = .{
            .pid = x.pid,
            .start = x.start_ticks,
            .ppid = @intCast(@min(u(x.ppid).get() orelse 0, std.math.maxInt(i32))),
            .name = try chars(a, x.comm),
            .cmdline = try name(a, x.cmdline),
            .user = try name(a, x.user),
            .uid = u(x.uid),
            .state = x.state,
            .kernel = (u(x.kernel_thread).get() orelse 0) != 0,
            .cpu = f(x.cpu_pct),
            .rss = u(x.rss),
            .pss = u(x.pss),
            .read_bps = f(x.io_read_bps),
            .write_bps = f(x.io_write_bps),
            .net_bps = f(x.net_bps),
            .threads = u(x.threads),
            .fds = u(x.fds),
            .nice = .{ .status = nice.status, .value = @as(i32, @intCast(@min(nice.value, 40))) - 20, .reason = nice.reason },
            .cgroup = try name(a, x.cgroup),
        };
    }
    s.processes = procs;

    const info = &src.info;
    s.hostname = try name(a, info.hostname);
    s.kernel = try name(a, info.kernel);
    s.os = try name(a, info.os);
    s.arch = try name(a, info.arch);
    s.init = try name(a, info.init);
    s.package_manager = try name(a, info.package_manager);
    if (!s.cpu_model.ok()) s.cpu_model = try name(a, info.cpu_model);
    s.physical_cores = u(info.physical_cores);
    s.memory_total = u(info.memory_total);
    const gnames = try a.alloc(m.Text, @min(info.gpu_count, c.XRT_SYS_MAX_GPUS));
    for (gnames, info.gpu[0..gnames.len]) |*o, x| o.* = try name(a, x);
    s.gpu_names = gnames;
    const me = &src.self;
    s.cost = .{ .wall_ms = f(me.wall_ms), .cpu_ms = f(me.cpu_ms), .cpu_pct = f(me.cpu_pct_of_core), .syscalls = u(me.syscalls) };
}

test "a zeroed collector snapshot converts to unavailable, never zero" {
    const src = try std.testing.allocator.create(c.struct_xrt_sys_snapshot);
    defer std.testing.allocator.destroy(src);
    src.* = std.mem.zeroes(c.struct_xrt_sys_snapshot);
    src.cpu.count = 2;
    src.cpu.cpu[1].t.busy = .{ .v = 42, .st = c.XRT_SYS_OK, .why = 0 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = m.Snapshot{};
    try convert(arena.allocator(), src, &s);
    try std.testing.expect(s.uptime_s.get() == null);
    try std.testing.expectEqualStrings("not collected", s.uptime_s.reason);
    try std.testing.expect(s.cpus[0].total.get() == null);
    try std.testing.expectEqual(@as(?f64, 42), s.cpus[1].total.get());
    try std.testing.expectEqual(@as(usize, 0), s.processes.len);
}
