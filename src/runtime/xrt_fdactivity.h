#ifndef XODB_RUNTIME_FDACTIVITY_H
#define XODB_RUNTIME_FDACTIVITY_H
/* One background owner for bounded polling and one explicit event scope.
 * Request/acquire do no procfs or perf operations and never wait for a scan.
 * Every GUI/MCP consumer borrows this owner, not a private collector. */
#include "xrt_fdevent.h"
#include "xrt_fdscan.h"
struct xrt_fdactivity;
struct xrt_fdactivity_request {
    uint32_t interval_ms; /* 250 or 1000; active faster requests win for 3s */
    int32_t event_pid;    /* zero: polling only; positive: explicit event scope */
    uint64_t event_start;
    int stop_events; /* explicit authorized stop; observers leave this zero */
};
struct xrt_fdactivity_view {
    const struct xrt_fd_snapshot *poll; /* NULL until the first successful poll */
    struct xrt_fdevent_snapshot event;
    enum xrt_status poll_status, event_status;
    struct xrt_perf_failure event_failure;
    uint64_t generation, event_generation, event_sequence, requested_event_generation, updated_ns, owner_cpu_ns;
    uint32_t interval_ms;
    int poll_active, event_requested;
};
enum xrt_status xrt_fdactivity_create(struct xrt_fdactivity **);
/* Publish stop and return; the single worker frees its resources on return
 * from any current scan. No calls/borrowed views are allowed after destroy. */
void xrt_fdactivity_destroy(struct xrt_fdactivity *);
/* A positive event_pid starts/renews costly host-wide syscall tracing. Callers
 * must require explicit UI consent or current controller authorization; cache
 * readers MUST NOT submit event demand. A zero-pid poll never renews events.
 * XRT_INVALID_STATE means a different pid/start event scope is still active.
 * XRT_STALE_SNAPSHOT means a short publication lock is busy; retry later. */
enum xrt_status xrt_fdactivity_request(struct xrt_fdactivity *,
                                       const struct xrt_fdactivity_request *);
/* A successful acquire holds the publication lock. Borrowed pointers remain
 * valid until release; copy/serialize a bounded page, never do IO while held.
 * Do not nest acquire/request, call destroy, or retain pointers past release. */
int xrt_fdactivity_acquire(struct xrt_fdactivity *, struct xrt_fdactivity_view *);
void xrt_fdactivity_release(struct xrt_fdactivity *);
#endif
