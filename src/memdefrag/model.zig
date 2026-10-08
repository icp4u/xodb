//! Memory "defrag" presentation model, shared by the overview's Memory map
//! panel and the `xodb --memdefrag` terminal view. One Map is a bounded copy
//! of one observer publication: fixed-size virtual-address cells inside VMAs,
//! the VMA list, THP coverage and the system-wide buddy and vmstat state.
//! It is also the replay and `--json` schema, so a recorded Map renders the
//! same as a live one. Nothing here reads /proc: the observer worker did.
//!
//! Honesty rules (binding UI semantics): unknown is never false or zero; the
//! three kinds of change (page category flip, PMD collapse/split, physical
//! migration) stay separate, and physical migration is never inferred from
//! virtual observations; vmstat activity is system-wide, never attributed to
//! the selected process.
const std = @import("std");
const c = @import("../c.zig").api;

pub const schema = "xodb-memdefrag/1";
pub const default_cell: u64 = 2 * 1024 * 1024;
pub const max_cells: usize = 65536;
/// Unmapped gaps longer than this many cells, and non-resident VMAs longer
/// than `reserved_cells`, are drawn as one compressed marker cell.
pub const gap_cells: u64 = 4;
pub const reserved_cells: u64 = 64;

// Category bits, as in xrt_memstat.h.
pub const present_bit: u64 = c.XRT_MEM_PAGE_PRESENT;
pub const swapped_bit: u64 = c.XRT_MEM_PAGE_SWAPPED;
pub const file_bit: u64 = c.XRT_MEM_PAGE_FILE;
pub const huge_bit: u64 = c.XRT_MEM_PAGE_HUGE;
pub const written_bit: u64 = c.XRT_MEM_PAGE_WRITTEN;
pub const zero_bit: u64 = c.XRT_MEM_PAGE_ZERO;

pub const Status = struct {
    state: []const u8 = "unavailable",
    reason: []const u8 = "not collected",
    pub fn ok(self: Status) bool {
        return std.mem.eql(u8, self.state, "ok");
    }
};
pub const Backend = enum { pagemap_scan, pagemap_flags, none };
pub const VmaKind = enum { anon, file, heap, stack, pseudo, special, hugetlb };

pub const NumaNode = struct { node: u32, pages: u64 };
pub const Vma = struct {
    start: u64,
    end: u64,
    perms: []const u8 = "----",
    kind: VmaKind = .anon,
    /// Null when redacted or unavailable; pseudo names ([heap], [stack]) stay.
    path: ?[]const u8 = null,
    thp_eligible: ?bool = null,
    rss: ?u64 = null,
    anon_huge: ?u64 = null,
    swap: ?u64 = null,
    locked: ?u64 = null,
    /// These are totals for this entire VMA, not locations of individual pages.
    numa_vma_totals: ?[]const NumaNode = null,
    numa_page_size: ?u64 = null,
    numa_partial: bool = false,
};

/// One fixed virtual range. Byte counts are over observed bytes; `known` is
/// the AND of the observed segments' known masks (a clear bit is unknown,
/// never false). `gap` > 0 marks a compressed marker covering [start, end).
pub const Cell = struct {
    start: u64,
    end: u64,
    vma: ?u32 = null,
    mapping_known: bool = true,
    mapped: u64 = 0,
    observed: u64 = 0,
    present: u64 = 0,
    huge: u64 = 0,
    file: u64 = 0,
    swapped: u64 = 0,
    /// Present bytes mapped to the (huge) zero page: not yet backed. Never
    /// counted in `huge`, so HUGE|ZERO is never drawn as THP.
    zero: u64 = 0,
    known: u64 = 0,
    /// (a) page category flips since the previous publication.
    changed: u64 = 0,
    change_known: u64 = 0,
    /// (b) PMD mapping changes: collapsed into / split out of huge mappings.
    pmd_known: bool = false,
    collapsed: u64 = 0,
    split: u64 = 0,
    gap: u64 = 0,
    /// VM_IO / VM_PFNMAP: pages that cannot be migrated.
    special: bool = false,
};

pub const Counter = struct { name: []const u8, value: u64, delta: ?u64 = null };
pub const Zone = struct { node: u32, name: []const u8, blocks: []const u64 };
pub const Setting = struct { name: []const u8, value: ?[]const u8 = null };
pub const System = struct {
    buddy: Status = .{},
    vmstat: Status = .{},
    thp: Status = .{},
    page_size: u64 = 4096,
    /// Interval of the counter deltas; zero on the first publication.
    interval_ns: u64 = 0,
    cpu_ns: u64 = 0,
    zones: []const Zone = &.{},
    counters: []const Counter = &.{},
    settings: []const Setting = &.{},
};

pub const Process = struct {
    pid: i32,
    start_ticks: u64,
    /// Null under redaction; the UI shows a pid+start alias instead.
    name: ?[]const u8 = null,
    maps: Status = .{},
    pages: Status = .{},
    numa: Status = .{},
    backend: Backend = .none,
    page_size: u64 = 4096,
    pmd_size: ?u64 = null,
    coverage_numerator: ?u64 = null,
    coverage_denominator: ?u64 = null,
    rss: ?u64 = null,
    anon_huge: ?u64 = null,
    swap: ?u64 = null,
    mapped_bytes: u64 = 0,
    scanned_bytes: u64 = 0,
    scan_cpu_ns: u64 = 0,
    /// Between this publication and the previous one; zero when unknown.
    interval_ns: u64 = 0,
    vma_count: u32 = 0,
};

pub const Map = struct {
    schema: []const u8 = schema,
    sequence: u64 = 0,
    sampled_ns: u64 = 0,
    redacted: bool = false,
    cell_bytes: u64 = default_cell,
    /// A uniform virtual-address viewport; null means the compact overview.
    range: ?AddressRange = null,
    pending: bool = false,
    /// The observer worker's cumulative thread CPU time (cost indicator).
    worker_cpu_ns: ?u64 = null,
    /// Actual refresh period of the shown scope (process, or system view) and
    /// of the system counters. Expensive maps refresh slower than 1 Hz to hold
    /// the worker's CPU target; zero when not reported.
    refresh_ns: u64 = 0,
    system_refresh_ns: u64 = 0,
    cost_limited: bool = false,
    system_cost_limited: bool = false,
    process: ?Process = null,
    vmas: []const Vma = &.{},
    cells: []const Cell = &.{},
    /// Cells beyond the bound that were not built (zoom in or scroll).
    cells_truncated: u64 = 0,
    system: ?System = null,
};

// --- Classification --------------------------------------------------------------

pub const State = enum {
    unmapped,
    gap,
    reserved,
    unknown,
    not_present,
    swapped,
    file,
    anon,
    mixed,
    thp,
    unmovable,
    free_contig,
    free_frag,
    zero,
};
pub const state_count = @typeInfo(State).@"enum".fields.len;
pub const Change = enum { none, changed, collapsed, split };

pub const Look = struct {
    state: State,
    change: Change = .none,
    /// Part of the mapped range was not observed, or the page size is unknown:
    /// drawn with hatching over the colour.
    partial: bool = false,
    /// THP fraction of present bytes (mixed cells draw it proportionally).
    huge_fraction: f32 = 0,
};

