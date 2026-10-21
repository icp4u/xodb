#ifndef XODB_RUNTIME_REMOTE_H
#define XODB_RUNTIME_REMOTE_H
#include "xrt_target.h"
#include "xrt_cancel.h"
#include <signal.h>
/* Spawn an authenticated transport (agent executable or ssh argv) with private
 * stdio pipes. argv is passed directly to exec; no shell evaluation on the host. */
enum xrt_status xrt_target_remote(const char *const argv[], struct xrt_target **out);
/* The caller owns a reference throughout startup; the connection retains its
 * own reference. A requested token is terminal and cannot be reused. */
enum xrt_status xrt_target_remote_cancel(const char *const argv[], struct xrt_target **out, struct xrt_cancel *);
/* Thread-local ownership guard: refuse before transport I/O or its mutex.
 * Violations are counted with saturation and logged once per thread. Debug and
 * tests may opt into strict assertions. Native ptrace/immutable reads remain. */
void xrt_remote_io_guard(bool forbidden);
void xrt_remote_io_guard_strict(bool strict);
uint32_t xrt_remote_io_violation_count(void);
/* Owner acquires while the target is alive; release when the holder is done. */
struct xrt_cancel *xrt_target_cancel(const struct xrt_target *);
bool xrt_target_is_remote(const struct xrt_target *);
/* Stopped-read cache capacity per connection: 5120 lazily allocated 4 KiB
 * pages, at most 20 MiB. */
#define XRT_READ_CACHE_PAGES 5120u
/* Host-side, connection-lifetime counters; no wire/agent version dependency.
 * Atomic observations may span an in-flight read. Local/GDB targets return false. */
struct xrt_read_cache_stats {
    uint64_t requests, hits, rpc_reads, rpc_bytes, allocated_bytes;
};
bool xrt_target_read_cache_stats(const struct xrt_target *, struct xrt_read_cache_stats *);
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
