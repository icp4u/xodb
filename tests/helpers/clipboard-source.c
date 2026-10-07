/* An owned clipboard source that delays or withholds a transfer. Only for the
 * private GUI harness; does not connect to an inherited interactive display. */
#define _GNU_SOURCE 1
#include "data-control.h"
#include <wayland-client.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static struct zwlr_data_control_manager_v1 *manager;
static struct wl_seat *seat;
static int delay_ms, stopped;
static struct { int fd; long long when; } writers[16];
static long long now(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void global(void *data, struct wl_registry *r, uint32_t id, const char *name, uint32_t version) {
    (void)data;
    if (!strcmp(name, "zwlr_data_control_manager_v1")) manager = wl_registry_bind(r, id, &zwlr_data_control_manager_v1_interface, version < 2 ? version : 2);
    if (!strcmp(name, "wl_seat")) seat = wl_registry_bind(r, id, &wl_seat_interface, 1);
}
static void removed(void *data, struct wl_registry *r, uint32_t id) { (void)data; (void)r; (void)id; }
static void send_text(void *data, struct zwlr_data_control_source_v1 *s, const char *type, int fd) {
    (void)data; (void)s; (void)type;
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { close(fd); return; }
    for (unsigned i = 0; i < 16; ++i) if (writers[i].fd < 0) {
        writers[i].fd = fd; writers[i].when = now() + delay_ms; return;
    }
    close(fd);
}
static void cancelled(void *data, struct zwlr_data_control_source_v1 *s) { (void)data; (void)s; stopped = 1; }
static void offer(void *data, struct zwlr_data_control_device_v1 *d, struct zwlr_data_control_offer_v1 *o) {
    (void)data; (void)d; zwlr_data_control_offer_v1_destroy(o);
}
static void selection(void *data, struct zwlr_data_control_device_v1 *d, struct zwlr_data_control_offer_v1 *o) { (void)data; (void)d; (void)o; }
static void finished(void *data, struct zwlr_data_control_device_v1 *d) { (void)data; (void)d; stopped = 1; }
int main(int argc, char **argv) {
    const char *private = getenv("XODB_TEST_PRIVATE_DISPLAY"), *runtime = getenv("XDG_RUNTIME_DIR");
    if (argc != 2 || !private || strcmp(private, "1") || !runtime || !strstr(runtime, "/.work/input-")) return 2;
    delay_ms = atoi(argv[1]); /* -1 holds the fd; otherwise send after N ms. */
    for (unsigned i = 0; i < 16; ++i) writers[i].fd = -1;
    signal(SIGPIPE, SIG_IGN);
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 3;
    struct wl_registry *registry = wl_display_get_registry(display);
    const struct wl_registry_listener registry_events = {global, removed};
    wl_registry_add_listener(registry, &registry_events, NULL);
    if (wl_display_roundtrip(display) < 0 || !manager || !seat) return 4;
    struct zwlr_data_control_device_v1 *device = zwlr_data_control_manager_v1_get_data_device(manager, seat);
    const struct zwlr_data_control_device_v1_listener device_events = {offer, selection, finished, selection};
    zwlr_data_control_device_v1_add_listener(device, &device_events, NULL);
    struct zwlr_data_control_source_v1 *source = zwlr_data_control_manager_v1_create_data_source(manager);
    const struct zwlr_data_control_source_v1_listener source_events = {send_text, cancelled};
    zwlr_data_control_source_v1_add_listener(source, &source_events, NULL);
    zwlr_data_control_source_v1_offer(source, "text/plain;charset=utf-8");
    zwlr_data_control_device_v1_set_selection(device, source);
    if (wl_display_roundtrip(display) < 0) return 5;
    puts("ready"); fflush(stdout);
    long long deadline = now() + 15000;
    while (!stopped && now() < deadline) {
        for (unsigned i = 0; i < 16; ++i) if (writers[i].fd >= 0 && delay_ms >= 0 && now() >= writers[i].when) {
            ssize_t n = write(writers[i].fd, "late", 4);
            if (n >= 0 || (errno != EAGAIN && errno != EINTR)) { close(writers[i].fd); writers[i].fd = -1; }
        }
        if (wl_display_dispatch_pending(display) < 0) break;
        wl_display_flush(display);
        struct pollfd fd = {.fd = wl_display_get_fd(display), .events = POLLIN};
        if (poll(&fd, 1, 10) > 0 && wl_display_dispatch(display) < 0) break;
    }
    for (unsigned i = 0; i < 16; ++i) if (writers[i].fd >= 0) close(writers[i].fd);
    zwlr_data_control_source_v1_destroy(source);
    zwlr_data_control_device_v1_destroy(device);
    zwlr_data_control_manager_v1_destroy(manager);
    wl_seat_destroy(seat); wl_registry_destroy(registry); wl_display_disconnect(display);
    return 0;
}