pub fn classify(cell: Cell) Look {
    if (!cell.mapping_known and cell.mapped == 0) return .{ .state = .unknown };
    if (cell.gap > 0) return .{ .state = if (cell.vma != null) .reserved else .gap };
    if (cell.mapped == 0) return .{ .state = .unmapped };
    if (cell.observed == 0 or cell.known & present_bit == 0) return .{ .state = .unknown };
    var look = Look{ .state = .unknown, .partial = !cell.mapping_known or cell.observed < cell.mapped };
    if (cell.special) {
        look.state = .unmovable;
    } else if (cell.present -| cell.zero == 0) {
        // Nothing backed: zero-page mappings (HUGE|ZERO included), swapped or absent.
        look.state = if (cell.zero > 0) .zero else if (cell.known & swapped_bit != 0 and cell.swapped > 0) .swapped else .not_present;
    } else if (cell.known & huge_bit == 0) {
        // Ordinary pagemap fallback: present, page size unknown.
        look.state = if (cell.known & file_bit != 0 and cell.file * 2 >= cell.present) .file else .anon;
        look.partial = true;
    } else if (cell.huge > 0) {
        const backed = cell.present - cell.zero;
        look.state = if (cell.huge >= backed and cell.zero == 0 and cell.present >= cell.mapped) .thp else .mixed;
        look.huge_fraction = @floatCast(@as(f64, @floatFromInt(cell.huge)) / @as(f64, @floatFromInt(cell.mapped)));
    } else {
        look.state = if (cell.known & file_bit != 0 and cell.file * 2 >= cell.present) .file else .anon;
    }
    // A collapse highlight needs real huge pages in the cell now.
    if (cell.pmd_known and cell.collapsed > 0 and (look.state == .thp or look.state == .mixed)) {
        look.change = .collapsed;
    } else if (cell.pmd_known and cell.split > 0) {
        look.change = .split;
    } else if (cell.changed & cell.change_known != 0) {
        look.change = .changed;
    }
    return look;
}

/// Display names, also the Legend's wording.
pub fn stateName(s: State) []const u8 {
    return switch (s) {
        .unmapped => "unmapped gap",
        .gap => "unmapped gap (compressed)",
        .reserved => "mapped, not resident (compressed)",
        .unknown => "unknown: not observed",
        .not_present => "mapped, not present",
        .swapped => "swapped out",
        .file => "file-backed / shared",
        .anon => "4 KiB anonymous",
        .mixed => "partly huge (THP + 4 KiB)",
        .thp => "THP, PMD-mapped (optimized)",
        .unmovable => "unmovable (VM_IO/PFNMAP)",
        .free_contig => "free, in >= 2 MiB blocks",
        .free_frag => "free, in smaller blocks",
        .zero => "zero page, not yet backed",
    };
}
pub fn changeName(k: Change) []const u8 {
    return switch (k) {
        .none => "unchanged",
        .changed => "changed this poll (page state)",
        .collapsed => "collapsed into THP this poll",
        .split => "split from THP this poll",
    };
}

/// Write-like change: pages appeared, were written or are now huge. DOS `W`;
/// every other observed category flip is `r`.
pub fn writeLike(cell: Cell) bool {
    const gained = cell.changed & cell.change_known & (present_bit | written_bit);
    return gained != 0 and cell.present > 0;
}

// --- Coverage and activity ---------------------------------------------------------

pub const Coverage = union(enum) {
    /// Numerator or denominator unknown: drawn hatched, never 0 %.
    unknown: []const u8,
    /// Known zero denominator: nothing is THP-eligible.
    none,
    value: struct { numerator: u64, denominator: u64, fraction: f64 },
};
pub fn coverage(map: *const Map) Coverage {
    const p = map.process orelse return system_coverage(map);
    const d = p.coverage_denominator orelse return .{ .unknown = "eligible span unknown" };
    const n = p.coverage_numerator orelse return .{ .unknown = "huge bytes unknown" };
    if (d == 0) return .none;
    return .{ .value = .{ .numerator = n, .denominator = d, .fraction = std.math.clamp(@as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d)), 0, 1) } };
}
/// System view: free memory held in >= PMD-order blocks, over all free memory.
fn system_coverage(map: *const Map) Coverage {
    const s = map.system orelse return .{ .unknown = "no system sample" };
    if (!s.buddy.ok()) return .{ .unknown = "buddyinfo unavailable" };
    const t = freeTotals(&s);
    if (t.free_pages == 0) return .none;
    return .{ .value = .{ .numerator = t.contig_pages * s.page_size, .denominator = t.free_pages * s.page_size, .fraction = @as(f64, @floatFromInt(t.contig_pages)) / @as(f64, @floatFromInt(t.free_pages)) } };
}
pub fn pmdOrder(page_size: u64) u32 {
    var o: u32 = 0;
    var b = page_size;
    while (b < default_cell and o < 20) : (o += 1) b *= 2;
    return o;
}
pub const FreeTotals = struct { free_pages: u64 = 0, contig_pages: u64 = 0 };
pub fn zoneFree(z: Zone, order: u32) FreeTotals {
    var t = FreeTotals{};
    for (z.blocks, 0..) |n, o| {
        const pages = std.math.shlExact(u64, n, @intCast(@min(o, 63))) catch std.math.maxInt(u64) / 2;
        t.free_pages +|= pages;
        if (o >= order) t.contig_pages +|= pages;
    }
    return t;
}
pub fn freeTotals(s: *const System) FreeTotals {
    var t = FreeTotals{};
    for (s.zones) |z| {
        const zt = zoneFree(z, pmdOrder(s.page_size));
        t.free_pages +|= zt.free_pages;
        t.contig_pages +|= zt.contig_pages;
    }
    return t;
}

pub const SysCell = struct { state: State, zone: u16 };
/// Free memory as cells of `unit` bytes, zone by zone: memory in smaller
/// blocks first, then memory in >= 2 MiB blocks. Counts, not positions: the
/// physical layout needs privilege. Contiguous cells round down, fragmented
/// ones up, so neither is overstated as contiguous.
pub fn systemCells(s: *const System, capacity: usize, out: []SysCell) struct { count: usize, unit: u64 } {
    const t = freeTotals(s);
    var unit: u64 = default_cell;
    const free_bytes = t.free_pages *| s.page_size;
    while (capacity > 0 and free_bytes / unit > capacity -| s.zones.len and unit < (1 << 50)) unit *= 2;
    var n: usize = 0;
    for (s.zones, 0..) |z, zi| {
        const zt = zoneFree(z, pmdOrder(s.page_size));
        const frag = (zt.free_pages - zt.contig_pages) *| s.page_size;
        const contig = zt.contig_pages *| s.page_size;
        const k_frag = (frag + unit - 1) / unit;
        const k_contig = contig / unit;
        for (0..@intCast(@min(k_frag, out.len))) |_| if (n < out.len) {
            out[n] = .{ .state = .free_frag, .zone = @intCast(zi) };
            n += 1;
        };
        for (0..@intCast(@min(k_contig, out.len))) |_| if (n < out.len) {
            out[n] = .{ .state = .free_contig, .zone = @intCast(zi) };
            n += 1;
        };
    }
    return .{ .count = n, .unit = unit };
}

pub fn counter(s: *const System, name: []const u8) ?Counter {
    for (s.counters) |k| if (std.mem.eql(u8, k.name, name)) return k;
    return null;
}
pub fn delta(s: *const System, name: []const u8) ?u64 {
    const k = counter(s, name) orelse return null;
    return k.delta;
}
pub fn setting(s: *const System, name: []const u8) ?[]const u8 {
    for (s.settings) |k| if (std.mem.eql(u8, k.name, name)) return k.value;
    return null;
}
/// The bracketed choice of a sysfs selector ("always [madvise] never").
pub fn selected(value: []const u8) []const u8 {
    const open = std.mem.indexOfScalar(u8, value, '[') orelse return std.mem.trim(u8, value, " \n");
    const close = std.mem.indexOfScalarPos(u8, value, open, ']') orelse return value;
    return value[open + 1 .. close];
}

/// What the kernel did system-wide over the last interval, from vmstat
/// counter deltas only. Never attributed to the selected process.
pub const Activity = struct {
    text: []const u8,
    known: bool,
    busy: bool,
    /// The counter delta that named the activity, and that counter.
    count: u64 = 0,
    counter: []const u8 = "",
};
pub fn activity(map: *const Map) Activity {
    const s = map.system orelse return .{ .text = "Waiting for system counters", .known = false, .busy = false };
    if (!s.vmstat.ok()) return .{ .text = "vmstat unavailable", .known = false, .busy = false };
    if (s.interval_ns == 0) return .{ .text = "Measuring (first interval)", .known = false, .busy = false };
    const pick = [_]struct { names: []const []const u8, text: []const u8 }{
        .{ .names = &.{ "compact_daemon_migrate_scanned", "compact_daemon_wake" }, .text = "kcompactd compacting memory" },
        .{ .names = &.{ "compact_stall", "compact_migrate_scanned" }, .text = "Direct compaction" },
        .{ .names = &.{"thp_collapse_alloc"}, .text = "Collapsing huge pages" },
        .{ .names = &.{ "thp_split_pmd", "thp_split_page" }, .text = "Splitting huge pages" },
        .{ .names = &.{"thp_fault_alloc"}, .text = "Allocating huge pages on fault" },
    };
    var any_known = false;
    for (pick) |p| {
        for (p.names) |name| if (delta(&s, name)) |d| {
            any_known = true;
            if (d > 0) return .{ .text = p.text, .known = true, .busy = true, .count = d, .counter = name };
        };
    }
    if (!any_known) return .{ .text = "THP/compaction counters unavailable", .known = false, .busy = false };
    return .{ .text = "Idle", .known = true, .busy = false };
}

