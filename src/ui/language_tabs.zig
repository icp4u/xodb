const std = @import("std");
const c = @import("../c.zig").api;
const TextLayout = @import("overview/draw.zig").Layout;
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Session = @import("../model/session.zig").Session;
const tabs = @import("../model/language_tabs.zig");
const selection = @import("../model/language_selection.zig");
const style = @import("style.zig");
const theme = style.theme;
const named = @import("../model/language_locals.zig");
const Editor = @import("watch.zig").Editor;
const Row = struct { following: usize = 0, name: []const u8, location: []const u8, reason: ?[]const u8, segment: usize, frame: ?usize };
const Hit = struct { rect: gpu.Rect, segment: usize, frame: usize };
const SelectedKey = struct { generation: u64, tid: i32, language: tabs.Tab, segment: usize, frame: usize };
const Key = struct { session: u64, generation: u64, revision: u64, metadata: u64, tid: i32, frame: usize, tab: tabs.Tab };
const NativePolicy = enum { auto, expanded, collapsed };
const Layout = struct { stack: f32, native: f32, collapsed: bool };
fn sectionLayout(available: f32, has_named: bool, native_count: usize, policy: NativePolicy, named_min: f32) Layout {
    const room = @max(0, available);
    const stack_min = @min(room, 3 * 48);
    var collapsed = policy == .collapsed or (policy == .auto and native_count == 0);
    if (policy == .auto and has_named and room < stack_min + 96 + named_min) collapsed = true;
    const native_wanted: f32 = if (collapsed) (if (has_named) 32 else 84) else if (has_named) 96 else @max(129, room * 0.43);
    const native_height = @min(native_wanted, room - stack_min);
    const stack_max = @max(stack_min, room - native_height - (if (has_named) named_min else @as(f32, 0)));
    const stack_height = if (has_named) @min(stack_max, @max(stack_min, @floor(room * 0.43) + @as(f32, if (collapsed) 64 else 0))) else room - native_height;
    return .{ .stack = stack_height, .native = native_height, .collapsed = collapsed };
}
fn revealRow(scroll: usize, index: usize, visible: usize) usize {
    // Keep one preceding row when a selection was at/above the viewport top.
    if (index <= scroll and visible > 1) return index -| 1;
    if (index < scroll) return index;
    if (index >= scroll + visible) return index -| (visible -| 1);
    return scroll;
}
pub const Panel = struct {
    text_layout: ?*TextLayout = null,
    layout_signature: ?u64 = null,
    layout_reason: []const u8 = "none",
    hits: [tabs.order.len]?gpu.Rect = @splat(null),
    content_y: f32 = 135,
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    rows: []Row = &.{},
    row_hits: [64]?Hit = @splat(null),
    scroll: usize = 0,
    native_policy: NativePolicy = .auto,
    native_collapsed: bool = false,
    native_header_hit: ?gpu.Rect = null,
    native_scroll: usize = 0,
    native_count: usize = 0,
    native_y: f32 = std.math.inf(f32),
    revealed: ?SelectedKey = null,
    stack_basis: ?[]const u8 = null,
    message: []const u8 = "",
    key: ?Key = null,
    bindings: ?named.Result = null,
    bindings_reason: []const u8 = "Select a logical frame for named locals",
    bindings_key: ?SelectedKey = null,
    binding_start: usize = 0,
    binding_visible: usize = 0,
    binding_selected: ?usize = null,
    binding_hits: [32]?struct { rect: gpu.Rect, index: usize } = @splat(null),
    binding_y: f32 = std.math.inf(f32),
    expression: [128]u8 = undefined,
    expression_len: usize = 0,
    expression_result: ?named.Result = null,
    expression_reason: ?[]const u8 = null,
    editor: Editor = .{},
    editor_key: ?SelectedKey = null,
    editor_watch: bool = false,
    fn selectedKey(session: *Session) ?SelectedKey {
        const row = session.language_tabs.logical_selection orelse return null;
        if (row.generation != session.target.snapshot().generation or row.language != session.language_tabs.selected) return null;
        return .{ .generation = row.generation, .tid = row.tid, .language = row.language, .segment = row.segment, .frame = row.frame };
    }
    pub fn syncEditor(self: *Panel, session: *Session) void {
        if (!self.editor.open) return;
        const selected = selectedKey(session);
        if (@intFromEnum(session.language_tabs.selected) < 2) {
            self.editor.open = false;
        } else if (self.editor_key == null) {
            // E before a frame is chosen (or after a stop dropped it) still
            // owns the keyboard, so typed text never reaches global keys.
            // The first frame the user then selects binds the field.
            if (selected != null) {
                self.editor_key = selected;
                self.editor.message = if (named.supported(session.language_tabs.selected)) "" else "Elisp expressions unavailable; Esc cancels";
            }
        } else if (selected == null or !std.meta.eql(selected.?, self.editor_key.?)) self.editor.open = false;
    }
    pub fn beginExpression(self: *Panel, session: *Session) !void {
        if (@intFromEnum(session.language_tabs.selected) < 2) return error.LanguageLocalsUnavailable;
        self.editor_key = selectedKey(session);
        self.editor_watch = false;
        self.editor.start();
        if (session.language_tabs.selected == .elisp) self.editor.message = "Elisp expressions unavailable; Esc cancels" else if (self.editor_key == null) self.editor.message = "Select a logical frame first; Esc cancels";
    }
    pub fn submitExpression(self: *Panel, session: *Session, text: []const u8) !void {
        if (session.language_tabs.selected == .elisp) return error.ElispExpressionsUnavailable;
        const selected = selectedKey(session) orelse return error.SelectLanguageFrame;
        if (self.editor_key == null or !std.meta.eql(self.editor_key.?, selected)) return error.StaleLanguageFrame;
        if (text.len == 0 or text.len > self.expression.len) return error.InvalidArguments;
        if (self.editor_watch) {
            _ = try session.language_watches.add(session, selected.language, selected.tid, selected.segment, selected.frame, text, null);
            session.record(.human, "add_language_watch");
            self.editor.open = false;
            return;
        }
        @memcpy(self.expression[0..text.len], text);
        self.expression_len = text.len;
        self.bindings_key = selected;
        self.key = null;
        self.editor.open = false;
    }
    pub fn watchBinding(self: *Panel, session: *Session) !u64 {
        if (session.language_tabs.selected == .elisp) return error.ElispWatchesUnavailable;
        const selected = selectedKey(session) orelse return error.SelectLanguageFrame;
        if (self.bindings_key == null or !std.meta.eql(self.bindings_key.?, selected)) return error.StaleLanguageFrame;
        const index = self.binding_selected orelse return error.SelectNamedBindingForWatch;
        const id = try session.language_watches.add(session, selected.language, selected.tid, selected.segment, selected.frame, null, index);
        session.record(.human, "add_language_watch");
        return id;
    }
    pub fn scrollBindings(self: *Panel, amount: i32) void {
        const result = self.bindings orelse return;
        // A wheel notch can represent several lines. Never jump over rows
        // when the viewport has room for only one or two bindings.
        const step = @min(@max(@as(usize, 1), self.binding_visible), @as(usize, @intCast(@abs(@as(i64, amount)))));
        if (amount < 0) self.binding_start -|= step else self.binding_start = @min(result.total -| 1, self.binding_start +| step);
        self.key = null;
    }
    pub fn deinit(self: *Panel) void {
        self.arena.deinit();
        if (self.text_layout) |layout| std.heap.page_allocator.destroy(layout);
    }
    pub fn hit(self: *const Panel, x: f32, y: f32) ?tabs.Tab {
        for (self.hits, 0..) |maybe, i| if (maybe) |rect| {
            if (x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h) return tabs.order[i];
        };
        return null;
    }
    pub fn click(self: *Panel, session: *Session, x: f32, y: f32) !bool {
        const key = self.key orelse return false;
        if (self.native_header_hit) |rect| {
            if (x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h) {
                if (key.session != session.id or key.generation != session.target.snapshot().generation or key.tab != session.language_tabs.selected) return error.StaleLanguageView;
                self.native_policy = if (self.native_collapsed) .expanded else .collapsed;
                self.revealed = null;
                return true;
            }
        }
        for (self.binding_hits) |maybe| if (maybe) |binding| {
            const rect = binding.rect;
            if (x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h) {
                if (key.session != session.id or key.generation != session.target.snapshot().generation or key.tab != session.language_tabs.selected) return error.StaleLanguageView;
                const selected = selectedKey(session) orelse return error.SelectLanguageFrame;
                if (self.bindings_key == null or !std.meta.eql(selected, self.bindings_key.?)) return error.StaleLanguageFrame;
                self.binding_selected = binding.index;
                return true;
            }
        };
        if (self.native_header_hit) |rect| {
            if (x >= rect.x and x < rect.x + rect.w and y >= rect.y + rect.h and y < self.binding_y) {
                self.binding_selected = null;
                return true;
            }
        }
        for (self.row_hits) |maybe| if (maybe) |row| {
            const rect = row.rect;
            if (x < rect.x or x >= rect.x + rect.w or y < rect.y or y >= rect.y + rect.h) continue;
            if (key.session != session.id or key.generation != session.target.snapshot().generation or key.metadata != session.metadata.revision or key.tab != session.language_tabs.selected)
                return error.StaleLanguageView;
            try selection.selectLogical(session, key.tid, key.tab, row.segment, row.frame);
            return true;
        };
        return false;
    }
    pub fn scrollBy(self: *Panel, amount: i32) void {
        if (amount >= 0) self.scroll = @min(self.rows.len -| 1, self.scroll +| @as(usize, @intCast(amount))) else self.scroll -|= @intCast(-@as(i64, amount));
    }
    pub fn scrollNative(self: *Panel, amount: i32) void {
        if (amount >= 0) self.native_scroll = @min(self.native_count -| 1, self.native_scroll +| @as(usize, @intCast(amount))) else self.native_scroll -|= @intCast(-@as(i64, amount));
    }
    pub fn header(self: *Panel, r: *gpu.Renderer, font: *Font, rect: gpu.Rect, state: *const tabs.State) !void {
        self.hits = @splat(null);
        r.clip = rect;
        try style.box(r, rect, theme.background, theme.border, @splat(5));
        var x = rect.x + 6;
        var y = rect.y + 5;
        for (tabs.order, 0..) |tab, i| {
            if (!state.visible(tab)) continue;
            var offered = false;
            for (state.offers.items[0..state.offers.count]) |offer| if (offer.language == tab) {
                offered = true;
                break;
            };
            const width = r.measure(font, tabs.title(tab)) + 16 + @as(f32, if (offered) 14 else 0);
            if (x + width > rect.x + rect.w - 5 and x > rect.x + 6) {
                x = rect.x + 6;
                y += 28;
            }
            const button = gpu.Rect{ .x = x, .y = y, .w = width, .h = 25 };
            self.hits[i] = button;
            if (state.selected == tab) try style.focus(r, button, 4, 1);
            try r.text(font, x + 8, y + 3, tabs.title(tab), if (state.selected == tab) theme.text else theme.weak);
            if (offered) try r.text(font, x + width - 15, y + 3, "*", theme.neutral);
            x += width + 2;
        }
        // Detected-but-unsupported runtimes are evidence, not selectable tabs.
        for (state.entries, 0..) |entry, i| {
            if (!entry.found or !entry.checked or entry.present or entry.reason == null) continue;
            y += 23;
            var buffer: [256]u8 = undefined;
            const hint = std.fmt.bufPrint(&buffer, "{s} unavailable", .{tabs.title(tabs.order[i + 2])}) catch unreachable;
            try r.textFit(font, rect.x + 12, y + 3, rect.w - 24, hint, theme.warm);
            y += 23;
            const reason = entry.reason.?;
            const detail = if (std.mem.eql(u8, reason, "PerlVersionUnsupported")) "Unsupported version" else if (std.mem.eql(u8, reason, "LuaImplementationUnsupported")) "Unsupported Lua build" else if (std.mem.eql(u8, reason, "RubyStaticRuntimeUnavailable")) "Needs standalone Ruby" else if (std.mem.eql(u8, reason, "RubyVersionUnsupported")) "Revision not supported" else if (std.mem.eql(u8, reason, "RubyArchitectureUnsupported")) "Unsupported Ruby CPU" else if (std.mem.eql(u8, reason, "RubyVersionMismatch") or std.mem.eql(u8, reason, "RubyBuildIdMismatch")) "Runtime image mismatch" else reason;
            try r.textFit(font, rect.x + 12, y + 3, rect.w - 24, detail, theme.weak);
        }
        self.content_y = y + 39;
        try r.rect(.{ .x = rect.x + 1, .y = y + 31, .w = rect.w - 2, .h = 1 }, theme.border);
    }
    fn collect(self: *Panel, stack: anytype) !void {
        const a = self.arena.allocator();
        var rows: std.ArrayList(Row) = .empty;
        self.message = "Segment anchor; frame pairing unproved";
        var count: usize = 0;
        for (stack.segments, 0..) |segment, segment_index| {
            if (rows.items.len >= 128) {
                self.message = "LanguageFrameLimit";
                break;
            }
            if (@hasField(@TypeOf(segment), "layout_source")) self.stack_basis = try a.dupe(u8, segment.layout_source);
            const anchor_name: ?[]const u8 = if (segment.anchor) |anchor| anchor.symbol else null;
            const segment_title: ?[]const u8 = if (@hasField(@TypeOf(segment), "title")) segment.title else anchor_name;
            try rows.append(a, .{ .name = if (segment_title) |name| try a.dupe(u8, name) else try std.fmt.allocPrint(a, "Segment {d}", .{segment_index}), .location = if (segment.anchor) |anchor| try std.fmt.allocPrint(a, "segment {d} / native #{d}", .{ segment_index, anchor.frame }) else "native anchor unproved", .reason = if (segment.reason) |value| try a.dupe(u8, value) else null, .segment = segment_index, .frame = null });
            for (segment.frames, 0..) |frame, frame_index| {
                if (count == 64 or rows.items.len == 128) {
                    self.message = "LanguageFrameLimit";
                    break;
                }
                if (@hasField(@TypeOf(frame), "native_binding")) self.message = "C argument links; other links partial";
                const label = if (@hasField(@TypeOf(frame), "qualified_name"))
                    if (frame.qualified_name) |text| try a.dupe(u8, text) else try std.fmt.allocPrint(a, "{s} [owner unproved]", .{frame.name})
                else
                    try a.dupe(u8, frame.name);
                const location = if (@hasField(@TypeOf(frame), "argument_count"))
                    if (frame.argument_count) |n| try std.fmt.allocPrint(a, "{s} / {d} args", .{ frame.kind, n }) else try std.fmt.allocPrint(a, "{s} / unevaluated", .{frame.kind})
                else if (frame.file) |file|
                    if (frame.line) |line| try std.fmt.allocPrint(a, "{s}:{d}", .{ std.fs.path.basename(file), line }) else try a.dupe(u8, std.fs.path.basename(file))
                else
                    "source position unproved";
                try rows.append(a, .{ .name = label, .location = location, .reason = if (frame.reason) |value| try a.dupe(u8, value) else null, .segment = segment_index, .frame = frame_index });
                count += 1;
                if (@hasField(@TypeOf(frame), "native_binding")) {
                    if (frame.native_binding) |anchor| {
                        if (rows.items.len < 128) {
                            rows.items[rows.items.len - 1].following = 1;
                            try rows.append(a, .{
                                .name = try std.fmt.allocPrint(a, "C: {s}", .{anchor.symbol}),
                                .location = try std.fmt.allocPrint(a, "arguments / native #{d}", .{anchor.frame}),
                                .reason = null,
                                .segment = segment_index,
                                .frame = null,
                            });
                        }
                    }
                }
                if (@hasField(@TypeOf(segment), "controls")) {
                    for (segment.controls) |control| {
                        if (control.frame == null or control.frame.? != frame_index or rows.items.len == 128) continue;
                        try rows.append(a, .{ .name = try a.dupe(u8, control.kind), .location = "control record; callback not evaluated", .reason = null, .segment = segment_index, .frame = null });
                    }
                }
            }
        }
        if (@hasField(@TypeOf(stack), "native_argument_diagnostics")) {
            for (stack.native_argument_diagnostics) |item| {
                if (rows.items.len == 128) break;
                try rows.append(a, .{ .name = try std.fmt.allocPrint(a, "native #{d}: no state argument", .{item.frame}), .location = try a.dupe(u8, item.reason), .reason = null, .segment = 0, .frame = null });
            }
        }
        self.rows = try rows.toOwnedSlice(a);
    }
    pub fn refresh(self: *Panel, session: *Session, tid: i32, frame: usize) void {
        self.syncEditor(session);
        const tab = session.language_tabs.selected;
        if (@intFromEnum(tab) < 2) return;
        const key = Key{ .session = session.id, .generation = session.target.snapshot().generation, .revision = session.language_tabs.revision, .metadata = session.metadata.revision, .tid = tid, .frame = frame, .tab = tab };
        if (self.key) |previous| if (std.meta.eql(previous, key)) return;
        if (self.key == null or self.key.?.generation != key.generation or self.key.?.tab != tab or self.key.?.tid != tid) self.scroll = 0;
        if (self.key == null or self.key.?.generation != key.generation or self.key.?.tab != tab or self.key.?.tid != tid or self.key.?.frame != frame) self.native_scroll = 0;
        if (self.key == null) self.revealed = null;
        self.key = key;
        self.stack_basis = null;
        self.bindings = null;
        self.expression_result = null;
        self.expression_reason = null;
        self.bindings_reason = "Select a logical frame for named locals";
        const selected = selectedKey(session);
        if (selected == null or self.bindings_key == null or !std.meta.eql(selected.?, self.bindings_key.?)) {
            self.binding_selected = null;
            self.binding_start = 0;
            self.expression_len = 0;
        }
        self.bindings_key = selected;
        _ = self.arena.reset(.retain_capacity);
        self.rows = &.{};
        self.message = "No stopped thread";
        if (session.target.snapshot().state != .stopped or tid == 0) return;
        const a = self.arena.allocator();
        switch (tab) {
            .python => self.collect(selection.cachedRead(.python, session, tid) catch |err| {
                self.message = @errorName(err);
                return;
            }) catch {
                self.message = "OutOfMemory";
            },
            .perl => self.collect(selection.cachedRead(.perl, session, tid) catch |err| {
                self.message = @errorName(err);
                return;
            }) catch {
                self.message = "OutOfMemory";
            },
            .lua => self.collect(selection.cachedRead(.lua, session, tid) catch |err| {
                self.message = @errorName(err);
                return;
            }) catch {
                self.message = "OutOfMemory";
            },
            .elisp => self.collect(selection.cachedRead(.elisp, session, tid) catch |err| {
                self.message = @errorName(err);
                return;
            }) catch {
                self.message = "OutOfMemory";
            },
            .ruby => self.collect(selection.cachedRead(.ruby, session, tid) catch |err| {
                self.message = @errorName(err);
                return;
            }) catch {
                self.message = "OutOfMemory";
            },
            .javascript => self.collect(selection.cachedRead(.javascript, session, tid) catch |err| {
                self.message = @errorName(err);
                return;
            }) catch {
                self.message = "OutOfMemory";
            },
            .go => self.collect(selection.cachedRead(.go, session, tid) catch |err| {
                self.message = @errorName(err);
                return;
            }) catch {
                self.message = "OutOfMemory";
            },
            else => unreachable,
        }
        if (selected) |row| {
            self.bindings = named.read(session, a, row.language, row.tid, row.segment, row.frame, self.binding_start, 32) catch |err| result: {
                self.bindings_reason = @errorName(err);
                break :result null;
            };
            if (self.expression_len != 0) self.expression_result = named.evaluate(session, a, row.language, row.tid, row.segment, row.frame, self.expression[0..self.expression_len]) catch |err| result: {
                self.expression_reason = @errorName(err);
                break :result null;
            };
        }
    }
    fn drawText(self: *Panel, r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, value: []const u8, color: gpu.Color) !void {
        try r.textFit(font, x, y, width, value, color);
        if (self.text_layout) |layout| {
            const left = @max(x, r.clip.x);
            const top = @max(y + 2, r.clip.y);
            const right = @min(x + @min(width, r.measure(font, value)), r.clip.x + r.clip.w);
            const bottom = @min(y + 18, r.clip.y + r.clip.h);
            if (bottom > top) layout.add(.{ .x = left, .y = top, .w = right - left, .h = bottom - top }, value);
        }
    }
    fn reportLayout(self: *Panel, session: *Session) void {
        const layout = self.text_layout orelse return;
        var hash = std.hash.Wyhash.init(session.target.snapshot().generation);
        hash.update(@tagName(session.language_tabs.selected));
        hash.update(self.layout_reason);
        for (0..layout.count) |i| {
            hash.update(std.mem.asBytes(&layout.boxes[i]));
            hash.update(layout.labels[i][0..layout.lens[i]]);
        }
        const signature = hash.final();
        if (self.layout_signature == signature) return;
        self.layout_signature = signature;
        var first: [6][]const u8 = @splat("");
        const overlaps = layout.overlaps(&first);
        std.debug.print("xodb: language layout tab={s} generation={d} boxes={d} selected_reason={s} overlaps={d} first=\"{s}\"/\"{s}\"\n", .{ @tagName(session.language_tabs.selected), session.target.snapshot().generation, layout.count, self.layout_reason, overlaps, first[0], first[1] });
    }
    fn wrapped(self: *Panel, r: *gpu.Renderer, font: *Font, rect: gpu.Rect, y: *f32, text: []const u8, color: gpu.Color) !void {
        var remaining = text;
        for (0..3) |_| {
            if (remaining.len == 0 or y.* + 20 > rect.y + rect.h - 8) break;
            var end = remaining.len;
            while (end > 0 and r.measure(font, remaining[0..end]) > rect.w - 24) {
                const space = std.mem.lastIndexOfScalar(u8, remaining[0..end], ' ') orelse break;
                end = space;
            }
            if (end == 0) end = remaining.len;
            try self.drawText(r, font, rect.x + 12, y.*, rect.w - 24, remaining[0..end], color);
            y.* += 23;
            remaining = std.mem.trimStart(u8, remaining[end..], " ");
        }
    }
    fn explanation(reason: []const u8) []const u8 {
        if (std.mem.eql(u8, reason, "LuaStateArgumentUnavailable")) return "No Lua state at this native frame";
        if (std.mem.eql(u8, reason, "JavaScriptNativeAnchorUnavailable")) return "No JavaScript anchor at this stop";
        if (std.mem.eql(u8, reason, "PerlInterpreterUnavailable")) return "No Perl interpreter at this native frame";
        return reason;
    }
    fn basisText(basis: []const u8) []const u8 {
        if (std.mem.eql(u8, basis, "postmortem-metadata")) return "postmortem metadata";
        if (std.mem.eql(u8, basis, "version-table")) return "version table";
        if (std.mem.eql(u8, basis, "version-table+dwarf-crosscheck")) return "version table + DWARF checks";
        return basis;
    }
    fn nativeMatches(tab: tabs.Tab, value: @import("../model/session.zig").ValueSummary) bool {
        const preview = value.visualization orelse return false;
        return switch (tab) {
            .python => preview.python != null,
            .perl => preview.perl != null,
            .lua => preview.lua != null,
            .javascript => preview.javascript != null,
            .ruby => preview.ruby != null,
            .elisp => preview.elisp != null,
            else => false,
        };
    }
    // Reuse Workspace's already bounded native previews; drawing performs no
    // new target reads and never treats a native variable as a logical local.
    fn nativeValues(self: *Panel, r: *gpu.Renderer, font: *Font, rect: gpu.Rect, tab: tabs.Tab, frame: usize, values: anytype, reason: ?[]const u8) !void {
        var y = rect.y + 8;
        try r.rect(.{ .x = rect.x + 1, .y = rect.y, .w = rect.w - 2, .h = 1 }, theme.border);
        var buffer: [256]u8 = undefined;
        self.native_header_hit = .{ .x = rect.x + 1, .y = rect.y, .w = rect.w - 2, .h = 32 };
        const title = try std.fmt.bufPrint(&buffer, "Native frame #{d} {s}", .{ frame, if (self.native_collapsed) "[+]" else "[-]" });
        try self.drawText(r, font, rect.x + 12, y, rect.w - 24, title, theme.neutral);
        y += 24;
        self.native_count = 0;
        for (values) |value| {
            if (nativeMatches(tab, value.value)) {
                self.native_count += 1;
            }
        }
        self.native_scroll = @min(self.native_scroll, self.native_count -| 1);
        const end = rect.y + rect.h - @as(f32, if (named.supported(tab)) 8 else 52);
        var index: usize = 0;
        for (values) |value| {
            if (self.native_collapsed or !nativeMatches(tab, value.value)) continue;
            const skip = index < self.native_scroll;
            index += 1;
            if (skip) continue;
            if (y + 42 > end) break;
            try self.drawText(r, font, rect.x + 12, y, rect.w - 24, value.name, theme.text);
            try self.drawText(r, font, rect.x + 12, y + 21, rect.w - 24, value.value.display, if (value.value.diagnostic != null) theme.warm else theme.weak);
            y += 45;
        }
        if (!self.native_collapsed and self.native_count == 0 and y + 23 <= end) try self.drawText(r, font, rect.x + 12, y, rect.w - 24, if (reason) |why| (if (std.mem.eql(u8, why, "BadMapping")) "No mapped native image" else why) else "No decoded native objects", theme.weak);
        if (!named.supported(tab) and end >= rect.y + 30) {
            try self.drawText(r, font, rect.x + 12, end + 3, rect.w - 24, "Variables by name", theme.weak);
            const hint = try std.fmt.bufPrint(&buffer, "Not yet for {s}", .{tabs.title(tab)});
            try self.drawText(r, font, rect.x + 12, end + 24, rect.w - 24, hint, theme.weak);
        }
    }
    pub fn body(self: *Panel, r: *gpu.Renderer, font: *Font, rect: gpu.Rect, session: *Session, tid: i32, frame: usize, native_values: anytype, native_reason: ?[]const u8) !void {
        if (self.text_layout == null and c.getenv("XODB_LANGUAGE_LAYOUT") != null) {
            self.text_layout = try std.heap.page_allocator.create(TextLayout);
            self.text_layout.?.* = .{};
        }
        if (self.text_layout) |layout| layout.count = 0;
        self.layout_reason = "none";
        defer self.reportLayout(session);
        self.row_hits = @splat(null);
        self.binding_hits = @splat(null);
        const logical = session.language_tabs.logical_selection;
        const logical_tid = if (logical) |selected| if (selected.generation == session.target.snapshot().generation and selected.language == session.language_tabs.selected) selected.tid else tid else tid;
        self.refresh(session, logical_tid, frame);
        const state = &session.language_tabs;
        const entry = &state.entries[@intFromEnum(state.selected) - 2];
        var y = self.content_y;
        try self.drawText(r, font, rect.x + 12, y, rect.w - 24, entry.version.slice(), theme.neutral);
        y += 23;
        try self.wrapped(r, font, rect, &y, basisText(self.stack_basis orelse entry.basis.slice()), theme.weak);
        if (entry.proof_generation == null or entry.proof_generation.? != session.target.snapshot().generation or entry.reason != null) {
            try self.drawText(r, font, rect.x + 12, y, rect.w - 24, entry.reason orelse "Runtime proof pending for this stop", theme.warm);
            y += 23;
        }
        try self.wrapped(r, font, rect, &y, explanation(self.message), theme.weak);
        y += 7;
        if (logical) |selected| {
            if (selected.native_anchor == null) try self.wrapped(r, font, rect, &y, "Selected logical row has no proved native anchor", theme.warm);
        }
        const has_named = named.supported(state.selected) or self.editor.open;
        const remaining = @max(0, rect.y + rect.h - 8 - y);
        var native_count: usize = 0;
        for (native_values) |value| if (nativeMatches(state.selected, value.value)) {
            native_count += 1;
        };
        const named_min: f32 = if (self.editor.open) 140 else if (logical != null) (if (state.selected == .javascript) @as(f32, if (self.expression_len != 0) 160 else 135) else 112) else 64;
        const layout = sectionLayout(remaining, has_named, native_count, self.native_policy, named_min);
        self.native_collapsed = layout.collapsed;
        const native_top = y + layout.stack;
        const binding_top = if (has_named) native_top + layout.native else rect.y + rect.h;
        self.native_y = native_top;
        self.binding_y = if (has_named) binding_top else std.math.inf(f32);
        if (logical) |current| {
            const key = SelectedKey{ .generation = current.generation, .tid = current.tid, .language = current.language, .segment = current.segment, .frame = current.frame };
            if (self.revealed == null or !std.meta.eql(self.revealed.?, key)) {
                const visible: usize = @intFromFloat(@max(1, @floor((native_top - y) / 48)));
                for (self.rows, 0..) |row, index| {
                    if (row.segment != current.segment or row.frame == null or row.frame.? != current.frame) continue;
                    self.scroll = revealRow(self.scroll, index, visible -| @min(row.following, visible -| 1));
                    break;
                }
                self.revealed = key;
            }
        } else self.revealed = null;
        var hit_count: usize = 0;
        for (self.rows, 0..) |row, index| {
            if (index < self.scroll) continue;
            if (y + 45 > native_top) break;
            const selected = if (logical) |current| current.language == state.selected and current.segment == row.segment and row.frame != null and current.frame == row.frame.? else false;
            const bounds = gpu.Rect{ .x = rect.x + 4, .y = y - 3, .w = rect.w - 8, .h = 47 };
            if (selected) try style.focus(r, bounds, 4, 1);
            if (row.frame) |frame_index| {
                self.row_hits[hit_count] = .{ .rect = bounds, .segment = row.segment, .frame = frame_index };
                hit_count += 1;
            }
            try self.drawText(r, font, rect.x + 12, y, rect.w - 24, row.name, if (row.frame == null) theme.neutral else theme.text);
            // A row has two lines. A selected diagnostic uses its detail
            // line instead of drawing into the next row's name.
            const reason = if (selected) row.reason else null;
            const detail = if (reason) |why| explanation(why) else row.location;
            try self.drawText(r, font, rect.x + 12, y + 21, rect.w - 24, detail, if (reason != null) theme.warm else theme.weak);
            if (reason) |why| self.layout_reason = why;
            y += 48;
        }
        try self.nativeValues(r, font, .{ .x = rect.x, .y = native_top, .w = rect.w, .h = binding_top - native_top }, state.selected, frame, native_values, native_reason);
        self.binding_visible = 0;
        if (!has_named) return;
        y = binding_top + 8;
        try r.rect(.{ .x = rect.x + 1, .y = binding_top, .w = rect.w - 2, .h = 1 }, theme.border);
        const heading_y = y;
        var more: usize = 0;
        y += 24;
        if (self.editor.open) {
            try self.editor.draw(r, font, .{ .x = rect.x + 12, .y = y, .w = rect.w - 24, .h = 25 });
            y += 29;
            try self.drawText(r, font, rect.x + 12, y, rect.w - 24, if (state.selected == .elisp) "Unavailable; Esc cancels" else if (self.editor.message.len > 0) self.editor.message else if (self.editor_watch) "Return adds watch; Esc cancels" else "Return reads this stop; Esc cancels", theme.warm);
            y += 24;
        } else if (self.expression_len != 0) {
            const value = if (self.expression_result) |result| if (result.rows.len != 0) result.rows[0].value.display else result.diagnostic orelse "No binding" else self.expression_reason orelse "Value unavailable";
            var buffer: [2048]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "E: {s} = {s}", .{ self.expression[0..self.expression_len], if (std.mem.eql(u8, value, "JavaScriptLexicalUnproved")) "unproved" else value }) catch "Value preview too long";
            try self.drawText(r, font, rect.x + 12, y, rect.w - 24, text, theme.text);
            y += 25;
        }
        if (!named.supported(state.selected)) {
            try self.drawText(r, font, rect.x + 12, heading_y, rect.w - 24, "ELISP EXPRESSION", theme.neutral);
            return;
        }
        if (self.bindings) |result| {
            if (result.diagnostic) |why| {
                try self.drawText(r, font, rect.x + 12, y, rect.w - 24, if (std.mem.eql(u8, why, "JavaScriptLexicalUnproved")) "Lexical visibility" else why, theme.warm);
                y += 23;
            }
            if (result.view_kind == .context_storage) {
                try self.drawText(r, font, rect.x + 12, y, rect.w - 24, "Unproved; stack hidden", theme.weak);
                y += 21;
            }
            var shown: usize = 0;
            for (result.rows, 0..) |row, index| {
                if (y + 42 > rect.y + rect.h - 8) break;
                const bounds = gpu.Rect{ .x = rect.x + 4, .y = y - 3, .w = rect.w - 8, .h = 43 };
                self.binding_hits[index] = .{ .rect = bounds, .index = result.start + index };
                if (self.binding_selected != null and self.binding_selected.? == result.start + index) try style.focus(r, bounds, 4, 1);
                var buffer: [2048]u8 = undefined;
                const text = if (row.name.len == 0) row.value.display else std.fmt.bufPrint(&buffer, "{s} = {s}", .{ row.name, row.value.display }) catch "Value preview too long";
                try self.drawText(r, font, rect.x + 12, y, rect.w - 24, text, theme.text);
                const matching_expression = if (self.expression_result) |expression| expression.rows.len == 1 and expression.rows[0].ordinal == row.ordinal and std.mem.eql(u8, expression.rows[0].name, row.name) else false;
                var context_label: [80]u8 = undefined;
                const context_detail = if (row.context_depth) |depth| try std.fmt.bufPrint(&context_label, "context #{d}{s}", .{ depth, if (row.context_parameter orelse false) " / parameter" else "" }) else null;
                const detail = row.name_diagnostic orelse row.value.diagnostic orelse context_detail orelse if (matching_expression) "expression result above" else if (row.hidden) "hidden compiler local" else if (row.immediate) "immediate integer in frame slot" else if (row.value.advisory) "bounded preview; object lifetime unproved" else @tagName(row.scope);
                try self.drawText(r, font, rect.x + 12, y + 20, rect.w - 24, detail, if (row.name_diagnostic != null or row.value.diagnostic != null) theme.warm else theme.weak);
                y += 44;
                shown += 1;
            }
            self.binding_visible = shown;
            more = result.total -| (result.start + shown);
        } else try self.drawText(r, font, rect.x + 12, y, rect.w - 24, self.bindings_reason, theme.weak);
        if (more != 0) {
            var buffer: [48]u8 = undefined;
            const hint = if (state.selected == .javascript) try std.fmt.bufPrint(&buffer, "▼ {d}", .{more}) else try std.fmt.bufPrint(&buffer, "▼ {d} more", .{more});
            const hint_width = r.measure(font, hint);
            try self.drawText(r, font, rect.x + 12, heading_y, rect.w - 32 - hint_width, if (state.selected == .javascript) "CONTEXT STORAGE" else "NAMED LOCALS", theme.neutral);
            try self.drawText(r, font, rect.x + rect.w - 12 - hint_width, heading_y, hint_width, hint, theme.weak);
        } else try self.drawText(r, font, rect.x + 12, heading_y, rect.w - 24, if (state.selected == .javascript) "CONTEXT STORAGE" else if (state.selected == .elisp) "FRAME BINDINGS" else "NAMED LOCALS  /  E name", theme.neutral);
    }
};

