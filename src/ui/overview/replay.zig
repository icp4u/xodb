//! Replay source: snapshots in the collector's JSON form (xrt_sys_json),
//! one object per line or a single object. Used for deterministic
//! screenshots and tests, and to view a saved sample without a live system.
//! Missing keys become "not in sample"; nothing missing reads as zero.
const std = @import("std");
const m = @import("model.zig");
const J = std.json.Value;

pub const max_bytes = 64 * 1024 * 1024;
const absent = "not in sample";

pub const Replay = struct {
    gpa: std.mem.Allocator,
    frames: []*m.Owned,
    next: usize = 0,

    pub fn load(gpa: std.mem.Allocator, bytes: []const u8) !Replay {
        var frames: std.ArrayList(*m.Owned) = .empty;
        errdefer {
            for (frames.items) |f| f.destroy();
            frames.deinit(gpa);
        }
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        // A pretty-printed single object spans lines; JSONL has one per line.
        if (std.json.validate(gpa, trimmed) catch false) {
            try frames.append(gpa, try parseOne(gpa, trimmed));
        } else {
            var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                const l = std.mem.trim(u8, line, " \t\r");
                if (l.len == 0) continue;
                try frames.append(gpa, try parseOne(gpa, l));
            }
        }
        if (frames.items.len == 0) return error.EmptyReplay;
        return .{ .gpa = gpa, .frames = try frames.toOwnedSlice(gpa) };
    }
    pub fn deinit(self: *Replay) void {
        for (self.frames) |f| f.destroy();
        self.gpa.free(self.frames);
    }
    /// The next frame, cycling. The caller does not own it.
    pub fn advance(self: *Replay) *m.Owned {
        const f = self.frames[self.next];
        self.next = (self.next + 1) % self.frames.len;
        return f;
    }
};

fn get(v: ?J, key: []const u8) ?J {
    const o = v orelse return null;
    if (o != .object) return null;
    return o.object.get(key);
}
/// First of several spellings (the JSON form names a few arrays differently).
fn any(v: ?J, keys: []const []const u8) ?J {
    for (keys) |k| if (get(v, k)) |x| return x;
    return null;
}
fn number(v: J) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}
fn state(v: J) m.Status {
    const s = get(v, "state") orelse return .unavailable;
    if (s != .string) return .unavailable;
    if (std.mem.eql(u8, s.string, "stale")) return .stale;
    if (std.mem.eql(u8, s.string, "ok")) return .ok;
    return .unavailable;
}
fn why(v: J) []const u8 {
    const w = get(v, "why") orelse return "unavailable";
    return if (w == .string) w.string else "unavailable";
}
fn f64f(v: ?J) m.F {
    const x = v orelse return m.F.missing(absent);
    if (number(x)) |n| return m.F.of(n);
    if (x == .object) {
        const st = state(x);
        if (st == .stale) if (get(x, "v")) |inner| if (number(inner)) |n| return .{ .status = .stale, .value = n, .reason = why(x) };
        if (st == .ok) if (get(x, "v")) |inner| if (number(inner)) |n| return m.F.of(n);
        return m.F.missing(why(x));
    }
    if (x == .null) return m.F.missing(absent);
    return m.F.missing("parse error");
}
fn u64f(v: ?J) m.U {
    const f = f64f(v);
    return .{ .status = f.status, .value = if (f.value <= 0) 0 else @intFromFloat(@min(f.value, 1.8e19)), .reason = f.reason };
}
fn i32f(v: ?J) m.Field(i32) {
    const f = f64f(v);
    return .{ .status = f.status, .value = @intFromFloat(std.math.clamp(f.value, -2147483648, 2147483647)), .reason = f.reason };
}
fn text(v: ?J) m.Text {
    const x = v orelse return m.Text.missing(absent);
    if (x == .string) return m.Text.of(x.string);
    if (x == .object) {
        if (get(x, "v")) |inner| if (inner == .string and state(x) != .unavailable) return .{ .s = inner.string, .why = "" };
        return m.Text.missing(why(x));
    }
    return m.Text.missing(absent);
}
fn str(v: ?J) []const u8 {
    const t = text(v);
    return if (t.ok()) t.s else "";
}
/// A group's rows: the group itself when it is an array, else its named
/// list, else its first array member.
fn rows(v: ?J, keys: []const []const u8) []const J {
    const x = v orelse return &.{};
    if (x == .array) return x.array.items;
    return items(any(v, keys) orelse x);
}
fn items(v: ?J) []const J {
    const x = v orelse return &.{};
    if (x == .array) return x.array.items;
    if (x == .object) {
        // A group object holding its list under some name: take the first array.
        var it = x.object.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .array) return e.value_ptr.array.items;
    }
    return &.{};
}
fn pressure(v: ?J) m.Pressure {
    return .{ .some10 = f64f(get(v, "some_avg10")), .some60 = f64f(get(v, "some_avg60")), .full10 = f64f(get(v, "full_avg10")), .full60 = f64f(get(v, "full_avg60")) };
}
fn kind(v: ?J) m.SensorKind {
    const s = str(v);
    const names = [_]struct { []const u8, m.SensorKind }{ .{ "temp", .temp }, .{ "fan", .fan }, .{ "voltage", .voltage }, .{ "in", .voltage }, .{ "current", .current }, .{ "power", .power }, .{ "energy", .energy }, .{ "freq", .freq }, .{ "humidity", .humidity }, .{ "pwm", .pwm } };
    for (names) |n| if (std.mem.eql(u8, s, n[0])) return n[1];
    return .other;
}

