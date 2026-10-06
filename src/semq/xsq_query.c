/* Bounded backwards slicing and control dependence over a validated graph.
 * Every loop is charged to the query budget; no recursion is used. */
#define _GNU_SOURCE 1
#include "xsq.h"
#include "xsq_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

void xsq_budget_default(struct xsq_budget *b)
{
    memset(b, 0, sizeof *b);
    b->max_nodes = 100000;
    b->max_edges = 1000000;
    b->max_work = 20000000;
    b->max_bytes = (size_t)256 << 20;
}

struct ctx {
    const struct xsq_graph *g;
    struct xsq_budget b;
    struct xsq_result *r;
    const struct xsq_func *f;
    uint64_t start_ns;
    int stop;
};

static uint64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

static void halt(struct ctx *c, enum xsq_limit why)
{
    if (!c->stop) {
        c->stop = 1;
        c->r->limit = why;
    }
}

/* Charge deterministic work; poll cancellation and the optional clock. */
static int tick(struct ctx *c, uint64_t units)
{
    if (c->stop)
        return 0;
    uint64_t before = c->r->work;
    if (units > c->b.max_work - before) { /* never charge past the budget */
        halt(c, XSQ_LIMIT_WORK);
        return 0;
    }
    c->r->work += units;
    if ((before == 0 || (before >> 8) != (c->r->work >> 8)) && xsq_cancel_requested(c->b.cancel)) {
        halt(c, XSQ_LIMIT_CANCELLED);
        return 0;
    }
    if (c->b.max_ns && (before >> 12) != (c->r->work >> 12) &&
        now_ns() - c->start_ns > c->b.max_ns) {
        halt(c, XSQ_LIMIT_TIME);
        return 0;
    }
    return 1;
}

static void *qalloc(struct ctx *c, size_t count, size_t size)
{
    if (c->stop) /* cancelled or out of budget: no further allocation */
        return NULL;
    if (count && size > SIZE_MAX / count) {
        halt(c, XSQ_LIMIT_MEMORY);
        return NULL;
    }
    size_t n = count * size;
    if (n == 0)
        n = 1;
    if (n > c->b.max_bytes - c->r->bytes_used) {
        halt(c, XSQ_LIMIT_MEMORY);
        return NULL;
    }
    void *p = xsq__calloc(1, n);
    if (!p) {
        halt(c, XSQ_LIMIT_ALLOCATION);
        return NULL;
    }
    c->r->bytes_used += n;
    return p;
}

static void begin(struct ctx *c, const struct xsq_graph *g, const struct xsq_budget *budget,
                  struct xsq_result *r)
{
    memset(r, 0, sizeof *r);
    memset(c, 0, sizeof *c);
    c->g = g;
    c->r = r;
    xsq_budget_default(&c->b);
    if (budget) {
        if (budget->max_nodes)
            c->b.max_nodes = budget->max_nodes;
        if (budget->max_edges)
            c->b.max_edges = budget->max_edges;
        if (budget->max_work)
            c->b.max_work = budget->max_work;
        if (budget->max_bytes)
            c->b.max_bytes = budget->max_bytes;
        c->b.max_ns = budget->max_ns;
        c->b.cancel = budget->cancel;
    }
    c->start_ns = now_ns();
    r->func = r->root_vn = r->root_op = XSQ_NONE;
    r->exhaustive = 1;
    r->memory_complete = 1;
    r->frontier_complete = 1;
    if (xsq_cancel_requested(c->b.cancel)) { /* early cancellation: no work, no allocation */
        halt(c, XSQ_LIMIT_CANCELLED);
        snprintf(r->message, sizeof r->message,
                 "cancelled before any work: nothing allocated or expanded; the queried root "
                 "is unexpanded (frontier not materialised)");
    }
}

static enum xsq_status finish(struct ctx *c)
{
    struct xsq_result *r = c->r;
    r->ns = now_ns() - c->start_ns;
    r->bytes = r->bytes_used;
    if (c->stop) {
        r->partial_reasons |= XSQ_PARTIAL_BUDGET;
        r->exhaustive = 0;
        r->status = r->limit == XSQ_LIMIT_CANCELLED ? XSQ_CANCELLED : XSQ_PARTIAL;
    } else if (r->partial_reasons && r->status == XSQ_OK) {
        r->status = XSQ_PARTIAL;
    }
    return r->status;
}

void xsq_result_free(struct xsq_result *r)
{
    free(r->nodes);
    free(r->boundaries);
    free(r->exclusions);
    free(r->controls);
    free(r->frontier);
    r->nodes = NULL;
    r->boundaries = NULL;
    r->exclusions = NULL;
    r->controls = NULL;
    r->frontier = NULL;
}

/* Append to a result array whose capacity grows by doubling within budget. */
static int append(struct ctx *c, void **items, uint32_t *count, uint32_t *cap, size_t size,
                  const void *item)
{
    if (*count == *cap) {
        /* Records are bounded by the edge budget (plus slack for the root). */
        uint64_t bound = (uint64_t)c->b.max_edges + 16u;
        uint64_t want = *cap ? (uint64_t)*cap * 2 : 16;
        if (bound > UINT32_MAX - 1u)
            bound = UINT32_MAX - 1u;
        uint32_t next = (uint32_t)(want < bound ? want : bound);
        if (*count >= next) {
            halt(c, XSQ_LIMIT_EDGES);
            return 0;
        }
        /* charged as the allocator request: the full new size (no refunds) */
        size_t request = (size_t)next * size;
        if (c->stop || request > c->b.max_bytes - c->r->bytes_used) {
            halt(c, XSQ_LIMIT_MEMORY);
            return 0;
        }
        void *p = xsq__realloc(*items, request);
        if (!p) {
            halt(c, XSQ_LIMIT_ALLOCATION);
            return 0;
        }
        c->r->bytes_used += request;
        *items = p;
        *cap = next;
    }
    memcpy((char *)*items + (size_t)*count * size, item, size);
    ++*count;
    return 1;
}

static uint32_t in_vn(const struct xsq_graph *g, const struct xsq_op *op, uint32_t i)
{
    return g->inputs[op->in_first + i];
}

static int is_const(const struct xsq_graph *g, uint32_t v)
{
    return v != XSQ_NONE && g->spaces[g->vns[v].space].cls == XSQ_SPACE_CONSTANT;
}

/* ---- control dependence ------------------------------------------------- */

struct cd {
    struct ctx *c;
    uint32_t nb, exit;
    uint32_t *po;      /* postorder number on the reverse CFG, XSQ_NONE if exit unreachable */
    uint32_t *ipdom;
    uint32_t *order;   /* nodes by postorder */
    uint32_t *stack, *next;
    uint32_t *mark, *queue, stamp;
    /* Direct control dependences per block (CSR): cd_first[x]..cd_first[x+1]
     * index cd_branch/cd_edge. Edges into nonexiting regions are listed in
     * nt_branch/nt_edge and resolved per query block (rare). */
    uint32_t *cd_first, *cd_branch, *cd_edge, cd_count;
    uint32_t *nt_branch, *nt_edge, nt_count;
};

