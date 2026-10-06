// C07-R4 / C05-R4 compatibility fixture (test-only; replaces C07-R3's
// tests/jitmap-r3/compat; needs the C05-R4 reader src/profile/logical_frames.{c,h},
// contract XLF_CONTRACT). Reads one closed C05-1 logical-frame document with that
// reader (xlf_decode_file: read lease, refuses a file open for writing; the
// document's input_stability is reported) and one jitdump with the C07-R4
// resolver, and prints them side by side. It embeds no logical-frame
// model and invents no bridge: physical JIT attribution and logical frames
// stay separate, the clocks are compared only by declared name, and logical
// weights are counts.
//
// usage: c05-compat DOC JITDUMP JITDUMP_SHA256 PID START_TICKS BOOT_ID SCOPE_HEX32
//                   COVERAGE_END THREAD FUNCTION JIT_NAME
#define _GNU_SOURCE
#include "jitmap.h"
#include "logical_frames.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(cond)                                                       \
    do {                                                                  \
        if (!(cond)) {                                                    \
            failures++;                                                   \
            fprintf(stderr, "c05-compat: CHECK failed: %s\n", #cond);     \
        }                                                                 \
    } while (0)

static void hex(const char *text, uint8_t *out, size_t n)
{
    size_t k = 0;
    memset(out, 0, n);
    for (const char *p = text; *p && k < 2 * n; ++p) {
        int d;
        if (*p >= '0' && *p <= '9')
            d = *p - '0';
        else if (*p >= 'a' && *p <= 'f')
            d = *p - 'a' + 10;
        else if (*p >= 'A' && *p <= 'F')
            d = *p - 'A' + 10;
        else
            continue;
        out[k / 2] = (uint8_t)(out[k / 2] << 4 | d);
        k++;
    }
}

static void json_str(const char *s, size_t n)
{
    putchar('"');
    for (size_t i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\')
            printf("\\%c", c);
        else if (c < 0x20)
            printf("\\u%04x", c);
        else
            putchar(c);
    }
    putchar('"');
}

static void json_xs(struct xlf_str s)
{
    if (s.ptr)
        json_str(s.ptr, s.len);
    else
        printf("null");
}

static uint8_t *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return NULL;
    size_t cap = 1 << 20, n = 0;
    uint8_t *b = malloc(cap);
    while (b) {
        n += fread(b + n, 1, cap - n, f);
        if (n < cap)
            break;
        uint8_t *g = realloc(b, cap *= 2);
        if (!g)
            free(b);
        b = g;
    }
    fclose(f);
    *len = n;
    return b;
}

