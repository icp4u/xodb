//! Owner-side preparation for the native debugger panes. Presentation contains
//! values and const slices only; a remote publication must retain those slices
//! before the next refresh. No live Session is needed to draw the result.
const std = @import("std");
const c = @import("../c.zig").api;
const model = @import("session.zig");
const linux = @import("../target/linux.zig");
const info = @import("../debug/info.zig");
const disasm = @import("disassembly.zig");
const cfg = @import("control_flow.zig");

pub const LocalRow = struct { name: []const u8, value: model.ValueSummary };
pub const Request = struct {
    tid: i32,
    frame: usize = 0,
    browse_address: ?u64 = null,
    browse_assembly: ?u64 = null,
    flow: bool = false,
};
pub const Source = struct {
    bytes: []const u8 = "",
    path: []const u8 = "No source file selected",
    lines: i32 = 0,
    truncated: bool = false,
    remote: bool = false,
    revision: u64 = 0,
};
pub const Graph = struct {
    address: u64,
    size: usize,
    decoded_bytes: usize,
    instructions: []const disasm.Instruction,
    blocks: []const cfg.Block,
    edges: []const cfg.Edge,
    pub fn blockAt(self: Graph, address: u64) ?usize {
        for (self.blocks) |block| if (address >= block.address and address < block.end) return block.id;
        return null;
    }
};
pub const FunctionGraph = struct {
    generation: u64,
    image_epoch: u64,
    module_id: u64,
    symbol: []const u8,
    link_address: u64,
    extent_source: @FieldType(model.FunctionGraph, "extent_source"),
    range_index: usize,
    range_count: usize,
    graph: Graph,
    pub fn from(value: model.FunctionGraph) FunctionGraph {
        return .{ .generation = value.generation, .image_epoch = value.image_epoch, .module_id = value.module_id, .symbol = value.symbol, .link_address = value.link_address, .extent_source = value.extent_source, .range_index = value.range_index, .range_count = value.range_count, .graph = .{ .address = value.graph.address, .size = value.graph.size, .decoded_bytes = value.graph.decoded_bytes, .instructions = value.graph.instructions, .blocks = value.graph.blocks, .edges = value.graph.edges } };
    }
};
pub const Flow = struct {
    generation: u64 = std.math.maxInt(u64),
    anchor: u64 = 0,
    function: ?FunctionGraph = null,
    diagnostic: ?[]const u8 = null,
};
pub const Presentation = struct {
    request: Request = .{ .tid = 0 },
    snapshot: linux.Snapshot = .{},
    metadata_revision: u64 = 0,
    architecture: @import("../target/arch.zig").Arch = .x86_64,
    threads: []const linux.Thread = &.{},
    events: []const linux.Event = &.{},
    frames: []const model.Frame = &.{},
    locals: []const LocalRow = &.{},
    local_diagnostic: ?[]const u8 = null,
    regs: ?linux.Registers = null,
    instructions: []const disasm.Instruction = &.{},
    assembly_error: ?[]const u8 = null,
    source: Source = .{},
    current_line: ?u32 = null,
    breakpoint_lines: []const u32 = &.{},
    selected_frame: usize = 0,
    flow: Flow = .{},
    language_header: ?@import("language_view.zig").Header = null,
    status: ?[]const u8 = null,
};

pub fn requireImmutable(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice or !p.is_const or p.sentinel() != null)
                @compileError("debugger presentations require const ordinary slices, not object pointers");
            requireImmutable(p.child);
        },
        .optional => |o| requireImmutable(o.child),
        .array => |v| requireImmutable(v.child),
        .@"struct" => |s| inline for (s.fields) |field| requireImmutable(field.type),
        .@"union" => |u| inline for (u.fields) |field| requireImmutable(field.type),
        else => {},
    }
}
comptime {
    @setEvalBranchQuota(10000);
    requireImmutable(Presentation);
}

