/* Private-X helper for tests/x11-gui.py. Linked with libxcb, not the xodb binary. */
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xcb/xcb.h>
#include <xcb/xtest.h>

static xcb_connection_t *conn;
static xcb_screen_t *screen;

static void die(const char *what) {
    fprintf(stderr, "x11-gate: %s\n", what);
    exit(1);
}

static void connect_display(void) {
    int preferred = 0;
    conn = xcb_connect(NULL, &preferred);
    if (xcb_connection_has_error(conn)) die("display connection failed");
    const xcb_setup_t *setup = xcb_get_setup(conn);
    xcb_screen_iterator_t it = xcb_setup_roots_iterator(setup);
    for (int i = 0; i < preferred && it.rem > 1; i++) xcb_screen_next(&it);
    if (it.rem < 1 || !it.data) die("no screen");
    screen = it.data;
}

static xcb_atom_t intern(const char *name) {
    xcb_intern_atom_cookie_t cookie = xcb_intern_atom(conn, 0, (uint16_t)strlen(name), name);
    xcb_intern_atom_reply_t *reply = xcb_intern_atom_reply(conn, cookie, NULL);
    if (!reply || reply->atom == 0) die("atom intern failed");
    xcb_atom_t atom = reply->atom;
    free(reply);
    return atom;
}

static int name_has_prefix(xcb_window_t window, xcb_atom_t atom, const char *prefix) {
    xcb_get_property_cookie_t cookie = xcb_get_property(conn, 0, window, atom, XCB_GET_PROPERTY_TYPE_ANY, 0, 64);
    xcb_get_property_reply_t *reply = xcb_get_property_reply(conn, cookie, NULL);
    if (!reply) return 0;
    int length = xcb_get_property_value_length(reply);
    const char *value = xcb_get_property_value(reply);
    size_t prefix_len = strlen(prefix);
    int match = length > 0 && (size_t)length >= prefix_len && memcmp(value, prefix, prefix_len) == 0;
    free(reply);
    return match;
}

static int find_named(xcb_window_t window, xcb_atom_t wm_name, xcb_atom_t net_name, const char *prefix, int depth, xcb_window_t *found) {
    if (name_has_prefix(window, net_name, prefix) || name_has_prefix(window, wm_name, prefix)) {
        *found = window;
        return 1;
    }
    if (depth <= 0) return 0;
    xcb_query_tree_cookie_t cookie = xcb_query_tree(conn, window);
    xcb_query_tree_reply_t *reply = xcb_query_tree_reply(conn, cookie, NULL);
    if (!reply) return 0;
    xcb_window_t *kids = xcb_query_tree_children(reply);
    int count = xcb_query_tree_children_length(reply);
    if (count > 64) count = 64;
    int hit = 0;
    for (int i = 0; i < count; i++) {
        if (find_named(kids[i], wm_name, net_name, prefix, depth - 1, found)) {
            hit = 1;
            break;
        }
    }
    free(reply);
    return hit;
}

static xcb_window_t parse_window(const char *text) {
    char *end = NULL;
    unsigned long value = strtoul(text, &end, 10);
    if (!text[0] || !end || *end || value == 0 || value > UINT32_MAX) die("bad window id");
    return (xcb_window_t)value;
}

static void flush_ok(void) {
    if (xcb_flush(conn) <= 0) die("flush failed");
}

static void fake(uint8_t type, uint8_t detail, int16_t x, int16_t y) {
    xcb_void_cookie_t cookie = xcb_test_fake_input(conn, type, detail, XCB_CURRENT_TIME, screen->root, x, y, 0);
    xcb_generic_error_t *error = xcb_request_check(conn, cookie);
    if (error) {
        fprintf(stderr, "x11-gate: input request failed %u\n", error->error_code);
        free(error);
        exit(1);
    }
}

static void window_root_point(xcb_window_t window, int16_t *x, int16_t *y) {
    xcb_translate_coordinates_cookie_t cookie = xcb_translate_coordinates(conn, window, screen->root, 8, 8);
    xcb_translate_coordinates_reply_t *reply = xcb_translate_coordinates_reply(conn, cookie, NULL);
    if (!reply) die("cannot place the pointer");
    *x = reply->dst_x;
    *y = reply->dst_y;
    free(reply);
}

static void send_delete(xcb_window_t window) {
    xcb_atom_t protocols = intern("WM_PROTOCOLS");
    xcb_atom_t delete = intern("WM_DELETE_WINDOW");
    xcb_client_message_event_t event;
    memset(&event, 0, sizeof event);
    event.response_type = XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.window = window;
    event.type = protocols;
    event.data.data32[0] = delete;
    xcb_void_cookie_t cookie = xcb_send_event(conn, 0, window, XCB_EVENT_MASK_NO_EVENT, (char *)&event);
    xcb_generic_error_t *error = xcb_request_check(conn, cookie);
    if (error) {
        free(error);
        die("delete event failed");
    }
}

