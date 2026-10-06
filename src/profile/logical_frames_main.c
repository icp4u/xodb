/* xodb-lframes: validate and query "xodb.logical-frames" v1 (draft C05-1).
 * Output is JSON. Logical frames are never merged with native stacks here. */
#define _GNU_SOURCE 1
#include "logical_frames.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

static void js(const char *p, size_t n)
{
    putchar('"');
    for (size_t i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)p[i];
        if (c == '"' || c == '\\')
            printf("\\%c", c);
        else if (c == '\n')
            fputs("\\n", stdout);
        else if (c < 0x20)
            printf("\\u%04x", c);
        else
            putchar(c);
    }
    putchar('"');
}
static void jstr(struct xlf_str v)
{
    if (v.ptr)
        js(v.ptr, v.len);
    else
        fputs("null", stdout);
}
static void jcite(struct xlf_cite c)
{
    printf("{\"line\":%llu,\"offset\":%llu,\"length\":%llu}", (unsigned long long)c.line,
           (unsigned long long)c.offset, (unsigned long long)c.length);
}
static void jopt(struct xlf_opt_u64 v)
{
    if (v.known)
        printf("\"%llu\"", (unsigned long long)v.value);
    else
        fputs("null", stdout);
}

static void jcount(struct xlf_count c)
{
    char buf[40];
    xlf_count_format(c, buf);
    printf("\"%s\"", buf);
}

static const char *const warning_names[] = {"no_end_record",   "truncated_tail", "producer_interrupted",
                                            "os_tid_shared",   "acquisition_incomplete", "loss_records",
                                            "partial_stacks",  "code_path_reused", "address_reuse_ambiguous",
                                            "no_clock"};

static void summary(const struct xlf_doc *d, const char *path)
{
    const struct xlf_header *h = &d->header;
    fputs("{\"status\":\"ok\",\"format\":\"" XLF_FORMAT "\",\"version\":1,\"draft\":\"" XLF_DRAFT
          "\",\"contract\":\"" XLF_CONTRACT "\",\"input\":", stdout);
    js(path, strlen(path));
    printf(",\"input_sha256\":\"%s\",\"input_bytes\":%llu,\"records\":%llu,\"complete\":%s", d->sha256_hex,
           (unsigned long long)d->input_bytes, (unsigned long long)d->records,
           d->ended && !(d->warnings & XLF_W_INCOMPLETE) ? "true" : "false");
    fputs(",\"end_status\":", stdout);
    jstr(d->end_status);
    fputs(",\"warnings\":[", stdout);
    bool first = true;
    for (unsigned i = 0; i < sizeof warning_names / sizeof *warning_names; ++i)
        if (d->warnings & (1u << i)) {
            printf("%s\"%s\"", first ? "" : ",", warning_names[i]);
            first = false;
        }
    fputs("]", stdout);
    if (d->warnings & XLF_W_TRUNCATED_TAIL) {
        fputs(",\"truncated_tail\":", stdout);
        jcite(d->truncated_tail);
    }
    fputs(",\"producer\":{\"name\":", stdout);
    jstr(h->producer_name);
    fputs(",\"version\":", stdout);
    jstr(h->producer_version);
    fputs(",\"kind\":", stdout);
    jstr(h->producer_kind);
    fputs("},\"source_kind\":", stdout);
    jstr(h->source_kind);
    fputs(",\"runtime\":{\"language\":", stdout);
    jstr(h->language);
    fputs(",\"implementation\":", stdout);
    jstr(h->implementation);
    fputs(",\"version\":", stdout);
    jstr(h->runtime_version);
    fputs(",\"executable_sha256\":", stdout);
    jstr(h->executable_sha256);
    fputs(",\"library_sha256\":", stdout);
    jstr(h->library_sha256);
    printf("},\"process\":{\"pid\":%lld,\"start_ticks\":", (long long)h->pid);
    jopt(h->start_ticks);
    fputs(",\"boot_id\":", stdout);
    jstr(h->boot_id);
    fputs("},\"clock\":", stdout);
    jstr(h->clock_domain);
    fputs(",\"collection\":{\"method\":", stdout);
    jstr(h->method);
    fputs(",\"atomicity\":", stdout);
    jstr(h->atomicity);
    fputs(",\"interval_ns\":", stdout);
    jopt(h->interval_ns);
    fputs("},\"weight_unit\":", stdout);
    jstr(h->weight_unit);
    uint64_t partial = 0, frames_with_pc = 0, markers = 0;
    size_t max_depth = 0;
    for (size_t i = 0; i < d->stack_count; ++i) {
        if (d->stacks[i].state != XLF_STACK_COMPLETE)
            partial++;
        if (d->stacks[i].frame_count > max_depth)
            max_depth = d->stacks[i].frame_count;
    }
    for (size_t i = 0; i < d->frame_count; ++i) {
        frames_with_pc += d->frames[i].has_pc;
        markers += d->frames[i].function == XLF_NONE;
    }
    printf(",\"counts\":{\"codes\":%zu,\"functions\":%zu,\"threads\":%zu,\"acquisitions\":%zu,\"stacks\":%zu,"
           "\"frames\":%zu,\"marker_frames\":%llu,\"frames_with_native_pc\":%llu,\"partial_stacks\":%llu,"
           "\"max_depth\":%zu,\"total_weight\":",
           d->code_count, d->function_count, d->thread_count, d->acquisition_count, d->stack_count,
           d->frame_count, (unsigned long long)markers, (unsigned long long)frames_with_pc,
           (unsigned long long)partial, max_depth);
    jcount(d->total_weight);
    fputs(",\"lost\":", stdout);
    jcount(d->lost);
    printf(",\"loss_records\":%zu}", d->loss_count);
}

