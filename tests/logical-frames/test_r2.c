/* C05-R2 regressions: exact counters at and beyond 2^64, recursion, empty
 * documents, allocation failure at every owned site, exact budget boundaries,
 * cancellation during decode/aggregate, cleanup and a following success.
 * Built with -DXLF_TESTING (allocation/cancel hooks). Expected values are
 * literal decimal strings computed independently of the reader's arithmetic. */
#define _GNU_SOURCE 1
#include "logical_frames.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void xlf_test_fail_alloc_at(uint64_t n);
void xlf_test_cancel_at_poll(uint64_t n);
uint64_t xlf_test_allocs(void);
size_t xlf_test_live_bytes(void);

static int failures, cases;
static void check(int ok, const char *fmt, ...)
{
    char what[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(what, sizeof what, fmt, ap);
    va_end(ap);
    cases++;
    if (!ok)
        failures++;
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
}
static const char *dec(struct xlf_count c)
{
    static char buf[8][40];
    static int i;
    i = (i + 1) % 8;
    xlf_count_format(c, buf[i]);
    return buf[i];
}

#define HEADER                                                                                      \
    "{\"type\":\"header\",\"format\":\"xodb.logical-frames\",\"version\":1,\"draft\":\"C05-1\","        \
    "\"producer\":{\"name\":\"t\",\"version\":\"1\",\"kind\":\"cooperating_in_process\",\"sha256\":null}," \
    "\"source_kind\":\"cooperative_sample\",\"runtime\":{\"language\":\"python\",\"implementation\":\"cpython\"," \
    "\"version\":\"3\",\"build\":null,\"executable\":{\"path\":null,\"sha256\":null,\"gnu_build_id\":null,"  \
    "\"unavailable\":\"test\"},\"library\":null},\"process\":{\"pid\":null,\"start_ticks\":null,\"boot_id\":null," \
    "\"unavailable\":\"test\"},\"clock\":null,\"clock_unavailable\":\"test\",\"command\":null,"           \
    "\"collection\":{\"method\":\"m\",\"trigger\":\"t\",\"interval_ns\":null,\"atomicity\":\"single_thread\"}," \
    "\"frame_order\":\"innermost_first\",\"weight_unit\":\"observation\",\"weight_semantics\":\"test\"}\n"
#define FNS                                                                                         \
    "{\"type\":\"function\",\"id\":\"f1\",\"name\":\"a\",\"qualified\":null,\"code\":null,\"first_line\":null," \
    "\"frame_kind\":\"logical\"}\n"                                                                    \
    "{\"type\":\"function\",\"id\":\"f2\",\"name\":\"b\",\"qualified\":null,\"code\":null,\"first_line\":null," \
    "\"frame_kind\":\"logical\"}\n"                                                                    \
    "{\"type\":\"thread\",\"id\":\"t1\",\"language_id\":null,\"name\":\"one\",\"os_tid\":null,\"os_tid_reason\":\"test\"}\n" \
    "{\"type\":\"thread\",\"id\":\"t2\",\"language_id\":null,\"name\":\"two\",\"os_tid\":null,\"os_tid_reason\":\"test\"}\n"

/* Build a document. Each stack spec: "WEIGHT STATE THREAD FRAMES" where FRAMES
 * is innermost-first letters: a=f1, b=f2, M=marker. Losses: "L COUNT". */
static char *build(const char *const *spec, size_t *size)
{
    size_t cap = 1 << 16, at = 0, records = 0, stacks = 0, acq = 0;
    char *s = malloc(cap);
    at += (size_t)snprintf(s + at, cap - at, "%s%s", HEADER, FNS);
    records = 5;
    for (size_t i = 0; spec[i]; ++i) {
        char w[32], state[16], thread[8], frames[64];
        if (spec[i][0] == 'L') {
            at += (size_t)snprintf(s + at, cap - at,
                                   "{\"type\":\"loss\",\"reason\":\"r\",\"count\":\"%s\",\"acquisition\":null}\n", spec[i] + 2);
            records++;
            continue;
        }
        frames[0] = 0;
        sscanf(spec[i], "%31s %15s %7s %63s", w, state, thread, frames);
        if (!strcmp(frames, "-"))
            frames[0] = 0;
        acq++, stacks++;
        at += (size_t)snprintf(s + at, cap - at, "{\"type\":\"acquisition\",\"seq\":%zu,\"start_ns\":null,\"end_ns\":null,\"stacks\":1}\n", acq);
        at += (size_t)snprintf(s + at, cap - at,
                               "{\"type\":\"stack\",\"id\":\"s%zu\",\"acquisition\":%zu,\"thread\":\"%s\",\"start_ns\":null,"
                               "\"end_ns\":null,\"trigger\":\"t\",\"weight\":\"%s\",\"state\":\"%s\",\"omitted\":null,"
                               "\"reason\":%s,\"frames\":[",
                               stacks, acq, thread, w, state, strcmp(state, "complete") ? "\"r\"" : "null");
        for (size_t j = 0; frames[j]; ++j) {
            if (frames[j] == 'M')
                at += (size_t)snprintf(s + at, cap - at, "%s{\"function\":null,\"kind\":\"unknown\",\"line\":null,"
                                       "\"provenance\":\"runtime\",\"label\":\"m\",\"reason\":\"r\"}", j ? "," : "");
            else
                at += (size_t)snprintf(s + at, cap - at, "%s{\"function\":\"f%d\",\"kind\":\"logical\",\"line\":1,"
                                       "\"provenance\":\"runtime\"}", j ? "," : "", frames[j] == 'a' ? 1 : 2);
        }
        at += (size_t)snprintf(s + at, cap - at, "]}\n");
        records += 2;
    }
    at += (size_t)snprintf(s + at, cap - at, "{\"type\":\"end\",\"records\":%zu,\"acquisitions\":%zu,\"stacks\":%zu,\"status\":\"complete\"}\n",
                           records, acq, stacks);
    *size = at;
    return s;
}

struct expect {
    const char *total, *partial, *marker, *unknown_leaf, *self1, *self2, *incl1, *incl2, *lost;
};
static void aggregate_case(const char *name, const char *const *spec, struct expect e)
{
    size_t n;
    char *text = build(spec, &n);
    struct xlf_error err;
    struct xlf_doc *d = xlf_decode(text, n, NULL, NULL, &err);
    check(d != NULL, "%s: decodes (%s %s)", name, d ? "ok" : xlf_status_name(err.status), d ? "" : err.message);
    if (d) {
        struct xlf_aggregate a;
        enum xlf_status st = xlf_aggregate(d, XLF_NONE, NULL, NULL, &a, &err);
        check(st == XLF_OK, "%s: aggregates", name);
        if (st == XLF_OK) {
            struct {
                const char *label, *want;
                struct xlf_count got;
            } rows[] = {{"total", e.total, a.total_weight},     {"partial", e.partial, a.partial_weight},
                        {"marker", e.marker, a.marker_weight},  {"unknown_leaf", e.unknown_leaf, a.unknown_leaf_weight},
                        {"self[f1]", e.self1, a.self[0]},       {"self[f2]", e.self2, a.self[1]},
                        {"inclusive[f1]", e.incl1, a.inclusive[0]}, {"inclusive[f2]", e.incl2, a.inclusive[1]},
                        {"lost", e.lost, d->lost},              {"doc total", e.total, d->total_weight}};
            for (size_t i = 0; i < sizeof rows / sizeof *rows; ++i)
                check(!strcmp(dec(rows[i].got), rows[i].want), "%s: %s = %s (want %s)", name, rows[i].label,
                      dec(rows[i].got), rows[i].want);
            xlf_aggregate_free(&a);
        }
        xlf_free(d);
    }
    free(text);
}

#define U63 "9223372036854775808"   /* 2^63 */
#define U63M "9223372036854775807"  /* 2^63 - 1 */
#define UMAX "18446744073709551615" /* 2^64 - 1 */
#define U64 "18446744073709551616"  /* 2^64 */

static void exact_counters(void)
{
    /* xlf_count primitives against literal values. */
    struct xlf_count c = {0, UINT64_MAX};
    uint64_t v;
    check(!strcmp(dec(c), UMAX) && xlf_count_to_u64(c, &v) && v == UINT64_MAX, "count UINT64_MAX fits u64");
    check(xlf_count_add(&c, 1) && !strcmp(dec(c), U64) && !xlf_count_to_u64(c, &v), "count 2^64: exact, u64 conversion refuses");
    struct xlf_count top = {UINT64_MAX, UINT64_MAX};
    check(!strcmp(dec(top), "340282366920938463463374607431768211455"), "count 2^128-1 formats exactly");
    check(!xlf_count_add(&top, 1) && top.hi == UINT64_MAX && top.lo == UINT64_MAX, "128-bit overflow refused, value unchanged");
    struct xlf_count z = {0, 0};
    check(!strcmp(dec(z), "0"), "count zero formats as 0");

    /* Each class at UINT64_MAX, then one beyond. Other classes stay independent. */
    aggregate_case("total at max", (const char *const[]){U63 " complete t1 a", U63M " complete t1 a", NULL},
                   (struct expect){UMAX, "0", "0", "0", UMAX, "0", UMAX, "0", "0"});
    aggregate_case("total beyond", (const char *const[]){U63 " complete t1 a", U63 " complete t2 b", NULL},
                   (struct expect){U64, "0", "0", "0", U63, U63, U63, U63, "0"});
    aggregate_case("self[f1] at max, total beyond",
                   (const char *const[]){U63 " complete t1 ab", U63M " complete t1 a", "5 complete t1 b", NULL},
                   (struct expect){"18446744073709551620", "0", "0", "0", UMAX, "5", UMAX, "9223372036854775813", "0"});
    aggregate_case("self[f1] beyond", (const char *const[]){U63 " complete t1 a", U63 " complete t2 a", NULL},
                   (struct expect){U64, "0", "0", "0", U64, "0", U64, "0", "0"});
    aggregate_case("inclusive[f2] at max with self 0",
                   (const char *const[]){U63 " complete t1 ab", U63M " complete t2 ab", NULL},
                   (struct expect){UMAX, "0", "0", "0", UMAX, "0", UMAX, UMAX, "0"});
    aggregate_case("inclusive[f2] beyond", (const char *const[]){U63 " complete t1 ab", U63 " complete t2 ab", "1 complete t1 a", NULL},
                   (struct expect){"18446744073709551617", "0", "0", "0", "18446744073709551617", "0",
                                   "18446744073709551617", U64, "0"});
    aggregate_case("partial at max", (const char *const[]){U63 " partial t1 a", U63M " truncated t1 a", "3 complete t1 a", NULL},
                   (struct expect){"18446744073709551618", UMAX, "0", "0", "18446744073709551618", "0",
                                   "18446744073709551618", "0", "0"});
    aggregate_case("partial beyond", (const char *const[]){U63 " partial t1 a", U63 " truncated t1 -", NULL},
                   (struct expect){U64, U64, "0", U63, U63, "0", U63, "0", "0"});
    aggregate_case("marker at max (not leaf)", (const char *const[]){U63 " complete t1 aM", U63M " complete t1 aMbM", "2 complete t1 a", NULL},
                   (struct expect){"18446744073709551617", "0", UMAX, "0", "18446744073709551617", "0",
                                   "18446744073709551617", U63M, "0"});
    aggregate_case("marker beyond", (const char *const[]){U63 " complete t1 aM", U63 " complete t2 bM", NULL},
                   (struct expect){U64, "0", U64, "0", U63, U63, U63, U63, "0"});
    aggregate_case("unknown leaf at max", (const char *const[]){U63 " complete t1 Ma", U63M " partial t1 -", "4 complete t1 b", NULL},
                   (struct expect){"18446744073709551619", U63M, U63, UMAX, "0", "4", U63, "4", "0"});
    aggregate_case("unknown leaf beyond", (const char *const[]){U63 " complete t1 Mb", U63 " complete t2 MMa", NULL},
                   (struct expect){U64, "0", U64, U64, "0", "0", U63, U63, "0"});
    aggregate_case("lost at max", (const char *const[]){"L " U63, "L " U63M, "1 complete t1 a", NULL},
                   (struct expect){"1", "0", "0", "0", "1", "0", "1", "0", UMAX});
    aggregate_case("lost beyond", (const char *const[]){"L " UMAX, "L 1", "1 complete t1 a", NULL},
                   (struct expect){"1", "0", "0", "0", "1", "0", "1", "0", U64});
    /* Recursion: a function counts once per stack in inclusive, even when it
     * recurs; marker frames count once per stack. */
    aggregate_case("recursion dedup at 2^64",
                   (const char *const[]){U63 " complete t1 aaaMaab", U63 " complete t2 aMMab", NULL},
                   (struct expect){U64, "0", U64, "0", U64, "0", U64, U64, "0"});
    aggregate_case("max weight single stack", (const char *const[]){UMAX " complete t1 ba", NULL},
                   (struct expect){UMAX, "0", "0", "0", "0", UMAX, UMAX, UMAX, "0"});
    aggregate_case("empty: no stacks", (const char *const[]){NULL},
                   (struct expect){"0", "0", "0", "0", "0", "0", "0", "0", "0"});
}

static void empty_and_thread(void)
{
    const char *text = HEADER "{\"type\":\"end\",\"records\":1,\"acquisitions\":0,\"stacks\":0,\"status\":\"complete\"}\n";
    struct xlf_error err;
    struct xlf_doc *d = xlf_decode(text, strlen(text), NULL, NULL, &err);
    check(d && !d->function_count && !d->stack_count, "header+end only decodes with zero entities");
    if (d) {
        struct xlf_aggregate a;
        check(xlf_aggregate(d, XLF_NONE, NULL, NULL, &a, &err) == XLF_OK && !a.self && !a.inclusive && !a.stacks &&
                  !a.total_weight.lo && !a.total_weight.hi && !a.input_incomplete,
              "aggregate over zero functions: NULL arrays, zero counters");
        xlf_aggregate_free(&a);
        check(xlf_aggregate(d, 0, NULL, NULL, &a, &err) == XLF_E_ARGUMENT && !a.self, "thread index out of range: invalid_argument, zeroed result");
        xlf_aggregate_free(&a); /* no-op on a zeroed result */
        xlf_free(d);
    }
    d = xlf_decode("", 0, NULL, NULL, &err);
    check(!d && err.status == XLF_E_EMPTY, "zero-byte input: empty");
    d = xlf_decode(NULL, 5, NULL, NULL, &err);
    check(!d && err.status == XLF_E_ARGUMENT, "NULL input with size: invalid_argument");
    /* Incomplete input marks the aggregate as such. */
    const char *open = HEADER FNS "{\"type\":\"acquisition\",\"seq\":1,\"start_ns\":null,\"end_ns\":null,\"stacks\":2}\n"
                                  "{\"type\":\"stack\",\"id\":\"s1\",\"acquisition\":1,\"thread\":\"t1\",\"start_ns\":null,"
                                  "\"end_ns\":null,\"trigger\":\"t\",\"weight\":\"7\",\"state\":\"complete\",\"omitted\":null,"
                                  "\"reason\":null,\"frames\":[{\"function\":\"f1\",\"kind\":\"logical\",\"line\":1,"
                                  "\"provenance\":\"runtime\"}]}\n";
    d = xlf_decode(open, strlen(open), NULL, NULL, &err);
    check(d && (d->warnings & XLF_W_NO_END) && (d->warnings & XLF_W_ACQ_INCOMPLETE), "missing end: decoded with incomplete warnings");
    if (d) {
        struct xlf_aggregate a;
        check(xlf_aggregate(d, 0, NULL, NULL, &a, &err) == XLF_OK && a.input_incomplete && !strcmp(dec(a.total_weight), "7"),
              "aggregate of incomplete input carries input_incomplete");
        xlf_aggregate_free(&a);
        check(xlf_aggregate(d, 1, NULL, NULL, &a, &err) == XLF_OK && a.stacks == 0 && !strcmp(dec(a.total_weight), "0"),
              "per-thread aggregate selects only that thread");
        xlf_aggregate_free(&a);
        xlf_free(d);
    }
}

/* A document with enough records to make every array, map and arena grow. */
static char *rich(size_t *size)
{
    static const char *const spec[] = {
        "1 complete t1 ab", "2 partial t2 aMb", "3 complete t1 Mab", "4 truncated t2 -", "5 complete t1 aaab",
        "L 9", "6 complete t2 ba", NULL};
    return build(spec, size);
}

static void allocation_failures(void)
{
    size_t n;
    char *text = rich(&n);
    struct xlf_error err;
    /* Count allocations of a successful decode + aggregate. */
    xlf_test_fail_alloc_at(0);
    struct xlf_doc *d = xlf_decode(text, n, NULL, NULL, &err);
    uint64_t decode_allocs = xlf_test_allocs();
    check(d != NULL && decode_allocs > 5, "baseline decode: %llu owned allocations", (unsigned long long)decode_allocs);
    xlf_test_fail_alloc_at(0);
    struct xlf_aggregate a;
    xlf_aggregate(d, XLF_NONE, NULL, NULL, &a, &err);
    uint64_t agg_allocs = xlf_test_allocs();
    check(agg_allocs == 2, "baseline aggregate: 2 owned allocations (result, scratch)");
    xlf_aggregate_free(&a);
    xlf_free(d);
    check(xlf_test_live_bytes() == 0, "baseline: all bytes released");
    int bad = 0;
    for (uint64_t k = 1; k <= decode_allocs; ++k) {
        xlf_test_fail_alloc_at(k);
        d = xlf_decode(text, n, NULL, NULL, &err);
        if (d || err.status != XLF_E_MEMORY || xlf_test_live_bytes() != 0) {
            bad++;
            printf("     decode alloc site %llu: %s live=%zu\n", (unsigned long long)k,
                   d ? "succeeded" : xlf_status_name(err.status), xlf_test_live_bytes());
            xlf_free(d);
        }
    }
    check(!bad, "decode: failure injected at each of %llu allocation sites -> memory_limit, zero live bytes",
          (unsigned long long)decode_allocs);
    /* decode_file adds the input copy as one more site. */
    char path[] = "/tmp/xlf-r2-XXXXXX";
    const char *tmpdir = getenv("XLF_TEST_TMPDIR");
    char pbuf[4096];
    snprintf(pbuf, sizeof pbuf, "%s/xlf-r2-XXXXXX", tmpdir ? tmpdir : "/tmp");
    int fd = mkstemp(tmpdir ? pbuf : path);
    const char *file = tmpdir ? pbuf : path;
    check(fd >= 0 && write(fd, text, n) == (ssize_t)n, "temporary input written");
    close(fd);
    xlf_test_fail_alloc_at(0);
    d = xlf_decode_file(file, NULL, NULL, &err);
    uint64_t file_allocs = xlf_test_allocs();
    check(d && d->input_charged && file_allocs == decode_allocs + 1 && d->decode_peak_bytes >= n + d->retained_bytes - 0,
          "decode_file: input copy charged (%llu allocations, peak %zu >= input %zu)", (unsigned long long)file_allocs,
          d ? d->decode_peak_bytes : 0, n);
    xlf_free(d);
    bad = 0;
    for (uint64_t k = 1; k <= file_allocs; ++k) {
        xlf_test_fail_alloc_at(k);
        d = xlf_decode_file(file, NULL, NULL, &err);
        if (d || err.status != XLF_E_MEMORY || xlf_test_live_bytes() != 0)
            bad++, xlf_free(d);
    }
    check(!bad, "decode_file: failure at each of %llu sites -> memory_limit, zero live bytes", (unsigned long long)file_allocs);
    xlf_test_fail_alloc_at(0);
    d = xlf_decode(text, n, NULL, NULL, &err);
    for (uint64_t k = 1; k <= agg_allocs; ++k) {
        xlf_test_fail_alloc_at(k);
        size_t before = xlf_test_live_bytes();
        enum xlf_status st = xlf_aggregate(d, XLF_NONE, NULL, NULL, &a, &err);
        check(st == XLF_E_MEMORY && !a.self && xlf_test_live_bytes() == before,
              "aggregate: failure at site %llu -> memory_limit, result zeroed, query bytes released", (unsigned long long)k);
    }
    xlf_test_fail_alloc_at(0);
    check(xlf_aggregate(d, XLF_NONE, NULL, NULL, &a, &err) == XLF_OK && !strcmp(dec(a.total_weight), "21"),
          "aggregate succeeds on the same document after failures (total 21)");
    xlf_aggregate_free(&a);
    xlf_free(d);
    check(xlf_test_live_bytes() == 0, "all bytes released after allocation-failure runs");
    unlink(file);
    free(text);
}

static void budget_boundaries(void)
{
    size_t n;
    char *text = rich(&n);
    struct xlf_error err;
    struct xlf_limits l;
    xlf_default_limits(&l);
    struct xlf_doc *d = xlf_decode(text, n, &l, NULL, &err);
    size_t peak = d->decode_peak_bytes, retained = d->retained_bytes;
    check(retained > 0 && peak > retained, "decode reports peak %zu > retained %zu (transient parse storage)", peak, retained);
    xlf_free(d);
    l.max_memory = peak;
    d = xlf_decode(text, n, &l, NULL, &err);
    check(d && d->decode_peak_bytes == peak, "decode with max_memory == measured peak (%zu) succeeds", peak);
    xlf_free(d);
    l.max_memory = peak - 1;
    d = xlf_decode(text, n, &l, NULL, &err);
    check(!d && err.status == XLF_E_MEMORY && err.peak_bytes <= peak - 1 && xlf_test_live_bytes() == 0,
          "decode with max_memory == peak-1 -> memory_limit (peak %zu), nothing retained", err.peak_bytes);
    xlf_default_limits(&l);
    d = xlf_decode(text, n, &l, NULL, &err);
    struct xlf_aggregate a;
    struct xlf_query_limits q;
    xlf_default_query_limits(&q);
    xlf_aggregate(d, XLF_NONE, &q, NULL, &a, &err);
    size_t qpeak = a.query_peak_bytes, comb = a.combined_peak_bytes, res = a.result_bytes;
    check(qpeak > res && res == 2 * d->function_count * sizeof(struct xlf_count) && comb == retained + qpeak,
          "aggregate reports result %zu, query peak %zu, combined %zu = retained + query peak", res, qpeak, comb);
    xlf_aggregate_free(&a);
    q.max_query_bytes = qpeak;
    check(xlf_aggregate(d, XLF_NONE, &q, NULL, &a, &err) == XLF_OK, "aggregate with max_query_bytes == peak succeeds");
    xlf_aggregate_free(&a);
    q.max_query_bytes = qpeak - 1;
    check(xlf_aggregate(d, XLF_NONE, &q, NULL, &a, &err) == XLF_E_MEMORY && !a.self, "aggregate with max_query_bytes == peak-1 -> memory_limit");
    xlf_default_query_limits(&q);
    q.max_combined_bytes = comb;
    check(xlf_aggregate(d, XLF_NONE, &q, NULL, &a, &err) == XLF_OK, "aggregate with max_combined_bytes == combined peak succeeds");
    xlf_aggregate_free(&a);
    q.max_combined_bytes = comb - 1;
    check(xlf_aggregate(d, XLF_NONE, &q, NULL, &a, &err) == XLF_E_MEMORY && !a.self,
          "aggregate with max_combined_bytes == combined-1 -> memory_limit");
    q.max_combined_bytes = retained - 1;
    check(xlf_aggregate(d, XLF_NONE, &q, NULL, &a, &err) == XLF_E_MEMORY, "combined limit below retained document -> memory_limit");
    xlf_free(d);
    check(xlf_test_live_bytes() == 0, "budget runs released everything");
    free(text);
}

static void cancellation(void)
{
    size_t n;
    char *text = rich(&n);
    struct xlf_error err;
    struct xlf_cancel *c = xlf_cancel_create();
    xlf_cancel_request(c);
    struct xlf_doc *d = xlf_decode(text, n, NULL, c, &err);
    check(!d && err.status == XLF_E_CANCELLED && xlf_test_live_bytes() == 0, "pre-requested cancel: decode cancelled, nothing live");
    xlf_cancel_reset(c);
    d = xlf_decode(text, n, NULL, c, &err);
    check(d != NULL, "after reset: decode succeeds");
    xlf_cancel_request(c);
    struct xlf_aggregate a;
    check(xlf_aggregate(d, XLF_NONE, NULL, c, &a, &err) == XLF_E_CANCELLED && !a.self, "pre-requested cancel: aggregate cancelled, zeroed");
    xlf_cancel_reset(c);
    xlf_free(d);
    /* Cancellation observed at every poll point of decode, then of aggregate. */
    int bad = 0;
    uint64_t k = 1;
    for (;; ++k) {
        xlf_test_cancel_at_poll(k);
        d = xlf_decode(text, n, NULL, NULL, &err);
        if (d)
            break;
        if (err.status != XLF_E_CANCELLED || xlf_test_live_bytes() != 0)
            bad++;
    }
    xlf_test_cancel_at_poll(0);
    check(!bad && k > 2, "decode: cancelled at each of %llu poll points, nothing live; next run succeeds", (unsigned long long)(k - 1));
    size_t live = xlf_test_live_bytes();
    bad = 0;
    for (k = 1;; ++k) {
        xlf_test_cancel_at_poll(k);
        enum xlf_status st = xlf_aggregate(d, XLF_NONE, NULL, NULL, &a, &err);
        if (st == XLF_OK)
            break;
        if (st != XLF_E_CANCELLED || a.self || xlf_test_live_bytes() != live)
            bad++;
    }
    xlf_test_cancel_at_poll(0);
    check(!bad && k == d->stack_count + 1, "aggregate: cancelled at each of %llu stacks, released; then succeeds",
          (unsigned long long)(k - 1));
    check(!strcmp(dec(a.total_weight), "21"), "aggregate after cancellations is exact (21)");
    xlf_aggregate_free(&a);
    xlf_free(d);
    xlf_cancel_destroy(c);
    check(xlf_test_live_bytes() == 0, "cancellation runs released everything");
    free(text);
}

static void retained_fixture(const char *path)
{
    struct xlf_error err;
    struct xlf_doc *d = xlf_decode_file(path, NULL, NULL, &err);
    check(d && !strcmp(d->sha256_hex, "cf2e2cf4bc3bf870a3379621be03c4fa504582411492eabf6d148163bc4bb49c") && d->stack_count == 76,
          "retained overflow fixture decodes (76 stacks, sha256 c259a719...)");
    if (!d)
        return;
    struct xlf_aggregate a;
    check(xlf_aggregate(d, XLF_NONE, NULL, NULL, &a, &err) == XLF_OK, "fixture aggregates");
    uint64_t v;
    check(!strcmp(dec(a.total_weight), "18446744073709551690"), "fixture total is exactly 18446744073709551690 (got %s)",
          dec(a.total_weight));
    check(strcmp(dec(a.total_weight), "74") && !xlf_count_to_u64(a.total_weight, &v),
          "fixture total never appears as 74; narrowing to u64 is an explicit overflow");
    struct xlf_count sum = {0, 0};
    for (size_t t = 0; t < d->thread_count; ++t) {
        struct xlf_aggregate p;
        xlf_aggregate(d, (uint32_t)t, NULL, NULL, &p, &err);
        xlf_count_add(&sum, p.total_weight.lo);
        if (p.total_weight.hi)
            sum.hi += p.total_weight.hi;
        xlf_aggregate_free(&p);
    }
    check(!xlf_count_cmp(sum, a.total_weight), "fixture: per-thread totals sum to the document total");
    xlf_aggregate_free(&a);
    xlf_free(d);
    /* Every allocation site of a larger decode (array growth, map rehash,
     * several arena chunks) and of its aggregate. */
    xlf_test_fail_alloc_at(0);
    d = xlf_decode_file(path, NULL, NULL, &err);
    uint64_t sites = xlf_test_allocs();
    xlf_free(d);
    int bad = 0;
    for (uint64_t k = 1; k <= sites; ++k) {
        xlf_test_fail_alloc_at(k);
        d = xlf_decode_file(path, NULL, NULL, &err);
        if (d || err.status != XLF_E_MEMORY || xlf_test_live_bytes() != 0)
            bad++, xlf_free(d);
    }
    xlf_test_fail_alloc_at(0);
    check(!bad && sites > 30, "fixture decode_file: failure at each of %llu sites -> memory_limit, zero live bytes",
          (unsigned long long)sites);
    d = xlf_decode_file(path, NULL, NULL, &err);
    check(d && xlf_aggregate(d, XLF_NONE, NULL, NULL, &a, &err) == XLF_OK &&
              !strcmp(dec(a.total_weight), "18446744073709551690"),
          "fixture decode + aggregate succeed after the failure runs");
    xlf_aggregate_free(&a);
    xlf_free(d);
    check(xlf_test_live_bytes() == 0, "fixture runs released everything");
}

int main(int argc, char **argv)
{
    exact_counters();
    empty_and_thread();
    allocation_failures();
    budget_boundaries();
    cancellation();
    if (argc > 1)
        retained_fixture(argv[1]);
    else
        check(0, "retained fixture path argument missing");
    printf("%d cases, %d failures\n", cases, failures);
    return failures != 0;
}
