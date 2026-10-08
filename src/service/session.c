#define _GNU_SOURCE 1
#include "session.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

struct xsvc {
    int listener, directory, socket_entry;
    pid_t owner;
    uid_t uid;
    char name[sizeof(((struct sockaddr_un *)0)->sun_path)];
    dev_t device;
    ino_t inode;
    bool bound;
    struct xsvc_peer peers[XSVC_MAX_PEERS];
    struct xsvc_event events[XSVC_EVENT_CAPACITY];
    size_t peer_count, event_count;
    uint64_t next_id, now_ns, controller, expires_ns, revision, sequence, lease_id;
    unsigned scope;
    uint64_t accept_error_count;
    int last_accept_errno;
};

static bool owned(const struct xsvc *s)
{
    return s && s->owner == getpid() && s->uid == geteuid();
}

static bool same_socket(const struct xsvc *s)
{
    struct stat st;
    return s->bound && fstatat(s->directory, s->name, &st, AT_SYMLINK_NOFOLLOW) == 0 &&
           S_ISSOCK(st.st_mode) && st.st_dev == s->device && st.st_ino == s->inode;
}

void xsvc_close(struct xsvc *s)
{
    if (!s)
        return;
    const int saved = errno;
    for (size_t i = 0; i < XSVC_MAX_PEERS; ++i)
        if (s->peers[i].id)
            close(s->peers[i].fd);
    if (s->listener >= 0)
        close(s->listener);
    if (s->owner == getpid() && same_socket(s))
        unlinkat(s->directory, s->name, 0);
    if (s->socket_entry >= 0)
        close(s->socket_entry);
    if (s->directory >= 0)
        close(s->directory);
    free(s);
    errno = saved;
}