static void budget(const struct xlf_doc *d, const struct xlf_limits *l)
{
    printf("\"budget\":{\"max_memory\":%zu,\"decode_peak_bytes\":%zu,\"retained_bytes\":%zu,\"input_charged\":%s",
           l->max_memory, d->decode_peak_bytes, d->retained_bytes, d->input_charged ? "true" : "false");
}

static void threads(const struct xlf_doc *d)
{
    printf("{\"input_sha256\":\"%s\",\"threads\":[", d->sha256_hex);
    for (size_t i = 0; i < d->thread_count; ++i) {
        const struct xlf_thread *t = &d->threads[i];
        uint64_t stacks = 0;
        for (size_t k = 0; k < d->stack_count; ++k)
            stacks += d->stacks[k].thread == i;
        printf("%s{\"id\":", i ? "," : "");
        jstr(t->id);
        fputs(",\"name\":", stdout);
        jstr(t->name);
        fputs(",\"language_id\":", stdout);
        jstr(t->language_id);
        if (t->os_tid > 0)
            printf(",\"os_tid\":%lld", (long long)t->os_tid);
        else
            fputs(",\"os_tid\":null", stdout);
        fputs(",\"os_tid_source\":", stdout);
        jstr(t->os_tid_source);
        fputs(",\"os_tid_reason\":", stdout);
        jstr(t->os_tid_reason);
        printf(",\"os_tid_shared\":%s,\"stacks\":%llu,\"source\":", t->os_tid_shared ? "true" : "false",
               (unsigned long long)stacks);
        jcite(t->cite);
        putchar('}');
    }
    puts("]}");
}

static const char *fn_label(const struct xlf_doc *d, const struct xlf_frame *f)
{
    if (f->function == XLF_NONE)
        return f->label.ptr;
    const struct xlf_function *fn = &d->functions[f->function];
    return fn->qualified.ptr ? fn->qualified.ptr : fn->name.ptr;
}

