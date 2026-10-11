//! Bounded logical-frame rows and source preview prepared by the session owner.
const std = @import("std");
const model = @import("../frames/model.zig");
const c = model.c;
const State = @import("../frames/state.zig").State;
pub const Request = struct {
    serial: u64 = 0,
    source: usize = 0,
    selected: usize = 0,
    scroll: usize = 0,
    visible: usize = 1,
    preview_lines: usize = 1,
    preview: bool = false,
};
pub const Row = struct { index: usize, label: []const u8 };
pub const Line = struct { number: usize, text: []const u8, selected: bool };
pub const View = struct {
    requested: Request = .{},
    request: Request = .{},
    source_count: usize = 0,
    function_count: usize = 0,
    busy: bool = false,
    diagnostic: ?[]const u8 = null,
    title: []const u8 = "No logical evidence imported",
    summary: []const u8 = "",
    evidence: []const u8 = "",
    incomplete: bool = false,
    logical: bool = false,
    rows: []const Row = &.{},
    name: []const u8 = "",
    location: []const u8 = "",
    preview_status: []const u8 = "Enter opens the recorded source location",
    preview: []const Line = &.{},
};
comptime {
    @import("debugger_view.zig").requireImmutable(View);
}
pub const Action = struct { serial: u64, source: usize, kind: enum { cancel, next_thread } };
pub fn apply(state: *State, action: Action) !void {
    if (action.serial != state.serial) return error.StaleFrameView;
    if (action.kind == .cancel) {
        state.cancel();
        return;
    }
    if (action.source >= state.count) return error.FrameSourceInvalid;
    const source = state.sources[action.source].?;
    if (source.jit_owner != null) return error.FrameSourceNotLogical;
    const next: ?u32 = if (source.metadata.selected_thread) |thread|
        (if (thread + 1 < source.doc().thread_count) thread + 1 else null)
    else
        (if (source.doc().thread_count > 0) @as(u32, 0) else null);
    try state.select(action.source, next);
}
pub const Capture = struct {
    source: usize = 0,
    selected: usize = 0,
    scroll: usize = 0,
    serial: u64 = 0,
    preview: c.struct_xfb_input = std.mem.zeroes(c.struct_xfb_input),
    preview_line: usize = 0,
    preview_status: []const u8 = "Enter opens the recorded source location",
    loaded: bool = false,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: ?View = null,
    pub fn deinit(self: *Capture) void {
        c.xfb_input_free(&self.preview);
        self.arena.deinit();
    }
    pub fn changed(self: *const Capture, state: *const State) bool {
        const old = self.value orelse return false;
        return old.request.serial != state.serial or old.busy != state.busy();
    }
    pub fn refresh(self: *Capture, state: *State, wanted: ?Request) void {
        var request = wanted orelse {
            self.clearPreview();
            self.loaded = false;
            _ = self.arena.reset(.free_all);
            self.value = null;
            return;
        };
        request.source = @min(request.source, model.max_sources - 1);
        request.selected = @min(request.selected, std.math.maxInt(u32));
        request.scroll = @min(request.scroll, std.math.maxInt(u32));
        request.visible = @min(64, @max(1, request.visible));
        request.preview_lines = @min(64, @max(1, request.preview_lines));
        if (request.serial != state.serial) {
            request.serial = state.serial;
            request.selected = 0;
            request.scroll = 0;
            request.preview = false;
        }
        if (self.value) |*old| if (std.meta.eql(old.request, request) and !self.changed(state)) {
            old.requested = wanted.?;
            return;
        };
        if (!request.preview or self.serial != request.serial or self.source != request.source or self.selected != request.selected) {
            self.clearPreview();
            self.loaded = false;
        }
        self.serial = request.serial;
        self.source = request.source;
        self.selected = request.selected;
        self.scroll = request.scroll;
        _ = self.arena.reset(.retain_capacity);
        self.value = .{ .requested = wanted.?, .request = request, .source_count = state.count, .busy = state.busy() };
        self.project(state) catch |err| {
            self.value.?.diagnostic = @errorName(err);
        };
    }
    fn print(self: *Capture, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), format, args);
    }
    fn project(self: *Capture, state: *State) !void {
        const a = self.arena.allocator();
        var view = &self.value.?;
        if (state.attachment.failure) |err| {
            view.diagnostic = try self.print("Archive attachments {s}: {s} (original bytes retained)", .{ @tagName(state.attachment.state), @errorName(err) });
        } else if (state.failure) |err| view.diagnostic = try self.print("Frame job: {s}", .{@errorName(err)});
        const source = self.current(state) orelse {
            view.title = if (state.busy()) "Importing frame evidence..." else "No logical evidence imported";
            return;
        };
        view.request.source = self.source;
        if (source.jit_owner) |jit| {
            view.title = try self.print("JIT source {d}/{d}: {s} / {d} versions / {d} diagnostics", .{ self.source + 1, state.count, @tagName(source.kind), jit.version_count, jit.diag_count });
            view.summary = "L returns to native profiles; I opens sampled stacks with JIT labels";
            return;
        }
        view.logical = true;
        const doc = source.doc();
        view.function_count = doc.function_count;
        const language = try model.ownBounded(a, doc.header.language, 512);
        const method = try model.ownBounded(a, doc.header.method, 512);
        const unit = try model.ownBounded(a, doc.header.weight_unit, 512);
        view.title = try self.print("Source {d}/{d}: {s} / {s} / read {s}", .{ self.source + 1, state.count, language orelse "unknown", method orelse "unspecified", std.mem.span(c.xlf_stability_name(source.input.stability)) });
        if (source.aggregate) |agg| {
            view.summary = try self.print("Weight {s} {s}  /  partial {s}  /  unknown leaf {s}  /  marker {s}", .{ model.preview(agg.total, 512), unit orelse "count", model.preview(agg.partial, 512), model.preview(agg.unknown_leaf, 512), model.preview(agg.marker, 512) });
            view.evidence = try self.print("{d} stacks / {d} partial / incomplete {} / thread {?d} / {s}", .{ agg.stacks, agg.partial_stacks, agg.input_incomplete, agg.thread, if (state.busy()) "worker pending" else model.algorithm });
            view.incomplete = agg.input_incomplete;
        } else {
            view.summary = "Saved analysis is stale; T explicitly recomputes from retained evidence";
            view.incomplete = true;
        }
        const selected = self.function(source);
        view.request.selected = self.selected;
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + view.request.visible) self.scroll = self.selected - view.request.visible + 1;
        self.scroll = @min(self.scroll, doc.function_count);
        view.request.scroll = self.scroll;
        const end = @min(doc.function_count, self.scroll + view.request.visible);
        const rows = try a.alloc(Row, end - self.scroll);
        for (rows, self.scroll..) |*row, ordinal| {
            const index: usize = if (source.aggregate) |agg| agg.order[ordinal] else ordinal;
            const f = try model.ownBounded(a, doc.functions[index], 512);
            const inclusive = if (source.aggregate) |agg| model.preview(agg.inclusive[index], 512) else "?";
            const weight = if (source.aggregate) |agg| model.preview(agg.self[index], 512) else "?";
            row.* = .{ .index = ordinal, .label = try self.print("{s} / {s}   {s}", .{ inclusive, weight, f.qualified orelse f.name orelse "unknown" }) };
        }
        view.rows = rows;
        if (selected) |index| {
            const f = try model.ownBounded(a, doc.functions[index], 512);
            view.name = f.qualified orelse f.name orelse "unknown";
            if (f.code != c.XLF_NONE) {
                const code = try model.ownBounded(a, doc.codes[f.code], 512);
                view.location = try self.print("{s}:{d}", .{ if (code.path) |path| std.fs.path.basename(path) else "source unavailable", f.first_line });
            }
            if (view.request.preview and !self.loaded) {
                self.load(state);
                self.loaded = true;
            }
            view.preview_status = self.preview_status;
            if (self.preview.bytes != null) {
                var lines = std.mem.splitScalar(u8, self.preview.bytes[0..self.preview.size], '\n');
                var number: usize = 1;
                var preview: std.ArrayList(Line) = .empty;
                while (lines.next()) |line| : (number += 1) {
                    if (number + 3 < self.preview_line) continue;
                    if (preview.items.len == view.request.preview_lines) break;
                    try preview.append(a, .{ .number = number, .text = try a.dupe(u8, model.preview(line, 512)), .selected = number == self.preview_line });
                }
                view.preview = preview.items;
            }
        }
    }
    fn current(self: *Capture, state: *State) ?*model.Source {
        if (state.count == 0) return null;
        self.source = @min(self.source, state.count - 1);
        return state.sources[self.source];
    }
    fn function(self: *Capture, source: *model.Source) ?u32 {
        if (source.jit_owner != null) return null;
        const doc = source.doc();
        if (doc.function_count == 0) return null;
        self.selected = @min(self.selected, doc.function_count - 1);
        return if (source.aggregate) |agg| agg.order[self.selected] else @intCast(self.selected);
    }
    fn load(self: *Capture, state: *State) void {
        c.xfb_input_free(&self.preview);
        const source = self.current(state) orelse return;
        const index = self.function(source) orelse return;
        const doc = source.doc();
        const f = doc.functions[index];
        if (f.code == c.XLF_NONE) {
            self.preview_status = "No source file recorded";
            return;
        }
        const code = doc.codes[f.code];
        if (code.path.ptr == null) {
            self.preview_status = "No source path recorded";
            return;
        }
        const path = code.path.ptr[0..code.path.len];
        if (path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) {
            self.preview_status = "Source path cannot be opened";
            return;
        }
        const name = std.heap.page_allocator.dupeZ(u8, path) catch {
            self.preview_status = "Source preview memory limit";
            return;
        };
        defer std.heap.page_allocator.free(name);
        model.bundleCheck(c.xfb_read(name, 1024 * 1024, null, &self.preview)) catch |err| {
            self.preview_status = @errorName(err);
            return;
        };
        if (!std.unicode.utf8ValidateSlice(self.preview.bytes[0..self.preview.size])) {
            c.xfb_input_free(&self.preview);
            self.preview_status = "Source is not UTF-8";
            return;
        }
        self.preview_line = if (f.first_line > 0) @intCast(f.first_line) else 1;
        self.preview_status = if (code.sha256.ptr == null) "Source identity was not recorded" else if (std.mem.eql(u8, code.sha256.ptr[0..code.sha256.len], self.preview.sha256[0..64])) "Source matches recorded SHA-256" else "Source has changed since collection";
    }
    fn clearPreview(self: *Capture) void {
        c.xfb_input_free(&self.preview);
        self.preview_status = "Enter opens the recorded source location";
    }
};

