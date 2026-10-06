// C07-R2 contract tests: indexed resolution against the exhaustive oracle,
// declared query bound (low-work-limit regression for the old nested scan),
// preparation work/memory limits with rollback, cancellation across threads,
// boundary/overflow edge cases. Usage: test-r2 [all|oracle|bound|edges|limits|cancel]
#define _GNU_SOURCE
#include "jitmap.h"
#include "adversary.h"
#include "oracle.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int failures, checks;
#define CHECK(cond)                                                                 \
    do {                                                                            \
        checks++;                                                                   \
        if (!(cond)) {                                                              \
            failures++;                                                             \
            if (failures < 40)                                                      \
                fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                           \
    } while (0)

static const struct xodb_jit_clock mono = {XODB_JIT_CLOCK_MONOTONIC, 1, {1, 2, 3}};
static const struct xodb_jit_clock mapped = {XODB_JIT_CLOCK_MONOTONIC, 1, {7, 7, 7}};
static const struct xodb_jit_clock unrelated = {XODB_JIT_CLOCK_MONOTONIC, 1, {9, 9, 9}};

static struct xodb_jit_process incarnation(uint32_t pid, uint64_t ticks)
{
    struct xodb_jit_process p = {pid, 1, ticks, {0}};
    p.boot_id[0] = 0xb0;
    return p;
}

static struct xodb_jit_source_meta meta_for(struct xodb_jit_process p)
{
    struct xodb_jit_source_meta m;
    memset(&m, 0, sizeof m);
    m.process = p;
    m.clock = mono;
    m.label = "r2";
    return m;
}

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* Memory the model must account for: every array capacity plus each source's charge. */
static size_t accounted(const struct xodb_jit_model *m)
{
    size_t total = m->source_cap * sizeof *m->sources + m->version_cap * sizeof *m->versions +
                   m->debug_cap * sizeof *m->debug + m->unwind_cap * sizeof *m->unwinds +
                   m->diag_cap * sizeof *m->diags;
    for (size_t i = 0; i < m->source_count; ++i)
        total += m->sources[i].charged;
    return total;
}

static uint64_t ceil_log2(uint64_t n)
{
    uint64_t k = 0;
    while (k < 64 && (1ull << k) < n)
        k++;
    return k;
}

/* Contract v1 section 2 query bound, summed over sources, plus the v4 classification term. */
static uint64_t query_bound(const struct xodb_jit_model *m)
{
    uint64_t bound = 16 + oracle_class_bound(m);
    for (size_t i = 0; i < m->source_count; ++i) {
        const struct xodb_jit_source *s = &m->sources[i];
        bound += 1;
        if (s->index.coord_count < 2)
            continue;
        uint64_t h = ceil_log2(s->index.base) + 1;
        bound += ceil_log2(s->index.coord_count) + 1 + h * (1 + 4 * (ceil_log2(s->version_count + 1) + 1));
    }
    return bound;
}

static int compare_one(const struct xodb_jit_model *m, const struct xodb_jit_query *q, struct oracle_result *o,
                       const char *what)
{
    struct xodb_jit_result r;
    struct xodb_jit_control c = {0};
    int e = xodb_jit_resolve_ctl(m, q, &c, &r);
    oracle_resolve(m, q, o);
    int bad = e ? 100 : oracle_compare(&r, o);
    if (!bad && c.work > query_bound(m))
        bad = 200;
    CHECK(!bad);
    if (bad && failures < 40)
        fprintf(stderr, "  %s: mismatch %d addr=%#llx has_time=%d time=%llu pid=%u known=%d: lib outcome=%u total=%zu "
                        "reasons=%#x / oracle outcome=%u total=%zu reasons=%#x work=%llu bound=%llu\n",
                what, bad, (unsigned long long)q->address, q->has_time, (unsigned long long)q->time, q->process.pid,
                q->process.known, r.outcome, r.total, r.reasons, o->outcome, o->total, o->reasons,
                (unsigned long long)c.work, (unsigned long long)query_bound(m));
    return bad;
}

/* ---- randomized differential against the oracle -------------------------- */

static uint64_t rng = 0x9e3779b97f4a7c15ull;
static uint64_t rnd(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}
static uint64_t pick(uint64_t n) { return rnd() % n; }

#define RPID 555u
static const uint64_t raddr[] = {0x1000, 0x1010, 0x1020, 0x1040, 0x1080, 0x2000, 0xfffffffffffff000ull};
static const uint64_t rsize[] = {0x8, 0x10, 0x20, 0x40, 0x80, 0x1000};

static uint64_t random_time(int extreme)
{
    static const uint64_t small[] = {100, 100, 101, 102, 105, 110, 120, 150};
    static const uint64_t big[] = {0, 1, UINT64_MAX - 1, UINT64_MAX, UINT64_MAX / 2, 1ull << 63};
    return extreme && pick(5) == 0 ? big[pick(6)] : small[pick(8)];
}

static void random_jitdump(struct jb *b, int extreme)
{
    jb_init(b, (int)pick(2));
    jb_header(b, RPID, random_time(extreme), 0);
    int n = 1 + (int)pick(24);
    uint64_t at[5] = {0};
    for (int i = 0; i < n; ++i) {
        uint64_t t = random_time(extreme), idx = 1 + pick(4);
        unsigned kind = (unsigned)pick(20);
        if (kind < 11) {
            uint64_t a = raddr[pick(7)], s = rsize[pick(6)];
            if (a == 0xfffffffffffff000ull)
                s = 0x10;
            jb_load(b, t, RPID, 1, a, s, idx, pick(2) ? "x" : "y", 0x90);
            at[idx] = a;
        } else if (kind < 16) {
            uint64_t from = pick(3) ? at[idx] : raddr[pick(7)], to = raddr[pick(6)];
            jb_move(b, t, RPID, 1, from, to, pick(4) ? 0x40 : 0x10, idx);
            at[idx] = to;
        } else if (kind == 16) {
            jb_close(b, t);
        } else if (kind == 17) {
            uint64_t a = raddr[pick(6)];
            jb_debug_begin(b, t, a, 1);
            jb_debug_entry(b, a + 4, 7, 0, "f.js");
            jb_load(b, t, RPID, 1, a, 0x40, idx, "dbg", 0x90);
            at[idx] = a;
        } else {
            jb_raw_record(b, 9, 24, t);
        }
    }
}

static void random_meta(struct xodb_jit_source_meta *m, int extreme)
{
    static const uint64_t slacks[] = {0, 0, 1, 3, 10, UINT64_MAX};
    static const int64_t offsets[] = {0, 7, -5, -1000, INT64_MAX, INT64_MIN, -(int64_t)(1ull << 62)};
    static const uint64_t uncert[] = {0, 1, 5, UINT64_MAX};
    *m = meta_for(pick(4) ? incarnation(RPID, 9) : (struct xodb_jit_process){RPID, 0, 0, {0}});
    m->slack = slacks[pick(extreme ? 6 : 5)];
    m->header_time_in_clock = pick(4) == 0;
    m->has_coverage_end = (int)pick(2);
    m->coverage_end = random_time(extreme);
    unsigned map = (unsigned)pick(3);
    if (map == 1)
        m->map = (struct xodb_jit_clock_map){XODB_JIT_MAP_OFFSET, mapped, offsets[pick(extreme ? 7 : 4)], 0, 0, 0,
                                             uncert[pick(extreme ? 4 : 3)], "random"};
    else if (map == 2)
        m->map = (struct xodb_jit_clock_map){XODB_JIT_MAP_PERF_TSC, mapped, 0,
                                             pick(2) ? 3u : 0xffffffffu, (uint16_t)(pick(2) ? 1 : 63),
                                             pick(2) ? 7 : UINT64_MAX - 3, uncert[pick(3)], "random tsc"};
}

static void random_case(struct oracle_result *o, int extreme)
{
    struct xodb_jit_model m;
    xodb_jit_model_init(&m, NULL);
    int sources = 1 + (int)pick(3);
    struct jb prev = {0};
    struct xodb_jit_source_meta prev_meta;
    for (int s = 0; s < sources; ++s) {
        struct xodb_jit_source_meta meta;
        random_meta(&meta, extreme);
        if (prev.bytes && pick(2)) {
            /* C07-R3: the previous jitdump again - exact copy, a copy with one
             * byte changed, or a copy under other metadata (duplicate rule). */
            unsigned how = (unsigned)pick(3);
            if (how < 2)
                meta = prev_meta;
            if (how == 1 && prev.len > 40)
                prev.bytes[40 + pick(prev.len - 40)] ^= 1;
            xodb_jit_add_jitdump(&m, &meta, prev.bytes, prev.len, NULL);
        } else if (pick(4)) {
            jb_free(&prev);
            random_jitdump(&prev, extreme);
            prev_meta = meta;
            int e = xodb_jit_add_jitdump(&m, &meta, prev.bytes, prev.len, NULL);
            CHECK(e == XODB_JIT_OK);
        } else {
            char text[512];
            size_t len = 0;
            int lines = 1 + (int)pick(6);
            for (int i = 0; i < lines; ++i)
                len += (size_t)snprintf(text + len, sizeof text - len, "%llx %llx %s\n",
                                        (unsigned long long)raddr[pick(6)], (unsigned long long)rsize[pick(5)],
                                        pick(2) ? "x" : "y");
            meta.process.pid = RPID;
            CHECK(xodb_jit_add_perfmap(&m, &meta, (const uint8_t *)text, len, NULL) == XODB_JIT_OK);
        }
    }
    jb_free(&prev);
    CHECK(m.memory == accounted(&m));
    uint64_t addrs[64], times[96];
    size_t na = 0, nt = 0;
    for (size_t i = 0; i < m.version_count && na + 4 <= 64; ++i) {
        const struct xodb_jit_version *v = &m.versions[i];
        addrs[na++] = v->start;
        addrs[na++] = v->start + v->size - 1;
        addrs[na++] = v->start + v->size;
        addrs[na++] = v->start ? v->start - 1 : 0;
    }
    for (size_t i = 0; i < m.version_count && nt + 10 <= 96; ++i) {
        const struct xodb_jit_version *v = &m.versions[i];
        uint64_t ts[2] = {v->begin.time, v->end.time};
        for (int k = 0; k < (v->end.has_time ? 2 : 1); ++k) {
            times[nt++] = ts[k];
            times[nt++] = ts[k] + 1;
            times[nt++] = ts[k] - 1;
            times[nt++] = ts[k] + 7;
        }
    }
    times[nt++] = 0;
    times[nt++] = UINT64_MAX;
    for (int qn = 0; qn < 160 && na; ++qn) {
        struct xodb_jit_query q;
        memset(&q, 0, sizeof q);
        unsigned who = (unsigned)pick(4);
        q.process = who == 0 ? (struct xodb_jit_process){RPID, 0, 0, {0}} : who == 1 ? incarnation(RPID, 10)
                                                                                     : incarnation(RPID, 9);
        q.address = addrs[pick(na)];
        q.has_time = pick(6) != 0;
        q.time = times[pick(nt)];
        unsigned c = (unsigned)pick(5);
        q.clock = c < 3 ? mono : c == 3 ? mapped : unrelated;
        compare_one(&m, &q, o, extreme ? "random-extreme" : "random");
    }
    xodb_jit_model_free(&m);
}

/* ---- adversarial families against the oracle ----------------------------- */

static void family_case(enum adv_family f, uint32_t n, struct oracle_result *o, int check_bound_vs_oracle)
{
    struct jb b;
    adv_build(&b, f, n);
    struct xodb_jit_model m;
    xodb_jit_model_init(&m, NULL);
    struct xodb_jit_source_meta meta = meta_for(incarnation(ADV_PID, 1));
    meta.has_coverage_end = 1;
    meta.coverage_end = adv_last_time(f, n) + 100000;
    if (f == ADV_UNCERTAIN) {
        meta.slack = 25;
        meta.map = (struct xodb_jit_clock_map){XODB_JIT_MAP_OFFSET, mapped, 1000, 0, 0, 0, 40, "declared"};
    }
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    CHECK(m.version_count == n && m.memory == accounted(&m));
    uint64_t hot = adv_hot(f, n), last = adv_last_time(f, n);
    uint64_t probe_times[] = {ADV_T0 - 1, ADV_T0, ADV_T0 + 1, (ADV_T0 + last) / 2, (ADV_T0 + last) / 2 + 5, last,
                              last + 1, last + 50, last + 1000};
    struct xodb_jit_process p = incarnation(ADV_PID, 1);
    uint64_t old_visits = 0;
    for (int clk = 0; clk < (f == ADV_UNCERTAIN ? 2 : 1); ++clk)
        for (size_t i = 0; i <= sizeof probe_times / sizeof *probe_times; ++i) {
            struct xodb_jit_query q = {p, hot, i < sizeof probe_times / sizeof *probe_times,
                                       i < sizeof probe_times / sizeof *probe_times ? probe_times[i] + (clk ? 1000 : 0)
                                                                                    : 0,
                                       clk ? mapped : mono};
            char what[64];
            snprintf(what, sizeof what, "family %s n=%u", adv_names[f], n);
            if (compare_one(&m, &q, o, what))
                continue;
            if (o->visits > old_visits)
                old_visits = o->visits;
        }
    /* The old nested scan's worst hot query costs far more than the declared bound. */
    if (check_bound_vs_oracle && f != ADV_SAME_INDEX)
        CHECK(old_visits > 16 * query_bound(&m));
    xodb_jit_model_free(&m);
    jb_free(&b);
}

static void test_oracle(void)
{
    struct oracle_result o = {0};
    double t0 = now();
    for (int i = 0; i < 3000; ++i)
        random_case(&o, 0);
    for (int i = 0; i < 3000; ++i)
        random_case(&o, 1);
    for (int f = 0; f < ADV_COUNT; ++f)
        for (uint32_t n = 1; n <= 300; n = n < 20 ? n + 1 : n * 2)
            family_case((enum adv_family)f, n, &o, 0);
    free(o.candidates);
    printf("oracle: %d checks so far, %.2fs\n", checks, now() - t0);
}

/* ---- declared bound / low-work-limit regression -------------------------- */

static void test_bound(void)
{
    struct oracle_result o = {0};
    /* n = 2048: the old nested scan needs ~n^2 = 4.2M visits per hot query. */
    for (int f = 0; f < ADV_COUNT; ++f)
        family_case((enum adv_family)f, 2048, &o, 1);

    struct jb b;
    adv_build(&b, ADV_SAME_TIME, 2048);
    struct xodb_jit_model m;
    xodb_jit_model_init(&m, NULL);
    struct xodb_jit_source_meta meta = meta_for(incarnation(ADV_PID, 1));
    meta.has_coverage_end = 1;
    meta.coverage_end = ADV_T0 + 1000;
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    struct xodb_jit_query q = {incarnation(ADV_PID, 1), ADV_A + 8, 1, ADV_T0 + 500, mono};
    uint64_t bound = query_bound(&m);
    /* Low work limit: the declared bound (a few hundred units) completes exactly. */
    struct xodb_jit_control c = {bound, NULL, 0, 0, 0};
    struct xodb_jit_result r;
    CHECK(xodb_jit_resolve_ctl(&m, &q, &c, &r) == XODB_JIT_OK);
    CHECK(r.outcome == XODB_JIT_AMBIGUOUS && r.total == 2048 && r.total_exact && r.count == 16 &&
          (r.reasons & XODB_JIT_R_CANDIDATES_TRUNCATED) && c.work <= bound && c.stop == XODB_JIT_STOP_NONE);
    oracle_resolve(&m, &q, &o);
    CHECK(o.total == 2048 && o.visits >= 2048ull * 2048ull);
    printf("bound: same_time n=2048 hot query: indexed work %llu (declared bound %llu), old nested scan visits %llu\n",
           (unsigned long long)c.work, (unsigned long long)bound, (unsigned long long)o.visits);
    /* Below what any scan could need: explicit incomplete result, never promoted. */
    for (uint64_t limit = 1; limit < c.work; limit = limit * 2 + 1) {
        struct xodb_jit_control low = {limit, NULL, 0, 0, 0};
        int e = xodb_jit_resolve_ctl(&m, &q, &low, &r);
        CHECK(e == XODB_JIT_E_WORK && r.outcome == XODB_JIT_INCOMPLETE && !r.total_exact &&
              (r.reasons & XODB_JIT_R_QUERY_STOPPED) && low.work <= limit && low.stop == XODB_JIT_STOP_WORK);
    }
    /* Exactly the measured work suffices; one less does not (deterministic counter). */
    struct xodb_jit_control exact = {c.work, NULL, 0, 0, 0}, less = {c.work - 1, NULL, 0, 0, 0};
    CHECK(xodb_jit_resolve_ctl(&m, &q, &exact, &r) == XODB_JIT_OK && exact.work == c.work);
    CHECK(xodb_jit_resolve_ctl(&m, &q, &less, &r) == XODB_JIT_E_WORK && r.outcome == XODB_JIT_INCOMPLETE);
    /* The model limit applies without a control too. */
    xodb_jit_model_free(&m);
    struct xodb_jit_limits limits;
    xodb_jit_limits_default(&limits);
    limits.max_query_work = 10;
    xodb_jit_model_init(&m, &limits);
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    CHECK(xodb_jit_resolve(&m, &q, &r) == XODB_JIT_E_WORK && r.outcome == XODB_JIT_INCOMPLETE);
    xodb_jit_model_free(&m);
    jb_free(&b);

    /* Bound holds at larger n for every family; work grows ~log^2. */
    for (int f = 0; f < ADV_COUNT; ++f)
        for (uint32_t n = 128; n <= 8192; n *= 4) {
            adv_build(&b, (enum adv_family)f, n);
            xodb_jit_model_init(&m, NULL);
            CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
            uint64_t worst = 0;
            for (uint64_t t = ADV_T0 - 1; t <= adv_last_time((enum adv_family)f, n) + 1;
                 t += 1 + adv_last_time((enum adv_family)f, n) / 64) {
                struct xodb_jit_query hq = {incarnation(ADV_PID, 1), adv_hot((enum adv_family)f, n), 1, t, mono};
                struct xodb_jit_control hc = {0};
                CHECK(xodb_jit_resolve_ctl(&m, &hq, &hc, &r) == XODB_JIT_OK && r.total_exact);
                if (hc.work > worst)
                    worst = hc.work;
            }
            CHECK(worst <= query_bound(&m));
            xodb_jit_model_free(&m);
            jb_free(&b);
        }
    free(o.candidates);
}

/* ---- edges: zero/one version, exact boundaries, overflow ----------------- */

static struct xodb_jit_result ask(const struct xodb_jit_model *m, uint64_t a, int has_time, uint64_t t,
                                  struct xodb_jit_clock clock)
{
    struct xodb_jit_query q = {incarnation(ADV_PID, 1), a, has_time, t, clock};
    struct xodb_jit_result r;
    struct oracle_result o = {0};
    CHECK(xodb_jit_resolve(m, &q, &r) == XODB_JIT_OK);
    oracle_resolve(m, &q, &o);
    CHECK(!oracle_compare(&r, &o));
    free(o.candidates);
    return r;
}

static void test_edges(void)
{
    struct xodb_jit_model m;
    struct xodb_jit_source_meta meta = meta_for(incarnation(ADV_PID, 1));
    meta.has_coverage_end = 1;
    meta.coverage_end = 5000;
    struct jb b;

    /* Zero versions: header only, and an empty perf map. */
    jb_init(&b, 0);
    jb_header(&b, ADV_PID, 1, 0);
    xodb_jit_model_init(&m, NULL);
    struct xodb_jit_control c = {0};
    CHECK(xodb_jit_add_jitdump_ctl(&m, &meta, b.bytes, b.len, &c, NULL) == XODB_JIT_OK);
    CHECK(m.version_count == 0 && m.sources[0].index.entry_count == 0 && c.work >= 1);
    CHECK(xodb_jit_add_perfmap(&m, &meta, (const uint8_t *)"", 0, NULL) == XODB_JIT_OK);
    struct xodb_jit_result r = ask(&m, 0x1000, 1, 10, mono);
    CHECK(r.outcome == XODB_JIT_NO_MATCH && r.total_exact);
    CHECK(m.memory == accounted(&m));
    xodb_jit_model_free(&m);
    jb_free(&b);

    /* One version: half-open range and exact begin/end boundaries. */
    jb_init(&b, 0);
    jb_header(&b, ADV_PID, 1, 0);
    jb_load(&b, 100, ADV_PID, 1, 0x1000, 0x10, 1, "one", 0x90);
    jb_move(&b, 200, ADV_PID, 1, 0x1000, 0x3000, 0x10, 1);
    xodb_jit_model_init(&m, NULL);
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    CHECK(ask(&m, 0x1000, 1, 99, mono).outcome == XODB_JIT_NO_MATCH);
    r = ask(&m, 0x1000, 1, 100, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_BOUNDARY));
    CHECK(ask(&m, 0x1000, 1, 101, mono).outcome == XODB_JIT_RESOLVED);
    CHECK(ask(&m, 0x100f, 1, 150, mono).outcome == XODB_JIT_RESOLVED);
    CHECK(ask(&m, 0x1010, 1, 150, mono).outcome == XODB_JIT_NO_MATCH); /* end is exclusive */
    CHECK(ask(&m, 0x0fff, 1, 150, mono).outcome == XODB_JIT_NO_MATCH);
    CHECK(ask(&m, 0x1000, 1, 199, mono).outcome == XODB_JIT_RESOLVED);
    r = ask(&m, 0x1000, 1, 200, mono); /* at the move: old copy possibly still there */
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_BOUNDARY));
    CHECK(ask(&m, 0x1000, 1, 201, mono).outcome == XODB_JIT_NO_MATCH);
    r = ask(&m, 0x3000, 1, 200, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_BOUNDARY));
    CHECK(ask(&m, 0x3000, 1, 201, mono).outcome == XODB_JIT_RESOLVED);
    CHECK(m.versions[1].line_base == 0 && m.versions[1].predecessor == 1);
    xodb_jit_model_free(&m);

    /* Exact arithmetic: a map beyond u64 places code after every query time
     * (the C07 draft called this "possible, clock unrelated"). */
    struct xodb_jit_source_meta far = meta;
    far.map = (struct xodb_jit_clock_map){XODB_JIT_MAP_OFFSET, mapped, INT64_MAX, 0, 0, 0, 0, "far"};
    xodb_jit_model_init(&m, NULL);
    struct jb hb;
    jb_init(&hb, 0);
    jb_header(&hb, ADV_PID, 1, 0);
    jb_load(&hb, UINT64_MAX - 10, ADV_PID, 1, 0x1000, 0x10, 1, "late", 0x90);
    CHECK(xodb_jit_add_jitdump(&m, &far, hb.bytes, hb.len, NULL) == XODB_JIT_OK);
    r = ask(&m, 0x1000, 1, UINT64_MAX, mapped);
    CHECK(r.outcome == XODB_JIT_NO_MATCH && (r.reasons & XODB_JIT_R_BEFORE_COVERAGE));
    xodb_jit_model_free(&m);
    jb_free(&hb);
    /* Negative offset below zero: the load precedes query time 0. */
    struct xodb_jit_source_meta back = meta;
    back.map = (struct xodb_jit_clock_map){XODB_JIT_MAP_OFFSET, mapped, -1000, 0, 0, 0, 0, "back"};
    xodb_jit_model_init(&m, NULL);
    CHECK(xodb_jit_add_jitdump(&m, &back, b.bytes, b.len, NULL) == XODB_JIT_OK);
    CHECK(ask(&m, 0x3000, 1, 0, mapped).outcome == XODB_JIT_RESOLVED);
    CHECK(ask(&m, 0x1000, 1, 0, mapped).outcome == XODB_JIT_NO_MATCH); /* moved away at -800 */
    xodb_jit_model_free(&m);
    /* Saturating slack and unbounded uncertainty: everything is a boundary. */
    struct xodb_jit_source_meta vague = meta;
    vague.slack = UINT64_MAX;
    vague.map = (struct xodb_jit_clock_map){XODB_JIT_MAP_OFFSET, mapped, 0, 0, 0, 0, UINT64_MAX, "vague"};
    xodb_jit_model_init(&m, NULL);
    CHECK(xodb_jit_add_jitdump(&m, &vague, b.bytes, b.len, NULL) == XODB_JIT_OK);
    r = ask(&m, 0x1000, 1, 150, mapped);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_BOUNDARY));
    r = ask(&m, 0x1000, 1, 150, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_BOUNDARY));
    xodb_jit_model_free(&m);
    /* perf_tsc with shift 63 and the largest multiplier stays exact; shift 64 is unusable. */
    struct jb tb;
    jb_init(&tb, 0);
    jb_header(&tb, ADV_PID, 1, 1);
    jb_load(&tb, UINT64_MAX - 1, ADV_PID, 1, 0x1000, 0x10, 1, "tsc", 0x90);
    struct xodb_jit_source_meta tsc = meta;
    tsc.clock = (struct xodb_jit_clock){XODB_JIT_CLOCK_ARCH, 1, {4}};
    tsc.coverage_end = UINT64_MAX;
    tsc.map = (struct xodb_jit_clock_map){XODB_JIT_MAP_PERF_TSC, mapped, 0, 0xffffffffu, 63, 5, 0, "tsc"};
    xodb_jit_model_init(&m, NULL);
    CHECK(xodb_jit_add_jitdump(&m, &tsc, tb.bytes, tb.len, NULL) == XODB_JIT_OK);
    /* (2^64 - 2) * (2^32 - 1) >> 63 = 2^33 - 3 (exact); + zero 5 */
    CHECK(ask(&m, 0x1000, 1, (1ull << 33) + 1, mapped).outcome == XODB_JIT_NO_MATCH);
    r = ask(&m, 0x1000, 1, (1ull << 33) + 2, mapped);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_BOUNDARY));
    r = ask(&m, 0x1000, 1, (1ull << 33) + 3, mapped); /* coverage end UINT64_MAX maps to 2^33 + 2 as well */
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && !(r.reasons & XODB_JIT_R_BOUNDARY) &&
          (r.reasons & XODB_JIT_R_AFTER_COVERAGE) && r.candidates[0].state == XODB_JIT_C_LIVE);
    xodb_jit_model_free(&m);
    tsc.map.shift = 64;
    xodb_jit_model_init(&m, NULL);
    CHECK(xodb_jit_add_jitdump(&m, &tsc, tb.bytes, tb.len, NULL) == XODB_JIT_OK);
    r = ask(&m, 0x1000, 1, 5, mapped);
    CHECK(r.outcome == XODB_JIT_UNAVAILABLE && (r.reasons & XODB_JIT_R_CLOCK_UNRELATED));
    xodb_jit_model_free(&m);
    jb_free(&tb);
    jb_free(&b);

    /* Highest addresses: a range ending exactly at 2^64 - 1. */
    jb_init(&b, 0);
    jb_header(&b, ADV_PID, 1, 0);
    jb_load(&b, 10, ADV_PID, 1, UINT64_MAX - 0x10, 0x10, 1, "top", 0x90);
    jb_load(&b, 10, ADV_PID, 1, 0, 0x10, 2, "bottom", 0x90);
    xodb_jit_model_init(&m, NULL);
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    CHECK(ask(&m, UINT64_MAX - 1, 1, 20, mono).outcome == XODB_JIT_RESOLVED);
    CHECK(ask(&m, UINT64_MAX, 1, 20, mono).outcome == XODB_JIT_NO_MATCH);
    CHECK(ask(&m, 0, 1, 20, mono).outcome == XODB_JIT_RESOLVED);
    CHECK(ask(&m, 0x10, 1, 20, mono).outcome == XODB_JIT_NO_MATCH);
    xodb_jit_model_free(&m);
    jb_free(&b);

    /* Raw citations survive indexing: ordinals/offsets of out-of-order records. */
    adv_build(&b, ADV_OUT_OF_ORDER, 64);
    xodb_jit_model_init(&m, NULL);
    meta.coverage_end = ADV_T0 + 10000;
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    r = ask(&m, ADV_A + 8, 1, ADV_T0 + 5, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED);
    const struct xodb_jit_version *v = &m.versions[r.candidates[0].version - 1];
    CHECK(v->begin.time == ADV_T0 && v->begin.ordinal == 64 && v->begin.kind == XODB_JIT_BOUND_LOAD);
    uint32_t id;
    memcpy(&id, m.sources[0].bytes + v->begin.offset, 4);
    CHECK(id == XODB_JIT_REC_LOAD && !memcmp(m.sources[0].bytes + v->name_offset, "reuse", 5));
    xodb_jit_model_free(&m);
    jb_free(&b);
}

