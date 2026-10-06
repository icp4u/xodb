/* xodb-jvm-import: import one declared JVM stack source and print the normalized
 * C06-0 document or a bounded query. Exit: 0 ok, 1 malformed input, 2 usage or
 * unsupported query, 3 unavailable input, 4 budget exhausted, 5 no matching evidence,
 * 6 lframes-check disagreement between the importer and the shared C05 reader,
 * 7 cancelled. lframes-check and evidence run through the owned evidence bundle
 * (jvm_evidence.h, C05-R3), the C API intended for integration. */
#define _GNU_SOURCE 1
#include "jvm_evidence_internal.h" /* lframes-check compares with the import state */
#include "sha256.h"
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>

static struct xlf_cancel *cancel_object;
static void on_signal(int sig)
{
    (void)sig;
    xlf_cancel_request(cancel_object);
}
static void jcount(const char *key, struct xlf_count c)
{
    char buf[40];
    xlf_count_format(c, buf);
    printf(",\"%s\":\"%s\"", key, buf);
}
static void usage_json(const struct jvm_evidence *ev)
{
    struct jvm_evidence_usage u;
    jvm_evidence_usage(ev, &u);
    printf(",\"usage\":{\"note\":\"bytes by phase of one whole-operation budget; whole_peak covers read, import, "
           "adaptation, emission and the reader's decode peak\",\"source_bytes\":%zu,\"import_peak\":%zu,"
           "\"adapt_peak\":%zu,\"lframes_bytes\":%zu,\"reader_decode_peak\":%zu,\"whole_peak\":%zu,"
           "\"retained_bytes\":%zu,\"limit\":%zu}",
           u.source_bytes, u.import_peak, u.adapt_peak, u.lframes_bytes, u.decode_peak, u.whole_peak,
           u.retained_bytes, u.limit);
}
/* Composed check: the evidence bundle (read once, import, adapt, decode with the
 * shared reader) aggregated and compared per thread with the importer's records.
 * Exit 0 agree, 6 disagree, 1 query failure. */
