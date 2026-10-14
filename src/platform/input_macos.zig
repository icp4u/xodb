//! Ordered input fed by events AppKit has already translated. AppKit owns the
//! keyboard layout, committed text, dead-key handling and repeat scheduling;
//! this module preserves xodb's platform-neutral event and held-key contract.
const std = @import("std");
const log = @import("../log.zig");
const shared = @import("input.zig");
const Event = shared.Event;
const Mods = shared.Mods;

pub const Keyboard = struct {
    queue: [shared.capacity]Event = undefined,
    head: usize = 0,
    count: usize = 0,
    dropped: u64 = 0,
    keymap_errors: u64 = 0,
    focused: bool = false,
    focus_revision: u64 = 0,
    trace: bool = false,
    current: Mods = .{},
    held: std.StaticBitSet(768) = .initEmpty(),
    held_shortcut: [768]u32 = @splat(0),

    pub fn init() Keyboard {
        return .{};
    }
    pub fn deinit(_: *Keyboard) void {}
    pub fn mods(self: *const Keyboard) Mods {
        return self.current;
    }
    pub fn heldShortcut(self: *const Keyboard, shortcut: u32) bool {
        if (!self.focused) return false;
        var it = self.held.iterator(.{});
        while (it.next()) |code| if (self.held_shortcut[code] == shortcut) return true;
        return false;
    }
    pub fn focus(self: *Keyboard, focused: bool) void {
        if (self.focused == focused) return;
        self.focused = focused;
        self.focus_revision +%= 1;
        self.current = .{};
        self.held = .initEmpty();
    }
    pub fn translated(self: *Keyboard, event: Event) void {
        self.current = event.mods;
        if (event.code < self.held.capacity() and event.kind != .repeat) {
            self.held.setValue(event.code, event.kind == .press and self.focused);
            self.held_shortcut[event.code] = event.shortcut;
        }
        self.push(event);
    }
    pub fn button(self: *Keyboard, time_ms: u32, code: u32, pressed: bool, x: f32, y: f32) void {
        self.push(.{ .kind = if (pressed) .button_press else .button_release, .time_ms = time_ms, .code = code, .mods = self.current, .x = x, .y = y });
    }
    pub fn tick(_: *Keyboard, _: u64) void {}
    pub fn timeoutMs(_: *const Keyboard, _: u64, idle_ms: i32) i32 {
        return idle_ms;
    }
    pub fn next(self: *Keyboard) ?Event {
        if (self.count == 0) return null;
        const event = self.queue[self.head];
        self.head = (self.head + 1) % shared.capacity;
        self.count -= 1;
        return event;
    }
    fn push(self: *Keyboard, event: Event) void {
        if (self.trace) log.info(.window, "input {s} code={d} sym=0x{x} shortcut=0x{x} text=\"{s}\" t={d}\n", .{ @tagName(event.kind), event.code, event.sym, event.shortcut, event.text(), event.time_ms });
        if (self.count == shared.capacity) {
            self.dropped += 1;
            return;
        }
        self.queue[(self.head + self.count) % shared.capacity] = event;
        self.count += 1;
    }
};

test "translated input preserves focus, held shortcuts, order and overflow" {
    var keyboard = Keyboard.init();
    keyboard.focus(true);
    try std.testing.expect(keyboard.focused and keyboard.focus_revision == 1);
    keyboard.translated(.{ .kind = .press, .code = 12, .sym = 'Q', .shortcut = 'q', .mods = .{ .super = true } });
    try std.testing.expect(keyboard.heldShortcut('q'));
    try std.testing.expect(keyboard.mods().super);
    keyboard.translated(.{ .kind = .repeat, .code = 12, .sym = 'Q', .shortcut = 'q', .mods = .{ .super = true } });
    keyboard.translated(.{ .kind = .release, .code = 12, .sym = 'q', .shortcut = 'q' });
    try std.testing.expect(!keyboard.heldShortcut('q'));
    try std.testing.expectEqual(shared.Kind.press, keyboard.next().?.kind);
    try std.testing.expectEqual(shared.Kind.repeat, keyboard.next().?.kind);
    try std.testing.expectEqual(shared.Kind.release, keyboard.next().?.kind);
    for (0..shared.capacity + 2) |_| keyboard.button(0, 272, true, 1, 2);
    try std.testing.expectEqual(@as(u64, 2), keyboard.dropped);
    keyboard.focus(false);
    try std.testing.expect(!keyboard.focused and keyboard.focus_revision == 2);
}
