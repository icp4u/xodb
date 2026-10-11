//! Owner-side profiling preparation. Frontends receive only const graph data
//! and retain navigation paths as values across publication retirement.
const std = @import("std");
const profile = @import("../profile/capture.zig");
const tree = @import("../profile/flame.zig");
const recorded = @import("../profile/recorded_view.zig");
const timeline = @import("../profile/timeline.zig");
const info = @import("../debug/info.zig");
const disasm = @import("disassembly.zig");
const derived = @import("../profile/derived.zig");
const now = @import("../target/linux.zig").now;
pub const Basis = enum { recorded, reconstructed };
pub const ViewStatus = union(enum) {
    ready,
    building,
    waiting,
    failed: []const u8,

    pub fn text(self: ViewStatus) []const u8 {
        return switch (self) {
            .ready => "ready",
            .building => "building",
            .waiting => "waiting for flame worker",
            .failed => |err| err,
        };
    }
};
/// What the session can offer for the reconstructed basis this frame.
pub const Derived = union(enum) {
    none,
    pending: struct { done: usize, total: usize },
    failed: []const u8,
    unavailable: []const u8,
    ready: *const derived.View,
};
pub const State = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    details: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    graph: ?tree.Graph = null,
    capture_id: u64 = 0,
    revision: u64 = 0,
    view_id: ?[64]u8 = null,
    view_status: ViewStatus = .ready,
    clone_failure: ?[]const u8 = null,
    mapping_revision: u64 = 0,
    selection: timeline.Selection = .{},
    built_filter: profile.Filter = .{},
    sample_count: usize = 0,
    trusted_before_ns: u64 = std.math.maxInt(u64),
    refreshed_ns: u64 = 0,
    selected: u32 = 0,
    zoom: u32 = 0,
    scroll: f32 = 0,
    source: ?info.Site = null,
    instructions: []disasm.Instruction = &.{},
    diagnostic: ?[]const u8 = null,
    /// Recorded kernel callchains, or the reconstructed view (B).
    basis: Basis = .recorded,
    derived_identity: [64]u8 = @splat(0),
    derived_failed_identity: ?[64]u8 = null,
    derived_counts: derived.Counts = .{},
    derived_examples: []u32 = &.{},

    pub fn deinit(self: *State) void {
        self.arena.deinit();
        self.details.deinit();
    }
    /// T09 commits its range/thread selection here. Building happens at refresh,
    /// so callers can preview drag motion without rebuilding flames per motion.
    pub fn setFilter(self: *State, capture: *const profile.Capture, filter: profile.Filter) !void {
        try capture.validateFilter(filter);
        self.selection.bind(capture.id, capture.extentNs());
        try self.selection.set(filter);
    }
    fn refreshOffline(self: *State, capture: ?*profile.Capture) void {
        const current = capture orelse return;
        if (current.id == self.capture_id and current.revision == self.revision and std.meta.eql(self.selection.filter, self.built_filter)) return;
        self.selection.bind(current.id, current.extentNs());
        const filter_changed = !std.meta.eql(self.selection.filter, self.built_filter);
        if (current.id == self.capture_id and current.revision == self.revision and !filter_changed) return;
        const changed = current.id != self.capture_id;
        const evidence_changed = changed or current.mapping_revision != self.mapping_revision or current.samples.len() != self.sample_count or current.trusted_before_ns != self.trusted_before_ns;
        // Timeline clock ticks and debugger markers advance the capture revision
        // without changing a flame tree. Do not rebuild that tree just to move time.
        if (!evidence_changed and !filter_changed and self.graph != null) {
            self.revision = current.revision;
            return;
        }
        if (!changed and !filter_changed and current.collector != null and now() -| self.refreshed_ns < 250_000_000) return;
        const reset = changed or filter_changed or current.mapping_revision != self.mapping_revision or current.trusted_before_ns != std.math.maxInt(u64);
        const selected_path = SavedPath.save(self.graph, self.selected);
        const zoom_path = SavedPath.save(self.graph, self.zoom);
        self.mapping_revision = current.mapping_revision;
        self.sample_count = current.samples.len();
        self.trusted_before_ns = current.trusted_before_ns;
        self.built_filter = self.selection.filter;
        self.refreshed_ns = now();
        self.capture_id = current.id;
        self.revision = current.revision;
        _ = self.arena.reset(.retain_capacity);
        self.graph = null;
        self.diagnostic = null;
        self.graph = current.graph(self.arena.allocator(), self.built_filter) catch |err| {
            self.diagnostic = if (err == error.ArchiveViewPending) "Building offline flame graph" else @errorName(err);
            self.revision = 0; // retry when the worker publishes this filter
            return;
        };
        // Node indices can change when samples arrive out of order. Match the
        // ancestry by identity; new mapping evidence invalidates the selection.
        self.selected = if (reset) 0 else selected_path.restore(&self.graph.?);
        self.zoom = if (reset) 0 else zoom_path.restore(&self.graph.?);
        if (reset) self.scroll = 0;
        self.select(current, @min(self.selected, @as(u32, @intCast(self.graph.?.nodes.items.len - 1))));
    }
    pub fn refresh(self: *State, capture: ?*profile.Capture, views: *recorded.State) void {
        const current = capture orelse return;
        if (current.offline) return self.refreshOffline(capture);
        self.selection.bind(current.id, current.extentNs());
        const changed = current.id != self.capture_id or !std.meta.eql(self.selection.filter, self.built_filter);
        if (changed) {
            self.graph = null;
            _ = self.arena.reset(.retain_capacity);
            _ = self.details.reset(.retain_capacity);
            self.source = null;
            self.instructions = &.{};
            self.diagnostic = null;
            self.capture_id = current.id;
            self.revision = 0;
            self.view_id = null;
            self.clone_failure = null;
            self.sample_count = 0;
            self.built_filter = self.selection.filter;
            self.selected = 0;
            self.zoom = 0;
            self.scroll = 0;
            self.refreshed_ns = 0;
        }
        views.poll(current);
        if (self.clone_failure) |err| {
            self.view_status = .{ .failed = err };
            return;
        }
        if (views.result) |*result| if (result.key.capture_id == current.id and std.meta.eql(result.key.filter, self.built_filter) and result.key.revision != self.revision) {
            const reset = self.graph == null or self.mapping_revision != result.mapping_revision or self.trusted_before_ns != result.trusted_before_ns;
            const selected_path = SavedPath.save(self.graph, self.selected);
            const zoom_path = SavedPath.save(self.graph, self.zoom);
            self.graph = null;
            _ = self.arena.reset(.retain_capacity);
            self.graph = result.graph.clone(self.arena.allocator()) catch |err| {
                self.clone_failure = @errorName(err);
                self.view_status = .{ .failed = @errorName(err) };
                return;
            };
            self.revision = result.key.revision;
            self.view_id = result.key.viewId();
            self.sample_count = result.sample_count;
            self.mapping_revision = result.mapping_revision;
            self.trusted_before_ns = result.trusted_before_ns;
            self.selected = if (reset) 0 else selected_path.restore(&self.graph.?);
            self.zoom = if (reset) 0 else zoom_path.restore(&self.graph.?);
            if (reset) self.scroll = 0;
            self.select(current, self.selected);
        };
        self.view_status = .ready;
        const needed = self.graph == null or current.samples.len() != self.sample_count or current.mapping_revision != self.mapping_revision or current.trusted_before_ns != self.trusted_before_ns;
        if (views.job) |job| {
            const matches = job.key.capture_id == current.id and std.meta.eql(job.key.filter, self.built_filter);
            if (!matches and job.owner == .gui) job.cancel.store(true, .release);
            if (needed) self.view_status = if (matches and !job.cancel.load(.acquire)) .building else .waiting;
            return;
        }
        if (!needed) return;
        if (views.failure) |failure| if (failure.key.capture_id == current.id and std.meta.eql(failure.key.filter, self.built_filter)) {
            self.view_status = .{ .failed = @errorName(failure.err) };
            return;
        };
        if (now() -| self.refreshed_ns < 250_000_000) return;
        self.refreshed_ns = now();
        _ = views.request(current, current.revision, self.built_filter, false) catch |err| {
            self.view_status = if (err == error.ProfileViewPending) .building else if (err == error.ProfileViewBusy) .waiting else .{ .failed = @errorName(err) };
            if (err == error.ProfileViewPending) views.job.?.owner = .gui;
            return;
        };
    }
    const SavedPath = struct {
        frames: [80]tree.Frame = undefined,
        count: usize = 0,
        fn save(graph: ?tree.Graph, node_id: u32) SavedPath {
            var path = SavedPath{};
            const old = graph orelse return path;
            var id = node_id;
            if (id >= old.nodes.items.len) return path;
            while (id != 0 and path.count < path.frames.len) {
                const node = old.nodes.items[id];
                path.frames[path.count] = .{ .kind = node.frame.kind, .module_id = node.frame.module_id, .mapping_id = node.frame.mapping_id, .address = node.frame.address, .name = "" };
                path.count += 1;
                id = node.parent orelse 0;
            }
            return path;
        }
        fn restore(path: SavedPath, graph: *const tree.Graph) u32 {
            var id: u32 = 0;
            var i = path.count;
            while (i > 0) {
                i -= 1;
                id = graph.findChild(id, path.frames[i]) orelse return 0;
            }
            return id;
        }
    };
    pub fn select(self: *State, capture: *profile.Capture, node: u32) void {
        const graph = self.graph orelse return;
        if (node >= graph.nodes.items.len) return;
        self.selected = node;
        _ = self.details.reset(.retain_capacity);
        self.source = null;
        self.instructions = &.{};
        self.diagnostic = null;
        const frame = graph.nodes.items[node].frame;
        if (frame.kind != .code) {
            if (frame.mapping_note.len > 0) self.diagnostic = frame.mapping_note;
            return;
        }
        self.source = capture.source(self.details.allocator(), frame) catch null;
        self.instructions = capture.instructions(self.details.allocator(), frame) catch |err| {
            self.diagnostic = @errorName(err);
            return;
        };
    }
    pub fn setBasis(self: *State, basis: Basis) void {
        if (basis == self.basis) return;
        self.basis = basis;
        _ = self.arena.reset(.retain_capacity);
        self.graph = null;
        self.selected = 0;
        self.zoom = 0;
        self.scroll = 0;
        self.capture_id = 0;
        self.revision = 0;
        self.view_id = null;
        self.clone_failure = null;
        self.view_status = .ready;
        self.derived_identity = @splat(0);
        self.derived_failed_identity = null;
        self.derived_examples = &.{};
        self.diagnostic = null;
    }
    fn adoptDerived(self: *State, capture: *profile.Capture, view: *const derived.View) void {
        if (std.mem.eql(u8, &self.derived_identity, &view.identity) and self.graph != null) return;
        if (self.derived_failed_identity) |id| if (std.mem.eql(u8, &id, &view.identity)) return;
        self.derived_failed_identity = null;
        const selected_path = SavedPath.save(self.graph, self.selected);
        const zoom_path = SavedPath.save(self.graph, self.zoom);
        _ = self.arena.reset(.retain_capacity);
        self.graph = null;
        self.graph = view.graph.clone(self.arena.allocator()) catch {
            self.derived_failed_identity = view.identity;
            self.diagnostic = "Derived view copy failed: OutOfMemory. B twice retries.";
            return;
        };
        self.derived_examples = self.arena.allocator().dupe(u32, view.examples) catch {
            self.graph = null;
            self.derived_failed_identity = view.identity;
            self.diagnostic = "Derived sample references failed: OutOfMemory. B twice retries.";
            return;
        };
        self.derived_counts = view.counts;
        self.derived_identity = view.identity;
        self.view_id = view.identity;
        self.sample_count = @intCast(view.counts.filtered);
        self.built_filter = view.filter;
        self.capture_id = capture.id;
        self.revision = capture.revision;
        self.mapping_revision = capture.mapping_revision;
        self.trusted_before_ns = capture.trusted_before_ns;
        self.selected = selected_path.restore(&self.graph.?);
        self.zoom = zoom_path.restore(&self.graph.?);
        self.select(capture, @min(self.selected, @as(u32, @intCast(self.graph.?.nodes.items.len - 1))));
    }
};

