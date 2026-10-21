//! Language inspection records, independent of session and selection state.
pub const Tab = enum { registers, native, python, perl, lua, javascript, ruby, go, elisp, gdscript };
pub const Identity = enum { witnessed, unwitnessed };
pub const Description = struct { version: []const u8, build_id: []const u8, basis: []const u8, identity: ?Identity = null, thread: ?i32 = null };

const std = @import("std");
/// Which language views may run. A view that is off does no work at all:
/// no runtime search, no file read and no target memory read on its behalf.
/// `enabled` false turns every one of them off.
pub const Languages = struct {
    enabled: bool = true,
    python: bool = true,
    perl: bool = true,
    lua: bool = true,
    javascript: bool = true,
    ruby: bool = true,
    go: bool = true,
    elisp: bool = true,
    gdscript: bool = true,
    /// In language tab order.
    pub const Name = enum { python, perl, lua, javascript, ruby, go, elisp, gdscript };
    pub fn on(self: Languages, name: Name) bool {
        return self.enabled and switch (name) {
            inline else => |which| @field(self, @tagName(which)),
        };
    }
    pub fn require(self: Languages, name: Name) error{LanguageDisabled}!void {
        if (!self.on(name)) return error.LanguageDisabled;
    }
    /// `all` or one language name, as the command line spells it.
    pub fn turnOff(self: *Languages, name: []const u8) !void {
        if (std.mem.eql(u8, name, "all")) {
            self.enabled = false;
            return;
        }
        switch (std.meta.stringToEnum(Name, name) orelse return error.UnknownLanguage) {
            inline else => |which| @field(self, @tagName(which)) = false,
        }
    }
};
