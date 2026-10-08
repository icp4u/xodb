//! T19 watch-list model: bounds, per-generation re-evaluation, frame identity,
//! change marking, stale-while-running without reads, and the text field.
const std = @import("std");
const watch = @import("watch.zig");
const keys = @import("../platform/input.zig");

const Fake = struct {
    running: bool = false,
    exited: bool = false,
    gen: u64 = 1,
    frames: []const watch.Frame = &.{},
    thread_alive: bool = true,
    ident: watch.Identity = .{ .session = 1, .image = 0, .thread = 1 },
    stack_available: bool = true,
    complete: bool = true,
    value: []const u8 = "1",
    extent_advisory: bool = false,
    fail: ?anyerror = null,
    calls: usize = 0,
    last_index: ?usize = null,
    pub fn stopped(self: *Fake) bool {
        return !self.running;
    }
    pub fn ended(self: *Fake) bool {
        return self.exited;
    }
    pub fn generation(self: *Fake) u64 {
        return self.gen;
    }
    pub fn identity(self: *Fake, tid: i32) ?watch.Identity {
        _ = tid;
        return if (self.thread_alive) self.ident else null;
    }
    pub fn stack(self: *Fake, tid: i32) watch.Stack {
        _ = tid;
        return if (self.stack_available) .{ .frames = .{ .items = self.frames, .complete = self.complete } } else .unavailable;
    }
    pub fn evaluate(self: *Fake, a: std.mem.Allocator, tid: i32, index: usize, text: []const u8, page: ?u64) watch.Result {
        _ = a;
        _ = tid;
        _ = text;
        _ = page;
        // Evaluation is the only path that reads target memory.
        std.debug.assert(!self.running);
        self.calls += 1;
        self.last_index = index;
        if (self.fail) |err| return .{ .failed = err };
        return .{ .value = .{ .display = self.value, .type_name = "int", .available = true, .extent_advisory = self.extent_advisory } };
    }
};
const f_main = watch.Frame{ .cfa = 0x7000, .symbol = "main", .module = 1, .function = 100, .pc = 100 };
const f_work = watch.Frame{ .cfa = 0x6f00, .symbol = "work", .module = 1, .function = 200, .pc = 200 };
const f_work_again = watch.Frame{ .cfa = 0x6e00, .symbol = "work", .module = 1, .function = 200, .pc = 200 };
const f_nocfa = watch.Frame{ .cfa = null, .symbol = "start", .module = 2, .function = 300, .pc = 300 };

test "bounds: count, length, empty text" {
    var list = watch.WatchList{};
    defer list.deinit();
    const id = watch.FrameId.of(10, 0, f_main, .{ .session = 1, .image = 0, .thread = 1 }, 1);
    for (0..watch.max_entries) |_| _ = try list.add("x", id);
    try std.testing.expectError(error.WatchListFull, list.add("y", id));
    list.remove(3);
    try std.testing.expectEqual(@as(usize, watch.max_entries - 1), list.count);
    try std.testing.expectError(error.EmptyExpression, list.add("  \t", id));
    try std.testing.expectError(error.ExpressionTooLong, list.add(&(@as([watch.max_text + 1]u8, @splat('a'))), id));
    _ = try list.add("  a->b  ", id);
    try std.testing.expectEqualStrings("a->b", list.entries[list.count - 1].expression());
}

test "evaluates once per generation; adding or expanding re-evaluates" {
    var fake = Fake{ .frames = &.{f_main} };
    var list = watch.WatchList{};
    defer list.deinit();
    _ = try list.add("i", watch.FrameId.of(10, 0, f_main, .{ .session = 1, .image = 0, .thread = 1 }, 1));
    list.refresh(&fake);
    list.refresh(&fake);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    fake.gen = 2;
    list.refresh(&fake);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    _ = try list.add("j", watch.FrameId.of(10, 0, f_main, .{ .session = 1, .image = 0, .thread = 1 }, 1));
    list.refresh(&fake);
    try std.testing.expectEqual(@as(usize, 4), fake.calls);
}

