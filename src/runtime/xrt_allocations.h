#ifndef XODB_RUNTIME_ALLOCATIONS_H
#define XODB_RUNTIME_ALLOCATIONS_H
#include "xrt_perf.h"
#include "xrt_files.h"
#define XRT_ALLOCATION_MAX_HOOKS 16
struct xrt_allocation_source {
    uint16_t id, kind;
    int fd;
    uint64_t offset;
    struct xrt_file_identity identity;
};
typedef int (*xrt_allocation_opener)(void *, int32_t tid, int group_fd, int file_fd,
                                     uint64_t offset, bool returning, bool leader, bool callstacks);
typedef bool (*xrt_allocation_cancelled)(void *);
struct xrt_allocation_config {
    int32_t pid;
    const int32_t *tids;
    size_t thread_count;
    const struct xrt_allocation_source *sources;
    size_t source_count;
    bool enable, callstacks;
    xrt_allocation_opener opener;
    xrt_allocation_cancelled cancelled;
    void *context;
};
struct xrt_allocations;
struct xrt_allocations *xrt_allocations_start_target(const struct xrt_target *,
                                                     const struct xrt_allocation_config *,
                                                     const struct xrt_mapping *, const char *helper,
                                                     struct xrt_perf_failure *);
struct xrt_allocations *xrt_allocations_start(const struct xrt_allocation_config *,
                                              struct xrt_perf_failure *);
bool xrt_allocations_enable(struct xrt_allocations *, struct xrt_perf_failure *);
void xrt_allocations_destroy(struct xrt_allocations *);
/* Borrowed handle for drain, stop and immutable metadata only. Owner destroys it. */
struct xrt_perf *xrt_allocations_perf(struct xrt_allocations *);
bool xrt_allocation_retprobe(const char *, size_t, uint64_t *mask);
/* NULL on success, otherwise a static diagnostic name. */
const char *xrt_allocation_offset(int fd, uint64_t offset);
#endif