test "logical frame publication survives source storage retirement" {
    const boundary = @import("remote_owner.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const a = arena.allocator();
    const title = try a.dupe(u8, "Source 1/1: fixture");
    const rows = try a.alloc(Row, 1);
    rows[0] = .{ .index = 2, .label = try a.dupe(u8, "3 / 2   hot") };
    const lines = try a.alloc(Line, 1);
    lines[0] = .{ .number = 17, .text = try a.dupe(u8, "return value"), .selected = true };
    const publication = try boundary.Publication.create(std.testing.allocator, .{
        .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 42, .start_ticks = 1, .image_epoch = 0, .generation = 1 },
        .revision = 1,
        .taken_ns = 1,
        .status = .ready,
        .logical_frames = .{ .request = .{ .serial = 3, .selected = 2 }, .source_count = 1, .function_count = 3, .logical = true, .title = title, .rows = rows, .preview = lines },
    });
    defer publication.destroy();
    @memset(title, 'x');
    rows[0].index = 0;
    lines[0].number = 0;
    arena.deinit();
    const view = publication.value.logical_frames.?;
    try std.testing.expectEqualStrings("Source 1/1: fixture", view.title);
    try std.testing.expectEqualStrings("3 / 2   hot", view.rows[0].label);
    try std.testing.expectEqual(@as(usize, 2), view.rows[0].index);
    try std.testing.expectEqualStrings("return value", view.preview[0].text);
    try std.testing.expectEqual(@as(usize, 17), view.preview[0].number);
}

test "logical frame commands refuse a replaced worker and bound empty projections" {
    var state: State = .{ .serial = 2 };
    defer state.deinit();
    try std.testing.expectError(error.StaleFrameView, apply(&state, .{ .serial = 1, .source = 0, .kind = .cancel }));
    try std.testing.expectError(error.FrameSourceInvalid, apply(&state, .{ .serial = 2, .source = 0, .kind = .next_thread }));
    var capture: Capture = .{};
    defer capture.deinit();
    capture.refresh(&state, .{ .serial = 1, .selected = 99, .scroll = 88, .preview = true, .visible = std.math.maxInt(usize), .preview_lines = std.math.maxInt(usize) });
    try std.testing.expectEqual(@as(usize, 0), capture.value.?.request.selected);
    try std.testing.expectEqual(@as(usize, 64), capture.value.?.request.visible);
    try std.testing.expectEqual(@as(usize, 64), capture.value.?.request.preview_lines);
    try std.testing.expect(!capture.value.?.request.preview);
    try std.testing.expectEqualStrings("No logical evidence imported", capture.value.?.title);
}