/// Array-list-shaped const storage keeps traversal independent of the owner's
/// mutable graph index and allocator. Labels are copied by the preparation.
pub const Graph = struct {
    nodes: struct { items: []const tree.Node },
    colors: []const u8 = &.{},
    rejected: u64,
    partial_samples: u64,
    unverified_samples: u64,
    pub fn borrow(graph: *const tree.Graph) Graph {
        return .{ .nodes = .{ .items = graph.nodes.items }, .rejected = graph.rejected, .partial_samples = graph.partial_samples, .unverified_samples = graph.unverified_samples };
    }
    pub fn findChild(self: *const Graph, parent: u32, frame: tree.Frame) ?u32 {
        if (parent >= self.nodes.items.len) return null;
        var next = self.nodes.items[parent].first_child;
        while (next) |id| {
            const node = self.nodes.items[id];
            if (FrameIdentity.of(node.frame).same(FrameIdentity.of(frame))) return id;
            next = node.next_sibling;
        }
        return null;
    }
};
pub const FrameIdentity = struct {
    kind: tree.Kind = .root,
    module_id: u64 = 0,
    mapping_id: u32 = 0,
    address: u64 = 0,
    pub fn of(frame: tree.Frame) FrameIdentity {
        return .{ .kind = frame.kind, .module_id = frame.module_id, .mapping_id = frame.mapping_id, .address = frame.address };
    }
    fn same(self: FrameIdentity, other: FrameIdentity) bool {
        return std.meta.eql(self, other);
    }
    fn asFrame(self: FrameIdentity) tree.Frame {
        return .{ .kind = self.kind, .module_id = self.module_id, .mapping_id = self.mapping_id, .address = self.address, .name = "" };
    }
};
/// No slice in a navigation request may point into a retired publication.
pub const Path = struct {
    frames: [80]FrameIdentity = @splat(.{}),
    count: usize = 0,
    pub fn save(graph: ?Graph, node_id: u32) Path {
        var path: Path = .{};
        const value = graph orelse return path;
        var id = node_id;
        if (id >= value.nodes.items.len) return path;
        while (id != 0 and path.count < path.frames.len) {
            const node = value.nodes.items[id];
            path.frames[path.count] = FrameIdentity.of(node.frame);
            path.count += 1;
            id = node.parent orelse 0;
        }
        return path;
    }
    pub fn restore(self: Path, graph: *const Graph) u32 {
        if (self.count > self.frames.len) return 0;
        var id: u32 = 0;
        var i = self.count;
        while (i > 0) {
            i -= 1;
            id = graph.findChild(id, self.frames[i].asFrame()) orelse return 0;
        }
        return id;
    }
};

