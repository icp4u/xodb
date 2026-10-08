#ifndef XODB_OBJECT_CACHE_H
#define XODB_OBJECT_CACHE_H
#include "object.h"

/* Private on-disk range cache. The caller owns a regular mode-0600 cache fd
 * and the pinned source; both outlive this object. An exclusive nonblocking
 * lease prevents concurrent updates. Cache identity includes the complete
 * source stat tuple and build ID. Cached ranges are checksummed, never mapped.
 * This cache saves source I/O; it does not turn a source into an immutable
 * snapshot. Source identity is still checked on every read. */
struct xbc_cache;
struct xbc_progress {
    uint64_t source_bytes,source_reads,cache_bytes,cache_reads,corrupt_ranges;
    uint64_t file_limit,memory_bytes;
};
/* Entire sparse file extent, including checked range metadata. */
enum xbo_status xbc_extent(uint64_t source_size, uint64_t *);
enum xbo_status xbc_create(const struct xbo_source *,const struct xbo_identity *,
                           const unsigned char *build_id,size_t build_id_size,
                           int cache_fd,uint64_t file_limit,struct xbc_cache **);
void xbc_destroy(struct xbc_cache *);
struct xbo_source xbc_source(struct xbc_cache *);
void xbc_progress(const struct xbc_cache *,struct xbc_progress *);
#endif
