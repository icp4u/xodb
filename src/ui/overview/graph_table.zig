//! Precise peer of the galaxy. Rows retain model identities; ordering, filtering
//! and folding are presentation only and never change the source graph.
const std = @import("std");
const log = @import("../../log.zig");
const model = @import("galaxy_model.zig");
const camera = @import("galaxy_camera.zig");
const draw = @import("draw.zig");
const input = @import("../../platform/input.zig");
const Window = @import("../../platform/window.zig").Window;
const c = @import("../../c_ui.zig").api;
const Row = union(enum) { cluster: u16, node: u16, resource: u16, edge: u16 };
const Sort = enum { name, units, incoming, outgoing, target };
const capacity = model.max_stars + model.max_clusters + model.max_junctions + model.max_strands;
pub const hints = "V galaxy / Tab nodes-edges / click headings sort / R reverse / / filter / Space fold / Ctrl+C copy TSV";

pub const Table = struct {
    open: bool = false,
    edges: bool = false,
    editing: bool = false,
    filter: [128]u8 = undefined,
    filter_len: usize = 0,
    sort: Sort = .name,
    reverse: bool = false,
    folded: [model.max_clusters]u64 = undefined,
    folded_count: usize = 0,
    rows: [capacity]Row = undefined,
    count: usize = 0,
    top: usize = 0,
    visible: usize = 1,
    cursor: usize = 0,
    bounds: draw.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    message: []const u8 = "",
    message_buffer: [128]u8 = undefined,
    /// The cursor's model identity: it follows its row through re-sorting,
    /// folding, filtering and inventory refreshes instead of keeping an index.
    at: ?Ident = null,

    const Ident = struct { kind: std.meta.Tag(Row), id: u64, ordinal: u16 = 0 };
    fn ident(s: *const model.Scene, row: Row) Ident {
        return switch (row) {
            .node => |i| .{ .kind = .node, .id = s.stars[i].seed },
            .cluster => |i| .{ .kind = .cluster, .id = s.clusters[i].key },
            .resource => |i| .{ .kind = .resource, .id = s.junctions[i].identity },
            .edge => |i| .{ .kind = .edge, .id = s.strands[i].seed, .ordinal = i },
        };
    }
    fn isFolded(self: *const Table, key: u64) bool {
        return std.mem.indexOfScalar(u64, self.folded[0..self.folded_count], key) != null;
    }
    fn fold(self: *Table, key: u64) void {
        if (std.mem.indexOfScalar(u64, self.folded[0..self.folded_count], key)) |i| {
            self.folded_count -= 1;
            self.folded[i] = self.folded[self.folded_count];
        } else if (self.folded_count < self.folded.len) {
            self.folded[self.folded_count] = key;
            self.folded_count += 1;
        }
    }
    fn matches(self: *const Table, text: []const u8) bool {
        return self.filter_len == 0 or std.ascii.indexOfIgnoreCase(text, self.filter[0..self.filter_len]) != null;
    }
    /// Junction ends carry their identity, so edges to different shared
    /// resources can be told apart and matched with the resource rows.
    fn endpoint(s: *const model.Scene, vertex: u16, buffer: *[40]u8) []const u8 {
        if (vertex < s.star_count) return s.stars[vertex].label();
        if (vertex >= model.max_stars and vertex - model.max_stars < s.junction_count)
            return std.fmt.bufPrint(buffer, "resource #{d}", .{s.junctions[vertex - model.max_stars].identity}) catch "resource";
        return "?";
    }
    fn plainEnd(s: *const model.Scene, vertex: u16) []const u8 {
        return if (vertex < s.star_count) s.stars[vertex].label() else "shared resource";
    }
    fn label(s: *const model.Scene, row: Row, buffer: *[40]u8) []const u8 {
        return switch (row) {
            .node => |i| s.stars[i].label(),
            .cluster => |i| s.clusters[i].label(),
            .resource => "shared resource",
            .edge => |i| endpoint(s, s.strands[i].a, buffer),
        };
    }
    fn value(s: *const model.Scene, row: Row, sort: Sort) f64 {
        return switch (row) {
            .node => |i| switch (sort) {
                .name, .target => 0,
                .units => @floatFromInt(s.stars[i].units),
                .incoming => s.stars[i].incoming,
                .outgoing => s.stars[i].outgoing,
            },
            .resource => |i| switch (sort) {
                .name, .target => 0,
                .units => @floatFromInt(s.junctions[i].holders),
                .incoming => s.junctions[i].incoming,
                .outgoing => s.junctions[i].outgoing,
            },
            .cluster => |i| switch (sort) {
                .name, .target => 0,
                .units => @floatFromInt(s.clusters[i].units),
                .incoming, .outgoing => blk: {
                    var sum: f64 = 0;
                    for (s.stars[0..s.star_count]) |node| if (node.cluster == i) {
                        sum += if (sort == .incoming) node.incoming else node.outgoing;
                    };
                    break :blk sum;
                },
            },
            .edge => |i| switch (sort) {
                .name, .target => 0,
                .units => @floatFromInt(s.strands[i].weight),
                .incoming => s.strands[i].pulse.ba,
                .outgoing => s.strands[i].pulse.ab,
            },
        };
    }
    const Order = struct {
        table: *const Table,
        scene: *const model.Scene,
        fn less(self: Order, a: Row, b: Row) bool {
            var ba: [40]u8 = undefined;
            var bb: [40]u8 = undefined;
            var order = if (self.table.sort == .target and a == .edge and b == .edge) std.mem.order(u8, endpoint(self.scene, self.scene.strands[a.edge].b, &ba), endpoint(self.scene, self.scene.strands[b.edge].b, &bb)) else if (self.table.sort == .name) std.mem.order(u8, label(self.scene, a, &ba), label(self.scene, b, &bb)) else std.math.order(value(self.scene, a, self.table.sort), value(self.scene, b, self.table.sort));
            if (order == .eq) order = std.math.order(index(a), index(b));
            return order == (if (self.table.reverse) std.math.Order.gt else .lt);
        }
    };
    fn index(row: Row) u16 {
        return switch (row) {
            inline else => |i| i,
        };
    }
    fn selection(s: *const model.Scene, row: Row) ?camera.Selection {
        return switch (row) {
            .node => |i| .{ .node = s.stars[i].seed },
            .cluster => |i| .{ .cluster = s.clusters[i].key },
            .resource => null,
            .edge => |i| if (s.strands[i].a < s.star_count) .{ .node = s.stars[s.strands[i].a].seed } else if (s.strands[i].b < s.star_count) .{ .node = s.stars[s.strands[i].b].seed } else null,
        };
    }
    pub fn rebuild(self: *Table, s: *const model.Scene) void {
        self.count = 0;
        const order = Order{ .table = self, .scene = s };
        if (self.edges) {
            var buffer: [40]u8 = undefined;
            for (s.strands[0..s.strand_count], 0..) |edge, i| if (self.matches(endpoint(s, edge.a, &buffer)) or self.matches(endpoint(s, edge.b, &buffer))) {
                self.rows[self.count] = .{ .edge = @intCast(i) };
                self.count += 1;
            };
            std.mem.sort(Row, self.rows[0..self.count], order, Order.less);
        } else {
            var groups: [model.max_clusters]Row = undefined;
            for (groups[0..s.cluster_count], 0..) |*row, i| row.* = .{ .cluster = @intCast(i) };
            std.mem.sort(Row, groups[0..s.cluster_count], order, Order.less);
            for (groups[0..s.cluster_count]) |group| {
                const cl = s.clusters[group.cluster];
                const start = self.count;
                self.rows[self.count] = group;
                self.count += 1;
                for (s.stars[0..s.star_count], 0..) |node, i| if (node.cluster == group.cluster and (self.matches(cl.label()) or self.matches(node.label()))) {
                    self.rows[self.count] = .{ .node = @intCast(i) };
                    self.count += 1;
                };
                if (self.count == start + 1) self.count = start else if (self.isFolded(cl.key) and self.filter_len == 0) self.count = start + 1 else std.mem.sort(Row, self.rows[start + 1 .. self.count], order, Order.less);
            }
            for (0..s.junction_count) |i| if (self.matches("shared resource")) {
                self.rows[self.count] = .{ .resource = @intCast(i) };
                self.count += 1;
            };
        }
        if (self.at) |want| for (self.rows[0..self.count], 0..) |row, i| if (std.meta.eql(ident(s, row), want)) {
            self.cursor = i;
            break;
        };
        self.cursor = @min(self.cursor, self.count -| 1);
        self.top = @min(self.top, self.count -| self.visible);
    }
    pub fn toggle(self: *Table, s: *const model.Scene, cam: *camera.Camera) void {
        self.open = !self.open;
        self.editing = false;
        cam.stopTour();
        cam.held = @splat(0);
        cam.drag = null;
        cam.active = false;
        cam.target_shift = cam.shift;
        cam.target_zoom = cam.zoom;
        cam.target_angle = cam.angle;
        if (self.open) {
            if (cam.selection) |selected| if (selected == .node) for (s.stars[0..s.star_count]) |node| if (node.seed == selected.node and self.isFolded(s.clusters[node.cluster].key)) {
                self.fold(s.clusters[node.cluster].key);
                break;
            };
            self.rebuild(s);
            // Rows without a camera selection (resources) are not a match for "nothing selected".
            if (cam.selection != null) for (self.rows[0..self.count], 0..) |row, i| if (std.meta.eql(selection(s, row), cam.selection)) {
                self.cursor = i;
                self.top = i;
                self.at = ident(s, row);
                break;
            };
            self.top = @min(self.top, self.count -| self.visible);
        }
    }
    pub fn wheel(self: *Table, lines: i32) void {
        self.top = @intCast(std.math.clamp(@as(i64, @intCast(self.top)) + lines, 0, @as(i64, @intCast(self.count -| self.visible))));
    }
    fn columns(self: *const Table) []const Sort {
        return if (self.edges) &.{ .name, .target, .units, .incoming, .outgoing } else &.{ .name, .units, .incoming, .outgoing };
    }
    fn column(self: *const Table, ordinal: usize) struct { x: f32, w: f32 } {
        const stops: []const f32 = if (self.edges) &.{ 0, 0.25, 0.5, 0.6667, 0.8333, 1 } else &.{ 0, 0.4, 0.6, 0.8, 1 };
        return .{ .x = self.bounds.x + stops[ordinal] * self.bounds.w, .w = (stops[ordinal + 1] - stops[ordinal]) * self.bounds.w };
    }
    fn choose(self: *Table, s: *const model.Scene, cam: *camera.Camera) void {
        if (self.count == 0) return;
        self.at = ident(s, self.rows[self.cursor]);
        cam.selection = selection(s, self.rows[self.cursor]);
        cam.frame_pending = true;
        if (self.cursor < self.top) self.top = self.cursor;
        if (self.cursor >= self.top + self.visible) self.top = self.cursor + 1 - self.visible;
    }
    /// Called before domain/global bindings, including while a filter is empty.
    pub fn event(self: *Table, s: *const model.Scene, cam: *camera.Camera, e: input.Event) bool {
        if (self.open and self.editing) {
            if (e.kind == .press or e.kind == .repeat) {
                if (e.sym == 0xff1b or e.sym == 0xff0d) self.editing = false else if (e.sym == 0xff08) {
                    self.filter_len -|= 1;
                    while (self.filter_len > 0 and self.filter[self.filter_len] & 0xc0 == 0x80) self.filter_len -= 1;
                } else if (e.plain() and e.text().len <= self.filter.len - self.filter_len) {
                    @memcpy(self.filter[self.filter_len..][0..e.text().len], e.text());
                    self.filter_len += e.text().len;
                }
                self.top = 0;
                self.rebuild(s);
            }
            return true;
        }
        if (e.kind == .press and e.plain() and e.shortcut == 'v') {
            self.toggle(s, cam);
            return true;
        }
        if (!self.open) return false;
        if (e.kind == .press or e.kind == .button_press) self.message = "";
        if (e.kind == .button_press and e.code == 272 and draw.inside(self.bounds, e.x, e.y)) {
            const y = e.y - self.bounds.y;
            if (y >= 28 and y < 56) {
                var next: Sort = .name;
                for (self.columns(), 0..) |col, ordinal| {
                    const box = self.column(ordinal);
                    if (e.x >= box.x and e.x < box.x + box.w) {
                        next = col;
                        break;
                    }
                }
                if (self.sort == next) self.reverse = !self.reverse else {
                    self.sort = next;
                    self.reverse = false;
                }
            } else if (y >= 56) {
                self.cursor = @min(self.count -| 1, self.top + @as(usize, @intFromFloat((y - 56) / 24)));
                self.choose(s, cam);
                if (self.count > 0 and self.rows[self.cursor] == .cluster and e.x < self.bounds.x + 28) self.fold(s.clusters[self.rows[self.cursor].cluster].key);
            }
            self.rebuild(s);
            return true;
        }
        if ((e.kind != .press and e.kind != .repeat) or !e.plain()) return false;
        switch (e.shortcut) {
            '/' => self.editing = true,
            'r' => self.reverse = !self.reverse,
            0xff09 => {
                self.edges = !self.edges;
                if (!self.edges and self.sort == .target) self.sort = .name;
                self.top = 0;
            },
            0xff52 => {
                self.cursor -|= 1;
                self.choose(s, cam);
            },
            0xff54 => {
                self.cursor = @min(self.count -| 1, self.cursor + 1);
                self.choose(s, cam);
            },
            0xff50 => self.top = 0,
            0xff0d => self.choose(s, cam),
            ' ', 0xff51, 0xff53 => if (self.count > 0) {
                const row = self.rows[self.cursor];
                const cl = switch (row) {
                    .cluster => |i| i,
                    .node => |i| s.stars[i].cluster,
                    .edge, .resource => return true,
                };
                self.fold(s.clusters[cl].key);
                // Folding from a child keeps the keys on that group's row.
                self.at = .{ .kind = .cluster, .id = s.clusters[cl].key };
            },
            0xff1b => {
                self.filter_len = 0;
                self.top = 0;
            },
            else => return false,
        }
        self.rebuild(s);
        return true;
    }
    pub fn tsv(self: *const Table, a: std.mem.Allocator, s: *const model.Scene) ![]u8 {
        var text: std.Io.Writer.Allocating = .init(a);
        errdefer text.deinit();
        try text.writer.writeAll("type\tid\tlabel\tto\tdirected\tunits\tincoming\toutgoing\tsource_id\ttarget_id\n");
        for (self.rows[0..self.count]) |row| {
            const id: u64 = switch (row) {
                .node => |i| s.stars[i].seed,
                .cluster => |i| s.clusters[i].key,
                .resource => |i| s.junctions[i].identity,
                .edge => |i| s.strands[i].seed,
            };
            try text.writer.print("{s}\t{s}:{d}", .{ @tagName(row), @tagName(row), id });
            if (row == .edge) try text.writer.print(":{d}", .{row.edge});
            try text.writer.writeByte('\t');
            // Edge ends keep the short text here: their identities are the
            // source_id/target_id columns, and the clipboard is small.
            var buffer: [40]u8 = undefined;
            for (if (row == .edge) plainEnd(s, s.strands[row.edge].a) else label(s, row, &buffer)) |ch| try text.writer.writeByte(if (ch == '\t' or ch == '\n' or ch == '\r') ' ' else ch);
            try text.writer.writeByte('\t');
            if (row == .edge) for (plainEnd(s, s.strands[row.edge].b)) |ch| try text.writer.writeByte(if (ch == '\t' or ch == '\n' or ch == '\r') ' ' else ch);
            try text.writer.print("\t{d}\t{d:.0}\t{d:.3}\t{d:.3}", .{ @intFromBool(row == .edge and s.strands[row.edge].directed), value(s, row, .units), value(s, row, .incoming), value(s, row, .outgoing) });
            if (row == .edge) {
                for ([2]u16{ s.strands[row.edge].a, s.strands[row.edge].b }) |vertex| {
                    if (vertex < s.star_count) try text.writer.print("\tnode:{d}", .{s.stars[vertex].seed}) else if (vertex >= model.max_stars and vertex - model.max_stars < s.junction_count) try text.writer.print("\tresource:{d}", .{s.junctions[vertex - model.max_stars].identity}) else try text.writer.writeByte('\t');
                }
            } else try text.writer.writeAll("\t\t");
            try text.writer.writeByte('\n');
        }
        return text.toOwnedSlice();
    }
    pub fn clipboard(self: *Table, w: *Window, s: *const model.Scene, e: input.Event) bool {
        if (!self.open or self.editing or e.kind != .press or !e.mods.ctrl or e.shortcut != 'c') return false;
        const text = self.tsv(std.heap.c_allocator, s) catch {
            self.message = "Copy failed";
            return true;
        };
        defer std.heap.c_allocator.free(text);
        // The platform clipboard is bounded; say so rather than "unavailable".
        self.message = if (w.clipCopy(false, text)) "Copied visible model rows as TSV" else std.fmt.bufPrint(&self.message_buffer, "Not copied: {d} bytes of TSV; clipboard unavailable or over its size limit (filter or fold to copy less)", .{text.len}) catch "Clipboard unavailable";
        return true;
    }
    pub fn render(self: *Table, s: *const model.Scene, cam: *const camera.Camera, ctx: draw.Ctx, bounds: draw.Rect) !model.Counts {
        self.bounds = bounds;
        self.visible = @intFromFloat(@max(1, (bounds.h - 80) / 24));
        self.rebuild(s);
        var buf: [384]u8 = undefined;
        try ctx.textFit(bounds.x + 8, bounds.y + 2, bounds.w - 16, try std.fmt.bufPrint(&buf, "{s} / {d} rows / Filter{s}: {s}", .{ if (self.edges) "EDGES (source -> target)" else "NODES / CLUSTERS", self.count, if (self.editing) " [typing]" else "", self.filter[0..self.filter_len] }), ctx.p.accent);
        for (self.columns(), 0..) |col, ordinal| {
            const box = self.column(ordinal);
            const name: []const u8 = switch (col) {
                .name => if (self.edges) "Source" else "Name",
                .target => "Target",
                .units => "Units / weight",
                .incoming => "In / reverse",
                .outgoing => "Out / forward",
            };
            try ctx.textFit(box.x + 8, bounds.y + 30, box.w - 16, try std.fmt.bufPrint(&buf, "{s}{s}", .{ name, if (self.sort == col) (if (self.reverse) " v" else " ^") else "" }), ctx.p.dim);
        }
        for (self.rows[self.top..self.count][0..@min(self.visible, self.count - self.top)], self.top..) |row, ordinal| {
            const y = bounds.y + 56 + @as(f32, @floatFromInt(ordinal - self.top)) * 24;
            const selected = cam.selection != null and std.meta.eql(selection(s, row), cam.selection);
            // The cursor is drawn for every row type; resource and edge rows
            // have no camera selection of their own to show where the keys act.
            if (selected or ordinal == self.cursor) try ctx.r.rect(.{ .x = bounds.x, .y = y, .w = bounds.w, .h = 24 }, draw.fade(ctx.p.accent, if (selected) 0.18 else 0.09));
            var name_buffer: [40]u8 = undefined;
            const marker: []const u8 = if (row == .cluster) (if (self.isFolded(s.clusters[row.cluster].key)) "+ " else "- ") else "  ";
            for (self.columns(), 0..) |col, ordinal_col| {
                const box = self.column(ordinal_col);
                const text = switch (col) {
                    .name => if (row == .resource) try std.fmt.bufPrint(&buf, "resource #{d}", .{s.junctions[row.resource].identity}) else try std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ marker, label(s, row, &name_buffer), if (row == .node and s.stars[row.node].unavailable) " [unavailable]" else if (row == .node and s.stars[row.node].stale) " [stale]" else "" }),
                    .target => try std.fmt.bufPrint(&buf, "{s} {s}", .{ if (s.strands[row.edge].directed) "->" else "--", endpoint(s, s.strands[row.edge].b, &name_buffer) }),
                    else => try std.fmt.bufPrint(&buf, "{d:.2}", .{value(s, row, col)}),
                };
                try ctx.textFit(box.x + 8, y + 2, box.w - 16, text, if (selected) ctx.p.accent else ctx.p.text);
            }
            if (c.getenv("XODB_OVERVIEW_AUDIT") != null) log.info(.overview, "xodb: graph-table-row type={s} index={d} id={d} selected={d} x={d:.1} y={d:.1}\n", .{ @tagName(row), index(row), if (selection(s, row)) |sel| switch (sel) {
                inline else => |id| id,
            } else 0, @intFromBool(selected), bounds.x + 50, y + 12 });
        }
        try ctx.textFit(bounds.x + 8, bounds.y + bounds.h - 22, bounds.w - 16, if (self.message.len > 0) self.message else hints, ctx.p.dim);
        if (c.getenv("XODB_OVERVIEW_AUDIT") != null) log.info(.overview, "xodb: graph-table rows={d} cursor={d} edges={d} filter={d} folded={d} sort={s} reverse={d}\n", .{ self.count, self.cursor, @intFromBool(self.edges), self.filter_len, self.folded_count, @tagName(self.sort), @intFromBool(self.reverse) });
        return .{ .stars = s.star_count, .clusters = s.cluster_count, .strands = s.strand_count };
    }
};