const setup = @import("../ui/capture_setup.zig");
const perf = @import("../profile/linux_perf.zig");
const Session = @import("session.zig").Session;
pub const Key = struct {
    session: u64,
    capture: u64,
    pid: i32,
    image_epoch: u64,
    mapping_revision: u64,
    revision: u64,
    trusted_before_ns: u64,
};
pub const Request = struct {
    key: ?Key = null,
    basis: Basis = .recorded,
    filter: profile.Filter = .{},
    selected: Path = .{},
};
pub const View = struct {
    request: ?Request = null,
    key: ?Key = null,
    graph: ?Graph = null,
    view_id: ?[64]u8 = null,
    view_status: ViewStatus = .ready,
    sample_count: usize = 0,
    built_filter: profile.Filter = .{},
    source: ?info.Site = null,
    instructions: []const disasm.Instruction = &.{},
    diagnostic: ?[]const u8 = null,
    detail_path: Path = .{},
    derived_counts: derived.Counts = .{},
    derived_examples: []const u32 = &.{},
    waiting: ?[]const u8 = null,
    facts: ?setup.Facts = null,
    start_failure: ?perf.Failure = null,
    start_error: ?[]const u8 = null,
    requested_threads: usize = 0,
    next: profile.Config = .{},
    cpu_activity: @FieldType(profile.Capture, "cpu_activity") = null,
    recorded_changes: usize = 0,
    unresolved_mappings: usize = 0,
    current_samples: usize = 0,
    extent_ns: u64 = 0,
    current_revision: u64 = 0,
    capture_diagnostic: []const u8 = "",
};
comptime {
    @setEvalBranchQuota(20000);
    @import("debugger_view.zig").requireImmutable(View);
}
const Signature = struct {
    session: u64,
    capture: u64,
    revision: u64,
    samples: usize,
    mappings: u64,
    active: bool,
    status: ?profile.Stop,
    error_hash: u64,
    settings_hash: u64,
    failure_hash: u64,
    requested_threads: usize,
    recorded_revision: ?u64,
    recorded_done: bool,
    archive_done: bool,
    fn read(session: *const Session) Signature {
        const capture = session.profile;
        var settings_hash = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&settings_hash, session.profile_defaults, .Deep);
        var failure_hash = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&failure_hash, session.profile_failure, .Deep);
        return .{
            .session = session.id,
            .capture = if (capture) |v| v.id else 0,
            .revision = if (capture) |v| v.revision else 0,
            .samples = if (capture) |v| v.samples.len() else 0,
            .mappings = if (capture) |v| v.mapping_revision else 0,
            .active = if (capture) |v| v.collector != null else false,
            .status = if (capture) |v| v.status else null,
            .error_hash = std.hash.Wyhash.hash(0, session.profile_error orelse ""),
            .settings_hash = settings_hash.final(),
            .failure_hash = failure_hash.final(),
            .requested_threads = session.profile_requested_threads,
            .recorded_revision = if (session.recorded_views.result) |v| v.key.revision else null,
            .recorded_done = if (session.recorded_views.job) |v| v.done.load(.acquire) else false,
            .archive_done = if (session.archive_job) |v| v.done.load(.acquire) else false,
        };
    }
};
pub const Capture = struct {
    state: State = .{},
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: View = .{},
    signature: ?Signature = null,
    refreshed_ns: u64 = 0,
    pending: bool = false,
    pub fn deinit(self: *Capture) void {
        self.state.deinit();
        self.arena.deinit();
    }
    pub fn clear(self: *Capture) void {
        self.state.deinit();
        self.state = .{};
        _ = self.arena.reset(.free_all);
        self.value = .{};
        self.signature = null;
        self.pending = false;
    }
    pub fn changed(self: *const Capture, session: *const Session) bool {
        const seen = self.signature orelse return true;
        const current = Signature.read(session);
        if (seen.session != current.session or seen.capture != current.capture) return true;
        // Collection advances its clock much faster than graph presentation.
        // Keep the existing quarter-second graph cadence; explicit requests
        // still refresh immediately. Static completed views do no idle work.
        return now() -| self.refreshed_ns >= 250 * std.time.ns_per_ms and
            (self.pending or !std.meta.eql(seen, current));
    }
    pub fn refresh(self: *Capture, session: *Session, wanted: ?Request) void {
        session.profile_view_visible = wanted != null;
        var request = wanted orelse {
            self.clear();
            return;
        };
        if (session.profile) |capture| {
            if (request.key == null or request.key.?.session != session.id or request.key.?.capture != capture.id) {
                request.key = null;
                request.filter = .{};
                request.selected = .{};
            }
        } else {
            request.key = null;
            request.filter = .{};
            request.selected = .{};
        }
        if (!self.changed(session) and std.meta.eql(self.value.request, @as(?Request, request))) return;
        _ = self.arena.reset(.retain_capacity);
        self.value = .{ .request = request };
        self.pending = false;
        self.prepare(session, request) catch |err| {
            self.value.diagnostic = @errorName(err);
        };
        self.signature = Signature.read(session);
        self.refreshed_ns = now();
    }
    fn prepare(self: *Capture, session: *Session, request: Request) !void {
        const a = self.arena.allocator();
        const current = session.profile;
        var value: View = .{
            .request = request,
            .facts = if (current) |capture| setup.factsFrom(capture) else null,
            .start_failure = session.profile_failure,
            .start_error = session.profile_error,
            .requested_threads = session.profile_requested_threads,
            .next = session.profile_defaults,
        };
        self.value = try @import("remote_owner.zig").copyView(a, value);
        const capture = current orelse return;
        self.value.key = .{ .session = session.id, .capture = capture.id, .pid = capture.pid, .image_epoch = capture.image_epoch, .mapping_revision = capture.mapping_revision, .revision = capture.revision, .trusted_before_ns = capture.trusted_before_ns };
        self.value.current_samples = capture.samples.len();
        self.value.current_revision = capture.revision;
        self.value.extent_ns = capture.extentNs();
        self.state.setBasis(request.basis);
        try self.state.setFilter(capture, request.filter);
        if (request.basis == .recorded) {
            if (capture.offline) session.ensureArchiveView(request.filter) catch {};
            self.state.refresh(capture, &session.recorded_views);
            self.pending = self.state.view_status == .building or self.state.view_status == .waiting or (capture.offline and self.state.revision == 0);
        } else switch (session.requestDerivedOwned(request.filter, .gui)) {
            .ready => |view| self.state.adoptDerived(capture, view),
            .pending => |progress| {
                value.waiting = try std.fmt.allocPrint(a, "Reconstructing stacks on the worker: {d} of {d} samples. Esc cancels; B returns to recorded callchains.", .{ progress.done, progress.total });
                self.pending = true;
            },
            .failed => |err| value.waiting = try std.fmt.allocPrint(a, "Reconstruction failed: {s}. Not retried automatically; press B twice to try again.", .{@errorName(err)}),
            .unavailable => |err| value.waiting = try std.fmt.allocPrint(a, "No reconstructed view: {s}. It needs a completed capture with sampled stacks (S, Stacks).", .{@errorName(err)}),
        }
        const key = Key{ .session = session.id, .capture = capture.id, .pid = capture.pid, .image_epoch = capture.image_epoch, .mapping_revision = self.state.mapping_revision, .revision = self.state.revision, .trusted_before_ns = self.state.trusted_before_ns };
        if (self.state.graph) |*graph| {
            const borrowed = Graph.borrow(graph);
            const same = if (request.key) |old| old.session == key.session and old.capture == key.capture and old.mapping_revision == key.mapping_revision and (capture.trusted_before_ns == std.math.maxInt(u64) or old.revision == key.revision) else false;
            const selected = if (same) request.selected.restore(&borrowed) else 0;
            if (selected != self.state.selected) self.state.select(capture, selected);
            value.detail_path = Path.save(borrowed, selected);
        }
        value.key = key;
        value.view_id = self.state.view_id;
        value.view_status = self.state.view_status;
        value.sample_count = self.state.sample_count;
        value.built_filter = self.state.built_filter;
        value.source = self.state.source;
        value.instructions = self.state.instructions;
        value.diagnostic = self.state.diagnostic;
        value.derived_counts = self.state.derived_counts;
        value.derived_examples = self.state.derived_examples;
        value.cpu_activity = capture.cpu_activity;
        value.current_samples = capture.samples.len();
        value.extent_ns = capture.extentNs();
        value.current_revision = capture.revision;
        value.capture_diagnostic = capture.diagnostic;
        // summary() refreshes remote PERF_INFO. It is an owner operation even
        // when the only fields used here describe already retained mappings.
        const metadata = capture.summary().mapping_history;
        value.recorded_changes = metadata.recorded_changes;
        value.unresolved_mappings = metadata.unresolved_executable_mappings;
        self.value = try @import("remote_owner.zig").copyView(a, value);
        if (self.state.graph) |*graph| self.value.graph = try copyGraph(a, graph);
        // Retain normalized scope in the owner, independent of request arenas.
        self.value.request.?.key = key;
        self.value.request.?.filter = self.state.selection.filter;
        self.value.request.?.selected = self.value.detail_path;
        session.profile_view = if (self.state.graph != null and value.waiting == null) .{ .capture_id = capture.id, .revision = self.state.revision, .filter = self.state.built_filter, .view_id = self.state.view_id, .sample_count = self.state.sample_count, .basis = @enumFromInt(@intFromEnum(request.basis)) } else null;
    }
};
fn copyGraph(a: std.mem.Allocator, graph: *const tree.Graph) !Graph {
    const nodes = try a.dupe(tree.Node, graph.nodes.items);
    const colors = try a.alloc(u8, nodes.len);
    for (nodes, colors) |*node, *color| {
        color.* = @intCast(std.hash.Wyhash.hash(0, node.frame.name) % 101);
        node.frame.name = try displayName(a, node.frame.name);
        node.frame.module = "";
        node.frame.mapping_note = "";
    }
    return .{ .nodes = .{ .items = nodes }, .colors = colors, .rejected = graph.rejected, .partial_samples = graph.partial_samples, .unverified_samples = graph.unverified_samples };
}
fn displayName(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len <= 384) return a.dupe(u8, text);
    var end: usize = 381;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return std.mem.concat(a, u8, &.{ text[0..end], "..." });
}

