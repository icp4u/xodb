/* xsq unit tests. Assertions check dependence and uncertainty, never text.
 * C02-R2 adds synchronized cancellation, allocation-failure injection at
 * every allocation, tiny/edge budgets with the byte-accounting invariant,
 * load-phase budgets and deterministic partial results.
 * usage: test-xsq FIXTURE_DIR [--concurrency-only] */
#define _GNU_SOURCE 1
#include "xsq.h"
#include "xsq_report.h"

#include <assert.h>
#include <dirent.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int failures, checks;
#define CHECK(cond)                                                                                \
    do {                                                                                           \
        checks++;                                                                                  \
        if (!(cond)) {                                                                             \
            failures++;                                                                            \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond);              \
        }                                                                                          \
    } while (0)

static const char *dir;

static void load(const char *name, struct xsq_graph *g)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    enum xsq_status s = xsq_load_file(path, g);
    if (s) {
        fprintf(stderr, "load %s: %s line %u %s\n", path, xsq_status_name(s), g->error_line,
                g->error);
        exit(1);
    }
}

static enum xsq_status slice_op(const struct xsq_graph *g, uint32_t op, int input,
                                const struct xsq_budget *b, struct xsq_result *r)
{
    struct xsq_selector sel = {.op_id = op, .vn_id = XSQ_NONE, .input = input};
    return xsq_slice(g, sel, b, r);
}

static enum xsq_relevance rel(const struct xsq_graph *g, const struct xsq_result *r, uint32_t id)
{
    uint32_t node;
    uint32_t v = xsq_find_vn(g, id);
    assert(v != XSQ_NONE);
    return xsq_relevance(r, v, &node);
}

static int has_boundary(const struct xsq_result *r, unsigned kind)
{
    for (uint32_t i = 0; i < r->boundary_count; ++i)
        if (r->boundaries[i].kind == kind)
            return 1;
    return 0;
}

static int has_exclusion(const struct xsq_result *r, unsigned reason)
{
    for (uint32_t i = 0; i < r->exclusion_count; ++i)
        if (r->exclusions[i].reason == reason)
            return 1;
    return 0;
}

/* Does the evidence path from the root to vn pass through an op with opcode? */
static int path_has(const struct xsq_graph *g, const struct xsq_result *r, uint32_t id,
                    unsigned opcode)
{
    uint32_t node;
    if (xsq_relevance(r, xsq_find_vn(g, id), &node) > XSQ_REL_POSSIBLE)
        return 0;
    for (uint32_t k = node; k != XSQ_NONE; k = r->nodes[k].parent)
        if (r->nodes[k].via_op != XSQ_NONE && g->ops[r->nodes[k].via_op].opcode == opcode)
            return 1;
    return 0;
}

