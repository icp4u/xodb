//! Descriptor activity drawn with the overview's existing theme and renderer.
const std = @import("std");
const c = @import("../../c.zig").api;
const draw = @import("draw.zig");
const vw = @import("view.zig");
const m = @import("model.zig");
const fm = @import("files_model.zig");
const Ctx = draw.Ctx;
const Rect = draw.Rect;
const fade = draw.fade;
const titles = [_][]const u8{ "Files", "Processes", "Leak watch", "Deleted", "Exact events" };

fn button(v: *vw.View, ctx: Ctx, rect: Rect, label: []const u8, selected: bool, action: vw.View.Action) !void {
    try ctx.r.shape(rect, if (selected) ctx.p.selection else ctx.p.raised, .{ .radii = @splat(5) });
    try ctx.textFit(rect.x + 10, rect.y + 5, rect.w - 20, label, if (selected) ctx.p.accent else ctx.p.dim);
    v.hit(rect, action);
}
fn tile(ctx: Ctx, rect: Rect, label: []const u8, value: []const u8, color: draw.Color) !void {
    try ctx.panel(rect);
    try ctx.textFit(rect.x + 12, rect.y + 8, rect.w - 24, label, ctx.p.dim);
    try ctx.textFit(rect.x + 12, rect.y + 34, rect.w - 24, value, color);
}
pub fn render(v: *vw.View, ctx: Ctx, rect: Rect, now: u64) !void {
    const f = &v.files;
    try f.rebuild(v.gpa, v.redact);
    var buf: [256]u8 = undefined;
    try ctx.text(rect.x + 8, rect.y + 2, "Files & IO", ctx.p.text);
    const scope = if (f.filter) |id| std.fmt.bufPrint(&buf, "pid {d} · start {d}", .{ id.pid, id.start }) catch "" else if (f.file_filter != null) "Holders of selected inode" else "Shared system cache";
    try ctx.textFit(rect.x + 160, rect.y + 2, rect.w - 170, scope, ctx.p.dim);
    const tab_w = @min(154, (rect.w - 110) / 5);
    for (titles, 0..) |title, i| {
        const mode: fm.Mode = @enumFromInt(i);
        try button(v, ctx, .{ .x = rect.x + @as(f32, @floatFromInt(i)) * tab_w, .y = rect.y + 32, .w = tab_w - 6, .h = 30 }, title, f.mode == mode, .{ .files_mode = mode });
    }
    try button(v, ctx, .{ .x = rect.x + rect.w - 98, .y = rect.y + 32, .w = 98, .h = 30 }, if (f.event_authorized or f.exact_active) "Stop / E" else "All", false, if (f.event_authorized or f.exact_active) .stop_events else .files_all);
    const snapshot = f.snapshot orelse {
        try ctx.hatchLight(.{ .x = rect.x, .y = rect.y + 88, .w = rect.w, .h = 100 });
        try ctx.textFit(rect.x + 16, rect.y + 106, rect.w - 32, if (v.action_hook == null) "Descriptor data is unavailable in this system replay" else if (v.paused) "Paused before the first descriptor sample" else "Waiting for the shared descriptor collector…", ctx.p.dim);
        return;
    };
    const s: *const c.struct_xrt_fd_snapshot = snapshot;
    const status = std.fmt.bufPrint(&buf, "System totals · {d} ms · {d} hidden · {d} stale · {d} unscanned · {d} capped · scan {d:.1} ms CPU", .{
        (now -| s.taken_ns) / 1_000_000,                    s.hidden, s.stale, s.unscanned, s.dropped_processes +| s.dropped_fds,
        @as(f64, @floatFromInt(s.scan_cpu_ns)) / 1_000_000,
    }) catch "";
    try ctx.textFit(rect.x + 8, rect.y + 72, rect.w - 16, status, if (s.hidden +| s.stale +| s.unscanned +| s.dropped_fds > 0) ctx.p.warn else ctx.p.dim);
    const card_w = (rect.w - 24) / 4;
    // System-wide totals (see the status line); short enough to fit a quarter width.
    const cards = [_][]const u8{ "Visible fds", "Read/s · partial", "Write/s · partial", "FD changes/s" };
    var known_io = false;
    var known_churn = false;
    for (s.processes[0..s.process_count]) |p| {
        known_io = known_io or (p.interval_ns > 0 and p.flags & c.XRT_FDP_NO_IO == 0);
        known_churn = known_churn or (p.interval_ns > 0 and p.flags & c.XRT_FDP_STALE == 0);
    }
    for (cards, 0..) |label, i| {
        const value = switch (i) {
            0 => std.fmt.bufPrint(&buf, "{d}", .{s.fd_count}) catch "",
            1 => if (known_io) m.rate(&buf, s.read_rate) else "not measured",
            2 => if (known_io) m.rate(&buf, s.write_rate) else "not measured",
            else => if (known_churn) std.fmt.bufPrint(&buf, "{d:.1}", .{s.churn_rate}) catch "" else "not measured",
        };
        const card = Rect{ .x = rect.x + @as(f32, @floatFromInt(i)) * (card_w + 8), .y = rect.y + 100, .w = card_w, .h = 70 };
        // accent2 is the palette's write series; an unmeasured value uses the hatch text colour.
        const measured = if (i == 1 or i == 2) known_io else if (i == 3) known_churn else true;
        try tile(ctx, card, label, value, if (!measured) ctx.p.hatch else if (i == 2) ctx.p.accent2 else ctx.p.accent);
        if ((i == 1 or i == 2) and !known_io) v.hover(card, "No comparable readable /proc IO sample yet", .{});
        if (i == 3 and !known_churn) v.hover(card, "No comparable fresh descriptor sample yet", .{});
    }
    try heatmap(ctx, .{ .x = rect.x, .y = rect.y + 184, .w = rect.w, .h = 88 }, s, v.redact);
    const table = Rect{ .x = rect.x, .y = rect.y + 280, .w = rect.w, .h = @max(90, rect.h - (if (f.mode == .events) @as(f32, 338) else 314)) };
    try ctx.panel(table);
    const proc = f.mode == .processes or f.mode == .leaks;
    try ctx.text(table.x + 12, table.y + 8, "PID / FD", ctx.p.dim);
    try ctx.textFit(table.x + 170, table.y + 8, table.w - 470, if (f.searching or f.query_len > 0) std.fmt.bufPrint(&buf, "/ {s}_", .{f.text()}) catch "" else if (proc) "Process · fd history" else if (f.mode == .events) "FD-number history · spans reuse" else "Path · [stale] = cached metadata", ctx.p.dim);
    try ctx.textRight(table.x + table.w - 150, table.y + 8, if (f.mode == .events) "Read bytes" else if (f.mode == .deleted) "File size" else if (proc) "Churn /s" else "Progress /s", ctx.p.dim);
    try ctx.textRight(table.x + table.w - 12, table.y + 8, if (f.mode == .events) "Write bytes" else if (f.mode == .deleted) "Disk bytes" else if (proc) "FDs" else "Offset", ctx.p.dim);
    f.visible = @max(1, @as(usize, @intFromFloat(@max(0, table.h - 42) / 34)));
    f.top = @min(f.top, f.rows.items.len -| f.visible);
    for (f.top..@min(f.rows.items.len, f.top + f.visible)) |index| {
        const y = table.y + 34 + @as(f32, @floatFromInt(index - f.top)) * 34;
        const row_rect = Rect{ .x = table.x + 4, .y = y, .w = table.w - 8, .h = 32 };
        if (index == f.selected_row) try ctx.r.shape(row_rect, ctx.p.selection, .{ .radii = @splat(4) });
        v.hit(row_rect, .{ .files_row = index });
        try row(v, ctx, .{ .x = table.x + 12, .y = y + 4, .w = table.w - 24, .h = 28 }, f.rows.items[index], now);
    }
    if (f.rows.items.len == 0) {
        var reason: []const u8 = if (f.mode == .leaks) "No growth candidates in the sampled cache" else if (f.mode == .deleted) "No deleted holders in the sampled cache" else "No matching rows; inspect partial coverage above";
        if (f.mode != .events) if (f.scopeReason()) |scope_reason| { reason = scope_reason; };
        var line: [400]u8 = undefined;
        const failed = f.mode == .events and std.mem.eql(u8, f.captureState(), "failed");
        if (f.mode == .events) reason = if (f.event_status == c.XRT_STALE_SNAPSHOT) (if (f.exact_requested or f.event_authorized) "Event enrollment pending" else "Exact capture is off; E opens its cost and access confirmation") else if (f.failure_len > 0) (if (failed) std.fmt.bufPrint(&line, "Exact capture failed: {s}", .{f.failure[0..f.failure_len]}) catch "Exact capture failed" else f.failure[0..f.failure_len]) else "Select a process and confirm event capture";
        if (failed) {
            // The operation, errno text, path and remedy must all stay readable.
            const room: usize = @intFromFloat(@max(24, table.h - 62) / 24);
            const y = try wrap(ctx, table.x + 14, table.y + 56, table.w - 28, reason, ctx.p.crit, @min(3, room));
            const used: usize = @intFromFloat((y - table.y - 56) / 24);
            if (f.remedy) |remedy| if (room > used) {
                _ = try wrap(ctx, table.x + 14, y + 6, table.w - 28, remedy, ctx.p.warn, @min(3, room - used));
            };
        } else try ctx.textFit(table.x + 14, table.y + 56, table.w - 28, reason, ctx.p.warn);
    }
    if (f.mode == .events) {
        const evidence = std.fmt.bufPrint(&buf, "Capture {d} · lost {d} · unpaired {d} · invalid {d} · {s}", .{ f.event_generation, f.event.lost, f.event.unpaired, f.event.invalid, f.captureState() }) catch "";
        try ctx.textFit(rect.x + 8, rect.y + rect.h - 48, rect.w - 16, evidence, if (std.mem.eql(u8, f.captureState(), "failed")) ctx.p.crit else if (f.event.flags != 0) ctx.p.warn else ctx.p.dim);
    }
    const note = std.fmt.bufPrint(&buf, "{d} cached rows · {d} ms shared polling · soft budget {d} ms · {s}", .{ f.rows.items.len, f.active_interval_ms, if (f.active_interval_ms == 250) @as(u8, 5) else 10, if (v.paused) "view frozen; peers may continue sampling" else "read-only; no target pause" }) catch "";
    try ctx.textFit(rect.x + 8, rect.y + rect.h - 24, rect.w - 16, if (f.exact_active) "exact mode slows all syscalls on this machine by roughly 10 % while active" else note, if (f.exact_active) ctx.p.warn else ctx.p.dim);
}

