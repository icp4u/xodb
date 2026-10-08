const std = @import("std");
const Modules = @import("modules.zig").Modules;
const info = @import("../debug/info.zig");
const loc = @import("../debug/location.zig");
const eval = @import("evaluate.zig");
const linux = @import("../target/linux.zig");
const profile = @import("../profile/capture.zig");
const archive = @import("../profile/archive.zig");
const ArchiveJob = @import("../profile/archive_job.zig").Job;
const perf = @import("../profile/linux_perf.zig");
const cfg = @import("control_flow.zig");
pub const FunctionGraph = struct { generation: u64, image_epoch: u64, module_id: u64, symbol: []const u8, link_address: u64, extent_source: enum { elf_symbol, dwarf_subprogram } = .elf_symbol, range_index: usize = 0, range_count: usize = 1, graph: cfg.Graph };
pub const AgentScope = enum { observe, control, mutate };
pub const Actor = enum { human, agent };
pub const Effect = enum { execution, mutation };
pub const Audit = struct { sequence: u64, actor: Actor, client_id: ?u64 = null, action: []const u8, generation: u64 };
pub const Frame = struct {
    architecture: @import("../target/arch.zig").Arch = .x86_64,
    tid: i32 = 0,
    index: usize,
    pc: u64,
    lookup_pc: u64,
    registers: loc.RegisterSet,
    cfa: ?u64 = null,
    module_id: ?u64 = null,
    symbol: ?[]const u8 = null,
    source: ?info.Site = null,
    unwind_method: ?[]const u8 = null,
    inline_frames: []info.Inline = &.{},
    inline_diagnostic: ?[]const u8 = null,
    diagnostic: ?[]const u8 = null,
    pub fn jsonStringify(self: @This(), writer: anytype) !void {
        try writer.write(.{ .index = self.index, .pc = self.pc, .lookup_pc = self.lookup_pc, .registers = self.registers[0..self.architecture.count()], .cfa = self.cfa, .module_id = self.module_id, .symbol = self.symbol, .source = self.source, .unwind_method = self.unwind_method, .inline_frames = self.inline_frames, .inline_diagnostic = self.inline_diagnostic, .diagnostic = self.diagnostic });
    }
};
const value_view = @import("value_view.zig");
pub const ValueSummary = struct { type: []const u8, kind: eval.Kind, size: u64, address: ?u64, bits: ?u64, display: []const u8, availability: eval.Availability, diagnostic: ?[]const u8 = null, language: eval.Language = .unknown, enumerator: ?[]const u8 = null, visualization: ?value_view.Preview = null, composite: bool = false, partial: bool = false };
/// Inspection borrows module strings. Evidence must own the entire value,
/// including optional preview metadata and inline/source names, across exec.
fn retainEvidence(a: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => return if (value) |v| try retainEvidence(a, v) else null,
        .pointer => |p| {
            if (p.size != .slice) @compileError("evidence must contain values and slices, not borrowed object pointers");
            const copy = try a.alloc(p.child, value.len);
            for (value, copy) |v, *out| out.* = try retainEvidence(a, v);
            return copy;
        },
        .@"struct" => |s| {
            var copy = value;
            inline for (s.fields) |f| @field(copy, f.name) = try retainEvidence(a, @field(value, f.name));
            return copy;
        },
        .array => {
            var copy = value;
            for (value, &copy) |v, *out| out.* = try retainEvidence(a, v);
            return copy;
        },
        else => return value,
    }
}
pub const InstructionEvidence = struct { address: u64, mnemonic: []const u8, operands: []const u8, source: ?info.Site, basis: []const u8 = "linear_decode_from_symbol_start" };
pub const LocalEvidence = struct { name: []const u8, value: ValueSummary, diagnostic: ?[]const u8 };
pub const Observation = struct { locals: []LocalEvidence, locals_truncated: bool, event: linux.Event, captured_generation: u64, value: ValueSummary, frames: []Frame, preceding_instruction: ?InstructionEvidence, access_instruction: ?InstructionEvidence = null };
pub const Investigation = struct {
    id: u64,
    question: []const u8,
    expression: []const u8,
    watchpoint_id: u64,
    initial: ValueSummary,
    created_generation: u64,
    created_sequence: u64,
    image_epoch: u64,
    status: enum { active, finished, capacity_reached } = .active,
    observations: std.ArrayList(Observation) = .empty,
    architecture: @import("../target/arch.zig").Arch = .x86_64,
    before_semantics: []const u8 = "value at previous debugger sample; concurrent writes can intervene",
    pc_semantics: []const u8 = "data watchpoint PC is after the instruction; preceding instruction is derived, not a recorded branch trace",
    pub fn jsonStringify(self: Investigation, writer: *std.json.Stringify) !void {
        try writer.write(.{ .id = self.id, .question = self.question, .expression = self.expression, .watchpoint_id = self.watchpoint_id, .initial = self.initial, .created_generation = self.created_generation, .created_sequence = self.created_sequence, .image_epoch = self.image_epoch, .status = self.status, .observations = self.observations.items, .before_semantics = if (self.architecture == .aarch64) "value sampled at the pre-access trap; check before_valid and peer-thread evidence" else self.before_semantics, .pc_semantics = if (self.architecture == .aarch64) "trap_pc is pre-access; pc is completion/interruption; check watch_phase and attribution" else self.pc_semantics });
    }
};
const RunTo = struct { tid: i32, thread_id: u64, address: u64, probe: u64, owns_probe: bool, image_epoch: u64, expected_sp: ?u64 = null, cancelled: bool = false, ignored_stops: usize = 0 };
const SourceStep = struct { tid: i32, line: u32, path: [4096]u8, path_len: usize, over: bool, instructions: usize = 0, return_address: ?u64 = null };
pub const Session = struct {
    id: u64,
    process_id: u64 = 1,
    process_tree: ?*@import("process_tree.zig").Tree = null,
    symbol_files: ?*@import("../binary/debug_files.zig").Files = null,
    source_map_owner: ?*const @import("source_maps.zig").Maps = null,
    fetch_source: bool = false,
    target: linux.Target = .{},
    modules: Modules = Modules.init(std.heap.page_allocator),
    debug_files: @import("../binary/debug_files.zig").Files = .{ .allocator = std.heap.page_allocator },
    source_maps: @import("source_maps.zig").Maps = .{},
    maps_epoch: u64 = 0,
    maps_generation: u64 = std.math.maxInt(u64),
    agent_scope: AgentScope = .observe,
    /// Set only while dispatching a shared MCP request on the owner thread.
    agent_client_id: ?u64 = null,
    agent_lease: ?@import("../service/lease.zig").Lease = null,
    pending_continue: ?struct {
        generation: u64,
        epoch: u64,
        actor: Actor,
        lease: ?@import("../service/lease.zig").Lease,
    } = null,
    /// Set with agent_client_id: the dispatching client holds control (the
    /// shared controller lease, or a control-scope stdio client).
    agent_controller: bool = false,
    source_step: ?SourceStep = null,
    source_step_resumes: usize = 0,
    source_step_batched: usize = 0,
    stepping_over: bool = false,
    run_to: ?RunTo = null,
    probes: @import("probes.zig").Manager = .{},
    memory: @import("memory.zig").Memory = .{},
    inspections: @import("../observe/context.zig").Manager = .{},
    persistent: @import("persistent.zig").Manager = .{},
    launch_argv: []const [:0]const u8 = &.{},
    suppress_probe_resume: bool = false,
    probe_resume_actor: Actor = .human,
    profile: ?*profile.Capture = null,
    /// Session defaults for future GUI captures and omitted MCP arguments.
    profile_defaults: profile.Config = .{},
    allocations: @import("../profile/allocation_live.zig").Live = .{},
    observations: @import("../observe/live.zig").Live = .{},
    observation_analysis: ?*@import("../observe/analysis.zig").Job = null,
    next_observation_analysis: u64 = 1,
    observation_associations: ?*@import("../observe/association_job.zig").Job = null,
    next_observation_association: u64 = 1,
    observation_archive: ?*@import("../observe/archive_job.zig").Job = null,
    next_observation_archive: u64 = 1,
    allocation_defaults: @import("../profile/allocation_live.zig").Config = .{},
    allocation_helper: ?[:0]const u8 = null,
    /// Opt-in static analysis: worker discovery, one bounded job, cached exports.
    static_analysis: @import("../semq/host.zig").State = .{},
    offline: bool = false,
    frames: @import("../frames/state.zig").State = .{},
    imported: ?@import("../profile/imported_job.zig").State = null,
    artifact: ?archive.Opened = null,
    comparison: ?*@import("../profile/comparison.zig").Job = null,
    archive_job: ?*ArchiveJob = null,
    /// Published reconstructed-stack view and the last failed key. A failure
    /// is never retried automatically; `retryDerived` is an explicit action.
    derived: ?Derived = null,
    derived_failure: ?struct { key: @import("../profile/derived.zig").Key, err: anyerror } = null,
    next_archive_job: u64 = 1,
    recorded_views: @import("../profile/recorded_view.zig").State = .{},
    profile_failure: ?perf.Failure = null,
    profile_error: ?[]const u8 = null,
    profile_requested_threads: usize = 0,
    next_profile_id: u64 = 1,
    profile_view: ?struct { capture_id: u64, revision: u64, filter: profile.Filter, view_id: ?[64]u8 = null, sample_count: usize = 0, basis: enum { recorded, reconstructed } = .recorded } = null,
    profile_view_visible: bool = false,
    investigation_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    investigations: std.ArrayList(Investigation) = .empty,
    evidence_sequence: u64 = 0,
    step_diagnostic: ?[]const u8 = null,
    audit: [256]Audit = undefined,
    audit_count: usize = 0,
    audit_sequence: u64 = 0,
    pub fn symbolFiles(self: *Session) *@import("../binary/debug_files.zig").Files {
        return self.symbol_files orelse &self.debug_files;
    }
    pub fn sourceMaps(self: *const Session) *const @import("source_maps.zig").Maps {
        return self.source_map_owner orelse &self.source_maps;
    }
    pub const allocation_hooks = [_]@import("../profile/allocation_hooks.zig").Request{
        .{ .id = 1, .kind = .malloc, .name = "malloc" },
        .{ .id = 2, .kind = .calloc, .name = "calloc" },
        .{ .id = 3, .kind = .realloc, .name = "realloc" },
        .{ .id = 4, .kind = .free, .name = "free" },
    };
    pub fn startAllocations(self: *Session, actor: Actor, tids: []const i32, config: @import("../profile/allocation_live.zig").Config, mapping_address: ?u64, requests: []const @import("../profile/allocation_hooks.zig").Request) !void {
        if (self.target.arch() != .x86_64) return error.UnsupportedAllocationArchitecture;
        if (self.offline or self.target.core != null) return error.LiveTargetRequired;
        if (self.target.snapshot().state != .stopped) return error.PauseBeforeAllocationCapture;
        if (self.target.sharedVm() or self.target.snapshot().birth_count > 0) return error.ProcessFamilyRequiresResolution;
        if (tids.len == 0 or tids.len > 32) return error.InvalidAllocationThreads;
        var context = @import("../profile/allocation_live.zig").Context{
            .target = self.target.handle,
            .identity = .{ .session_id = self.id, .capture_id = 0, .process_id = self.process_id, .pid = self.target.snapshot().pid, .image_epoch = self.target.snapshot().image_epoch },
            .generation = self.target.snapshot().generation + @intFromBool(actor == .agent),
            .thread_count = tids.len,
        };
        for (tids, 0..) |tid, index| {
            for (tids[0..index]) |previous| if (previous == tid) return error.InvalidAllocationThreads;
            context.threads[index] = for (self.target.threadSlice()) |thread| {
                if (thread.tid == tid and thread.state == .stopped) break .{ .id = thread.id, .tid = tid };
            } else return error.InvalidAllocationThreads;
        }
        try self.refreshMaps();
        var chosen: ?@import("modules.zig").Region = null;
        for (self.modules.regions.items) |region| {
            if (region.permissions[2] != 'x' or region.inode == 0) continue;
            const matches = if (mapping_address) |address| address >= region.start and address < region.end else std.mem.eql(u8, std.fs.path.basename(region.path), "libc.so.6");
            if (!matches) continue;
            if (chosen != null) return error.AmbiguousAllocationModule;
            chosen = region;
        }
        try self.allocations.start(context, config, chosen orelse return error.AllocationModuleNotFound, requests, self.allocation_helper);
        self.record(actor, "start_allocations");
    }
    fn allocationThreadsMatch(self: *const Session, threads: []const @import("../profile/allocation_capture.zig").Thread, stopped: bool) bool {
        for (threads) |wanted| {
            const found = for (self.target.threadSlice()) |thread| {
                if (thread.id == wanted.id and thread.tid == wanted.tid and thread.state != .exited and (!stopped or thread.state == .stopped)) break true;
            } else false;
            if (!found) return false;
        }
        return true;
    }
    fn pollAllocations(self: *Session) void {
        var pending_valid = false;
        if (self.allocations.pendingContext()) |context| pending_valid =
            self.target.snapshot().state == .stopped and self.target.snapshot().pid == context.identity.pid and
            self.target.snapshot().image_epoch == context.identity.image_epoch and self.target.snapshot().generation == context.generation and
            self.target.snapshot().birth_count == 0 and !self.target.sharedVm() and self.allocationThreadsMatch(context.threads[0..context.thread_count], true);
        const boundary: ?@import("../profile/allocation_live.zig").Stop = if (self.allocations.capture) |capture|
            if (self.target.snapshot().state == .idle or self.target.snapshot().state == .exited or self.target.snapshot().pid != capture.identity.pid) .target_ended else if (self.target.snapshot().image_epoch != capture.identity.image_epoch) .image_changed else if (self.target.snapshot().birth_count > 0 or self.target.sharedVm()) .scope_changed else if (!self.allocationThreadsMatch(capture.threads[0..capture.thread_count], false)) blk: {
                for (self.target.threadSlice()) |thread| if (thread.state != .exited) break :blk .thread_ended;
                break :blk .target_ended;
            } else null
        else
            null;
        self.allocations.poll(pending_valid, boundary);
    }
    pub fn detach(self: *Session) !void {
        self.allocations.stop(.target_ended);
        self.observations.stop(.target_ended);
        try self.target.detach();
    }
    pub fn startObservation(self: *Session, actor: Actor, tids: []const i32, config: @import("../observe/capture.zig").Config, mapping_address: u64, requests: []const @import("../profile/uprobe_hooks.zig").Request) !void {
        if (self.observation_archive) |job| if (!job.done.load(.acquire)) return error.ObservationArchiveBusy;
        if (self.observation_associations) |job| {
            if (!job.done.load(.acquire)) return error.ObservationAssociationsBusy;
            job.deinit();
            self.observation_associations = null;
        }
        if (self.observation_analysis) |job| {
            if (!job.done.load(.acquire)) return error.ObservationAnalysisBusy;
            job.deinit();
            self.observation_analysis = null;
        }
        if (self.target.arch() != .x86_64) return error.UnsupportedObservationArchitecture;
        if (self.offline or self.target.core != null) return error.LiveTargetRequired;
        const stopped = self.target.snapshot();
        if (stopped.state != .stopped) return error.PauseBeforeObservation;
        if (self.target.sharedVm() or stopped.birth_count > 0) return error.ProcessFamilyRequiresResolution;
        if (tids.len == 0 or tids.len > 32) return error.InvalidObservationThreads;
        const runtime = @import("../profile/runtime.zig");
        const handle = self.target.handle orelse return error.LiveTargetRequired;
        var scope: runtime.c.struct_xrt_function_scope = undefined;
        var failure: runtime.c.struct_xrt_perf_failure = undefined;
        if (!runtime.c.xrt_functions_capture_scope(@ptrCast(handle), tids.ptr, tids.len, &scope, &failure)) {
            self.observations.failure = runtime.failure(failure);
            return error.ObservationScopeCapture;
        }
        var context = @import("../observe/live.zig").Context{
            .target = handle,
            .scope = scope,
            .producer = @import("../profile/producer.zig").describe(handle),
            .identity = .{ .session_id = self.id, .capture_id = 0, .process_id = self.process_id, .pid = stopped.pid, .image_epoch = stopped.image_epoch, .generation = stopped.generation + @intFromBool(actor == .agent) },
            .thread_count = tids.len,
        };
        for (tids, 0..) |tid, index| {
            for (tids[0..index]) |previous| if (previous == tid) return error.InvalidObservationThreads;
            context.threads[index] = for (self.target.threadSlice()) |thread| {
                if (thread.tid == tid and thread.state == .stopped) break .{ .id = thread.id, .tid = tid };
            } else return error.InvalidObservationThreads;
        }
        try self.refreshMaps();
        const region = for (self.modules.regions.items) |region| {
            if (region.permissions[2] == 'x' and region.inode != 0 and mapping_address >= region.start and mapping_address < region.end) break region;
        } else return error.ObservationMappingNotFound;
        try self.observations.start(context, config, region, requests, self.allocation_helper);
        self.record(actor, "start_observation");
    }
    fn observationThreadsMatch(self: *const Session, threads: []const @import("../observe/capture.zig").Thread, stopped: bool) bool {
        for (threads) |wanted| {
            for (self.target.threadSlice()) |thread| {
                if (thread.id == wanted.id and thread.tid == wanted.tid and thread.state != .exited and (!stopped or thread.state == .stopped)) break;
            } else return false;
        }
        return true;
    }
    fn pollObservations(self: *Session) void {
        // Replacement preparation keeps the old capture readable, but cannot
        // admit a worker that would borrow it across publication of the new one.
        if (self.observations.preparation != null) std.debug.assert(self.observation_analysis == null and self.observation_associations == null);
        const stopped = self.target.snapshot();
        const pending_valid = if (self.observations.pendingContext()) |context|
            stopped.state == .stopped and stopped.pid == context.identity.pid and stopped.image_epoch == context.identity.image_epoch and stopped.generation == context.identity.generation and
                stopped.birth_count == 0 and !self.target.sharedVm() and self.observationThreadsMatch(context.threads[0..context.thread_count], true)
        else
            false;
        const boundary: ?@import("../observe/capture.zig").Stop = if (self.observations.capture) |capture|
            if (stopped.state == .idle or stopped.state == .exited or stopped.pid != capture.identity.pid) .target_ended else if (stopped.image_epoch != capture.identity.image_epoch) .image_changed else if (stopped.birth_count > 0 or self.target.sharedVm()) .scope_changed else if (!self.observationThreadsMatch(capture.threads, false)) .thread_ended else null
        else
            null;
        self.observations.poll(pending_valid, boundary);
    }
    fn clearObservationArchive(self: *Session) !void {
        self.pollObservationArchive();
        if (self.observation_archive) |job| {
            if (!job.done.load(.acquire)) return error.ObservationArchiveBusy;
            job.deinit();
            self.observation_archive = null;
        }
    }
    pub fn saveObservation(self: *Session, path: []const u8) !u64 {
        const capture = self.observations.capture orelse return error.NoObservation;
        if (!capture.store.finished or self.observations.busy()) return error.ObservationStillCollecting;
        try self.clearObservationArchive();
        self.observation_archive = try @import("../observe/archive_job.zig").Job.start(self.next_observation_archive, .save, path, capture, self.observation_associations);
        self.next_observation_archive += 1;
        return self.observation_archive.?.id;
    }
    /// Starts the single retained cohort comparison for the current ended
    /// capture. MCP `compare_observation` and the GUI share this operation;
    /// callers perform their own authorization first.
    pub fn compareObservation(self: *Session, selection: @import("../observe/comparison.zig").Selection) !u64 {
        const capture = self.observations.capture orelse return error.NoObservation;
        if (!capture.store.finished or self.observations.busy()) return error.ObservationStillCollecting;
        if (self.observation_archive) |job| if (!job.done.load(.acquire)) return error.ObservationArchiveBusy;
        try selection.validate();
        if (self.observation_analysis) |job| {
            if (!job.done.load(.acquire)) return error.ObservationAnalysisBusy;
            job.deinit();
            self.observation_analysis = null;
        }
        self.observation_analysis = try @import("../observe/analysis.zig").Job.create(self.next_observation_analysis, capture, selection);
        capture.comparison_selection = selection;
        self.next_observation_analysis += 1;
        return self.observation_analysis.?.id;
    }
    pub fn openObservation(self: *Session, path: []const u8) !void {
        const failed_open = if (self.observation_archive) |job| job.kind == .open and job.done.load(.acquire) and job.err != null else false;
        if (self.target.snapshot().pid != 0 or (self.offline and !failed_open) or self.profile != null or self.observations.capture != null or self.observations.busy()) return error.ConflictingTargets;
        try self.clearObservationArchive();
        self.observation_archive = try @import("../observe/archive_job.zig").Job.start(self.next_observation_archive, .open, path, null, null);
        self.next_observation_archive += 1;
        self.offline = true;
    }
    fn pollObservationArchive(self: *Session) void {
        const job = self.observation_archive orelse return;
        if (job.reaped or !job.done.load(.acquire)) return;
        job.reaped = true;
        job.source = null;
        job.association_source = null;
        if (job.restored_associations) |restored| {
            restored.id = self.next_observation_association;
            self.next_observation_association += 1;
            self.observation_associations = restored;
            job.restored_associations = null;
        }
        if (job.capture) |capture| {
            self.observations.capture = capture;
            job.capture = null;
        }
    }
    pub fn archiveBusy(self: *const Session) bool {
        if (self.frames.job) |job| if (job.capture != null) return true;
        return if (self.archive_job) |job| !job.reaped else false;
    }
    fn clearArchiveJob(self: *Session) !void {
        self.pollArchive();
        if (self.archiveBusy()) return error.ArchiveBusy;
        if (self.archive_job) |job| job.deinit();
        self.archive_job = null;
    }
    pub fn openFrames(self: *Session, path: []const u8) !void {
        try self.frames.open(path);
    }
    pub fn openImported(self: *Session, path: []const u8) !void {
        if (self.target.snapshot().pid != 0 or self.profile != null or self.offline) return error.ConflictingTargets;
        self.imported = try @import("../profile/imported_job.zig").State.open(path);
        self.offline = true;
    }
    pub fn openArchive(self: *Session, path: []const u8, symbols: ?[]const u8, reanalyze: bool) !void {
        if (self.target.snapshot().pid != 0 or self.profile != null or self.imported != null or self.allocations.capture != null or self.allocations.preparing()) return error.ConflictingTargets;
        try self.clearArchiveJob();
        const job = try ArchiveJob.create(self.next_archive_job, .open, path);
        errdefer job.deinit();
        job.local_id = self.next_profile_id;
        job.reanalyze = reanalyze;
        if (symbols) |root| job.symbols = try std.heap.page_allocator.dupeZ(u8, root);
        try job.start();
        self.offline = true;
        self.archive_job = job;
        self.next_archive_job += 1;
        self.next_profile_id += 1;
    }
    pub fn ensureArchiveView(self: *Session, filter: profile.Filter) !void {
        const capture = self.profile orelse return error.NoProfile;
        if (!capture.offline) return;
        try capture.validateFilter(filter);
        self.pollArchive();
        if (capture.offline_graph != null and std.meta.eql(filter, capture.offline_graph_filter)) return;
        if (self.archiveBusy()) return error.ArchiveViewPending;
        if (self.archive_job) |job| {
            if (job.kind == .view and std.meta.eql(filter, job.filter)) {
                if (job.failure) |err| return err;
            }
        }
        try self.clearArchiveJob();
        const job = try ArchiveJob.create(self.next_archive_job, .view, "offline flame graph");
        job.capture = capture;
        job.filter = filter;
        job.start() catch |err| {
            job.deinit();
            return err;
        };
        self.archive_job = job;
        self.next_archive_job += 1;
        return error.ArchiveViewPending;
    }
    pub const Derived = struct { key: @import("../profile/derived.zig").Key, view: @import("../profile/derived.zig").View, budget: *@import("../profile/archive_budget.zig").Budget };
    pub const DerivedState = union(enum) {
        ready: *const @import("../profile/derived.zig").View,
        pending: struct { done: usize, total: usize },
        failed: anyerror,
        unavailable: anyerror,
    };
    fn dropDerived(self: *Session) void {
        if (self.derived) |*published| {
            published.view.deinit();
            std.heap.page_allocator.destroy(published.budget);
        }
        self.derived = null;
        self.derived_failure = null;
    }
    pub fn retryDerived(self: *Session) void {
        self.derived_failure = null;
    }
    /// The reconstructed view for `filter`, starting or awaiting the worker.
    /// Completed captures with sampled stacks only. Never rebuilds a failed
    /// key by itself, and never does DWARF work on the calling thread.
    pub fn requestDerived(self: *Session, filter: profile.Filter) DerivedState {
        return self.requestDerivedOwned(filter, .mcp);
    }
    fn failDerived(self: *Session, key: @import("../profile/derived.zig").Key, err: anyerror) DerivedState {
        self.derived_failure = .{ .key = key, .err = err };
        return .{ .failed = err };
    }
    pub fn requestDerivedOwned(self: *Session, filter: profile.Filter, owner: ArchiveJob.DerivedOwner) DerivedState {
        const derived = @import("../profile/derived.zig");
        self.pollArchive();
        const capture = self.profile orelse return .{ .unavailable = error.NoProfile };
        if (capture.collector != null) return .{ .unavailable = error.ArchiveStillCollecting };
        if (capture.config.user_stack_bytes == 0) return .{ .unavailable = error.SampledStacksDisabled };
        capture.validateFilter(filter) catch |err| return .{ .unavailable = err };
        if (self.frames.job) |job| if (job.capture != null) return .{ .unavailable = error.FrameBusy };
        const key = derived.Key.of(capture, filter);
        if (self.derived) |*published| if (std.meta.eql(published.key, key)) return .{ .ready = &published.view };
        if (self.derived_failure) |failure| if (std.meta.eql(failure.key, key)) return .{ .failed = failure.err };
        if (self.archive_job) |job| if (!job.reaped) {
            if (job.kind == .derived and std.meta.eql(job.derived_key, key)) return .{ .pending = .{ .done = job.progress.units.load(.acquire), .total = capture.samples.len() } };
            // A superseded reconstruction is cancelled; a different kind of
            // job (save, open, inspection) finishes first.
            if (job.kind == .derived and job.derived_owner == owner) {
                job.superseded = true;
                job.progress.cancel.store(true, .release);
            }
            return .{ .pending = .{ .done = 0, .total = capture.samples.len() } };
        };
        self.clearArchiveJob() catch |err| return self.failDerived(key, err);
        const job = ArchiveJob.create(self.next_archive_job, .derived, "reconstructed stack flame view") catch |err| return self.failDerived(key, err);
        job.capture = capture;
        job.capture_id = capture.id;
        job.capture_revision = capture.revision;
        job.filter = filter;
        job.derived_key = key;
        job.derived_owner = owner;
        capture.archive_busy = true;
        job.start() catch |err| {
            job.deinit();
            return self.failDerived(key, err);
        };
        self.archive_job = job;
        self.next_archive_job += 1;
        return .{ .pending = .{ .done = 0, .total = capture.samples.len() } };
    }
    pub fn requestProfileStack(self: *Session, ordinal: usize) !*ArchiveJob {
        if (self.frames.job) |job| if (job.capture != null) return error.FrameBusy;
        self.pollArchive();
        const capture = self.profile orelse return error.NoProfile;
        if (capture.collector != null) return error.ArchiveStillCollecting;
        if (ordinal >= capture.samples.len()) return error.InvalidSampleOrdinal;
        if (self.archive_job) |job| {
            if (job.kind == .stack and job.capture_id == capture.id and job.capture_revision == capture.revision and job.sample_ordinal == ordinal) return job;
        }
        try self.clearArchiveJob();
        const job = try ArchiveJob.create(self.next_archive_job, .stack, "sampled stack reconstruction");
        errdefer job.deinit();
        job.capture = capture;
        job.capture_id = capture.id;
        job.capture_revision = capture.revision;
        job.sample_ordinal = ordinal;
        capture.archive_busy = true;
        try job.start();
        self.archive_job = job;
        self.next_archive_job += 1;
        return job;
    }
    pub fn saveArchive(self: *Session, path: []const u8) !u64 {
        self.frames.poll();
        const attachment_save = try self.frames.archiveSave();
        try self.clearArchiveJob();
        const capture = self.profile orelse return error.NoProfile;
        if (capture.collector != null) return error.ArchiveStillCollecting;
        const job = try ArchiveJob.create(self.next_archive_job, .save, path);
        errdefer job.deinit();
        job.attachment_save = attachment_save;
        if (self.frames.count > 0) {
            self.frames.pinned = true;
            job.frames = &self.frames;
        }
        if (self.artifact) |*artifact| job.original_bytes = artifact.bytes else {
            capture.archive_busy = true;
            job.capture = capture;
        }
        try job.start();
        self.archive_job = job;
        self.next_archive_job += 1;
        return job.id;
    }
    pub fn saveAllocationArchive(self: *Session, path: []const u8) !u64 {
        try self.clearArchiveJob();
        const capture = self.allocations.capture orelse return error.NoAllocationCapture;
        capture.poll();
        if (capture.ended_ns == null or capture.worker != null) return error.AllocationCaptureNotFinalized;
        const job = try ArchiveJob.create(self.next_archive_job, .allocation_save, path);
        errdefer job.deinit();
        job.allocation = capture;
        capture.archive_busy = true;
        try job.start();
        self.archive_job = job;
        self.next_archive_job += 1;
        return job.id;
    }
    pub fn pollArchive(self: *Session) void {
        const job = self.archive_job orelse return;
        if (job.reaped or !job.done.load(.acquire)) return;
        job.join();
        job.reaped = true;
        if (job.frames) |frames| {
            frames.pinned = false;
            job.frames = null;
        }

        if (job.kind == .derived) {
            // Publish only for the capture that is still current.
            const current = if (self.profile) |capture| std.meta.eql(job.derived_key, @import("../profile/derived.zig").Key.of(capture, job.filter)) else false;
            // Cancellation may arrive after the worker's final check but before
            // publication. It must still prevent publication and latch failure.
            const cancelled = job.progress.cancel.load(.acquire);
            if (cancelled and job.failure == null) job.failure = error.ArchiveCancelled;
            if (job.derived_view) |view| {
                if (current and !cancelled and !job.superseded) {
                    self.dropDerived();
                    self.derived = .{ .key = job.derived_key, .view = view, .budget = job.derived_budget.? };
                    job.derived_budget = null;
                } else {
                    var stale = view;
                    stale.deinit();
                }
                job.derived_view = null;
            }
            if (job.failure) |err| {
                // A reconstruction cancelled because the request moved on is
                // not a failure of its key.
                if (current and !job.superseded) self.derived_failure = .{ .key = job.derived_key, .err = err };
            }
        }
        if (job.capture) |capture| {
            capture.archive_busy = false;
            if (job.view) |view| {
                capture.clearOfflineGraph();
                capture.offline_graph = view;
                capture.offline_graph_filter = job.filter;
                capture.offline_graph_budget = job.view_budget;
                job.view = null;
                job.view_budget = null;
            }
        }
        // Clear the borrowed pointer before a later capture can replace it.
        job.capture = null;
        if (job.allocation) |capture| capture.archive_busy = false;
        job.allocation = null;
        if (job.allocation_opened) |capture| {
            if (job.progress.cancel.load(.acquire)) {
                capture.deinit();
                job.failure = error.ArchiveCancelled;
            } else {
                self.allocations.capture = capture;
                capture.requestAnalysis(false) catch {};
                std.debug.print("xodb: opened allocation archive: {d} records, {d} stacks; {s}\n", .{ capture.store.records.items.len, capture.stacks.entries.items.len, job.path });
            }
            job.allocation_opened = null;
        }
        if (job.opened) |opened| {
            self.artifact = opened;
            if (opened.frame_bundle) |bytes| self.frames.restoreArchive(bytes);
            self.dropDerived();
            self.profile = self.artifact.?.capture;
            job.opened = null;
            std.debug.print("xodb: opened archive: {d} samples, {d} annotations, {d} decoded allocation peak bytes; {s}\n", .{ self.profile.?.samples.len(), opened.source.annotation_count, opened.budget.peak, job.path });
        }
        if (job.failure) |err| std.debug.print("xodb: archive {s} failed: {s}; {s}\n", .{ @tagName(job.kind), @errorName(err), job.path });
        if (job.publication) |result| std.debug.print("xodb: archive {s}: {d} bytes; error={s} cleanup_error={}; {s}\n", .{ @tagName(result.state), result.bytes, result.error_name orelse "none", result.cleanup_error, job.path });
    }
    pub fn finishArchive(self: *Session) !void {
        const job = self.archive_job orelse return;
        job.join();
        self.pollArchive();
        if (job.failure) |err| return err;
        if (job.publication) |result| if (result.state != .published) return error.ArchiveSaveFailed;
    }
    pub fn startProfile(self: *Session, request: profile.Config) !u64 {
        if (self.target.core != null) return error.ReadOnlyCore;
        if (self.target.arch() != .x86_64) return error.ProfilingUnsupportedArchitecture;
        self.profile_failure = null;
        self.profile_error = null;
        self.profile_requested_threads = request.tids.len;
        if (request.tids.len == 0) for (self.target.threadSlice()) |thread| {
            if (thread.state != .exited) self.profile_requested_threads += 1;
        };
        return self.openProfile(request) catch |err| {
            self.profile_error = @errorName(err);
            std.debug.print("xodb: profile start failed: {s}; pid={d} requested_threads={d}\n", .{ @errorName(err), self.target.snapshot().pid, self.profile_requested_threads });
            if (self.profile_failure) |failure| std.debug.print("xodb: perf open: {s} syscall={s} errno={d} tid={d} opened_then_closed={d}; {s}\n", .{ @tagName(failure.kind), failure.syscall, failure.errno, failure.tid, failure.opened_then_closed, failure.detail });
            return err;
        };
    }
    fn openProfile(self: *Session, request: profile.Config) !u64 {
        if (self.offline) return error.OfflineSession;
        if (self.archiveBusy()) return error.ArchiveBusy;
        try request.validate();
        if (request.syscall_timing and request.tids.len == 0) return error.SyscallRequiresExplicitThreads;
        if (self.profile != null and self.profile.?.collector != null) return error.ProfileAlreadyRunning;
        if (self.target.snapshot().state != .stopped) return error.NotStopped;
        if (self.source_step != null) return error.StepInProgress;
        var tids: [perf.max_threads]i32 = undefined;
        var identities: [perf.max_threads]u64 = undefined;
        var count: usize = 0;
        var unselected: usize = 0;
        for (self.target.threadSlice()) |thread| {
            if (thread.state == .exited) continue;
            if (request.tids.len > 0 and std.mem.indexOfScalar(i32, request.tids, thread.tid) == null) {
                unselected += 1;
                continue;
            }
            if (thread.state != .stopped) return error.NotStopped;
            if (count == tids.len) return error.ProfileThreadLimit;
            tids[count] = thread.tid;
            identities[count] = thread.id;
            count += 1;
        }
        if (count == 0 or (request.tids.len > 0 and request.tids.len != count)) return error.InvalidProfileThreads;
        var config = request;
        config.follow_threads = request.follow_threads and request.tids.len == 0;
        config.tids = tids[0..count];
        const opened = try profile.Capture.openTarget(self.target.handle, std.heap.page_allocator, self.next_profile_id, self.id, self.target.snapshot().generation, self.target.snapshot().image_epoch, self.target.snapshot().pid, try self.target.stoppedTid(), config, identities[0..count], linux.now());
        switch (opened) {
            .failed => |failure| {
                self.profile_failure = failure;
                return error.PerfOpenFailed;
            },
            .capture => |capture| {
                self.dropDerived();
                if (self.profile) |old| self.recorded_views.retire(old);
                self.profile = capture;
                self.profile_view = null;
                capture.debugger_sequence = self.target.snapshot().sequence;
                capture.addMarker(.{ .offset_ns = 0, .sequence = self.target.snapshot().sequence, .tid = self.target.snapshot().pid, .kind = .capture_open_stopped });
                self.profile_failure = null;
                capture.unselected_threads = unselected;
                if (unselected > 0) {
                    capture.trusted_before_ns = 0;
                    capture.diagnostic = "unselected threads may change mappings; addresses retained without symbols";
                }
                self.next_profile_id += 1;
                return capture.id;
            },
        }
    }
    pub fn stopProfile(self: *Session) !void {
        const capture = self.profile orelse return error.NoProfile;
        if (capture.collector == null) return error.ProfileNotRunning;
        self.profileMarkers(capture);
        capture.stop(.manual, linux.now());
    }
    fn retireProfileThreads(self: *Session, capture: *profile.Capture) void {
        const now = linux.now();
        for (capture.threads[0..capture.thread_count], 0..) |recorded, i| {
            var present = false;
            for (self.target.threadSlice()) |thread| if (thread.id == recorded.debugger_id and thread.tid == recorded.perf.tid) {
                present = true;
                break;
            };
            // PTRACE_EVENT_EXIT alone is too early: wait for final reaping.
            if (!present) capture.retireThread(i, now);
        }
    }
    fn profileNewThread(raw: *anyopaque, thread: linux.Thread, member: bool) void {
        const self: *Session = @ptrCast(@alignCast(raw));
        const capture = self.profile orelse return;
        if (capture.collector == null or !capture.config.follow_threads) return;
        const now = linux.now();
        if (capture.image_epoch != self.target.snapshot().image_epoch) {
            capture.trusted_before_ns = 0;
            capture.stop(.image_changed, now);
            return;
        }
        if (!member) {
            capture.enrollmentFailed(.{ .kind = .configuration, .syscall = "enroll", .tid = thread.tid, .detail = "new task is not a verified member of the captured process" }, now);
            return;
        }
        self.retireProfileThreads(capture);
        capture.enroll(thread.tid, thread.id, now);
    }
    fn pollProfile(self: *Session) void {
        const capture = self.profile orelse return;
        if (capture.collector == null) return;
        self.profileMarkers(capture);
        const now = linux.now();
        capture.syncRemoteThreads(now);
        if (capture.collector == null) return;
        self.retireProfileThreads(capture);
        capture.poll(now);
        if (capture.collector == null) return;
        if (self.target.snapshot().image_epoch != capture.image_epoch) {
            capture.trusted_before_ns = 0;
            capture.stop(.image_changed, now);
        } else if (self.target.snapshot().state == .idle or self.target.snapshot().state == .exited) {
            capture.stop(.target_ended, now);
        } else {
            var unselected: usize = 0;
            for (self.target.threadSlice()) |thread| {
                if (capture.config.follow_threads and thread.newborn) continue;
                if (thread.state != .exited and !capture.includesThread(thread.tid)) unselected += 1;
            }
            if (unselected != capture.unselected_threads) {
                capture.unselected_threads = unselected;
                capture.revision += 1;
                if (unselected > 0) {
                    capture.trusted_before_ns = 0;
                    capture.stop(.thread_scope_changed, now);
                }
            }
        }
    }
    fn profileMarkers(self: *Session, capture: *profile.Capture) void {
        if (self.target.snapshot().sequence == capture.debugger_sequence) return;
        const events = self.target.eventSlice();
        if (events.len > 0 and events[0].sequence > capture.debugger_sequence + 1) {
            capture.debugger_events_lost +|= events[0].sequence - capture.debugger_sequence - 1;
            capture.revision += 1;
        }
        for (events) |event| {
            if (event.sequence <= capture.debugger_sequence or event.time_ns < capture.started_ns) continue;
            const kind: @import("../profile/timeline.zig").MarkerKind = switch (event.kind) {
                .continued => .continued,
                .stop => .stop,
                .step_started => .step_started,
                .step_complete => .step_complete,
                .breakpoint_hit => .breakpoint_hit,
                .watchpoint_hit => .watchpoint_hit,
                .exit => .exit,
                .detach => .detach,
                else => continue,
            };
            if (kind != .continued and kind != .detach and !capture.includesThread(event.tid)) continue;
            capture.addMarker(.{ .offset_ns = event.time_ns - capture.started_ns, .sequence = event.sequence, .tid = event.tid, .kind = kind });
        }
        capture.debugger_sequence = self.target.snapshot().sequence;
    }
    pub fn launch(self: *Session, argv: []const [:0]const u8) !void {
        if (self.launch_argv.len > 0) return error.AlreadyLaunched;
        const a = std.heap.page_allocator;
        const saved = try a.alloc([:0]const u8, argv.len);
        errdefer a.free(saved);
        var count: usize = 0;
        errdefer for (saved[0..count]) |arg| a.free(arg);
        for (argv, saved) |arg, *copy| {
            copy.* = try a.dupeZ(u8, arg);
            count += 1;
        }
        try self.target.launch(saved);
        self.launch_argv = saved;
    }
    pub fn restart(self: *Session) !void {
        if (self.observation_archive) |job| if (!job.done.load(.acquire)) return error.ObservationArchiveBusy;
        if (self.observations.busy()) {
            self.observations.stop(.target_ended);
            return error.ObservationStopping;
        }
        if (self.target.snapshot().birth_count > 0 or self.target.sharedVm()) return error.ProcessFamilyRequiresResolution;
        if (!self.target.snapshot().owned or self.launch_argv.len == 0) return error.RestartRequiresOwnedLaunch;
        if (self.target.snapshot().state != .stopped and self.target.snapshot().state != .exited and self.target.snapshot().state != .idle) return error.PauseBeforeRestart;
        if (self.archiveBusy()) return error.ArchiveBusy;
        self.allocations.stop(.target_ended);
        if (self.profile) |capture| if (capture.collector != null) capture.stop(.target_ended, linux.now());
        if (self.target.snapshot().state == .stopped) try self.persistent.remember(self);
        // Save desired enables before replacing the address space. Thread filters
        // retain their old identity and are disabled until explicitly rebound.
        var enables: [128]bool = undefined;
        var count: usize = 0;
        for (self.persistent.entries.items) |item| {
            enables[count] = if (@import("persistent.zig").Manager.probe(self, item.id)) |probe| probe.enabled else item.enabled;
            count += 1;
        }
        self.cancelStep();
        self.run_to = null;
        self.source_step = null;
        try self.target.reset();
        try self.target.launch(self.launch_argv);
        // Relocation happens before another event-loop policy pass can prune IDs.
        for (self.persistent.entries.items, 0..) |item, i| {
            try self.target.restoreBreakpoint(item.id, enables[i]);
            if (self.probes.rule(item.id)) |rule| {
                rule.matched_hits = 0;
                if (rule.thread_id != null) {
                    try self.target.enableBreakpoint(item.id, false);
                    rule.last_error = "RestartThreadFilterNeedsSelection";
                }
            }
        }
        self.persistent.hook = null;
        self.persistent.debug_address = null;
        self.persistent.loader_attempt = 0;
        self.persistent.epoch = self.target.snapshot().image_epoch;
        self.persistent.observed = 0;
        self.suppress_probe_resume = true;
        try self.persistent.poll(self);
    }
    pub fn openCore(self: *Session, path: []const u8, executable: ?[]const u8) !void {
        if (self.target.snapshot().pid != 0 or self.offline or self.imported != null or self.profile != null) return error.ConflictingTargets;
        try self.target.openCore(path);
        self.modules.debug_files = self.symbolFiles();
        try self.modules.fromCore(&self.target.core.?, executable);
        self.maps_epoch = self.target.snapshot().image_epoch;
        self.maps_generation = self.target.snapshot().generation;
    }
    pub fn refreshMaps(self: *Session) !void {
        if (self.target.core != null) return;
        if (self.target.snapshot().state == .stopped and self.maps_generation != self.target.snapshot().generation) {
            if (self.maps_epoch != self.target.snapshot().image_epoch) {
                const next_id = self.modules.next_id;
                self.modules.deinit();
                self.modules = Modules.init(std.heap.page_allocator);
                self.modules.next_id = next_id;
                self.maps_epoch = self.target.snapshot().image_epoch;
            }
            self.modules.debug_files = self.symbolFiles();
            self.modules.target = self.target.handle;
            try self.modules.refresh(try self.target.stoppedTid());
            self.maps_generation = self.target.snapshot().generation;
        }
    }
    pub fn investigateWrite(self: *Session, tid: i32, frame_index: usize, question: []const u8, expression: []const u8) !u64 {
        if (question.len == 0 or question.len > 4096 or expression.len == 0 or expression.len > 4096) return error.InvalidInvestigation;
        if (self.investigations.items.len == 16) return error.InvestigationLimit;
        const a = self.investigation_arena.allocator();
        const value = try self.evaluateExpression(a, tid, frame_index, expression);
        const address = value.address orelse return error.NotAddressable;
        if (value.type.size > 8 or value.type.size == 0) return error.InvalidWatchRange;
        const summary = try retainEvidence(a, try self.summarize(a, value));
        if (summary.availability != .available) return error.ValueUnavailable;
        const question_copy = try a.dupe(u8, question);
        const expression_copy = try a.dupe(u8, expression);
        try self.investigations.ensureUnusedCapacity(a, 1);
        const watch = try self.target.setWatchpoint(address, @intCast(value.type.size), .write);
        const id = self.investigations.items.len + 1;
        self.investigations.appendAssumeCapacity(.{ .architecture = self.target.arch(), .id = id, .question = question_copy, .expression = expression_copy, .watchpoint_id = watch, .initial = summary, .created_generation = self.target.snapshot().generation, .created_sequence = self.target.snapshot().sequence, .image_epoch = self.target.snapshot().image_epoch });
        return id;
    }
    pub fn investigation(self: *Session, id: u64) !*Investigation {
        if (id == 0 or id > self.investigations.items.len) return error.UnknownInvestigation;
        return &self.investigations.items[@intCast(id - 1)];
    }
    fn precedingInstruction(self: *Session, a: std.mem.Allocator, pc: u64) !?InstructionEvidence {
        if (pc == 0) return null;
        const symbol = self.modules.symbolAt(pc - 1) catch return null;
        if (symbol.address >= pc or pc - symbol.address > 4096) return null;
        var bytes: [4096]u8 = undefined;
        const count: usize = @intCast(pc - symbol.address);
        if (try self.target.readMemory(symbol.address, bytes[0..count]) != count) return null;
        var instructions: [1024]@import("disassembly.zig").Instruction = undefined;
        const n = try @import("disassembly.zig").decodeFor(self.target.arch(), bytes[0..count], symbol.address, &instructions);
        if (n == 0) return null;
        const last = instructions[n - 1];
        if (last.address + last.size != pc) return null;
        return .{ .address = last.address, .mnemonic = try a.dupe(u8, std.mem.sliceTo(&last.mnemonic, 0)), .operands = try a.dupe(u8, std.mem.sliceTo(&last.operands, 0)), .source = self.sourceAt(a, last.address) catch null };
    }
    fn armAccessInstruction(self: *Session, a: std.mem.Allocator, pc: u64) !?InstructionEvidence {
        var bytes: [4]u8 = undefined;
        if (try self.target.readMemory(pc, &bytes) != 4) return null;
        var decoded: [1]@import("disassembly.zig").Instruction = undefined;
        if (try @import("disassembly.zig").decodeFor(self.target.arch(), &bytes, pc, &decoded) != 1) return null;
        const inst = decoded[0];
        return .{ .address = pc, .mnemonic = try a.dupe(u8, std.mem.sliceTo(&inst.mnemonic, 0)), .operands = try a.dupe(u8, std.mem.sliceTo(&inst.operands, 0)), .source = self.sourceAt(a, pc) catch null, .basis = "decode_at_recorded_pre_access_trap_pc" };
    }
    fn captureInvestigations(self: *Session) !void {
        if (self.target.snapshot().state == .running) return;
        const a = self.investigation_arena.allocator();
        for (self.investigations.items) |*record_| {
            var installed = false;
            for (self.target.watchpointSlice()) |watch| if (watch != null and watch.?.id == record_.watchpoint_id) {
                installed = true;
            };
            if (!installed or self.target.snapshot().state != .stopped or self.target.snapshot().image_epoch != record_.image_epoch) {
                record_.status = .finished;
                continue;
            }
            for (self.target.eventSlice()) |event| {
                if (event.sequence <= self.evidence_sequence or event.sequence <= record_.created_sequence or event.kind != .watchpoint_hit or event.detail != record_.watchpoint_id) continue;
                if (record_.observations.items.len == 16) {
                    record_.status = .capacity_reached;
                    continue;
                }
                const frames: []Frame = self.stack(a, event.tid, 16) catch try a.alloc(Frame, 0);
                var value = record_.initial;
                // Keep the watched identity even if the expression goes out of
                // scope or a pointer variable changes at this stop.
                value.bits = event.after;
                const fixed_type = eval.Type{ .name = value.type, .kind = value.kind, .size = value.size };
                value = try self.summarize(a, .{ .type = &fixed_type, .bits = event.after });
                value.address = event.address;
                if (!event.after_valid) {
                    value.bits = null;
                    value.availability = .unavailable;
                    value.display = "[access completion/value unavailable]";
                    value.diagnostic = "Watch access interrupted or completed value unreadable";
                }
                const variables = self.locals(a, event.tid, 0) catch &.{};
                var saved_locals: std.ArrayList(LocalEvidence) = .empty;
                for (variables[0..@min(64, variables.len)]) |variable| {
                    try saved_locals.append(a, .{ .name = variable.name, .value = try self.summarize(a, variable.value), .diagnostic = variable.diagnostic });
                }
                const observation = Observation{ .locals = try saved_locals.toOwnedSlice(a), .locals_truncated = variables.len > 64, .event = event, .captured_generation = self.target.snapshot().generation, .value = value, .frames = frames, .preceding_instruction = if (event.trap_pc == null) self.precedingInstruction(a, event.pc) catch null else null, .access_instruction = if (event.trap_pc) |pc| self.armAccessInstruction(a, pc) catch null else null };
                try record_.observations.append(a, try retainEvidence(a, observation));
            }
        }
        self.evidence_sequence = self.target.snapshot().sequence;
    }
    pub fn saveInvestigations(self: *Session, path: [:0]const u8) !void {
        // Exclusive creation keeps an existing evidence file intact.
        const c = @import("../c.zig").api;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const bytes = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .schema_version = 1, .session_id = self.id, .investigations = self.investigations.items, .audit = self.audit[0..self.audit_count] }, .{ .whitespace = .indent_2 });
        const file = c.fopen(path, "wx") orelse return error.EvidenceFileUnavailable;
        defer _ = c.fclose(file);
        if (c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len or c.fflush(file) != 0) return error.EvidenceWriteFailed;
    }
    pub fn stepInstruction(self: *Session, tid: i32) !void {
        if (self.persistent.resolving) return error.SymbolDiscoveryPending;
        self.suppress_probe_resume = true;
        try self.target.singleStep(tid);
    }
    pub fn runTo(self: *Session, tid: i32, address: u64, expected_sp: ?u64, actor: Actor) !void {
        if (self.target.snapshot().state != .stopped) return error.NotStopped;
        if (self.source_step != null or self.run_to != null) return error.StepInProgress;
        var identity: ?u64 = null;
        for (self.target.threadSlice()) |thread| if (thread.tid == tid and thread.state == .stopped) {
            identity = thread.id;
        };
        const stable_id = identity orelse return error.UnknownThread;
        var owned = true;
        for (self.target.breakpointSlice()) |probe| if (probe.address == address) {
            if (!probe.enabled) return error.RunToDisabledBreakpoint;
            owned = false;
        };
        const id = try self.target.setBreakpoint(address, false);
        errdefer if (owned) {
            self.target.removeBreakpoint(id) catch {};
        };
        self.run_to = .{ .tid = tid, .thread_id = stable_id, .address = address, .probe = id, .owns_probe = owned, .image_epoch = self.target.snapshot().image_epoch, .expected_sp = expected_sp };
        errdefer self.run_to = null;
        self.step_diagnostic = null;
        try self.continueExecution(actor);
    }
    pub fn finishFrame(self: *Session, tid: i32, frame_index: usize, actor: Actor) !void {
        if (frame_index >= 63) return error.InvalidFrame;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const frames = try self.stack(arena.allocator(), tid, frame_index + 2);
        if (frames.len <= frame_index + 1) return error.CallerUnavailable;
        const caller = frames[frame_index + 1];
        const sp = caller.registers[self.target.arch().sp()] orelse return error.CallerUnavailable;
        try self.runTo(tid, caller.pc, sp, actor);
    }
    fn pollRunTo(self: *Session, filtered: bool) !void {
        const run = self.run_to orelse return;
        if (self.target.snapshot().image_epoch != run.image_epoch or self.target.snapshot().state == .exited or self.target.snapshot().state == .idle) {
            self.run_to = null;
            return;
        }
        if (self.target.snapshot().state != .stopped) return;
        if (self.target.sharedVm()) {
            self.run_to.?.cancelled = true;
            return;
        }
        var reached = false;
        var foreign_hit = false;
        for (self.target.threadSlice()) |thread| if (thread.reason == .breakpoint and thread.breakpoint_address == run.address) {
            if (thread.tid == run.tid and thread.id == run.thread_id) {
                const regs = try self.target.registers(thread.tid);
                const sp = linux.stackPointer(regs) catch null;
                reached = run.expected_sp == null or (sp != null and sp.? == run.expected_sp.?);
            } else foreign_hit = true;
        };
        if (filtered and foreign_hit and !reached and !self.run_to.?.cancelled) {
            self.run_to.?.ignored_stops += 1;
            if (self.run_to.?.ignored_stops >= 64) {
                self.run_to.?.cancelled = true;
                self.step_diagnostic = "RunToNoProgress";
            }
        }
        if (reached or self.run_to.?.cancelled or !filtered) {
            if (run.owns_probe) self.target.removeBreakpoint(run.probe) catch |err| {
                if (err != error.UnknownBreakpoint) return err;
            };
            self.run_to = null;
            self.suppress_probe_resume = true;
        }
    }
    pub fn continueExecution(self: *Session, actor: Actor) !void {
        try self.persistent.remember(self);
        try self.persistent.poll(self);
        self.probe_resume_actor = actor;
        if (self.persistent.resolving) {
            const snapshot_ = self.target.snapshot();
            self.pending_continue = .{ .generation = snapshot_.generation, .epoch = snapshot_.image_epoch, .actor = actor, .lease = if (actor == .agent) self.agent_lease else null };
            self.suppress_probe_resume = true;
            return;
        }
        self.pending_continue = null;
        if (actor == .agent) if (self.agent_lease) |lease| {
            if (!lease.valid(linux.now(), @intFromEnum(self.agent_scope))) return error.ControlLeaseRequired;
        };
        try self.target.continueExecution();
        self.suppress_probe_resume = false;
    }
    pub fn cancelStep(self: *Session) void {
        self.pending_continue = null;
        self.stepping_over = false;
        self.suppress_probe_resume = true;
        if (self.run_to) |*run| run.cancelled = true;
        self.source_step = null;
    }
    pub fn startSourceStep(self: *Session, tid: i32, over: bool) !void {
        try self.persistent.remember(self);
        try self.persistent.poll(self);
        if (self.persistent.resolving) return error.SymbolDiscoveryPending;
        self.suppress_probe_resume = true;
        if (self.source_step != null) return error.StepInProgress;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const regs = try self.target.registers(tid);
        const site = try self.sourceAt(arena.allocator(), try linux.programCounter(regs));
        if (site.path.len > 4096) return error.SourcePathTooLong;
        var step = SourceStep{ .tid = tid, .line = site.line, .path = undefined, .path_len = site.path.len, .over = over };
        @memcpy(step.path[0..site.path.len], site.path);
        self.source_step = step;
        self.source_step_resumes = 0;
        self.source_step_batched = 0;
        self.step_diagnostic = null;
        errdefer self.source_step = null;
        try self.advanceSourceStep();
    }
    fn advanceSourceStep(self: *Session) !void {
        if (self.source_step == null) return;
        const step = &self.source_step.?;
        self.source_step.?.instructions += 1;
        self.source_step_resumes += 1;
        self.source_step.?.return_address = null;
        if (try self.advanceSourceBlock()) return;
        if (step.over) {
            const regs = try self.target.registers(step.tid);
            var bytes: [16]u8 = undefined;
            const pc = try linux.programCounter(regs);
            const n = try self.target.readMemory(pc, &bytes);
            var instructions: [1]@import("disassembly.zig").Instruction = undefined;
            const count = try @import("disassembly.zig").decodeFlowFor(self.target.arch(), bytes[0..n], pc, &instructions);
            if (count == 1 and instructions[0].flow == .call) {
                const address = pc + instructions[0].size;
                var user_breakpoint = false;
                for (self.target.breakpointSlice()) |probe| {
                    if (probe.address == address and !probe.temporary) user_breakpoint = true;
                }
                if (!user_breakpoint) self.source_step.?.return_address = address;
            }
            try self.stepOverInstruction(step.tid);
        } else try self.target.singleStep(step.tid);
    }
    /// Batch a straight-line run on the current source line. A single live
    /// thread preserves single-step peer scheduling; multi-thread/shared-VM
    /// targets keep the instruction path. Calls, branches, traps and syscalls
    /// are boundaries, as are source changes and existing user probes.
    fn advanceSourceBlock(self: *Session) !bool {
        if (self.target.arch() != .x86_64) return false;
        const step = &self.source_step.?;
        if (self.target.sharedVm() or self.target.snapshot().birth_count != 0) return false;
        var live: usize = 0;
        for (self.target.threadSlice()) |thread| if (thread.state != .exited) {
            live += 1;
        };
        if (live != 1) return false;
        const regs = try self.target.registers(step.tid);
        const pc = try linux.programCounter(regs);
        var bytes: [256]u8 = undefined;
        const n = self.target.readMemory(pc, &bytes) catch return false;
        var instructions: [64]@import("disassembly.zig").Instruction = undefined;
        const count = @import("disassembly.zig").decodeFlowFor(self.target.arch(), bytes[0..n], pc, &instructions) catch return false;
        if (count < 3) return false;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var boundary: usize = 0;
        while (boundary + 1 < count) : (boundary += 1) {
            const inst = instructions[boundary];
            const site = self.sourceAt(arena.allocator(), inst.address) catch break;
            if (site.line != step.line or !std.mem.eql(u8, site.path, step.path[0..step.path_len]) or inst.flow != .ordinary) break;
        }
        if (boundary < 2) return false;
        const address = instructions[boundary].address;
        for (self.target.breakpointSlice()) |probe| {
            if (!probe.pending and probe.address > pc and probe.address <= address) return false;
        }
        const probe = self.target.setBreakpoint(address, true) catch return false;
        errdefer self.target.removeBreakpoint(probe) catch {};
        step.return_address = address;
        try self.target.continueExecution();
        self.source_step_batched += boundary;
        return true;
    }
    pub fn poll(self: *Session) !void {
        defer self.inspections.poll(self);
        defer self.pollObservationArchive();
        if (self.target.core != null) {
            self.memory.poll(self);
            return;
        }
        self.frames.poll();
        if (self.imported) |*state| {
            state.poll();
            return;
        }
        self.pollArchive();
        self.target.new_thread_observer = .{ .context = self, .before_resume = profileNewThread };
        defer self.target.new_thread_observer = null;
        self.target.poll() catch |err| {
            self.persistent.resolving = false;
            self.cancelStep();
            self.allocations.stop(.collector_error);
            self.allocations.poll(false, .collector_error);
            self.observations.stop(.collector_error);
            self.observations.poll(false, .collector_error);
            return err;
        };
        self.pollAllocations();
        self.pollObservations();
        if (self.process_tree) |tree| tree.admit(self);
        if (self.target.snapshot().birth_count > 0) {
            self.cancelStep();
            self.pollProfile();
            self.recorded_views.poll(self.profile);
            return;
        }
        if (self.pending_continue) |pending| {
            const snapshot_ = self.target.snapshot();
            if (snapshot_.state != .stopped or snapshot_.generation != pending.generation or snapshot_.image_epoch != pending.epoch or
                (pending.actor == .agent and (self.agent_scope == .observe or
                    (if (pending.lease) |lease| !lease.valid(linux.now(), @intFromEnum(self.agent_scope)) else false))))
            {
                self.cancelStep();
                self.step_diagnostic = "DeferredContinueCancelled";
            }
        }
        self.persistent.poll(self) catch |err| {
            self.cancelStep();
            self.suppress_probe_resume = true;
            self.step_diagnostic = @errorName(err);
            std.debug.print("xodb: breakpoint relocation stopped: {s}\n", .{@errorName(err)});
        };
        self.memory.poll(self);
        self.pollProfile();
        self.recorded_views.poll(self.profile);
        try self.captureInvestigations();
        if (self.pending_continue) |*pending| pending.generation = self.target.snapshot().generation;
        // Keep breakpoint events unconsumed until their symbol discovery has
        // completed. Otherwise an internal loader stop could resume too soon.
        if (self.persistent.resolving) return;
        if (self.pending_continue) |pending| {
            // A slice can cross the lease deadline. Recheck immediately before
            // resuming, even when the same peer has since reclaimed control.
            if (pending.lease) |lease| if (!lease.valid(linux.now(), @intFromEnum(self.agent_scope))) {
                self.cancelStep();
                self.step_diagnostic = "DeferredContinueCancelled";
                return;
            };
            self.pending_continue = null;
            try self.target.continueExecution();
            self.suppress_probe_resume = false;
            return;
        }
        const internal_id = if (self.run_to) |run| (if (run.owns_probe) run.probe else null) else null;
        const filtered = try self.probes.poll(self, internal_id);
        try self.pollRunTo(filtered);
        // A hidden loader rendezvous may interrupt an instruction/source step-over.
        // Preserve its temporary return probe; explicit pause cancels the operation.
        if (filtered and self.target.onlyInternalStops() and (self.source_step != null or self.stepping_over) and self.run_to == null) {
            if (self.probe_resume_actor == .agent and self.agent_scope == .observe) {
                self.step_diagnostic = "AgentScopeRevoked";
                return;
            }
            try self.target.continueExecution();
            return;
        }
        if (self.target.snapshot().state == .stopped and !self.target.onlyInternalStops()) self.stepping_over = false;
        if (self.target.snapshot().state == .stopped and !self.target.sharedVm() and self.source_step == null and !self.stepping_over and self.suppress_probe_resume) {
            var b: usize = 0;
            while (b < self.target.snapshot().breakpoint_count) {
                const probe = self.target.breakpointSlice()[b];
                if (probe.temporary) try self.target.removeBreakpoint(probe.id) else b += 1;
            }
        }
        if (filtered and self.source_step == null and !self.suppress_probe_resume) {
            if (self.probe_resume_actor == .agent and self.agent_scope == .observe) {
                self.step_diagnostic = "AgentScopeRevoked";
            } else {
                self.target.continueExecution() catch |err| {
                    self.step_diagnostic = @errorName(err);
                    return;
                };
                return;
            }
        }
        if (self.source_step) |step| {
            if (self.target.snapshot().state == .exited or self.target.snapshot().state == .idle) {
                self.source_step = null;
                return;
            }
            if (self.target.snapshot().state != .stopped) return;
            var expected_stop = false;
            for (self.target.threadSlice()) |thread| {
                if (thread.tid == step.tid) expected_stop = thread.reason == .single_step or (thread.reason == .breakpoint and step.return_address != null and step.return_address.? == thread.breakpoint_address);
                if (thread.tid != step.tid and thread.reason != .interrupt and thread.reason != .none) {
                    self.source_step = null;
                    return;
                }
            }
            if (!expected_stop) {
                self.source_step = null;
                return;
            }
            if (step.instructions >= 10000) {
                self.step_diagnostic = "SourceStepResumeLimit";
                self.source_step = null;
                return;
            }
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const regs = try self.target.registers(step.tid);
            if (self.sourceAt(arena.allocator(), try linux.programCounter(regs))) |site| {
                if (site.line != step.line or !std.mem.eql(u8, site.path, step.path[0..step.path_len])) {
                    self.source_step = null;
                    return;
                }
            } else |_| {}
            self.advanceSourceStep() catch |err| {
                self.step_diagnostic = @errorName(err);
                self.source_step = null;
            };
        }
    }
    pub fn stepOverInstruction(self: *Session, tid: i32) !void {
        if (self.persistent.resolving) return error.SymbolDiscoveryPending;
        self.stepping_over = false;
        self.suppress_probe_resume = true;
        const regs = try self.target.registers(tid);
        var bytes: [16]u8 = undefined;
        const pc = try linux.programCounter(regs);
        const n = try self.target.readMemory(pc, &bytes);
        var instructions: [1]@import("disassembly.zig").Instruction = undefined;
        const count = try @import("disassembly.zig").decodeFlowFor(self.target.arch(), bytes[0..n], pc, &instructions);
        if (count == 1 and instructions[0].flow == .call) {
            _ = try self.target.setBreakpoint(pc + instructions[0].size, true);
            try self.target.continueExecution();
            self.stepping_over = true;
        } else try self.target.singleStep(tid);
    }
    fn readTarget(ptr: *anyopaque, address: u64, out: []u8) !usize {
        const self: *Session = @ptrCast(@alignCast(ptr));
        return self.target.readMemory(address, out);
    }
    pub fn functionGraph(self: *Session, a: std.mem.Allocator, address: u64) !FunctionGraph {
        if (self.target.snapshot().state != .stopped) return error.NotStopped;
        try self.refreshMaps();
        const module = try self.modules.at(address);
        const pc = try module.linkAddress(address);
        const found = module.symbols().symbolAt(pc);
        var extent_source: @FieldType(FunctionGraph, "extent_source") = .elf_symbol;
        var range_index: usize = 0;
        var range_count: usize = 1;
        var function_name: []const u8 = "";
        var link: u64 = 0;
        var size: u64 = 0;
        if (found) |entry| {
            if (entry.symbol.type != .func and entry.symbol.type != .gnu_ifunc) return error.FunctionSymbolRequired;
            function_name = entry.symbol.name;
            link = entry.symbol.value;
            size = entry.symbol.size;
        }
        if (size == 0) {
            const debug = module.debugInfo() catch return error.FunctionExtentUnavailable;
            const range = debug.functionRangeAt(a, pc) catch |err| return switch (err) {
                error.NoDebugInfo, error.NoDebugInfoAtAddress, error.NoFunctionRange => error.FunctionExtentUnavailable,
                else => err,
            };
            extent_source = .dwarf_subprogram;
            function_name = range.name;
            link = range.address;
            size = range.end - range.address;
            range_index = range.range_index;
            range_count = range.range_count;
        }
        if (size > cfg.max_bytes) return error.FunctionTooLarge;
        const start = try module.runtimeAddress(link);
        const end = std.math.add(u64, start, size) catch return error.InvalidAddress;
        var executable = false;
        for (self.modules.regions.items) |region| if (start >= region.start and end <= region.end and region.permissions[2] == 'x') {
            executable = true;
            break;
        };
        if (!executable) return error.FunctionNotExecutable;
        const bytes = try a.alloc(u8, @intCast(size));
        defer a.free(bytes);
        if (try self.target.readMemory(start, bytes) != bytes.len) return error.FunctionMemoryIncomplete;
        var graph = try cfg.buildFor(self.target.arch(), a, bytes, start);
        errdefer graph.deinit(a);
        if (module.debugInfo()) |debug| {
            for (graph.blocks) |*block| {
                var site = debug.siteAt(a, try module.linkAddress(block.address)) catch continue;
                site.address = try module.runtimeAddress(site.address);
                const mapped = try self.sourceMaps().forward(a, site.path);
                if (mapped.ptr != site.path.ptr) {
                    site.original_path = site.path;
                    site.path = mapped;
                }
                block.source = site;
            }
        } else |_| {}
        return .{ .generation = self.target.snapshot().generation, .image_epoch = self.target.snapshot().image_epoch, .module_id = module.id, .symbol = try a.dupe(u8, function_name), .link_address = link, .extent_source = extent_source, .range_index = range_index, .range_count = range_count, .graph = graph };
    }
    pub fn sourceAt(self: *Session, a: std.mem.Allocator, address: u64) !info.Site {
        try self.refreshMaps();
        const module = try self.modules.at(address);
        var site = try (try module.debugInfo()).siteAt(a, try module.linkAddress(address));
        site.address = try module.runtimeAddress(site.address);
        const mapped = try self.sourceMaps().forward(a, site.path);
        if (mapped.ptr != site.path.ptr) {
            site.original_path = site.path;
            site.path = mapped;
        }
        return site;
    }
    pub fn remoteSource(self: *Session, a: std.mem.Allocator, site: info.Site) ![]u8 {
        if (!self.fetch_source or site.original_path != null) return error.RemoteSourceDisabled;
        const rt = @import("../target/runtime.zig").c;
        const module = try self.modules.at(site.address);
        if (module.file_offset != 0) return error.RemoteSourceEmbeddedImageUnsupported;
        for (self.modules.regions.items) |region| {
            if (site.address < region.start or site.address >= region.end) continue;
            const path = try a.dupeZ(u8, region.path);
            defer a.free(path);
            const request = rt.struct_xrt_file_request{ .kind = rt.XRT_FILE_MAPPED, .mapping = .{ .start = region.start, .end = region.end, .offset = region.offset, .device_major = region.device_major, .device_minor = region.device_minor, .inode = region.inode, .path = path } };
            return @import("remote_source.zig").fetch(a, self.target.handle orelse return error.RemoteSourceUnavailable, &request, site.path, module.image.buildId() orelse return error.SourceBuildIdMissing);
        }
        return error.UnmappedAddress;
    }
    pub fn sourceAddresses(self: *Session, a: std.mem.Allocator, path: []const u8, line: u32) ![]u64 {
        try self.refreshMaps();
        var addresses: std.ArrayList(u64) = .empty;
        const originals = try self.sourceMaps().originals(a, path);
        for (self.modules.regions.items) |region| {
            if (region.offset != 0 and region.permissions[2] != 'x') continue;
            const module = self.modules.load(region) catch continue;
            const debug = module.debugInfo() catch continue;
            for (originals) |original| {
                const rows = debug.rowsForLine(a, original, line) catch continue;
                for (rows) |row| {
                    const address = try module.runtimeAddress(row.address);
                    var found = false;
                    for (addresses.items) |old| if (old == address) {
                        found = true;
                        break;
                    };
                    if (!found) try addresses.append(a, address);
                }
            }
        }
        if (addresses.items.len == 0) return error.NoCodeForSourceLine;
        return addresses.toOwnedSlice(a);
    }
    pub fn setSourceBreakpoint(self: *Session, a: std.mem.Allocator, path: []const u8, line: u32) ![]u64 {
        const addresses = try self.sourceAddresses(a, path, line);
        if (addresses.len > 128 - self.target.snapshot().breakpoint_count) return error.BreakpointLimit;
        const ids = try a.alloc(u64, addresses.len);
        var added: std.ArrayList(u64) = .empty;
        errdefer for (added.items) |id| self.target.removeBreakpoint(id) catch {};
        for (addresses, ids) |address, *id| {
            const previous = self.target.snapshot().breakpoint_count;
            id.* = try self.target.setBreakpoint(address, false);
            if (self.target.snapshot().breakpoint_count != previous) try added.append(a, id.*);
        }
        return ids;
    }
    pub fn stack(self: *Session, a: std.mem.Allocator, tid: i32, limit: usize) ![]Frame {
        if (self.target.snapshot().state != .stopped) return error.NotStopped;
        try self.refreshMaps();
        const raw_registers = try self.target.registers(tid);
        var registers = loc.registers(raw_registers);
        var frames: std.ArrayList(Frame) = .empty;
        while (frames.items.len < @min(64, limit)) {
            const arch_ = self.target.arch();
            const slot = arch_.pc();
            // LoongArch csr_era has no DWARF number. The top frame uses the
            // kernel PC; a caller frame's PC is the return-address column.
            const pc = if (slot < registers.len)
                registers[slot] orelse break
            else if (frames.items.len == 0)
                linux.programCounter(raw_registers) catch break
            else
                registers[arch_.ra()] orelse break;
            if (pc == 0) break;
            var frame = Frame{ .architecture = self.target.arch(), .tid = tid, .index = frames.items.len, .pc = pc, .lookup_pc = if (frames.items.len > 0) self.target.arch().callerLookup(pc) orelse break else pc, .registers = registers };
            frame.source = self.sourceAt(a, frame.lookup_pc) catch null;
            if (self.modules.symbolAt(frame.lookup_pc)) |symbol| frame.symbol = symbol.name else |_| {}
            const module = self.modules.at(frame.lookup_pc) catch |err| {
                frame.diagnostic = @errorName(err);
                try frames.append(a, frame);
                break;
            };
            frame.module_id = module.id;
            const debug = module.debugInfo() catch |err| {
                frame.diagnostic = @errorName(err);
                try frames.append(a, frame);
                break;
            };
            frame.inline_frames = debug.inlineAt(a, try module.linkAddress(frame.lookup_pc)) catch |err| blk: {
                frame.inline_diagnostic = @errorName(err);
                break :blk &.{};
            };
            for (frame.inline_frames) |*inlined| {
                if (inlined.call_path) |path| inlined.call_path = try self.sourceMaps().forward(a, path);
                if (inlined.decl_path) |path| inlined.decl_path = try self.sourceMaps().forward(a, path);
            }
            const step = debug.unwind(a, try module.linkAddress(frame.lookup_pc), .{ .registers = registers, .load_bias = module.bias, .user = self, .read = readTarget }) catch |err| {
                frame.diagnostic = @errorName(err);
                try frames.append(a, frame);
                break;
            };
            frame.cfa = step.cfa;
            frame.unwind_method = @tagName(step.method);
            try frames.append(a, frame);
            const caller_pc = if (slot < step.caller.len) step.caller[slot] else step.caller[arch_.ra()];
            const frame_pc: ?u64 = if (slot < registers.len) registers[slot] else pc;
            if (caller_pc == frame_pc and step.caller[arch_.sp()] == registers[arch_.sp()]) {
                frames.items[frames.items.len - 1].diagnostic = "UnwindCycle";
                break;
            }
            if (step.outermost) break;
            registers = step.caller;
        }
        return frames.toOwnedSlice(a);
    }
    pub fn locals(self: *Session, a: std.mem.Allocator, tid: i32, frame_index: usize) ![]info.Local {
        if (frame_index >= 64) return error.InvalidFrame;
        const frames = try self.stack(a, tid, frame_index + 1);
        if (frame_index >= frames.len) return error.InvalidFrame;
        return self.frameLocals(a, frames[frame_index]);
    }
    /// Locals of a frame from `stack`, without unwinding again.
    pub fn frameLocals(self: *Session, a: std.mem.Allocator, frame: Frame) ![]info.Local {
        return self.frameLocalsAtDepth(a, frame, 0);
    }
    pub fn localsAtDepth(self: *Session, a: std.mem.Allocator, tid: i32, frame_index: usize, depth: usize) ![]info.Local {
        if (frame_index >= 64 or depth > 64) return error.InvalidFrame;
        const frames = try self.stack(a, tid, frame_index + 1);
        if (frame_index >= frames.len) return error.InvalidFrame;
        return self.frameLocalsAtDepth(a, frames[frame_index], depth);
    }
    pub fn frameLocalsAtDepth(self: *Session, a: std.mem.Allocator, frame: Frame, depth: usize) ![]info.Local {
        if (depth > frame.inline_frames.len) return error.InvalidInlineDepth;
        if (self.target.snapshot().state != .stopped) return error.NotStopped;
        const module = try self.modules.at(frame.lookup_pc);
        var context = LocalContext{ .session = self };
        if (self.target.arch() == .x86_64 and frame.index == 0 and frame.tid != 0) context.vector = self.target.extendedRegisters(frame.tid) catch null;
        return (try module.debugInfo()).localsAtDepth(a, try module.linkAddress(frame.lookup_pc), .{ .registers = frame.registers, .cfa = frame.cfa, .load_bias = module.bias, .user = &context, .read = LocalContext.read, .register_data = LocalContext.register }, depth);
    }
    const LocalContext = struct {
        session: *Session,
        vector: ?@import("../target/xstate.zig").State = null,
        fn read(ptr: *anyopaque, address: u64, out: []u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.session.target.readMemory(address, out);
        }
        fn register(ptr: *anyopaque, number: u64) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.vector) |*v| {
                if (number >= 17 and number <= 32) return v.vectors[@intCast(number - 17)][0..16];
                if (number >= 33 and number <= 40 and v.st_valid[@intCast(number - 33)]) return &v.st[@intCast(number - 33)];
            }
            return null;
        }
    };
    pub fn summarize(self: *Session, a: std.mem.Allocator, value: eval.Value) !ValueSummary {
        var result = ValueSummary{ .type = value.type.name, .kind = value.type.kind, .size = value.type.size, .address = value.address, .bits = null, .display = @tagName(value.availability), .availability = value.availability, .language = value.type.language };
        result.composite = value.data != null;
        result.partial = eval.hasMissingBits(value);
        if (result.partial) result.diagnostic = "PartialValue";
        if (value.availability != .available) return result;
        const Stub = struct {
            fn lookup(_: *anyopaque, _: []const u8) !eval.Value {
                return error.UnknownVariable;
            }
        };
        const v = eval.materialize(.{ .allocator = a, .user = self, .read = readTarget, .lookup = Stub.lookup }, value) catch |err| {
            result.availability = if (err == error.UnsupportedType) .unsupported else .unavailable;
            result.diagnostic = @errorName(err);
            result.display = @errorName(err);
            return result;
        };
        result.bits = if (v.type.kind == .array or v.type.kind == .structure) null else v.bits;
        result.display = switch (v.type.kind) {
            .signed => try std.fmt.allocPrint(a, "{d}", .{@as(i64, @bitCast(v.bits))}),
            .unsigned => try std.fmt.allocPrint(a, "{d}", .{v.bits}),
            .pointer => try std.fmt.allocPrint(a, "0x{x}", .{v.bits}),
            .boolean => if (v.bits == 0) "false" else "true",
            .float => if (v.type.size == 4) try std.fmt.allocPrint(a, "{d}", .{@as(f32, @bitCast(@as(u32, @truncate(v.bits))))}) else try std.fmt.allocPrint(a, "{d}", .{@as(f64, @bitCast(v.bits))}),
            .array => try std.fmt.allocPrint(a, "[{d} elements]", .{v.type.count}),
            .structure => try std.fmt.allocPrint(a, "{{{d} fields}}", .{v.type.fields.len}),
            .unknown => "unsupported type",
        };
        if (eval.enumeratorName(v)) |label| {
            result.enumerator = label;
            result.display = try std.fmt.allocPrint(a, "{s} ({s})", .{ label, result.display });
        }
        const lua_preview = @import("../language/lua.zig").preview(self, a, v) catch |err| blk: {
            result.diagnostic = @errorName(err);
            break :blk null;
        };
        if (lua_preview) |shown| {
            result.visualization = shown;
            result.display = if (shown.lua.?.display.len > 0) shown.lua.?.display else shown.diagnostic orelse "Lua value unavailable";
            result.diagnostic = shown.diagnostic;
            return result;
        }
        const javascript_preview = @import("../language/javascript.zig").preview(self, a, v) catch |err| blk: {
            result.diagnostic = @errorName(err);
            break :blk null;
        };
        if (javascript_preview) |shown| {
            result.visualization = shown;
            result.display = shown.javascript.?.display;
            result.diagnostic = shown.diagnostic;
            return result;
        }
        const perl_preview = @import("../language/perl.zig").preview(self, a, v) catch |err| blk: {
            result.diagnostic = @errorName(err);
            break :blk null;
        };
        if (perl_preview) |shown| {
            result.visualization = shown;
            const detail = shown.perl.?;
            result.display = try std.fmt.allocPrint(a, "{s} (refcnt {d}, flags 0x{x})", .{ detail.display, detail.refcount, detail.flags });
            result.diagnostic = shown.diagnostic;
            return result;
        }
        const python_preview = @import("../language/python.zig").preview(self, a, v) catch |err| blk: {
            result.diagnostic = @errorName(err);
            break :blk null;
        };
        if (python_preview) |shown| {
            result.visualization = shown;
            const detail = shown.python.?;
            // A rejected head has no meaningful refcount (N7).
            result.display = if (std.mem.eql(u8, detail.type, "freed") or std.mem.eql(u8, detail.type, "invalid"))
                try a.dupe(u8, detail.display)
            else if (detail.immortal)
                try std.fmt.allocPrint(a, "{s} (immortal)", .{detail.display})
            else
                try std.fmt.allocPrint(a, "{s} (refcnt {d})", .{ detail.display, detail.refcount });
            result.diagnostic = shown.diagnostic;
            return result;
        }
        result.visualization = value_view.preview(self.valueContext(a), v) catch |err| blk: {
            result.diagnostic = @errorName(err);
            break :blk null;
        };
        if (result.visualization) |shown| {
            if (shown.text) |text| {
                const quoted = try std.json.Stringify.valueAlloc(a, text, .{});
                result.display = try std.fmt.allocPrint(a, "{s}{s} [{d} bytes]", .{ quoted, if (shown.truncated) "..." else "", shown.count });
            } else if (shown.hex) |hex| {
                result.display = try std.fmt.allocPrint(a, "hex {s}{s} [{d} bytes]", .{ hex, if (shown.truncated) "..." else "", shown.count });
            } else result.display = try std.fmt.allocPrint(a, "[{d} {s}] @ 0x{x}{s}", .{ shown.count, shown.element_type, shown.data_address, if (shown.diagnostic != null) " (unreadable)" else "" });
        }
        return result;
    }
    fn valueContext(self: *Session, a: std.mem.Allocator) eval.Context {
        const Stub = struct {
            fn lookup(_: *anyopaque, _: []const u8) !eval.Value {
                return error.UnknownVariable;
            }
        };
        return .{ .endian = self.target.arch().endian(), .allocator = a, .user = self, .read = readTarget, .lookup = Stub.lookup };
    }
    pub const ValueChild = struct { index: u64, name: []const u8, value: ValueSummary };
    pub const ValuePage = struct { value: ValueSummary, presentation: value_view.Presentation, total: u64, start: u64, next: ?u64, children: []ValueChild, basis: []const u8 = value_view.basis };
    pub fn valueChildren(self: *Session, a: std.mem.Allocator, v: eval.Value, start: u64, limit: usize, raw: bool) !ValuePage {
        const page = try value_view.children(self.valueContext(a), v, start, limit, raw);
        const children = try a.alloc(ValueChild, page.children.len);
        for (page.children, children) |child, *item| item.* = .{ .index = child.index, .name = child.name, .value = try self.summarize(a, child.value) };
        return .{ .value = try self.summarize(a, v), .presentation = page.presentation, .total = page.total, .start = page.start, .next = page.next, .children = children };
    }
    pub fn evaluateExpression(self: *Session, a: std.mem.Allocator, tid: i32, frame_index: usize, text: []const u8) !eval.Value {
        return self.evaluateAtDepth(a, tid, frame_index, 0, text);
    }
    pub fn evaluateAtDepth(self: *Session, a: std.mem.Allocator, tid: i32, frame_index: usize, depth: usize, text: []const u8) !eval.Value {
        if (frame_index >= 64 or depth > 64) return error.InvalidFrame;
        const frames = try self.stack(a, tid, frame_index + 1);
        if (frame_index >= frames.len) return error.InvalidFrame;
        const values = if (depth == 0) self.frameLocals(a, frames[frame_index]) catch &.{} else try self.frameLocalsAtDepth(a, frames[frame_index], depth);
        return self.evaluateInFrame(a, frames[frame_index], values, text);
    }
    /// Evaluates against a frame from `stack` and its locals (empty when
    /// unavailable), so several expressions can share one unwind.
    pub fn evaluateInFrame(self: *Session, a: std.mem.Allocator, frame: Frame, values: []const info.Local, text: []const u8) !eval.Value {
        if (self.target.snapshot().state != .stopped) return error.NotStopped;
        const Adapter = struct {
            session: *Session,
            registers: loc.RegisterSet,
            values: []const info.Local,
            fn lookup(ptr: *anyopaque, variable_name: []const u8) !eval.Value {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                if (variable_name.len > 1 and variable_name[0] == '$') {
                    const number = ctx.session.target.arch().registerNumber(variable_name[1..]) orelse return error.UnknownRegister;
                    return .{ .type = &eval.uint_type, .bits = ctx.registers[number] orelse return error.RegisterUnavailable };
                }
                for (ctx.values) |v| if (std.mem.eql(u8, variable_name, v.name)) return v.value;
                return error.UnknownVariable;
            }
            fn read(ptr: *anyopaque, address: u64, out: []u8) !usize {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                return ctx.session.target.readMemory(address, out);
            }
        };
        var adapter = Adapter{ .session = self, .registers = frame.registers, .values = values };
        return eval.evaluate(.{ .endian = self.target.arch().endian(), .user = &adapter, .lookup = Adapter.lookup, .read = Adapter.read, .allocator = a }, text);
    }
    pub fn authorize(self: *Session, actor: Actor, effect: Effect, generation: ?u64) !void {
        if (self.target.core != null) return error.ReadOnlyCore;
        if (actor == .agent) {
            if (self.agent_scope == .observe or (effect == .mutation and self.agent_scope != .mutate)) return error.AgentScopeDenied;
            if (generation == null) return error.GenerationRequired;
        }
        if (generation) |g| try self.target.expectGeneration(g);
    }
    pub fn record(self: *Session, actor: Actor, action: []const u8) void {
        // Action names are static strings owned by the command implementation.
        self.audit_sequence += 1;
        if (self.audit_count == self.audit.len) {
            std.mem.copyForwards(Audit, self.audit[0 .. self.audit.len - 1], self.audit[1..]);
            self.audit_count -= 1;
        }
        self.audit[self.audit_count] = .{ .sequence = self.audit_sequence, .actor = actor, .client_id = if (actor == .agent) self.agent_client_id else null, .action = action, .generation = self.target.snapshot().generation };
        self.audit_count += 1;
        if (actor == .agent) {
            self.target.event(.agent_action, self.target.snapshot().pid, @intCast(self.audit_sequence));
            // Recording the accepted deferred command changes the generation
            // itself. Other later actions must still cancel that command.
            if (self.pending_continue) |*pending| {
                if (std.mem.eql(u8, action, "continue") or std.mem.eql(u8, action, "run_to") or std.mem.eql(u8, action, "finish"))
                    pending.generation = self.target.snapshot().generation;
            }
        }
    }
    pub fn setAgentScope(self: *Session, scope: AgentScope) void {
        if (self.process_tree) |tree| {
            tree.setScope(scope);
            return;
        }
        self.agent_scope = scope;
        self.target.invalidate();
        self.record(.human, "set_agent_scope");
    }
    pub fn init() Session {
        return .{ .id = linux.now() };
    }
    pub fn snapshot(self: *const Session) Snapshot {
        return .{ .mode = if (self.imported != null) .imported else if (self.offline) .archive else if (self.target.core != null) .core else .live, .process_id = self.process_id, .session_id = self.id, .generation = self.target.snapshot().generation, .image_epoch = self.target.snapshot().image_epoch, .pid = self.target.snapshot().pid, .architecture = if (self.imported) |state| (if (state.profile) |data| data.wire.architecture else "pending") else @tagName(self.target.arch()), .state = self.target.snapshot().state, .threads = self.target.threadSlice(), .last_event_sequence = self.target.snapshot().sequence, .agent_scope = self.agent_scope, .source_stepping = self.source_step != null, .symbol_discovery_pending = self.persistent.resolving, .continue_pending = self.pending_continue != null, .source_step_resumes = self.source_step_resumes, .source_step_planned_instructions = self.source_step_batched, .running_to = if (self.run_to) |run| run.address else null, .step_diagnostic = self.step_diagnostic, .last_action = if (self.audit_count > 0) self.audit[self.audit_count - 1] else null };
    }
    pub fn deinit(self: *Session) void {
        self.static_analysis.deinit();
        if (self.observation_archive) |job| job.deinit();
        if (self.observation_associations) |job| job.deinit();
        if (self.observation_analysis) |job| job.deinit();
        if (self.comparison) |job| job.deinit();
        if (self.archive_job) |job| {
            job.deinit();
            self.archive_job = null;
        }
        self.allocations.deinit();
        self.observations.deinit();
        self.inspections.deinit();
        self.memory.deinit();
        self.persistent.deinit();
        for (self.launch_argv) |arg| std.heap.page_allocator.free(arg);
        if (self.launch_argv.len > 0) std.heap.page_allocator.free(self.launch_argv);
        self.frames.deinit();
        if (self.imported) |*state| state.deinit();
        self.recorded_views.deinit();
        if (self.archive_job) |job| job.deinit();
        self.dropDerived();
        if (self.artifact) |*artifact| artifact.deinit() else if (self.profile) |capture| capture.deinit();
        self.target.deinit();
        self.modules.deinit();
        self.debug_files.deinit();
        self.source_maps.deinit();
        self.investigation_arena.deinit();
    }
};
pub const Snapshot = struct { process_id: u64 = 1, mode: enum { live, core, archive, imported } = .live, session_id: u64, generation: u64, image_epoch: u64 = 0, pid: i32, architecture: []const u8, state: linux.State, threads: []const linux.Thread, last_event_sequence: u64, agent_scope: AgentScope, source_stepping: bool, symbol_discovery_pending: bool = false, continue_pending: bool = false, source_step_resumes: usize = 0, source_step_planned_instructions: usize = 0, running_to: ?u64, step_diagnostic: ?[]const u8, last_action: ?Audit };
test {
    std.testing.refAllDecls(linux);
    std.testing.refAllDecls(cfg);
    std.testing.refAllDecls(profile);
    std.testing.refAllDecls(@import("../profile/flame.zig"));
    _ = @import("../binary/elf.zig");
}

