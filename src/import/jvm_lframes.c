#define _GNU_SOURCE 1
/* Adapter: imported JVM records -> "xodb.logical-frames" v1 draft C05-1 (JSON Lines).
 * One output document carries one record kind, so collection semantics and weight
 * units never mix. JVM-specific evidence goes in x_* members. No PCs are emitted.
 * C05-R2: the output is decoded by the shared R2 reader (src/profile/logical_frames.c,
 * contract C05-R2-1); jvm_lframes_decode composes both in one process. */
#include "jvm_import.h"
#include "logical_frames.h"
#include <stdlib.h>
#include <string.h>
/* C05-1 small JSON integers (pid, os_tid, line) are limited to 0..2^31-1. */
#define C05_SMALL_MAX 0x7fffffffLL
enum { MAX_STRING = 16000 };
static int clipped_string(FILE *o, const char *s)
{
    if (!s) {
        fputs("null", o);
        return 0;
    }
    size_t n = strlen(s);
    if (n <= MAX_STRING) {
        jvm_json_string(o, s);
        return 0;
    }
    n = MAX_STRING;
    while (n && ((unsigned char)s[n] & 0xc0) == 0x80)
        n--;
    jvm_json_string_n(o, s, n); /* C05-R3: no heap copy */
    return 1;
}
/* "cls.name+desc" clipped like clipped_string, composed on the stack. */
static int clipped_qualified(FILE *o, const char *cls, const char *name, const char *desc)
{
    if (!cls) {
        fputs("null", o);
        return 0;
    }
    char buf[MAX_STRING + 8];
    int n = snprintf(buf, sizeof buf, "%s.%s%s", cls, name ? name : "", desc ? desc : "");
    if (n < 0)
        n = 0;
    return clipped_string(o, buf) || (size_t)n >= sizeof buf;
}
static void member(FILE *o, const char *key, const char *value)
{
    fprintf(o, ",\"%s\":", key);
    clipped_string(o, value);
}
static const char *c05_kind(unsigned k)
{
    switch (k) {
    case JVM_FRAME_INTERPRETED: return "interpreter";
    case JVM_FRAME_JIT:
    case JVM_FRAME_INLINED: return "jit";
    case JVM_FRAME_NATIVE_METHOD: return "native";
    default: return "unclassified";
    }
}
static int marker(const struct jvm_frame *f)
{
    return f->kind == JVM_FRAME_UNAVAILABLE || f->kind == JVM_FRAME_COROUTINE_MARKER ||
           f->name_status == JVM_NAME_ABSENT || f->name_status == JVM_NAME_EMPTY;
}
struct fmap {
    char **keys;
    uint32_t *slots, slot_count, count, cap;
    uint32_t *of_frame; /* frame id -> function index + 1 */
    uint32_t *first_frame;
};
static uint64_t hash(const char *s)
{
    uint64_t h = 0xcbf29ce484222325ull;
    for (; *s; s++)
        h = (h ^ (unsigned char)*s) * 0x100000001b3ull;
    return h;
}
static int function_of(struct fmap *m, const struct jvm_import *im, uint32_t frame)
{
    if (m->of_frame[frame])
        return 0;
    const struct jvm_frame *f = &im->frames[frame];
    struct jvm_budget *b = im->budget;
    char kbuf[192], *key;
    /* C05-R3: identity includes every producer-supplied class identity field:
     * loader status, loader name, loader type, module and module version. Frames
     * whose loader was not exported share a function only with frames that also
     * lack it, and the function says so (x_identity_basis). */
    /* C05-R4: plus the raw exported class name (p/C and p.C are
     * different producer identities) and which strings were NUL-escaped
     * (C05-R5: a bit per field, enum jvm_nul_field). */
    int kn = snprintf(kbuf, sizeof kbuf, "%u\x1f%u\x1f%u\x1f%s\x1f%u\x1f%u\x1f%u\x1f%u\x1f%u\x1f%u\x1f%u", f->class_name,
                      f->method, f->descriptor, c05_kind(f->kind), f->loader_status, f->loader, f->loader_type,
                      f->module, f->module_version, f->raw_class, f->nul_escaped);
    if (kn < 0 || (size_t)kn >= sizeof kbuf || !(key = jvm_bstrndup(b, kbuf, (size_t)kn)))
        return -1;
    if ((m->count + 1) * 2 > m->slot_count) {
        uint32_t n = m->slot_count ? m->slot_count * 2 : 256;
        uint32_t *slots = jvm_bcalloc(b, n, sizeof(*slots));
        if (!slots) {
            jvm_bfree(b, key);
            return -1;
        }
        for (uint32_t i = 0; i < m->count; i++) {
            uint32_t k = (uint32_t)hash(m->keys[i]) & (n - 1);
            while (slots[k])
                k = (k + 1) & (n - 1);
            slots[k] = i + 1;
        }
        jvm_bfree(b, m->slots);
        m->slots = slots;
        m->slot_count = n;
    }
    uint32_t k = (uint32_t)hash(key) & (m->slot_count - 1);
    for (; m->slots[k]; k = (k + 1) & (m->slot_count - 1))
        if (!strcmp(m->keys[m->slots[k] - 1], key)) {
            jvm_bfree(b, key);
            m->of_frame[frame] = m->slots[k];
            return 0;
        }
    if (m->count == m->cap) {
        uint32_t cap = m->cap ? m->cap * 2 : 256;
        char **keys = jvm_brealloc(b, m->keys, cap * sizeof(*keys));
        if (keys)
            m->keys = keys;
        uint32_t *first = keys ? jvm_brealloc(b, m->first_frame, cap * sizeof(*first)) : NULL;
        if (!keys || !first) {
            jvm_bfree(b, key);
            return -1;
        }
        m->keys = keys;
        m->first_frame = first;
        m->cap = cap;
    }
    m->keys[m->count] = key;
    m->first_frame[m->count] = frame;
    m->slots[k] = ++m->count;
    m->of_frame[frame] = m->count;
    return 0;
}
static int wanted(const struct jvm_import *im, const struct jvm_query *q, const struct jvm_record *r)
{
    if (r->kind != q->kind)
        return 0;
    if (q->has_java_tid) {
        if (r->thread == UINT32_MAX)
            return 0;
        const struct jvm_thread *t = &im->threads[r->thread];
        return t->has_java_tid && t->java_tid == q->java_tid;
    }
    return 1;
}
unsigned jvm_lframes_kind(const struct jvm_import *im, const struct jvm_query *q);
static unsigned default_kind(enum jvm_source s);
unsigned jvm_lframes_kind(const struct jvm_import *im, const struct jvm_query *q)
{
    return q->has_kind ? q->kind : default_kind(im->source);
}
static unsigned default_kind(enum jvm_source s)
{
    switch (s) {
    case JVM_SOURCE_JFR_JSON: return JVM_EXECUTION_SAMPLE;
    case JVM_SOURCE_THREAD_DUMP_JSON: return JVM_THREAD_DUMP_STACK;
    case JVM_SOURCE_THREAD_PRINT: return JVM_THREAD_PRINT_STACK;
    case JVM_SOURCE_COROUTINE_PROBES: return JVM_COROUTINE_STACK;
    }
    return JVM_EXECUTION_SAMPLE;
}
static void header(FILE *o, const struct jvm_import *im, unsigned kind, int clock)
{
    const char *method, *trigger, *atomicity, *unit, *semantics;
    switch (kind) {
    case JVM_EXECUTION_SAMPLE:
    case JVM_NATIVE_METHOD_SAMPLE:
        method = kind == JVM_EXECUTION_SAMPLE ? "jdk.ExecutionSample" : "jdk.NativeMethodSample";
        trigger = "timer";
        atomicity = "single_thread";
        unit = "sample";
        semantics = "count of JFR thread samples; not CPU time";
        break;
    case JVM_THREAD_DUMP_STACK:
        method = "jcmd Thread.dump_to_file -format=json";
        trigger = "on_demand";
        atomicity = "per_thread_sequential";
        unit = "observation";
        semantics = "one point-in-time observation per thread; not time";
        break;
    case JVM_THREAD_PRINT_STACK:
        method = "jcmd Thread.print";
        trigger = "on_demand";
        atomicity = "all_threads_one_call";
        unit = "observation";
        semantics = "one point-in-time observation per platform thread; not time";
        break;
    case JVM_COROUTINE_STACK:
        method = "kotlinx.coroutines DebugProbesImpl.dumpCoroutinesInfo";
        trigger = "on_demand";
        atomicity = "per_thread_sequential";
        unit = "observation";
        semantics = "one observation per live coroutine at dump time; not time";
        break;
    default:
        method = jvm_kind_name(kind);
        trigger = "event";
        atomicity = "single_thread";
        unit = "event";
        semantics = "count of JFR events; not time";
    }
    int identity = im->jvm_version || im->runtime_version;
    fputs("{\"type\":\"header\",\"format\":\"xodb.logical-frames\",\"version\":1,"
          "\"draft\":\"C05-1\",\"producer\":{\"name\":\"xodb-jvm-import\",\"version\":\""
          JVM_PRODUCER_VERSION "\",\"kind\":\"report_converter\",\"sha256\":null},"
          "\"source_kind\":\"imported_report\",\"runtime\":{\"language\":\"jvm-bytecode\","
          "\"implementation\":", o);
    jvm_json_string(o, im->source == JVM_SOURCE_COROUTINE_PROBES ? "kotlinx-coroutines-on-hotspot"
                                                                 : "hotspot");
    fputs(",\"version\":", o);
    clipped_string(o, identity ? jvm_str(im, im->runtime_version ? im->runtime_version
                                                                 : im->jvm_version)
                               : "unknown");
    fputs(",\"build\":", o);
    clipped_string(o, jvm_str(im, im->jvm_version));
    fputs(",\"executable\":{\"path\":null,\"sha256\":null,\"gnu_build_id\":null,\"unavailable\":"
          "\"JVM executable identity is not exported by this source\"},\"library\":null},"
          "\"process\":{\"pid\":", o);
    int pid_ok = im->has_pid && im->pid > 0 && im->pid <= C05_SMALL_MAX;
    if (pid_ok)
        fprintf(o, "%lld", (long long)im->pid);
    else
        fputs("null", o);
    fputs(",\"start_ticks\":null,\"boot_id\":null,\"unavailable\":\"source exports no /proc "
          "start ticks or boot id; see x_jvm_start_time and the capture manifest\"", o);
    if (im->has_pid && !pid_ok) /* keep an out-of-range pid as evidence, not as identity */
        fprintf(o, ",\"x_pid_text\":\"%lld\"", (long long)im->pid);
    fputs("},", o);
    if (clock)
        fputs("\"clock\":{\"domain\":\"jfr-wallclock-utc-epoch\",\"unit\":\"ns\"},", o);
    else
        fprintf(o, "\"clock\":null,\"clock_unavailable\":\"%s\",",
                im->source == JVM_SOURCE_THREAD_PRINT
                    ? "Thread.print header is unzoned local time with second resolution"
                    : "one dump timestamp for a non-atomic walk; no per-stack time");
    fprintf(o, "\"command\":null,\"collection\":{\"method\":\"%s\",\"trigger\":\"%s\","
               "\"interval_ns\":null,\"atomicity\":\"%s\",\"notes\":",
            method, trigger, atomicity);
    jvm_json_string(o, im->source == JVM_SOURCE_JFR_JSON
                           ? "sampling period not present in jfr print --json export"
                       : im->source == JVM_SOURCE_COROUTINE_PROBES
                           ? "debug probes installed by -javaagent; adds instrumentation overhead"
                           : NULL);
    fprintf(o, "},\"frame_order\":\"innermost_first\",\"weight_unit\":\"%s\","
               "\"weight_semantics\":\"%s\",\"x_source\":{\"format\":\"%s\",\"sha256\":\"%s\","
               "\"bytes\":\"%llu\",\"import_status\":\"%s\",\"jfr_export_stack_depth\":%u}",
            unit, semantics, jvm_source_name(im->source), im->sha256,
            (unsigned long long)im->bytes, im->incomplete ? "incomplete" : "complete",
            im->limits.jfr_export_depth);
    member(o, "x_jvm_start_time", jvm_str(im, im->jvm_start));
    member(o, "x_collected_at", jvm_str(im, im->collected_at));
    if (clock)
        fputs(",\"x_clock_conversion\":\"jfr print --json renders JFR ticks as zoned ISO-8601 "
              "wall time with ns digits; converted exactly to UTC epoch ns\","
              "\"x_clock_relation\":\"wall clock; not CLOCK_MONOTONIC or perf time; no mapping declared\"", o);
    fputs("}\n", o);
}
static void thread_record(FILE *o, const struct jvm_import *im, uint32_t id)
{
    const struct jvm_thread *t = &im->threads[id];
    fprintf(o, "{\"type\":\"thread\",\"id\":\"t%u\",\"language_id\":", id);
    if (t->has_java_tid)
        fprintf(o, "\"java_thread_id:%lld\"", (long long)t->java_tid);
    else
        fputs("null", o);
    fputs(",\"name\":", o);
    int clipped = clipped_string(o, t->name_count ? jvm_str(im, t->names[0]) : NULL);
    if (t->has_os_tid && t->os_tid > 0 && t->os_tid <= C05_SMALL_MAX)
        fprintf(o, ",\"os_tid\":%lld,\"os_tid_source\":\"%s\"", (long long)t->os_tid,
                im->source == JVM_SOURCE_JFR_JSON ? "jfr osThreadId" : "Thread.print [tid]/nid");
    else if (t->has_os_tid && t->os_tid > 0)
        fprintf(o, ",\"os_tid\":null,\"os_tid_reason\":\"OS TID outside the C05-1 range\","
                   "\"x_os_tid_text\":\"%lld\"", (long long)t->os_tid);
    else
        fprintf(o, ",\"os_tid\":null,\"os_tid_reason\":\"%s\"",
                t->is_virtual == JVM_YES ? "virtual thread has no fixed OS thread"
                                         : "not exported by source");
    fprintf(o, ",\"x_virtual\":%s,\"x_vm_internal\":%s",
            t->is_virtual == JVM_YES ? "true" : t->is_virtual == JVM_NO ? "false" : "null",
            t->vm_internal ? "true" : "false");
    member(o, "x_vm_thread_address", jvm_str(im, t->vm_address));
    if (t->name_count > 1) {
        fputs(",\"x_names\":[", o);
        for (uint32_t i = 0; i < t->name_count; i++) {
            if (i)
                fputc(',', o);
            clipped |= clipped_string(o, jvm_str(im, t->names[i]));
        }
        fputc(']', o);
    }
    if (clipped)
        fputs(",\"x_clipped\":true", o);
    fputs("}\n", o);
}
static void coroutine_thread(FILE *o, const struct jvm_import *im, const struct jvm_record *r)
{
    fprintf(o, "{\"type\":\"thread\",\"id\":\"c%llu\",\"language_id\":\"kotlinx-coroutine:%lld\","
               "\"name\":",
            (unsigned long long)r->ordinal, (long long)r->coroutine_seq);
    clipped_string(o, jvm_str(im, r->detail));
    fputs(",\"os_tid\":null,\"os_tid_reason\":\"a coroutine is not an OS thread; see "
          "x_last_thread\"", o);
    member(o, "x_state", jvm_str(im, r->state));
    member(o, "x_parent_relation", jvm_str(im, r->parent_relation));
    if (r->has_parent)
        fprintf(o, ",\"x_parent_sequence\":\"%lld\"", (long long)r->parent_seq);
    if (r->thread != UINT32_MAX) {
        const struct jvm_thread *t = &im->threads[r->thread];
        fputs(",\"x_last_thread\":{\"java_thread_id\":", o);
        if (t->has_java_tid)
            fprintf(o, "\"%lld\"", (long long)t->java_tid);
        else
            fputs("null", o);
        member(o, "name", jvm_str(im, r->name));
        fputc('}', o);
    } else
        fputs(",\"x_last_thread\":null", o);
    fputs("}\n", o);
}
static void function_record(FILE *o, const struct jvm_import *im, const struct fmap *m, uint32_t i)
{
    const struct jvm_frame *f = &im->frames[m->first_frame[i]];
    fprintf(o, "{\"type\":\"function\",\"id\":\"f%u\",\"name\":", i);
    const char *name = jvm_str(im, f->method), *cls = jvm_str(im, f->class_name);
    const char *desc = jvm_str(im, f->descriptor);
    int clipped = clipped_string(o, name ? name : "");
    fputs(",\"qualified\":", o);
    clipped |= clipped_qualified(o, cls, name, desc);
    fprintf(o, ",\"code\":null,\"first_line\":null,\"frame_kind\":\"%s\",\"runtime_id\":null",
            c05_kind(f->kind));
    member(o, "x_class", cls);
    member(o, "x_descriptor", desc);
    member(o, "x_module", jvm_str(im, f->module));
    member(o, "x_class_loader", jvm_str(im, f->loader));
    member(o, "x_class_loader_type", jvm_str(im, f->loader_type));
    member(o, "x_module_version", jvm_str(im, f->module_version));
    fprintf(o, ",\"x_identity_basis\":\"%s\"", jvm_loader_status_name(f->loader_status));
    if (f->raw_class && f->raw_class != f->class_name)
        member(o, "x_raw_class", jvm_str(im, f->raw_class));
    if (f->nul_escaped) {
        /* C05-R5: which fields were escaped (part of the identity). */
        static const char *const field[] = {"class", "method", "descriptor", "class_loader",
                                            "class_loader_type", "module", "module_version"};
        fputs(",\"x_nul_escaped\":true,\"x_nul_escaped_fields\":[", o);
        for (unsigned i = 0, n = 0; i < sizeof field / sizeof field[0]; i++)
            if (f->nul_escaped & 1u << i)
                fprintf(o, "%s\"%s\"", n++ ? "," : "", field[i]);
        fputc(']', o);
    }
    if (f->name_status != JVM_NAME_OK)
        fprintf(o, ",\"x_name_status\":\"%s\"",
                f->name_status == JVM_NAME_EMPTY ? "empty" : "invalid_jvm_name");
    if (f->hidden == JVM_YES)
        fputs(",\"x_hidden\":true", o);
    if (clipped)
        fputs(",\"x_clipped\":true", o);
    fputs("}\n", o);
}
static void frames(FILE *o, const struct jvm_import *im, const struct fmap *m, uint32_t start,
                   uint32_t count)
{
    fputc('[', o);
    for (uint32_t i = 0; i < count; i++) {
        uint32_t id = im->stack[start + i];
        const struct jvm_frame *f = &im->frames[id];
        if (i)
            fputc(',', o);
        if (marker(f)) {
            fputs("{\"function\":null,\"kind\":\"unknown\",\"line\":null,\"provenance\":\"runtime\","
                  "\"label\":", o);
            int unnamed = f->kind != JVM_FRAME_COROUTINE_MARKER && f->name_status == JVM_NAME_EMPTY;
            clipped_string(o, f->kind == JVM_FRAME_COROUTINE_MARKER ? jvm_str(im, f->raw_text)
                              : unnamed                             ? "unnamed method"
                                                                    : "unavailable frame");
            fprintf(o, ",\"reason\":\"%s\"", f->kind == JVM_FRAME_COROUTINE_MARKER
                                                 ? "kotlinx coroutine debug marker frame"
                                             : unnamed ? "source exported an empty method name"
                                                       : "malformed frame record kept in position");
            if (unnamed) {
                member(o, "x_class", jvm_str(im, f->class_name));
                member(o, "x_execution_mode", jvm_frame_kind_name(f->kind));
            }
            if (f->heuristic)
                fputs(",\"x_parse\":\"heuristic_text\"", o);
            fputc('}', o);
            continue;
        }
        fprintf(o, "{\"function\":\"f%u\",\"kind\":\"%s\",", m->of_frame[id] - 1, c05_kind(f->kind));
        if (f->has_line && f->line >= 0 && f->line <= C05_SMALL_MAX)
            fprintf(o, "\"line\":%lld,\"provenance\":\"runtime\"", (long long)f->line);
        else if (f->has_line)
            fprintf(o, "\"line\":null,\"provenance\":\"runtime\",\"reason\":\"exported line outside "
                       "the C05-1 range\",\"x_line_text\":\"%lld\"", (long long)f->line);
        else
            fputs("\"line\":null,\"provenance\":\"runtime\",\"reason\":\"no line exported for "
                  "this frame\"", o);
        if (f->has_bci && f->bci >= 0 && f->bci <= C05_SMALL_MAX)
            fprintf(o, ",\"x_bci\":%lld", (long long)f->bci);
        else if (f->has_bci)
            fprintf(o, ",\"x_bci_text\":\"%lld\"", (long long)f->bci);
        if (f->heuristic)
            fputs(",\"x_parse\":\"heuristic_text\"", o);
        if (f->kind == JVM_FRAME_INLINED)
            fputs(",\"x_inlined\":true", o);
        if (f->kind == JVM_FRAME_NATIVE_METHOD)
            fputs(",\"x_jvm_native_method\":true", o);
        if (f->kind == JVM_FRAME_UNSPECIFIED)
            fputs(",\"x_execution_mode\":\"not exported\"", o);
        if (f->file)
            member(o, "x_file", jvm_str(im, f->file));
        fputc('}', o);
    }
    fputc(']', o);
}
int jvm_lframes_write(FILE *o, const struct jvm_import *im, const struct jvm_query *q0,
                      uint32_t max_frames)
{
    struct jvm_query q = *q0;
    if (!q.has_kind)
        q.kind = default_kind(im->source);
    if (q.kind == JVM_COROUTINE_STACK ? im->source != JVM_SOURCE_COROUTINE_PROBES
                                      : im->source == JVM_SOURCE_COROUTINE_PROBES)
        return 2;
    struct jvm_budget *b = im->budget;
    struct fmap m = {0};
    m.of_frame = jvm_bcalloc(b, (size_t)im->frame_count + 1, sizeof(*m.of_frame));
    uint8_t *threads = jvm_bcalloc(b, (size_t)im->thread_count + 1, 1);
    if (!m.of_frame || !threads) {
        jvm_bfree(b, m.of_frame);
        jvm_bfree(b, threads);
        return -1;
    }
    uint64_t selected = 0;
    int unknown_thread = 0, rc = 0;
    for (uint64_t i = 0; i < im->record_count && !rc; i++) {
        const struct jvm_record *r = &im->records[i];
        if (jvm_bcancelled(b)) { /* C05-R3 */
            rc = -1;
            break;
        }
        if (!wanted(im, &q, r))
            continue;
        selected++;
        if (r->kind != JVM_COROUTINE_STACK) {
            if (r->thread == UINT32_MAX)
                unknown_thread = 1;
            else
                threads[r->thread] = 1;
        }
        uint32_t n = r->frame_count < max_frames ? r->frame_count : max_frames;
        for (uint32_t k = 0; k < n && !rc; k++)
            if (!marker(&im->frames[im->stack[r->frame_start + k]]))
                rc = function_of(&m, im, im->stack[r->frame_start + k]);
    }
    int clock = im->source == JVM_SOURCE_JFR_JSON;
    uint64_t lines = 0, acquisitions = 0, stacks = 0;
    if (!rc) {
        header(o, im, q.kind, clock);
        lines++;
        for (uint32_t i = 0; i < m.count; i++, lines++)
            function_record(o, im, &m, i);
        for (uint32_t i = 0; i < im->thread_count; i++)
            if (threads[i]) {
                thread_record(o, im, i);
                lines++;
            }
        if (unknown_thread) {
            fputs("{\"type\":\"thread\",\"id\":\"t-unknown\",\"language_id\":null,\"name\":null,"
                  "\"os_tid\":null,\"os_tid_reason\":\"record carried no thread\"}\n", o);
            lines++;
        }
        int one_acquisition = im->source != JVM_SOURCE_JFR_JSON;
        if (one_acquisition && selected) {
            fprintf(o, "{\"type\":\"acquisition\",\"seq\":1,\"start_ns\":null,\"end_ns\":null,"
                       "\"stacks\":%llu}\n", (unsigned long long)selected);
            lines++;
            acquisitions++;
        }
        for (uint64_t i = 0; i < im->record_count; i++) {
            const struct jvm_record *r = &im->records[i];
            if (jvm_bcancelled(b)) { /* C05-R3 */
                rc = -1;
                break;
            }
            if (!wanted(im, &q, r))
                continue;
            if (r->kind == JVM_COROUTINE_STACK) {
                coroutine_thread(o, im, r);
                lines++;
            }
            int timed = clock && r->has_time_ns && r->time_ns >= 0;
            if (!one_acquisition) {
                acquisitions++;
                if (timed)
                    fprintf(o, "{\"type\":\"acquisition\",\"seq\":%llu,\"start_ns\":\"%lld\","
                               "\"end_ns\":\"%lld\",\"stacks\":1}\n",
                            (unsigned long long)acquisitions, (long long)r->time_ns,
                            (long long)r->time_ns);
                else
                    fprintf(o, "{\"type\":\"acquisition\",\"seq\":%llu,\"start_ns\":null,"
                               "\"end_ns\":null,\"stacks\":1}\n",
                            (unsigned long long)acquisitions);
                lines++;
            }
            fprintf(o, "{\"type\":\"stack\",\"id\":\"s%llu\",\"acquisition\":%llu,\"thread\":",
                    (unsigned long long)r->ordinal,
                    (unsigned long long)(one_acquisition ? 1 : acquisitions));
            if (r->kind == JVM_COROUTINE_STACK)
                fprintf(o, "\"c%llu\"", (unsigned long long)r->ordinal);
            else if (r->thread == UINT32_MAX)
                fputs("\"t-unknown\"", o);
            else
                fprintf(o, "\"t%u\"", r->thread);
            if (timed)
                fprintf(o, ",\"start_ns\":\"%lld\",\"end_ns\":\"%lld\"", (long long)r->time_ns,
                        (long long)r->time_ns);
            else
                fputs(",\"start_ns\":null,\"end_ns\":null", o);
            const char *trigger = r->kind <= JVM_NATIVE_METHOD_SAMPLE ? "timer"
                                  : r->kind <= JVM_ERROR_THROW        ? "exception"
                                  : r->kind <= JVM_VIRTUAL_THREAD_END ? "thread_lifecycle"
                                                                      : "on_demand";
            uint32_t n = r->frame_count < max_frames ? r->frame_count : max_frames;
            const char *state = "complete", *reason = NULL;
            if (n < r->frame_count) {
                state = "truncated";
                reason = "adapter frame limit for the C05-1 reader";
            } else if (r->truncated == JVM_TRUNC_SOURCE) {
                state = "truncated";
                reason = "JFR stack depth limit (truncated flag set by the JVM)";
            } else if (r->truncated == JVM_TRUNC_IMPORTER) {
                state = "truncated";
                reason = "importer max_stack_frames budget";
            } else if (r->truncated == JVM_TRUNC_EXPORT) {
                state = "partial";
                reason = "stack reached the declared jfr print --stack-depth, or none was declared";
            } else if (r->truncated == JVM_TRUNC_UNREPORTED) {
                state = "partial";
                reason = "source does not report whether the stack was truncated";
            } else if (!n) {
                state = "partial";
                reason = "no Java frames exported for this record";
            }
            fprintf(o, ",\"trigger\":\"%s\",\"weight\":\"1\",\"state\":\"%s\",\"omitted\":", trigger,
                    state);
            if (n < r->frame_count || r->truncated == JVM_TRUNC_IMPORTER)
                fprintf(o, "\"%llu\"", (unsigned long long)(r->frame_count - n) + r->dropped);
            else
                fputs("null", o);
            fputs(",\"reason\":", o);
            jvm_json_string(o, reason);
            if (r->kind == JVM_EXCEPTION_THROW || r->kind == JVM_ERROR_THROW) {
                fputs(",\"exception\":{\"type\":", o);
                clipped_string(o, jvm_str(im, r->detail) ? jvm_str(im, r->detail) : "unknown");
                fputs(",\"message\":", o);
                clipped_string(o, jvm_str(im, r->detail2));
                fputc('}', o);
            }
            fputs(",\"frames\":", o);
            frames(o, im, &m, r->frame_start, n);
            fprintf(o, ",\"x_citation\":{\"source_sha256\":\"%s\",\"ordinal\":\"%llu\"", im->sha256,
                    (unsigned long long)r->ordinal);
            if (im->source == JVM_SOURCE_JFR_JSON)
                fprintf(o, ",\"path\":\"recording.events[%llu]\"", (unsigned long long)r->ordinal);
            else if (r->path)
                member(o, "path", jvm_str(im, r->path));
            if (im->source == JVM_SOURCE_THREAD_PRINT)
                fprintf(o, ",\"lines\":\"%llu-%llu\"", (unsigned long long)r->line_start,
                        (unsigned long long)r->line_end);
            fputc('}', o);
            member(o, "x_thread_state", jvm_str(im, r->state));
            member(o, "x_time_raw", jvm_str(im, r->time_raw));
            /* C05-R3: why a stack has no time, never a wrapped or invented value. */
            if (r->time_status != JVM_TIME_OK)
                fprintf(o, ",\"x_time_status\":\"%s\"", jvm_time_status_name(r->time_status));
            else if (clock && !timed)
                fputs(",\"x_time_status\":\"before_unix_epoch_not_representable_in_c05\"", o);
            if (r->kind == JVM_COROUTINE_STACK) {
                fputs(",\"x_creation_frames\":[", o); /* creation context, not callers */
                for (uint32_t k = 0; k < r->creation_count && k < max_frames; k++) {
                    const struct jvm_frame *f = &im->frames[im->stack[r->creation_start + k]];
                    if (k)
                        fputc(',', o);
                    clipped_string(o, jvm_str(im, f->raw_text) ? jvm_str(im, f->raw_text) : "");
                }
                fputc(']', o);
                if (r->creation_count > max_frames)
                    fprintf(o, ",\"x_creation_frames_omitted\":\"%llu\"",
                            (unsigned long long)(r->creation_count - max_frames));
            }
            fputs("}\n", o);
            lines++;
            stacks++;
        }
        if (!rc)
            fprintf(o, "{\"type\":\"end\",\"records\":%llu,\"acquisitions\":%llu,\"stacks\":%llu,"
                   "\"status\":\"%s\"}\n",
                (unsigned long long)lines, (unsigned long long)acquisitions,
                (unsigned long long)stacks, im->incomplete ? "interrupted" : "complete");
    }
    for (uint32_t i = 0; i < m.count; i++)
        jvm_bfree(b, m.keys[i]);
    jvm_bfree(b, m.keys);
    jvm_bfree(b, m.slots);
    jvm_bfree(b, m.first_frame);
    jvm_bfree(b, m.of_frame);
    jvm_bfree(b, threads);
    if (!rc && ferror(o))
        rc = -1;
    return rc ? -1 : selected ? 0 : 1;
}