pub fn parseOne(gpa: std.mem.Allocator, line: []const u8) !*m.Owned {
    const owned = try m.Owned.create(gpa);
    errdefer owned.destroy();
    const a = owned.arena.allocator();
    const root = try std.json.parseFromSliceLeaky(J, a, line, .{ .max_value_len = max_bytes, .allocate = .alloc_always });
    if (root != .object) return error.ReplayNotObject;
    const r: ?J = root;
    var s = &owned.snap;
    s.sequence = u64f(get(r, "sequence")).get() orelse 0;
    s.redacted = if (get(r, "redacted")) |x| x == .bool and x.bool else false;
    s.interval_s = f64f(get(r, "interval_s"));
    if (get(r, "memory_map")) |mm| {
        const map = try a.create(@import("../../memdefrag/model.zig").Map);
        map.* = try @import("../../memdefrag/model.zig").fromValue(a, mm);
        s.memory_map = map;
    }
    if (get(r, "groups")) |groups| if (groups == .object) {
        inline for (std.meta.fields(m.Group), 0..) |g, i| {
            if (groups.object.get(g.name)) |x| {
                const st = state(x);
                const cost: ?u64 = u64f(get(x, "cost_ns")).get() orelse if (u64f(get(x, "cost_us")).get()) |us| us * 1000 else null;
                s.groups[i] = .{ .status = st, .reason = if (st == .ok) "" else why(x), .detail = str(get(x, "detail")), .cost_ns = cost };
            }
        }
    };
    const sum = get(r, "summary");
    s.uptime_s = f64f(get(sum, "uptime_s"));
    s.load1 = f64f(get(sum, "load1"));
    s.load5 = f64f(get(sum, "load5"));
    s.load15 = f64f(get(sum, "load15"));
    s.boot_time = u64f(get(sum, "boot_time_s"));
    s.process_count = u64f(get(sum, "processes"));
    s.thread_count = u64f(get(sum, "threads"));
    s.running = u64f(get(sum, "running"));
    s.blocked = u64f(get(sum, "blocked"));
    s.context_switches_ps = f64f(get(sum, "context_switches_ps"));
    s.interrupts_ps = f64f(get(sum, "interrupts_ps"));
    s.forks_ps = f64f(get(sum, "forks_ps"));
    s.cpu_total = f64f(get(sum, "cpu_busy_pct"));

    const cpu = get(r, "cpu");
    if (s.cpu_total.get() == null) s.cpu_total = f64f(get(get(cpu, "total"), "busy"));
    s.cpu_user = f64f(get(get(cpu, "total"), "user"));
    s.cpu_system = f64f(get(get(cpu, "total"), "system"));
    s.cpu_iowait = f64f(get(get(cpu, "total"), "iowait"));
    s.cpu_model = text(get(cpu, "model"));
    s.freq_driver = text(get(cpu, "freq_driver"));
    s.governor = text(get(cpu, "governor"));
    s.cpu_package_temp = f64f(get(cpu, "package_temp_c"));
    s.psi_cpu = pressure(get(cpu, "psi"));
    {
        const list = rows(cpu, &.{ "cpus", "cpu" });
        const out = try a.alloc(m.Cpu, list.len);
        for (list, out, 0..) |x, *c, i| {
            const t = any(x, &.{ "times", "t" });
            c.* = .{
                .id = @intCast(u64f(get(x, "id")).get() orelse i),
                .core = @intCast(@min(u64f(get(x, "core_id")).get() orelse 0, 1 << 20)),
                .package = @intCast(@min(u64f(get(x, "package_id")).get() orelse 0, 1 << 20)),
                .cache = @intCast(@min(u64f(get(x, "l3_id")).get() orelse 0, 1 << 20)),
                .smt = @intCast(@min(u64f(get(x, "smt_index")).get() orelse 0, 1 << 20)),
                .topology_why = m.firstMissing(&.{ u64f(get(x, "package_id")), u64f(get(x, "core_id")), u64f(get(x, "l3_id")), u64f(get(x, "smt_index")) }),
                .online = if (u64f(get(x, "online")).get()) |on| on != 0 else null,
                .online_why = u64f(get(x, "online")).reason,
                .total = f64f(get(t, "busy")),
                .user = f64f(get(t, "user")),
                .system = f64f(get(t, "system")),
                .iowait = f64f(get(t, "iowait")),
                .irq = f64f(get(t, "irq")),
                .steal = f64f(get(t, "steal")),
                .mhz = f64f(get(x, "freq_mhz")),
                .max_mhz = f64f(get(x, "freq_max_mhz")),
                .temp_c = f64f(get(x, "temp_c")),
            };
        }
        s.cpus = out;
        const temps = items(get(cpu, "temps"));
        const t_out = try a.alloc(m.Sensor, temps.len);
        for (temps, t_out) |x, *t| t.* = .{ .chip = str(get(x, "chip")), .label = str(get(x, "label")), .kind = .temp, .value = f64f(get(x, "value")) };
        s.cpu_temps = t_out;
    }

    const mem = get(r, "memory");
    s.memory = .{
        .total = u64f(get(mem, "total")),
        .used = u64f(get(mem, "used")),
        .free = u64f(get(mem, "free")),
        .available = u64f(get(mem, "available")),
        .cached = u64f(get(mem, "cached")),
        .buffers = u64f(get(mem, "buffers")),
        .shared = u64f(get(mem, "shmem")),
        .slab = u64f(get(mem, "slab_reclaimable")),
        .dirty = u64f(get(mem, "dirty")),
        .writeback = u64f(get(mem, "writeback")),
        .committed = u64f(get(mem, "committed")),
        .commit_limit = u64f(get(mem, "commit_limit")),
        .swap_total = u64f(get(mem, "swap_total")),
        .swap_used = u64f(get(mem, "swap_used")),
        .zswap_pool = u64f(get(mem, "zswap_pool")),
        .zswap_stored = u64f(get(mem, "zswap_stored")),
        .major_faults_ps = f64f(get(mem, "major_faults_ps")),
        .swap_in_ps = f64f(get(mem, "swap_in_ps")),
        .swap_out_ps = f64f(get(mem, "swap_out_ps")),
    };
    s.psi_memory = pressure(get(mem, "psi"));

    const disks = get(r, "disks");
    s.psi_io = pressure(get(disks, "psi"));
    {
        const list = rows(disks, &.{ "devices", "disks", "disk", "rows" });
        const out = try a.alloc(m.Disk, list.len);
        for (list, out) |x, *d| d.* = .{
            .name = str(get(x, "name")),
            .model = text(get(x, "model")),
            .size = u64f(get(x, "size_bytes")),
            .rotational = (u64f(get(x, "rotational")).get() orelse 0) != 0,
            .read_bps = f64f(get(x, "read_bps")),
            .write_bps = f64f(get(x, "write_bps")),
            .read_iops = f64f(get(x, "read_iops")),
            .write_iops = f64f(get(x, "write_iops")),
            .busy = f64f(get(x, "busy_pct")),
            .queue = f64f(get(x, "queue_depth")),
            .latency_ms = f64f(get(x, "avg_latency_ms")),
            .temp_c = f64f(get(x, "temp_c")),
        };
        s.disks = out;
    }
    {
        const list = rows(get(r, "filesystems"), &.{ "mounts", "filesystems", "fs", "rows" });
        const out = try a.alloc(m.Mount, list.len);
        for (list, out) |x, *f| f.* = .{
            .path = text(get(x, "mount")),
            .device = text(get(x, "source")),
            .fstype = str(get(x, "fstype")),
            .total = u64f(get(x, "total")),
            .used = u64f(get(x, "used")),
            .available = u64f(get(x, "avail")),
            .used_pct = f64f(get(x, "used_pct")),
            .inodes_total = u64f(get(x, "inodes_total")),
            .inodes_free = u64f(get(x, "inodes_free")),
            .read_only = (u64f(get(x, "read_only")).get() orelse 0) != 0,
        };
        s.mounts = out;
    }
    const net = get(r, "network");
    s.net_rx_bps = f64f(get(net, "rx_bps"));
    s.net_tx_bps = f64f(get(net, "tx_bps"));
    {
        const list = rows(net, &.{ "interfaces", "ifaces", "iface", "rows" });
        const out = try a.alloc(m.Net, list.len);
        for (list, out) |x, *n| {
            const addrs = items(any(x, &.{ "addresses", "addr" }));
            const t = try a.alloc(m.Text, addrs.len);
            for (addrs, t) |ad, *o| o.* = text(if (ad == .object and get(ad, "addr") != null) get(ad, "addr") else ad);
            n.* = .{
                .name = str(get(x, "name")),
                .state = text(get(x, "operstate")),
                .loopback = (u64f(get(x, "loopback")).get() orelse 0) != 0,
                .rx_bps = f64f(get(x, "rx_bps")),
                .tx_bps = f64f(get(x, "tx_bps")),
                .rx_pps = f64f(get(x, "rx_pps")),
                .tx_pps = f64f(get(x, "tx_pps")),
                .errors_ps = f64f(get(x, "rx_errors_ps")),
                .drops_ps = f64f(get(x, "rx_drops_ps")),
                .speed_mbps = u64f(get(x, "speed_mbps")),
                .mtu = u64f(get(x, "mtu")),
                .mac = text(get(x, "mac")),
                .addresses = t,
            };
        }
        s.nets = out;
    }
    const conns = get(r, "connections");
    s.connections_truncated = u64f(get(conns, "truncated")).get() orelse 0;
    s.owners_unresolved = u64f(get(conns, "owners_unresolved"));
    {
        const list = rows(conns, &.{ "rows", "connections", "conn" });
        const out = try a.alloc(m.Connection, list.len);
        for (list, out) |x, *c| c.* = .{
            .proto = str(get(x, "proto")),
            .family = @intCast(@min(255, u64f(get(x, "family")).get() orelse 0)),
            .state = str(get(x, "state")),
            .local = text(get(x, "local")),
            .remote = text(get(x, "remote")),
            .pid = i32f(get(x, "pid")),
            .owner = str(get(x, "comm")),
            .rx_queue = u64f(get(x, "rx_queue")),
            .tx_queue = u64f(get(x, "tx_queue")),
        };
        s.connections = out;
    }
    const power = get(r, "power");
    s.cpu_package_power = f64f(get(power, "cpu_package_w"));
    s.battery_pct = f64f(get(power, "battery_pct"));
    {
        const list = items(get(power, "sensors"));
        const out = try a.alloc(m.Sensor, list.len);
        for (list, out) |x, *o| o.* = .{ .chip = str(get(x, "chip")), .label = str(get(x, "label")), .kind = kind(get(x, "kind")), .value = f64f(get(x, "value")), .max = f64f(get(x, "max")), .crit = f64f(get(x, "crit")) };
        s.sensors = out;
        const gl = items(get(power, "gpus"));
        const g_out = try a.alloc(m.Gpu, gl.len);
        for (gl, g_out) |x, *o| o.* = .{ .card = str(get(x, "card")), .driver = str(get(x, "driver")), .name = text(get(x, "name")), .busy = f64f(get(x, "busy_pct")), .power_w = f64f(get(x, "power_w")), .temp_c = f64f(get(x, "temp_c")), .vram_used = u64f(get(x, "vram_used")), .vram_total = u64f(get(x, "vram_total")), .graphics_mhz = f64f(get(x, "graphics_mhz")), .memory_mhz = f64f(get(x, "memory_mhz")) };
        s.gpus = g_out;
    }
    {
        const list = rows(get(r, "users"), &.{ "sessions", "users", "user", "rows" });
        const out = try a.alloc(m.UserSession, list.len);
        for (list, out) |x, *o| o.* = .{ .name = text(get(x, "user")), .line = str(get(x, "line")), .from = text(get(x, "host")), .pid = u64f(get(x, "pid")), .login_s = u64f(get(x, "login_time_s")) };
        s.users = out;
    }
    const svc = get(r, "services");
    s.service_manager = text(get(svc, "manager"));
    {
        const list = rows(svc, &.{ "rows", "services", "service" });
        const out = try a.alloc(m.Service, list.len);
        for (list, out) |x, *o| o.* = .{
            .name = str(get(x, "name")), .state = text(get(x, "state")), .pid = u64f(get(x, "pid")),
            .start = u64f(get(x, "start_ticks")), .uid = u64f(get(x, "uid")), .user = text(get(x, "user")),
            .uptime = f64f(get(x, "uptime_s")), .cpu = f64f(get(x, "cpu_pct")), .rss = u64f(get(x, "rss")), .cgroup = text(get(x, "cgroup")),
        };
        s.services = out;
    }
    const apps = get(r, "apps");
    s.apps_manager = text(get(apps, "manager"));
    s.apps_count = u64f(get(apps, "count"));
    s.apps_bytes = u64f(get(apps, "total_size"));
    {
        const list = rows(apps, &.{ "largest", "list", "packages", "rows" });
        const out = try a.alloc(m.Package, list.len);
        for (list, out) |x, *o| o.* = .{ .name = str(get(x, "name")), .version = str(get(x, "version")), .size = u64f(get(x, "size")) };
        s.packages = out;
    }
    const procs = get(r, "processes");
    s.processes_truncated = u64f(get(procs, "truncated")).get() orelse 0;
    {
        const list = rows(procs, &.{ "rows", "processes", "proc" });
        const out = try a.alloc(m.Process, list.len);
        for (list, out) |x, *p| {
            const st = str(get(x, "state"));
            p.* = .{
                .pid = i32f(get(x, "pid")).get() orelse 0,
                .start = u64f(get(x, "start_ticks")).get() orelse 0,
                .ppid = i32f(get(x, "ppid")).get() orelse 0,
                .name = str(get(x, "comm")),
                .cmdline = text(get(x, "cmdline")),
                .user = text(get(x, "user")),
                .uid = u64f(get(x, "uid")),
                .state = if (st.len > 0) st[0] else '?',
                .kernel = (u64f(get(x, "kernel_thread")).get() orelse 0) != 0,
                .cpu = f64f(get(x, "cpu_pct")),
                .rss = u64f(get(x, "rss")),
                .pss = u64f(get(x, "pss")),
                .read_bps = f64f(get(x, "io_read_bps")),
                .write_bps = f64f(get(x, "io_write_bps")),
                .net_bps = f64f(get(x, "net_bps")),
                .threads = u64f(get(x, "threads")),
                .fds = u64f(get(x, "fds")),
                .nice = i32f(get(x, "nice")),
                .cgroup = text(get(x, "cgroup")),
            };
            if (p.nice.get()) |n| p.nice.value = n - 20;
        }
        s.processes = out;
    }
    const info = any(r, &.{ "sysinfo", "info" });
    s.hostname = text(get(info, "hostname"));
    s.kernel = text(get(info, "kernel"));
    s.os = text(get(info, "os"));
    s.arch = text(get(info, "arch"));
    s.init = text(get(info, "init"));
    s.package_manager = text(get(info, "package_manager"));
    if (!s.cpu_model.ok()) s.cpu_model = text(get(info, "cpu_model"));
    s.physical_cores = u64f(get(info, "physical_cores"));
    s.memory_total = u64f(get(info, "memory_total"));
    {
        const list = items(any(info, &.{ "gpus", "gpu" }));
        const out = try a.alloc(m.Text, list.len);
        for (list, out) |x, *o| o.* = text(x);
        s.gpu_names = out;
    }
    const me = get(r, "self");
    s.cost = .{ .wall_ms = f64f(get(me, "wall_ms")), .cpu_ms = f64f(get(me, "cpu_ms")), .cpu_pct = f64f(get(me, "cpu_pct_of_core")), .syscalls = u64f(any(me, &.{ "syscalls_estimate", "syscalls" })) };
    return owned;
}

