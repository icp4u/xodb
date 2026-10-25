#include <xcb/xcb.h>

/* xcb_setup_roots_iterator returns a three-field iterator by value.
   Zig 0.16 mis-lowers that return on LoongArch64, so the call stays in C. */
void xodb_xcb_setup_roots(xcb_screen_iterator_t (*fn)(const xcb_setup_t *setup),
                          const xcb_setup_t *setup, xcb_screen_iterator_t *out)
{
    *out = fn(setup);
}
