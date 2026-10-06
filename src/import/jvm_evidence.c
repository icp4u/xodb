#define _GNU_SOURCE 1
/* C05-R3 owned JVM evidence bundle; contract in jvm_evidence.h. */
#include "jvm_evidence_internal.h"
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct jvm_evidence {
    struct jvm_budget budget;
    char *source;
    size_t source_len;
    struct jvm_import *im;
    char *lframes;
    size_t lframes_len;
    struct xlf_doc *doc;
    size_t doc_charge;
    uint32_t *stack_record;   /* doc stack -> import record */
    uint32_t *function_frame; /* doc function -> representative import frame */
    struct jvm_evidence_usage usage;
    enum xlf_stability stability;
    _Atomic size_t query_reserved; /* C05-R4: sum of the reservations of running aggregates */
};

void jvm_evidence_default_limits(struct jvm_evidence_limits *l)
{
    *l = (struct jvm_evidence_limits){.max_total_bytes = (size_t)1 << 31, .max_frames = 4096};
    jvm_limits_default(&l->import);
    xlf_default_limits(&l->reader);
}

static enum xlf_status ev_fail(struct xlf_error *err, enum xlf_status st, size_t peak, const char *fmt, ...)
{
    *err = (struct xlf_error){.status = st, .peak_bytes = peak};
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err->message, sizeof err->message, fmt, ap);
    va_end(ap);
    return st;
}

void jvm_evidence_free(struct jvm_evidence *ev)
{
    if (!ev)
        return;
    struct jvm_budget *b = &ev->budget;
    xlf_free(ev->doc);
    jvm_bfree(b, ev->stack_record);
    jvm_bfree(b, ev->function_frame);
    jvm_bfree(b, ev->lframes);
    jvm_import_free(ev->im);
    jvm_bfree(b, ev->source);
    free(ev);
}

/* Start a phase: its peak is measured from what is live now. */
static void phase(struct jvm_evidence *ev)
{
    if (ev->budget.peak > ev->usage.whole_peak)
        ev->usage.whole_peak = ev->budget.peak;
    ev->budget.peak = ev->budget.live;
}
static size_t phase_end(struct jvm_evidence *ev)
{
    if (ev->budget.peak > ev->usage.whole_peak)
        ev->usage.whole_peak = ev->budget.peak;
    return ev->budget.peak;
}

