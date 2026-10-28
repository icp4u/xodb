const std = @import("std");
const log = @import("../log.zig");
const c = @import("../c_ui.zig").api;
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Window = @import("../platform/window.zig").Window;
const model = @import("../model/session.zig");
const Session = model.Session;
const linux = @import("../target/linux.zig");
const disasm = @import("../model/disassembly.zig");
const debugger_view = @import("../model/debugger_view.zig");
const keys = @import("../platform/input.zig");
const style = @import("style.zig");
const theme = style.theme;
const FlameView = @import("flame.zig").FlameView;
const FlowView = @import("flow.zig").FlowView;
const timeline = @import("timeline.zig");
const capture_setup = @import("capture_setup.zig");
const sample_inspector = @import("sample_inspector.zig");
const capture_panel = @import("capture_panel.zig");
const watch_ui = @import("watch.zig");
const native_watches = @import("../model/native_watches.zig");
const info = @import("../debug/info.zig");
const profile = @import("../profile/capture.zig");
const look = @import("../look.zig");
const layout_snapshot = @import("../layout_snapshot.zig");
const buttons = look.actions;
fn gpuRect(b: look.Rect) gpu.Rect {
    return .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h };
}
const tab_width = 4;
/// In the profile view, flames take the body above this fraction of the height
/// and the timeline the row below it.
const profile_split = 0.64;

