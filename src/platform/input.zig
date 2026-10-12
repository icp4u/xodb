//! Input events as the interface sees them, whatever window system produced
//! them. A backend's `Keyboard` (see window.zig) fills one ordered queue with
//! key and pointer-button events; the application drains it with `next`.
//!
//! Each event keeps four things apart:
//!   code      the physical key (evdev code), independent of layout
//!   sym       the keysym the layout and modifiers produce now
//!   shortcut  the key's logical identity for bindings: its unshifted keysym,
//!             from the active layout only
//!   text      committed UTF-8 text, after dead keys and compose sequences;
//!             empty while composing and when Ctrl, Alt, or Super is held

pub const Keyboard = @import("window.zig").Keyboard;

pub const capacity = 64;
/// `super` is the system key: Logo on Linux keyboards, Command on a Mac.
pub const Mods = packed struct(u8) { shift: bool = false, ctrl: bool = false, alt: bool = false, super: bool = false, caps: bool = false, num: bool = false, _: u2 = 0 };
pub const Kind = enum { press, release, repeat, button_press, button_release };
pub const Event = struct {
    kind: Kind,
    /// Window system timestamp in milliseconds; for a repeat, the press time plus elapsed time.
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
    /// True for a binding that should fire: no Ctrl, Alt, or Super held.
    pub fn plain(self: Event) bool {
        return !self.mods.ctrl and !self.mods.alt and !self.mods.super;
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
