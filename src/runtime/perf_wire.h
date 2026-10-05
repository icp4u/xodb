#ifndef XODB_RUNTIME_PERF_WIRE_H
#define XODB_RUNTIME_PERF_WIRE_H
#include "xrt_perf.h"
#include "xrt_wire.h"
void xrt_wire_perf_attr(struct xrt_codec *, struct xrt_perf_attr *);
void xrt_wire_perf_info(struct xrt_codec *, struct xrt_perf_info *);
void xrt_wire_perf_thread(struct xrt_codec *, struct xrt_perf_thread *);
void xrt_wire_cpu_config(struct xrt_codec *, struct xrt_cpu_config *, int32_t *tids);
void xrt_wire_cpu_acceptance(struct xrt_codec *, struct xrt_cpu_acceptance *);
/* Remote failures retain category, errno, TID and rollback count. Strings are
 * stable runtime diagnostics, so callers may retain them after handle close. */
void xrt_wire_perf_failure(struct xrt_codec *, struct xrt_perf_failure *);
#endif
