//! The overview's view of one system sample. Every measured value carries
//! its status; nothing here defaults to a measured zero. Sources (live
//! collector, replay, synthetic) fill a Snapshot whose strings and slices
//! live in the snapshot's own arena.
const std = @import("std");

pub const Status = enum { ok, unavailable, stale };

/// A measured value, or the reason it was not measured.
pub fn Field(comptime T: type) type {
    return struct {
        status: Status = .unavailable,
        value: T = 0,
        reason: []const u8 = "not collected",
        const Self = @This();
        pub fn of(value: T) Self {
            return .{ .status = .ok, .value = value, .reason = "" };
        }
        pub fn missing(reason: []const u8) Self {
            return .{ .reason = reason };
        }
        pub fn get(self: Self) ?T {
            return if (self.status == .unavailable) null else self.value;
        }
    };
}
pub const F = Field(f64);
pub const U = Field(u64);

/// A string that may be unavailable (redacted, needs privilege); `why`
/// is empty when `s` is the measured text.
pub const Text = struct {
    s: []const u8 = "",
    why: []const u8 = "not collected",
    pub fn of(s: []const u8) Text {
        return .{ .s = s, .why = "" };
    }
    pub fn missing(why: []const u8) Text {
        return .{ .why = why };
    }
    pub fn ok(self: Text) bool {
        return self.why.len == 0;
    }
};

pub const Cpu = struct {
    id: u32,
    core: u32 = 0,
    package: u32 = 0,
    /// Last-level cache domain (CCX/CCD on AMD); groups the Performance grid.
    cache: u32 = 0,
    /// Position among the core's SMT siblings (0 = first thread).
    smt: u32 = 0,
    /// Why package/core/cache/SMT are unknown; empty when all were measured.
    /// Unknown topology is never shown as package 0 / core 0.
    topology_why: []const u8 = "",
    /// Null when online state was not measured (reason in online_why).
    online: ?bool = true,
    online_why: []const u8 = "",
    total: F = .{},
    user: F = .{},
    system: F = .{},
    iowait: F = .{},
    irq: F = .{},
    steal: F = .{},
    mhz: F = .{},
    max_mhz: F = .{},
    temp_c: F = .{},
};

pub const Memory = struct {
    total: U = .{},
    used: U = .{},
    free: U = .{},
    available: U = .{},
    cached: U = .{},
    buffers: U = .{},
    shared: U = .{},
    slab: U = .{},
    dirty: U = .{},
    writeback: U = .{},
    committed: U = .{},
    commit_limit: U = .{},
    swap_total: U = .{},
    swap_used: U = .{},
    zswap_pool: U = .{},
    zswap_stored: U = .{},
    major_faults_ps: F = .{},
    swap_in_ps: F = .{},
    swap_out_ps: F = .{},
};

pub const Pressure = struct { some10: F = .{}, some60: F = .{}, full10: F = .{}, full60: F = .{} };

pub const Disk = struct {
    name: []const u8,
    model: Text = .{},
    size: U = .{},
    rotational: bool = false,
    read_bps: F = .{},
    write_bps: F = .{},
    read_iops: F = .{},
    write_iops: F = .{},
    busy: F = .{},
    queue: F = .{},
    latency_ms: F = .{},
    temp_c: F = .{},
};

pub const Mount = struct {
    path: Text,
    device: Text = .{},
    fstype: []const u8 = "",
    total: U = .{},
    used: U = .{},
    available: U = .{},
    used_pct: F = .{},
    inodes_total: U = .{},
    inodes_free: U = .{},
    read_only: bool = false,
};

pub const Net = struct {
    name: []const u8,
    state: Text = .{},
    loopback: bool = false,
    rx_bps: F = .{},
    tx_bps: F = .{},
    rx_pps: F = .{},
    tx_pps: F = .{},
    errors_ps: F = .{},
    drops_ps: F = .{},
    speed_mbps: U = .{},
    mtu: U = .{},
    mac: Text = .{},
    addresses: []const Text = &.{},
};

