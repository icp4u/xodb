//! The iterator is passed by pointer. That call is allowed.
const c = @cImport({
    @cInclude("xcb/xcb.h");
});

const next: *const fn (*c.xcb_screen_iterator_t) callconv(.c) void = undefined;

export fn use() void {
    var iter: c.xcb_screen_iterator_t = undefined;
    next(&iter);
}