static int lframes_check(const struct jvm_evidence *ev, const struct jvm_query *q)
{
    const struct xlf_doc *d = jvm_evidence_doc(ev);
    const struct jvm_import *im = jvm_evidence_import_state(ev);
    struct xlf_error err;
    struct xlf_aggregate all;
    if (jvm_evidence_aggregate(ev, XLF_NONE, cancel_object, &all, &err)) {
        printf("{\"status\":\"error\",\"phase\":\"query\",\"error\":\"%s\"}\n", xlf_status_name(err.status));
        return 1;
    }
    /* Importer-side counts per adapter thread id, from the records themselves. */
    unsigned kind = jvm_lframes_kind(im, q);
    uint64_t selected = 0, *per = calloc(d->thread_count + 1, sizeof *per);
    int agree = per != NULL, threads_ok = per != NULL;
    char key[64];
    for (uint64_t i = 0; per && i < im->record_count; i++) {
        const struct jvm_record *r = &im->records[i];
        if (r->kind != kind)
            continue;
        if (q->has_java_tid && (r->thread == UINT32_MAX || !im->threads[r->thread].has_java_tid ||
                                im->threads[r->thread].java_tid != q->java_tid))
            continue;
        selected++;
        if (r->kind == JVM_COROUTINE_STACK)
            snprintf(key, sizeof key, "c%llu", (unsigned long long)r->ordinal);
        else if (r->thread == UINT32_MAX)
            snprintf(key, sizeof key, "t-unknown");
        else
            snprintf(key, sizeof key, "t%u", r->thread);
        uint32_t t = xlf_find_thread(d, key);
        if (t >= d->thread_count)
            threads_ok = 0;
        else
            per[t]++;
    }
    agree &= threads_ok && selected == d->stack_count && selected == all.stacks && !all.total_weight.hi &&
             all.total_weight.lo == selected;
    printf("{\"contract\":\"" XLF_CONTRACT "\",\"reader\":\"src/profile/logical_frames.c\",\"api\":\"jvm_evidence\","
           "\"source_sha256\":\"%s\",\"lframes_sha256\":\"%s\",\"lframes_bytes\":%llu,\"import_complete\":%s,"
           "\"document_complete\":%s,\"importer_records\":%llu,\"stacks\":%llu,\"partial_stacks\":%llu",
           im->sha256, d->sha256_hex, (unsigned long long)d->input_bytes, im->incomplete ? "false" : "true",
           all.input_incomplete ? "false" : "true", (unsigned long long)selected, (unsigned long long)all.stacks,
           (unsigned long long)all.partial_stacks);
    jcount("total_weight", all.total_weight);
    jcount("partial_weight", all.partial_weight);
    jcount("marker_weight", all.marker_weight);
    jcount("unknown_leaf_weight", all.unknown_leaf_weight);
    printf(",\"functions\":%zu,\"threads\":[", d->function_count);
    for (size_t t = 0; t < d->thread_count && per; t++) {
        struct xlf_aggregate one;
        int ok = jvm_evidence_aggregate(ev, (uint32_t)t, cancel_object, &one, &err) == XLF_OK &&
                 !one.total_weight.hi && one.total_weight.lo == per[t] && one.stacks == per[t];
        agree &= ok;
        printf("%s{\"id\":", t ? "," : "");
        jvm_json_string(stdout, d->threads[t].id.ptr);
        printf(",\"language_id\":");
        jvm_json_string(stdout, d->threads[t].language_id.ptr);
        if (d->threads[t].os_tid > 0)
            printf(",\"os_tid\":%lld", (long long)d->threads[t].os_tid);
        else
            fputs(",\"os_tid\":null", stdout);
        printf(",\"importer_records\":%llu,\"reader_stacks\":%llu", (unsigned long long)per[t],
               (unsigned long long)one.stacks);
        jcount("reader_weight", one.total_weight);
        printf(",\"agree\":%s}", ok ? "true" : "false");
        xlf_aggregate_free(&one);
    }
    printf("],\"budget\":{\"phase\":\"reader decode and query only (see usage for the whole operation)\","
           "\"decode_peak_bytes\":%zu,\"retained_bytes\":%zu,\"query_peak_bytes\":%zu,\"combined_peak_bytes\":%zu}",
           d->decode_peak_bytes, d->retained_bytes, all.query_peak_bytes, all.combined_peak_bytes);
    usage_json(ev);
    printf(",\"agree\":%s,\"status\":\"%s\"}\n", agree ? "true" : "false", agree ? "ok" : "mismatch");
    free(per);
    xlf_aggregate_free(&all);
    return agree ? 0 : 6;
}
/* Evidence as returned by the C API only (no JSON from the adapter is parsed):
 * per stack the cited source span and its SHA-256, time raw/status, truncation and
 * one code per frame; per function the producer identity; per thread the
 * virtual/coroutine evidence. Frame codes: I interpreted, J jit, L jit inlined,
 * N Java method declared native, U unspecified, K unknown, X unavailable,
 * C coroutine marker; lowercase = parsed heuristically from text; '.' = emitted
 * as a C05 marker frame (no function); '!' would mean native authority (never). */
