/* C05-R3 reader regressions. Each case reproduces a defect of the R2 reader
 * and fails on it:
 *  - admission: a document whose retained bytes already exceed the combined
 *    budget is refused even when the query allocates nothing (empty and
 *    marker-only documents), with exact boundary and one byte below.
 * Built with -DXLF_TESTING for the live-byte hook. Expected byte counts are taken
 * from the decoded document, never from the code under test's own arithmetic. */
#define _GNU_SOURCE 1
#include "logical_frames.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    fflush(stdout);
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
#define THREAD "{\"type\":\"thread\",\"id\":\"t1\",\"language_id\":null,\"name\":\"one\",\"os_tid\":null,\"os_tid_reason\":\"test\"}\n"
#define MARKER                                                                                       \
    "{\"function\":null,\"kind\":\"unknown\",\"line\":null,\"provenance\":\"runtime\",\"label\":\"m\",\"reason\":\"r\"}"
#define STACK(n, w)                                                                                 \
    "{\"type\":\"acquisition\",\"seq\":" #n ",\"start_ns\":null,\"end_ns\":null,\"stacks\":1}\n"            \
    "{\"type\":\"stack\",\"id\":\"s" #n "\",\"acquisition\":" #n ",\"thread\":\"t1\",\"start_ns\":null,"    \
    "\"end_ns\":null,\"trigger\":\"t\",\"weight\":\"" #w "\",\"state\":\"complete\",\"omitted\":null,"       \
    "\"reason\":null,\"frames\":[" MARKER "," MARKER "]}\n"

static const struct {
    const char *name, *text, *total, *marker;
} docs[] = {
    {"empty (header+end)", HEADER "{\"type\":\"end\",\"records\":1,\"acquisitions\":0,\"stacks\":0,\"status\":\"complete\"}\n",
     "0", "0"},
    {"header only (no end)", HEADER, "0", "0"},
    {"marker-only stacks, zero functions",
     HEADER THREAD STACK(1, 18446744073709551615) STACK(2, 3)
         "{\"type\":\"end\",\"records\":6,\"acquisitions\":2,\"stacks\":2,\"status\":\"complete\"}\n",
     "18446744073709551618", "18446744073709551618"},
};

static void admission(void)
{
    for (size_t i = 0; i < sizeof docs / sizeof *docs; ++i) {
        struct xlf_error err;
        struct xlf_doc *d = xlf_decode(docs[i].text, strlen(docs[i].text), NULL, NULL, &err);
        check(d && d->function_count == 0 && d->retained_bytes > 0, "%s: decodes with zero functions (%s)",
              docs[i].name, d ? "ok" : err.message);
        if (!d)
            continue;
        size_t retained = d->retained_bytes, live = xlf_test_live_bytes();
        struct xlf_query_limits q;
        xlf_default_query_limits(&q);
        struct xlf_aggregate a;
        char buf[40];

        q.max_combined_bytes = retained; /* exact boundary: the document fits, the query needs nothing */
        enum xlf_status st = xlf_aggregate(d, XLF_NONE, &q, NULL, &a, &err);
        xlf_count_format(a.total_weight, buf);
        check(st == XLF_OK && a.combined_peak_bytes == retained && a.query_peak_bytes == 0 && !strcmp(buf, docs[i].total),
              "%s: combined limit == retained (%zu) -> ok, combined peak %zu, total %s", docs[i].name, retained,
              a.combined_peak_bytes, buf);
        xlf_count_format(a.marker_weight, buf);
        check(st == XLF_OK && !strcmp(buf, docs[i].marker), "%s: marker weight %s exact", docs[i].name, buf);
        xlf_aggregate_free(&a);

        q.max_combined_bytes = retained - 1; /* one byte below */
        st = xlf_aggregate(d, XLF_NONE, &q, NULL, &a, &err);
        check(st == XLF_E_MEMORY && !a.self && !a.stacks && !a.total_weight.lo && !a.combined_peak_bytes &&
                  xlf_test_live_bytes() == live,
              "%s: combined limit == retained-1 (%zu) -> memory_limit (got %s), result zeroed, nothing allocated",
              docs[i].name, retained - 1, xlf_status_name(st));
        q.max_combined_bytes = 1;
        st = xlf_aggregate(d, XLF_NONE, &q, NULL, &a, &err);
        check(st == XLF_E_MEMORY, "%s: combined limit 1 -> memory_limit (got %s)", docs[i].name, xlf_status_name(st));
        /* A per-thread query is admitted the same way. */
        if (d->thread_count) {
            q.max_combined_bytes = retained - 1;
            st = xlf_aggregate(d, 0, &q, NULL, &a, &err);
            check(st == XLF_E_MEMORY, "%s: per-thread query below retained -> memory_limit", docs[i].name);
        }
        /* The refusal leaves the document usable. */
        xlf_default_query_limits(&q);
        st = xlf_aggregate(d, XLF_NONE, &q, NULL, &a, &err);
        check(st == XLF_OK, "%s: default limits after refusal -> ok", docs[i].name);
        xlf_aggregate_free(&a);
        xlf_free(d);
    }
    check(xlf_test_live_bytes() == 0, "admission runs released everything");
}

int main(void)
{
    admission();
    printf("%d cases, %d failures\n", cases, failures);
    return failures != 0;
}
