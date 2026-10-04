//! Keyboard input adapter: turns wl_keyboard events into an ordered queue of
//! key events, using libxkbcommon for the compositor's keymap.
//!
//! The adapter knows nothing about Wayland objects. The Wayland listeners pass
//! it plain values (`keymap`, `enter`, `leave`, `key`, `modifiers`,
//! `repeatInfo`, `seatRemoved`, and `button` for pointer buttons), the main loop
//! calls `tick` with a monotonic time, and the application drains `next`.
//! Everything runs on the thread that dispatches the display.
//!
//! Each event keeps four things apart:
//!   code      the physical key (evdev code), independent of layout
//!   sym       the keysym the layout and modifiers produce now
//!   shortcut  the key's logical identity for bindings: its unshifted keysym,
//!             from the active layout only (see `shortcutSym`)
//!   text      committed UTF-8 text, after dead keys and compose sequences;
//!             empty while composing and when Ctrl, Alt, or Logo is held
//!
//! API reference: libxkbcommon's xkbcommon.h and xkbcommon-compose.h (MIT),
//! and the wl_keyboard interface in wayland.xml. No code was copied.

const std = @import("std");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("sys/mman.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-compose.h");
    @cInclude("malloc.h"); // mallinfo2 and stdio are used only by the leak test
    @cInclude("stdio.h");
});

pub const capacity = 64;
pub const Mods = packed struct(u8) { shift: bool = false, ctrl: bool = false, alt: bool = false, logo: bool = false, caps: bool = false, num: bool = false, _: u2 = 0 };
pub const Kind = enum { press, release, repeat, button_press, button_release };
pub const Event = struct {
    kind: Kind,
    /// Compositor timestamp in milliseconds; for a repeat, the press time plus elapsed time.
    time_ms: u32 = 0,
    /// evdev key code, or the button code for pointer events.
    code: u32 = 0,
    sym: u32 = 0,
    shortcut: u32 = 0,
    text_bytes: [16]u8 = @splat(0),
    text_len: u8 = 0,
    mods: Mods = .{},
    /// Pointer position for button events.
    x: f32 = 0,
    y: f32 = 0,

    pub fn text(self: *const Event) []const u8 {
        return self.text_bytes[0..self.text_len];
    }
    /// True for a binding that should fire: no Ctrl, Alt, or Logo held.
    pub fn plain(self: Event) bool {
        return !self.mods.ctrl and !self.mods.alt and !self.mods.logo;
    }
};

// Keysyms used here; values from xkbcommon-keysyms.h.
pub const sym = struct {
    pub const space = 0x20;
    pub const tab = 0xff09;
    pub const escape = 0xff1b;
    pub const up = 0xff52;
    pub const down = 0xff54;
    pub const f1 = 0xffbe;
    pub const f5 = f1 + 4;
    pub const f6 = f1 + 5;
    pub const f8 = f1 + 7;
    pub const f10 = f1 + 9;
    pub const f11 = f1 + 10;
};

