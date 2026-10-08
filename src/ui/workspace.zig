const std = @import("std");
const c = @import("../c.zig").api;
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Window = @import("../platform/wayland.zig").Window;
const model = @import("../model/session.zig");
const Session = model.Session;
const linux = @import("../target/linux.zig");
const disasm = @import("../model/disassembly.zig");
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
const info = @import("../debug/info.zig");
const profile = @import("../profile/capture.zig");
const ToolButton = struct { label: []const u8, key: []const u8, code: u32, x: f32, w: f32 };
// One table for drawing and hit-testing. The zones are the ones the smoke tests click.
const buttons = [_]ToolButton{
    .{ .label = "Continue", .key = "SPACE", .code = 57, .x = 18, .w = 174 },
    .{ .label = "Detach", .key = "D", .code = 32, .x = 212, .w = 138 },
    .{ .label = "Step", .key = "F11", .code = 87, .x = 375, .w = 104 },
    .{ .label = "Over", .key = "F10", .code = 68, .x = 485, .w = 110 },
    .{ .label = "Agent", .key = "F8", .code = 66, .x = 605, .w = 200 },
    .{ .label = "Watch", .key = "W", .code = 17, .x = 940, .w = 110 },
    .{ .label = "Flow", .key = "G", .code = 34, .x = 1068, .w = 138 },
};
const tab_width = 4;
/// In the profile view, flames take the body above this fraction of the height
/// and the timeline the row below it.
const profile_split = 0.64;

/// Watch-list evaluation through the same Session paths as MCP
/// `evaluate_expression`: one unwind per thread and one locals lookup per
/// frame for each refresh, shared by all entries.
const WatchSource = struct {
    session: *Session,
    scratch: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    tids: [watch_ui.max_entries]i32 = undefined,
    frames: [watch_ui.max_entries][]const model.Frame = undefined,
    views: [watch_ui.max_entries][]watch_ui.Frame = undefined,
    stacks: usize = 0,
    local_keys: [watch_ui.max_entries]struct { tid: i32, index: usize } = undefined,
    locals: [watch_ui.max_entries][]const info.Local = undefined,
    local_count: usize = 0,
    pub fn stopped(self: *WatchSource) bool {
        return self.session.target.snapshot().state == .stopped;
    }
    pub fn ended(self: *WatchSource) bool {
        return self.session.target.snapshot().state == .exited or self.session.target.snapshot().state == .idle;
    }
    pub fn generation(self: *WatchSource) u64 {
        return self.session.target.snapshot().generation;
    }
    fn slot(self: *WatchSource, tid: i32) ?usize {
        for (self.tids[0..self.stacks], 0..) |t, i| if (t == tid) return i;
        return null;
    }
    pub fn identity(self: *WatchSource, tid: i32) ?watch_ui.Identity {
        for (self.session.target.threadSlice()) |thread| {
            if (thread.tid == tid and thread.state != .exited) return .{ .session = self.session.id, .image = self.session.target.snapshot().image_epoch, .thread = thread.id };
        }
        return null;
    }
    fn frameView(session: *Session, frame: model.Frame) watch_ui.Frame {
        const function = if (session.modules.symbolAt(frame.lookup_pc)) |symbol| symbol.address else |_| null;
        return .{ .cfa = frame.cfa, .symbol = frame.symbol, .module = frame.module_id, .function = function, .pc = frame.pc };
    }
    pub fn stack(self: *WatchSource, tid: i32) watch_ui.Stack {
        const i = self.slot(tid) orelse blk: {
            if (self.stacks == watch_ui.max_entries) return .unavailable;
            const a = self.scratch.allocator();
            const frames = self.session.stack(a, tid, 64) catch return .unavailable;
            const views = a.alloc(watch_ui.Frame, frames.len) catch return .unavailable;
            for (frames, views) |frame, *view| view.* = frameView(self.session, frame);
            const i = self.stacks;
            self.tids[i] = tid;
            self.frames[i] = frames;
            self.views[i] = views;
            self.stacks += 1;
            break :blk i;
        };
        const frames = self.frames[i];
        return .{ .frames = .{ .items = self.views[i], .complete = frames.len > 0 and frames.len < 64 and frames[frames.len - 1].diagnostic == null } };
    }
    fn frameLocals(self: *WatchSource, tid: i32, index: usize, frame: model.Frame) []const info.Local {
        for (self.local_keys[0..self.local_count], 0..) |key, i| if (key.tid == tid and key.index == index) return self.locals[i];
        const values = self.session.frameLocals(self.scratch.allocator(), frame) catch &.{};
        if (self.local_count < watch_ui.max_entries) {
            self.local_keys[self.local_count] = .{ .tid = tid, .index = index };
            self.locals[self.local_count] = values;
            self.local_count += 1;
        }
        return values;
    }
    pub fn evaluate(self: *WatchSource, a: std.mem.Allocator, tid: i32, index: usize, text: []const u8, page: ?u64) watch_ui.Result {
        const i = self.slot(tid) orelse return .{ .failed = error.InvalidFrame };
        if (index >= self.frames[i].len) return .{ .failed = error.InvalidFrame };
        const frame = self.frames[i][index];
        const value = self.session.evaluateInFrame(self.scratch.allocator(), frame, self.frameLocals(tid, index, frame), text) catch |err| return .{ .failed = err };
        const summary = self.session.summarize(a, value) catch |err| return .{ .failed = err };
        const expandable = value.type.kind == .structure or value.type.kind == .array;
        const extent_advisory = if (summary.visualization) |v| v.extent_advisory else false;
        var result = watch_ui.Result{ .value = .{ .display = summary.display, .type_name = summary.type, .available = summary.availability == .available, .extent_advisory = extent_advisory, .expandable = expandable } };
        if (page) |start| if (expandable) {
            const view = self.session.valueChildren(a, value, start, watch_ui.max_children, false) catch |err| return .{ .failed = err };
            const children = a.alloc(watch_ui.Child, view.children.len) catch return result;
            for (view.children, children) |child, *out| {
                const advisory = if (child.value.visualization) |v| v.extent_advisory else false;
                out.* = .{ .name = child.name, .display = if (advisory) std.fmt.allocPrint(a, "unproved extent: {s}", .{child.value.display}) catch child.value.display else child.value.display, .extent_advisory = advisory };
            }
            result.value.children = children;
            result.value.total = view.total;
            result.value.next = view.next;
        };
        return result;
    }
};