test "replay keeps unavailable reasons and never invents zeros" {
    const line =
        \\{"abi":1,"sequence":2,"redacted":true,"interval_s":0.5,
        \\ "groups":{"services":{"state":"unavailable","why":"needs privilege","detail":"process metadata: permission denied"},"cpu":{"state":"ok","cost_ns":1200}},
        \\ "summary":{"uptime_s":100.5,"processes":12,"threads":{"state":"unavailable","why":"not collected"}},
        \\ "cpu":{"cpus":[{"id":0,"times":{"busy":12.5},"temp_c":{"state":"unavailable","why":"not present"}}]},
        \\ "power":{"cpu_package_w":{"state":"unavailable","why":"needs privilege"},"sensors":[{"chip":"nvme","label":"Composite","kind":"temp","value":36.85}]},
        \\ "processes":{"rows":[{"pid":1,"start_ticks":27,"comm":"init","cmdline":{"state":"unavailable","why":"redacted"},"cpu_pct":{"v":3,"state":"stale","why":"budget"}}]}}
    ;
    const o = try parseOne(std.testing.allocator, line);
    defer o.destroy();
    const s = &o.snap;
    try std.testing.expect(s.redacted);
    try std.testing.expectEqual(@as(?f64, 100.5), s.uptime_s.get());
    try std.testing.expectEqualStrings("not collected", s.thread_count.reason);
    try std.testing.expect(s.thread_count.get() == null);
    try std.testing.expectEqualStrings("not in sample", s.load1.reason);
    try std.testing.expectEqualStrings("needs privilege", s.cpu_package_power.reason);
    try std.testing.expectEqualStrings("needs privilege", s.group(.services).reason);
    try std.testing.expectEqualStrings("process metadata: permission denied", s.group(.services).detail);
    try std.testing.expectEqual(@as(?u64, 1200), s.group(.cpu).cost_ns);
    try std.testing.expectEqual(@as(?f64, 12.5), s.cpus[0].total.get());
    try std.testing.expectEqualStrings("not present", s.cpus[0].temp_c.reason);
    try std.testing.expectEqual(m.SensorKind.temp, s.sensors[0].kind);
    try std.testing.expectEqualStrings("redacted", s.processes[0].cmdline.why);
    try std.testing.expectEqual(m.Status.stale, s.processes[0].cpu.status);
    try std.testing.expectEqual(@as(?f64, 3), s.processes[0].cpu.get());
    // JSONL: one object per line.
    const one = try std.mem.replaceOwned(u8, std.testing.allocator, line, "\n", "");
    defer std.testing.allocator.free(one);
    const two = try std.mem.concat(std.testing.allocator, u8, &.{ one, "\n", one, "\n" });
    defer std.testing.allocator.free(two);
    var r = try Replay.load(std.testing.allocator, two);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.frames.len);
}


