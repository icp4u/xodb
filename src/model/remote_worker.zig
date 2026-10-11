//! One remote family owner. Frontends exchange owned commands, fixed-size
//! completions and immutable publications; they never borrow the live Tree.
const std = @import("std");
const boundary = @import("remote_owner.zig");
const dispatch = @import("remote_dispatch.zig");
const Tree = @import("process_tree.zig").Tree;
const Server = @import("../mcp/server.zig").Server;
const Endpoint = @import("../mcp/shared.zig").Endpoint;
const linux = @import("../target/linux.zig");
const c = @import("../c.zig").api;
const rt = @import("../target/runtime.zig").c;
const a = std.heap.page_allocator;

pub const Completion = struct {
    sequence: u64,
    stamp: boundary.Stamp,
    failure: ?anyerror = null,
    status: ?@import("inline_view.zig").Message = null,
    first_id: ?u64 = null,
    id_count: usize = 0,
    native_watch_revision: ?u64 = null,
    inline_expression: ?@import("inline_view.zig").Message = null,
    probe_policy: ?@import("probe_view.zig").Outcome = null,
    capture_control: ?@import("capture_view.zig").Outcome = null,
};
/// Normal replies use at most 64 slots; another 64 are reserved for cancellation
/// of the remaining input queue. No allocation or payload free on the frame.
pub const Completions = struct {
    mutex: std.atomic.Mutex = .unlocked,
    items: [2 * boundary.max_commands]Completion = undefined,
    head: usize = 0,
    count: usize = 0,
    fn available(self: *Completions) bool {
        if (!self.mutex.tryLock()) return false;
        defer self.mutex.unlock();
        return self.count < boundary.max_commands;
    }
    /// Owner only; normal dispatch respects available(), teardown uses the
    /// reserved cancellation capacity. Fixtures can inject delayed replies.
    pub fn put(self: *Completions, value: Completion) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        std.debug.assert(self.count < self.items.len);
        self.items[(self.head + self.count) % self.items.len] = value;
        self.count += 1;
    }
    pub fn take(self: *Completions) !?Completion {
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock();
        if (self.count == 0) return null;
        const value = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.count -= 1;
        return value;
    }
};
pub const Options = struct {
    connection: u64,
    server: ?*Server = null,
    endpoint: ?*Endpoint = null,
    source: ?[:0]const u8 = null,
    initial_view: ?ViewSelection = null,
    trace: bool = false,
    test_directory: ?[:0]const u8 = null,
    // Empty remote sessions can establish their first connection here. The
    // cancellation capability exists before any startup transport operation.
    bootstrap: ?struct { context: *anyopaque, run: *const fn (*anyopaque, *rt.struct_xrt_cancel) anyerror!void } = null,
    // Called after every admitted command is completed/disposed, before done.
    // The caller keeps context and all borrowed model storage alive until then.
    shutdown: ?struct { context: *anyopaque, run: *const fn (*anyopaque) anyerror!void } = null,
};
pub const ViewSelection = struct {
    process: u64,
    selection: boundary.Selection,
    request_id: u64,
    kind: @FieldType(boundary.Inspection, "kind") = .view,
    browse_address: ?u64 = null,
    browse_assembly: ?u64 = null,
    show_flow: bool = false,
    show_stop: bool = false,
    show_processes: bool = false,
    show_probes: bool = false,
    show_setup: bool = false,
    logical_frames: ?@import("frame_view.zig").Request = null,
    static_analysis: ?@import("static_view.zig").Request = null,
    runtime_types: ?@import("runtime_type_view.zig").Request = null,
    invocations: ?@import("invocation_view.zig").Request = null,
    allocations: ?@import("allocation_view.zig").Request = null,
    profile: ?@import("profile_view.zig").Request = null,
    timeline: ?@import("../ui/timeline.zig").Request = null,
    sample: ?@import("sample_view.zig").Request = null,
    syscalls: ?@import("syscall_view.zig").Request = null,
    memory: ?@import("inspection_view.zig").Request = null,
    inline_scope: ?@import("inline_view.zig").Request = null,
    binding_start: usize = 0,
    language_selection: ?@import("language_view.zig").SelectedKey = null,
    text: [128]u8 = @splat(0),
    text_len: usize = 0,
    fn inspection(self: *const ViewSelection) boundary.Inspection {
        return .{ .selection = self.selection, .request_id = self.request_id, .kind = self.kind, .browse_address = self.browse_address, .browse_assembly = self.browse_assembly, .show_flow = self.show_flow, .show_stop = self.show_stop, .show_processes = self.show_processes, .show_probes = self.show_probes, .show_setup = self.show_setup, .logical_frames = self.logical_frames, .static_analysis = self.static_analysis, .runtime_types = self.runtime_types, .invocations = self.invocations, .allocations = self.allocations, .profile = self.profile, .timeline = self.timeline, .sample = self.sample, .syscalls = self.syscalls, .memory = self.memory, .inline_scope = self.inline_scope, .binding_start = self.binding_start, .language_selection = self.language_selection, .text = self.text[0..self.text_len] };
    }
};
pub const Worker = struct {
    commands: boundary.Queue = .{},
    publications: boundary.Publications,
    completions: Completions = .{},
    stopping: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null, // Read only after done.acquire or join.
    presentation_error: std.atomic.Value(u16) = .init(0),
    startup_error: std.atomic.Value(u16) = .init(0),
    connected: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    executor: dispatch.Executor,
    options: Options,
    revision: u64 = 0,
    last_generation: ?u64 = null,
    last_metadata: ?u64 = null,
    last_language: ?u64 = null,
    last_runtime_watch: ?u64 = null,
    last_native_watch: ?u64 = null,
    last_tree_revision: ?u64 = null,
    last_workspace_signature: ?u64 = null,
    last_workspace_ns: u64 = 0,
    selection: ?ViewSelection = null,
    next_poll_ns: u64 = 0,
    active: ?*const boundary.Command = null,
    cancel: ?*rt.struct_xrt_cancel = null,
    preparation_retry: @import("remote_retry.zig").Retry = .{},
    preparation_attempts: std.atomic.Value(u64) = .init(0),
    test_probes: @import("remote_test.zig").Probes = .{},

    /// Exclusive ownership of tree/server/endpoint transfers until join. Native
    /// ptrace never transfers. Startup may establish a remote link beforehand.
    pub fn start(tree: *Tree, options: Options) !*Worker {
        if (tree.count == 0 or options.connection == 0) return error.InvalidArguments;
        for (tree.entries[0..tree.count]) |entry| {
            if (options.bootstrap != null) {
                if (entry.session.target.handle != null or entry.session.target.core != null) return error.ConflictingTargets;
            } else if (!entry.session.target.isRemote()) return error.RemoteSessionRequired;
        }
        if (options.initial_view) |view| {
            _ = try tree.find(view.process);
            if (view.text_len > view.text.len or view.binding_start > 4096 or
                (view.kind != .view and view.kind != .debugger and view.kind != .language)) return error.InvalidArguments;
        }
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        self.* = .{
            .publications = .{ .connection = options.connection },
            .executor = .{ .connection = options.connection, .tree = tree, .service = if (options.endpoint) |endpoint| endpoint.service else null, .source = options.source },
            .options = options,
            .selection = options.initial_view,
            .cancel = if (options.bootstrap != null) rt.xrt_cancel_create() else rt.xrt_target_cancel(tree.root().target.handle),
            .test_probes = .{ .directory = options.test_directory },
        };
        if (self.cancel == null) return error.RemoteSessionRequired;
        errdefer rt.xrt_cancel_release(self.cancel);
        self.configure(true);
        errdefer self.configure(false);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn configure(self: *Worker, enabled: bool) void {
        const queue = if (enabled) &self.commands else null;
        if (self.options.server) |server| {
            server.owner_queue = queue;
            server.owner_connection = self.options.connection;
        }
        if (self.options.endpoint) |endpoint| {
            endpoint.owner_queue = queue;
            endpoint.owner_connection = self.options.connection;
            for (&endpoint.clients) |*slot| if (slot.*) |client| {
                client.server.owner_queue = queue;
                client.server.owner_connection = self.options.connection;
            };
        }
    }
    pub fn requestStop(self: *Worker) void {
        self.commands.close() catch unreachable;
        self.stopping.store(true, .release);
        rt.xrt_cancel_request(self.cancel);
    }
    /// Blocking owner hand-back for non-GUI callers. A frame waits for done
    /// while pumping its window, then calls joinCompleted instead.
    pub fn join(self: *Worker) void {
        self.requestStop();
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.configure(false);
    }
    pub fn joinCompleted(self: *Worker) void {
        std.debug.assert(self.done.load(.acquire));
        self.join();
    }
    pub fn destroy(self: *Worker) void {
        std.debug.assert(self.thread == null);
        self.commands.deinit();
        self.publications.deinit();
        self.executor.deinit();
        rt.xrt_cancel_release(self.cancel);
        a.destroy(self);
    }
    fn serverFor(self: *Worker, sequence: u64) ?*Server {
        if (self.options.server) |server| if (server.pending_sequence == sequence) return server;
        if (self.options.endpoint) |endpoint| return endpoint.queuedServer(sequence);
        return null;
    }
    fn run(self: *Worker) void {
        if (self.options.bootstrap) |bootstrap| bootstrap.run(bootstrap.context, self.cancel.?) catch |err| {
            self.startup_error.store(@intFromError(err), .release);
        };
        if (self.startup_error.load(.acquire) == 0) {
            self.connected.store(true, .release);
            self.loop();
        } else {
            // Keep the lifecycle available to close/reconnect while displaying
            // the startup refusal. Never poll a missing target as native.
            while (!self.stopping.load(.acquire)) _ = c.usleep(20000);
        }
        // Close admission before cancelling queued requests. No mutation is
        // executed merely to drain the queue, when shutdown was requested.
        while (true) {
            self.commands.close() catch {
                std.atomic.spinLoopHint();
                continue;
            };
            break;
        }
        if (self.active) |command| {
            self.complete(command, error.Cancelled);
            self.commands.finish();
            self.active = null;
        }
        while (true) {
            const command = (self.commands.take() catch {
                std.atomic.spinLoopHint();
                continue;
            }) orelse break;
            self.complete(command, error.Cancelled);
            self.commands.finish();
        }
        if (self.options.trace) std.debug.print("xodb: remote quiesce poll_error={s}\n", .{self.executor.tree.root().step_diagnostic orelse "none"});
        if (self.options.shutdown) |shutdown| shutdown.run(shutdown.context) catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
    fn reportPresentationError(self: *Worker, err: anyerror) void {
        self.presentation_error.store(@intFromError(err), .release);
    }
    fn loop(self: *Worker) void {
        while (!self.stopping.load(.acquire)) {
            const ready = self.tick() catch |err| failed: {
                self.reportPresentationError(err);
                break :failed false;
            };
            if (!ready) _ = c.usleep(2000);
        }
    }
    fn tick(self: *Worker) !bool {
        const root = self.executor.tree.root();
        if (self.options.server) |server| {
            server.overviewTick() catch |err| self.reportPresentationError(err);
            // A request the primary client cannot complete (an oversized line)
            // is that client's failure: report it, and keep serving the queue,
            // the GUI's commands and the refresh below.
            server.pump(root) catch |err| self.reportPresentationError(err);
            if (server.closed and server.queued == 0 and server.pending_sequence == null) {
                self.requestStop();
                return false;
            }
        }
        if (self.options.endpoint) |endpoint| endpoint.pump(root) catch |err| self.reportPresentationError(err);
        if (self.stopping.load(.acquire)) return false;
        const now = linux.now();
        const batch = self.protocolBatch();
        if (batch == .boundary or (batch != .continuation and now >= self.next_poll_ns)) {
            // Polls have no variable payload. Reuse malloc's small header
            // storage rather than mmap/munmap a page on each idle tick.
            const poll = try boundary.Command.create(std.heap.c_allocator, .{ .stamp = dispatch.stamp(self.options.connection, root), .actor = .human, .action = .poll });
            _ = self.commands.trySubmit(poll) catch |err| blk: {
                poll.destroy();
                if (err != error.Busy and err != error.PollPending) return err;
                break :blk 0;
            };
            self.next_poll_ns = now + 2 * std.time.ns_per_ms;
        }
        var progressed = false;
        if (self.active == null) self.active = self.commands.take() catch null;
        if (self.active) |command| {
            if (!(self.test_probes.dispatchAllowed(command, self.serverFor(command.sequence) != null, now) catch |err| {
                self.failure = err;
                self.requestStop();
                return false;
            })) return false;
            const needs_completion = command.request.action != .mcp and command.request.action != .poll;
            if (!needs_completion or self.completions.available()) {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                var result: anyerror!dispatch.Result = if (command.request.action == .inspect and command.request.stamp.process != self.executor.tree.active().process_id) error.StaleProcess else self.executor.execute(arena.allocator(), command, self.serverFor(command.sequence));
                if (result) |value| {
                    if (command.request.action == .inspect and (value == .view or value == .debugger or value == .language)) {
                        const inspection = command.request.action.inspect;
                        self.selection = .{ .process = command.request.stamp.process, .selection = inspection.selection, .request_id = inspection.request_id, .kind = inspection.kind, .browse_address = inspection.browse_address, .browse_assembly = inspection.browse_assembly, .show_flow = inspection.show_flow, .show_stop = inspection.show_stop, .show_processes = inspection.show_processes, .show_probes = inspection.show_probes, .show_setup = inspection.show_setup, .logical_frames = inspection.logical_frames, .static_analysis = inspection.static_analysis, .runtime_types = inspection.runtime_types, .invocations = inspection.invocations, .allocations = inspection.allocations, .profile = inspection.profile, .timeline = inspection.timeline, .sample = inspection.sample, .syscalls = inspection.syscalls, .memory = inspection.memory, .inline_scope = inspection.inline_scope };
                        self.selection.?.binding_start = inspection.binding_start;
                        self.selection.?.language_selection = inspection.language_selection;
                        self.selection.?.text_len = inspection.text.len;
                        @memcpy(self.selection.?.text[0..inspection.text.len], inspection.text);
                        if (value == .language) self.rememberLanguage(value.language);
                        if (value == .debugger) self.rememberDebugger(value.debugger);
                        self.publish(if (value == .view) value.view else null, if (value == .debugger) value.debugger else null, if (value == .language) value.language else null, null) catch |err| {
                            self.preparation_retry.failed(self.preparationKey(), err, now);
                            result = err;
                        };
                    }
                } else |_| {}
                self.complete(command, result);
                self.commands.finish();
                self.active = null;
                progressed = true;
            }
        }
        if (self.stopping.load(.acquire)) return false;
        const preparation_key = self.preparationKey();
        if (self.preparation_retry.ready(preparation_key, now)) {
            self.refresh(now) catch |err| {
                self.preparation_retry.failed(preparation_key, err, now);
                self.reportPresentationError(err);
            };
        }
        if (self.publications.collect() catch null) |retired| retired.destroy();
        // Drain ready work in order before sleeping. Poll admission keeps
        // its cadence even during a request flood; a full completion box
        // still yields instead of spinning on the active command.
        if (progressed) {
            self.active = self.commands.take() catch null;
            if (self.active != null) return true;
        }
        return false;
    }
    fn refresh(self: *Worker, now: u64) !void {
        // Headless owners do not construct unused GUI views. A frame asks
        // for its first inspection explicitly; later stops refresh it.
        if (self.selection) |*selected| if (selected.process != self.executor.tree.active().process_id) {
            selected.* = .{ .process = self.executor.tree.active().process_id, .selection = .{ .tid = 0 }, .kind = selected.kind, .request_id = selected.request_id };
            self.last_generation = null;
        };
        if (self.selection) |selected| {
            const session = (try self.executor.tree.find(selected.process)).session;
            const threads = session.target.threadSlice();
            const allocation_tid = if (selected.selection.tid != 0) selected.selection.tid else if (threads.len > 0) threads[0].tid else 0;
            if ((self.last_workspace_signature != @import("workspace_view.zig").signature(try self.workspaceHeader(session)) and now -| self.last_workspace_ns >= 100 * std.time.ns_per_ms) or (selected.static_analysis != null and self.executor.static_analysis.changed(session)) or (selected.runtime_types != null and self.executor.runtime_types.changed(session)) or (selected.invocations != null and self.executor.invocations.changed(session)) or (selected.logical_frames != null and self.executor.logical_frames.changed(&session.frames)) or self.executor.capture_control.changed(session) or (selected.sample != null and self.executor.sample.changed(session)) or (selected.syscalls != null and self.executor.syscalls.changed(session)) or (selected.timeline != null and self.executor.timeline.changed(session)) or (selected.profile != null and self.executor.profile.changed(session)) or (selected.allocations != null and self.executor.allocations.changed(&session.allocations, allocation_tid)) or (selected.show_probes and self.executor.probes.changed(session)) or self.last_generation != session.target.snapshot().generation or self.last_metadata != session.metadata.revision or self.last_language != session.language_tabs.revision or self.last_runtime_watch != session.language_watches.revision or self.last_native_watch != self.executor.nativeWatchRevision(session) or self.executor.nativeWatchMetadataChanged(session) or (selected.memory != null and self.executor.inspectionChanged(session)) or (selected.show_processes and self.last_tree_revision != self.executor.tree.revision)) {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                if (selected.kind == .language) {
                    if (self.executor.captureLanguage(session, selected.inspection())) |view| {
                        self.rememberLanguage(view);
                        try self.publish(null, null, view, null);
                    } else |err| try self.publish(null, null, null, err);
                } else if (selected.kind == .debugger) {
                    const view = self.executor.captureDebugger(session, selected.inspection());
                    self.rememberDebugger(view);
                    try self.publish(null, view, null, null);
                } else {
                    const view = @import("../mcp/remote.zig").captureView(arena.allocator(), session, .{ .selection = selected.selection, .source = self.options.source });
                    if (view) |value| try self.publish(value, null, null, null) else |err| try self.publish(null, null, null, err);
                }
            }
        }
    }
    fn preparationKey(self: *Worker) u64 {
        const selected = self.selection orelse return 0;
        const session = (self.executor.tree.find(selected.process) catch return 0).session;
        var hash = std.hash.Wyhash.init(self.options.connection);
        std.hash.autoHash(&hash, selected.process);
        var inspection = selected.inspection();
        inspection.request_id = 0; // Automatic retries keep the same selection key.
        @import("remote_retry.zig").hashValue(&hash, inspection);
        std.hash.autoHash(&hash, session.id);
        std.hash.autoHash(&hash, session.target.snapshot().generation);
        std.hash.autoHash(&hash, session.metadata.revision);
        std.hash.autoHash(&hash, session.language_tabs.revision);
        return hash.final();
    }
    fn protocolBatch(self: *const Worker) enum { none, continuation, boundary } {
        // Stdio normally admits eight requests per pump; a shared peer admits
        // one. Preserve those finite batches across deferred owner replies.
        // A batch boundary requests a poll even when its cadence is not due.
        var continuation = false;
        if (self.options.server) |server| if (server.ownerBatchContinuation()) {
            if (server.owner_batch_remaining <= 1) return .boundary;
            continuation = true;
        };
        if (self.options.endpoint) |endpoint| for (endpoint.clients) |slot| if (slot) |client| {
            if (!client.server.ownerBatchContinuation()) continue;
            if (client.server.owner_batch_remaining <= 1) return .boundary;
            continuation = true;
        };
        return if (continuation) .continuation else .none;
    }
    fn complete(self: *Worker, command: *const boundary.Command, result: anyerror!dispatch.Result) void {
        if (command.request.action == .poll) {
            if (result) |_| {} else |err| self.reportPresentationError(err);
            return;
        }
        if (command.request.action == .mcp) {
            const server = self.serverFor(command.sequence) orelse {
                // A dropped client's admitted command is disposed exactly once;
                // there is no socket to receive a terminal protocol reply.
                self.test_probes.completed(command, true);
                return;
            };
            self.test_probes.completed(command, false);
            const json: anyerror![]const u8 = if (result) |value| if (value == .json) value.json else error.InvalidOwnerReply else |err| err;
            server.completeQueued(command.sequence, json) catch |err| {
                self.failServer(server, err);
                return;
            };
            server.flush() catch |err| {
                self.failServer(server, err);
            };
            return;
        }
        const current = if (self.executor.tree.find(command.request.stamp.process)) |entry| dispatch.stamp(self.options.connection, entry.session) else |_| command.request.stamp;
        var completion = Completion{ .sequence = command.sequence, .stamp = current };
        if (result) |value| {
            if (command.request.action == .native_watch) {
                if (self.executor.tree.find(command.request.stamp.process)) |entry| {
                    completion.native_watch_revision = self.executor.nativeWatchRevision(entry.session);
                } else |_| {}
            }
            if (value == .inline_expression) completion.inline_expression = value.inline_expression;
            if (value == .probe_policy) completion.probe_policy = value.probe_policy;
            if (value == .capture_control) completion.capture_control = value.capture_control;
            if (value == .ids) {
                completion.id_count = value.ids.len;
                if (value.ids.len > 0) completion.first_id = value.ids[0];
            }
        } else |err| completion.failure = err;
        if (self.executor.tree.find(command.request.stamp.process)) |entry| {
            if (entry.session.modules.skipped().count != 0) {
                const source_action = switch (command.request.action) {
                    .workspace => |v| v == .run_to_source or v == .toggle_source,
                    .breakpoint => |v| v == .source,
                    else => false,
                };
                const message: ?[]const u8 = if (completion.failure != null and completion.failure.? == error.NoCodeForSourceLine)
                    "NoCodeForSourceLine in the images searched; some are over the image budget (Modules lists them)"
                else if (completion.failure == null and source_action)
                    "Operation completed in the images searched; some are over the image budget (Modules lists them)"
                else
                    null;
                if (message) |text| {
                    completion.status = .{};
                    @memcpy(completion.status.?.bytes[0..text.len], text);
                    completion.status.?.len = text.len;
                }
            }
        } else |_| {}
        self.completions.put(completion);
    }
    fn failServer(self: *Worker, server: *Server, err: anyerror) void {
        server.closed = true;
        server.pending_sequence = null;
        server.used = 0;
        server.queued = 0;
        server.sent = 0;
        if (self.options.server == server) {
            self.failure = err;
            self.stopping.store(true, .release);
        } else {
            // Endpoint drops this peer on its next pump. A disconnected shared
            // observer must not stop the family or another client's commands.
            std.debug.print("xodb: remote session client response failed: {s}\n", .{@errorName(err)});
        }
    }
    // Retain normalized request data in fixed owner storage. Neither the
    // command arena nor a replaced language presentation may back a refresh.
    fn workspaceHeader(self: *Worker, session: *@import("session.zig").Session) !@import("workspace_view.zig").Header {
        var value = @import("workspace_view.zig").capture(session);
        if (self.options.endpoint) |endpoint| {
            const ownership = try endpoint.state(self.executor.tree.root());
            value.shared_clients = ownership.peer_count;
            value.shared_controller = if (ownership.controller == 0) null else ownership.controller;
            value.fd_events = endpoint.collector().fdEventState();
        } else if (self.options.server) |server| value.fd_events = (server.overview_shared orelse &server.overview).fdEventState();
        return value;
    }
    fn rememberLanguage(self: *Worker, view: @import("language_view.zig").Presentation) void {
        const selected = &self.selection.?;
        std.debug.assert(view.expression.len <= selected.text.len);
        selected.text_len = view.expression.len;
        @memcpy(selected.text[0..selected.text_len], view.expression);
        selected.binding_start = view.binding_start;
        selected.language_selection = view.selected;
    }
    fn rememberDebugger(self: *Worker, view: @import("debugger_view.zig").Presentation) void {
        self.selection.?.selection = .{ .tid = view.request.tid, .frame = view.selected_frame };
    }
    fn publish(self: *Worker, view: ?@import("../remote/view.zig").View, debugger: ?@import("debugger_view.zig").Presentation, language_: ?@import("language_view.zig").Presentation, failure: ?anyerror) !void {
        _ = self.preparation_attempts.fetchAdd(1, .monotonic);
        // A workspace always has the native columns and the selected language
        // body in the same publication, even when the selected tab is native.
        const language = if (debugger != null) try self.executor.captureLanguage((try self.executor.tree.find(self.selection.?.process)).session, self.selection.?.inspection()) else language_;
        if (language) |value| self.rememberLanguage(value);
        const selected = self.selection.?;
        const session = (try self.executor.tree.find(selected.process)).session;
        if (self.publications.collect() catch null) |retired| retired.destroy();
        self.revision += 1;
        var watch_arena = std.heap.ArenaAllocator.init(a);
        defer watch_arena.deinit();
        const runtime_watches = @import("runtime_watch_view.zig").snapshot(session, watch_arena.allocator());
        const native_watches = self.executor.captureNativeWatches(session, selected.selection);
        const threads = session.target.threadSlice();
        const stop_tid = if (selected.selection.tid != 0) selected.selection.tid else if (threads.len > 0) threads[0].tid else 0;
        self.executor.stop_details.refresh(session, stop_tid, selected.show_stop);
        const memory = try self.executor.captureInspection(session, selected.memory);
        try self.executor.processes.refresh(self.executor.tree, self.options.connection, selected.show_processes);
        const processes = if (selected.show_processes) self.executor.processes.value else null;
        self.executor.inline_scopes.refresh(session, selected.inline_scope);
        const inline_scope = if (selected.inline_scope != null) self.executor.inline_scopes.value else null;
        if (inline_scope) |v| if (v.key) |key| {
            self.selection.?.inline_scope = key.request;
        };
        const stop = if (selected.show_stop) self.executor.stop_details.value else null;
        self.executor.probes.refresh(session, selected.show_probes);
        const probes = if (selected.show_probes) self.executor.probes.value else null;
        self.executor.allocations.refresh(&session.allocations, selected.allocations, stop_tid);
        const allocations = if (selected.allocations != null) self.executor.allocations.value else null;
        if (allocations) |v| self.selection.?.allocations = v.request;
        self.executor.profile.refresh(session, selected.profile);
        const profile = if (selected.profile != null) self.executor.profile.value else null;
        if (profile) |v| self.selection.?.profile = v.request;
        self.executor.timeline.refresh(session, selected.timeline);
        const timeline = self.executor.timeline.value;
        if (timeline) |v| self.selection.?.timeline = v.normalized;
        self.executor.sample.refresh(session, selected.sample);
        const sample = self.executor.sample.value;
        if (sample) |v| self.selection.?.sample = v.normalized;
        self.executor.syscalls.refresh(session, selected.syscalls);
        const syscalls = self.executor.syscalls.value;
        if (syscalls) |v| self.selection.?.syscalls = v.normalized;
        self.executor.capture_control.refresh(session, selected.show_setup);
        self.executor.logical_frames.refresh(&session.frames, selected.logical_frames);
        self.executor.static_analysis.refresh(session, selected.static_analysis);
        self.executor.runtime_types.refresh(session, selected.runtime_types);
        self.executor.invocations.refresh(session, selected.invocations);
        if (self.executor.static_analysis.value) |v| self.selection.?.static_analysis = v.request;
        if (self.executor.logical_frames.value) |v| self.selection.?.logical_frames = v.request;
        const workspace = try self.workspaceHeader(session);
        const current = dispatch.stamp(self.options.connection, session);
        // Preparing a stack may start metadata discovery. Keep the revisions
        // actually observed so the next loop refreshes that incomplete view.
        const pane_generation = if (language) |v| v.header.generation else if (debugger) |v| v.snapshot.generation else if (view) |v| v.generation else current.generation;
        const pane_metadata = if (language) |v| v.key.metadata else if (debugger) |v| v.metadata_revision else session.metadata.revision;
        const language_revision = if (language) |v| v.header.revision else if (debugger) |v| if (v.language_header) |h| h.revision else session.language_tabs.revision else session.language_tabs.revision;
        var generation = if (stop) |v| if (v.key.?.generation != current.generation) v.key.?.generation else pane_generation else pane_generation;
        var metadata = if (stop) |v| if (v.key.?.metadata != session.metadata.revision) v.key.?.metadata else pane_metadata else pane_metadata;
        if (memory) |v| {
            if (v.generation != current.generation) generation = v.generation;
            if (v.metadata != session.metadata.revision) metadata = v.metadata;
        }
        if (inline_scope) |v| if (v.key) |key| {
            if (key.request.generation != current.generation) generation = key.request.generation;
            if (key.metadata != session.metadata.revision) metadata = key.metadata;
        };
        const stale = generation != current.generation or metadata != session.metadata.revision or language_revision != session.language_tabs.revision;
        const presentation: boundary.Presentation = .{
            .stamp = current,
            .revision = self.revision,
            .taken_ns = linux.now(),
            .status = if (failure != null) .failed else if (stale) .pending else .ready,
            .inspection_id = selected.request_id,
            .view = view,
            .debugger = debugger,
            .language = language,
            .runtime_watches = runtime_watches,
            .native_watches = native_watches,
            .stop = stop,
            .memory = memory,
            .inline_scope = inline_scope,
            .processes = processes,
            .probes = probes,
            .allocations = allocations,
            .profile = profile,
            .capture_control = self.executor.capture_control.value,
            .logical_frames = self.executor.logical_frames.value,
            .static_analysis = self.executor.static_analysis.value,
            .runtime_types = self.executor.runtime_types.value,
            .invocations = self.executor.invocations.value,
            .workspace = workspace,
            .timeline = timeline,
            .sample = sample,
            .syscalls = syscalls,
            .diagnostic = if (failure) |err| @errorName(err) else "",
        };
        if (try self.test_probes.failPublication()) return error.OutOfMemory;
        const publication = try boundary.Publication.createDegraded(a, presentation);
        errdefer publication.destroy();
        while (true) {
            const retired = self.publications.publish(publication) catch |err| {
                if (err != error.Busy) return err;
                std.atomic.spinLoopHint();
                continue;
            };
            if (retired) |old| old.destroy();
            break;
        }
        self.presentation_error.store(0, .release);
        self.preparation_retry.clear();
        self.last_workspace_signature = @import("workspace_view.zig").signature(workspace);
        self.last_workspace_ns = linux.now();
        self.last_generation = generation;
        self.last_metadata = metadata;
        self.last_language = language_revision;
        self.last_runtime_watch = runtime_watches.revision;
        self.last_native_watch = native_watches.revision;
        self.last_tree_revision = if (processes) |v| v.revision else self.executor.tree.revision;
    }
};

test "silent saturated queue cancels exactly once with full completions" {
    const test_a = std.testing.allocator;
    const session = try test_a.create(@import("session.zig").Session);
    defer test_a.destroy(session);
    session.* = @import("session.zig").Session.init();
    defer session.deinit();
    const tree = try test_a.create(Tree);
    defer test_a.destroy(tree);
    tree.* = .{};
    tree.init(session);
    defer tree.deinit();
    const Barrier = struct {
        released: std.atomic.Value(bool) = .init(false),
        fn run(context: *anyopaque, _: *rt.struct_xrt_cancel) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            while (!self.released.load(.acquire)) _ = c.usleep(1000);
        }
    };
    var barrier: Barrier = .{};
    const worker = try Worker.start(tree, .{ .connection = 1, .bootstrap = .{ .context = &barrier, .run = Barrier.run } });
    defer {
        barrier.released.store(true, .release);
        worker.join();
        worker.destroy();
    }
    const identity = dispatch.stamp(1, session);
    for (0..boundary.max_commands) |index| {
        worker.completions.put(.{ .sequence = 1000 + index, .stamp = identity });
        const command = try boundary.Command.create(test_a, .{ .stamp = identity, .actor = .human, .action = .{ .control = .continue_execution } });
        try std.testing.expectEqual(index + 1, try worker.commands.trySubmit(command));
    }
    try std.testing.expect(!worker.completions.available());
    // Quiescing itself cannot depend on acquiring a producer's queue lock.
    try std.testing.expect(worker.commands.mutex.tryLock());
    worker.requestStop();
    const cancelled = rt.xrt_cancel_requested(worker.cancel);
    worker.commands.mutex.unlock();
    try std.testing.expect(cancelled);
    barrier.released.store(true, .release);
    const deadline = linux.now() + 10 * std.time.ns_per_s;
    while (!worker.done.load(.acquire)) {
        if (linux.now() > deadline) return error.CancellationDeadline;
        _ = c.usleep(1000);
    }
    worker.joinCompleted();
    // No further producer input or completion consumption was needed to finish.
    for (0..2 * boundary.max_commands) |index| {
        const reply = (try worker.completions.take()).?;
        if (index < boundary.max_commands) {
            try std.testing.expectEqual(1000 + index, reply.sequence);
            try std.testing.expect(reply.failure == null);
        } else {
            try std.testing.expectEqual(index - boundary.max_commands + 1, reply.sequence);
            try std.testing.expect(reply.failure.? == error.Cancelled);
        }
    }
    try std.testing.expect((try worker.completions.take()) == null);
    try std.testing.expectEqual(@as(usize, 0), worker.commands.bytes);
}

test "completion capacity reserves cancellation without losing earlier replies" {
    var replies: Completions = .{};
    for (0..boundary.max_commands) |i| {
        try std.testing.expect(replies.available());
        replies.put(.{ .sequence = i + 1, .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 1, .image_epoch = 0, .generation = 0 } });
    }
    try std.testing.expect(!replies.available());
    for (0..boundary.max_commands) |i| replies.put(.{ .sequence = boundary.max_commands + i + 1, .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 1, .image_epoch = 0, .generation = 0 }, .failure = error.Cancelled });
    for (0..2 * boundary.max_commands) |i| {
        const reply = (try replies.take()).?;
        try std.testing.expectEqual(i + 1, reply.sequence);
        try std.testing.expectEqual(i >= boundary.max_commands, reply.failure != null);
    }
    try std.testing.expect((try replies.take()) == null);
}