/// How fresh the shown data is. A refresh slower than the 1 s minimum means
/// the worker throttled itself to hold its CPU target (cost-limited).
pub const Cadence = struct { refresh_s: ?f64, cost_limited: bool, age_s: ?f64 };
pub fn cadence(map: *const Map, now: ?u64) Cadence {
    const r: ?f64 = if (map.refresh_ns == 0) null else @as(f64, @floatFromInt(map.refresh_ns)) / 1e9;
    const age: ?f64 = if (now) |t| (if (map.sampled_ns == 0 or t < map.sampled_ns) null else @as(f64, @floatFromInt(t - map.sampled_ns)) / 1e9) else null;
    return .{ .refresh_s = r, .cost_limited = map.cost_limited, .age_s = age };
}
/// "Refresh 5.0 s (cost-limited)", "Refresh 1.0 s" or "Refresh unknown".
pub fn cadenceText(buf: []u8, k: Cadence) []const u8 {
    const r = k.refresh_s orelse return "Refresh unknown";
    return std.fmt.bufPrint(buf, "Refresh {d:.1} s{s}", .{ r, if (k.cost_limited) " (cost-limited)" else "" }) catch "";
}
/// "age 2.1 s", or "recorded" for a replay (no live clock).
pub fn ageText(buf: []u8, k: Cadence) []const u8 {
    const a = k.age_s orelse return "recorded";
    return std.fmt.bufPrint(buf, "age {d:.1} s", .{a}) catch "";
}

/// Why a process has no map: exited, a reused pid, denied and unavailable
/// read differently. Null when the map is usable (also when partial).
pub fn processProblem(buf: []u8, p: Process) ?[]const u8 {
    const st = p.maps.state;
    if (std.mem.eql(u8, st, "pending")) return std.fmt.bufPrint(buf, "Waiting for memory map of process {d}", .{p.pid}) catch "Waiting for memory map";
    if (std.mem.eql(u8, st, "ok") or std.mem.eql(u8, st, "partial")) return null;
    if (std.mem.eql(u8, st, "exited")) return std.fmt.bufPrint(buf, "Process {d} exited", .{p.pid}) catch "Process exited";
    if (std.mem.eql(u8, st, "identity_changed")) return std.fmt.bufPrint(buf, "pid {d} now belongs to another process (start changed)", .{p.pid}) catch "Identity changed";
    if (std.mem.eql(u8, st, "denied")) return std.fmt.bufPrint(buf, "Access denied: {s}", .{p.maps.reason}) catch "Access denied";
    return std.fmt.bufPrint(buf, "Map unavailable: {s}", .{p.maps.reason}) catch "Map unavailable";
}

/// Stable alias for a redacted process, from pid + start (same as the
/// overview's Processes alias, so both views name a process alike).
pub fn alias(buf: *[24]u8, pid: i32, start: u64) []const u8 {
    var key: [12]u8 = undefined;
    std.mem.writeInt(i32, key[0..4], pid, .little);
    std.mem.writeInt(u64, key[4..12], start, .little);
    const hv: u32 = @truncate(std.hash.Wyhash.hash(0x0a26, &key));
    return std.fmt.bufPrint(buf, "proc-{x:0>5}", .{hv & 0xfffff}) catch "proc";
}
pub fn processLabel(buf: *[24]u8, p: Process) []const u8 {
    return p.name orelse alias(buf, p.pid, p.start_ticks);
}
pub fn vmaLabel(v: Vma) []const u8 {
    if (v.path) |path| if (path.len > 0) return path;
    return switch (v.kind) {
        .anon => "[anonymous]",
        .file => "file (path hidden)",
        .heap => "[heap]",
        .stack => "[stack]",
        .pseudo => "[kernel pseudo-mapping]",
        .special => "[I/O or PFN mapping]",
        .hugetlb => "[hugetlbfs]",
    };
}
pub fn knownText(buf: []u8, mask: u64) []const u8 {
    var w: usize = 0;
    const names = [_]struct { u64, []const u8 }{ .{ present_bit, "present" }, .{ swapped_bit, "swapped" }, .{ file_bit, "file" }, .{ huge_bit, "huge" }, .{ zero_bit, "zero" }, .{ written_bit, "written" } };
    for (names) |n| if (mask & n[0] != 0) {
        const piece = std.fmt.bufPrint(buf[w..], "{s}{s}", .{ if (w > 0) "," else "", n[1] }) catch break;
        w += piece.len;
    };
    return if (w == 0) "none" else buf[0..w];
}

// --- Building from the observer publication --------------------------------------

pub const AddressRange = struct { start: u64, end: u64 };
pub const Request = struct {
    cell_bytes: u64 = default_cell,
    /// Zoomed compact views start at this address, aligned down to cell size.
    anchor: u64 = 0,
    /// Explicit viewports retain every fixed cell, including unmapped gaps.
    range: ?AddressRange = null,
    numa: bool = false,
    redact: bool = false,
    limit: usize = max_cells,

    pub fn check(self: Request, page_size: u64) !void {
        if (page_size == 0 or self.cell_bytes < page_size or self.cell_bytes % page_size != 0 or
            self.limit == 0 or self.limit > max_cells) return error.MemoryMapInvalid;
        if (self.range) |r| {
            if (r.end <= r.start or r.start % self.cell_bytes != 0 or r.end % self.cell_bytes != 0)
                return error.MemoryMapInvalid;
            if ((r.end - r.start) / self.cell_bytes > self.limit) return error.MemoryMapTooLarge;
        }
    }
    pub fn observation(self: Request, who: Identity) c.struct_xrt_mem_request {
        var r = std.mem.zeroes(c.struct_xrt_mem_request);
        r.pid = who.pid;
        r.start_ticks = who.start;
        if (self.numa) r.flags |= c.XRT_MEM_NUMA;
        if (self.range) |span| {
            r.range_start = span.start;
            r.range_end = span.end;
        }
        return r;
    }
};

fn status(s: c.struct_xrt_mem_status) Status {
    const state: []const u8 = switch (s.state) {
        c.XRT_MEM_OK => "ok",
        c.XRT_MEM_UNAVAILABLE => "unavailable",
        c.XRT_MEM_DENIED => "denied",
        c.XRT_MEM_EXITED => "exited",
        c.XRT_MEM_IDENTITY_CHANGED => "identity_changed",
        c.XRT_MEM_PARTIAL => "partial",
        else => "invalid",
    };
    return .{ .state = state, .reason = std.mem.sliceTo(&s.reason, 0) };
}
fn copyStatus(a: std.mem.Allocator, s: c.struct_xrt_mem_status) !Status {
    const st = status(s);
    return .{ .state = st.state, .reason = try a.dupe(u8, st.reason) };
}
fn known(value: u64, mask: u64, bit: u64) ?u64 {
    return if (mask & bit != 0) value else null;
}
fn safeText(a: std.mem.Allocator, bytes: []const u8) !?[]const u8 {
    if (bytes.len == 0 or bytes.len > 4096 or !std.unicode.utf8ValidateSlice(bytes)) return null;
    for (bytes) |ch| if (ch < 32 or ch == 127) return null;
    return try a.dupe(u8, bytes);
}
const pseudo_names = [_][]const u8{ "[heap]", "[stack]", "[vdso]", "[vvar]", "[vvar_vclock]", "[vsyscall]", "[uprobes]" };

