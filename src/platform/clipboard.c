#define _GNU_SOURCE 1
#include "clipboard.h"
#include "primary-selection-unstable-v1-client-protocol.h"
#include <wayland-client.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define OFFERS 32
#define SOURCES 8
#define WRITERS 8
#define DEADLINE_NS UINT64_C(1000000000)
static const char utf8[] = "text/plain;charset=utf-8";
static const char plain[] = "text/plain";
struct offer {
    void *object;
    bool primary, utf8, plain;
};
struct source {
    struct xclip *owner;
    void *object;
    bool primary;
    size_t size;
    unsigned char bytes[XCLIP_LIMIT];
};
struct channel {
    struct offer *offer;
    struct source *source;
    bool pending, owned;
    uint32_t serial;
    size_t size;
    unsigned char bytes[XCLIP_LIMIT];
};
struct writer {
    int fd;
    uint64_t deadline;
    size_t at, size;
    unsigned char bytes[XCLIP_LIMIT];
};
struct xclip {
    struct wl_registry *registry;
    struct wl_seat *seat;
    uint32_t seat_name, manager_name, primary_name;
    struct wl_data_device_manager *manager;
    struct wl_data_device *device;
    struct zwp_primary_selection_device_manager_v1 *primary_manager;
    struct zwp_primary_selection_device_v1 *primary_device;
    struct offer offers[OFFERS];
    struct offer *drag;
    struct source sources[SOURCES];
    struct channel channels[2];
    struct writer writers[WRITERS];
    uint64_t destination, epoch, deadline;
    int read_fd;
    struct xclip_result result;
    bool changed;
};
static uint64_t now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000 + (uint64_t)ts.tv_nsec;
}
static void end_read(struct xclip *c, enum xclip_status status)
{
    if (c->read_fd >= 0) close(c->read_fd);
    c->read_fd = -1;
    c->result.status = status;
    c->changed = true;
}
static void destroy_offer(struct xclip *c, struct offer *o)
{
    if (!o || !o->object) return;
    if (c->drag == o) c->drag = NULL;
    for (unsigned i = 0; i < 2; ++i)
        if (c->channels[i].offer == o) c->channels[i].offer = NULL;
    if (o->primary) zwp_primary_selection_offer_v1_destroy(o->object);
    else wl_data_offer_destroy(o->object);
    *o = (struct offer){0};
}
static struct offer *find_offer(struct xclip *c, void *object)
{
    for (unsigned i = 0; object && i < OFFERS; ++i)
        if (c->offers[i].object == object) return &c->offers[i];
    return NULL;
}
static void mime(void *data, const char *name)
{
    struct offer *o = data;
    if (!strcmp(name, utf8)) o->utf8 = true;
    if (!strcmp(name, plain)) o->plain = true;
}
static void data_mime(void *data, struct wl_data_offer *o, const char *name)
{ (void)o; mime(data, name); }
static void primary_mime(void *data, struct zwp_primary_selection_offer_v1 *o, const char *name)
{ (void)o; mime(data, name); }
static void offer_actions(void *data, struct wl_data_offer *o, uint32_t action)
{ (void)data; (void)o; (void)action; }
static const struct wl_data_offer_listener offer_listener = {data_mime, offer_actions, offer_actions};
static const struct zwp_primary_selection_offer_v1_listener primary_offer_listener = {primary_mime};
static void new_offer(struct xclip *c, void *object, bool primary)
{
    for (unsigned i = 0; i < OFFERS; ++i) if (!c->offers[i].object) {
        struct offer *o = &c->offers[i];
        *o = (struct offer){.object = object, .primary = primary};
        if (primary) zwp_primary_selection_offer_v1_add_listener(object, &primary_offer_listener, o);
        else wl_data_offer_add_listener(object, &offer_listener, o);
        return;
    }
    /* Legitimate selection and DND sequences need only a few live offers.
     * Refuse an unbounded producer; no strings or payloads are retained. */
    if (primary) zwp_primary_selection_offer_v1_destroy(object);
    else wl_data_offer_destroy(object);
}
static void data_offer(void *data, struct wl_data_device *device, struct wl_data_offer *o)
{ (void)device; new_offer(data, o, false); }
static void primary_offer(void *data, struct zwp_primary_selection_device_v1 *device, struct zwp_primary_selection_offer_v1 *o)
{ (void)device; new_offer(data, o, true); }
static void selection(struct xclip *c, void *object, bool primary)
{
    struct channel *ch = &c->channels[primary];
    struct offer *o = find_offer(c, object);
    if (ch->offer != o) destroy_offer(c, ch->offer);
    ch->offer = o;
}
static void data_selection(void *data, struct wl_data_device *device, struct wl_data_offer *o)
{ (void)device; selection(data, o, false); }
static void primary_selection(void *data, struct zwp_primary_selection_device_v1 *device, struct zwp_primary_selection_offer_v1 *o)
{ (void)device; selection(data, o, true); }
static void drag_enter(void *data, struct wl_data_device *device, uint32_t serial,
                       struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y, struct wl_data_offer *o)
{
    (void)device; (void)serial; (void)surface; (void)x; (void)y;
    struct xclip *c = data;
    destroy_offer(c, c->drag);
    c->drag = find_offer(c, o);
}
static void drag_leave(void *data, struct wl_data_device *device)
{ (void)device; struct xclip *c = data; destroy_offer(c, c->drag); }
static void drag_motion(void *data, struct wl_data_device *device, uint32_t time, wl_fixed_t x, wl_fixed_t y)
{ (void)data; (void)device; (void)time; (void)x; (void)y; }
static const struct wl_data_device_listener device_listener = {
    data_offer, drag_enter, drag_leave, drag_motion, drag_leave, data_selection
};
static const struct zwp_primary_selection_device_v1_listener primary_device_listener = {
    primary_offer, primary_selection
};
static void send_text(struct source *source, const char *type, int fd)
{
    struct xclip *c = source->owner;
    if (strcmp(type, utf8) && strcmp(type, plain)) { close(fd); return; }
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
        close(fd); return;
    }
    for (unsigned i = 0; i < WRITERS; ++i) if (c->writers[i].fd < 0) {
        struct writer *w = &c->writers[i];
        w->fd = fd; w->at = 0; w->size = source->size; w->deadline = now() + DEADLINE_NS;
        memcpy(w->bytes, source->bytes, source->size);
        return;
    }
    close(fd);
}
static void data_send(void *data, struct wl_data_source *source, const char *type, int fd)
{ (void)source; send_text(data, type, fd); }
static void primary_send(void *data, struct zwp_primary_selection_source_v1 *source, const char *type, int fd)
{ (void)source; send_text(data, type, fd); }
static void cancel_source(struct source *source)
{
    struct channel *ch = &source->owner->channels[source->primary];
    if (ch->source == source) {
        ch->source = NULL;
        if (!ch->pending) ch->owned = false;
    }
    if (source->primary) zwp_primary_selection_source_v1_destroy(source->object);
    else wl_data_source_destroy(source->object);
    source->object = NULL;
}
static void data_cancel(void *data, struct wl_data_source *source)
{ (void)source; cancel_source(data); }
static void primary_cancel(void *data, struct zwp_primary_selection_source_v1 *source)
{ (void)source; cancel_source(data); }
static void data_target(void *data, struct wl_data_source *source, const char *type)
{ (void)data; (void)source; (void)type; }
static void source_event(void *data, struct wl_data_source *source)
{ (void)data; (void)source; }
static void source_action(void *data, struct wl_data_source *source, uint32_t action)
{ (void)data; (void)source; (void)action; }
static const struct wl_data_source_listener source_listener = {
    data_target, data_send, data_cancel, source_event, source_event, source_action
};
static const struct zwp_primary_selection_source_v1_listener primary_source_listener = {
    primary_send, primary_cancel
};
static void publish(struct xclip *c, bool primary)
{
    struct channel *ch = &c->channels[primary];
    if (!ch->pending) return;
    for (unsigned i = 0; i < SOURCES; ++i) if (!c->sources[i].object) {
        struct source *s = &c->sources[i];
        s->owner = c; s->primary = primary; s->size = ch->size;
        memcpy(s->bytes, ch->bytes, ch->size);
        if (primary) {
            s->object = zwp_primary_selection_device_manager_v1_create_source(c->primary_manager);
            if (!s->object) return;
            zwp_primary_selection_source_v1_add_listener(s->object, &primary_source_listener, s);
            zwp_primary_selection_source_v1_offer(s->object, utf8);
            zwp_primary_selection_source_v1_offer(s->object, plain);
            zwp_primary_selection_device_v1_set_selection(c->primary_device, s->object, ch->serial);
        } else {
            s->object = wl_data_device_manager_create_data_source(c->manager);
            if (!s->object) return;
            wl_data_source_add_listener(s->object, &source_listener, s);
            wl_data_source_offer(s->object, utf8); wl_data_source_offer(s->object, plain);
            wl_data_device_set_selection(c->device, s->object, ch->serial);
        }
        ch->source = s; ch->pending = false;
        return;
    }
    /* A burst of selection changes is coalesced until cancellation releases
     * a source slot. Every published source keeps immutable bytes. */
}
static void attach(struct xclip *c)
{
    if (!c->seat) return;
    if (c->manager && !c->device) {
        c->device = wl_data_device_manager_get_data_device(c->manager, c->seat);
        if (c->device) wl_data_device_add_listener(c->device, &device_listener, c);
    }
    if (c->primary_manager && !c->primary_device) {
        c->primary_device = zwp_primary_selection_device_manager_v1_get_device(c->primary_manager, c->seat);
        if (c->primary_device) zwp_primary_selection_device_v1_add_listener(c->primary_device, &primary_device_listener, c);
    }
}
static void seat_caps(void *data, struct wl_seat *seat, uint32_t caps)
{ (void)data; (void)seat; (void)caps; }
static const struct wl_seat_listener seat_listener = {.capabilities = seat_caps};
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *type, uint32_t version)
{
    struct xclip *c = data;
    if (!strcmp(type, "wl_seat") && !c->seat) {
        c->seat = wl_registry_bind(registry, name, &wl_seat_interface, 1); c->seat_name = name;
        if (c->seat) wl_seat_add_listener(c->seat, &seat_listener, c);
    } else if (!strcmp(type, "wl_data_device_manager") && !c->manager) {
        c->manager = wl_registry_bind(registry, name, &wl_data_device_manager_interface, version < 3 ? version : 3);
        c->manager_name = name;
    } else if (!strcmp(type, "zwp_primary_selection_device_manager_v1") && !c->primary_manager) {
        c->primary_manager = wl_registry_bind(registry, name, &zwp_primary_selection_device_manager_v1_interface, 1);
        c->primary_name = name;
    }
    attach(c);
}
static void drop_devices(struct xclip *c)
{
    end_read(c, XCLIP_IDLE);
    for (unsigned i = 0; i < OFFERS; ++i) destroy_offer(c, &c->offers[i]);
    for (unsigned i = 0; i < SOURCES; ++i) if (c->sources[i].object) cancel_source(&c->sources[i]);
    memset(c->channels, 0, sizeof(c->channels));
    for (unsigned i = 0; i < WRITERS; ++i) if (c->writers[i].fd >= 0) { close(c->writers[i].fd); c->writers[i].fd = -1; }
    if (c->device) {
        if (wl_data_device_get_version(c->device) >= 2) wl_data_device_release(c->device);
        else wl_data_device_destroy(c->device);
        c->device = NULL;
    }
    if (c->primary_device) zwp_primary_selection_device_v1_destroy(c->primary_device);
    c->primary_device = NULL;
}
static void removed(void *data, struct wl_registry *registry, uint32_t name)
{
    (void)registry;
    struct xclip *c = data;
    if (name != c->seat_name && name != c->manager_name && name != c->primary_name) return;
    drop_devices(c);
    if (name == c->seat_name && c->seat) { wl_seat_destroy(c->seat); c->seat = NULL; c->seat_name = 0; }
    if (name == c->manager_name && c->manager) { wl_data_device_manager_destroy(c->manager); c->manager = NULL; c->manager_name = 0; }
    if (name == c->primary_name && c->primary_manager) { zwp_primary_selection_device_manager_v1_destroy(c->primary_manager); c->primary_manager = NULL; c->primary_name = 0; }
    attach(c);
}
static const struct wl_registry_listener registry_listener = {global, removed};
struct xclip *xclip_create(struct wl_display *display)
{
    struct xclip *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->read_fd = -1;
    for (unsigned i = 0; i < WRITERS; ++i) c->writers[i].fd = -1;
    c->registry = wl_display_get_registry(display);
    if (!c->registry) { free(c); return NULL; }
    wl_registry_add_listener(c->registry, &registry_listener, c);
    return c;
}
void xclip_destroy(struct xclip *c)
{
    if (!c) return;
    drop_devices(c);
    for (unsigned i = 0; i < WRITERS; ++i) if (c->writers[i].fd >= 0) close(c->writers[i].fd);
    if (c->seat) wl_seat_destroy(c->seat);
    if (c->manager) wl_data_device_manager_destroy(c->manager);
    if (c->primary_manager) zwp_primary_selection_device_manager_v1_destroy(c->primary_manager);
    wl_registry_destroy(c->registry);
    free(c);
}
void xclip_focus(struct xclip *c, uint64_t destination, uint64_t epoch)
{
    if (!c || (c->destination == destination && c->epoch == epoch)) return;
    end_read(c, XCLIP_IDLE);
    c->destination = destination; c->epoch = epoch;
}
enum xclip_status xclip_request(struct xclip *c, bool primary)
{
    /* Missing optional primary-selection support is a true no-op, including
     * when a clipboard transfer is already pending. */
    if (primary && (!c || !c->primary_device)) return XCLIP_IDLE;
    if (!c) return XCLIP_UNAVAILABLE;
    end_read(c, XCLIP_IDLE);
    c->result = (struct xclip_result){.destination = c->destination, .epoch = c->epoch, .status = XCLIP_UNAVAILABLE};
    if (!c->destination) return c->result.status;
    struct channel *ch = &c->channels[primary];
    if (ch->owned) {
        c->result.size = ch->size; memcpy(c->result.bytes, ch->bytes, ch->size);
        return c->result.status = XCLIP_READY;
    }
    const struct offer *o = ch->offer;
    if (!o || (!o->utf8 && !o->plain)) return c->result.status;
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC)) return c->result.status = XCLIP_FAILED;
    int flags = fcntl(pipefd[0], F_GETFL);
    if (flags < 0 || fcntl(pipefd[0], F_SETFL, flags | O_NONBLOCK) < 0) {
        close(pipefd[0]); close(pipefd[1]); return c->result.status = XCLIP_FAILED;
    }
    if (primary) zwp_primary_selection_offer_v1_receive(o->object, o->utf8 ? utf8 : plain, pipefd[1]);
    else wl_data_offer_receive(o->object, o->utf8 ? utf8 : plain, pipefd[1]);
    close(pipefd[1]); c->read_fd = pipefd[0]; c->deadline = now() + DEADLINE_NS;
    return c->result.status = XCLIP_PENDING;
}
bool xclip_take(struct xclip *c, struct xclip_result *out)
{
    if (!c || !out || c->result.status == XCLIP_IDLE || c->result.status == XCLIP_PENDING) return false;
    *out = c->result; c->result.status = XCLIP_IDLE;
    return true;
}
bool xclip_copy(struct xclip *c, bool primary, uint32_t serial, const void *bytes, size_t size)
{
    if (!c || !serial || size > XCLIP_LIMIT || (size && !bytes) ||
        (primary ? !c->primary_device : !c->device)) return false;
    struct channel *ch = &c->channels[primary];
    ch->serial = serial; ch->size = size; ch->owned = true; ch->pending = true;
    if (size) memcpy(ch->bytes, bytes, size);
    publish(c, primary);
    return true;
}
/* Do not change the process SIGPIPE disposition for a clipboard consumer.
 * Block it in this thread and consume only a newly generated pending signal. */