static int wait_fd(int timeout_ms) {
    struct pollfd pollfd = { .fd = xcb_get_file_descriptor(conn), .events = POLLIN, .revents = 0 };
    int ready = poll(&pollfd, 1, timeout_ms);
    if (ready < 0 && errno == EINTR) return 0;
    if (ready < 0) die("poll failed");
    return ready;
}

static void offer(const char *text) {
    size_t length = strlen(text);
    if (length == 0 || length > 64) die("offer length");
    xcb_window_t window = xcb_generate_id(conn);
    xcb_create_window(conn, 0, window, screen->root, 0, 0, 1, 1, 0, XCB_WINDOW_CLASS_INPUT_ONLY, screen->root_visual, 0, NULL);
    xcb_atom_t clipboard = intern("CLIPBOARD");
    xcb_atom_t utf8 = intern("UTF8_STRING");
    xcb_atom_t targets = intern("TARGETS");
    xcb_set_selection_owner(conn, window, clipboard, XCB_CURRENT_TIME);
    flush_ok();
    xcb_get_selection_owner_reply_t *owner = xcb_get_selection_owner_reply(conn, xcb_get_selection_owner(conn, clipboard), NULL);
    int owned = owner && owner->owner == window;
    free(owner);
    if (!owned) die("selection was not taken");
    fputs("ready\n", stdout);
    fflush(stdout);
    int served = 0;
    for (int spins = 0; spins < 80 && !served; spins++) {
        if (!wait_fd(100)) continue;
        xcb_generic_event_t *event;
        while ((event = xcb_poll_for_event(conn))) {
            if ((event->response_type & 0x7f) == XCB_SELECTION_REQUEST) {
                xcb_selection_request_event_t *request = (xcb_selection_request_event_t *)event;
                xcb_atom_t property = request->property ? request->property : request->target;
                int answered = 0;
                xcb_void_cookie_t changed = {0};
                if (request->selection == clipboard && request->target == targets) {
                    xcb_atom_t list[2] = { utf8, XCB_ATOM_STRING };
                    changed = xcb_change_property(conn, XCB_PROP_MODE_REPLACE, request->requestor, property, XCB_ATOM_ATOM, 32, 2, list);
                    answered = 1;
                } else if (request->selection == clipboard && (request->target == utf8 || request->target == XCB_ATOM_STRING)) {
                    changed = xcb_change_property(conn, XCB_PROP_MODE_REPLACE, request->requestor, property, request->target, 8, (uint32_t)length, text);
                    answered = 1;
                    served = 1;
                } else property = 0;
                xcb_selection_notify_event_t notify;
                memset(&notify, 0, sizeof notify);
                notify.response_type = XCB_SELECTION_NOTIFY;
                notify.time = request->time;
                notify.requestor = request->requestor;
                notify.selection = request->selection;
                notify.target = request->target;
                notify.property = answered ? property : 0;
                xcb_void_cookie_t sent = xcb_send_event(conn, 0, request->requestor, XCB_EVENT_MASK_NO_EVENT, (char *)&notify);
                flush_ok();
                /* This process exits after one transfer. Wait until the server
                 * has accepted the write so the close cannot drop it. */
                if (answered) {
                    xcb_generic_error_t *error = xcb_request_check(conn, changed);
                    if (error) {
                        free(error);
                        die("offer property failed");
                    }
                    error = xcb_request_check(conn, sent);
                    if (error) {
                        free(error);
                        die("offer notify failed");
                    }
                }
            }
            free(event);
        }
    }
    if (!served) die("offer timed out");
}

static void take(const char *expected) {
    size_t length = strlen(expected);
    xcb_window_t window = xcb_generate_id(conn);
    uint32_t mask = XCB_CW_EVENT_MASK;
    uint32_t values = XCB_EVENT_MASK_PROPERTY_CHANGE;
    xcb_create_window(conn, 0, window, screen->root, 0, 0, 1, 1, 0, XCB_WINDOW_CLASS_INPUT_ONLY, screen->root_visual, mask, &values);
    xcb_atom_t clipboard = intern("CLIPBOARD");
    xcb_atom_t utf8 = intern("UTF8_STRING");
    xcb_atom_t property = intern("XODB_GATE");
    xcb_convert_selection(conn, window, clipboard, utf8, property, XCB_CURRENT_TIME);
    flush_ok();
    xcb_selection_notify_event_t *notify = NULL;
    for (int spins = 0; spins < 10 && !notify; spins++) {
        if (!wait_fd(100)) continue;
        xcb_generic_event_t *event;
        while ((event = xcb_poll_for_event(conn))) {
            if ((event->response_type & 0x7f) == XCB_SELECTION_NOTIFY) {
                notify = (xcb_selection_notify_event_t *)event;
                break;
            }
            free(event);
        }
    }
    if (!notify || notify->property == 0) die("selection notify missing");
    xcb_get_property_cookie_t cookie = xcb_get_property(conn, 1, window, notify->property, XCB_GET_PROPERTY_TYPE_ANY, 0, 64);
    xcb_get_property_reply_t *reply = xcb_get_property_reply(conn, cookie, NULL);
    free(notify);
    if (!reply) die("selection property missing");
    int got = xcb_get_property_value_length(reply);
    const char *bytes = xcb_get_property_value(reply);
    int match = got >= 0 && (size_t)got == length && memcmp(bytes, expected, length) == 0;
    printf("bytes %d\n", got);
    free(reply);
    if (!match) die("selection bytes differ");
}

