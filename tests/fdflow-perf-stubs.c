/* The focused local collector tests must never enter a remote transport. */
#include "check.h"
#include "perf_remote.h"
uint64_t xrt_target_timestamp(const struct xrt_target *t, uint64_t producer)
{
    CHECK(!t);
    return producer;
}
bool xrt_remote_perf_op(struct xrt_perf *p, uint16_t op, uint64_t arg, struct xrt_perf_failure *f) {
    (void)p;
    (void)op;
    (void)arg;
    (void)f;
    CHECK(0);
    return false;
}
void xrt_remote_perf_refresh(struct xrt_perf *p) {
    (void)p;
    CHECK(0);
}
void xrt_remote_perf_destroy(struct xrt_perf *p) {
    (void)p;
    CHECK(0);
}
bool xrt_remote_perf_thread(const struct xrt_perf *p, size_t i, struct xrt_perf_thread *t) {
    (void)p;
    (void)i;
    (void)t;
    CHECK(0);
    return false;
}
enum xrt_perf_drain_status xrt_remote_perf_drain(struct xrt_perf *p, xrt_perf_decoder d, void *c) {
    (void)p;
    (void)d;
    (void)c;
    CHECK(0);
    return XRT_PERF_DRAIN_MALFORMED;
}