test "flame range filters rebuild selection while timeline-only revisions reuse the graph" {
    const a = std.testing.allocator;
    const capture = try a.create(profile.Capture);
    capture.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = 1, .session_id = 1, .generation = 0, .image_epoch = 0, .pid = 1, .started_ns = 100, .ended_ns = 200, .config = .{}, .accepted = undefined, .thread_count = 1, .collector = null, .images = @import("../model/modules.zig").Modules.init(a) };
    defer capture.deinit();
    capture.threads[0] = .{ .debugger_id = 1, .perf = .{ .tid = 1, .event_id = 1, .start_time_ticks = 1, .start_time_known = true } };
    _ = try std.fmt.bufPrintZ(&capture.thread_names[0], "Thread 1", .{});
    for ([_]u64{ 110, 120 }) |time| try capture.samples.append(a, .{ .tid = 1, .tid_present = true, .time_ns = time, .time_present = true });
    var view = State{};
    defer view.deinit();
    var views = recorded.State{};
    defer views.deinit();
    view.refresh(capture, &views);
    if (views.job) |job| job.join();
    view.refresh(capture, &views);
    try std.testing.expectEqual(2, view.graph.?.nodes.items[0].inclusive);
    const built = view.refreshed_ns;
    const nodes = view.graph.?.nodes.items.ptr;
    capture.addMarker(.{ .offset_ns = 30, .sequence = 1, .tid = 1, .kind = .stop });
    view.refresh(capture, &views);
    if (views.job) |job| job.join();
    view.refresh(capture, &views);
    try std.testing.expect(view.revision < capture.revision);
    try std.testing.expectEqual(built, view.refreshed_ns);
    try std.testing.expect(nodes == view.graph.?.nodes.items.ptr);
    try view.setFilter(capture, .{ .to_ns = 15 });
    view.refresh(capture, &views);
    if (views.job) |job| job.join();
    view.refresh(capture, &views);
    try std.testing.expectEqual(1, view.graph.?.nodes.items[0].inclusive);
    try std.testing.expectEqual(15, view.built_filter.to_ns);
    try std.testing.expectError(error.UnknownProfileThread, view.setFilter(capture, .{ .tid = 77 }));
    capture.id = 2;
    view.refresh(capture, &views);
    if (views.job) |job| job.join();
    view.refresh(capture, &views);
    try std.testing.expectEqual(2, view.graph.?.nodes.items[0].inclusive);
    try std.testing.expectEqual(std.math.maxInt(u64), view.selection.filter.to_ns);
}