test "agent capabilities and generation protect shared execution state" {
    var session = Session.init();
    try std.testing.expectError(error.AgentScopeDenied, session.authorize(.agent, .execution, 0));
    session.setAgentScope(.control);
    try std.testing.expectError(error.GenerationRequired, session.authorize(.agent, .execution, null));
    try std.testing.expectError(error.StaleSnapshot, session.authorize(.agent, .execution, 0));
    try session.authorize(.agent, .execution, session.target.snapshot().generation);
    try std.testing.expectError(error.AgentScopeDenied, session.authorize(.agent, .mutation, session.target.snapshot().generation));
    try session.authorize(.human, .mutation, null);
    session.setAgentScope(.mutate);
    try session.authorize(.agent, .mutation, session.target.snapshot().generation);
    session.setAgentScope(.observe);
    try std.testing.expectError(error.AgentScopeDenied, session.authorize(.agent, .execution, session.target.snapshot().generation));
}

test "retained evidence owns enum and nested preview and frame strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var borrowed = "FIRST".*;
    const value = ValueSummary{
        .type = &borrowed,
        .kind = .signed,
        .size = 4,
        .address = 1,
        .bits = 1,
        .display = &borrowed,
        .availability = .available,
        .enumerator = &borrowed,
        .diagnostic = &borrowed,
        .visualization = .{ .presentation = .slice, .data_address = 1, .count = 1, .element_type = &borrowed, .text = &borrowed, .hex = &borrowed, .diagnostic = &borrowed, .basis = &borrowed },
    };
    var inlined = [_]info.Inline{.{ .name = &borrowed, .depth = 1, .die_offset = 0, .call_path = &borrowed, .decl_path = &borrowed }};
    const frame = Frame{ .index = 0, .pc = 1, .lookup_pc = 1, .registers = @splat(null), .symbol = &borrowed, .inline_frames = &inlined, .source = .{ .path = &borrowed, .original_path = &borrowed, .line = 1, .column = 0, .address = 1, .is_statement = true, .prologue_end = false, .discriminator = 0 } };
    const saved_value = try retainEvidence(arena.allocator(), value);
    const saved_frame = try retainEvidence(arena.allocator(), frame);
    @memset(&borrowed, '?');
    const expected_value = try std.json.Stringify.valueAlloc(arena.allocator(), saved_value, .{});
    const expected_frame = try std.json.Stringify.valueAlloc(arena.allocator(), saved_frame, .{});
    try std.testing.expect(std.mem.indexOf(u8, expected_value, "?????") == null);
    try std.testing.expect(std.mem.indexOf(u8, expected_frame, "?????") == null);
    try std.testing.expectEqualStrings("FIRST", saved_value.enumerator.?);
    try std.testing.expectEqualStrings("FIRST", saved_value.visualization.?.element_type);
    try std.testing.expectEqualStrings("FIRST", saved_frame.inline_frames[0].name);
}