static void test_units(void)
{
    struct xsq_graph g;
    struct xsq_result r;
    load("synthetic/units.xsg", &g);
    CHECK(!strcmp(xsq_string(&g, g.source_kind), "synthetic"));

    /* allocation size: count and size flow in, flag is proven irrelevant */
    CHECK(slice_op(&g, 1007, 1, NULL, &r) == XSQ_OK);
    CHECK(r.exhaustive && r.memory_complete);
    CHECK(rel(&g, &r, 100) == XSQ_REL_DIRECT);
    CHECK(rel(&g, &r, 101) == XSQ_REL_DIRECT);
    CHECK(rel(&g, &r, 102) == XSQ_REL_IRRELEVANT); /* neither data nor control */
    CHECK(r.control_included);
    CHECK(path_has(&g, &r, 100, XSQ_OP_INT_ZEXT) && path_has(&g, &r, 100, XSQ_OP_INT_MULT));
    CHECK(!path_has(&g, &r, 100, XSQ_OP_INT_SEXT));
    xsq_result_free(&r);

    /* length guard: the malloc call is controlled by the false edge of the guard */
    CHECK(xsq_controls(&g, 1007, NULL, &r) == XSQ_OK);
    CHECK(r.control_count == 1);
    if (r.control_count == 1) {
        CHECK(g.ops[r.controls[0].branch_op].id == 1001);
        CHECK(g.edges[r.controls[0].edge].kind == XSQ_EDGE_FALSE);
        CHECK(r.controls[0].certainty == XSQ_DIRECT && r.controls[0].depth == 0);
        uint32_t cond = r.controls[0].condition_vn;
        xsq_result_free(&r);
        struct xsq_selector sel = {.op_id = XSQ_NONE, .vn_id = g.vns[cond].id, .input = 0};
        CHECK(xsq_slice(&g, sel, NULL, &r) == XSQ_OK);
        CHECK(rel(&g, &r, 100) == XSQ_REL_DIRECT);
        CHECK(rel(&g, &r, 101) == XSQ_REL_IRRELEVANT);
        CHECK(g.ops[g.vns[cond].def].opcode == XSQ_OP_INT_LESS); /* unsigned guard */
    }
    xsq_result_free(&r);

    /* signed length: sign extension on the path, signed comparison controls */
    CHECK(slice_op(&g, 2004, 1, NULL, &r) == XSQ_OK);
    CHECK(path_has(&g, &r, 200, XSQ_OP_INT_SEXT) && !path_has(&g, &r, 200, XSQ_OP_INT_ZEXT));
    xsq_result_free(&r);
    CHECK(xsq_controls(&g, 2004, NULL, &r) == XSQ_OK && r.control_count == 1);
    if (r.control_count)
        CHECK(g.ops[g.vns[r.controls[0].condition_vn].def].opcode == XSQ_OP_INT_SLESS);
    xsq_result_free(&r);

    /* loop with phi cycles terminates; n is control-only, not a data input */
    CHECK(slice_op(&g, 3010, 1, NULL, &r) == XSQ_OK);
    CHECK(rel(&g, &r, 300) == XSQ_REL_DIRECT);  /* a, through the load address */
    CHECK(rel(&g, &r, 301) == XSQ_REL_CONTROL); /* n only decides iterations */
    CHECK(has_boundary(&r, XSQ_BOUND_MEMORY_AT_ENTRY) && !r.memory_complete);
    CHECK(path_has(&g, &r, 312, XSQ_OP_MULTIEQUAL));
    xsq_result_free(&r);
    {
        struct xsq_selector sel = {.op_id = 3010, .vn_id = XSQ_NONE, .input = 1,
                                   .flags = XSQ_SLICE_DATA_ONLY};
        CHECK(xsq_slice(&g, sel, NULL, &r) == XSQ_OK);
        CHECK(rel(&g, &r, 301) == XSQ_REL_UNKNOWN); /* no data path, not exhaustive */
        xsq_result_free(&r);
    }
    CHECK(xsq_controls(&g, 3006, NULL, &r) == XSQ_OK && r.control_count >= 1);
    if (r.control_count) {
        CHECK(g.ops[r.controls[0].branch_op].id == 3003 && r.controls[0].depth == 0);
        CHECK(g.edges[r.controls[0].edge].kind == XSQ_EDGE_TRUE);
    }
    xsq_result_free(&r);

    /* pointer alias counterexample: *q = 2 may alias *p */
    CHECK(slice_op(&g, 4003, 1, NULL, &r) == XSQ_OK);
    CHECK(rel(&g, &r, 402) == XSQ_REL_DIRECT);   /* *p = 1, same location */
    CHECK(rel(&g, &r, 403) == XSQ_REL_POSSIBLE); /* *q = 2, may alias */
    CHECK(rel(&g, &r, 401) == XSQ_REL_POSSIBLE); /* q decides whether it aliases */
    CHECK(!r.exhaustive && !r.memory_complete);
    CHECK(has_exclusion(&r, XSQ_EXCLUDE_KILLED));
    xsq_result_free(&r);

    /* non-escaping stack slots: b proven irrelevant despite a call */
    CHECK(slice_op(&g, 5007, 1, NULL, &r) == XSQ_OK);
    CHECK(r.exhaustive && r.memory_complete);
    CHECK(rel(&g, &r, 500) == XSQ_REL_DIRECT);
    CHECK(rel(&g, &r, 501) == XSQ_REL_IRRELEVANT);
    CHECK(has_exclusion(&r, XSQ_EXCLUDE_NONESCAPING_STACK));
    CHECK(has_exclusion(&r, XSQ_EXCLUDE_DISJOINT_STACK));
    xsq_result_free(&r);

    /* escaping slot: the call is an unknown boundary */
    CHECK(slice_op(&g, 6005, 1, NULL, &r) == XSQ_OK);
    CHECK(has_boundary(&r, XSQ_BOUND_CALL_MAY_WRITE) && !r.exhaustive);
    CHECK(rel(&g, &r, 600) == XSQ_REL_DIRECT);
    xsq_result_free(&r);

    /* function pointer, CALLOTHER, INDIRECT and read-only load */
    CHECK(slice_op(&g, 7007, 1, NULL, &r) == XSQ_OK);
    CHECK(has_boundary(&r, XSQ_BOUND_CALL_RESULT));
    CHECK(has_boundary(&r, XSQ_BOUND_INDIRECT_CALL));
    CHECK(has_boundary(&r, XSQ_BOUND_UNKNOWN_OP));
    CHECK(has_boundary(&r, XSQ_BOUND_IMMUTABLE_LOAD));
    CHECK(!has_boundary(&r, XSQ_BOUND_MEMORY_AT_ENTRY)); /* read-only: no entry state */
    CHECK(rel(&g, &r, 700) == XSQ_REL_POSSIBLE && rel(&g, &r, 701) == XSQ_REL_POSSIBLE);
    CHECK(rel(&g, &r, 705) == XSQ_REL_DIRECT);
    xsq_result_free(&r);

    /* nonterminating region: explicit partial, and unsupported inside it */
    CHECK(xsq_controls(&g, 8002, NULL, &r) == XSQ_PARTIAL);
    CHECK(r.partial_reasons & XSQ_PARTIAL_NONTERMINATING);
    CHECK(r.control_count == 1 && r.control_count && r.controls[0].nontermination &&
          r.controls[0].certainty == XSQ_POSSIBLE);
    xsq_result_free(&r);
    CHECK(xsq_controls(&g, 8001, NULL, &r) == XSQ_UNSUPPORTED);
    xsq_result_free(&r);

    /* unresolved indirect branch */
    CHECK(xsq_controls(&g, 9003, NULL, &r) == XSQ_PARTIAL);
    CHECK(r.partial_reasons & XSQ_PARTIAL_CFG_INCOMPLETE);
    xsq_result_free(&r);

    /* unknown opcode is a barrier, not a no-op */
    CHECK(slice_op(&g, 10001, 1, NULL, &r) == XSQ_OK);
    CHECK(has_boundary(&r, XSQ_BOUND_UNKNOWN_OP) && rel(&g, &r, 1000) == XSQ_REL_POSSIBLE);
    xsq_result_free(&r);

    /* distinct outcomes: no such op, operand out of range, op without output */
    CHECK(slice_op(&g, 424242, -1, NULL, &r) == XSQ_NOT_FOUND);
    xsq_result_free(&r);
    CHECK(slice_op(&g, 1007, 9, NULL, &r) == XSQ_NOT_FOUND);
    xsq_result_free(&r);
    CHECK(slice_op(&g, 1001, -1, NULL, &r) == XSQ_NOT_FOUND);
    xsq_result_free(&r);
    CHECK(xsq_controls(&g, 424242, NULL, &r) == XSQ_NOT_FOUND);
    xsq_result_free(&r);

    /* budgets: partial results carry a limit and a frontier */
    struct xsq_budget b;
    memset(&b, 0, sizeof b);
    b.max_nodes = 3;
    CHECK(slice_op(&g, 3010, 1, &b, &r) == XSQ_PARTIAL);
    CHECK(r.limit == XSQ_LIMIT_NODES && r.frontier_count > 0 && !r.exhaustive);
    CHECK(r.node_count == 3);
    CHECK(rel(&g, &r, 301) == XSQ_REL_UNKNOWN);
    xsq_result_free(&r);
    memset(&b, 0, sizeof b);
    b.max_work = 4;
    CHECK(slice_op(&g, 3010, 1, &b, &r) == XSQ_PARTIAL && r.limit == XSQ_LIMIT_WORK);
    CHECK(r.frontier_count > 0 && r.work <= 4);
    xsq_result_free(&r);
    memset(&b, 0, sizeof b);
    b.max_bytes = 16;
    CHECK(slice_op(&g, 3010, 1, &b, &r) == XSQ_PARTIAL && r.limit == XSQ_LIMIT_MEMORY);
    /* too small even for the frontier: explicitly incomplete, never silent */
    CHECK(r.frontier_count == 0 && !r.frontier_complete && r.bytes <= 16);
    xsq_result_free(&r);
    memset(&b, 0, sizeof b);
    b.max_edges = 2;
    CHECK(slice_op(&g, 3010, 1, &b, &r) == XSQ_PARTIAL && r.limit == XSQ_LIMIT_EDGES);
    xsq_result_free(&r);
    struct xsq_cancel cancel;
    xsq_cancel_init(&cancel);
    xsq_cancel_request(&cancel);
    memset(&b, 0, sizeof b);
    b.cancel = &cancel;
    /* C02-R3: pre-cancelled queries allocate nothing (R2 allocated a frontier
     * and scratch first); the root is reported as unexpanded through an
     * explicitly incomplete frontier instead of a one-slot allocation. */
    xsq_test_alloc_fail_at(-1);
    CHECK(slice_op(&g, 3010, 1, &b, &r) == XSQ_CANCELLED && r.limit == XSQ_LIMIT_CANCELLED);
    CHECK(xsq_test_alloc_fail_at(-1) == 0);
    CHECK(r.work == 0 && r.node_count == 0 && r.bytes == 0 && r.frontier_count == 0 &&
          !r.frontier_complete && r.root_vn != XSQ_NONE);
    xsq_result_free(&r);
    CHECK(xsq_controls(&g, 3006, &b, &r) == XSQ_CANCELLED);
    CHECK(xsq_test_alloc_fail_at(-1) == 0 && r.bytes == 0 && !r.frontier_complete);
    xsq_result_free(&r);

    /* determinism: identical node order and evidence across runs */
    struct xsq_result r2;
    slice_op(&g, 7007, 1, NULL, &r);
    slice_op(&g, 7007, 1, NULL, &r2);
    CHECK(r.node_count == r2.node_count &&
          !memcmp(r.nodes, r2.nodes, r.node_count * sizeof *r.nodes));
    CHECK(r.boundary_count == r2.boundary_count &&
          !memcmp(r.boundaries, r2.boundaries, r.boundary_count * sizeof *r.boundaries));
    xsq_result_free(&r);
    xsq_result_free(&r2);
    xsq_free(&g);
}