fn vmaOf(a: std.mem.Allocator, p: *const c.struct_xrt_mem_process, i: usize, redact: bool) !Vma {
    const v = p.vmas[i];
    const path_ok = v.flags & c.XRT_MEM_PATH_CUT == 0 and @as(u64, v.path) + v.path_length <= p.path_length;
    const raw: []const u8 = if (path_ok and v.path_length > 0) p.paths[v.path..][0..v.path_length] else "";
    var kind: VmaKind = if (v.inode != 0 or v.dev_major != 0 or v.dev_minor != 0) .file else .anon;
    var pseudo = false;
    for (pseudo_names) |name| if (std.mem.eql(u8, raw, name)) {
        pseudo = true;
        kind = if (std.mem.eql(u8, name, "[heap]")) .heap else if (std.mem.eql(u8, name, "[stack]")) .stack else .pseudo;
    };
    if (v.flags & c.XRT_MEM_VMA_HUGETLB != 0) kind = .hugetlb;
    if (v.flags & c.XRT_MEM_VMA_SPECIAL != 0) kind = .special;
    var nodes: ?[]const NumaNode = null;
    if (v.numa_available != 0) {
        const copied = try a.alloc(NumaNode, @min(v.numa_count, v.numa.len));
        for (copied, 0..) |*node, j| node.* = .{ .node = v.numa[j].node, .pages = v.numa[j].pages };
        nodes = copied;
    }
    return .{
        .start = v.start,
        .end = v.end,
        .perms = try a.dupe(u8, v.permissions[0..4]),
        .kind = kind,
        .path = if (redact and !pseudo) null else try safeText(a, raw),
        .thp_eligible = if (v.known & c.XRT_MEM_ELIGIBLE != 0) v.thp_eligible != 0 else null,
        .rss = known(v.rss, v.known, c.XRT_MEM_RSS),
        .anon_huge = known(v.anon_huge, v.known, c.XRT_MEM_ANON_HUGE),
        .swap = known(v.swap, v.known, c.XRT_MEM_SWAP),
        .locked = known(v.locked, v.known, c.XRT_MEM_LOCKED),
        .numa_vma_totals = nodes,
        .numa_page_size = if (v.numa_page_size != 0) v.numa_page_size else null,
        .numa_partial = v.flags & c.XRT_MEM_NUMA_CUT != 0,
    };
}

/// Page-state bytes of [s, e) from the published ranges. `cursor` advances
/// monotonically because cells are emitted in address order.
fn measure(p: *const c.struct_xrt_mem_process, cursor: *usize, cell: *Cell) void {
    const ranges = p.ranges[0..p.range_count];
    while (cursor.* < ranges.len and ranges[cursor.*].end <= cell.start) cursor.* += 1;
    var known_all: u64 = std.math.maxInt(u64);
    var j = cursor.*;
    while (j < ranges.len and ranges[j].start < cell.end) : (j += 1) {
        const r = ranges[j];
        if (r.backend == c.XRT_MEM_BACKEND_NONE) continue;
        const lo = @max(r.start, cell.start);
        const hi = @min(r.end, cell.end);
        if (hi <= lo) continue;
        const ov = hi - lo;
        cell.observed += ov;
        known_all &= r.known;
        if (r.categories & r.known & present_bit != 0) cell.present += ov;
        // The huge zero page reports HUGE|ZERO: count it as zero, never as THP.
        if (r.categories & r.known & zero_bit != 0) {
            cell.zero += ov;
        } else if (r.categories & r.known & huge_bit != 0) cell.huge += ov;
        if (r.categories & r.known & file_bit != 0) cell.file += ov;
        if (r.categories & r.known & swapped_bit != 0) cell.swapped += ov;
    }
    cell.known = if (cell.observed == 0) 0 else known_all;
}

/// The VMA index containing or following `address` (binary search).
fn vmaAt(p: *const c.struct_xrt_mem_process, address: u64) usize {
    var lo: usize = 0;
    var hi: usize = p.vma_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (p.vmas[mid].end <= address) lo = mid + 1 else hi = mid;
    }
    return lo;
}

const Builder = struct {
    a: std.mem.Allocator,
    p: *const c.struct_xrt_mem_process,
    previous: ?*const c.struct_xrt_mem_process,
    cells: std.ArrayList(Cell) = .empty,
    limit: usize,
    truncated: u64 = 0,
    cursor: usize = 0,

    fn full(self: *Builder) bool {
        return self.cells.items.len >= self.limit;
    }
    fn marker(self: *Builder, start: u64, end: u64, vma: ?u32) !void {
        if (self.full()) {
            self.truncated += 1;
            return;
        }
        try self.cells.append(self.a, .{ .start = start, .end = end, .vma = vma, .gap = end - start, .mapping_known = vma != null or self.p.maps_status.state == c.XRT_MEM_OK, .mapped = if (vma != null) end - start else 0 });
    }
    fn cell(self: *Builder, start: u64, end: u64) !void {
        if (self.full()) {
            self.truncated += 1;
            return;
        }
        var out = Cell{ .start = start, .end = end, .mapping_known = false };
        var raw: c.struct_xrt_mem_cell = undefined;
        if (c.xrt_mem_cell_read(self.p, self.previous, start, end, &raw) != 0) {
            out.mapping_known = raw.mapping_known != 0;
            out.mapped = raw.mapped_bytes;
            out.changed = raw.changed_categories;
            out.change_known = raw.change_known;
            out.pmd_known = raw.pmd_change_known != 0;
            out.collapsed = raw.collapsed_bytes;
            out.split = raw.split_bytes;
        }
        const i = vmaAt(self.p, start);
        if (i < self.p.vma_count and self.p.vmas[i].start < end) {
            out.vma = @intCast(i);
            // Any VM_IO/PFNMAP VMA in the cell makes it unmovable.
            var k = i;
            while (k < self.p.vma_count and self.p.vmas[k].start < end) : (k += 1) {
                if (self.p.vmas[k].flags & c.XRT_MEM_VMA_SPECIAL != 0) out.special = true;
            }
        }
        measure(self.p, &self.cursor, &out);
        try self.cells.append(self.a, out);
    }
};

