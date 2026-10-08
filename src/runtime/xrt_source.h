#ifndef XODB_RUNTIME_SOURCE_H
#define XODB_RUNTIME_SOURCE_H
#include "xrt_files.h"
#include <stdbool.h>
#define XRT_SOURCE_MAX (1024u * 1024u)
#define XRT_SOURCE_REQUESTS 1024u
#define XRT_SOURCE_WINDOW_NS UINT64_C(1000000000)
enum xrt_source_reason {
    XRT_SOURCE_READY, XRT_SOURCE_AGENT_UPDATE, XRT_SOURCE_NOT_REMOTE,
    XRT_SOURCE_NOT_LISTED, XRT_SOURCE_DEBUG_UNAVAILABLE, XRT_SOURCE_DEBUG_LIMIT,
    XRT_SOURCE_TOO_LARGE, XRT_SOURCE_COUNT_LIMIT, XRT_SOURCE_UNAVAILABLE,
    XRT_SOURCE_CHANGED, XRT_SOURCE_INVALID_REQUEST,
    XRT_SOURCE_PATH_UNSAFE, XRT_SOURCE_KERNEL_UNSUPPORTED, XRT_SOURCE_FILESYSTEM_UNSUPPORTED
};
struct xrt_source_file {
    uint64_t handle;
    struct xrt_file_identity identity;
    unsigned char build_id[64];
    uint32_t build_id_size;
    enum xrt_source_reason reason;
};
bool xrt_target_source_capable(const struct xrt_target *);
/* Explicit opt-in caller only. The agent independently verifies the mapping
 * and requested absolute path against the image's DWARF line tables. A handle
 * belongs to this target and must be closed on its owner thread before target
 * destruction. Metadata is refreshed on every open, including cache hits. */
enum xrt_status xrt_source_open(const struct xrt_target *, const struct xrt_file_request *,
                                const char *path, struct xrt_source_file *);
enum xrt_status xrt_source_read(const struct xrt_target *, const struct xrt_source_file *,
                                uint64_t offset, void *, size_t);
enum xrt_status xrt_source_close(const struct xrt_target *, struct xrt_source_file *);
/* Agent-side: never takes a host-authorized path or compilation directory.
 * Returned regular descriptor is bounded and caller-owned. */
enum xrt_status xrt_source_local(const struct xrt_target *, const struct xrt_file_request *,
                                 const char *, int *, struct xrt_source_file *);
#endif
