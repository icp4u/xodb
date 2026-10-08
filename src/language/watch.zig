//! Arena-owned adapter result. C owns canonical samples and comparison state.
const c = @import("../c.zig").api;
pub const Capture = struct {
    scope: c.struct_xlw_scope,
    expression: [:0]const u8,
    observation: c.enum_xlw_observation = c.XLW_INCOMPLETE,
    sample: ?c.struct_xlw_sample = null,
    diagnostic: ?[:0]const u8 = null,
    reads: usize = 0,
    bytes: usize = 0,
};