static void frame_json(const struct xlf_doc *d, const struct xlf_frame *f, uint32_t depth)
{
    printf("{\"depth\":%u,\"kind\":\"%s\",\"provenance\":\"%s\",\"label\":", depth, xlf_kind_name(f->kind),
           xlf_provenance_name(f->provenance));
    const char *label = fn_label(d, f);
    js(label, strlen(label));
    if (f->function != XLF_NONE) {
        const struct xlf_function *fn = &d->functions[f->function];
        fputs(",\"function\":", stdout);
        jstr(fn->id);
        if (fn->code != XLF_NONE) {
            fputs(",\"path\":", stdout);
            jstr(d->codes[fn->code].path);
            fputs(",\"code_sha256\":", stdout);
            jstr(d->codes[fn->code].sha256);
        }
    }
    if (f->line >= 0)
        printf(",\"line\":%lld", (long long)f->line);
    else
        fputs(",\"line\":null", stdout);
    if (f->reason.ptr) {
        fputs(",\"reason\":", stdout);
        jstr(f->reason);
    }
    if (f->has_pc)
        printf(",\"pc\":\"0x%llx\"", (unsigned long long)f->pc);
    putchar('}');
}

static void stacks(const struct xlf_doc *d, uint32_t thread, size_t limit)
{
    printf("{\"input_sha256\":\"%s\",\"frame_order\":\"innermost_first\",\"stacks\":[", d->sha256_hex);
    size_t shown = 0, matched = 0;
    for (size_t i = 0; i < d->stack_count; ++i) {
        const struct xlf_stack *k = &d->stacks[i];
        if (thread != XLF_NONE && k->thread != thread)
            continue;
        if (matched++ >= limit)
            continue;
        printf("%s{\"id\":", shown++ ? "," : "");
        jstr(k->id);
        printf(",\"acquisition\":%llu,\"thread\":", (unsigned long long)d->acquisitions[k->acquisition].seq);
        jstr(d->threads[k->thread].id);
        fputs(",\"thread_name\":", stdout);
        jstr(d->threads[k->thread].name);
        fputs(",\"start_ns\":", stdout);
        jopt(k->start_ns);
        fputs(",\"end_ns\":", stdout);
        jopt(k->end_ns);
        fputs(",\"trigger\":", stdout);
        jstr(k->trigger);
        printf(",\"weight\":\"%llu\",\"state\":\"%s\",\"omitted\":", (unsigned long long)k->weight,
               xlf_state_name(k->state));
        jopt(k->omitted);
        fputs(",\"reason\":", stdout);
        jstr(k->reason);
        fputs(",\"exception\":", stdout);
        jstr(k->exception_type);
        fputs(",\"source\":", stdout);
        jcite(k->cite);
        fputs(",\"frames\":[", stdout);
        for (uint32_t j = 0; j < k->frame_count; ++j) {
            if (j)
                putchar(',');
            frame_json(d, &d->frames[k->first_frame + j], j);
        }
        fputs("]}", stdout);
    }
    printf("],\"matched\":%zu,\"shown\":%zu,\"incomplete_listing\":%s}\n", matched, shown,
           shown < matched ? "true" : "false");
}