test "extent advisory remains attached to stale values and refreshes at a stop" {
    var fake = Fake{ .frames = &.{f_main}, .extent_advisory = true };
    var list = watch.WatchList{};
    defer list.deinit();
    _ = try list.add("value", watch.FrameId.of(10, 0, f_main, .{ .session = 1, .image = 0, .thread = 1 }, 1));
    list.refresh(&fake);
    try std.testing.expect(list.entries[0].available and list.entries[0].extent_advisory);
    fake.running = true;
    fake.extent_advisory = false;
    list.refresh(&fake);
    try std.testing.expect(list.entries[0].extent_advisory);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    fake.running = false;
    fake.gen += 1;
    list.refresh(&fake);
    try std.testing.expect(list.entries[0].available and !list.entries[0].extent_advisory);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "frame identity: follows the activation, never the index" {
    var fake = Fake{ .frames = &.{ f_work, f_main } };
    var list = watch.WatchList{};
    defer list.deinit();
    _ = try list.add("n", watch.FrameId.of(10, 1, f_main, .{ .session = 1, .image = 0, .thread = 1 }, 1));
    list.refresh(&fake);
    try std.testing.expectEqual(@as(?usize, 1), fake.last_index);
    // A call made from main: main is now frame 2, still the same activation.
    fake.gen = 2;
    fake.frames = &.{ f_work_again, f_work, f_main };
    list.refresh(&fake);
    try std.testing.expectEqual(@as(?usize, 2), fake.last_index);
    try std.testing.expectEqual(watch.State.value, list.entries[0].state);
    // A different activation of work at the same index is not the frame.
    _ = try list.add("k", watch.FrameId.of(10, 1, f_work, .{ .session = 1, .image = 0, .thread = 1 }, 1));
    list.refresh(&fake);
    try std.testing.expectEqual(@as(?usize, 1), fake.last_index);
    fake.gen = 3;
    fake.frames = &.{ f_work_again, f_main };
    const before = fake.calls;
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.frame_gone, list.entries[1].state);
    try std.testing.expectEqual(before + 1, fake.calls); // only main's entry
    try std.testing.expect(list.entries[1].has_value); // "last seen" stays labelled
}

test "frames without a CFA are usable only at their original stop" {
    var fake = Fake{ .frames = &.{ f_work, f_nocfa } };
    var list = watch.WatchList{};
    defer list.deinit();
    _ = try list.add("argc", watch.FrameId.of(10, 1, f_nocfa, .{ .session = 1, .image = 0, .thread = 1 }, 1));
    list.refresh(&fake);
    try std.testing.expect(!list.entries[0].unverified);
    try std.testing.expectEqual(watch.State.value, list.entries[0].state);
    fake.gen = 2;
    fake.frames = &.{ f_work_again, f_work, f_nocfa };
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.context_changed, list.entries[0].state);
}

test "changes are marked against the previous stop only" {
    var fake = Fake{ .frames = &.{f_main} };
    var list = watch.WatchList{};
    defer list.deinit();
    _ = try list.add("i", watch.FrameId.of(10, 0, f_main, .{ .session = 1, .image = 0, .thread = 1 }, 1));
    list.refresh(&fake);
    try std.testing.expect(!list.entries[0].changed);
    fake.gen = 2;
    fake.value = "2";
    list.refresh(&fake);
    try std.testing.expect(list.entries[0].changed);
    // Same stop, re-evaluated (e.g. expand): still marked.
    list.dirty = true;
    list.refresh(&fake);
    try std.testing.expect(list.entries[0].changed);
    fake.gen = 3;
    list.refresh(&fake);
    try std.testing.expect(!list.entries[0].changed);
    // A failure is not a change, and the next value is not compared with it.
    fake.gen = 4;
    fake.fail = error.UnknownVariable;
    list.refresh(&fake);
    try std.testing.expect(!list.entries[0].changed);
    try std.testing.expectEqualStrings("unknown name here", watch.explain(list.entries[0].failure.?));
    fake.gen = 5;
    fake.fail = null;
    fake.value = "9";
    list.refresh(&fake);
    try std.testing.expect(!list.entries[0].changed);
}