pub const Workspace = struct {
    shared_clients: ?usize = null,
    shared_controller: ?u64 = null,
    /// Owner loop consumes this even when several toggles restore the old scope.
    shared_scope_changed: bool = false,
    imported: @import("imported.zig").View = .{},
    logical_frames: @import("frames.zig").View = .{},
    jit_requested: ?struct { capture: u64, revision: u64, evidence: u64, ordinal: usize } = null,
    source: []const u8 = "",
    source_path: []const u8 = "No source file selected",
    source_line: i32 = 0,
    source_lines: i32 = 0,
    source_truncated: bool = false,
    current_line: ?u32 = null,
    cursor_line: ?u32 = null,
    was_running_to: bool = false,
    probes_panel: @import("probes.zig").Panel = .{},
    stop_panel: @import("stop.zig").Panel = .{},
    process_panel: @import("processes.zig").Panel = .{},
    allocation_panel: @import("allocations.zig").Panel = .{},
    allocation_save_editor: watch_ui.Editor = .{},
    allocation_archive_seen: bool = false,
    syscall_panel: @import("syscalls.zig").Panel = .{},
    inline_panel: @import("inline.zig").Panel = .{},
    /// Static slice/control answers (S); see src/semq/host.zig.
    static_panel: @import("static_analysis.zig").Panel = .{},
    /// The assembly row last clicked, and whether S should use the source
    /// cursor line instead (the most recent selection wins).
    assembly_cursor: ?u64 = null,
    static_from_line: bool = false,
    static_traced: u64 = 0,
    assembly_rows: struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, count: usize = 0 } = .{},
    inspection_panel: @import("inspection.zig").Panel = .{},
    selected_frame: usize = 0,
    last_frame: usize = std.math.maxInt(usize),
    frames: []model.Frame = &.{},
    locals: []LocalRow = &.{},
    local_diagnostic: ?[]const u8 = null,
    breakpoint_lines: []u32 = &.{},
    show_registers: bool = false,
    show_flow: bool = false,
    show_profile: bool = false,
    flame: FlameView = .{},
    inspector: sample_inspector.Inspector = .{},
    /// Next-capture setup (S): the session defaults plus this thread choice.
    /// The selection is GUI state for the next capture and is never saved.
    setup: capture_panel.Panel = .{},
    thread_selection: capture_setup.Selection = .{},
    thread_rows: ThreadRows = .{},
    timeline: timeline.TimelineView = .{},
    timeline_source: TimelineSource = .{},
    last_show_flow: bool = false,
    flow: FlowView = .{},
    browse_address: ?u64 = null,
    browse_assembly: ?u64 = null,
    last_browse: ?u64 = null,
    selected_local: usize = 0,
    /// Expression field (E) and watch list, shown in place of EVENTS (V).
    editor: watch_ui.Editor = .{},
    watch: watch_ui.WatchList = .{},
    show_watch: bool = false,
    /// Up/Down, Delete, Return, PgUp/PgDn and W act on the watch list.
    watch_focus: bool = false,
    watch_rect: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    watch_hits: [64]?usize = @splat(null),
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    source_buffer: ?[]u8 = null,
    source_name: ?[:0]u8 = null,
    selected: usize = 0,
    split: f32 = 0.48,
    dragging: bool = false,
    reported_dropped: u64 = 0,
    reported_keymap_errors: u64 = 0,
    status: []const u8 = "Ready",
    allocation_busy: bool = false,
    allocation_collecting: bool = false,
    last_generation: u64 = std.math.maxInt(u64),
    last_tid: i32 = 0,
    regs: ?linux.Registers = null,
    instructions: [32]disasm.Instruction = undefined,
    instruction_count: usize = 0,
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

    const LocalRow = struct { name: []const u8, value: model.ValueSummary };
    pub fn deinit(self: *Workspace) void {
        self.logical_frames.deinit();
        self.flow.deinit();
        self.flame.deinit();
        self.timeline_source.deinit();
        self.syscall_panel.deinit();
        self.allocation_panel.deinit();
        self.invocations.deinit();
        self.watch.deinit();
        self.arena.deinit();
        if (self.source_buffer) |bytes| std.heap.page_allocator.free(bytes);
        if (self.source_name) |name| std.heap.page_allocator.free(name);
    }
    pub fn loadSource(self: *Workspace, path: []const u8) !void {
        if (std.mem.eql(u8, path, self.source_path) and self.source.len > 0) return;
        const a = std.heap.page_allocator;
        const name = try a.dupeZ(u8, path);
        errdefer a.free(name);
        const file = c.fopen(name, "rb") orelse return error.SourceFileUnavailable;
        defer _ = c.fclose(file);
        const bytes = try a.alloc(u8, 1024 * 1024);
        errdefer a.free(bytes);
        const n = c.fread(bytes.ptr, 1, bytes.len, file);
        if (c.ferror(file) != 0) return error.SourceReadFailed;
        self.cursor_line = null;
        if (self.source_buffer) |old| a.free(old);
        if (self.source_name) |old| a.free(old);
        self.source_buffer = bytes;
        self.source_name = name;
        self.source = bytes[0..n];
        self.source_lines = @intCast(std.mem.count(u8, self.source, "\n") + @intFromBool(n > 0 and bytes[n - 1] != '\n'));
        self.source_truncated = n == bytes.len and c.fgetc(file) != c.EOF;
        self.source_path = name;
    }
    /// The key bindings, as the evdev codes `step` tests for. A key is matched by
    /// its logical identity, and never with Ctrl, Alt, or Logo held. Only
    /// navigation repeats while a key is held; execution control, detach, watch,
    /// graph, agent scope, and quit act once per press.
    /// The selected sample's per-sample reconstruction, on the existing stack
    /// job. Waits behind other worker jobs; never unwinds on this thread.
    fn inspectorStack(session: *Session, ordinal: usize) sample_inspector.Stack {
        const capture = session.profile.?;
        if (capture.collector != null) return .{ .not_available = "Stop collection to reconstruct" };
        if (capture.config.user_stack_bytes == 0) return .{ .not_available = "Stack capture was off (S, Stacks)" };
        if (session.archive_job) |job| {
            if (job.kind == .stack and job.capture_id == capture.id and job.capture_revision == capture.revision and job.sample_ordinal == ordinal) {
                if (!job.done.load(.acquire)) return .pending;
                if (job.stack_result) |*result| return .{ .ready = result };
                return .{ .failed = if (job.failure) |err| @errorName(err) else "no result" };
            }
            if (!job.done.load(.acquire)) return .{ .waiting = if (job.kind == .derived) "reconstructed flame view" else "archive job" };
        }
        _ = session.requestProfileStack(ordinal) catch |err| return .{ .failed = @errorName(err) };
        return .pending;
    }
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
            'd' => 32,
            'g' => 34,
            'p' => 25,
            't' => 20,
            's' => 31,
            'f' => 33,
            'z' => 44,
            'x' => 45,
            0xff0d => 28, // Return
            0xff08 => 14, // BackSpace
            'j' => 36,
            'k' => 37,
            'q' => 16,
            'b' => 48,
            'm' => 50,
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
    fn activeEditor(self: *Workspace, session: *Session) ?*watch_ui.Editor {
        if (self.logical_frames.open or (session.comparison != null and self.comparison.open) or session.imported != null) return null;
        if (self.invocations.open) return if (self.invocations.editor.open) &self.invocations.editor else null;
        if (session.process_tree != null and self.process_panel.open) return null;
        if (self.allocation_save_editor.open) return &self.allocation_save_editor;
        if (self.allocation_panel.open or self.syscall_panel.open or self.stop_panel.open or self.static_panel.open) return null;
        if (self.inline_panel.open) return if (self.inline_panel.editor.open) &self.inline_panel.editor else null;
        if (self.inspection_panel.open) return if (self.inspection_panel.editor.open) &self.inspection_panel.editor else null;
        if (self.probes_panel.open) return if (self.probes_panel.editor.open) &self.probes_panel.editor else null;
        if (self.editor.open) return &self.editor;
        if (self.show_profile and self.setup.open and self.setup.editor.open) return &self.setup.editor;
        return null;
    }
    fn clipboardFocus(self: *Workspace, w: *Window, session: *Session) void {
        watch_ui.Editor.focus(w, self.activeEditor(session));
        self.setup.syncEditor();
    }
    /// Applies the queued key and button events one at a time, in order, then the
    /// pointer state. A click is handled at the position where it happened.
    pub fn input(self: *Workspace, w: *Window, session: *Session) void {
        self.sharedScopeInput(w, session);
        self.clipboardFocus(w, session);
        defer self.clipboardFocus(w, session);
        if (self.show_profile and self.inspector.open and session.frames.hasJit()) if (session.profile) |capture| {
            const key: @typeInfo(@FieldType(Workspace, "jit_requested")).optional.child = .{ .capture = capture.id, .revision = capture.revision, .evidence = session.frames.evidence_revision, .ordinal = self.inspector.ordinal };
            if (capture.collector == null and !capture.archive_busy and !session.frames.busy() and (self.jit_requested == null or !std.meta.eql(self.jit_requested.?, key))) {
                session.frames.prepareJit(capture, if (session.artifact) |artifact| artifact.source else null, self.inspector.ordinal, 1) catch |err| {
                    self.status = @errorName(err);
                };
                self.jit_requested = key;
            }
        };

        if (self.logical_frames.open) return self.logical_frames.input(w, &session.frames);
        if (session.comparison) |job| if (self.comparison.open) return self.comparison.input(w, job);
        if (self.invocations.open) {
            self.invocations.input(w, session);
            if (!self.invocations.open) self.status = "Invocation browser closed; N reopens it";
            return;
        }
        if (session.imported) |*state| return self.imported.input(w, state);
        const pointer = [2]f32{ w.pointer_x, w.pointer_y };
        const down = w.mouse_down;
        defer {
            w.pointer_x = pointer[0];
            w.pointer_y = pointer[1];
            w.mouse_down = down;
        }
        var scroll = w.scroll;
        if (self.process_panel.open and scroll != 0) if (session.process_tree) |tree| {
            self.process_panel.wheel(tree, scroll);
            scroll = 0;
            w.dirty = true;
        };
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
        if (self.inspection_panel.open and scroll != 0) {
            self.inspection_panel.wheel(scroll);
            scroll = 0;
            w.dirty = true;
        }
        if (self.probes_panel.open and scroll != 0) {
            self.probes_panel.wheel(scroll, session.target.snapshot().breakpoint_count);
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
            self.clipboardFocus(w, session);
            if (self.activeEditor(session)) |editor| if (editor.clipboard(w, event)) continue;
            switch (event.kind) {
                .press, .repeat => {
                    if (self.activeEditor(session) == null and session.comparison != null and event.plain() and event.kind == .press and event.shortcut == 'v') {
                        self.comparison.open = true;
                        w.dirty = true;
                        continue;
                    }
                    if (self.activeEditor(session) == null and (session.observations.capture != null or session.observation_archive != null) and event.plain() and event.kind == .press and event.shortcut == 'n') {
                        self.invocations.open = true;
                        w.dirty = true;
                        // Later queued input belongs to the browser.
                        return self.input(w, session);
                    }
                    if (session.process_tree) |tree| if (self.process_panel.key(tree, event)) {
                        w.dirty = true;
                        if (tree.active() != session) return;
                        continue;
                    };
                    if (self.allocation_save_editor.open) {
                        if (self.allocation_save_editor.key(event)) |action| switch (action) {
                            .submit => |path| {
                                _ = session.saveAllocationArchive(path) catch |err| {
                                    self.allocation_save_editor.message = @errorName(err);
                                    w.dirty = true;
                                    continue;
                                };
                                session.record(.human, "save_allocation_archive");
                                self.allocation_save_editor.open = false;
                            },
                            else => {},
                        };
                        w.dirty = true;
                        continue;
                    }
                    if (self.allocation_panel.open and event.plain() and event.kind == .press and event.shortcut == 's') {
                        self.allocation_save_editor.start();
                        w.dirty = true;
                        continue;
                    }
                    const inspect_tid = if (session.target.snapshot().thread_count > 0) session.target.threadSlice()[@min(self.selected, session.target.snapshot().thread_count - 1)].tid else 0;
                    if (self.allocation_panel.open and event.plain() and event.kind == .press and event.shortcut == 'p') {
                        self.toggleAllocations(session);
                        w.dirty = true;
                        continue;
                    }
                    if (self.allocation_panel.key(session.allocations.capture, event)) {
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
                    if (self.inspection_panel.key(session, inspect_tid, self.selected_frame, event)) {
                        w.dirty = true;
                        continue;
                    }
                    if (self.probes_panel.key(session, event)) {
                        w.dirty = true;
                        continue;
                    }
                    if (self.editor.open) {
                        if (self.editor.key(event)) |action| {
                            self.applyEditor(session, action);
                            w.dirty = true;
                            continue;
                        }
                    }
                    if (!self.show_profile and self.show_watch and self.watch_focus and event.kind == .press and event.plain() and event.mods.shift and event.shortcut == 'l') {
                        self.toggleWatchMode(session);
                        w.dirty = true;
                        continue;
                    }
                    if (self.show_profile and self.setup.open) {
                        const snapshot = self.thread_rows.snapshot(session);
                        if (self.setup.key(event, &snapshot, .{})) |action| {
                            self.applySetup(w, session, action);
                            continue;
                        }
                    }
                    if (event.kind == .press and event.plain() and event.shortcut == 'l' and (session.frames.count > 0 or session.frames.job != null or session.frames.attachment.failure != null)) {
                        self.logical_frames.open = true;
                        w.dirty = true;
                        return self.logical_frames.input(w, &session.frames);
                    }
                    const code = binding(event);
                    if (code == 0) continue;
                    self.step(w, session, false, code);
                    if (code == 18 and self.editor.open) self.editor.mode = if (event.mods.shift) .live else .pinned;
                },
                .button_press, .button_release => {
                    if (event.code != 272) continue;
                    if (self.process_panel.open) if (session.process_tree) |tree| {
                        if (event.kind == .button_press) self.process_panel.press(tree, event.x, event.y);
                        w.dirty = true;
                        if (tree.active() != session) return;
                        continue;
                    };
                    if (self.allocation_panel.open) {
                        if (event.kind == .button_press) {
                            if (@import("allocations.zig").Panel.liveHit(@floatFromInt(w.width), event.x, event.y)) self.toggleAllocations(session) else self.allocation_panel.press(session.allocations.capture, event.x, event.y);
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
                            self.static_panel.press(session, event.x, event.y);
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
                    if (self.inspection_panel.open) {
                        if (event.kind == .button_press) self.inspection_panel.press(event.x, event.y);
                        w.dirty = true;
                        continue;
                    }
                    if (self.probes_panel.open) {
                        if (event.kind == .button_press) self.probes_panel.press(event.x, event.y, session.target.snapshot().breakpoint_count);
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
                        if (self.timeline.release(event.x, event.y)) self.applyTimeline(session);
                        w.dirty = true;
                        continue;
                    }
                    // A complete drag may arrive between two display frames.
                    if (!w.mouse_down and self.dragging) self.split = std.math.clamp(event.x / @as(f32, @floatFromInt(w.width)), 0.30, 0.62);
                    self.step(w, session, w.mouse_down, 0);
                },
                else => continue,
            }
            // Later actions in the batch must use a newly selected frame/thread.
            // The first action still observes the normal stale-snapshot guard.
            if (!w.closing) self.refresh(session);
        }
        w.pointer_x = pointer[0];
        w.pointer_y = pointer[1];
        w.mouse_down = down;
        w.scroll = scroll;
        if (w.closing) return;
        if (self.show_profile and self.timeline.motion(w.pointer_x, w.pointer_y)) w.dirty = true;
        self.step(w, session, false, 0);
        if (w.input.dropped != self.reported_dropped) {
            std.debug.print("Input queue dropped {d} events ({d} total)\n", .{ w.input.dropped - self.reported_dropped, w.input.dropped });
            self.reported_dropped = w.input.dropped;
            self.status = "Some input was dropped; try again";
            w.dirty = true;
        }
        if (w.input.keymap_errors != self.reported_keymap_errors) {
            std.debug.print("Input keymap errors: {d}\n", .{w.input.keymap_errors});
            self.reported_keymap_errors = w.input.keymap_errors;
            self.status = "Keyboard layout unavailable; mouse controls still work";
            w.dirty = true;
        }
        w.setCursor(if (self.divider_hot or self.dragging) .col_resize else .default);
    }
    /// S: the most recent selection (source line or assembly row), else the PC.
    /// A line keeps all its line-table rows and every function they fall in;
    /// the panel asks which function when there is more than one.
    fn openStatic(self: *Workspace, w: *Window, session: *Session) void {
        if (self.static_from_line) if (self.cursor_line) |line| {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            const addresses = session.sourceAddresses(a, self.source_path, line) catch &.{};
            if (addresses.len == 0) {
                self.status = "No code at the selected line for static analysis";
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
                std.debug.print("static functions:", .{});
                for (functions.items) |f| std.debug.print(" {s}", .{f.name});
                std.debug.print("\n", .{});
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
    /// With XODB_INPUT_TRACE, each static answer is logged once for GUI tests.
    fn traceStatic(self: *Workspace, w: *Window) void {
        const panel = &self.static_panel;
        if (!w.input.trace or panel.answers == self.static_traced) return;
        self.static_traced = panel.answers;
        std.debug.print("static answer: {s} | {s} | {s} | rows={d}\n", .{ panel.heading, panel.summary, panel.parameters, panel.rows.len });
        for (panel.rows) |row| std.debug.print("static row: {s} 0x{x} {s}\n", .{ row.certainty, row.address orelse 0, row.label });
    }
    /// A chosen static citation browses the assembly and source to it.
    fn followStatic(self: *Workspace, w: *Window) void {
        const address = self.static_panel.navigate orelse return;
        if (w.input.trace) std.debug.print("static navigate: 0x{x}\n", .{address});
        self.static_panel.navigate = null;
        self.browse_address = address;
        self.browse_assembly = address;
        self.assembly_cursor = address;
        self.static_from_line = false;
        self.status = "Static citation; S returns to the answer";
    }
    fn toggleAllocations(self: *Workspace, session: *Session) void {
        if (session.allocations.preparing() or session.allocations.collecting()) {
            session.allocations.stop(.manual);
            session.record(.human, "stop_allocations");
            self.status = "Allocation capture stopping";
            return;
        }
        if (self.selected >= session.target.snapshot().thread_count) {
            self.status = "Select a stopped thread before allocation capture";
            return;
        }
        const tids = [_]i32{session.target.threadSlice()[self.selected].tid};
        session.startAllocations(.human, &tids, session.allocation_defaults, null, &Session.allocation_hooks) catch |err| {
            self.status = @errorName(err);
            return;
        };
        self.allocation_busy = true;
        self.status = "Preparing allocation capture; keep target paused";
    }
    fn step(self: *Workspace, w: *Window, session: *Session, press: bool, key: u32) void {
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
                if (session.profile) |capture| self.inspector.step(capture, self.flame.selection.filter, if (key == 26) -1 else 1);
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
            if (self.setup.press(w.pointer_x, w.pointer_y, w.input.mods().shift)) |action| return self.applySetup(w, session, action);
            if (!self.setup.containsPoint(w.pointer_x, w.pointer_y)) self.setup.open = false;
        }
        if (self.show_profile and (key == 31 or (click and self.flame.setupHit(w.pointer_x, w.pointer_y)))) {
            self.setup.open = !self.setup.open;
            self.setup.editing = .none;
            w.dirty = true;
            click = false;
        }
        if (self.show_profile and !session.offline and (key == 20 or (click and self.flame.durationHit(w.pointer_x, w.pointer_y)))) {
            @import("flame.zig").FlameView.cycleDuration(&session.profile_defaults);
            self.status = if (session.profile_defaults.duration_ms == 0) "Next capture: until stopped; resource and scope limits still apply" else "Next capture duration changed";
            w.dirty = true;
            click = false;
        }
        if (self.show_profile and click and self.timeline.press(w.pointer_x, w.pointer_y)) {
            click = false;
            w.dirty = true;
        }
        if (!self.show_profile and click and @abs(w.pointer_x - @as(f32, @floatFromInt(w.width)) * self.split) < 7 and w.pointer_y > 90) self.dragging = true;
        if (!w.mouse_down) self.dragging = false;
        if (self.dragging) self.split = std.math.clamp(w.pointer_x / @as(f32, @floatFromInt(w.width)), 0.30, 0.62);
        var code = key;
        // Hover targets: a change needs one redraw, after which the animation keeps itself going.
        var hovered: ?usize = null;
        if (w.pointer_y >= 44 and w.pointer_y < 84) for (buttons, 0..) |b, i| {
            if (w.pointer_x >= b.x and w.pointer_x < b.x + b.w) hovered = i;
        };
        const gutter_row = (w.pointer_y - 135) / 23;
        const hover_line: ?u32 = if (!self.show_profile and w.pointer_x > 10 and w.pointer_x < 74 and gutter_row >= 0 and w.pointer_y < self.bottomY(@floatFromInt(w.height)) - 10) @intCast(self.source_line + @as(i32, @intFromFloat(gutter_row)) + 1) else null;
        const divider_hot = !self.show_profile and @abs(w.pointer_x - @as(f32, @floatFromInt(w.width)) * self.split) < 7 and w.pointer_y > 90;
        if (hovered != self.hovered or hover_line != self.hover_line or divider_hot != self.divider_hot) w.dirty = true;
        self.hovered = hovered;
        self.hover_line = hover_line;
        self.divider_hot = divider_hot;
        if (click) if (hovered) |i| {
            code = buttons[i].code;
            self.pressed[i] = 1;
        };
        const flame_x: f32 = if (w.width < 900) 280 else 380;
        const flame_w: f32 = if (w.width < 900) 110 else 178;
        if (click and w.pointer_x >= flame_x and w.pointer_x < flame_x + flame_w and w.pointer_y >= 8 and w.pointer_y < 37) code = 33;
        if (code == 62 and !self.show_profile) {
            session.restart() catch |err| {
                self.status = @errorName(err);
                w.dirty = true;
                return;
            };
            session.record(.human, "restart");
            self.status = "Restarted owned launch; watches cleared, breakpoints relocated";
            self.selected = 0;
            self.selected_frame = 0;
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
            self.openStatic(w, session);
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
            self.inspection_panel.show(session, code == 19, address);
            w.dirty = true;
            return;
        }
        if (code == 48 and !self.show_profile) {
            self.probes_panel.open = !self.probes_panel.open;
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
            if (session.profile != null and session.profile.?.collector != null) {
                session.stopProfile() catch |err| {
                    self.status = @errorName(err);
                    return;
                };
                session.record(.human, "stop_profile");
                self.status = "Capture stopped; target execution unchanged";
            } else {
                // Revalidate the thread choice against the current target, then
                // let Session apply its own checks.
                const snapshot = self.thread_rows.snapshot(session);
                if (self.thread_selection.sync(&snapshot) == .cleared_replaced) {
                    self.setup.message = "The target changed; review the capture thread selection";
                    self.setup.open = true;
                    self.status = self.setup.message;
                    return;
                }
                var tids: [@import("../profile/linux_perf.zig").max_threads]i32 = undefined;
                switch (capture_setup.prepareStart(&snapshot, session.profile_defaults, &self.thread_selection, .{}, &tids)) {
                    .rejected => |rejected| {
                        self.status = capture_setup.problemText(rejected.problem);
                        if (rejected.problem == .empty_subset or rejected.problem == .missing_threads or rejected.problem == .too_many_threads) self.setup.open = true;
                        return;
                    },
                    .ready => |config| {
                        _ = session.startProfile(config) catch |err| {
                            self.status = @errorName(err);
                            return;
                        };
                    },
                }
                session.record(.human, "start_profile");
                self.setup.open = false;
                self.status = "Capturing CPU samples; Space runs the target";
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
                    session.retryDerived();
                    self.flame.setBasis(.reconstructed);
                    self.status = "Reconstructed stacks from saved registers and stack bytes; B returns to recorded callchains";
                } else {
                    self.flame.setBasis(.recorded);
                    self.status = "Recorded kernel callchains";
                }
                w.dirty = true;
            }
            if (session.profile) |capture| {
                if (code == 23) {
                    self.inspector.open = !self.inspector.open;
                    if (self.inspector.open) self.inspector.scroll = 0;
                    if (self.inspector.open) self.inspector.ordinal = self.flame.selectedExample() orelse sample_inspector.Inspector.first(capture, self.flame.selection.filter) orelse capture.samples.len();
                    w.dirty = true;
                }
                if (self.inspector.open and (code == 26 or code == 27)) {
                    self.inspector.step(capture, self.flame.selection.filter, if (code == 26) -1 else 1);
                    w.dirty = true;
                }
            }
            if (code == 44) self.flame.zoomSelected();
            if (code == 14) self.flame.zoomOut();
            if (click) if (session.profile) |capture| {
                // Hit rectangles describe the displayed revision; frame identity
                // remains valid within this capture until new mapping evidence.
                if (capture.id == self.flame.capture_id and capture.mapping_revision == self.flame.mapping_revision and (capture.trusted_before_ns == std.math.maxInt(u64) or capture.revision == self.flame.revision)) {
                    if (self.flame.hit(w.pointer_x, w.pointer_y)) |node| self.flame.select(capture, node);
                }
            };
            if (code == 28) if (session.profile) |capture| {
                if (self.flame.capture_id == capture.id and capture.mapping_revision == self.flame.mapping_revision and (capture.trusted_before_ns == std.math.maxInt(u64) or capture.revision == self.flame.revision)) if (self.flame.selectedFrame()) |frame| {
                    if (capture.offline) {
                        self.status = "Offline capture: recorded source location shown below; historical source text is not bundled";
                    } else if (session.target.snapshot().state != .stopped or session.target.snapshot().image_epoch != capture.image_epoch or session.target.snapshot().pid != capture.pid) {
                        self.status = "Pause in the captured image to browse; frozen assembly remains below";
                    } else {
                        session.refreshMaps() catch |err| {
                            self.status = @errorName(err);
                            return;
                        };
                        if (capture.matchesLive(&session.modules, frame)) {
                            self.browse_address = frame.lookup_address;
                            self.browse_assembly = frame.address; // start decoding at a known instruction boundary
                            self.show_flow = false;
                            self.show_profile = false;
                            self.status = "Browsing sampled function; execution unchanged";
                        } else self.status = "Captured frame has no matching live image";
                    }
                };
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
        if (code == 24 or (click and w.pointer_y >= 8 and w.pointer_y < 37 and w.pointer_x >= 91 and w.pointer_x < 262)) {
            if (session.process_tree) |tree| self.process_panel.show(tree);
            w.dirty = true;
            return;
        }
        if (code == 34) {
            self.show_profile = false;
            self.show_flow = !self.show_flow;
            w.dirty = true;
        }
        if (!self.show_profile and self.show_flow and session.target.snapshot().state == .stopped and self.flow.generation == session.target.snapshot().generation) {
            if (click) if (self.flow.hit(w.pointer_x, w.pointer_y)) |address| {
                self.browse_address = address;
                self.browse_assembly = null;
                self.status = "Browsing block; execution unchanged";
                w.dirty = true;
            };
            if (!(self.show_watch and self.watch_focus) and w.pointer_x >= @as(f32, @floatFromInt(w.width)) * self.split and w.pointer_x < @as(f32, @floatFromInt(w.width)) * 0.79) {
                self.flow.scrollBy(w.scroll + (if (code == 108) @as(i32, 3) else if (code == 103) @as(i32, -3) else 0));
                w.scroll = 0;
                if (code == 108 or code == 103) code = 0;
            }
        }
        if (!self.show_profile) {
            if (code == 18) {
                self.editor.start();
                self.show_watch = true;
                self.watch_focus = true;
                w.dirty = true;
            }
            if (code == 47) {
                self.show_watch = !self.show_watch;
                if (!self.show_watch) self.watch_focus = false;
                w.dirty = true;
            }
            if (self.show_watch and w.scroll != 0) {
                const r = self.watch_rect;
                if (w.pointer_x >= r.x and w.pointer_x < r.x + r.w and w.pointer_y >= r.y and w.pointer_y < r.y + r.h) {
                    self.watch.scrollBy(w.scroll);
                    w.scroll = 0;
                    w.dirty = true;
                }
            }
            if (click and self.show_watch) {
                const r = self.watch_rect;
                self.watch_focus = w.pointer_x >= r.x and w.pointer_x < r.x + r.w and w.pointer_y >= r.y and w.pointer_y < r.y + r.h;
                if (self.watch_focus) {
                    if (self.watch.rowAt(w.pointer_y, &self.watch_hits)) |i| self.watch.selected = i;
                    click = false;
                    w.dirty = true;
                }
            }
            if (self.show_watch and self.watch_focus) if (self.watch.selected) |i| {
                if (code == 103 or code == 108) {
                    self.watch.reveal_selection = true;
                    self.watch.selected = if (code == 103) i -| 1 else @min(i + 1, self.watch.count - 1);
                    code = 0;
                    w.dirty = true;
                }
                if (code == 26 or code == 27) {
                    self.watch.scrollBy(if (code == 26) -1 else 1);
                    code = 0;
                    w.dirty = true;
                }
                // Delete or BackSpace: compact keyboards (e.g. HHKB) have no
                // dedicated Delete key.
                if (code == 111 or code == 14) {
                    self.watch.remove(i);
                    code = 0;
                    w.dirty = true;
                }
                if (code == 28) {
                    self.watch.toggleExpanded(i);
                    self.refreshWatch(session);
                    w.dirty = true;
                }
                if (code == 104 or code == 109) {
                    self.watch.pageChildren(i, code == 109);
                    self.refreshWatch(session);
                    w.dirty = true;
                }
                if (code == 17) return self.watchWrite(session, i);
            };
        }
        if (code == 15) {
            self.show_registers = !self.show_registers;
            w.dirty = true;
        }
        if (click and !self.show_registers and w.pointer_x >= @as(f32, @floatFromInt(w.width)) * 0.79 and w.pointer_y >= 135 and w.pointer_y < self.bottomY(@floatFromInt(w.height)) - 10) {
            self.selected_local = @intFromFloat((w.pointer_y - 135) / 48);
            w.dirty = true;
        }
        if (code == 17 and session.target.snapshot().state == .stopped and self.selected_local < self.locals.len and session.target.snapshot().thread_count > 0) {
            if (self.last_generation != session.target.snapshot().generation) {
                self.status = "StaleSnapshot";
                return;
            }
            const local = self.locals[self.selected_local];
            const address = local.value.address orelse {
                self.status = "NotAddressable";
                return;
            };
            for (session.target.watchpointSlice()) |watch| if (watch != null and watch.?.address == address) {
                session.target.removeWatchpoint(watch.?.id) catch |err| {
                    self.status = @errorName(err);
                    return;
                };
                session.record(.human, "remove_watchpoint");
                self.status = "Watchpoint removed";
                return;
            };
            const tid = session.target.threadSlice()[self.selected % session.target.snapshot().thread_count].tid;
            _ = session.investigateWrite(tid, self.selected_frame, "Why did the selected value change?", local.name) catch |err| {
                self.status = @errorName(err);
                return;
            };
            session.record(.human, "investigate_write");
            self.status = "Write investigation started";
        }
        if (click and w.pointer_x > 10 and w.pointer_x < 74 and w.pointer_y >= 135 and w.pointer_y < self.bottomY(@floatFromInt(w.height)) - 10 and session.target.snapshot().state == .stopped) {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const number: u32 = @intCast(self.source_line + @as(i32, @intFromFloat((w.pointer_y - 135) / 23)) + 1);
            const addresses = session.sourceAddresses(scratch.allocator(), self.source_path, number) catch |err| {
                self.status = @errorName(err);
                return;
            };
            var removed = false;
            for (addresses) |address| {
                for (session.target.breakpointSlice()) |probe| if (probe.address == address) {
                    session.target.removeBreakpoint(probe.id) catch |err| {
                        self.status = @errorName(err);
                        return;
                    };
                    removed = true;
                    break;
                };
            }
            if (!removed) _ = session.setSourceBreakpoint(scratch.allocator(), self.source_path, number) catch |err| {
                self.status = @errorName(err);
                return;
            };
            session.record(.human, "toggle_source_breakpoint");
        }
        if (click and !self.show_profile and w.pointer_x >= 74 and w.pointer_x < @as(f32, @floatFromInt(w.width)) * self.split and w.pointer_y >= 135 and w.pointer_y < self.bottomY(@floatFromInt(w.height)) - 10) {
            self.cursor_line = @intCast(self.source_line + @as(i32, @intFromFloat((w.pointer_y - 135) / 23)) + 1);
            self.static_from_line = true;
            self.status = "Source line selected; F9 run to cursor, F12 finish, B breakpoints, S static slice";
            w.dirty = true;
        }
        const rows = self.assembly_rows;
        if (click and !self.show_profile and !self.show_flow and rows.count > 0 and w.pointer_x >= rows.x and w.pointer_x < rows.x + rows.w and w.pointer_y >= rows.y - 2 and w.pointer_y < rows.y - 2 + @as(f32, @floatFromInt(rows.count)) * 23) {
            const index: usize = @intFromFloat((w.pointer_y - rows.y + 2) / 23);
            if (index < self.instruction_count) {
                self.assembly_cursor = self.instructions[index].address;
                self.static_from_line = false;
                self.status = "Instruction selected; S static slice / control dependences";
                w.dirty = true;
            }
        }
        if ((code == 67 or code == 88) and session.target.snapshot().state == .stopped and session.target.snapshot().thread_count > 0) {
            const tid = session.target.threadSlice()[self.selected % session.target.snapshot().thread_count].tid;
            if (code == 88) session.finishFrame(tid, self.selected_frame, .human) catch |err| {
                self.status = @errorName(err);
                return;
            } else {
                const line_number = self.cursor_line orelse {
                    self.status = "Click a source line first";
                    return;
                };
                var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch.deinit();
                const addresses = session.sourceAddresses(scratch.allocator(), self.source_path, line_number) catch |err| {
                    self.status = @errorName(err);
                    return;
                };
                if (addresses.len == 0) {
                    self.status = "No code at selected line";
                    return;
                }
                session.runTo(tid, addresses[0], null, .human) catch |err| {
                    self.status = @errorName(err);
                    return;
                };
            }
            session.record(.human, if (code == 88) "finish" else "run_to");
            self.status = if (code == 88) "Running until selected frame returns" else "Running to selected source line";
            self.browse_address = null;
        }
        const stack_x = @as(f32, @floatFromInt(w.width)) * self.split * 0.36;
        const stack_y = self.bottomY(@floatFromInt(w.height)) + 44;
        if (click and !self.show_profile and w.pointer_x >= stack_x and w.pointer_x < @as(f32, @floatFromInt(w.width)) * self.split and w.pointer_y >= stack_y and self.frames.len > 0) {
            self.browse_address = null;
            self.selected_frame = @min(self.frames.len - 1, @as(usize, @intFromFloat((w.pointer_y - stack_y) / 25)));
            w.dirty = true;
        }
        if (code == 66) self.toggleAgentScope(session); // F8 or the Agent button.
        if (code == 87 or code == 68 or code == 57 or code == 63 or code == 64 or code == 36 or code == 37) self.browse_address = null;
        if ((code == 87 or code == 68) and session.target.snapshot().state == .stopped and session.target.snapshot().thread_count > 0) {
            const tid = session.target.threadSlice()[self.selected % session.target.snapshot().thread_count].tid;
            session.probe_resume_actor = .human;
            if (self.current_line != null) session.startSourceStep(tid, code == 68) catch |err| {
                self.status = @errorName(err);
                return;
            } else if (code == 87) session.stepInstruction(tid) catch |err| {
                self.status = @errorName(err);
                return;
            } else session.stepOverInstruction(tid) catch |err| {
                self.status = @errorName(err);
                return;
            };
            self.selected_frame = 0;
            session.record(.human, if (code == 87) "step" else "step_over");
        }
        if (code == 1) {
            if (session.archive_job) |job| {
                if (!job.done.load(.acquire)) {
                    job.progress.cancel.store(true, .release);
                    self.status = "Archive cancellation requested";
                    return;
                }
            }
        }
        if (code == 16 or code == 1) {
            w.closing = true;
            w.close_reason = .quit_key;
        }
        if (code == 57 or code == 63 or code == 64) {
            if (session.pending_continue != null) {
                session.cancelStep();
                self.status = "Pending continue cancelled";
            } else if (session.target.snapshot().state == .stopped) {
                session.continueExecution(.human) catch |err| {
                    self.status = @errorName(err);
                    return;
                };
                if (session.pending_continue != null) self.status = "Resolving symbols; Space cancels the queued continue";
            } else if (session.target.snapshot().state == .running) {
                session.cancelStep();
                session.target.interrupt() catch |err| {
                    self.status = @errorName(err);
                    return;
                };
            }
            self.selected_frame = 0;
        }
        if (code == 57 or code == 63 or code == 64) session.record(.human, "continue_or_interrupt");
        if (code == 32 and session.target.snapshot().pid != 0) session.detach() catch |err| {
            self.status = @errorName(err);
            return;
        };
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
        if (session.target.snapshot().thread_count > 0) self.selected %= session.target.snapshot().thread_count else self.selected = 0;
    }
    /// Performs a setup-panel action. Start goes through the same path as P.
    fn applySetup(self: *Workspace, w: *Window, session: *Session, action: capture_panel.Action) void {
        w.dirty = true;
        const snapshot = self.thread_rows.snapshot(session);
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
            .set_duration, .set_frequency, .toggle_scheduling, .toggle_syscalls => self.status = "Next capture settings changed; a running capture keeps its own",
            else => {},
        }
    }
    /// Hands the committed timeline selection to the flames.
    fn applyTimeline(self: *Workspace, session: *Session) void {
        const capture = session.profile orelse return;
        if (capture.id != self.timeline.capture_id) return;
        self.flame.setFilter(capture, self.timeline.filter()) catch |err| {
            self.status = @errorName(err);
        };
    }
    /// Starts a write investigation on a watch entry, in the frame the entry
    /// resolved to at this stop. Same authority as W on a local.
    fn watchWrite(self: *Workspace, session: *Session, index: usize) void {
        const entry = &self.watch.entries[index];
        if (session.target.snapshot().state != .stopped or self.watch.generation == null or self.watch.generation.? != session.target.snapshot().generation) {
            self.status = "StaleSnapshot";
            return;
        }
        const frame = entry.resolved_index orelse {
            self.status = "The watch entry's frame is gone";
            return;
        };
        if (entry.state != .value) {
            self.status = "The watch entry has no current value";
            return;
        }
        _ = session.investigateWrite(entry.frame.tid, frame, "Why did the watched expression change?", entry.expression()) catch |err| {
            self.status = @errorName(err);
            return;
        };
        session.record(.human, "investigate_write");
        self.status = "Write investigation started";
    }
    fn applyEditor(self: *Workspace, session: *Session, action: watch_ui.Editor.Action) void {
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
                const frame = self.frames[self.selected_frame];
                const tid = session.target.threadSlice()[self.selected].tid;
                _ = self.watch.addMode(text, watch_ui.FrameId.of(tid, self.selected_frame, WatchSource.frameView(session, frame), .{ .session = session.id, .image = session.target.snapshot().image_epoch, .thread = session.target.threadSlice()[self.selected].id }, session.target.snapshot().generation), self.editor.mode) catch |err| {
                    self.editor.message = switch (err) {
                        error.WatchListFull => "The watch list is full (16); Delete one first",
                        error.ExpressionTooLong => "Expressions are limited to 256 characters",
                        else => "Type an expression",
                    };
                    return;
                };
                self.status = if (self.editor.mode == .live) "Live display added; updates in the selected frame at each stop / Shift+L pins it" else "Watch added; later CFA matches cannot prove call lifetime between stops / Shift+L makes it live";
                self.editor.open = false;
                self.watch_focus = true;
                self.refreshWatch(session);
            },
        }
    }
    fn toggleWatchMode(self: *Workspace, session: *Session) void {
        const index = self.watch.selected orelse return;
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
        const frame = self.frames[self.selected_frame];
        self.watch.toggleMode(index, watch_ui.FrameId.of(thread.tid, self.selected_frame, WatchSource.frameView(session, frame), .{ .session = session.id, .image = session.target.snapshot().image_epoch, .thread = thread.id }, session.target.snapshot().generation));
        self.status = if (self.watch.entries[index].mode == .live) "Live display: follows the selected frame / Shift+L pins it" else "Watch pinned to the selected frame / Shift+L makes it live";
        self.refreshWatch(session);
    }
    /// Top of the bottom row (threads, stack, events/watch). Short windows give
    /// the watch view more rows; the source and assembly panes shrink instead.
    fn bottomY(self: *const Workspace, height: f32) f32 {
        return @round(height * @as(f32, if (self.show_watch and height < 640) 0.56 else 0.73));
    }
    fn refreshWatch(self: *Workspace, session: *Session) void {
        if (self.watch.count == 0) return;
        self.watch.setDisplayFrame(if (self.selected < session.target.snapshot().thread_count) .{ .tid = session.target.threadSlice()[self.selected].tid, .index = self.selected_frame } else null);
        var source = WatchSource{ .session = session };
        defer source.scratch.deinit();
        self.watch.refresh(&source);
    }
    fn refresh(self: *Workspace, session: *Session) void {
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
        if (self.last_generation == session.target.snapshot().generation and self.last_tid == tid and self.last_frame == self.selected_frame and self.last_browse == self.browse_address and self.last_show_flow == self.show_flow) return;
        if (self.last_generation != session.target.snapshot().generation) self.browse_address = null;
        self.last_browse = self.browse_address;
        self.last_show_flow = self.show_flow;
        if (self.last_tid != tid) self.stale_regs = null else if (self.regs) |regs| self.stale_regs = regs;
        self.alive = 0;
        self.last_generation = session.target.snapshot().generation;
        self.last_tid = tid;
        self.last_frame = self.selected_frame;
        _ = self.arena.reset(.retain_capacity);
        self.frames = &.{};
        self.locals = &.{};
        self.current_line = null;
        self.breakpoint_lines = &.{};
        self.local_diagnostic = null;
        self.regs = null;
        self.instruction_count = 0;
        if (tid == 0 or session.target.snapshot().state != .stopped) {
            self.flow.refresh(session, 0);
            return;
        }
        self.regs = session.target.registers(tid) catch |err| {
            self.status = @errorName(err);
            return;
        };
        var bytes: [256]u8 = undefined;
        const assembly_address = if (self.browse_address) |address| self.browse_assembly orelse address else linux.programCounter(self.regs.?) catch |err| {
            self.status = @errorName(err);
            return;
        };
        const n = session.target.readMemory(assembly_address, &bytes) catch |err| {
            self.status = @errorName(err);
            return;
        };
        self.instruction_count = disasm.decodeFor(session.target.arch(), bytes[0..n], assembly_address, &self.instructions) catch 0;
        const a = self.arena.allocator();
        self.frames = session.stack(a, tid, 64) catch &.{};
        if (self.frames.len > 0) {
            self.selected_frame = @min(self.selected_frame, self.frames.len - 1);
            if (self.frames[self.selected_frame].source) |site| {
                self.loadSource(site.path) catch |err| {
                    self.status = @errorName(err);
                };
                if (std.mem.eql(u8, self.source_path, site.path)) {
                    self.current_line = site.line;
                    self.source_line = @intCast(site.line -| 6);
                }
            }
        }
        if (self.show_flow) {
            const anchor = if (self.frames.len > 0) self.frames[self.selected_frame].lookup_pc else linux.programCounter(self.regs.?) catch |err| {
                self.status = @errorName(err);
                return;
            };
            self.flow.refresh(session, anchor);
        }
        if (self.browse_address) |address| {
            self.current_line = null;
            if (session.sourceAt(a, address)) |site| {
                self.loadSource(site.path) catch {};
                if (std.mem.eql(u8, self.source_path, site.path)) {
                    self.current_line = site.line;
                    self.source_line = @intCast(site.line -| 6);
                }
            } else |_| {
                self.current_line = null;
            }
        }
        const variables = session.locals(a, tid, self.selected_frame) catch |err| {
            self.local_diagnostic = @errorName(err);
            return;
        };
        var rows: std.ArrayList(LocalRow) = .empty;
        for (variables) |v| {
            const summary = session.summarize(a, v.value) catch continue;
            rows.append(a, .{ .name = v.name, .value = summary }) catch {};
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
        self.locals = rows.toOwnedSlice(a) catch &.{};
        var lines: std.ArrayList(u32) = .empty;
        for (session.target.breakpointSlice()) |probe| {
            const site = session.sourceAt(a, probe.address) catch continue;
            if (std.mem.eql(u8, site.path, self.source_path)) lines.append(a, site.line) catch {};
        }
        self.breakpoint_lines = lines.toOwnedSlice(a) catch &.{};
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
        r.clip = .{ .x = 0, .y = 0, .w = @floatFromInt(r.extent.width), .h = @floatFromInt(r.extent.height) };
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
    fn animate(self: *Workspace, session: *Session) void {
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
        switch (session.target.snapshot().state) {
            .running => target = theme.pop,
            .exited => target = theme.good_pop,
            .stopped => for (session.target.threadSlice()) |thread| switch (thread.reason) {
                .breakpoint, .watchpoint, .signal => target = theme.bad_pop,
                else => {},
            },
            .idle => {},
        }
        for (&self.bar, target) |*channel, goal| {
            if (style.approach(channel, goal, 30, dt)) moving = true;
        }
        self.animating = moving or self.inspection_panel.busy(session);
    }
    fn drawSharedOwnership(self: *Workspace, r: *gpu.Renderer, font: *Font, w: *Window, session: *Session) !void {
        const count = self.shared_clients orelse return;
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        r.clip = .{ .x = 0, .y = 0, .w = width, .h = height };
        const top = @max(0, height - 30);
        try r.rect(.{ .x = 0, .y = top, .w = width, .h = height - top }, theme.header);
        try r.rect(.{ .x = 0, .y = top, .w = width, .h = 1 }, theme.status_border);
        if (self.shared_controller) |owner| {
            try fit(r, font, 12, top + 5, @max(0, width - 24), theme.text, "F8 agent {s} / controller #{d} / {d} clients", .{ @tagName(session.agent_scope), owner, count });
        } else {
            try fit(r, font, 12, top + 5, @max(0, width - 24), theme.text, "F8 agent {s} / no controller / {d} clients", .{ @tagName(session.agent_scope), count });
        }
    }
    pub fn draw(self: *Workspace, r: *gpu.Renderer, font: *Font, w: *Window, session: *Session) !void {
        if (self.logical_frames.open) {
            session.profile_view_visible = false;
            self.animating = session.frames.busy();
            try self.logical_frames.draw(r, font, w, &session.frames);
            return self.drawSharedOwnership(r, font, w, session);
        }

        if (session.comparison) |job| if (self.comparison.open) {
            session.profile_view_visible = false;
            self.animating = !job.done.load(.acquire);
            try self.comparison.draw(r, font, w, job);
            return self.drawSharedOwnership(r, font, w, session);
        };
        if (self.invocations.open) {
            session.profile_view_visible = false;
            self.animating = @import("invocations.zig").View.busy(session);
            try self.invocations.draw(r, font, w, session, if (self.shared_clients != null) 30 else 0);
            return self.drawSharedOwnership(r, font, w, session);
        }
        if (session.imported) |*state| {
            try self.imported.draw(r, font, w, state);
            return self.drawSharedOwnership(r, font, w, session);
        }
        if (session.allocations.capture) |capture| if (capture.archived and !self.allocation_archive_seen) {
            self.allocation_archive_seen = true;
            self.show_profile = false;
            self.allocation_panel.show();
            self.allocation_panel.setMode(.heap);
        };
        self.refresh(session);
        self.animate(session);
        const state = session.target.snapshot().state;
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        const all = gpu.Rect{ .x = 0, .y = 0, .w = width, .h = height };
        const selected_thread: ?linux.Thread = if (session.target.snapshot().thread_count > 0) session.target.threadSlice()[self.selected] else null;
        const thread_color = if (selected_thread) |thread| style.threadColor(thread.id) else theme.good;
        r.clip = all;
        try r.rect(all, theme.background);
        try r.rect(.{ .x = 0, .y = 0, .w = width, .h = 44 }, theme.header);
        try r.rect(.{ .x = 0, .y = 43, .w = width, .h = 1 }, theme.border);
        try r.text(font, 18, 12, "xo", theme.good);
        try r.text(font, 41, 12, "db", theme.text);
        r.clip = .{ .x = 0, .y = 0, .w = width - 322, .h = 44 };
        if (session.target.core != null) try r.text(font, 91, 12, "/  core dump (read-only)", theme.weak) else try style.button(r, font, .{ .x = 91, .y = 8, .w = 171, .h = 29 }, "Processes", "O", theme.text, 0, 0);
        r.clip = all;
        {
            // Run state as a pill: tinted fill and border in the state's color.
            var buffer: [64]u8 = undefined;
            const label_text = std.fmt.bufPrint(&buffer, "#{d} {s}  PID {d}", .{ session.process_id, if (session.target.core != null) "core" else @tagName(state), session.target.snapshot().pid }) catch "";
            const color = switch (state) {
                .stopped => theme.warm,
                .running => theme.good,
                else => theme.weak,
            };
            const pill = gpu.Rect{ .x = width - 312, .y = 9, .w = r.measure(font, label_text) + 28, .h = 26 };
            try style.box(r, pill, style.fade(color, 0.10), style.fade(color, 0.45), @splat(13));
            try r.text(font, width - 298, 12, label_text, color);
        }
        try style.button(r, font, .{ .x = if (width < 900) 280 else 380, .y = 8, .w = if (width < 900) 110 else 178, .h = 29 }, if (self.show_profile) "Source" else "Flames", "F", theme.warm, 0, 0);
        for (buttons, 0..) |b, i| {
            const label_text: []const u8 = switch (b.code) {
                57 => if (session.target.core != null) "Read-only" else switch (state) {
                    .running => "Pause",
                    .stopped => if (session.pending_continue != null) "Cancel" else "Continue",
                    .exited => "Exited",
                    .idle => "No target",
                },
                66 => if (session.agent_scope == .observe) "Agent: observe" else "Agent: control",
                else => b.label,
            };
            const live = (session.target.core == null or b.code == 34) and (state == .stopped or (state == .running and (b.code == 57 or b.code == 32 or b.code == 66)));
            const color = if (!live) theme.weak else if (b.code == 57) theme.good else if (b.code == 66 and session.agent_scope != .observe) theme.warm else theme.text;
            try style.button(r, font, .{ .x = b.x, .y = 50, .w = b.w, .h = 29 }, label_text, b.key, color, if (live) self.hot[i] else 0, self.pressed[i]);
        }
        _ = try style.chip(r, font, 822, 54, "TAB", theme.weak);
        try r.text(font, 872, 55, if (self.show_registers) "locals" else "regs", theme.weak);
        const left = @round(width * self.split);
        const right = @round(width * 0.79);
        const bottom = if (self.show_profile) @round(height * profile_split) else self.bottomY(height);
        const body_y: f32 = 91;
        session.profile_view_visible = self.show_profile;
        const timeline_data = if (self.show_profile) self.timeline_source.refresh(session.profile) else null;
        if (self.show_profile) {
            // Capture replacement or shrinkage can change the selection.
            if (timeline_data) |data| if (self.timeline.sync(data)) self.applyTimeline(session);
            if (self.flame.basis == .recorded) if (session.profile) |capture| if (capture.offline and (self.flame.capture_id != capture.id or self.flame.revision != capture.revision or !std.meta.eql(self.flame.selection.filter, self.flame.built_filter))) session.ensureArchiveView(self.flame.selection.filter) catch {};
            const reconstructed: @import("flame.zig").Derived = if (self.flame.basis == .recorded) .none else switch (session.requestDerivedOwned(self.flame.selection.filter, .gui)) {
                .ready => |view| .{ .ready = view },
                .pending => |p| .{ .pending = .{ .done = p.done, .total = p.total } },
                .failed => |err| .{ .failed = @errorName(err) },
                .unavailable => |err| .{ .unavailable = @errorName(err) },
            };
            try self.flame.draw(r, font, .{ .x = 8, .y = body_y, .w = width - 16, .h = bottom - body_y - 5 }, session.profile, &session.recorded_views, session.profile_failure, session.profile_error, session.profile_requested_threads, session.profile_defaults, reconstructed);
            session.profile_view = if (self.flame.graph != null and (self.flame.basis == .recorded or reconstructed == .ready)) .{ .capture_id = self.flame.capture_id, .revision = self.flame.revision, .filter = self.flame.built_filter, .view_id = self.flame.view_id, .sample_count = self.flame.sample_count, .basis = @enumFromInt(@intFromEnum(self.flame.basis)) } else null;
        } else {
            const source_rect = gpu.Rect{ .x = 8, .y = body_y, .w = left - 12, .h = bottom - body_y - 5 };
            try pane(r, font, source_rect, if (self.source_truncated) "SOURCE (first 1 MiB)" else if (self.browse_address != null) "SOURCE / browsing" else "SOURCE", std.fs.path.basename(self.source_path));
            if (self.source.len == 0) {
                try r.text(font, 24, body_y + 58, "Open a file with --source <path>", theme.weak);
                try r.text(font, 24, body_y + 86, "Stop in code with DWARF to follow source.", theme.weak);
            } else {
                var lines = std.mem.splitScalar(u8, self.source, '\n');
                var number: i32 = 0;
                var y = body_y + 44;
                var more = false;
                while (lines.next()) |source| : (number += 1) {
                    if (number < self.source_line) continue;
                    if (y + 20 > bottom - 10) {
                        more = source.len != 0 or lines.rest().len != 0;
                        break;
                    }
                    const line_number: u32 = @intCast(number + 1);
                    const row = gpu.Rect{ .x = 9, .y = y - 2, .w = left - 14, .h = 23 };
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
                    y += 23;
                }
                if (more) try style.fadeBottom(r, .{ .x = source_rect.x + 1, .y = source_rect.y, .w = source_rect.w - 2, .h = source_rect.h - 1 }, 0.55);
            }
            if (self.show_flow) {
                try pane(r, font, .{ .x = left + 2, .y = body_y, .w = right - left - 6, .h = bottom - body_y - 5 }, "CONTROL FLOW", "G assembly");
                try self.flow.draw(r, font, r.clip, if (self.regs) |regs| linux.programCounter(regs) catch null else null);
            } else {
                try pane(r, font, .{ .x = left + 2, .y = body_y, .w = right - left - 6, .h = bottom - body_y - 5 }, "ASSEMBLY", if (self.browse_address != null) "browsing / G flow" else "x86-64 / G flow");
                if (self.instruction_count == 0) try r.text(font, left + 16, body_y + 55, "Pause to inspect instructions", theme.weak);
                const current_pc = if (self.regs) |regs| linux.programCounter(regs) catch null else null;
                self.assembly_rows = .{ .x = left + 2, .y = body_y + 45, .w = right - left - 6, .count = 0 };
                for (self.instructions[0..self.instruction_count], 0..) |inst, i| {
                    const y = body_y + 45 + @as(f32, @floatFromInt(i)) * 23;
                    if (y + 20 > bottom - 10) break;
                    self.assembly_rows.count = i + 1;
                    if (self.assembly_cursor == inst.address and !self.static_from_line) try style.focus(r, .{ .x = left + 4, .y = y - 2, .w = right - left - 10, .h = 23 }, 4, 1);
                    if (current_pc != null and inst.address == current_pc.?) {
                        try style.threadLine(r, .{ .x = left + 3, .y = y - 2, .w = right - left - 8, .h = 23 }, thread_color, self.alive, 16);
                        try r.text(font, left + 8, y, "\u{25b6}", thread_color);
                    }
                    try label(r, font, left + 22, y, if (current_pc != null and inst.address == current_pc.?) thread_color else theme.weak, "{x:0>12}", .{inst.address});
                    const mnemonic = std.mem.sliceTo(@as([]const u8, &inst.mnemonic), 0);
                    try r.text(font, left + 156, y, mnemonic, theme.neutral);
                    try r.textFit(font, left + 156 + @max(58, r.measure(font, mnemonic) + 10), y, right - left - 6 - 156 - 70, std.mem.sliceTo(@as([]const u8, &inst.operands), 0), theme.text);
                }
            }
            const side = gpu.Rect{ .x = right + 2, .y = body_y, .w = width - right - 10, .h = bottom - body_y - 5 };
            if (!self.show_registers) {
                try pane(r, font, side, "LOCALS", "TAB registers");
                if (self.local_diagnostic) |diagnostic| try r.text(font, right + 14, body_y + 48, diagnostic, theme.weak);
                for (self.locals, 0..) |local, i| {
                    const y = body_y + 44 + @as(f32, @floatFromInt(i)) * 48;
                    if (y + 40 > bottom - 10) break;
                    if (i == self.selected_local) try style.focus(r, .{ .x = right + 6, .y = y - 3, .w = side.w - 8, .h = 47 }, 6, 1);
                    try r.textFit(font, right + 14, y, side.w - 24, local.name, theme.neutral);
                    const type_x = right + 14 + r.measure(font, local.name) + 14;
                    const advisory = if (local.value.visualization) |v| v.extent_advisory else false;
                    try r.textFit(font, type_x, y, side.x + side.w - 10 - type_x, if (advisory) "extent unproved" else local.value.type, theme.weak);
                    try r.textFit(font, right + 14, y + 21, side.w - 24, local.value.display, if (local.value.availability == .available and !advisory) theme.text else theme.weak);
                }
            } else {
                try pane(r, font, side, "REGISTERS", "changed since last stop");
                if (self.regs) |regs| {
                    for (regs.descriptions(), 0..) |desc, i| {
                        const y = body_y + 45 + @as(f32, @floatFromInt(i)) * 23;
                        const value = regs.value(desc) catch null;
                        const previous = if (self.stale_regs) |old| if (old.architecture() == regs.architecture()) old.value(desc) catch null else null else null;
                        const changed = value != null and previous != null and value.? != previous.?;
                        if (changed) try r.shape(.{ .x = right + 79, .y = y - 2, .w = 166, .h = 23 }, theme.fresh, .{ .radii = @splat(5) });
                        try label(r, font, right + 14, y, theme.weak, "{s}", .{std.mem.span(desc.name)});
                        if (value) |word| {
                            try label(r, font, right + 85, y, if (i == 0) thread_color else if (changed) theme.warm else theme.text, "{x:0>16}", .{word});
                        } else try label(r, font, right + 85, y, theme.weak, "{s}", .{"unavailable"});
                    }
                } else try r.text(font, right + 14, body_y + 55, "No stopped thread", theme.weak);
            }
        }
        if (self.show_profile) {
            try self.timeline.draw(r, font, .{ .x = 8, .y = bottom, .w = width - 16, .h = height - bottom - 37 }, timeline_data);
            if (self.inspector.open) if (session.profile) |capture| {
                self.inspector.sync(capture, self.flame.selection.filter);
                try self.inspector.draw(r, font, .{ .x = 8, .y = body_y, .w = width - 16, .h = height - body_y - 37 }, capture, inspectorStack(session, self.inspector.ordinal), if (session.frames.jit_view) |view| view.sample(capture, self.inspector.ordinal, session.frames.evidence_revision) else null);
            };
            if (self.setup.open) {
                const snapshot = self.thread_rows.snapshot(session);
                if (self.thread_selection.sync(&snapshot) == .cleared_replaced) self.setup.message = "The target changed; the earlier thread choice was cleared";
                try self.setup.draw(r, font, .{ .x = 8, .y = body_y, .w = width - 16, .h = height - body_y - 37 }, .{ .snapshot = &snapshot, .defaults = session.profile_defaults, .selection = &self.thread_selection, .facts = if (session.profile) |capture| capture_setup.factsFrom(capture) else null, .clock = .{ .now_ns = linux.now() }, .start_error = session.profile_error, .start_failure = session.profile_failure, .requested_threads = session.profile_requested_threads });
            }
        } else try self.drawBottom(r, font, session, width, height, left, bottom, thread_color);
        r.clip = all;
        try r.rect(.{ .x = 0, .y = height - 28, .w = width, .h = 28 }, self.bar);
        try r.rect(.{ .x = 0, .y = height - 28, .w = width, .h = 1 }, theme.status_border);
        if (session.frames.attachment.failure) |err| {
            try fit(r, font, 16, height - 23, if (width >= 900) width - 432 else width - 32, theme.warm, "Archive frames {s}: {s} / L details", .{ @tagName(session.frames.attachment.state), @errorName(err) });
        } else if (self.shared_clients) |count| {
            if (self.shared_controller) |owner| {
                try fit(r, font, 16, height - 23, if (width >= 900) width - 432 else width - 32, theme.text, "{s} / agent {s} / controller #{d} / {d} clients", .{ self.status, @tagName(session.agent_scope), owner, count });
            } else {
                try fit(r, font, 16, height - 23, if (width >= 900) width - 432 else width - 32, theme.text, "{s} / agent {s} / no controller / {d} clients", .{ self.status, @tagName(session.agent_scope), count });
            }
        } else {
            try fit(r, font, 16, height - 23, if (width >= 900) width - 432 else width - 32, theme.text, "{s}  /  agent {s}  /  generation {d}", .{ self.status, @tagName(session.agent_scope), session.target.snapshot().generation });
        }
        if (width >= 900) try r.text(font, width - 400, height - 23, std.mem.sliceTo(@as([]const u8, &r.gpu_name), 0), style.fade(theme.text, 0.55));
        if (!self.show_profile) try r.rect(.{ .x = left - 3, .y = body_y, .w = 3, .h = height - body_y - 35 }, if (self.dragging) theme.focus else if (self.divider_hot) style.fade(theme.focus, 0.55) else style.fade(theme.border, 0.6));
        try self.probes_panel.draw(r, font, width, height, session);
        const inspect_tid = if (session.target.snapshot().thread_count > 0) session.target.threadSlice()[@min(self.selected, session.target.snapshot().thread_count - 1)].tid else 0;
        try self.inspection_panel.draw(r, font, width, height, session, inspect_tid);
        try self.inline_panel.draw(r, font, width, height, session, inspect_tid, self.selected_frame);
        try self.static_panel.draw(r, font, width, height, session, inspect_tid, self.selected_frame);
        if (self.static_panel.open and self.static_panel.running) self.animating = true;
        try self.stop_panel.draw(r, font, width, height, session, inspect_tid);
        if (self.show_profile) try self.syscall_panel.draw(r, font, width, height, session.profile, self.flame.selection.filter);
        try self.allocation_panel.drawLive(r, font, width, height, &session.allocations, inspect_tid);
        if (self.allocation_panel.open and self.allocation_panel.mode == .heap and self.allocation_panel.heap_pending) self.animating = true;
        if (self.allocation_save_editor.open) {
            const b = gpu.Rect{ .x = 32, .y = 102, .w = @max(0, width - 64), .h = 92 };
            try style.box(r, b, theme.background, theme.focus, @splat(6));
            try r.textFit(font, b.x + 10, b.y + 8, b.w - 20, "Save allocation archive: enter a new file path; Enter saves, Esc cancels", theme.text);
            try self.allocation_save_editor.draw(r, font, .{ .x = b.x + 10, .y = b.y + 34, .w = b.w - 20, .h = 22 });
            try r.textFit(font, b.x + 10, b.y + 61, b.w - 20, self.allocation_save_editor.message, theme.warm);
        }
        if (session.process_tree) |tree| try self.process_panel.draw(tree, r, font, width, height);
    }
    /// Threads, stack and events, below the source view.
    fn drawBottom(self: *Workspace, r: *gpu.Renderer, font: *Font, session: *Session, width: f32, height: f32, left: f32, bottom: f32, thread_color: gpu.Color) !void {
        const thread_right = @round(left * 0.36);
        try pane(r, font, .{ .x = 8, .y = bottom, .w = thread_right - 12, .h = height - bottom - 37 }, "THREADS", "J/K to select");
        const thread_rows: usize = @intFromFloat(@max(1, (height - bottom - 87) / 25));
        const first_thread = (self.selected + 1) -| thread_rows;
        for (session.target.threadSlice(), 0..) |thread, i| {
            if (i < first_thread) continue;
            const y = bottom + 44 + @as(f32, @floatFromInt(i - first_thread)) * 25;
            if (i == self.selected) try style.focus(r, .{ .x = 12, .y = y - 3, .w = thread_right - 20, .h = 25 }, 6, 1);
            try style.disc(r, 25, y + 9.5, 4, style.fade(style.threadColor(thread.id), if (thread.state == .running) 0.5 else 1));
            try fit(r, font, 40, y, thread_right - 12 - 40, if (i == self.selected) theme.text else theme.weak, "{d} {s}", .{ @as(u32, @intCast(thread.tid)), if (thread.reason != .none and thread.state == .stopped) @tagName(thread.reason) else @tagName(thread.state) });
        }
        if (session.target.snapshot().thread_count == 0) try r.textFit(font, 24, bottom + 50, thread_right - 40, "Launch with -- <executable> [args]", theme.weak);
        const stack = gpu.Rect{ .x = thread_right, .y = bottom, .w = left - thread_right - 4, .h = height - bottom - 37 };
        try pane(r, font, stack, "STACK", "click frame / I inline");
        for (self.frames, 0..) |frame, i| {
            const y = bottom + 44 + @as(f32, @floatFromInt(i)) * 25;
            if (y + 20 > height - 40) break;
            if (i == self.selected_frame) try style.focus(r, .{ .x = thread_right + 4, .y = y - 3, .w = stack.w - 8, .h = 25 }, 6, 1);
            try label(r, font, thread_right + 12, y, if (i == 0) thread_color else theme.weak, "{d: >2}", .{i});
            // Frames without source are dimmed; frames with it show where.
            var where_buffer: [96]u8 = undefined;
            const where = if (frame.source) |site| std.fmt.bufPrint(&where_buffer, "{s}:{d}", .{ std.fs.path.basename(site.path), site.line }) catch "" else "";
            const where_width = r.measure(font, where);
            const name_width = stack.w - 54 - (if (where.len > 0 and stack.w > 330) where_width + 16 else 0);
            try fit(r, font, thread_right + 42, y, name_width, if (frame.source != null) theme.text else theme.weak, "{s} {s}", .{ frame.symbol orelse "?", frame.diagnostic orelse "" });
            if (where.len > 0 and stack.w > 330) try r.text(font, stack.x + stack.w - where_width - 12, y, where, theme.weak);
        }
        const events_rect = gpu.Rect{ .x = left + 2, .y = bottom, .w = width - left - 10, .h = height - bottom - 37 };
        if (self.show_watch) {
            const wide = events_rect.w > 640;
            try pane(r, font, events_rect, "WATCH", if (self.editor.open) (if (self.editor.mode == .live) "Live / Up/Down history  Return add  Esc cancel" else "Pinned / Up/Down history  Return add  Esc cancel") else if (wide) "E/Shift+E add  V events  [] scroll  Shift+L convert  Del remove  Return expand  W write" else "E/Shift+E add  V events  [] scroll");
            if (self.watch_focus) try r.rect(.{ .x = events_rect.x + 1, .y = events_rect.y + 32, .w = events_rect.w - 2, .h = 2 }, theme.focus);
            self.watch_rect = events_rect;
            try watch_ui.draw(&self.watch, &self.editor, r, font, r.clip, &self.watch_hits);
            return;
        }
        self.watch_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        try pane(r, font, events_rect, "EVENTS", if (self.watch.count > 0) "monotonic time  /  V watch" else "monotonic time  /  E expression");
        const events = session.target.eventSlice();
        const visible: usize = @intFromFloat(@max(1, (height - bottom - 87) / 23));
        const start = events.len -| visible;
        for (events[start..], 0..) |event, i| {
            const y = bottom + 44 + @as(f32, @floatFromInt(i)) * 23;
            if ((start + i) % 2 == 1) try r.rect(.{ .x = events_rect.x + 1, .y = y - 2, .w = events_rect.w - 2, .h = 23 }, theme.stripe);
            const ms = (event.time_ns - events[0].time_ns) / 1_000_000;
            try label(r, font, left + 16, y, theme.weak, "+{d: >7} ms", .{ms});
            const kind_color = switch (event.kind) {
                .stop => theme.warm,
                .breakpoint_hit, .watchpoint_hit => theme.breakpoint,
                .exit, .detach => theme.weak,
                else => theme.good,
            };
            try label(r, font, left + 160, y, kind_color, "{s: <12}", .{@tagName(event.kind)});
            if (event.kind == .watchpoint_hit) {
                if (!event.before_valid or !event.after_valid or event.watch_attribution == .candidate) {
                    try fit(r, font, left + 325, y, events_rect.w - 335, theme.warm, "0x{x}: {s} / {s}", .{ event.address, @tagName(event.watch_phase), if (event.watch_attribution == .candidate) "candidate watch" else "value unavailable" });
                } else try fit(r, font, left + 325, y, events_rect.w - 335, theme.warm, "0x{x}: {d} -> {d}", .{ event.address, event.before, event.after });
            } else try fit(r, font, left + 325, y, events_rect.w - 335, theme.text, "thread {d}   detail {d}", .{ event.tid, event.detail });
        }
    }
};

/// Per-frame thread snapshot for the setup panel: rows by value with names
/// read once per debugger thread ID from the live target's comm files.
/// Nothing here points into target storage; names live in this cache.
const ThreadRows = struct {
    rows: [@import("../profile/linux_perf.zig").max_threads]capture_setup.ThreadRow = undefined,
    names: [@import("../profile/linux_perf.zig").max_threads]Name = undefined,
    name_count: usize = 0,
    key: ?capture_setup.TargetKey = null,
    const Name = struct { id: u64, len: u8, bytes: [16]u8 };

    fn snapshot(self: *ThreadRows, session: *Session) capture_setup.Snapshot {
        const target = &session.target;
        const live = target.core == null and target.snapshot().pid != 0 and target.snapshot().state != .idle and target.snapshot().state != .exited;
        const key: ?capture_setup.TargetKey = if (live) .{ .pid = target.snapshot().pid, .image_epoch = target.snapshot().image_epoch } else null;
        if (!std.meta.eql(key, self.key)) {
            self.key = key;
            self.name_count = 0;
        }
        var n: usize = 0;
        if (live) for (target.threadSlice()) |thread| {
            if (n == self.rows.len) break;
            self.rows[n] = .{ .ref = .{ .id = thread.id, .tid = thread.tid }, .state = switch (thread.state) {
                .stopped => .stopped,
                .running => .running,
                else => .exited,
            }, .name = self.name(target, thread.id, thread.tid) };
            n += 1;
        };
        const collecting = if (session.profile) |capture| capture.collector != null else false;
        return .{ .target = key, .stopped = target.snapshot().state == .stopped, .offline = session.offline, .collecting = collecting, .threads = self.rows[0..n] };
    }
    fn name(self: *ThreadRows, target: *const @import("../target/linux.zig").Target, id: u64, tid: i32) []const u8 {
        for (self.names[0..self.name_count]) |*entry| if (entry.id == id) return entry.bytes[0..entry.len];
        if (self.name_count == self.names.len) return "";
        const rt = @import("../target/runtime.zig").c;
        const request = std.mem.zeroInit(rt.struct_xrt_file_request, .{ .kind = rt.XRT_FILE_THREAD_COMM, .tid = tid });
        const entry = &self.names[self.name_count];
        entry.* = .{ .id = id, .len = 0, .bytes = undefined };
        var fd: c_int = -1;
        if (rt.xrt_target_file(target.handle, &request, &fd) == rt.XRT_OK) {
            defer _ = c.close(fd);
            const got = c.read(fd, &entry.bytes, entry.bytes.len);
            if (got > 0) entry.len = @intCast(std.mem.trimEnd(u8, entry.bytes[0..@intCast(got)], "\n").len);
        }
        self.name_count += 1;
        return entry.bytes[0..entry.len];
    }
};

/// The timeline's display data for the session capture: per-thread sample
/// times and debugger stop ranges. Rebuilt when the capture revision changes,
/// at most four times a second while collecting. Samples follow the capture's
/// own validity rule (time and TID present, not before start, an opening
/// thread), so counts agree with flames and `get_profile_timeline`.
/// Scheduling intervals use the same reconstruction as MCP.
const TimelineSource = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    data: ?timeline.Data = null,
    capture_id: u64 = 0,
    revision: u64 = 0,
    built_ns: u64 = 0,

    fn deinit(self: *TimelineSource) void {
        self.arena.deinit();
    }
    fn refresh(self: *TimelineSource, capture: ?*profile.Capture) ?*const timeline.Data {
        const current = capture orelse {
            self.data = null;
            return null;
        };
        const same = self.data != null and current.id == self.capture_id;
        if (same and current.revision == self.revision) return &self.data.?;
        if (same and current.collector != null and linux.now() -| self.built_ns < 250_000_000) return &self.data.?;
        self.build(current) catch {
            self.data = null;
            return null;
        };
        return &self.data.?;
    }
    const max_stop_spans = 4096;
    fn build(self: *TimelineSource, capture: *profile.Capture) !void {
        self.data = null;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        const n = capture.thread_count;
        var lane_of: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        try lane_of.ensureTotalCapacity(a, @intCast(n));
        for (capture.threads[0..n], 0..) |thread, i| lane_of.putAssumeCapacity(@intCast(thread.perf.tid), @intCast(i));
        const counts = try a.alloc(usize, n);
        @memset(counts, 0);
        for (0..capture.samples.len()) |ordinal| {
            const sample = capture.samples.core(ordinal);
            if (valid(capture, sample)) if (lane_of.get(sample.tid)) |i| {
                counts[i] += 1;
            };
        }
        const lanes = try a.alloc(timeline.Lane, n);
        const times = try a.alloc([]u64, n);
        for (lanes, times, counts, capture.threads[0..n]) |*lane, *slot, count, thread| {
            slot.* = try a.alloc(u64, count);
            lane.* = .{ .tid = @intCast(thread.perf.tid), .debugger_id = thread.debugger_id };
        }
        @memset(counts, 0);
        for (0..capture.samples.len()) |ordinal| {
            const sample = capture.samples.core(ordinal);
            if (valid(capture, sample)) if (lane_of.get(sample.tid)) |i| {
                times[i][counts[i]] = sample.time_ns - capture.started_ns;
                counts[i] += 1;
            };
        }
        for (lanes, times) |*lane, slot| {
            std.mem.sort(u64, slot, {}, std.sort.asc(u64));
            lane.samples = slot;
        }
        const extent = capture.extentNs();
        if (capture.config.context_switch) for (lanes, 0..) |*lane, i| {
            const spans = try capture.switches.spans(a, i, extent, .{ .from_ns = 0, .to_ns = extent }, capture.schedulingCoverage());
            const intervals = try a.alloc(timeline.Interval, spans.len);
            for (spans, intervals) |span, *interval| interval.* = .{
                .from_ns = span.from_ns,
                .to_ns = span.to_ns,
                .state = switch (span.state) {
                    .running => .running,
                    .off_cpu => .off_cpu,
                    .unknown => .unknown,
                },
                .from_observed = span.from_ns != 0 and span.state != .unknown,
                .to_observed = span.to_ns != extent and span.state != .unknown,
                .preempted = span.switch_out_preempted orelse false,
                .detail = if (span.unknown_reason) |reason| @tagName(reason) else "",
            };
            lane.intervals = intervals;
        };
        var omitted: u64 = 0;
        const stops_ = try stops(a, capture, extent, &omitted);
        const imported = capture.application_intervals.items.items;
        const marks = try a.alloc(timeline.Mark, stops_.len + imported.len + capture.syscalls.items.items.len);
        @memcpy(marks[0..stops_.len], stops_);
        for (imported, marks[stops_.len..][0..imported.len]) |interval, *mark| mark.* = .{ .from_ns = interval.from_ns, .to_ns = interval.to_ns, .kind = .application, .tid = interval.tid, .label = try std.fmt.allocPrint(a, "  /  imported {s}: {s}", .{ @tagName(interval.kind), interval.label() }) };
        for (capture.syscalls.items.items, marks[stops_.len + imported.len ..]) |span, *mark| {
            const from = (span.entry_ns orelse span.exit_ns.?) -| capture.started_ns;
            const to = (span.exit_ns orelse span.entry_ns.?) -| capture.started_ns;
            mark.* = .{ .from_ns = from, .to_ns = to, .kind = .syscall, .tid = @intCast(capture.threads[span.thread_index].perf.tid), .label = if (span.elapsed()) |ns| try std.fmt.allocPrint(a, "  /  syscall {s} ({d}): {d:.3} ms elapsed", .{ @import("../profile/syscalls.zig").name(span.nr) orelse "?", span.nr, @as(f64, @floatFromInt(ns)) / 1000000 }) else try std.fmt.allocPrint(a, "  /  syscall ({d}): {s}, duration unknown", .{ span.nr, @tagName(span.reason) }) };
        }
        self.data = .{ .capture_id = capture.id, .revision = capture.revision, .extent_ns = extent, .live = capture.collector != null, .scheduling = capture.config.context_switch, .lanes = lanes, .marks = marks, .application_count = imported.len, .syscall_count = capture.syscalls.items.items.len, .debugger_marks_dropped = omitted +| capture.debugger_marker_dropped +| capture.debugger_events_lost, .lost_samples = capture.lost_samples };
        self.capture_id = capture.id;
        self.revision = capture.revision;
        self.built_ns = linux.now();
    }
    fn valid(capture: *const profile.Capture, sample: anytype) bool {
        return sample.timePresent() and sample.tidPresent() and sample.time_ns >= capture.started_ns;
    }
    /// Debugger stop ranges from the capture's observed control markers. These
    /// are debugger timestamps, not exact scheduler boundaries. With lost events
    /// a pairing could span a missed resume, so none are shown; a stop still open
    /// at the last retained marker is omitted when later markers were dropped.
    fn stops(a: std.mem.Allocator, capture: *const profile.Capture, extent: u64, omitted: *u64) ![]timeline.Mark {
        var out: std.ArrayList(timeline.Mark) = .empty;
        if (capture.debugger_events_lost > 0) return out.items;
        for (capture.threads[0..capture.thread_count]) |thread| {
            var from: ?u64 = null;
            for (capture.debugger_markers.items) |marker| {
                if (thread.enrolled_ns) |enrolled| if (marker.offset_ns < enrolled -| capture.started_ns) continue;
                const all = marker.kind == .capture_open_stopped or marker.kind == .continued or marker.kind == .detach;
                if (!all and marker.tid != thread.perf.tid) continue;
                switch (marker.kind) {
                    .capture_open_stopped, .stop, .breakpoint_hit, .watchpoint_hit, .step_complete => {
                        if (from == null) from = marker.offset_ns;
                    },
                    .continued, .step_started, .exit, .detach => if (from) |start| {
                        if (marker.offset_ns > start) try stopSpan(a, &out, omitted, .{ .from_ns = start, .to_ns = marker.offset_ns, .kind = .debugger_stop, .tid = @intCast(thread.perf.tid) });
                        from = null;
                    },
                }
            }
            if (from) |start| if (capture.debugger_marker_dropped == 0 and extent > start) try stopSpan(a, &out, omitted, .{ .from_ns = start, .to_ns = extent, .kind = .debugger_stop, .tid = @intCast(thread.perf.tid) });
        }
        return out.items;
    }
    fn stopSpan(a: std.mem.Allocator, out: *std.ArrayList(timeline.Mark), omitted: *u64, mark: timeline.Mark) !void {
        if (out.items.len == max_stop_spans) {
            omitted.* +|= 1;
        } else try out.append(a, mark);
    }
};

test "queued drag preserves release position and quit ends the batch" {
    var session = Session{ .id = 1 };
    defer session.deinit();
    var workspace = Workspace{};
    defer workspace.deinit();
    var w = Window{ .width = 1000, .height = 800, .pointer_x = 600, .pointer_y = 300 };
    w.input.button(1, 272, true, 480, 300);
    w.input.button(2, 272, false, 600, 300);
    workspace.input(&w, &session);
    try std.testing.expectApproxEqAbs(@as(f32, 0.60), workspace.split, 0.001);
    try std.testing.expect(!workspace.dragging);
    w.mouse_down = true;
    w.input.button(3, 272, true, 600, 300);
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
    w.input.queue[0] = .{ .kind = .press, .shortcut = 'q' };
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
        _ = @import("../c.zig").api.usleep(1000);
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
    const data = workspace.timeline_source.refresh(capture).?;
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
    const dynamic = workspace.timeline_source.refresh(capture).?;
    for (dynamic.marks) |mark| try std.testing.expect(mark.tid != 42);
    // A replacement capture clears both.
    capture.id = 4;
    const replaced = workspace.timeline_source.refresh(capture).?;
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
    const snapshot = workspace.thread_rows.snapshot(&session);
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
    const replaced = workspace.thread_rows.snapshot(&session);
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