struct row {
    uint32_t function;
    struct xlf_count self, inclusive;
};
static int by_inclusive(const void *a, const void *b)
{
    const struct row *x = a, *y = b;
    int c = xlf_count_cmp(y->inclusive, x->inclusive);
    if (!c)
        c = xlf_count_cmp(y->self, x->self);
    if (!c)
        c = x->function < y->function ? -1 : x->function > y->function;
    return c;
}
static void query_error(const struct xlf_error *err)
{
    printf("{\"status\":\"error\",\"phase\":\"query\",\"error\":\"%s\",\"peak_bytes\":%zu,\"message\":",
           xlf_status_name(err->status), err->peak_bytes);
    js(err->message, strlen(err->message));
    puts("}");
}
static int aggregate(const struct xlf_doc *d, const struct xlf_limits *l, const struct xlf_query_limits *ql,
                     const struct xlf_cancel *cancel, uint32_t thread, size_t top)
{
    struct xlf_aggregate a;
    struct xlf_error err;
    if (xlf_aggregate(d, thread, ql, cancel, &a, &err)) {
        query_error(&err);
        return 2;
    }
    /* Presentation rows (CLI only): one per function with nonzero inclusive weight. */
    struct row *rows = calloc(d->function_count + 1, sizeof *rows);
    if (!rows) {
        xlf_aggregate_free(&a);
        fputs("xodb-lframes: out of memory\n", stderr);
        return 1;
    }
    size_t n = 0;
    for (size_t i = 0; i < d->function_count; ++i)
        if (a.inclusive[i].hi || a.inclusive[i].lo)
            rows[n++] = (struct row){(uint32_t)i, a.self[i], a.inclusive[i]};
    if (n)
        qsort(rows, n, sizeof *rows, by_inclusive);
    printf("{\"status\":\"ok\",\"contract\":\"" XLF_CONTRACT "\",\"input_sha256\":\"%s\",\"analysis\":\"xlf-aggregate-v1\",\"thread\":",
           d->sha256_hex);
    if (thread == XLF_NONE)
        fputs("null", stdout);
    else
        jstr(d->threads[thread].id);
    fputs(",\"weight_unit\":", stdout);
    jstr(d->header.weight_unit);
    printf(",\"input_complete\":%s,\"stacks\":%llu,\"partial_stacks\":%llu,\"total_weight\":",
           a.input_incomplete ? "false" : "true", (unsigned long long)a.stacks, (unsigned long long)a.partial_stacks);
    jcount(a.total_weight);
    fputs(",\"partial_weight\":", stdout);
    jcount(a.partial_weight);
    fputs(",\"marker_weight\":", stdout);
    jcount(a.marker_weight);
    fputs(",\"unknown_leaf_weight\":", stdout);
    jcount(a.unknown_leaf_weight);
    fputs(",\"lost\":", stdout);
    jcount(d->lost);
    printf(",\"rules\":\"exact unsigned integers; self=innermost function frame; inclusive counts a function once "
           "per stack (recursion-safe); marker_weight counts a stack once if any frame is a marker; partial stacks "
           "included and also reported in partial_weight\",\"functions\":%zu,\"rows\":[",
           n);
    for (size_t i = 0; i < n && i < top; ++i) {
        const struct xlf_function *f = &d->functions[rows[i].function];
        printf("%s{\"function\":", i ? "," : "");
        jstr(f->id);
        fputs(",\"label\":", stdout);
        jstr(f->qualified.ptr ? f->qualified : f->name);
        printf(",\"kind\":\"%s\",\"self\":", xlf_kind_name(f->kind));
        jcount(rows[i].self);
        fputs(",\"inclusive\":", stdout);
        jcount(rows[i].inclusive);
        fputs(",\"source\":", stdout);
        jcite(f->cite);
        putchar('}');
    }
    printf("],\"truncated_rows\":%s,", n > top ? "true" : "false");
    budget(d, l);
    printf(",\"max_query_bytes\":%zu,\"max_combined_bytes\":%zu,\"query_peak_bytes\":%zu,\"result_bytes\":%zu,"
           "\"combined_peak_bytes\":%zu,\"presentation_bytes\":%zu}}\n",
           ql->max_query_bytes, ql->max_combined_bytes, a.query_peak_bytes, a.result_bytes, a.combined_peak_bytes,
           (d->function_count + 1) * sizeof *rows);
    free(rows);
    xlf_aggregate_free(&a);
    return 0;
}

