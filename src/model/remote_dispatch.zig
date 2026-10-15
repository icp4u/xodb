//! Concrete owner-thread execution. All returned slices still belong to the
//! request arena or Session; the worker must copy them into owned messages.
const std = @import("std");
const model = @import("session.zig");
const boundary = @import("remote_owner.zig");
const context = @import("../service/authority.zig");
const lease_model = @import("../service/lease.zig");
const linux = @import("../target/linux.zig");
const A = std.mem.Allocator;
const api = @import("command.zig");
pub const CommandResult = @import("commands.zig").Result;

pub fn stamp(connection: u64, session: *const model.Session) boundary.Stamp {
    const state = session.target.snapshot();
    return .{ .connection = connection, .session = session.id, .process = session.process_id, .pid = state.pid, .image_epoch = state.image_epoch, .generation = state.generation };
}

pub const Result = union(enum) {
    done,
    command: CommandResult,
    ids: []const u64,
    view: @import("../remote/view.zig").View,
    debugger: @import("debugger_view.zig").Presentation,
    language: @import("language_view.zig").Presentation,
    json: []const u8,
    inline_expression: @import("inline_view.zig").Message,
    probe_policy: @import("probe_view.zig").Outcome,
    capture_control: @import("capture_view.zig").Outcome,
};

