// C07-R4 classification-work bound tests (contract v4 section 2).
//
// Long-name perf maps with repeated lines, beside zero, one or two jitdump
// sources, with 1..17 candidates at the query address. Expected work is
// derived here from the fixture description alone, not from the oracle:
//
//  - expect_class() walks the candidates in version order and charges each
//    comparison with the first exactly as contract v4 section 2 states
//    (perf-map pair of one map: floor(name/4096); identical jitdump pair of
//    two sources: 1 + floor(name/4096) + floor(code/4096); anything else
//    stops classification uncharged). Index work is measured as the sum of
//    one-source models with short names (no charged comparison there), so
//    work must equal index + expect_class() for both the long-name fixture
//    and its short-name twin: a comparison branch or constant the library
//    charges and the walk omits (or the reverse) fails. With more than 16
//    candidates (truncated, never classified) long and short work are equal.
//  - class_term() is the declared C term computed from the description
//    (15 * the largest per-version cost); oracle_class_bound(model) must
//    equal it, and measured work must stay within 16 + index + C.
//
// Every case also checks the exact and the one-below work limit. One JSON
// line per case; "claim":"defect" marks the cases whose declared bound C07-R3
// omitted (no or one jitdump source, a perf-map name of 4,096 bytes or more).
// Usage: test-r4
#include "jitmap.h"
#include "jitmap_build.h"
#include "oracle.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures, checks;
static struct oracle_result oracle; /* outcome cross-check only, not the work expectation */
#define CHECK(cond)                                                                 \
    do {                                                                            \
        checks++;                                                                   \
        if (!(cond)) {                                                              \
            failures++;                                                             \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                           \
    } while (0)

#define PID 4343u
#define AT 0x9000ull    /* query address: every perf-map line, optionally the jitdump LOAD */
#define ELSEWHERE 0x5000ull
#define SHORT 100       /* short-name control: floor(100 / 4096) = 0 */

static const struct xodb_jit_clock mono = {XODB_JIT_CLOCK_MONOTONIC, 1, {7, 7}};

struct fx {
    int lines;     /* perf-map lines "9000 1 <name>" */
    size_t name;   /* perf-map and jitdump name length */
    int dumps;     /* identical jitdump sources: 0, 1 or 2 */
    int dump_at;   /* the jitdump LOAD is at AT (a candidate) rather than ELSEWHERE */
    int map_first; /* perf map added before the jitdumps */
    int diff;      /* -1: equal lines; else this line's last name byte differs */
};

static struct xodb_jit_process me(void)
{
    return (struct xodb_jit_process){PID, 1, 1, {9, 9}};
}

static uint8_t *perfmap(const struct fx *f, size_t name, size_t *len)
{
    size_t row = 7 + name + 1;
    uint8_t *p = malloc(f->lines * row + 1);
    if (!p)
        abort();
    for (int i = 0; i < f->lines; ++i) {
        uint8_t *r = p + i * row;
        memcpy(r, "9000 1 ", 7);
        memset(r + 7, 'n', name);
        if (i == f->diff)
            r[7 + name - 1] = 'm';
        r[row - 1] = '\n';
    }
    *len = f->lines * row;
    return p;
}

static void jitdump(struct jb *b, const struct fx *f, size_t name)
{
    char *s = malloc(name + 1);
    if (!s)
        abort();
    memset(s, 'j', name);
    s[name] = 0;
    jb_init(b, 0);
    jb_header(b, PID, 10, 0);
    jb_load(b, 100, PID, 1, f->dump_at ? AT : ELSEWHERE, 1, 1, s, 0xc3);
    jb_close(b, 500);
    free(s);
}

static void build(struct xodb_jit_model *m, const struct fx *f, size_t name)
{
    struct xodb_jit_source_meta meta;
    memset(&meta, 0, sizeof meta);
    meta.process = me();
    meta.clock = mono;
    size_t len;
    uint8_t *map = perfmap(f, name, &len);
    struct jb b;
    jitdump(&b, f, name);
    xodb_jit_model_init(m, NULL);
    if (f->map_first && f->lines)
        CHECK(xodb_jit_add_perfmap(m, &meta, map, len, NULL) == XODB_JIT_OK);
    for (int k = 0; k < f->dumps; ++k)
        CHECK(xodb_jit_add_jitdump(m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    if (!f->map_first && f->lines)
        CHECK(xodb_jit_add_perfmap(m, &meta, map, len, NULL) == XODB_JIT_OK);
    CHECK(m->version_count == (size_t)(f->lines + f->dumps));
    jb_free(&b);
    free(map);
}

/* Classification units the contract charges for this fixture. */
static uint64_t expect_class(const struct fx *f, size_t name)
{
    int kind[40], line[40], n = 0; /* 0 perf-map line, 1 jitdump LOAD; version order */
    if (f->map_first)
        for (int i = 0; i < f->lines; ++i)
            kind[n] = 0, line[n++] = i;
    if (f->dump_at)
        for (int k = 0; k < f->dumps; ++k)
            kind[n] = 1, line[n++] = -1;
    if (!f->map_first)
        for (int i = 0; i < f->lines; ++i)
            kind[n] = 0, line[n++] = i;
    if (n > XODB_JIT_MAX_CANDIDATES) /* truncated: ambiguous, never classified */
        return 0;
    uint64_t units = 0;
    for (int i = 1; i < n; ++i) {
        if (kind[0] == 0 && kind[i] == 0) {
            units += name / 4096; /* equal range and length: the names are compared */
            if (line[0] == f->diff || line[i] == f->diff)
                break;
        } else if (kind[0] == 1 && kind[i] == 1) {
            units += 1 + name / 4096 + 1 / 4096; /* identical copies: no debug, no unwind, 1 code byte */
        } else {
            break; /* perf map with jitdump: not one object, nothing compared */
        }
    }
    return units;
}

/* The declared C term from the fixture description. */
static uint64_t class_term(const struct fx *f, size_t name)
{
    uint64_t worst = 0;
    if (f->lines)
        worst = name / 4096;
    if (f->dumps >= 2 && 1 + name / 4096 > worst)
        worst = 1 + name / 4096;
    return 15 * worst;
}

/* C07-R3 (contract v3) C term, for the report only. */
static uint64_t class_term_v3(const struct fx *f, size_t name)
{
    return f->dumps >= 2 ? 15 * (1 + name / 4096) : 0;
}

static uint64_t clog2(uint64_t n)
{
    uint64_t k = 0;
    while ((1ull << k) < n)
        k++;
    return k;
}

/* v2 section 2 index term: 16 + per source 1 + search cost. */
static uint64_t index_term(const struct xodb_jit_model *m)
{
    uint64_t t = 16;
    for (size_t i = 0; i < m->source_count; ++i) {
        const struct xodb_jit_source *s = &m->sources[i];
        t += 1;
        if (s->index.coord_count >= 2)
            t += clog2(s->index.coord_count) + 1 +
                 (clog2(s->index.base) + 1) * (1 + 4 * (clog2(s->version_count + 1) + 1));
    }
    return t;
}

struct run {
    int rc;
    uint64_t work;
    struct xodb_jit_result r;
};

static struct run query(const struct xodb_jit_model *m, uint64_t limit)
{
    struct xodb_jit_query q = {me(), AT, 0, 0, mono};
    struct xodb_jit_control c = {limit, NULL, 0, 0, 0};
    struct run x;
    x.rc = xodb_jit_resolve_ctl(m, &q, &c, &x.r);
    x.work = c.work;
    return x;
}

/* Exact limit completes with the same result; one unit less is incomplete. */
static int limits_hold(const struct xodb_jit_model *m, const struct run *full)
{
    struct run exact = query(m, full->work), low = query(m, full->work - 1);
    return exact.rc == XODB_JIT_OK && exact.work == full->work && exact.r.outcome == full->r.outcome &&
           exact.r.reasons == full->r.reasons && low.rc == XODB_JIT_E_WORK &&
           low.r.outcome == XODB_JIT_INCOMPLETE && !low.r.total_exact &&
           (low.r.reasons & XODB_JIT_R_QUERY_STOPPED) && low.work <= full->work - 1;
}

static void one(const char *label, const struct fx *f)
{
    struct xodb_jit_model lm, sm;
    build(&lm, f, f->name);
    build(&sm, f, SHORT);
    struct run L = query(&lm, 0), S = query(&sm, 0);
    int fl = failures;
    CHECK(L.rc == XODB_JIT_OK && S.rc == XODB_JIT_OK && L.r.total_exact);
    int total = f->lines + (f->dump_at ? f->dumps : 0);
    CHECK(L.r.total == (size_t)total);
    uint32_t want;
    if (total > XODB_JIT_MAX_CANDIDATES)
        want = XODB_JIT_AMBIGUOUS;
    else if (f->diff >= 0 && f->lines > 1)
        want = XODB_JIT_AMBIGUOUS;
    else if (f->dump_at && f->dumps && f->lines)
        want = XODB_JIT_AMBIGUOUS; /* perf map beside jitdump: never one object */
    else
        want = XODB_JIT_UNVERIFIED; /* perf-map lines only; no query time */
    CHECK(L.r.outcome == want && S.r.outcome == want);
    struct xodb_jit_query q = {me(), AT, 0, 0, mono};
    oracle_resolve(&lm, &q, &oracle);
    CHECK(!oracle_compare(&L.r, &oracle));
    CHECK(total <= XODB_JIT_MAX_CANDIDATES || (L.r.reasons & XODB_JIT_R_CANDIDATES_TRUNCATED));
    /* Index work is a sum over sources (v2 section 2); a model holding only
     * one source and short names has no charged comparison, so its work is
     * that source's index share. */
    struct fx map_only = *f, dump_only = *f;
    map_only.dumps = 0;
    dump_only.lines = 0;
    dump_only.dumps = 1;
    uint64_t idx = 0;
    if (f->lines) {
        struct xodb_jit_model one_map;
        build(&one_map, &map_only, SHORT);
        idx += query(&one_map, 0).work;
        xodb_jit_model_free(&one_map);
    }
    if (f->dumps) {
        struct xodb_jit_model one_dump;
        build(&one_dump, &dump_only, SHORT);
        idx += f->dumps * query(&one_dump, 0).work;
        xodb_jit_model_free(&one_dump);
    }
    uint64_t el = expect_class(f, f->name), es = expect_class(f, SHORT);
    /* With more than 16 candidates the search stops collecting early (no
     * per-source sum) and nothing is classified: names must not matter. */
    int branches = total > XODB_JIT_MAX_CANDIDATES ? el == 0 && L.work == S.work
                                                   : L.work == idx + el && S.work == idx + es;
    CHECK(branches);
    uint64_t C = class_term(f, f->name), oc = oracle_class_bound(&lm);
    int oracle_ok = oc == C && oracle_class_bound(&sm) == class_term(f, SHORT);
    CHECK(oracle_ok);
    uint64_t bound = index_term(&lm) + C, bound3 = index_term(&lm) + class_term_v3(f, f->name);
    int within = L.work <= bound && S.work <= index_term(&sm) + class_term(f, SHORT) &&
                 L.work <= index_term(&lm) + oc;
    CHECK(within);
    int lim = limits_hold(&lm, &L) && limits_hold(&sm, &S);
    CHECK(lim);
    int defect = f->dumps < 2 && f->lines >= 1 && f->name >= 4096;
    printf("{\"case\":\"%s\",\"claim\":\"%s\",\"lines\":%d,\"name\":%zu,\"dumps\":%d,\"dump_at\":%d,\"map_first\":%d,"
           "\"diff\":%d,\"outcome\":\"%s\",\"work\":%llu,\"short_work\":%llu,\"index_work\":%llu,\"expected_class_units\":%llu,"
           "\"bound_v4\":%llu,\"bound_v3\":%llu,\"oracle_C\":%llu,\"independent_C\":%llu,\"branches\":%s,"
           "\"oracle_agrees\":%s,\"within_bound\":%s,\"limits\":%s,\"pass\":%s}\n",
           label, defect ? "defect" : "baseline", f->lines, f->name, f->dumps, f->dump_at, f->map_first, f->diff,
           xodb_jit_outcome_name(L.r.outcome), (unsigned long long)L.work, (unsigned long long)S.work,
           (unsigned long long)idx, (unsigned long long)el, (unsigned long long)bound, (unsigned long long)bound3, (unsigned long long)oc,
           (unsigned long long)C, branches ? "true" : "false", oracle_ok ? "true" : "false",
           within ? "true" : "false", lim ? "true" : "false", failures == fl ? "true" : "false");
    xodb_jit_model_free(&lm);
    xodb_jit_model_free(&sm);
}

int main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    /* The two acceptance fixtures: A07's 13 lines of 8,192 bytes, and 16
     * lines of a near-limit 65,500-byte name (line limit 65,536). */
    one("a07-13x8192", &(struct fx){13, 8192, 0, 0, 0, -1});
    one("near-limit-16x65500", &(struct fx){16, 65500, 0, 0, 0, -1});
    static const int lines[] = {1, 2, 13, 15, 16, 17};
    static const size_t names[] = {4095, 4096, 8192, 65500};
    static const int shapes[][3] = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {1, 1, 1}, {2, 0, 0}, {2, 1, 0}, {2, 1, 1}};
    for (size_t li = 0; li < sizeof lines / sizeof *lines; ++li)
        for (size_t ni = 0; ni < sizeof names / sizeof *names; ++ni)
            for (size_t si = 0; si < sizeof shapes / sizeof *shapes; ++si)
                for (int d = 0; d < 3; ++d) {
                    struct fx f = {lines[li], names[ni], shapes[si][0], shapes[si][1], shapes[si][2], -1};
                    if (d == 1)
                        f.diff = 0;
                    if (d == 2)
                        f.diff = f.lines - 1;
                    char label[96];
                    snprintf(label, sizeof label, "map%d-name%zu-dumps%d%s%s-%s", f.lines, f.name, f.dumps,
                             f.dump_at ? "-at" : "", f.map_first ? "-mapfirst" : "",
                             d == 0 ? "equal" : d == 1 ? "first-differs" : "last-differs");
                    one(label, &f);
                }
    free(oracle.candidates);
    printf("test-r4: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
