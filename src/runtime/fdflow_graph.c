#include "xrt_fdflow_graph.h"
#include "fdflow_join.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
static uint64_t sum(uint64_t a, uint64_t b) { return UINT64_MAX - a < b ? UINT64_MAX : a + b; }
static void add(struct xrt_fdflow_metric *to, const struct xrt_fdflow_metric *from) {
    to->read_bytes = sum(to->read_bytes, from->read_bytes);
    to->write_bytes = sum(to->write_bytes, from->write_bytes);
    to->read_rate += from->read_rate;
    to->write_rate += from->write_rate;
    if (from->last_ns > to->last_ns)
        to->last_ns = from->last_ns;
}
void xrt_fdflow_graph_free(struct xrt_fdflow_graph *v) {
    if (!v)
        return;
    free(v->stars);
    free(v->particles);
    free(v->vertices);
    free(v->links);
    free(v);
}
static int link_compare(const struct xrt_fdgraph_link *a, uint32_t star, uint32_t vertex) {
    if (a->kind != XRT_FDG_HOLDS)
        return 1;
    if (a->from != star)
        return a->from < star ? -1 : 1;
    return a->to < vertex ? -1 : a->to != vertex;
}
static uint32_t link_index(const struct xrt_fdgraph_layout *l, uint32_t star, uint32_t vertex) {
    uint32_t lo = 0, hi = l->link_count;
    while (lo < hi) {
        uint32_t m = lo + (hi - lo) / 2;
        if (link_compare(&l->links[m], star, vertex) < 0)
            lo = m + 1;
        else
            hi = m;
    }
    return lo < l->link_count && !link_compare(&l->links[lo], star, vertex) ? lo : UINT32_MAX;
}
static uint32_t *indices(uint32_t n) {
    uint32_t *p = malloc((n ? n : 1) * sizeof *p);
    if (p)
        for (uint32_t i = 0; i < n; ++i)
            p[i] = UINT32_MAX;
    return p;
}
enum xrt_status xrt_fdflow_graph(const struct xrt_fdgraph *g, const struct xrt_fd_snapshot *s,
                                 const struct xrt_fdgraph_projection *p,
                                 const struct xrt_fdgraph_layout *l,
                                 const struct xrt_fdflow_live *flow,
                                 struct xrt_fdflow_graph **out) {
    if (out)
        *out = NULL;
    if (!out || !g || !s || !p || !l || !flow || g->sequence != s->sequence ||
        s->process_count > 16384 || s->fd_count > 262144 || g->node_count > 294912 ||
        g->member_count > s->fd_count || p->star_count > 1024 || p->particle_count > 16384 ||
        l->vertex_count > 2048 || l->link_count > 16384 || l->star_count != p->star_count ||
        l->star_count > l->vertex_count || g->processes > g->node_count ||
        (s->process_count && !s->processes) || (s->fd_count && !s->fds) ||
        (g->member_count && !g->members) || (g->processes && !p->process_to_star) ||
        (p->particle_count && !p->particles) || (l->vertex_count && !l->vertices) ||
        (l->link_count && !l->links) || flow->counts.row_count > 262144 ||
        (flow->counts.row_count && (!flow->counts.rows || !flow->rates)))
        return XRT_INVALID_ARGUMENT;
    struct xrt_fdflow_graph *v = calloc(1, sizeof *v);
    uint32_t *members = indices(s->fd_count), *particles = indices(s->fd_count),
             *vertices = indices(g->node_count), *buckets = indices(p->star_count * XRT_FD_KINDS);
    if (!v || !members || !particles || !vertices || !buckets)
        goto oom;
    v->stars = calloc(p->star_count ? p->star_count : 1, sizeof *v->stars);
    v->particles = calloc(p->particle_count ? p->particle_count : 1, sizeof *v->particles);
    v->vertices = calloc(l->vertex_count ? l->vertex_count : 1, sizeof *v->vertices);
    v->links = calloc(l->link_count ? l->link_count : 1, sizeof *v->links);
    if (!v->stars || !v->particles || !v->vertices || !v->links)
        goto oom;
    v->star_count = p->star_count;
    v->particle_count = p->particle_count;
    v->vertex_count = l->vertex_count;
    v->link_count = l->link_count;
    v->graph_sequence = g->sequence;
    v->flow_sequence = flow->sequence;
    for (uint32_t i = 0; i < g->member_count; ++i) {
        const struct xrt_fdgraph_member *m = &g->members[i];
        if (m->source_fd >= s->fd_count || m->process >= g->processes ||
            m->resource >= g->node_count || members[m->source_fd] != UINT32_MAX)
            goto invalid;
        members[m->source_fd] = i;
    }
    for (uint32_t i = 0; i < p->particle_count; ++i) {
        const struct xrt_fdgraph_particle *q = &p->particles[i];
        if (q->star >= p->star_count || q->kind >= XRT_FD_KINDS)
            goto invalid;
        if (q->source_fd == UINT32_MAX)
            buckets[q->star * XRT_FD_KINDS + q->kind] = i;
        else {
            if (q->source_fd >= s->fd_count)
                goto invalid;
            particles[q->source_fd] = i;
        }
    }
    for (uint32_t i = l->star_count; i < l->vertex_count; ++i) {
        if (l->vertices[i].source_node >= g->node_count)
            goto invalid;
        vertices[l->vertices[i].source_node] = i;
    }
    for (uint32_t i = 0; i < flow->counts.row_count; ++i) {
        const struct xrt_fdflow_count_row *r = &flow->counts.rows[i];
        if (!r->active)
            continue;
        uint32_t pi=UINT32_MAX;
        uint32_t fd=xrt_fdflow_match(s,r,&pi);
        if (fd==UINT32_MAX || pi>=g->processes || members[fd]==UINT32_MAX)
            continue;
        const struct xrt_fd *f=&s->fds[fd];
        const struct xrt_fdgraph_member *m = &g->members[members[fd]];
        uint32_t star = p->process_to_star[m->process];
        if (star == UINT32_MAX)
            continue;
        if (star >= p->star_count)
            goto invalid;
        double read = flow->rates[i].read, write = flow->rates[i].write;
        if (!isfinite(read) || !isfinite(write) || read < 0 || write < 0)
            goto invalid;
        struct xrt_fdflow_metric metric = {.read_bytes = r->read_bytes,
                                           .write_bytes = r->write_bytes,
                                           .last_ns = r->last_ns,
                                           .read_rate = read,
                                           .write_rate = write};
        ++v->matched_rows;
        add(&v->stars[star], &metric);
        uint32_t particle = particles[fd];
        if (particle == UINT32_MAX)
            particle = buckets[star * XRT_FD_KINDS + f->kind];
        if (particle != UINT32_MAX)
            add(&v->particles[particle], &metric);
        uint32_t vertex = vertices[m->resource];
        if (vertex != UINT32_MAX) {
            add(&v->vertices[vertex], &metric);
            uint32_t link = link_index(l, star, vertex);
            if (link != UINT32_MAX)
                add(&v->links[link], &metric);
        }
        if (r->last_ns > v->last_ns)
            v->last_ns = r->last_ns;
    }
    for (uint32_t i = 0; i < l->link_count; ++i) {
        const struct xrt_fdgraph_link *link = &l->links[i];
        if (link->from >= l->vertex_count || link->to >= l->vertex_count)
            goto invalid;
        if (link->kind == XRT_FDG_UNIX_PEER) {
            add(&v->links[i], &v->vertices[link->from]);
            add(&v->links[i], &v->vertices[link->to]);
        }
    }
    free(members);
    free(particles);
    free(vertices);
    free(buckets);
    *out = v;
    return XRT_OK;
invalid:
    free(members);
    free(particles);
    free(vertices);
    free(buckets);
    xrt_fdflow_graph_free(v);
    return XRT_INVALID_ARGUMENT;
oom:
    free(members);
    free(particles);
    free(vertices);
    free(buckets);
    xrt_fdflow_graph_free(v);
    return XRT_OUT_OF_MEMORY;
}