/// A source line that was not found is only as good as the search: say so
/// when images were left unread for a budget.
fn lineStatus(session: *const Session, err: anyerror) []const u8 {
    if (err == error.NoCodeForSourceLine and session.modules.skipped().count != 0) return "NoCodeForSourceLine in the images searched; some are over the image budget (Modules lists them)";
    return @errorName(err);
}
pub const Workspace = struct {
    density: look.Density = .auto,
    compact: bool = false,
    layout: look.Layout = .{},
    layout_key: ?struct { width: u32, height: u32, split: f32, compact: bool, pinned: ?look.Pane, watch: bool, named_threads: bool } = null,
    pinned_pane: ?look.Pane = null,
    more_open: bool = false,
    value_hover: ?usize = null,
    layout_report: layout_snapshot.Snapshot = .{},

    shared_clients: ?usize = null,
    shared_controller: ?u64 = null,
    /// Owner loop consumes this even when several toggles restore the old scope.
    shared_scope_changed: bool = false,
    imported: @import("imported.zig").View = .{},
    logical_frames: @import("frames.zig").View = .{},
    source: []const u8 = "",
    source_path: []const u8 = "No source file selected",
    source_line: i32 = 0,
    source_lines: i32 = 0,
    source_truncated: bool = false,
    source_remote: bool = false,
    current_line: ?u32 = null,
    cursor_line: ?u32 = null,
    was_running_to: bool = false,
    probes_panel: @import("probes.zig").Panel = .{},
    probe_capture: @import("../model/probe_view.zig").Capture = .{},
    stop_panel: @import("stop.zig").Panel = .{},
    stop_capture: @import("../model/stop_view.zig").Capture = .{},
    stop_view: @import("../model/stop_view.zig").View = .{},
    process_panel: @import("processes.zig").Panel = .{},
    redot_panel: @import("redot.zig").Panel = .{},
    process_capture: @import("../model/process_view.zig").Capture = .{},
    allocation_panel: @import("allocations.zig").Panel = .{},
    allocation_capture: @import("../model/allocation_view.zig").Capture = .{},
    allocation_save_key: ?@import("../profile/allocation_capture.zig").Key = null,
    allocation_save_editor: watch_ui.Editor = .{},
    allocation_archive_seen: bool = false,
    syscall_panel: @import("syscalls.zig").Panel = .{},
    syscall_capture: @import("../model/syscall_view.zig").Capture = .{},
    inline_panel: @import("inline.zig").Panel = .{},
    inline_capture: @import("../model/inline_view.zig").Capture = .{},
    /// Static slice/control answers (S); see src/semq/host.zig.
    static_panel: @import("static_analysis.zig").Panel = .{},
    /// The assembly row last clicked, and whether S should use the source
    /// cursor line instead (the most recent selection wins).
    assembly_cursor: ?u64 = null,
    static_from_line: bool = false,
    static_traced: u64 = 0,
    assembly_rows: struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, count: usize = 0 } = .{},
    inspection_panel: @import("inspection.zig").Panel = .{},
    runtime_type_panel: @import("runtime_types.zig").Panel = .{},
    thread_list: @import("thread_list.zig").Panel = .{},
    compatibility_info: @import("../model/compatibility.zig").Info = .{ .kind = .unavailable },
    thread_labels: []const @import("../model/compatibility.zig").Label = &.{},
    inspection_capture: @import("../model/inspection_view.zig").Capture = .{},
    selected_frame: usize = 0,
    last_frame: usize = std.math.maxInt(usize),
    frames: []const model.Frame = &.{},
    locals: []const LocalRow = &.{},
    local_diagnostic: ?[]const u8 = null,
    breakpoint_lines: []const u32 = &.{},
    language_panel: @import("language_tabs.zig").Panel = .{},
    show_flow: bool = false,
    show_profile: bool = false,
    flame: FlameView = .{},
    profile_capture: @import("../model/profile_view.zig").Capture = .{},
    inspector: sample_inspector.Inspector = .{},
    sample_capture: @import("../model/sample_view.zig").Capture = .{},
    /// Next-capture setup (S): the session defaults plus this thread choice.
    /// The selection is GUI state for the next capture and is never saved.
    setup: capture_panel.Panel = .{},
    thread_selection: capture_setup.Selection = .{},
    capture_control: @import("../model/capture_view.zig").Capture = .{},
    capture_view: @import("../model/capture_view.zig").View = .{},
    timeline: timeline.TimelineView = .{},
    timeline_capture: @import("../model/profile_timeline.zig").Capture = .{},
    last_show_flow: bool = false,
    flow: FlowView = .{},
    browse_address: ?u64 = null,
    browse_assembly: ?u64 = null,
    last_browse: ?u64 = null,
    selected_local: usize = 0,
    /// Expression field (E) and watch list, shown in place of EVENTS (V).
    editor: watch_ui.Editor = .{},
    watch: native_watches.WatchList = .{},
    watch_panel: watch_ui.Panel = .{},
    watch_view: native_watches.View = .{},
    runtime_watch_panel: @import("language_watches.zig").Panel = .{},
    runtime_watch_capture: @import("../model/runtime_watch_view.zig").Capture = .{},
    runtime_watch_view: @import("../model/runtime_watch_view.zig").View = .{},
    show_watch: bool = false,
    /// Up/Down, Delete, Return, PgUp/PgDn and W act on the watch list.
    watch_focus: bool = false,
    watch_rect: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    watch_hits: [64]?usize = @splat(null),
    prepared: debugger_view.Capture = .{},
    source_revision: u64 = 0,
    presented: ?struct { generation: u64, tid: i32, frame: usize, browse: ?u64, source_revision: u64 } = null,
    presentation_status: [256]u8 = undefined,
    selected: usize = 0,
    split: f32 = 0.48,
    dragging: bool = false,
    reported_dropped: u64 = 0,
    reported_keymap_errors: u64 = 0,
    status: []const u8 = "Ready",
    fd_event_state: @import("../model/system.zig").FdEventState = .inactive,
    allocation_busy: bool = false,
    allocation_collecting: bool = false,
    last_generation: u64 = std.math.maxInt(u64),
    last_metadata_revision: u64 = 0,
    last_language_revision: u64 = 0,
    last_tid: i32 = 0,
    regs: ?linux.Registers = null,
    instructions: [32]disasm.Instruction = undefined,
    instruction_count: usize = 0,
    /// Set when disassembly failed while the target was stopped. Null means
    /// the pane is empty because there is nothing to show yet.
    assembly_error: ?[]const u8 = null,
    hot: [buttons.len]f32 = @splat(0),
    pressed: [buttons.len]f32 = @splat(0),
    hovered: ?usize = null,
    hover_line: ?u32 = null,
    divider_hot: bool = false,
    alive: f32 = 1, // thread-line entrance, restarted at each stop
    bar: gpu.Color = (@import("../appearance.zig").Colors{}).header,
    stale_regs: ?linux.Registers = null, // the same thread's registers at its previous stop
    last_draw: u64 = 0,
    animating: bool = false,
    comparison: @import("comparison.zig").Panel = .{},
    invocations: @import("invocations.zig").View = .{},

    const LocalRow = debugger_view.LocalRow;
    pub fn deinit(self: *Workspace) void {
        self.redot_panel.deinit();
        self.language_panel.deinit();
        self.runtime_type_panel.deinit();
        self.logical_frames.deinit();
        self.flame.deinit();
        self.profile_capture.deinit();
        self.timeline_capture.deinit();
        self.syscall_capture.deinit();
        self.sample_capture.deinit();
        self.allocation_panel.deinit();
        self.allocation_capture.deinit();
        self.invocations.deinit();
        self.watch.deinit();
        self.stop_capture.deinit();
        self.inline_capture.deinit();
        self.process_capture.deinit();
        self.probe_capture.deinit();
        self.inspection_capture.deinit();
        self.runtime_watch_capture.deinit();
        self.prepared.deinit();
        self.static_panel.deinit();
    }
    pub fn updateLayout(self: *Workspace, w: *const Window) void {
        self.compact = look.compactFor(self.density, @floatFromInt(w.width), self.compact);
        const named_threads = self.thread_labels.len > 0 and self.thread_labels[0].source == .gdb_thread_info;
        const pinned: ?look.Pane = if (self.editor.open) .events else if (self.language_panel.editor.open) .registers else self.pinned_pane;
        const key: @typeInfo(@TypeOf(self.layout_key)).optional.child = .{ .width = w.width, .height = w.height, .split = self.split, .compact = self.compact, .pinned = pinned, .watch = self.show_watch, .named_threads = named_threads };
        if (self.layout_key) |old| if (std.meta.eql(old, key)) return;
        self.layout = look.Layout.compute(@floatFromInt(w.width), @floatFromInt(w.height), self.split, self.compact, pinned, self.show_watch);
        if (named_threads) self.layout.threadFraction(0.48);
        self.layout_key = key;
    }
    fn menuRect(self: *const Workspace, index: usize, width: f32) look.Rect {
        var row: usize = 0;
        for (self.layout.toolbar[0..index]) |b| if (b.w == 0) {
            row += 1;
        };
        return .{ .x = width - look.overflow.width - look.overflow.margin, .y = look.overflow.top + @as(f32, @floatFromInt(row)) * look.overflow.row, .w = look.overflow.width, .h = look.overflow.height };
    }
    fn rowStep(self: *const Workspace) f32 {
        return if (self.compact) look.compact.row else look.normal.row;
    }
    pub fn loadSource(self: *Workspace, path: []const u8) !void {
        try self.prepared.source.load(path);
        self.presentSource(self.prepared.source.value);
    }
    fn presentSource(self: *Workspace, source: debugger_view.Source) void {
        if (self.source_revision != source.revision) self.cursor_line = null;
        self.source_revision = source.revision;
        self.source = source.bytes;
        self.source_path = source.path;
        self.source_lines = source.lines;
        self.source_truncated = source.truncated;
        self.source_remote = source.remote;
    }
    /// The key bindings, as the evdev codes `step` tests for. A key is matched by
    /// its logical identity, and never with Ctrl, Alt, or Logo held. Only
    /// navigation repeats while a key is held; execution control, detach, watch,
    /// graph, agent scope, and quit act once per press.
    fn binding(event: keys.Event) u32 {
        if (!event.plain()) return 0;
        const code: u32 = switch (event.shortcut) {
            keys.sym.space => 57,
            0xffc1 => 62, // F4 restart owned launch
            keys.sym.f5 => 63,
            keys.sym.f6 => 64,
            keys.sym.f8 => 66,
            keys.sym.f10 => 68,
            keys.sym.f11 => 87,
            0xffc6 => 67, // F9 run to source cursor
            0xffc9 => 88, // F12 finish selected frame
            keys.sym.tab => 15,
            keys.sym.escape => 1,
            keys.sym.up => 103,
            keys.sym.down => 108,
            'a' => 30,
            'w' => 17,
            'd' => if (event.mods.shift) 32 else 49,
            'g' => 34,
            'h' => 35,
            'p' => 25,
            't' => 20,
            's' => 31,
            'f' => 33,
            'z' => 44,
            'x' => 45,
            0xff0d => 28, // Return
            0xff08 => 14, // BackSpace
            'j' => 36,
            'k' => if (event.mods.shift) 38 else 37,
            'q' => if (event.mods.shift) 16 else 0,
            'b' => if (event.mods.shift) 39 else 48,
            'm' => 50,
            'y' => 21,
            'r' => 19,
            'i' => 23,
            'c' => 46,
            'o' => 24,
            '[' => 26,
            ']' => 27,
            'e' => 18,
            'v' => 47,
            0xffff => 111, // Delete
            0xff55 => 104, // Page Up
            0xff56 => 109, // Page Down
            else => 0,
        };
        const navigation = code == 36 or code == 37 or code == 103 or code == 108;
        return if (event.kind == .repeat and !navigation) 0 else code;
    }
    fn toggleAgentScope(self: *Workspace, session: *Session) void {
        session.setAgentScope(if (session.agent_scope == .observe) .control else .observe);
        self.status = if (session.agent_scope == .observe) "Agent control revoked" else "Agent control enabled";
        if (self.shared_clients != null) {
            self.shared_scope_changed = true;
            self.shared_controller = null;
        }
    }
    fn sharedScopeInput(self: *Workspace, w: *Window, session: *Session) void {
        if (self.shared_clients == null or w.closing) return;
        // Scope control belongs to the human even while a delegated view or
        // text editor owns ordinary input. The queue is bounded to 64 events.
        for (0..w.input.count) |offset| {
            const event = &w.input.queue[(w.input.head + offset) % keys.capacity];
            if (event.kind != .press or !event.plain() or event.shortcut != keys.sym.f8) continue;
            self.toggleAgentScope(session);
            w.dirty = true;
            // No text/key action can replay this press in a delegated handler.
            event.* = .{ .kind = .release };
        }
    }
    pub fn activeEditor(self: *Workspace, context: anytype) ?*watch_ui.Editor {
        if (self.redot_panel.open) return null;
        const remote = @TypeOf(context) != *Session;
        const session = if (remote) {} else context;
        if (remote) self.language_panel.syncEditorView(context.language) else self.language_panel.syncEditor(session);
        if (self.logical_frames.open or (if (remote) false else (session.comparison != null and self.comparison.open) or session.imported != null)) return null;
        if (self.invocations.open) return if (self.invocations.editor.open) &self.invocations.editor else null;
        if ((if (remote) true else session.process_tree != null) and self.process_panel.open) return null;
        if (self.allocation_save_editor.open) return &self.allocation_save_editor;
        if (self.allocation_panel.open or self.syscall_panel.open or self.stop_panel.open or self.static_panel.open) return null;
        if (self.inline_panel.open) return if (self.inline_panel.editor.open) &self.inline_panel.editor else null;
        if (self.runtime_type_panel.open) return if (self.runtime_type_panel.editor.open) &self.runtime_type_panel.editor else null;
        if (self.inspection_panel.open) return if (self.inspection_panel.editor.open) &self.inspection_panel.editor else null;
        if (self.probes_panel.open) return if (self.probes_panel.editor.open) &self.probes_panel.editor else null;
        if (self.language_panel.editor.open) return &self.language_panel.editor;
        if (self.editor.open) return &self.editor;
        if (self.show_profile and self.setup.open and self.setup.editor.open) return &self.setup.editor;
        return null;
    }
    pub fn clipboardFocus(self: *Workspace, w: *Window, context: anytype) void {
        watch_ui.Editor.focus(w, self.activeEditor(context));
        self.setup.syncEditor();
    }
    /// Applies the queued key and button events one at a time, in order, then the
    /// pointer state. A click is handled at the position where it happened.
    pub fn input(self: *Workspace, w: *Window, context: anytype) void {
        self.updateLayout(w);
        const remote = @TypeOf(context) != *Session;
        const session = if (remote) {} else context;
        const language = if (remote) context.language else @import("../model/language_view.zig").header(session);
        if (remote) context.scopeInput(self, w) else self.sharedScopeInput(w, session);
        self.clipboardFocus(w, context);
        defer self.clipboardFocus(w, context);
        if (!remote and self.redot_panel.open) return self.redot_panel.input(w, &session.redot);
        if (self.logical_frames.open) {
            if (remote) {
                if (self.logical_frames.inputPrepared(w)) |action| context.send(self, .{ .logical_frames = action });
            } else self.logical_frames.input(w, &session.frames);
            return;
        }
        if (!remote) if (session.comparison) |job| if (self.comparison.open) return self.comparison.input(w, job);
        if (self.invocations.open) {
            if (remote) {
                if (self.invocations.inputPrepared(w)) |action| context.send(self, .{ .invocation = action });
            } else self.invocations.input(w, session);
            if (!self.invocations.open) self.status = "Invocation browser closed; N reopens it";
            return;
        }
        if (!remote) if (session.imported) |*state| return self.imported.input(w, state);
        const pointer = [2]f32{ w.pointer_x, w.pointer_y };
        const down = w.mouse_down;
        defer {
            w.pointer_x = pointer[0];
            w.pointer_y = pointer[1];
            w.mouse_down = down;
        }
        var scroll = w.scroll;
        const decompile_rows = self.static_panel.decompile_rows;
        if (self.static_panel.decompile_open and scroll != 0 and decompile_rows.count > 0 and
            w.pointer_x >= decompile_rows.x and w.pointer_x < decompile_rows.x + decompile_rows.w and
            w.pointer_y >= decompile_rows.y - 2 and w.pointer_y < decompile_rows.y - 2 + @as(f32, @floatFromInt(decompile_rows.count)) * look.workspace.code_row)
        {
            self.static_panel.wheelDecompile(scroll);
            scroll = 0;
            w.dirty = true;
        }
        if (self.process_panel.open and scroll != 0 and (if (remote) true else session.process_tree != null)) {
            self.process_panel.wheel(scroll);
            scroll = 0;
            w.dirty = true;
        }
        if (self.allocation_panel.open and scroll != 0) {
            self.allocation_panel.wheel(scroll);
            scroll = 0;
            w.dirty = true;
        }
        if (self.syscall_panel.open and scroll != 0) {
            self.syscall_panel.wheel(scroll);
            scroll = 0;
            w.dirty = true;
        }
        if (self.static_panel.open and scroll != 0) {
            self.static_panel.wheel(scroll);
            scroll = 0;
            w.dirty = true;
        }
        if (self.inline_panel.open and scroll != 0) {
            self.inline_panel.wheel(scroll);
            scroll = 0;
            w.dirty = true;
        }
        if (self.runtime_type_panel.open and scroll != 0) {
            if (remote) context.runtimeTypeInput(self, self.runtime_type_panel.wheelPrepared(scroll)) else self.runtime_type_panel.wheel(session, scroll);
            scroll = 0;
            w.dirty = true;
        }
        if (self.inspection_panel.open and scroll != 0) {
            self.inspection_panel.wheel(scroll);
            scroll = 0;
            w.dirty = true;
        }
        if (self.probes_panel.open and scroll != 0) {
            self.probes_panel.wheel(scroll);
            scroll = 0;
            w.dirty = true;
        }
        w.scroll = 0; // motion/wheel state is coalesced; apply it after queued edges
        // Over the open setup panel the wheel scrolls its list, nothing else.
        if (self.show_profile and self.setup.containsPoint(pointer[0], pointer[1]) and scroll != 0) {
            _ = self.setup.wheel(pointer[0], pointer[1], scroll);
            scroll = 0;
            w.dirty = true;
        }
        w.mouse_down = self.dragging or down; // replay a pending drag release in order
        while (w.input.next()) |event| {
            if (w.closing) break;
            self.clipboardFocus(w, context);
            if (self.activeEditor(context)) |editor| if (editor.clipboard(w, event)) continue;
            switch (event.kind) {
                .press, .repeat => {
                    if (self.activeEditor(context) == null and event.kind == .press and event.mods.alt and event.shortcut >= '1' and event.shortcut <= '6') {
                        const p: look.Pane = @enumFromInt(event.shortcut - '1');
                        self.pinned_pane = if (self.pinned_pane == p) null else p;
                        self.updateLayout(w);
                        w.dirty = true;
                        continue;
                    }
                    if (self.activeEditor(context) == null and event.kind == .press and event.mods.ctrl and event.mods.shift and event.shortcut == 'd') {
                        self.density = switch (self.density) {
                            .auto => .normal,
                            .normal => .compact,
                            .compact => .auto,
                        };
                        self.status = switch (self.density) {
                            .auto => "Density: auto",
                            .normal => "Density: normal",
                            .compact => "Density: compact",
                        };
                        self.updateLayout(w);
                        w.dirty = true;
                        continue;
                    }
                    if (!remote and self.activeEditor(context) == null and session.comparison != null and event.plain() and event.kind == .press and event.shortcut == 'v') {
                        self.comparison.open = true;
                        w.dirty = true;
                        continue;
                    }
                    if (self.activeEditor(context) == null and (if (remote) context.header.observation_available else session.observations.capture != null or session.observation_archive != null) and event.plain() and event.kind == .press and event.shortcut == 'n') {
                        self.invocations.open = true;
                        w.dirty = true;
                        // Later queued input belongs to the browser.
                        return self.input(w, context);
                    }
                    if (remote) {
                        if (context.processInput(self, self.process_panel.keyView(event))) {
                            w.dirty = true;
                            continue;
                        }
                    } else if (session.process_tree) |tree| if (self.process_panel.key(tree, event)) {
                        w.dirty = true;
                        if (tree.active() != session) return;
                        continue;
                    };
                    if (self.allocation_save_editor.open) {
                        if (self.allocation_save_editor.key(event)) |action| switch (action) {
                            .submit => |path| {
                                const identity = self.allocation_save_key orelse {
                                    self.allocation_save_editor.message = "NoAllocationCapture";
                                    continue;
                                };
                                if (remote) {
                                    context.send(self, .{ .allocation = .{ .save = .{ .key = identity, .path = path } } });
                                    continue;
                                }
                                @import("../model/allocation_view.zig").apply(session, .{ .save = .{ .key = identity, .path = path } }, .human) catch |err| {
                                    self.allocation_save_editor.message = @errorName(err);
                                    w.dirty = true;
                                    continue;
                                };
                                self.allocation_save_editor.open = false;
                            },
                            else => {},
                        };
                        w.dirty = true;
                        continue;
                    }
                    if (self.allocation_panel.open and event.plain() and event.kind == .press and event.shortcut == 's') {
                        self.allocation_save_key = self.allocation_panel.key_;
                        self.allocation_save_editor.start();
                        w.dirty = true;
                        continue;
                    }
                    const threads = if (remote) context.display.threads else session.target.threadSlice();
                    const inspect_tid = if (threads.len > 0) threads[@min(self.selected, threads.len - 1)].tid else 0;
                    if (self.allocation_panel.open and event.plain() and event.kind == .press and event.shortcut == 'p') {
                        self.toggleAllocations(context, @floatFromInt(w.height));
                        w.dirty = true;
                        continue;
                    }
                    const allocation_input = self.allocation_panel.key(event);
                    if (allocation_input != .unhandled) {
                        if (remote) {
                            if (allocation_input == .owner) context.send(self, .{ .allocation = allocation_input.owner });
                        } else if (allocation_input == .owner) @import("../model/allocation_view.zig").apply(session, allocation_input.owner, .human) catch |err| {
                            self.allocation_panel.message = @errorName(err);
                        };
                        w.dirty = true;
                        continue;
                    }
                    if (self.syscall_panel.key(event)) {
                        w.dirty = true;
                        continue;
                    }
                    if (self.stop_panel.key(event)) {
                        w.dirty = true;
                        continue;
                    }
                    if (remote) {
                        if (context.paneKey(self, inspect_tid, event, w)) {
                            w.dirty = true;
                            continue;
                        }
                    } else {
                        if (self.static_panel.key(session, event)) {
                            self.traceStatic(w);
                            self.followStatic(w);
                            w.dirty = true;
                            continue;
                        }
                        if (self.inline_panel.key(session, inspect_tid, self.selected_frame, event)) {
                            w.dirty = true;
                            continue;
                        }
                        if (self.runtime_type_panel.key(session, event)) {
                            w.dirty = true;
                            continue;
                        }
                        if (self.inspection_panel.key(session, inspect_tid, self.selected_frame, event)) {
                            w.dirty = true;
                            continue;
                        }
                        if (self.probes_panel.key(session, event)) {
                            w.dirty = true;
                            continue;
                        }
                    }
                    if (self.editor.open) {
                        if (self.editor.key(event)) |action| {
                            self.applyEditor(context, action);
                            w.dirty = true;
                            continue;
                        }
                    }
                    if (@intFromEnum(language.selected) < 2 and !self.show_profile and self.show_watch and self.watch_focus and event.kind == .press and event.plain() and event.mods.shift and event.shortcut == 'l') {
                        self.toggleWatchMode(context);
                        w.dirty = true;
                        continue;
                    }
                    if (self.show_profile and self.setup.open) {
                        const capture_snapshot = if (remote) self.capture_view.snapshot else self.capture_control.rows.snapshot(session);
                        if (self.setup.key(event, &capture_snapshot, .{})) |action| {
                            self.applySetup(w, context, action);
                            continue;
                        }
                    }
                    if (event.kind == .press and event.plain() and event.shortcut == 'l' and (if (remote) context.header.logical_frames_available else session.frames.count > 0 or session.frames.job != null or session.frames.attachment.failure != null)) {
                        self.logical_frames.open = true;
                        w.dirty = true;
                        return self.input(w, context);
                    }
                    if (self.language_panel.editor.open) {
                        if (self.language_panel.editor.key(event)) |action| switch (action) {
                            .submit => |text| {
                                const watching = self.language_panel.editor_watch;
                                (if (remote) context.submitLanguage(self, text) else self.language_panel.submitExpression(session, text)) catch |err| {
                                    self.language_panel.editor.message = @import("language_tabs.zig").watchError(err);
                                    continue;
                                };
                                if (watching) {
                                    self.show_watch = true;
                                    self.watch_focus = false;
                                    self.status = "Runtime watch added; compares when the process stops";
                                }
                            },
                            else => {},
                        };
                        w.dirty = true;
                        continue;
                    }
                    const code = binding(event);
                    if (!remote and event.kind == .press and event.plain() and event.shortcut == 'u') {
                        if (session.redot.state == .off) {
                            self.status = "Scene inspector requires --redot-debugger";
                            w.dirty = true;
                            continue;
                        }
                        self.redot_panel.show(&session.redot);
                        w.dirty = true;
                        return self.input(w, context);
                    }
                    if (code == 0) continue;
                    self.step(w, context, false, code);
                    if (code == 18 and self.language_panel.editor.open) self.language_panel.editor_watch = event.mods.shift;
                    if (code == 18 and self.editor.open) self.editor.mode = if (event.mods.shift) .live else .pinned;
                },
                .button_press, .button_release => {
                    if (event.code != 272) continue;
                    if (remote and self.process_panel.open) {
                        if (event.kind == .button_press) if (self.process_panel.pressView(event.x, event.y)) |intent| context.sendAt(self, intent.stamp, .{ .process = intent.operation });
                        w.dirty = true;
                        continue;
                    }
                    if (!remote and self.process_panel.open) if (session.process_tree) |tree| {
                        if (event.kind == .button_press) self.process_panel.press(tree, event.x, event.y);
                        w.dirty = true;
                        if (tree.active() != session) return;
                        continue;
                    };
                    if (self.allocation_panel.open) {
                        if (event.kind == .button_press) {
                            if (@import("allocations.zig").Panel.liveHit(@floatFromInt(w.width), event.x, event.y)) self.toggleAllocations(context, @floatFromInt(w.height)) else self.allocation_panel.press(event.x, event.y);
                        }
                        w.dirty = true;
                        continue;
                    }
                    if (self.syscall_panel.open) {
                        if (event.kind == .button_press) self.syscall_panel.press(event.x, event.y);
                        w.dirty = true;
                        continue;
                    }
                    if (self.stop_panel.open) {
                        if (event.kind == .button_press) self.stop_panel.press(event.x, event.y);
                        w.dirty = true;
                        continue;
                    }
                    if (self.static_panel.open) {
                        if (event.kind == .button_press) {
                            if (remote) self.static_panel.pressPrepared(event.x, event.y) else self.static_panel.press(session, event.x, event.y);
                            self.traceStatic(w);
                            self.followStatic(w);
                        }
                        w.dirty = true;
                        continue;
                    }
                    if (self.inline_panel.open) {
                        if (event.kind == .button_press) self.inline_panel.press(event.x, event.y);
                        w.dirty = true;
                        continue;
                    }
                    if (self.runtime_type_panel.open) {
                        if (event.kind == .button_press) {
                            if (remote) context.runtimeTypeInput(self, self.runtime_type_panel.pressPrepared(event.x, event.y)) else self.runtime_type_panel.press(session, event.x, event.y);
                        }
                        w.dirty = true;
                        continue;
                    }
                    if (self.inspection_panel.open) {
                        if (event.kind == .button_press) self.inspection_panel.press(event.x, event.y);
                        w.dirty = true;
                        continue;
                    }
                    if (self.probes_panel.open) {
                        if (event.kind == .button_press) self.probes_panel.press(event.x, event.y);
                        w.dirty = true;
                        continue;
                    }
                    w.pointer_x = event.x;
                    w.pointer_y = event.y;
                    w.mouse_down = event.kind == .button_press;
                    // Keep the event's Ctrl state; queued modifier changes may already
                    // have reached the keyboard by the time this batch is consumed.
                    if (event.kind == .button_press and self.show_profile and !self.setup.open and event.mods.ctrl and self.timeline.pressModified(event.x, event.y, true)) {
                        w.dirty = true;
                        continue;
                    }
                    // A timeline drag commits on release; motion only previews it.
                    if (event.kind == .button_release and self.show_profile and self.timeline.drag != null) {
                        if (self.timeline.release(event.x, event.y)) self.applyTimeline(context);
                        w.dirty = true;
                        continue;
                    }
                    // A complete drag may arrive between two display frames.
                    if (!w.mouse_down and self.dragging) self.split = std.math.clamp(event.x / @as(f32, @floatFromInt(w.width)), 0.30, 0.62);
                    self.step(w, context, w.mouse_down, 0);
                },
                else => continue,
            }
            // Later actions in the batch must use a newly selected frame/thread.
            // The first action still observes the normal stale-snapshot guard.
            if (!remote and !w.closing) self.refresh(session);
        }
        w.pointer_x = pointer[0];
        w.pointer_y = pointer[1];
        w.mouse_down = down;
        w.scroll = scroll;
        if (w.closing) return;
        if (self.show_profile and self.timeline.motion(w.pointer_x, w.pointer_y)) w.dirty = true;
        self.step(w, context, false, 0);
        if (w.input.dropped != self.reported_dropped) {
            log.warn(.window, "Input queue dropped {d} events ({d} total)\n", .{ w.input.dropped - self.reported_dropped, w.input.dropped });
            self.reported_dropped = w.input.dropped;
            self.status = "Some input was dropped; try again";
            w.dirty = true;
        }
        if (w.input.keymap_errors != self.reported_keymap_errors) {
            log.warn(.window, "Input keymap errors: {d}\n", .{w.input.keymap_errors});
            self.reported_keymap_errors = w.input.keymap_errors;
            self.status = "Keyboard layout unavailable; mouse controls still work";
            w.dirty = true;
        }
        w.setCursor(if (self.divider_hot or self.dragging) .col_resize else .default);
    }
    /// S: the most recent selection (source line or assembly row), else the PC.
    /// A line keeps all its line-table rows and every function they fall in;
    /// the panel asks which function when there is more than one.
    fn openStatic(self: *Workspace, w: *Window, context: anytype) void {
        self.static_panel.hideDecompile();
        if (@TypeOf(context) != *Session) {
            if (self.static_from_line) if (self.cursor_line) |line| {
                const origin = @import("../model/static_view.zig").Origin.source(self.source_path, line) catch |err| {
                    self.status = @errorName(err);
                    return;
                };
                self.static_panel.showOrigin(origin);
                return;
            };
            const pc = self.assembly_cursor orelse (if (self.regs) |regs| linux.programCounter(regs) catch null else null) orelse {
                self.status = "Pause, or select an instruction or source line, for static analysis";
                return;
            };
            self.static_panel.showOrigin(.{ .pc = pc });
        } else {
            const session = context;
            if (self.static_from_line) if (self.cursor_line) |line| {
                var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch.deinit();
                const a = scratch.allocator();
                const addresses = session.sourceAddresses(a, self.source_path, line) catch &.{};
                if (addresses.len == 0) {
                    self.status = if (session.modules.skipped().count != 0) "No code at the selected line in the images searched; some are over the image budget (Modules lists them)" else "No code at the selected line for static analysis";
                    return;
                }
                var functions: std.ArrayList(@import("static_analysis.zig").Choice) = .empty;
                for (addresses) |address| {
                    const f = session.static_analysis.resolve(a, session, address) catch continue;
                    const entry = f.runtime(f.key.entry);
                    for (functions.items) |known| {
                        if (known.entry == entry) break;
                    } else functions.append(a, .{ .name = f.name, .entry = entry }) catch {};
                }
                if (functions.items.len == 0) {
                    self.status = "The selected line has no function bounds in the session's symbols";
                    return;
                }
                if (w.input.trace) {
                    log.info(.window, "static functions:", .{});
                    for (functions.items) |f| log.info(.window, " {s}", .{f.name});
                    log.info(.window, "\n", .{});
                }
                self.static_panel.show(.{ .line = .{ .path = self.source_path, .line = line, .addresses = addresses, .functions = functions.items } });
                return;
            };
            const pc = self.assembly_cursor orelse (if (self.regs) |regs| linux.programCounter(regs) catch null else null) orelse {
                self.status = "Pause, or select an instruction or source line, for static analysis";
                return;
            };
            self.static_panel.show(.{ .pc = pc });
        }
    }
    /// D: show the worker's retained pseudo-C for the function at the stopped
    /// PC (the selected instruction when nothing is stopped).  The analysis is the same cached artifact used by S and MCP.
    fn toggleDecompile(self: *Workspace) void {
        if (self.static_panel.decompile_open) {
            self.static_panel.hideDecompile();
            self.status = "Assembly pane restored";
            return;
        }
        const pc = (if (self.regs) |regs| linux.programCounter(regs) catch null else null) orelse self.assembly_cursor orelse {
            self.status = "Pause or select an instruction before opening pseudo-C";
            return;
        };
        self.show_flow = false;
        self.static_panel.showDecompile(.{ .pc = pc });
        self.pinned_pane = .assembly;
        self.status = "Preparing pseudo-C; D returns to assembly";
    }
    /// With XODB_INPUT_TRACE, each static answer is logged once for GUI tests.
    pub fn traceStatic(self: *Workspace, w: *Window) void {
        const panel = &self.static_panel;
        if (!w.input.trace or panel.answers == self.static_traced) return;
        self.static_traced = panel.answers;
        log.info(.window, "static answer: {s} | {s} | {s} | rows={d}\n", .{ panel.heading, panel.summary, panel.parameters, panel.rows.len });
        for (panel.rows) |row| log.info(.window, "static row: {s} 0x{x} {s}\n", .{ row.certainty, row.address orelse 0, row.label });
    }
    /// A chosen static citation browses the assembly and source to it.
    pub fn followStatic(self: *Workspace, w: *Window) void {
        const address = self.static_panel.navigate orelse return;
        if (w.input.trace) log.info(.window, "static navigate: 0x{x}\n", .{address});
        self.static_panel.navigate = null;
        self.browse_address = address;
        self.browse_assembly = address;
        self.assembly_cursor = address;
        self.static_from_line = false;
        self.status = "Static citation; S returns to the answer";
    }
    pub fn toggleAllocations(self: *Workspace, context: anytype, height: f32) void {
        if (@TypeOf(context) != *Session) {
            const view = self.allocation_panel.view;
            const stopping = view.preparing or view.collecting;
            if (!stopping and self.selected >= context.display.threads.len) {
                self.status = "Select a stopped thread before allocation capture";
                return;
            }
            const action: @import("../model/allocation_view.zig").Action = if (stopping) .{ .stop = .{ .identity = if (view.key) |key| key.identity else null, .serial = view.serial } } else .{ .start = .{ .tid = context.display.threads[self.selected].tid, .serial = view.serial } };
            context.send(self, .{ .allocation = action });
        } else {
            const session = context;
            const threads = session.target.threadSlice();
            const tid = if (threads.len > 0) threads[@min(self.selected, threads.len - 1)].tid else 0;
            self.allocation_capture.refresh(&session.allocations, self.allocation_panel.request(height), tid);
            self.allocation_panel.present(self.allocation_capture.value);
            const view = self.allocation_panel.view;
            const stopping = view.preparing or view.collecting;
            if (!stopping and self.selected >= session.target.snapshot().thread_count) {
                self.status = "Select a stopped thread before allocation capture";
                return;
            }
            const action: @import("../model/allocation_view.zig").Action = if (stopping)
                .{ .stop = .{ .identity = if (view.key) |key| key.identity else null, .serial = view.serial } }
            else
                .{ .start = .{ .tid = session.target.threadSlice()[self.selected].tid, .serial = view.serial } };
            @import("../model/allocation_view.zig").apply(session, action, .human) catch |err| {
                self.status = @errorName(err);
                return;
            };
            if (!stopping) self.allocation_busy = true;
            self.status = if (stopping) "Allocation capture stopping" else "Preparing allocation capture; keep target paused";
        }
    }
    pub fn step(self: *Workspace, w: *Window, context: anytype, press: bool, key: u32) void {
        const remote = @TypeOf(context) != *Session;
        const session = if (remote) {} else context;
        const snapshot = if (remote) context.display.snapshot else session.target.snapshot();
        const threads = if (remote) context.display.threads else session.target.threadSlice();
        const language = if (remote) context.language else @import("../model/language_view.zig").header(session);
        const offline = if (remote) false else session.offline;
        var click = press;
        if (key == 30) {
            self.syscall_panel.open = false;
            self.inline_panel.open = false;
            self.inspection_panel.open = false;
            self.stop_panel.open = false;
            self.probes_panel.open = false;
            self.allocation_panel.show();
            w.dirty = true;
            return;
        }
        if (self.show_profile and key == 45) {
            self.setup.open = false;
            self.inspector.open = false;
            self.syscall_panel.show();
            w.dirty = true;
            return;
        }
        if (self.show_profile and self.inspector.open) {
            if (key == 1 or key == 23) {
                self.inspector.open = false;
                w.dirty = true;
                return;
            }
            if (key == 26 or key == 27) {
                self.inspector.step(self.flame.selection.filter, if (key == 26) -1 else 1);
                w.dirty = true;
                return;
            }
            if (w.scroll != 0 or key == 103 or key == 108) {
                self.inspector.scrollBy(w.scroll + (if (key == 108) @as(i32, 1) else if (key == 103) @as(i32, -1) else 0));
                w.scroll = 0;
                w.dirty = true;
                return;
            }
            if (click and w.pointer_y >= self.inspector.bounds.y) return;
        }
        // The setup panel covers the profile view while open.
        if (self.show_profile and self.setup.open and click) {
            click = false;
            w.dirty = true;
            if (self.setup.press(w.pointer_x, w.pointer_y, w.input.mods().shift)) |action| return self.applySetup(w, context, action);
            if (!self.setup.containsPoint(w.pointer_x, w.pointer_y)) self.setup.open = false;
        }
        if (self.show_profile and (key == 38 or (click and self.flame.kernelHit(w.pointer_x, w.pointer_y)))) {
            self.flame.selection.filter.hide_kernel = !self.flame.selection.filter.hide_kernel;
            self.status = if (self.flame.selection.filter.hide_kernel) "Kernel frames hidden" else "Kernel frames shown";
            w.dirty = true;
            if (key == 38) return;
            click = false;
        }
        if (self.show_profile and (key == 39 or (click and self.flame.blockedHit(w.pointer_x, w.pointer_y)))) {
            if (self.flame.basis == .blocked) {
                self.flame.setBasis(.recorded);
                self.status = "Recorded kernel callchains";
            } else {
                self.flame.setBasis(.blocked);
                self.status = "Blocked time; B returns to recorded callchains";
            }
            w.dirty = true;
            if (key == 39) return;
            click = false;
        }
        if (self.show_profile and (key == 31 or (click and self.flame.setupHit(w.pointer_x, w.pointer_y)))) {
            self.setup.open = !self.setup.open;
            self.setup.editing = .none;
            w.dirty = true;
            click = false;
        }
        if (self.show_profile and !offline and (key == 20 or (click and self.flame.durationHit(w.pointer_x, w.pointer_y)))) {
            if (remote) {
                var defaults = self.capture_view.defaults;
                @import("flame.zig").FlameView.cycleDuration(&defaults);
                context.send(self, .{ .capture_control = .{ .defaults = defaults } });
            } else {
                @import("flame.zig").FlameView.cycleDuration(&session.profile_defaults);
                self.status = if (session.profile_defaults.duration_ms == 0) "Next capture: until stopped; resource and scope limits still apply" else "Next capture duration changed";
            }
            w.dirty = true;
            click = false;
        }
        if (self.show_profile and click and self.timeline.press(w.pointer_x, w.pointer_y)) {
            click = false;
            w.dirty = true;
        }
        if (!self.show_profile and self.layout.visible(.source) and self.layout.visible(.assembly) and click and @abs(w.pointer_x - self.layout.left) < 7 and w.pointer_y > 90) self.dragging = true;
        if (!w.mouse_down) self.dragging = false;
        if (self.dragging) {
            self.split = std.math.clamp(w.pointer_x / @as(f32, @floatFromInt(w.width)), 0.30, 0.62);
            self.updateLayout(w);
        }
        var code = key;
        var value_hover: ?usize = null;
        for (self.layout_report.rows[0..self.layout_report.row_count], 0..) |row, i| if (row.value_elided and row.rect.contains(w.pointer_x, w.pointer_y)) {
            value_hover = i;
            break;
        };
        if (value_hover != self.value_hover) w.dirty = true;
        self.value_hover = value_hover;
        if (click and !self.show_profile) for (self.layout.tabs, 0..) |b, i| {
            if (b.contains(w.pointer_x, w.pointer_y)) {
                self.pinned_pane = @enumFromInt(i);
                self.updateLayout(w);
                w.dirty = true;
                return;
            }
        };
        if (click and self.layout.more.contains(w.pointer_x, w.pointer_y)) {
            self.more_open = !self.more_open;
            w.dirty = true;
            return;
        }
        if (self.more_open) {
            if (key == 1) {
                self.more_open = false;
                w.dirty = true;
                return;
            }
            if (click) {
                for (self.layout.toolbar, 0..) |b, i| if (b.w == 0 and self.menuRect(i, @floatFromInt(w.width)).contains(w.pointer_x, w.pointer_y)) {
                    code = buttons[i].code;
                };
                self.more_open = false;
                w.dirty = true;
                if (code == 0) return;
                click = false;
            }
        }
        // Hover targets: a change needs one redraw, after which the animation keeps itself going.
        var hovered: ?usize = null;
        if (w.pointer_y >= 44 and w.pointer_y < 84) for (self.layout.toolbar, 0..) |b, i| {
            if (b.contains(w.pointer_x, w.pointer_y)) hovered = i;
        };
        const gutter_row = (w.pointer_y - look.workspace.source_y) / look.workspace.code_row;
        const hover_line: ?u32 = if (!self.show_profile and self.layout.visible(.source) and w.pointer_x > 10 and w.pointer_x < 74 and gutter_row >= 0 and w.pointer_y < self.bottomY(@floatFromInt(w.height)) - 10) @intCast(self.source_line + @as(i32, @intFromFloat(gutter_row)) + 1) else null;
        const divider_hot = !self.show_profile and self.layout.visible(.source) and self.layout.visible(.assembly) and @abs(w.pointer_x - self.layout.left) < 7 and w.pointer_y > 90;
        if (hovered != self.hovered or hover_line != self.hover_line or divider_hot != self.divider_hot) w.dirty = true;
        self.hovered = hovered;
        self.hover_line = hover_line;
        self.divider_hot = divider_hot;
        if (click) if (hovered) |i| {
            code = buttons[i].code;
            self.pressed[i] = 1;
        };
        if (click and self.layout.flames.contains(w.pointer_x, w.pointer_y)) code = 33;
        if (code == 62 and !self.show_profile) {
            if (remote) context.send(self, .{ .control = .restart }) else {
                _ = session.humanCommand(std.heap.page_allocator, self.last_generation, .{ .control = .restart }) catch |err| {
                    self.status = @errorName(err);
                    w.dirty = true;
                    return;
                };
            }
            self.status = "Restarted owned launch; watches cleared, breakpoints relocated";
            self.selected = 0;
            self.selected_frame = 0;
            w.dirty = true;
            return;
        }
        if (code == 21 and !self.show_profile) {
            self.probes_panel.open = false;
            self.inspection_panel.open = false;
            self.inline_panel.open = false;
            self.stop_panel.open = false;
            self.allocation_panel.open = false;
            self.syscall_panel.open = false;
            self.static_panel.open = false;
            self.runtime_type_panel.show();
            w.dirty = true;
            return;
        }
        if (code == 46 and !self.show_profile) {
            self.probes_panel.open = false;
            self.inspection_panel.open = false;
            self.inline_panel.open = false;
            self.static_panel.open = false;
            self.stop_panel.open = true;
            w.dirty = true;
            return;
        }
        if (code == 31 and !self.show_profile) {
            self.stop_panel.open = false;
            self.probes_panel.open = false;
            self.inspection_panel.open = false;
            self.inline_panel.open = false;
            self.openStatic(w, context);
            w.dirty = true;
            return;
        }
        if (code == 49 and !self.show_profile) {
            self.static_panel.open = false;
            self.toggleDecompile();
            w.dirty = true;
            return;
        }
        if ((code == 26 or code == 27) and self.static_panel.decompile_open and !self.show_profile) {
            self.static_panel.scrollDecompile(if (code == 26) -8 else 8);
            self.status = "Pseudo-C horizontal scroll";
            w.dirty = true;
            return;
        }
        if (code == 23 and !self.show_profile) {
            self.stop_panel.open = false;
            self.probes_panel.open = false;
            self.inspection_panel.open = false;
            self.static_panel.open = false;
            self.inline_panel.show();
            w.dirty = true;
            return;
        }
        if ((code == 50 or code == 19) and !self.show_profile) {
            self.stop_panel.open = false;
            const fallback_sp = if (self.regs) |regs| linux.stackPointer(regs) catch {
                self.status = "RegisterUnavailable";
                return;
            } else 0;
            const address = if (self.selected_local < self.locals.len) self.locals[self.selected_local].value.address orelse fallback_sp else fallback_sp;
            self.probes_panel.open = false;
            self.inspection_panel.show(code == 19, address);
            w.dirty = true;
            return;
        }
        if (code == 48 and !self.show_profile) {
            self.probes_panel.open = !self.probes_panel.open;
            if (!remote) {
                self.probe_capture.refresh(session, self.probes_panel.open);
                self.probes_panel.present(self.probe_capture.value);
            }
            w.dirty = true;
            return;
        }
        if (code == 33) {
            self.show_profile = !self.show_profile;
            self.dragging = false;
            self.timeline.drag = null;
            w.dirty = true;
        }
        if (self.show_profile and click and w.pointer_y >= 96 and w.pointer_y < 124) {
            if (w.pointer_x >= 213 and w.pointer_x < 383) code = 25;
            if (w.pointer_x >= 398 and w.pointer_x < 538) code = 44;
            if (w.pointer_x >= 553 and w.pointer_x < 713) code = 14;
            if (w.pointer_x >= 728 and w.pointer_x < 968) code = 28;
        }
        if (code == 25) {
            self.show_profile = true;
            self.dragging = false;
            w.dirty = true;
            const control = @import("../model/capture_view.zig");
            if (if (remote) self.capture_view.snapshot.collecting else session.profile != null and session.profile.?.collector != null) {
                self.applyCapture(context, .{ .stop = if (remote) self.capture_view.capture_id orelse return else session.profile.?.id });
            } else {
                const capture_snapshot = if (remote) self.capture_view.snapshot else self.capture_control.rows.snapshot(session);
                if (self.thread_selection.sync(&capture_snapshot) == .cleared_replaced) {
                    self.setup.message = "The target changed; review the capture thread selection";
                    self.setup.open = true;
                    self.status = self.setup.message;
                    return;
                }
                self.applyCapture(context, .{ .start = control.Start.from(&self.thread_selection) });
            }
        }
        if (self.show_profile) {
            if (code == 1 and self.inspector.open) {
                self.inspector.open = false;
                w.dirty = true;
                return;
            }
            if (code == 48) {
                if (self.flame.basis == .recorded) {
                    // Choosing the basis again is the explicit retry of a failure.
                    self.applyCapture(context, .retry_derived);
                    self.flame.setBasis(.reconstructed);
                    self.status = "Reconstructed stacks from saved registers and stack bytes; B returns to recorded callchains";
                } else {
                    self.flame.setBasis(.recorded);
                    self.status = "Recorded kernel callchains";
                }
                w.dirty = true;
            }
            if (self.flame.capture_key != null) {
                if (code == 23) {
                    self.inspector.open = !self.inspector.open;
                    if (self.inspector.open) self.inspector.scroll = 0;
                    if (self.inspector.open) self.inspector.ordinal = if (self.flame.selectedExample()) |ordinal| ordinal else std.math.maxInt(usize);
                    w.dirty = true;
                }
                if (self.inspector.open and (code == 26 or code == 27)) {
                    self.inspector.step(self.flame.selection.filter, if (code == 26) -1 else 1);
                    w.dirty = true;
                }
            }
            if (code == 44) self.flame.zoomSelected();
            if (code == 14) self.flame.zoomOut();
            if (remote) {
                if (click) if (self.flame.hit(w.pointer_x, w.pointer_y)) |node| self.flame.select(node);
            } else {
                if (click) if (session.profile) |capture| {
                    // Hit rectangles describe the displayed revision; frame identity
                    // remains valid within this capture until new mapping evidence.
                    if (capture.id == self.flame.capture_id and capture.mapping_revision == self.flame.mapping_revision and (capture.trusted_before_ns == std.math.maxInt(u64) or capture.revision == self.flame.revision)) {
                        if (self.flame.hit(w.pointer_x, w.pointer_y)) |node| self.flame.select(node);
                    }
                };
            }
            if (code == 28) if (self.flame.view.key) |capture_key| if (self.flame.selectedFrame()) |frame| {
                self.applyCapture(context, .{ .browse = .{ .key = capture_key, .frame = frame } });
            };
            if (w.scroll != 0 and self.timeline.wheel(w.pointer_x, w.pointer_y, w.scroll)) {
                w.scroll = 0;
                w.dirty = true;
            }
            if (w.scroll != 0 or code == 103 or code == 108) self.flame.scrollBy(w.scroll + (if (code == 108) @as(i32, 3) else if (code == 103) @as(i32, -3) else 0));
            w.scroll = 0;
            if (code == 103 or code == 108) code = 0;
            if (click or code == 44 or code == 14 or code == 28) w.dirty = true;
            if (w.pointer_y >= 90 and w.pointer_y < @as(f32, @floatFromInt(w.height)) * 0.73) click = false;
        }
        if (code == 24 or (click and self.layout.processes.contains(w.pointer_x, w.pointer_y))) {
            if (remote) {
                self.process_panel.show(context.processes);
            } else if (session.process_tree) |tree| {
                self.process_capture.refresh(tree, 0, true) catch |err| {
                    self.status = @errorName(err);
                };
                self.process_panel.show(self.process_capture.value);
            }
            w.dirty = true;
            return;
        }
        if (code == 34) {
            self.show_profile = false;
            self.static_panel.hideDecompile();
            self.show_flow = !self.show_flow;
            if (self.show_flow) self.pinned_pane = .assembly;
            w.dirty = true;
        }
        if (!self.show_profile and self.show_flow and snapshot.state == .stopped and self.flow.generation == snapshot.generation) {
            if (click) if (self.flow.hit(w.pointer_x, w.pointer_y)) |address| {
                self.browse_address = address;
                self.browse_assembly = null;
                self.status = "Browsing block; execution unchanged";
                w.dirty = true;
            };
            if (!(self.show_watch and self.watch_focus) and self.layout.rect(.assembly).contains(w.pointer_x, w.pointer_y)) {
                self.flow.scrollBy(w.scroll + (if (code == 108) @as(i32, 3) else if (code == 103) @as(i32, -3) else 0));
                w.scroll = 0;
                if (code == 108 or code == 103) code = 0;
            }
        }
        if (!self.show_profile) {
            if (code == 18 and @intFromEnum(language.selected) >= 2) {
                (if (remote) self.language_panel.beginExpressionView(language) else self.language_panel.beginExpression(session)) catch |err| {
                    self.status = @errorName(err);
                };
                w.dirty = true;
            } else if (code == 18) {
                self.editor.start();
                self.show_watch = true;
                self.watch_focus = true;
                w.dirty = true;
            }
            if (code == 47) {
                self.show_watch = !self.show_watch;
                if (self.show_watch) self.pinned_pane = .events;
                if (!self.show_watch) self.watch_focus = false;
                w.dirty = true;
            }
            if (self.show_watch and w.scroll != 0) {
                const r = self.watch_rect;
                if (w.pointer_x >= r.x and w.pointer_x < r.x + r.w and w.pointer_y >= r.y and w.pointer_y < r.y + r.h) {
                    if (@intFromEnum(language.selected) >= 2) self.runtime_watch_panel.scrollBy(w.scroll) else self.watch_panel.scrollBy(w.scroll);
                    w.scroll = 0;
                    w.dirty = true;
                }
            }
            if (click and self.show_watch) {
                const r = self.watch_rect;
                self.watch_focus = w.pointer_x >= r.x and w.pointer_x < r.x + r.w and w.pointer_y >= r.y and w.pointer_y < r.y + r.h;
                if (self.watch_focus) {
                    if (@intFromEnum(language.selected) >= 2) {
                        self.runtime_watch_panel.click(w.pointer_x, w.pointer_y);
                    } else if (self.watch_panel.rowAt(w.pointer_y, &self.watch_hits)) |i| self.watch_panel.selected = i;
                    click = false;
                    w.dirty = true;
                }
            }
            if (self.show_watch and self.watch_focus and @intFromEnum(language.selected) >= 2) {
                if (remote) {
                    switch (self.runtime_watch_panel.keyView(self.runtime_watch_view, code)) {
                        .ignored => {},
                        .local => {
                            code = 0;
                            w.dirty = true;
                        },
                        .remove => |id| {
                            context.send(self, .{ .runtime_watch = .{ .remove = id } });
                            code = 0;
                            w.dirty = true;
                        },
                    }
                } else {
                    if (self.runtime_watch_panel.key(session, code) catch |err| failed: {
                        self.status = @errorName(err);
                        break :failed false;
                    }) {
                        code = 0;
                        w.dirty = true;
                    }
                }
            }
            if (self.show_watch and self.watch_focus and @intFromEnum(language.selected) < 2) {
                switch (self.watch_panel.keyView(self.watch_view, code)) {
                    .ignored => {},
                    .local => {
                        code = 0;
                        w.dirty = true;
                    },
                    .owner => |action| {
                        if (action == .investigate_write) {
                            self.watchWrite(context, action.investigate_write.index);
                        } else if (self.applyWatch(context, action)) {
                            if (action == .remove) self.watch_panel.removed(action.remove.index, self.watch_view.entries.len);
                        }
                        code = 0;
                        w.dirty = true;
                    },
                }
            }
        }
        if (!self.show_profile and self.layout.visible(.registers) and click) {
            if (self.language_panel.hit(w.pointer_x, w.pointer_y)) |tab| {
                if (remote) context.send(self, .{ .language = .{ .tab = tab } }) else session.language_tabs.select(tab) catch {};
                click = false;
                w.dirty = true;
            }
        }
        if (!self.show_profile and self.layout.visible(.registers) and @intFromEnum(language.selected) >= 2) {
            if (click) {
                if (remote) {
                    const result = self.language_panel.clickView(language, w.pointer_x, w.pointer_y) catch |err| {
                        self.status = @errorName(err);
                        return;
                    };
                    switch (result) {
                        .ignored => {},
                        .local => {
                            click = false;
                            w.dirty = true;
                        },
                        .select => |action| {
                            context.send(self, .{ .language = action });
                            click = false;
                            w.dirty = true;
                        },
                    }
                } else {
                    const handled = self.language_panel.click(session, w.pointer_x, w.pointer_y) catch |err| {
                        self.status = @errorName(err);
                        return;
                    };
                    if (handled) {
                        click = false;
                        w.dirty = true;
                    }
                }
            }
            if (self.layout.rect(.registers).contains(w.pointer_x, w.pointer_y) and w.pointer_y >= self.language_panel.content_y and w.scroll != 0) {
                if (w.pointer_y >= self.language_panel.binding_y) self.language_panel.scrollBindings(w.scroll) else if (w.pointer_y >= self.language_panel.native_y) self.language_panel.scrollNative(w.scroll) else self.language_panel.scrollBy(w.scroll);
                w.scroll = 0;
                w.dirty = true;
            }
        }
        if (code == 15) {
            if (!self.layout.visible(.registers)) self.pinned_pane = .registers;
            if (remote) {
                const tabs = @import("../model/language_tabs.zig");
                for (1..tabs.order.len + 1) |offset| {
                    const tab = tabs.order[(@intFromEnum(language.selected) + offset) % tabs.order.len];
                    if (language.visible(tab)) {
                        context.send(self, .{ .language = .{ .tab = tab } });
                        break;
                    }
                }
            } else session.language_tabs.cycle();
            w.dirty = true;
        }
        if (click and language.selected == .native and self.layout.rect(.registers).contains(w.pointer_x, w.pointer_y) and w.pointer_y >= self.language_panel.content_y and w.pointer_y < self.bottomY(@floatFromInt(w.height)) - 10) {
            self.selected_local = @intFromFloat((w.pointer_y - self.language_panel.content_y) / look.workspace.local_row);
            w.dirty = true;
        }
        if (code == 17 and @intFromEnum(language.selected) >= 2) {
            if (remote) {
                const action = self.language_panel.watchBindingView(language) catch |err| {
                    self.status = @import("language_tabs.zig").watchError(err);
                    return;
                };
                context.send(self, .{ .runtime_watch = action });
            } else {
                const id = self.language_panel.watchBinding(session) catch |err| {
                    self.status = @import("language_tabs.zig").watchError(err);
                    return;
                };
                self.runtime_watch_panel.selected = id;
                self.runtime_watch_panel.reveal = true;
            }
            self.show_watch = true;
            self.watch_focus = false;
            self.status = "Runtime binding watch added; compares when the process stops";
            w.dirty = true;
            return;
        }
        if (code == 17 and language.selected == .native and snapshot.state == .stopped and self.selected_local < self.locals.len and snapshot.thread_count > 0) {
            if (self.last_generation != snapshot.generation) {
                self.status = "StaleSnapshot";
                return;
            }
            const local = self.locals[self.selected_local];
            const address = local.value.address orelse {
                self.status = "NotAddressable";
                return;
            };
            if (remote) {
                context.send(self, .{ .workspace = .{ .watch_local = .{ .tid = threads[self.selected % threads.len].tid, .frame = self.selected_frame, .metadata = self.last_metadata_revision, .name = local.name, .address = address } } });
            } else {
                for (session.target.watchpointSlice()) |watch| if (watch != null and watch.?.address == address) {
                    session.target.removeWatchpoint(watch.?.id) catch |err| {
                        self.status = @errorName(err);
                        return;
                    };
                    session.record(.human, "remove_watchpoint");
                    self.status = "Watchpoint removed";
                    return;
                };
                const tid = threads[self.selected % snapshot.thread_count].tid;
                _ = session.investigateWrite(tid, self.selected_frame, "Why did the selected value change?", local.name) catch |err| {
                    self.status = @errorName(err);
                    return;
                };
                session.record(.human, "investigate_write");
                self.status = "Write investigation started";
            }
        }
        if (click and self.layout.visible(.source) and w.pointer_x > 10 and w.pointer_x < 74 and w.pointer_y >= look.workspace.source_y and w.pointer_y < self.bottomY(@floatFromInt(w.height)) - 10 and snapshot.state == .stopped) {
            if (remote) {
                const number: u32 = @intCast(self.source_line + @as(i32, @intFromFloat((w.pointer_y - look.workspace.source_y) / look.workspace.code_row)) + 1);
                context.send(self, .{ .breakpoint = .{ .toggle_source = .{ .path = self.source_path, .line = number } } });
            } else {
                var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch.deinit();
                const number: u32 = @intCast(self.source_line + @as(i32, @intFromFloat((w.pointer_y - look.workspace.source_y) / look.workspace.code_row)) + 1);
                _ = session.humanCommand(scratch.allocator(), self.last_generation, .{ .breakpoint = .{ .toggle_source = .{ .path = self.source_path, .line = number } } }) catch |err| {
                    self.status = lineStatus(session, err);
                    return;
                };
                if (session.modules.skipped().count != 0) self.status = "Breakpoint toggled in the images searched; some are over the image budget (Modules lists them)";
            }
        }
        if (click and !self.show_profile and w.pointer_x >= 74 and w.pointer_x < self.layout.left and w.pointer_y >= look.workspace.source_y and w.pointer_y < self.bottomY(@floatFromInt(w.height)) - 10) {
            self.cursor_line = @intCast(self.source_line + @as(i32, @intFromFloat((w.pointer_y - look.workspace.source_y) / look.workspace.code_row)) + 1);
            self.static_from_line = true;
            self.status = "Source line selected; F9 run to cursor, F12 finish, B breakpoints, S static slice";
            w.dirty = true;
        }
        if (click and !self.show_profile and self.static_panel.decompile_open and self.static_panel.selectDecompileAt(w.pointer_x, w.pointer_y)) {
            self.followStatic(w);
            self.status = if (self.static_panel.decompile_pcs.items.len > 0) "Pseudo-C line selected; exact mapped instructions and source selected" else "Pseudo-C line has no exported instruction mapping";
            w.dirty = true;
            click = false;
        }
        const rows = self.assembly_rows;
        if (click and !self.show_profile and !self.show_flow and !self.static_panel.decompile_open and rows.count > 0 and w.pointer_x >= rows.x and w.pointer_x < rows.x + rows.w and w.pointer_y >= rows.y - 2 and w.pointer_y < rows.y - 2 + @as(f32, @floatFromInt(rows.count)) * look.workspace.code_row) {
            const index: usize = @intFromFloat((w.pointer_y - rows.y + 2) / look.workspace.code_row);
            if (index < self.instruction_count) {
                self.assembly_cursor = self.instructions[index].address;
                self.static_from_line = false;
                self.status = "Instruction selected; S static slice / control dependences";
                w.dirty = true;
            }
        }
        if ((code == 67 or code == 88) and snapshot.state == .stopped and snapshot.thread_count > 0) {
            const tid = threads[self.selected % snapshot.thread_count].tid;
            if (remote) {
                if (code == 88) context.send(self, .{ .control = .{ .finish_frame = .{ .tid = tid, .frame = self.selected_frame } } }) else {
                    const line = self.cursor_line orelse {
                        self.status = "Click a source line first";
                        return;
                    };
                    context.send(self, .{ .control = .{ .run_to_source = .{ .tid = tid, .path = self.source_path, .line = line } } });
                }
            } else {
                const action: @import("../model/command.zig").Control = if (code == 88) .{ .finish_frame = .{ .tid = tid, .frame = self.selected_frame } } else .{ .run_to_source = .{ .tid = tid, .path = self.source_path, .line = self.cursor_line orelse {
                    self.status = "Click a source line first";
                    return;
                } } };
                var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch.deinit();
                _ = session.humanCommand(scratch.allocator(), self.last_generation, .{ .control = action }) catch |err| {
                    self.status = lineStatus(session, err);
                    return;
                };
            }
            self.status = if (code == 88) "Running until selected frame returns" else "Running to selected source line";
            self.browse_address = null;
        }
        const thread_bounds = self.layout.rect(.threads);
        const stack_bounds = self.layout.rect(.stack);
        const stack_x = thread_bounds.x + thread_bounds.w + 4;
        const stack_y = self.bottomY(@floatFromInt(w.height)) + 44;
        if (click and !self.show_profile and threads.len > 0 and thread_bounds.contains(w.pointer_x, w.pointer_y) and w.pointer_y >= stack_y) {
            const bottom = self.bottomY(@floatFromInt(w.height));
            // The owner frontend clears self.thread_labels after each draw;
            // hit-test against the same publication rows that were drawn.
            const labels = if (remote) context.display.thread_labels else self.thread_labels;
            const wine = if (remote) context.display.compatibility.kind == .wine else self.compatibility_info.kind == .wine;
            const darwin = labels.len > 0 and labels[0].source == .gdb_thread_info;
            const selected = if (wine or darwin)
                self.thread_list.hit(.{ .x = 12, .y = bottom + 42, .w = stack_x - 20, .h = @max(0, thread_bounds.h - 50) }, threads, labels, self.selected, w.pointer_x, w.pointer_y)
            else blk: {
                const visible: usize = @intFromFloat(@max(0, (thread_bounds.h - 50) / self.rowStep()));
                const first = (self.selected + 1) -| visible;
                const row: usize = @intFromFloat((w.pointer_y - stack_y) / self.rowStep());
                const index = first + row;
                break :blk if (index < threads.len and row < visible) index else null;
            };
            if (selected) |index| {
                self.selected = index;
                self.selected_frame = 0;
                self.browse_address = null;
                self.selectNative(context);
                w.dirty = true;
            }
        }
        if (click and !self.show_profile and stack_bounds.contains(w.pointer_x, w.pointer_y) and w.pointer_y >= stack_y and w.pointer_y + self.rowStep() <= stack_bounds.y + stack_bounds.h and self.frames.len > 0) {
            self.browse_address = null;
            self.selected_frame = @min(self.frames.len - 1, @as(usize, @intFromFloat((w.pointer_y - stack_y) / self.rowStep())));
            self.selectNative(context);
            w.dirty = true;
        }
        if (code == 66) {
            if (remote) context.send(self, .toggle_scope) else self.toggleAgentScope(session);
        } // F8 or the Agent button.
        if (code == 87 or code == 68 or code == 57 or code == 63 or code == 64 or code == 36 or code == 37) self.browse_address = null;
        if ((code == 87 or code == 68) and snapshot.state == .stopped and snapshot.thread_count > 0) {
            const tid = threads[self.selected % snapshot.thread_count].tid;
            if (remote) {
                const action: @import("../model/remote_owner.zig").Control = if (self.current_line != null) .{ .step_source = .{ .tid = tid, .over = code == 68 } } else if (code == 87) .{ .step_instruction = tid } else .{ .step_over_instruction = tid };
                context.send(self, .{ .control = action });
                self.selected_frame = 0;
            } else {
                const action: @import("../model/command.zig").Control = if (self.current_line != null) .{ .step_source = .{ .tid = tid, .over = code == 68 } } else if (code == 87) .{ .step_instruction = tid } else .{ .step_over_instruction = tid };
                _ = session.humanCommand(std.heap.page_allocator, self.last_generation, .{ .control = action }) catch |err| {
                    self.status = @errorName(err);
                    return;
                };
                self.selected_frame = 0;
            }
        }
        if (remote) {
            if (code == 1) if (self.capture_view.archive_job) |job| if (!job.done) {
                self.applyCapture(context, .{ .cancel_archive = job.id });
                return;
            };
        } else {
            if (code == 1) if (session.archive_job) |job| {
                if (!job.done.load(.acquire)) {
                    self.applyCapture(context, .{ .cancel_archive = job.id });
                    return;
                }
            };
        }
        // Snapshot every metadata job only for Esc, not on each input pass.
        const pending_image = if (code != 1) null else if (remote) context.header.metadata else @import("../model/workspace_view.zig").capture(session).metadata;
        if (pending_image) |job| if (job.kind == .image) {
            if (remote) context.send(self, .{ .workspace = .{ .cancel_metadata = job.id } }) else session.metadata.cancel(job.id) catch |err| {
                self.status = @errorName(err);
                return;
            };
            self.status = "Image transfer cancelled";
            w.dirty = true;
            return;
        };
        if (code == 16) {
            w.closing = true;
            w.close_reason = .quit_key;
        }
        if (remote) {
            if (code == 57 or code == 63 or code == 64) {
                if (context.header.pending_continue) context.send(self, .{ .control = .cancel_continue }) else if (snapshot.state == .stopped) context.send(self, .{ .control = .continue_execution }) else if (snapshot.state == .running) context.send(self, .{ .control = .interrupt });
                self.selected_frame = 0;
            }
            if (code == 32 and snapshot.pid != 0) context.send(self, .{ .control = .detach });
        } else {
            if (code == 57 or code == 63 or code == 64) {
                const action: ?@import("../model/command.zig").Control = if (session.pending_continue != null) .cancel_continue else if (snapshot.state == .stopped) .continue_execution else if (snapshot.state == .running) .interrupt else null;
                if (action) |control| {
                    _ = session.humanCommand(std.heap.page_allocator, self.last_generation, .{ .control = control }) catch |err| {
                        self.status = @errorName(err);
                        return;
                    };
                    if (control == .cancel_continue) self.status = "Pending continue cancelled" else if (session.pending_continue != null) self.status = "Resolving symbols; Space cancels the queued continue";
                }
                self.selected_frame = 0;
            }
            if (code == 32 and snapshot.pid != 0) _ = session.humanCommand(std.heap.page_allocator, self.last_generation, .{ .control = .detach }) catch |err| {
                self.status = @errorName(err);
                return;
            };
        }
        // View-only thread grouping; the owner frontend reads its publication.
        {
            const wine = if (remote) context.display.compatibility.kind == .wine else session.compatibility.info.kind == .wine;
            const labels = if (remote) context.display.thread_labels else session.compatibility.labels.items;
            if (code == 35 and wine) {
                self.thread_list.hide_internal = !self.thread_list.hide_internal;
                self.status = if (self.thread_list.hide_internal) "Wine internal names hidden; selected/faulting threads remain visible; capture keeps all threads" else "All threads shown; Wine internal names grouped below application threads";
            }
            if (code == 36 or code == 37) if (wine) {
                self.thread_list.prepare(threads, labels, self.selected);
                self.selected = self.thread_list.move(self.selected, code == 36);
                self.selected_frame = 0;
                self.selectNative(context);
                return;
            };
        }
        if (code == 36) {
            self.selected += 1;
            self.selected_frame = 0;
        }
        if (code == 37) {
            self.selected -|= 1;
            self.selected_frame = 0;
        }
        if (code == 108) self.source_line += 3;
        if (code == 103) self.source_line = @max(0, self.source_line - 3);
        self.source_line = std.math.clamp(self.source_line + w.scroll, 0, @max(0, self.source_lines - 1));
        w.scroll = 0;
        if (snapshot.thread_count > 0) self.selected %= snapshot.thread_count else self.selected = 0;
        if (code == 36 or code == 37) self.selectNative(context);
    }
    fn applyCapture(self: *Workspace, context: anytype, action: @import("../model/capture_view.zig").Action) void {
        if (@TypeOf(context) != *Session) {
            context.send(self, .{ .capture_control = action });
        } else {
            const session = context;
            const outcome = @import("../model/capture_view.zig").apply(&self.capture_control.rows, session, .human, action) catch |err| {
                self.status = switch (err) {
                    error.ProfileSourceNotRecorded => "Offline capture: recorded source location shown below; historical source text is not bundled",
                    error.ProfileImageNotStopped => "Pause in the captured image to browse; frozen assembly remains below",
                    error.ProfileImageMismatch => "Captured frame has no matching live image",
                    else => @errorName(err),
                };
                return;
            };
            self.captureOutcome(outcome);
        }
    }
    pub fn captureOutcome(self: *Workspace, outcome: @import("../model/capture_view.zig").Outcome) void {
        switch (outcome) {
            .configured => self.status = "Next capture settings changed; a running capture keeps its own",
            .started => {
                self.setup.open = false;
                self.status = "Capturing CPU samples; Space runs the target";
            },
            .stopped => self.status = "Capture stopped; target execution unchanged",
            .rejected => |reason| {
                self.status = capture_setup.problemText(reason);
                if (reason == .empty_subset or reason == .missing_threads or reason == .too_many_threads) self.setup.open = true;
            },
            .retrying => {},
            .cancelled => self.status = "Archive cancellation requested",
            .browse => |addresses| {
                self.browse_address = addresses.source;
                self.browse_assembly = addresses.assembly;
                self.show_flow = false;
                self.show_profile = false;
                self.status = "Browsing sampled function; execution unchanged";
            },
        }
    }
    /// Performs a setup-panel action. Start goes through the same path as P.
    pub fn applySetup(self: *Workspace, w: *Window, context: anytype, action: capture_panel.Action) void {
        if (@TypeOf(context) != *Session) {
            w.dirty = true;
            const snapshot = self.capture_view.snapshot;
            var defaults = self.capture_view.defaults;
            const effect = self.setup.apply(action, &snapshot, &defaults, &self.thread_selection) catch |err| {
                self.status = @errorName(err);
                return;
            };
            if (!std.meta.eql(defaults, self.capture_view.defaults)) context.send(self, .{ .capture_control = .{ .defaults = defaults } });
            if (effect == .start_requested) self.step(w, context, false, 25);
        } else {
            const session = context;
            w.dirty = true;
            const snapshot = self.capture_control.rows.snapshot(session);
            // Offline sessions show recorded settings only.
            if (session.offline) switch (action) {
                .close, .page, .edit => {},
                else => return,
            };
            const effect = self.setup.apply(action, &snapshot, &session.profile_defaults, &self.thread_selection) catch |err| {
                self.status = @errorName(err);
                return;
            };
            if (effect == .start_requested) self.step(w, session, false, 25);
            switch (action) {
                .set_duration, .set_frequency, .toggle_scheduling, .toggle_syscalls, .toggle_kernel_stacks, .toggle_off_cpu => self.status = "Next capture settings changed; a running capture keeps its own",
                else => {},
            }
        }
    }
    /// Hands the committed timeline selection to the flames.
    pub fn applyTimeline(self: *Workspace, context: anytype) void {
        if (@TypeOf(context) != *Session) {
            if (self.flame.capture_id != self.timeline.capture_id) return;
            self.flame.setFilter(self.timeline.filter()) catch |err| {
                self.status = @errorName(err);
            };
        } else {
            const session = context;
            const capture = session.profile orelse return;
            if (capture.id != self.timeline.capture_id) return;
            self.flame.setFilter(self.timeline.filter()) catch |err| {
                self.status = @errorName(err);
            };
        }
    }
    /// Starts a write investigation on a watch entry, in the frame the entry
    /// resolved to at this stop. Same authority as W on a local.
    fn watchWrite(self: *Workspace, context: anytype, index: usize) void {
        if (@TypeOf(context) != *Session) {
            context.send(self, .{ .native_watch = .{ .investigate_write = self.watchToken(index) } });
        } else {
            const session = context;
            if (self.applyWatch(session, .{ .investigate_write = self.watchToken(index) })) self.status = "Write investigation started";
        }
    }
    fn watchToken(self: *const Workspace, index: usize) native_watches.Token {
        return .{ .revision = self.watch_view.revision, .index = index };
    }
    fn applyWatch(self: *Workspace, context: anytype, action: native_watches.Action) bool {
        if (@TypeOf(context) != *Session) {
            context.send(self, .{ .native_watch = action });
            return false; // Completion, not admission, confirms an edit.
        } else {
            const session = context;
            _ = native_watches.apply(&self.watch, session, .human, action) catch |err| {
                self.status = @errorName(err);
                return false;
            };
            self.refreshWatch(session);
            return true;
        }
    }
    fn applyEditor(self: *Workspace, context: anytype, action: watch_ui.Editor.Action) void {
        if (@TypeOf(context) != *Session) {
            switch (action) {
                .edited => {},
                .cancel => self.status = "Expression cancelled",
                .submit => |text| {
                    if (context.display.snapshot.state != .stopped or self.selected >= context.display.threads.len or self.frames.len == 0) {
                        self.editor.message = "Pause and select a frame to evaluate";
                        return;
                    }
                    context.send(self, .{ .native_watch = .{ .add = .{ .binding = .{ .selection = .{ .tid = context.display.threads[self.selected].tid, .index = self.selected_frame }, .metadata = context.language.metadata }, .text = text, .mode = self.editor.mode } } });
                },
            }
        } else {
            const session = context;
            switch (action) {
                .edited => {},
                .cancel => self.status = "Expression cancelled",
                .submit => |text| {
                    if (session.target.snapshot().state != .stopped or session.target.snapshot().thread_count == 0) {
                        self.editor.message = "Pause the target to evaluate";
                        return;
                    }
                    self.refresh(session);
                    if (self.frames.len == 0 or self.last_generation != session.target.snapshot().generation) {
                        self.editor.message = "No frame to evaluate in";
                        return;
                    }
                    const tid = session.target.threadSlice()[self.selected].tid;
                    const added = native_watches.apply(&self.watch, session, .human, .{ .add = .{ .binding = .{ .selection = .{ .tid = tid, .index = self.selected_frame }, .metadata = session.metadata.revision }, .text = text, .mode = self.editor.mode } }) catch |err| {
                        self.editor.message = switch (err) {
                            error.WatchListFull => "The watch list is full (16); Delete one first",
                            error.ExpressionTooLong => "Expressions are limited to 256 characters",
                            error.EmptyExpression => "Type an expression",
                            else => @errorName(err),
                        };
                        return;
                    };
                    self.watch_panel.added(@intCast(added.?));
                    self.status = watchAddedStatus(self.editor.mode == .live);
                    self.editor.open = false;
                    self.watch_focus = true;
                    self.refreshWatch(session);
                },
            }
        }
    }
    fn toggleWatchMode(self: *Workspace, context: anytype) void {
        if (@TypeOf(context) != *Session) {
            const index = self.watch_panel.selected orelse return;
            if (context.display.snapshot.state != .stopped or self.selected >= context.display.threads.len or self.frames.len == 0) {
                self.status = "Pause and select a frame to change the watch mode";
                return;
            }
            context.send(self, .{ .native_watch = .{ .toggle_mode = .{ .entry = self.watchToken(index), .binding = .{ .selection = .{ .tid = context.display.threads[self.selected].tid, .index = self.selected_frame }, .metadata = context.language.metadata } } } });
        } else {
            const session = context;
            const index = self.watch_panel.selected orelse return;
            if (session.target.snapshot().state != .stopped) {
                self.status = "Pause in the desired frame to change the watch mode";
                return;
            }
            self.refresh(session);
            if (self.frames.len == 0 or session.target.snapshot().thread_count == 0) {
                self.status = "No selected frame to bind the watch";
                return;
            }
            const thread = session.target.threadSlice()[self.selected];
            if (!self.applyWatch(session, .{ .toggle_mode = .{ .entry = self.watchToken(index), .binding = .{ .selection = .{ .tid = thread.tid, .index = self.selected_frame }, .metadata = session.metadata.revision } } })) return;
            self.status = watchModeStatus(self.watch_view.entries[index].mode == .live);
            self.refreshWatch(session);
        }
    }
    pub fn watchAddedStatus(live: bool) []const u8 {
        return if (live) "Live display added; updates in the selected frame at each stop / Shift+L pins it" else "Watch added; later CFA matches cannot prove call lifetime between stops / Shift+L makes it live";
    }
    pub fn watchModeStatus(live: bool) []const u8 {
        return if (live) "Live display: follows the selected frame / Shift+L pins it" else "Watch pinned to the selected frame / Shift+L makes it live";
    }
    /// Top of the bottom row (threads, stack, events/watch). Short windows give
    /// the watch view more rows; the source and assembly panes shrink instead.
    fn bottomY(self: *const Workspace, height: f32) f32 {
        if (self.layout_key != null) return self.layout.bottom;
        return @round(height * @as(f32, if (self.show_watch and height < 640) 0.56 else 0.73));
    }
    fn refreshWatch(self: *Workspace, session: *Session) void {
        self.presentNativeWatches(native_watches.refresh(&self.watch, session, if (self.selected < session.target.snapshot().thread_count) .{ .tid = session.target.threadSlice()[self.selected].tid, .index = self.selected_frame } else null));
    }
    pub fn presentStop(self: *Workspace, view: @import("../model/stop_view.zig").View) void {
        self.stop_view = view;
    }
    pub fn presentNativeWatches(self: *Workspace, view: native_watches.View) void {
        self.watch_view = view;
        self.watch_panel.present(view);
    }
    fn selectNative(self: *Workspace, context: anytype) void {
        if (@TypeOf(context) != *Session) {
            if (self.selected >= context.display.threads.len or context.display.snapshot.state != .stopped) return;
            context.send(self, .{ .language = .{ .native = .{ .tid = context.display.threads[self.selected].tid, .frame = self.selected_frame } } });
        } else {
            const session = context;
            if (self.selected >= session.target.snapshot().thread_count or session.target.snapshot().state != .stopped) return;
            const tid = session.target.threadSlice()[self.selected].tid;
            @import("../model/language_selection.zig").selectNative(session, tid, self.selected_frame) catch |err| {
                self.status = @errorName(err);
            };
        }
    }
    fn refresh(self: *Workspace, session: *Session) void {
        defer {
            const threads = session.target.threadSlice();
            const tid = if (threads.len > 0) threads[@min(self.selected, threads.len - 1)].tid else 0;
            if (session.process_tree) |tree| {
                self.process_capture.refresh(tree, 0, self.process_panel.open) catch |err| {
                    self.status = @errorName(err);
                };
            } else self.process_capture.clear();
            self.process_panel.present(self.process_capture.value);
            self.probe_capture.refresh(session, self.probes_panel.open);
            self.probes_panel.present(self.probe_capture.value);
            self.inline_capture.refresh(session, self.inline_panel.request(tid, self.selected_frame, session.target.snapshot().generation));
            self.inline_panel.present(self.inline_capture.value);
            self.inspection_capture.refresh(session, self.inspection_panel.request(tid));
            self.inspection_panel.present(self.inspection_capture.value);
            self.stop_capture.refresh(session, tid, self.stop_panel.open);
            self.presentStop(self.stop_capture.value);
            self.runtime_watch_capture.refresh(session);
            self.presentRuntimeWatches(self.runtime_watch_capture.value);
        }
        session.language_tabs.request(session);
        session.language_tabs.syncSelection(session.target.snapshot().generation);
        if (self.last_language_revision != session.language_tabs.revision) {
            self.last_language_revision = session.language_tabs.revision;
            if (session.language_tabs.native_selection) |selected| {
                for (session.target.threadSlice(), 0..) |thread, index| {
                    if (thread.tid != selected.tid) continue;
                    self.selected = index;
                    self.selected_frame = selected.frame;
                    break;
                }
            }
        }
        // Live displays use the selected frame after this refresh clamps it.
        defer self.refreshWatch(session);
        const busy = session.allocations.preparing();
        const collecting = session.allocations.collecting();
        if (self.allocation_busy and !busy) self.status = if (session.allocations.err) |err| @errorName(err) else if (collecting) "Allocation capture ready; Space continues" else "Allocation preparation ended";
        if (self.allocation_collecting and !collecting) self.status = "Allocation capture ended; A opens evidence";
        self.allocation_busy = busy;
        self.allocation_collecting = collecting;
        if (self.was_running_to and session.run_to == null) self.status = if (session.target.snapshot().state == .stopped) "Run-to operation stopped" else "Run-to operation ended";
        self.was_running_to = session.run_to != null;
        if (session.target.snapshot().thread_count > 0) {
            self.selected %= session.target.snapshot().thread_count;
            if (session.target.snapshot().state == .stopped and session.target.threadSlice()[self.selected].state == .exited) {
                for (session.target.threadSlice(), 0..) |thread, index| if (thread.state == .stopped) {
                    self.selected = index;
                    self.selected_frame = 0;
                    break;
                };
            }
        }
        const tid = if (session.target.snapshot().thread_count > 0) session.target.threadSlice()[self.selected].tid else 0;
        if (self.last_metadata_revision == session.metadata.revision and self.last_generation == session.target.snapshot().generation and self.last_tid == tid and self.last_frame == self.selected_frame and self.last_browse == self.browse_address and self.last_show_flow == self.show_flow) return;
        if (self.last_generation != session.target.snapshot().generation) {
            self.browse_address = null;
        }
        self.last_browse = self.browse_address;
        self.last_show_flow = self.show_flow;
        if (self.last_tid != tid) self.stale_regs = null else if (self.regs) |regs| self.stale_regs = regs;
        self.alive = 0;
        self.last_generation = session.target.snapshot().generation;
        self.last_metadata_revision = session.metadata.revision;
        self.last_tid = tid;
        self.last_frame = self.selected_frame;
        self.prepared.refresh(session, .{ .tid = tid, .frame = self.selected_frame, .browse_address = self.browse_address, .browse_assembly = self.browse_assembly, .flow = self.show_flow });
        self.presentDebugger(self.prepared.value);
        self.last_language_revision = session.language_tabs.revision;
    }
    pub fn presentRuntimeWatches(self: *Workspace, view: @import("../model/runtime_watch_view.zig").View) void {
        if (self.runtime_watch_view.session != view.session) self.runtime_watch_panel = .{};
        self.runtime_watch_view = view;
    }
    /// Bind prepared pane values without target reads or ownership changes.
    /// The caller keeps the source preparation/publication alive while drawn.
    pub fn presentDebugger(self: *Workspace, view: debugger_view.Presentation) void {
        self.frames = view.frames;
        self.locals = view.locals;
        self.local_diagnostic = view.local_diagnostic;
        self.regs = view.regs;
        self.instruction_count = view.instructions.len;
        std.debug.assert(self.instruction_count <= self.instructions.len);
        @memcpy(self.instructions[0..self.instruction_count], view.instructions);
        self.assembly_error = view.assembly_error;
        self.current_line = view.current_line;
        self.selected_frame = view.selected_frame;
        self.breakpoint_lines = view.breakpoint_lines;
        self.presentSource(view.source);
        const key: @typeInfo(@FieldType(Workspace, "presented")).optional.child = .{ .generation = view.snapshot.generation, .tid = view.request.tid, .frame = view.selected_frame, .browse = view.request.browse_address, .source_revision = view.source.revision };
        if (self.presented == null or !std.meta.eql(self.presented.?, key)) {
            if (view.current_line) |line| self.source_line = @intCast(line -| 6);
        }
        self.presented = key;
        self.flow.present(view.flow);
        if (view.status) |message| {
            const n = @min(message.len, self.presentation_status.len);
            @memcpy(self.presentation_status[0..n], message[0..n]);
            self.status = self.presentation_status[0..n];
        }
    }
    fn expandTabs(buffer: []u8, source: []const u8) []const u8 {
        var n: usize = 0;
        for (source) |byte| {
            const stop = if (byte == '\t') (n / tab_width + 1) * tab_width else n + 1;
            if (stop > buffer.len) break;
            if (byte == '\t') @memset(buffer[n..stop], ' ') else buffer[n] = byte;
            n = stop;
        }
        return buffer[0..n];
    }
    fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, color: gpu.Color, comptime format: []const u8, args: anytype) !void {
        var buffer: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buffer, format, args) catch return;
        try r.text(font, x, y, s, color);
    }
    fn fit(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime format: []const u8, args: anytype) !void {
        var buffer: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buffer, format, args) catch return;
        try r.textFit(font, x, y, width, s, color);
    }
    fn pane(r: *gpu.Renderer, font: *Font, rect: gpu.Rect, name: []const u8, detail: []const u8) !void {
        r.clip = r.fullClip();
        try style.shadow(r, rect, 8, 0.6);
        try style.box(r, rect, theme.surface, theme.border, @splat(8));
        try r.shape(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = 33 }, theme.header, .{ .radii = .{ 7, 7, 0, 0 } });
        try r.rect(.{ .x = rect.x + 1, .y = rect.y + 33, .w = rect.w - 2, .h = 1 }, theme.border);
        r.clip = rect;
        const detail_x = @max(140, r.measure(font, name) + 34);
        try r.text(font, rect.x + 14, rect.y + 8, name, theme.text);
        try r.textFit(font, rect.x + detail_x, rect.y + 8, rect.w - detail_x - 12, detail, theme.weak);
        r.clip = .{ .x = rect.x + 1, .y = rect.y + 35, .w = rect.w - 2, .h = rect.h - 37 };
    }
    /// Advances every eased value by the time since the last frame.
    fn animate(self: *Workspace, state: linux.State, threads: []const linux.Thread) void {
        const now = linux.now();
        const dt: f32 = if (self.last_draw == 0) 0 else @min(0.05, @as(f32, @floatFromInt(now - self.last_draw)) / 1e9);
        self.last_draw = now;
        var moving = false;
        for (&self.hot, &self.pressed, 0..) |*hot, *pressed, i| {
            if (style.approach(hot, if (self.hovered == i) 1 else 0, 60, dt)) moving = true;
            if (style.approach(pressed, 0, 14, dt)) moving = true;
        }
        if (style.approach(&self.alive, 1, 9, dt)) moving = true;
        // The status bar takes the color of the run state, as RAD Debugger's does.
        var target = theme.header;
        switch (state) {
            .running => target = theme.pop,
            .exited => target = theme.good_pop,
            .stopped => for (threads) |thread| switch (thread.reason) {
                .breakpoint, .watchpoint, .exception, .signal => target = theme.bad_pop,
                else => {},
            },
            .idle => {},
        }
        for (&self.bar, target) |*channel, goal| {
            if (style.approach(channel, goal, 30, dt)) moving = true;
        }
        self.animating = moving or self.inspection_panel.busy() or self.runtime_type_panel.busyPrepared();
    }
    pub fn drawSharedOwnership(self: *Workspace, r: *gpu.Renderer, font: *Font, w: *Window, scope: model.AgentScope) !void {
        const count = self.shared_clients orelse return;
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        r.clip = .{ .x = 0, .y = 0, .w = width, .h = height };
        const top = @max(0, height - 30);
        try r.rect(.{ .x = 0, .y = top, .w = width, .h = height - top }, theme.header);
        try r.rect(.{ .x = 0, .y = top, .w = width, .h = 1 }, theme.status_border);
        if (self.shared_controller) |owner| {
            try fit(r, font, 12, top + 5, @max(0, width - 24), theme.text, "F8 agent {s} / controller #{d} / {d} clients", .{ @tagName(scope), owner, count });
        } else {
            try fit(r, font, 12, top + 5, @max(0, width - 24), theme.text, "F8 agent {s} / no controller / {d} clients", .{ @tagName(scope), count });
        }
    }
    pub fn draw(self: *Workspace, r: *gpu.Renderer, font: *Font, w: *Window, session: *Session) !void {
        if (self.logical_frames.open or self.invocations.open or session.imported != null or (session.comparison != null and self.comparison.open)) layout_snapshot.unavailable();
        self.compatibility_info = session.compatibility.info;
        self.thread_labels = session.compatibility.labels.items;
        if (self.logical_frames.open) {
            session.profile_view_visible = false;
            self.animating = session.frames.busy();
            try self.logical_frames.draw(r, font, w, &session.frames);
            return self.drawSharedOwnership(r, font, w, session.agent_scope);
        }

        if (session.comparison) |job| if (self.comparison.open) {
            session.profile_view_visible = false;
            self.animating = !job.done.load(.acquire);
            try self.comparison.draw(r, font, w, job);
            return self.drawSharedOwnership(r, font, w, session.agent_scope);
        };
        if (self.invocations.open) {
            session.profile_view_visible = false;
            self.animating = @import("invocations.zig").View.busy(session);
            try self.invocations.draw(r, font, w, session, if (self.shared_clients != null) 30 else 0);
            return self.drawSharedOwnership(r, font, w, session.agent_scope);
        }
        if (session.imported) |*state| {
            try self.imported.draw(r, font, w, state);
            return self.drawSharedOwnership(r, font, w, session.agent_scope);
        }
        if (session.allocations.capture) |capture| if (capture.archived and !self.allocation_archive_seen) {
            self.allocation_archive_seen = true;
            self.show_profile = false;
            self.allocation_panel.show();
            self.allocation_panel.setMode(.heap);
        };
        self.refresh(session);
        const height: f32 = @floatFromInt(w.height);
        const tid = if (session.target.threadSlice().len > 0) session.target.threadSlice()[self.selected].tid else 0;
        self.allocation_capture.refresh(&session.allocations, self.allocation_panel.request(height), tid);
        self.allocation_panel.present(self.allocation_capture.value);
        session.profile_view_visible = self.show_profile;
        const bounds = self.timelineBounds(w);
        self.timeline_capture.refresh(session, if (self.show_profile) self.timeline.request(bounds) else null);
        if (self.timeline.present(self.timeline_capture.value, bounds)) self.applyTimeline(session);
        self.profile_capture.refresh(session, self.flame.request(self.show_profile));
        self.flame.present(self.profile_capture.value);
        if (!self.show_profile) self.language_panel.refresh(session, if (session.language_tabs.logical_selection) |selected| selected.tid else tid, self.selected_frame);
        self.sample_capture.refresh(session, if (self.show_profile) self.inspector.request(self.flame.selection.filter) else null);
        self.inspector.present(self.sample_capture.value, self.flame.selection.filter);
        self.syscall_capture.refresh(session, if (self.show_profile) self.syscall_panel.request(height, self.flame.selection.filter) else null);
        self.syscall_panel.present(self.syscall_capture.value, height, self.flame.selection.filter);
        self.capture_control.refresh(session, self.show_profile and self.setup.open);
        self.capture_view = self.capture_control.value;
        try self.runtime_type_panel.prepare(session, height);
        try self.static_panel.prepare(session, tid, self.selected_frame);
        try self.drawPrepared(r, font, w, self.prepared.value, @import("../model/workspace_view.zig").capture(session), @import("../model/language_view.zig").header(session), session.target.core != null);
        try self.redot_panel.draw(r, font, @floatFromInt(w.width), @floatFromInt(w.height), session.redot.snapshot());
        self.animating = self.animating or self.redot_panel.moving();
    }
    pub fn timelineBounds(self: *const Workspace, w: *const Window) gpu.Rect {
        const height: f32 = @floatFromInt(w.height);
        const bottom = if (self.show_profile) @round(height * profile_split) else self.bottomY(height);
        return .{ .x = 8, .y = bottom, .w = @as(f32, @floatFromInt(w.width)) - 16, .h = height - bottom - 37 };
    }
    /// Rendering uses only copied pane values; callers prepare or publish them.
    pub fn drawPrepared(self: *Workspace, r: *gpu.Renderer, font: *Font, w: *Window, display: debugger_view.Presentation, header: @import("../model/workspace_view.zig").Header, language: @import("../model/language_view.zig").Header, core: bool) !void {
        self.updateLayout(w);
        const extent = w.bufferExtent();
        self.layout_report = .{ .available = !self.show_profile, .width = w.width, .height = w.height, .buffer_width = extent.width, .buffer_height = extent.height, .ui_scale = w.scale(), .backing_scale = w.backing_scale, .density = self.density, .compact = self.compact, .font_size = font.ui_size };
        defer layout_snapshot.publish(&self.layout_report);
        if (w.width < look.minimum.width or w.height < look.minimum.height) {
            self.layout_report.too_small = true;
            r.clip = r.fullClip();
            try r.rect(r.clip, theme.background);
            try r.textWrap(font, .{ .x = 8, .y = 8, .w = @max(0, @as(f32, @floatFromInt(w.width)) - 16), .h = @max(0, @as(f32, @floatFromInt(w.height)) - 16) }, "Window too small. Enlarge to 640 x 400 UI units, or lower --ui-scale.", theme.warm);
            return;
        }
        if (!self.show_profile) {
            for (look.pane_names, 0..) |name, i| self.layout_report.panes[i] = .{ .name = name, .key = look.pane_keys[i], .rect = self.layout.panes[i], .tab = self.layout.tabs[i], .collapsed = self.layout.collapsed[i] };
            self.layout_report.pane_count = 6;
        }
        self.animate(display.snapshot.state, display.threads);
        const state = display.snapshot.state;
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        const all = gpu.Rect{ .x = 0, .y = 0, .w = width, .h = height };
        const selected_thread: ?linux.Thread = if (display.threads.len > 0) display.threads[@min(self.selected, display.threads.len - 1)] else null;
        const thread_color = if (selected_thread) |thread| style.threadColor(thread.id) else theme.good;
        r.clip = all;
        try r.rect(all, theme.background);
        try r.rect(.{ .x = 0, .y = 0, .w = width, .h = 44 }, theme.header);
        try r.rect(.{ .x = 0, .y = 43, .w = width, .h = 1 }, theme.border);
        try r.text(font, 18, 12, "xo", theme.good);
        try r.text(font, 41, 12, "db", theme.text);
        r.clip = .{ .x = 0, .y = 0, .w = width - 322, .h = 44 };
        if (core) try r.textFit(font, 91, 12, self.layout.processes.w, "core (read-only)", theme.weak) else try style.button(r, font, gpuRect(self.layout.processes), if (width < 900) "Tasks" else "Processes", "O", theme.text, 0, 0);
        self.layout_report.control("Processes", "O", self.layout.processes, false);
        if (self.compatibility_info.kind == .wine) {
            var title: [192]u8 = undefined;
            const title_x: f32 = if (width < 900) 405 else 575;
            try r.textFit(font, title_x, 12, @max(0, width - title_x - 322), self.compatibility_info.title(&title), theme.weak);
        }
        r.clip = all;
        {
            // Run state as a pill: tinted fill and border in the state's color.
            var buffer: [64]u8 = undefined;
            const label_text = std.fmt.bufPrint(&buffer, "#{d} {s}  PID {d}", .{ header.process, if (core) "core" else @tagName(state), display.snapshot.pid }) catch "";
            const color = switch (state) {
                .stopped => theme.warm,
                .running => theme.good,
                else => theme.weak,
            };
            const pill_width = r.measure(font, label_text) + 28;
            const pill = gpu.Rect{ .x = width - pill_width - 8, .y = 9, .w = pill_width, .h = 26 };
            try style.box(r, pill, style.fade(color, 0.10), style.fade(color, 0.45), @splat(13));
            try r.text(font, pill.x + 14, 12, label_text, color);
        }
        try style.button(r, font, gpuRect(self.layout.flames), if (self.show_profile) "Source" else "Flames", "F", theme.warm, 0, 0);
        self.layout_report.control("Flames", "F", self.layout.flames, false);
        for (buttons, 0..) |b, i| {
            const bounds = self.layout.toolbar[i];
            self.layout_report.control(b.label, b.key, bounds, bounds.w == 0);
            if (bounds.w == 0) continue;
            const label_text: []const u8 = switch (b.code) {
                57 => if (core) "Read-only" else switch (state) {
                    .running => "Pause",
                    .stopped => if (header.pending_continue) "Cancel" else "Continue",
                    .exited => "Exited",
                    .idle => "No target",
                },
                66 => if (header.scope == .observe) "Agent: observe" else "Agent: control",
                else => b.label,
            };
            const live = (!core or b.code == 34) and (state == .stopped or (state == .running and (b.code == 57 or b.code == 32 or b.code == 66)));
            const color = if (!live) theme.weak else if (b.code == 57) theme.good else if (b.code == 66 and header.scope != .observe) theme.warm else theme.text;
            try style.button(r, font, gpuRect(bounds), label_text, b.key, color, if (live) self.hot[i] else 0, self.pressed[i]);
        }
        if (self.layout.more.w > 0) {
            try style.button(r, font, gpuRect(self.layout.more), "More", "", theme.text, 0, 0);
            self.layout_report.control("More", "", self.layout.more, false);
        } else {
            _ = try style.chip(r, font, 822, 54, "TAB", theme.weak);
            try r.text(font, 872, 55, "panes", theme.weak);
        }
        const left = self.layout.left;
        const right = self.layout.right;
        const bottom = if (self.show_profile) @round(height * profile_split) else self.bottomY(height);
        const body_y: f32 = look.frame.body_y;
        const timeline_bounds = gpu.Rect{ .x = 8, .y = bottom, .w = width - 16, .h = height - bottom - 37 };
        if (self.show_profile) {
            try self.flame.draw(r, font, .{ .x = 8, .y = body_y, .w = width - 16, .h = bottom - body_y - 5 });
        } else {
            try self.drawDebuggerColumns(r, font, left, right, bottom, body_y, state, display.architecture, thread_color);
            if (self.layout.visible(.registers)) {
                const side = gpuRect(self.layout.rect(.registers));
                try self.language_panel.header(r, font, side, language);
                for (self.language_panel.hits, 0..) |hit, i| if (hit) |b| {
                    self.layout_report.control(@tagName(@import("../model/language_tabs.zig").order[i]), "Tab", .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h }, false);
                };
                const content_y = self.language_panel.content_y;
                if (language.selected == .native or language.selected == .registers) {
                    try self.drawNativeValues(r, font, side, content_y, bottom, language.selected, thread_color);
                } else {
                    try self.language_panel.drawBody(r, font, side, language, self.selected_frame, self.locals, self.local_diagnostic);
                }
            }
        }
        if (self.show_profile) {
            try self.timeline.drawPrepared(r, font, timeline_bounds);
            try self.inspector.draw(r, font, .{ .x = 8, .y = body_y, .w = width - 16, .h = height - body_y - 37 });
            if (self.setup.open) {
                const capture = self.capture_view;
                if (self.thread_selection.sync(&capture.snapshot) == .cleared_replaced) self.setup.message = "The target changed; the earlier thread choice was cleared";
                try self.setup.draw(r, font, .{ .x = 8, .y = body_y, .w = width - 16, .h = height - body_y - 37 }, .{ .snapshot = &capture.snapshot, .defaults = capture.defaults, .selection = &self.thread_selection, .facts = capture.facts, .clock = .{ .now_ns = linux.now() }, .start_error = capture.start_error, .start_failure = capture.start_failure, .requested_threads = capture.requested_threads });
            }
        } else try self.drawBottom(r, font, display.threads, display.events, display.signal_table, width, height, left, bottom, thread_color);
        r.clip = all;
        if (!self.show_profile) for (self.layout.tabs, 0..) |b, i| {
            if (b.w == 0) continue;
            try style.button(r, font, gpuRect(b), look.pane_tab_names[i], look.pane_keys[i], theme.weak, 0, 0);
            self.layout_report.control(look.pane_names[i], look.pane_keys[i], b, false);
        };
        try r.rect(.{ .x = 0, .y = height - 28, .w = width, .h = 28 }, self.bar);
        try r.rect(.{ .x = 0, .y = height - 28, .w = width, .h = 1 }, theme.status_border);
        const pending_metadata = header.metadata;
        if (self.fd_event_state != .inactive) {
            const message = if (self.fd_event_state == .active)
                (if (width >= 1100) "Exact FD capture ACTIVE: exact mode slows all syscalls on this machine by roughly 10 % while active" else "Exact FD capture ACTIVE: all host syscalls roughly 10 % slower")
            else
                "Exact FD capture requested: all host syscalls roughly 10 % slower while active";
            try fit(r, font, 16, height - look.workspace.footer_text, width - 32, theme.warm, "{s}", .{message});
        } else if (header.frame_failure) |err| {
            try fit(r, font, 16, height - look.workspace.footer_text, if (width >= 900) width - 432 else width - 32, theme.warm, "Archive frames {s}: {s} / L details", .{ header.frame_state, err });
        } else if (pending_metadata) |job| {
            if (job.kind == .image)
                try fit(r, font, 16, height - look.workspace.footer_text, if (width >= 900) width - 432 else width - 32, theme.text, "Image: {d}/{d} MiB, {d} MiB transferred / Esc cancels", .{ job.image_bytes / (1024 * 1024), job.image_total / (1024 * 1024), job.source_bytes / (1024 * 1024) })
            else
                try fit(r, font, 16, height - look.workspace.footer_text, if (width >= 900) width - 432 else width - 32, theme.text, "Debug data: {s}, {d} units, {d} MiB read", .{ job.state, job.units, job.source_bytes / (1024 * 1024) });
        } else if (self.shared_clients) |count| {
            if (self.shared_controller) |owner| {
                try fit(r, font, 16, height - look.workspace.footer_text, if (width >= 900) width - 432 else width - 32, theme.text, "{s} / agent {s} / controller #{d} / {d} clients", .{ self.status, @tagName(header.scope), owner, count });
            } else {
                try fit(r, font, 16, height - look.workspace.footer_text, if (width >= 900) width - 432 else width - 32, theme.text, "{s} / agent {s} / no controller / {d} clients", .{ self.status, @tagName(header.scope), count });
            }
        } else {
            try fit(r, font, 16, height - look.workspace.footer_text, if (width >= 900) width - 432 else width - 32, theme.text, "{s}  /  agent {s}  /  generation {d}", .{ self.status, @tagName(header.scope), display.snapshot.generation });
        }
        if (width >= 900 and self.fd_event_state == .inactive) try r.text(font, width - 400, height - look.workspace.footer_text, std.mem.sliceTo(@as([]const u8, &r.gpu_name), 0), style.fade(theme.text, 0.55));
        if (!self.show_profile and self.layout.visible(.source) and self.layout.visible(.assembly)) try r.rect(.{ .x = left - 3, .y = body_y, .w = 3, .h = bottom - body_y - 5 }, if (self.dragging) theme.focus else if (self.divider_hot) style.fade(theme.focus, 0.55) else style.fade(theme.border, 0.6));
        try self.probes_panel.draw(r, font, width, height);
        try self.inspection_panel.draw(r, font, width, height);
        try self.runtime_type_panel.drawPrepared(r, font, width, height);
        try self.inline_panel.draw(r, font, width, height);
        try self.static_panel.drawPrepared(r, font, width, height);
        if (self.static_panel.open and self.static_panel.running) self.animating = true;
        try self.stop_panel.draw(r, font, width, height, self.stop_view);
        if (self.show_profile) try self.syscall_panel.draw(r, font, width, height);
        try self.allocation_panel.drawLive(r, font, width, height);
        if (self.allocation_panel.open and self.allocation_panel.mode == .heap and self.allocation_panel.heap_pending) self.animating = true;
        if (self.allocation_save_editor.open) {
            const b = gpu.Rect{ .x = 32, .y = 102, .w = @max(0, width - 64), .h = 92 };
            try style.box(r, b, theme.background, theme.focus, @splat(6));
            try r.textFit(font, b.x + 10, b.y + 8, b.w - 20, "Save allocation archive: enter a new file path; Enter saves, Esc cancels", theme.text);
            try self.allocation_save_editor.draw(r, font, .{ .x = b.x + 10, .y = b.y + 34, .w = b.w - 20, .h = 22 });
            try r.textFit(font, b.x + 10, b.y + 61, b.w - 20, self.allocation_save_editor.message, theme.warm);
        }
        try self.process_panel.draw(r, font, width, height);
        r.clip = all;
        if (self.more_open) {
            // An opaque sheet: pane text must not show between the menu rows.
            var rows: f32 = 0;
            for (self.layout.toolbar) |b| rows += @floatFromInt(@intFromBool(b.w == 0));
            const sheet = look.Rect{ .x = width - look.overflow.width - 2 * look.overflow.margin, .y = look.overflow.top - 6, .w = look.overflow.width + 2 * look.overflow.margin, .h = rows * look.overflow.row + 12 - (look.overflow.row - look.overflow.height) };
            if (rows > 0) try style.box(r, gpuRect(sheet), theme.background, theme.border, @splat(8));
        }
        if (self.more_open) for (buttons, 0..) |b, i| {
            if (self.layout.toolbar[i].w != 0) continue;
            const bounds = self.menuRect(i, width);
            try style.button(r, font, gpuRect(bounds), b.label, b.key, theme.text, 0, 0);
            self.layout_report.control(b.label, b.key, bounds, false);
        };
        // Full values are available without changing the selected debug frame.
        for (self.layout_report.rows[0..self.layout_report.row_count]) |row| {
            if (!row.value_elided or !row.rect.contains(w.pointer_x, w.pointer_y)) continue;
            const text = std.mem.sliceTo(&row.value, 0);
            const tw = @min(width - 2 * look.tooltip.margin, r.measure(font, text) + 2 * look.tooltip.padding);
            const th = @min(height - look.tooltip.top - 40, (@ceil(r.measure(font, text) / (tw - 2 * look.tooltip.padding)) + 1) * look.tooltip.row + look.tooltip.padding);
            const tip = gpu.Rect{ .x = std.math.clamp(w.pointer_x, look.tooltip.margin, width - tw - look.tooltip.margin), .y = @max(look.tooltip.top, @min(row.rect.y - th - 4, height - th - 40)), .w = tw, .h = th };
            try style.box(r, tip, theme.header, theme.focus, @splat(4));
            try r.textWrap(font, .{ .x = tip.x + look.tooltip.padding, .y = tip.y + 5, .w = tip.w - 2 * look.tooltip.padding, .h = tip.h - 10 }, text, theme.text);
            break;
        }
    }
    /// Pure source, assembly and flow painting from the bound presentation.
    pub fn drawDebuggerColumns(self: *Workspace, r: *gpu.Renderer, font: *Font, left: f32, right: f32, bottom: f32, body_y: f32, state: linux.State, architecture: @import("../target/arch.zig").Arch, thread_color: gpu.Color) !void {
        if (self.layout.visible(.source)) {
            const source_rect = gpu.Rect{ .x = 8, .y = body_y, .w = left - 12, .h = bottom - body_y - 5 };
            try pane(r, font, source_rect, if (self.source_remote) "SOURCE / remote copy" else if (self.source_truncated) "SOURCE (first 1 MiB)" else if (self.browse_address != null) "SOURCE / browsing" else "SOURCE", std.fs.path.basename(self.source_path));
            if (self.source.len == 0) {
                try r.textWrap(font, .{ .x = 24, .y = body_y + 48, .w = source_rect.w - 32, .h = source_rect.h - 58 }, "Open a file with --source <path>. Stop in code with DWARF to follow source.", theme.weak);
            } else {
                var lines = std.mem.splitScalar(u8, self.source, '\n');
                var number: i32 = 0;
                var y: f32 = look.workspace.source_y;
                var more = false;
                while (lines.next()) |source| : (number += 1) {
                    if (number < self.source_line) continue;
                    if (y + 20 > bottom - 10) {
                        more = source.len != 0 or lines.rest().len != 0;
                        break;
                    }
                    const line_number: u32 = @intCast(number + 1);
                    const row = gpu.Rect{ .x = 9, .y = y - 2, .w = left - 14, .h = look.workspace.code_row };
                    const current = self.current_line != null and self.current_line.? == line_number;
                    const has_breakpoint = std.mem.indexOfScalar(u32, self.breakpoint_lines, line_number) != null;
                    if (has_breakpoint) {
                        const red = style.fade(theme.breakpoint, 0.13);
                        try r.shape(row, red, .{ .colors = .{ red, style.fade(red, 0), red, style.fade(red, 0) } });
                    }
                    if (self.cursor_line == line_number) {
                        if (@import("../appearance.zig").active.block_selection) try style.focus(r, row, 0, 1) else try r.rect(row, style.fade(theme.focus, 0.08));
                    }
                    if (current) {
                        try style.threadLine(r, row, if (self.browse_address != null) theme.focus else thread_color, self.alive, 16);
                        try r.text(font, 24, y, if (self.browse_address != null) "\u{25c6}" else "\u{25b6}", if (self.browse_address != null) theme.focus else thread_color);
                    }
                    if (has_breakpoint) {
                        try style.disc(r, 16, y + 9.5, 5, theme.breakpoint);
                    } else if (self.hover_line == line_number and state == .stopped) {
                        try style.disc(r, 16, y + 9.5, 5, style.fade(theme.breakpoint, 0.3));
                    }
                    try label(r, font, 36, y, if (current) (if (self.browse_address != null) theme.focus else thread_color) else theme.weak, "{d: >4}", .{line_number});
                    const trimmed = std.mem.trimStart(u8, source, " \t");
                    const color = if (std.mem.startsWith(u8, trimmed, "#")) theme.neutral else if (std.mem.startsWith(u8, trimmed, "//")) theme.weak else theme.text;
                    var expanded: [1024]u8 = undefined;
                    try r.textFit(font, 88, y, left - 14 - 88, expandTabs(&expanded, source[0..@min(source.len, 512)]), color);
                    y += look.workspace.code_row;
                }
                if (more) try style.fadeBottom(r, .{ .x = source_rect.x + 1, .y = source_rect.y, .w = source_rect.w - 2, .h = source_rect.h - 1 }, 0.55);
            }
        }
        if (!self.layout.visible(.assembly)) {
            self.assembly_rows.count = 0;
            self.static_panel.decompile_rows.count = 0;
            return;
        }
        if (self.static_panel.decompile_open) {
            try self.drawPseudoC(r, font, left, right, bottom, body_y, thread_color);
        } else if (self.show_flow) {
            try pane(r, font, .{ .x = left + 2, .y = body_y, .w = right - left - 6, .h = bottom - body_y - 5 }, "CONTROL FLOW", "G assembly");
            try self.flow.draw(r, font, r.clip, if (self.regs) |regs| linux.programCounter(regs) catch null else null);
        } else {
            var arch_subtitle: [64]u8 = undefined;
            const assembly_detail = if (self.browse_address != null)
                "browsing / G flow"
            else
                std.fmt.bufPrint(&arch_subtitle, "{s} / G flow", .{@tagName(architecture)}) catch "G flow";
            try pane(r, font, .{ .x = left + 2, .y = body_y, .w = right - left - 6, .h = bottom - body_y - 5 }, "ASSEMBLY", assembly_detail);
            if (self.instruction_count == 0) {
                var unavailable: [96]u8 = undefined;
                const message = if (self.assembly_error) |name|
                    std.fmt.bufPrint(&unavailable, "assembly unavailable: {s}", .{name}) catch "assembly unavailable"
                else
                    "Pause to inspect instructions";
                try r.text(font, left + 16, body_y + 55, message, theme.weak);
            }
            const current_pc = if (self.regs) |regs| linux.programCounter(regs) catch null else null;
            self.assembly_rows = .{ .x = left + 2, .y = body_y + 45, .w = right - left - 6, .count = 0 };
            for (self.instructions[0..self.instruction_count], 0..) |inst, i| {
                const y = body_y + 45 + @as(f32, @floatFromInt(i)) * look.workspace.code_row;
                if (y + 20 > bottom - 10) break;
                self.assembly_rows.count = i + 1;
                var pseudo_selected = false;
                for (self.static_panel.decompile_pcs.items) |pc| if (pc == inst.address) {
                    pseudo_selected = true;
                    break;
                };
                if ((self.assembly_cursor == inst.address and !self.static_from_line) or pseudo_selected) try style.focus(r, .{ .x = left + 4, .y = y - 2, .w = right - left - 10, .h = look.workspace.code_row }, 4, 1);
                if (current_pc != null and inst.address == current_pc.?) {
                    try style.threadLine(r, .{ .x = left + 3, .y = y - 2, .w = right - left - 8, .h = look.workspace.code_row }, thread_color, self.alive, 16);
                    try r.text(font, left + 8, y, "\u{25b6}", thread_color);
                }
                try label(r, font, left + 22, y, if (current_pc != null and inst.address == current_pc.?) thread_color else theme.weak, "{x:0>12}", .{inst.address});
                const mnemonic = std.mem.sliceTo(@as([]const u8, &inst.mnemonic), 0);
                try r.text(font, left + 156, y, mnemonic, theme.neutral);
                try r.textFit(font, left + 156 + @max(58, r.measure(font, mnemonic) + 10), y, right - left - 6 - 156 - 70, std.mem.sliceTo(@as([]const u8, &inst.operands), 0), theme.text);
            }
        }
    }

    fn pseudoColor(kind: []const u8) gpu.Color {
        if (std.mem.eql(u8, kind, "type")) return theme.neutral;
        if (std.mem.eql(u8, kind, "funcname")) return theme.good;
        if (std.mem.eql(u8, kind, "op")) return theme.warm;
        if (std.mem.eql(u8, kind, "syntax")) return theme.weak;
        return theme.text;
    }

    fn drawPseudoC(self: *Workspace, r: *gpu.Renderer, font: *Font, left: f32, right: f32, bottom: f32, body_y: f32, thread_color: gpu.Color) !void {
        const rect = gpu.Rect{ .x = left + 2, .y = body_y, .w = right - left - 6, .h = bottom - body_y - 5 };
        try pane(r, font, rect, "PSEUDO-C", "D assembly / [ ] horizontal / S queries");
        const current_pc = if (self.regs) |regs| linux.programCounter(regs) catch null else null;
        // The pane follows the stop: a new stop drops the old selection, and
        // one outside the shown function reopens the pane there.
        if (current_pc) |pc| if (self.static_panel.decompile_stop != pc) {
            if (self.static_panel.decompile_stop != null) self.assembly_cursor = null;
            self.static_panel.decompile_stop = pc;
            const shown = self.static_panel.decompileView();
            if (shown == null or shown.?.status != .ready or pc -% shown.?.function_entry >= shown.?.function_size) self.static_panel.showDecompile(.{ .pc = pc });
        };
        const view = self.static_panel.decompileView() orelse {
            try r.textFit(font, left + 16, body_y + 55, rect.w - 28, "Preparing pseudo-C…", theme.weak);
            self.static_panel.decompile_rows = .{};
            return;
        };
        if (view.status != .ready) {
            try r.textFit(font, left + 16, body_y + 53, rect.w - 28, view.title, if (view.status == .pending) theme.text else theme.breakpoint);
            try r.textFit(font, left + 16, body_y + 79, rect.w - 28, view.detail, theme.weak);
            self.static_panel.decompile_rows = .{};
            if (view.status == .pending) self.animating = true;
            return;
        }
        try r.textFit(font, left + 14, body_y + look.workspace.pseudo_qualification_y, rect.w - 24, view.pseudo_qualification, if (view.unreliable) theme.breakpoint else theme.weak);
        try r.textFit(font, left + 14, body_y + 58, rect.w - 24, if (view.pseudo_cut) "pane document capped" else if (!std.mem.eql(u8, view.pseudo_token_status, "ok")) "token map incomplete: some text has no colours or PCs" else view.pseudo_reasons, if (view.pseudo_cut or !std.mem.eql(u8, view.pseudo_token_status, "ok")) theme.warm else theme.weak);
        var observed: [384]u8 = undefined;
        const observed_prefix = "observed now";
        @memcpy(observed[0..observed_prefix.len], observed_prefix);
        var observed_len: usize = observed_prefix.len;
        var observed_count: usize = 0;
        for (view.pseudo_values) |value| {
            if (observed_count == 6) break;
            const written = std.fmt.bufPrint(observed[observed_len..], "  {s}={s}", .{ value.name, value.display }) catch break;
            observed_len += written.len;
            observed_count += 1;
        }
        for (self.locals) |local| if (local.parameter and local.value.availability == .available and observed_count < 6) {
            var duplicate = false;
            for (view.pseudo_values) |value| if (std.mem.eql(u8, value.name, local.name)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            const written = std.fmt.bufPrint(observed[observed_len..], "  {s}={s}", .{ local.name, local.value.display }) catch break;
            observed_len += written.len;
            observed_count += 1;
        };
        if (observed_count > 0) try r.textFit(font, left + 14, body_y + 77, rect.w - 24, observed[0..observed_len], theme.thread_main);
        var lines = std.mem.splitScalar(u8, view.pseudocode, '\n');
        var line_number: u32 = 1;
        const first = self.static_panel.decompile_first;
        const start_y = body_y + 105;
        var shown: usize = 0;
        self.static_panel.syncDecompilePC(self.assembly_cursor orelse current_pc);
        while (lines.next()) |line| : (line_number += 1) {
            if (line_number < first) continue;
            const y = start_y + @as(f32, @floatFromInt(shown)) * look.workspace.code_row;
            if (y + 20 > bottom - 10) break;
            shown += 1;
            const row = gpu.Rect{ .x = left + 4, .y = y - 2, .w = rect.w - 6, .h = look.workspace.code_row };
            var current = false;
            if (view.pseudo_entry_pad) |pad| {
                if (current_pc) |pc| current = line_number == pad.line and pc >= pad.start and pc < pad.end;
            }
            var breakpoint = false;
            for (view.pseudo_tokens) |token| if (token.line == line_number) {
                if (token.pc == current_pc) current = true;
                if (token.source) |site| {
                    if (std.mem.eql(u8, site.path, self.source_path) and std.mem.indexOfScalar(u32, self.breakpoint_lines, site.line) != null) breakpoint = true;
                }
            };
            if (breakpoint) try r.rect(row, style.fade(theme.breakpoint, 0.11));
            if (self.static_panel.decompile_line == line_number) try style.focus(r, row, 2, 1);
            if (current) {
                try style.threadLine(r, row, thread_color, self.alive, 16);
                try r.text(font, left + 8, y, "\u{25b6}", thread_color);
            } else if (breakpoint) try style.disc(r, left + 14, y + 9.5, 4, theme.breakpoint);
            try label(r, font, left + 23, y, if (current) thread_color else theme.weak, "{d: >3}", .{line_number});

            // One exact live-value annotation per row. Reserve its column
            // before drawing code so the static text and observed value never
            // paint over one another.
            var annotation_name: ?[]const u8 = null;
            var annotation_display: []const u8 = "";
            for (view.pseudo_tokens) |token| if (token.line == line_number and std.mem.eql(u8, token.kind, "variable")) {
                for (view.pseudo_values) |value| if (std.mem.eql(u8, value.name, token.text)) {
                    annotation_name = value.name;
                    annotation_display = value.display;
                    break;
                };
                if (annotation_name != null) break;
                if (token.parameter) |wanted| {
                    var ordinal: u32 = 0;
                    for (self.locals) |local| if (local.parameter) {
                        if (ordinal == wanted) {
                            if (local.value.availability == .available) {
                                annotation_name = local.name;
                                annotation_display = local.value.display;
                            }
                            break;
                        }
                        ordinal += 1;
                    };
                } else for (self.locals) |local| if (std.mem.eql(u8, local.name, token.text) and local.value.availability == .available) {
                    annotation_name = local.name;
                    annotation_display = local.value.display;
                    break;
                };
                if (annotation_name != null) break;
            };
            var note: [192]u8 = undefined;
            var note_text: []const u8 = "";
            var note_w: f32 = 0;
            if (annotation_name) |name| {
                note_text = std.fmt.bufPrint(&note, "{s} = {s}", .{ name, annotation_display }) catch "";
                note_w = @min(rect.w * 0.30, r.measure(font, note_text) + 10);
                // The code comes first: a value that would cut it stays on the "observed now" row.
                if (left + 62 + r.measure(font, line) > right - 24 - note_w) note_text = "";
            }
            const note_x = right - 8 - note_w;
            const code_right = if (note_text.len > 0) note_x - 8 else right - 8;
            var x = left + 62;
            var col = @min(self.static_panel.decompile_column, line.len);
            while (col < line.len and line[col] & 0xc0 == 0x80) col += 1;
            for (view.pseudo_tokens) |token| if (token.line == line_number) {
                const token_col: usize = token.col;
                if (token_col < col or token_col > line.len) continue;
                if (token_col > col) {
                    const gap = line[col..token_col];
                    try r.textFit(font, x, y, @max(0, code_right - x), gap, theme.text);
                    x += r.measure(font, gap);
                }
                if (x < code_right) try r.textFit(font, x, y, code_right - x, token.text, pseudoColor(token.kind));
                x += r.measure(font, token.text);
                col = @min(line.len, token_col + token.text.len);
            };
            if (col < line.len and x < code_right) try r.textFit(font, x, y, code_right - x, line[col..], theme.text);
            if (note_text.len > 0) {
                try r.rect(.{ .x = note_x - 4, .y = y - 1, .w = note_w + 4, .h = 20 }, style.fade(theme.thread_main, 0.16));
                try r.textFit(font, note_x, y, note_w, note_text, theme.thread_main);
            }
        }
        self.static_panel.decompile_rows = .{ .x = rect.x, .y = start_y, .w = rect.w, .count = shown };
        if (shown == 0) try r.textFit(font, left + 16, start_y, rect.w - 28, if (view.pseudocode.len == 0) "The worker returned no pseudo-C text" else "No pseudo-C rows in this viewport", theme.weak);
    }
    /// Pure locals/register painting. Language inspection is prepared separately.
    pub fn drawNativeValues(self: *Workspace, r: *gpu.Renderer, font: *Font, side: gpu.Rect, content_y: f32, bottom: f32, tab: @import("../model/language_tabs.zig").Tab, thread_color: gpu.Color) !void {
        const right = side.x - 2;
        if (tab == .native) {
            if (self.local_diagnostic) |diagnostic| try r.textWrap(font, .{ .x = right + 14, .y = content_y + 4, .w = side.w - 24, .h = bottom - content_y - 14 }, diagnostic, theme.weak);
            for (self.locals, 0..) |local, i| {
                const y = content_y + @as(f32, @floatFromInt(i)) * look.workspace.local_row;
                if (y + 40 > bottom - 10) break;
                if (i == self.selected_local) try style.focus(r, .{ .x = right + 6, .y = y - 3, .w = side.w - 8, .h = look.workspace.local_focus }, 6, 1);
                try r.textFit(font, right + 14, y, side.w - 24, local.name, theme.neutral);
                const type_x = right + 14 + r.measure(font, local.name) + 14;
                const advisory = if (local.value.visualization) |v| v.extent_advisory else false;
                try r.textFit(font, type_x, y, side.x + side.w - 10 - type_x, if (advisory) "extent unproved" else local.value.type, theme.weak);
                try r.textFit(font, right + 14, y + 21, side.w - 24, local.value.display, if (local.value.availability == .available and !advisory) theme.text else theme.weak);
                self.layout_report.row("Values", .{ .x = right + 14, .y = y + 21, .w = side.w - 24, .h = 21 }, local.name, local.value.display, r.measure(font, local.name) > side.w - 24, r.measure(font, local.value.display) > side.w - 24, false);
            }
        } else if (tab == .registers) {
            const restart_slot = if (self.regs) |regs| regs.architecture() == .loongarch64 else false;
            const register_y = content_y + @as(f32, if (restart_slot) look.workspace.code_row else 0);
            if (restart_slot) try r.textFit(font, right + 14, content_y, side.w - 24, "r0 is the kernel restart slot", theme.weak);
            if (self.regs) |regs| {
                for (regs.descriptions(), 0..) |desc, i| {
                    const y = register_y + @as(f32, @floatFromInt(i)) * look.workspace.code_row;
                    if (y + 21 > bottom - 10) break;
                    const value = regs.value(desc) catch null;
                    const previous = if (self.stale_regs) |old| if (old.architecture() == regs.architecture()) old.value(desc) catch null else null else null;
                    const changed = value != null and previous != null and value.? != previous.?;
                    const name = std.mem.span(desc.name);
                    var buffer: [32]u8 = undefined;
                    const text = if (value) |word| try std.fmt.bufPrint(&buffer, "0x{x}", .{word}) else "—";
                    const value_width = @min(side.w - 58, r.measure(font, text));
                    const value_x = side.x + side.w - 12 - value_width;
                    const name_width = @max(0, value_x - right - 22);
                    if (changed) try r.shape(.{ .x = value_x - 4, .y = y - 2, .w = value_width + 8, .h = look.workspace.code_row }, theme.fresh, .{ .radii = @splat(5) });
                    try r.textFit(font, right + 14, y, name_width, name, theme.weak);
                    try r.textFit(font, value_x, y, value_width, text, if (i == 0) thread_color else if (changed) theme.warm else theme.text);
                    self.layout_report.row("Values", .{ .x = right + 14, .y = y, .w = side.w - 24, .h = 21 }, name, text, r.measure(font, name) > name_width, r.measure(font, text) > value_width, false);
                }
            } else try r.text(font, right + 14, content_y + 10, "No stopped thread", theme.weak);
        }
    }
    /// Threads, stack and events, below the source view.
    pub fn drawBottom(self: *Workspace, r: *gpu.Renderer, font: *Font, threads: []const linux.Thread, events: []const linux.Event, signal_table: linux.SignalTable, _: f32, _: f32, _: f32, bottom: f32, thread_color: gpu.Color) !void {
        const wine = self.compatibility_info.kind == .wine;
        const darwin = self.thread_labels.len > 0 and self.thread_labels[0].source == .gdb_thread_info;
        const thread_rect = gpuRect(self.layout.rect(.threads));
        const thread_right = thread_rect.x + thread_rect.w + 4;
        const row_step = self.rowStep();
        if (self.layout.visible(.threads)) {
            const hint = if (!wine) "J/K to select" else if (self.thread_list.hide_internal) "H show" else "H hide";
            try pane(r, font, thread_rect, "THREADS", hint);
            if (wine or darwin) {
                try self.thread_list.draw(r, font, .{ .x = 12, .y = bottom + 42, .w = thread_right - 20, .h = @max(0, thread_rect.h - 50) }, threads, self.thread_labels, self.selected);
            } else {
                const thread_rows: usize = @intFromFloat(@max(0, (thread_rect.h - 50) / row_step));
                const first_thread = (self.selected + 1) -| thread_rows;
                for (threads, 0..) |thread, i| {
                    if (i < first_thread) continue;
                    if (i - first_thread >= thread_rows) break;
                    const y = bottom + 44 + @as(f32, @floatFromInt(i - first_thread)) * row_step;
                    if (i == self.selected) try style.focus(r, .{ .x = 12, .y = y - look.workspace.focus_top, .w = thread_right - 20, .h = row_step }, 6, 1);
                    try style.disc(r, 25, y + 9.5, 4, style.fade(style.threadColor(thread.id), if (thread.state == .running) 0.5 else 1));
                    var id_buffer: [32]u8 = undefined;
                    const id_text = try std.fmt.bufPrint(&id_buffer, "{d}", .{thread.tid});
                    const id_width = r.measure(font, id_text);
                    try r.text(font, 40, y, id_text, if (i == self.selected) theme.text else theme.weak);
                    const state_text = if (thread.reason != .none and thread.state == .stopped) @tagName(thread.reason) else @tagName(thread.state);
                    const state_width = @max(0, thread_right - 60 - id_width);
                    try r.textFit(font, 48 + id_width, y, state_width, state_text, theme.weak);
                    self.layout_report.row("Threads", .{ .x = 40, .y = y, .w = thread_right - 52, .h = row_step }, state_text, id_text, r.measure(font, state_text) > state_width, false, true);
                }
            }
            if (threads.len == 0) try r.textWrap(font, .{ .x = 24, .y = bottom + 44, .w = thread_right - 40, .h = thread_rect.h - 54 }, "Launch with -- <executable> [args]", theme.weak);
        }
        const stack = gpuRect(self.layout.rect(.stack));
        if (self.layout.visible(.stack)) {
            try pane(r, font, stack, "STACK", "click frame / I inline");
            for (self.frames, 0..) |frame, i| {
                const y = bottom + 44 + @as(f32, @floatFromInt(i)) * row_step;
                if (y + row_step > stack.y + stack.h - 4) break;
                if (i == self.selected_frame) try style.focus(r, .{ .x = stack.x + 4, .y = y - look.workspace.focus_top, .w = stack.w - 8, .h = row_step }, 6, 1);
                try label(r, font, stack.x + 12, y, if (i == 0) thread_color else theme.weak, "{d: >2}", .{i});
                // Frames without source are dimmed; frames with it show where.
                var where_buffer: [96]u8 = undefined;
                const where = if (frame.source) |site| std.fmt.bufPrint(&where_buffer, "{s}:{d}", .{ std.fs.path.basename(site.path), site.line }) catch "" else "";
                const where_width = @min(stack.w * 0.4, r.measure(font, where));
                const name_width = stack.w - 54 - (if (where.len > 0 and stack.w > 330) where_width + 16 else 0);
                try fit(r, font, stack.x + 42, y, name_width, if (frame.source != null) theme.text else theme.weak, "{s} {s}", .{ frame.symbol orelse "?", frame.diagnostic orelse "" });
                if (where.len > 0 and stack.w > 330) try r.textFit(font, stack.x + stack.w - where_width - 12, y, where_width, where, theme.weak);
                self.layout_report.row("Stack", .{ .x = stack.x + 42, .y = y, .w = name_width, .h = row_step }, "", frame.symbol orelse "?", false, r.measure(font, frame.symbol orelse "?") > name_width, false);
            }
        }
        if (!self.layout.visible(.events)) {
            self.watch_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            return;
        }
        const events_rect = gpuRect(self.layout.rect(.events));
        if (self.show_watch and @intFromEnum(self.runtime_watch_view.selected_language) >= 2) {
            try pane(r, font, events_rect, "RUNTIME WATCHES", "W binding  Shift+E name  V events  [] scroll  Del remove");
            self.watch_rect = events_rect;
            if (self.watch_focus) try r.rect(.{ .x = events_rect.x + 1, .y = events_rect.y + 32, .w = events_rect.w - 2, .h = 2 }, theme.focus);
            try self.runtime_watch_panel.draw(self.runtime_watch_view, r, font, r.clip);
            return;
        }
        if (self.show_watch) {
            const wide = events_rect.w > 640;
            try pane(r, font, events_rect, "WATCH", if (self.editor.open) (if (self.editor.mode == .live) "Live / Up/Down history  Return add  Esc cancel" else "Pinned / Up/Down history  Return add  Esc cancel") else if (wide) "E/Shift+E add  V events  [] scroll  Shift+L convert  Del remove  Return expand  W write" else "E/Shift+E add  V events  [] scroll");
            if (self.watch_focus) try r.rect(.{ .x = events_rect.x + 1, .y = events_rect.y + 32, .w = events_rect.w - 2, .h = 2 }, theme.focus);
            self.watch_rect = events_rect;
            try watch_ui.draw(&self.watch_panel, self.watch_view, &self.editor, r, font, r.clip, &self.watch_hits);
            return;
        }
        self.watch_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        try pane(r, font, events_rect, "EVENTS", if (self.watch_view.entries.len > 0) "monotonic time  /  V watch" else "monotonic time  /  E expression");
        const visible: usize = @intFromFloat(@max(0, (events_rect.h - 50) / look.workspace.code_row));
        const start = events.len -| visible;
        for (events[start..], 0..) |event, i| {
            const y = bottom + 44 + @as(f32, @floatFromInt(i)) * look.workspace.code_row;
            if ((start + i) % 2 == 1) try r.rect(.{ .x = events_rect.x + 1, .y = y - 2, .w = events_rect.w - 2, .h = look.workspace.code_row }, theme.stripe);
            const ms = (event.time_ns - events[0].time_ns) / 1_000_000;
            // The kind column is as wide as the longest kind, so kinds stay whole
            // while the value keeps the rest of the row.
            const kind_x = events_rect.x + 106;
            const kind_width = @min(r.measure(font, "breakpoint_hit"), @max(0, events_rect.w * 0.5 - 118));
            const value_x = kind_x + kind_width + 12;
            const value_width = @max(0, events_rect.x + events_rect.w - 12 - value_x);
            try fit(r, font, events_rect.x + 14, y, 80, theme.weak, "+{d} ms", .{ms});
            const kind_color = switch (event.kind) {
                .stop => theme.warm,
                .breakpoint_hit, .watchpoint_hit => theme.breakpoint,
                .exit, .detach => theme.weak,
                else => theme.good,
            };
            try r.textFit(font, kind_x, y, kind_width, @tagName(event.kind), kind_color);
            var value_buffer: [256]u8 = undefined;
            const value_text = if (event.kind == .watchpoint_hit) value: {
                if (!event.before_valid or !event.after_valid or event.watch_attribution == .candidate) {
                    break :value try std.fmt.bufPrint(&value_buffer, "0x{x}: {s} / {s}", .{ event.address, @tagName(event.watch_phase), if (event.watch_attribution == .candidate) "candidate watch" else "value unavailable" });
                } else break :value try std.fmt.bufPrint(&value_buffer, "0x{x}: {d} -> {d}", .{ event.address, event.before, event.after });
            } else if (event.kind == .exit)
                (if (event.detail >= 0) try std.fmt.bufPrint(&value_buffer, "status {d}", .{event.detail}) else try std.fmt.bufPrint(&value_buffer, "{s} ({d})", .{ linux.signalNameIn(signal_table, std.math.cast(i32, -%event.detail) orelse 0), -%event.detail }))
            else if (event.kind == .image_replaced) "image changed; breakpoints removed" else try std.fmt.bufPrint(&value_buffer, "thread {d} · detail {d}", .{ event.tid, event.detail });
            try r.textFit(font, value_x, y, value_width, value_text, theme.text);
            self.layout_report.row("Events", .{ .x = value_x, .y = y, .w = value_width, .h = 21 }, @tagName(event.kind), value_text, r.measure(font, @tagName(event.kind)) > kind_width, r.measure(font, value_text) > value_width, false);
        }
    }
};