/* ---- preparation limits, rollback, success afterwards --------------------- */

struct snapshot {
    size_t sources, versions, debug, unwinds, diags, memory;
    uint64_t dropped;
};

static struct snapshot snap(const struct xodb_jit_model *m)
{
    return (struct snapshot){m->source_count, m->version_count, m->debug_count, m->unwind_count, m->diag_count,
                             m->memory, m->diags_dropped};
}

static int same_except_capacity(const struct xodb_jit_model *m, struct snapshot s)
{
    return m->source_count == s.sources && m->version_count == s.versions && m->debug_count == s.debug &&
           m->unwind_count == s.unwinds && m->diag_count == s.diags && m->diags_dropped == s.dropped &&
           m->memory == accounted(m);
}

static void same_answers(const struct xodb_jit_model *a, const struct xodb_jit_model *b, enum adv_family f, uint32_t n)
{
    for (uint64_t t = ADV_T0 - 1; t <= adv_last_time(f, n) + 1; t += 1 + adv_last_time(f, n) / 16) {
        struct xodb_jit_query q = {incarnation(ADV_PID, 1), adv_hot(f, n), 1, t, mono};
        struct xodb_jit_result ra, rb;
        CHECK(xodb_jit_resolve(a, &q, &ra) == XODB_JIT_OK && xodb_jit_resolve(b, &q, &rb) == XODB_JIT_OK);
        CHECK(ra.outcome == rb.outcome && ra.total == rb.total && ra.count == rb.count && ra.reasons == rb.reasons);
        for (size_t i = 0; i < ra.count && i < rb.count; ++i)
            CHECK(ra.candidates[i].state == rb.candidates[i].state &&
                  ra.candidates[i].reasons == rb.candidates[i].reasons &&
                  a->versions[ra.candidates[i].version - 1].begin.ordinal ==
                      b->versions[rb.candidates[i].version - 1].begin.ordinal);
    }
}