/* Local reverse-graph children: X -> exit blocks; b -> CFG predecessors. */
static uint32_t rchild_count(const struct cd *d, uint32_t x)
{
    const struct xsq_graph *g = d->c->g;
    if (x == d->exit) {
        uint32_t n = 0;
        for (uint32_t b = 0; b < d->nb; ++b)
            n += g->blocks[d->c->f->block_first + b].succ_count == 0;
        return n;
    }
    return g->blocks[d->c->f->block_first + x].pred_count;
}

static uint32_t rchild(const struct cd *d, uint32_t x, uint32_t i)
{
    const struct xsq_graph *g = d->c->g;
    const struct xsq_func *f = d->c->f;
    if (x == d->exit) {
        for (uint32_t b = 0; b < d->nb; ++b)
            if (g->blocks[f->block_first + b].succ_count == 0 && i-- == 0)
                return b;
        return XSQ_NONE;
    }
    const struct xsq_block *bl = &g->blocks[f->block_first + x];
    return g->edges[g->pred[bl->pred_first + i]].from - f->block_first;
}

static int postdominators(struct cd *d)
{
    struct ctx *c = d->c;
    const struct xsq_graph *g = c->g;
    const struct xsq_func *f = c->f;
    uint32_t n = d->nb + 1, count = 0, depth = 0;
    uint32_t exits = rchild_count(d, d->exit);
    uint32_t *exit_list = qalloc(c, exits + 1, sizeof *exit_list);
    if (!exit_list)
        return 0;
    for (uint32_t b = 0, k = 0; b < d->nb; ++b)
        if (g->blocks[f->block_first + b].succ_count == 0)
            exit_list[k++] = b;
    for (uint32_t i = 0; i < n; ++i)
        d->po[i] = d->ipdom[i] = XSQ_NONE;
    uint8_t *seen = qalloc(c, n, 1);
    if (!seen) {
        free(exit_list);
        return 0;
    }
    d->stack[depth] = d->exit;
    d->next[depth++] = 0;
    seen[d->exit] = 1;
    while (depth && tick(c, 1)) {
        uint32_t x = d->stack[depth - 1];
        uint32_t i = d->next[depth - 1]++;
        uint32_t limit = x == d->exit ? exits : rchild_count(d, x);
        if (i >= limit) {
            d->po[x] = count;
            d->order[count++] = x;
            depth--;
            continue;
        }
        uint32_t y = x == d->exit ? exit_list[i] : rchild(d, x, i);
        if (!seen[y]) {
            seen[y] = 1;
            d->stack[depth] = y;
            d->next[depth++] = 0;
        }
    }
    free(seen);
    free(exit_list);
    if (c->stop)
        return 0;
    d->ipdom[d->exit] = d->exit;
    for (int changed = 1; changed;) {
        changed = 0;
        for (uint32_t k = count; k-- > 0;) {
            uint32_t b = d->order[k];
            if (b == d->exit)
                continue;
            const struct xsq_block *bl = &g->blocks[f->block_first + b];
            uint32_t best = XSQ_NONE;
            uint32_t succs = bl->succ_count ? bl->succ_count : 1;
            for (uint32_t i = 0; i < succs; ++i) {
                if (!tick(c, 1))
                    return 0;
                uint32_t s = bl->succ_count
                                 ? g->edges[g->succ[bl->succ_first + i]].to - f->block_first
                                 : d->exit;
                if (d->ipdom[s] == XSQ_NONE)
                    continue;
                if (best == XSQ_NONE) {
                    best = s;
                    continue;
                }
                uint32_t a = s, z = best;
                while (a != z) {
                    while (d->po[a] < d->po[z]) {
                        if (!tick(c, 1))
                            return 0;
                        a = d->ipdom[a];
                    }
                    while (d->po[z] < d->po[a]) {
                        if (!tick(c, 1))
                            return 0;
                        z = d->ipdom[z];
                    }
                }
                best = a;
            }
            if (best != XSQ_NONE && d->ipdom[b] != best) {
                d->ipdom[b] = best;
                changed = 1;
            }
        }
    }
    return !c->stop;
}

/* Can execution leave block a by a successor other than skip and reach x? */
static int reaches_avoiding(struct cd *d, uint32_t a, uint32_t skip, uint32_t x)
{
    struct ctx *c = d->c;
    const struct xsq_graph *g = c->g;
    const struct xsq_func *f = c->f;
    uint32_t stamp = ++d->stamp, head = 0, tail = 0;
    const struct xsq_block *ab = &g->blocks[f->block_first + a];
    for (uint32_t i = 0; i < ab->succ_count; ++i) {
        uint32_t t = g->edges[g->succ[ab->succ_first + i]].to - f->block_first;
        if (t != skip && d->mark[t] != stamp) {
            d->mark[t] = stamp;
            d->queue[tail++] = t;
        }
    }
    while (head < tail) {
        uint32_t y = d->queue[head++];
        if (y == x)
            return 1;
        if (!tick(c, 1))
            return 1; /* unknown: conservative */
        const struct xsq_block *b = &g->blocks[f->block_first + y];
        for (uint32_t i = 0; i < b->succ_count; ++i) {
            uint32_t t = g->edges[g->succ[b->succ_first + i]].to - f->block_first;
            if (d->mark[t] != stamp) {
                d->mark[t] = stamp;
                d->queue[tail++] = t;
            }
        }
    }
    return 0;
}


static void cd_release(struct cd *d)
{
    free(d->po);
    free(d->ipdom);
    free(d->order);
    free(d->stack);
    free(d->next);
    free(d->mark);
    free(d->queue);
    free(d->cd_first);
    free(d->cd_branch);
    free(d->cd_edge);
    free(d->nt_branch);
    free(d->nt_edge);
    memset(d, 0, sizeof *d);
}

/* Ferrante-Ottenstein-Warren: for each branch edge a->t, every block on the
 * postdominator-tree path from t up to (excluding) ipdom(a) is control
 * dependent on that edge. Two passes (count, fill); cost charged per step. */