const TimelineSource = @import("../model/profile_timeline.zig").Source;

test "queued drag preserves release position and quit ends the batch" {
    var session = Session{ .id = 1 };
    defer session.deinit();
    var workspace = Workspace{};
    defer workspace.deinit();
    var w = Window{ .width = 1000, .height = 800, .pointer_x = 600, .pointer_y = 300 };
    workspace.updateLayout(&w);
    w.input.button(1, 272, true, workspace.layout.left, 300);
    w.input.button(2, 272, false, 600, 300);
    workspace.input(&w, &session);
    try std.testing.expectApproxEqAbs(@as(f32, 0.60), workspace.split, 0.001);
    try std.testing.expect(!workspace.dragging);
    w.mouse_down = true;
    w.input.button(3, 272, true, workspace.layout.left, 300);
    workspace.input(&w, &session);
    try std.testing.expect(workspace.dragging);
    // A key before a queued release must not observe the final button state
    // early and discard the last part of an existing drag.
    w.mouse_down = false;
    w.pointer_x = 550;
    w.input.head = 0;
    w.input.count = 1;
    w.input.queue[0] = .{ .kind = .press, .shortcut = 'j' };
    w.input.button(4, 272, false, 550, 300);
    workspace.input(&w, &session);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), workspace.split, 0.001);
    try std.testing.expect(!workspace.dragging);
    w.input.queue[0] = .{ .kind = .press, .shortcut = 'q', .mods = .{ .shift = true } };
    w.input.queue[1] = .{ .kind = .press, .shortcut = keys.sym.f8 };
    w.input.head = 0;
    w.input.count = 2;
    workspace.input(&w, &session);
    try std.testing.expect(w.closing);
    try std.testing.expectEqual(model.AgentScope.observe, session.agent_scope);
}