static void test_limits(void)
{
    struct xodb_jit_source_meta meta = meta_for(incarnation(ADV_PID, 1));
    meta.has_coverage_end = 1;
    meta.coverage_end = ADV_T0 + 1000000;
    struct jb b, small;
    adv_build(&b, ADV_NESTED, 4096);
    adv_build(&small, ADV_MOVES, 16);
    struct xodb_jit_model ref, m;
    xodb_jit_model_init(&ref, NULL);
    struct xodb_jit_control c = {0};
    CHECK(xodb_jit_add_jitdump_ctl(&ref, &meta, b.bytes, b.len, &c, NULL) == XODB_JIT_OK);
    uint64_t w = c.work;
    CHECK(w == ref.sources[0].build_work && c.memory_peak <= ref.limits.max_memory_bytes && c.memory_peak > ref.memory);
    printf("limits: nested n=4096 build work %llu, index entries %zu, memory %zu, peak %zu\n", (unsigned long long)w,
           ref.sources[0].index.entry_count, ref.memory, c.memory_peak);

    /* Work limit: below the deterministic count rolls back; exactly it succeeds. */
    uint64_t tries[] = {1, 2, 10, w / 3, w / 2, w - 1};
    for (size_t i = 0; i < sizeof tries / sizeof *tries; ++i) {
        xodb_jit_model_init(&m, NULL);
        CHECK(xodb_jit_add_jitdump(&m, &meta, small.bytes, small.len, NULL) == XODB_JIT_OK);
        struct snapshot before = snap(&m);
        struct xodb_jit_control lim = {tries[i], NULL, 0, 0, 0};
        int index = 7;
        CHECK(xodb_jit_add_jitdump_ctl(&m, &meta, b.bytes, b.len, &lim, &index) == XODB_JIT_E_WORK);
        CHECK(index == -1 && lim.stop == XODB_JIT_STOP_WORK && lim.work <= tries[i]);
        CHECK(same_except_capacity(&m, before));
        /* A successful request afterwards on the same model. */
        CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, &index) == XODB_JIT_OK && index == 1);
        CHECK(m.memory == accounted(&m));
        xodb_jit_model_free(&m);
    }
    xodb_jit_model_init(&m, NULL);
    struct xodb_jit_control exact = {w, NULL, 0, 0, 0};
    CHECK(xodb_jit_add_jitdump_ctl(&m, &meta, b.bytes, b.len, &exact, NULL) == XODB_JIT_OK && exact.work == w);
    same_answers(&ref, &m, ADV_NESTED, 4096);
    xodb_jit_model_free(&m);

    /* Memory sweep: every limit gives OK, a kept partial source, or a rollback;
     * the peak never exceeds the limit and accounting stays exact. */
    int ok = 0, partial = 0, rolled = 0;
    struct jb mid;
    adv_build(&mid, ADV_REUSE, 512);
    xodb_jit_model_init(&m, NULL);
    CHECK(xodb_jit_add_jitdump_ctl(&m, &meta, mid.bytes, mid.len, &c, NULL) == XODB_JIT_OK);
    size_t full = c.memory_peak;
    xodb_jit_model_free(&m);
    for (size_t limit = 64; limit <= full + 4096; limit += full / 97 + 1) {
        struct xodb_jit_limits limits;
        xodb_jit_limits_default(&limits);
        limits.max_memory_bytes = limit;
        xodb_jit_model_init(&m, &limits);
        struct snapshot before = snap(&m);
        struct xodb_jit_control mc = {0};
        int index;
        int e = xodb_jit_add_jitdump_ctl(&m, &meta, mid.bytes, mid.len, &mc, &index);
        CHECK(mc.memory_peak <= limit && m.memory <= limit && m.memory == accounted(&m));
        if (e == XODB_JIT_OK) {
            ok++;
            CHECK(index == 0 && m.version_count == 512);
        } else if (e == XODB_JIT_E_BUDGET && index == 0) {
            partial++;
            CHECK(m.sources[0].partial && m.sources[0].version_count == m.version_count);
            struct xodb_jit_result r;
            struct xodb_jit_query q = {incarnation(ADV_PID, 1), ADV_A + 8, 1, ADV_T0 + 5, mono};
            CHECK(xodb_jit_resolve(&m, &q, &r) == XODB_JIT_OK && r.outcome != XODB_JIT_RESOLVED);
        } else {
            rolled++;
            CHECK(e == XODB_JIT_E_BUDGET && index == -1 && same_except_capacity(&m, before));
        }
        xodb_jit_model_free(&m);
    }
    CHECK(ok > 0 && partial > 0 && rolled > 0);
    printf("limits: memory sweep ok=%d partial=%d rolled_back=%d (full peak %zu bytes)\n", ok, partial, rolled, full);

    /* Many sources: the source array is grown and charged, not reallocated per add. */
    xodb_jit_model_init(&m, NULL);
    for (int i = 0; i < 300; ++i)
        CHECK(xodb_jit_add_jitdump(&m, &meta, small.bytes, small.len, NULL) == XODB_JIT_OK);
    CHECK(m.source_count == 300 && m.source_cap >= 300 && m.memory == accounted(&m));
    xodb_jit_model_free(&m);
    xodb_jit_model_free(&ref);
    jb_free(&mid);
    jb_free(&small);
    jb_free(&b);
}