static int cd_lists(struct cd *d)
{
    struct ctx *c = d->c;
    const struct xsq_graph *g = c->g;
    const struct xsq_func *f = c->f;
    d->cd_first = qalloc(c, (size_t)d->nb + 2, sizeof *d->cd_first);
    if (!d->cd_first)
        return 0;
    for (int pass = 0; pass < 2; ++pass) {
        uint32_t nt = 0;
        for (uint32_t a = 0; a < d->nb; ++a) {
            const struct xsq_block *ab = &g->blocks[f->block_first + a];
            if (ab->succ_count < 2 || d->po[a] == XSQ_NONE)
                continue;
            for (uint32_t i = 0; i < ab->succ_count; ++i) {
                uint32_t e = g->succ[ab->succ_first + i];
                uint32_t t = g->edges[e].to - f->block_first;
                if (d->po[t] == XSQ_NONE) {
                    if (pass) {
                        d->nt_branch[nt] = a;
                        d->nt_edge[nt] = e;
                    }
                    nt++;
                    continue;
                }
                for (uint32_t x = t; x != d->ipdom[a] && x != d->exit; x = d->ipdom[x]) {
                    if (!tick(c, 1))
                        return 0;
                    if (!pass) {
                        d->cd_first[x + 2]++;
                    } else {
                        uint32_t k = d->cd_first[x + 1]++;
                        d->cd_branch[k] = a;
                        d->cd_edge[k] = e;
                    }
                }
            }
        }
        if (!pass) {
            for (uint32_t x = 0; x < d->nb; ++x)
                d->cd_first[x + 2] += d->cd_first[x + 1];
            d->cd_count = d->cd_first[d->nb + 1];
            d->nt_count = nt;
            d->cd_branch = qalloc(c, d->cd_count, sizeof *d->cd_branch);
            d->cd_edge = qalloc(c, d->cd_count, sizeof *d->cd_edge);
            d->nt_branch = qalloc(c, nt, sizeof *d->nt_branch);
            d->nt_edge = qalloc(c, nt, sizeof *d->nt_edge);
            if (c->stop)
                return 0;
        }
    }
    /* After the fill pass cd_first[x] is the start and cd_first[x + 1] the end of x's list. */
    return 1;
}

/* Allocate and compute postdominators for c->f. 0 on budget stop. */
static int cd_init(struct ctx *c, struct cd *d)
{
    memset(d, 0, sizeof *d);
    d->c = c;
    d->nb = c->f->block_count;
    d->exit = d->nb;
    uint32_t n = d->nb + 1;
    d->po = qalloc(c, n, sizeof *d->po);
    d->ipdom = qalloc(c, n, sizeof *d->ipdom);
    d->order = qalloc(c, n, sizeof *d->order);
    d->stack = qalloc(c, n, sizeof *d->stack);
    d->next = qalloc(c, n, sizeof *d->next);
    d->mark = qalloc(c, n, sizeof *d->mark);
    d->queue = qalloc(c, n, sizeof *d->queue);
    if (c->stop || !postdominators(d))
        return 0;
    if (c->f->cfg_incomplete)
        c->r->partial_reasons |= XSQ_PARTIAL_CFG_INCOMPLETE;
    return cd_lists(d);
}

/* Direct control dependences of local block x: for each branch block a and
 * successor edge e with x postdominating e's target but not strictly
 * postdominating a. An edge into a region that cannot reach an exit is
 * reported as nontermination-sensitive when x is reachable from a otherwise.
 * Returns 0 when x itself cannot reach an exit (post-dominance undefined). */
typedef void (*cd_visit)(void *arg, uint32_t a, uint32_t edge, int nontermination);

static int cd_direct(struct cd *d, uint32_t x, cd_visit visit, void *arg)
{
    struct ctx *c = d->c;
    if (d->po[x] == XSQ_NONE)
        return 0;
    for (uint32_t k = d->cd_first[x]; k < d->cd_first[x + 1] && !c->stop; ++k)
        if (tick(c, 1))
            visit(arg, d->cd_branch[k], d->cd_edge[k], 0);
    for (uint32_t k = 0; k < d->nt_count && !c->stop; ++k) {
        uint32_t a = d->nt_branch[k], e = d->nt_edge[k];
        uint32_t t = c->g->edges[e].to - c->f->block_first;
        if (!reaches_avoiding(d, a, t, x))
            continue;
        c->r->partial_reasons |= XSQ_PARTIAL_NONTERMINATING;
        visit(arg, a, e, 1);
    }
    return 1;
}

/* The condition a block's final branch tests (CBRANCH input 1, BRANCHIND input 0). */
static void branch_condition(const struct xsq_graph *g, const struct xsq_block *b,
                             uint32_t *op, uint32_t *vn, uint32_t *input)
{
    *op = b->op_first + b->op_count - 1;
    const struct xsq_op *bop = &g->ops[*op];
    *input = bop->opcode == XSQ_OP_CBRANCH ? 1 : 0;
    *vn = in_vn(g, bop, *input);
}

/* ---- slice state ------------------------------------------------------- */

struct slice {
    struct ctx *c;
    uint32_t *node_of;   /* per function-local varnode */
    uint32_t *queue;
    uint32_t queue_head, queue_tail, queue_cap;
    uint32_t node_cap, boundary_cap, exclusion_cap, frontier_cap;
    uint8_t *stack_derived; /* per local varnode: address derived from the frame base */
    uint8_t stack_escapes;
    uint8_t escape_done;
    uint32_t *block_mark;   /* per local block, query-generation stamp */
    uint32_t stamp;
    uint32_t *block_queue;
    uint8_t *expanded;    /* per local varnode: 1 once expanded */
    uint8_t *in_frontier; /* per local varnode */
    int reexpanding;      /* certainty upgrade: dedup records, skip exclusions */
    int control;          /* follow control/gating dependences */
    int cd_state;         /* 0 not computed, 1 ready, -1 failed */
    struct cd cd;
    uint8_t *control_done; /* per local block: controllers already enqueued */
    uint32_t *load_blocks;  /* per local block + 1: expand_load scratch, allocated once */
};

static uint32_t local_vn(const struct slice *s, uint32_t v) { return v - s->c->f->vn_first; }

static void add_boundary(struct slice *s, uint8_t kind, uint32_t op, uint32_t vn, uint32_t other,
                         uint8_t certainty)
{
    struct xsq_result *r = s->c->r;
    /* A first expansion cannot repeat a (kind, op, other) record; an upgrade can. */
    for (uint32_t i = 0; s->reexpanding && i < r->boundary_count && tick(s->c, 1); ++i) {
        struct xsq_boundary *b = &r->boundaries[i];
        if (b->kind == kind && b->op == op && b->other == other) {
            if (certainty < b->certainty)
                b->certainty = certainty;
            return;
        }
    }
    struct xsq_boundary b = {.op = op, .vn = vn, .other = other, .kind = kind,
                             .certainty = certainty};
    if (kind != XSQ_BOUND_IMMUTABLE_LOAD)
        r->exhaustive = 0;
    append(s->c, (void **)&r->boundaries, &r->boundary_count, &s->boundary_cap, sizeof b, &b);
}

static void add_exclusion(struct slice *s, uint32_t load, uint32_t other, uint8_t reason)
{
    struct xsq_result *r = s->c->r;
    if (s->reexpanding)
        return;
    struct xsq_exclusion e = {.load_op = load, .other_op = other, .reason = reason};
    append(s->c, (void **)&r->exclusions, &r->exclusion_count, &s->exclusion_cap, sizeof e, &e);
}