/* C05-R3: unbuffered stdio sink into a budgeted buffer. stdio's own FILE object
 * (fopencookie) is a fixed allocation outside the budget; nothing grows there. */
struct sink {
    struct jvm_budget *b;
    char *buf;
    size_t len, cap, since_poll;
};
static ssize_t sink_write(void *cookie, const char *p, size_t n)
{
    struct sink *k = cookie;
    if (n > SIZE_MAX / 2 - k->len - 1)
        return -1;
    if (k->len + n + 1 > k->cap) {
        size_t cap = k->cap ? k->cap : 65536;
        while (cap < k->len + n + 1)
            cap *= 2;
        char *q = jvm_brealloc(k->b, k->buf, cap);
        if (!q)
            return -1;
        k->buf = q;
        k->cap = cap;
    }
    memcpy(k->buf + k->len, p, n);
    k->len += n;
    k->buf[k->len] = 0;
    if ((k->since_poll += n) >= 65536) {
        k->since_poll = 0;
        if (jvm_bcancelled(k->b))
            return -1;
    }
    return (ssize_t)n;
}
static enum xlf_status adapt_fail(struct xlf_error *err, struct jvm_budget *b, int rc)
{
    *err = (struct xlf_error){.peak_bytes = b->peak};
    const char *what;
    if (b->cancelled)
        err->status = XLF_E_CANCELLED, what = "cancelled during adaptation";
    else if (b->exhausted)
        err->status = XLF_E_MEMORY, what = "whole-operation budget exhausted during adaptation";
    else if (rc == 1)
        err->status = XLF_E_EMPTY, what = "no record selected";
    else if (rc == 2)
        err->status = XLF_E_ARGUMENT, what = "record kind does not match this source";
    else
        err->status = XLF_E_MEMORY, what = "write failed (out of memory)";
    snprintf(err->message, sizeof err->message, "adapt: %s", what);
    return err->status;
}
enum xlf_status jvm_lframes_emit(const struct jvm_import *im, const struct jvm_query *q, uint32_t max_frames,
                                 char **text, size_t *length, struct xlf_error *err)
{
    *text = NULL;
    *length = 0;
    *err = (struct xlf_error){0};
    struct jvm_budget *b = im->budget;
    if (jvm_bcancelled(b))
        return adapt_fail(err, b, -1);
    struct sink k = {.b = b};
    FILE *o = fopencookie(&k, "w", (cookie_io_functions_t){.write = sink_write});
    if (!o)
        return adapt_fail(err, b, -1);
    setvbuf(o, NULL, _IONBF, 0);
    int rc = jvm_lframes_write(o, im, q, max_frames);
    if (fclose(o) && !rc)
        rc = -1;
    if (rc || b->cancelled || b->exhausted || b->oom) {
        jvm_bfree(b, k.buf);
        return adapt_fail(err, b, rc ? rc : -1);
    }
    *text = k.buf;
    *length = k.len;
    return XLF_OK;
}
enum xlf_status jvm_lframes_decode(const struct jvm_import *im, const struct jvm_query *q, uint32_t max_frames,
                                   const struct xlf_limits *limits, const struct xlf_cancel *cancel,
                                   struct xlf_doc **out, struct xlf_error *err)
{
    *out = NULL;
    struct jvm_budget *b = im->budget;
    const struct xlf_cancel *saved = b->cancel;
    if (cancel)
        b->cancel = cancel; /* poll the caller's object during adaptation too */
    char *text;
    size_t size;
    enum xlf_status st = jvm_lframes_emit(im, q, max_frames, &text, &size, err);
    b->cancel = saved;
    if (st)
        return st;
    /* The reader's own budget is capped by what the whole operation has left. */
    struct xlf_limits l;
    if (limits)
        l = *limits;
    else
        xlf_default_limits(&l);
    if (jvm_bremaining(b) < l.max_memory)
        l.max_memory = jvm_bremaining(b);
    *out = l.max_memory ? xlf_decode(text, size, &l, cancel, err) : NULL;
    if (!l.max_memory) {
        *err = (struct xlf_error){.status = XLF_E_MEMORY};
        snprintf(err->message, sizeof err->message, "decode: whole-operation budget exhausted before decode");
    }
    jvm_bfree(b, text);
    return *out ? XLF_OK : err->status;
}
