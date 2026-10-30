//! Kernel census rows share the model publication with MCP. No reads in draw.
const std = @import("std");
const draw = @import("draw.zig");
const redact = @import("../../redact.zig");

pub fn render(v: anytype, ctx: draw.Ctx, rect: draw.Rect) !void {
    try ctx.panel(rect);
    const r = draw.inset(rect, 12);
    var out: [512]u8 = undefined;
    const cache = v.kernel_census orelse {
        try ctx.textFit(r.x, r.y, r.w, "Kernel stacks require a live Linux source", ctx.p.dim);
        return;
    };
    try ctx.textFit(r.x, r.y, r.w, "Kernel stacks · D-state first", ctx.p.text);
    const s = if (cache.current) |*snapshot| snapshot else {
        try ctx.textFit(r.x, r.y + 26, r.w, cache.failure orelse "Collecting task stacks…", ctx.p.dim);
        return;
    };
    const heading = try std.fmt.bufPrint(&out, "{s}{d} tasks · {d} groups · denied {d} · gone {d}{s}", .{
        if (s.truncated or s.failure != null) "PARTIAL · " else "",
        s.tasks.items.len,
        s.groups.items.len,
        s.denied,
        s.vanished,
        if (cache.job != null) " · refreshing" else "",
    });
    try ctx.textFit(r.x, r.y + 26, r.w, heading, ctx.p.dim);
    try ctx.textFit(r.x, r.y + 52, r.w, if (s.scope_missing) "The --kernel-pid process was not found." else if (s.denied > 0) "Denied stacks need root/access." else "Sampled, not an atomic stop. No attach.", ctx.p.dim);
    try ctx.textFit(r.x, r.y + 74, r.w, "User stack: stopped debugger thread only.", ctx.p.dim);
    var line: usize = 0;
    const first = &v.scroll[@intFromEnum(@TypeOf(v.panel).kernel_stacks)];
    const visible: usize = @intFromFloat(@max(0, r.h - 104) / 22);
    v.visible_rows = visible;
    for (s.groups.items) |g| {
        const title = try std.fmt.bufPrint(&out, "{d} tasks  /  D {d}  /  {s}", .{ g.count, g.d_count, @tagName(g.status) });
        try row(ctx, r, first.*, visible, &line, title, true);
        var frames = std.mem.splitScalar(u8, g.stack, '\n');
        while (frames.next()) |frame| if (frame.len > 0) {
            try row(ctx, r, first.*, visible, &line, frame, false);
        };
        for (s.tasks.items[g.first..][0..g.count]) |task| {
            const member = try std.fmt.bufPrint(&out, "  {d}/{d}  {c}  {s}  {s}", .{ task.pid, task.tid, task.state, if (v.redact) "<redacted>" else task.comm, task.wchan });
            try row(ctx, r, first.*, visible, &line, member, false);
        }
    }
    first.* = @min(first.*, line -| visible);
}

fn row(ctx: draw.Ctx, r: draw.Rect, first: usize, visible: usize, line: *usize, text: []const u8, strong: bool) !void {
    defer line.* += 1;
    if (line.* < first or line.* - first >= visible) return;
    var buf: [1024]u8 = undefined;
    const shown = if (redact.active()) |policy| policy.scrubInto(&buf, text) else text;
    try ctx.textFit(r.x, r.y + 104 + @as(f32, @floatFromInt(line.* - first)) * 22, r.w, shown, if (strong) ctx.p.text else ctx.p.dim);
}