pub const Connection = struct {
    proto: []const u8,
    family: u8 = 0,
    state: []const u8 = "",
    local: Text = .{},
    remote: Text = .{},
    pid: Field(i32) = .{},
    owner: []const u8 = "",
    rx_queue: U = .{},
    tx_queue: U = .{},
};

pub const SensorKind = enum { temp, fan, voltage, current, power, energy, freq, humidity, pwm, other };
pub fn unit(kind: SensorKind) []const u8 {
    return switch (kind) {
        .temp => "°C",
        .fan => "RPM",
        .voltage => "V",
        .current => "A",
        .power => "W",
        .energy => "J",
        .freq => "MHz",
        .humidity => "%RH",
        .pwm => "%",
        .other => "",
    };
}
pub const Sensor = struct {
    chip: []const u8,
    label: []const u8,
    kind: SensorKind,
    value: F = .{},
    max: F = .{},
    crit: F = .{},
};

/// The reason of the first unmeasured field among `fields`, or "".
pub fn firstMissing(fields: []const U) []const u8 {
    for (fields) |f| if (f.get() == null) return f.reason;
    return "";
}

pub const Gpu = struct {
    card: []const u8,
    driver: []const u8 = "",
    name: Text = .{},
    busy: F = .{},
    power_w: F = .{},
    temp_c: F = .{},
    vram_used: U = .{},
    vram_total: U = .{},
    graphics_mhz: F = .{},
    memory_mhz: F = .{},
};

pub const UserSession = struct {
    name: Text,
    line: []const u8 = "",
    from: Text = .{},
    pid: U = .{},
    login_s: U = .{},
};

pub const Service = struct {
    name: []const u8,
    state: Text = .{},
    pid: U = .{},
    start: U = .{},
    user: Text = .{},
    uid: U = .{},
    uptime: F = .{},
    cpu: F = .{},
    rss: U = .{},
    cgroup: Text = .{},
};
pub const Package = struct { name: []const u8, version: []const u8 = "", size: U = .{} };

pub const Process = struct {
    pid: i32,
    /// Start time in clock ticks after boot: pid + start is the identity.
    start: u64,
    ppid: i32 = 0,
    name: []const u8,
    cmdline: Text = .{},
    user: Text = .{},
    uid: U = .{},
    state: u8 = '?',
    kernel: bool = false,
    cpu: F = .{},
    rss: U = .{},
    pss: U = .{},
    read_bps: F = .{},
    write_bps: F = .{},
    net_bps: F = .{},
    threads: U = .{},
    fds: U = .{},
    nice: Field(i32) = .{},
    cgroup: Text = .{},
};

/// The collector's own cost for this sample.
pub const Cost = struct {
    wall_ms: F = .{},
    cpu_ms: F = .{},
    cpu_pct: F = .{},
    syscalls: U = .{},
};

/// Collector groups, in the contract's order (xrt_sysstat.h).
pub const Group = enum { summary, cpu, memory, disks, filesystems, network, connections, power, users, services, apps, processes, sysinfo };
pub const group_count = @typeInfo(Group).@"enum".fields.len;
pub const GroupState = struct {
    status: Status = .unavailable,
    reason: []const u8 = "not collected",
    detail: []const u8 = "",
    cost_ns: ?u64 = null,
};

