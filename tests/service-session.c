#define _GNU_SOURCE 1
/* Public API: compile with src/service/session.c. XSVC_TEST_INTERNAL instead
 * includes that same implementation to test otherwise unreachable counters. */
#ifdef XSVC_TEST_INTERNAL
#include "../src/service/session.c"
#else
#include "../src/service/session.h"
#endif
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "%s:%d: %s (errno %d)\n", \
    __FILE__, __LINE__, #x, errno); exit(1); } } while (0)
#define OK(x) CHECK((x) == XSVC_OK)
static char directory[PATH_MAX], path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static unsigned groups;

static struct xsvc_state state(struct xsvc *s)
{
    struct xsvc_state result;
    OK(xsvc_state(s, &result));
    return result;
}
static void unchanged(struct xsvc *s, struct xsvc_state before)
{
    struct xsvc_state after = state(s);
    CHECK(before.controller == after.controller && before.expires_ns == after.expires_ns &&
          before.revision == after.revision && before.latest_sequence == after.latest_sequence &&
          before.oldest_sequence == after.oldest_sequence && before.scope == after.scope &&
          before.peer_count == after.peer_count);
}
static int connect_client(const char *socket_path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    CHECK(fd >= 0);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    CHECK(strlen(socket_path) < sizeof(address.sun_path));
    strcpy(address.sun_path, socket_path);
    CHECK(connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0);
    return fd;
}
static int add(struct xsvc *s, uint64_t now, struct xsvc_peer *peer)
{
    int fd = connect_client(path);
    CHECK(xsvc_accept(s, now, peer) == 1);
    CHECK(peer->id > 0 && peer->id <= XSVC_MAX_ID);
    CHECK(fcntl(peer->fd, F_GETFD) & FD_CLOEXEC);
    CHECK(fcntl(peer->fd, F_GETFL) & O_NONBLOCK);
    return fd;
}
static void gone(void)
{
    struct stat st;
    CHECK(lstat(path, &st) == -1 && errno == ENOENT);
}
static void test_open(void)
{
    CHECK(!xsvc_open(NULL) && errno == EINVAL);
    CHECK(!xsvc_open("") && errno == EINVAL);
    CHECK(!xsvc_open("relative.sock") && errno == EINVAL);
    CHECK(!xsvc_open("/") && errno == EINVAL);
    CHECK(!xsvc_open("/.") && errno == EINVAL);
    CHECK(!xsvc_open("/..") && errno == EINVAL);
    char too_long[sizeof(((struct sockaddr_un *)0)->sun_path) + 1];
    memset(too_long, 'x', sizeof(too_long));
    too_long[0] = '/';
    too_long[sizeof(too_long)-1] = 0;
    CHECK(!xsvc_open(too_long) && errno == ENAMETOOLONG);
    int file = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    CHECK(file >= 0 && write(file, "keep", 4) == 4 && close(file) == 0);
    CHECK(!xsvc_open(path) && errno == EEXIST);
    struct stat before, after;
    CHECK(lstat(path, &before) == 0 && S_ISREG(before.st_mode));
    CHECK(unlink(path) == 0);
    CHECK(symlink("missing", path) == 0);
    CHECK(!xsvc_open(path) && errno == EEXIST);
    CHECK(lstat(path, &after) == 0 && S_ISLNK(after.st_mode));
    CHECK(unlink(path) == 0);
    struct xsvc *s = xsvc_open(path);
    CHECK(s);
    CHECK(lstat(path, &before) == 0 && S_ISSOCK(before.st_mode));
    CHECK((before.st_mode & 0777) == 0600 && before.st_uid == geteuid());
    CHECK(!xsvc_open(path) && errno == EEXIST);
    CHECK(lstat(path, &after) == 0 && before.st_ino == after.st_ino);
    struct xsvc_state initial = state(s);
    CHECK(initial.peer_count == 0 && initial.scope == XSVC_OBSERVE &&
          initial.controller == 0 && initial.expires_ns == 0 && initial.revision == 1 &&
          initial.latest_sequence == 0 && initial.oldest_sequence == 0);
    struct xsvc_peer untouched = {123, 456};
    CHECK(xsvc_accept(s, 0, &untouched) == 0);
    CHECK(untouched.id == 123 && untouched.fd == 456);
    CHECK(xsvc_accept(s, 0, NULL) == -1 && errno == EINVAL);
    unchanged(s, initial);
    xsvc_close(s);
    gone();
    xsvc_close(NULL);
    char longest[sizeof(((struct sockaddr_un *)0)->sun_path)];
    size_t prefix = strlen(directory);
    CHECK(prefix+2 < sizeof(longest));
    memcpy(longest, directory, prefix);
    longest[prefix] = '/';
    memset(longest+prefix+1, 's', sizeof(longest)-prefix-2);
    longest[sizeof(longest)-1] = 0;
    s = xsvc_open(longest);
    CHECK(s);
    xsvc_close(s);
    CHECK(lstat(longest, &after) == -1 && errno == ENOENT);
    ++groups;
}
static void test_open_failure_cleanup(void)
{
    pid_t child = fork();
    CHECK(child >= 0);
    if (!child) {
        struct rlimit limits;
        if (getrlimit(RLIMIT_NOFILE, &limits) != 0 || limits.rlim_cur < 16) _exit(21);
        limits.rlim_cur = 32;
        if (setrlimit(RLIMIT_NOFILE, &limits) != 0) _exit(22);
        int pool[32], count = 0;
        while (count < 32) {
            int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
            if (fd < 0) break;
            pool[count++] = fd;
        }
        if (errno != EMFILE || count < 2) _exit(23);
        /* Leave space for the directory and socket, but not the inode pin. */
        close(pool[--count]); close(pool[--count]);
        if (xsvc_open(path) != NULL || errno != EMFILE) _exit(24);
        struct stat st;
        if (lstat(path, &st) != -1 || errno != ENOENT) _exit(25);
        while (count) close(pool[--count]);
        struct xsvc *retry = xsvc_open(path);
        if (!retry) _exit(26);
        xsvc_close(retry);
        _exit(0);
    }
    int status;
    CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    gone();
    ++groups;
}
static void test_policy(void)
{
    struct xsvc *s = xsvc_open(path);
    CHECK(s);
    struct xsvc_peer a, b;
    int a_fd = add(s, 1, &a), b_fd = add(s, 2, &b);
    CHECK(a.id == 1 && b.id == 2);
    OK(xsvc_authorize(s, a.id, XSVC_OBSERVE, 2));
    CHECK(xsvc_check(s, a.id, 2) == XSVC_SCOPE_DENIED);
    CHECK(xsvc_claim(s, a.id, 100, 2) == XSVC_SCOPE_DENIED);
    OK(xsvc_tick(s, 3, XSVC_CONTROL));
    OK(xsvc_claim(s, a.id, 100, 4));
    CHECK(state(s).expires_ns == UINT64_C(100000004));
    const uint64_t lease = state(s).lease_id;
    CHECK(lease != 0);
    OK(xsvc_check(s, a.id, 5));
    CHECK(xsvc_check(s, b.id, 5) == XSVC_CONTROL_REQUIRED);
    CHECK(xsvc_authorize(s, a.id, XSVC_MUTATE, 5) == XSVC_SCOPE_DENIED);
    CHECK(xsvc_claim(s, b.id, 100, 6) == XSVC_CONTROLLER_BUSY);
    CHECK(xsvc_release(s, b.id, 6) == XSVC_CONTROL_REQUIRED);
    OK(xsvc_claim(s, a.id, 200, 7));
    CHECK(state(s).expires_ns == UINT64_C(200000007));
    CHECK(state(s).lease_id == lease);
    OK(xsvc_tick(s, 8, XSVC_CONTROL));
    CHECK(state(s).controller == a.id);
    OK(xsvc_check(s, a.id, UINT64_C(200000006)));
    CHECK(xsvc_check(s, a.id, UINT64_C(200000007)) == XSVC_CONTROL_REQUIRED);
    CHECK(state(s).controller == 0 && state(s).expires_ns == 0);
    OK(xsvc_claim(s, b.id, 100, UINT64_C(200000008)));
    OK(xsvc_tick(s, UINT64_C(200000009), XSVC_MUTATE));
    CHECK(state(s).controller == 0);
    OK(xsvc_claim(s, a.id, 100, UINT64_C(200000010)));
    OK(xsvc_authorize(s, a.id, XSVC_MUTATE, UINT64_C(200000011)));
    OK(xsvc_tick(s, UINT64_C(200000012), XSVC_CONTROL));
    CHECK(state(s).controller == 0);
    OK(xsvc_claim(s, a.id, 100, UINT64_C(200000013)));
    CHECK(state(s).lease_id != lease);
    OK(xsvc_release(s, a.id, UINT64_C(200000014)));
    CHECK(state(s).controller == 0);
    OK(xsvc_claim(s, b.id, 100, UINT64_C(200000015)));
    OK(xsvc_drop(s, b.id, UINT64_C(200000016)));
    CHECK(state(s).controller == 0 && state(s).peer_count == 1);
    CHECK(fcntl(b.fd, F_GETFD) == -1 && errno == EBADF);
    OK(xsvc_claim(s, a.id, 100, UINT64_C(200000017)));
    OK(xsvc_tick(s, UINT64_C(200000018), XSVC_OBSERVE));
    CHECK(state(s).controller == 0 && xsvc_check(s, a.id, UINT64_C(200000018)) == XSVC_SCOPE_DENIED);
    OK(xsvc_tick(s, UINT64_C(200000019), XSVC_CONTROL));
    OK(xsvc_claim(s, a.id, 100, UINT64_C(200000020)));
    const uint64_t before_release = state(s).lease_id;
    OK(xsvc_release(s, a.id, UINT64_C(200000021)));
    OK(xsvc_claim(s, a.id, 100, UINT64_C(200000022)));
    CHECK(state(s).lease_id != before_release);
    struct xsvc_event events[XSVC_EVENT_CAPACITY];
    size_t count = 0;
    bool gap = true;
    OK(xsvc_events(s, 0, events, XSVC_EVENT_CAPACITY, &count, &gap));
    CHECK(!gap && count > 10);
    bool kinds[7] = {false};
    for (size_t i = 0; i < count; ++i) {
        CHECK(events[i].sequence == i+1 && events[i].kind >= XSVC_CONNECTED && events[i].kind <= XSVC_SCOPE_CHANGED);
        kinds[events[i].kind] = true;
        if (i) CHECK(events[i].time_ns >= events[i-1].time_ns);
    }
    for (size_t i = 1; i <= XSVC_SCOPE_CHANGED; ++i) CHECK(kinds[i]);
    CHECK(close(a_fd) == 0 && close(b_fd) == 0);
    xsvc_close(s);
    gone();
    ++groups;
}
static void test_invalid(void)
{
    struct xsvc *s = xsvc_open(path);
    CHECK(s);
    struct xsvc_peer peer;
    int client = add(s, 1, &peer);
    OK(xsvc_tick(s, 2, XSVC_CONTROL));
    OK(xsvc_claim(s, peer.id, 100, 10));
    struct xsvc_state before = state(s);
    const uint64_t later = UINT64_C(200000010);
    CHECK(xsvc_claim(s, peer.id, 99, later) == XSVC_BAD_REQUEST);
    CHECK(xsvc_claim(s, peer.id, 60001, later) == XSVC_BAD_REQUEST);
    CHECK(xsvc_claim(s, peer.id, UINT32_MAX, later) == XSVC_BAD_REQUEST);
    CHECK(xsvc_claim(s, peer.id, 100, UINT64_MAX) == XSVC_BAD_REQUEST);
    CHECK(xsvc_claim(s, peer.id, 100, 9) == XSVC_BAD_REQUEST);
    CHECK(xsvc_claim(s, 0, 100, later) == XSVC_BAD_REQUEST);
    CHECK(xsvc_claim(s, XSVC_MAX_ID+1, 100, later) == XSVC_BAD_REQUEST);
    CHECK(xsvc_claim(s, 999, 100, later) == XSVC_NO_CLIENT);
    CHECK(xsvc_release(s, 999, later) == XSVC_NO_CLIENT);
    CHECK(xsvc_drop(s, 999, later) == XSVC_NO_CLIENT);
    CHECK(xsvc_check(s, 999, later) == XSVC_NO_CLIENT);
    CHECK(xsvc_authorize(s, peer.id, 3, later) == XSVC_BAD_REQUEST);
    CHECK(xsvc_tick(s, later, 3) == XSVC_BAD_REQUEST);
    CHECK(xsvc_tick(s, 9, XSVC_OBSERVE) == XSVC_BAD_REQUEST);
    struct xsvc_peer untouched = {123, 456};
    CHECK(xsvc_accept(s, 9, &untouched) == -1 && errno == EINVAL);
    CHECK(untouched.id == 123 && untouched.fd == 456);
    unchanged(s, before);
    CHECK(xsvc_state(s, NULL) == XSVC_BAD_REQUEST);
    struct xsvc_state sentinel = {.controller = 99};
    CHECK(xsvc_state(NULL, &sentinel) == XSVC_BAD_REQUEST && sentinel.controller == 99);
    CHECK(xsvc_claim(NULL, 1, 100, 1) == XSVC_BAD_REQUEST);
    CHECK(xsvc_peers(s, NULL, 1) == 0 && errno == EINVAL);
    unchanged(s, before);
    /* Invalid requests also did not advance the private monotonic clock. */
    OK(xsvc_check(s, peer.id, 11));
    OK(xsvc_tick(s, UINT64_MAX-UINT64_C(100000000), XSVC_CONTROL));
    OK(xsvc_claim(s, peer.id, 100, UINT64_MAX-UINT64_C(100000000)));
    CHECK(state(s).expires_ns == UINT64_MAX);
    CHECK(xsvc_check(s, peer.id, UINT64_MAX) == XSVC_CONTROL_REQUIRED);
    CHECK(close(client) == 0);
    xsvc_close(s);
    gone();
    ++groups;
}
static void test_owner_revoke(void)
{
    struct xsvc *s = xsvc_open(path);
    CHECK(s);
    struct xsvc_peer peer;
    int client = add(s, 1, &peer);
    OK(xsvc_tick(s, 2, XSVC_CONTROL));
    OK(xsvc_claim(s, peer.id, 100, 3));
    struct xsvc_state before = state(s);
    CHECK(xsvc_revoke(NULL, 4) == XSVC_BAD_REQUEST);
    CHECK(xsvc_revoke(s, 2) == XSVC_BAD_REQUEST);
    unchanged(s, before);
    /* A GUI can revoke+regrant within one input batch: final scope is unchanged,
     * but its explicit owner revocation must still invalidate the old lease. */
    OK(xsvc_revoke(s, 4));
    CHECK(state(s).controller == 0 && state(s).expires_ns == 0 && state(s).scope == XSVC_CONTROL);
    CHECK(xsvc_check(s, peer.id, 4) == XSVC_CONTROL_REQUIRED);
    struct xsvc_event e;
    size_t count;
    bool gap;
    OK(xsvc_events(s, before.latest_sequence, &e, 1, &count, &gap));
    CHECK(count == 1 && !gap && e.kind == XSVC_REVOKED && e.client_id == peer.id && e.time_ns == 4);
    before = state(s);
    OK(xsvc_revoke(s, 5));
    unchanged(s, before);
    OK(xsvc_claim(s, peer.id, 100, 6));
    before = state(s);
    OK(xsvc_revoke(s, UINT64_C(100000006)));
    CHECK(state(s).controller == 0 && state(s).scope == XSVC_CONTROL);
    OK(xsvc_events(s, before.latest_sequence, &e, 1, &count, &gap));
    CHECK(count == 1 && e.kind == XSVC_EXPIRED && e.client_id == peer.id);
    CHECK(state(s).latest_sequence == before.latest_sequence+1);
    CHECK(close(client) == 0);
    xsvc_close(s);
    gone();
    ++groups;
}
static void test_capacity(void)
{
    struct xsvc *s = xsvc_open(path);
    CHECK(s);
    int clients[XSVC_MAX_PEERS];
    struct xsvc_peer peers[XSVC_MAX_PEERS], rows[XSVC_MAX_PEERS+1];
    for (size_t i = 0; i < XSVC_MAX_PEERS; ++i) clients[i] = add(s, i, &peers[i]);
    rows[XSVC_MAX_PEERS] = (struct xsvc_peer){987, 654};
    CHECK(xsvc_peers(s, rows, XSVC_MAX_PEERS+1) == XSVC_MAX_PEERS);
    CHECK(rows[XSVC_MAX_PEERS].id == 987 && rows[XSVC_MAX_PEERS].fd == 654);
    CHECK(xsvc_peers(s, NULL, 0) == 0);
    int rejected = connect_client(path);
    struct xsvc_peer untouched = {123, 456};
    struct xsvc_state before = state(s);
    CHECK(xsvc_accept(s, XSVC_MAX_PEERS, &untouched) == 0);
    CHECK(untouched.id == 123 && untouched.fd == 456);
    unchanged(s, before);
    char byte;
    CHECK(read(rejected, &byte, 1) == 0 && close(rejected) == 0);
    OK(xsvc_drop(s, peers[2].id, 10));
    CHECK(close(clients[2]) == 0);
    clients[2] = add(s, 11, &peers[2]);
    CHECK(peers[2].id == XSVC_MAX_PEERS+1);
    for (size_t i = 0; i < XSVC_MAX_PEERS; ++i) CHECK(close(clients[i]) == 0);
    xsvc_close(s);
    gone();
    ++groups;
}
static void test_history(void)
{
    struct xsvc *s = xsvc_open(path);
    CHECK(s);
    struct xsvc_peer peer;
    int client = add(s, 0, &peer);
    OK(xsvc_tick(s, 1, XSVC_CONTROL));
    for (uint64_t i = 0; i < 80; ++i) {
        OK(xsvc_claim(s, peer.id, 100, 2+i*2));
        OK(xsvc_release(s, peer.id, 3+i*2));
    }
    struct xsvc_state final = state(s);
    CHECK(final.latest_sequence == 162 && final.oldest_sequence == 35 && final.revision == 163);
    struct xsvc_event events[XSVC_EVENT_CAPACITY];
    size_t count = 999;
    bool gap = false;
    OK(xsvc_events(s, 0, events, XSVC_EVENT_CAPACITY, &count, &gap));
    CHECK(gap && count == XSVC_EVENT_CAPACITY);
    for (size_t i = 0; i < count; ++i) CHECK(events[i].sequence == 35+i);
    OK(xsvc_events(s, 34, events, 2, &count, &gap));
    CHECK(!gap && count == 2 && events[0].sequence == 35 && events[1].sequence == 36);
    OK(xsvc_events(s, 161, events, 2, &count, &gap));
    CHECK(!gap && count == 1 && events[0].sequence == 162);
    OK(xsvc_events(s, 162, events, 2, &count, &gap));
    CHECK(!gap && count == 0);
    OK(xsvc_events(s, 0, NULL, 0, &count, &gap));
    CHECK(gap && count == 0);
    count = 999; gap = true; events[0].sequence = 777;
    CHECK(xsvc_events(s, 163, events, 1, &count, &gap) == XSVC_BAD_REQUEST);
    CHECK(xsvc_events(s, 0, events, XSVC_EVENT_CAPACITY+1, &count, &gap) == XSVC_BAD_REQUEST);
    CHECK(xsvc_events(s, 0, NULL, 1, &count, &gap) == XSVC_BAD_REQUEST);
    CHECK(xsvc_events(s, 0, events, 1, NULL, &gap) == XSVC_BAD_REQUEST);
    CHECK(xsvc_events(s, 0, events, 1, &count, NULL) == XSVC_BAD_REQUEST);
    CHECK(count == 999 && gap && events[0].sequence == 777);
    CHECK(close(client) == 0);
    xsvc_close(s);
    gone();
    ++groups;
}
static void test_fork_and_replacement(void)
{
    struct xsvc *s = xsvc_open(path);
    CHECK(s);
    struct xsvc_peer peer;
    int client = add(s, 0, &peer);
    struct stat original, preserved;
    CHECK(lstat(path, &original) == 0);
    pid_t child = fork();
    CHECK(child >= 0);
    if (!child) {
        struct xsvc_state sentinel = {.controller = 123};
        if (xsvc_state(s, &sentinel) != XSVC_BAD_REQUEST || sentinel.controller != 123) _exit(11);
        if (xsvc_tick(s, 1, XSVC_CONTROL) != XSVC_BAD_REQUEST ||
            xsvc_revoke(s, 1) != XSVC_BAD_REQUEST) _exit(12);
        xsvc_close(s);
        if (fcntl(peer.fd, F_GETFD) != -1 || errno != EBADF) _exit(13);
        if (lstat(path, &preserved) != 0 || preserved.st_ino != original.st_ino) _exit(14);
        close(client);
        int fresh = connect_client(path);
        if (write(fresh, "c", 1) != 1 || close(fresh) != 0) _exit(15);
        _exit(0);
    }
    int status;
    CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(lstat(path, &preserved) == 0 && original.st_ino == preserved.st_ino);
    struct xsvc_peer child_peer;
    CHECK(xsvc_accept(s, 0, &child_peer) == 1);
    struct ucred credentials;
    socklen_t credentials_size = sizeof(credentials);
    CHECK(getsockopt(child_peer.fd, SOL_SOCKET, SO_PEERCRED, &credentials, &credentials_size) == 0 &&
          credentials_size == sizeof(credentials) && credentials.uid == geteuid() && credentials.pid == child);
    CHECK(write(client, "x", 1) == 1);
    char byte;
    CHECK(read(peer.fd, &byte, 1) == 1 && byte == 'x');
    CHECK(close(client) == 0);
    CHECK(unlink(path) == 0);
    int file = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    CHECK(file >= 0 && write(file, "keep", 4) == 4);
    xsvc_close(s);
    CHECK(lstat(path, &preserved) == 0 && S_ISREG(preserved.st_mode));
    char data[4];
    CHECK(pread(file, data, sizeof(data), 0) == 4 && !memcmp(data, "keep", 4));
    CHECK(close(file) == 0 && unlink(path) == 0);
    s = xsvc_open(path);
    CHECK(s && unlink(path) == 0);
    struct xsvc *replacement = xsvc_open(path);
    CHECK(replacement && lstat(path, &original) == 0);
    xsvc_close(s);
    CHECK(lstat(path, &preserved) == 0 && original.st_ino == preserved.st_ino);
    client = add(replacement, 0, &peer);
    CHECK(close(client) == 0);
    xsvc_close(replacement);
    gone();
    ++groups;
}
#ifdef XSVC_TEST_INTERNAL
static void test_limits(void)
{
    struct xsvc *s = xsvc_open(path);
    CHECK(s && (fcntl(s->listener, F_GETFD) & FD_CLOEXEC) &&
          (fcntl(s->listener, F_GETFL) & O_NONBLOCK) && (fcntl(s->directory, F_GETFD) & FD_CLOEXEC) &&
          (fcntl(s->socket_entry, F_GETFD) & FD_CLOEXEC));
    struct stat pinned, entry;
    CHECK(fstat(s->socket_entry, &pinned) == 0 && lstat(path, &entry) == 0 &&
          S_ISSOCK(pinned.st_mode) && pinned.st_ino == entry.st_ino && pinned.st_dev == entry.st_dev);
    s->next_id = XSVC_MAX_ID;
    struct xsvc_peer peer;
    int client = add(s, 0, &peer);
    CHECK(peer.id == XSVC_MAX_ID);
    int pending = connect_client(path);
    struct xsvc_peer untouched = {123, 456};
    CHECK(xsvc_accept(s, 1, &untouched) == -1 && errno == EOVERFLOW);
    CHECK(untouched.id == 123 && untouched.fd == 456);
    CHECK(close(pending) == 0);
    OK(xsvc_tick(s, 1, XSVC_CONTROL));
    s->sequence = XSVC_MAX_ID-1;
    s->revision = XSVC_MAX_ID-1;
    s->event_count = 0;
    OK(xsvc_claim(s, peer.id, 100, 2));
    CHECK(s->sequence == XSVC_MAX_ID && s->revision == XSVC_MAX_ID);
    struct xsvc_state before = state(s);
    CHECK(xsvc_claim(s, peer.id, 100, 3) == XSVC_LIMIT);
    CHECK(xsvc_release(s, peer.id, 3) == XSVC_LIMIT);
    CHECK(xsvc_revoke(s, 3) == XSVC_LIMIT);
    CHECK(xsvc_revoke(s, UINT64_C(100000002)) == XSVC_LIMIT);
    CHECK(xsvc_drop(s, peer.id, 3) == XSVC_LIMIT);
    CHECK(xsvc_check(s, peer.id, 3) == XSVC_LIMIT);
    CHECK(xsvc_tick(s, 3, XSVC_MUTATE) == XSVC_LIMIT);
    CHECK(xsvc_tick(s, UINT64_C(100000002), XSVC_CONTROL) == XSVC_LIMIT);
    unchanged(s, before);
    struct xsvc_event e;
    size_t count;
    bool gap;
    OK(xsvc_events(s, XSVC_MAX_ID-1, &e, 1, &count, &gap));
    CHECK(count == 1 && e.sequence == XSVC_MAX_ID && !gap);
    OK(xsvc_events(s, XSVC_MAX_ID, &e, 1, &count, &gap));
    CHECK(count == 0 && !gap);
    CHECK(close(client) == 0);
    xsvc_close(s);
    gone();
    ++groups;
}
#endif
static void test_accept_pressure(void)
{
    const pid_t child = fork();
    CHECK(child >= 0);
    if (!child) {
        struct rlimit limit;
        CHECK(getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_max >= 64);
        limit.rlim_cur = 64;
        CHECK(setrlimit(RLIMIT_NOFILE, &limit) == 0);
        struct xsvc *s = xsvc_open(path);
        CHECK(s);
        struct xsvc_peer owner;
        const int first = add(s, 1, &owner);
        OK(xsvc_tick(s, 1, XSVC_CONTROL));
        OK(xsvc_claim(s, owner.id, 100, 1));
        const struct xsvc_state before = state(s);
        const int pending = connect_client(path);
        int fds[64];
        size_t count = 0;
        while (count < 64 && (fds[count] = dup(STDERR_FILENO)) >= 0)
            ++count;
        CHECK(errno == EMFILE && count < 64);
        struct xsvc_peer untouched = {123, 456};
        for (unsigned i = 1; i <= 8; ++i) {
            CHECK(xsvc_accept(s, 2, &untouched) == 0);
            CHECK(untouched.id == 123 && untouched.fd == 456);
            unchanged(s, before); /* Lease, peers and policy journal survive. */
            const struct xsvc_state after = state(s);
            CHECK(after.accept_error_count == i && after.last_accept_errno == EMFILE);
        }
        while (count)
            CHECK(close(fds[--count]) == 0);
        CHECK(xsvc_accept(s, 3, &untouched) == 1);
        CHECK(state(s).peer_count == 2 && state(s).controller == owner.id);
        OK(xsvc_check(s, owner.id, 3));
        CHECK(close(first) == 0 && close(pending) == 0);
        xsvc_close(s);
        _exit(0);
    }
    int status;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    gone();
    ++groups;
}

int main(void)
{
    const char *tmp = getenv("XODB_TEST_TMPDIR");
    if (!tmp || !*tmp) tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    int n = snprintf(directory, sizeof(directory), "%s/xsvc-XXXXXX", tmp);
    CHECK(n > 0 && (size_t)n < sizeof(directory) && mkdtemp(directory));
    /* Private IPC directory intentionally remains 0700. */
    n = snprintf(path, sizeof(path), "%s/session.sock", directory);
    CHECK(n > 0 && (size_t)n < sizeof(path));
    test_open();
    test_open_failure_cleanup();
    test_accept_pressure();
    test_policy();
    test_invalid();
    test_owner_revoke();
    test_capacity();
    test_history();
    test_fork_and_replacement();
#ifdef XSVC_TEST_INTERNAL
    test_limits();
#endif
    CHECK(rmdir(directory) == 0);
    printf("service-session: %u test groups passed (uid=%lu); cross-UID rejection requires a separate UID fixture\n", groups, (unsigned long)geteuid());
    return 0;
}