test "table sorts filters folds and preserves shared identities" {
    const s = try std.testing.allocator.create(model.Scene);
    defer std.testing.allocator.destroy(s);
    s.* = .{};
    _ = s.addStar(.{ .seed = 9, .key = 7, .units = 2 }, "beta");
    _ = s.addStar(.{ .seed = 8, .key = 7, .units = 8 }, "alpha");
    s.group(struct {
        pub fn cluster(_: @This(), _: u32, _: []u8) []const u8 {
            return "group";
        }
    }{});
    var t: Table = .{};
    var cam: camera.Camera = .{ .selection = .{ .node = 9 } };
    t.toggle(s, &cam);
    try std.testing.expectEqual(@as(usize, 2), t.cursor);
    try std.testing.expectEqual(@as(u16, 1), t.rows[1].node);
    _ = t.event(s, &cam, .{ .kind = .press, .shortcut = 0xff52 });
    try std.testing.expectEqual(@as(u64, 8), cam.selection.?.node);
    try std.testing.expect(cam.frame_pending);
    // The cursor is an identity: reversing the order moves it with its row, so
    // the next arrow key steps from the highlighted row, not from an old index.
    try std.testing.expectEqual(@as(usize, 1), t.cursor);
    _ = t.event(s, &cam, .{ .kind = .press, .shortcut = 'r' });
    try std.testing.expectEqual(@as(usize, 2), t.cursor);
    try std.testing.expectEqual(@as(u16, 1), t.rows[t.cursor].node);
    _ = t.event(s, &cam, .{ .kind = .press, .shortcut = 0xff52 });
    try std.testing.expectEqual(@as(u64, 9), cam.selection.?.node);
    _ = t.event(s, &cam, .{ .kind = .press, .shortcut = 'r' });
    try std.testing.expectEqual(@as(usize, 2), t.cursor);
    _ = t.event(s, &cam, .{ .kind = .press, .shortcut = 0xff52 });
    try std.testing.expectEqual(@as(u64, 8), cam.selection.?.node);
    t.fold(7);
    t.rebuild(s);
    try std.testing.expectEqual(@as(usize, 1), t.count);
    @memcpy(t.filter[0..5], "alpha");
    t.filter_len = 5;
    t.rebuild(s);
    try std.testing.expectEqual(@as(usize, 2), t.count);
    t.editing = true;
    try std.testing.expect(t.event(s, &cam, .{ .kind = .press, .shortcut = 'q', .text_bytes = .{'q'} ++ .{0} ** 15, .text_len = 1 }));
    try std.testing.expectEqualStrings("alphaq", t.filter[0..t.filter_len]);
    t.filter_len = 5;
    t.rebuild(s);
    const text = try t.tsv(std.testing.allocator, s);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "type\tid\tlabel"));
    try std.testing.expect(std.mem.indexOf(u8, text, "node:8\talpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "beta") == null);
}