pub const Snapshot = struct {
    /// Monotonic sample time and the interval it covers.
    time_ns: u64 = 0,
    interval_s: F = .{},
    sequence: u64 = 0,
    redacted: bool = false,
    groups: [group_count]GroupState = @splat(.{}),
    hostname: Text = .{},
    kernel: Text = .{},
    os: Text = .{},
    arch: Text = .{},
    init: Text = .{},
    package_manager: Text = .{},
    cpu_model: Text = .{},
    freq_driver: Text = .{},
    governor: Text = .{},
    physical_cores: U = .{},
    memory_total: U = .{},
    gpu_names: []const Text = &.{},
    boot_time: U = .{},
    uptime_s: F = .{},
    load1: F = .{},
    load5: F = .{},
    load15: F = .{},
    process_count: U = .{},
    thread_count: U = .{},
    running: U = .{},
    blocked: U = .{},
    context_switches_ps: F = .{},
    interrupts_ps: F = .{},
    forks_ps: F = .{},
    cpu_total: F = .{},
    cpu_user: F = .{},
    cpu_system: F = .{},
    cpu_iowait: F = .{},
    cpu_package_temp: F = .{},
    cpu_temps: []const Sensor = &.{},
    cpus: []const Cpu = &.{},
    memory: Memory = .{},
    psi_cpu: Pressure = .{},
    psi_memory: Pressure = .{},
    psi_io: Pressure = .{},
    disks: []const Disk = &.{},
    mounts: []const Mount = &.{},
    nets: []const Net = &.{},
    net_rx_bps: F = .{},
    net_tx_bps: F = .{},
    connections: []const Connection = &.{},
    connections_truncated: u64 = 0,
    owners_unresolved: U = .{},
    sensors: []const Sensor = &.{},
    gpus: []const Gpu = &.{},
    cpu_package_power: F = .{},
    battery_pct: F = .{},
    users: []const UserSession = &.{},
    services: []const Service = &.{},
    service_manager: Text = .{},
    apps_manager: Text = .{},
    apps_count: U = .{},
    apps_bytes: U = .{},
    packages: []const Package = &.{},
    processes: []const Process = &.{},
    processes_truncated: u64 = 0,
    cost: Cost = .{},
    /// A recorded memory map (replays only; live maps come from the observer).
    memory_map: ?*const @import("../../memdefrag/model.zig").Map = null,
    /// Recorded explicit viewports (uniform cells over a range) for the deep look.
    memory_viewports: []const @import("../../memdefrag/model.zig").Map = &.{},
    /// False for a group copied from an earlier sample (sampled less often).
    fresh: [group_count]bool = @splat(true),
    pub fn group(self: *const Snapshot, g: Group) GroupState {
        return self.groups[@intFromEnum(g)];
    }
};

/// A sample with the arena that owns its strings and slices.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    snap: Snapshot = .{},
    /// A slow group carried into later samples keeps its sample alive.
    refs: u32 = 1,
    pub fn retain(self: *Owned) *Owned {
        self.refs += 1;
        return self;
    }
    pub fn release(self: *Owned) void {
        self.refs -= 1;
        if (self.refs == 0) self.destroy();
    }
    pub fn create(gpa: std.mem.Allocator) !*Owned {
        const self = try gpa.create(Owned);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        return self;
    }
    pub fn destroy(self: *Owned) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// Human units. Writes into `buf` and returns the used part.
pub fn bytes(buf: []u8, value: f64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    var v = value;
    var i: usize = 0;
    while (@abs(v) >= 1024 and i + 1 < units.len) : (i += 1) v /= 1024;
    const precision: usize = if (i == 0 or @abs(v) >= 100) 0 else if (@abs(v) >= 10) 1 else 2;
    return switch (precision) {
        0 => std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[i] }),
        1 => std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[i] }),
        else => std.fmt.bufPrint(buf, "{d:.2} {s}", .{ v, units[i] }),
    } catch "?";
}
pub fn rate(buf: []u8, value: f64) []const u8 {
    var tmp: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/s", .{bytes(&tmp, value)}) catch "?";
}
pub fn duration(buf: []u8, seconds: f64) []const u8 {
    const s: u64 = @intFromFloat(@max(0, seconds));
    const d = s / 86400;
    const h = (s % 86400) / 3600;
    const m = (s % 3600) / 60;
    return (if (d > 0) std.fmt.bufPrint(buf, "{d}d {d:0>2}:{d:0>2}:{d:0>2}", .{ d, h, m, s % 60 }) else std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s % 60 })) catch "?";
}

test "fields never present an unmeasured default as a value" {
    const missing = F.missing("needs privilege");
    try std.testing.expect(missing.get() == null);
    try std.testing.expectEqualStrings("needs privilege", missing.reason);
    const empty = U{};
    try std.testing.expect(empty.get() == null);
    try std.testing.expectEqual(@as(?f64, 0), F.of(0).get());
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.50 KiB", bytes(&b, 1536));
    try std.testing.expectEqualStrings("512 B", bytes(&b, 512));
    try std.testing.expectEqualStrings("1d 01:01:01", duration(&b, 90061));
}