/* ---- cancellation -------------------------------------------------------- */

struct canceller {
    struct xodb_jit_cancel *token;
    double delay, requested_at;
};

static void *cancel_later(void *arg)
{
    struct canceller *c = arg;
    double until = now() + c->delay;
    while (now() < until)
        ;
    c->requested_at = now();
    xodb_jit_cancel_request(c->token);
    return NULL;
}

struct querier {
    const struct xodb_jit_model *model;
    struct xodb_jit_cancel *token;
    int stop, ok, cancelled, bad;
};

static void *query_loop(void *arg)
{
    struct querier *q = arg;
    struct xodb_jit_query query = {incarnation(ADV_PID, 1), adv_hot(ADV_NESTED, 4096), 1, ADV_T0 + 5000, mono};
    while (!__atomic_load_n(&q->stop, __ATOMIC_ACQUIRE)) {
        struct xodb_jit_control c = {0, q->token, 0, 0, 0};
        struct xodb_jit_result r;
        int e = xodb_jit_resolve_ctl(q->model, &query, &c, &r);
        if (e == XODB_JIT_OK && r.outcome == XODB_JIT_RESOLVED)
            __atomic_add_fetch(&q->ok, 1, __ATOMIC_RELEASE);
        else if (e == XODB_JIT_E_CANCELLED && r.outcome == XODB_JIT_INCOMPLETE && !r.total_exact)
            __atomic_add_fetch(&q->cancelled, 1, __ATOMIC_RELEASE);
        else
            __atomic_add_fetch(&q->bad, 1, __ATOMIC_RELEASE);
    }
    return NULL;
}

