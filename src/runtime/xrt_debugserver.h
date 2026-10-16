#ifndef XODB_RUNTIME_DEBUGSERVER_H
#define XODB_RUNTIME_DEBUGSERVER_H
#include "xrt.h"
#include "xrt_cancel.h"
#include <stddef.h>
#include <stdint.h>

/* Native bootstrap only. The session owner connects the existing GDB client
 * to endpoint, then owns all debugger commands and target cleanup. */
struct xrt_debugserver {
    int32_t pid;                 /* Only this child may be signalled/reaped. */
    char endpoint[32];          /* Always 127.0.0.1:<OS-selected port>. */
};
struct xrt_debugserver_options {
    const char *executable;     /* NULL: discover selected Xcode's debugserver. */
    const char *directory;      /* Existing writable root for private handshake. */
    const char *const *argv;    /* Launch OR attach_pid, never both. */
    int32_t attach_pid;
    struct xrt_cancel *cancel;  /* Borrowed; startup is bounded and cancellable. */
};
enum xrt_status xrt_debugserver_find(char *out, size_t capacity, struct xrt_cancel *);
enum xrt_status xrt_debugserver_start(const struct xrt_debugserver_options *, struct xrt_debugserver *);
/* Call after the GDB client's detach/close, or to abandon failed startup.
 * Never signals the target. Reaps the helper; keeps its pid on cleanup failure. */
enum xrt_status xrt_debugserver_close(struct xrt_debugserver *);
#endif