/// Builds a Map from an acquired observer view. Call while holding the
/// publication (between xrt_memobserver_acquire and release); every string
/// and slice is copied into `a`, so the result outlives the release.
pub fn fromView(a: std.mem.Allocator, view: *const c.struct_xrt_mem_view, scope: ?*const c.struct_xrt_mem_scope, req: Request) !Map {
    try req.check(1);
    var map = Map{ .range = req.range, .redacted = req.redact, .cell_bytes = req.cell_bytes, .worker_cpu_ns = view.owner_cpu_ns, .sequence = view.system_sequence, .sampled_ns = view.system_sampled_ns, .refresh_ns = view.system_refresh_ns, .system_refresh_ns = view.system_refresh_ns, .cost_limited = view.system_cost_limited != 0, .system_cost_limited = view.system_cost_limited != 0 };
    if (view.system != null) map.system = try systemOf(a, view.system);
    const sc = scope orelse return map;
    const p: *const c.struct_xrt_mem_process = sc.snapshot orelse return map;
    map.sequence = sc.sequence;
    map.sampled_ns = sc.sampled_ns;
    map.refresh_ns = sc.refresh_ns;
    map.cost_limited = sc.cost_limited != 0;
    const name = std.mem.sliceTo(&p.name, 0);
    map.process = .{
        .pid = p.pid,
        .start_ticks = if (sc.bound_start != 0) sc.bound_start else p.start_ticks,
        .name = if (req.redact or p.maps_status.state == c.XRT_MEM_DENIED or name.len == 0) null else try safeText(a, name),
        .maps = try copyStatus(a, p.maps_status),
        .pages = try copyStatus(a, p.pages_status),
        .numa = try copyStatus(a, p.numa_status),
        .backend = backendOf(p),
        .page_size = p.page_size,
        .pmd_size = if (p.pmd_size_known != 0) p.pmd_size else null,
        .coverage_numerator = if (p.coverage_numerator_known != 0) p.coverage_numerator else null,
        .coverage_denominator = if (p.coverage_denominator_known != 0) p.coverage_denominator else null,
        .rss = known(p.rss, p.totals_known, c.XRT_MEM_RSS),
        .anon_huge = known(p.anon_huge, p.totals_known, c.XRT_MEM_ANON_HUGE),
        .swap = known(p.swap, p.totals_known, c.XRT_MEM_SWAP),
        .mapped_bytes = p.mapped_bytes,
        .scanned_bytes = p.scanned_bytes,
        .scan_cpu_ns = p.cpu_ns,
        .interval_ns = sc.delta_interval_ns,
        .vma_count = p.vma_count,
    };
    const vmas = try a.alloc(Vma, p.vma_count);
    for (vmas, 0..) |*v, i| v.* = try vmaOf(a, p, i, req.redact);
    map.vmas = vmas;
    if (p.page_size == 0) return map;
    try req.check(p.page_size);
    var b = Builder{ .a = a, .p = p, .previous = sc.previous, .limit = req.limit };
    const B = req.cell_bytes;
    if (req.range) |span| {
        try b.cells.ensureTotalCapacityPrecise(a, @intCast((span.end - span.start) / B));
        var at = span.start;
        while (at < span.end) : (at += B) try b.cell(at, at + B);
        map.cells = try b.cells.toOwnedSlice(a);
        return map;
    }
    const anchor = req.anchor - req.anchor % B;
    var next: u64 = 0;
    for (p.vmas[0..p.vma_count], 0..) |v, i| {
        if (v.end <= anchor) continue;
        var first = @max(v.start - v.start % B, anchor);
        const last = std.math.add(u64, v.end, B - 1) catch v.end;
        const stop = last - last % B;
        if (first < next) first = next;
        if (first >= stop) continue;
        if (next != 0 and first > next) {
            if ((first - next) / B <= gap_cells) {
                var at = next;
                while (at < first) : (at += B) try b.cell(at, at + B);
            } else try b.marker(next, first, null);
        }
        // A large VMA with nothing resident reads as one reserved marker.
        const rss = known(v.rss, v.known, c.XRT_MEM_RSS);
        if (rss != null and rss.? == 0 and v.swap == 0 and (stop - first) / B > reserved_cells and first == v.start - v.start % B) {
            try b.marker(first, stop, @intCast(i));
        } else {
            var at = first;
            while (at < stop) : (at += B) {
                if (b.full()) {
                    b.truncated += (stop - at) / B;
                    break;
                }
                try b.cell(at, at + B);
            }
        }
        next = stop;
    }
    map.cells = try b.cells.toOwnedSlice(a);
    map.cells_truncated = b.truncated;
    return map;
}

fn backendOf(p: *const c.struct_xrt_mem_process) Backend {
    var scan = false;
    var flags = false;
    for (p.ranges[0..p.range_count]) |r| switch (r.backend) {
        c.XRT_MEM_BACKEND_SCAN => scan = true,
        c.XRT_MEM_BACKEND_PAGEMAP => flags = true,
        else => {},
    };
    return if (scan) .pagemap_scan else if (flags) .pagemap_flags else .none;
}

const counter_names = [_][]const u8{ "thp_fault_alloc", "thp_fault_fallback", "thp_collapse_alloc", "thp_collapse_alloc_failed", "thp_split_page", "thp_split_pmd", "thp_deferred_split_page", "compact_stall", "compact_fail", "compact_success", "compact_migrate_scanned", "compact_free_scanned", "compact_daemon_wake", "compact_daemon_migrate_scanned", "pgmigrate_success" };
const setting_names = [_][]const u8{ "enabled", "defrag", "khugepaged/pages_collapsed", "khugepaged/full_scans", "khugepaged/pages_to_scan", "khugepaged/scan_sleep_millisecs" };

fn systemOf(a: std.mem.Allocator, s: *const c.struct_xrt_mem_system) !System {
    var out = System{ .buddy = try copyStatus(a, s.buddy_status), .vmstat = try copyStatus(a, s.vmstat_status), .thp = try copyStatus(a, s.thp_status), .page_size = s.page_size, .interval_ns = s.delta_interval_ns, .cpu_ns = s.cpu_ns };
    const zones = try a.alloc(Zone, s.zone_count);
    for (zones, s.zones[0..s.zone_count]) |*z, raw| {
        z.* = .{ .node = raw.node, .name = try a.dupe(u8, std.mem.sliceTo(&raw.name, 0)), .blocks = try a.dupe(u64, raw.blocks[0..@min(raw.orders, c.XRT_MEM_MAX_ORDERS)]) };
    }
    out.zones = zones;
    var counters: std.ArrayList(Counter) = .empty;
    for (s.counters[0..s.counter_count]) |k| {
        const name = std.mem.sliceTo(&k.name, 0);
        for (counter_names) |want| if (std.mem.eql(u8, name, want)) {
            try counters.append(a, .{ .name = try a.dupe(u8, name), .value = k.value, .delta = if (k.delta_known != 0) k.delta else null });
        };
    }
    out.counters = try counters.toOwnedSlice(a);
    var settings: std.ArrayList(Setting) = .empty;
    for (s.settings[0..s.setting_count]) |k| {
        const name = std.mem.sliceTo(&k.name, 0);
        for (setting_names) |want| if (std.mem.eql(u8, name, want)) {
            try settings.append(a, .{ .name = try a.dupe(u8, name), .value = if (k.status.state == c.XRT_MEM_OK) try safeText(a, std.mem.trim(u8, std.mem.sliceTo(&k.value, 0), " \n")) else null });
        };
    }
    out.settings = try settings.toOwnedSlice(a);
    return out;
}

// --- Observer access ---------------------------------------------------------------

pub const Identity = struct { pid: i32, start: u64 };

/// Renews demand for one process (or the system only) and, when a newer
/// publication exists, copies it into a fresh arena. Returns null when
/// nothing changed or the publication was busy (try again next frame).
pub const Reader = struct {
    const Demand = struct { id: ?Identity, range: ?AddressRange, numa: bool };
    ticket: u64 = 0,
    seen_ticket: u64 = 0,
    seen_scope: u64 = 0,
    seen_system: u64 = 0,
    seen_any: bool = false,
    requested_ns: u64 = 0,
    copy_ns: u64 = 0,
    demand: ?Demand = null,
    projected: ?Request = null,
    projected_id: ?Identity = null,

    pub fn reset(self: *Reader) void {
        self.* = .{};
    }
    pub fn renew(self: *Reader, observer: *c.struct_xrt_memobserver, id: ?Identity, req: Request, now: u64) !void {
        const page = c.sysconf(c._SC_PAGESIZE);
        if (page <= 0) return error.MemoryMapInvalid;
        try req.check(@intCast(page));
        const wanted: ?Demand = .{ .id = id, .range = req.range, .numa = req.numa };
        if (!std.meta.eql(self.demand, wanted)) {
            self.demand = wanted;
            self.ticket = 0;
            self.seen_any = false;
        }
        // Bound changing viewport demand to 1 Hz too. Old shared leases expire
        // normally; never retarget a cache another reader might still hold.
        if (self.requested_ns != 0 and now -| self.requested_ns < 1_000_000_000) return;
        if (id) |who| {
            const r = req.observation(who);
            const t = c.xrt_memobserver_process(observer, &r);
            if (t == 0) return; // busy or full: retain pending and retry
            self.ticket = t;
        } else {
            self.ticket = 0;
            if (c.xrt_memobserver_system(observer) == 0) return;
        }
        self.requested_ns = now;
    }
    pub fn read(self: *Reader, gpa: std.mem.Allocator, observer: *c.struct_xrt_memobserver, id: ?Identity, req: Request) !?*Owned {
        var view: c.struct_xrt_mem_view = undefined;
        if (c.xrt_memobserver_acquire(observer, &view) == 0) return null;
        defer c.xrt_memobserver_release(observer);
        return self.project(gpa, &view, id, req);
    }
    fn project(self: *Reader, gpa: std.mem.Allocator, view: *const c.struct_xrt_mem_view, id: ?Identity, req: Request) !?*Owned {
        var scope: ?*const c.struct_xrt_mem_scope = null;
        if (id) |who| {
            const wanted = req.observation(who);
            if (self.ticket != 0) for (&view.scopes) |*s| {
                if (s.ticket == self.ticket and s.request.pid == who.pid and
                    (who.start == 0 or s.bound_start == who.start or s.request.start_ticks == who.start) and
                    s.request.flags == wanted.flags and s.request.range_start == wanted.range_start and
                    s.request.range_end == wanted.range_end) scope = s;
            };
        }
        const scope_seq = if (scope) |s| s.sequence else 0;
        const scope_ticket = if (scope) |s| s.ticket else 0;
        if (self.seen_any and scope_ticket == self.seen_ticket and scope_seq == self.seen_scope and
            view.system_sequence == self.seen_system and std.meta.eql(self.projected, @as(?Request, req)) and
            std.meta.eql(self.projected_id, id)) return null;
        const started = threadNs();
        const owned = try Owned.create(gpa);
        errdefer owned.destroy();
        owned.map = try fromView(owned.arena.allocator(), view, scope, req);
        if (id) |who| if (scope == null or scope.?.snapshot == null) {
            owned.map.pending = true;
            owned.map.process = .{ .pid = who.pid, .start_ticks = who.start, .page_size = 0, .maps = .{ .state = "pending", .reason = "Waiting for requested memory map publication" }, .pages = .{ .state = "pending", .reason = "Requested viewport has not been sampled" } };
        };
        self.seen_ticket = scope_ticket;
        self.seen_scope = scope_seq;
        self.seen_system = view.system_sequence;
        self.projected = req;
        self.projected_id = id;
        self.seen_any = true;
        self.copy_ns = threadNs() -| started;
        return owned;
    }
};