/// Up to `lines` lines broken after a space or '/', the last one truncated; returns the next y.
fn wrap(ctx: Ctx, x: f32, y0: f32, w: f32, text: []const u8, color: draw.Color, lines: usize) !f32 {
    var rest = text;
    var y = y0;
    for (0..lines) |line| {
        if (rest.len == 0) break;
        var end = rest.len;
        if (line + 1 < lines and ctx.measure(rest) > w) {
            end = 0;
            for (rest, 0..) |ch, i| {
                if (ch != ' ' and ch != '/') continue;
                if (ctx.measure(rest[0 .. i + 1]) > w) break;
                end = i + 1;
            }
            if (end == 0) end = rest.len;
        }
        try ctx.textFit(x, y, w, std.mem.trimEnd(u8, rest[0..end], " "), color);
        rest = rest[end..];
        y += 24;
    }
    return y;
}

fn heatmap(ctx: Ctx, rect: Rect, s: *const c.struct_xrt_fd_snapshot, redact: bool) !void {
    try ctx.text(rect.x + 8, rect.y, "System fd churn history · sampled opens + closes", ctx.p.dim);
    var best: [8]?u32 = @splat(null);
    for (s.processes[0..s.process_count], 0..) |p, index| {
        for (&best, 0..) |*entry, slot| {
            if (entry.* == null or p.churn_rate > s.processes[entry.*.?].churn_rate) {
                var j: usize = best.len - 1;
                while (j > slot) : (j -= 1) best[j] = best[j - 1];
                entry.* = @intCast(index);
                break;
            }
        }
    }
    const width = rect.w / 8;
    for (best, 0..) |maybe, tile_index| {
        const index = maybe orelse continue;
        const p: *const c.struct_xrt_fd_process = @ptrCast(&s.processes[index]);
        const x = rect.x + @as(f32, @floatFromInt(tile_index)) * width;
        var buf: [64]u8 = undefined;
        var name: []const u8 = if (redact) std.fmt.bufPrint(&buf, "pid {d}", .{p.pid}) catch "" else "";
        if (!redact) {
            // Keep the pid visible: shorten only the command name.
            const comm = fm.State.name(p);
            var keep = comm.len;
            name = fm.State.churnLabel(&buf, comm, p.pid, keep);
            while (keep > 0 and ctx.measure(name) > width - 16) : (keep -= 1) name = fm.State.churnLabel(&buf, comm, p.pid, keep - 1);
        }
        try ctx.textFit(x + 8, rect.y + 24, width - 16, name, if (p.flags & c.XRT_FDP_STALE != 0) ctx.p.dim else ctx.p.text);
        const count = @min(p.history.samples, c.XRT_FD_HISTORY);
        var peak: u32 = 1;
        for (p.history.churn[0..count]) |n| peak = @max(peak, n);
        const cell_w = (width - 16) / 32;
        for (0..32) |i| {
            const cell = Rect{ .x = x + 8 + @as(f32, @floatFromInt(i)) * cell_w, .y = rect.y + 50, .w = @max(1, cell_w - 1), .h = 16 };
            if (i >= count) {
                try ctx.r.rect(cell, ctx.p.grid);
            } else {
                const intensity = @as(f32, @floatFromInt(p.history.churn[i])) / @as(f32, @floatFromInt(peak));
                try ctx.r.rect(cell, draw.mix(ctx.p.raised, ctx.p.accent2, intensity));
            }
        }
    }
}