test "running: stale, last value kept, nothing evaluated; thread gone is explicit" {
    var fake = Fake{ .frames = &.{f_main} };
    var list = watch.WatchList{};
    defer list.deinit();
    _ = try list.add("i", watch.FrameId.of(10, 0, f_main, .{ .session = 1, .image = 0, .thread = 1 }, 1));
    list.refresh(&fake);
    fake.running = true;
    fake.gen = 2;
    list.refresh(&fake);
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.stale, list.entries[0].state);
    try std.testing.expectEqualStrings("1", list.entries[0].display.slice());
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    fake.running = false;
    fake.thread_alive = false;
    fake.gen = 3;
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.thread_gone, list.entries[0].state);
    // An older observation stays labelled as such while running.
    fake.running = true;
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.thread_gone, list.entries[0].state);
}

fn press(shortcut: u32, text: []const u8, ctrl: bool) keys.Event {
    var event = keys.Event{ .kind = .press, .shortcut = shortcut };
    event.mods.ctrl = ctrl;
    @memcpy(event.text_bytes[0..text.len], text);
    event.text_len = @intCast(text.len);
    return event;
}

test "editor: typing, editing keys, history and cancel" {
    var editor = watch.Editor{};
    try std.testing.expect(editor.key(press('a', "a", false)) == null); // closed
    editor.start();
    for ("p->x") |ch| _ = editor.key(press(ch, &.{ch}, false));
    _ = editor.key(press(0xff08, "", false));
    try std.testing.expectEqualStrings("p->", editor.text.slice());
    _ = editor.key(press('y', "y", false));
    // A chord is consumed without typing or reaching workspace shortcuts.
    try std.testing.expect(editor.key(press('q', "", true)).? == .edited);
    const submitted = editor.key(press(0xff0d, "", false)).?;
    try std.testing.expectEqualStrings("p->y", submitted.submit);
    editor.start();
    _ = editor.key(press('z', "z", false));
    _ = editor.key(press('u', "", true)); // Ctrl-U clears
    try std.testing.expectEqual(@as(usize, 0), editor.text.len);
    _ = editor.key(press(0xff0d, "", false)); // empty: no submit
    try std.testing.expect(editor.open);
    for ("i + 1") |ch| _ = editor.key(press(ch, &.{ch}, false));
    _ = editor.key(press(0xff0d, "", false));
    editor.start();
    _ = editor.key(press(keys.sym.up, "", false));
    try std.testing.expectEqualStrings("i + 1", editor.text.slice());
    _ = editor.key(press(keys.sym.up, "", false));
    try std.testing.expectEqualStrings("p->y", editor.text.slice());
    _ = editor.key(press(keys.sym.down, "", false));
    try std.testing.expectEqualStrings("i + 1", editor.text.slice());
    _ = editor.key(press(keys.sym.down, "", false));
    try std.testing.expectEqual(@as(usize, 0), editor.text.len);
    // F8 (agent) and F10 (step) are not the field's.
    try std.testing.expect(editor.key(press(0xffc5, "", false)) == null);
    try std.testing.expect(editor.key(press(0xffc7, "", false)) == null);
    _ = editor.key(press(' ', " ", false)); // Space is text here, not Continue
    try std.testing.expectEqualStrings(" ", editor.text.slice());
    try std.testing.expect(editor.key(press(keys.sym.escape, "", false)).? == .cancel);
    try std.testing.expect(!editor.open);
}