pub fn threadNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.THREAD_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// A Map with the arena that owns it.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    map: Map = .{},
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

// --- JSON (replay and --json) --------------------------------------------------------

pub fn toJson(a: std.mem.Allocator, map: *const Map) ![]u8 {
    return std.json.Stringify.valueAlloc(a, map.*, .{});
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Map {
    const map = try std.json.parseFromSliceLeaky(Map, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    try validate(&map);
    return map;
}
pub fn fromValue(a: std.mem.Allocator, value: std.json.Value) !Map {
    const map = try std.json.parseFromValueLeaky(Map, a, value, .{ .ignore_unknown_fields = true });
    try validate(&map);
    return map;
}
/// Replay input is untrusted: reject what the views would misdraw.
pub fn validate(map: *const Map) !void {
    if (!std.mem.eql(u8, map.schema, schema)) return error.MemoryMapSchema;
    if (map.cells.len > max_cells) return error.MemoryMapTooLarge;
    if (map.cell_bytes == 0) return error.MemoryMapInvalid;
    if (map.range) |span| {
        try (Request{ .cell_bytes = map.cell_bytes, .range = span }).check(1);
        const count = (span.end - span.start) / map.cell_bytes;
        if (map.cells.len != 0 and map.cells.len != count) return error.MemoryMapInvalid;
        if (map.process == null and map.cells.len != 0) return error.MemoryMapInvalid;
        if (!map.pending and map.process != null and map.process.?.page_size != 0 and
            map.cells.len != (span.end - span.start) / map.cell_bytes) return error.MemoryMapInvalid;
    }
    if (map.pending and map.cells.len != 0) return error.MemoryMapInvalid;
    for (map.vmas) |v| if (v.numa_vma_totals) |nodes| {
        if (nodes.len > 16) return error.MemoryMapInvalid;
    };
    var last: u64 = 0;
    for (map.cells, 0..) |cell, index| {
        if (map.range) |span| {
            const first = span.start + @as(u64, @intCast(index)) * map.cell_bytes;
            if (cell.start != first or cell.end -| cell.start != map.cell_bytes or cell.gap != 0)
                return error.MemoryMapInvalid;
        }
        if (cell.end <= cell.start or cell.start < last) return error.MemoryMapInvalid;
        if (cell.observed > cell.end - cell.start or cell.mapped > cell.end - cell.start) return error.MemoryMapInvalid;
        if (cell.vma) |i| if (i >= map.vmas.len) return error.MemoryMapInvalid;
        last = cell.end;
    }
    if (map.system) |s| for (s.zones) |z| if (z.blocks.len > c.XRT_MEM_MAX_ORDERS) return error.MemoryMapInvalid;
}

// --- Tests ---------------------------------------------------------------------------

test "cells classify honestly: unknown is never a state, three changes stay apart" {
    const B = default_cell;
    const all = present_bit | swapped_bit | file_bit | huge_bit;
    try std.testing.expectEqual(State.unmapped, classify(.{ .start = 0, .end = B }).state);
    try std.testing.expectEqual(State.unknown, classify(.{ .start = 0, .end = B, .mapped = B }).state);
    try std.testing.expectEqual(State.thp, classify(.{ .start = 0, .end = B, .mapped = B, .observed = B, .present = B, .huge = B, .known = all }).state);
    try std.testing.expectEqual(State.mixed, classify(.{ .start = 0, .end = B, .mapped = B, .observed = B, .present = B, .huge = B / 2, .known = all }).state);
    try std.testing.expectEqual(State.anon, classify(.{ .start = 0, .end = B, .mapped = B, .observed = B, .present = B, .known = all }).state);
    // Plain pagemap: present but huge unknown is hatched, never THP or 4 KiB.
    const fallback = classify(.{ .start = 0, .end = B, .mapped = B, .observed = B, .present = B, .known = present_bit | swapped_bit | file_bit });
    try std.testing.expect(fallback.partial);
    try std.testing.expectEqual(State.swapped, classify(.{ .start = 0, .end = B, .mapped = B, .observed = B, .swapped = B, .known = all }).state);
    try std.testing.expectEqual(State.not_present, classify(.{ .start = 0, .end = B, .mapped = B, .observed = B, .known = all }).state);
    try std.testing.expectEqual(State.unmovable, classify(.{ .start = 0, .end = B, .mapped = B, .observed = B, .present = B, .known = all, .special = true }).state);
    const thp = Cell{ .start = 0, .end = B, .mapped = B, .observed = B, .present = B, .huge = B, .known = all };
    var x = thp;
    x.pmd_known = true;
    x.collapsed = B;
    try std.testing.expectEqual(Change.collapsed, classify(x).change);
    x.collapsed = 0;
    x.split = B;
    try std.testing.expectEqual(Change.split, classify(x).change);
    // A split without a known PMD comparison is not shown.
    x.pmd_known = false;
    try std.testing.expectEqual(Change.none, classify(x).change);
    x.changed = present_bit;
    try std.testing.expectEqual(Change.none, classify(x).change);
    x.change_known = present_bit;
    try std.testing.expectEqual(Change.changed, classify(x).change);
    try std.testing.expect(writeLike(x));
}

test "the huge zero page is never THP, and exited is not unavailable" {
    const B = default_cell;
    const all = present_bit | swapped_bit | file_bit | huge_bit | zero_bit;
    try std.testing.expectEqual(State.zero, classify(.{ .start = 0, .end = B, .mapped = B, .observed = B, .present = B, .zero = B, .known = all }).state);
    // A HUGE flip into the zero page is not drawn as a collapse.
    try std.testing.expectEqual(Change.none, classify(.{ .start = 0, .end = B, .mapped = B, .observed = B, .present = B, .zero = B, .known = all, .pmd_known = true, .collapsed = B }).change);
    var b: [96]u8 = undefined;
    var p = Process{ .pid = 9, .start_ticks = 1, .maps = .{ .state = "exited", .reason = "" } };
    try std.testing.expectEqualStrings("Process 9 exited", processProblem(&b, p).?);
    p.maps = .{ .state = "unavailable", .reason = "smaps: busy" };
    try std.testing.expectEqualStrings("Map unavailable: smaps: busy", processProblem(&b, p).?);
    p.maps = .{ .state = "partial", .reason = "" };
    try std.testing.expect(processProblem(&b, p) == null);
}

test "coverage stays unknown without a denominator and is not 0 %" {
    var map = Map{ .process = .{ .pid = 1, .start_ticks = 2, .coverage_numerator = 0 } };
    try std.testing.expect(coverage(&map) == .unknown);
    map.process.?.coverage_denominator = 0;
    try std.testing.expect(coverage(&map) == .none);
    map.process.?.coverage_denominator = 4 * default_cell;
    map.process.?.coverage_numerator = default_cell;
    try std.testing.expectEqual(@as(f64, 0.25), coverage(&map).value.fraction);
}

test "activity text comes only from known vmstat deltas" {
    var map = Map{ .system = .{ .vmstat = .{ .state = "ok", .reason = "" }, .interval_ns = 0 } };
    try std.testing.expect(!activity(&map).known);
    map.system.?.interval_ns = 1_000_000_000;
    try std.testing.expect(!activity(&map).known);
    const idle = [_]Counter{ .{ .name = "thp_collapse_alloc", .value = 5, .delta = 0 }, .{ .name = "compact_stall", .value = 1, .delta = 0 } };
    map.system.?.counters = &idle;
    try std.testing.expect(activity(&map).known and !activity(&map).busy);
    const busy = [_]Counter{ .{ .name = "thp_collapse_alloc", .value = 9, .delta = 4 }, .{ .name = "compact_stall", .value = 1, .delta = null } };
    map.system.?.counters = &busy;
    try std.testing.expect(std.mem.startsWith(u8, activity(&map).text, "Collapsing"));
}

test "cadence reports cost-limited refresh and age, never invented" {
    var map = Map{ .refresh_ns = 5_000_000_000, .sampled_ns = 10_000_000_000, .cost_limited = true };
    const k = cadence(&map, 12_000_000_000);
    try std.testing.expect(k.cost_limited and k.age_s.? == 2);
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Refresh 5.0 s (cost-limited)", cadenceText(&b, k));
    map.refresh_ns = 1_050_000_000;
    try std.testing.expect(cadence(&map, null).cost_limited);
    map.refresh_ns = 1_000_000_000;
    map.cost_limited = false;
    try std.testing.expect(!cadence(&map, null).cost_limited and cadence(&map, null).age_s == null);
    map.refresh_ns = 0;
    try std.testing.expectEqualStrings("Refresh unknown", cadenceText(&b, cadence(&map, null)));
}

test "publication keeps the pinned alias after exit and carries cost limiting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = std.mem.zeroes(c.struct_xrt_mem_process);
    var empty_vmas: [1]c.struct_xrt_mem_vma = undefined;
    var empty_ranges: [1]c.struct_xrt_mem_range = undefined;
    p.vmas = &empty_vmas;
    p.ranges = &empty_ranges;
    p.pid = 42;
    p.start_ticks = 123;
    p.page_size = 4096;
    var scope = std.mem.zeroes(c.struct_xrt_mem_scope);
    scope.bound_start = 123;
    scope.snapshot = &p;
    scope.refresh_ns = 1_050_000_000;
    scope.cost_limited = 1;
    const view = std.mem.zeroes(c.struct_xrt_mem_view);
    const before = try fromView(arena.allocator(), &view, &scope, .{ .redact = true });
    p.start_ticks = 0;
    p.maps_status.state = c.XRT_MEM_EXITED;
    const after = try fromView(arena.allocator(), &view, &scope, .{ .redact = true });
    var a: [24]u8 = undefined;
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings(processLabel(&a, before.process.?), processLabel(&b, after.process.?));
    try std.testing.expectEqual(@as(u64, 123), after.process.?.start_ticks);
    try std.testing.expect(after.cost_limited and cadence(&after, null).cost_limited);
    var message: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Process 42 exited", processProblem(&message, after.process.?).?);
}

test "free contiguity from buddy orders" {
    const blocks = [_]u64{ 10, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1 };
    const sys = System{ .buddy = .{ .state = "ok", .reason = "" }, .zones = &.{.{ .node = 0, .name = "Normal", .blocks = &blocks }} };
    const t = freeTotals(&sys);
    try std.testing.expectEqual(@as(u64, 10 + 2 * 512 + 1024), t.free_pages);
    try std.testing.expectEqual(@as(u64, 2 * 512 + 1024), t.contig_pages);
    try std.testing.expectEqualStrings("madvise", selected("always [madvise] never"));
}

test "maps round-trip through JSON and reject disordered replay cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cells = [_]Cell{ .{ .start = 0x200000, .end = 0x400000, .vma = 0, .mapped = default_cell, .observed = default_cell, .present = default_cell, .huge = default_cell, .known = 15 }, .{ .start = 0x400000, .end = 0x10000000, .gap = 0x10000000 - 0x400000 } };
    const vmas = [_]Vma{.{ .start = 0x200000, .end = 0x400000, .perms = "rw-p", .thp_eligible = true }};
    const map = Map{ .process = .{ .pid = 7, .start_ticks = 9, .coverage_numerator = 1, .coverage_denominator = 2 }, .vmas = &vmas, .cells = &cells };
    const bytes = try toJson(a, &map);
    const back = try parse(a, bytes);
    try std.testing.expectEqual(@as(usize, 2), back.cells.len);
    try std.testing.expectEqual(State.gap, classify(back.cells[1]).state);
    try std.testing.expectEqual(@as(?u64, 2), back.process.?.coverage_denominator);
    try std.testing.expectError(error.MemoryMapInvalid, parse(a, "{\"schema\":\"xodb-memdefrag/1\",\"cells\":[{\"start\":8192,\"end\":4096}]}"));
    try std.testing.expectError(error.MemoryMapSchema, parse(a, "{\"schema\":\"other\"}"));
    var b: [24]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, alias(&b, 42, 7), "proc-"));
}