/* The frontier array is allocated (and charged) once with one slot per
 * function varnode, so recording the frontier can never fail or be lost. */
static void push_frontier(struct slice *s, uint32_t vn)
{
    struct xsq_result *r = s->c->r;
    if (!r->frontier || !s->in_frontier) {
        r->frontier_complete = 0;
        return;
    }
    if (s->in_frontier[local_vn(s, vn)])
        return;
    r->frontier[r->frontier_count++] = vn;
    s->in_frontier[local_vn(s, vn)] = 1;
}

static void reach(struct slice *s, uint32_t vn, uint32_t parent, uint32_t via_op, uint32_t input,
                  uint8_t step, uint8_t certainty)
{
    struct ctx *c = s->c;
    struct xsq_result *r = c->r;
    if (parent != XSQ_NONE && r->nodes[parent].certainty > certainty)
        certainty = r->nodes[parent].certainty; /* a path is as weak as its weakest step */
    if (c->stop) {
        push_frontier(s, vn);
        return;
    }
    if (r->edges >= c->b.max_edges) { /* cap before taking another relation */
        halt(c, XSQ_LIMIT_EDGES);
        push_frontier(s, vn);
        return;
    }
    r->edges++;
    if (!tick(c, 1)) {
        push_frontier(s, vn);
        return;
    }
    uint32_t *slot = &s->node_of[local_vn(s, vn)];
    if (*slot != XSQ_NONE) {
        struct xsq_node *n = &r->nodes[*slot];
        if (certainty < n->certainty) {
            n->certainty = certainty; /* upgrade (at most twice); re-expand with stronger evidence */
            n->parent = parent;
            n->via_op = via_op;
            n->via_input = (uint16_t)input;
            n->step = step;
            s->queue[s->queue_tail++] = *slot;
        }
        return;
    }
    if (r->node_count >= c->b.max_nodes) {
        halt(c, XSQ_LIMIT_NODES);
        push_frontier(s, vn);
        return;
    }
    struct xsq_node n = {.vn = vn, .parent = parent, .via_op = via_op,
                         .via_input = (uint16_t)input, .step = step, .certainty = certainty};
    *slot = r->node_count;
    r->nodes[r->node_count++] = n;
    s->queue[s->queue_tail++] = *slot;
}

static void control_of_block(struct slice *s, uint32_t block, uint32_t node, uint8_t step);

/* ---- memory locations --------------------------------------------------- */

/* A memory location: an address space (the LOAD/STORE space constant), an
 * address width w (bytes of the address varnode) and base + offset modulo
 * 2^(8w).  Addresses whose width differs from the graph's addr_bytes are
 * not modelled (BASE_UNKNOWN: may alias anything, never same/disjoint/readonly). */
enum base_kind { BASE_STACK, BASE_GLOBAL, BASE_VALUE, BASE_UNKNOWN };
struct location { uint8_t kind, width; uint32_t base, size; uint64_t space, offset; };

static uint64_t width_mask(unsigned width)
{
    return width >= 8 ? UINT64_MAX : ((uint64_t)1 << (8 * width)) - 1;
}

/* p-code operations keep their operand widths (validated on load), so every
 * step of an address computation is arithmetic modulo 2^(8 * width). */
static struct location describe(struct slice *s, uint64_t space, uint32_t vn, uint32_t size)
{
    const struct xsq_graph *g = s->c->g;
    uint32_t width = g->vns[vn].size;
    struct location l = {.kind = BASE_VALUE, .base = vn, .offset = 0, .size = size,
                         .space = space, .width = (uint8_t)(width > 8 ? 0 : width)};
    if (width != g->addr_bytes || width == 0 || width > 8) {
        l.kind = BASE_UNKNOWN;
        return l;
    }
    uint64_t mask = width_mask(width);
    uint32_t cur = vn;
    for (unsigned step = 0; step < 64 && tick(s->c, 1); ++step) {
        const struct xsq_vn *v = &g->vns[cur];
        if (is_const(g, cur)) {
            l.kind = BASE_GLOBAL;
            l.offset = (l.offset + v->offset) & mask;
            return l;
        }
        if (v->def == XSQ_NONE) {
            l.kind = (v->flags & XSQ_VN_SPACEBASE) ? BASE_STACK : BASE_VALUE;
            l.base = cur;
            l.offset &= mask;
            return l;
        }
        const struct xsq_op *d = &g->ops[v->def];
        uint32_t a = d->in_count > 0 ? in_vn(g, d, 0) : XSQ_NONE;
        uint32_t b = d->in_count > 1 ? in_vn(g, d, 1) : XSQ_NONE;
        switch (d->opcode) {
        case XSQ_OP_COPY:
        case XSQ_OP_CAST:
            cur = a;
            continue;
        case XSQ_OP_INT_ADD:
        case XSQ_OP_PTRSUB:
            if (is_const(g, b)) {
                l.offset += g->vns[b].offset;
                cur = a;
                continue;
            }
            if (is_const(g, a) && d->opcode == XSQ_OP_INT_ADD) {
                l.offset += g->vns[a].offset;
                cur = b;
                continue;
            }
            break;
        case XSQ_OP_INT_SUB:
            if (is_const(g, b)) {
                l.offset -= g->vns[b].offset;
                cur = a;
                continue;
            }
            break;
        case XSQ_OP_PTRADD:
            if (is_const(g, b)) {
                l.offset += g->vns[b].offset * g->vns[in_vn(g, d, 2)].offset;
                cur = a;
                continue;
            }
            break;
        default:
            break;
        }
        break;
    }
    l.kind = BASE_VALUE;
    l.base = cur;
    l.offset &= mask;
    return l;
}

/* Frame-address escape: any frame-derived value used other than as a
 * constant-offset derivation or a LOAD/STORE address escapes the whole frame. */
