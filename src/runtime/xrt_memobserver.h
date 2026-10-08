#ifndef XODB_RUNTIME_MEMOBSERVER_H
#define XODB_RUNTIME_MEMOBSERVER_H
#include "xrt_memstat.h"

#define XRT_MEM_SCOPES 4u
struct xrt_memobserver;
struct xrt_mem_scope {
    uint64_t ticket, sequence, sampled_ns, demand_until, bound_start;
    struct xrt_mem_request request;
    const struct xrt_mem_process *snapshot, *previous;
    uint64_t delta_interval_ns, refresh_ns;
    int32_t error;
    uint8_t sampling, cost_limited;
};
struct xrt_mem_view {
    uint64_t system_sequence, system_sampled_ns, owner_cpu_ns, system_refresh_ns;
    const struct xrt_mem_system *system;
    int32_t system_error;
    uint8_t system_cost_limited;
    struct xrt_mem_scope scopes[XRT_MEM_SCOPES];
};
/* One worker owns at most four bounded process/range caches and one system
 * cache. Reads do not collect. Requests renew a three-second demand lease;
 * collection is at most once per second per cache, with no catch-up scans.
 * Expensive sources adapt to a target of 8 ms CPU per second per scope;
 * refresh_ns and cost_limited expose the actual period and CPU decision.
 * Publications retain explicit page-scan coverage and partial states.
 * Metadata-only requests can reuse an existing page-state scope. */
/* Cost-derived period, bounded to 1..60 seconds; CPU time, never wall time. */
uint64_t xrt_memobserver_period(uint64_t cpu_ns);
struct xrt_memobserver *xrt_memobserver_open(const struct xrt_mem_roots *roots,
    const struct xrt_mem_limits *limits);
int xrt_memobserver_system(struct xrt_memobserver *observer);
/* Returns a stable nonzero ticket, or zero for invalid input/full live cache.
 * A request with start_ticks zero binds once and never follows PID reuse. */
uint64_t xrt_memobserver_process(struct xrt_memobserver *observer,
    const struct xrt_mem_request *request);
/* A successful acquire holds the publication lock. Pointers remain valid
 * until release. Never collect, block on IO, or request while holding it. */
int xrt_memobserver_acquire(struct xrt_memobserver *observer, struct xrt_mem_view *view);
void xrt_memobserver_release(struct xrt_memobserver *observer);
void xrt_memobserver_close(struct xrt_memobserver *observer);
#endif