test "queued frame selection refreshes locals before starting a watch" {
    try @import("../test_support.zig").requireLive();
    var session = Session{ .id = 1 };
    defer session.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try session.target.launch(&.{ "./zig-out/bin/xodb-m1-fixture", "w" });
    _ = try session.setSourceBreakpoint(arena.allocator(), "tests/fixtures/m1.c", 10);
    try session.continueExecution(.human);
    // Exercise the same owner loop as the GUI: target-only waiting would expose
    // an internal loader rendezvous before session policy has consumed it.
    const deadline = linux.now() + 3_000_000_000;
    while (linux.now() < deadline) {
        try session.poll();
        if (session.target.snapshot().state == .stopped and !session.target.onlyInternalStops()) break;
        _ = @import("../c_ui.zig").api.usleep(1000);
    }
    try std.testing.expectEqual(linux.State.stopped, session.target.snapshot().state);
    var workspace = Workspace{};
    defer workspace.deinit();
    workspace.refresh(&session);
    try std.testing.expect(workspace.frames.len >= 2);
    var w = Window{};
    const x: f32 = 300;
    const y: f32 = @as(f32, @floatFromInt(w.height)) * 0.73 + 44 + 30;
    w.input.button(1, 272, true, x, y);
    w.input.button(2, 272, false, x, y);
    w.input.queue[2] = .{ .kind = .press, .shortcut = 'w' };
    w.input.count = 3;
    workspace.input(&w, &session);
    try std.testing.expectEqual(@as(usize, 1), workspace.selected_frame);
    try std.testing.expectEqual(@as(usize, 1), session.language_tabs.native_selection.?.frame);
    try std.testing.expectEqual(session.target.snapshot().generation, session.language_tabs.native_selection.?.generation);
    try std.testing.expectEqual(@as(usize, 1), session.investigations.items.len);
    try std.testing.expectEqualStrings(workspace.locals[0].name, session.investigations.items[0].expression);
}

