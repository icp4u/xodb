#ifndef XODB_CACHE_POOL_H
#define XODB_CACHE_POOL_H
#include "object.h"

/* Two fixed slots, each with an 8 GiB combined range/index extent. A private
 * directory and nonblocking leases bound disk use across sessions/processes.
 * No pathname contains target metadata. Borrowed fds outlive their consumers. */
#define XCP_SLOTS 2
#define XCP_SLOT_LIMIT UINT64_C(8589934592)
struct xcp_entry;
/* Opens/creates $XDG_CACHE_HOME/xodb-debug-v2, or $HOME/.cache/xodb-debug-v2.
 * Best-effort reclamation truncates v1 range files only under both leases.
 * Returns a private directory fd, or -1; relative environment paths refuse. */
int xcp_directory(void);
enum xbo_status xcp_acquire(int directory, const struct xbo_identity *,
        const unsigned char *build_id, size_t build_id_size, struct xcp_entry **);
int xcp_range_fd(const struct xcp_entry *);
int xcp_index_fd(const struct xcp_entry *);
uint64_t xcp_range_limit(const struct xcp_entry *);
uint64_t xcp_index_limit(const struct xcp_entry *);
/* Recover corrupt range metadata only before opening either cache consumer. */
enum xbo_status xcp_reset(struct xcp_entry *);
void xcp_release(struct xcp_entry *);
#endif
