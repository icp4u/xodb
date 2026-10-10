#ifndef XODB_RUNTIME_FDFLOW_GRAPH_H
#define XODB_RUNTIME_FDFLOW_GRAPH_H
#include "xrt_fdflow_owner.h"
struct xrt_fdflow_metric {
    uint64_t read_bytes, write_bytes, last_ns;
    double read_rate, write_rate;
};
struct xrt_fdflow_graph {
    struct xrt_fdflow_metric *stars, *particles, *vertices, *links;
    uint32_t star_count, particle_count, vertex_count, link_count, matched_rows;
    uint64_t graph_sequence, flow_sequence, last_ns;
};
/* Pure, bounded aggregation for the exact graph/projection/layout. Peer links
 * show endpoint activity, not a claim that a particular transfer crossed that
 * socket pair. Holds links retain process->resource write / reverse read rates. */
enum xrt_status xrt_fdflow_graph(const struct xrt_fdgraph *, const struct xrt_fd_snapshot *,
                                 const struct xrt_fdgraph_projection *,
                                 const struct xrt_fdgraph_layout *, const struct xrt_fdflow_live *,
                                 struct xrt_fdflow_graph **);
void xrt_fdflow_graph_free(struct xrt_fdflow_graph *);
#endif