static void test_malformed(void)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/malformed", dir);
    DIR *d = opendir(path);
    CHECK(d != NULL);
    if (!d)
        return;
    unsigned cases = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t n = strlen(e->d_name);
        if (n < 5 || strcmp(e->d_name + n - 4, ".xsg"))
            continue;
        char file[8192], line[256] = {0}, status[32] = {0}, needle[200] = {0};
        snprintf(file, sizeof file, "%s/%s", path, e->d_name);
        FILE *f = fopen(file, "rb");
        if (!f || !fgets(line, sizeof line, f)) {
            CHECK(0);
            if (f)
                fclose(f);
            continue;
        }
        fclose(f);
        line[strcspn(line, "\n")] = 0;
        CHECK(sscanf(line, "# expect: %31s", status) == 1);
        const char *rest = strstr(line, status) + strlen(status);
        snprintf(needle, sizeof needle, "%s", *rest ? rest + 1 : "");
        struct xsq_graph g;
        enum xsq_status s = xsq_load_file(file, &g);
        int ok = !strcmp(xsq_status_name(s), status) && strstr(g.error, needle);
        if (!ok)
            fprintf(stderr, "malformed %s: want %s '%s' got %s '%s'\n", e->d_name, status, needle,
                    xsq_status_name(s), g.error);
        CHECK(ok);
        if (!s)
            xsq_free(&g);
        cases++;
    }
    closedir(d);
    CHECK(cases >= 50);
    printf("malformed corpus: %u cases\n", cases);
}

/* ---- generated large/deep/cyclic graphs ---------------------------------- */

struct buf { char *p; size_t n, cap; };

static void put(struct buf *b, const char *format, ...)
{
    va_list a;
    for (;;) {
        va_start(a, format);
        int k = vsnprintf(b->p + b->n, b->cap - b->n, format, a);
        va_end(a);
        if ((size_t)k < b->cap - b->n) {
            b->n += (size_t)k;
            return;
        }
        b->cap = b->cap ? b->cap * 2 : 1 << 20;
        b->p = realloc(b->p, b->cap);
        assert(b->p);
    }
}

static void header(struct buf *b)
{
    put(b, "xsg 1\nimage sha256=unknown build_id=unknown name=generated\n"
           "spec language=x86:LE:64:default compiler=synthetic addr_bytes=8\n"
           "producer test_xsq 1\nsource kind=synthetic sha256=none\n"
           "space 0 const constant\nspace 1 ram ram\nspace 2 register register\n"
           "space 3 unique unique\n");
}

/* A data chain of n INT_ADDs: deep def-use without recursion. */
static void test_deep_chain(unsigned n)
{
    struct buf b = {0};
    header(&b);
    put(&b, "function 1 chain entry=0x1000\nblock 1 0x1000\nvn 1 2 0x38 8 input param=0\n"
            "vn 2 0 0x1 8\n");
    for (unsigned i = 0; i < n; ++i)
        put(&b, "vn %u 3 0x%x 8\nop %u 1 0x1000 %u INT_ADD %u %u 2\n", 10 + i, 8 * i, 10 + i, i,
            10 + i, i ? 9 + i : 1);
    put(&b, "vn 5 0 0x0 4\nop 5 1 0x2000 %u RETURN - 5 %u\nend\n", n, 9 + n);
    struct xsq_graph g;
    CHECK(xsq_load_buffer(b.p, b.n, &g) == XSQ_OK);
    struct xsq_result r;
    struct xsq_budget budget;
    memset(&budget, 0, sizeof budget);
    budget.max_nodes = n + 10;
    CHECK(slice_op(&g, 5, 1, &budget, &r) == XSQ_OK);
    CHECK(r.node_count == n + 2 && rel(&g, &r, 1) == XSQ_REL_DIRECT && r.exhaustive);
    xsq_result_free(&r);
    budget.max_nodes = n / 2;
    CHECK(slice_op(&g, 5, 1, &budget, &r) == XSQ_PARTIAL && r.limit == XSQ_LIMIT_NODES);
    CHECK(r.frontier_count >= 1 && rel(&g, &r, 1) == XSQ_REL_UNKNOWN);
    xsq_result_free(&r);
    xsq_free(&g);
    free(b.p);
}

/* A ring of k phi nodes inside one loop: cyclic data flow terminates. */
static void test_phi_ring(unsigned k)
{
    struct buf b = {0};
    header(&b);
    put(&b, "function 1 ring entry=0x1000\nblock 1 0x1000\nblock 2 0x1010\nblock 3 0x1020\n"
            "edge 1 2 fall\nedge 2 2 true\nedge 2 3 false\n"
            "vn 1 2 0x38 4 input param=0\nvn 2 2 0x30 1 input param=1\nvn 3 1 0x1010 1 annotation\n"
            "vn 4 0 0x0 4\n");
    /* p_i = MULTIEQUAL(x, p_{i+1 mod k}) */
    for (unsigned i = 0; i < k; ++i)
        put(&b, "vn %u 3 0x%x 4\nop %u 2 0x1010 %u MULTIEQUAL %u 1 %u\n", 100 + i, 4 * i, 100 + i,
            i, 100 + i, 100 + (i + 1) % k);
    put(&b, "op 6 2 0x1014 %u CBRANCH - 3 2\nop 7 3 0x1020 0 RETURN - 4 100\nend\n", k);
    struct xsq_graph g;
    CHECK(xsq_load_buffer(b.p, b.n, &g) == XSQ_OK);
    struct xsq_result r;
    CHECK(slice_op(&g, 7, 1, NULL, &r) == XSQ_OK);
    CHECK(r.node_count == k + 2 && rel(&g, &r, 1) == XSQ_REL_DIRECT);
    CHECK(rel(&g, &r, 2) == XSQ_REL_CONTROL); /* loop condition gates the merge */
    xsq_result_free(&r);
    struct xsq_selector data_only = {.op_id = 7, .vn_id = XSQ_NONE, .input = 1,
                                     .flags = XSQ_SLICE_DATA_ONLY};
    CHECK(xsq_slice(&g, data_only, NULL, &r) == XSQ_OK && r.node_count == k + 1);
    CHECK(rel(&g, &r, 2) == XSQ_REL_IRRELEVANT); /* no data path; scope is data only */
    xsq_result_free(&r);
    CHECK(xsq_controls(&g, 7, NULL, &r) == XSQ_OK && r.control_count == 0); /* sole exit */
    xsq_result_free(&r);
    CHECK(xsq_controls(&g, 6, NULL, &r) == XSQ_OK && r.control_count == 1); /* loop header */
    if (r.control_count)
        CHECK(g.edges[r.controls[0].edge].kind == XSQ_EDGE_TRUE);
    xsq_result_free(&r);
    xsq_free(&g);
    free(b.p);
}

/* n diamonds in sequence: postdominators on a long CFG, no recursion. */
static void build_diamonds(struct buf *b, unsigned n)
{
    header(b);
    put(b, "function 1 diamonds entry=0x0\nvn 1 2 0x38 1 input param=0\nvn 2 1 0x0 1 annotation\n"
           "vn 3 0 0x0 4\n");
    for (unsigned i = 0; i < n; ++i) {
        unsigned h = 3 * i;
        put(b, "block %u 0x%x\nblock %u 0x%x\nblock %u 0x%x\n", h, 0x10 * h, h + 1, 0x10 * (h + 1),
            h + 2, 0x10 * (h + 2));
        put(b, "edge %u %u true\nedge %u %u false\nedge %u %u fall\n", h, h + 1, h, h + 2, h + 1,
            h + 2);
        put(b, "op %u %u 0x%x 0 CBRANCH - 2 1\n", 10 + h, h, 0x10 * h);
        if (i + 1 < n)
            put(b, "edge %u %u fall\n", h + 2, h + 3);
    }
    put(b, "op 5 %u 0x%x 0 RETURN - 3 3\nend\n", 3 * n - 1, 0x10 * (3 * n - 1));
}

static void test_diamonds(unsigned n)
{
    struct buf b = {0};
    build_diamonds(&b, n);
    struct xsq_graph g;
    CHECK(xsq_load_buffer(b.p, b.n, &g) == XSQ_OK);
    struct xsq_result r;
    /* The final join postdominates every branch: no control dependence. */
    CHECK(xsq_controls(&g, 5, NULL, &r) == XSQ_OK && r.control_count == 0);
    xsq_result_free(&r);
    /* Each middle arm depends exactly on its own diamond's branch. */
    struct xsq_budget budget;
    memset(&budget, 0, sizeof budget);
    budget.max_work = 20;
    CHECK(xsq_controls(&g, 5, &budget, &r) == XSQ_PARTIAL && r.limit == XSQ_LIMIT_WORK);
    xsq_result_free(&r);
    xsq_free(&g);
    free(b.p);
}