static ssize_t write_pipe(int fd, const void *bytes, size_t size)
{
    sigset_t set, old, pending;
    sigemptyset(&set); sigaddset(&set, SIGPIPE);
    if (pthread_sigmask(SIG_BLOCK, &set, &old)) { errno = EIO; return -1; }
    sigpending(&pending);
    bool had_pipe = sigismember(&pending, SIGPIPE) == 1;
    ssize_t n = write(fd, bytes, size);
    int error = errno;
    if (n < 0 && error == EPIPE && !had_pipe) {
        struct timespec zero = {0};
        while (sigtimedwait(&set, NULL, &zero) < 0 && errno == EINTR) {}
    }
    pthread_sigmask(SIG_SETMASK, &old, NULL); errno = error;
    return n;
}
bool xclip_tick(struct xclip *c)
{
    if (!c) return false;
    uint64_t time = now();
    if (c->read_fd >= 0) {
        /* One extra byte distinguishes exactly-full text from truncation. */
        unsigned char bytes[XCLIP_LIMIT + 1];
        ssize_t n = read(c->read_fd, bytes, XCLIP_LIMIT + 1 - c->result.size);
        if (n > 0) {
            size_t keep = (size_t)n;
            if (keep > XCLIP_LIMIT - c->result.size) keep = XCLIP_LIMIT - c->result.size;
            memcpy(c->result.bytes + c->result.size, bytes, keep); c->result.size += keep;
            if (keep < (size_t)n) end_read(c, XCLIP_TRUNCATED);
        } else if (!n) end_read(c, XCLIP_READY);
        else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) end_read(c, XCLIP_FAILED);
        if (c->read_fd >= 0 && time >= c->deadline) end_read(c, XCLIP_TIMEOUT);
    }
    for (unsigned i = 0; i < WRITERS; ++i) {
        struct writer *w = &c->writers[i];
        if (w->fd < 0) continue;
        if (w->at < w->size) {
            ssize_t n = write_pipe(w->fd, w->bytes + w->at, w->size - w->at);
            if (n > 0) w->at += (size_t)n;
            else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) w->deadline = 0;
        }
        if (w->at == w->size || time >= w->deadline) { close(w->fd); w->fd = -1; }
    }
    publish(c, false); publish(c, true);
    bool changed = c->changed; c->changed = false;
    return changed;
}
bool xclip_busy(const struct xclip *c)
{
    if (!c) return false;
    if (c->read_fd >= 0 || c->channels[0].pending || c->channels[1].pending) return true;
    for (unsigned i = 0; i < WRITERS; ++i) if (c->writers[i].fd >= 0) return true;
    return false;
}

bool xclip_pending(const struct xclip *c)
{ return c && c->result.status == XCLIP_PENDING; }