static void compute_escape(struct slice *s)
{
    if (s->escape_done)
        return;
    s->escape_done = 1;
    struct ctx *c = s->c;
    const struct xsq_graph *g = c->g;
    const struct xsq_func *f = c->f;
    for (uint32_t v = f->vn_first; v < f->vn_first + f->vn_count; ++v)
        if (g->vns[v].flags & XSQ_VN_SPACEBASE)
            s->stack_derived[local_vn(s, v)] = 1;
    for (int changed = 1; changed && !c->stop;) {
        changed = 0;
        for (uint32_t o = f->op_first; o < f->op_first + f->op_count; ++o) {
            if (!tick(c, 1)) {
                s->stack_escapes = 1; /* incomplete analysis must not prove non-escape */
                return;
            }
            const struct xsq_op *op = &g->ops[o];
            int derived_in = 0;
            for (uint32_t i = 0; i < op->in_count; ++i) {
                uint32_t v = in_vn(g, op, i);
                if (v != XSQ_NONE && s->stack_derived[local_vn(s, v)])
                    derived_in |= 1 << (i < 8 ? i : 7);
            }
            if (!derived_in)
                continue;
            int derive = 0;
            switch (op->opcode) {
            case XSQ_OP_COPY:
            case XSQ_OP_CAST:
                derive = 1;
                break;
            case XSQ_OP_INT_ADD:
            case XSQ_OP_PTRSUB:
                derive = (derived_in == 1 && is_const(g, in_vn(g, op, 1))) ||
                         (derived_in == 2 && is_const(g, in_vn(g, op, 0)) &&
                          op->opcode == XSQ_OP_INT_ADD);
                break;
            case XSQ_OP_INT_SUB:
                derive = derived_in == 1 && is_const(g, in_vn(g, op, 1));
                break;
            case XSQ_OP_PTRADD:
                derive = derived_in == 1 && is_const(g, in_vn(g, op, 1));
                break;
            case XSQ_OP_LOAD:
                continue; /* address use only */
            case XSQ_OP_STORE:
                if (derived_in == 2)
                    continue; /* address use only; storing the pointer escapes */
                break;
            default:
                break;
            }
            if (!derive) {
                s->stack_escapes = 1;
                return;
            }
            uint32_t out = local_vn(s, op->out);
            if (!s->stack_derived[out]) {
                s->stack_derived[out] = 1;
                changed = 1;
            }
        }
    }
}

/* A block lies on a CFG cycle if it is reachable from one of its successors. */
static int block_in_cycle(struct slice *s, uint32_t block)
{
    struct ctx *c = s->c;
    const struct xsq_graph *g = c->g;
    const struct xsq_func *f = c->f;
    uint32_t stamp = ++s->stamp;
    uint32_t head = 0, tail = 0;
    const struct xsq_block *b = &g->blocks[block];
    for (uint32_t i = 0; i < b->succ_count; ++i) {
        uint32_t t = g->edges[g->succ[b->succ_first + i]].to;
        if (s->block_mark[t - f->block_first] != stamp) {
            s->block_mark[t - f->block_first] = stamp;
            s->block_queue[tail++] = t;
        }
    }
    while (head < tail) {
        uint32_t x = s->block_queue[head++];
        if (x == block)
            return 1;
        if (!tick(c, 1))
            return 1; /* unknown: assume the conservative answer */
        const struct xsq_block *xb = &g->blocks[x];
        for (uint32_t i = 0; i < xb->succ_count; ++i) {
            uint32_t t = g->edges[g->succ[xb->succ_first + i]].to;
            if (s->block_mark[t - f->block_first] != stamp) {
                s->block_mark[t - f->block_first] = stamp;
                s->block_queue[tail++] = t;
            }
        }
    }
    return 0;
}

static int base_invariant(struct slice *s, uint32_t base)
{
    const struct xsq_vn *v = &s->c->g->vns[base];
    return v->def == XSQ_NONE || !block_in_cycle(s, s->c->g->ops[v->def].block);
}

enum alias { ALIAS_SAME, ALIAS_OVERLAP, ALIAS_DISJOINT, ALIAS_MAY };

static int overlap(const struct location *a, const struct location *b)
{
    /* Interval test on offsets wrapped at the address width, relative to a. */
    uint64_t mask = width_mask(a->width);
    uint64_t d = (b->offset - a->offset) & mask;
    uint64_t e = (a->offset - b->offset) & mask;
    return d < a->size || e < b->size;
}

static enum alias classify(struct slice *s, const struct location *a, const struct location *b,
                           uint8_t *reason)
{
    /* Different spaces (their relation is not declared), different address
     * widths or unmodelled addresses: never a same-location or disjointness proof. */
    if (a->kind == BASE_UNKNOWN || b->kind == BASE_UNKNOWN || a->space != b->space ||
        a->width != b->width)
        return ALIAS_MAY;
    if (a->kind == b->kind && (a->kind != BASE_VALUE || a->base == b->base)) {
        if (a->kind == BASE_VALUE && !base_invariant(s, a->base))
            return ALIAS_MAY; /* one SSA name, different values across iterations */
        if (a->offset == b->offset && a->size == b->size)
            return ALIAS_SAME;
        if (overlap(a, b))
            return ALIAS_OVERLAP;
        *reason = a->kind == BASE_STACK    ? XSQ_EXCLUDE_DISJOINT_STACK
                  : a->kind == BASE_GLOBAL ? XSQ_EXCLUDE_DISJOINT_GLOBAL
                                           : XSQ_EXCLUDE_DISJOINT_SAME_BASE;
        return ALIAS_DISJOINT;
    }
    if ((a->kind == BASE_STACK && b->kind == BASE_GLOBAL) ||
        (a->kind == BASE_GLOBAL && b->kind == BASE_STACK)) {
        *reason = XSQ_EXCLUDE_STACK_VS_GLOBAL;
        return ALIAS_DISJOINT;
    }
    if (a->kind == BASE_STACK || b->kind == BASE_STACK) {
        compute_escape(s);
        if (!s->stack_escapes) {
            *reason = XSQ_EXCLUDE_NONESCAPING_STACK;
            return ALIAS_DISJOINT;
        }
    }
    return ALIAS_MAY;
}

/* Read-only ranges are image addresses without a named space: they apply
 * only to the graph's single RAM-class space (none if there are several). */
static int readonly_location(const struct xsq_graph *g, const struct location *l)
{
    if (l->kind != BASE_GLOBAL)
        return 0;
    uint32_t ram = 0, ram_id = 0;
    for (uint32_t i = 0; i < g->space_count; ++i)
        if (g->spaces[i].cls == XSQ_SPACE_RAM)
            ram++, ram_id = g->spaces[i].id;
    if (ram != 1 || l->space != ram_id)
        return 0;
    for (uint32_t i = 0; i < g->readonly_count; ++i)
        if (l->offset >= g->readonly[i].low && l->offset < g->readonly[i].high &&
            l->size <= g->readonly[i].high - l->offset)
            return 1;
    return 0;
}