test "timeline drag and lane click commit a flame filter; motion does not" {
    const a = std.testing.allocator;
    var session = Session{ .id = 1 };
    defer session.deinit();
    const capture = try a.create(profile.Capture);
    capture.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = 3, .session_id = 1, .generation = 0, .image_epoch = 0, .pid = 1, .started_ns = 1000, .ended_ns = 1000 + 1_000_000, .config = .{}, .accepted = undefined, .thread_count = 2, .collector = null, .images = @import("../model/modules.zig").Modules.init(a) };
    session.profile = capture;
    for (0..2) |i| {
        capture.threads[i] = .{ .debugger_id = i + 1, .perf = .{ .tid = @intCast(i + 41), .event_id = i + 1, .start_time_ticks = 1, .start_time_known = true } };
        _ = try std.fmt.bufPrintZ(&capture.thread_names[i], "Thread {d}", .{i + 41});
    }
    for (0..100) |i| try capture.samples.append(a, .{ .tid = @intCast(41 + i % 2), .tid_present = true, .time_ns = 1000 + i * 10_000, .time_present = true });
    // Invalid samples are excluded exactly as flames exclude them.
    try capture.samples.append(a, .{ .tid = 41, .tid_present = true, .time_ns = 999, .time_present = true });
    try capture.samples.append(a, .{ .tid = 77, .tid_present = true, .time_ns = 5000, .time_present = true });
    capture.addMarker(.{ .offset_ns = 0, .sequence = 1, .tid = 1, .kind = .capture_open_stopped });
    capture.addMarker(.{ .offset_ns = 100_000, .sequence = 2, .tid = 1, .kind = .continued });
    capture.addMarker(.{ .offset_ns = 600_000, .sequence = 3, .tid = 41, .kind = .stop });
    var workspace = Workspace{ .show_profile = true };
    defer workspace.deinit();
    const data = workspace.timeline_capture.source.refresh(capture).?;
    var lane_total: usize = 0;
    for (data.lanes) |lane| lane_total += lane.samples.len;
    try std.testing.expectEqual(100, lane_total);
    try std.testing.expectEqual(3, data.marks.len);
    try std.testing.expectEqual(@as(?u32, 41), data.marks[1].tid);
    try std.testing.expectEqual(@as(?u32, 42), data.marks[2].tid);
    try std.testing.expectEqual(100_000, data.marks[2].to_ns);
    try std.testing.expectEqual(timeline.Range{ .from_ns = 0, .to_ns = 100_000 }, timeline.Range{ .from_ns = data.marks[0].from_ns, .to_ns = data.marks[0].to_ns });
    try std.testing.expectEqual(data.extent_ns, data.marks[1].to_ns);
    // Geometry as drawn in a 1280x800 window.
    var w = Window{};
    const bottom = @round(@as(f32, @floatFromInt(w.height)) * profile_split);
    workspace.timeline.layout(.{ .x = 8, .y = bottom, .w = @as(f32, @floatFromInt(w.width)) - 16, .h = @as(f32, @floatFromInt(w.height)) - bottom - 37 }, data);
    const plot = workspace.timeline.geometry.plot;
    const y = plot.y + 5;
    w.input.button(1, 272, true, plot.x + plot.w * 0.25, y);
    workspace.input(&w, &session);
    // Motion previews without touching flames.
    w.pointer_x = plot.x + plot.w * 0.5;
    w.pointer_y = y;
    w.mouse_down = true;
    workspace.input(&w, &session);
    try std.testing.expectEqual(std.math.maxInt(u64), workspace.flame.selection.filter.to_ns);
    w.input.button(2, 272, false, plot.x + plot.w * 0.5, y);
    workspace.input(&w, &session);
    const f = workspace.flame.selection.filter;
    try std.testing.expect(f.from_ns > 200_000 and f.from_ns < 300_000 and f.to_ns > 450_000 and f.to_ns < 550_000);
    try std.testing.expectEqual(@as(?u32, null), f.tid);
    // A click on the second lane filters its thread and keeps the range.
    w.mouse_down = false;
    w.input.button(3, 272, true, plot.x + 30, plot.y + 24 + 5);
    w.input.button(4, 272, false, plot.x + 30, plot.y + 24 + 5);
    workspace.input(&w, &session);
    try std.testing.expectEqual(@as(?u32, 42), workspace.flame.selection.filter.tid);
    try std.testing.expectEqual(f.from_ns, workspace.flame.selection.filter.from_ns);
    // Ctrl state belongs to the queued press, even if it was released before dispatch.
    w.input.button(5, 272, true, plot.x + 30, plot.y + 5);
    w.input.queue[w.input.head].mods.ctrl = true;
    w.input.button(6, 272, false, plot.x + 30, plot.y + 5);
    workspace.input(&w, &session);
    try std.testing.expectEqualSlices(u32, &.{ 41, 42 }, workspace.flame.selection.filter.tids.slice());
    try std.testing.expectEqual(f.from_ns, workspace.flame.selection.filter.from_ns);
    // A newly enrolled lane must not inherit the opening all-stop interval.
    capture.threads[1].enrolled_ns = capture.started_ns + 200_000;
    capture.revision += 1;
    const dynamic = workspace.timeline_capture.source.refresh(capture).?;
    for (dynamic.marks) |mark| try std.testing.expect(mark.tid != 42);
    // A replacement capture clears both.
    capture.id = 4;
    const replaced = workspace.timeline_capture.source.refresh(capture).?;
    try std.testing.expect(workspace.timeline.sync(replaced));
    workspace.applyTimeline(&session);
    try std.testing.expectEqual(profile.Filter{}, workspace.flame.selection.filter);
}

