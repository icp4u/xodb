/* C05-R2 cross-thread checks (no test hooks; run under ThreadSanitizer):
 * cancellation requested by another thread during decode and aggregate,
 * concurrent aggregates over one immutable document, and a following success. */
#define _GNU_SOURCE 1
#include "logical_frames.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures, cases;
static void check(int ok, const char *what)
{
    cases++;
    failures += !ok;
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
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

/* stacks stacks of depth 8 over 64 functions, weight 2^63 each. */
static char *big(size_t stacks, size_t *size)
{
    size_t cap = 4096 + 64 * 160 + stacks * 900, at = 0;
    char *s = malloc(cap);
    at += (size_t)snprintf(s + at, cap - at, "%s", HEADER);
    for (int f = 0; f < 64; ++f)
        at += (size_t)snprintf(s + at, cap - at,
                               "{\"type\":\"function\",\"id\":\"f%d\",\"name\":\"n%d\",\"qualified\":null,\"code\":null,"
                               "\"first_line\":null,\"frame_kind\":\"logical\"}\n", f, f);
    at += (size_t)snprintf(s + at, cap - at, "{\"type\":\"thread\",\"id\":\"t\",\"language_id\":null,\"name\":null,"
                                             "\"os_tid\":null,\"os_tid_reason\":\"test\"}\n");
    at += (size_t)snprintf(s + at, cap - at, "{\"type\":\"acquisition\",\"seq\":1,\"start_ns\":null,\"end_ns\":null,\"stacks\":%zu}\n", stacks);
    for (size_t i = 0; i < stacks; ++i) {
        at += (size_t)snprintf(s + at, cap - at, "{\"type\":\"stack\",\"id\":\"s%zu\",\"acquisition\":1,\"thread\":\"t\","
                                                 "\"start_ns\":null,\"end_ns\":null,\"trigger\":\"t\",\"weight\":\"9223372036854775808\","
                                                 "\"state\":\"complete\",\"omitted\":null,\"reason\":null,\"frames\":[", i);
        for (int j = 0; j < 8; ++j)
            at += (size_t)snprintf(s + at, cap - at, "%s{\"function\":\"f%zu\",\"kind\":\"logical\",\"line\":1,\"provenance\":\"runtime\"}",
                                   j ? "," : "", (i * 7 + (size_t)j * 3) % 64);
        at += (size_t)snprintf(s + at, cap - at, "]}\n");
    }
    at += (size_t)snprintf(s + at, cap - at, "{\"type\":\"end\",\"records\":%zu,\"acquisitions\":1,\"stacks\":%zu,\"status\":\"complete\"}\n",
                           stacks + 67, stacks);
    *size = at;
    return s;
}

struct job {
    const char *text;
    size_t size;
    const struct xlf_doc *doc;
    struct xlf_cancel *cancel;
    atomic_int started;
    enum xlf_status status;
    struct xlf_doc *out;
    struct xlf_aggregate agg;
};
static void *decode_job(void *p)
{
    struct job *j = p;
    struct xlf_error err;
    atomic_store(&j->started, 1);
    j->out = xlf_decode(j->text, j->size, NULL, j->cancel, &err);
    j->status = j->out ? XLF_OK : err.status;
    return NULL;
}
static void *aggregate_job(void *p)
{
    struct job *j = p;
    struct xlf_error err;
    atomic_store(&j->started, 1);
    j->status = xlf_aggregate(j->doc, XLF_NONE, NULL, j->cancel, &j->agg, &err);
    return NULL;
}

int main(void)
{
    size_t size;
    char *text = big(200000, &size);
    struct xlf_cancel *c = xlf_cancel_create();
    /* 1. Cancel from another thread while decode runs. */
    struct job j = {.text = text, .size = size, .cancel = c};
    pthread_t t;
    pthread_create(&t, NULL, decode_job, &j);
    while (!atomic_load(&j.started))
        ;
    xlf_cancel_request(c);
    pthread_join(t, NULL);
    check(j.status == XLF_E_CANCELLED && !j.out, "decode cancelled by another thread; no document");
    xlf_free(j.out);
    xlf_cancel_reset(c);
    struct xlf_error err;
    struct xlf_doc *d = xlf_decode(text, size, NULL, c, &err);
    check(d && d->stack_count == 200000, "decode after reset succeeds (200000 stacks)");
    /* 2. Concurrent aggregates over one immutable document agree exactly. */
    struct job js[4];
    pthread_t ts[4];
    for (int i = 0; i < 4; ++i) {
        js[i] = (struct job){.doc = d};
        pthread_create(&ts[i], NULL, aggregate_job, &js[i]);
    }
    int agree = 1;
    for (int i = 0; i < 4; ++i) {
        pthread_join(ts[i], NULL);
        agree &= js[i].status == XLF_OK && !xlf_count_cmp(js[i].agg.total_weight, js[0].agg.total_weight);
        for (size_t f = 0; agree && f < d->function_count; ++f)
            agree &= !xlf_count_cmp(js[i].agg.inclusive[f], js[0].agg.inclusive[f]) &&
                     !xlf_count_cmp(js[i].agg.self[f], js[0].agg.self[f]);
    }
    char total[40];
    xlf_count_format(js[0].agg.total_weight, total);
    check(agree && !strcmp(total, "1844674407370955161600000"), "4 concurrent aggregates agree; total 200000*2^63 exact");
    for (int i = 0; i < 4; ++i)
        xlf_aggregate_free(&js[i].agg);
    /* 3. Cancel from another thread while aggregate runs. */
    struct job a = {.doc = d, .cancel = c};
    pthread_create(&t, NULL, aggregate_job, &a);
    while (!atomic_load(&a.started))
        ;
    xlf_cancel_request(c);
    pthread_join(t, NULL);
    check((a.status == XLF_E_CANCELLED && !a.agg.self) || a.status == XLF_OK,
          "aggregate with concurrent cancel: cancelled with zeroed result, or completed before the request");
    printf("     aggregate outcome: %s\n", xlf_status_name(a.status));
    xlf_aggregate_free(&a.agg);
    xlf_cancel_reset(c);
    struct xlf_aggregate r;
    check(xlf_aggregate(d, XLF_NONE, NULL, c, &r, &err) == XLF_OK && !xlf_count_cmp(r.total_weight, d->total_weight),
          "aggregate after reset succeeds and equals the document total");
    xlf_aggregate_free(&r);
    xlf_free(d);
    xlf_cancel_destroy(c);
    free(text);
    printf("%d cases, %d failures\n", cases, failures);
    return failures != 0;
}