pub const Executor = struct {
    connection: u64,
    tree: *@import("process_tree.zig").Tree,
    // Borrowed only by this owner; never queued or published.
    service: ?*context.c.struct_xsvc = null,
    source: ?[:0]const u8 = null,
    debugger: @import("debugger_view.zig").Capture = .{},
    language: @import("language_view.zig").Capture = .{},
    stop_details: @import("stop_view.zig").Capture = .{},
    inline_scopes: @import("inline_view.zig").Capture = .{},
    processes: @import("process_view.zig").Capture = .{},
    probes: @import("probe_view.zig").Capture = .{},
    allocations: @import("allocation_view.zig").Capture = .{},
    profile: @import("profile_view.zig").Capture = .{},
    capture_control: @import("capture_view.zig").Capture = .{},
    logical_frames: @import("frame_view.zig").Capture = .{},
    static_analysis: @import("static_view.zig").Capture = .{},
    runtime_types: @import("runtime_type_view.zig").Capture = .{},
    invocations: @import("invocation_view.zig").Capture = .{},
    timeline: @import("profile_timeline.zig").Capture = .{},
    sample: @import("sample_view.zig").Capture = .{},
    syscalls: @import("syscall_view.zig").Capture = .{},
    inspection: ?*@import("inspection_view.zig").Capture = null,
    debugger_process: ?u64 = null,
    native_watches: [@import("process_tree.zig").maximum]?struct { process: u64, list: *@import("native_watches.zig").WatchList } = @splat(null),

    pub fn deinit(self: *Executor) void {
        self.debugger.deinit();
        self.logical_frames.deinit();
        self.static_analysis.deinit();
        self.runtime_types.deinit();
        self.invocations.deinit();
        self.language.deinit();
        self.stop_details.deinit();
        self.inline_scopes.deinit();
        self.processes.deinit();
        self.probes.deinit();
        self.allocations.deinit();
        self.profile.deinit();
        self.timeline.deinit();
        self.sample.deinit();
        self.syscalls.deinit();
        if (self.inspection) |capture| {
            capture.deinit();
            std.heap.page_allocator.destroy(capture);
        }
        for (self.native_watches) |slot| if (slot) |entry| {
            entry.list.deinit();
            std.heap.page_allocator.destroy(entry.list);
        };
    }
    pub fn captureInspection(self: *Executor, session: *model.Session, wanted: ?@import("inspection_view.zig").Request) !?@import("inspection_view.zig").View {
        if (wanted == null) {
            if (self.inspection) |capture| capture.clear();
            return null;
        }
        if (self.inspection == null) {
            const capture = try std.heap.page_allocator.create(@import("inspection_view.zig").Capture);
            capture.* = .{};
            self.inspection = capture;
        }
        self.inspection.?.refresh(session, wanted);
        return self.inspection.?.value;
    }
    pub fn inspectionChanged(self: *const Executor, session: *const model.Session) bool {
        const capture = self.inspection orelse return false;
        const wanted = capture.value.request orelse return false;
        if (wanted.kind != .memory) return false;
        if (capture.snapshot) |id| {
            _ = session.memory.find(id) catch return true;
        }
        if (session.memory.search) |search| {
            const seen = capture.value.search orelse return true;
            return search.id != seen.id or search.state != seen.state or search.scanned != seen.scanned or search.unreadable != seen.unreadable or search.count != seen.hits.len;
        }
        return capture.value.search != null;
    }
    fn existingWatches(self: *const Executor, session: *const model.Session) ?*@import("native_watches.zig").WatchList {
        for (self.native_watches) |slot| if (slot) |entry| {
            if (entry.process == session.process_id) return entry.list;
        };
        return null;
    }
    pub fn nativeWatchRevision(self: *const Executor, session: *const model.Session) u64 {
        return if (self.existingWatches(session)) |list| list.revision else 0;
    }
    pub fn nativeWatchMetadataChanged(self: *const Executor, session: *const model.Session) bool {
        return if (self.existingWatches(session)) |list| list.count > 0 and (list.metadata_revision != session.metadata.revision or list.runtime_type_signature != session.runtime_types.signature()) else false;
    }
    pub fn captureNativeWatches(self: *Executor, session: *model.Session, selected: boundary.Selection) @import("native_watches.zig").View {
        const list = self.existingWatches(session) orelse return .{ .session = session.id };
        return @import("native_watches.zig").refresh(list, session, if (selected.tid != 0) .{ .tid = selected.tid, .index = selected.frame } else null);
    }
    fn nativeWatchList(self: *Executor, session: *model.Session, action: @import("native_watches.zig").Action) !*@import("native_watches.zig").WatchList {
        if (self.existingWatches(session)) |list| return list;
        if (action != .add) return error.WatchEntryNotFound;
        for (&self.native_watches) |*slot| if (slot.* == null) {
            const list = try std.heap.page_allocator.create(@import("native_watches.zig").WatchList);
            list.* = .{};
            slot.* = .{ .process = session.process_id, .list = list };
            return list;
        };
        return error.ProcessLimit;
    }
    /// MCP and GUI both choose the session's canonical native frame. A display
    /// request can retain its old TID only while no canonical selection exists.
    fn nativeSelection(session: *model.Session, wanted: boundary.Selection) boundary.Selection {
        if (session.language_tabs.native_selection) |value| return .{ .tid = value.tid, .frame = value.frame };
        const threads = session.target.threadSlice();
        for (threads) |thread| if (thread.tid == wanted.tid and thread.state != .exited) return wanted;
        for (threads) |thread| if (thread.state == .stopped) return .{ .tid = thread.tid };
        return .{ .tid = if (threads.len > 0) threads[0].tid else 0 };
    }
    fn prepareViewProcess(self: *Executor, session: *model.Session) void {
        if (self.debugger_process != session.process_id) {
            self.debugger.deinit();
            self.logical_frames.deinit();
            self.logical_frames = .{};
            self.static_analysis.deinit();
            self.static_analysis = .{};
            self.runtime_types.deinit();
            self.runtime_types = .{};
            self.invocations.deinit();
            self.invocations = .{};
            self.debugger = .{};
            self.language.deinit();
            self.language = .{};
            self.debugger_process = session.process_id;
            if (self.source) |path| self.debugger.source.load(path) catch {};
        }
        session.language_tabs.enabled = true;
        session.language_tabs.syncSelection(session.target.snapshot().generation);
    }
    pub fn captureDebugger(self: *Executor, session: *model.Session, inspection: boundary.Inspection) @import("debugger_view.zig").Presentation {
        self.prepareViewProcess(session);
        const selected = nativeSelection(session, inspection.selection);
        self.debugger.refresh(session, .{ .tid = selected.tid, .frame = selected.frame, .browse_address = inspection.browse_address, .browse_assembly = inspection.browse_assembly, .flow = inspection.show_flow });
        return self.debugger.value;
    }
    pub fn captureLanguage(self: *Executor, session: *model.Session, inspection: boundary.Inspection) !@import("language_view.zig").Presentation {
        if (inspection.text.len > 128 or inspection.binding_start > 4096) return error.InvalidArguments;
        self.prepareViewProcess(session);
        const state = @import("language_view.zig").header(session);
        const threads = session.target.threadSlice();
        const tid = if (state.selectedKey()) |row| row.tid else if (inspection.selection.tid != 0) inspection.selection.tid else if (threads.len > 0) threads[0].tid else 0;
        self.language.refresh(session, .{ .tid = tid, .frame = inspection.selection.frame, .selected = inspection.language_selection, .binding_start = inspection.binding_start, .expression = inspection.text });
        return self.language.value;
    }

    /// Validate non-core commands at their owner-thread boundary.
    pub fn sessionFor(self: *Executor, command: *const boundary.Command) !*model.Session {
        const session = (try self.tree.find(command.request.stamp.process)).session;
        if (!session.target.isRemote()) return error.RemoteSessionRequired;
        var authorizer = Authorizer{ .executor = self, .session = session };
        try command.validate(stamp(self.connection, session), &authorizer);
        return session;
    }
    pub fn execute(self: *Executor, a: A, command: *const boundary.Command) !Result {
        const request = command.request;
        const session = (try self.tree.find(request.stamp.process)).session;
        if (!session.target.isRemote()) return error.RemoteSessionRequired;
        const operation: ?api.Operation = switch (request.action) {
            .control => |control| .{ .control = control },
            .breakpoint => |bp| .{ .breakpoint = bp },
            else => null,
        };
        if (operation) |op| return .{ .command = try session.executeCommand(a, self.connection, self.service, .{ .stamp = request.stamp, .caller = request.actor, .operation = op }) };
        if (request.action == .probe_policy) {
            _ = try self.sessionFor(command);
            const resolved = try @import("probe_view.zig").resolve(session, request.action.probe_policy);
            _ = try session.executeCommand(a, self.connection, self.service, .{ .stamp = request.stamp, .caller = request.actor, .operation = resolved.operation });
            return .{ .probe_policy = resolved.outcome };
        }
        var authorizer = Authorizer{ .executor = self, .session = session };
        try command.validate(stamp(self.connection, session), &authorizer);

        const previous_client = session.agent_client_id;
        const previous_lease = session.agent_lease;
        const previous_controller = session.agent_controller;
        defer {
            session.agent_client_id = previous_client;
            session.agent_lease = previous_lease;
            session.agent_controller = previous_controller;
        }
        const actor: model.Actor = if (request.actor == .human) .human else .agent;
        session.agent_client_id = if (request.actor == .agent and request.actor.agent.client != 0) request.actor.agent.client else null;
        session.agent_lease = authorizer.lease;
        session.agent_controller = actor == .agent and effect(request.action) != null;

        switch (request.action) {
            .allocation => |intent| try @import("allocation_view.zig").apply(session, intent, actor),
            .probe_policy => unreachable,
            .poll => {
                try self.tree.poll();
                return .done;
            },
            .inspect => |inspection| {
                if (inspection.text.len > 128 or inspection.binding_start > 4096) return error.InvalidArguments;
                if (inspection.kind == .language) return .{ .language = try self.captureLanguage(session, inspection) };
                if (inspection.kind == .debugger) return .{ .debugger = self.captureDebugger(session, inspection) };
                if (inspection.kind != .view) return error.UnsupportedInspection;
                return error.ProtocolAdapterRequired;
            },
            .mcp => return error.ProtocolAdapterRequired,
            .workspace => |action| try @import("workspace_view.zig").apply(a, session, action),
            .toggle_scope => {
                if (self.service) |service| try context.check(context.c.xsvc_revoke(service, linux.now()));
                session.setAgentScope(if (session.agent_scope == .observe) .control else .observe);
            },
            .control => unreachable,
            .static_cancel => |id| try @import("static_view.zig").cancel(session, actor, id),
            .invocation => |action| try self.invocations.apply(session, actor, action),
            .runtime_type => |action| try self.runtime_types.apply(session, actor, action),
            .logical_frames => |action| try @import("frame_view.zig").apply(&session.frames, action),
            .capture_control => |action| return .{ .capture_control = try @import("capture_view.zig").apply(&self.capture_control.rows, session, actor, action) },
            .language => |action| try @import("language_view.zig").apply(session, action),
            .process => |process_op| try @import("process_view.zig").apply(self.tree, request.stamp, actor, process_op),
            .inline_expression => |request_| return .{ .inline_expression = try @import("inline_view.zig").evaluate(session, request_) },
            .memory_action => |action| {
                if (try @import("inspection_view.zig").apply(session, actor, action)) |value| {
                    const ids = try a.alloc(u64, 1);
                    ids[0] = value;
                    return .{ .ids = ids };
                }
            },
            .native_watch => |action| {
                if (try @import("native_watches.zig").apply(try self.nativeWatchList(session, action), session, actor, action)) |id| {
                    const ids = try a.alloc(u64, 1);
                    ids[0] = id;
                    return .{ .ids = ids };
                }
            },
            .runtime_watch => |action| {
                if (try @import("runtime_watch_view.zig").apply(session, actor, action)) |id| {
                    const ids = try a.alloc(u64, 1);
                    ids[0] = id;
                    return .{ .ids = ids };
                }
            },
            .breakpoint => unreachable,
            .watchpoint => |wp| switch (wp) {
                .add => |add| {
                    const ids = try a.alloc(u64, 1);
                    const kind = std.meta.stringToEnum(@import("../target/breakpoints.zig").WatchKind, @tagName(add.kind)).?;
                    const id = try session.target.setWatchpoint(add.address, add.length, kind);
                    ids[0] = id;
                    session.record(actor, "set_watchpoint");
                    return .{ .ids = ids };
                },
                .remove => |id| {
                    try session.target.removeWatchpoint(id);
                    session.record(actor, "remove_watchpoint");
                },
            },
            .write_memory => |write| {
                if (write.bytes.len == 0 or write.bytes.len > 4096) return error.InvalidArguments;
                const before = session.target.snapshot().generation;
                session.target.writeMemory(write.address, write.bytes) catch |err| {
                    if (session.target.snapshot().generation != before) session.record(actor, "write_memory_partial");
                    return err;
                };
                session.record(actor, "write_memory");
            },
            .write_register => |write| {
                if (write.tid <= 0) return error.InvalidArguments;
                try session.target.writeRegister(write.tid, write.name, write.value);
                session.record(actor, "write_register");
            },
        }
        return .done;
    }

    const Authorizer = struct {
        executor: *Executor,
        session: *model.Session,
        lease: ?lease_model.Lease = null,
        pub fn authorize(self: *@This(), request: boundary.Request) !void {
            if (request.action == .mcp) {
                if (request.actor != .agent) return error.ProtocolActorRequired;
                return; // queuedTool resolves catalog access and live identity.
            }
            // Presentation selection belongs to the human frontend. It can
            // prepare retained GUI jobs; protocol clients must use the common
            // tool dispatcher and its per-call requester instead.
            if ((request.action == .inspect or request.action == .workspace or request.action == .toggle_scope) and request.actor != .human) return error.GuiActorRequired;
            if (request.actor == .agent) {
                const agent = request.actor.agent;
                if (self.executor.service) |service| {
                    try context.check(context.c.xsvc_tick(service, linux.now(), @intFromEnum(self.executor.tree.root().agent_scope)));
                    try context.check(context.c.xsvc_authorize(service, agent.client, context.c.XSVC_OBSERVE, linux.now()));
                    if (effect(request.action)) |required| {
                        try context.authorize(service, agent.client, required == .mutation, linux.now());
                        const live = lease_model.Lease.capture(service, agent.client) orelse return error.ControlLeaseRequired;
                        if (agent.lease != live.id) return error.ControlLeaseRequired;
                        self.lease = live;
                    }
                } else if (agent.client != 0 or agent.lease != null) return error.UnknownSessionClient;
            }
            if (effect(request.action)) |required| try self.session.authorize(if (request.actor == .human) .human else .agent, required, request.stamp.generation);
        }
    };
};
fn effect(action: boundary.Action) ?model.Effect {
    return switch (action) {
        .control, .breakpoint, .watchpoint, .runtime_watch, .native_watch, .language, .probe_policy, .allocation, .capture_control, .logical_frames, .static_cancel, .invocation, .workspace => .execution,
        .runtime_type => |action_| if (action_.kind == .undo or (action_.kind == .edit and action_.kind.edit.mode == .write)) .mutation else .execution,
        .write_memory, .write_register => .mutation,
        .memory_action => |action_| if (action_ == .address) null else .execution,
        .process => .execution,
        .poll, .inspect, .inline_expression, .mcp, .toggle_scope => null,
    };
}
test "remote dispatch refuses local ownership and validates queued identities" {
    const a = std.testing.allocator;
    const session = try a.create(model.Session);
    defer a.destroy(session);
    session.* = model.Session.init();
    defer session.deinit();
    const tree = try a.create(@import("process_tree.zig").Tree);
    defer a.destroy(tree);
    tree.* = .{};
    tree.init(session);
    defer tree.deinit();
    var executor: Executor = .{ .connection = 1, .tree = tree };
    const local = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .human, .action = .poll });
    defer local.destroy();
    try std.testing.expectError(error.RemoteSessionRequired, executor.execute(a, local));

    try session.target.connectRemote(&.{ "./zig-out/bin/xodb-agent", "--stdio" });
    const old_connection = try boundary.Command.create(a, .{ .stamp = stamp(2, session), .actor = .human, .action = .{ .control = .interrupt } });
    defer old_connection.destroy();
    try std.testing.expectError(error.StaleProcess, executor.execute(a, old_connection));
    const old_stop = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .human, .action = .{ .control = .cancel_continue } });
    defer old_stop.destroy();
    try session.target.invalidate();
    _ = try executor.execute(a, old_stop); // Old-view cancellation remains effective.
    const after_cancel = session.audit_count;

    const denied = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .{ .agent = .{ .client = 0, .lease = null } }, .action = .{ .control = .interrupt } });
    defer denied.destroy();
    try std.testing.expectError(error.AgentScopeDenied, executor.execute(a, denied));
    try std.testing.expectEqual(after_cancel, session.audit_count);
    const selection_denied = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .{ .agent = .{ .client = 0, .lease = null } }, .action = .{ .language = .{ .tab = .registers } } });
    defer selection_denied.destroy();
    try std.testing.expectError(error.AgentScopeDenied, executor.execute(a, selection_denied));
    const probe_denied = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .{ .agent = .{ .client = 0, .lease = null } }, .action = .{ .probe_policy = .{ .key = @import("probe_view.zig").sessionKey(session), .edit = .{ .remove = 1 } } } });
    defer probe_denied.destroy();
    try std.testing.expectError(error.AgentScopeDenied, executor.execute(a, probe_denied));
    const allocation_denied = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .{ .agent = .{ .client = 0, .lease = null } }, .action = .{ .allocation = .{ .stop = .{ .identity = null, .serial = 0 } } } });
    defer allocation_denied.destroy();
    try std.testing.expectError(error.AgentScopeDenied, executor.execute(a, allocation_denied));
    const watch_denied = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .{ .agent = .{ .client = 0, .lease = null } }, .action = .{ .runtime_watch = .{ .remove = 1 } } });
    defer watch_denied.destroy();
    try std.testing.expectError(error.AgentScopeDenied, executor.execute(a, watch_denied));
    const watch_human = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .human, .action = .{ .runtime_watch = .{ .remove = 1 } } });
    defer watch_human.destroy();
    try std.testing.expectError(error.LanguageWatchNotFound, executor.execute(a, watch_human));
    const native_denied = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .{ .agent = .{ .client = 0, .lease = null } }, .action = .{ .native_watch = .{ .remove = .{ .revision = 0, .index = 0 } } } });
    defer native_denied.destroy();
    try std.testing.expectError(error.AgentScopeDenied, executor.execute(a, native_denied));
    const native_human = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .human, .action = .{ .native_watch = .{ .remove = .{ .revision = 0, .index = 0 } } } });
    defer native_human.destroy();
    try std.testing.expectError(error.WatchEntryNotFound, executor.execute(a, native_human));
    const memory_denied = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .{ .agent = .{ .client = 0, .lease = null } }, .action = .{ .memory_action = .{ .cancel = 1 } } });
    defer memory_denied.destroy();
    try std.testing.expectError(error.AgentScopeDenied, executor.execute(a, memory_denied));
    const inspection_denied = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .{ .agent = .{ .client = 0, .lease = null } }, .action = .{ .inspect = .{ .request_id = 1, .selection = .{ .tid = 0 }, .kind = .debugger, .profile = .{ .basis = .reconstructed } } } });
    defer inspection_denied.destroy();
    try std.testing.expectError(error.GuiActorRequired, executor.execute(a, inspection_denied));
    try std.testing.expect(!session.profile_view_visible);
    const address_read = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .{ .agent = .{ .client = 0, .lease = null } }, .action = .{ .memory_action = .{ .address = .{ .tid = 1, .frame = 0, .metadata = session.metadata.revision, .text = "0x1000" } } } });
    defer address_read.destroy();
    const address_reply = try executor.execute(a, address_read);
    defer a.free(address_reply.ids);
    try std.testing.expectEqual(@as(u64, 0x1000), address_reply.ids[0]);

    const scope_stamp = stamp(1, session);
    const scope_denied = try boundary.Command.create(a, .{ .stamp = scope_stamp, .actor = .{ .agent = .{ .client = 0, .lease = null } }, .action = .toggle_scope });
    defer scope_denied.destroy();
    try std.testing.expectError(error.GuiActorRequired, executor.execute(a, scope_denied));
    const scope_human = try boundary.Command.create(a, .{ .stamp = scope_stamp, .actor = .human, .action = .toggle_scope });
    defer scope_human.destroy();
    const audit_before = session.audit_count;
    _ = try executor.execute(a, scope_human);
    try std.testing.expectEqual(model.AgentScope.control, session.agent_scope);
    // Both queued presses must apply even though the first invalidates the stop.
    _ = try executor.execute(a, scope_human);
    try std.testing.expectEqual(model.AgentScope.observe, session.agent_scope);
    try std.testing.expectEqual(audit_before + 2, session.audit_count);

    // A human is allowed to control an observe-scope remote session. This
    // catches accidentally routing GUI actions through agent-only handlers.
    try session.launch(&.{"/bin/true"});
    const pc = try linux.programCounter(try session.target.registers(session.target.snapshot().pid));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const add = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .human, .action = .{ .breakpoint = .{ .address = pc } } });
    defer add.destroy();
    const result = try executor.execute(arena.allocator(), add);
    try std.testing.expectEqual(@as(usize, 1), result.command.ids.len);
    const id = result.command.ids[0];
    try session.probes.configure(&session.target, id, .{ .condition = "1", .ignore_count = 3 }, true);
    const disable = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .human, .action = .{ .breakpoint = .{ .enabled = .{ .id = id, .enabled = false } } } });
    defer disable.destroy();
    _ = try executor.execute(arena.allocator(), disable);
    try std.testing.expectEqualStrings("1", session.probes.rule(id).?.condition.slice());
    try std.testing.expectEqual(@as(u64, 3), session.probes.rule(id).?.ignore_remaining);
    try std.testing.expect(!@import("persistent.zig").Manager.probe(session, id).?.enabled);
    const remove = try boundary.Command.create(a, .{ .stamp = stamp(1, session), .actor = .human, .action = .{ .breakpoint = .{ .remove = id } } });
    defer remove.destroy();
    _ = try executor.execute(arena.allocator(), remove);
    try std.testing.expect(@import("persistent.zig").Manager.probe(session, id) == null);
    try std.testing.expectEqual(model.Actor.human, session.audit[session.audit_count - 1].actor);
}