test "timeline adapter bounds maximum scheduling and debugger overlay history" {
    const a = std.testing.allocator;
    const capture = try a.create(profile.Capture);
    capture.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = 1, .session_id = 1, .generation = 0, .image_epoch = 0, .pid = 1, .started_ns = 1000, .ended_ns = 1_000_000, .config = .{ .context_switch = true }, .accepted = undefined, .thread_count = 1024, .collector = null, .images = @import("../model/modules.zig").Modules.init(a) };
    defer capture.deinit();
    for (0..capture.thread_count) |i| {
        capture.threads[i] = .{ .debugger_id = i + 1, .perf = .{ .tid = @intCast(i + 1), .event_id = i + 1, .start_time_ticks = 1, .start_time_known = true } };
        for (0..256) |j| try capture.switches.add(a, i, .{ .offset_ns = j * 100, .direction = if (j % 2 == 0) .switch_in else .switch_out });
    }
    for (0..profile.max_samples) |i| try capture.samples.append(a, .{ .tid = @intCast(i % 1024 + 1), .tid_present = true, .time_present = true, .time_ns = 1000 + i });
    for (0..1024) |i| capture.addMarker(.{ .offset_ns = i * 100, .sequence = i, .tid = 1, .kind = if (i % 2 == 0) .capture_open_stopped else .continued });
    capture.syscalls.enabled = true;
    capture.syscalls.limit = 65536;
    for (0..65536) |i| try capture.syscalls.items.append(a, .{ .thread_index = @intCast(i % 32), .nr = 0, .exit_nr = 0, .entry_ns = 1000 + i * 10, .exit_ns = 1005 + i * 10, .result = 1, .reason = .complete });
    var source = TimelineSource{};
    defer source.deinit();
    const begin = linux.now();
    try source.build(capture);
    const data = source.data.?;
    try std.testing.expectEqual(1024, data.lanes.len);
    try std.testing.expectEqual(TimelineSource.max_stop_spans + 65536, data.marks.len);
    try std.testing.expectEqual(1024 * 512 - TimelineSource.max_stop_spans, data.debugger_marks_dropped);
    try std.testing.expect(data.lanes[1023].intervals.len > 250);
    var samples: usize = 0;
    for (data.lanes) |lane| samples += lane.samples.len;
    try std.testing.expectEqual(profile.max_samples, samples);
    var viewport = timeline.TimelineView{};
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const prepared = try viewport.prepare(arena.allocator(), 1, .{ .bounds = .{ .x = 8, .y = 512, .w = 1264, .h = 251 } }, &data);
    const boundary = @import("../model/remote_owner.zig");
    const publication = try boundary.Publication.create(a, .{ .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 1, .image_epoch = 0, .generation = 0 }, .revision = 1, .taken_ns = 1, .status = .ready, .timeline = prepared });
    defer publication.destroy();
    try std.testing.expect(publication.bytes < 256 * 1024);
    try std.testing.expectEqual(@as(usize, 65536), publication.value.timeline.?.data.syscall_count);
    var bucket_total: u64 = 0;
    for (publication.value.timeline.?.buckets) |bucket| bucket_total += bucket[0];
    try std.testing.expectEqual(@as(u64, profile.max_samples), bucket_total);
    _ = arena.reset(.free_all);
    source.clear();
    try std.testing.expectEqual(@as(usize, 0), source.arena.queryCapacity());
    try std.testing.expectEqual(@as(usize, 1024), publication.value.timeline.?.data.lanes.len);
    std.debug.print("timeline adapter maximum history: {d} us; {d} switch events, {d} total overlays\n", .{ (linux.now() - begin) / 1000, capture.switches.retained, data.marks.len });
}

