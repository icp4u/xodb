//! Remote debugger presentation. Never reads /proc or native registers locally.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Window = @import("../platform/wayland.zig").Window;
const keys = @import("../platform/input.zig");
const style = @import("style.zig");
const theme = style.theme;
const remote = @import("../remote/client.zig");
const wire = @import("../remote/view.zig");
const transport = @import("../remote/transport.zig");
const Button = struct { name: []const u8, key: []const u8, x: f32, width: f32 };
const buttons = [_]Button{
    .{ .name = "Continue", .key = "SPACE", .x = 16, .width = 174 },
    .{ .name = "Step", .key = "F11", .x = 204, .width = 104 },
    .{ .name = "Over", .key = "F10", .x = 320, .width = 106 },
    .{ .name = "Instruction", .key = "F7", .x = 438, .width = 164 },
    .{ .name = "Detach", .key = "D", .x = 618, .width = 126 },
    .{ .name = "Registers", .key = "TAB", .x = 762, .width = 170 },
    .{ .name = "Watch", .key = "W", .x = 944, .width = 116 },
    .{ .name = "Watches", .key = "V", .x = 1072, .width = 144 },
};
const Workspace = struct {
    snapshot: ?remote.Snapshot = null,
    last_stop: ?remote.Snapshot = null,
    registers: bool = false,
    watch_list: bool = false,
    selected_value: ?usize = null,
    selected_watch: ?u64 = null,
    source_scroll: usize = 0,
    values_scroll: usize = 0,
    thread_scroll: usize = 0,
    frame_scroll: usize = 0,
    status: []const u8 = "Connecting",
    fn deinit(self: *Workspace) void {
        if (self.snapshot) |snapshot| snapshot.deinit();
        if (self.last_stop) |snapshot| snapshot.deinit();
    }
    fn displayView(self: *const Workspace) ?wire.View {
        if (self.last_stop) |snapshot| return snapshot.value;
        return if (self.snapshot) |snapshot| snapshot.value else null;
    }
    fn sync(self: *Workspace, client: *remote.Client) bool {
        const next = client.take() orelse return false;
        self.accept(next);
        return true;
    }
    fn accept(self: *Workspace, next: remote.Snapshot) void {
        const changed_thread = if (self.displayView()) |old| old.tid != next.value.tid else true;
        const same_target = if (self.snapshot) |old| old.value.session_id == next.value.session_id and old.value.pid == next.value.pid else false;
        if (same_target and std.mem.eql(u8, next.value.state, "running")) {
            if (self.snapshot) |old| if (std.mem.eql(u8, old.value.state, "stopped")) {
                if (self.last_stop) |saved| saved.deinit();
                self.last_stop = old; // Transfer ownership; no inspection-data copy.
                self.snapshot = null;
            };
        } else if (self.last_stop) |saved| {
            saved.deinit();
            self.last_stop = null;
        }
        if (self.snapshot) |old| old.deinit();
        self.snapshot = next;
        // Running updates own state/generation and the live thread list. Keep
        // the stopped panes and scroll positions until a new stop arrives.
        if (self.last_stop != null) return;
        self.selected_value = null;
        self.selected_watch = null;
        self.status = "Ready";
        const view = next.value;
        if (changed_thread) {
            self.frame_scroll = 0;
            self.values_scroll = 0;
            for (view.threads, 0..) |thread, i| if (thread.tid == view.tid) {
                self.thread_scroll = i -| 2;
                break;
            };
        }
        if (view.source) |source| if (view.frame < view.frames.len) {
            if (view.frames[view.frame].source) |site| if (sameFile(site.path, source.path)) {
                self.source_scroll = site.line -| 6;
            };
        };
    }
    fn invoke(self: *Workspace, client: *remote.Client, index: usize) void {
        if (index == 5 or index == 7) {
            if (index == 5) {
                self.registers = !self.registers;
                self.watch_list = false;
            } else {
                self.watch_list = !self.watch_list;
                self.registers = false;
            }
            self.values_scroll = 0;
            return;
        }
        const view = if (self.snapshot) |snapshot| snapshot.value else return;
        const facts = client.facts();
        if (facts.state != .ready or facts.busy) {
            self.status = "Waiting for remote state";
            return;
        }
        if (std.mem.eql(u8, view.scope, "observe")) {
            self.status = "Server scope is observe; restart server with --agent-scope control";
            return;
        }
        const running = std.mem.eql(u8, view.state, "running");
        const stopped = std.mem.eql(u8, view.state, "stopped");
        if (!running and !stopped) return;
        if (index == 6) {
            if (!stopped) return;
            if (self.watch_list) {
                const id = self.selected_watch orelse {
                    self.status = "Select a watch to remove";
                    return;
                };
                client.action("remove_watchpoint", .{ .generation = view.generation, .id = id }) catch |err| {
                    self.status = @errorName(err);
                };
                return;
            }
            const selected = self.selected_value orelse {
                self.status = "Click an addressable scalar local, then Watch (W)";
                return;
            };
            if (self.registers or selected >= view.locals.len) return;
            const local = view.locals[selected];
            const address = local.address orelse {
                self.status = "Selected local has no memory address";
                return;
            };
            if (local.size != 1 and local.size != 2 and local.size != 4 and local.size != 8) {
                self.status = "Watch requires an aligned 1, 2, 4 or 8 byte value";
                return;
            }
            if (address % local.size != 0) {
                self.status = "Watch requires natural alignment";
                return;
            }
            for (view.watchpoints) |watch| if (watch.address == address and watch.length == local.size) {
                client.action("remove_watchpoint", .{ .generation = view.generation, .id = watch.id }) catch |err| {
                    self.status = @errorName(err);
                };
                return;
            };
            client.action("investigate_write", .{ .generation = view.generation, .tid = view.tid, .frame = view.frame, .question = "Why did this local change?", .expression = local.name }) catch |err| {
                self.status = @errorName(err);
            };
            return;
        }
        if (index == 0 or index == 4) {
            client.action(if (index == 4) "detach" else if (running or view.continue_pending) "interrupt" else "continue", .{ .generation = view.generation }) catch |err| {
                self.status = @errorName(err);
                return;
            };
            if (index == 0 and !running) client.select(0, 0);
        } else if (stopped) {
            // Match the local workspace: no current source line means instruction
            // stepping. The inspected caller's source is not the executing PC.
            client.action(stepMethod(view, index), .{ .generation = view.generation, .tid = view.tid }) catch |err| {
                self.status = @errorName(err);
                return;
            };
            client.select(view.tid, 0);
        }
    }
    fn input(self: *Workspace, window: *Window, client: *remote.Client) void {
        const width: f32 = @floatFromInt(window.width);
        const height: f32 = @floatFromInt(window.height);
        const left = @round(width * 0.46);
        const right = @round(width * 0.75);
        const bottom = @round(height * 0.70);
        while (window.input.next()) |event| {
            if (event.kind == .press and event.plain()) {
                switch (event.shortcut) {
                    'q' => {
                        window.closing = true;
                        window.close_reason = .quit_key;
                    },
                    keys.sym.space, keys.sym.f5, keys.sym.f6 => self.invoke(client, 0),
                    keys.sym.f11 => self.invoke(client, 1),
                    keys.sym.f10 => self.invoke(client, 2),
                    0xffc4 => self.invoke(client, 3), // F7
                    'd' => self.invoke(client, 4),
                    keys.sym.tab => self.invoke(client, 5),
                    'w' => self.invoke(client, 6),
                    'v' => self.invoke(client, 7),
                    else => {},
                }
            }
            if (event.kind != .button_press or event.code != 272) continue;
            if (event.y >= 50 and event.y < 80) {
                for (buttons, 0..) |b, i| if (event.x >= b.x and event.x < b.x + b.width) self.invoke(client, i);
                continue;
            }
            const view = if (self.snapshot) |snapshot| snapshot.value else continue;
            if (event.y >= bottom + 38 and event.y < height - 36) {
                if (!std.mem.eql(u8, view.state, "stopped") or client.facts().busy) continue;
                const row: usize = @intFromFloat((event.y - bottom - 38) / 23);
                if (event.x < left) {
                    const index = row + self.thread_scroll;
                    if (index < view.threads.len) client.select(view.threads[index].tid, 0);
                } else {
                    const index = row + self.frame_scroll;
                    if (index < view.frames.len) client.select(view.tid, index);
                }
                continue;
            }
            if (event.y < 132 or event.y >= bottom - 8 or client.facts().busy) continue;
            if (!std.mem.eql(u8, view.state, "stopped")) continue;
            if (event.x >= right and !self.registers) {
                const selected = self.values_scroll + @as(usize, @intFromFloat((event.y - 132) / 46));
                if (self.watch_list) {
                    self.selected_watch = if (selected < view.watchpoints.len) view.watchpoints[selected].id else null;
                } else {
                    self.selected_value = if (selected < view.locals.len) selected else null;
                }
                continue;
            }
            if (std.mem.eql(u8, view.scope, "observe")) {
                self.status = "Server scope is observe";
                continue;
            }
            const row: usize = @intFromFloat((event.y - 132) / 23);
            if (event.x >= left and event.x < left + 35 and row < view.instructions.len) {
                const address = view.instructions[row].address;
                var probe_id: ?u64 = null;
                for (view.breakpoints) |probe| if (probe.address == address) {
                    probe_id = probe.id;
                    break;
                };
                if (probe_id) |id| {
                    client.action("remove_breakpoint", .{ .generation = view.generation, .id = id }) catch |err| {
                        self.status = @errorName(err);
                    };
                } else {
                    var buffer: [32]u8 = undefined;
                    const address_text = std.fmt.bufPrint(&buffer, "0x{x}", .{address}) catch unreachable;
                    client.action("set_breakpoint", .{ .generation = view.generation, .address = address_text }) catch |err| {
                        self.status = @errorName(err);
                    };
                }
            } else if (event.x < 76 and view.source != null) {
                const path = sourceBreakpointPath(view);
                const line_number = self.source_scroll + row + 1;
                var probe_id: ?u64 = null;
                for (view.breakpoints) |probe| if (probe.source) |s| if (s.line == line_number and sameFile(s.path, view.source.?.path)) {
                    probe_id = probe.id;
                    break;
                };
                if (probe_id) |id| {
                    client.action("remove_breakpoint", .{ .generation = view.generation, .id = id }) catch |err| {
                        self.status = @errorName(err);
                    };
                } else client.action("set_breakpoint", .{ .generation = view.generation, .file = path, .line = line_number }) catch |err| {
                    self.status = @errorName(err);
                };
            }
        }
        if (window.scroll != 0) {
            const scroll = window.scroll;
            window.scroll = 0;
            const target = if (window.pointer_y >= bottom) (if (window.pointer_x < left) &self.thread_scroll else &self.frame_scroll) else if (window.pointer_x >= right) &self.values_scroll else &self.source_scroll;
            const displayed = self.displayView();
            const max_rows = if (window.pointer_y >= bottom)
                (if (window.pointer_x < left) (if (self.snapshot) |s| s.value.threads.len else 0) else if (displayed) |v| v.frames.len else 0)
            else if (window.pointer_x >= right)
                (if (displayed) |v| (if (self.registers) v.registers.len else if (self.watch_list) v.watchpoints.len else v.locals.len) else 0)
            else if (displayed) |v| (if (v.source) |source| std.mem.count(u8, source.text, "\n") + 1 else 0) else 0;
            target.* = @min(max_rows -| 1, if (scroll > 0) target.* + 3 else target.* -| 3);
        }
    }
    fn draw(self: *Workspace, r: *gpu.Renderer, font: *Font, window: *Window, client: *remote.Client, label: []const u8) !void {
        const width: f32 = @floatFromInt(window.width);
        const height: f32 = @floatFromInt(window.height);
        const all = gpu.Rect{ .x = 0, .y = 0, .w = width, .h = height };
        r.clip = all;
        try r.rect(all, theme.background);
        const facts = client.facts();
        const live_view: ?wire.View = if (self.snapshot) |s| s.value else null;
        const view = self.displayView();
        const historical = self.last_stop != null;
        try r.text(font, 18, 14, "xodb", theme.neutral);
        try r.textFit(font, 82, 14, width - 98, label, theme.text);
        for (buttons, 0..) |b, i| {
            const text = if (i == 0 and live_view != null and live_view.?.continue_pending) "Cancel" else if (i == 0 and live_view != null and std.mem.eql(u8, live_view.?.state, "running")) "Interrupt" else if (i == 5 and self.registers) "Locals" else if (i == 6 and self.watch_list) "Remove" else if (i == 7 and self.watch_list) "Locals" else b.name;
            const live = i == 5 or i == 7 or (facts.state == .ready and !facts.busy and live_view != null and !std.mem.eql(u8, live_view.?.scope, "observe") and (std.mem.eql(u8, live_view.?.state, "stopped") or (std.mem.eql(u8, live_view.?.state, "running") and (i == 0 or i == 4))));
            const hovered = window.pointer_y >= 50 and window.pointer_y < 79 and window.pointer_x >= b.x and window.pointer_x < b.x + b.width;
            try style.button(r, font, .{ .x = b.x, .y = 50, .w = b.width, .h = 29 }, text, b.key, if (!live) theme.weak else if (i == 0) theme.good else theme.text, if (hovered and live) 1 else 0, 0);
        }
        const left = @round(width * 0.46);
        const right = @round(width * 0.75);
        const bottom = @round(height * 0.70);
        try pane(r, font, .{ .x = 8, .y = 91, .w = left - 12, .h = bottom - 98 }, if (view != null and view.?.source != null and view.?.source.?.truncated) "SOURCE / first 48 KiB" else if (historical) "SOURCE / last stop" else "SOURCE / provided file", if (view) |v| (if (v.source) |s| std.fs.path.basename(s.path) else "not shared") else "");
        if (view) |v| {
            if (v.source) |source| {
                var lines = std.mem.splitScalar(u8, source.text, '\n');
                var number: usize = 0;
                var row: usize = 0;
                while (lines.next()) |text| : (number += 1) {
                    if (number < self.source_scroll) continue;
                    const y = 132 + @as(f32, @floatFromInt(row)) * 23;
                    if (y + 20 >= bottom - 10) break;
                    const line_number = number + 1;
                    const site = if (v.frame < v.frames.len) v.frames[v.frame].source else null;
                    const current = if (site) |s| sameFile(s.path, source.path) and s.line == line_number else false;
                    if (current) try r.rect(.{ .x = 9, .y = y - 2, .w = left - 14, .h = 23 }, style.fade(theme.thread_main, 0.13));
                    for (v.breakpoints) |probe| if (probe.source) |s| if (s.line == line_number and sameFile(s.path, source.path)) {
                        try style.disc(r, 20, y + 9, 4, theme.breakpoint);
                        break;
                    };
                    try formatted(r, font, 30, y, 40, if (current) theme.thread_main else theme.weak, "{d}", .{line_number});
                    try r.textFit(font, 80, y, left - 94, text[0..@min(text.len, 512)], theme.text);
                    row += 1;
                }
            } else {
                try r.textFit(font, 22, 142, left - 38, "Server: --source FILE shares one source file", theme.weak);
                try r.textFit(font, 22, 170, left - 38, "Assembly and stack remain available.", theme.weak);
            }
        }
        try pane(r, font, .{ .x = left, .y = 91, .w = right - left - 5, .h = bottom - 98 }, if (historical) "ASSEMBLY / last stop" else "ASSEMBLY", if (view) |v| v.architecture else "");
        if (view) |v| for (v.instructions, 0..) |inst, row| {
            const y = 132 + @as(f32, @floatFromInt(row)) * 23;
            if (y + 20 >= bottom - 10) break;
            if (row == 0) try r.rect(.{ .x = left + 1, .y = y - 2, .w = right - left - 7, .h = 23 }, style.fade(theme.thread_main, 0.13));
            for (v.breakpoints) |probe| if (probe.address == inst.address) {
                try style.disc(r, left + 15, y + 9, 4, theme.breakpoint);
                break;
            };
            try formatted(r, font, left + 28, y, right - left - 38, theme.text, "{x}  {s} {s}", .{ inst.address, inst.mnemonic, inst.operands });
        };
        try pane(r, font, .{ .x = right, .y = 91, .w = width - right - 8, .h = bottom - 98 }, if (self.registers) (if (historical) "REGISTERS / last stop" else "REGISTERS") else if (self.watch_list) (if (historical) "WATCHES / last stop" else "HARDWARE WATCHES") else if (view != null and view.?.locals_truncated) "LOCALS / first 128" else if (historical) "LOCALS / last stop" else "LOCALS", if (historical) "values are stale" else if (self.registers) "thread / scroll" else if (self.watch_list) "select / W removes" else "select / W watches");
        if (view) |v| {
            if (self.registers) {
                for (v.registers, 0..) |reg, index| {
                    if (index < self.values_scroll) continue;
                    const y = 132 + @as(f32, @floatFromInt(index - self.values_scroll)) * 23;
                    if (y + 20 >= bottom - 10) break;
                    if (reg.value) |word| {
                        try formatted(r, font, right + 14, y, width - right - 28, theme.text, "{s: <7} {x:0>16}", .{ reg.name, word });
                    } else try formatted(r, font, right + 14, y, width - right - 28, theme.weak, "{s: <7} {s}", .{ reg.name, "unavailable" });
                }
            } else if (self.watch_list) {
                for (v.watchpoints, 0..) |watch, index| {
                    if (index < self.values_scroll) continue;
                    const y = 132 + @as(f32, @floatFromInt(index - self.values_scroll)) * 46;
                    if (y + 40 >= bottom - 10) break;
                    if (self.selected_watch == watch.id) try r.rect(.{ .x = right + 1, .y = y - 2, .w = width - right - 10, .h = 46 }, style.fade(theme.focus, 0.13));
                    try formatted(r, font, right + 14, y, width - right - 28, theme.warm, "#{d}  0x{x}", .{ watch.id, watch.address });
                    try formatted(r, font, right + 14, y + 21, width - right - 28, theme.text, "{s} / {d} bytes", .{ watch.kind, watch.length });
                }
                const y = 132 + @as(f32, @floatFromInt(v.watchpoints.len)) * 46;
                if (y + 40 < bottom - 10) try formatted(r, font, right + 14, y + 8, width - right - 28, theme.weak, "{d} installed / {d} data slots", .{ v.watchpoints.len, v.watch_slots orelse 0 });
            } else for (v.locals, 0..) |local, index| {
                if (index < self.values_scroll) continue;
                const y = 132 + @as(f32, @floatFromInt(index - self.values_scroll)) * 46;
                if (y + 40 >= bottom - 10) break;
                if (self.selected_value == index) try r.rect(.{ .x = right + 1, .y = y - 2, .w = width - right - 10, .h = 46 }, style.fade(theme.focus, 0.13));
                for (v.watchpoints) |watch| if (local.address == watch.address and local.size == watch.length) {
                    try style.disc(r, right + 7, y + 9, 3, theme.warm);
                    break;
                };
                try r.textFit(font, right + 14, y, width - right - 28, local.name, theme.neutral);
                try r.textFit(font, right + 14, y + 21, width - right - 28, local.display, if (std.mem.eql(u8, local.availability, "available")) theme.text else theme.weak);
            }
        }
        try pane(r, font, .{ .x = 8, .y = bottom, .w = left - 12, .h = height - bottom - 37 }, if (live_view != null and live_view.?.threads_truncated) "THREADS / first 256" else "THREADS", "click to select / scroll");
        if (live_view) |v| for (v.threads, 0..) |thread, index| {
            if (index < self.thread_scroll) continue;
            const y = bottom + 38 + @as(f32, @floatFromInt(index - self.thread_scroll)) * 23;
            if (y + 20 > height - 40) break;
            if (thread.tid == v.tid) try r.rect(.{ .x = 9, .y = y - 2, .w = left - 14, .h = 23 }, style.fade(theme.focus, 0.13));
            try formatted(r, font, 22, y, left - 38, style.threadColor(thread.id), "{d}  {s} / {s}", .{ thread.tid, thread.state, thread.reason });
        };
        try pane(r, font, .{ .x = left, .y = bottom, .w = width - left - 8, .h = height - bottom - 37 }, if (historical) "STACK / last stop" else "STACK", if (historical) "scroll" else "click to inspect frame / scroll");
        if (view) |v| for (v.frames, 0..) |frame, index| {
            if (index < self.frame_scroll) continue;
            const y = bottom + 38 + @as(f32, @floatFromInt(index - self.frame_scroll)) * 23;
            if (y + 20 > height - 40) break;
            if (index == v.frame) try r.rect(.{ .x = left + 1, .y = y - 2, .w = width - left - 10, .h = 23 }, style.fade(theme.focus, 0.13));
            try formatted(r, font, left + 14, y, width - left - 28, theme.text, "#{d} {s}  {s}:{d}", .{ index, frame.symbol orelse "[unknown]", if (frame.source) |s| std.fs.path.basename(s.path) else "", if (frame.source) |s| s.line else 0 });
        };
        r.clip = all;
        try r.rect(.{ .x = 0, .y = height - 32, .w = width, .h = 32 }, theme.header);
        const message = std.mem.sliceTo(&facts.status, 0);
        const state_text = if (facts.state == .disconnected) "DISCONNECTED / last snapshot; target state unknown" else if (facts.busy) "Pending remote request" else if (message.len != 0) message else if (!std.mem.eql(u8, self.status, "Ready") and !std.mem.eql(u8, self.status, "Connecting")) self.status else if (historical) "Showing last stop; values are stale" else if (live_view) |v| (if (v.diagnostics.len > 0) v.diagnostics[0].message else self.status) else "Connecting";
        if (view) |v| if (!historical and !facts.busy and facts.state == .ready and message.len == 0 and v.watch_hits.len > 0 and std.mem.eql(u8, self.status, "Ready")) {
            const hit = v.watch_hits[0];
            try formatted(r, font, 14, height - 25, width - 28, theme.warm, "{s} #{d}: {any} -> {any}  |  access {s}  |  0x{x}  |  V watches / W toggles selected local", .{ if (std.mem.eql(u8, hit.attribution, "candidate")) "Possible watch" else "Watch", hit.id, hit.before, hit.after, if (std.mem.eql(u8, hit.phase, "interrupted")) "interrupted" else "completed", hit.address });
            return;
        };
        try formatted(r, font, 14, height - 25, width - 28, if (facts.state == .disconnected) theme.warm else theme.text, "{s}  |  {s}  {s}  |  {s}", .{ if (live_view) |v| v.architecture else "", if (live_view) |v| v.state else "", if (live_view) |v| v.scope else "", state_text });
    }
};
fn hasCurrentSource(view: wire.View) bool {
    return view.frames.len > 0 and view.frames[0].source != null and view.frames[0].source.?.line != 0;
}
fn stepMethod(view: wire.View, button: usize) []const u8 {
    return switch (button) {
        1 => if (hasCurrentSource(view)) "step_source" else "step_instruction",
        2 => if (hasCurrentSource(view)) "step_over" else "step_over_instruction",
        3 => "step_instruction",
        else => unreachable,
    };
}
fn sourceBreakpointPath(view: wire.View) []const u8 {
    const source = view.source.?;
    if (view.frame < view.frames.len) if (view.frames[view.frame].source) |site| {
        if (sameFile(site.path, source.path)) return site.path;
    };
    // The explicitly shared file can be relocated (e.g. ./demo.c on Android).
    // Resolve its displayed basename using the server's existing DWARF lookup
    // even when the selected frame is in the loader or another source file.
    return std.fs.path.basename(source.path);
}
fn sameFile(path: []const u8, provided: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(path), std.fs.path.basename(provided));
}
fn pane(r: *gpu.Renderer, font: *Font, rect: gpu.Rect, title: []const u8, detail: []const u8) !void {
    r.clip = .{ .x = 0, .y = 0, .w = @floatFromInt(r.extent.width), .h = @floatFromInt(r.extent.height) };
    try style.box(r, rect, theme.surface, theme.border, @splat(5));
    try r.textFit(font, rect.x + 12, rect.y + 9, rect.w * 0.60, title, theme.neutral);
    try r.textFit(font, rect.x + rect.w * 0.62, rect.y + 9, rect.w * 0.36 - 8, detail, theme.weak);
    r.clip = .{ .x = rect.x + 1, .y = rect.y + 33, .w = rect.w - 2, .h = rect.h - 34 };
}
fn formatted(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime format: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch "[text too long]";
    try r.textFit(font, x, y, width, text, color);
}
pub fn run(endpoint: remote.Endpoint, label: []const u8, font_path: [:0]const u8, max_frames: u64, quitting: *volatile transport.c.sig_atomic_t, startup_started: u64) !void {
    const a = std.heap.page_allocator;
    const client = try a.create(remote.Client);
    defer a.destroy(client);
    client.* = .{ .endpoint = endpoint };
    try client.start();
    defer client.deinit();
    var window = Window{};
    try window.init();
    defer window.deinit();
    var renderer = gpu.Renderer{};
    defer renderer.deinit();
    const font = try a.create(Font);
    defer a.destroy(font);
    font.* = .{};
    try font.initSelected(font_path, @import("build_options").font_path ++ "");
    defer font.deinit();
    var workspace = Workspace{};
    defer workspace.deinit();
    var ready = false;
    var retry: u64 = 0;
    var rendered: u64 = 0;
    var last_frame: u64 = 0;
    var old_state: remote.State = .connecting;
    var old_busy = true;
    while (!window.closing and quitting.* == 0) {
        try window.pump(window.input.timeoutMs(transport.now(), 8));
        window.input.tick(transport.now());
        const changed = workspace.sync(client);
        if (changed) window.dirty = true;
        workspace.input(&window, client);
        if (window.closing) break;
        const facts = client.facts();
        if (facts.state != old_state or facts.busy != old_busy) window.dirty = true;
        old_state = facts.state;
        old_busy = facts.busy;
        const now = transport.now();
        if (now < retry or (!window.dirty and now -| last_frame < 250_000_000)) continue;
        if (!ready) {
            renderer.init(&window) catch |err| {
                std.debug.print("xodb: remote GUI renderer failed: {s}\n", .{@errorName(err)});
                retry = now + 1_000_000_000;
                continue;
            };
            ready = true;
            font.dirty = true;
        }
        const presented = drawFrame(&renderer, font, &workspace, &window, client, label) catch |err| {
            std.debug.print("xodb: remote GUI frame failed: {s}\n", .{@errorName(err)});
            renderer.deinit();
            ready = false;
            retry = now + 1_000_000_000;
            continue;
        };
        window.dirty = !presented;
        if (!presented) continue;
        if (rendered == 0) @import("../startup.zig").report(startup_started, false);
        last_frame = now;
        rendered += 1;
        if (max_frames != 0 and rendered >= max_frames) break;
    }
    std.debug.print("xodb: remote GUI closing after {d} frames; closing transport\n", .{rendered});
}
fn drawFrame(r: *gpu.Renderer, font: *Font, workspace: *Workspace, window: *Window, client: *remote.Client, label: []const u8) !bool {
    if (!try r.begin(window.width, window.height)) return false;
    try workspace.draw(r, font, window, client, label);
    return r.end(font);
}

