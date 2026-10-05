#ifndef XODB_RUNTIME_PERF_REMOTE_H
#define XODB_RUNTIME_PERF_REMOTE_H
#include "xrt_perf.h"
#include "xrt_allocations.h"
#include "xrt_uprobes.h"
#include "xrt_target.h"
#include "rpc.h"
struct xrt_allocations *xrt_allocations_remote(struct xrt_perf *);
struct xrt_perf *xrt_remote_allocations_start(const struct xrt_target *,
                                              const struct xrt_allocation_config *,
                                              const struct xrt_mapping *, const char *,
                                              struct xrt_perf_failure *);
/* Shared verified-file uprobe engine; function mode has no allocator-kind semantics. */
struct xrt_allocations *xrt_uprobes_start_local(const struct xrt_target *,
                                               const struct xrt_allocation_config *,
                                               const struct xrt_mapping *, const char *, bool,
                                               struct xrt_perf_failure *);
struct xrt_perf *xrt_remote_functions_start(const struct xrt_target *,
                                            const struct xrt_allocation_config *,
                                            const struct xrt_mapping *, const char *,
                                            struct xrt_perf_failure *);
struct xrt_perf *xrt_remote_cpu_start(const struct xrt_target *, const struct xrt_cpu_config *,
                                      struct xrt_cpu_acceptance *, struct xrt_perf_failure *);
struct xrt_perf *xrt_remote_syscalls_start(const struct xrt_target *, int32_t, const int32_t *,
                                           size_t, uint16_t *, uint16_t *,
                                           struct xrt_perf_failure *);
bool xrt_remote_perf_op(struct xrt_perf *, uint16_t, uint64_t, struct xrt_perf_failure *);
void xrt_remote_perf_refresh(struct xrt_perf *);
void xrt_remote_perf_destroy(struct xrt_perf *);
bool xrt_remote_perf_thread(const struct xrt_perf *, size_t, struct xrt_perf_thread *);
enum xrt_perf_drain_status xrt_remote_perf_drain(struct xrt_perf *, xrt_perf_decoder, void *);
struct xrt_agent_perf;
struct xrt_agent_perf *xrt_agent_perf_create(void);
void xrt_agent_perf_destroy(struct xrt_agent_perf *);
void xrt_agent_perf_observe(struct xrt_agent_perf *, struct xrt_target *, const struct xrt_thread *,
                            bool);
bool xrt_agent_perf_uses(struct xrt_agent_perf *, const struct xrt_target *);
enum xrt_status xrt_agent_perf_dispatch(struct xrt_agent_perf *, struct xrt_target *, uint16_t,
                                        const uint64_t *, void *, size_t, uint64_t *, void *,
                                        size_t *);
#endif