test "language sections retain stack context and collapse empty native values" {
    const empty = sectionLayout(310, true, 0, .auto, 112);
    try std.testing.expect(empty.stack >= 144 and empty.collapsed and empty.native == 32);
    const native = sectionLayout(310, true, 2, .auto, 64);
    try std.testing.expect(native.stack >= 144 and !native.collapsed and native.native >= 80);
    const selected = sectionLayout(310, true, 2, .auto, 112);
    try std.testing.expect(selected.collapsed and 310 - selected.stack - selected.native >= 112);
    const expanded = sectionLayout(310, true, 2, .expanded, 112);
    try std.testing.expect(!expanded.collapsed and expanded.stack >= 144);
    for ([_]f32{ 0, 60, 200, 310, 600 }) |height| {
        const layout = sectionLayout(height, true, 0, .auto, 112);
        try std.testing.expect(layout.stack >= 0 and layout.native >= 0 and layout.stack + layout.native <= height);
    }
    try std.testing.expectEqual(@as(usize, 4), revealRow(5, 5, 3));
    try std.testing.expectEqual(@as(usize, 0), revealRow(0, 2, 3));
    try std.testing.expectEqual(@as(usize, 0), revealRow(5, 0, 3));
}

pub fn watchError(err: anyerror) []const u8 {
    return switch (err) {
        error.SelectNamedBindingForWatch => "Select a named binding before W; native previews have no watch storage",
        error.LuaWatchBindingHasNoStorage => "This summary row has no named watch storage",
        error.LanguageWatchRuntimeUnsupported => "Select Lua, Python, Perl, Ruby or JavaScript context storage",
        error.JavaScriptLexicalUnproved => "JS name unproved; use W",
        error.SelectLanguageFrame => "Select a logical frame first",
        else => @errorName(err),
    };
}