test "remote step follows executing frame source, including loader and caller inspection" {
    var view = wire.View{ .session_id = 1, .generation = 4, .pid = 123, .architecture = "aarch64", .state = "stopped", .scope = "control", .owned = true };
    try std.testing.expectEqualStrings("step_instruction", stepMethod(view, 1));
    try std.testing.expectEqualStrings("step_over_instruction", stepMethod(view, 2));
    view.frames = &.{ .{ .index = 0, .pc = 0x1000 }, .{ .index = 1, .pc = 0x2000, .source = .{ .path = "main.c", .line = 12 } } };
    view.frame = 1;
    try std.testing.expectEqualStrings("step_instruction", stepMethod(view, 1));
    view.frames = &.{.{ .index = 0, .pc = 0x1000, .source = .{ .path = "main.c", .line = 7 } }};
    view.frame = 0;
    try std.testing.expectEqualStrings("step_source", stepMethod(view, 1));
    try std.testing.expectEqualStrings("step_over", stepMethod(view, 2));
    try std.testing.expectEqualStrings("step_instruction", stepMethod(view, 3));
}

fn testSnapshot(view: wire.View) !remote.Snapshot {
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, view, .{});
    defer std.testing.allocator.free(bytes);
    return std.json.parseFromSlice(wire.View, std.testing.allocator, bytes, .{ .allocate = .alloc_always });
}