struct canceller { struct xsq_cancel *flag; unsigned us; };

static void *cancel_later(void *arg)
{
    struct canceller *c = arg;
    struct timespec t = {c->us / 1000000u, (long)(c->us % 1000000u) * 1000L};
    nanosleep(&t, NULL);
    xsq_cancel_request(c->flag); /* atomic release store: no data race */
    return NULL;
}

static uint64_t ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

/* n blocks; block i loads the slot block i-1 stored: every load scans all
 * earlier ops (quadratic), so an unbounded query runs for seconds. */
static void build_far_loads(struct buf *b, unsigned n)
{
    header(b);
    put(b, "function 1 far entry=0x0\nvn 1 2 0x38 8 input param=0\n"
           "vn 2 2 0x20 8 input spacebase\nvn 3 0 0x1 4\nvn 4 0 0x0 4\n");
    for (unsigned i = 0; i < n; ++i) {
        unsigned base = 10 + 8 * i;
        put(b, "block %u 0x%x\n", i, 0x10 * i);
        if (i + 1 < n)
            put(b, "edge %u %u fall\n", i, i + 1);
        put(b, "vn %u 0 0x%llx 8\nvn %u 3 0x%x 8\n", base, (unsigned long long)(-8ll * (i + 1)),
            base + 1, 32 * i);
        put(b, "op %u %u 0x%x 0 PTRSUB %u 2 %u\n", base, i, 0x10 * i, base + 1, base);
        if (i) {
            put(b, "vn %u 3 0x%x 8\nvn %u 3 0x%x 8\n", base + 2, 32 * i + 8, base + 3, 32 * i + 16);
            put(b, "op %u %u 0x%x 1 LOAD %u 3 %u\n", base + 1, i, 0x10 * i + 1, base + 2, base - 7);
            put(b, "op %u %u 0x%x 2 INT_ADD %u %u %u\n", base + 2, i, 0x10 * i + 2, base + 3,
                base + 2, base - 5);
            put(b, "op %u %u 0x%x 3 STORE - 3 %u %u\n", base + 3, i, 0x10 * i + 3, base + 1,
                base + 3);
        } else {
            put(b, "vn %u 3 0x%x 8\nop %u 0 0x1 1 COPY %u 1\n", base + 3, 16, base + 2, base + 3);
            put(b, "op %u 0 0x2 2 STORE - 3 %u %u\n", base + 3, base + 1, base + 3);
        }
    }
    put(b, "op 5 %u 0x%x 4 RETURN - 4 %u\nend\n", n - 1, 0x10 * (n - 1) + 4, 10 + 8 * (n - 1) + 3);
}

/* Cancellation latency on a query that would otherwise run for seconds. */
static void test_cancel_latency(void)
{
    struct buf b = {0};
    build_far_loads(&b, 20000);
    struct xsq_graph g;
    enum xsq_status ls = xsq_load_buffer(b.p, b.n, &g);
    CHECK(ls == XSQ_OK);
    if (ls) {
        fprintf(stderr, "far-load graph: %s line %u %s\n", xsq_status_name(ls), g.error_line, g.error);
        free(b.p);
        return;
    }
    struct xsq_cancel flag;
    xsq_cancel_init(&flag);
    struct xsq_budget budget;
    memset(&budget, 0, sizeof budget);
    budget.cancel = &flag;
    budget.max_work = UINT64_MAX;
    budget.max_edges = UINT32_MAX - 1;
    budget.max_nodes = UINT32_MAX - 1;
    struct canceller c = {&flag, 20000};
    pthread_t thread;
    pthread_create(&thread, NULL, cancel_later, &c);
    struct xsq_result r;
    uint64_t start = ns();
    enum xsq_status s = slice_op(&g, 5, 1, &budget, &r);
    uint64_t end = ns();
    pthread_join(thread, NULL);
    double ms = (double)(end - start) / 1e6;
    printf("far-load slice: %s after %.2f ms (cancel flag set at 20 ms), work %llu, frontier %u\n",
           xsq_status_name(s), ms, (unsigned long long)r.work, r.frontier_count);
    CHECK(s == XSQ_CANCELLED && r.limit == XSQ_LIMIT_CANCELLED && r.frontier_count > 0);
    CHECK(ms < 20 + 50);
    xsq_result_free(&r);
    /* The same query with a work budget stops deterministically. */
    memset(&budget, 0, sizeof budget);
    budget.max_work = 100000;
    CHECK(slice_op(&g, 5, 1, &budget, &r) == XSQ_PARTIAL && r.limit == XSQ_LIMIT_WORK);
    CHECK(r.work <= budget.max_work);
    uint64_t work = r.work;
    uint32_t nodes = r.node_count;
    xsq_result_free(&r);
    CHECK(slice_op(&g, 5, 1, &budget, &r) == XSQ_PARTIAL && r.work == work &&
          r.node_count == nodes);
    xsq_result_free(&r);
    xsq_free(&g);
    free(b.p);
}

/* ---- C02-R2: budgets, allocation failures, cancellation ------------------ */

/* Structural consistency and budget invariants of any (possibly partial) result. */
static void check_result(const struct xsq_graph *g, const struct xsq_result *r,
                         const struct xsq_budget *b, int controls)
{
    struct xsq_budget d;
    xsq_budget_default(&d);
    size_t max_bytes = b && b->max_bytes ? b->max_bytes : d.max_bytes;
    uint64_t max_work = b && b->max_work ? b->max_work : d.max_work;
    uint32_t max_nodes = b && b->max_nodes ? b->max_nodes : d.max_nodes;
    CHECK(r->bytes <= max_bytes);
    CHECK(r->work <= max_work);
    CHECK(r->node_count <= max_nodes);
    for (uint32_t i = 0; i < r->node_count; ++i)
        CHECK(r->nodes[i].vn < g->vn_count &&
              (r->nodes[i].parent == XSQ_NONE || r->nodes[i].parent < r->node_count));
    for (uint32_t i = 0; i < r->boundary_count; ++i)
        CHECK(r->boundaries[i].op < g->op_count);
    for (uint32_t i = 0; i < r->frontier_count; ++i)
        CHECK(controls ? r->frontier[i] < g->block_count : r->frontier[i] < g->vn_count);
    if (!r->frontier_complete)
        CHECK(r->frontier_count == 0);
    /* C02-R3: the edge cap is enforced before a relation is published */
    uint32_t max_edges = b && b->max_edges ? b->max_edges : d.max_edges;
    CHECK(r->edges <= max_edges);
    if (controls)
        CHECK(r->control_count <= max_edges);
    if (r->status == XSQ_PARTIAL || r->status == XSQ_CANCELLED)
        CHECK(r->limit != XSQ_LIMIT_NONE || r->partial_reasons);
    if (r->status == XSQ_CANCELLED)
        CHECK(r->limit == XSQ_LIMIT_CANCELLED);
}

static char *slurp(const char *name, size_t *n)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        exit(1);
    }
    char *p = malloc(1 << 22);
    *n = fread(p, 1, 1 << 22, f);
    fclose(f);
    return p;
}

struct q { int controls; uint32_t op; int input; unsigned flags; };
static const struct q unit_queries[] = {
    {0, 3010, 1, 0}, {0, 7007, 1, 0}, {0, 7007, 1, XSQ_SLICE_DATA_ONLY}, {1, 3006, -1, 0},
};