const ModelFixture = struct {
    process: c.struct_xrt_mem_process,
    vmas: [1]c.struct_xrt_mem_vma,
    ranges: [1]c.struct_xrt_mem_range,
    view: c.struct_xrt_mem_view,
    const who = Identity{ .pid = 42, .start = 123 };
    fn init(self: *ModelFixture, start: u64, end: u64) void {
        self.* = std.mem.zeroes(ModelFixture);
        self.process.pid = who.pid;
        self.process.start_ticks = who.start;
        self.process.page_size = 4096;
        self.process.started_ns = 10;
        self.process.maps_status.state = c.XRT_MEM_OK;
        self.process.pages_status.state = c.XRT_MEM_OK;
        self.process.numa_status.state = c.XRT_MEM_OK;
        @memcpy(self.process.name[0..7], "fixture");
        self.process.vmas = &self.vmas;
        self.process.vma_count = 1;
        self.process.ranges = &self.ranges;
        self.process.range_count = 1;
        const path = "viewport.bin";
        self.process.paths = @constCast(path.ptr);
        self.process.path_length = path.len;
        self.vmas[0] = std.mem.zeroes(c.struct_xrt_mem_vma);
        self.vmas[0].start = start;
        self.vmas[0].end = end;
        self.vmas[0].permissions = .{ 'r', 'w', '-', 'p', 0 };
        self.vmas[0].rss = end - start;
        self.vmas[0].known = c.XRT_MEM_RSS | c.XRT_MEM_VMFLAGS;
        self.vmas[0].path_length = path.len;
        self.ranges[0] = .{ .start = start, .end = end, .vma = 0, .backend = c.XRT_MEM_BACKEND_SCAN, .categories = present_bit | huge_bit, .known = present_bit | huge_bit | zero_bit | swapped_bit | file_bit | written_bit };
        self.view.scopes[0].ticket = 7;
        self.view.scopes[0].sequence = 1;
        self.view.scopes[0].bound_start = who.start;
        self.view.scopes[0].snapshot = &self.process;
        self.view.scopes[0].request = (Request{}).observation(who);
    }
};

