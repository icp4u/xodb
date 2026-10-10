//! Parent/child descriptor comparison; all matching and accounting is C-owned.
const std = @import("std");
const c = @import("../../c.zig").api;
const vw = @import("view.zig");
const draw = @import("draw.zig");
const fm = @import("files_model.zig");
pub fn render(v: *vw.View, ctx: draw.Ctx, rect: draw.Rect, now: u64) !void {
    var buffer: [512]u8 = undefined;
    try ctx.textFit(rect.x + 8, rect.y + 4, rect.w - 16, "Parent & child descriptors", ctx.p.text);
    try ctx.textFit(rect.x + 8, rect.y + 30, rect.w - 16, "POLLING · matching fd + inode · inheritance and exec history unproved", ctx.p.warn);
    const rows = v.graph.inheritance orelse {
        const reason = if (v.graph.failure()) |why| why else if (v.graph.inheritance_status == c.XRT_OUT_OF_MEMORY) "Not enough memory for descriptor comparisons" else if (v.graph.inheritance_status != c.XRT_OK and v.graph.inheritance_status != c.XRT_STALE_SNAPSHOT) "Descriptor comparison unavailable" else if (v.action_hook == null) "Descriptor data is unavailable in this replay" else "Waiting for descriptor snapshot";
        try ctx.textFit(rect.x + 8, rect.y + 64, rect.w - 16, reason, ctx.p.dim);
        return;
    };
    const snapshot = v.graph.snapshot orelse return;
    const totals = std.fmt.bufPrint(&buffer, "{d} pairs · {d} sampled matches · child flags: {d} CLOEXEC / {d} no CLOEXEC / {d} unknown", .{ rows.parent_pairs, rows.matched, rows.cloexec, rows.no_cloexec, rows.flags_unknown }) catch "";
    try ctx.textFit(rect.x + 8, rect.y + 58, rect.w - 16, totals, ctx.p.dim);
    const limits = std.fmt.bufPrint(&buffer, "{d} cached matches · parents: {d} need privilege, {d} exited or hidepid, {d} pid reused · {d} unknown identities · {d} rows capped", .{ rows.stale, rows.parent_denied, rows.parent_absent, rows.parent_reused, rows.identity_unknown, rows.dropped }) catch "";
    try ctx.textFit(rect.x + 8, rect.y + 80, rect.w - 16, limits, ctx.p.dim);
    const omissions = std.fmt.bufPrint(&buffer, "Scan: {d} denied · {d} unscanned · {d} gone · capped {d} processes / {d} fds", .{ snapshot.hidden, snapshot.unscanned, snapshot.gone, snapshot.dropped_processes, snapshot.dropped_fds }) catch "";
    try ctx.textFit(rect.x + 8, rect.y + 102, rect.w - 16, omissions, ctx.p.dim);
    if (v.graph.failure()) |why| {
        const line = std.fmt.bufPrint(&buffer, "{s} · previous snapshot ({d:.1}s old)", .{ why, @as(f64, @floatFromInt(now -| rows.taken_ns)) / 1_000_000_000.0 }) catch why;
        try ctx.textFit(rect.x + 8, rect.y + 124, rect.w - 16, line, ctx.p.warn);
    }
    const top = &v.scroll[@intFromEnum(vw.Panel.inheritance)];
    const height = @max(0, rect.h - 208);
    const visible: u32 = @intFromFloat(height / 46);
    v.visible_rows = @max(1, visible);
    top.* = @min(top.*, rows.count -| visible);
    const body = draw.Rect{ .x = rect.x + 4, .y = rect.y + 156, .w = rect.w - 8, .h = height };
    const clip = ctx.r.clip;
    ctx.r.clip = draw.intersect(clip, body);
    for (top.*..@min(rows.count, top.* + visible)) |i| {
        const r = rows.rows[i];
        const parent = snapshot.processes[r.parent];
        const child = snapshot.processes[r.child];
        const fd = snapshot.fds[r.child_fd];
        const y = body.y + @as(f32, @floatFromInt(i - top.*)) * 46;
        const hit = draw.Rect{ .x = body.x, .y = y, .w = body.w, .h = 44 };
        if (i % 2 == 0) try ctx.r.rect(hit, draw.fade(ctx.p.raised, 0.65));
        v.hit(hit, .{ .inheritance_files = .{ .pid = child.pid, .start = child.start } });
        const stale = r.flags & (c.XRT_FDINH_PARENT_STALE | c.XRT_FDINH_CHILD_STALE | c.XRT_FDINH_IDENTITY_STALE) != 0;
        const color = if (stale) ctx.p.dim else ctx.p.text;
        const identity = std.fmt.bufPrint(&buffer, "{d} → {d} · fd {d}", .{ parent.pid, child.pid, fd.fd }) catch "";
        const left = @min(280, body.w * 0.47);
        try ctx.textFit(body.x + 8, y + 2, left - 16, identity, color);
        const flag_text: []const u8 = if (r.flags & c.XRT_FDINH_CHILD_FLAGS_KNOWN == 0) "child flags unknown" else if (r.flags & c.XRT_FDINH_CHILD_CLOEXEC != 0) "child CLOEXEC" else "child no CLOEXEC";
        try ctx.textFit(body.x + left, y + 2, body.w - left - 8, flag_text, if (r.flags & c.XRT_FDINH_CHILD_FLAGS_KNOWN == 0) ctx.p.dim else if (r.flags & c.XRT_FDINH_CHILD_CLOEXEC != 0) ctx.p.ok else ctx.p.warn);
        const path = if (v.redact) "path redacted" else fm.State.path(snapshot, fd);
        const label = std.fmt.bufPrint(&buffer, "{s} · {s}{s}", .{ std.mem.span(c.xrt_fd_kind_name(fd.kind)), path, if (stale) " · cached" else "" }) catch "path unavailable";
        try ctx.textFit(body.x + 8, y + 24, body.w - 16, label, ctx.p.dim);
        v.hover(hit, "Sampled match only; independently reopened files can match. Click for child {d} fd table.", .{child.pid});
        if (c.getenv("XODB_OVERVIEW_AUDIT") != null)
            std.debug.print("xodb: fdinherit-row parent={d} child={d} fd={d} flags={d} x={d:.1} y={d:.1}\n", .{ parent.pid, child.pid, fd.fd, r.flags, hit.x + 10, hit.y + 10 });
    }
    ctx.r.clip = clip;
    if (rows.count == 0) try ctx.textFit(rect.x + 12, rect.y + 166, rect.w - 24, "No sampled parent/child matches; review missing coverage above", ctx.p.dim);
    const excluded = std.fmt.bufPrint(&buffer, "{d} child fds lack a matching parent fd · {d} different objects · same inode does not prove same open", .{ rows.no_parent_fd, rows.different_object }) catch "";
    try ctx.textFit(rect.x + 8, rect.y + rect.h - 46, rect.w - 16, excluded, ctx.p.dim);
    try ctx.textFit(rect.x + 8, rect.y + rect.h - 24, rect.w - 16, "Click a row for child Files · arrows/wheel scroll · P pause · G graph · Y galaxy", ctx.p.dim);
}
