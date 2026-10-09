#include "xrt_fdgraph.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
struct candidate {
    uint32_t node, holders;
};
static int candidate_compare(const void *a, const void *b) {
    const struct candidate *x = a, *y = b;
    if (x->holders != y->holders)
        return x->holders > y->holders ? -1 : 1;
    return x->node < y->node ? -1 : x->node != y->node;
}
static int link_compare(const void *a, const void *b) {
    const struct xrt_fdgraph_link *x = a, *y = b;
    if (x->kind != y->kind)
        return x->kind < y->kind ? -1 : 1;
    if (x->from != y->from)
        return x->from < y->from ? -1 : 1;
    return x->to < y->to ? -1 : x->to != y->to;
}
void xrt_fdgraph_layout_free(struct xrt_fdgraph_layout *l) {
    if (!l)
        return;
    free(l->vertices);
    free(l->links);
    free(l);
}
enum xrt_status xrt_fdgraph_layout(const struct xrt_fdgraph *g, const struct xrt_fdgraph_projection *p,
                                   uint32_t max_resources, uint32_t max_links,
                                   struct xrt_fdgraph_layout **out) {
    if (out)
        *out = NULL;
    if (!g || !p || !out || !max_resources || max_resources > 1024 || !max_links || max_links > 16384)
        return XRT_INVALID_ARGUMENT;
    struct candidate *c = calloc(g->resources ? g->resources : 1, sizeof *c);
    uint32_t *map = malloc((g->node_count ? g->node_count : 1) * sizeof *map);
    unsigned char *wanted = calloc(g->node_count ? g->node_count : 1, 1);
    struct xrt_fdgraph_link *links = calloc(g->edge_count ? g->edge_count : 1, sizeof *links);
    struct xrt_fdgraph_layout *l = calloc(1, sizeof *l);
    if (!c || !map || !wanted || !links || !l)
        goto oom;
    for (uint32_t i = 0; i < g->node_count; ++i)
        map[i] = UINT32_MAX;
    for (uint32_t i = 0; i < g->edge_count; ++i) {
        const struct xrt_fdgraph_edge *e = &g->edges[i];
        if (e->kind == XRT_FDG_UNIX_PEER) {
            wanted[e->from] |= 1;
            wanted[e->to] |= 1;
        } else if (p->process_to_star[e->from] != UINT32_MAX)
            wanted[e->to] |= 2;
    }
    uint32_t count = 0;
    for (uint32_t i = g->processes; i < g->node_count; ++i)
        if ((wanted[i] & 2) && (g->nodes[i].holders > 1 || (wanted[i] & 1)))
            c[count++] = (struct candidate){i, g->nodes[i].holders};
    qsort(c, count, sizeof *c, candidate_compare);
    uint32_t kept = count < max_resources ? count : max_resources;
    l->vertices = calloc(p->star_count + kept ? p->star_count + kept : 1, sizeof *l->vertices);
    if (!l->vertices)
        goto oom;
    l->star_count = p->star_count;
    l->resource_count = kept;
    l->vertex_count = p->star_count + kept;
    l->omitted_resources = count - kept;
    for (uint32_t i = 0; i < p->star_count; ++i) {
        double angle =
            6.283185307179586 * (double)i / (p->star_count ? p->star_count : 1) - 1.570796326794897;
        l->vertices[i] = (struct xrt_fdgraph_vertex){p->stars[i].source_node, (float)(.5 + .43 * cos(angle)),
                                                     (float)(.5 + .43 * sin(angle))};
    }
    for (uint32_t i = 0; i < kept; ++i) {
        uint32_t at = p->star_count + i;
        map[c[i].node] = at;
        l->vertices[at] = (struct xrt_fdgraph_vertex){c[i].node, 0, 0};
    }
    uint32_t used = 0;
    for (uint32_t i = 0; i < g->edge_count; ++i) {
        const struct xrt_fdgraph_edge *e = &g->edges[i];
        uint32_t from = e->kind == XRT_FDG_HOLDS ? p->process_to_star[e->from] : map[e->from];
        uint32_t to = map[e->to];
        if (from == UINT32_MAX || to == UINT32_MAX)
            continue;
        links[used++] = (struct xrt_fdgraph_link){from, to, e->kind, i, e->descriptors, e->flags};
    }
    qsort(links, used, sizeof *links, link_compare);
    uint32_t n = 0;
    for (uint32_t i = 0; i < used; ++i) {
        if (n && !link_compare(&links[n - 1], &links[i])) {
            links[n - 1].descriptors += links[i].descriptors;
            links[n - 1].flags |= links[i].flags;
        } else
            links[n++] = links[i];
    }
    l->link_count = n < max_links ? n : max_links;
    l->omitted_links = n - l->link_count;
    l->links = calloc(l->link_count ? l->link_count : 1, sizeof *l->links);
    if (!l->links)
        goto oom;
    if (l->link_count)
        memcpy(l->links, links, l->link_count * sizeof *links);
    /* Resource positions are centroids of all represented owners, independent
     * of the drawing-edge cap. Tiny deterministic separation avoids coincidence. */
    for (uint32_t i = 0; i < kept; ++i)
        c[i].holders = 0;
    for (uint32_t j = 0; j < n; ++j)
        if (links[j].kind == XRT_FDG_HOLDS) {
            uint32_t at = links[j].to;
            l->vertices[at].x += l->vertices[links[j].from].x;
            l->vertices[at].y += l->vertices[links[j].from].y;
            ++c[at - p->star_count].holders;
        }
    for (uint32_t i = 0; i < kept; ++i) {
        uint32_t at = p->star_count + i, owners = c[i].holders;
        uint64_t seed = g->nodes[c[i].node].inode;
        seed ^= seed >> 33;
        seed *= UINT64_C(0xff51afd7ed558ccd);
        seed ^= seed >> 33;
        double angle = (double)(seed & 65535u) * (6.283185307179586 / 65536.0);
        double x = owners ? l->vertices[at].x / owners : .5, y = owners ? l->vertices[at].y / owners : .5;
        l->vertices[at].x = (float)(x * .65 + .175 + .065 * cos(angle));
        l->vertices[at].y = (float)(y * .65 + .175 + .065 * sin(angle));
    }
    free(c);
    free(map);
    free(wanted);
    free(links);
    *out = l;
    return XRT_OK;
oom:
    free(c);
    free(map);
    free(wanted);
    free(links);
    xrt_fdgraph_layout_free(l);
    return XRT_OUT_OF_MEMORY;
}