static enum xsq_status run_q(const struct xsq_graph *g, const struct q *q,
                             const struct xsq_budget *b, struct xsq_result *r)
{
    if (q->controls)
        return xsq_controls(g, q->op, b, r);
    struct xsq_selector sel = {.op_id = q->op, .vn_id = XSQ_NONE, .input = q->input,
                               .flags = q->flags};
    return xsq_slice(g, sel, b, r);
}

/* Fail every allocation index in turn: loading reports NO_MEMORY and keeps
 * nothing; a query stops with limit allocation_failed and a consistent result;
 * the report marks its citation list incomplete.  ASan/LSan builds of this
 * test also prove that no failure path leaks. */
static void test_alloc_failures(void)
{
    size_t n;
    char *data = slurp("synthetic/units.xsg", &n);
    long load_points = 0, query_points = 0;
    for (long k = 0;; ++k) {
        struct xsq_graph g;
        xsq_test_alloc_fail_at(k);
        enum xsq_status s = xsq_load_buffer(data, n, &g);
        long used = xsq_test_alloc_fail_at(-1);
        if (k >= used) {
            CHECK(s == XSQ_OK);
            xsq_free(&g);
            load_points = k;
            break;
        }
        CHECK(s == XSQ_NO_MEMORY && g.ops == NULL && g.func_count == 0);
    }
    struct xsq_graph g;
    CHECK(xsq_load_buffer(data, n, &g) == XSQ_OK);
    for (unsigned qi = 0; qi < sizeof unit_queries / sizeof *unit_queries; ++qi) {
        struct xsq_result full;
        enum xsq_status want = run_q(&g, &unit_queries[qi], NULL, &full);
        for (long k = 0;; ++k) {
            struct xsq_result r;
            xsq_test_alloc_fail_at(k);
            enum xsq_status s = run_q(&g, &unit_queries[qi], NULL, &r);
            long used = xsq_test_alloc_fail_at(-1);
            if (k >= used) {
                CHECK(s == want && r.node_count == full.node_count);
                xsq_result_free(&r);
                query_points += k;
                break;
            }
            CHECK(s == XSQ_PARTIAL && r.limit == XSQ_LIMIT_ALLOCATION);
            check_result(&g, &r, NULL, unit_queries[qi].controls);
            /* records kept before the failure are a prefix of the full run */
            CHECK(r.node_count <= full.node_count);
            for (uint32_t i = 0; i < r.node_count; ++i)
                CHECK(r.nodes[i].vn == full.nodes[i].vn);
            xsq_result_free(&r);
        }
        xsq_result_free(&full);
    }
    /* report-phase allocation failure is explicit */
    struct xsq_result r;
    struct xsq_budget eff;
    xsq_budget_default(&eff);
    CHECK(run_q(&g, &unit_queries[0], NULL, &r) == XSQ_OK || r.status == XSQ_PARTIAL);
    FILE *out = tmpfile();
    xsq_test_alloc_fail_at(0);
    xsq_report_slice_json(out, &g, &r, &eff, 1000);
    xsq_test_alloc_fail_at(-1);
    fflush(out);
    rewind(out);
    char *text = calloc(1, 1 << 20);
    size_t got = fread(text, 1, (1 << 20) - 1, out);
    fclose(out);
    CHECK(got > 0 && strstr(text, "\"instructions_complete\":false") != NULL);
    free(text);
    xsq_result_free(&r);
    xsq_free(&g);
    free(data);
    printf("allocation failure injection: %ld load points, %ld query points\n", load_points,
           query_points);
}

/* Tiny and edge budgets: the accounting invariants hold for every value,
 * and the same budget always gives the same partial result. */
static void test_budget_edges(void)
{
    struct xsq_graph g;
    load("synthetic/units.xsg", &g);
    unsigned runs = 0;
    for (unsigned qi = 0; qi < sizeof unit_queries / sizeof *unit_queries; ++qi) {
        const struct q *q = &unit_queries[qi];
        for (size_t mb = 1; mb < (1u << 22); mb = mb < 600 ? mb + 1 : mb + mb / 7) {
            struct xsq_budget b;
            memset(&b, 0, sizeof b);
            b.max_bytes = mb;
            struct xsq_result r, r2;
            enum xsq_status s = run_q(&g, q, &b, &r);
            enum xsq_status s2 = run_q(&g, q, &b, &r2);
            runs++;
            CHECK(s == XSQ_OK || s == XSQ_UNSUPPORTED ||
                  (s == XSQ_PARTIAL && (r.limit == XSQ_LIMIT_MEMORY || r.limit == XSQ_LIMIT_NONE)));
            check_result(&g, &r, &b, q->controls);
            CHECK(s == s2 && r.limit == r2.limit && r.node_count == r2.node_count &&
                  r.work == r2.work && r.bytes == r2.bytes && r.frontier_count == r2.frontier_count &&
                  r.frontier_complete == r2.frontier_complete);
            if (r.node_count == r2.node_count && r.node_count)
                CHECK(!memcmp(r.nodes, r2.nodes, r.node_count * sizeof *r.nodes));
            if (r.frontier_count == r2.frontier_count && r.frontier_count)
                CHECK(!memcmp(r.frontier, r2.frontier, r.frontier_count * sizeof *r.frontier));
            int done = s != XSQ_PARTIAL || r.limit != XSQ_LIMIT_MEMORY;
            xsq_result_free(&r);
            xsq_result_free(&r2);
            if (done)
                break;
        }
        for (uint64_t w = 1; w <= 64; ++w) {
            struct xsq_budget b;
            memset(&b, 0, sizeof b);
            b.max_work = w;
            struct xsq_result r;
            run_q(&g, q, &b, &r);
            runs++;
            check_result(&g, &r, &b, q->controls);
            xsq_result_free(&r);
        }
        for (uint32_t m = 1; m <= 8; ++m) {
            struct xsq_budget b;
            memset(&b, 0, sizeof b);
            b.max_nodes = m;
            b.max_edges = m;
            struct xsq_result r;
            run_q(&g, q, &b, &r);
            runs++;
            check_result(&g, &r, &b, q->controls);
            xsq_result_free(&r);
        }
    }
    xsq_free(&g);
    printf("budget edges: %u bounded runs\n", runs);
}

/* Load-phase budget: every budget either loads or reports LIMIT, and the
 * charged bytes never exceed it. */
static void test_load_budget(void)
{
    size_t n;
    char *data = slurp("synthetic/units.xsg", &n);
    size_t needed = 0;
    for (size_t mb = 1; mb < ((size_t)1 << 30); mb += mb / 16 + 1) {
        struct xsq_load_budget lb = {.max_bytes = mb};
        struct xsq_graph g;
        enum xsq_status s = xsq_load_buffer_budget(data, n, &lb, &g);
        CHECK(g.load_bytes <= mb);
        if (s == XSQ_OK) {
            needed = g.load_bytes;
            xsq_free(&g);
            break;
        }
        CHECK(s == XSQ_LIMIT && g.ops == NULL);
    }
    CHECK(needed > 0);
    char path[4096];
    snprintf(path, sizeof path, "%s/synthetic/units.xsg", dir);
    struct xsq_load_budget tiny = {.max_bytes = 64};
    struct xsq_graph g;
    CHECK(xsq_load_file_budget(path, &tiny, &g) == XSQ_LIMIT);
    struct xsq_cancel c;
    xsq_cancel_init(&c);
    xsq_cancel_request(&c);
    struct xsq_load_budget cancelled = {.cancel = &c};
    CHECK(xsq_load_file_budget(path, &cancelled, &g) == XSQ_CANCELLED && g.ops == NULL);
    CHECK(xsq_load_buffer_budget(data, n, &cancelled, &g) == XSQ_CANCELLED && g.ops == NULL);
    free(data);
    printf("load budget: units.xsg needs %zu charged bytes\n", needed);
}

