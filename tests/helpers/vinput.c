/* T07 test input: a virtual keyboard and pointer for a private headless
 * compositor. It refuses to run anywhere else.
 *
 * usage: vinput WIDTH HEIGHT command...
 *   layout NAME    create the keyboard if needed and upload the keymap for an
 *                  xkb layout ("us", "fr", "fr,ru"); doing it again replaces the keymap
 *   down CODE      press an evdev key        up CODE     release it
 *   tap CODE       press, 30 ms, release
 *   burst N CODE.. N taps with no waits, flushed as one batch
 *   group N        lock layout group N
 *   detach         destroy the keyboard while keys may still be held
 *   m X Y          move the pointer          click X Y   move, press, release
 *   fastclick X Y  move, then press and release in one batch
 *   fastdrag X Y X Y  left drag with all edges sent in one batch
 *   middle X Y     middle button at X/Y; button CODE STATE sends a pointer edge
 *   scroll X Y N   move to X/Y and send N vertical wheel steps
 *   w MS           wait
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-pointer.h"
#include "virtual-keyboard.h"

static struct zwlr_virtual_pointer_manager_v1 *pointers;
static struct zwp_virtual_keyboard_manager_v1 *keyboards;
static struct wl_seat *seat;
static struct wl_display *display;
static struct zwp_virtual_keyboard_v1 *keyboard;
static struct xkb_state *state;
static uint32_t t = 1;

static void global(void *data, struct wl_registry *registry, uint32_t id, const char *name, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(name, "zwlr_virtual_pointer_manager_v1")) pointers = wl_registry_bind(registry, id, &zwlr_virtual_pointer_manager_v1_interface, 1);
    if (!strcmp(name, "zwp_virtual_keyboard_manager_v1")) keyboards = wl_registry_bind(registry, id, &zwp_virtual_keyboard_manager_v1_interface, 1);
    if (!strcmp(name, "wl_seat")) seat = wl_registry_bind(registry, id, &wl_seat_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t id) { (void)data; (void)registry; (void)id; }
static void settle(int ms) {
    wl_display_roundtrip(display);
    usleep(ms * 1000);
}
static int layout(const char *name) {
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_rule_names names = {.layout = name};
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!keymap) return 0;
    char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    size_t size = strlen(text) + 1;
    int fd = memfd_create("keymap", 0);
    if (fd < 0 || write(fd, text, size) != (ssize_t)size) return 0;
    if (!keyboard) keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboards, seat);
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
    close(fd);
    free(text);
    if (state) xkb_state_unref(state);
    state = xkb_state_new(keymap);
    xkb_keymap_unref(keymap);
    xkb_context_unref(context);
    return 1;
}
/* The compositor does not derive modifier state from a virtual keyboard's keys;
 * like a real keyboard driver, this tracks it and reports each change. */
static void key(int code, int pressed) {
    zwp_virtual_keyboard_v1_key(keyboard, t++, code, pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
    if (xkb_state_update_key(state, code + 8, pressed ? XKB_KEY_DOWN : XKB_KEY_UP) & (XKB_STATE_MODS_DEPRESSED | XKB_STATE_MODS_LATCHED | XKB_STATE_MODS_LOCKED | XKB_STATE_LAYOUT_EFFECTIVE))
        zwp_virtual_keyboard_v1_modifiers(keyboard, xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED), xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED), xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED), xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE));
}