/* Root-first collapsed stacks ("folded"), one line per stack with weight. */
static void folded(const struct xlf_doc *d, uint32_t thread)
{
    for (size_t i = 0; i < d->stack_count; ++i) {
        const struct xlf_stack *k = &d->stacks[i];
        if (thread != XLF_NONE && k->thread != thread)
            continue;
        const struct xlf_thread *t = &d->threads[k->thread];
        fputs(t->name.ptr ? t->name.ptr : t->id.ptr, stdout);
        if (k->state != XLF_STACK_COMPLETE)
            printf(";[%s]", xlf_state_name(k->state));
        for (uint32_t j = k->frame_count; j-- > 0;) {
            const struct xlf_frame *f = &d->frames[k->first_frame + j];
            const char *label = fn_label(d, f);
            putchar(';');
            if (f->function == XLF_NONE)
                printf("[%s:%s]", xlf_kind_name(f->kind), label);
            else
                for (const char *c = label; *c; ++c)
                    putchar(*c == ';' || *c == ' ' || *c == '\n' ? '_' : *c);
        }
        printf(" %llu\n", (unsigned long long)k->weight);
    }
}

static void occurrences(const struct xlf_doc *d, const char *name, size_t limit)
{
    printf("{\"input_sha256\":\"%s\",\"query\":", d->sha256_hex);
    js(name, strlen(name));
    fputs(",\"occurrences\":[", stdout);
    size_t matched = 0, shown = 0;
    for (size_t i = 0; i < d->stack_count; ++i) {
        const struct xlf_stack *k = &d->stacks[i];
        for (uint32_t j = 0; j < k->frame_count; ++j) {
            const struct xlf_frame *f = &d->frames[k->first_frame + j];
            if (f->function == XLF_NONE)
                continue;
            const struct xlf_function *fn = &d->functions[f->function];
            if (strcmp(fn->name.ptr, name) && (!fn->qualified.ptr || strcmp(fn->qualified.ptr, name)) &&
                strcmp(fn->id.ptr, name))
                continue;
            if (matched++ >= limit)
                continue;
            printf("%s{\"stack\":", shown++ ? "," : "");
            jstr(k->id);
            fputs(",\"thread\":", stdout);
            jstr(d->threads[k->thread].id);
            fputs(",\"frame\":", stdout);
            frame_json(d, f, j);
            fputs(",\"source\":", stdout);
            jcite(k->cite);
            putchar('}');
        }
    }
    printf("],\"matched\":%zu,\"shown\":%zu}\n", matched, shown);
}

static int usage(void)
{
    fputs("usage: xodb-lframes validate|threads|stacks|aggregate|folded|frames FILE\n"
          "  [--strict] [--thread ID|NAME] [--limit N] [--top N] [--function NAME]\n"
          "  [--max-bytes N] [--max-records N] [--max-frames N] [--max-stack-frames N]\n"
          "  [--max-memory N] [--max-string N] [--max-entities N] [--max-stacks N]\n"
          "  [--max-query-memory N] [--max-combined-memory N]\n"
          "candidate tool (C05-R2), not an installed xodb feature\n",
          stderr);
    return 1;
}
static int number(const char *s, size_t *out)
{
    char *end;
    errno = 0;
    if (*s < '0' || *s > '9')
        return -1;
    unsigned long long v = strtoull(s, &end, 10);
    if (errno || end == s || *end || v > SIZE_MAX)
        return -1;
    *out = (size_t)v;
    return 0;
}

static struct xlf_cancel *cancel_object;
static void on_signal(int sig)
{
    (void)sig;
    xlf_cancel_request(cancel_object); /* lock-free atomic store */
}