/* Concurrent cancellation at many points of loading and querying. */
static void test_concurrent_cancel(void)
{
    struct buf b = {0};
    build_far_loads(&b, 20000);
    static const unsigned delays_us[] = {0, 1, 10, 50, 200, 1000, 3000, 10000};
    unsigned cancelled_loads = 0, cancelled_queries = 0;
    for (unsigned i = 0; i < sizeof delays_us / sizeof *delays_us; ++i) {
        struct xsq_cancel flag;
        xsq_cancel_init(&flag);
        struct canceller c = {&flag, delays_us[i]};
        pthread_t thread;
        struct xsq_load_budget lb = {.cancel = &flag};
        struct xsq_graph g;
        pthread_create(&thread, NULL, cancel_later, &c);
        enum xsq_status s = xsq_load_buffer_budget(b.p, b.n, &lb, &g);
        pthread_join(thread, NULL);
        CHECK(s == XSQ_OK || s == XSQ_CANCELLED);
        if (s == XSQ_CANCELLED) {
            cancelled_loads++;
            CHECK(g.ops == NULL && g.func_count == 0);
            continue;
        }
        xsq_free(&g);
    }
    struct xsq_graph g;
    CHECK(xsq_load_buffer(b.p, b.n, &g) == XSQ_OK);
    for (unsigned i = 0; i < sizeof delays_us / sizeof *delays_us; ++i) {
        struct xsq_cancel flag;
        xsq_cancel_init(&flag);
        struct xsq_budget budget;
        memset(&budget, 0, sizeof budget);
        budget.cancel = &flag;
        budget.max_work = UINT64_MAX;
        budget.max_edges = UINT32_MAX - 1;
        budget.max_nodes = UINT32_MAX - 1;
        struct canceller c = {&flag, delays_us[i]};
        pthread_t thread;
        struct xsq_result r;
        pthread_create(&thread, NULL, cancel_later, &c);
        enum xsq_status s = i & 1 ? xsq_controls(&g, 5, &budget, &r) : slice_op(&g, 5, 1, &budget, &r);
        pthread_join(thread, NULL);
        CHECK(s == XSQ_CANCELLED || s == XSQ_OK || s == XSQ_PARTIAL);
        if (s == XSQ_CANCELLED)
            cancelled_queries++;
        check_result(&g, &r, &budget, i & 1);
        if (s == XSQ_CANCELLED) /* or cancelled before anything was allocated (C02-R3) */
            CHECK((r.frontier_complete && r.frontier_count > 0) ||
                  (!r.frontier_complete && r.bytes == 0 && r.work == 0));
        xsq_result_free(&r);
    }
    /* cancellation after completion changes nothing; a set flag stays set */
    struct xsq_graph u;
    load("synthetic/units.xsg", &u);
    struct xsq_cancel flag;
    xsq_cancel_init(&flag);
    struct xsq_budget budget;
    memset(&budget, 0, sizeof budget);
    budget.cancel = &flag;
    struct xsq_result r;
    CHECK(slice_op(&u, 3010, 1, &budget, &r) == XSQ_OK);
    xsq_cancel_request(&flag);
    CHECK(r.status == XSQ_OK);
    xsq_result_free(&r);
    CHECK(slice_op(&u, 3010, 1, &budget, &r) == XSQ_CANCELLED && r.work == 0);
    xsq_result_free(&r);
    xsq_free(&u);
    xsq_free(&g);
    free(b.p);
    printf("concurrent cancellation: %u/%u loads and %u/%u queries cancelled\n", cancelled_loads,
           (unsigned)(sizeof delays_us / sizeof *delays_us), cancelled_queries,
           (unsigned)(sizeof delays_us / sizeof *delays_us));
}


/* ---- C02-R3 regressions (C01-R2/C02-R2 review counterexamples) ---------- */

static const char *const R3_HEAD =
    "xsg 1\n"
    "image sha256=unknown build_id=unknown name=r3-fixture\n"
    "spec language=synthetic compiler=synthetic addr_bytes=%u\n"
    "producer r3-regression 1\n"
    "source kind=synthetic sha256=none\n"
    "qualification level=complete\n"
    "space 0 const constant\nspace 1 ram ram\nspace 2 register register\nspace 3 unique unique\n"
    "%s"
    "function 1 test entry=0x1000\nblock 1 0x1000\n"
    "vn 100 2 0x10 4 input param=0 name=a\nvn 101 2 0x20 4 input param=1 name=b\n"
    "vn 1 0 0x1 4\nvn 4 0 0x4 4\nvn 20 3 0x100 4\nvn 30 0 0x0 4\n";

static int r3_load(struct xsq_graph *g, unsigned addr_bytes, const char *spaces, const char *body)
{
    char text[8192];
    int n = snprintf(text, sizeof text, R3_HEAD, addr_bytes, spaces);
    n += snprintf(text + n, sizeof text - (size_t)n, "%send\n", body);
    enum xsq_status st = xsq_load_buffer(text, (size_t)n, g);
    if (st)
        fprintf(stderr, "r3 fixture: %s line %u %s\n", xsq_status_name(st), g->error_line, g->error);
    return st == XSQ_OK;
}

/* Data-only slice of the LOAD output (op 3 or as given); relevance of a, b. */
static void r3_slice(const char *name, unsigned addr_bytes, const char *spaces, const char *body,
                     uint32_t load_op, enum xsq_relevance want_a, enum xsq_relevance want_b,
                     int want_exhaustive)
{
    struct xsq_graph g;
    CHECK(r3_load(&g, addr_bytes, spaces, body));
    if (!g.ops)
        return;
    struct xsq_selector sel = {.op_id = load_op, .vn_id = XSQ_NONE, .input = -1,
                               .flags = XSQ_SLICE_DATA_ONLY};
    struct xsq_result r;
    enum xsq_status st = xsq_slice(&g, sel, NULL, &r);
    enum xsq_relevance a = rel(&g, &r, 100), b = rel(&g, &r, 101);
    int ok = st == XSQ_OK && a == want_a && b == want_b && r.exhaustive == want_exhaustive;
    CHECK(ok);
    if (!ok)
        fprintf(stderr, "  %s: status=%s a=%s b=%s exhaustive=%d\n", name, xsq_status_name(st),
                xsq_relevance_name(a), xsq_relevance_name(b), r.exhaustive);
    xsq_result_free(&r);
    xsq_free(&g);
}

/* nested-N: N chained conditional blocks guarding a final block (review
 * nested-controls.xsg is N = 3). */
static char *r3_nested(unsigned levels, size_t *len)
{
    struct buf b = {0};
    put(&b, "xsg 1\nimage sha256=unknown name=r3-nested\n"
                "spec language=synthetic compiler=synthetic addr_bytes=8\n"
                "producer r3-regression 1\nsource kind=synthetic sha256=none\n"
                "qualification level=complete\n"
                "space 0 const constant\nspace 1 ram ram\nspace 2 register register\n"
                "function 1 nested entry=0x1000\n");
    for (unsigned i = 1; i <= levels + 2; ++i)
        put(&b, "block %u 0x%x\n", i, 0x1000 + 0x10 * (i - 1));
    for (unsigned i = 1; i <= levels; ++i)
        put(&b, "edge %u %u true\nedge %u %u false\n", i, i + 1, i, levels + 2);
    for (unsigned i = 1; i <= levels; ++i)
        put(&b, "vn %u 2 0x%x 1 input param=%u\n", i, 0x10 * i, i - 1);
    put(&b, "vn %u 1 0x%x 1 annotation\nvn %u 0 0x0 4\nvn %u 0 0x1 4\n", levels + 1,
            0x1000 + 0x10 * levels, levels + 2, levels + 3);
    for (unsigned i = 1; i <= levels; ++i)
        put(&b, "op %u %u 0x%x 0 CBRANCH - %u %u\n", i, i, 0x1000 + 0x10 * (i - 1), levels + 1, i);
    put(&b, "op %u %u 0x%x 0 RETURN - %u %u\nop %u %u 0x%x 0 RETURN - %u %u\nend\n",
            levels + 1, levels + 1, 0x1000 + 0x10 * levels, levels + 2, levels + 3,
            levels + 2, levels + 2, 0x1000 + 0x10 * (levels + 1), levels + 2, levels + 2);
    *len = b.n;
    return b.p;
}