test "a gone frame never resurrects when its CFA and function are reused" {
    var fake = Fake{ .frames = &.{f_work} };
    var list = watch.WatchList{};
    defer list.deinit();
    _ = try list.add("n", watch.FrameId.of(10, 0, f_work, fake.ident, fake.gen));
    list.refresh(&fake);
    fake.gen += 1;
    fake.frames = &.{f_main};
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.frame_gone, list.entries[0].state);
    fake.gen += 1;
    fake.frames = &.{f_work};
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.frame_gone, list.entries[0].state);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(list.entries[0].resolved_index == null);
}

test "thread reuse, exec and session changes invalidate matching addresses" {
    for (0..3) |kind| {
        var fake = Fake{ .frames = &.{f_work} };
        var list = watch.WatchList{};
        defer list.deinit();
        _ = try list.add("n", watch.FrameId.of(10, 0, f_work, fake.ident, fake.gen));
        list.refresh(&fake);
        switch (kind) {
            0 => fake.ident.thread += 1,
            1 => fake.ident.image += 1,
            else => fake.ident.session += 1,
        }
        fake.gen += 1;
        list.refresh(&fake);
        try std.testing.expectEqual(watch.State.context_changed, list.entries[0].state);
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
    }
}

test "incomplete or failed unwind is unavailable, not evidence of a dead frame" {
    var fake = Fake{ .frames = &.{f_work} };
    var list = watch.WatchList{};
    defer list.deinit();
    _ = try list.add("n", watch.FrameId.of(10, 0, f_work, fake.ident, fake.gen));
    list.refresh(&fake);
    fake.gen += 1;
    fake.stack_available = false;
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.stack_unavailable, list.entries[0].state);
    fake.gen += 1;
    fake.stack_available = true;
    fake.complete = false;
    fake.frames = &.{f_main};
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.stack_unavailable, list.entries[0].state);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    fake.gen += 1;
    fake.frames = &.{f_work};
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.value, list.entries[0].state);
    try std.testing.expect(list.entries[0].unverified);
}

test "change after truncated display prefix is still marked" {
    var fake = Fake{ .frames = &.{f_work} };
    var list = watch.WatchList{};
    defer list.deinit();
    var text = [_]u8{'a'} ** 200;
    fake.value = &text;
    _ = try list.add("n", watch.FrameId.of(10, 0, f_work, fake.ident, fake.gen));
    list.refresh(&fake);
    text[199] = 'b';
    fake.gen += 1;
    list.refresh(&fake);
    try std.testing.expect(list.entries[0].changed);
}

test "exit does not leave live watches labelled running or read the target" {
    var fake = Fake{ .frames = &.{f_work} };
    var list = watch.WatchList{};
    defer list.deinit();
    _ = try list.add("n", watch.FrameId.of(10, 0, f_work, fake.ident, fake.gen));
    list.refresh(&fake);
    fake.exited = true;
    fake.running = true;
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.thread_gone, list.entries[0].state);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "live displays follow selected frames, retain scope failures and never evaluate while running" {
    var fake = Fake{ .frames = &.{ f_work, f_main } };
    var list = watch.WatchList{};
    defer list.deinit();
    const id = watch.FrameId.of(10, 0, f_work, fake.ident, fake.gen);
    _ = try list.addMode("val", id, .live);
    _ = try list.add("pinned", id);
    list.setDisplayFrame(.{ .tid = 10, .index = 0 });
    list.refresh(&fake);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    list.refresh(&fake);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    list.setDisplayFrame(.{ .tid = 10, .index = 1 });
    list.refresh(&fake);
    try std.testing.expectEqual(@as(?usize, 1), list.entries[0].resolved_index);
    try std.testing.expectEqual(@as(?usize, 0), list.entries[1].resolved_index);
    fake.running = true;
    const calls = fake.calls;
    list.refresh(&fake);
    try std.testing.expectEqual(calls, fake.calls);
    try std.testing.expectEqual(watch.State.stale, list.entries[0].state);
    fake.running = false;
    fake.gen += 1;
    fake.frames = &.{f_main};
    fake.fail = error.UnknownVariable;
    const unknown = try list.addMode("never_seen", id, .live);
    list.setDisplayFrame(.{ .tid = 10, .index = 0 });
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.not_in_scope, list.entries[0].state);
    try std.testing.expectEqual(watch.State.failed, list.entries[unknown].state);
    try std.testing.expectEqual(error.UnknownVariable, list.entries[unknown].failure.?);
    fake.gen += 1;
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.not_in_scope, list.entries[0].state);
    try std.testing.expectEqual(watch.State.failed, list.entries[unknown].state);
    try std.testing.expect(!list.entries[0].has_value);
    try std.testing.expectEqualStrings("", list.entries[0].display.slice());
    try std.testing.expectEqual(watch.State.frame_gone, list.entries[1].state);
    fake.gen += 1;
    fake.fail = null;
    fake.frames = &.{f_work_again};
    fake.value = "undef";
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.value, list.entries[0].state);
    try std.testing.expectEqualStrings("undef", list.entries[0].display.slice());
    try std.testing.expectEqual(watch.State.frame_gone, list.entries[1].state);
    const current = watch.FrameId.of(10, 0, f_work_again, fake.ident, fake.gen);
    list.toggleMode(0, current);
    list.refresh(&fake);
    try std.testing.expectEqual(watch.Mode.pinned, list.entries[0].mode);
    fake.gen += 1;
    fake.frames = &.{f_main};
    list.refresh(&fake);
    try std.testing.expectEqual(watch.State.frame_gone, list.entries[0].state);
    list.toggleMode(0, watch.FrameId.of(10, 0, f_main, fake.ident, fake.gen));
    list.refresh(&fake);
    try std.testing.expectEqual(watch.Mode.live, list.entries[0].mode);
    try std.testing.expectEqual(watch.State.value, list.entries[0].state);
}

