/* Reproduce a graphics-library reader consuming readiness between poll and
 * dispatch. Only enabled by a gate file in a private test compositor. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

static struct wl_display *display;
static struct wl_event_queue *queue;
static pthread_t owner, reader_thread;
static int reader_started;
static atomic_int entered, finished;
static int fired;

struct wl_display *wl_display_connect(const char *name) {
    struct wl_display *(*real_connect)(const char *) = dlsym(RTLD_NEXT, "wl_display_connect");
    struct wl_display *result = real_connect(name);
    if (!display) { display = result; owner = pthread_self(); }
    return result;
}

static void done(void *data, struct wl_callback *cb, uint32_t serial) {
    (void)serial;
    *(int *)data = 1;
    wl_callback_destroy(cb);
}
static const struct wl_callback_listener listener = { done };
static void *reader(void *unused) {
    (void)unused;
    atomic_store(&entered, 1);
    wl_display_dispatch_queue(display, queue);
    atomic_store(&finished, 1);
    return NULL;
}

int poll(struct pollfd *fds, nfds_t count, int timeout) {
    int (*real_poll)(struct pollfd *, nfds_t, int) = dlsym(RTLD_NEXT, "poll");
    const char *gate = getenv("XODB_TEST_READ_RACE");
    if (!fired && display && gate && pthread_equal(owner, pthread_self()) &&
        count == 1 && fds[0].fd == wl_display_get_fd(display) && timeout >= 0 &&
        access(gate, F_OK) == 0) {
        fired = 1;
        queue = wl_display_create_queue(display);
        struct wl_display *wrapper = wl_proxy_create_wrapper(display);
        wl_proxy_set_queue((struct wl_proxy *)wrapper, queue);
        struct wl_callback *cb = wl_display_sync(wrapper);
        wl_proxy_wrapper_destroy(wrapper);
        static int callback_done;
        wl_callback_add_listener(cb, &listener, &callback_done);
        wl_display_flush(display);
        int n = real_poll(fds, count, 1000);
        if (n <= 0 || !(fds[0].revents & POLLIN)) abort();
        if (pthread_create(&reader_thread, NULL, reader, NULL)) abort();
        reader_started = 1;
        while (!atomic_load(&entered)) usleep(100);
        /* A prepared main reader prevents consumption until it calls read_events.
         * Otherwise the helper consumes the sync reply before poll returns. */
        usleep(50000);
        int consumed = atomic_load(&finished);
        if (consumed) wl_display_dispatch_pending(display);
        fprintf(stderr, "xodb test: competing reader %s before poll returns\n",
                consumed ? "consumed readiness" : "waiting for main reader");
        return n;
    }
    return real_poll(fds, count, timeout);
}

void wl_display_disconnect(struct wl_display *connection) {
    void (*real_disconnect)(struct wl_display *) = dlsym(RTLD_NEXT, "wl_display_disconnect");
    if (connection == display && reader_started) {
        pthread_join(reader_thread, NULL);
        wl_event_queue_destroy(queue);
        reader_started = 0;
    }
    real_disconnect(connection);
}