/* A partial controls result is truthful if every control of the full answer
 * that it lacks is reachable from its frontier: the controlled block is a
 * frontier block, or (transitively) the branch block of a reachable one. */
static int r3_frontier_truthful(const struct xsq_result *full, const struct xsq_result *part)
{
    if (!part->frontier_complete)
        return 1; /* explicitly incomplete: no completeness claimed */
    uint8_t reach[512] = {0};
    for (uint32_t i = 0; i < part->frontier_count; ++i)
        if (part->frontier[i] < 512)
            reach[part->frontier[i]] = 1;
    for (int changed = 1; changed;) {
        changed = 0;
        for (uint32_t i = 0; i < full->control_count; ++i) {
            const struct xsq_control *c = &full->controls[i];
            if (c->controlled_block < 512 && reach[c->controlled_block] && !reach[c->branch_block])
                reach[c->branch_block] = 1, changed = 1;
        }
    }
    for (uint32_t i = 0; i < full->control_count; ++i) {
        const struct xsq_control *c = &full->controls[i];
        int found = 0;
        for (uint32_t k = 0; k < part->control_count && !found; ++k)
            found = part->controls[k].branch_op == c->branch_op &&
                    part->controls[k].controlled_block == c->controlled_block;
        if (!found && !(c->controlled_block < 512 && reach[c->controlled_block]))
            return 0;
    }
    return 1;
}

static void test_r3_regressions(void)
{
    /* B1: memory-space identity (review address-spaces.xsg) */
    static const char spaces4[] = "space 4 other_ram ram\n";
    r3_slice("address-spaces", 8, spaces4,
             "vn 10 0 0x4000 8\n"
             "op 1 1 0x1000 0 STORE - 1 10 100\nop 2 1 0x1001 1 STORE - 4 10 101\n"
             "op 3 1 0x1002 2 LOAD 20 1 10\nop 4 1 0x1003 3 RETURN - 30 20\n",
             3, XSQ_REL_DIRECT, XSQ_REL_POSSIBLE, 0);
    /* control: both stores in the same space -> nearer store kills (supported) */
    r3_slice("same-space-kill", 8, spaces4,
             "vn 10 0 0x4000 8\n"
             "op 1 1 0x1000 0 STORE - 1 10 100\nop 2 1 0x1001 1 STORE - 1 10 101\n"
             "op 3 1 0x1002 2 LOAD 20 1 10\nop 4 1 0x1003 3 RETURN - 30 20\n",
             3, XSQ_REL_IRRELEVANT, XSQ_REL_DIRECT, 1);
    /* control: other-space store disjoint by address stays a may-alias, never a proof */
    r3_slice("other-space-store-then-same", 8, spaces4,
             "vn 10 0 0x4000 8\n"
             "op 1 1 0x1000 0 STORE - 4 10 100\nop 2 1 0x1001 1 STORE - 1 10 101\n"
             "op 3 1 0x1002 2 LOAD 20 1 10\nop 4 1 0x1003 3 RETURN - 30 20\n",
             3, XSQ_REL_IRRELEVANT, XSQ_REL_DIRECT, 1);
    /* B2: 32-bit address arithmetic wraps at 2^32 (review address-wrap.xsg) */
    static const char wrap_vns[] = "vn 10 0 0xfffffffc 4\nvn 11 0 0x8 4\nvn 12 0 0x4 4\nvn 13 3 0x110 4\n";
    char body[2048];
    snprintf(body, sizeof body,
             "%sop 1 1 0x1000 0 INT_ADD 13 10 11\nop 2 1 0x1001 1 STORE - 1 13 100\n"
             "op 3 1 0x1002 2 STORE - 1 12 101\nop 4 1 0x1003 3 LOAD 20 1 13\n"
             "op 5 1 0x1004 4 RETURN - 30 20\n", wrap_vns);
    r3_slice("address-wrap-32", 4, spaces4, body, 4, XSQ_REL_IRRELEVANT, XSQ_REL_DIRECT, 1);
    /* control: 32-bit arithmetic without wrap; distinct addresses stay disjoint */
    r3_slice("address-32-nowrap", 4, "",
             "vn 10 0 0x1000 4\nvn 11 0 0x8 4\nvn 12 0 0x1008 4\nvn 14 0 0x2000 4\nvn 13 3 0x110 4\n"
             "op 1 1 0x1000 0 INT_ADD 13 10 11\nop 2 1 0x1001 1 STORE - 1 12 100\n"
             "op 3 1 0x1002 2 STORE - 1 14 101\nop 4 1 0x1003 3 LOAD 20 1 13\n"
             "op 5 1 0x1004 4 RETURN - 30 20\n",
             4, XSQ_REL_DIRECT, XSQ_REL_IRRELEVANT, 1);
    /* control: 64-bit wrap (x86-64 width) is unchanged */
    r3_slice("address-wrap-64", 8, "",
             "vn 10 0 0xfffffffffffffffc 8\nvn 11 0 0x8 8\nvn 12 0 0x4 8\nvn 13 3 0x110 8\n"
             "op 1 1 0x1000 0 INT_ADD 13 10 11\nop 2 1 0x1001 1 STORE - 1 13 100\n"
             "op 3 1 0x1002 2 STORE - 1 12 101\nop 4 1 0x1003 3 LOAD 20 1 13\n"
             "op 5 1 0x1004 4 RETURN - 30 20\n",
             4, XSQ_REL_IRRELEVANT, XSQ_REL_DIRECT, 1);
    /* unmodelled: address varnode narrower than addr_bytes -> may alias, no proof */
    r3_slice("address-width-mismatch", 8, "",
             "vn 10 0 0x4000 4\nvn 12 0 0x4000 8\n"
             "op 1 1 0x1000 0 STORE - 1 12 100\nop 2 1 0x1001 1 STORE - 1 10 101\n"
             "op 3 1 0x1002 2 LOAD 20 1 12\nop 4 1 0x1003 3 RETURN - 30 20\n",
             3, XSQ_REL_DIRECT, XSQ_REL_POSSIBLE, 0);
    /* read-only ranges apply to the single RAM space only */
    {
        struct xsq_graph g;
        static const char load_body[] = "vn 10 0 0x4000 8\nop 1 1 0x1000 0 LOAD 20 4 10\n"
                                        "op 2 1 0x1001 1 RETURN - 30 20\n";
        CHECK(r3_load(&g, 8, "space 4 other_ram ram\nreadonly 0x4000 0x5000\n", load_body));
        struct xsq_selector sel = {.op_id = 1, .vn_id = XSQ_NONE, .input = -1};
        struct xsq_result r;
        if (g.ops) {
            CHECK(xsq_slice(&g, sel, NULL, &r) == XSQ_OK);
            CHECK(!has_boundary(&r, XSQ_BOUND_IMMUTABLE_LOAD) && !r.exhaustive);
            xsq_result_free(&r);
            xsq_free(&g);
        }
        CHECK(r3_load(&g, 8, "readonly 0x4000 0x5000\n",
                      "vn 10 0 0x4000 8\nop 1 1 0x1000 0 LOAD 20 1 10\nop 2 1 0x1001 1 RETURN - 30 20\n"));
        if (g.ops) {
            CHECK(xsq_slice(&g, sel, NULL, &r) == XSQ_OK);
            CHECK(has_boundary(&r, XSQ_BOUND_IMMUTABLE_LOAD) && r.exhaustive);
            xsq_result_free(&r);
            xsq_free(&g);
        }
    }

    /* C1/C2: control-edge cap and interrupted frontier (review nested-controls) */
    unsigned sweeps = 0;
    for (unsigned levels = 3; levels <= 25; levels += 22) {
        size_t len;
        char *text = r3_nested(levels, &len);
        struct xsq_graph g;
        CHECK(xsq_load_buffer(text, len, &g) == XSQ_OK);
        free(text);
        if (!g.ops)
            continue;
        uint32_t root = levels + 1; /* RETURN in the guarded block */
        struct xsq_result full;
        CHECK(xsq_controls(&g, root, NULL, &full) == XSQ_OK && full.control_count == levels);
        for (uint32_t e = 1; e <= levels + 1; ++e) {
            struct xsq_budget b;
            memset(&b, 0, sizeof b);
            b.max_edges = e;
            struct xsq_result r;
            enum xsq_status st = xsq_controls(&g, root, &b, &r);
            CHECK(r.edges <= e && r.control_count <= e);
            CHECK(e >= levels ? st == XSQ_OK : (st == XSQ_PARTIAL && r.limit == XSQ_LIMIT_EDGES));
            CHECK(r3_frontier_truthful(&full, &r));
            check_result(&g, &r, &b, 1);
            xsq_result_free(&r);
            sweeps++;
        }
        for (uint64_t w = 1; w <= full.work; ++w) {
            struct xsq_budget b;
            memset(&b, 0, sizeof b);
            b.max_work = w;
            struct xsq_result r;
            enum xsq_status st = xsq_controls(&g, root, &b, &r);
            CHECK(st == XSQ_PARTIAL || st == XSQ_OK);
            if (st == XSQ_PARTIAL)
                CHECK(r.frontier_count > 0 || !r.frontier_complete);
            CHECK(r3_frontier_truthful(&full, &r));
            check_result(&g, &r, &b, 1);
            xsq_result_free(&r);
            sweeps++;
        }
        /* the review's exact case: 3 levels, one unit short of the full work */
        if (levels == 3) {
            struct xsq_budget b;
            memset(&b, 0, sizeof b);
            b.max_work = full.work - 3;
            struct xsq_result r;
            CHECK(xsq_controls(&g, root, &b, &r) == XSQ_PARTIAL);
            CHECK(r.frontier_count > 0 || !r.frontier_complete);
            xsq_result_free(&r);
        }
        /* slice frontier: a work-limited slice reports the interrupted node */
        for (uint64_t w = 1; w <= 200; ++w) {
            struct xsq_budget b;
            memset(&b, 0, sizeof b);
            b.max_work = w;
            struct xsq_result r;
            struct xsq_selector sel = {.op_id = root, .vn_id = XSQ_NONE, .input = 1};
            enum xsq_status st = xsq_slice(&g, sel, &b, &r);
            if (st == XSQ_PARTIAL)
                CHECK(r.frontier_count > 0 || !r.frontier_complete);
            check_result(&g, &r, &b, 0);
            xsq_result_free(&r);
            sweeps++;
        }
        xsq_result_free(&full);
        xsq_free(&g);
    }

    /* C3: pre-cancelled loads hash nothing (counted work, not time) */
    {
        size_t size = (size_t)64 << 20;
        char *bytes = malloc(size);
        CHECK(bytes != NULL);
        if (bytes) {
            memset(bytes, 'x', size);
            struct xsq_cancel flag;
            xsq_cancel_init(&flag);
            xsq_cancel_request(&flag);
            struct xsq_load_budget lb = {.max_bytes = 1, .cancel = &flag};
            struct xsq_graph g;
            xsq_test_hashed_bytes(1);
            xsq_test_alloc_fail_at(-1);
            CHECK(xsq_load_buffer_budget(bytes, size, &lb, &g) == XSQ_CANCELLED);
            CHECK(xsq_test_hashed_bytes(1) == 0 && xsq_test_alloc_fail_at(-1) == 0);
            /* oversized input is refused before hashing as well */
            struct xsq_load_budget big = {0};
            CHECK(xsq_load_buffer_budget(bytes, (size_t)XSQ_MAX_FILE_BYTES + 1, &big, &g) == XSQ_LIMIT);
            CHECK(xsq_test_hashed_bytes(1) == 0);
            /* oracle sanity: an uncancelled load does hash the whole buffer */
            CHECK(xsq_load_buffer_budget(bytes, (size_t)2 << 20, &big, &g) == XSQ_LIMIT); /* line too long */
            CHECK(xsq_test_hashed_bytes(1) == (unsigned long long)2 << 20);
            free(bytes);
        }
    }
    printf("r3 regressions: %u bounded sweep runs\n", sweeps);
}