test "duration shortcut works in a narrow profile view without changing target state" {
    var session = Session{ .id = 1 };
    defer session.deinit();
    var workspace = Workspace{ .show_profile = true };
    defer workspace.deinit();
    var w = Window{ .width = 640, .height = 480 };
    const generation = session.target.snapshot().generation;
    w.input.queue[0] = .{ .kind = .press, .shortcut = 't' };
    w.input.count = 1;
    workspace.input(&w, &session);
    try std.testing.expectEqual(@as(u32, 300000), session.profile_defaults.duration_ms);
    try std.testing.expectEqual(generation, session.target.snapshot().generation);
    session.offline = true;
    w.input.head = 0;
    w.input.queue[0] = .{ .kind = .press, .shortcut = 't' };
    w.input.count = 1;
    workspace.input(&w, &session);
    try std.testing.expectEqual(@as(u32, 300000), session.profile_defaults.duration_ms);
}

test "capture setup: S opens it, an empty subset never starts, replacement clears, offline is read-only" {
    var session = Session{ .id = 1 };
    defer session.deinit();
    // A synthetic target: clear it before teardown so cleanup never touches PID 4242.
    defer {
        session.target.testing().thread_count = 0;
        session.target.testing().pid = 0;
        session.target.testing().state = @intFromEnum(linux.State.idle);
    }
    session.target.testing().pid = 4242;
    session.target.testing().state = @intFromEnum(linux.State.stopped);
    session.target.testing().image_epoch = 1;
    for (0..3) |i| session.target.testing().threads[i] = std.mem.zeroInit(@TypeOf(session.target.testing().threads[i]), .{ .id = i + 1, .tid = @as(i32, @intCast(4242 + i)), .state = @intFromEnum(linux.State.stopped) });
    session.target.testing().thread_count = 3;
    // The synthetic inspection is already current. Setup/input assertions
    // must not issue register reads against invented operating-system PIDs.
    var workspace = Workspace{ .show_profile = true, .last_generation = session.target.snapshot().generation, .last_tid = 4242, .last_frame = 0 };
    defer workspace.deinit();
    var w = Window{};
    w.input.queue[0] = .{ .kind = .press, .shortcut = 's' };
    w.input.count = 1;
    workspace.input(&w, &session);
    try std.testing.expect(workspace.setup.open);
    // Choose a subset, then empty it: P must not fall back to all threads.
    const snapshot = workspace.capture_control.rows.snapshot(&session);
    _ = workspace.thread_selection.sync(&snapshot);
    workspace.applySetup(&w, &session, .start_subset);
    try std.testing.expectEqual(capture_setup.Mode.subset, workspace.thread_selection.mode);
    w.input.head = 0;
    w.input.queue[0] = .{ .kind = .press, .shortcut = 'p' };
    w.input.count = 1;
    workspace.input(&w, &session);
    try std.testing.expect(session.profile == null);
    try std.testing.expectEqualStrings(capture_setup.problemText(.empty_subset), workspace.status);
    // Next settings change without touching any capture.
    workspace.applySetup(&w, &session, .{ .set_frequency = 499 });
    workspace.applySetup(&w, &session, .toggle_scheduling);
    try std.testing.expectEqual(@as(u32, 499), session.profile_defaults.frequency_hz);
    try std.testing.expect(session.profile_defaults.context_switch);
    // exec: the explicit choice is cleared rather than matched by TID.
    workspace.applySetup(&w, &session, .{ .toggle_thread = .{ .id = 2, .tid = 4243 } });
    try std.testing.expectEqual(@as(usize, 1), workspace.thread_selection.count);
    session.target.testing().image_epoch = 2;
    const replaced = workspace.capture_control.rows.snapshot(&session);
    try std.testing.expectEqual(capture_setup.Notice.cleared_replaced, workspace.thread_selection.sync(&replaced));
    try std.testing.expectEqual(capture_setup.Mode.all, workspace.thread_selection.mode);
    // A P event queued for an earlier target cannot silently start all threads.
    workspace.applySetup(&w, &session, .{ .toggle_thread = .{ .id = 2, .tid = 4243 } });
    session.target.testing().image_epoch = 3;
    w.input.head = 0;
    w.input.queue[0] = .{ .kind = .press, .shortcut = 'p' };
    w.input.count = 1;
    workspace.input(&w, &session);
    try std.testing.expect(session.profile == null);
    try std.testing.expectEqualStrings("The target changed; review the capture thread selection", workspace.status);
    // Offline: settings actions are ignored.
    session.offline = true;
    workspace.applySetup(&w, &session, .{ .set_duration = 10000 });
    try std.testing.expect(session.profile_defaults.duration_ms != 10000);
}

