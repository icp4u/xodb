#ifndef XODB_RUNTIME_FDTREEMAP_H
#define XODB_RUNTIME_FDTREEMAP_H
#include "xrt_fdflow_owner.h"
#define XRT_FDT_SATURATED 1u
#define XRT_FDT_OVERFLOW_BIT UINT32_C(0x80000000)
#define XRT_FDT_NODE_LIMIT 65536u
#define XRT_FDT_TEXT_LIMIT (8u*1024u*1024u)
struct xrt_fdtreemap_metric {
    uint32_t descriptors,stale,deleted,unknown_paths,stale_paths,offset_measured,flow_measured,unexpanded,flags;
    uint64_t read_bytes,write_bytes,last_ns;
    double offset_rate,read_rate,write_rate;
};
struct xrt_fdtreemap_holder { int32_t pid,fd; uint64_t start; };
struct xrt_fdtreemap_node {
    uint32_t parent,first_child,next,name,name_length,kind,sample_fd;
    struct xrt_fdtreemap_holder holder; /* sample_fd's process and fd number, captured at build */
    /* kind0 is a literal path component; other values are synthetic buckets. */
    struct xrt_fdtreemap_metric own,overflow,total;
    uint64_t hash;
};
struct xrt_fdtreemap {
    uint64_t sequence,taken_ns,flow_sequence;
    struct xrt_fdtreemap_node *nodes;
    char *text;
    uint32_t *fd_nodes; /* source-fd index -> node; high bit means overflow */
    uint32_t count,text_length,fd_count,matched_rows,unmatched_rows;
    uint32_t dropped_processes,dropped_fds,unscanned,gone,denied;
    uint32_t flow_flags,count_flags;
    int flow_present,flow_running;
    enum xrt_status flow_status;
    size_t allocated_bytes;
};
struct xrt_fdtreemap_options {
    uint32_t max_nodes; /* 16..65536; arrays grow with observed demand */
    uint32_t max_text; /* 256..8MiB */
    uint32_t max_depth; /* 1..32 path components */
};
/* Pure immutable path aggregation. No procfs, tracing or target IO. Literal
 * observed paths group descriptors, never prove inode or open-file identity.
 * Unknown/stale names and node/text/depth overflow remain explicitly counted.
 * Every input fd contributes exactly once; file size is never an area weight. */
enum xrt_status xrt_fdtreemap_build(const struct xrt_fd_snapshot *,
    const struct xrt_fdflow_live *,const struct xrt_fdtreemap_options *,struct xrt_fdtreemap **);
void xrt_fdtreemap_free(struct xrt_fdtreemap *);
/* Captured spelling with empty components dropped (the kernel never emits
 * them, so "//a/" is "/a"), deleted suffixes kept. Spellings are injective.
 * Synthetic kind buckets are labelled, not paths. needed includes final NUL. */
enum xrt_status xrt_fdtreemap_path(const struct xrt_fdtreemap *,uint32_t node,
    char *out,size_t size,size_t *needed);
/* Relocate a selected component chain in a newer tree by raw name bytes and
 * bucket kind, never by spelling, so buckets and literal components stay
 * distinct. Missing/capped chains return STALE_SNAPSHOT, never a guessed parent. */
enum xrt_status xrt_fdtreemap_relocate(const struct xrt_fdtreemap *old,uint32_t node,
    const struct xrt_fdtreemap *fresh,uint32_t *result);
/* One sampled holder of this subtree, as of the build's snapshot; not proof
 * that all equal paths share an inode. STALE_SNAPSHOT: no descriptor here. */
enum xrt_status xrt_fdtreemap_holder(const struct xrt_fdtreemap *,uint32_t node,
    struct xrt_fdtreemap_holder *);
#define XRT_FDT_CHILD 0u
#define XRT_FDT_DIRECT 1u
#define XRT_FDT_OVERFLOW 2u
#define XRT_FDT_OTHER 3u
struct xrt_fdtreemap_tile {
    uint32_t node,kind,hidden_items; /* Other has node UINT32_MAX: no single path */
    struct xrt_fdtreemap_metric metric;
    float x,y,w,h; /* normalized, nonoverlapping; area = descriptor share */
};
struct xrt_fdtreemap_layout {
    struct xrt_fdtreemap_tile *tiles;
    uint32_t count,hidden_items;
    size_t allocated_bytes;
};
/* One directory level, plus its direct/overflow descriptors. Keeps largest
 * entries within max_tiles, combines the remainder in an explicit Other tile.
 * C performs grouping and deterministic weighted bisection for the renderer. */
enum xrt_status xrt_fdtreemap_layout(const struct xrt_fdtreemap *,uint32_t node,
    uint32_t max_tiles,double aspect,struct xrt_fdtreemap_layout **);
void xrt_fdtreemap_layout_free(struct xrt_fdtreemap_layout *);
#endif
