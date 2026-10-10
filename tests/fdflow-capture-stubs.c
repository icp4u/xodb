/* Polling owner tests may create an idle worker, but must never enable capture. */
#include "check.h"
#include "xrt_fdflow.h"
enum xrt_status xrt_fdflow_open(const struct xrt_fdflow_options *o, struct xrt_fdflow **p,
                                struct xrt_perf_failure *f) {
    (void)o;
    (void)p;
    (void)f;
    CHECK(0);
    return XRT_INVALID_STATE;
}
void xrt_fdflow_stop(struct xrt_fdflow *p) {
    (void)p;
    CHECK(0);
}
void xrt_fdflow_close(struct xrt_fdflow *p) { CHECK(!p); }
enum xrt_status xrt_fdflow_drain(struct xrt_fdflow *p, struct xrt_fdflow_snapshot *s) {
    (void)p;
    (void)s;
    CHECK(0);
    return XRT_INVALID_STATE;
}