test "profile navigation survives publication retirement and rejects stale filters" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const colors = [_]u8{ 0, 1, 2, 3 };
    var nodes = [_]tree.Node{
        .{ .id = 0, .parent = null, .first_child = 1, .frame = .{ .kind = .root, .name = "all" } },
        .{ .id = 1, .parent = 0, .first_child = 2, .next_sibling = 3, .frame = .{ .kind = .code, .module_id = 1, .address = 0x1000, .name = try arena.allocator().dupe(u8, "outer") } },
        .{ .id = 2, .parent = 1, .frame = .{ .kind = .code, .module_id = 1, .address = 0x2000, .name = try arena.allocator().dupe(u8, "selected_leaf") } },
        .{ .id = 3, .parent = 0, .frame = .{ .kind = .code, .module_id = 1, .address = 0x3000, .name = "other" } },
    };
    const graph = Graph{ .nodes = .{ .items = &nodes }, .colors = &colors, .rejected = 0, .partial_samples = 0, .unverified_samples = 0 };
    const boundary = @import("remote_owner.zig");
    const stamp = boundary.Stamp{ .connection = 1, .session = 1, .process = 1, .pid = 7, .image_epoch = 1, .generation = 1 };
    const key = Key{ .session = 1, .capture = 2, .pid = 7, .image_epoch = 1, .mapping_revision = 1, .revision = 1, .trusted_before_ns = std.math.maxInt(u64) };
    var view: View = .{ .key = key, .request = .{ .key = key }, .graph = graph, .extent_ns = 100 };
    const first = try boundary.Publication.create(a, .{ .stamp = stamp, .revision = 1, .taken_ns = 1, .status = .ready, .profile = view });
    var panel: @import("../ui/flame.zig").FlameView = .{};
    defer panel.deinit();
    const rt = @import("../target/runtime.zig").c;
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    panel.present(first.value.profile.?);
    panel.select(2);
    panel.zoomSelected();
    // The owner may retire the old publication as soon as the exchange takes
    // it; presentation must use saved values, never that old graph again.
    first.destroy();
    var reordered = [_]tree.Node{ nodes[0], nodes[3], nodes[1], nodes[2] };
    reordered[0].first_child = 2;
    reordered[1].id = 1;
    reordered[2].id = 2;
    reordered[2].first_child = 3;
    reordered[2].next_sibling = 1;
    reordered[3].id = 3;
    reordered[3].parent = 2;
    view.graph.?.nodes.items = &reordered;
    view.key.?.revision = 2;
    view.request.?.key = view.key;
    view.detail_path = Path.save(view.graph, 3);
    view.source = .{ .path = try arena.allocator().dupe(u8, "fixture.c"), .line = 8, .column = 1, .address = 0x2000, .is_statement = true, .prologue_end = false, .discriminator = 0 };
    const second = try boundary.Publication.create(a, .{ .stamp = stamp, .revision = 2, .taken_ns = 2, .status = .ready, .profile = view });
    defer second.destroy();
    _ = arena.reset(.free_all);
    var pending_view = second.value.profile.?;
    pending_view.graph = null;
    pending_view.source = null;
    pending_view.view_status = .building;
    panel.present(pending_view);
    try std.testing.expect(panel.request(true).?.selected.count > 0);
    panel.present(second.value.profile.?);
    try std.testing.expectEqual(@as(u32, 3), panel.selected);
    try std.testing.expectEqual(@as(u32, 3), panel.zoom);
    try std.testing.expectEqualStrings("selected_leaf", panel.selectedFrame().?.name);
    try std.testing.expectEqualStrings("fixture.c", panel.source.?.path);
    try panel.setFilter(.{ .to_ns = 50 });
    panel.present(second.value.profile.?);
    try std.testing.expect(panel.graph == null and panel.source == null and panel.view.facts == null);
    try std.testing.expectEqual(@as(u64, 50), panel.request(true).?.filter.to_ns);
    try std.testing.expectEqual(@as(u64, 2), panel.request(true).?.key.?.capture);
    const command = try boundary.Command.create(a, .{ .stamp = stamp, .actor = .human, .action = .{ .inspect = .{ .request_id = 1, .selection = .{ .tid = 7 }, .kind = .debugger, .profile = panel.request(true) } } });
    defer command.destroy();
    try std.testing.expectEqual(@as(u64, 50), command.request.action.inspect.profile.?.filter.to_ns);
}