int main(int argc, char **argv) {
    if (argc < 2) die("missing command");
    connect_display();
    const char *command = argv[1];
    if (strcmp(command, "dpi") == 0) {
        const char *text = "Xft.dpi:\t192\n";
        xcb_void_cookie_t cookie = xcb_change_property(conn, XCB_PROP_MODE_REPLACE, screen->root, XCB_ATOM_RESOURCE_MANAGER, XCB_ATOM_STRING, 8, (uint32_t)strlen(text), text);
        xcb_generic_error_t *error = xcb_request_check(conn, cookie);
        if (error) {
            free(error);
            die("dpi property failed");
        }
        /* This private server drops root properties when its last client
         * disconnects. Stay connected so the resource is still there when
         * the debugger opens the display. */
        printf("ready\n");
        fflush(stdout);
        for (;;) pause();
    } else if (strcmp(command, "find") == 0) {
        if (argc != 3) die("find needs a prefix");
        xcb_window_t found = 0;
        if (!find_named(screen->root, XCB_ATOM_WM_NAME, intern("_NET_WM_NAME"), argv[2], 6, &found)) die("window not found");
        printf("%u\n", found);
    } else if (strcmp(command, "focus") == 0) {
        if (argc != 3) die("focus needs a window");
        xcb_set_input_focus(conn, XCB_INPUT_FOCUS_POINTER_ROOT, parse_window(argv[2]), XCB_CURRENT_TIME);
        flush_ok();
    } else if (strcmp(command, "key") == 0) {
        if (argc != 5) die("key needs a window, code and down or up");
        (void)parse_window(argv[2]);
        unsigned long code = strtoul(argv[3], NULL, 10);
        if (code == 0 || code > 255) die("bad keycode");
        uint8_t type = strcmp(argv[4], "down") == 0 ? XCB_KEY_PRESS : XCB_KEY_RELEASE;
        if (strcmp(argv[4], "down") != 0 && strcmp(argv[4], "up") != 0) die("key direction");
        fake(type, (uint8_t)code, 0, 0);
    } else if (strcmp(command, "click") == 0) {
        if (argc != 3) die("click needs a window");
        int16_t x = 0, y = 0;
        window_root_point(parse_window(argv[2]), &x, &y);
        fake(XCB_MOTION_NOTIFY, 0, x, y);
        fake(XCB_BUTTON_PRESS, 1, x, y);
        fake(XCB_BUTTON_RELEASE, 1, x, y);
    } else if (strcmp(command, "resize") == 0) {
        if (argc != 5) die("resize needs a window and a size");
        uint32_t values[2] = { (uint32_t)atoi(argv[3]), (uint32_t)atoi(argv[4]) };
        if (values[0] == 0 || values[1] == 0) die("bad size");
        xcb_window_t window = parse_window(argv[2]);
        xcb_void_cookie_t cookie = xcb_configure_window(conn, window, XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, values);
        xcb_generic_error_t *error = xcb_request_check(conn, cookie);
        if (error) {
            fprintf(stderr, "configure error %u\n", error->error_code);
            free(error);
            die("configure failed");
        }
        xcb_get_geometry_reply_t *geometry = xcb_get_geometry_reply(conn, xcb_get_geometry(conn, window), NULL);
        if (!geometry) die("geometry missing");
        printf("%u %u\n", geometry->width, geometry->height);
        free(geometry);
    } else if (strcmp(command, "delete") == 0) {
        if (argc != 3) die("delete needs a window");
        send_delete(parse_window(argv[2]));
    } else if (strcmp(command, "offer") == 0) {
        if (argc != 3) die("offer needs text");
        offer(argv[2]);
    } else if (strcmp(command, "take") == 0) {
        if (argc != 3) die("take needs text");
        take(argv[2]);
    } else die("unknown command");
    xcb_disconnect(conn);
    return 0;
}
