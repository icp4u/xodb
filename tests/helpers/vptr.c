/* T09 test input: a virtual pointer for run.py's private headless compositor.
 * It refuses to run anywhere else.
 *
 * usage: vptr WIDTH HEIGHT command...
 *   m X Y                  move           down / up     left button
 *   click X Y              move, press, release
 *   drag X0 Y0 X1 Y1 N     press at X0,Y0, move in N steps, release at X1,Y1
 *   hold X0 Y0 X1 Y1 N     like drag, without the release
 *   wheel X Y V            move, then vertical axis value V (15 is one notch)
 *   w MS                   wait
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>
#include "virtual-pointer.h"

static struct zwlr_virtual_pointer_manager_v1 *manager;
static struct zwlr_virtual_pointer_v1 *pointer;
static struct wl_display *display;
static uint32_t t = 1;
static int width, height;

static void global(void *data, struct wl_registry *registry, uint32_t id, const char *name, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(name, "zwlr_virtual_pointer_manager_v1")) manager = wl_registry_bind(registry, id, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t id) {
    (void)data; (void)registry; (void)id;
}
static void settle(int ms) {
    wl_display_roundtrip(display);
    usleep(ms * 1000);
}
static void move(int x, int y) {
    zwlr_virtual_pointer_v1_motion_absolute(pointer, t++, x, y, width, height);
    zwlr_virtual_pointer_v1_frame(pointer);
}
static void button(int pressed) {
    zwlr_virtual_pointer_v1_button(pointer, t++, 272, pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    zwlr_virtual_pointer_v1_frame(pointer);
}

int main(int argc, char **argv) {
    const char *permission = getenv("XODB_TEST_PRIVATE_DISPLAY");
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (argc < 4 || !permission || strcmp(permission, "1") || !runtime || !strstr(runtime, "/.work/timeline-")) return 2;
    display = wl_display_connect(NULL);
    if (!display) return 3;
    struct wl_registry *registry = wl_display_get_registry(display);
    const struct wl_registry_listener listener = {global, removed};
    wl_registry_add_listener(registry, &listener, NULL);
    wl_display_roundtrip(display);
    if (!manager) return 4;
    pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, NULL);
    width = atoi(argv[1]);
    height = atoi(argv[2]);
    settle(60);
    for (int i = 3; i < argc; i++) {
        const char *cmd = argv[i];
        if (!strcmp(cmd, "m") && i + 2 < argc) {
            move(atoi(argv[i + 1]), atoi(argv[i + 2]));
            i += 2;
            settle(40);
        } else if (!strcmp(cmd, "down") || !strcmp(cmd, "up")) {
            button(cmd[0] == 'd');
            settle(60);
        } else if (!strcmp(cmd, "click") && i + 2 < argc) {
            move(atoi(argv[i + 1]), atoi(argv[i + 2]));
            i += 2;
            settle(40);
            button(1);
            settle(40);
            button(0);
            settle(80);
        } else if ((!strcmp(cmd, "drag") || !strcmp(cmd, "hold")) && i + 5 < argc) {
            int x0 = atoi(argv[i + 1]), y0 = atoi(argv[i + 2]), x1 = atoi(argv[i + 3]), y1 = atoi(argv[i + 4]), n = atoi(argv[i + 5]);
            i += 5;
            if (n < 1) n = 1;
            move(x0, y0);
            settle(40);
            button(1);
            settle(40);
            for (int k = 1; k <= n; k++) {
                move(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n);
                settle(8);
            }
            if (cmd[0] == 'd') {
                button(0);
                settle(80);
            }
        } else if (!strcmp(cmd, "wheel") && i + 3 < argc) {
            move(atoi(argv[i + 1]), atoi(argv[i + 2]));
            settle(40);
            zwlr_virtual_pointer_v1_axis(pointer, t++, WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_double(atof(argv[i + 3])));
            zwlr_virtual_pointer_v1_frame(pointer);
            i += 3;
            settle(80);
        } else if (!strcmp(cmd, "w") && i + 1 < argc) {
            settle(atoi(argv[++i]));
        } else return 7;
    }
    zwlr_virtual_pointer_v1_destroy(pointer);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    return 0;
}
