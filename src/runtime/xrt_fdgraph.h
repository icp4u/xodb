#ifndef XODB_RUNTIME_FDGRAPH_H
#define XODB_RUNTIME_FDGRAPH_H
#include "xrt_fdscan.h"
/* Immutable bipartite descriptor graph. Process -> resource edges avoid the
 * quadratic clique produced by a file held by many processes. UNIX peer edges
 * join socket resources; no relation is inferred from pathname text.
 * Source indices refer to the exact polling sequence recorded in this graph. */
#define XRT_FDG_STALE 1u
#define XRT_FDG_IDENTITY_UNKNOWN 2u
#define XRT_FDG_DENIED 4u
#define XRT_FDG_DELETED 8u
#define XRT_FDG_TRUNCATED 16u
#define XRT_FDG_KERNEL 32u
#define XRT_FDG_IDENTITY_STALE 64u
#define XRT_FDG_PROCESS 0u
#define XRT_FDG_RESOURCE 1u
#define XRT_FDG_HOLDS 0u
#define XRT_FDG_UNIX_PEER 1u
struct xrt_fdgraph_node {
    uint32_t type, kind, flags, source_process, source_fd;
    int32_t pid;
    uint64_t start, device, inode;
    uint32_t descriptors, holders, measured_descriptors;
    double offset_rate; /* seekable offset progress only, never syscall bytes */
};
struct xrt_fdgraph_edge {
    uint32_t from, to, kind, flags, descriptors, source_fd, measured_descriptors;
    double offset_rate;
};
struct xrt_unix_peer {
    uint32_t inode, peer, cookie[2];
};
struct xrt_unix_peers {
    struct xrt_unix_peer *rows;
    uint32_t count, capacity;
    size_t bytes;
    uint64_t started_ns, taken_ns;
    int complete, error;
    const char *reason;
};
/* inode==0 dumps the current network namespace; a positive inode queries just
 * that owned socket (also used by tests). Limits are explicit and partial
 * results never masquerade as a complete peer set. No setns or target calls. */
enum xrt_status xrt_unix_peers_read(uint32_t inode, uint32_t capacity, struct xrt_unix_peers *);
void xrt_unix_peers_free(struct xrt_unix_peers *);
/* Pure parser: caller authenticates a kernel sender and rejects MSG_TRUNC. */
int xrt_unix_peers_decode(const void *, size_t, uint32_t sequence, struct xrt_unix_peers *);
struct xrt_fdgraph_member { uint32_t process, resource, source_fd, flags; };
struct xrt_fdgraph {
    uint64_t sequence, taken_ns;
    struct xrt_fdgraph_node *nodes;
    struct xrt_fdgraph_edge *edges;
    struct xrt_fdgraph_member *members;
    uint64_t *groups; /* exact interned cgroup IDs; unknowns get unique IDs */
    uint32_t cgroup_processes, cgroup_count;
    uint32_t member_count;
    uint32_t node_count, edge_count, processes, resources, peer_edges;
    uint32_t unknown_descriptors, stale_descriptors, denied_processes;
    uint32_t dropped_processes, dropped_descriptors, unmatched_peers, unscanned_processes, gone_processes;
    size_t allocated_bytes;
};
/* peer rows must be a complete, validated UNIX_DIAG result for the collector's
 * network namespace. Incomplete dumps supply no rows. Missing peers remain
 * unavailable, never inferred from socket names. A graph is still a sample,
 * not an atomic assertion that an fd remained open after collection. */
enum xrt_status xrt_fdgraph_build(const struct xrt_fd_snapshot *,
                                 const struct xrt_unix_peer *, uint32_t,
                                 struct xrt_fdgraph **);
/* Identity can be current even when unrelated stat/fdinfo fields are old. */
int xrt_fd_identity_current(const struct xrt_fd_snapshot *, const struct xrt_fd_process *, const struct xrt_fd *);
void xrt_fdgraph_free(struct xrt_fdgraph *);
struct xrt_fdgraph *xrt_fdgraph_copy(const struct xrt_fdgraph *);
/* Bounded galaxy projection. C owns grouping; renderer draws these records.
 * At wide zoom, each orbit particle aggregates one kind within a process group.
 * Focused mode expands actual descriptors up to the requested particle bound;
 * overflow remains in explicit kind buckets. No descriptor disappears. */
struct xrt_fdgraph_star {
    uint64_t group;
    uint32_t source_node, sample_node, processes, descriptors, denied, stale, mixed_groups;
};
struct xrt_fdgraph_particle {
    uint32_t star, kind, descriptors, deleted, stale, source_node, source_fd;
};
struct xrt_fdgraph_projection {
    struct xrt_fdgraph_star *stars;
    struct xrt_fdgraph_particle *particles;
    uint32_t *process_to_star; /* g->processes entries, UINT32_MAX outside focus */
    uint32_t star_count, particle_count, represented_processes, represented_descriptors;
    uint32_t grouped_stars, grouped_particles;
    size_t allocated_bytes;
};
struct xrt_fdgraph_project_options {
    uint32_t max_stars, max_particles; /* 1..1024; stars*XRT_FD_KINDS..16384 */
    uint32_t focus_process; /* process node index, or UINT32_MAX for all */
    /* Optional interned exact cgroup/service IDs, one per process node.
     * IDs are supplied by C collection, not hashes assumed collision-free.
     * NULL groups by process identity. Excess groups share an explicit bucket. */
    const uint64_t *groups;
    int collapse_cgroups; /* uses g->groups when explicit groups is NULL */
    uint64_t focus_group; /* 0: all; otherwise exact g->groups ID */
};
enum xrt_status xrt_fdgraph_project(const struct xrt_fdgraph *,
                                   const struct xrt_fdgraph_project_options *,
                                   struct xrt_fdgraph_projection **);
void xrt_fdgraph_projection_free(struct xrt_fdgraph_projection *);
/* Bounded graph topology for drawing. Star indices come first; resource
 * vertices follow. Coordinates are normalized; the renderer scales them. */
struct xrt_fdgraph_vertex { uint32_t source_node; float x,y; };
struct xrt_fdgraph_link {
    uint32_t from,to,kind,source_edge,descriptors,flags;
};
struct xrt_fdgraph_layout {
    struct xrt_fdgraph_vertex *vertices;
    struct xrt_fdgraph_link *links;
    uint32_t vertex_count,star_count,resource_count,link_count;
    uint32_t omitted_resources,omitted_links;
};
enum xrt_status xrt_fdgraph_layout(const struct xrt_fdgraph *, const struct xrt_fdgraph_projection *,
                                  uint32_t max_resources, uint32_t max_links, struct xrt_fdgraph_layout **);
void xrt_fdgraph_layout_free(struct xrt_fdgraph_layout *);
#endif