test "profile display names are bounded at UTF8 boundaries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var name: [1200]u8 = undefined;
    for (0..name.len / 3) |i| @memcpy(name[i * 3 ..][0..3], "界");
    const copied = try displayName(arena.allocator(), &name);
    try std.testing.expect(copied.len <= 384);
    try std.testing.expect(std.unicode.utf8ValidateSlice(copied));
    try std.testing.expect(std.mem.endsWith(u8, copied, "..."));
}

test "profile idle cache tracks next settings and failure without a capture" {
    var session = Session.init();
    defer session.deinit();
    var capture: Capture = .{};
    defer capture.deinit();
    capture.refresh(&session, .{});
    try std.testing.expect(!capture.changed(&session));
    session.profile_defaults.duration_ms = 12345;
    capture.refreshed_ns = 0;
    try std.testing.expect(capture.changed(&session));
    capture.refresh(&session, .{});
    try std.testing.expectEqual(@as(u32, 12345), capture.value.next.duration_ms);
    try std.testing.expect(!capture.changed(&session));
    session.profile_error = "FixtureFailure";
    capture.refreshed_ns = 0;
    capture.refresh(&session, .{});
    try std.testing.expectEqualStrings("FixtureFailure", capture.value.start_error.?);
    session.profile_view = .{ .capture_id = 3, .revision = 4, .filter = .{} };
    capture.refresh(&session, null);
    try std.testing.expect(capture.value.request == null and capture.signature == null);
    try std.testing.expect(!session.profile_view_visible);
    try std.testing.expectEqual(@as(u64, 3), session.profile_view.?.capture_id);
}

test "maximum profile graph stays within publication budget with long symbols" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var graph = tree.Graph{ .allocator = a };
    const nodes = try arena.allocator().alloc(tree.Node, tree.max_nodes);
    const name = try arena.allocator().alloc(u8, 8192);
    @memset(name, 'x');
    for (nodes, 0..) |*node, i| node.* = .{ .id = @intCast(i), .parent = if (i == 0) null else 0, .frame = .{ .kind = .code, .name = name, .module = name, .mapping_note = name } };
    graph.nodes.items = nodes;
    const copied = try copyGraph(arena.allocator(), &graph);
    const boundary = @import("remote_owner.zig");
    const publication = try boundary.Publication.create(a, .{ .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 7, .image_epoch = 1, .generation = 1 }, .revision = 1, .taken_ns = 1, .status = .ready, .profile = .{ .graph = copied } });
    defer publication.destroy();
    _ = arena.reset(.free_all);
    try std.testing.expectEqual(tree.max_nodes, publication.value.profile.?.graph.?.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 384), publication.value.profile.?.graph.?.nodes.items[tree.max_nodes - 1].frame.name.len);
    try std.testing.expect(publication.bytes < 6 * 1024 * 1024);
}
