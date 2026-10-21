//! Runtime identity evidence, independent of owner-side discovery and caches.
const c = @import("../c.zig").api;
pub const Budget = struct { reads: usize = 0, bytes: usize = 0 };
pub const Witness = struct { seen: bool, python_stack: ?*const c.struct_xpy_stack = null };
pub const Language = enum { python, perl };
pub const Identity = @import("types.zig").Identity;
pub const Token = struct { module_id: u64, generation: u64, epoch: u64, maps: u64 };
pub fn noFrame(comptime language: Language) anyerror {
    return switch (language) {
        .python => error.PythonInterpreterFrameUnavailable,
        .perl => error.PerlInterpreterFrameUnavailable,
    };
}