pub const Keyboard = struct {
    context: ?*c.xkb_context = null,
    xkb_keymap: ?*c.xkb_keymap = null,
    state: ?*c.xkb_state = null,
    compose_table: ?*c.xkb_compose_table = null,
    compose: ?*c.xkb_compose_state = null,
    mod_index: [6]u32 = @splat(c.XKB_MOD_INVALID),

    queue: [capacity]Event = undefined,
    head: usize = 0,
    count: usize = 0,
    /// Events discarded because the queue was full. The newest event is the one dropped.
    dropped: u64 = 0,
    /// Keymaps the compositor sent that could not be used.
    keymap_errors: u64 = 0,

    focused: bool = false,
    repeat_rate: i32 = 0,
    repeat_delay_ms: i32 = 0,
    repeat_code: ?u32 = null,
    repeat_next_ns: u64 = 0,
    repeat_time_ms: u32 = 0,
    repeat_from_ns: u64 = 0,
    /// When set, every queued event is also printed to stderr.
    trace: bool = false,

    /// `locale` selects the compose table (for example "en_US.UTF-8"); null uses
    /// LC_ALL, LC_CTYPE, or LANG, then "C". A missing table only disables composing.
    pub fn init(locale: ?[*:0]const u8) Keyboard {
        var self = Keyboard{};
        self.context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        const context = self.context orelse return self;
        const name: [*:0]const u8 = locale orelse blk: {
            for ([_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |variable| {
                if (std.c.getenv(variable)) |value| if (value[0] != 0) break :blk value;
            }
            break :blk "C";
        };
        self.compose_table = c.xkb_compose_table_new_from_locale(context, name, c.XKB_COMPOSE_COMPILE_NO_FLAGS);
        return self;
    }
    pub fn deinit(self: *Keyboard) void {
        self.dropKeymap();
        if (self.compose_table) |table| c.xkb_compose_table_unref(table);
        if (self.context) |context| c.xkb_context_unref(context);
        self.* = .{};
    }

    fn dropKeymap(self: *Keyboard) void {
        if (self.compose) |state| c.xkb_compose_state_unref(state);
        if (self.state) |state| c.xkb_state_unref(state);
        if (self.xkb_keymap) |map| c.xkb_keymap_unref(map);
        self.compose = null;
        self.state = null;
        self.xkb_keymap = null;
        self.repeat_code = null;
    }

    /// wl_keyboard.keymap. Takes ownership of `fd` and closes it on every path.
    /// A keymap that cannot be used leaves the keyboard without one: events then
    /// carry only the physical code, and `keymap_errors` counts the failure.
    pub fn keymap(self: *Keyboard, format: u32, fd: i32, size: u32) void {
        defer if (fd >= 0) {
            _ = c.close(fd);
        };
        self.dropKeymap();
        if (format != c.XKB_KEYMAP_FORMAT_TEXT_V1) return; // "no keymap": physical codes only
        const context = self.context orelse return self.failKeymap();
        if (fd < 0 or size == 0) return self.failKeymap();
        // wl_keyboard version 7 and later require a private mapping.
        const mapped = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
        if (mapped == c.MAP_FAILED) return self.failKeymap();
        defer _ = c.munmap(mapped, size);
        const bytes: [*]const u8 = @ptrCast(mapped.?);
        const length = std.mem.indexOfScalar(u8, bytes[0..size], 0) orelse size;
        const map = c.xkb_keymap_new_from_buffer(context, bytes, length, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return self.failKeymap();
        const state = c.xkb_state_new(map) orelse {
            c.xkb_keymap_unref(map);
            return self.failKeymap();
        };
        self.xkb_keymap = map;
        self.state = state;
        if (self.compose_table) |table| self.compose = c.xkb_compose_state_new(table, c.XKB_COMPOSE_STATE_NO_FLAGS);
        for (&self.mod_index, [_][*:0]const u8{ c.XKB_MOD_NAME_SHIFT, c.XKB_MOD_NAME_CTRL, c.XKB_MOD_NAME_ALT, c.XKB_MOD_NAME_LOGO, c.XKB_MOD_NAME_CAPS, c.XKB_MOD_NAME_NUM }) |*index, name| index.* = c.xkb_keymap_mod_get_index(map, name);
    }
    fn failKeymap(self: *Keyboard) void {
        self.keymap_errors += 1;
    }

    pub fn enter(self: *Keyboard) void {
        self.focused = true;
    }
    /// wl_keyboard.leave: no key is held from the application's point of view.
    pub fn leave(self: *Keyboard) void {
        self.focused = false;
        self.repeat_code = null;
        if (self.state) |state| _ = c.xkb_state_update_mask(state, 0, 0, 0, 0, 0, 0);
        if (self.compose) |state| c.xkb_compose_state_reset(state);
    }
    /// The seat lost its keyboard: release the keymap and forget all key state.
    pub fn seatRemoved(self: *Keyboard) void {
        self.dropKeymap();
        self.focused = false;
        self.repeat_rate = 0;
        self.repeat_delay_ms = 0;
    }
    pub fn modifiers(self: *Keyboard, depressed: u32, latched: u32, locked: u32, group: u32) void {
        if (self.state) |state| _ = c.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
    }
    /// wl_keyboard.repeat_info: `rate` in keys per second (0 disables repeat), `delay_ms` before the first repeat.
    pub fn repeatInfo(self: *Keyboard, rate: i32, delay_ms: i32) void {
        self.repeat_rate = rate;
        self.repeat_delay_ms = delay_ms;
        if (rate <= 0) self.repeat_code = null;
    }

    pub fn mods(self: *const Keyboard) Mods {
        const state = self.state orelse return .{};
        var active: [6]bool = undefined;
        for (&active, self.mod_index) |*on, index| on.* = index != c.XKB_MOD_INVALID and c.xkb_state_mod_index_is_active(state, index, c.XKB_STATE_MODS_EFFECTIVE) > 0;
        return .{ .shift = active[0], .ctrl = active[1], .alt = active[2], .logo = active[3], .caps = active[4], .num = active[5] };
    }

    /// Only the unshifted keysym in the active layout can identify a shortcut.
    /// ASCII and function/editing/keypad keysyms are accepted; letters are lower
    /// case. Other layouts and physical positions are deliberately not consulted.
    pub fn shortcutSym(self: *const Keyboard, code: u32) u32 {
        const map = self.xkb_keymap orelse return 0;
        const state = self.state orelse return 0;
        const keycode = code + 8;
        const active = c.xkb_state_key_get_layout(state, keycode);
        if (active == c.XKB_LAYOUT_INVALID) return 0;
        var syms: [*c]const c.xkb_keysym_t = null;
        if (c.xkb_keymap_key_get_syms_by_level(map, keycode, active, 0, &syms) != 1) return 0;
        const lower = c.xkb_keysym_to_lower(syms[0]);
        if ((lower >= 0x20 and lower < 0x7f) or (lower >= 0xff00 and lower <= 0xffff)) return lower;
        return 0;
    }

    fn translate(self: *Keyboard, event: *Event, feed_compose: bool) void {
        event.mods = self.mods();
        event.shortcut = self.shortcutSym(event.code);
        const state = self.state orelse return;
        const keycode = event.code + 8;
        event.sym = c.xkb_state_key_get_one_sym(state, keycode);
        if (!feed_compose) return;
        // A shortcut chord must not finish an earlier dead-key sequence and
        // leak committed text. Cancel composition when such a chord arrives.
        if (!event.plain()) {
            if (self.compose) |compose| c.xkb_compose_state_reset(compose);
            return;
        }
        var buffer: [event.text_bytes.len + 1]u8 = @splat(0);
        var length: c_int = 0;
        var status: c.enum_xkb_compose_status = c.XKB_COMPOSE_NOTHING;
        if (self.compose) |compose| {
            if (c.xkb_compose_state_feed(compose, event.sym) == c.XKB_COMPOSE_FEED_ACCEPTED) status = c.xkb_compose_state_get_status(compose);
        }
        switch (status) {
            c.XKB_COMPOSE_COMPOSING => return,
            c.XKB_COMPOSE_CANCELLED => {
                c.xkb_compose_state_reset(self.compose.?);
                return;
            },
            c.XKB_COMPOSE_COMPOSED => {
                length = c.xkb_compose_state_get_utf8(self.compose.?, &buffer, buffer.len);
                event.sym = c.xkb_compose_state_get_one_sym(self.compose.?);
                c.xkb_compose_state_reset(self.compose.?);
            },
            else => {
                length = c.xkb_state_key_get_utf8(state, keycode, &buffer, buffer.len);
            },
        }
        if (length <= 0 or length > event.text_bytes.len) return;
        if (buffer[0] < 0x20 or buffer[0] == 0x7f) return; // Enter, Tab, Backspace and the like are keys, not text
        @memcpy(event.text_bytes[0..@intCast(length)], buffer[0..@intCast(length)]);
        event.text_len = @intCast(length);
    }

    fn push(self: *Keyboard, event: Event) void {
        if (self.trace) {
            var name: [64]u8 = @splat(0);
            _ = c.xkb_keysym_get_name(event.shortcut, &name, name.len);
            std.debug.print("input {s} code={d} sym=0x{x} shortcut={s} text=\"{s}\" mods={s}{s}{s}{s} t={d}\n", .{ @tagName(event.kind), event.code, event.sym, std.mem.sliceTo(&name, 0), event.text(), if (event.mods.shift) "S" else "", if (event.mods.ctrl) "C" else "", if (event.mods.alt) "A" else "", if (event.mods.logo) "L" else "", event.time_ms });
        }
        if (self.count == capacity) {
            self.dropped += 1;
            return;
        }
        self.queue[(self.head + self.count) % capacity] = event;
        self.count += 1;
    }

    /// wl_keyboard.key. `now_ns` is the monotonic clock that `tick` will be called with.
    pub fn key(self: *Keyboard, time_ms: u32, code: u32, pressed: bool, now_ns: u64) void {
        var event = Event{ .kind = if (pressed) .press else .release, .time_ms = time_ms, .code = code };
        self.translate(&event, pressed);
        self.push(event);
        if (!pressed) {
            if (self.repeat_code == code) self.repeat_code = null;
            return;
        }
        // The newest key that the keymap says repeats takes over; modifiers do not repeat.
        const map = self.xkb_keymap orelse return;
        if (self.repeat_rate <= 0 or c.xkb_keymap_key_repeats(map, code + 8) == 0) return;
        self.repeat_code = code;
        self.repeat_time_ms = time_ms;
        self.repeat_from_ns = now_ns;
        self.repeat_next_ns = now_ns + @as(u64, @intCast(@max(0, self.repeat_delay_ms))) * 1_000_000;
    }

    /// Pointer buttons share the queue so clicks and keys keep their order and a
    /// press and release in one dispatch are both seen.
    pub fn button(self: *Keyboard, time_ms: u32, code: u32, pressed: bool, x: f32, y: f32) void {
        self.push(.{ .kind = if (pressed) .button_press else .button_release, .time_ms = time_ms, .code = code, .mods = self.mods(), .x = x, .y = y });
    }

    /// Queues at most one repeat per call. If the caller was away for longer
    /// than one interval, the schedule restarts from `now_ns` instead of
    /// delivering the missed repeats in a burst.
    pub fn tick(self: *Keyboard, now_ns: u64) void {
        const code = self.repeat_code orelse return;
        if (now_ns < self.repeat_next_ns) return;
        const interval: u64 = @divTrunc(1_000_000_000, @as(u64, @intCast(self.repeat_rate)));
        var event = Event{ .kind = .repeat, .code = code, .time_ms = self.repeat_time_ms +% @as(u32, @truncate((now_ns - self.repeat_from_ns) / 1_000_000)) };
        self.translate(&event, true);
        self.push(event);
        self.repeat_next_ns = if (now_ns - self.repeat_next_ns > interval) now_ns + interval else self.repeat_next_ns + interval;
    }
    /// Poll timeout: `idle_ms`, shortened so the next repeat is not late.
    pub fn timeoutMs(self: *const Keyboard, now_ns: u64, idle_ms: i32) i32 {
        if (self.repeat_code == null) return idle_ms;
        if (now_ns >= self.repeat_next_ns) return 0;
        return @intCast(@min(@as(u64, @intCast(idle_ms)), (self.repeat_next_ns - now_ns + 999_999) / 1_000_000));
    }

    pub fn next(self: *Keyboard) ?Event {
        if (self.count == 0) return null;
        const event = self.queue[self.head];
        self.head = (self.head + 1) % capacity;
        self.count -= 1;
        return event;
    }
};

// Tests. Build keymaps with libxkbcommon from the installed layouts and hand
// them over through a memfd, the way a compositor does. Run with:
//   zig test src/platform/input.zig -lc -lxkbcommon

const testing = std.testing;
const KEY = struct {
    const @"1" = 2;
    const equal = 13;
    const q = 16;
    const w = 17;
    const e = 18;
    const y = 21;
    const a = 30;
    const j = 36;
    const semicolon = 39;
    const leftshift = 42;
    const space = 57;
    const f5 = 63;
};
const ms = 1_000_000;

/// A keymap as the compositor would send it: an fd and the size including the terminator.
fn makeKeymap(layout: [*:0]const u8, variant: ?[*:0]const u8) struct { fd: i32, size: u32 } {
    const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS).?;
    defer c.xkb_context_unref(context);
    var names = std.mem.zeroes(c.xkb_rule_names);
    names.layout = layout;
    names.variant = variant;
    const map = c.xkb_keymap_new_from_names(context, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS).?;
    defer c.xkb_keymap_unref(map);
    const string = c.xkb_keymap_get_as_string(map, c.XKB_KEYMAP_FORMAT_TEXT_V1).?;
    defer std.c.free(string);
    const size = std.mem.len(string) + 1;
    const fd = c.memfd_create("xodb-test-keymap", 0);
    std.debug.assert(fd >= 0 and c.write(fd, string, size) == @as(isize, @intCast(size)));
    return .{ .fd = fd, .size = @intCast(size) };
}
fn keyboard(layout: [*:0]const u8) Keyboard {
    var k = Keyboard.init("en_US.UTF-8");
    const map = makeKeymap(layout, null);
    k.keymap(c.XKB_KEYMAP_FORMAT_TEXT_V1, map.fd, map.size);
    k.enter();
    return k;
}
fn tap(k: *Keyboard, code: u32) Event {
    k.key(0, code, true, 0);
    const event = k.next().?;
    k.key(0, code, false, 0);
    _ = k.next().?;
    return event;
}
fn fdOpen(fd: i32) bool {
    return std.c.fcntl(fd, std.c.F.GETFD) != -1;
}
fn openFds() usize {
    var n: usize = 0;
    var fd: i32 = 0;
    while (fd < 256) : (fd += 1) n += @intFromBool(fdOpen(fd));
    return n;
}
/// Number of mappings in this process; a keymap mapping that is not released stays in the list.
fn mappings() usize {
    const file = c.fopen("/proc/self/maps", "r").?;
    defer _ = c.fclose(file);
    var buffer: [4096]u8 = undefined;
    var lines: usize = 0;
    while (true) {
        const n = c.fread(&buffer, 1, buffer.len, file);
        if (n == 0) return lines;
        lines += std.mem.count(u8, buffer[0..n], "\n");
    }
}
/// Sets Shift or Control the way a compositor's wl_keyboard.modifiers would.
fn hold(k: *Keyboard, name: [*:0]const u8) void {
    const index = c.xkb_keymap_mod_get_index(k.xkb_keymap.?, name);
    k.modifiers(@as(u32, 1) << @intCast(index), 0, 0, 0);
}

test "several events in one dispatch are delivered in order, press and release" {
    var k = keyboard("us");
    defer k.deinit();
    k.key(10, KEY.j, true, 0);
    k.key(11, KEY.j, false, 0);
    k.button(12, 272, true, 90, 65);
    k.button(13, 272, false, 90, 65);
    k.key(14, KEY.f5, true, 0);
    k.key(15, KEY.space, true, 0);
    const expected = [_]struct { Kind, u32 }{ .{ .press, KEY.j }, .{ .release, KEY.j }, .{ .button_press, 272 }, .{ .button_release, 272 }, .{ .press, KEY.f5 }, .{ .press, KEY.space } };
    for (expected, 10..) |want, time| {
        const event = k.next().?;
        try testing.expectEqual(want[0], event.kind);
        try testing.expectEqual(want[1], event.code);
        try testing.expectEqual(@as(u32, @intCast(time)), event.time_ms);
    }
    try testing.expect(k.next() == null);
    try testing.expectEqual(@as(u64, 0), k.dropped);
}

test "physical code, keysym, shortcut and text stay distinct under modifiers" {
    var k = keyboard("us");
    defer k.deinit();
    var event = tap(&k, KEY.a);
    try testing.expectEqual(@as(u32, 'a'), event.sym);
    try testing.expectEqual(@as(u32, 'a'), event.shortcut);
    try testing.expectEqualStrings("a", event.text());
    try testing.expect(event.plain());

    hold(&k, c.XKB_MOD_NAME_SHIFT);
    event = tap(&k, KEY.a);
    try testing.expectEqual(@as(u32, KEY.a), event.code);
    try testing.expectEqual(@as(u32, 'A'), event.sym);
    try testing.expectEqual(@as(u32, 'a'), event.shortcut);
    try testing.expectEqualStrings("A", event.text());
    try testing.expect(event.mods.shift and event.plain());

    // Ctrl and Alt make a shortcut, never text.
    hold(&k, c.XKB_MOD_NAME_CTRL);
    event = tap(&k, KEY.a);
    try testing.expect(event.mods.ctrl and !event.plain());
    try testing.expectEqual(@as(u32, 'a'), event.shortcut);
    try testing.expectEqualStrings("", event.text());
    hold(&k, c.XKB_MOD_NAME_ALT);
    event = tap(&k, KEY.a);
    try testing.expect(event.mods.alt and !event.plain());
    try testing.expectEqualStrings("", event.text());

    // Function and control keys have a shortcut identity and no text.
    k.modifiers(0, 0, 0, 0);
    event = tap(&k, KEY.f5);
    try testing.expectEqual(@as(u32, sym.f1 + 4), event.shortcut);
    try testing.expectEqualStrings("", event.text());
    try testing.expectEqual(@as(u32, sym.space), tap(&k, KEY.space).shortcut);
    try testing.expectEqualStrings(" ", tap(&k, KEY.space).text());
    try testing.expectEqualStrings("", tap(&k, 15).text()); // Tab
    try testing.expectEqual(@as(u32, sym.tab), tap(&k, 15).shortcut);
    try testing.expectEqualStrings("", (blk: {
        k.key(0, KEY.a, false, 0);
        break :blk k.next().?;
    }).text()); // a release never carries text
}

test "shortcuts use only the active layout, with no physical or other-layout fallback" {
    {
        // German: Y and Z swap, and the semicolon position types o-umlaut.
        var k = keyboard("de");
        defer k.deinit();
        try testing.expectEqualStrings("z", tap(&k, KEY.y).text());
        try testing.expectEqual(@as(u32, 'z'), tap(&k, KEY.y).shortcut);
        const umlaut = tap(&k, KEY.semicolon);
        try testing.expectEqualStrings("\u{f6}", umlaut.text());
        try testing.expectEqual(@as(u32, KEY.semicolon), umlaut.code);
    }
    {
        // French AZERTY: the key at the QWERTY "A" position is labelled Q.
        var k = keyboard("fr");
        defer k.deinit();
        try testing.expectEqual(@as(u32, 'q'), tap(&k, KEY.a).shortcut);
        try testing.expectEqual(@as(u32, 'a'), tap(&k, KEY.q).shortcut);
        try testing.expectEqualStrings("q", tap(&k, KEY.a).text());
        // The digit row types punctuation unshifted; that is the key's identity there.
        try testing.expectEqual(@as(u32, '&'), tap(&k, KEY.@"1").shortcut);
    }
    {
        // Russian only: text is Cyrillic; the QWERTY position supplies no shortcut.
        var k = keyboard("ru");
        defer k.deinit();
        const event = tap(&k, KEY.q);
        try testing.expectEqualStrings("\u{439}", event.text());
        try testing.expectEqual(@as(u32, 0x6ca), event.sym); // Cyrillic_shorti
        try testing.expectEqual(@as(u32, 0), event.shortcut);
        try testing.expectEqual(@as(u32, sym.f1 + 4), tap(&k, KEY.f5).shortcut);
    }
    {
        // Russian active: the inactive French layout must not supply a shortcut.
        var k = keyboard("fr,ru");
        defer k.deinit();
        k.modifiers(0, 0, 0, 1);
        const event = tap(&k, KEY.a);
        try testing.expectEqualStrings("\u{444}", event.text());
        try testing.expectEqual(@as(u32, 0), event.shortcut);
        k.modifiers(0, 0, 0, 0);
        try testing.expectEqualStrings("q", tap(&k, KEY.a).text());
        try testing.expectEqual(@as(u32, 'q'), tap(&k, KEY.a).shortcut);
    }
    {
        // No keymap: physical codes remain available, without inferred shortcuts.
        var k = Keyboard.init("en_US.UTF-8");
        defer k.deinit();
        const event = tap(&k, KEY.q);
        try testing.expectEqual(@as(u32, 0), event.shortcut);
        try testing.expectEqual(@as(u32, KEY.q), event.code);
        try testing.expectEqual(@as(u32, 0), event.sym);
        try testing.expectEqualStrings("", event.text());
        try testing.expectEqual(@as(u32, 0), tap(&k, KEY.f5).shortcut);
    }
}

test "dead keys compose text; a cancelled sequence produces none" {
    var k = keyboard("de");
    defer k.deinit();
    try testing.expect(k.compose != null);
    // The key right of sharp-s is dead_acute on the German layout.
    k.key(0, KEY.equal, true, 0);
    const dead = k.next().?;
    try testing.expectEqualStrings("", dead.text());
    try testing.expectEqual(@as(u32, 0xfe51), dead.sym);
    k.key(0, KEY.equal, false, 0);
    _ = k.next();
    const composed = tap(&k, KEY.e);
    try testing.expectEqualStrings("\u{e9}", composed.text());
    try testing.expectEqual(@as(u32, 0xe9), composed.sym);
    try testing.expectEqual(@as(u32, 'e'), composed.shortcut);
    try testing.expectEqualStrings("e", tap(&k, KEY.e).text());

    // dead_acute followed by a key with no accented form cancels; the next key is ordinary again.
    _ = tap(&k, KEY.equal);
    try testing.expectEqualStrings("", tap(&k, KEY.q).text());
    try testing.expectEqualStrings("q", tap(&k, KEY.q).text());

    // Losing focus in the middle of a sequence forgets it.
    _ = tap(&k, KEY.equal);
    k.leave();
    k.enter();
    try testing.expectEqualStrings("e", tap(&k, KEY.e).text());
}

test "a full queue drops the newest events and counts them" {
    var k = keyboard("us");
    defer k.deinit();
    for (0..capacity + 6) |i| k.key(@intCast(i), KEY.j, i % 2 == 0, 0);
    try testing.expectEqual(@as(usize, capacity), k.count);
    try testing.expectEqual(@as(u64, 6), k.dropped);
    for (0..capacity) |i| try testing.expectEqual(@as(u32, @intCast(i)), k.next().?.time_ms);
    try testing.expect(k.next() == null);
    k.key(999, KEY.j, true, 0);
    try testing.expectEqual(@as(u32, 999), k.next().?.time_ms);
    try testing.expectEqual(@as(u64, 6), k.dropped);
}

fn repeats(k: *Keyboard) usize {
    var n: usize = 0;
    while (k.next()) |event| n += @intFromBool(event.kind == .repeat);
    return n;
}

test "repeat follows the compositor's rate and delay on a caller-supplied clock" {
    var k = keyboard("us");
    defer k.deinit();
    k.repeatInfo(25, 600);
    k.key(1000, KEY.j, true, 0);
    try testing.expectEqual(@as(i32, 8), k.timeoutMs(0, 8));
    k.tick(599 * ms);
    try testing.expectEqual(@as(usize, 0), repeats(&k));
    try testing.expectEqual(@as(i32, 1), k.timeoutMs(599 * ms, 8));
    k.tick(600 * ms);
    k.tick(600 * ms); // a second call at the same instant adds nothing
    try testing.expectEqual(@as(usize, 1), k.count);
    const first = k.next().?;
    try testing.expectEqual(Kind.repeat, first.kind);
    try testing.expectEqual(@as(u32, KEY.j), first.code);
    try testing.expectEqualStrings("j", first.text());
    try testing.expectEqual(@as(u32, 1600), first.time_ms);
    k.tick(639 * ms);
    try testing.expectEqual(@as(usize, 0), repeats(&k));
    k.tick(640 * ms);
    k.tick(680 * ms);
    try testing.expectEqual(@as(usize, 2), repeats(&k));

    // A long stall yields one repeat, then the normal cadence resumes from now.
    k.tick(5000 * ms);
    k.tick(5000 * ms);
    k.tick(5039 * ms);
    try testing.expectEqual(@as(usize, 1), repeats(&k));
    k.tick(5040 * ms);
    try testing.expectEqual(@as(usize, 1), repeats(&k));
}

test "repeat is cancelled by release, leave, keymap replacement, seat removal, and rate 0" {
    var k = keyboard("us");
    defer k.deinit();
    k.repeatInfo(25, 600);
    const Cancel = enum { release, leave, new_keymap, seat_removed, rate_zero, other_release };
    for (std.enums.values(Cancel)) |how| {
        k.key(0, KEY.j, true, 0);
        k.tick(600 * ms);
        try testing.expectEqual(@as(usize, 1), repeats(&k));
        switch (how) {
            .release => k.key(0, KEY.j, false, 700 * ms),
            .leave => k.leave(),
            .new_keymap => {
                const map = makeKeymap("de", null);
                k.keymap(c.XKB_KEYMAP_FORMAT_TEXT_V1, map.fd, map.size);
            },
            .seat_removed => k.seatRemoved(),
            .rate_zero => k.repeatInfo(0, 0),
            .other_release => k.key(0, KEY.a, false, 700 * ms), // releasing a different key does not cancel
        }
        k.tick(2000 * ms);
        try testing.expectEqual(@as(usize, if (how == .other_release) 1 else 0), repeats(&k));
        try testing.expectEqual(how != .other_release, k.repeat_code == null);
        // Restore a known state for the next case.
        k.key(0, KEY.j, false, 0);
        _ = repeats(&k);
        const map = makeKeymap("us", null);
        k.keymap(c.XKB_KEYMAP_FORMAT_TEXT_V1, map.fd, map.size);
        k.enter();
        k.repeatInfo(25, 600);
    }
    // Modifier keys do not repeat, and the newest repeating key takes over.
    k.key(0, KEY.leftshift, true, 0);
    try testing.expect(k.repeat_code == null);
    k.key(0, KEY.j, true, 0);
    k.key(0, KEY.a, true, 100 * ms);
    k.tick(700 * ms);
    while (k.next()) |event| if (event.kind == .repeat) try testing.expectEqual(@as(u32, KEY.a), event.code);
}

test "leave and seat removal reset modifiers" {
    var k = keyboard("us");
    defer k.deinit();
    hold(&k, c.XKB_MOD_NAME_SHIFT);
    try testing.expect(tap(&k, KEY.a).mods.shift);
    k.leave();
    k.enter();
    const after_leave = tap(&k, KEY.a);
    try testing.expect(!after_leave.mods.shift);
    try testing.expectEqualStrings("a", after_leave.text());

    hold(&k, c.XKB_MOD_NAME_CTRL);
    k.seatRemoved();
    try testing.expect(k.xkb_keymap == null and k.state == null and k.compose == null);
    try testing.expectEqual(Mods{}, tap(&k, KEY.a).mods);
    const map = makeKeymap("us", null);
    k.keymap(c.XKB_KEYMAP_FORMAT_TEXT_V1, map.fd, map.size);
    try testing.expect(tap(&k, KEY.a).plain());
}

test "keymap descriptors are closed on every path and bad keymaps are counted" {
    var k = Keyboard.init("en_US.UTF-8");
    defer k.deinit();
    const before = openFds();

    const good = makeKeymap("us", null);
    k.keymap(c.XKB_KEYMAP_FORMAT_TEXT_V1, good.fd, good.size);
    try testing.expect(!fdOpen(good.fd) and k.xkb_keymap != null);
    try testing.expectEqual(@as(u64, 0), k.keymap_errors);

    // Not a keymap.
    const garbage = c.memfd_create("xodb-test-garbage", 0);
    _ = c.write(garbage, "not a keymap", 13);
    k.keymap(c.XKB_KEYMAP_FORMAT_TEXT_V1, garbage, 13);
    try testing.expect(!fdOpen(garbage) and k.xkb_keymap == null);
    try testing.expectEqual(@as(u64, 1), k.keymap_errors);
    try testing.expectEqual(@as(u32, KEY.q), tap(&k, KEY.q).code); // events still arrive, with the physical code only

    // Size 0, a descriptor that cannot be mapped, an invalid descriptor, and the "no keymap" format.
    const empty = makeKeymap("us", null);
    k.keymap(c.XKB_KEYMAP_FORMAT_TEXT_V1, empty.fd, 0);
    try testing.expect(!fdOpen(empty.fd));
    var pipe: [2]i32 = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&pipe));
    k.keymap(c.XKB_KEYMAP_FORMAT_TEXT_V1, pipe[0], 64);
    try testing.expect(!fdOpen(pipe[0]));
    _ = c.close(pipe[1]);
    k.keymap(c.XKB_KEYMAP_FORMAT_TEXT_V1, -1, 64);
    try testing.expectEqual(@as(u64, 4), k.keymap_errors);
    const unused = makeKeymap("us", null);
    k.keymap(0, unused.fd, unused.size);
    try testing.expect(!fdOpen(unused.fd) and k.xkb_keymap == null);
    try testing.expectEqual(@as(u64, 4), k.keymap_errors);

    try testing.expectEqual(before, openFds());
}

