#ifndef XODB_SERVICE_SESSION_H
#define XODB_SERVICE_SESSION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define XSVC_MAX_PEERS 8
#define XSVC_EVENT_CAPACITY 128
#define XSVC_MAX_ID UINT64_C(9007199254740991)
#define XSVC_MIN_TTL_MS 100
#define XSVC_MAX_TTL_MS 60000

/* One owner thread calls this API. No global registry, target access or worker
 * callbacks. The service owns every fd; peers only borrow them until drop/close.
 * Call tick with monotonic nanoseconds before reporting state. Backward time,
 * invalid arguments and unknown IDs never modify outputs or service state. */
struct xsvc;
enum xsvc_scope { XSVC_OBSERVE = 0, XSVC_CONTROL = 1, XSVC_MUTATE = 2 };
enum xsvc_result {
    XSVC_OK = 0,
    XSVC_BAD_REQUEST,
    XSVC_NO_CLIENT,
    XSVC_SCOPE_DENIED,
    XSVC_CONTROLLER_BUSY,
    XSVC_CONTROL_REQUIRED,
    XSVC_LIMIT
};
enum xsvc_event_kind {
    XSVC_CONNECTED = 1,
    XSVC_DISCONNECTED,
    XSVC_ACQUIRED, /* Includes explicit same-owner renewal. */
    XSVC_RELEASED,
    XSVC_EXPIRED,
    XSVC_SCOPE_CHANGED,
    XSVC_REVOKED /* Explicit owner/human revocation without a scope change. */
};
struct xsvc_peer { uint64_t id; int fd; };
struct xsvc_event {
    uint64_t sequence, time_ns, client_id;
    enum xsvc_event_kind kind;
};
struct xsvc_state {
    uint64_t controller, expires_ns, revision, latest_sequence, oldest_sequence;
    unsigned scope;
    size_t peer_count;
    uint64_t accept_error_count; /* Recoverable accept errors, saturates at XSVC_MAX_ID. */
    int last_accept_errno;      /* Most recent recoverable error; 0 before any. */
};

/* Linux pathname AF_UNIX only: absolute, nonempty, shorter than sun_path.
 * Refuses all existing entries. Creates mode 0600, nonblocking/CLOEXEC; accepts
 * only the effective UID captured at open. Caller supplies an owned directory.
 * NULL reports errno. No umask change or stale-socket removal is performed. */
struct xsvc *xsvc_open(const char *path);
/* In a fork child, closes inherited descriptors without unlinking the parent's
 * socket. Other operations reject inherited handles. Parent cleanup preserves
 * an entry replaced since bind (device/inode/type checked before unlink). */
void xsvc_close(struct xsvc *service);
/* At most one accept syscall per call. 1 fills out, 0 means no peer or one
 * rejected peer, including transient resource/protocol errors counted in state;
 * -1 reports a fatal errno. out is unchanged unless result is 1. */
int xsvc_accept(struct xsvc *service, uint64_t now_ns, struct xsvc_peer *out);
enum xsvc_result xsvc_drop(struct xsvc *service, uint64_t id, uint64_t now_ns);
/* Returns rows copied, up to capacity. NULL out requires zero capacity. */
size_t xsvc_peers(const struct xsvc *service, struct xsvc_peer *out, size_t capacity);
enum xsvc_result xsvc_tick(struct xsvc *service, uint64_t now_ns, unsigned scope);
enum xsvc_result xsvc_claim(struct xsvc *service, uint64_t id, uint32_t ttl_ms,
                             uint64_t now_ns);
enum xsvc_result xsvc_release(struct xsvc *service, uint64_t id, uint64_t now_ns);
/* Owner/human revocation, independent of peer authorization. If already expired,
 * emits EXPIRED only; otherwise emits REVOKED for the old owner. No owner is a
 * no-op. Useful when several human scope toggles restore the original ceiling. */
enum xsvc_result xsvc_revoke(struct xsvc *service, uint64_t now_ns);
/* check is authorize(required_scope=CONTROL). Observe reads need no lease;
 * control/mutate require both the global scope ceiling and this peer's lease. */
enum xsvc_result xsvc_check(struct xsvc *service, uint64_t id, uint64_t now_ns);
enum xsvc_result xsvc_authorize(struct xsvc *service, uint64_t id,
                                 unsigned required_scope, uint64_t now_ns);
enum xsvc_result xsvc_state(const struct xsvc *service, struct xsvc_state *out);
/* after is an exclusive cursor. Future cursors, capacity>128, invalid pointers
 * fail with outputs unchanged. gap says older records were evicted; returned
 * events then begin at oldest_sequence. count may be zero. */
enum xsvc_result xsvc_events(const struct xsvc *service, uint64_t after,
                              struct xsvc_event *out, size_t capacity,
                              size_t *count, bool *gap);

/* Initially scope=OBSERVE, revision=1, no peers/controller/events. Each event
 * advances revision and sequence once; IDs/revisions/sequences stay exact in
 * JSON (<=2^53-1). Exhaustion fails closed, never wraps. Expiry happens at >=
 * deadline. Drop revokes its controller with DISCONNECTED; any scope change
 * revokes with SCOPE_CHANGED (client_id names the revoked owner, or zero).
 * Tick/claim/release/check may first emit EXPIRED. Rejected policy requests can
 * therefore observe expiry, while invalid requests cannot advance state. */
#endif
