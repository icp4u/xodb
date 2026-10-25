//! The iterator is returned by value. The lint must report this call.
const c = @cImport({
    @cInclude("xcb/xcb.h");
});

const roots: *const fn (*const c.xcb_setup_t) callconv(.c) c.xcb_screen_iterator_t = undefined;

export fn use() void {
    const setup: *const c.xcb_setup_t = undefined;
    var iter = roots(setup);
    _ = &iter;
}
