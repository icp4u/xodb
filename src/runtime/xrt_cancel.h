#ifndef XODB_RUNTIME_CANCEL_H
#define XODB_RUNTIME_CANCEL_H
#include <stdbool.h>

/* A terminal capability for one connection incarnation, independent of its
 * targets. Each holder retains a reference until its last access. Requesting
 * cancellation never takes a transport lock or closes a transport descriptor.
 * The wake stays readable so every waiter observes it. NULL means no cancel. */
struct xrt_cancel;
struct xrt_cancel *xrt_cancel_create(void);
struct xrt_cancel *xrt_cancel_retain(struct xrt_cancel *);
void xrt_cancel_release(struct xrt_cancel *);
void xrt_cancel_request(struct xrt_cancel *);
bool xrt_cancel_requested(const struct xrt_cancel *);
int xrt_cancel_fd(const struct xrt_cancel *);
#endif
