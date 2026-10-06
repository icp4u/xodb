/* Independent allocator oracle for xsq byte accounting (C02-R3).
 * Adapted from the C01-R2/C02-R2 review's budget probe.  Linked with
 * -Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc so every request the
 * library makes is counted here, outside the library; the documented
 * contract is that charged bytes equal cumulative allocator requests (no
 * refunds) for the load phase and for every query.  Counts are requested
 * bytes, not RSS.  usage: alloc-probe UNITS.xsg */
#define _GNU_SOURCE 1
#include "xsq.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static size_t requested;
static int track;
void *__real_malloc(size_t);
void *__real_calloc(size_t, size_t);
void *__real_realloc(void *, size_t);
void *__wrap_malloc(size_t n) { if (track) requested += n; return __real_malloc(n); }
void *__wrap_calloc(size_t n, size_t s) { if (track) requested += n * s; return __real_calloc(n, s); }
void *__wrap_realloc(void *p, size_t n) { if (track) requested += n; return __real_realloc(p, n); }

static int failures, checks;
static void expect(int ok, const char *what, size_t charged, size_t actual)
{
    checks++;
    if (!ok) {
        failures++;
        fprintf(stderr, "FAIL %s: charged %zu, allocator requests %zu\n", what, charged, actual);
    }
}

/* Every query kind at every op of g: charged bytes == allocator requests. */
static size_t probe_queries(const struct xsq_graph *g, const char *label)
{
    size_t total = 0;
    for (uint32_t i = 0; i < g->op_count; ++i) {
        for (int kind = 0; kind < 3; ++kind) {
            struct xsq_result r;
            requested = 0, track = 1;
            if (kind == 2) {
                xsq_controls(g, g->ops[i].id, NULL, &r);
            } else {
                struct xsq_selector sel = {.op_id = g->ops[i].id, .vn_id = XSQ_NONE,
                                           .input = g->ops[i].out != XSQ_NONE ? -1 : 0,
                                           .flags = kind ? XSQ_SLICE_DATA_ONLY : 0};
                xsq_slice(g, sel, NULL, &r);
            }
            track = 0;
            char what[96];
            snprintf(what, sizeof what, "%s op %u query %d", label, g->ops[i].id, kind);
            expect(r.bytes == requested, what, (size_t)r.bytes, requested);
            total += requested;
            xsq_result_free(&r);
        }
    }
    return total;
}

/* levels nested conditional blocks guarding one block (as in the review's
 * nested-25.xsg): its controls query grows the result array. */
static char *nested(unsigned levels, size_t *len)
{
    size_t cap = 4096 + (size_t)levels * 160, n = 0;
    char *t = malloc(cap);
#define P(...) (n += (size_t)snprintf(t + n, cap - n, __VA_ARGS__))
    P("xsg 1\nimage sha256=unknown name=nested\nspec language=synthetic compiler=synthetic addr_bytes=8\n"
      "producer alloc-probe 1\nsource kind=synthetic sha256=none\nqualification level=complete\n"
      "space 0 const constant\nspace 1 ram ram\nspace 2 register register\nfunction 1 nested entry=0x1000\n");
    for (unsigned i = 1; i <= levels + 2; ++i)
        P("block %u 0x%x\n", i, 0x1000 + 0x10 * (i - 1));
    for (unsigned i = 1; i <= levels; ++i)
        P("edge %u %u true\nedge %u %u false\n", i, i + 1, i, levels + 2);
    for (unsigned i = 1; i <= levels; ++i)
        P("vn %u 2 0x%x 1 input param=%u\n", i, 0x10 * i, i - 1);
    P("vn %u 1 0x%x 1 annotation\nvn %u 0 0x0 4\nvn %u 0 0x1 4\n", levels + 1, 0x1000 + 0x10 * levels,
      levels + 2, levels + 3);
    for (unsigned i = 1; i <= levels; ++i)
        P("op %u %u 0x%x 0 CBRANCH - %u %u\n", i, i, 0x1000 + 0x10 * (i - 1), levels + 1, i);
    P("op %u %u 0x%x 0 RETURN - %u %u\nop %u %u 0x%x 0 RETURN - %u %u\nend\n", levels + 1, levels + 1,
      0x1000 + 0x10 * levels, levels + 2, levels + 3, levels + 2, levels + 2, 0x1000 + 0x10 * (levels + 1),
      levels + 2, levels + 2);
#undef P
    *len = n;
    return t;
}

int main(int argc, char **argv)
{
    if (argc != 2)
        return 2;
    struct xsq_graph g;
    requested = 0, track = 1;
    enum xsq_status s = xsq_load_file(argv[1], &g);
    track = 0;
    if (s)
        return 1;
    expect(g.load_bytes == requested, "file load", g.load_bytes, requested);
    printf("file load: charged %zu, allocator requests %zu\n", g.load_bytes, requested);
    FILE *f = fopen(argv[1], "rb");
    char *buf = malloc(1 << 22);
    size_t n = f ? fread(buf, 1, 1 << 22, f) : 0;
    if (f)
        fclose(f);
    struct xsq_graph b;
    requested = 0, track = 1;
    s = xsq_load_buffer(buf, n, &b);
    track = 0;
    expect(s == XSQ_OK && b.load_bytes == requested, "buffer load", b.load_bytes, requested);
    xsq_free(&b);
    free(buf);
    size_t total_q = probe_queries(&g, "units");
    static const unsigned levels[] = {25, 200};
    for (unsigned k = 0; k < 2; ++k) {
        size_t len;
        char *text = nested(levels[k], &len);
        struct xsq_graph ng;
        requested = 0, track = 1;
        s = xsq_load_buffer(text, len, &ng);
        track = 0;
        char what[64];
        snprintf(what, sizeof what, "nested-%u load", levels[k]);
        expect(s == XSQ_OK && ng.load_bytes == requested, what, ng.load_bytes, requested);
        if (s == XSQ_OK) {
            snprintf(what, sizeof what, "nested-%u", levels[k]);
            total_q += probe_queries(&ng, what);
            xsq_free(&ng);
        }
        free(text);
    }
    xsq_free(&g);
    printf("alloc probe: %d checks, %d failures (%zu query bytes requested)\n", checks, failures, total_q);
    return failures ? 1 : 0;
}