test "shared F8 precedes imported input and consumes only plain presses" {
    var session = Session{ .id = 1, .agent_scope = .control, .imported = .{} };
    defer session.deinit();
    var workspace = Workspace{ .shared_clients = 2, .shared_controller = 7 };
    defer workspace.deinit();
    var w = Window{};
    // Exercise wraparound and preserve an unrelated imported-view shortcut.
    w.input.head = keys.capacity - 1;
    w.input.count = 4;
    w.input.queue[keys.capacity - 1] = .{ .kind = .press, .shortcut = keys.sym.f8 };
    w.input.queue[0] = .{ .kind = .repeat, .shortcut = keys.sym.f8 };
    w.input.queue[1] = .{ .kind = .press, .shortcut = keys.sym.f8, .mods = .{ .ctrl = true } };
    w.input.queue[2] = .{ .kind = .press, .shortcut = 'i' };
    workspace.input(&w, &session);
    try std.testing.expectEqual(model.AgentScope.observe, session.agent_scope);
    try std.testing.expectEqual(@as(usize, 1), session.audit_count);
    try std.testing.expect(workspace.shared_scope_changed and workspace.shared_controller == null);
    try std.testing.expect(workspace.imported.inspector);
    try std.testing.expectEqual(@as(usize, 0), w.input.count);
    workspace.shared_scope_changed = false;
    w.input.head = 0;
    w.input.count = 1;
    w.input.queue[0] = .{ .kind = .press, .shortcut = keys.sym.f8 };
    workspace.input(&w, &session);
    workspace.input(&w, &session);
    try std.testing.expectEqual(model.AgentScope.control, session.agent_scope);
    try std.testing.expectEqual(@as(usize, 2), session.audit_count);
    try std.testing.expect(workspace.shared_scope_changed);
}

test "unavailable Redot pane leaves ordinary input ownership unchanged" {
    var session = Session{ .id = 1, .agent_scope = .control };
    defer session.deinit();
    var workspace = Workspace{};
    defer workspace.deinit();
    var w = Window{};
    w.input.count = 5;
    for ([_]u32{ 'q', 'u', 'i', 't', keys.sym.f8 }, 0..) |shortcut, i|
        w.input.queue[i] = .{ .kind = .press, .shortcut = shortcut };
    const before = session.target.snapshot().state;
    workspace.input(&w, &session);
    try std.testing.expect(!workspace.redot_panel.open);
    try std.testing.expectEqual(model.AgentScope.observe, session.agent_scope);
    try std.testing.expectEqual(@as(usize, 1), session.audit_count);
    try std.testing.expectEqual(before, session.target.snapshot().state);
    try std.testing.expectEqual(@as(usize, 0), w.input.count);
}

test "shared F8 bypasses a modal editor without double toggling normal input" {
    var session = Session{ .id = 1, .agent_scope = .control };
    defer session.deinit();
    var workspace = Workspace{ .shared_clients = 1 };
    defer workspace.deinit();
    workspace.allocation_save_editor.start();
    var w = Window{};
    w.input.count = 3;
    w.input.queue[0] = .{ .kind = .press, .shortcut = keys.sym.f8 };
    w.input.queue[1] = .{ .kind = .repeat, .shortcut = keys.sym.f8 };
    w.input.queue[2] = .{ .kind = .press, .shortcut = 'x', .text_len = 1 };
    w.input.queue[2].text_bytes[0] = 'x';
    workspace.input(&w, &session);
    try std.testing.expectEqual(model.AgentScope.observe, session.agent_scope);
    try std.testing.expectEqual(@as(usize, 1), session.audit_count);
    try std.testing.expect(workspace.allocation_save_editor.open);
    try std.testing.expectEqualStrings("x", workspace.allocation_save_editor.text.slice());
    workspace.allocation_save_editor.open = false;
    w.input.head = 0;
    w.input.count = 1;
    w.input.queue[0] = .{ .kind = .press, .shortcut = keys.sym.f8 };
    workspace.input(&w, &session);
    try std.testing.expectEqual(model.AgentScope.control, session.agent_scope);
    try std.testing.expectEqual(@as(usize, 2), session.audit_count);
    // A revoke+grant batch must still tell the owner loop to revoke the old lease.
    workspace.shared_scope_changed = false;
    w.input.head = 0;
    w.input.count = 2;
    w.input.queue[0] = .{ .kind = .press, .shortcut = keys.sym.f8 };
    w.input.queue[1] = .{ .kind = .press, .shortcut = keys.sym.f8 };
    workspace.input(&w, &session);
    try std.testing.expectEqual(model.AgentScope.control, session.agent_scope);
    try std.testing.expectEqual(@as(usize, 4), session.audit_count);
    try std.testing.expect(workspace.shared_scope_changed);
}

test "nonshared F8 keeps delegated and modal behavior unchanged" {
    var session = Session{ .id = 1, .agent_scope = .control, .imported = .{} };
    defer session.deinit();
    var workspace = Workspace{};
    defer workspace.deinit();
    var w = Window{};
    w.input.count = 1;
    w.input.queue[0] = .{ .kind = .press, .shortcut = keys.sym.f8 };
    workspace.input(&w, &session);
    try std.testing.expectEqual(model.AgentScope.control, session.agent_scope);
    try std.testing.expectEqual(@as(usize, 0), session.audit_count);
    session.imported.?.deinit();
    session.imported = null;
    workspace.allocation_save_editor.start();
    w.input.head = 0;
    w.input.count = 1;
    w.input.queue[0] = .{ .kind = .press, .shortcut = keys.sym.f8 };
    workspace.input(&w, &session);
    try std.testing.expectEqual(model.AgentScope.control, session.agent_scope);
    try std.testing.expectEqual(@as(usize, 0), session.audit_count);
    workspace.allocation_save_editor.open = false;
    w.input.head = 0;
    w.input.count = 1;
    w.input.queue[0] = .{ .kind = .press, .shortcut = keys.sym.f8 };
    workspace.input(&w, &session);
    try std.testing.expectEqual(model.AgentScope.observe, session.agent_scope);
    try std.testing.expectEqual(@as(usize, 1), session.audit_count);
    try std.testing.expect(!workspace.shared_scope_changed);
}

test "N opens the invocation browser only for observation evidence" {
    var session = Session{ .id = 1 };
    defer session.deinit();
    var workspace = Workspace{};
    defer workspace.deinit();
    var w = Window{ .width = 1280, .height = 800 };
    w.input.count = 1;
    w.input.queue[0] = .{ .kind = .press, .shortcut = 'n' };
    workspace.input(&w, &session);
    try std.testing.expect(!workspace.invocations.open);
    const identity = @import("../observe/capture.zig").Identity{ .session_id = 2, .capture_id = 1, .process_id = 1, .pid = 9, .image_epoch = 1, .generation = 1 };
    const function = @import("../observe/capture.zig").Function{ .id = 1, .name = "f", .path = "/f", .identity = std.mem.zeroes(@import("../profile/uprobe_hooks.zig").Identity), .file_offset = 0, .link_address = 0, .runtime_address = 1 };
    session.observations.capture = try @import("../observe/capture.zig").Capture.create(std.heap.page_allocator, identity, .{}, &.{.{ .id = 1, .tid = 9 }}, &.{function});
    session.observations.capture.?.store.finish(.capture_end);
    // Keys queued after N belong to the browser.
    w.input.head = 0;
    w.input.count = 2;
    w.input.queue[0] = .{ .kind = .press, .shortcut = 'n' };
    w.input.queue[1] = .{ .kind = .press, .shortcut = keys.sym.tab };
    workspace.input(&w, &session);
    try std.testing.expect(workspace.invocations.open);
    try std.testing.expectEqual(@import("invocations.zig").List.slow, workspace.invocations.list);
    w.input.head = 0;
    w.input.count = 1;
    w.input.queue[0] = .{ .kind = .press, .shortcut = 'n' };
    workspace.input(&w, &session);
    try std.testing.expect(!workspace.invocations.open);
    try std.testing.expectEqualStrings("Invocation browser closed; N reopens it", workspace.status);
}