/// Persistent source storage belongs to the preparation owner. Native callers
/// borrow it synchronously; remote callers publish a deep copy.
pub const SourceFile = struct {
    value: Source = .{},
    bytes: ?[]u8 = null,
    name: ?[:0]u8 = null,
    pub fn deinit(self: *SourceFile) void {
        if (self.bytes) |bytes| std.heap.page_allocator.free(bytes);
        if (self.name) |name| std.heap.page_allocator.free(name);
        self.* = .{};
    }
    fn replace(self: *SourceFile, bytes: []u8, count: usize, name: [:0]u8, truncated: bool, remote: bool) void {
        if (self.bytes) |old| std.heap.page_allocator.free(old);
        if (self.name) |old| std.heap.page_allocator.free(old);
        self.bytes = bytes;
        self.name = name;
        self.value = .{ .bytes = bytes[0..count], .path = name, .lines = @intCast(std.mem.count(u8, bytes[0..count], "\n") + @intFromBool(count > 0 and bytes[count - 1] != '\n')), .truncated = truncated, .remote = remote, .revision = self.value.revision +% 1 };
    }
    pub fn load(self: *SourceFile, path: []const u8) !void {
        if (!self.value.remote and std.mem.eql(u8, path, self.value.path) and self.value.bytes.len > 0) return;
        const a = std.heap.page_allocator;
        const name = try a.dupeZ(u8, path);
        errdefer a.free(name);
        const fd = c.open(name, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) return error.SourceFileUnavailable;
        defer _ = c.close(fd);
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return error.SourceFileUnavailable;
        const bytes = try a.alloc(u8, 1024 * 1024);
        errdefer a.free(bytes);
        var n: usize = 0;
        while (n < bytes.len) {
            const count = c.read(fd, bytes.ptr + n, bytes.len - n);
            if (count < 0 and c.__errno_location().* == c.EINTR) continue;
            if (count < 0) return error.SourceReadFailed;
            if (count == 0) break;
            n += @intCast(count);
        }
        self.replace(bytes, n, name, stat.st_size > bytes.len, false);
    }
    fn loadSite(self: *SourceFile, session: *model.Session, site: info.Site) !void {
        self.load(site.path) catch |err| {
            if (!session.fetch_source or site.original_path != null or !session.target.isRemote()) return err;
            const a = std.heap.page_allocator;
            const bytes = session.remoteSource(a, site) catch |remote_err| {
                // A failed new fetch must never relabel an old remote copy.
                if (self.value.remote) self.value = .{ .path = "", .revision = self.value.revision +% 1 };
                return remote_err;
            };
            errdefer a.free(bytes);
            const name = try a.dupeZ(u8, site.path);
            self.replace(bytes, bytes.len, name, false, true);
        };
    }
};

pub const FlowCapture = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: Flow = .{},
    pub fn deinit(self: *FlowCapture) void {
        self.arena.deinit();
    }
    pub fn refresh(self: *FlowCapture, session: *model.Session, address: u64) void {
        const generation = session.target.snapshot().generation;
        if (self.value.generation == generation and self.value.anchor == address) return;
        _ = self.arena.reset(.retain_capacity);
        self.value = .{ .generation = generation, .anchor = address };
        if (session.target.snapshot().state != .stopped or address == 0) return;
        const function = session.functionGraph(self.arena.allocator(), address) catch |err| {
            self.value.diagnostic = @errorName(err);
            return;
        };
        self.value.function = FunctionGraph.from(function);
    }
};