test "remote running panes retain one stopped view while controls use current state" {
    var workspace = Workspace{};
    defer workspace.deinit();
    var view = wire.View{ .session_id = 1, .generation = 10, .pid = 100, .tid = 101, .architecture = "aarch64", .state = "stopped", .scope = "control", .owned = false, .source = .{ .path = "demo.c", .text = "value += 5;" }, .locals = &.{.{ .name = "value", .type = "int", .display = "7", .availability = "available", .address = 0x1000, .size = 4 }}, .registers = &.{.{ .name = "pc", .value = 0x2000 }}, .instructions = &.{.{ .address = 0x2000, .mnemonic = "str", .operands = "w0, [x1]" }}, .frames = &.{.{ .index = 0, .pc = 0x2000, .symbol = "demo", .source = .{ .path = "demo.c", .line = 4 } }} };
    workspace.accept(try testSnapshot(view));
    const text_pointer = workspace.displayView().?.source.?.text.ptr;
    workspace.source_scroll = 3;
    workspace.selected_value = 0;
    var running = wire.View{ .session_id = 1, .generation = 11, .pid = 100, .architecture = "aarch64", .state = "running", .scope = "control", .owned = false };
    for (11..14) |generation| {
        running.generation = generation;
        workspace.accept(try testSnapshot(running));
        try std.testing.expect(workspace.last_stop != null);
        try std.testing.expectEqual(text_pointer, workspace.displayView().?.source.?.text.ptr);
        try std.testing.expectEqualStrings("7", workspace.displayView().?.locals[0].display);
        try std.testing.expectEqual(@as(usize, 1), workspace.displayView().?.registers.len);
        try std.testing.expectEqual(@as(usize, 1), workspace.displayView().?.instructions.len);
        try std.testing.expectEqual(@as(usize, 1), workspace.displayView().?.frames.len);
        try std.testing.expectEqual(@as(usize, 3), workspace.source_scroll);
        try std.testing.expectEqual(generation, workspace.snapshot.?.value.generation);
    }
    var client = remote.Client{ .endpoint = .{ .tcp = "127.0.0.1:1" }, .state = .ready, .busy = false };
    defer client.deinit();
    workspace.invoke(&client, 1); // Old source must not enable Step.
    workspace.invoke(&client, 6); // Old local must not enable a hardware watch.
    try std.testing.expect(client.pending == null);
    workspace.invoke(&client, 0);
    const command = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, client.pending.?, .{});
    defer command.deinit();
    try std.testing.expectEqualStrings("interrupt", remote.string(remote.field(command.value, "name")));
    try std.testing.expectEqual(@as(i64, 13), remote.field(remote.field(command.value, "arguments"), "generation").integer);
    view.generation = 14;
    view.locals = &.{.{ .name = "value", .type = "int", .display = "12", .availability = "available" }};
    workspace.accept(try testSnapshot(view));
    try std.testing.expect(workspace.last_stop == null);
    try std.testing.expectEqualStrings("12", workspace.displayView().?.locals[0].display);
    workspace.accept(try testSnapshot(running));
    view.generation = 15;
    view.source = null;
    view.locals = &.{};
    workspace.accept(try testSnapshot(view)); // A real source-less stop replaces history.
    try std.testing.expect(workspace.last_stop == null);
    try std.testing.expect(workspace.displayView().?.source == null);
    try std.testing.expectEqual(@as(usize, 0), workspace.displayView().?.locals.len);
}

