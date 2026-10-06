#define _GNU_SOURCE 1
/* Normalized document output and bounded queries over one imported JVM source.
 * Weights keep the source's unit: samples, events or observations. Nothing here
 * converts a sample count into CPU time, and every derived row cites ordinals. */
#include "jvm_import.h"
#include <stdlib.h>
#include <string.h>
void jvm_json_string(FILE *o, const char *s)
{
    jvm_json_string_n(o, s, s ? strlen(s) : 0);
}
void jvm_json_string_n(FILE *o, const char *s, size_t n)
{
    if (!s) {
        fputs("null", o);
        return;
    }
    fputc('"', o);
    for (const char *e = s + n; s < e && *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\')
            fprintf(o, "\\%c", c);
        else if (c == '\n')
            fputs("\\n", o);
        else if (c == '\t')
            fputs("\\t", o);
        else if (c < 0x20 || c == 0x7f)
            fprintf(o, "\\u%04x", c);
        else
            fputc(c, o);
    }
    fputc('"', o);
}
static void key_str(FILE *o, const char *key, const char *value)
{
    fprintf(o, "\"%s\":", key);
    jvm_json_string(o, value);
}
static void key_i64(FILE *o, const char *key, int has, int64_t v)
{
    if (has)
        fprintf(o, "\"%s\":\"%lld\"", key, (long long)v);
    else
        fprintf(o, "\"%s\":null", key);
}
static const char *tri(unsigned v)
{
    return v == JVM_YES ? "true" : v == JVM_NO ? "false" : "null";
}
static const char *truncation(unsigned t)
{
    static const char *const n[] = {"complete", "truncated_by_source", "not_reported_by_source",
                                    "truncated_by_importer", "possibly_truncated_by_export"};
    return t < 5 ? n[t] : "invalid";
}
static const char *name_status(unsigned s)
{
    static const char *const n[] = {"ok", "empty", "invalid_jvm_name", "absent"};
    return s < 4 ? n[s] : "invalid";
}
static void weight(FILE *o, unsigned kind)
{
    switch (kind) {
    case JVM_EXECUTION_SAMPLE:
    case JVM_NATIVE_METHOD_SAMPLE:
        fputs("{\"value\":1,\"unit\":\"samples\"}", o);
        break;
    case JVM_THREAD_DUMP_STACK:
    case JVM_THREAD_PRINT_STACK:
    case JVM_COROUTINE_STACK:
        fputs("{\"value\":1,\"unit\":\"observations\"}", o);
        break;
    default:
        fputs("{\"value\":1,\"unit\":\"events\"}", o);
    }
}
static const char *unit(unsigned kind)
{
    return kind <= JVM_NATIVE_METHOD_SAMPLE ? "samples"
           : kind >= JVM_THREAD_DUMP_STACK  ? "observations"
                                            : "events";
}
static void frame(FILE *o, const struct jvm_import *im, uint32_t id)
{
    const struct jvm_frame *f = &im->frames[id];
    fprintf(o, "{\"id\":%u,\"kind\":\"%s\",", id, jvm_frame_kind_name(f->kind));
    key_str(o, "raw_kind", jvm_str(im, f->raw_kind));
    fputc(',', o);
    key_str(o, "class", jvm_str(im, f->class_name));
    fputc(',', o);
    key_str(o, "method", jvm_str(im, f->method));
    fprintf(o, ",\"name_status\":\"%s\",", name_status(f->name_status));
    key_str(o, "descriptor", jvm_str(im, f->descriptor));
    fputc(',', o);
    key_str(o, "module", jvm_str(im, f->module));
    fputc(',', o);
    key_str(o, "module_version", jvm_str(im, f->module_version));
    fputc(',', o);
    key_str(o, "class_loader", jvm_str(im, f->loader));
    fputc(',', o);
    key_str(o, "class_loader_type", jvm_str(im, f->loader_type));
    fprintf(o, ",\"class_loader_status\":\"%s\"", jvm_loader_status_name(f->loader_status));
    fputc(',', o);
    key_str(o, "file", jvm_str(im, f->file));
    if (f->has_line)
        fprintf(o, ",\"line\":%lld", (long long)f->line);
    else
        fputs(",\"line\":null", o);
    if (f->has_bci)
        fprintf(o, ",\"bytecode_index\":%lld", (long long)f->bci);
    else
        fputs(",\"bytecode_index\":null", o);
    fprintf(o, ",\"hidden\":%s,\"parse\":\"%s\"", tri(f->hidden),
            f->heuristic ? "heuristic_text" : "structured");
    if (f->raw_text) {
        fputc(',', o);
        key_str(o, "raw_text", jvm_str(im, f->raw_text));
    }
    if (f->raw_class && f->raw_class != f->class_name) {
        fputc(',', o);
        key_str(o, "raw_class", jvm_str(im, f->raw_class));
    }
    fputc('}', o);
}
static void thread(FILE *o, const struct jvm_import *im, uint32_t id)
{
    const struct jvm_thread *t = &im->threads[id];
    fprintf(o, "{\"id\":%u,", id);
    key_i64(o, "java_thread_id", t->has_java_tid, t->java_tid);
    fputc(',', o);
    key_i64(o, "os_tid", t->has_os_tid, t->os_tid);
    fprintf(o, ",\"virtual\":%s,\"vm_internal\":%s,", tri(t->is_virtual),
            t->vm_internal ? "true" : "false");
    key_str(o, "vm_thread_address", jvm_str(im, t->vm_address));
    fputc(',', o);
    key_str(o, "group", jvm_str(im, t->group));
    fputs(",\"names\":[", o);
    for (uint32_t i = 0; i < t->name_count; i++) {
        if (i)
            fputc(',', o);
        jvm_json_string(o, jvm_str(im, t->names[i]));
    }
    fprintf(o, "],\"names_truncated\":%s,\"records\":{", t->names_truncated ? "true" : "false");
    int first = 1;
    for (unsigned k = 0; k < JVM_KIND_COUNT; k++)
        if (t->records[k]) {
            fprintf(o, "%s\"%s\":%llu", first ? "" : ",", jvm_kind_name(k),
                    (unsigned long long)t->records[k]);
            first = 0;
        }
    fprintf(o, "},\"first_ordinal\":%llu,\"last_ordinal\":%llu}",
            (unsigned long long)t->first_ordinal, (unsigned long long)t->last_ordinal);
}
static void citation(FILE *o, const struct jvm_import *im, const struct jvm_record *r)
{
    fprintf(o, "{\"source_sha256\":\"%s\",\"ordinal\":%llu", im->sha256,
            (unsigned long long)r->ordinal);
    if (im->source == JVM_SOURCE_JFR_JSON)
        fprintf(o, ",\"path\":\"recording.events[%llu]\"", (unsigned long long)r->ordinal);
    else if (r->path) {
        fputc(',', o);
        key_str(o, "path", jvm_str(im, r->path));
    }
    if (im->source == JVM_SOURCE_THREAD_PRINT)
        fprintf(o, ",\"lines\":[%llu,%llu],\"bytes\":[%llu,%llu]",
                (unsigned long long)r->line_start, (unsigned long long)r->line_end,
                (unsigned long long)r->byte_start, (unsigned long long)r->byte_end);
    fputc('}', o);
}
static void stack(FILE *o, const struct jvm_import *im, uint32_t start, uint32_t count, int expand)
{
    fputc('[', o);
    for (uint32_t i = 0; i < count; i++) {
        if (i)
            fputc(',', o);
        if (expand)
            frame(o, im, im->stack[start + i]);
        else
            fprintf(o, "%u", im->stack[start + i]);
    }
    fputc(']', o);
}
static void record(FILE *o, const struct jvm_import *im, const struct jvm_record *r, int expand)
{
    fprintf(o, "{\"ordinal\":%llu,\"citation\":", (unsigned long long)r->ordinal);
    citation(o, im, r);
    fprintf(o, ",\"kind\":\"%s\",", jvm_kind_name(r->kind));
    key_str(o, "event_type", jvm_str(im, r->event_type));
    if (r->thread == UINT32_MAX)
        fputs(",\"thread\":null", o);
    else
        fprintf(o, ",\"thread\":%u", r->thread);
    fputc(',', o);
    key_str(o, "thread_name", jvm_str(im, r->name));
    fputc(',', o);
    key_str(o, "os_thread_name", jvm_str(im, r->os_name));
    fputc(',', o);
    key_str(o, "state", jvm_str(im, r->state));
    fputs(",\"time\":{", o);
    key_str(o, "raw", jvm_str(im, r->time_raw));
    fputc(',', o);
    key_i64(o, "epoch_ns", r->has_time_ns, r->time_ns);
    fprintf(o, ",\"status\":\"%s\"", jvm_time_status_name(r->time_status));
    fputs("},\"weight\":", o);
    weight(o, r->kind);
    fprintf(o, ",\"stack_order\":\"innermost_first\",\"truncation\":\"%s\",",
            truncation(r->truncated));
    if (r->truncated == JVM_TRUNC_IMPORTER)
        fprintf(o, "\"importer_dropped_frames\":%llu,", (unsigned long long)r->dropped);
    fputs("\"stack\":", o);
    stack(o, im, r->frame_start, r->frame_count, expand);
    if (r->kind == JVM_EXCEPTION_THROW || r->kind == JVM_ERROR_THROW) {
        fputs(",\"exception\":{", o);
        key_str(o, "class", jvm_str(im, r->detail));
        fputc(',', o);
        key_str(o, "message", jvm_str(im, r->detail2));
        fputc('}', o);
    } else if (r->kind == JVM_THREAD_DUMP_STACK) {
        fputc(',', o);
        key_str(o, "container", jvm_str(im, r->detail));
    } else if (r->kind == JVM_THREAD_PRINT_STACK) {
        fputc(',', o);
        key_str(o, "raw_header", jvm_str(im, r->detail));
    } else if (r->kind == JVM_COROUTINE_STACK) {
        fprintf(o, ",\"coroutine\":{\"sequence\":\"%lld\",", (long long)r->coroutine_seq);
        key_i64(o, "coroutine_id", r->has_coroutine_id, r->coroutine_id);
        fputc(',', o);
        key_str(o, "name", jvm_str(im, r->detail));
        fputc(',', o);
        key_str(o, "parent_relation", jvm_str(im, r->parent_relation));
        fputc(',', o);
        key_i64(o, "parent_sequence", r->has_parent, r->parent_seq);
        fputs("},\"creation_stack\":", o);
        stack(o, im, r->creation_start, r->creation_count, expand);
    }
    fputc('}', o);
}
static void collection(FILE *o, enum jvm_source s)
{
    switch (s) {
    case JVM_SOURCE_JFR_JSON:
        fputs("{\"method\":\"jfr_events\",\"semantics\":\"sampled\",\"consistency\":\"per_event\","
              "\"note\":\"ExecutionSample/NativeMethodSample are periodic thread samples; weights "
              "are sample counts, not CPU time. jfr print --json converts JFR ticks to zoned "
              "wall-clock text; raw ticks are not exported.\"}", o);
        break;
    case JVM_SOURCE_THREAD_DUMP_JSON:
        fputs("{\"method\":\"jcmd_thread_dump_to_file_json\",\"semantics\":\"point_in_time\","
              "\"consistency\":\"per_thread_non_atomic\",\"note\":\"Includes virtual threads; "
              "no OS TID, execution mode, truncation or virtual flag is exported.\"}", o);
        break;
    case JVM_SOURCE_THREAD_PRINT:
        fputs("{\"method\":\"jcmd_thread_print\",\"semantics\":\"point_in_time\","
              "\"consistency\":\"vm_operation_platform_threads\",\"note\":\"Platform threads "
              "only; header time is unzoned local wall time with second resolution.\"}", o);
        break;
    case JVM_SOURCE_COROUTINE_PROBES:
        fputs("{\"method\":\"kotlinx_coroutines_debug_probes\",\"semantics\":\"point_in_time\","
              "\"consistency\":\"probe_registry_snapshot\",\"instrumentation\":"
              "\"-javaagent debug probes installed (adds overhead)\",\"note\":\"Parent relation "
              "is Job.parent at dump time; frames after the _COROUTINE._CREATION marker are "
              "creation stack, never callers.\"}", o);
        break;
    }
}
static int document(FILE *o, const struct jvm_import *im)
{
    fputs("{\"schema\":\"xodb.jvm-frames\",\"schema_version\":\"" JVM_SCHEMA "\",", o);
    fputs("\"producer\":{\"name\":\"xodb-jvm-import\",\"version\":\"" JVM_PRODUCER_VERSION "\","
          "\"compiler\":", o);
    jvm_json_string(o, __VERSION__);
    fprintf(o, "},\"status\":\"%s\",", im->incomplete ? "incomplete" : "complete");
    key_str(o, "incomplete_reason", im->incomplete);
    fputs(",\"source\":{\"kind\":\"imported_runtime_report\",", o);
    fprintf(o, "\"format\":\"%s\",", jvm_source_name(im->source));
    key_str(o, "path", im->path);
    fprintf(o, ",\"sha256\":\"%s\",\"bytes\":%llu,\"records_scanned\":%llu,\"stability\":\"%s\",",
            im->sha256, (unsigned long long)im->bytes, (unsigned long long)im->records_scanned,
            xlf_stability_name((enum xlf_stability)im->source_stability));
    if (im->source == JVM_SOURCE_JFR_JSON && im->limits.jfr_export_depth)
        fprintf(o, "\"declared_export_stack_depth\":%u,", im->limits.jfr_export_depth);
    else if (im->source == JVM_SOURCE_JFR_JSON)
        fputs("\"declared_export_stack_depth\":null,", o);
    fputs("\"collection\":", o);
    collection(o, im->source);
    int identity = im->jvm_version || im->runtime_version;
    fprintf(o, "},\"runtime\":{\"family\":\"hotspot_jvm\",\"identity\":\"%s\",",
            identity ? "present" : "missing");
    key_str(o, "jvm_name", jvm_str(im, im->jvm_name));
    fputc(',', o);
    key_str(o, "jvm_version", jvm_str(im, im->jvm_version));
    fputc(',', o);
    key_str(o, "runtime_version", jvm_str(im, im->runtime_version));
    fputc(',', o);
    key_str(o, "jvm_start_time", jvm_str(im, im->jvm_start));
    fputc(',', o);
    key_str(o, "jvm_arguments", jvm_str(im, im->jvm_args));
    fputc(',', o);
    key_str(o, "java_arguments", jvm_str(im, im->java_args));
    fputc(',', o);
    key_str(o, "os", jvm_str(im, im->os_version));
    fputc(',', o);
    key_str(o, "header", jvm_str(im, im->dump_header));
    fputs("},\"process\":{", o);
    key_i64(o, "pid", im->has_pid, im->pid);
    fprintf(o, ",\"instance\":");
    if (im->has_pid && im->jvm_start) {
        fprintf(o, "{\"pid\":\"%lld\",", (long long)im->pid);
        key_str(o, "jvm_start_time", jvm_str(im, im->jvm_start));
        fputc('}', o);
    } else
        fputs("null", o);
    fputs(",\"note\":\"A PID alone does not identify a process instance; correlate with the "
          "capture manifest (boot id, launch time).\"},\"time\":{", o);
    key_str(o, "collected_at", jvm_str(im, im->collected_at));
    fputc(',', o);
    key_str(o, "recording_start", jvm_str(im, im->recording_start));
    fputc(',', o);
    key_str(o, "probe_nano_time", jvm_str(im, im->probe_nano));
    fprintf(o, ",\"record_domain\":\"%s\"},",
            im->source == JVM_SOURCE_JFR_JSON           ? "jfr_wallclock_from_ticks_iso8601"
            : im->source == JVM_SOURCE_THREAD_PRINT     ? "unzoned_local_wallclock_seconds"
                                                        : "utc_wallclock_iso8601");
    fputs("\"native_pc_policy\":\"absent: these sources export no native or JIT addresses\",", o);
    const struct jvm_diagnostics *d = &im->diag;
    fprintf(o, "\"diagnostics\":{\"skipped_events\":%llu,\"unknown_frame_kinds\":%llu,"
               "\"malformed_frames\":%llu,\"unnamed_methods\":%llu,\"invalid_method_names\":%llu,"
               "\"lossy_strings\":%llu,\"os_tid_zero_treated_absent\":%llu,"
               "\"missing_thread\":%llu,\"missing_stack\":%llu,\"heuristic_frames\":%llu,"
               "\"creation_marker_splits\":%llu,\"importer_truncated_stacks\":%llu,"
               "\"invalid_utf8_lines\":%llu,\"nid_mismatch\":%llu,\"unparsed_lines\":%llu,"
               "\"monitor_lines\":%llu,\"invalid_numbers\":%llu,\"export_depth_unknown\":%llu,"
               "\"nul_escaped_strings\":%llu,\"crlf_lines\":%llu},",
            (unsigned long long)d->skipped_events, (unsigned long long)d->unknown_frame_kinds,
            (unsigned long long)d->malformed_frames, (unsigned long long)d->unnamed_methods,
            (unsigned long long)d->invalid_method_names, (unsigned long long)d->lossy_strings,
            (unsigned long long)d->os_tid_zero, (unsigned long long)d->missing_thread,
            (unsigned long long)d->missing_stack, (unsigned long long)d->heuristic_frames,
            (unsigned long long)d->creation_marker_splits,
            (unsigned long long)d->importer_truncated_stacks,
            (unsigned long long)d->invalid_utf8_lines, (unsigned long long)d->nid_mismatch,
            (unsigned long long)d->unparsed_lines, (unsigned long long)d->monitor_lines,
            (unsigned long long)d->invalid_numbers, (unsigned long long)d->export_depth_unknown,
            (unsigned long long)d->nul_escaped_strings, (unsigned long long)d->crlf_lines);
    fprintf(o, "\"counts\":{\"records\":%llu,\"threads\":%u,\"frames\":%u},\"threads\":[",
            (unsigned long long)im->record_count, im->thread_count, im->frame_count);
    for (uint32_t i = 0; i < im->thread_count; i++) {
        if (i)
            fputc(',', o);
        thread(o, im, i);
    }
    fputs("],\"frames\":[", o);
    for (uint32_t i = 0; i < im->frame_count; i++) {
        if (i)
            fputc(',', o);
        frame(o, im, i);
    }
    fputs("],\"records\":[", o);
    for (uint64_t i = 0; i < im->record_count; i++) {
        if (i)
            fputs(",\n", o);
        record(o, im, &im->records[i], 0);
    }
    fputs("]}\n", o);
    return 0;
}
static int selected(const struct jvm_import *im, const struct jvm_query *q, const struct jvm_record *r)
{
    if (q->has_kind && r->kind != q->kind)
        return 0;
    if (q->has_java_tid) {
        if (r->thread == UINT32_MAX)
            return 0;
        const struct jvm_thread *t = &im->threads[r->thread];
        if (!t->has_java_tid || t->java_tid != q->java_tid)
            return 0;
    }
    return 1;
}
static void header(FILE *o, const struct jvm_import *im, const struct jvm_query *q,
                   const char *status)
{
    fprintf(o, "{\"schema\":\"xodb.jvm-frames.query\",\"schema_version\":\"" JVM_SCHEMA "\","
               "\"query\":{\"name\":\"%s\",", q->name);
    if (q->has_kind)
        fprintf(o, "\"kind\":\"%s\",", jvm_kind_name(q->kind));
    else
        fputs("\"kind\":null,", o);
    key_i64(o, "java_thread_id", q->has_java_tid, q->java_tid);
    fputc(',', o);
    key_str(o, "by", q->by);
    fprintf(o, ",\"start\":%llu,\"limit\":%llu},\"input\":{\"format\":\"%s\",\"sha256\":\"%s\","
               "\"status\":\"%s\"},\"analysis\":\"xodb-jvm-import " JVM_PRODUCER_VERSION "\","
               "\"status\":\"%s\"",
            (unsigned long long)q->start, (unsigned long long)q->limit, jvm_source_name(im->source),
            im->sha256, im->incomplete ? "incomplete" : "complete", status);
}
struct row {
    char *key;
    uint32_t a, b, c; /* top: frame; method: class, method, descriptor; stack: start, count, truncated */
    uint64_t weight, records, truncated, first;
    uint64_t *cites;
    uint32_t cite_count;
};
struct rows {
    struct row *v;
    uint64_t count, cap;
    uint64_t *slots;
    uint64_t slot_count;
};
static uint64_t hash(const char *s)
{
    uint64_t h = 0xcbf29ce484222325ull;
    for (; *s; s++)
        h = (h ^ (unsigned char)*s) * 0x100000001b3ull;
    return h;
}
static struct row *find(struct rows *rs, char *key, int *fresh)
{
    if ((rs->count + 1) * 2 > rs->slot_count) {
        uint64_t n = rs->slot_count ? rs->slot_count * 2 : 256;
        uint64_t *slots = calloc(n, sizeof(*slots));
        if (!slots)
            return NULL;
        for (uint64_t i = 0; i < rs->count; i++) {
            uint64_t k = hash(rs->v[i].key) & (n - 1);
            while (slots[k])
                k = (k + 1) & (n - 1);
            slots[k] = i + 1;
        }
        free(rs->slots);
        rs->slots = slots;
        rs->slot_count = n;
    }
    uint64_t k = hash(key) & (rs->slot_count - 1);
    for (; rs->slots[k]; k = (k + 1) & (rs->slot_count - 1))
        if (!strcmp(rs->v[rs->slots[k] - 1].key, key)) {
            free(key);
            *fresh = 0;
            return &rs->v[rs->slots[k] - 1];
        }
    if (rs->count == rs->cap) {
        uint64_t cap = rs->cap ? rs->cap * 2 : 64;
        struct row *v = realloc(rs->v, cap * sizeof(*v));
        if (!v)
            return NULL;
        rs->v = v;
        rs->cap = cap;
    }
    struct row *r = &rs->v[rs->count];
    memset(r, 0, sizeof(*r));
    r->key = key;
    rs->slots[k] = ++rs->count;
    *fresh = 1;
    return r;
}
static int by_weight(const void *x, const void *y)
{
    const struct row *a = x, *b = y;
    if (a->weight != b->weight)
        return a->weight > b->weight ? -1 : 1;
    return a->first < b->first ? -1 : a->first > b->first;
}
static int add(struct rows *rs, char *key, const struct jvm_record *r, const struct jvm_query *q,
               uint32_t a, uint32_t b, uint32_t c)
{
    if (!key)
        return -1;
    int fresh;
    struct row *row = find(rs, key, &fresh);
    if (!row)
        return -1;
    if (fresh) {
        row->a = a;
        row->b = b;
        row->c = c;
        row->first = r->ordinal;
        row->cites = calloc(q->citations ? q->citations : 1, sizeof(*row->cites));
        if (!row->cites)
            return -1;
    }
    row->weight++;
    row->records++;
    row->truncated += r->truncated != JVM_TRUNC_NO;
    if (row->cite_count < q->citations)
        row->cites[row->cite_count++] = r->ordinal;
    return 0;
}
static char *fmt_key(const char *f, uint32_t a, uint32_t b, uint32_t c)
{
    char *s;
    return asprintf(&s, f, a, b, c) < 0 ? NULL : s;
}
static char *stack_key(const struct jvm_import *im, const struct jvm_record *r)
{
    size_t n = (size_t)r->frame_count * 11 + 16;
    char *s = malloc(n), *p = s;
    if (!s)
        return NULL;
    p += sprintf(p, "%c", r->truncated == JVM_TRUNC_NO ? 'C' : 'T');
    for (uint32_t i = 0; i < r->frame_count; i++)
        p += sprintf(p, ",%u", im->stack[r->frame_start + i]);
    return s;
}
static int aggregate(FILE *o, const struct jvm_import *im, const struct jvm_query *q)
{
    const char *by = q->by ? q->by : "top";
    int mode = !strcmp(by, "top") ? 0 : !strcmp(by, "method") ? 1 : !strcmp(by, "inclusive") ? 2
             : !strcmp(by, "stack") ? 3 : -1;
    if (!q->has_kind || mode < 0) {
        header(o, im, q, "invalid_query");
        fputs(",\"reason\":\"aggregate needs --kind (sources with different collection semantics "
              "are never mixed) and --by top|method|inclusive|stack\"}\n", o);
        return 2;
    }
    struct rows rs = {0};
    uint64_t total = 0, truncated = 0;
    int rc = 0;
    for (uint64_t i = 0; i < im->record_count && !rc; i++) {
        const struct jvm_record *r = &im->records[i];
        if (!selected(im, q, r))
            continue;
        total++;
        truncated += r->truncated != JVM_TRUNC_NO;
        if (!r->frame_count) {
            rc = add(&rs, strdup("empty"), r, q, UINT32_MAX, 0, 0);
            continue;
        }
        const struct jvm_frame *top = &im->frames[im->stack[r->frame_start]];
        if (mode == 0)
            rc = add(&rs, fmt_key("f%u", im->stack[r->frame_start], 0, 0), r, q,
                     im->stack[r->frame_start], 0, 0);
        else if (mode == 1)
            rc = add(&rs, fmt_key("m%u.%u.%u", top->class_name, top->method, top->descriptor), r, q,
                     top->class_name, top->method, top->descriptor);
        else if (mode == 3)
            rc = add(&rs, stack_key(im, r), r, q, r->frame_start, r->frame_count,
                     r->truncated != JVM_TRUNC_NO);
        else
            for (uint32_t k = 0; k < r->frame_count && !rc; k++) { /* once per record */
                const struct jvm_frame *f = &im->frames[im->stack[r->frame_start + k]];
                uint32_t j;
                for (j = 0; j < k; j++) {
                    const struct jvm_frame *g = &im->frames[im->stack[r->frame_start + j]];
                    if (g->class_name == f->class_name && g->method == f->method &&
                        g->descriptor == f->descriptor)
                        break;
                }
                if (j == k)
                    rc = add(&rs, fmt_key("m%u.%u.%u", f->class_name, f->method, f->descriptor), r,
                             q, f->class_name, f->method, f->descriptor);
            }
    }
    if (rc) {
        header(o, im, q, "failed");
        fputs(",\"reason\":\"out of memory\"}\n", o);
        return 2;
    }
    if (rs.count) /* qsort(NULL, 0) is undefined */
        qsort(rs.v, rs.count, sizeof(*rs.v), by_weight);
    const char *status = !total ? "no_matching_evidence" : q->start >= rs.count ? "empty_page" : "ok";
    header(o, im, q, status);
    fprintf(o, ",\"semantics\":\"%s\",\"weight_unit\":\"%s\",\"total_weight\":%llu,"
               "\"total_records\":%llu,\"truncated_records\":%llu,\"rows_total\":%llu,"
               "\"attribution\":\"%s\",\"rows\":[",
            mode == 2 ? "inclusive_once_per_record" : "self", unit(q->kind),
            (unsigned long long)total, (unsigned long long)total, (unsigned long long)truncated,
            (unsigned long long)rs.count,
            "weights count records whose (possibly truncated) stack matches; never CPU time");
    for (uint64_t i = q->start, n = 0; i < rs.count && n < q->limit; i++, n++) {
        struct row *r = &rs.v[i];
        if (n)
            fputc(',', o);
        fputs("{\"key\":", o);
        if (r->a == UINT32_MAX && mode != 3)
            fputs("{\"empty_stack\":true}", o);
        else if (mode == 0) {
            fputs("{\"frame\":", o);
            frame(o, im, r->a);
            fputc('}', o);
        } else if (mode == 1 || mode == 2) {
            fputc('{', o);
            key_str(o, "class", jvm_str(im, r->a));
            fputc(',', o);
            key_str(o, "method", jvm_str(im, r->b));
            fputc(',', o);
            key_str(o, "descriptor", jvm_str(im, r->c));
            fputc('}', o);
        } else {
            fprintf(o, "{\"truncated\":%s,\"stack_order\":\"innermost_first\",\"frames\":",
                    r->c ? "true" : "false");
            stack(o, im, r->a, r->b, 1);
            fputc('}', o);
        }
        fprintf(o, ",\"weight\":%llu,\"records\":%llu,\"truncated_records\":%llu,"
                   "\"citations\":{\"ordinals\":[",
                (unsigned long long)r->weight, (unsigned long long)r->records,
                (unsigned long long)r->truncated);
        for (uint32_t k = 0; k < r->cite_count; k++)
            fprintf(o, "%s%llu", k ? "," : "", (unsigned long long)r->cites[k]);
        fprintf(o, "],\"total\":%llu,\"truncated\":%s}}", (unsigned long long)r->records,
                r->records > r->cite_count ? "true" : "false");
    }
    fputs("]}\n", o);
    for (uint64_t i = 0; i < rs.count; i++) {
        free(rs.v[i].key);
        free(rs.v[i].cites);
    }
    free(rs.v);
    free(rs.slots);
    return total ? 0 : 1;
}
static int listing(FILE *o, const struct jvm_import *im, const struct jvm_query *q)
{
    uint64_t total = 0;
    for (uint64_t i = 0; i < im->record_count; i++)
        total += selected(im, q, &im->records[i]);
    header(o, im, q, !total ? "no_matching_evidence" : q->start >= total ? "empty_page" : "ok");
    fprintf(o, ",\"total_records\":%llu,\"records\":[", (unsigned long long)total);
    uint64_t seen = 0, written = 0;
    for (uint64_t i = 0; i < im->record_count && written < q->limit; i++) {
        const struct jvm_record *r = &im->records[i];
        if (!selected(im, q, r) || seen++ < q->start)
            continue;
        if (written++)
            fputs(",\n", o);
        record(o, im, r, 1);
    }
    fputs("]}\n", o);
    return total ? 0 : 1;
}
static int threads(FILE *o, const struct jvm_import *im, const struct jvm_query *q)
{
    header(o, im, q, !im->thread_count ? "no_matching_evidence" : "ok");
    fprintf(o, ",\"total_threads\":%u,\"threads\":[", im->thread_count);
    for (uint64_t i = q->start, n = 0; i < im->thread_count && n < q->limit; i++, n++) {
        if (n)
            fputc(',', o);
        thread(o, im, (uint32_t)i);
    }
    fputs("]}\n", o);
    return im->thread_count ? 0 : 1;
}
static int relations(FILE *o, const struct jvm_import *im, const struct jvm_query *q)
{
    if (im->source != JVM_SOURCE_COROUTINE_PROBES) {
        header(o, im, q, "unsupported_query");
        fputs(",\"reason\":\"coroutine relations exist only in a probe dump\"}\n", o);
        return 2;
    }
    header(o, im, q, im->record_count ? "ok" : "no_matching_evidence");
    fputs(",\"relation\":\"coroutine_job_parent\",\"evidence\":\"Job.parent from kotlinx "
          "DebugProbes at dump time; not a call edge\",\"relations\":[", o);
    for (uint64_t i = 0; i < im->record_count; i++) {
        const struct jvm_record *r = &im->records[i];
        if (i)
            fputc(',', o);
        fprintf(o, "{\"child_sequence\":\"%lld\",", (long long)r->coroutine_seq);
        key_str(o, "child_name", jvm_str(im, r->detail));
        fputc(',', o);
        key_str(o, "status", jvm_str(im, r->parent_relation));
        fputc(',', o);
        key_i64(o, "parent_sequence", r->has_parent, r->parent_seq);
        fputs(",\"citation\":", o);
        citation(o, im, r);
        fputc('}', o);
    }
    fputs("]}\n", o);
    return im->record_count ? 0 : 1;
}
int jvm_query_write(FILE *o, const struct jvm_import *im, const struct jvm_query *q)
{
    if (!q->name || !strcmp(q->name, "document"))
        return document(o, im);
    if (!strcmp(q->name, "threads"))
        return threads(o, im, q);
    if (!strcmp(q->name, "stacks"))
        return listing(o, im, q);
    if (!strcmp(q->name, "aggregate"))
        return aggregate(o, im, q);
    if (!strcmp(q->name, "relations"))
        return relations(o, im, q);
    header(o, im, q, "unsupported_query");
    fputs(",\"reason\":\"queries: document, threads, stacks, aggregate, relations\"}\n", o);
    return 2;
}