/* Returns 1 if the op is an exact same-location store that kills earlier ones. */
static int memory_effect(struct slice *s, uint32_t node, uint32_t load, const struct location *l,
                         uint32_t o)
{
    struct ctx *c = s->c;
    const struct xsq_graph *g = c->g;
    const struct xsq_op *op = &g->ops[o];
    unsigned cls = xsq_opcode_class(op->opcode);
    uint8_t reason = 0;
    uint8_t certainty = c->r->nodes[node].certainty;
    uint32_t load_out = g->ops[load].out;
    if (cls == XSQ_CLASS_STORE) {
        uint32_t value = in_vn(g, op, 2);
        struct location sl = describe(s, g->vns[in_vn(g, op, 0)].offset, in_vn(g, op, 1),
                                      g->vns[value].size);
        switch (classify(s, l, &sl, &reason)) {
        case ALIAS_SAME:
            reach(s, value, node, o, 2, XSQ_STEP_STORE_SAME, XSQ_DIRECT);
            control_of_block(s, op->block, node, XSQ_STEP_CONTROL);
            return 1;
        case ALIAS_OVERLAP:
            reach(s, value, node, o, 2, XSQ_STEP_STORE_SAME, XSQ_DIRECT);
            control_of_block(s, op->block, node, XSQ_STEP_CONTROL);
            return 0;
        case ALIAS_DISJOINT:
            add_exclusion(s, load, o, reason);
            return 0;
        case ALIAS_MAY:
            c->r->memory_complete = 0;
            c->r->exhaustive = 0;
            reach(s, value, node, o, 2, XSQ_STEP_STORE_MAY, XSQ_POSSIBLE);
            reach(s, in_vn(g, op, 1), node, o, 1, XSQ_STEP_STORE_ADDRESS, XSQ_POSSIBLE);
            control_of_block(s, op->block, node, XSQ_STEP_CONTROL);
            return 0;
        }
        return 0;
    }
    if (cls == XSQ_CLASS_CALL || cls == XSQ_CLASS_BARRIER) {
        if (l->kind == BASE_STACK) {
            compute_escape(s);
            if (!s->stack_escapes) {
                add_exclusion(s, load, o, XSQ_EXCLUDE_NONESCAPING_STACK);
                return 0;
            }
        }
        c->r->memory_complete = 0;
        add_boundary(s, cls == XSQ_CLASS_CALL ? XSQ_BOUND_CALL_MAY_WRITE : XSQ_BOUND_UNKNOWN_WRITE,
                     load, load_out, o, certainty);
    }
    return 0;
}

static int cmp_u32(const void *a, const void *b)
{
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return (x > y) - (x < y);
}

static void expand_load(struct slice *s, uint32_t node, uint32_t load)
{
    struct ctx *c = s->c;
    const struct xsq_graph *g = c->g;
    const struct xsq_func *f = c->f;
    const struct xsq_op *op = &g->ops[load];
    uint8_t certainty = c->r->nodes[node].certainty;
    reach(s, in_vn(g, op, 1), node, load, 1, XSQ_STEP_LOAD_ADDRESS, XSQ_DIRECT);
    struct location l = describe(s, g->vns[in_vn(g, op, 0)].offset, in_vn(g, op, 1),
                                 g->vns[op->out].size);
    if (readonly_location(g, &l)) {
        add_boundary(s, XSQ_BOUND_IMMUTABLE_LOAD, load, op->out, XSQ_NONE, certainty);
        return;
    }
    const struct xsq_block *b = &g->blocks[op->block];
    /* Same block, nearest first: an exact same-location store kills the rest. */
    for (uint32_t o = load; o > b->op_first && !c->stop;) {
        --o;
        if (!tick(c, 1))
            return;
        if (memory_effect(s, node, load, &l, o)) {
            add_exclusion(s, load, XSQ_NONE, XSQ_EXCLUDE_KILLED);
            return;
        }
    }
    /* Otherwise every op that can execute earlier on some path may matter. */
    uint32_t stamp = ++s->stamp;
    uint32_t head = 0, tail = 0;
    for (uint32_t i = 0; i < b->pred_count; ++i) {
        uint32_t p = g->edges[g->pred[b->pred_first + i]].from;
        if (s->block_mark[p - f->block_first] != stamp) {
            s->block_mark[p - f->block_first] = stamp;
            s->block_queue[tail++] = p;
        }
    }
    while (head < tail && !c->stop) {
        uint32_t x = s->block_queue[head++];
        if (!tick(c, 1))
            return;
        const struct xsq_block *xb = &g->blocks[x];
        for (uint32_t i = 0; i < xb->pred_count; ++i) {
            uint32_t p = g->edges[g->pred[xb->pred_first + i]].from;
            if (s->block_mark[p - f->block_first] != stamp) {
                s->block_mark[p - f->block_first] = stamp;
                s->block_queue[tail++] = p;
            }
        }
    }
    int self = s->block_mark[op->block - f->block_first] == stamp;
    /* Deterministic: function op order. Copy the marks so nested queries
     * (describe/classify using block_in_cycle) cannot disturb them; the
     * copy lives in charged per-query scratch (a load is never re-entered
     * while this copy is in use). */
    uint32_t count = tail;
    uint32_t *blocks = s->load_blocks;
    memcpy(blocks, s->block_queue, (size_t)count * sizeof *blocks);
    if (!tick(c, count)) /* charge the sort before doing it */
        return;
    qsort(blocks, count, sizeof *blocks, cmp_u32);
    for (uint32_t i = 0; i < count && !c->stop; ++i) {
        const struct xsq_block *xb = &g->blocks[blocks[i]];
        for (uint32_t o = xb->op_first; o < xb->op_first + xb->op_count && !c->stop; ++o) {
            if (blocks[i] == op->block && o <= load && !self)
                continue;
            if (blocks[i] == op->block && o < load)
                continue; /* already scanned */
            if (o == load)
                continue;
            if (tick(c, 1))
                memory_effect(s, node, load, &l, o);
        }
    }
    if (!c->stop) {
        c->r->memory_complete = 0;
        add_boundary(s, XSQ_BOUND_MEMORY_AT_ENTRY, load, op->out, XSQ_NONE, certainty);
    }
}

struct control_walk { struct slice *s; uint32_t node; uint8_t step; };

static void control_visit(void *arg, uint32_t a, uint32_t e, int nontermination)
{
    (void)e;
    (void)nontermination; /* recorded through partial_reasons by cd_direct */
    struct control_walk *w = arg;
    const struct xsq_graph *g = w->s->c->g;
    uint32_t op, vn, input;
    branch_condition(g, &g->blocks[w->s->c->f->block_first + a], &op, &vn, &input);
    reach(w->s, vn, w->node, op, input, w->step, XSQ_CONTROL);
}

/* Enqueue the conditions of branches that decide whether block executes. */
static void control_of_block(struct slice *s, uint32_t block, uint32_t node, uint8_t step)
{
    struct ctx *c = s->c;
    uint32_t local = block - c->f->block_first;
    if (!s->control || s->control_done[local] || c->stop)
        return;
    s->control_done[local] = 1;
    if (!s->cd_state)
        s->cd_state = cd_init(c, &s->cd) ? 1 : -1;
    if (s->cd_state < 0) {
        c->r->exhaustive = 0;
        return;
    }
    struct control_walk w = {s, node, step};
    if (!cd_direct(&s->cd, local, control_visit, &w)) {
        c->r->partial_reasons |= XSQ_PARTIAL_NONTERMINATING; /* undefined for this block */
        c->r->exhaustive = 0;
    }
}

