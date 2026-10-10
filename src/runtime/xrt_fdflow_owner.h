#ifndef XODB_RUNTIME_FDFLOW_OWNER_H
#define XODB_RUNTIME_FDFLOW_OWNER_H
#include "xrt_fdflow_count.h"
/* The stream worker is independent of procfs scanning. Publication arrays are
 * immutable while acquired. No IO under an acquire; release before requesting. */
struct xrt_fdflow_rate {
    double read, write;
};
struct xrt_fdflow_live {
    struct xrt_fdflow_snapshot stream; /* records omitted; owned CPU status */
    struct xrt_fdflow_counts counts;
    const struct xrt_fdflow_rate *rates; /* counts.row_count entries */
    struct xrt_perf_failure failure;
    enum xrt_status status;
    uint64_t generation, sequence, owner_cpu_ns;
    int requested;
};
struct xrt_fdflow_owner;
enum xrt_status xrt_fdflow_owner_create(const int32_t *scope_pids, uint32_t scope_count,
                                        struct xrt_fdflow_owner **);
/* Joins only this stream worker. fdactivity calls this from its background
 * cleanup path; a slow procfs scan never blocks GUI destruction. */
void xrt_fdflow_owner_destroy(struct xrt_fdflow_owner *);
/* Explicit caller authority/GUI action only. enable renews 3 seconds; zero
 * stops. Read-only consumers must never call this to renew capture. */
enum xrt_status xrt_fdflow_owner_request(struct xrt_fdflow_owner *, int enable);
/* Takes ownership on success, including while idle; newer polls replace old
 * pending ones. A capture rejects bindings from before its start. */
enum xrt_status xrt_fdflow_owner_bind(struct xrt_fdflow_owner *, struct xrt_fdflow_bindings *);
int xrt_fdflow_owner_acquire(struct xrt_fdflow_owner *, struct xrt_fdflow_live *);
void xrt_fdflow_owner_release(struct xrt_fdflow_owner *);
/* Copy an acquired publication (proportional to its live rows) so consumers
 * build graphs and treemaps after release, never under the drain's lock. */
struct xrt_fdflow_live *xrt_fdflow_live_copy(const struct xrt_fdflow_live *);
void xrt_fdflow_live_free(struct xrt_fdflow_live *);
#endif
