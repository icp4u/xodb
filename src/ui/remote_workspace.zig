//! Frame-thread adapter. Its only live connection is the bounded exchange with
//! the owner; every pane reads the retained immutable publication.
const std = @import("std");
const boundary = @import("../model/remote_owner.zig");
const Worker = @import("../model/remote_worker.zig").Worker;
const Completion = @import("../model/remote_worker.zig").Completion;
const Workspace = @import("workspace.zig").Workspace;
const Window = @import("../platform/wayland.zig").Window;
const keys = @import("../platform/input.zig");
const a = std.heap.page_allocator;
const empty_language: @import("../model/language_view.zig").Header = .{ .session = 0, .generation = 0, .metadata = 0, .revision = 0, .state = .idle, .selected = .native, .native_selection = null, .logical_selection = null };
const Pending = struct {
    command: *boundary.Command,
    sequence: ?u64 = null,
    order: u64,
    workspace: *Workspace,
    editor_signature: ?u64 = null,
};
pub const Frontend = struct {
    owner: *Worker,
    current: ?*const boundary.Publication = null,
    display: @import("../model/debugger_view.zig").Presentation = .{},
    header: @import("../model/workspace_view.zig").Header = .{},
    language: @import("../model/language_view.zig").Header = empty_language,
    processes: @import("../model/process_view.zig").View = .{},
    pending: [boundary.max_commands]?Pending = @splat(null),
    pending_bytes: usize = 0,
    next_order: u64 = 0,
    inspection_sequence: ?u64 = null,
    inspection_hash: ?u64 = null,
    inspection_id: u64 = 0,
    last_archive: ?u64 = null,
    last_presentation_error: u16 = 0,
    archive_message: [512]u8 = undefined,

    /// Only after the owner has joined; teardown may free the last publication.
    pub fn deinit(self: *Frontend) void {
        for (self.pending) |slot| if (slot) |p| p.command.destroy();
        if (self.current) |publication| publication.destroy();
    }
    pub fn stamp(self: *const Frontend) ?boundary.Stamp {
        return if (self.current) |value| value.value.stamp else null;
    }
    pub fn send(self: *Frontend, workspace: *Workspace, action: boundary.Action) void {
        self.sendAt(workspace, self.stamp() orelse {
            workspace.status = "Waiting for the remote session";
            return;
        }, action);
    }
    pub fn sendAt(self: *Frontend, workspace: *Workspace, identity: boundary.Stamp, action: boundary.Action) void {
        self.enqueue(workspace, identity, action) catch |err| {
            workspace.status = @errorName(err);
            if (action == .runtime_type) workspace.runtime_type_panel.complete(err);
        };
    }
    fn editor(workspace: *Workspace, action: boundary.Action) ?*@import("watch.zig").Editor {
        return switch (action) {
            .native_watch => |v| if (v == .add) &workspace.editor else null,
            .runtime_watch => |v| if (v == .add and workspace.language_panel.editor.open) &workspace.language_panel.editor else null,
            .inline_expression => &workspace.inline_panel.editor,
            .memory_action => &workspace.inspection_panel.editor,
            .probe_policy => &workspace.probes_panel.editor,
            .allocation => |v| if (v == .save) &workspace.allocation_save_editor else null,
            else => null,
        };
    }
    fn enqueue(self: *Frontend, workspace: *Workspace, identity: boundary.Stamp, action: boundary.Action) !void {
        const index = for (self.pending, 0..) |slot, i| {
            if (slot == null) break i;
        } else return error.Busy;
        const command = try boundary.Command.create(a, .{ .stamp = identity, .actor = .human, .action = action });
        errdefer command.destroy();
        if (command.bytes > boundary.max_command_bytes -| self.pending_bytes) return error.Busy;
        self.pending[index] = .{ .command = command, .workspace = workspace, .order = self.next_order, .editor_signature = if (editor(workspace, action)) |field| editorSignature(field) else null };
        self.pending_bytes += command.bytes;
        self.next_order += 1;
    }
    /// Admission is nonblocking. Keep a private command copy for retry and for
    /// completion context; the owner receives a separate owned payload.
    pub fn pump(self: *Frontend) void {
        while (self.owner.completions.take() catch null) |reply| {
            for (&self.pending) |*slot| if (slot.*) |p| {
                if (p.sequence == null or p.sequence.? != reply.sequence) continue;
                self.complete(p, reply);
                if (p.command.request.action == .inspect) self.inspection_sequence = null;
                self.pending_bytes -= p.command.bytes;
                p.command.destroy();
                slot.* = null;
                break;
            };
        }
        while (true) {
            var oldest: ?*Pending = null;
            for (&self.pending) |*slot| if (slot.*) |*entry| {
                if (entry.sequence == null and (oldest == null or entry.order < oldest.?.order)) oldest = entry;
            };
            const p = oldest orelse break;
            const copy = boundary.Command.create(a, p.command.request) catch |err| {
                p.workspace.status = @errorName(err);
                break;
            };
            const sequence = self.owner.commands.trySubmit(copy) catch |err| {
                copy.destroy();
                if (err != error.Busy) p.workspace.status = @errorName(err);
                break;
            };
            p.sequence = sequence;
            if (p.command.request.action == .inspect) self.inspection_sequence = sequence;
        }
    }
    fn complete(self: *Frontend, pending: Pending, reply: Completion) void {
        const workspace = pending.workspace;
        const action = pending.command.request.action;
        // Completion text is copied before the fixed reply slot is reused.
        defer if (reply.status) |message| {
            const text = message.slice();
            const n = @min(text.len, workspace.presentation_status.len);
            @memcpy(workspace.presentation_status[0..n], text[0..n]);
            workspace.status = workspace.presentation_status[0..n];
        };
        if (action == .inspect) {
            if (reply.failure != null) self.inspection_hash = null;
            return;
        }
        const same_editor = if (editor(workspace, action)) |field| pending.editor_signature != null and editorSignature(field) == pending.editor_signature.? else true;
        if (reply.failure) |err| {
            workspace.status = @errorName(err);
            if (same_editor) {
                if (editor(workspace, action)) |field| field.message = @errorName(err);
            }
            if (action == .runtime_type) workspace.runtime_type_panel.complete(err);
            if (action == .invocation) workspace.invocations.complete(err);
            if (action == .probe_policy and same_editor) workspace.probes_panel.failed(err);
            self.inspection_hash = null;
            return;
        }
        switch (action) {
            .capture_control => if (reply.capture_control) |value| workspace.captureOutcome(value),
            .runtime_type => workspace.runtime_type_panel.complete(null),
            .invocation => workspace.invocations.complete(null),
            .inline_expression => if (same_editor) {
                if (reply.inline_expression) |message| workspace.inline_panel.complete(message);
            },
            .probe_policy => if (same_editor) {
                if (reply.probe_policy) |outcome| workspace.probes_panel.complete(outcome);
            },
            .memory_action => |value| if (same_editor) {
                workspace.inspection_panel.complete(value, reply.first_id);
            },
            .process => |value| workspace.process_panel.complete(value),
            .allocation => |value| if (value == .save and same_editor) {
                workspace.allocation_save_editor.open = false;
            },
            .native_watch => |value| switch (value) {
                .add => {
                    if (reply.first_id) |id| if (reply.native_watch_revision) |revision| workspace.watch_panel.addedAt(@intCast(id), revision);
                    if (same_editor) workspace.editor.open = false;
                    workspace.status = "Watch added; activation lifetime between stops is unproved";
                },
                .remove => |token| workspace.watch_panel.removed(token.index, workspace.watch_view.entries.len -| 1),
                .investigate_write => workspace.status = "Write investigation started",
                else => {},
            },
            .runtime_watch => |value| {
                if (value == .add) {
                    workspace.runtime_watch_panel.selected = reply.first_id;
                    workspace.runtime_watch_panel.reveal = true;
                    workspace.show_watch = true;
                    if (same_editor) workspace.language_panel.editor.open = false;
                } else workspace.runtime_watch_panel.selected = null;
            },
            .toggle_scope => workspace.status = "Agent scope changed",
            else => {},
        }
        self.inspection_hash = null;
    }
    pub fn scopeInput(self: *Frontend, workspace: *Workspace, window: *Window) void {
        if (workspace.shared_clients == null or window.closing) return;
        for (0..window.input.count) |offset| {
            const event = &window.input.queue[(window.input.head + offset) % keys.capacity];
            if (event.kind != .press or !event.plain() or event.shortcut != keys.sym.f8) continue;
            self.send(workspace, .toggle_scope);
            window.dirty = true;
            event.* = .{ .kind = .release };
        }
    }
    pub fn processInput(self: *Frontend, workspace: *Workspace, input: @import("processes.zig").Panel.KeyAction) bool {
        return switch (input) {
            .ignored => false,
            .local => true,
            .owner => |intent| blk: {
                self.sendAt(workspace, intent.stamp, .{ .process = intent.operation });
                break :blk true;
            },
        };
    }
    pub fn runtimeTypeInput(self: *Frontend, workspace: *Workspace, input: @import("runtime_types.zig").Input) void {
        if (input.action) |action| self.send(workspace, .{ .runtime_type = action });
    }
    pub fn submitLanguage(self: *Frontend, workspace: *Workspace, text: []const u8) !void {
        if (try workspace.language_panel.submitExpressionView(self.language, text)) |action| self.send(workspace, .{ .runtime_watch = action });
    }
    pub fn paneKey(self: *Frontend, workspace: *Workspace, tid: i32, event: keys.Event, window: *Window) bool {
        const static = workspace.static_panel.keyPrepared(event);
        if (static.handled) {
            if (static.cancel) |id| self.send(workspace, .{ .static_cancel = id });
            workspace.traceStatic(window);
            workspace.followStatic(window);
            return true;
        }
        switch (workspace.inline_panel.keyView(tid, workspace.selected_frame, self.language.metadata, event)) {
            .ignored => {},
            .local => return true,
            .owner => |action| {
                self.send(workspace, .{ .inline_expression = action });
                return true;
            },
        }
        const types = workspace.runtime_type_panel.keyPrepared(event);
        if (types.handled) {
            self.runtimeTypeInput(workspace, types);
            return true;
        }
        const memory = workspace.inspection_panel.keyView(tid, workspace.selected_frame, self.language.metadata, event) catch |err| {
            workspace.inspection_panel.message = @errorName(err);
            return true;
        };
        switch (memory) {
            .ignored => {},
            .local => return true,
            .owner => |action| {
                self.send(workspace, .{ .memory_action = action });
                return true;
            },
        }
        switch (workspace.probes_panel.keyView(event)) {
            .ignored => {},
            .local => return true,
            .owner => |action| {
                self.send(workspace, .{ .probe_policy = action });
                return true;
            },
        }
        return false;
    }
    pub fn take(self: *Frontend) !bool {
        const failure = self.owner.presentation_error.load(.acquire);
        const changed = self.last_presentation_error != failure;
        self.last_presentation_error = failure;
        const next = (self.owner.publications.take(self.current) catch |err| {
            if (err == error.Busy) return false;
            return err;
        }) orelse return changed and self.current != null;
        self.current = next;
        self.display = next.value.debugger orelse .{};
        self.header = next.value.workspace orelse .{};
        self.language = if (next.value.language) |value| value.header else self.display.language_header orelse empty_language;
        self.processes = next.value.processes orelse .{};
        return true;
    }
    pub fn present(self: *Frontend, workspace: *Workspace, window: *Window) void {
        const publication = self.current orelse return;
        const value = publication.value;
        const changed_stop = workspace.last_generation != self.display.snapshot.generation;
        if (changed_stop) {
            workspace.browse_address = null;
            workspace.browse_assembly = null;
            workspace.alive = 0;
            workspace.stale_regs = if (workspace.last_tid == self.display.request.tid) workspace.regs else null;
        }
        workspace.last_generation = self.display.snapshot.generation;
        workspace.last_metadata_revision = self.display.metadata_revision;
        workspace.last_tid = self.display.request.tid;
        workspace.last_frame = self.display.selected_frame;
        workspace.selected = for (self.display.threads, 0..) |thread, index| {
            if (thread.tid == self.display.request.tid) break index;
        } else 0;
        workspace.presentDebugger(self.display);
        workspace.shared_clients = self.header.shared_clients;
        workspace.shared_controller = self.header.shared_controller;
        workspace.fd_event_state = self.header.fd_events;
        workspace.presentNativeWatches(value.native_watches orelse .{});
        workspace.presentRuntimeWatches(value.runtime_watches orelse .{});
        workspace.presentStop(value.stop orelse .{});
        workspace.inspection_panel.present(value.memory orelse .{});
        workspace.inline_panel.present(value.inline_scope orelse .{});
        workspace.process_panel.present(self.processes);
        workspace.probes_panel.present(value.probes orelse .{});
        workspace.allocation_panel.present(value.allocations orelse .{});
        workspace.flame.present(value.profile orelse .{});
        if (workspace.timeline.present(value.timeline, workspace.timelineBounds(window))) workspace.applyTimeline(self);
        workspace.inspector.present(value.sample, workspace.flame.selection.filter);
        workspace.syscall_panel.present(value.syscalls, @floatFromInt(window.height), workspace.flame.selection.filter);
        workspace.capture_view = value.capture_control orelse .{};
        workspace.logical_frames.present(value.logical_frames);
        workspace.static_panel.present(value.static_analysis);
        workspace.runtime_type_panel.present(value.runtime_types);
        workspace.invocations.present(value.invocations);
        if (value.language) |language| workspace.language_panel.present(language) else workspace.language_panel.present(.{ .header = self.language, .key = self.language.key(0, 0) });
        const busy = workspace.allocation_panel.view.preparing;
        const collecting = workspace.allocation_panel.view.collecting;
        if (workspace.allocation_busy and !busy) workspace.status = if (collecting) "Allocation capture ready; Space continues" else "Allocation preparation ended";
        if (workspace.allocation_collecting and !collecting) workspace.status = "Allocation capture ended; A opens evidence";
        workspace.allocation_busy = busy;
        workspace.allocation_collecting = collecting;
        if (workspace.was_running_to and !self.header.running_to) workspace.status = "Run-to operation ended";
        workspace.was_running_to = self.header.running_to;
        if (workspace.capture_view.archive_job) |job| {
            if (!job.done or self.last_archive != job.id) {
                workspace.status = std.fmt.bufPrint(&self.archive_message, "Archive {s}: {s}{s}{s}", .{ job.kind, if (!job.done) job.phase else if (job.publication) |p| @tagName(p.state) else if (job.error_name != null) "failed" else "ready", if (job.error_name != null) " / " else "", job.error_name orelse "" }) catch "Archive operation";
                if (job.done) self.last_archive = job.id;
            }
        }
        workspace.traceStatic(window);
        if (window.input.trace) if (value.static_analysis) |static| if (static.target == .line and static.request.chosen == null) {
            std.debug.print("static functions:", .{});
            for (static.target.line.functions) |function| std.debug.print(" {s}", .{function.name});
            std.debug.print("\n", .{});
        };
        window.dirty = true;
    }
    pub fn inspect(self: *Frontend, workspace: *Workspace, window: *Window) void {
        const identity = self.stamp() orelse return;
        // One pending inspection is enough. Local input continues changing the
        // desired view while a remote call is held; submit the newest next.
        for (self.pending) |slot| if (slot) |p| if (p.command.request.action == .inspect) return;
        const tid = if (workspace.selected < self.display.threads.len) self.display.threads[workspace.selected].tid else 0;
        const height: f32 = @floatFromInt(window.height);
        const profile_visible = workspace.show_profile and !workspace.logical_frames.open and !workspace.invocations.open;
        var request = boundary.Inspection{
            .request_id = 0,
            .selection = .{ .tid = tid, .frame = workspace.selected_frame },
            .kind = .debugger,
            .browse_address = workspace.browse_address,
            .browse_assembly = workspace.browse_assembly,
            .show_flow = workspace.show_flow,
            .show_stop = workspace.stop_panel.open,
            .show_processes = workspace.process_panel.open,
            .show_probes = workspace.probes_panel.open,
            .show_setup = profile_visible and workspace.setup.open,
            .logical_frames = workspace.logical_frames.request(@intCast(window.height)),
            .static_analysis = workspace.static_panel.request(tid, workspace.selected_frame),
            .runtime_types = workspace.runtime_type_panel.request(height),
            .invocations = workspace.invocations.request(window.input.trace),
            .allocations = workspace.allocation_panel.request(height),
            .profile = workspace.flame.request(profile_visible),
            .timeline = if (profile_visible) workspace.timeline.request(workspace.timelineBounds(window)) else null,
            .sample = if (profile_visible) workspace.inspector.request(workspace.flame.selection.filter) else null,
            .syscalls = if (profile_visible) workspace.syscall_panel.request(height, workspace.flame.selection.filter) else null,
            .memory = workspace.inspection_panel.request(tid),
            .inline_scope = workspace.inline_panel.request(tid, workspace.selected_frame, identity.generation),
            .binding_start = workspace.language_panel.binding_start,
            .language_selection = workspace.language_panel.bindings_key,
            .text = workspace.language_panel.expression[0..workspace.language_panel.expression_len],
        };
        var hash = std.hash.Wyhash.init(identity.process);
        hashValue(&hash, request);
        const signature = hash.final();
        if (self.inspection_hash == signature) return;
        request.request_id = self.inspection_id + 1;
        self.enqueue(workspace, identity, .{ .inspect = request }) catch |err| {
            workspace.status = @errorName(err);
            return;
        };
        self.inspection_id = request.request_id;
        self.inspection_hash = signature;
    }
    pub fn draw(self: *Frontend, workspace: *Workspace, r: *@import("../render/vulkan.zig").Renderer, font: *@import("../render/font.zig").Font, window: *Window) !void {
        // Local task metadata is never read or borrowed by the remote painter.
        workspace.compatibility_info = .{ .kind = .unavailable };
        workspace.thread_labels = &.{};
        if (workspace.logical_frames.open) {
            workspace.animating = workspace.logical_frames.value.busy;
            try workspace.logical_frames.drawPrepared(r, font, window);
            try workspace.drawSharedOwnership(r, font, window, self.header.scope);
            return self.drawPublicationStatus(r, font, window);
        }
        if (workspace.invocations.open) {
            workspace.animating = workspace.invocations.busyPrepared();
            try workspace.invocations.drawPrepared(r, font, window, if (workspace.shared_clients != null) 30 else 0);
            try workspace.drawSharedOwnership(r, font, window, self.header.scope);
            return self.drawPublicationStatus(r, font, window);
        }
        try workspace.drawPrepared(r, font, window, self.display, self.header, self.language, false);
        try self.drawPublicationStatus(r, font, window);
    }
    fn drawPublicationStatus(self: *Frontend, r: *@import("../render/vulkan.zig").Renderer, font: *@import("../render/font.zig").Font, window: *Window) !void {
        var buffer: [1024]u8 = undefined;
        var stream = std.Io.Writer.fixed(&buffer);
        const failure = self.owner.presentation_error.load(.acquire);
        if (failure != 0) {
            try stream.print("Remote refresh failed: {s}; showing the last confirmed view", .{@errorName(@errorFromInt(failure))});
        } else if (self.current) |publication| {
            const value = publication.value;
            if (value.omitted != 0 or value.debugger_omitted != 0) {
                try stream.writeAll("View limit; unavailable:");
                inline for (@typeInfo(boundary.Presentation).@"struct".fields, 0..) |field, index| {
                    if (value.omitted & (@as(u64, 1) << index) != 0) try stream.print(" {s}", .{field.name});
                }
                inline for (@typeInfo(@TypeOf(self.display)).@"struct".fields, 0..) |field, index| {
                    if (value.debugger_omitted & (@as(u32, 1) << index) != 0) try stream.print(" {s}", .{field.name});
                }
            } else if (value.status == .failed or value.status == .disconnected) {
                try stream.print("Remote view {s}: {s}", .{ @tagName(value.status), value.diagnostic });
            } else if (value.status == .pending) {
                try stream.writeAll("Remote view pending; preparation is incomplete");
            }
        }
        const message = stream.buffered();
        if (message.len == 0) return;
        const style = @import("style.zig");
        const width: f32 = @floatFromInt(window.width);
        const height: f32 = @floatFromInt(window.height);
        r.clip = .{ .x = 0, .y = 0, .w = width, .h = height };
        try r.rect(.{ .x = 0, .y = height - 52, .w = width, .h = 24 }, style.theme.header);
        try r.textFit(font, 12, height - 49, @max(0, width - 24), message, style.theme.text);
    }
};

fn editorSignature(editor_: *const @import("watch.zig").Editor) u64 {
    var hash = std.hash.Wyhash.init(editor_.epoch);
    std.hash.autoHash(&hash, editor_.open);
    hash.update(editor_.text.slice());
    return hash.final();
}
// Requests include viewport coordinates. Hash floats by representation and
// slices by content; addresses and padding must not turn an unchanged viewport
// into another remote inspection on every frame.
fn hashValue(hash: *std.hash.Wyhash, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .float => std.hash.autoHash(hash, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(value))), @bitCast(value))),
        .pointer => {
            std.hash.autoHash(hash, value.len);
            for (value) |item| hashValue(hash, item);
        },
        .optional => {
            std.hash.autoHash(hash, value != null);
            if (value) |item| hashValue(hash, item);
        },
        .@"struct" => |structure| inline for (structure.fields) |field| hashValue(hash, @field(value, field.name)),
        .@"union" => {
            std.hash.autoHash(hash, std.meta.activeTag(value));
            switch (value) {
                inline else => |item| hashValue(hash, item),
            }
        },
        .array => for (value) |item| hashValue(hash, item),
        else => std.hash.autoHash(hash, value),
    }
}