test "owner selection follows the canonical frame and watch lists belong to each process" {
    const a = std.testing.allocator;
    const session = try a.create(model.Session);
    defer a.destroy(session);
    session.* = model.Session.init();
    defer session.deinit();
    const tree = try a.create(@import("process_tree.zig").Tree);
    defer a.destroy(tree);
    tree.* = .{};
    tree.init(session);
    defer tree.deinit();
    var executor: Executor = .{ .connection = 1, .tree = tree };
    defer executor.deinit();
    session.language_tabs.native_selection = .{ .generation = 3, .tid = 42, .frame = 7 };
    const chosen = Executor.nativeSelection(session, .{ .tid = 24, .frame = 1 });
    try std.testing.expectEqual(@as(i32, 42), chosen.tid);
    try std.testing.expectEqual(@as(usize, 7), chosen.frame);
    const create: @import("native_watches.zig").Action = .{ .add = .{ .binding = .{ .selection = .{ .tid = 42, .index = 0 }, .metadata = 0 }, .text = "1", .mode = .pinned } };
    const root_id = session.process_id;
    const first = try executor.nativeWatchList(session, create);
    first.revision = 11;
    session.process_id = root_id + 1;
    try std.testing.expect(executor.existingWatches(session) == null);
    const second = try executor.nativeWatchList(session, create);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(u64, 0), second.revision);
    second.revision = 23;
    session.process_id = root_id;
    try std.testing.expectEqual(first, executor.existingWatches(session).?);
    try std.testing.expectEqual(@as(u64, 11), executor.nativeWatchRevision(session));
}