static void test_cancel(uint32_t n)
{
    struct xodb_jit_source_meta meta = meta_for(incarnation(ADV_PID, 1));
    meta.has_coverage_end = 1;
    meta.coverage_end = ADV_T0 + 10000000;
    struct jb b;
    adv_build(&b, ADV_NESTED, n);
    struct xodb_jit_cancel token;
    xodb_jit_cancel_init(&token);
    struct xodb_jit_model m;

    /* Already requested: nothing is added, nothing is resolved. */
    xodb_jit_cancel_request(&token);
    xodb_jit_model_init(&m, NULL);
    struct xodb_jit_control c = {0, &token, 0, 0, 0};
    int index;
    CHECK(xodb_jit_add_jitdump_ctl(&m, &meta, b.bytes, b.len, &c, &index) == XODB_JIT_E_CANCELLED);
    CHECK(index == -1 && m.source_count == 0 && c.work == 0 && c.stop == XODB_JIT_STOP_CANCELLED &&
          m.memory == accounted(&m));
    xodb_jit_cancel_reset(&token);
    double t0 = now();
    CHECK(xodb_jit_add_jitdump_ctl(&m, &meta, b.bytes, b.len, &c, &index) == XODB_JIT_OK && index == 0);
    double full = now() - t0;
    uint64_t full_work = c.work;
    xodb_jit_cancel_request(&token);
    struct xodb_jit_query q = {incarnation(ADV_PID, 1), adv_hot(ADV_NESTED, n), 1, ADV_T0 + n + 10, mono};
    struct xodb_jit_result r;
    CHECK(xodb_jit_resolve_ctl(&m, &q, &c, &r) == XODB_JIT_E_CANCELLED && r.outcome == XODB_JIT_INCOMPLETE &&
          (r.reasons & XODB_JIT_R_QUERY_STOPPED) && !r.total_exact);
    xodb_jit_cancel_reset(&token);
    CHECK(xodb_jit_resolve_ctl(&m, &q, &c, &r) == XODB_JIT_OK && r.outcome == XODB_JIT_RESOLVED);
    xodb_jit_model_free(&m);

    /* Requested from another thread mid-preparation, at several points. */
    double worst = 0;
    int stopped = 0, finished = 0;
    for (int i = 0; i < 12; ++i) {
        xodb_jit_cancel_reset(&token);
        xodb_jit_model_init(&m, NULL);
        struct canceller cn = {&token, full * (i + 0.5) / 12.0, 0};
        pthread_t th;
        pthread_create(&th, NULL, cancel_later, &cn);
        struct xodb_jit_control cc = {0, &token, 0, 0, 0};
        int e = xodb_jit_add_jitdump_ctl(&m, &meta, b.bytes, b.len, &cc, &index);
        double done = now();
        pthread_join(th, NULL);
        if (e == XODB_JIT_E_CANCELLED) {
            stopped++;
            double latency = done - cn.requested_at;
            if (latency > worst)
                worst = latency;
            CHECK(index == -1 && m.source_count == 0 && m.version_count == 0 && m.memory == accounted(&m) &&
                  cc.work < full_work);
        } else {
            finished++;
            CHECK(e == XODB_JIT_OK);
        }
        /* The same model serves a successful request after cancellation. */
        xodb_jit_cancel_reset(&token);
        CHECK(xodb_jit_add_jitdump_ctl(&m, &meta, b.bytes, b.len, &cc, &index) == XODB_JIT_OK);
        xodb_jit_model_free(&m);
    }
    CHECK(stopped > 0);
    printf("cancel: nested n=%u full add %.3fs (%llu units); cancelled %d, finished first %d; worst latency %.6fs\n", n,
           full, (unsigned long long)full_work, stopped, finished, worst);
    CHECK(worst < 0.05);

    /* Concurrent queries on one model while another thread toggles the token. */
    xodb_jit_model_init(&m, NULL);
    struct jb q4;
    adv_build(&q4, ADV_NESTED, 4096);
    CHECK(xodb_jit_add_jitdump(&m, &meta, q4.bytes, q4.len, NULL) == XODB_JIT_OK);
    xodb_jit_cancel_reset(&token);
    struct querier qs[3];
    pthread_t th[3];
    for (int i = 0; i < 3; ++i) {
        qs[i] = (struct querier){&m, &token, 0, 0, 0, 0};
        pthread_create(&th[i], NULL, query_loop, &qs[i]);
    }
    for (int i = 0; i < 2000; ++i) {
        if (i & 1)
            xodb_jit_cancel_request(&token);
        else
            xodb_jit_cancel_reset(&token);
        for (volatile int spin = 0; spin < 2000; ++spin)
            ;
    }
    /* After a reset every thread must complete queries again. */
    xodb_jit_cancel_reset(&token);
    int base[3];
    for (int i = 0; i < 3; ++i)
        base[i] = __atomic_load_n(&qs[i].ok, __ATOMIC_ACQUIRE);
    double deadline = now() + 10;
    for (int i = 0; i < 3; ++i)
        while (__atomic_load_n(&qs[i].ok, __ATOMIC_ACQUIRE) == base[i] && now() < deadline)
            ;
    for (int i = 0; i < 3; ++i)
        __atomic_store_n(&qs[i].stop, 1, __ATOMIC_RELEASE);
    int ok = 0, cancelled = 0, bad = 0;
    for (int i = 0; i < 3; ++i) {
        pthread_join(th[i], NULL);
        ok += qs[i].ok;
        cancelled += qs[i].cancelled;
        bad += qs[i].bad;
    }
    CHECK(bad == 0 && ok > 0);
    printf("cancel: concurrent queries ok=%d cancelled=%d bad=%d\n", ok, cancelled, bad);
    xodb_jit_model_free(&m);
    jb_free(&q4);
    jb_free(&b);
}

int main(int argc, char **argv)
{
    const char *what = argc > 1 ? argv[1] : "all";
    int all = !strcmp(what, "all");
    if (all || !strcmp(what, "edges"))
        test_edges();
    if (all || !strcmp(what, "oracle"))
        test_oracle();
    if (all || !strcmp(what, "bound"))
        test_bound();
    if (all || !strcmp(what, "limits"))
        test_limits();
    if (all || !strcmp(what, "cancel"))
        test_cancel(argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : 131072);
    printf("jitmap-r2 %s: %d checks, %d failures\n", what, checks, failures);
    return failures != 0;
}
