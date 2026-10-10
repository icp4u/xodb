#include "check.h"
#include "xrt_fdflow_graph.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    int wrong = argc == 2 && !strcmp(argv[1], "--wrong-oracle");
    struct xrt_fd_process procs[2] = {{.pid = 100, .start = 10, .first = 0, .count = 2},
                                      {.pid = 200, .start = 20, .first = 2, .count = 2}};
    struct xrt_fd fds[4] = {
        {.fd = 7, .kind = XRT_FD_PIPE, .flags = XRT_FD_STAT, .device = 1, .inode = 101},
        {.fd = 8, .kind = XRT_FD_SOCKET, .flags = XRT_FD_STAT, .device = 1, .inode = 201},
        {.fd = 9, .kind = XRT_FD_PIPE, .flags = XRT_FD_STAT, .device = 1, .inode = 101},
        {.fd = 10, .kind = XRT_FD_SOCKET, .flags = XRT_FD_STAT, .device = 1, .inode = 202}};
    struct xrt_fd_snapshot s = {.sequence = 1,
                                .taken_ns = 1,
                                .processes = procs,
                                .process_count = 2,
                                .fds = fds,
                                .fd_count = 4};
    struct xrt_unix_peer peers[2] = {{.inode = 201, .peer = 202}, {.inode = 202, .peer = 201}};
    struct xrt_fdgraph *g = NULL;
    CHECK(xrt_fdgraph_build(&s, peers, 2, &g) == XRT_OK && g->member_count == 4 &&
          g->peer_edges == 1);
    struct xrt_fdgraph_project_options o = {
        .max_stars = 1, .max_particles = XRT_FD_KINDS, .focus_process = UINT32_MAX};
    struct xrt_fdgraph_projection *p = NULL;
    struct xrt_fdgraph_layout *l = NULL;
    CHECK(xrt_fdgraph_project(g, &o, &p) == XRT_OK && p->star_count == 1);
    CHECK(xrt_fdgraph_layout(g, p, 16, 16, &l) == XRT_OK);
    struct xrt_fdflow_count_row rows[5] = {{.pid = 100,
                                            .fd = 7,
                                            .start = 10,
                                            .device = 1,
                                            .inode = 101,
                                            .kind = XRT_FD_PIPE,
                                            .active = 1,
                                            .read_bytes = 17,
                                            .last_ns = 10},
                                           {.pid = 100,
                                            .fd = 8,
                                            .start = 10,
                                            .device = 1,
                                            .inode = 201,
                                            .kind = XRT_FD_SOCKET,
                                            .active = 1,
                                            .read_bytes = 40,
                                            .last_ns = 20},
                                           {.pid = 200,
                                            .fd = 9,
                                            .start = 20,
                                            .device = 1,
                                            .inode = 101,
                                            .kind = XRT_FD_PIPE,
                                            .active = 1,
                                            .write_bytes = 23,
                                            .last_ns = 30},
                                           {.pid = 200,
                                            .fd = 10,
                                            .start = 20,
                                            .device = 1,
                                            .inode = 202,
                                            .kind = XRT_FD_SOCKET,
                                            .active = 1,
                                            .write_bytes = 50,
                                            .last_ns = 40},
                                           {.pid = 100,
                                            .fd = 7,
                                            .start = 10,
                                            .device = 1,
                                            .inode = 99,
                                            .kind = XRT_FD_PIPE,
                                            .active = 0,
                                            .read_bytes = 900,
                                            .last_ns = 5}};
    struct xrt_fdflow_rate rates[5] = {
        {.read = 170}, {.read = 400}, {.write = 230}, {.write = 500}, {.read = 9000}};
    struct xrt_fdflow_live flow = {
        .sequence = 7, .counts = {.rows = rows, .row_count = 5}, .rates = rates};
    struct xrt_fdflow_graph *v = NULL;
    CHECK(xrt_fdflow_graph(g, &s, p, l, &flow, &v) == XRT_OK);
    CHECK(v->matched_rows == 4 && v->last_ns == 40 && v->flow_sequence == 7);
    CHECK(v->stars[0].read_bytes == 57 && v->stars[0].write_bytes == 73);
    CHECK(v->stars[0].read_rate == 570 && v->stars[0].write_rate == 730);
    int saw_pipe = 0, saw_peer = 0;
    for (uint32_t i = 0; i < l->link_count; ++i) {
        if (l->links[i].kind == XRT_FDG_UNIX_PEER) {
            CHECK(v->links[i].read_bytes == 40 && v->links[i].write_bytes == 50);
            saw_peer = 1;
        } else if (g->nodes[l->vertices[l->links[i].to].source_node].kind == XRT_FD_PIPE) {
            /* Both owners collapsed onto one edge; source_edge alone loses one. */
            CHECK(v->links[i].read_bytes == 17 && v->links[i].write_bytes == 23);
            saw_pipe = 1;
        }
    }
    CHECK(saw_pipe && saw_peer);
    uint64_t actual = v->stars[0].read_bytes;
    xrt_fdflow_graph_free(v);
    rows[0].active = 0;
    rows[4].active = 1; /* same fd, old inode must not match */
    CHECK(xrt_fdflow_graph(g, &s, p, l, &flow, &v) == XRT_OK && v->matched_rows == 3);
    CHECK(v->stars[0].read_bytes == 40);
    xrt_fdflow_graph_free(v);
    rates[1].read = NAN;
    CHECK(xrt_fdflow_graph(g, &s, p, l, &flow, &v) == XRT_INVALID_ARGUMENT && !v);
    rates[1].read = 400;
    const struct xrt_fd_snapshot bad = {.sequence = 1, .process_count = 2};
    CHECK(xrt_fdflow_graph(g, &bad, p, l, &flow, &v) == XRT_INVALID_ARGUMENT && !v);
    xrt_fdgraph_projection_free(p);
    xrt_fdgraph_layout_free(l);
    o.focus_process = 0;
    CHECK(xrt_fdgraph_project(g, &o, &p) == XRT_OK && p->represented_processes == 1);
    CHECK(xrt_fdgraph_layout(g, p, 16, 16, &l) == XRT_OK);
    CHECK(xrt_fdflow_graph(g, &s, p, l, &flow, &v) == XRT_OK && v->matched_rows == 1);
    uint64_t particles = 0;
    for (uint32_t i = 0; i < v->particle_count; ++i)
        particles += v->particles[i].read_bytes;
    CHECK(particles == 40 && !v->stars[0].write_bytes);
    xrt_fdflow_graph_free(v);
    xrt_fdgraph_projection_free(p);
    xrt_fdgraph_layout_free(l);
    xrt_fdgraph_free(g);
    CHECK(actual == (wrong ? 58u : 57u));
    puts("flow projection: grouped links, kind buckets, focused fds, reused inode and peer "
         "endpoint evidence PASS");
    return 0;
}