pub const Capture = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    source: SourceFile = .{},
    flow: FlowCapture = .{},
    value: Presentation = .{},
    budget_status: [128 + 288 + 32]u8 = undefined,
    instructions: [32]disasm.Instruction = undefined,
    pub fn deinit(self: *Capture) void {
        self.flow.deinit();
        self.source.deinit();
        self.arena.deinit();
    }
    /// Owner only. Some frame/value strings still borrow Session metadata;
    /// retain the returned presentation before any subsequent owner mutation.
    pub fn refresh(self: *Capture, session: *model.Session, request: Request) void {
        _ = self.arena.reset(.retain_capacity);
        self.value = .{ .request = request, .snapshot = session.target.snapshot(), .metadata_revision = session.metadata.revision, .architecture = session.target.arch(), .threads = session.target.threadSlice(), .events = session.target.eventSlice(), .selected_frame = request.frame };
        defer {
            self.value.source = self.source.value;
            self.value.flow = self.flow.value;
            self.value.language_header = @import("language_view.zig").header(session);
            // Unnamed frames of an image refused in full: say which and why.
            budget_frames: for (self.value.frames) |frame| {
                for ([_]?[]const u8{ frame.inline_diagnostic, frame.diagnostic }) |reason| if (reason) |why| if (std.mem.eql(u8, why, "BinarySnapshotLimit") or std.mem.eql(u8, why, "CompressedDebugBudget")) if (session.modules.budgetFailure(frame.lookup_pc)) |failure| {
                    // The line is narrow and formatted into a fixed buffer with
                    // the rest of the status: the file name, cut to fit.
                    var name: [128]u8 = undefined;
                    var text: [@import("../binary/snapshot.zig").refusal_text]u8 = undefined;
                    const budget = failure.budget orelse continue;
                    self.value.status = std.fmt.bufPrint(&self.budget_status, "Over budget: {s}", .{budget.write(&text, @import("../binary/snapshot.zig").printable(&name, std.fs.path.basename(failure.path), name.len))}) catch "Image over budget";
                    break :budget_frames;
                };
            }
        }
        if (request.tid == 0 or self.value.snapshot.state != .stopped) {
            self.flow.refresh(session, 0);
            return;
        }
        self.value.regs = session.target.registers(request.tid) catch |err| {
            self.value.status = @errorName(err);
            return;
        };
        const assembly_address = if (request.browse_address) |address| request.browse_assembly orelse address else linux.programCounter(self.value.regs.?) catch |err| {
            self.value.status = @errorName(err);
            return;
        };
        var bytes: [256]u8 = undefined;
        const n = session.target.readMemory(assembly_address, &bytes) catch |err| {
            self.value.status = @errorName(err);
            return;
        };
        const count = disasm.decodeFor(self.value.architecture, bytes[0..n], assembly_address, &self.instructions) catch |err| blk: {
            self.value.assembly_error = @errorName(err);
            break :blk 0;
        };
        self.value.instructions = self.instructions[0..count];
        const a = self.arena.allocator();
        self.value.frames = session.stack(a, request.tid, 64) catch &.{};
        if (self.value.frames.len > 0) {
            self.value.selected_frame = @min(request.frame, self.value.frames.len - 1);
            if (session.language_tabs.native_selection == null and session.language_tabs.logical_selection == null) {
                session.language_tabs.native_selection = .{ .generation = self.value.snapshot.generation, .tid = request.tid, .frame = self.value.selected_frame };
                session.language_tabs.revision +%= 1;
            }
            if (self.value.frames[self.value.selected_frame].source) |site| self.followSource(session, site);
        }
        if (request.flow) {
            const anchor = if (self.value.frames.len > 0) self.value.frames[self.value.selected_frame].lookup_pc else linux.programCounter(self.value.regs.?) catch |err| {
                self.value.status = @errorName(err);
                return;
            };
            self.flow.refresh(session, anchor);
        }
        if (request.browse_address) |address| {
            self.value.current_line = null;
            if (session.sourceAt(a, address)) |site| self.followSource(session, site) else |_| {}
        }
        const variables = session.locals(a, request.tid, self.value.selected_frame) catch |err| {
            self.value.local_diagnostic = @errorName(err);
            return;
        };
        var rows: std.ArrayList(LocalRow) = .empty;
        for (variables) |v| {
            const summary = session.summarize(a, v.value) catch continue;
            rows.append(a, .{ .name = v.name, .value = summary }) catch {};
            if (@import("../language/go_values.zig").supported(v.value.type)) continue;
            const is_pointer = v.value.type.kind == .pointer;
            const structure = if (is_pointer) v.value.type.child orelse continue else v.value.type;
            if (structure.kind != .structure or summary.availability != .available) continue;
            const base = if (is_pointer) summary.bits orelse continue else summary.address orelse continue;
            for (structure.fields[0..@min(8, structure.fields.len)]) |field| {
                const expression = std.fmt.allocPrint(a, "{s}{s}{s}", .{ v.name, if (is_pointer) "->" else ".", field.name }) catch continue;
                const address = std.math.add(u64, base, field.offset) catch continue;
                var value = session.summarize(a, .{ .type = field.type, .address = address }) catch continue;
                if (summary.visualization) |shown| {
                    if (shown.perl != null and std.mem.eql(u8, field.name, "sv_u"))
                        value.display = std.fmt.allocPrint(a, "raw union (not a value): {s}", .{value.display}) catch continue;
                }
                rows.append(a, .{ .name = expression, .value = value }) catch {};
            }
        }
        self.value.locals = rows.toOwnedSlice(a) catch &.{};
        var lines: std.ArrayList(u32) = .empty;
        for (session.target.breakpointSlice()) |probe| {
            const site = session.sourceAt(a, probe.address) catch continue;
            if (std.mem.eql(u8, site.path, self.source.value.path)) lines.append(a, site.line) catch {};
        }
        self.value.breakpoint_lines = lines.toOwnedSlice(a) catch &.{};
    }
    fn followSource(self: *Capture, session: *model.Session, site: info.Site) void {
        self.source.loadSite(session, site) catch |err| {
            self.value.status = if (err == error.SourceAgentNeedsUpdating) "Source: agent needs updating" else @errorName(err);
        };
        if (std.mem.eql(u8, self.source.value.path, site.path)) self.value.current_line = site.line;
    }
};