/* MULTIEQUAL selection: branches deciding which predecessor edge enters. */
static void gating(struct slice *s, uint32_t node, uint32_t phi)
{
    const struct xsq_graph *g = s->c->g;
    const struct xsq_block *b = &g->blocks[g->ops[phi].block];
    for (uint32_t i = 0; i < b->pred_count && !s->c->stop; ++i) {
        const struct xsq_block *p = &g->blocks[g->edges[g->pred[b->pred_first + i]].from];
        if (p->succ_count >= 2) {
            uint32_t op, vn, input;
            branch_condition(g, p, &op, &vn, &input);
            reach(s, vn, node, op, input, XSQ_STEP_GATING, XSQ_CONTROL);
        }
        control_of_block(s, (uint32_t)(p - g->blocks), node, XSQ_STEP_GATING);
    }
}

static void expand(struct slice *s, uint32_t node)
{
    struct ctx *c = s->c;
    const struct xsq_graph *g = c->g;
    uint32_t vn = c->r->nodes[node].vn;
    const struct xsq_vn *v = &g->vns[vn];
    uint8_t certainty = c->r->nodes[node].certainty;
    s->reexpanding = s->expanded[local_vn(s, vn)];
    s->expanded[local_vn(s, vn)] = 1;
    if (is_const(g, vn) || v->def == XSQ_NONE)
        return; /* constant or function input: terminal */
    uint32_t d = v->def;
    const struct xsq_op *op = &g->ops[d];
    control_of_block(s, op->block, node, XSQ_STEP_CONTROL);
    switch (xsq_opcode_class(op->opcode)) {
    case XSQ_CLASS_DATA:
        for (uint32_t i = 0; i < op->in_count; ++i)
            reach(s, in_vn(g, op, i), node, d, i, XSQ_STEP_OPERAND, XSQ_DIRECT);
        return;
    case XSQ_CLASS_PHI:
        for (uint32_t i = 0; i < op->in_count; ++i)
            reach(s, in_vn(g, op, i), node, d, i, XSQ_STEP_PHI, XSQ_DIRECT);
        if (s->control)
            gating(s, node, d);
        return;
    case XSQ_CLASS_INDIRECT: {
        reach(s, in_vn(g, op, 0), node, d, 0, XSQ_STEP_INDIRECT_INPUT, XSQ_DIRECT);
        const struct xsq_op *effect = &g->ops[op->iop];
        unsigned cls = xsq_opcode_class(effect->opcode);
        c->r->memory_complete = 0;
        if (cls == XSQ_CLASS_STORE) {
            c->r->exhaustive = 0;
            reach(s, in_vn(g, effect, 2), node, op->iop, 2, XSQ_STEP_INDIRECT_STORE, XSQ_POSSIBLE);
        } else if (cls == XSQ_CLASS_CALL) {
            add_boundary(s, XSQ_BOUND_INDIRECT_CALL, d, vn, op->iop, certainty);
            for (uint32_t i = 1; i < effect->in_count; ++i)
                reach(s, in_vn(g, effect, i), node, op->iop, i, XSQ_STEP_CALL_INPUT, XSQ_POSSIBLE);
        } else {
            add_boundary(s, XSQ_BOUND_INDIRECT_OTHER, d, vn, op->iop, certainty);
        }
        return;
    }
    case XSQ_CLASS_LOAD:
        expand_load(s, node, d);
        return;
    case XSQ_CLASS_CALL:
        c->r->memory_complete = 0; /* the callee may read memory */
        add_boundary(s, XSQ_BOUND_CALL_RESULT, d, vn, XSQ_NONE, certainty);
        for (uint32_t i = op->opcode == XSQ_OP_CALL ? 1 : 0; i < op->in_count; ++i)
            reach(s, in_vn(g, op, i), node, d, i, XSQ_STEP_CALL_INPUT, XSQ_POSSIBLE);
        return;
    case XSQ_CLASS_BARRIER:
        c->r->memory_complete = 0;
        add_boundary(s, XSQ_BOUND_UNKNOWN_OP, d, vn, XSQ_NONE, certainty);
        for (uint32_t i = 0; i < op->in_count; ++i)
            reach(s, in_vn(g, op, i), node, d, i, XSQ_STEP_BARRIER_INPUT, XSQ_POSSIBLE);
        return;
    case XSQ_CLASS_STORE:
    case XSQ_CLASS_BRANCH:
    case XSQ_CLASS_CBRANCH:
    case XSQ_CLASS_BRANCHIND:
    case XSQ_CLASS_RETURN:
        return; /* rejected by validation: these define no value */
    }
}

static enum xsq_status select_root(const struct xsq_graph *g, struct xsq_selector sel,
                                   struct xsq_result *r)
{
    if (sel.op_id == XSQ_NONE) {
        uint32_t v = xsq_find_vn(g, sel.vn_id);
        if (v == XSQ_NONE)
            return XSQ_NOT_FOUND;
        r->root_vn = v;
        r->root_input = -2;
        r->func = g->vns[v].func;
        return XSQ_OK;
    }
    uint32_t o = xsq_find_op(g, sel.op_id);
    if (o == XSQ_NONE)
        return XSQ_NOT_FOUND;
    const struct xsq_op *op = &g->ops[o];
    r->root_op = o;
    r->root_input = sel.input;
    r->func = op->func;
    if (sel.input < 0) {
        if (op->out == XSQ_NONE)
            return XSQ_NOT_FOUND;
        r->root_vn = op->out;
    } else {
        if ((uint32_t)sel.input >= op->in_count || in_vn(g, op, (uint32_t)sel.input) == XSQ_NONE)
            return XSQ_NOT_FOUND;
        r->root_vn = in_vn(g, op, (uint32_t)sel.input);
    }
    return XSQ_OK;
}