test "remote stopped history is released on detach, exit or target replacement" {
    const stopped = wire.View{ .session_id = 1, .generation = 1, .pid = 100, .architecture = "aarch64", .state = "stopped", .scope = "control", .owned = false };
    for (0..4) |mode| {
        var workspace = Workspace{};
        defer workspace.deinit();
        workspace.accept(try testSnapshot(stopped));
        var next = stopped;
        next.state = "running";
        next.generation = 2;
        workspace.accept(try testSnapshot(next));
        try std.testing.expect(workspace.last_stop != null);
        switch (mode) {
            0 => next.state = "idle",
            1 => next.state = "exited",
            2 => next.pid = 200,
            3 => next.session_id = 2,
            else => unreachable,
        }
        next.generation = 3;
        workspace.accept(try testSnapshot(next));
        try std.testing.expect(workspace.last_stop == null);
    }
}

test "remote continue control cancels a queued resume at a stopped target" {
    var workspace = Workspace{};
    defer workspace.deinit();
    workspace.accept(try testSnapshot(.{ .session_id = 1, .generation = 7, .pid = 100, .architecture = "x86_64", .state = "stopped", .scope = "control", .owned = true, .continue_pending = true }));
    var client = remote.Client{ .endpoint = .{ .tcp = "127.0.0.1:1" }, .state = .ready, .busy = false };
    defer client.deinit();
    workspace.invoke(&client, 0);
    const command = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, client.pending.?, .{});
    defer command.deinit();
    try std.testing.expectEqualStrings("interrupt", remote.string(remote.field(command.value, "name")));
    try std.testing.expectEqual(@as(i64, 7), remote.field(remote.field(command.value, "arguments"), "generation").integer);
}