int main(int argc, char **argv)
{
    if (argc != 12) {
        fprintf(stderr, "usage: c05-compat DOC JITDUMP JITDUMP_SHA256 PID START_TICKS BOOT_ID SCOPE COVERAGE_END "
                        "THREAD FUNCTION JIT_NAME\n");
        return 2;
    }
    const char *doc_path = argv[1], *dump_path = argv[2], *dump_sha = argv[3], *thread_name = argv[9],
               *function_name = argv[10], *jit_name = argv[11];

    /* Logical frames: C05-R4 reader, exact counters. */
    struct xlf_limits limits;
    xlf_default_limits(&limits);
    struct xlf_error err;
    struct xlf_doc *doc = xlf_decode_file(doc_path, &limits, NULL, &err);
    if (!doc) {
        printf("{\"status\":\"error\",\"phase\":\"c05_decode\",\"error\":\"%s\"}\n", xlf_status_name(err.status));
        fprintf(stderr, "c05-compat: decode: %s\n", err.message);
        return 1;
    }
    uint32_t thread = xlf_find_thread(doc, thread_name);
    CHECK(thread != XLF_NONE && thread != XLF_AMBIGUOUS);
    struct xlf_query_limits qlimits;
    xlf_default_query_limits(&qlimits);
    struct xlf_aggregate agg;
    enum xlf_status st = xlf_aggregate(doc, thread, &qlimits, NULL, &agg, &err);
    CHECK(st == XLF_OK);
    uint32_t fn = XLF_NONE;
    for (size_t i = 0; i < doc->function_count; ++i)
        if (doc->functions[i].name.ptr && !strcmp(doc->functions[i].name.ptr, function_name))
            fn = (uint32_t)i;
    CHECK(fn != XLF_NONE);

    /* Physical JIT attribution: C07-R4 resolver over the jitdump. */
    size_t len = 0;
    uint8_t *bytes = slurp(dump_path, &len);
    CHECK(bytes != NULL);
    struct xodb_jit_source_meta meta;
    memset(&meta, 0, sizeof meta);
    meta.process.pid = (uint32_t)strtoul(argv[4], NULL, 10);
    meta.process.known = 1;
    meta.process.start_ticks = strtoull(argv[5], NULL, 10);
    hex(argv[6], meta.process.boot_id, 16);
    meta.clock.kind = XODB_JIT_CLOCK_MONOTONIC;
    meta.clock.scope_known = 1;
    hex(argv[7], meta.clock.scope, 16);
    meta.has_coverage_end = 1;
    meta.coverage_end = strtoull(argv[8], NULL, 10);
    meta.artifact_sha256 = dump_sha;
    meta.label = "c05-compat jitdump";
    struct xodb_jit_model model;
    xodb_jit_model_init(&model, NULL);
    struct xodb_jit_control prep = {0};
    int e = bytes ? xodb_jit_add_jitdump_ctl(&model, &meta, bytes, len, &prep, NULL) : XODB_JIT_E_ARGUMENT;
    free(bytes);
    CHECK(e == XODB_JIT_OK);
    const struct xodb_jit_version *v = NULL;
    for (size_t i = 0; e == XODB_JIT_OK && i < model.version_count && !v; ++i) {
        const struct xodb_jit_version *w = &model.versions[i];
        const char *name = (const char *)model.sources[w->source].bytes + w->name_offset;
        if (memmem(name, w->name_len, jit_name, strlen(jit_name)))
            v = w;
    }
    CHECK(v != NULL);
    struct xodb_jit_query q;
    memset(&q, 0, sizeof q);
    q.process = meta.process;
    q.clock = meta.clock;
    q.address = v ? v->start + v->size / 2 : 0;
    q.has_time = 1;
    q.time = meta.coverage_end - 1; /* source clock: before coverage end, after every load */
    struct xodb_jit_result r;
    struct xodb_jit_control qc = {0};
    int qe = v ? xodb_jit_resolve_ctl(&model, &q, &qc, &r) : XODB_JIT_E_ARGUMENT;
    CHECK(qe == XODB_JIT_OK && r.total_exact && r.count >= 1);

    /* Composition: identity by declared fields, clocks by declared name only. */
    char boot[33] = {0}, c07_domain[64];
    for (size_t i = 0, k = 0; doc->header.boot_id.ptr && i < doc->header.boot_id.len && k < 32; ++i)
        if (doc->header.boot_id.ptr[i] != '-')
            boot[k++] = doc->header.boot_id.ptr[i];
    uint8_t doc_boot[16];
    hex(boot, doc_boot, 16);
    int same_instance = doc->header.pid >= 0 && (uint32_t)doc->header.pid == meta.process.pid &&
                        doc->header.start_ticks.known && doc->header.start_ticks.value == meta.process.start_ticks &&
                        !memcmp(doc_boot, meta.process.boot_id, 16);
    int n = snprintf(c07_domain, sizeof c07_domain, "linux-monotonic:");
    for (int i = 0; i < 16; ++i)
        n += snprintf(c07_domain + n, sizeof c07_domain - (size_t)n, "%02x", meta.clock.scope[i]);
    int same_clock_name = doc->header.has_clock && doc->header.clock_domain.ptr &&
                          !strcmp(doc->header.clock_domain.ptr, c07_domain);

    char total[40], self[40], incl[40];
    xlf_count_format(agg.total_weight, total);
    xlf_count_format(fn != XLF_NONE ? agg.self[fn] : (struct xlf_count){0, 0}, self);
    xlf_count_format(fn != XLF_NONE ? agg.inclusive[fn] : (struct xlf_count){0, 0}, incl);
    printf("{\"format\":\"xodb-c07r4-c05-compat/1\",\"note\":\"candidate test fixture, not an installed xodb feature\",\n");
    printf("\"logical\":{\"reader\":\"C05-R4 src/profile/logical_frames.c\",\"contract\":\"" XLF_CONTRACT "\",\"document_sha256\":\"%s\","
           "\"input_stability\":\"%s\",\"producer\":",
           doc->sha256_hex, xlf_stability_name(doc->input_stability));
    json_xs(doc->header.producer_name);
    printf(",\"producer_kind\":");
    json_xs(doc->header.producer_kind);
    printf(",\"runtime\":");
    json_xs(doc->header.runtime_version);
    printf(",\"process\":{\"pid\":%" PRId64 ",\"start_ticks\":\"%" PRIu64 "\",\"boot_id\":", doc->header.pid,
           doc->header.start_ticks.value);
    json_xs(doc->header.boot_id);
    printf("},\"clock_domain\":");
    json_xs(doc->header.clock_domain);
    printf(",\"weight_unit\":");
    json_xs(doc->header.weight_unit);
    printf(",\"weight_semantics\":");
    json_xs(doc->header.weight_semantics);
    printf(",\"thread\":\"%s\",\"stacks\":%" PRIu64 ",\"total_weight\":\"%s\",\"input_incomplete\":%s,"
           "\"function\":{\"name\":\"%s\",\"self\":\"%s\",\"inclusive\":\"%s\",\"record_line\":%" PRIu64
           ",\"record_offset\":%" PRIu64 "}},\n",
           thread_name, agg.stacks, total, agg.input_incomplete ? "true" : "false", function_name, self, incl,
           fn != XLF_NONE ? doc->functions[fn].cite.line : 0, fn != XLF_NONE ? doc->functions[fn].cite.offset : 0);
    printf("\"jit\":{\"resolver\":\"C07-R4 src/profile/jitmap.c\",\"model\":\"" XODB_JIT_MODEL_VERSION "\","
           "\"source_sha256\":\"%s\",\"records\":%" PRIu64 ",\"versions\":%zu,\"build_work\":%" PRIu64
           ",\"clock\":\"%s\",\"header_time_clock\":\"producer_defined_unrelated\",",
           dump_sha, model.source_count ? model.sources[0].records : 0, model.version_count, prep.work, c07_domain);
    if (v && qe == XODB_JIT_OK) {
        const struct xodb_jit_version *c = &model.versions[r.candidates[0].version - 1];
        printf("\"query\":{\"address\":\"0x%" PRIx64 "\",\"time\":\"%" PRIu64 "\",\"outcome\":\"%s\",\"total\":%zu,"
               "\"total_exact\":%s,\"work\":%" PRIu64 ",\"candidate\":{\"name\":",
               q.address, q.time, xodb_jit_outcome_name(r.outcome), r.total, r.total_exact ? "true" : "false", qc.work);
        json_str((const char *)model.sources[c->source].bytes + c->name_offset, c->name_len);
        printf(",\"code_index\":\"%" PRIu64 "\",\"start\":\"0x%" PRIx64 "\",\"size\":\"0x%" PRIx64
               "\",\"begin\":{\"kind\":\"%s\",\"time\":\"%" PRIu64 "\",\"record\":%" PRIu64 ",\"offset\":%" PRIu64 "}",
               c->code_index, c->start, c->size, xodb_jit_bound_name(c->begin.kind), c->begin.time, c->begin.ordinal,
               c->begin.offset);
        if (c->unwind_record >= 0)
            printf(",\"unwinding_info\":{\"record\":%" PRIu64 ",\"bytes\":\"%" PRIu64 "\",\"interpreted\":false}",
                   model.unwinds[c->unwind_record].ordinal, model.unwinds[c->unwind_record].unwind_size);
        printf("}}");
    } else {
        printf("\"query\":null");
    }
    printf("},\n\"composition\":{\"process_instance\":\"%s\",\"clock_relation\":\"%s\",\"bridge\":null,"
           "\"bridge_reason\":\"no same-context native-to-logical observation was measured\","
           "\"weights_are_cpu_time\":false,\"frames_interleaved\":false}}\n",
           same_instance ? "same_declared_instance" : "different_or_unknown",
           same_clock_name ? "same_declared_domain_name" : "unrelated_no_declared_mapping");
    CHECK(!same_clock_name); /* the C05 exporter names CLOCK_MONOTONIC; no mapping is declared here */
    xlf_aggregate_free(&agg);
    xlf_free(doc);
    xodb_jit_model_free(&model);
    return failures != 0;
}