static int parse_u64(const char *s, uint64_t *out)
{
    if (!*s)
        return -1;
    uint64_t v = 0;
    for (; *s; s++) {
        if (*s < '0' || *s > '9' || v > (UINT64_MAX - (uint64_t)(*s - '0')) / 10)
            return -1;
        v = v * 10 + (uint64_t)(*s - '0');
    }
    *out = v;
    return 0;
}
/* Records are appended in increasing source ordinal. */
static uint32_t record_by_ordinal(const struct jvm_import *im, uint64_t ordinal)
{
    uint64_t lo = 0, hi = im->record_count;
    while (lo < hi) {
        uint64_t mid = lo + (hi - lo) / 2;
        if (im->records[mid].ordinal < ordinal)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < im->record_count && im->records[lo].ordinal == ordinal ? (uint32_t)lo : UINT32_MAX;
}
static int same_identity(const struct jvm_frame *a, const struct jvm_frame *b)
{
    return a->class_name == b->class_name && a->method == b->method && a->descriptor == b->descriptor &&
           a->loader == b->loader && a->loader_type == b->loader_type && a->loader_status == b->loader_status &&
           a->module == b->module && a->module_version == b->module_version && a->raw_class == b->raw_class &&
           a->nul_escaped == b->nul_escaped;
}

/* Join the decoded document to the import by the adapter's ids and check that
 * every function's frames share one producer identity. */
static enum xlf_status build_index(struct jvm_evidence *ev, struct xlf_error *err)
{
    const struct xlf_doc *d = ev->doc;
    const struct jvm_import *im = ev->im;
    struct jvm_budget *b = &ev->budget;
    ev->stack_record = jvm_bcalloc(b, d->stack_count + 1, sizeof *ev->stack_record);
    ev->function_frame = jvm_bcalloc(b, d->function_count + 1, sizeof *ev->function_frame);
    if (!ev->stack_record || !ev->function_frame)
        return ev_fail(err, XLF_E_MEMORY, b->peak, "index: whole-operation budget exhausted");
    for (size_t i = 0; i < d->function_count; ++i)
        ev->function_frame[i] = UINT32_MAX;
    for (size_t i = 0; i < d->stack_count; ++i) {
        if (jvm_bcancelled(b))
            return ev_fail(err, XLF_E_CANCELLED, b->peak, "index: cancelled");
        const struct xlf_stack *k = &d->stacks[i];
        uint64_t ordinal;
        uint32_t r = k->id.ptr[0] == 's' && !parse_u64(k->id.ptr + 1, &ordinal) ? record_by_ordinal(im, ordinal)
                                                                               : UINT32_MAX;
        if (r == UINT32_MAX || k->frame_count > im->records[r].frame_count)
            return ev_fail(err, XLF_E_REFERENCE, b->peak, "index: stack %s has no matching import record", k->id.ptr);
        ev->stack_record[i] = r;
        for (uint32_t j = 0; j < k->frame_count; ++j) {
            uint32_t fn = d->frames[k->first_frame + j].function;
            if (fn == XLF_NONE)
                continue;
            uint32_t jf = im->stack[im->records[r].frame_start + j];
            if (ev->function_frame[fn] == UINT32_MAX)
                ev->function_frame[fn] = jf;
            else if (!same_identity(&im->frames[ev->function_frame[fn]], &im->frames[jf]))
                return ev_fail(err, XLF_E_REFERENCE, b->peak, "index: function %s joins frames of different identity",
                               d->functions[fn].id.ptr);
        }
    }
    for (size_t i = 0; i < d->function_count; ++i)
        if (ev->function_frame[i] == UINT32_MAX)
            return ev_fail(err, XLF_E_REFERENCE, b->peak, "index: function %s is never used", d->functions[i].id.ptr);
    return XLF_OK;
}

static enum xlf_status map_import(int rc, struct xlf_error *err, size_t peak, const char *phase_name,
                                  const char *message)
{
    enum xlf_status st = rc == -2 ? XLF_E_IO : rc == -3 ? XLF_E_MEMORY : rc == -4 ? XLF_E_LIMIT
                         : rc == -5 ? XLF_E_CANCELLED : XLF_E_SCHEMA;
    return ev_fail(err, st, peak, "%s: %s", phase_name, message && *message ? message : "failed");
}
/* C05-R4: a failure without a message from the importer (the
 * import object itself could not be allocated) still names its reason. */
static const char *budget_reason(const struct jvm_budget *b, const char *message)
{
    if (message && *message)
        return message;
    return b->cancelled ? "cancelled" : b->exhausted ? "whole-operation budget exhausted" : b->oom ? "out of memory" : NULL;
}

/* Shared tail: source already owned by ev. */
static enum xlf_status finish_import(struct jvm_evidence *ev, const char *label, enum jvm_source source,
                                     const struct jvm_query *q, const struct jvm_evidence_limits *limits,
                                     const struct xlf_cancel *cancel, struct xlf_error *err)
{
    struct jvm_budget *b = &ev->budget;
    int rc = jvm_import_bytes(ev->source, ev->source_len, label, source, &limits->import, b, &ev->im);
    ev->usage.import_peak = phase_end(ev);
    if (rc)
        return map_import(rc, err, ev->usage.whole_peak, "import", budget_reason(b, ev->im ? ev->im->error : NULL));

    phase(ev);
    struct jvm_query sel = {.name = "lframes"};
    if (q) {
        sel.kind = q->kind, sel.has_kind = q->has_kind;
        sel.java_tid = q->java_tid, sel.has_java_tid = q->has_java_tid;
    }
    enum xlf_status st = jvm_lframes_emit(ev->im, &sel, limits->max_frames, &ev->lframes, &ev->lframes_len, err);
    ev->usage.adapt_peak = phase_end(ev);
    if (st) {
        err->peak_bytes = ev->usage.whole_peak;
        return st;
    }
    ev->usage.lframes_bytes = ev->lframes_len + JVM_BUDGET_HEADER;
    /* Shrink the emission buffer to what is retained. */
    char *fit = jvm_brealloc(b, ev->lframes, ev->lframes_len + 1);
    if (fit)
        ev->lframes = fit;

    phase(ev);
    struct xlf_limits l = limits->reader;
    size_t left = jvm_bremaining(b);
    if (left < l.max_memory)
        l.max_memory = left;
    if (!l.max_memory)
        return ev_fail(err, XLF_E_MEMORY, ev->usage.whole_peak, "decode: whole-operation budget exhausted before decode");
    size_t live = b->live;
    ev->doc = xlf_decode(ev->lframes, ev->lframes_len, &l, cancel, err);
    size_t reader_peak = ev->doc ? ev->doc->decode_peak_bytes : err->peak_bytes;
    ev->usage.decode_peak = reader_peak;
    if (live + reader_peak > ev->usage.whole_peak)
        ev->usage.whole_peak = live + reader_peak;
    if (!ev->doc) {
        char m[sizeof err->message];
        snprintf(m, sizeof m, "decode: %.240s", err->message);
        memcpy(err->message, m, sizeof m);
        err->peak_bytes = ev->usage.whole_peak;
        return err->status;
    }
    if (jvm_bcharge(b, ev->doc->retained_bytes))
        return ev_fail(err, XLF_E_MEMORY, ev->usage.whole_peak, "decode: retained document exceeds the budget");
    ev->doc_charge = ev->doc->retained_bytes;

    phase(ev);
    st = build_index(ev, err);
    phase_end(ev);
    if (st) {
        err->peak_bytes = ev->usage.whole_peak;
        return st;
    }
    if (jvm_bcancelled(b))
        return ev_fail(err, XLF_E_CANCELLED, ev->usage.whole_peak, "index: cancelled");
    ev->usage.retained_bytes = b->live;
    ev->usage.limit = b->limit;
    return XLF_OK;
}

static struct jvm_evidence *new_bundle(const struct jvm_evidence_limits *limits, const struct xlf_cancel *cancel,
                                       uint64_t cancel_after_polls)
{
    struct jvm_evidence *ev = calloc(1, sizeof *ev);
    if (!ev)
        return NULL;
    ev->budget = (struct jvm_budget){.limit = limits->max_total_bytes, .cancel = cancel,
                                     .cancel_at_poll = cancel_after_polls};
    if (jvm_bcharge(&ev->budget, sizeof *ev)) {
        free(ev);
        return NULL;
    }
    return ev;
}

enum xlf_status jvm_evidence_import(const char *path, enum jvm_source source, const struct jvm_query *q,
                                    const struct jvm_evidence_limits *limits, const struct xlf_cancel *cancel,
                                    struct jvm_evidence **out, struct xlf_error *err)
{
    return jvm_evidence_import_test(path, source, q, limits, cancel, 0, out, err);
}
enum xlf_status jvm_evidence_import_test(const char *path, enum jvm_source source, const struct jvm_query *q,
                                         const struct jvm_evidence_limits *limits, const struct xlf_cancel *cancel,
                                         uint64_t cancel_after_polls, struct jvm_evidence **out,
                                         struct xlf_error *err)
{
    *out = NULL;
    *err = (struct xlf_error){0};
    struct jvm_evidence_limits defaults;
    if (!limits) {
        jvm_evidence_default_limits(&defaults);
        limits = &defaults;
    }
    if (cancel && xlf_cancel_requested(cancel))
        return ev_fail(err, XLF_E_CANCELLED, 0, "read: cancelled before any work");
    struct jvm_evidence *ev = new_bundle(limits, cancel, cancel_after_polls);
    if (!ev)
        return ev_fail(err, XLF_E_MEMORY, 0, "read: budget below the bundle itself");
    char message[256] = "";
    int rc = jvm_read_source_labelled(path, &ev->budget, limits->import.max_bytes, &ev->source, &ev->source_len,
                                      &ev->stability, message, sizeof message);
    if (rc) {
        phase_end(ev);
        enum xlf_status st = map_import(rc, err, ev->usage.whole_peak, "read", message);
        jvm_evidence_free(ev);
        return st;
    }
    ev->usage.source_bytes = ev->source_len + 1 + JVM_BUDGET_HEADER;
    enum xlf_status st = finish_import(ev, path, source, q, limits, cancel, err);
    if (st) {
        jvm_evidence_free(ev);
        return st;
    }
    *out = ev;
    return XLF_OK;
}

enum xlf_status jvm_evidence_import_bytes(const void *bytes, size_t length, const char *label,
                                          enum jvm_source source, const struct jvm_query *q,
                                          const struct jvm_evidence_limits *limits,
                                          const struct xlf_cancel *cancel, struct jvm_evidence **out,
                                          struct xlf_error *err)
{
    *out = NULL;
    *err = (struct xlf_error){0};
    struct jvm_evidence_limits defaults;
    if (!limits) {
        jvm_evidence_default_limits(&defaults);
        limits = &defaults;
    }
    if (cancel && xlf_cancel_requested(cancel))
        return ev_fail(err, XLF_E_CANCELLED, 0, "read: cancelled before any work");
    if (!bytes && length)
        return ev_fail(err, XLF_E_ARGUMENT, 0, "read: NULL bytes with nonzero length");
    if ((uint64_t)length > limits->import.max_bytes)
        return ev_fail(err, XLF_E_LIMIT, 0, "read: input %zu bytes exceeds byte budget %llu", length,
                       (unsigned long long)limits->import.max_bytes);
    struct jvm_evidence *ev = new_bundle(limits, cancel, 0);
    if (!ev)
        return ev_fail(err, XLF_E_MEMORY, 0, "read: budget below the bundle itself");
    ev->stability = XLF_STABILITY_CALLER;
    ev->source = length < SIZE_MAX ? jvm_balloc(&ev->budget, length + 1) : NULL;
    if (!ev->source) {
        phase_end(ev);
        enum xlf_status st = ev_fail(err, XLF_E_MEMORY, ev->usage.whole_peak,
                                     "read: whole-operation budget exhausted by the source copy");
        jvm_evidence_free(ev);
        return st;
    }
    if (length)
        memcpy(ev->source, bytes, length);
    ev->source[length] = 0;
    ev->source_len = length;
    ev->usage.source_bytes = length + 1 + JVM_BUDGET_HEADER;
    enum xlf_status st = finish_import(ev, label, source, q, limits, cancel, err);
    if (st) {
        jvm_evidence_free(ev);
        return st;
    }
    *out = ev;
    return XLF_OK;
}

const struct xlf_doc *jvm_evidence_doc(const struct jvm_evidence *ev)
{
    return ev->doc;
}
const struct jvm_import *jvm_evidence_import_state(const struct jvm_evidence *ev)
{
    return ev->im;
}
void jvm_evidence_info(const struct jvm_evidence *ev, struct jvm_evidence_info *o)
{
    const struct jvm_import *im = ev->im;
    *o = (struct jvm_evidence_info){
        .source = im->source,
        .label = im->path,
        .sha256_hex = im->sha256,
        .source_bytes = ev->source_len,
        .stability = ev->stability,
        .incomplete = im->incomplete,
        .records_scanned = im->records_scanned,
        .records = im->record_count,
        .threads = im->thread_count,
        .frames = im->frame_count,
        .has_pid = im->has_pid,
        .pid = im->pid,
        .jvm_name = jvm_str(im, im->jvm_name),
        .jvm_version = jvm_str(im, im->jvm_version),
        .runtime_version = jvm_str(im, im->runtime_version),
        .jvm_start = jvm_str(im, im->jvm_start),
        .os_version = jvm_str(im, im->os_version),
        .collected_at = jvm_str(im, im->collected_at),
        .collected_status = im->source == JVM_SOURCE_THREAD_PRINT
                                ? (im->collected_at ? (enum jvm_time_status)im->collected_status : JVM_TIME_ABSENT)
                                : (enum jvm_time_status)jvm_parse_iso_time(jvm_str(im, im->collected_at), &(int64_t){0}),
        .recording_start = jvm_str(im, im->recording_start),
        .recording_name = jvm_str(im, im->recording_name),
        .probes_installed = im->probes_installed,
        .diagnostics = im->diag,
    };
}
const uint8_t *jvm_evidence_source(const struct jvm_evidence *ev, size_t *length, const char **sha256_hex)
{
    if (length)
        *length = ev->source_len;
    if (sha256_hex)
        *sha256_hex = ev->im->sha256;
    return (const uint8_t *)ev->source;
}
const char *jvm_evidence_lframes(const struct jvm_evidence *ev, size_t *length)
{
    if (length)
        *length = ev->lframes_len;
    return ev->lframes;
}
void jvm_evidence_usage(const struct jvm_evidence *ev, struct jvm_evidence_usage *u)
{
    *u = ev->usage;
}

static void frame_fill(const struct jvm_import *im, uint32_t id, struct jvm_evidence_frame *o)
{
    const struct jvm_frame *f = &im->frames[id];
    *o = (struct jvm_evidence_frame){
        .jvm_frame = id,
        .mode = (enum jvm_frame_kind)f->kind,
        .heuristic_text = f->heuristic,
        .inlined = f->kind == JVM_FRAME_INLINED,
        .jvm_native_method = f->kind == JVM_FRAME_NATIVE_METHOD,
        .native_authority = false,
        .has_line = f->has_line,
        .has_bci = f->has_bci,
        .line = f->line,
        .bci = f->bci,
        .loader_status = (enum jvm_loader_status)f->loader_status,
        .class_name = jvm_str(im, f->class_name),
        .method = jvm_str(im, f->method),
        .descriptor = jvm_str(im, f->descriptor),
        .class_loader = jvm_str(im, f->loader),
        .class_loader_type = jvm_str(im, f->loader_type),
        .module = jvm_str(im, f->module),
        .module_version = jvm_str(im, f->module_version),
        .file = jvm_str(im, f->file),
        .raw_text = jvm_str(im, f->raw_text),
        .raw_class = jvm_str(im, f->raw_class),
        .nul_escaped = f->nul_escaped,
    };
}
/* Stack containing document frame i: the last stack starting at or before i. */
static uint32_t stack_of_frame(const struct xlf_doc *d, uint32_t i)
{
    size_t lo = 0, hi = d->stack_count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (d->stacks[mid].first_frame <= i)
            lo = mid + 1;
        else
            hi = mid;
    }
    while (lo > 0) {
        const struct xlf_stack *k = &d->stacks[lo - 1];
        if (i >= k->first_frame && i < k->first_frame + k->frame_count)
            return (uint32_t)(lo - 1);
        if (k->first_frame < i)
            break;
        lo--;
    }
    return UINT32_MAX;
}
int jvm_evidence_frame(const struct jvm_evidence *ev, uint32_t doc_frame, struct jvm_evidence_frame *out)
{
    const struct xlf_doc *d = ev->doc;
    if (doc_frame >= d->frame_count)
        return -1;
    uint32_t k = stack_of_frame(d, doc_frame);
    if (k == UINT32_MAX)
        return -1;
    const struct jvm_record *r = &ev->im->records[ev->stack_record[k]];
    frame_fill(ev->im, ev->im->stack[r->frame_start + (doc_frame - d->stacks[k].first_frame)], out);
    out->marker = d->frames[doc_frame].function == XLF_NONE;
    return 0;
}
int jvm_evidence_function(const struct jvm_evidence *ev, uint32_t doc_function, struct jvm_evidence_frame *out)
{
    if (doc_function >= ev->doc->function_count)
        return -1;
    frame_fill(ev->im, ev->function_frame[doc_function], out);
    return 0;
}
int jvm_evidence_stack(const struct jvm_evidence *ev, uint32_t doc_stack, struct jvm_evidence_stack *out)
{
    if (doc_stack >= ev->doc->stack_count)
        return -1;
    const struct jvm_import *im = ev->im;
    uint32_t ri = ev->stack_record[doc_stack];
    const struct jvm_record *r = &im->records[ri];
    *out = (struct jvm_evidence_stack){
        .record = ri,
        .ordinal = r->ordinal,
        .source_offset = r->byte_start,
        .source_length = r->byte_end > r->byte_start ? r->byte_end - r->byte_start : 0,
        .line_start = r->line_start,
        .line_end = r->line_end,
        .path = jvm_str(im, r->path),
        .time_raw = jvm_str(im, r->time_raw),
        .time_status = (enum jvm_time_status)r->time_status,
        .has_time_ns = r->has_time_ns,
        .time_ns = r->time_ns,
        .truncation = (enum jvm_truncation)r->truncated,
        .creation_count = r->creation_count,
    };
    return 0;
}
int jvm_evidence_cite(const struct jvm_evidence *ev, uint32_t doc_stack, const uint8_t **bytes, size_t *length)
{
    struct jvm_evidence_stack s;
    if (jvm_evidence_stack(ev, doc_stack, &s))
        return -1;
    if (!s.source_length || s.source_offset + s.source_length > ev->source_len)
        return -2;
    *bytes = (const uint8_t *)ev->source + s.source_offset;
    *length = (size_t)s.source_length;
    return 0;
}
int jvm_evidence_thread(const struct jvm_evidence *ev, uint32_t doc_thread, struct jvm_evidence_thread *out)
{
    const struct xlf_doc *d = ev->doc;
    const struct jvm_import *im = ev->im;
    if (doc_thread >= d->thread_count)
        return -1;
    const char *id = d->threads[doc_thread].id.ptr;
    *out = (struct jvm_evidence_thread){.what = JVM_EVIDENCE_NO_THREAD, .thread = UINT32_MAX, .record = UINT32_MAX,
                                        .is_virtual = JVM_UNKNOWN, .parent_doc_thread = XLF_NONE};
    uint64_t n;
    if (id[0] == 'c' && !parse_u64(id + 1, &n)) {
        uint32_t ri = record_by_ordinal(im, n);
        if (ri == UINT32_MAX)
            return -1;
        const struct jvm_record *r = &im->records[ri];
        out->what = JVM_EVIDENCE_COROUTINE;
        out->record = ri;
        out->coroutine_seq = r->coroutine_seq;
        out->has_parent = r->has_parent;
        out->parent_seq = r->parent_seq;
        out->parent_relation = jvm_str(im, r->parent_relation);
        out->state = jvm_str(im, r->state);
        out->thread = r->thread;
        if (r->has_parent)
            for (size_t t = 0; t < d->thread_count; ++t) {
                const char *pid = d->threads[t].id.ptr;
                uint64_t m;
                uint32_t pr;
                if (pid[0] == 'c' && !parse_u64(pid + 1, &m) && (pr = record_by_ordinal(im, m)) != UINT32_MAX &&
                    im->records[pr].coroutine_seq == r->parent_seq) {
                    out->parent_doc_thread = (uint32_t)t;
                    break;
                }
            }
    } else if (id[0] == 't' && !parse_u64(id + 1, &n) && n < im->thread_count) {
        out->what = JVM_EVIDENCE_PLATFORM_OR_VIRTUAL;
        out->thread = (uint32_t)n;
    } else if (strcmp(id, "t-unknown"))
        return -1;
    if (out->thread != UINT32_MAX) {
        const struct jvm_thread *t = &im->threads[out->thread];
        out->is_virtual = (enum jvm_tri)t->is_virtual;
        out->vm_internal = t->vm_internal;
        out->has_java_tid = t->has_java_tid, out->java_tid = t->java_tid;
        out->has_os_tid = t->has_os_tid, out->os_tid = t->os_tid;
    }
    return 0;
}
enum xlf_status jvm_evidence_aggregate(const struct jvm_evidence *ev, uint32_t thread, const struct xlf_cancel *cancel,
                                       struct xlf_aggregate *out, struct xlf_error *err)
{
    struct xlf_query_limits q;
    xlf_default_query_limits(&q);
    if (!ev->budget.limit)
        return xlf_aggregate(ev->doc, thread, &q, cancel, out, err);
    /* The bundle is immutable; only the reservation counter changes. */
    _Atomic size_t *reserved = &((struct jvm_evidence *)(uintptr_t)ev)->query_reserved;
    size_t left = ev->budget.limit - ev->budget.live, cur = atomic_load(reserved), take;
    do {
        size_t avail = cur < left ? left - cur : 0;
        take = avail < q.max_query_bytes ? avail : q.max_query_bytes;
    } while (take && !atomic_compare_exchange_weak(reserved, &cur, cur + take));
    if (!take && ev->doc->function_count) {
        *out = (struct xlf_aggregate){0};
        return ev_fail(err, XLF_E_MEMORY, 0, left ? "query: whole-operation budget reserved by concurrent queries"
                                                  : "query: whole-operation budget fully retained by the bundle");
    }
    q.max_query_bytes = take ? take : 1; /* 0 means invalid to the reader; 1 refuses any allocation */
    q.max_combined_bytes = ev->doc->retained_bytes + q.max_query_bytes;
    enum xlf_status st = xlf_aggregate(ev->doc, thread, &q, cancel, out, err);
    if (take)
        atomic_fetch_sub(reserved, take);
    return st;
}