test "replacing the keymap many times does not grow the heap" {
    var k = Keyboard.init("en_US.UTF-8");
    defer k.deinit();
    const before = openFds();
    var after_warmup: usize = 0;
    var mapped_after_warmup: usize = 0;
    for (0..300) |i| {
        const map = makeKeymap(if (i % 2 == 0) "us" else "de", null);
        k.keymap(c.XKB_KEYMAP_FORMAT_TEXT_V1, map.fd, map.size);
        hold(&k, c.XKB_MOD_NAME_SHIFT);
        _ = tap(&k, KEY.a);
        if (i % 50 == 49) k.seatRemoved();
        if (i == 99) after_warmup = c.mallinfo2().uordblks;
        if (i == 99) mapped_after_warmup = mappings();
    }
    // Both measurements are taken just after seatRemoved, with no keymap loaded.
    // 200 replacements lie between them: anything leaked per keymap would add megabytes.
    const in_use = c.mallinfo2().uordblks;
    try testing.expect(in_use < after_warmup + 64 * 1024);
    try testing.expect(mappings() < mapped_after_warmup + 8);
    try testing.expectEqual(before, openFds());
}

test "shortcut modifiers cannot commit pending composed text" {
    var k = keyboard("de");
    defer k.deinit();
    for ([_][*:0]const u8{ c.XKB_MOD_NAME_CTRL, c.XKB_MOD_NAME_ALT, c.XKB_MOD_NAME_LOGO }) |modifier| {
        _ = tap(&k, KEY.equal);
        hold(&k, modifier);
        try testing.expectEqualStrings("", tap(&k, KEY.e).text());
        k.modifiers(0, 0, 0, 0);
        try testing.expectEqualStrings("e", tap(&k, KEY.e).text());
    }
}