test "service replay preserves process identity, rates and missing fields" {
    const line =
        \\{"abi":1,"services":{"manager":"init: init","rows":[{"name":"daemon","pid":71,"start_ticks":900,"uid":42,"user":"uid:42","state":"S","uptime_s":34.5,"cpu_pct":{"state":"unavailable","why":"first sample"},"rss":4096,"cgroup":"/service"}]}}
    ;
    const o = try parseOne(std.testing.allocator, line);
    defer o.destroy();
    try std.testing.expectEqualStrings("init: init", o.snap.service_manager.s);
    const svc = o.snap.services[0];
    try std.testing.expectEqual(@as(?u64, 71), svc.pid.get());
    try std.testing.expectEqual(@as(?u64, 900), svc.start.get());
    try std.testing.expectEqual(@as(?u64, 42), svc.uid.get());
    try std.testing.expectEqualStrings("uid:42", svc.user.s);
    try std.testing.expectEqualStrings("S", svc.state.s);
    try std.testing.expectEqual(@as(?f64, 34.5), svc.uptime.get());
    try std.testing.expect(svc.cpu.get() == null);
    try std.testing.expectEqualStrings("first sample", svc.cpu.reason);
    try std.testing.expectEqual(@as(?u64, 4096), svc.rss.get());
    try std.testing.expectEqualStrings("/service", svc.cgroup.s);
}