int main(int argc, char **argv)
{
    if (argc < 3)
        return usage();
    const char *command = argv[1], *path = argv[2], *thread_name = NULL, *function = NULL;
    size_t limit = 1000, top = 50;
    bool strict = false;
    struct xlf_limits limits;
    struct xlf_query_limits qlimits;
    xlf_default_limits(&limits);
    xlf_default_query_limits(&qlimits);
    for (int i = 3; i < argc; ++i) {
        size_t *target = NULL;
        if (!strcmp(argv[i], "--strict")) {
            strict = true;
            continue;
        }
        if (i + 1 >= argc)
            return usage();
        const char *value = argv[++i], *name = argv[i - 1];
        static const struct {
            const char *name;
            size_t offset;
            int which; /* 0 limits, 1 query limits */
        } options[] = {
            {"--max-bytes", offsetof(struct xlf_limits, max_input_bytes), 0},
            {"--max-records", offsetof(struct xlf_limits, max_records), 0},
            {"--max-frames", offsetof(struct xlf_limits, max_total_frames), 0},
            {"--max-stack-frames", offsetof(struct xlf_limits, max_frames_per_stack), 0},
            {"--max-memory", offsetof(struct xlf_limits, max_memory), 0},
            {"--max-string", offsetof(struct xlf_limits, max_string_bytes), 0},
            {"--max-entities", offsetof(struct xlf_limits, max_entities), 0},
            {"--max-stacks", offsetof(struct xlf_limits, max_stacks), 0},
            {"--max-query-memory", offsetof(struct xlf_query_limits, max_query_bytes), 1},
            {"--max-combined-memory", offsetof(struct xlf_query_limits, max_combined_bytes), 1},
        };
        if (!strcmp(name, "--thread"))
            thread_name = value;
        else if (!strcmp(name, "--function"))
            function = value;
        else if (!strcmp(name, "--limit"))
            target = &limit;
        else if (!strcmp(name, "--top"))
            target = &top;
        else {
            for (size_t o = 0; o < sizeof options / sizeof *options && !target; ++o)
                if (!strcmp(name, options[o].name))
                    target = (size_t *)(void *)((options[o].which ? (char *)&qlimits : (char *)&limits) +
                                                options[o].offset);
            if (!target)
                return usage();
        }
        if (target && number(value, target))
            return usage();
    }
    cancel_object = xlf_cancel_create();
    if (!cancel_object) {
        fputs("xodb-lframes: out of memory\n", stderr);
        return 1;
    }
    struct sigaction sa = {.sa_handler = on_signal};
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    struct xlf_error err;
    struct xlf_doc *d = xlf_decode_file(path, &limits, cancel_object, &err);
    if (!d) {
        printf("{\"status\":\"error\",\"phase\":\"decode\",\"error\":\"%s\",\"line\":%llu,\"offset\":%llu,"
               "\"peak_bytes\":%zu,\"max_memory\":%zu,\"message\":",
               xlf_status_name(err.status), (unsigned long long)err.line, (unsigned long long)err.offset,
               err.peak_bytes, limits.max_memory);
        js(err.message, strlen(err.message));
        puts("}");
        xlf_cancel_destroy(cancel_object);
        return 2;
    }
    uint32_t thread = XLF_NONE;
    int rc = 0;
    if (thread_name) {
        thread = xlf_find_thread(d, thread_name);
        if (thread >= d->thread_count) {
            printf("{\"status\":\"error\",\"error\":\"%s\",\"thread\":", thread == XLF_NONE ? "no_such_thread" : "ambiguous_thread");
            js(thread_name, strlen(thread_name));
            puts("}");
            xlf_free(d);
            xlf_cancel_destroy(cancel_object);
            return 3;
        }
    }
    if (!strcmp(command, "validate")) {
        summary(d, path);
        putchar(',');
        budget(d, &limits);
        puts("}}");
    } else if (!strcmp(command, "threads"))
        threads(d);
    else if (!strcmp(command, "stacks"))
        stacks(d, thread, limit);
    else if (!strcmp(command, "aggregate"))
        rc = aggregate(d, &limits, &qlimits, cancel_object, thread, top);
    else if (!strcmp(command, "folded"))
        folded(d, thread);
    else if (!strcmp(command, "frames") && function)
        occurrences(d, function, limit);
    else
        rc = usage();
    if (!rc && strict && (!d->ended || (d->warnings & XLF_W_INCOMPLETE)))
        rc = 4;
    xlf_free(d);
    xlf_cancel_destroy(cancel_object);
    if (fflush(stdout) || ferror(stdout))
        return rc ? rc : 1;
    return rc;
}
