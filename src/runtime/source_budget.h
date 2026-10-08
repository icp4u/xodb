#ifndef XODB_SOURCE_BUDGET_H
#define XODB_SOURCE_BUDGET_H
#include "xrt_source.h"

/* Connection-wide rate window, not a lifetime quota. The clock is supplied
 * so its expiry boundary can be tested without sleeps or privileged hooks. */
struct xrt_source_budget { uint64_t since; unsigned requests; };
static inline int xrt_source_budget_take(struct xrt_source_budget *budget, uint64_t now)
{
    if (!budget->requests || (now >= budget->since && now-budget->since >= XRT_SOURCE_WINDOW_NS)) {
        budget->since=now; budget->requests=0;
    }
    if (budget->requests >= XRT_SOURCE_REQUESTS) return 0;
    ++budget->requests; return 1;
}
#endif