static int evidence_query(const struct jvm_evidence *ev)
{
    const struct xlf_doc *d = jvm_evidence_doc(ev);
    size_t slen;
    const char *ssha;
    jvm_evidence_source(ev, &slen, &ssha);
    struct jvm_evidence_info info;
    jvm_evidence_info(ev, &info);
    printf("{\"status\":\"ok\",\"api\":\"jvm_evidence\",\"contract\":\"" XLF_CONTRACT "\",\"source\":{\"sha256\":\"%s\","
           "\"bytes\":%zu,\"stability\":\"%s\"},\"lframes_sha256\":\"%s\"",
           ssha, slen, xlf_stability_name(info.stability), d->sha256_hex);
    usage_json(ev);
    fputs(",\"stacks\":[", stdout);
    static const char codes[] = "IJLNUKXC";
    for (uint32_t i = 0; i < d->stack_count; i++) {
        struct jvm_evidence_stack s;
        jvm_evidence_stack(ev, i, &s);
        printf("%s{\"id\":", i ? "," : "");
        jvm_json_string(stdout, d->stacks[i].id.ptr);
        printf(",\"ordinal\":%llu,\"thread\":", (unsigned long long)s.ordinal);
        jvm_json_string(stdout, d->threads[d->stacks[i].thread].id.ptr);
        const uint8_t *span;
        size_t n;
        if (!jvm_evidence_cite(ev, i, &span, &n)) {
            char h[65];
            sha256_hex(span, n, h);
            printf(",\"cite\":{\"offset\":%llu,\"length\":%zu,\"sha256\":\"%s\"}", (unsigned long long)s.source_offset,
                   n, h);
        } else
            fputs(",\"cite\":null", stdout);
        if (s.line_start)
            printf(",\"lines\":[%llu,%llu]", (unsigned long long)s.line_start, (unsigned long long)s.line_end);
        fputs(",\"time\":{\"raw\":", stdout);
        jvm_json_string(stdout, s.time_raw);
        printf(",\"status\":\"%s\",\"epoch_ns\":", jvm_time_status_name(s.time_status));
        if (s.has_time_ns)
            printf("\"%lld\"", (long long)s.time_ns);
        else
            fputs("null", stdout);
        printf("},\"truncation\":%u,\"creation_frames\":%u,\"frames\":\"", (unsigned)s.truncation, s.creation_count);
        for (uint32_t j = 0; j < d->stacks[i].frame_count; j++) {
            struct jvm_evidence_frame f;
            jvm_evidence_frame(ev, d->stacks[i].first_frame + j, &f);
            char c = f.marker ? '.' : (unsigned)f.mode < sizeof codes - 1 ? codes[f.mode] : '?';
            if (f.native_authority)
                c = '!';
            putchar(f.heuristic_text && c >= 'A' && c <= 'Z' ? c + 32 : c);
        }
        fputs("\"}", stdout);
    }
    fputs("],\"functions\":[", stdout);
    for (uint32_t i = 0; i < d->function_count; i++) {
        struct jvm_evidence_frame f;
        jvm_evidence_function(ev, i, &f);
        printf("%s{\"id\":", i ? "," : "");
        jvm_json_string(stdout, d->functions[i].id.ptr);
        printf(",\"basis\":\"%s\",\"class_loader\":", jvm_loader_status_name(f.loader_status));
        jvm_json_string(stdout, f.class_loader);
        fputs(",\"class_loader_type\":", stdout);
        jvm_json_string(stdout, f.class_loader_type);
        fputs(",\"module\":", stdout);
        jvm_json_string(stdout, f.module);
        fputs(",\"module_version\":", stdout);
        jvm_json_string(stdout, f.module_version);
        fputs(",\"class\":", stdout);
        jvm_json_string(stdout, f.class_name);
        fputs(",\"method\":", stdout);
        jvm_json_string(stdout, f.method);
        fputs(",\"descriptor\":", stdout);
        jvm_json_string(stdout, f.descriptor);
        putchar('}');
    }
    fputs("],\"threads\":[", stdout);
    for (uint32_t i = 0; i < d->thread_count; i++) {
        struct jvm_evidence_thread t;
        jvm_evidence_thread(ev, i, &t);
        printf("%s{\"id\":", i ? "," : "");
        jvm_json_string(stdout, d->threads[i].id.ptr);
        printf(",\"what\":\"%s\",\"virtual\":%s,\"vm_internal\":%s,\"java_tid\":",
               t.what == JVM_EVIDENCE_COROUTINE ? "coroutine" : t.what == JVM_EVIDENCE_NO_THREAD ? "none" : "thread",
               t.is_virtual == JVM_YES ? "true" : t.is_virtual == JVM_NO ? "false" : "null",
               t.vm_internal ? "true" : "false");
        if (t.has_java_tid)
            printf("\"%lld\"", (long long)t.java_tid);
        else
            fputs("null", stdout);
        fputs(",\"os_tid\":", stdout);
        if (t.has_os_tid)
            printf("\"%lld\"", (long long)t.os_tid);
        else
            fputs("null", stdout);
        if (t.what == JVM_EVIDENCE_COROUTINE) {
            printf(",\"coroutine\":{\"sequence\":\"%lld\",\"parent_sequence\":", (long long)t.coroutine_seq);
            if (t.has_parent)
                printf("\"%lld\"", (long long)t.parent_seq);
            else
                fputs("null", stdout);
            fputs(",\"parent_thread\":", stdout);
            jvm_json_string(stdout, t.parent_doc_thread != XLF_NONE ? d->threads[t.parent_doc_thread].id.ptr : NULL);
            fputs(",\"relation\":", stdout);
            jvm_json_string(stdout, t.parent_relation);
            fputs(",\"state\":", stdout);
            jvm_json_string(stdout, t.state);
            putchar('}');
        }
        putchar('}');
    }
    puts("]}");
    return 0;
}
static int usage(void)
{
    fputs("usage: xodb-jvm-import --source jfr-json|thread-dump-json|thread-print|coroutine-probes\n"
          "       [--query document|threads|stacks|aggregate|relations|lframes|lframes-check|evidence]\n"
          "       [--kind KIND]\n"
          "       [--java-tid N] [--by top|method|inclusive|stack] [--start N] [--limit N]\n"
          "       [--citations N] [--max-bytes N] [--max-records N] [--max-stack-frames N]\n"
          "       [--max-total-frames N] [--max-threads N] [--max-depth N]\n"
          "       [--lframes-max-frames N] [--jfr-stack-depth N] [--max-total-bytes N] FILE\n"
          "--query evidence|lframes-check use the owned evidence bundle; --max-total-bytes bounds\n"
          "its whole operation (read, import, adaptation, emission, decode, retained result).\n"
          "--jfr-stack-depth declares the jfr print --stack-depth used for the export;\n"
          "without it JFR stack completeness is reported as unknown.\n", stderr);
    return 2;
}
static int number(const char *s, uint64_t *out)
{
    char *end;
    errno = 0;
    if (!s || *s == '-' || !*s)
        return -1;
    unsigned long long v = strtoull(s, &end, 10);
    if (errno || *end)
        return -1;
    *out = v;
    return 0;
}
int main(int argc, char **argv)
{
    struct jvm_limits limits;
    jvm_limits_default(&limits);
    struct jvm_query q = {.name = "document", .limit = 50, .citations = 8};
    const char *source = NULL, *path = NULL;
    uint64_t lframes_max = 4096; /* C05-1 reader default frames per stack */
    struct jvm_evidence_limits elimits;
    jvm_evidence_default_limits(&elimits);
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        uint64_t n = 0;
        int numeric = strcmp(a, "--source") && strcmp(a, "--query") && strcmp(a, "--kind") &&
                      strcmp(a, "--by") && !strncmp(a, "--", 2);
        if (numeric && number(v, &n))
            return usage();
        if (!strcmp(a, "--source"))
            source = v;
        else if (!strcmp(a, "--query"))
            q.name = v;
        else if (!strcmp(a, "--kind")) {
            unsigned k;
            if (!v || jvm_parse_kind(v, &k))
                return usage();
            q.kind = k;
            q.has_kind = 1;
        } else if (!strcmp(a, "--by"))
            q.by = v;
        else if (!strcmp(a, "--java-tid")) {
            if (n > INT64_MAX)
                return usage();
            q.java_tid = (int64_t)n;
            q.has_java_tid = 1;
        } else if (!strcmp(a, "--start"))
            q.start = n;
        else if (!strcmp(a, "--limit")) {
            if (!n || n > 10000)
                return usage();
            q.limit = n;
        } else if (!strcmp(a, "--citations")) {
            if (n > 1024)
                return usage();
            q.citations = n;
        } else if (!strcmp(a, "--max-bytes"))
            limits.max_bytes = n;
        else if (!strcmp(a, "--max-records"))
            limits.max_records = n;
        else if (!strcmp(a, "--max-stack-frames"))
            limits.max_stack_frames = n;
        else if (!strcmp(a, "--max-total-frames"))
            limits.max_total_frames = n;
        else if (!strcmp(a, "--jfr-stack-depth")) {
            if (!n || n > 1000000)
                return usage();
            limits.jfr_export_depth = (uint32_t)n;
        } else if (!strcmp(a, "--lframes-max-frames")) {
            if (!n || n > UINT32_MAX)
                return usage();
            lframes_max = n;
        } else if (!strcmp(a, "--max-total-bytes")) {
            if (n > SIZE_MAX)
                return usage();
            elimits.max_total_bytes = (size_t)n;
        } else if (!strcmp(a, "--max-threads"))
            limits.max_threads = n;
        else if (!strcmp(a, "--max-depth")) {
            if (!n || n > 4096)
                return usage();
            limits.max_depth = (uint32_t)n;
        } else if (!strncmp(a, "--", 2))
            return usage();
        else {
            if (path)
                return usage();
            path = a;
            continue;
        }
        if (!v)
            return usage();
        i++;
    }
    if (!source || !path || !q.name)
        return usage();
    enum jvm_source s;
    if (!strcmp(source, "jfr-json"))
        s = JVM_SOURCE_JFR_JSON;
    else if (!strcmp(source, "thread-dump-json"))
        s = JVM_SOURCE_THREAD_DUMP_JSON;
    else if (!strcmp(source, "thread-print"))
        s = JVM_SOURCE_THREAD_PRINT;
    else if (!strcmp(source, "coroutine-probes"))
        s = JVM_SOURCE_COROUTINE_PROBES;
    else {
        fprintf(stderr, "unsupported source '%s' (ART and Kotlin/Native are separate producers)\n",
                source);
        return 2;
    }
    if (!strcmp(q.name, "lframes-check") || !strcmp(q.name, "evidence")) {
        cancel_object = xlf_cancel_create();
        if (!cancel_object)
            return 1;
        struct sigaction sa = {.sa_handler = on_signal};
        sigemptyset(&sa.sa_mask);
        sigaction(SIGINT, &sa, NULL);
        sigaction(SIGTERM, &sa, NULL);
        elimits.import = limits;
        elimits.max_frames = (uint32_t)lframes_max;
        struct jvm_evidence *ev;
        struct xlf_error err;
        enum xlf_status st = jvm_evidence_import(path, s, &q, &elimits, cancel_object, &ev, &err);
        int crc;
        if (st) {
            printf("{\"status\":\"error\",\"api\":\"jvm_evidence\",\"error\":\"%s\",\"whole_peak\":%zu,\"message\":",
                   xlf_status_name(st), err.peak_bytes);
            jvm_json_string(stdout, err.message);
            puts("}");
            crc = st == XLF_E_IO ? 3 : st == XLF_E_LIMIT || st == XLF_E_MEMORY ? 4 : st == XLF_E_EMPTY ? 5
                  : st == XLF_E_ARGUMENT ? 2 : st == XLF_E_CANCELLED ? 7 : 1;
        } else {
            crc = !strcmp(q.name, "evidence") ? evidence_query(ev) : lframes_check(ev, &q);
            jvm_evidence_free(ev);
        }
        xlf_cancel_destroy(cancel_object);
        if (fflush(stdout) || ferror(stdout))
            return 1;
        return crc;
    }
    struct jvm_import *im = NULL;
    int rc = jvm_import_file(path, s, &limits, &im);
    if (rc) {
        fprintf(stderr, "xodb-jvm-import: %s\n", im && im->error[0] ? im->error : "out of memory");
        jvm_import_free(im);
        return rc == -2 ? 3 : rc == -4 ? 4 : 1;
    }
    int qrc;
    if (!strcmp(q.name, "lframes")) {
        qrc = jvm_lframes_write(stdout, im, &q, (uint32_t)lframes_max);
        if (qrc == 2)
            fputs("xodb-jvm-import: record kind does not match this source\n", stderr);
        if (qrc < 0) {
            jvm_import_free(im);
            return 1;
        }
    } else
        qrc = jvm_query_write(stdout, im, &q);
    int incomplete = im->incomplete != NULL;
    if (incomplete)
        fprintf(stderr, "xodb-jvm-import: incomplete: %s\n", im->incomplete);
    jvm_import_free(im);
    if (fflush(stdout) || ferror(stdout))
        return 1;
    return qrc == 2 ? 2 : incomplete ? 4 : qrc == 1 ? 5 : 0;
}