fn row(v: *vw.View, ctx: Ctx, rect: Rect, item: fm.Row, now: u64) !void {
    const f = &v.files;
    const id = f.identity(item);
    var buf: [256]u8 = undefined;
    const label = if (id.fd >= 0) std.fmt.bufPrint(&buf, "{d}:{d}", .{ id.owner.pid, id.fd }) catch "" else std.fmt.bufPrint(&buf, "{d}", .{id.owner.pid}) catch "";
    try ctx.textFit(rect.x, rect.y, 142, label, ctx.p.dim);
    const text_x = rect.x + 158;
    const text_w = rect.w - 446;
    const first_right = rect.x + rect.w - 138;
    const right = rect.x + rect.w;
    switch (item) {
        .event => |index| {
            const event = f.event_rows.items[index];
            try ctx.textFit(text_x, rect.y, text_w, "Successful syscall returns; current path is not attribution", ctx.p.dim);
            try ctx.textRight(first_right, rect.y, m.bytes(&buf, @floatFromInt(event.read_bytes)), ctx.p.accent);
            try ctx.textRight(right, rect.y, m.bytes(&buf, @floatFromInt(event.write_bytes)), ctx.p.accent2);
        },
        .process => |index| {
            const p: *const c.struct_xrt_fd_process = @ptrCast(&f.snapshot.?.processes[index]);
            const color = if (p.flags & c.XRT_FDP_STALE != 0) ctx.p.dim else ctx.p.text;
            const name = if (v.redact) "process" else fm.State.name(p);
            try ctx.textFit(text_x, rect.y, text_w * 0.48, name, color);
            const n = @min(p.history.samples, 32);
            if (n > 1) {
                var points: [32]?[2]f32 = @splat(null);
                var low: u32 = std.math.maxInt(u32);
                var high: u32 = 0;
                for (p.history.fds[0..n]) |value| {
                    low = @min(low, value);
                    high = @max(high, value);
                }
                const x = text_x + text_w * 0.54;
                const width = text_w * 0.44;
                for (p.history.fds[0..n], 0..) |value, i| points[i] = .{
                    x + width * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1)),
                    rect.y + 21 - 18 * @as(f32, @floatFromInt(value - low)) / @as(f32, @floatFromInt(@max(1, high - low))),
                };
                try ctx.polyline(points[0..n], 1.5, if (f.mode == .leaks) ctx.p.warn else ctx.p.accent, true);
            }
            try ctx.textRight(first_right, rect.y, if (p.flags & c.XRT_FDP_STALE != 0) "stale" else if (p.interval_ns == 0) "first sample" else std.fmt.bufPrint(&buf, "{d:.1}", .{p.churn_rate}) catch "", color);
            try ctx.textRight(right, rect.y, std.fmt.bufPrint(&buf, "{d}", .{p.count}) catch "", if (f.mode == .leaks) ctx.p.warn else color);
            v.hover(rect, "pid {d}, start {d}; growth above window low {d}; stale={}; truncated={}", .{ p.pid, p.start, p.growth, p.flags & c.XRT_FDP_STALE != 0, p.flags & c.XRT_FDP_TRUNCATED != 0 });
        },
        .descriptor => |index| {
            const s = f.snapshot.?;
            const p = s.processes[index.process];
            const fd = s.fds[index.fd];
            const color = if (fm.State.stale(p, fd)) ctx.p.dim else ctx.p.text;
            const retained = if (fm.State.stale(p, fd)) "[stale] " else "";
            const path = if (v.redact) "redacted" else fm.State.path(s, fd);
            const leaf = std.fs.path.basename(path);
            const title = if (!v.redact and !std.mem.eql(u8, leaf, path)) std.fmt.bufPrint(&buf, "{s}{s}  {s} · {s}", .{ retained, std.mem.span(c.xrt_fd_kind_name(fd.kind)), leaf, path }) catch leaf else std.fmt.bufPrint(&buf, "{s}{s}  {s}", .{ retained, std.mem.span(c.xrt_fd_kind_name(fd.kind)), path }) catch path;
            try ctx.textFit(text_x, rect.y, text_w, title, color);
            if (f.mode == .deleted) {
                try ctx.textRight(first_right, rect.y, if (fd.flags & c.XRT_FD_STAT == 0) "unavailable" else m.bytes(&buf, @floatFromInt(fd.size)), color);
                try ctx.textRight(right, rect.y, if (fd.flags & c.XRT_FD_STAT == 0) "unavailable" else m.bytes(&buf, @floatFromInt(fd.disk)), ctx.p.warn);
                v.hover(rect, "Held inode sizes are not additive across holders; no reclaimed-space estimate", .{});
            } else {
                const rate = fm.State.progress(p, fd);
                try ctx.textRight(first_right, rect.y, if (rate) |n| m.rate(&buf, n) else "unmeasured", color);
                try ctx.textRight(right, rect.y, if (fd.kind != c.XRT_FD_REGULAR and fd.kind != c.XRT_FD_MEMFD) "—" else if (fd.flags & c.XRT_FD_INFO == 0) "unavailable" else std.fmt.bufPrint(&buf, "{d}", .{fd.pos}) catch "", color);
                if (rate) |n| {
                    try ctx.bar(.{ .x = text_x, .y = rect.y + 23, .w = text_w, .h = 3 }, @min(1, @log2(@as(f64, n) + 1) / 30), fade(ctx.p.accent, 0.6));
                    if (n > 0 and !v.paused and !fm.State.offsetStale(p, fd)) {
                        const phase = @as(f32, @floatFromInt(now % 1_000_000_000)) / 1_000_000_000;
                        try ctx.r.shape(.{ .x = text_x + phase * @max(0, text_w - 8), .y = rect.y + 22, .w = 8, .h = 5 }, ctx.p.accent, .{ .radii = @splat(2) });
                    }
                }
                var flags_buf: [32]u8 = undefined;
                const flags = if (fd.flags & c.XRT_FD_INFO != 0) std.fmt.bufPrint(&flags_buf, "0{o}", .{fd.open_flags}) catch "unavailable" else "unavailable";
                v.hover(rect, "pid {d}, fd {d}; {s}; flags {s} ({s}); offset age {d} ms; path stale={}; stat stale={}; {s}", .{ p.pid, fd.fd, fm.State.progressReason(p, fd), flags, if (fm.State.offsetStale(p, fd)) "cached" else "sampled", (now -| fd.info_sampled_ns) / 1_000_000, p.flags & c.XRT_FDP_STALE != 0 or fd.flags & c.XRT_FD_LINK_STALE != 0, p.flags & c.XRT_FDP_STALE != 0 or fd.flags & c.XRT_FD_STAT_STALE != 0, path });
            }
        },
    }
}
