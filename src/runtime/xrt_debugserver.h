#ifndef XODB_RUNTIME_DEBUGSERVER_H
#define XODB_RUNTIME_DEBUGSERVER_H
#include "xrt.h"
#include "xrt_cancel.h"
#include <stddef.h>
#include <stdint.h>

/* Native bootstrap only. The session owner adopts transport into the existing
 * GDB client, then owns all debugger commands and target cleanup. */
struct xrt_debugserver {
    int32_t pid;                 /* Only this child may be signalled/reaped. */
    int32_t transport;           /* Private socketpair end; 0 after transfer. */
};
struct xrt_debugserver_options {
    const char *executable;     /* NULL: discover selected Xcode's debugserver. */
    const char *const *argv;    /* Launch OR attach_pid, never both. */
    int32_t attach_pid;
    struct xrt_cancel *cancel;  /* Borrowed; startup is bounded and cancellable. */
};
enum xrt_status xrt_debugserver_find(char *out, size_t capacity, struct xrt_cancel *);
enum xrt_status xrt_debugserver_start(const struct xrt_debugserver_options *, struct xrt_debugserver *);
/* Transfer the private descriptor to the one owning GDB link. */
int xrt_debugserver_take_transport(struct xrt_debugserver *);
/* Conservative close for startup failure or an unconfirmed/lost GDB link.
 * EOF asks debugserver to detach; this path never sends it a signal. */
enum xrt_status xrt_debugserver_close(struct xrt_debugserver *);
/* Call only after a successful D/OK exchange and transport disconnect. The
 * target is then detached, so a helper that fails to exit may be signalled by
 * exact pid after a grace period. Never call this on an unconfirmed detach. */
enum xrt_status xrt_debugserver_close_detached(struct xrt_debugserver *);
#endif