enum xsq_status xsq_slice(const struct xsq_graph *g, struct xsq_selector sel,
                          const struct xsq_budget *budget, struct xsq_result *r)
{
    struct ctx c;
    begin(&c, g, budget, r);
    enum xsq_status st = select_root(g, sel, r);
    if (st) {
        snprintf(r->message, sizeof r->message, "selector names no %s",
                 sel.op_id == XSQ_NONE ? "varnode" : "op/operand");
        return r->status = st;
    }
    c.f = &g->funcs[r->func];
    struct slice s = {.c = &c, .control = !(sel.flags & XSQ_SLICE_DATA_ONLY)};
    r->control_included = (uint8_t)s.control;
    uint32_t nv = c.f->vn_count, nb = c.f->block_count;
    uint32_t cap = nv < c.b.max_nodes ? nv : c.b.max_nodes;
    /* The frontier is allocated first so that even a budget too small for
     * the scratch below can still report the unexpanded root. */
    r->frontier = qalloc(&c, (size_t)nv + 1, sizeof *r->frontier);
    s.node_of = qalloc(&c, nv, sizeof *s.node_of);
    s.queue = qalloc(&c, (size_t)cap * 3 + 1, sizeof *s.queue); /* create + two upgrades */
    s.stack_derived = qalloc(&c, nv, 1);
    s.block_mark = qalloc(&c, nb, sizeof *s.block_mark);
    s.block_queue = qalloc(&c, nb, sizeof *s.block_queue);
    s.expanded = qalloc(&c, nv, 1);
    s.in_frontier = qalloc(&c, nv, 1);
    s.control_done = qalloc(&c, nb, 1);
    s.load_blocks = qalloc(&c, (size_t)nb + 1, sizeof *s.load_blocks);
    r->nodes = qalloc(&c, cap ? cap : 1, sizeof *r->nodes);
    if (c.stop) {
        /* Budget, allocation or early cancellation before any expansion:
         * the whole query from its root is unexpanded (frontier = root; if the
         * frontier array itself was not allocated it is marked incomplete). */
        if (r->frontier) {
            r->frontier[0] = r->root_vn;
            r->frontier_count = 1;
        } else {
            r->frontier_complete = 0;
        }
        goto done;
    }
    for (uint32_t i = 0; i < nv; ++i)
        s.node_of[i] = XSQ_NONE;
    reach(&s, r->root_vn, XSQ_NONE, XSQ_NONE, 0, XSQ_STEP_ROOT, XSQ_DIRECT);
    if (r->root_op != XSQ_NONE && r->node_count)
        control_of_block(&s, g->ops[r->root_op].block, 0, XSQ_STEP_CONTROL);
    while (s.queue_head < s.queue_tail && !c.stop) {
        uint32_t node = s.queue[s.queue_head++];
        expand(&s, node);
        if (c.stop) /* interrupted inside its expansion: not fully expanded */
            push_frontier(&s, r->nodes[node].vn);
    }
    /* Queued-but-unexpanded nodes form the frontier of a partial result. */
    if (c.stop)
        for (uint32_t i = s.queue_head; i < s.queue_tail; ++i)
            push_frontier(&s, r->nodes[s.queue[i]].vn);
    for (uint32_t i = 0; i < r->node_count; ++i)
        if (r->nodes[i].certainty == XSQ_POSSIBLE)
            r->exhaustive = 0;
done:
    free(s.node_of);
    free(s.queue);
    free(s.stack_derived);
    free(s.block_mark);
    free(s.block_queue);
    free(s.expanded);
    free(s.in_frontier);
    free(s.control_done);
    free(s.load_blocks);
    cd_release(&s.cd);
    r->status = XSQ_OK;
    return finish(&c);
}

enum xsq_relevance xsq_relevance(const struct xsq_result *r, uint32_t vn, uint32_t *node)
{
    *node = XSQ_NONE;
    for (uint32_t i = 0; i < r->node_count; ++i)
        if (r->nodes[i].vn == vn) {
            *node = i;
            return r->nodes[i].certainty == XSQ_DIRECT     ? XSQ_REL_DIRECT
                   : r->nodes[i].certainty == XSQ_POSSIBLE ? XSQ_REL_POSSIBLE
                                                           : XSQ_REL_CONTROL;
        }
    /* Irrelevance needs a complete slice without boundaries or uncertainty,
     * and only covers values of the same function. */
    if (r->status == XSQ_OK && r->exhaustive && r->root_vn != XSQ_NONE)
        return XSQ_REL_IRRELEVANT;
    return XSQ_REL_UNKNOWN;
}

struct controls_walk {
    struct ctx *c;
    struct cd *d;
    uint32_t x, *depth, *work, *tail, cap;
};

static void controls_visit(void *arg, uint32_t a, uint32_t e, int nontermination)
{
    struct controls_walk *w = arg;
    struct ctx *c = w->c;
    const struct xsq_graph *g = c->g;
    const struct xsq_func *f = c->f;
    uint32_t op, vn, input;
    branch_condition(g, &g->blocks[f->block_first + a], &op, &vn, &input);
    uint32_t depth = w->depth[w->x];
    struct xsq_control ctl = {.branch_op = op, .branch_block = f->block_first + a,
                              .condition_vn = vn, .controlled_block = f->block_first + w->x,
                              .edge = e, .depth = (uint16_t)(depth > 65535 ? 65535 : depth),
                              .certainty = nontermination ? XSQ_POSSIBLE : XSQ_DIRECT,
                              .nontermination = (uint8_t)nontermination};
    if (c->stop)
        return;
    if (c->r->edges >= c->b.max_edges) { /* cap before publishing another relation */
        halt(c, XSQ_LIMIT_EDGES);
        return;
    }
    if (!append(c, (void **)&c->r->controls, &c->r->control_count, &w->cap, sizeof ctl, &ctl))
        return;
    c->r->edges++;
    if (w->depth[a] == XSQ_NONE) {
        w->depth[a] = depth + 1;
        w->work[(*w->tail)++] = a;
    }
}

enum xsq_status xsq_controls(const struct xsq_graph *g, uint32_t op_id,
                             const struct xsq_budget *budget, struct xsq_result *r)
{
    struct ctx c;
    begin(&c, g, budget, r);
    r->exhaustive = 0; /* slice notion; not applicable */
    uint32_t o = xsq_find_op(g, op_id);
    if (o == XSQ_NONE) {
        snprintf(r->message, sizeof r->message, "no op %u", op_id);
        return r->status = XSQ_NOT_FOUND;
    }
    r->root_op = o;
    r->root_input = -1;
    r->func = g->ops[o].func;
    c.f = &g->funcs[r->func];
    const struct xsq_func *f = c.f;
    struct cd d = {0};
    uint32_t n = f->block_count + 1;
    r->frontier = qalloc(&c, n + 1, sizeof *r->frontier);
    uint32_t *depth = qalloc(&c, n, sizeof *depth);
    uint32_t *work = qalloc(&c, n, sizeof *work);
    uint32_t head = 0, tail = 0;
    uint32_t q = g->ops[o].block - f->block_first;
    r->status = XSQ_OK;
    if (c.stop || !cd_init(&c, &d)) {
        if (r->frontier) {
            r->frontier[r->frontier_count++] = f->block_first + q;
        } else {
            r->frontier_complete = 0;
        }
        goto done;
    }
    for (uint32_t i = 0; i < n; ++i)
        depth[i] = XSQ_NONE;
    work[tail++] = q;
    depth[q] = 0;
    struct controls_walk w = {.c = &c, .d = &d, .depth = depth, .work = work, .tail = &tail};
    while (head < tail && !c.stop) {
        w.x = work[head++];
        if (!cd_direct(&d, w.x, controls_visit, &w)) {
            snprintf(r->message, sizeof r->message,
                     "block %u cannot reach a function exit (nonterminating component); "
                     "post-dominance is undefined there",
                     g->blocks[f->block_first + w.x].id);
            r->status = XSQ_UNSUPPORTED;
            goto done;
        }
    }
    /* Partial: the block whose expansion was interrupted (head - 1) and every
     * queued block are unexpanded.  Each block is queued once, so n slots suffice. */
    if (c.stop)
        for (uint32_t i = head ? head - 1 : 0; i < tail; ++i)
            r->frontier[r->frontier_count++] = f->block_first + work[i];
done:
    cd_release(&d);
    free(depth);
    free(work);
    return finish(&c);
}