struct xsvc *xsvc_open(const char *path)
{
    const size_t limit = sizeof(((struct sockaddr_un *)0)->sun_path);
    if (!path || path[0] != '/') {
        errno = EINVAL;
        return NULL;
    }
    const size_t length = strnlen(path, limit);
    if (length == limit) {
        errno = ENAMETOOLONG;
        return NULL;
    }
    const char *name = strrchr(path, '/') + 1;
    if (!*name || !strcmp(name, ".") || !strcmp(name, "..")) {
        errno = EINVAL;
        return NULL;
    }
    struct xsvc *s = calloc(1, sizeof(*s));
    if (!s)
        return NULL;
    s->listener = s->directory = s->socket_entry = -1;
    s->owner = getpid();
    s->uid = geteuid();
    s->next_id = s->revision = 1;
    memcpy(s->name, name, strlen(name) + 1);
    char parent[sizeof(((struct sockaddr_un *)0)->sun_path)];
    size_t parent_length = (size_t)(name - path);
    memcpy(parent, path, parent_length);
    parent[parent_length] = 0;
    s->directory = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (s->directory < 0)
        goto fail;
    struct stat st;
    if (fstatat(s->directory, s->name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
        errno = EEXIST;
        goto fail;
    }
    if (errno != ENOENT)
        goto fail;
    s->listener = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (s->listener < 0)
        goto fail;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    memcpy(address.sun_path, path, length + 1);
    if (bind(s->listener, (struct sockaddr *)&address,
             (socklen_t)(offsetof(struct sockaddr_un, sun_path) + length + 1)) < 0)
        goto fail;
    if (fstatat(s->directory, s->name, &st, AT_SYMLINK_NOFOLLOW) < 0)
        goto fail;
    if (!S_ISSOCK(st.st_mode) || st.st_uid != s->uid) {
        errno = ESTALE;
        goto fail;
    }
    s->device = st.st_dev;
    s->inode = st.st_ino;
    s->bound = true;
    /* Pin the filesystem inode until cleanup. Otherwise unlinking our socket
     * could let a replacement reuse its inode and pass the identity check.
     * Record ownership first so EMFILE here still removes the just-bound path. */
    s->socket_entry = openat(s->directory, s->name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (s->socket_entry < 0 || fstat(s->socket_entry, &st) < 0)
        goto fail;
    if (!S_ISSOCK(st.st_mode) || st.st_dev != s->device || st.st_ino != s->inode) {
        errno = ESTALE;
        goto fail;
    }
    /* No connections are possible until listen. Do not change process umask. */
    if (fchmodat(s->directory, s->name, 0600, 0) < 0)
        goto fail;
    if (!same_socket(s)) {
        errno = ESTALE;
        goto fail;
    }
    if (listen(s->listener, XSVC_MAX_PEERS) < 0)
        goto fail;
    return s;
fail:
    xsvc_close(s);
    return NULL;
}

static bool room(const struct xsvc *s, unsigned count)
{
    return s->sequence <= XSVC_MAX_ID - count && s->revision <= XSVC_MAX_ID - count;
}

static void event(struct xsvc *s, uint64_t now, uint64_t id, enum xsvc_event_kind kind)
{
    ++s->sequence;
    ++s->revision;
    s->events[(s->sequence - 1) % XSVC_EVENT_CAPACITY] =
        (struct xsvc_event){s->sequence, now, id, kind};
    if (s->event_count < XSVC_EVENT_CAPACITY)
        ++s->event_count;
}

static bool due(const struct xsvc *s, uint64_t now)
{
    return s->controller && now >= s->expires_ns;
}

static void advance(struct xsvc *s, uint64_t now)
{
    s->now_ns = now;
    if (due(s, now)) {
        event(s, now, s->controller, XSVC_EXPIRED);
        s->controller = s->expires_ns = 0;
    }
}

static struct xsvc_peer *find(struct xsvc *s, uint64_t id)
{
    for (size_t i = 0; i < XSVC_MAX_PEERS; ++i)
        if (s->peers[i].id == id)
            return &s->peers[i];
    return NULL;
}

static enum xsvc_result valid(struct xsvc *s, uint64_t id, uint64_t now)
{
    if (!owned(s) || !id || id > XSVC_MAX_ID || now < s->now_ns)
        return XSVC_BAD_REQUEST;
    return find(s, id) ? XSVC_OK : XSVC_NO_CLIENT;
}

int xsvc_accept(struct xsvc *s, uint64_t now, struct xsvc_peer *out)
{
    if (!owned(s) || !out || now < s->now_ns) {
        errno = EINVAL;
        return -1;
    }
    if (s->next_id > XSVC_MAX_ID || !room(s, 1 + (unsigned)due(s, now))) {
        errno = EOVERFLOW;
        return -1;
    }
    const int fd = accept4(s->listener, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (fd < 0) {
        if (errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM ||
            errno == EPROTO) {
            /* Resource pressure must not tear down targets or existing peers.
             * A saturating counter is observable without a log/journal flood. */
            if (s->accept_error_count < XSVC_MAX_ID)
                ++s->accept_error_count;
            s->last_accept_errno = errno;
            return 0;
        }
        return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ||
                       errno == ECONNABORTED ? 0 : -1;
    }
    struct ucred credentials;
    socklen_t size = sizeof(credentials);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &size) < 0 ||
        size != sizeof(credentials) || credentials.uid != s->uid ||
        s->peer_count == XSVC_MAX_PEERS) {
        close(fd);
        return 0;
    }
    advance(s, now);
    struct xsvc_peer *peer = find(s, 0);
    *peer = (struct xsvc_peer){s->next_id++, fd};
    ++s->peer_count;
    event(s, now, peer->id, XSVC_CONNECTED);
    *out = *peer;
    return 1;
}

enum xsvc_result xsvc_drop(struct xsvc *s, uint64_t id, uint64_t now)
{
    enum xsvc_result result = valid(s, id, now);
    if (result != XSVC_OK)
        return result;
    if (!room(s, 1 + (unsigned)due(s, now)))
        return XSVC_LIMIT;
    advance(s, now);
    struct xsvc_peer *peer = find(s, id);
    close(peer->fd);
    *peer = (struct xsvc_peer){0};
    --s->peer_count;
    if (s->controller == id)
        s->controller = s->expires_ns = 0;
    event(s, now, id, XSVC_DISCONNECTED);
    return XSVC_OK;
}

size_t xsvc_peers(const struct xsvc *s, struct xsvc_peer *out, size_t capacity)
{
    if (!owned(s) || (capacity && !out)) {
        errno = EINVAL;
        return 0;
    }
    size_t count = 0;
    for (size_t i = 0; i < XSVC_MAX_PEERS && count < capacity; ++i)
        if (s->peers[i].id)
            out[count++] = s->peers[i];
    return count;
}

enum xsvc_result xsvc_tick(struct xsvc *s, uint64_t now, unsigned scope)
{
    if (!owned(s) || now < s->now_ns || scope > XSVC_MUTATE)
        return XSVC_BAD_REQUEST;
    const bool changed = scope != s->scope;
    if (!room(s, (unsigned)due(s, now) + (unsigned)changed))
        return XSVC_LIMIT;
    advance(s, now);
    if (changed) {
        event(s, now, s->controller, XSVC_SCOPE_CHANGED);
        s->scope = scope;
        s->controller = s->expires_ns = 0;
    }
    return XSVC_OK;
}

enum xsvc_result xsvc_claim(struct xsvc *s, uint64_t id, uint32_t ttl, uint64_t now)
{
    enum xsvc_result result = valid(s, id, now);
    const uint64_t duration = (uint64_t)ttl * UINT64_C(1000000);
    if (ttl < XSVC_MIN_TTL_MS || ttl > XSVC_MAX_TTL_MS || now > UINT64_MAX - duration)
        return XSVC_BAD_REQUEST;
    if (result != XSVC_OK)
        return result;
    if (!room(s, 1 + (unsigned)due(s, now)))
        return XSVC_LIMIT;
    advance(s, now);
    if (s->scope == XSVC_OBSERVE)
        return XSVC_SCOPE_DENIED;
    if (s->controller && s->controller != id)
        return XSVC_CONTROLLER_BUSY;
    if (!s->controller) s->lease_id = s->sequence + 1;
    s->controller = id;
    s->expires_ns = now + duration;
    event(s, now, id, XSVC_ACQUIRED);
    return XSVC_OK;
}

enum xsvc_result xsvc_release(struct xsvc *s, uint64_t id, uint64_t now)
{
    enum xsvc_result result = valid(s, id, now);
    if (result != XSVC_OK)
        return result;
    if (!room(s, 1 + (unsigned)due(s, now)))
        return XSVC_LIMIT;
    advance(s, now);
    if (s->controller != id)
        return XSVC_CONTROL_REQUIRED;
    s->controller = s->expires_ns = 0;
    event(s, now, id, XSVC_RELEASED);
    return XSVC_OK;
}

enum xsvc_result xsvc_revoke(struct xsvc *s, uint64_t now)
{
    if (!owned(s) || now < s->now_ns)
        return XSVC_BAD_REQUEST;
    /* A due lease emits EXPIRED instead; either path needs just one record. */
    if (!room(s, s->controller ? 1 : 0))
        return XSVC_LIMIT;
    advance(s, now);
    if (s->controller) {
        event(s, now, s->controller, XSVC_REVOKED);
        s->controller = s->expires_ns = 0;
    }
    return XSVC_OK;
}

enum xsvc_result xsvc_authorize(struct xsvc *s, uint64_t id, unsigned required, uint64_t now)
{
    enum xsvc_result result = valid(s, id, now);
    if (required > XSVC_MUTATE)
        return XSVC_BAD_REQUEST;
    if (result != XSVC_OK)
        return result;
    if (!room(s, due(s, now) || required != XSVC_OBSERVE ? 1 : 0))
        return XSVC_LIMIT;
    advance(s, now);
    if (required > s->scope)
        return XSVC_SCOPE_DENIED;
    return required == XSVC_OBSERVE || s->controller == id ? XSVC_OK : XSVC_CONTROL_REQUIRED;
}

enum xsvc_result xsvc_check(struct xsvc *s, uint64_t id, uint64_t now)
{
    return xsvc_authorize(s, id, XSVC_CONTROL, now);
}

enum xsvc_result xsvc_state(const struct xsvc *s, struct xsvc_state *out)
{
    if (!owned(s) || !out)
        return XSVC_BAD_REQUEST;
    *out = (struct xsvc_state){.controller = s->controller,
                                .expires_ns = s->expires_ns,
                                .lease_id = s->lease_id,
                                .revision = s->revision,
                                .latest_sequence = s->sequence,
                                .oldest_sequence = s->event_count ? s->sequence - s->event_count + 1 : 0,
                                .scope = s->scope,
                                .peer_count = s->peer_count,
                                .accept_error_count = s->accept_error_count,
                                .last_accept_errno = s->last_accept_errno};
    return XSVC_OK;
}

enum xsvc_result xsvc_events(const struct xsvc *s, uint64_t after,
                              struct xsvc_event *out, size_t capacity,
                              size_t *count, bool *gap)
{
    if (!owned(s) || !count || !gap || (capacity && !out) ||
        capacity > XSVC_EVENT_CAPACITY || after > s->sequence)
        return XSVC_BAD_REQUEST;
    const uint64_t oldest = s->event_count ? s->sequence - s->event_count + 1 : 1;
    const bool missing = after < oldest - 1;
    uint64_t next = missing ? oldest : after + 1;
    size_t written = 0;
    while (next <= s->sequence && written < capacity) {
        out[written++] = s->events[(next - 1) % XSVC_EVENT_CAPACITY];
        ++next;
    }
    *count = written;
    *gap = missing;
    return XSVC_OK;
}

static bool job_owner_valid(struct xsvc_job_owner owner) {
    if (owner.kind == XSVC_JOB_SHARED) return owner.client > 0 && owner.client <= XSVC_MAX_ID;
    return (owner.kind == XSVC_JOB_HUMAN || owner.kind == XSVC_JOB_STDIO) && owner.client == 0;
}
bool xsvc_job_may_change(struct xsvc_job_owner owner,
                          struct xsvc_job_owner requester, bool controller) {
    if (!job_owner_valid(owner) || !job_owner_valid(requester)) return false;
    return requester.kind == XSVC_JOB_HUMAN || controller ||
        (owner.kind == requester.kind && owner.client == requester.client);
}