/* Cancellation arriving during hashing stops within one 1 MiB chunk. */
struct hash_canceller { struct xsq_cancel *flag; unsigned long long at; };

static void *cancel_mid_hash(void *arg)
{
    struct hash_canceller *c = arg;
    for (int i = 0; i < 200000; ++i) {
        unsigned long long h = xsq_test_hashed_bytes(0);
        if (h >= (8ull << 20)) {
            xsq_cancel_request(c->flag);
            c->at = xsq_test_hashed_bytes(0);
            return NULL;
        }
        usleep(10);
    }
    return NULL;
}

static void test_cancel_during_hash(void)
{
    size_t size = (size_t)64 << 20;
    char *bytes = malloc(size);
    CHECK(bytes != NULL);
    if (!bytes)
        return;
    memset(bytes, 'x', size);
    int observed = 0;
    for (int attempt = 0; attempt < 3 && !observed; ++attempt) {
        struct xsq_cancel flag;
        xsq_cancel_init(&flag);
        struct hash_canceller c = {&flag, 0};
        struct xsq_load_budget lb = {.cancel = &flag};
        struct xsq_graph g;
        xsq_test_hashed_bytes(1);
        pthread_t t;
        pthread_create(&t, NULL, cancel_mid_hash, &c);
        enum xsq_status st = xsq_load_buffer_budget(bytes, size, &lb, &g);
        pthread_join(t, NULL);
        unsigned long long done = xsq_test_hashed_bytes(1);
        if (st == XSQ_CANCELLED && c.at && done < size) {
            observed = 1;
            CHECK(done <= c.at + (2ull << 20)); /* at most the chunk in flight plus one */
            printf("cancel during hash: requested at %llu bytes, stopped at %llu of %zu\n", c.at, done, size);
        } else if (st != XSQ_CANCELLED) {
            xsq_free(&g);
        }
    }
    CHECK(observed);
    free(bytes);
}

int main(int argc, char **argv)
{
    if (argc != 2 && !(argc == 3 && !strcmp(argv[2], "--concurrency-only"))) {
        fprintf(stderr, "usage: test-xsq FIXTURE_DIR [--concurrency-only]\n");
        return 2;
    }
    dir = argv[1];
    if (argc == 3) { /* the subset run under ThreadSanitizer */
        test_cancel_latency();
        test_concurrent_cancel();
        test_cancel_during_hash();
        printf("%d checks, %d failures\n", checks, failures);
        return failures ? 1 : 0;
    }
    test_units();
    test_malformed();
    test_deep_chain(200000);
    test_phi_ring(5000);
    test_diamonds(20000);
    test_cancel_latency();
    test_alloc_failures();
    test_budget_edges();
    test_load_budget();
    test_concurrent_cancel();
    test_r3_regressions();
    test_cancel_during_hash();
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