int main(int argc, char **argv) {
    const char *permission = getenv("XODB_TEST_PRIVATE_DISPLAY");
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (argc < 4 || !permission || strcmp(permission, "1") || !runtime || !strstr(runtime, "/.work/input-")) return 2;
    display = wl_display_connect(NULL);
    if (!display) return 3;
    struct wl_registry *registry = wl_display_get_registry(display);
    const struct wl_registry_listener listener = {global, removed};
    wl_registry_add_listener(registry, &listener, NULL);
    wl_display_roundtrip(display);
    if (!pointers || !keyboards || !seat) return 4;
    struct zwlr_virtual_pointer_v1 *pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pointers, NULL);
    int width = atoi(argv[1]), height = atoi(argv[2]);
    settle(60);
    for (int i = 3; i < argc; i++) {
        const char *cmd = argv[i];
        if (!strcmp(cmd, "layout")) {
            if (!layout(argv[++i])) return 5;
            settle(120);
        } else if (!strcmp(cmd, "down") || !strcmp(cmd, "up")) {
            if (!keyboard) return 6;
            key(atoi(argv[++i]), cmd[0] == 'd');
            settle(40);
        } else if (!strcmp(cmd, "tap")) {
            if (!keyboard) return 6;
            int code = atoi(argv[++i]);
            key(code, 1);
            settle(30);
            key(code, 0);
            settle(60);
        } else if (!strcmp(cmd, "burst")) {
            if (!keyboard) return 6;
            for (int n = atoi(argv[++i]); n > 0; n--) {
                int code = atoi(argv[++i]);
                key(code, 1);
                key(code, 0);
            }
            wl_display_flush(display);
            settle(120);
        } else if (!strcmp(cmd, "group")) {
            if (!keyboard) return 6;
            zwp_virtual_keyboard_v1_modifiers(keyboard, 0, 0, 0, atoi(argv[++i]));
            settle(60);
        } else if (!strcmp(cmd, "detach")) {
            if (keyboard) zwp_virtual_keyboard_v1_destroy(keyboard);
            keyboard = NULL;
            if (state) xkb_state_unref(state);
            state = NULL;
            settle(120);
        } else if (!strcmp(cmd, "fastdrag")) {
            int x = atoi(argv[++i]), y = atoi(argv[++i]);
            zwlr_virtual_pointer_v1_motion_absolute(pointer, t++, x, y, width, height);
            zwlr_virtual_pointer_v1_button(pointer, t++, 272, WL_POINTER_BUTTON_STATE_PRESSED);
            zwlr_virtual_pointer_v1_frame(pointer);
            x = atoi(argv[++i]); y = atoi(argv[++i]);
            zwlr_virtual_pointer_v1_motion_absolute(pointer, t++, x, y, width, height);
            zwlr_virtual_pointer_v1_button(pointer, t++, 272, WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(pointer);
            settle(120);
        } else if (!strcmp(cmd, "button")) {
            int code = atoi(argv[++i]);
            int pressed = atoi(argv[++i]);
            zwlr_virtual_pointer_v1_button(pointer, t++, code, pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(pointer);
            settle(60);
        } else if (!strcmp(cmd, "m") || !strcmp(cmd, "click") || !strcmp(cmd, "fastclick") || !strcmp(cmd, "middle")) {
            zwlr_virtual_pointer_v1_motion_absolute(pointer, t++, atoi(argv[i + 1]), atoi(argv[i + 2]), width, height);
            zwlr_virtual_pointer_v1_frame(pointer);
            i += 2;
            settle(80);
            if (strcmp(cmd, "m")) {
                unsigned button = !strcmp(cmd, "middle") ? 274 : 272;
                zwlr_virtual_pointer_v1_button(pointer, t++, button, WL_POINTER_BUTTON_STATE_PRESSED);
                zwlr_virtual_pointer_v1_frame(pointer);
                if (cmd[0] == 'c') settle(60);
                zwlr_virtual_pointer_v1_button(pointer, t++, button, WL_POINTER_BUTTON_STATE_RELEASED);
                zwlr_virtual_pointer_v1_frame(pointer);
                wl_display_flush(display);
                settle(80);
            }
        } else if (!strcmp(cmd, "scroll")) {
            int x = atoi(argv[++i]), y = atoi(argv[++i]);
            int steps = atoi(argv[++i]);
            zwlr_virtual_pointer_v1_motion_absolute(pointer, t++, x, y, width, height);
            zwlr_virtual_pointer_v1_frame(pointer);
            settle(80);
            zwlr_virtual_pointer_v1_axis_source(pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
            zwlr_virtual_pointer_v1_axis_discrete(pointer, t++, WL_POINTER_AXIS_VERTICAL_SCROLL,
                wl_fixed_from_int(10 * steps), steps);
            zwlr_virtual_pointer_v1_frame(pointer);
            settle(80);
        } else if (!strcmp(cmd, "w")) {
            settle(atoi(argv[++i]));
        } else return 7;
    }
    zwlr_virtual_pointer_v1_destroy(pointer);
    if (keyboard) zwp_virtual_keyboard_v1_destroy(keyboard);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    return 0;
}