test "live remote owner publishes while frontend transport guard is armed" {
    const test_a = std.testing.allocator;
    const Session = @import("session.zig").Session;
    const session = try test_a.create(Session);
    defer test_a.destroy(session);
    session.* = Session.init();
    defer session.deinit();
    try session.target.connectRemote(&.{ "./zig-out/bin/xodb-agent", "--stdio" });
    try session.launch(&.{ "./zig-out/bin/xodb-m1-fixture", "w" });
    const tree = try test_a.create(Tree);
    defer test_a.destroy(tree);
    tree.* = .{};
    tree.init(session);
    defer tree.deinit();
    var current: ?*const boundary.Publication = null;
    defer if (current) |value| value.destroy();
    const allocation_model = @import("../profile/allocation_capture.zig");
    const opening = session.target.snapshot();
    session.allocations.capture = try allocation_model.Capture.create(test_a, .{ .session_id = session.id, .capture_id = 1, .process_id = 1, .pid = opening.pid, .image_epoch = opening.image_epoch }, .{}, &.{.{ .id = 1, .tid = opening.pid }}, &.{.{ .id = 1, .kind = .malloc, .name = "malloc", .path = "/fixture/allocator", .device = 1, .inode = 2, .file_offset = 1, .link_address = 1, .runtime_address = 1 }}, 1);
    try session.allocations.capture.?.feed(0, .{ .time_ns = 2, .data = .{ .sample = .{ .kind = .malloc, .phase = .enter, .hook = 1, .stack_key = 0x8000, .arg0 = 32 } } });
    try session.allocations.capture.?.feed(0, .{ .time_ns = 3, .data = .{ .sample = .{ .kind = .malloc, .phase = .leave, .hook = 1, .stack_key = 0x8000, .result = 0x1000 } } });
    try session.allocations.capture.?.finish(4, false);
    const profile_model = @import("../profile/capture.zig");
    const profile_capture = try test_a.create(profile_model.Capture);
    profile_capture.* = .{ .allocator = test_a, .arena = std.heap.ArenaAllocator.init(test_a), .id = 1, .session_id = session.id, .generation = opening.generation, .image_epoch = opening.image_epoch, .pid = opening.pid, .started_ns = 100, .ended_ns = 200, .config = .{}, .accepted = std.mem.zeroes(@import("../profile/linux_perf.zig").Acceptance), .thread_count = 1, .collector = null, .images = @import("modules.zig").Modules.init(test_a) };
    session.profile = profile_capture;
    profile_capture.threads[0] = .{ .debugger_id = 1, .perf = .{ .tid = opening.pid, .event_id = 1, .start_time_ticks = 1, .start_time_known = true } };
    _ = try std.fmt.bufPrintZ(&profile_capture.thread_names[0], "Fixture thread", .{});
    for ([_]u64{ 110, 120 }) |time| try profile_capture.samples.append(test_a, .{ .tid = @intCast(opening.pid), .tid_present = true, .time_ns = time, .time_present = true });
    profile_capture.syscalls.enabled = true;
    try profile_capture.syscalls.items.append(test_a, .{ .thread_index = 0, .nr = 0, .exit_nr = 0, .entry_ns = 105, .exit_ns = 115, .result = 1, .reason = .complete });
    const worker = try Worker.start(tree, .{ .connection = 1, .source = "tests/fixtures/m1.c", .initial_view = .{ .process = 1, .selection = .{ .tid = 0 }, .request_id = 1 } });
    defer {
        worker.join();
        worker.destroy();
    }
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    // This is a bounded functional wait, not a latency requirement. From this
    // point until join the frontend reads only message state, never Session.
    const deadline = linux.now() + 60 * std.time.ns_per_s;
    while (current == null) {
        current = worker.publications.take(null) catch null;
        if (current != null) break;
        if (worker.done.load(.acquire)) return worker.failure orelse error.OwnerStopped;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    try std.testing.expect(current.?.value.matchesInspection(current.?.value.stamp, 1));
    try std.testing.expect(current.?.value.view.?.threads.len > 0);
    try std.testing.expect(current.?.value.view.?.registers.len > 0);
    var sequence: ?u64 = null;
    var completed = false;
    while (!completed) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (sequence == null) {
            const command = try boundary.Command.create(a, .{
                .stamp = current.?.value.stamp,
                .actor = .human,
                .action = .{ .inspect = .{ .request_id = 2, .selection = .{ .tid = if (current.?.value.view) |v| v.tid else current.?.value.debugger.?.request.tid }, .kind = .debugger, .show_stop = true, .show_processes = true } },
            });
            sequence = worker.commands.trySubmit(command) catch |err| blk: {
                command.destroy();
                if (err != error.Busy) return err;
                break :blk null;
            };
        }
        if (worker.completions.take() catch null) |reply| {
            try std.testing.expectEqual(sequence.?, reply.sequence);
            if (reply.failure) |err| {
                if (err != error.StaleSnapshot) return err;
                sequence = null; // Retry from the next confirmed publication.
            } else completed = true;
        }
        if (worker.done.load(.acquire)) return worker.failure orelse error.OwnerStopped;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    while (!current.?.value.matchesInspection(current.?.value.stamp, 2)) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    try std.testing.expect(current.?.value.matchesInspection(current.?.value.stamp, 2));
    const pane = current.?.value.debugger.?;
    try std.testing.expect(pane.regs != null);
    try std.testing.expect(pane.instructions.len > 0);
    try std.testing.expect(pane.frames.len > 0);
    try std.testing.expect(pane.source.bytes.len > 0);
    const stop = current.?.value.stop.?;
    try std.testing.expectEqual(pane.request.tid, stop.info.?.tid);
    try std.testing.expect(!stop.info.?.read_only);
    // The real GUI binds exactly this prepared payload, with the frontend
    // transport guard still armed. Its local source/flow controls need no owner.
    const Workspace = @import("../ui/workspace.zig").Workspace;
    const workspace = try test_a.create(Workspace);
    defer test_a.destroy(workspace);
    workspace.* = .{};
    defer workspace.deinit();
    workspace.presentDebugger(pane);
    workspace.presentStop(stop);
    const processes = current.?.value.processes.?;
    try std.testing.expectEqual(@as(usize, 1), processes.rows.len);
    try std.testing.expectEqual(current.?.value.stamp.process, processes.rows[0].stamp.process);
    workspace.process_panel.present(processes);
    try std.testing.expectEqual(pane.request.tid, workspace.stop_view.info.?.tid);
    workspace.source_line = 7;
    workspace.presentDebugger(pane);
    workspace.flow.scrollBy(1);
    try std.testing.expectEqual(@as(i32, 7), workspace.source_line);
    try std.testing.expectEqualStrings(pane.source.bytes, workspace.source);
    const tid = pane.request.tid;
    const instruction = pane.instructions[0];
    _ = try testSubmit(worker, &current, .{ .inspect = .{ .request_id = 4, .selection = .{ .tid = tid }, .kind = .debugger, .memory = .{ .kind = .memory, .tid = tid, .address = instruction.address } } }, deadline);
    while (!current.?.value.matchesInspection(current.?.value.stamp, 4)) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    const memory_view = current.?.value.memory.?;
    try std.testing.expect(memory_view.snapshot.?.valid[0]);
    var decoded: [1]@import("disassembly.zig").Instruction = undefined;
    try std.testing.expectEqual(@as(usize, 1), try @import("disassembly.zig").decodeFor(current.?.value.debugger.?.architecture, memory_view.snapshot.?.bytes, instruction.address, &decoded));
    try std.testing.expectEqual(instruction.size, decoded[0].size);
    try std.testing.expectEqualStrings(std.mem.sliceTo(&instruction.mnemonic, 0), std.mem.sliceTo(&decoded[0].mnemonic, 0));
    workspace.inspection_panel.present(memory_view);
    var pattern: [6]u8 = undefined;
    const text = try std.fmt.bufPrint(&pattern, "hex:{x:0>2}", .{memory_view.snapshot.?.bytes[0]});
    const search = try testSubmit(worker, &current, .{ .memory_action = .{ .search = .{ .address = instruction.address, .length = 16, .text = text } } }, deadline);
    while (current.?.value.memory.?.search == null or current.?.value.memory.?.search.?.state == .running) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(search.first_id.?, current.?.value.memory.?.search.?.id);
    try std.testing.expectEqual(instruction.address, current.?.value.memory.?.search.?.hits[0]);
    try std.testing.expectError(error.StaleMemorySearch, testSubmit(worker, &current, .{ .memory_action = .{ .cancel = search.first_id.? + 1 } }, deadline));
    _ = try testSubmit(worker, &current, .{ .inspect = .{ .request_id = 5, .selection = .{ .tid = tid }, .kind = .debugger, .inline_scope = .{ .generation = current.?.value.stamp.generation, .tid = tid, .frame = 0, .depth = 0 } } }, deadline);
    while (!current.?.value.matchesInspection(current.?.value.stamp, 5)) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    const inline_scope = current.?.value.inline_scope.?;
    try std.testing.expect(inline_scope.frame != null);
    workspace.inline_panel.present(inline_scope);
    const expression = try testSubmit(worker, &current, .{ .inline_expression = .{ .tid = tid, .frame = 0, .depth = 0, .metadata = inline_scope.key.?.metadata, .text = "1 + 2" } }, deadline);
    try std.testing.expect(std.mem.startsWith(u8, expression.inline_expression.?.slice(), "1 + 2 = 3 ("));
    workspace.inline_panel.complete(expression.inline_expression.?);
    try std.testing.expect(std.mem.startsWith(u8, workspace.inline_panel.message[0..workspace.inline_panel.message_len], "1 + 2 = 3 ("));
    _ = try testSubmit(worker, &current, .{ .inspect = .{ .request_id = 3, .selection = .{ .tid = tid }, .kind = .language } }, deadline);
    while (!current.?.value.matchesInspection(current.?.value.stamp, 3)) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    const language_revision = current.?.value.revision;
    _ = try testSubmit(worker, &current, .{ .language = .{ .native = .{ .tid = tid, .frame = 0 } } }, deadline);
    while (current.?.value.revision <= language_revision or !current.?.value.matchesInspection(current.?.value.stamp, 3)) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    const language = current.?.value.language.?;
    try std.testing.expect(current.?.value.matchesInspection(current.?.value.stamp, 3));
    try std.testing.expectEqual(tid, language.header.native_selection.?.tid);
    try std.testing.expectEqual(@as(usize, 0), language.header.native_selection.?.frame);
    try std.testing.expect(current.?.value.stop == null);
    try std.testing.expect(current.?.value.inline_scope == null);
    try std.testing.expect(current.?.value.processes == null);
    // Selection preparation can read the target on the owner. Binding and
    // local scrolling here still execute under the frontend transport guard.
    workspace.language_panel.present(language);
    workspace.language_panel.scrollBy(1);
    try std.testing.expectEqual(language.header.session, workspace.language_panel.key.?.session);
    _ = try testSubmit(worker, &current, .{ .native_watch = .{ .add = .{ .binding = .{ .selection = .{ .tid = tid, .index = 0 }, .metadata = language.header.metadata }, .text = "1 + 2", .mode = .pinned } } }, deadline);
    while (current.?.value.native_watches.?.entries.len != 1) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    const watch_view = current.?.value.native_watches.?;
    try std.testing.expectEqualStrings("3", watch_view.entries[0].display.slice());
    workspace.presentNativeWatches(watch_view);
    workspace.watch_panel.added(0);
    const remove_watch = workspace.watch_panel.keyView(watch_view, 111).owner;
    _ = try testSubmit(worker, &current, .{ .native_watch = remove_watch }, deadline);
    while (current.?.value.native_watches.?.entries.len != 0) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    _ = try testSubmit(worker, &current, .{ .inspect = .{ .request_id = 6, .selection = .{ .tid = tid }, .kind = .debugger, .show_probes = true } }, deadline);
    while (!current.?.value.matchesInspection(current.?.value.stamp, 6)) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    const added_probe = try testSubmit(worker, &current, .{ .breakpoint = .{ .address = instruction.address } }, deadline);
    const probe_id = added_probe.first_id.?;
    while (true) {
        if (worker.publications.take(current) catch null) |next| current = next;
        var found = false;
        for (current.?.value.probes.?.rows) |row| if (row.probe.id == probe_id) {
            found = true;
        };
        if (found) break;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    const configured = try testSubmit(worker, &current, .{ .probe_policy = .{ .key = current.?.value.probes.?.key.?, .edit = .{ .ignore = .{ .id = probe_id, .count = 7 } } } }, deadline);
    try std.testing.expect(configured.probe_policy.? == .updated);
    while (true) {
        if (worker.publications.take(current) catch null) |next| current = next;
        var found = false;
        for (current.?.value.probes.?.rows) |row| if (row.probe.id == probe_id) if (row.rule) |rule| {
            found = rule.options.ignore_count == 7;
        };
        if (found) break;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    workspace.probes_panel.open = true;
    workspace.probes_panel.selected_id = probe_id;
    workspace.probes_panel.present(current.?.value.probes.?);
    const remove_probe = workspace.probes_panel.keyView(.{ .kind = .press, .shortcut = 0xffff }).owner;
    try std.testing.expectEqual(probe_id, remove_probe.edit.remove);
    const removed_probe = try testSubmit(worker, &current, .{ .probe_policy = remove_probe }, deadline);
    try std.testing.expect(removed_probe.probe_policy.? == .removed);
    _ = try testSubmit(worker, &current, .{ .inspect = .{ .request_id = 7, .selection = .{ .tid = tid }, .kind = .debugger } }, deadline);
    while (!current.?.value.matchesInspection(current.?.value.stamp, 7)) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    try std.testing.expect(current.?.value.probes == null);
    _ = try testSubmit(worker, &current, .{ .inspect = .{ .request_id = 8, .selection = .{ .tid = 0 }, .kind = .debugger, .allocations = .{ .mode = .heap } } }, deadline);
    while (!current.?.value.matchesInspection(current.?.value.stamp, 8) or current.?.value.allocations == null or current.?.value.allocations.?.heap == null) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (worker.done.load(.acquire)) return worker.failure orelse error.OwnerStopped;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    const allocations = current.?.value.allocations.?;
    try std.testing.expect(std.mem.indexOf(u8, allocations.banner, "TID 0:") == null);
    try std.testing.expectEqual(@as(u64, 32), allocations.heap.?.nodes[0].inclusive);
    try std.testing.expectEqual(@as(usize, 1), allocations.threads.len);
    _ = try testSubmit(worker, &current, .{ .allocation = .{ .retry = allocations.key.? } }, deadline);
    _ = try testSubmit(worker, &current, .{ .inspect = .{ .request_id = 9, .selection = .{ .tid = tid }, .kind = .debugger } }, deadline);
    while (!current.?.value.matchesInspection(current.?.value.stamp, 9)) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    try std.testing.expect(current.?.value.allocations == null);
    const timeline_bounds = @import("../render/vulkan.zig").Rect{ .x = 8, .y = 512, .w = 1264, .h = 251 };
    _ = try testSubmit(worker, &current, .{ .inspect = .{ .request_id = 10, .selection = .{ .tid = tid }, .kind = .debugger, .profile = .{}, .timeline = .{ .bounds = timeline_bounds }, .sample = .{}, .syscalls = .{ .count = 16 } } }, deadline);
    while (!current.?.value.matchesInspection(current.?.value.stamp, 10) or current.?.value.profile == null or current.?.value.profile.?.graph == null) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (worker.done.load(.acquire)) return worker.failure orelse error.OwnerStopped;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(@as(u64, 2), current.?.value.profile.?.graph.?.nodes.items[0].inclusive);
    workspace.flame.present(current.?.value.profile.?);
    try std.testing.expectEqual(@as(usize, 2), workspace.flame.sample_count);
    const timeline_view = current.?.value.timeline.?;
    try std.testing.expectEqual(@as(usize, 1), timeline_view.data.lanes.len);
    var total: u64 = 0;
    for (timeline_view.buckets) |bucket| total += bucket[0];
    try std.testing.expectEqual(@as(u64, 2), total);
    _ = workspace.timeline.present(timeline_view, timeline_bounds);
    try std.testing.expectEqual(@as(usize, 1), workspace.timeline.lane_count);
    workspace.inspector.open = true;
    workspace.inspector.present(current.?.value.sample, .{});
    try std.testing.expectEqual(@as(usize, 2), workspace.inspector.view.?.matching.len);
    workspace.inspector.step(.{}, 1);
    try std.testing.expectEqual(@as(usize, 1), workspace.inspector.ordinal);
    try std.testing.expectEqual(@as(usize, 1), current.?.value.syscalls.?.rows.len);
    try std.testing.expectEqual(@as(?u64, 10), current.?.value.syscalls.?.rows[0].elapsed_ns);
    workspace.syscall_panel.open = true;
    workspace.syscall_panel.present(current.?.value.syscalls, 714, .{});
    try std.testing.expectEqual(@as(usize, 1), workspace.syscall_panel.total);
    _ = try testSubmit(worker, &current, .{ .inspect = .{ .request_id = 11, .selection = .{ .tid = tid }, .kind = .debugger } }, deadline);
    while (!current.?.value.matchesInspection(current.?.value.stamp, 11)) {
        if (worker.publications.take(current) catch null) |next| current = next;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
    try std.testing.expect(current.?.value.profile == null);
    try std.testing.expect(current.?.value.timeline == null);
    try std.testing.expect(current.?.value.sample == null and current.?.value.syscalls == null);
}

fn testSubmit(worker: *Worker, current: *?*const boundary.Publication, action: boundary.Action, deadline: u64) !Completion {
    var sequence: ?u64 = null;
    while (true) {
        if (worker.publications.take(current.*) catch null) |next| current.* = next;
        if (sequence == null) {
            const command = try boundary.Command.create(a, .{ .stamp = current.*.?.value.stamp, .actor = .human, .action = action });
            sequence = worker.commands.trySubmit(command) catch |err| blk: {
                command.destroy();
                if (err != error.Busy) return err;
                break :blk null;
            };
        }
        if (worker.completions.take() catch null) |reply| {
            try std.testing.expectEqual(sequence.?, reply.sequence);
            if (reply.failure) |err| {
                if (err != error.StaleSnapshot) return err;
                sequence = null;
            } else return reply;
        }
        if (worker.done.load(.acquire)) return worker.failure orelse error.OwnerStopped;
        if (linux.now() >= deadline) return error.PublicationTimeout;
        _ = c.usleep(1000);
    }
}

test "metadata discovered during preparation stays pending until recaptured" {
    const test_a = std.testing.allocator;
    const Session = @import("session.zig").Session;
    const prepared = @import("language_view.zig");
    const session = try test_a.create(Session);
    defer test_a.destroy(session);
    session.* = Session.init();
    defer session.deinit();
    const tree = try test_a.create(Tree);
    defer test_a.destroy(tree);
    tree.* = .{};
    tree.init(session);
    defer tree.deinit();
    const worker = try test_a.create(Worker);
    defer test_a.destroy(worker);
    worker.* = .{ .publications = .{ .connection = 1 }, .executor = .{ .connection = 1, .tree = tree }, .options = .{ .connection = 1 }, .selection = .{ .process = 1, .selection = .{ .tid = 0 }, .kind = .language, .request_id = 1 } };
    defer worker.publications.deinit();
    defer worker.executor.deinit();
    const before = prepared.header(session);
    // Starting an unwind/layout metadata job advances this revision within a
    // preparation call, even while the target's stop generation is unchanged.
    session.metadata.revision += 1;
    try worker.publish(null, null, .{ .header = before, .key = before.key(0, 0) }, null);
    const pending = (try worker.publications.take(null)).?;
    var current: ?*const boundary.Publication = pending;
    defer if (current) |value| value.destroy();
    try std.testing.expectEqual(@FieldType(boundary.Presentation, "status").pending, pending.value.status);
    try std.testing.expect(!pending.value.matchesInspection(pending.value.stamp, 1));
    try std.testing.expect(worker.last_metadata != session.metadata.revision);
    const after = prepared.header(session);
    try worker.publish(null, null, .{ .header = after, .key = after.key(0, 0) }, null);
    current = (try worker.publications.take(pending)).?;
    try std.testing.expect(current.?.value.matchesInspection(current.?.value.stamp, 1));
}
