#define _GNU_SOURCE 1
#include "xrt_cancel.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>

struct xrt_cancel {
    atomic_uint references;
    atomic_bool requested;
    int wake[2];
};
struct xrt_cancel *xrt_cancel_create(void)
{
    struct xrt_cancel *c = malloc(sizeof(*c));
    if (!c) return NULL;
    if (pipe2(c->wake, O_CLOEXEC | O_NONBLOCK)) { free(c); return NULL; }
    atomic_init(&c->references, 1);
    atomic_init(&c->requested, false);
    return c;
}
struct xrt_cancel *xrt_cancel_retain(struct xrt_cancel *c)
{
    if (c && atomic_fetch_add_explicit(&c->references, 1, memory_order_relaxed) == UINT_MAX)
        abort();
    return c;
}
void xrt_cancel_release(struct xrt_cancel *c)
{
    if (!c || atomic_fetch_sub_explicit(&c->references, 1, memory_order_acq_rel) != 1) return;
    close(c->wake[0]);
    close(c->wake[1]);
    free(c);
}
void xrt_cancel_request(struct xrt_cancel *c)
{
    if (!c || atomic_exchange_explicit(&c->requested, true, memory_order_acq_rel)) return;
    /* One byte, once. EAGAIN already means a pending wake. The read end stays
     * open while the caller holds its reference; no reader drains this pipe. */
    while (write(c->wake[1], "!", 1) < 0 && errno == EINTR) {}
}
bool xrt_cancel_requested(const struct xrt_cancel *c)
{
    return c && atomic_load_explicit(&c->requested, memory_order_acquire);
}
int xrt_cancel_fd(const struct xrt_cancel *c) { return c ? c->wake[0] : -1; }