test "editor paste replaces selection without submitting and respects UTF-8 boundaries" {
    var editor = watch.Editor{};
    editor.start();
    const epoch = editor.epoch;
    editor.insert("aéλz", false);
    _ = editor.key(press(0xff51, "", false));
    _ = editor.key(press(0xff08, "", false));
    try std.testing.expectEqualStrings("aéz", editor.text.slice());
    var left = press(0xff51, "", false);
    left.mods.shift = true;
    _ = editor.key(left);
    try std.testing.expectEqualStrings("é", editor.selectedText());
    editor.insert("\r\n\x1b", false);
    try std.testing.expectEqualStrings("aéz", editor.text.slice());
    editor.insert("nv\n", false);
    try std.testing.expectEqualStrings("anvz", editor.text.slice());
    try std.testing.expect(editor.open);
    _ = editor.key(press(0xffff, "", false));
    try std.testing.expectEqualStrings("anv", editor.text.slice());
    editor.start();
    try std.testing.expect(editor.epoch != epoch);
    editor.limit = 3;
    editor.insert("éλ", false);
    try std.testing.expectEqualStrings("é", editor.text.slice());
    try std.testing.expect(std.mem.indexOf(u8, editor.message, "truncated") != null);
    editor.start();
    editor.digits_only = true;
    editor.limit = 4;
    editor.insert("12\nabc34\x005", false);
    try std.testing.expectEqualStrings("1234", editor.text.slice());
    try std.testing.expect(editor.open);
}

test "pasted format characters cannot hide text or erase a selection" {
    var editor = watch.Editor{};
    editor.start();
    editor.insert("é\u{ad}\u{61c}\u{200b}\u{202e}\u{2066}\u{feff}\u{e0061}λ", false);
    try std.testing.expectEqualStrings("éλ", editor.text.slice());
    try std.testing.expect(editor.message.len > 0);
    var left = press(0xff51, "", false);
    left.mods.shift = true;
    _ = editor.key(left);
    try std.testing.expectEqualStrings("λ", editor.selectedText());
    editor.insert("\u{202a}\u{2069}", false);
    try std.testing.expectEqualStrings("éλ", editor.text.slice());
    try std.testing.expectEqualStrings("λ", editor.selectedText());
    try std.testing.expect(editor.open);
}
