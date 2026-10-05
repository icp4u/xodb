#ifndef XODB_RUNTIME_REMOTE_H
#define XODB_RUNTIME_REMOTE_H
#include "xrt_target.h"
#include <signal.h>
/* Spawn an authenticated transport (agent executable or ssh argv) with private
 * stdio pipes. argv is passed directly to exec; no shell evaluation on the host. */
enum xrt_status xrt_target_remote(const char *const argv[], struct xrt_target **out);
bool xrt_target_is_remote(const struct xrt_target *);
const struct xrt_arch *xrt_target_arch(const struct xrt_target *);
/* Standalone service. All ptrace work runs on this one calling OS thread.
 * Input/output must be nonblocking private streams. Stop is optional. */
int xrt_agent_serve(int input, int output, const volatile sig_atomic_t *stop);
/* Fixed correlation from the shortest of four HELLO round trips. Uncertainty
 * is half that round trip; clock drift after connection is not measured. */
struct xrt_clock {
    uint64_t producer_ns, host_ns, uncertainty_ns;
};
bool xrt_target_clock(const struct xrt_target *, struct xrt_clock *);
uint64_t xrt_target_timestamp(const struct xrt_target *, uint64_t producer_ns);
uint64_t xrt_target_tick_hz(const struct xrt_target *);
uint64_t xrt_target_page_size(const struct xrt_target *);
#endif