test "memory viewport builds 65536 fixed cells and page zoom without markers" {
    const start: u64 = 1 << 32;
    const span = AddressRange{ .start = start, .end = start + 128 * 1024 * 1024 * 1024 };
    var f: ModelFixture = undefined;
    f.init(span.start, span.end);
    // A sparse VMA is still a full grid in explicit viewport mode.
    f.vmas[0].rss = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const began = threadNs();
    const map = try fromView(arena.allocator(), &f.view, &f.view.scopes[0], .{ .range = span });
    const cpu = threadNs() -| began;
    try std.testing.expectEqual(@as(usize, 65536), map.cells.len);
    try std.testing.expectEqual(span.start, map.cells[0].start);
    try std.testing.expectEqual(span.end, map.cells[65535].end);
    for (map.cells) |cell| {
        try std.testing.expectEqual(default_cell, cell.end - cell.start);
        try std.testing.expectEqual(@as(u64, 0), cell.gap);
    }
    try validate(&map);
    std.debug.print("memory viewport: 65536 cells, {d} bytes of cell storage, {d} ns projection CPU\n", .{ @sizeOf(Cell) * map.cells.len, cpu });
    const small = AddressRange{ .start = start + default_cell, .end = start + 2 * default_cell };
    const zoomed = try fromView(arena.allocator(), &f.view, &f.view.scopes[0], .{ .range = small, .cell_bytes = 4096 });
    try std.testing.expectEqual(@as(usize, 512), zoomed.cells.len);
    try std.testing.expectEqual(small.start, zoomed.cells[0].start);
    try std.testing.expectEqual(small.end, zoomed.cells[511].end);
    try std.testing.expectEqual(State.thp, classify(zoomed.cells[511]).state);
    try validate(&zoomed);
    const demand = (Request{ .range = small, .cell_bytes = 4096, .numa = true }).observation(ModelFixture.who);
    try std.testing.expectEqual(small.start, demand.range_start);
    try std.testing.expectEqual(small.end, demand.range_end);
    try std.testing.expectEqual(@as(u32, c.XRT_MEM_NUMA), demand.flags);
}

test "memory viewport unknown mapping, NUMA totals and redaction survive JSON" {
    const start: u64 = 2 * default_cell;
    var f: ModelFixture = undefined;
    f.init(start, start + 4096);
    f.vmas[0].numa_available = 1;
    f.vmas[0].numa_count = 2;
    f.vmas[0].numa_page_size = 4096;
    f.vmas[0].numa[0] = .{ .node = 0, .pages = 3 };
    f.vmas[0].numa[1] = .{ .node = 2, .pages = 5 };
    f.vmas[0].flags |= c.XRT_MEM_NUMA_CUT;
    f.process.maps_status.state = c.XRT_MEM_PARTIAL;
    f.process.numa_status.state = c.XRT_MEM_PARTIAL;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = Request{ .range = .{ .start = start, .end = start + 8192 }, .cell_bytes = 4096, .numa = true, .redact = true };
    const map = try fromView(arena.allocator(), &f.view, &f.view.scopes[0], req);
    try std.testing.expectEqual(State.thp, classify(map.cells[0]).state);
    try std.testing.expect(!map.cells[1].mapping_known);
    try std.testing.expectEqual(State.unknown, classify(map.cells[1]).state);
    try std.testing.expect(map.process.?.name == null and map.vmas[0].path == null);
    try std.testing.expectEqualStrings("partial", map.process.?.numa.state);
    try std.testing.expect(map.vmas[0].numa_partial);
    f.vmas[0].numa[0].pages = 99;
    try std.testing.expectEqual(@as(u64, 3), map.vmas[0].numa_vma_totals.?[0].pages);
    const text = try toJson(arena.allocator(), &map);
    const copy = try parse(arena.allocator(), text);
    try std.testing.expectEqualDeep(map.range, copy.range);
    try std.testing.expectEqual(@as(u32, 2), copy.vmas[0].numa_vma_totals.?[1].node);
    try std.testing.expectEqual(@as(?u64, 4096), copy.vmas[0].numa_page_size);
    try std.testing.expectEqual(State.unknown, classify(copy.cells[1]).state);
    f.process.maps_status.state = c.XRT_MEM_OK;
    f.vmas[0].numa_available = 0;
    f.process.numa_status.state = c.XRT_MEM_UNAVAILABLE;
    const complete = try fromView(arena.allocator(), &f.view, &f.view.scopes[0], req);
    try std.testing.expectEqual(State.unmapped, classify(complete.cells[1]).state);
    try std.testing.expect(complete.vmas[0].numa_vma_totals == null);
}

test "memory viewport geometry and hostile replay stay bounded" {
    const page: u64 = 4096;
    try std.testing.expectError(error.MemoryMapInvalid, (Request{ .cell_bytes = 0 }).check(page));
    try std.testing.expectError(error.MemoryMapInvalid, (Request{ .limit = 0 }).check(page));
    try std.testing.expectError(error.MemoryMapInvalid, (Request{ .limit = max_cells + 1 }).check(page));
    try std.testing.expectError(error.MemoryMapInvalid, (Request{ .range = .{ .start = 2, .end = 1 } }).check(page));
    try std.testing.expectError(error.MemoryMapInvalid, (Request{ .range = .{ .start = 0, .end = page + 1 }, .cell_bytes = page }).check(page));
    try std.testing.expectError(error.MemoryMapTooLarge, (Request{ .range = .{ .start = 0, .end = (max_cells + 1) * page }, .cell_bytes = page }).check(page));
    const end = std.math.maxInt(u64) - (page - 1);
    const top = AddressRange{ .start = end - page, .end = end };
    try (Request{ .range = top, .cell_bytes = page }).check(page);
    const bad = [_]Cell{ .{ .start = top.start, .end = end }, .{ .start = top.start, .end = end } };
    try std.testing.expectError(error.MemoryMapInvalid, validate(&.{ .range = top, .cell_bytes = page, .cells = &bad }));
    try std.testing.expectError(error.MemoryMapInvalid, validate(&.{ .pending = true, .cells = bad[0..1] }));
}

test "memory viewport reader reprojects requests and never relabels another scope" {
    const start: u64 = 2 * default_cell;
    var f: ModelFixture = undefined;
    f.init(start, start + 4 * 4096);
    var req = Request{ .range = .{ .start = start, .end = start + 8192 }, .cell_bytes = 4096 };
    f.view.scopes[0].request = req.observation(ModelFixture.who);
    var reader = Reader{ .ticket = 7 };
    const first = (try reader.project(std.testing.allocator, &f.view, ModelFixture.who, req)).?;
    defer first.destroy();
    try std.testing.expectEqual(@as(usize, 2), first.map.cells.len);
    try std.testing.expect((try reader.project(std.testing.allocator, &f.view, ModelFixture.who, req)) == null);
    req.cell_bytes = 8192;
    const zoom = (try reader.project(std.testing.allocator, &f.view, ModelFixture.who, req)).?;
    defer zoom.destroy();
    try std.testing.expectEqual(@as(usize, 1), zoom.map.cells.len);
    req.redact = true;
    const redacted = (try reader.project(std.testing.allocator, &f.view, ModelFixture.who, req)).?;
    defer redacted.destroy();
    try std.testing.expect(redacted.map.process.?.name == null and redacted.map.vmas[0].path == null);
    req.range = .{ .start = start + 8192, .end = start + 16384 };
    const pending = (try reader.project(std.testing.allocator, &f.view, ModelFixture.who, req)).?;
    defer pending.destroy();
    try std.testing.expect(pending.map.pending and pending.map.cells.len == 0);
    try std.testing.expectEqualDeep(req.range, pending.map.range);
    var message: [128]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, processProblem(&message, pending.map.process.?).?, "Waiting for memory map"));
    // The new cache can start at the same sequence as the old cache.
    reader.ticket = 8;
    f.view.scopes[0].ticket = 8;
    f.view.scopes[0].request = req.observation(ModelFixture.who);
    const moved = (try reader.project(std.testing.allocator, &f.view, ModelFixture.who, req)).?;
    defer moved.destroy();
    try std.testing.expect(!moved.map.pending and moved.map.cells[0].start == start + 8192);
    req.numa = true;
    const need_numa = (try reader.project(std.testing.allocator, &f.view, ModelFixture.who, req)).?;
    defer need_numa.destroy();
    try std.testing.expect(need_numa.map.pending);
    f.view.scopes[0].request.flags |= c.XRT_MEM_NUMA;
    const numa = (try reader.project(std.testing.allocator, &f.view, ModelFixture.who, req)).?;
    defer numa.destroy();
    try std.testing.expect(!numa.map.pending);
    const other = Identity{ .pid = ModelFixture.who.pid, .start = ModelFixture.who.start + 1 };
    const reused = (try reader.project(std.testing.allocator, &f.view, other, req)).?;
    defer reused.destroy();
    try std.testing.expect(reused.map.pending and reused.map.process.?.start_ticks == other.start);
}
