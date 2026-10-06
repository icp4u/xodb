// C07-R3 duplicate-evidence tests (contract v3 section 5). Separate sources
// whose candidates share an address range and name are one code object only
// when every identity, content and lifetime fact agrees; anything else stays
// ambiguous and is never corroborated. Fixtures come from a small writer in
// this file (not tests/jitmap_build.h). Each case prints one JSON line; the
// last line counts checks and failures. Usage: test-r3
#define _GNU_SOURCE
#include "jitmap.h"
#include "oracle.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures, checks;
#define CHECK(cond)                                                                 \
    do {                                                                            \
        checks++;                                                                   \
        if (!(cond)) {                                                              \
            failures++;                                                             \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                           \
    } while (0)

#define PID 4242u
#define ADDR 0x7f0000001000ull
#define MOVED 0x7f0000009000ull

static const struct xodb_jit_clock mono = {XODB_JIT_CLOCK_MONOTONIC, 1, {1, 2, 3}};
static const struct xodb_jit_clock other = {XODB_JIT_CLOCK_MONOTONIC, 1, {4, 5, 6}};

/* ---- writer ------------------------------------------------------------- */

struct buf {
    uint8_t *p;
    size_t n, cap;
    int swap;
};

static void put(struct buf *b, const void *p, size_t n)
{
    if (b->n + n > b->cap) {
        b->cap = (b->n + n) * 2 + 64;
        b->p = realloc(b->p, b->cap);
        if (!b->p)
            abort();
    }
    memcpy(b->p + b->n, p, n);
    b->n += n;
}

static void u32(struct buf *b, uint32_t v)
{
    v = b->swap ? __builtin_bswap32(v) : v;
    put(b, &v, 4);
}

static void u64(struct buf *b, uint64_t v)
{
    v = b->swap ? __builtin_bswap64(v) : v;
    put(b, &v, 8);
}

/* What one producer file says about the code at ADDR. */
struct spec {
    int swap;
    uint32_t mach, tid;
    uint64_t header_time, load_time, index, size;
    uint8_t fill;
    const char *name;
    uint32_t debug_line;   /* 0: no DEBUG_INFO record */
    int unwind;            /* 0 none, 1 data pattern, 2 pattern with one byte changed */
    uint64_t move_time;    /* 0: no MOVE; else MOVE ADDR -> MOVED */
    int stop_after_load;   /* snapshot: file ends right after the LOAD */
};

static struct spec base(void)
{
    return (struct spec){0, 62, 1, 50, 100, 7, 0x40, 0x90, "alpha", 0, 0, 0, 0};
}

static void header(struct buf *b, const struct spec *s)
{
    u32(b, 0x4A695444u);
    u32(b, 1);
    u32(b, 40);
    u32(b, s->mach);
    u32(b, 0);
    u32(b, PID);
    u64(b, s->header_time);
    u64(b, 0);
}

static void dump(struct buf *b, const struct spec *s)
{
    memset(b, 0, sizeof *b);
    b->swap = s->swap;
    header(b, s);
    if (s->debug_line) {
        static const char file[] = "owned.js";
        u32(b, 2);
        u32(b, (uint32_t)(32 + 16 + sizeof file));
        u64(b, s->load_time);
        u64(b, ADDR);
        u64(b, 1);
        u64(b, ADDR + 4);
        u32(b, s->debug_line);
        u32(b, 0);
        put(b, file, sizeof file);
    }
    if (s->unwind) {
        u32(b, 4);
        u32(b, 40 + 16);
        u64(b, s->load_time);
        u64(b, 16);
        u64(b, 8);
        u64(b, 16);
        for (uint8_t i = 0; i < 16; ++i) {
            uint8_t x = (uint8_t)(i * 7 + (s->unwind == 2 && i == 9));
            put(b, &x, 1);
        }
    }
    size_t name = strlen(s->name) + 1;
    u32(b, 0);
    u32(b, (uint32_t)(56 + name + s->size));
    u64(b, s->load_time);
    u32(b, PID);
    u32(b, s->tid);
    u64(b, ADDR);
    u64(b, ADDR);
    u64(b, s->size);
    u64(b, s->index);
    put(b, s->name, name);
    for (uint64_t i = 0; i < s->size; ++i)
        put(b, &s->fill, 1);
    if (s->stop_after_load)
        return;
    if (s->move_time) {
        u32(b, 1);
        u32(b, 64);
        u64(b, s->move_time);
        u32(b, PID);
        u32(b, s->tid);
        u64(b, MOVED);
        u64(b, ADDR);
        u64(b, MOVED);
        u64(b, s->size);
        u64(b, s->index);
    }
    u32(b, 3);
    u32(b, 16);
    u64(b, 200);
}

/* ---- model and query ---------------------------------------------------- */

static struct xodb_jit_process me(void)
{
    struct xodb_jit_process p = {PID, 1, 77, {0}};
    p.boot_id[0] = 0xb0;
    return p;
}

static struct xodb_jit_source_meta meta(void)
{
    struct xodb_jit_source_meta m;
    memset(&m, 0, sizeof m);
    m.process = me();
    m.clock = mono;
    m.has_coverage_end = 1;
    m.coverage_end = 1000;
    m.label = "r3";
    return m;
}

enum kind { DUMP, MAP };

struct input {
    enum kind kind;
    struct spec spec;
    const char *map; /* perf-map text */
    struct xodb_jit_source_meta meta;
};

static struct input jd(struct spec s)
{
    return (struct input){DUMP, s, NULL, meta()};
}

static struct input pm(const char *text)
{
    return (struct input){MAP, base(), text, meta()};
}

static struct oracle_result oracle;

static uint64_t ceil_log2(uint64_t n)
{
    uint64_t k = 0;
    while (k < 64 && (1ull << k) < n)
        k++;
    return k;
}

static uint64_t query_bound(const struct xodb_jit_model *m)
{
    uint64_t bound = 16 + oracle_class_bound(m);
    for (size_t i = 0; i < m->source_count; ++i) {
        const struct xodb_jit_source *s = &m->sources[i];
        bound += 1;
        if (s->index.coord_count >= 2)
            bound += ceil_log2(s->index.coord_count) + 1 +
                     (ceil_log2(s->index.base) + 1) * (1 + 4 * (ceil_log2(s->version_count + 1) + 1));
    }
    return bound;
}

static void load(struct xodb_jit_model *m, const struct input *in, size_t n)
{
    xodb_jit_model_init(m, NULL);
    for (size_t i = 0; i < n; ++i) {
        if (in[i].kind == MAP) {
            CHECK(xodb_jit_add_perfmap(m, &in[i].meta, (const uint8_t *)in[i].map, strlen(in[i].map), NULL) ==
                  XODB_JIT_OK);
            continue;
        }
        struct buf b;
        dump(&b, &in[i].spec);
        CHECK(xodb_jit_add_jitdump(m, &in[i].meta, b.p, b.n, NULL) == XODB_JIT_OK);
        free(b.p);
    }
}

static const char *outcome_name(uint32_t o)
{
    return xodb_jit_outcome_name(o);
}

/* Query ADDR + 8 (or `at`) at time 150 and compare with the expectation. */
static void expect_at(const char *name, const char *claim, const struct input *in, size_t n, uint64_t at,
                      uint32_t outcome, int corroborated, size_t total)
{
    struct xodb_jit_model m;
    load(&m, in, n);
    struct xodb_jit_query q = {me(), at, 1, 150, mono};
    struct xodb_jit_result r;
    struct xodb_jit_control c = {0};
    int e = xodb_jit_resolve_ctl(&m, &q, &c, &r);
    int corr = (r.reasons & XODB_JIT_R_CORROBORATED) != 0;
    int ok = e == XODB_JIT_OK && r.outcome == outcome && corr == corroborated && r.total == total && r.total_exact;
    oracle_resolve(&m, &q, &oracle);
    int agree = !oracle_compare(&r, &oracle);
    int bounded = c.work <= query_bound(&m);
    CHECK(ok);
    CHECK(agree);
    CHECK(bounded);
    printf("{\"case\":\"%s\",\"claim\":\"%s\",\"outcome\":\"%s\",\"expected\":\"%s\",\"corroborated\":%s,"
           "\"total\":%zu,\"work\":%llu,\"oracle_agrees\":%s,\"within_bound\":%s,\"pass\":%s}\n",
           name, claim, outcome_name(r.outcome), outcome_name(outcome), corr ? "true" : "false", r.total,
           (unsigned long long)c.work, agree ? "true" : "false", bounded ? "true" : "false",
           ok && agree && bounded ? "true" : "false");
    xodb_jit_model_free(&m);
}

static void expect(const char *name, const char *claim, const struct input *in, size_t n, uint32_t outcome,
                   int corroborated, size_t total)
{
    expect_at(name, claim, in, n, ADDR + 8, outcome, corroborated, total);
}

#define N(a) (sizeof(a) / sizeof *(a))

static void duplicates(void)
{
    struct spec s = base(), t;
    /* Explicitly identical duplicate evidence: one code object, corroborated. */
    {
        struct input in[] = {jd(s), jd(s)};
        expect("identical-copy", "duplicate", in, N(in), XODB_JIT_RESOLVED, 1, 2);
    }
    t = s;
    t.swap = 1;
    {
        struct input in[] = {jd(s), jd(t)};
        expect("identical-other-byte-order", "duplicate", in, N(in), XODB_JIT_RESOLVED, 1, 2);
    }
    t = s;
    t.stop_after_load = 1;
    {
        struct input in[] = {jd(t), jd(s)};
        expect("snapshot-prefix-and-full", "duplicate", in, N(in), XODB_JIT_RESOLVED, 1, 2);
    }
    t = s;
    t.debug_line = 12;
    t.unwind = 1;
    {
        struct input in[] = {jd(t), jd(t)};
        expect("identical-with-debug-and-unwind", "duplicate", in, N(in), XODB_JIT_RESOLVED, 1, 2);
    }
    {
        struct input in[] = {jd(s), jd(s), jd(s)};
        expect("identical-three-sources", "duplicate", in, N(in), XODB_JIT_RESOLVED, 1, 3);
    }
}

static void conflicts(void)
{
    struct spec s = base(), t, u;
    /* Conflicting objects: same incarnation, clock, address,
     * one-byte extent and name; code index 7 byte 'A' vs index 8 byte 'B'. */
    t = s;
    t.size = 1;
    t.fill = 'A';
    u = t;
    u.index = 8;
    u.fill = 'B';
    {
        struct input in[] = {jd(t), jd(u)};
        expect_at("conflicting-object-a-b", "defect", in, N(in), ADDR, XODB_JIT_AMBIGUOUS, 0, 2);
    }
    t = s;
    t.fill = 0xcc;
    {
        struct input in[] = {jd(s), jd(t)};
        expect("different-code-bytes", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    t = s;
    t.index = 8;
    {
        struct input in[] = {jd(s), jd(t)};
        expect("different-code-index", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    t = s;
    t.load_time = 110;
    {
        struct input in[] = {jd(s), jd(t)};
        expect("different-load-time", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    t = s;
    t.move_time = 180;
    {
        struct input in[] = {jd(s), jd(t)};
        expect("different-end-evidence", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    t = s;
    t.tid = 2;
    {
        struct input in[] = {jd(s), jd(t)};
        expect("different-thread", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    t = s;
    t.header_time = 51;
    {
        struct input in[] = {jd(s), jd(t)};
        expect("different-producer-header-time", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    t = s;
    t.mach = 183;
    {
        struct input in[] = {jd(s), jd(t)};
        expect("different-producer-machine", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    t = s;
    t.debug_line = 12;
    u = s;
    u.debug_line = 13;
    {
        struct input in[] = {jd(t), jd(u)};
        expect("different-debug-line", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    {
        struct input in[] = {jd(s), jd(t)};
        expect("debug-in-one-source-only", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    t = s;
    t.unwind = 1;
    u = s;
    u.unwind = 2;
    {
        struct input in[] = {jd(t), jd(u)};
        expect("different-unwind-bytes", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    {
        struct input in[] = {jd(s), jd(t)};
        expect("unwind-in-one-source-only", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    t = s;
    t.name = "alphb";
    {
        struct input in[] = {jd(s), jd(t)};
        expect("different-name", "baseline", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    {
        struct input in[] = {jd(s), jd(s), jd(t)};
        expect("two-identical-one-conflicting", "baseline", in, N(in), XODB_JIT_AMBIGUOUS, 0, 3);
    }
    /* Identity and clock facts of the sources. */
    {
        struct input in[] = {jd(s), jd(s)};
        in[1].meta.process.known = 0;
        expect("one-source-identity-unknown", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    {
        struct input in[] = {jd(s), jd(s)};
        in[1].meta.clock = other;
        in[1].meta.map = (struct xodb_jit_clock_map){XODB_JIT_MAP_OFFSET, mono, 0, 0, 0, 0, 0, "declared"};
        expect("different-source-clock-mapped", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    /* A move creates a version without retained bytes: not shown identical. */
    t = s;
    t.move_time = 120;
    {
        struct input in[] = {jd(t), jd(t)};
        expect_at("moved-identical-copies", "conservative", in, N(in), MOVED + 8, XODB_JIT_AMBIGUOUS, 0, 2);
    }
}

static void mixed(void)
{
    struct spec s = base();
    {
        struct input in[] = {jd(s), pm("7f0000001000 40 alpha\n")};
        expect("jitdump-and-perfmap-same-line", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    {
        struct input in[] = {pm("7f0000001000 40 alpha\n"), pm("7f0000001000 40 alpha\n")};
        expect("two-perfmaps-same-line", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 2);
    }
    {
        struct input in[] = {pm("7f0000001000 40 alpha\n7f0000001000 40 alpha\n")};
        expect("one-perfmap-repeated-line", "baseline", in, N(in), XODB_JIT_UNVERIFIED, 0, 2);
    }
    {
        struct input in[] = {jd(s), jd(s), pm("7f0000001000 40 alpha\n")};
        expect("duplicate-jitdumps-and-perfmap", "defect", in, N(in), XODB_JIT_AMBIGUOUS, 0, 3);
    }
}

/* Byte comparisons are charged: an exact limit completes, one unit less and
 * cancellation give an explicit incomplete result, never a promoted one. */
static void classification_work(void)
{
    struct spec s = base();
    s.size = 65536;
    struct input in[] = {jd(s), jd(s)};
    struct xodb_jit_model m;
    load(&m, in, N(in));
    struct xodb_jit_query q = {me(), ADDR + 8, 1, 150, mono};
    struct xodb_jit_result r;
    struct xodb_jit_control c = {0};
    CHECK(xodb_jit_resolve_ctl(&m, &q, &c, &r) == XODB_JIT_OK && r.outcome == XODB_JIT_RESOLVED &&
          (r.reasons & XODB_JIT_R_CORROBORATED));
    /* Single-source work for the same query, then the classification share. */
    struct xodb_jit_model one;
    load(&one, in, 1);
    struct xodb_jit_control c1 = {0};
    CHECK(xodb_jit_resolve_ctl(&one, &q, &c1, &r) == XODB_JIT_OK && r.outcome == XODB_JIT_RESOLVED);
    uint64_t index_work = 2 * c1.work, classified = c.work - index_work;
    CHECK(c.work > index_work && classified == 1 + 65536 / 4096);
    CHECK(c.work <= query_bound(&m));
    struct xodb_jit_control exact = {c.work, NULL, 0, 0, 0};
    CHECK(xodb_jit_resolve_ctl(&m, &q, &exact, &r) == XODB_JIT_OK && r.outcome == XODB_JIT_RESOLVED);
    int low_ok = 1;
    for (uint64_t limit = index_work; limit < c.work; ++limit) {
        struct xodb_jit_control low = {limit, NULL, 0, 0, 0};
        int e = xodb_jit_resolve_ctl(&m, &q, &low, &r);
        low_ok &= e == XODB_JIT_E_WORK && r.outcome == XODB_JIT_INCOMPLETE && !r.total_exact &&
                  (r.reasons & XODB_JIT_R_QUERY_STOPPED) && !(r.reasons & XODB_JIT_R_CORROBORATED) &&
                  low.stop == XODB_JIT_STOP_WORK && low.work <= limit;
    }
    CHECK(low_ok);
    struct xodb_jit_cancel cancel;
    xodb_jit_cancel_init(&cancel);
    xodb_jit_cancel_request(&cancel);
    struct xodb_jit_control cc = {0, &cancel, 0, 0, 0};
    CHECK(xodb_jit_resolve_ctl(&m, &q, &cc, &r) == XODB_JIT_E_CANCELLED && r.outcome == XODB_JIT_INCOMPLETE &&
          cc.stop == XODB_JIT_STOP_CANCELLED);
    printf("{\"case\":\"classification-work\",\"claim\":\"bound\",\"work\":%llu,\"index_work\":%llu,"
           "\"classification_units\":%llu,\"declared_bound\":%llu,\"low_limits_incomplete\":%s}\n",
           (unsigned long long)c.work, (unsigned long long)index_work, (unsigned long long)classified,
           (unsigned long long)query_bound(&m), low_ok ? "true" : "false");
    xodb_jit_model_free(&one);
    xodb_jit_model_free(&m);
}

int main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0); /* JSON lines stay whole beside stderr */
    duplicates();
    conflicts();
    mixed();
    classification_work();
    free(oracle.candidates);
    printf("test-r3: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
