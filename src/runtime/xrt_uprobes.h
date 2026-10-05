#ifndef XODB_RUNTIME_UPROBES_H
#define XODB_RUNTIME_UPROBES_H
#include "xrt_perf.h"
#include "xrt_files.h"
#define XRT_FUNCTION_MAX_SOURCES 16
/* Linux x86 perf registers, ascending bit order: AX,CX,DX,SI,DI,SP,IP,R8,R9.
 * Both entry and return samples have these nine u64 values after ABI=2.
 * SysV integer argument words are DI,SI,DX,CX,R8,R9; the result word is AX.
 * No pointer dereference, type interpretation or call pairing occurs here. */
#define XRT_FUNCTION_REGISTER_MASK UINT64_C(0x301bd)
#define XRT_ALLOCATION_REGISTER_MASK UINT64_C(0x1b1)
struct xrt_function_source {
    uint16_t id;
    int fd; /* Same verified image descriptor for every source; remote is a host snapshot. */
    uint64_t offset;
    struct xrt_file_identity identity; /* Original target identity, also for remote snapshots. */
};
typedef bool (*xrt_function_cancelled)(void *);
struct xrt_function_config {
    int32_t pid;
    const int32_t *tids;
    size_t thread_count;
    const struct xrt_function_source *sources;
    size_t source_count;
    bool enable, callstacks;
    xrt_function_cancelled cancelled;
    void *context;
};
/* Captured on the target owner thread, then immutable until setup finishes.
 * file_pid is a selected surviving TID for /proc maps/file access; pid is TGID. */
struct xrt_function_scope {
    bool remote;
    int32_t pid, file_pid;
    int32_t tids[32];
    size_t thread_count;
    uint64_t breakpoint_addresses[128];
    size_t breakpoint_count;
};
bool xrt_functions_capture_scope(const struct xrt_target *, const int32_t *, size_t,
                                  struct xrt_function_scope *, struct xrt_perf_failure *);
struct xrt_functions;
/* Fixed scope: 1..32 held threads, 1..16 distinct entry offsets in one verified
 * executable mapping. No auto-elevation: helper is used only if explicitly set.
 * Entry callstacks add CALLCHAIN (max_stack=32) and STACK_USER (8-byte SP word);
 * return records never include these fields. Other perf records carry TID/TIME/ID
 * sample-id trailers. Event IDs in each thread are [entry0,return0,...].
 * The caller keeps the target held throughout preparation and rejects stale
 * generation/image state before publication. Cancellation rolls back all FDs. */
struct xrt_functions *xrt_functions_start_target(const struct xrt_target *,
                                                const struct xrt_function_config *,
                                                const struct xrt_mapping *, const char *helper,
                                                struct xrt_perf_failure *);
/* Worker-safe setup from an owner-captured immutable scope. Pass NULL as target
 * for native: no mutable Target field is read. For remote only, pass the same
 * live connection handle; its lifetime extends through preparation/cleanup.
 * The owner rejects stale process/image/generation before enabling publication. */
struct xrt_functions *xrt_functions_start_scoped(const struct xrt_target *remote_target,
                                                const struct xrt_function_scope *,
                                                const struct xrt_function_config *,
                                                const struct xrt_mapping *, const char *helper,
                                                struct xrt_perf_failure *);
bool xrt_functions_enable(struct xrt_functions *, struct xrt_perf_failure *);
void xrt_functions_destroy(struct xrt_functions *);
/* Borrowed handle for drain/stop/metadata only; owner destroys it. */
struct xrt_perf *xrt_functions_perf(struct xrt_functions *);
#endif
