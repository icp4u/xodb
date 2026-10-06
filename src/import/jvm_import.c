#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "jvm_import.h"
#include "jvm_json.h"
#include "sha256.h"
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static const char *const kind_names[JVM_KIND_COUNT] = {
    "execution_sample", "native_method_sample", "exception_throw", "error_throw",
    "thread_start", "thread_end", "virtual_thread_start", "virtual_thread_end",
    "thread_dump_stack", "thread_print_stack", "coroutine_stack"};
static const char *const frame_kind_names[] = {
    "interpreted", "jit_compiled", "jit_inlined", "jvm_native_method",
    "unspecified", "unknown", "unavailable", "coroutine_marker"};
const char *jvm_kind_name(unsigned k)
{
    return k < JVM_KIND_COUNT ? kind_names[k] : "invalid";
}
const char *jvm_frame_kind_name(unsigned k)
{
    return k < sizeof(frame_kind_names) / sizeof(*frame_kind_names) ? frame_kind_names[k] : "invalid";
}
const char *jvm_source_name(enum jvm_source s)
{
    switch (s) {
    case JVM_SOURCE_JFR_JSON: return "jfr-print-json";
    case JVM_SOURCE_THREAD_DUMP_JSON: return "jcmd-thread-dump-json";
    case JVM_SOURCE_THREAD_PRINT: return "jcmd-thread-print";
    case JVM_SOURCE_COROUTINE_PROBES: return "kotlinx-coroutines-probe-dump";
    }
    return "invalid";
}
int jvm_parse_kind(const char *name, unsigned *out)
{
    for (unsigned k = 0; k < JVM_KIND_COUNT; k++)
        if (!strcmp(name, kind_names[k])) {
            *out = k;
            return 0;
        }
    return -1;
}
void jvm_limits_default(struct jvm_limits *l)
{
    l->max_bytes = 512ull << 20;
    l->max_records = 1000000;
    l->max_stack_frames = 8192;
    l->max_total_frames = 16000000;
    l->max_threads = 65536;
    l->max_event_bytes = 64ull << 20;
    l->max_depth = 64;
    l->jfr_export_depth = 0; /* C05-R5: undeclared (was left uninitialized) */
}
static int fail(struct jvm_import *im, const char *fmt, ...)
{
    if (!im->error[0]) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(im->error, sizeof(im->error), fmt, ap);
        va_end(ap);
    }
    return -1;
}
static int grow(struct jvm_budget *b, void **p, uint64_t *cap, uint64_t need, size_t size)
{
    if (need <= *cap)
        return 0;
    uint64_t n = *cap ? *cap : 64;
    while (n < need)
        n *= 2;
    if (n > SIZE_MAX / size)
        return -1;
    void *q = jvm_brealloc(b, *p, (size_t)n * size);
    if (!q)
        return -1;
    *p = q;
    *cap = n;
    return 0;
}
static uint64_t fnv(const void *p, size_t n, uint64_t h)
{
    const unsigned char *s = p;
    for (size_t i = 0; i < n; i++)
        h = (h ^ s[i]) * 0x100000001b3ull;
    return h;
}
/* C05-R4: an allocation that fails anywhere in the importer is
 * sticky. A failed intern returns 0, which also means "absent"; callers that
 * need the string back stop at the next check of import_broken instead of
 * dereferencing it. */
static int nomem(struct jvm_import *im)
{
    im->alloc_failed = 1;
    return -1;
}
static int import_broken(const struct jvm_import *im)
{
    return im->alloc_failed || im->budget->exhausted || im->budget->oom;
}
/* --- interned strings; id 0 means absent --- */
const char *jvm_str(const struct jvm_import *im, uint32_t id)
{
    return id && id <= im->strings.count ? im->strings.data + im->strings.offsets[id - 1] : NULL;
}
static int rehash(struct jvm_budget *b, struct jvm_strings *t)
{
    uint32_t n = t->slot_count ? t->slot_count * 2 : 1024;
    uint32_t *slots = jvm_bcalloc(b, n, sizeof(*slots));
    if (!slots)
        return -1;
    for (uint32_t id = 1; id <= t->count; id++) {
        const char *s = t->data + t->offsets[id - 1];
        uint32_t i = (uint32_t)fnv(s, strlen(s), 0xcbf29ce484222325ull) & (n - 1);
        while (slots[i])
            i = (i + 1) & (n - 1);
        slots[i] = id;
    }
    jvm_bfree(b, t->slots);
    t->slots = slots;
    t->slot_count = n;
    return 0;
}
static uint32_t intern_raw(struct jvm_import *im, const char *s, size_t n)
{
    struct jvm_strings *t = &im->strings;
    if ((uint64_t)(t->count + 1) * 2 > t->slot_count && rehash(im->budget, t)) {
        nomem(im);
        return 0;
    }
    uint32_t i = (uint32_t)fnv(s, n, 0xcbf29ce484222325ull) & (t->slot_count - 1);
    for (; t->slots[i]; i = (i + 1) & (t->slot_count - 1)) {
        const char *have = t->data + t->offsets[t->slots[i] - 1];
        if (!strncmp(have, s, n) && !have[n])
            return t->slots[i];
    }
    uint64_t cap = t->cap, ids = t->cap_ids;
    if (grow(im->budget, (void **)&t->data, &cap, t->used + n + 1, 1) ||
        grow(im->budget, (void **)&t->offsets, &ids, (uint64_t)t->count + 1, sizeof(size_t))) {
        nomem(im);
        return 0;
    }
    t->cap = cap;
    t->cap_ids = (uint32_t)ids;
    memcpy(t->data + t->used, s, n);
    t->data[t->used + n] = 0;
    t->offsets[t->count++] = t->used;
    t->used += n + 1;
    t->slots[i] = t->count;
    return t->count;
}
/* C05-R4: a string with an embedded NUL (JSON \u0000; modified
 * UTF-8 allows U+0000 in JVM names) is never shortened. It is stored escaped
 * ("\0" for NUL, "\\" for a backslash, so distinct inputs stay distinct) and
 * the field's bit is set in *escaped so identity keys also distinguish it from
 * a NUL-free string that happens to read the same (C05-R5: per field, not one
 * flag per frame, so NUL in the class and a literal "\0" in the method never
 * key like the reverse). */
static uint32_t intern_n_flag(struct jvm_import *im, const char *s, size_t n, uint8_t *escaped, uint8_t bit)
{
    if (!s)
        return 0;
    if (!memchr(s, 0, n))
        return intern_raw(im, s, n);
    if (n > (SIZE_MAX - 1) / 2) {
        nomem(im);
        return 0;
    }
    char *o = jvm_balloc(im->budget, n * 2 + 1);
    if (!o) {
        nomem(im);
        return 0;
    }
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        if (!s[i] || s[i] == '\\') {
            o[k++] = '\\';
            o[k++] = s[i] ? '\\' : '0';
        } else
            o[k++] = s[i];
    }
    uint32_t id = intern_raw(im, o, k);
    jvm_bfree(im->budget, o);
    im->diag.nul_escaped_strings++;
    if (escaped)
        *escaped |= bit;
    return id;
}
static uint32_t intern_n(struct jvm_import *im, const char *s, size_t n)
{
    return intern_n_flag(im, s, n, NULL, 0);
}
static uint32_t intern(struct jvm_import *im, const char *s)
{
    return s ? intern_raw(im, s, strlen(s)) : 0;
}
/* A JSON string member with its decoded length (keeps embedded NULs). */
static uint32_t intern_member(struct jvm_import *im, const struct jj_value *o, const char *key, uint8_t *escaped,
                              uint8_t bit)
{
    const struct jj_value *v = jj_get(o, key);
    return v && v->type == JJ_STRING ? intern_n_flag(im, v->text, v->length, escaped, bit) : 0;
}
/* --- frames, deduplicated by every exported field --- */
static int frame_equal(const struct jvm_frame *a, const struct jvm_frame *b)
{
    return a->class_name == b->class_name && a->raw_class == b->raw_class && a->method == b->method &&
           a->descriptor == b->descriptor && a->module == b->module &&
           a->module_version == b->module_version && a->loader == b->loader && a->file == b->file &&
           a->raw_kind == b->raw_kind && a->raw_text == b->raw_text && a->line == b->line &&
           a->bci == b->bci && a->has_line == b->has_line && a->has_bci == b->has_bci &&
           a->kind == b->kind && a->hidden == b->hidden && a->name_status == b->name_status &&
           a->heuristic == b->heuristic && a->loader_type == b->loader_type &&
           a->loader_status == b->loader_status && a->nul_escaped == b->nul_escaped;
}
static uint64_t frame_hash(const struct jvm_frame *f)
{
    uint32_t v[] = {f->class_name, f->raw_class, f->method, f->descriptor, f->module,
                    f->module_version, f->loader, f->file, f->raw_kind, f->raw_text,
                    (uint32_t)f->line, (uint32_t)f->bci,
                    (uint32_t)f->has_line << 24 | f->has_bci << 16 | f->kind << 8 | f->hidden,
                    (uint32_t)f->name_status << 8 | f->heuristic, f->loader_type,
                    (uint32_t)f->nul_escaped << 8 | f->loader_status};
    return fnv(v, sizeof(v), 0xcbf29ce484222325ull);
}
static int frame_id(struct jvm_import *im, const struct jvm_frame *f, uint32_t *out)
{
    if ((uint64_t)(im->frame_count + 1) * 2 > im->frame_slot_count) {
        uint32_t n = im->frame_slot_count ? im->frame_slot_count * 2 : 1024;
        uint32_t *slots = jvm_bcalloc(im->budget, n, sizeof(*slots));
        if (!slots)
            return -1;
        for (uint32_t id = 0; id < im->frame_count; id++) {
            uint32_t i = (uint32_t)frame_hash(&im->frames[id]) & (n - 1);
            while (slots[i])
                i = (i + 1) & (n - 1);
            slots[i] = id + 1;
        }
        jvm_bfree(im->budget, im->frame_slots);
        im->frame_slots = slots;
        im->frame_slot_count = n;
    }
    uint32_t i = (uint32_t)frame_hash(f) & (im->frame_slot_count - 1);
    for (; im->frame_slots[i]; i = (i + 1) & (im->frame_slot_count - 1))
        if (frame_equal(&im->frames[im->frame_slots[i] - 1], f)) {
            *out = im->frame_slots[i] - 1;
            return 0;
        }
    uint64_t cap = im->frame_cap;
    if (grow(im->budget, (void **)&im->frames, &cap, (uint64_t)im->frame_count + 1, sizeof(*im->frames)))
        return -1;
    im->frame_cap = (uint32_t)cap;
    im->frames[im->frame_count] = *f;
    im->frame_slots[i] = ++im->frame_count;
    *out = im->frame_count - 1;
    return 0;
}
/* Appends a frame to the stack being built for the current record. Returns 1 when the
 * per-stack budget has been reached (frame dropped, stack marked importer-truncated). */
static int push_frame(struct jvm_import *im, struct jvm_record *r, const struct jvm_frame *f)
{
    if (r->frame_count >= im->limits.max_stack_frames) {
        if (r->truncated != JVM_TRUNC_IMPORTER)
            im->diag.importer_truncated_stacks++;
        r->truncated = JVM_TRUNC_IMPORTER;
        r->dropped++;
        return 0; /* keep counting what is dropped */
    }
    if (im->stack_used >= im->limits.max_total_frames) {
        im->incomplete = "total frame budget exhausted";
        r->truncated = JVM_TRUNC_IMPORTER;
        return 1;
    }
    uint32_t id;
    if (frame_id(im, f, &id) || grow(im->budget, (void **)&im->stack, &im->stack_cap, im->stack_used + 1, 4))
        return -1;
    im->stack[im->stack_used++] = id;
    r->frame_count++;
    return 0;
}
static int method_status(const char *name)
{
    if (!name)
        return JVM_NAME_ABSENT;
    if (!*name)
        return JVM_NAME_EMPTY;
    if (!strcmp(name, "<init>") || !strcmp(name, "<clinit>"))
        return JVM_NAME_OK;
    return strpbrk(name, ".;[/<>") ? JVM_NAME_INVALID : JVM_NAME_OK; /* JVMS 4.2.2 */
}
static void note_name(struct jvm_import *im, struct jvm_frame *f, const char *method)
{
    f->name_status = (uint8_t)method_status(method);
    if (f->name_status == JVM_NAME_EMPTY || f->name_status == JVM_NAME_ABSENT)
        im->diag.unnamed_methods++;
    else if (f->name_status == JVM_NAME_INVALID)
        im->diag.invalid_method_names++;
}
/* JVM internal names use '/', hidden classes already carry a dotted name plus "/0x..". */
static uint32_t binary_name_n(struct jvm_import *im, const char *raw, size_t n, uint8_t *escaped, uint8_t bit)
{
    if (!raw)
        return 0;
    if (memchr(raw, '.', n))
        return intern_n_flag(im, raw, n, escaped, bit);
    char *s = jvm_balloc(im->budget, n + 1);
    if (!s) {
        nomem(im);
        return 0;
    }
    for (size_t i = 0; i < n; i++)
        s[i] = raw[i] == '/' ? '.' : raw[i];
    s[n] = 0;
    uint32_t id = intern_n_flag(im, s, n, escaped, bit);
    jvm_bfree(im->budget, s);
    return id;
}
static uint32_t binary_name(struct jvm_import *im, const char *raw)
{
    return raw ? binary_name_n(im, raw, strlen(raw), NULL, 0) : 0;
}
/* --- threads --- */
static int thread_id(struct jvm_import *im, const struct jvm_thread *key, uint32_t name,
                     uint64_t ordinal, unsigned kind, uint32_t *out)
{
    uint32_t i;
    for (i = 0; i < im->thread_count; i++) {
        struct jvm_thread *t = &im->threads[i];
        if (t->has_java_tid == key->has_java_tid && t->java_tid == key->java_tid &&
            t->has_os_tid == key->has_os_tid && t->os_tid == key->os_tid &&
            t->is_virtual == key->is_virtual && t->vm_internal == key->vm_internal &&
            (key->has_java_tid || key->has_os_tid || t->names[0] == name))
            break;
    }
    if (i == im->thread_count) {
        if (im->thread_count >= im->limits.max_threads) {
            im->incomplete = "thread budget exhausted";
            return 1;
        }
        uint64_t cap = im->thread_cap;
        if (grow(im->budget, (void **)&im->threads, &cap, (uint64_t)im->thread_count + 1, sizeof(*im->threads)))
            return -1;
        im->thread_cap = (uint32_t)cap;
        struct jvm_thread *t = &im->threads[im->thread_count++];
        *t = *key;
        memset(t->names, 0, sizeof(t->names));
        memset(t->records, 0, sizeof(t->records));
        t->name_count = 0;
        t->names_truncated = 0;
        t->first_ordinal = ordinal;
    }
    struct jvm_thread *t = &im->threads[i];
    if (key->vm_address && !t->vm_address)
        t->vm_address = key->vm_address;
    if (key->group && !t->group)
        t->group = key->group;
    if (name) {
        uint32_t k;
        for (k = 0; k < t->name_count && t->names[k] != name; k++)
            ;
        if (k == t->name_count) {
            if (t->name_count < JVM_THREAD_NAMES)
                t->names[t->name_count++] = name;
            else
                t->names_truncated = 1;
        }
    }
    t->records[kind]++;
    t->last_ordinal = ordinal;
    *out = i;
    return 0;
}
static struct jvm_record *new_record(struct jvm_import *im, unsigned kind, uint64_t ordinal)
{
    if (im->record_count >= im->limits.max_records) {
        im->incomplete = "record budget exhausted";
        return NULL;
    }
    if (grow(im->budget, (void **)&im->records, &im->record_cap, im->record_count + 1, sizeof(*im->records))) {
        fail(im, "out of memory");
        return NULL;
    }
    struct jvm_record *r = &im->records[im->record_count];
    memset(r, 0, sizeof(*r));
    r->kind = kind;
    r->ordinal = ordinal;
    r->frame_start = (uint32_t)im->stack_used;
    r->thread = UINT32_MAX;
    return r;
}
static int attach_thread(struct jvm_import *im, struct jvm_record *r, struct jvm_thread *key)
{
    int rc = thread_id(im, key, r->name, r->ordinal, r->kind, &r->thread);
    if (rc < 0)
        return fail(im, "out of memory");
    return rc;
}
/* --- time --- */
static int digits(const char *s, int n, int64_t *out)
{
    int64_t v = 0;
    for (int i = 0; i < n; i++) {
        if (s[i] < '0' || s[i] > '9')
            return -1;
        v = v * 10 + (s[i] - '0');
    }
    *out = v;
    return 0;
}
static int64_t days_from_civil(int64_t y, int64_t m, int64_t d)
{
    y -= m <= 2;
    int64_t era = (y >= 0 ? y : y - 399) / 400;
    int64_t yoe = y - era * 400;
    int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}
static const char *const time_status_names[JVM_TIME_STATUS_COUNT] = {
    "ok", "absent", "malformed", "unzoned", "invalid_calendar_date", "invalid_time_of_day",
    "leap_second_not_representable", "invalid_zone_offset", "precision_finer_than_ns",
    "outside_int64_epoch_ns"};
const char *jvm_time_status_name(unsigned k)
{
    return k < JVM_TIME_STATUS_COUNT ? time_status_names[k] : "invalid";
}
const char *jvm_loader_status_name(unsigned k)
{
    return k == JVM_LOADER_NAMED ? "loader_named" : k == JVM_LOADER_UNNAMED ? "loader_unnamed" : "loader_not_exported";
}
static int leap_year(int64_t y)
{
    return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}
/* C05-R3: every field is range checked against the proleptic Gregorian calendar;
 * offsets are limited to the java.time ZoneOffset range (+-18:00, optional
 * seconds); a leap second (:60) is refused, not folded into the next second; the
 * nanosecond product and the fractional endpoint use checked arithmetic, so
 * 1677-09-21T00:12:43.145224192Z and 2262-04-11T23:47:16.854775807Z are the
 * exact limits. */
int jvm_parse_iso_time(const char *s, int64_t *out)
{
    static const int64_t month_days[13] = {0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    int64_t y, mo, d, h, mi, se, frac = 0, oh = 0, om = 0, os = 0;
    if (!s)
        return JVM_TIME_ABSENT;
    size_t n = strlen(s);
    if (n < 19 || digits(s, 4, &y) || s[4] != '-' || digits(s + 5, 2, &mo) || s[7] != '-' ||
        digits(s + 8, 2, &d) || s[10] != 'T' || digits(s + 11, 2, &h) || s[13] != ':' ||
        digits(s + 14, 2, &mi) || s[16] != ':' || digits(s + 17, 2, &se))
        return JVM_TIME_MALFORMED;
    const char *p = s + 19;
    int k = 0, unzoned = 0;
    if (*p == '.') { /* C05-R4: all digits are scanned; precision is judged after the shape */
        for (p++; *p >= '0' && *p <= '9'; p++, k++)
            if (k < 9)
                frac = frac * 10 + (*p - '0');
        if (!k)
            return JVM_TIME_MALFORMED;
        for (int z = k; z < 9; z++)
            frac *= 10;
    }
    int sign = 0;
    if (*p == 'Z')
        p++;
    else if (*p == '+' || *p == '-') {
        sign = *p == '-' ? -1 : 1;
        if (strlen(p) < 6 || digits(p + 1, 2, &oh) || p[3] != ':' || digits(p + 4, 2, &om))
            return JVM_TIME_MALFORMED;
        p += 6;
        if (*p == ':') {
            if (strlen(p) < 3 || digits(p + 1, 2, &os))
                return JVM_TIME_MALFORMED;
            p += 3;
        }
    } else if (!*p)
        unzoned = 1;
    else
        return JVM_TIME_MALFORMED;
    if (*p)
        return JVM_TIME_MALFORMED;
    if (k > 9)
        return JVM_TIME_PRECISION;
    if (unzoned)
        return JVM_TIME_UNZONED; /* an unzoned time has no defined epoch */
    if (mo < 1 || mo > 12 || d < 1 || d > month_days[mo] + (mo == 2 && leap_year(y)))
        return JVM_TIME_INVALID_DATE;
    if (h > 23 || mi > 59 || se > 60)
        return JVM_TIME_INVALID_CLOCK;
    if (se == 60)
        return JVM_TIME_LEAP_SECOND;
    if (om > 59 || os > 59 || oh * 3600 + om * 60 + os > 18 * 3600)
        return JVM_TIME_INVALID_OFFSET;
    /* |secs| < 2^39 for years 0000..9999: no overflow below. */
    int64_t secs = days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se;
    secs -= sign * (oh * 3600 + om * 60 + os);
    if (secs < 0 && frac > 0) { /* keep the product in range at the negative endpoint */
        secs += 1;
        frac -= 1000000000;
    }
    int64_t ns;
    if (__builtin_mul_overflow(secs, (int64_t)1000000000, &ns) || __builtin_add_overflow(ns, frac, &ns))
        return JVM_TIME_OUT_OF_RANGE;
    *out = ns;
    return JVM_TIME_OK;
}
static void record_time(struct jvm_import *im, struct jvm_record *r, const char *raw)
{
    r->time_raw = intern(im, raw);
    r->time_status = (uint8_t)jvm_parse_iso_time(raw, &r->time_ns);
    r->has_time_ns = r->time_status == JVM_TIME_OK;
}
/* --- StackTraceElement-style text frames --- */
static int all_hex(const char *s)
{
    if (s[0] != '0' || s[1] != 'x' || !s[2])
        return 0;
    for (s += 2; *s; s++)
        if (!((*s >= '0' && *s <= '9') || (*s >= 'a' && *s <= 'f') || (*s >= 'A' && *s <= 'F')))
            return 0;
    return 1;
}
static void module_spec(struct jvm_import *im, struct jvm_frame *f, const char *spec, size_t n)
{
    const char *at = memchr(spec, '@', n);
    f->module = n ? intern_n(im, spec, at ? (size_t)(at - spec) : n) : 0;
    if (at)
        f->module_version = intern_n(im, at + 1, n - (size_t)(at + 1 - spec));
}
/* Accepts StackTraceElement.toString() and HotSpot's "at" form, which moves the
 * module into the parenthesis. The format is ambiguous for hidden classes and
 * custom loaders; every parse from text is marked heuristic. */
static void text_frame(struct jvm_import *im, const char *text, struct jvm_frame *f)
{
    memset(f, 0, sizeof(*f));
    f->kind = JVM_FRAME_UNSPECIFIED;
    f->hidden = JVM_UNKNOWN;
    f->heuristic = 1;
    if (!text) { /* C05-R4: never strlen(NULL); the import fails as broken */
        f->kind = JVM_FRAME_UNAVAILABLE;
        f->name_status = JVM_NAME_ABSENT;
        nomem(im);
        return;
    }
    f->raw_text = intern(im, text);
    im->diag.heuristic_frames++;
    size_t n = strlen(text);
    const char *open = NULL;
    for (const char *p = text; *p; p++)
        if (*p == '(')
            open = p;
    if (!n || text[n - 1] != ')' || !open) {
        f->kind = JVM_FRAME_UNAVAILABLE;
        f->name_status = JVM_NAME_ABSENT;
        im->diag.malformed_frames++;
        return;
    }
    size_t qn = (size_t)(open - text);
    char *q = jvm_bstrndup(im->budget, text, qn), *loc = jvm_bstrndup(im->budget, open + 1, n - qn - 2);
    if (!q || !loc) {
        jvm_bfree(im->budget, q);
        jvm_bfree(im->budget, loc);
        f->kind = JVM_FRAME_UNAVAILABLE;
        nomem(im);
        return;
    }
    char *dot = strrchr(q, '.');
    if (!dot) {
        f->kind = JVM_FRAME_UNAVAILABLE;
        f->name_status = JVM_NAME_ABSENT;
        im->diag.malformed_frames++;
        jvm_bfree(im->budget, q);
        jvm_bfree(im->budget, loc);
        return;
    }
    *dot = 0;
    f->method = intern(im, dot + 1);
    note_name(im, f, dot + 1);
    char *seg[64];
    int count = 0;
    for (char *s = q;; ) {
        if (count == 64)
            break;
        seg[count++] = s;
        char *slash = strchr(s, '/');
        if (!slash)
            break;
        *slash = 0;
        s = slash + 1;
    }
    int last = count - 1;
    if (count >= 2 && all_hex(seg[last])) { /* hidden class "Name/0x..." */
        seg[last - 1][strlen(seg[last - 1])] = '/';
        last--;
        f->hidden = JVM_YES;
    }
    f->class_name = intern(im, seg[last]);
    f->raw_class = f->class_name;
    if (last == 1)
        module_spec(im, f, seg[0], strlen(seg[0]));
    else if (last == 2) {
        f->loader = seg[0][0] ? intern(im, seg[0]) : 0;
        f->loader_status = f->loader ? JVM_LOADER_NAMED : JVM_LOADER_NOT_EXPORTED;
        module_spec(im, f, seg[1], strlen(seg[1]));
    } else if (last > 2)
        im->diag.malformed_frames++;
    char *file = loc, *slash = strchr(loc, '/');
    if (slash && !f->module) {
        module_spec(im, f, loc, (size_t)(slash - loc));
        file = slash + 1;
    } else if (slash)
        file = slash + 1;
    if (!strcmp(file, "Native Method"))
        f->kind = JVM_FRAME_NATIVE_METHOD;
    else if (strcmp(file, "Unknown Source")) {
        char *colon = strrchr(file, ':');
        int64_t line;
        if (colon && colon[1] && strspn(colon + 1, "0123456789") == strlen(colon + 1) &&
            strlen(colon + 1) < 10 && !digits(colon + 1, (int)strlen(colon + 1), &line)) {
            f->line = line;
            f->has_line = 1;
            *colon = 0;
        }
        f->file = intern(im, file);
    }
    jvm_bfree(im->budget, q);
    jvm_bfree(im->budget, loc);
}
static int coroutine_marker(const char *text)
{
    return !strncmp(text, "_COROUTINE.", 11);
}
/* --- JFR `jfr print --json` --- */
static void thread_key(const struct jj_value *t, struct jvm_import *im, struct jvm_thread *key,
                       struct jvm_record *r)
{
    memset(key, 0, sizeof(*key));
    key->is_virtual = JVM_UNKNOWN;
    const struct jj_value *v = jj_get(t, "virtual");
    if (v && (v->type == JJ_TRUE || v->type == JJ_FALSE))
        key->is_virtual = v->type == JJ_TRUE ? JVM_YES : JVM_NO;
    int64_t n;
    const struct jj_value *java = jj_get(t, "javaThreadId"), *os = jj_get(t, "osThreadId");
    if (!jj_i64(java, &n)) {
        key->java_tid = n;
        key->has_java_tid = 1;
    } else if (java && java->type != JJ_NULL)
        im->diag.invalid_numbers++; /* out of range or non-integer: absent, never rounded */
    if (!jj_i64(os, &n)) {
        if (n > 0) {
            key->os_tid = n;
            key->has_os_tid = 1;
        } else
            im->diag.os_tid_zero++; /* JFR writes 0 when no OS thread is bound */
    } else if (os && os->type != JJ_NULL)
        im->diag.invalid_numbers++;
    const struct jj_value *group = jj_get(t, "group");
    key->group = intern(im, jj_str(group, "name"));
    r->name = intern(im, jj_str(t, "javaName"));
    r->os_name = intern(im, jj_str(t, "osName"));
}
static int jfr_frame(struct jvm_import *im, const struct jj_value *v, struct jvm_frame *f)
{
    memset(f, 0, sizeof(*f));
    f->hidden = JVM_UNKNOWN;
    const struct jj_value *m = jj_get(v, "method");
    const char *kind = jj_str(v, "type");
    f->raw_kind = intern(im, kind);
    if (!kind)
        f->kind = JVM_FRAME_UNKNOWN;
    else if (!strcmp(kind, "Interpreted"))
        f->kind = JVM_FRAME_INTERPRETED;
    else if (!strcmp(kind, "JIT compiled"))
        f->kind = JVM_FRAME_JIT;
    else if (!strcmp(kind, "Inlined"))
        f->kind = JVM_FRAME_INLINED;
    else if (!strcmp(kind, "Native"))
        f->kind = JVM_FRAME_NATIVE_METHOD;
    else {
        f->kind = JVM_FRAME_UNKNOWN;
        im->diag.unknown_frame_kinds++;
    }
    if (!m || m->type != JJ_OBJECT) {
        f->kind = JVM_FRAME_UNAVAILABLE;
        f->name_status = JVM_NAME_ABSENT;
        im->diag.malformed_frames++;
        return 0;
    }
    const char *method = jj_str(m, "name");
    f->method = intern_member(im, m, "name", &f->nul_escaped, JVM_NUL_METHOD);
    note_name(im, f, method);
    f->descriptor = intern_member(im, m, "descriptor", &f->nul_escaped, JVM_NUL_DESCRIPTOR);
    const struct jj_value *type = jj_get(m, "type");
    const char *raw = jj_str(type, "name");
    const struct jj_value *rawv = jj_get(type, "name");
    /* C05-R4: raw_class (as exported: p/C or an already dotted p.C) is
     * part of the identity, so two raw names never merge through binary_name. */
    f->raw_class = intern_member(im, type, "name", &f->nul_escaped, JVM_NUL_CLASS);
    f->class_name = raw ? binary_name_n(im, raw, rawv->length, &f->nul_escaped, JVM_NUL_CLASS) : 0;
    const struct jj_value *hidden = jj_get(m, "hidden"), *type_hidden = jj_get(type, "hidden");
    if ((hidden && hidden->type == JJ_TRUE) || (type_hidden && type_hidden->type == JJ_TRUE))
        f->hidden = JVM_YES;
    else if (hidden && hidden->type == JJ_FALSE)
        f->hidden = JVM_NO;
    /* C05-R3: the exported loader (name and the loader's own class) is part of
     * the frame's identity; a frame without loader information stays unknown. */
    const struct jj_value *loader = jj_get(type, "classLoader");
    if (loader && loader->type == JJ_OBJECT) {
        f->loader = intern_member(im, loader, "name", &f->nul_escaped, JVM_NUL_LOADER);
        f->loader_type = intern_member(im, jj_get(loader, "type"), "name", &f->nul_escaped, JVM_NUL_LOADER_TYPE);
        f->loader_status = f->loader ? JVM_LOADER_NAMED : JVM_LOADER_UNNAMED;
    }
    const struct jj_value *module = jj_get(jj_get(type, "package"), "module");
    f->module = intern_member(im, module, "name", &f->nul_escaped, JVM_NUL_MODULE);
    f->module_version = intern_member(im, module, "version", &f->nul_escaped, JVM_NUL_MODULE_VERSION);
    int64_t n;
    if (!jj_i64(jj_get(v, "lineNumber"), &n) && n >= 0) {
        f->line = n;
        f->has_line = 1;
    }
    if (!jj_i64(jj_get(v, "bytecodeIndex"), &n) && n >= 0) {
        f->bci = n;
        f->has_bci = 1;
    }
    if (!raw)
        im->diag.malformed_frames++;
    return 0;
}
static int jfr_stack(struct jvm_import *im, struct jvm_record *r, const struct jj_value *st)
{
    if (!st || st->type != JJ_OBJECT) {
        r->truncated = JVM_TRUNC_UNREPORTED;
        im->diag.missing_stack++;
        return 0;
    }
    const struct jj_value *t = jj_get(st, "truncated");
    r->truncated = t && t->type == JJ_TRUE    ? JVM_TRUNC_SOURCE
                   : t && t->type == JJ_FALSE ? JVM_TRUNC_NO
                                              : JVM_TRUNC_UNREPORTED;
    const struct jj_value *frames = jj_get(st, "frames");
    if (!frames || frames->type != JJ_ARRAY) {
        im->diag.missing_stack++;
        return 0;
    }
    /* `jfr print` cuts stacks to --stack-depth (default 5) but keeps the JVM's flag, so a
     * stack that reaches the export depth, or any stack when the depth is undeclared,
     * cannot be called complete. */
    uint32_t depth = im->limits.jfr_export_depth;
    if (r->truncated == JVM_TRUNC_NO && (!depth || frames->count >= depth)) {
        r->truncated = JVM_TRUNC_EXPORT;
        im->diag.export_depth_unknown++;
    }
    for (uint32_t i = 0; i < frames->count; i++) {
        if (import_broken(im))
            return fail(im, "out of memory");
        struct jvm_frame f;
        jfr_frame(im, &frames->items[i], &f);
        int rc = push_frame(im, r, &f);
        if (rc < 0)
            return fail(im, "out of memory");
        if (rc)
            break;
    }
    return 0;
}
static int jfr_event(struct jvm_import *im, const struct jj_value *e, uint64_t ordinal)
{
    const char *type = jj_str(e, "type");
    const struct jj_value *v = jj_get(e, "values");
    if (!type || !v || v->type != JJ_OBJECT)
        return fail(im, "event %llu lacks type/values", (unsigned long long)ordinal);
    if (!strcmp(type, "jdk.JVMInformation")) {
        im->jvm_name = intern(im, jj_str(v, "jvmName"));
        im->jvm_version = intern(im, jj_str(v, "jvmVersion"));
        im->jvm_start = intern(im, jj_str(v, "jvmStartTime"));
        im->jvm_args = intern(im, jj_str(v, "jvmArguments"));
        im->java_args = intern(im, jj_str(v, "javaArguments"));
        int64_t pid;
        if (!jj_i64(jj_get(v, "pid"), &pid)) {
            im->pid = pid;
            im->has_pid = 1;
        }
        return 0;
    }
    if (!strcmp(type, "jdk.OSInformation")) {
        im->os_version = intern(im, jj_str(v, "osVersion"));
        return 0;
    }
    if (!strcmp(type, "jdk.ActiveRecording")) {
        im->recording_start = intern(im, jj_str(v, "recordingStart"));
        im->recording_name = intern(im, jj_str(v, "name"));
        return 0;
    }
    static const struct { const char *type, *thread; unsigned kind; } map[] = {
        {"jdk.ExecutionSample", "sampledThread", JVM_EXECUTION_SAMPLE},
        {"jdk.NativeMethodSample", "sampledThread", JVM_NATIVE_METHOD_SAMPLE},
        {"jdk.JavaExceptionThrow", "eventThread", JVM_EXCEPTION_THROW},
        {"jdk.JavaErrorThrow", "eventThread", JVM_ERROR_THROW},
        {"jdk.ThreadStart", "thread", JVM_THREAD_START},
        {"jdk.ThreadEnd", "thread", JVM_THREAD_END},
        {"jdk.VirtualThreadStart", "eventThread", JVM_VIRTUAL_THREAD_START},
        {"jdk.VirtualThreadEnd", "eventThread", JVM_VIRTUAL_THREAD_END}};
    unsigned i;
    for (i = 0; i < sizeof(map) / sizeof(*map) && strcmp(type, map[i].type); i++)
        ;
    if (i == sizeof(map) / sizeof(*map)) {
        im->diag.skipped_events++;
        return 0;
    }
    struct jvm_record *r = new_record(im, map[i].kind, ordinal);
    if (!r)
        return im->error[0] ? -1 : 1;
    r->event_type = intern(im, type);
    record_time(im, r, jj_str(v, "startTime"));
    r->state = intern(im, jj_str(v, "state"));
    if (map[i].kind == JVM_EXCEPTION_THROW || map[i].kind == JVM_ERROR_THROW) {
        r->detail = binary_name(im, jj_str(jj_get(v, "thrownClass"), "name"));
        r->detail2 = intern(im, jj_str(v, "message"));
    }
    if (jfr_stack(im, r, jj_get(v, "stackTrace")))
        return -1;
    const struct jj_value *t = jj_get(v, map[i].thread);
    if (!t || t->type != JJ_OBJECT)
        t = jj_get(v, "eventThread");
    if (!t || t->type != JJ_OBJECT) {
        im->diag.missing_thread++;
    } else {
        struct jvm_thread key;
        thread_key(t, im, &key, r);
        int rc = attach_thread(im, r, &key);
        if (rc < 0)
            return -1;
        if (rc > 0) {
            im->stack_used = r->frame_start;
            return 1;
        }
    }
    im->record_count++;
    return 0;
}
static int skip_member(struct jj_parser *j, struct jj_arena *arena)
{
    struct jj_value ignored;
    int rc = jj_value(j, &ignored);
    jj_arena_reset(arena);
    return rc;
}
/* Streams `{"recording":{"events":[...]}}`, holding one event in memory at a time. */
static int import_jfr(struct jvm_import *im, const char *text, size_t length)
{
    struct jj_arena arena = {.limit = im->limits.max_event_bytes, .budget = im->budget};
    struct jj_parser j;
    jj_init(&j, text, length, &arena, im->limits.max_depth, 1u << 20);
    const char *key;
    size_t key_length;
    int saw_events = 0, rc = 0;
    if (jj_expect(&j, '{'))
        goto bad;
    while (!rc) {
        if (jj_skip_space(&j) == '}') {
            j.p++;
            break;
        }
        if (jj_string(&j, &key, &key_length) || jj_expect(&j, ':'))
            goto bad;
        if (strcmp(key, "recording")) {
            jj_arena_reset(&arena);
            if (skip_member(&j, &arena))
                goto bad;
        } else {
            jj_arena_reset(&arena);
            if (jj_expect(&j, '{'))
                goto bad;
            while (!rc) {
                if (jj_skip_space(&j) == '}') {
                    j.p++;
                    break;
                }
                if (jj_string(&j, &key, &key_length) || jj_expect(&j, ':'))
                    goto bad;
                if (strcmp(key, "events")) {
                    jj_arena_reset(&arena);
                    if (skip_member(&j, &arena))
                        goto bad;
                } else {
                    jj_arena_reset(&arena);
                    saw_events = 1;
                    if (jj_expect(&j, '['))
                        goto bad;
                    if (jj_skip_space(&j) == ']')
                        j.p++;
                    else
                        for (uint64_t ordinal = 0;; ordinal++) {
                            struct jj_value e;
                            if (jvm_bcancelled(im->budget) || import_broken(im)) {
                                rc = -1;
                                break;
                            }
                            if (jj_value(&j, &e))
                                goto bad;
                            im->records_scanned++;
                            uint64_t before = im->record_count;
                            rc = jfr_event(im, &e, ordinal);
                            if (!rc && im->record_count > before) { /* C05-R3: cite the event's bytes */
                                im->records[before].byte_start = e.start;
                                im->records[before].byte_end = e.end;
                            }
                            jj_arena_reset(&arena);
                            if (rc)
                                break;
                            int c = jj_skip_space(&j);
                            if (c == ',') {
                                j.p++;
                                continue;
                            }
                            if (c == ']') {
                                j.p++;
                                break;
                            }
                            jj_fail(&j, "expected separator");
                            goto bad;
                        }
                }
                if (rc)
                    break;
                int c = jj_skip_space(&j);
                if (c == ',')
                    j.p++;
                else if (c != '}') {
                    jj_fail(&j, "expected separator");
                    goto bad;
                }
            }
        }
        if (rc)
            break;
        int c = jj_skip_space(&j);
        if (c == ',')
            j.p++;
        else if (c != '}') {
            jj_fail(&j, "expected separator");
            goto bad;
        }
    }
    im->diag.lossy_strings += j.lossy;
    jj_arena_free(&arena);
    if (rc < 0)
        return -1;
    if (!rc && jj_skip_space(&j) >= 0)
        return fail(im, "trailing data after JSON at byte %zu", (size_t)(j.p - j.start));
    if (!saw_events)
        return fail(im, "not a jfr print --json document (no recording.events)");
    return 0;
bad:
    jj_arena_free(&arena);
    return fail(im, "JSON error at byte %zu: %s", j.error_offset, j.error ? j.error : "?");
}
/* --- generic small JSON documents --- */
static int whole_json(struct jvm_import *im, const char *text, size_t length,
                      struct jj_arena *arena, struct jj_value *root)
{
    struct jj_parser j;
    arena->limit = im->limits.max_event_bytes;
    jj_init(&j, text, length, arena, im->limits.max_depth, 1u << 20);
    if (jj_value(&j, root))
        return fail(im, "JSON error at byte %zu: %s", j.error_offset, j.error);
    if (jj_skip_space(&j) >= 0)
        return fail(im, "trailing data after JSON at byte %zu", (size_t)(j.p - j.start));
    im->diag.lossy_strings += j.lossy;
    return 0;
}
static int text_stack(struct jvm_import *im, struct jvm_record *r, const struct jj_value *frames,
                      int split_creation)
{
    if (!frames || frames->type != JJ_ARRAY) {
        im->diag.missing_stack++;
        return 0;
    }
    for (uint32_t i = 0; i < frames->count; i++) {
        if (import_broken(im))
            return fail(im, "out of memory");
        const struct jj_value *v = &frames->items[i];
        struct jvm_frame f;
        if (v->type != JJ_STRING) {
            memset(&f, 0, sizeof(f));
            f.kind = JVM_FRAME_UNAVAILABLE;
            f.name_status = JVM_NAME_ABSENT;
            im->diag.malformed_frames++;
        } else if (coroutine_marker(v->text)) {
            if (split_creation && strstr(v->text, "_COROUTINE._CREATION.")) {
                im->diag.creation_marker_splits++;
                break; /* creation stack follows: not callers of the suspended frames */
            }
            text_frame(im, v->text, &f);
            f.kind = JVM_FRAME_COROUTINE_MARKER;
        } else
            text_frame(im, v->text, &f);
        int rc = push_frame(im, r, &f);
        if (rc < 0)
            return fail(im, "out of memory");
        if (rc)
            break;
    }
    return 0;
}
static int import_thread_dump(struct jvm_import *im, const char *text, size_t length)
{
    struct jj_arena arena = {.budget = im->budget};
    struct jj_value root;
    int rc = whole_json(im, text, length, &arena, &root);
    const struct jj_value *d = rc ? NULL : jj_get(&root, "threadDump");
    if (!rc && (!d || d->type != JJ_OBJECT))
        rc = fail(im, "not a jcmd Thread.dump_to_file JSON document");
    if (!rc) {
        im->runtime_version = intern(im, jj_str(d, "runtimeVersion"));
        im->collected_at = intern(im, jj_str(d, "time"));
        int64_t pid;
        if (!jj_i64(jj_get(d, "processId"), &pid)) {
            im->pid = pid;
            im->has_pid = 1;
        }
        const struct jj_value *cs = jj_get(d, "threadContainers");
        uint64_t ordinal = 0;
        for (uint32_t c = 0; !rc && cs && cs->type == JJ_ARRAY && c < cs->count; c++) {
            const struct jj_value *container = &cs->items[c];
            const struct jj_value *ts = jj_get(container, "threads");
            char path[96];
            for (uint32_t t = 0; !rc && ts && ts->type == JJ_ARRAY && t < ts->count; t++, ordinal++) {
                if (jvm_bcancelled(im->budget) || import_broken(im)) {
                    rc = -1;
                    break;
                }
                im->records_scanned++;
                const struct jj_value *th = &ts->items[t];
                struct jvm_record *r = new_record(im, JVM_THREAD_DUMP_STACK, ordinal);
                if (!r) {
                    rc = im->error[0] ? -1 : 1;
                    break;
                }
                snprintf(path, sizeof(path), "threadDump.threadContainers[%u].threads[%u]", c, t);
                r->byte_start = th->start;
                r->byte_end = th->end;
                r->path = intern(im, path);
                r->detail = intern(im, jj_str(container, "container"));
                record_time(im, r, jvm_str(im, im->collected_at));
                r->truncated = JVM_TRUNC_UNREPORTED;
                r->name = intern(im, jj_str(th, "name"));
                if ((rc = text_stack(im, r, jj_get(th, "stack"), 0)))
                    break;
                struct jvm_thread key = {.is_virtual = JVM_UNKNOWN};
                int64_t tid;
                if (!jj_i64(jj_get(th, "tid"), &tid)) {
                    key.java_tid = tid;
                    key.has_java_tid = 1;
                } else
                    im->diag.missing_thread++;
                rc = attach_thread(im, r, &key);
                if (!rc)
                    im->record_count++;
            }
        }
        if (!cs)
            rc = fail(im, "thread dump lacks threadContainers");
    }
    jj_arena_free(&arena);
    return rc < 0 ? -1 : 0;
}
static int import_probes(struct jvm_import *im, const char *text, size_t length)
{
    struct jj_arena arena = {.budget = im->budget};
    struct jj_value root;
    int rc = whole_json(im, text, length, &arena, &root);
    const char *format = rc ? NULL : jj_str(&root, "format");
    if (!rc && (!format || strcmp(format, "xodb-c06-coroutine-probes")))
        rc = fail(im, "not an xodb-c06-coroutine-probes document");
    if (!rc) {
        int64_t version;
        if (jj_i64(jj_get(&root, "version"), &version) || version != 1)
            rc = fail(im, "unsupported coroutine probe dump version");
    }
    if (!rc) {
        im->runtime_version = intern(im, jj_str(&root, "runtime_version"));
        im->collected_at = intern(im, jj_str(&root, "wall_time"));
        im->probe_nano = intern(im, jj_str(&root, "nano_time"));
        const struct jj_value *installed = jj_get(&root, "probes_installed");
        im->probes_installed = installed && installed->type == JJ_TRUE;
        int64_t pid;
        if (!jj_i64(jj_get(&root, "pid"), &pid)) {
            im->pid = pid;
            im->has_pid = 1;
        }
        const struct jj_value *cs = jj_get(&root, "coroutines");
        for (uint32_t i = 0; !rc && cs && cs->type == JJ_ARRAY && i < cs->count; i++) {
            const struct jj_value *c = &cs->items[i];
            if (jvm_bcancelled(im->budget) || import_broken(im)) {
                rc = -1;
                break;
            }
            im->records_scanned++;
            struct jvm_record *r = new_record(im, JVM_COROUTINE_STACK, i);
            if (!r) {
                rc = im->error[0] ? -1 : 1;
                break;
            }
            char path[48];
            snprintf(path, sizeof(path), "coroutines[%u]", i);
            r->path = intern(im, path);
            r->byte_start = c->start;
            r->byte_end = c->end;
            record_time(im, r, jvm_str(im, im->collected_at));
            r->truncated = JVM_TRUNC_UNREPORTED;
            if (jj_i64(jj_get(c, "sequence"), &r->coroutine_seq)) {
                rc = fail(im, "coroutine %u lacks sequence", i);
                break;
            }
            r->has_coroutine_id = !jj_i64(jj_get(c, "coroutine_id"), &r->coroutine_id);
            r->has_parent = !jj_i64(jj_get(c, "parent_sequence"), &r->parent_seq);
            r->parent_relation = intern(im, jj_str(c, "parent_relation"));
            r->detail = intern(im, jj_str(c, "name"));
            r->state = intern(im, jj_str(c, "state"));
            if ((rc = text_stack(im, r, jj_get(c, "last_observed_frames"), 1)))
                break;
            struct jvm_record shadow = *r; /* creation frames, stored after the logical stack */
            shadow.frame_start = (uint32_t)im->stack_used;
            shadow.frame_count = 0;
            if ((rc = text_stack(im, &shadow, jj_get(c, "creation_frames"), 0)))
                break;
            r->creation_start = shadow.frame_start;
            r->creation_count = shadow.frame_count;
            const struct jj_value *lt = jj_get(c, "last_thread");
            if (lt && lt->type == JJ_OBJECT) {
                struct jvm_thread key = {.is_virtual = JVM_UNKNOWN};
                const struct jj_value *virt = jj_get(lt, "virtual");
                if (virt && (virt->type == JJ_TRUE || virt->type == JJ_FALSE))
                    key.is_virtual = virt->type == JJ_TRUE ? JVM_YES : JVM_NO;
                int64_t tid;
                if (!jj_i64(jj_get(lt, "java_thread_id"), &tid)) {
                    key.java_tid = tid;
                    key.has_java_tid = 1;
                }
                r->name = intern(im, jj_str(lt, "name"));
                rc = attach_thread(im, r, &key);
            }
            if (!rc)
                im->record_count++;
        }
        if (!cs)
            rc = fail(im, "probe dump lacks coroutines");
    }
    jj_arena_free(&arena);
    return rc < 0 ? -1 : 0;
}
/* --- jcmd Thread.print text --- */
static uint32_t intern_line(struct jvm_import *im, const char *s, size_t n)
{
    if (jj_utf8_valid(s, n))
        return intern_n(im, s, n);
    im->diag.invalid_utf8_lines++;
    char *o = n < SIZE_MAX / 3 ? jvm_balloc(im->budget, n * 3 + 1) : NULL;
    if (!o) {
        nomem(im);
        return 0;
    }
    size_t k = 0;
    for (size_t i = 0; i < n;) { /* replace each invalid byte with U+FFFD */
        size_t step = jj_utf8_one((const unsigned char *)s + i, n - i);
        if (step) {
            memcpy(o + k, s + i, step);
            k += step;
            i += step;
        } else {
            memcpy(o + k, "\xef\xbf\xbd", 3);
            k += 3;
            i++;
        }
    }
    uint32_t id = intern_n(im, o, k);
    jvm_bfree(im->budget, o);
    return id;
}
/* C05-R3: a non-negative decimal or 0x-hexadecimal integer that lies wholly in
 * [s, limit). Unlike strtoll it skips no white space (so it never continues on a
 * following line) and never reads at or beyond limit. */
static int parse_number(const char *s, const char *limit, const char **end, int64_t *out)
{
    int hex = limit - s > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X');
    const char *p = s + (hex ? 2 : 0), *start = p;
    uint64_t v = 0;
    for (; p < limit; p++) {
        int d = *p >= '0' && *p <= '9' ? *p - '0'
                : hex && *p >= 'a' && *p <= 'f' ? *p - 'a' + 10
                : hex && *p >= 'A' && *p <= 'F' ? *p - 'A' + 10 : -1;
        if (d < 0)
            break;
        if (v > ((uint64_t)INT64_MAX - (uint64_t)d) / (hex ? 16 : 10))
            return -1;
        v = v * (hex ? 16 : 10) + (uint64_t)d;
    }
    if (p == start)
        return -1;
    *end = p;
    *out = (int64_t)v;
    return 0;
}
/* C05-R3: fixed-prefix test bounded by the span [p, e). */
static int has_prefix(const char *p, const char *e, const char *lit)
{
    size_t n = strlen(lit);
    return e >= p && (size_t)(e - p) >= n && !memcmp(p, lit, n);
}
static const char *field(const char *s, const char *end, const char *name)
{
    size_t n = strlen(name);
    for (const char *p = s; p + n <= end; p++)
        if ((p == s || p[-1] == ' ') && !memcmp(p, name, n))
            return p + n;
    return NULL;
}
static int thread_header(struct jvm_import *im, struct jvm_record *r, const char *s,
                         const char *end)
{
    const char *anchor = field(s, end, "tid=0x");
    if (!anchor)
        anchor = field(s, end, "os_prio=");
    const char *close = NULL;
    if (*s != '"')
        close = s - 1; /* HotSpot prints unnamed VM threads without a name field */
    else
        for (const char *p = s + 1; p < (anchor ? anchor : end); p++)
            if (*p == '"')
                close = p;
    if (!close || !anchor) {
        im->diag.unparsed_lines++;
        return 1;
    }
    if (*s == '"')
        r->name = intern_line(im, s + 1, (size_t)(close - s - 1));
    struct jvm_thread key = {.is_virtual = JVM_UNKNOWN};
    const char *p = close + 1, *e;
    int64_t v;
    if (p + 2 < end && p[0] == ' ' && p[1] == '#' && !parse_number(p + 2, end, &e, &v)) {
        key.java_tid = v;
        key.has_java_tid = 1;
        p = e;
        key.is_virtual = JVM_NO; /* Thread.print lists platform threads only */
    } else
        key.vm_internal = 1;
    if (p + 2 < end && p[0] == ' ' && p[1] == '[' && !parse_number(p + 2, end, &e, &v) && e < end && *e == ']') {
        key.os_tid = v;
        key.has_os_tid = 1;
    }
    const char *nid = field(s, end, "nid=");
    if (nid && !parse_number(nid, end, &e, &v)) {
        if (key.has_os_tid && key.os_tid != v)
            im->diag.nid_mismatch++;
        else if (!key.has_os_tid && v > 0) {
            key.os_tid = v;
            key.has_os_tid = 1;
        }
    }
    const char *tid = field(s, end, "tid=");
    if (tid) {
        size_t n = 0;
        while (tid + n < end && strchr("0123456789abcdefxABCDEF", tid[n]) && tid[n])
            n++;
        if (n > 2)
            key.vm_address = intern_n(im, tid, n);
    }
    r->detail = intern_line(im, s, (size_t)(end - s)); /* full header retained */
    return attach_thread(im, r, &key);
}
static int import_thread_print(struct jvm_import *im, const char *text, size_t length)
{
    const char *p = text, *end = text + length;
    uint64_t line_no = 0, ordinal = 0;
    struct jvm_record *r = NULL;
    while (p < end) {
        if (jvm_bcancelled(im->budget))
            return -1;
        if (import_broken(im))
            return fail(im, "out of memory");
        const char *nl = memchr(p, '\n', (size_t)(end - p));
        const char *e = nl ? nl : end;
        if (e > p && e[-1] == '\r') { /* C05-R4: CRLF line ending */
            e--;
            im->diag.crlf_lines++;
        }
        line_no++;
        if (line_no <= 3 && e > p) {
            int64_t pid;
            const char *after;
            if (line_no == 1 && !parse_number(p, e, &after, &pid) && after < e && *after == ':' &&
                after + 1 == e) {
                im->pid = pid;
                im->has_pid = 1;
            } else if (e - p > 17 && has_prefix(p, e, "Full thread dump ")) {
                im->dump_header = intern_line(im, p, (size_t)(e - p));
                const char *name = p + 17;
                const char *open = memchr(name, '(', (size_t)(e - name));
                const char *sp = open ? memchr(open, ' ', (size_t)(e - open)) : NULL;
                if (open && sp)
                    im->runtime_version = intern_line(im, open + 1, (size_t)(sp - open - 1));
                /* C05-R3: "(" directly after the prefix leaves an empty name, never a
                 * negative length. */
                const char *name_end = open ? (open > name && open[-1] == ' ' ? open - 1 : open) : e;
                im->jvm_name = name_end > name ? intern_line(im, name, (size_t)(name_end - name)) : 0;
            } else if (line_no == 2 && e - p == 19 && p[4] == '-' && p[10] == ' ') {
                /* C05-R4: repaired like every other line; local wall time with
                 * no zone, so a valid one is "unzoned", anything else "malformed"
                 * (or the calendar/clock reason). */
                im->collected_at = intern_line(im, p, 19);
                char iso[21];
                memcpy(iso, p, 19);
                iso[10] = 'T';
                iso[19] = 'Z';
                iso[20] = 0;
                int64_t ignored;
                int st = jvm_parse_iso_time(iso, &ignored);
                im->collected_status = (uint8_t)(st == JVM_TIME_OK ? JVM_TIME_UNZONED : st);
            }
        }
        if (e > p && (*p == '"' || (e - p > 8 && has_prefix(p, e, "os_prio=")))) {
            if (r && !im->incomplete)
                im->record_count++;
            r = new_record(im, JVM_THREAD_PRINT_STACK, ordinal++);
            im->records_scanned++;
            if (!r)
                return im->error[0] ? -1 : 0;
            r->line_start = r->line_end = line_no;
            r->byte_start = (uint64_t)(p - text);
            r->byte_end = (uint64_t)(e - text);
            r->truncated = JVM_TRUNC_UNREPORTED;
            r->time_raw = im->collected_at;
            r->time_status = im->collected_at ? im->collected_status : JVM_TIME_ABSENT;
            int rc = thread_header(im, r, p, e);
            if (rc < 0)
                return -1;
            if (rc > 0) {
                r = NULL;
                if (im->incomplete)
                    return 0;
            }
        } else if (r && e - p > 4 && has_prefix(p, e, "\tat ")) {
            uint32_t id = intern_line(im, p + 4, (size_t)(e - p - 4));
            if (!id) /* C05-R4: the line could not be stored */
                return fail(im, "out of memory");
            struct jvm_frame f;
            text_frame(im, jvm_str(im, id), &f);
            int rc = push_frame(im, r, &f);
            if (rc < 0)
                return fail(im, "out of memory");
            r->line_end = line_no;
            r->byte_end = (uint64_t)(e - text);
        } else if (r && e - p > 3 && has_prefix(p, e, "\t- ")) {
            im->diag.monitor_lines++;
            r->line_end = line_no;
            r->byte_end = (uint64_t)(e - text);
        } else if (r && e - p > 27 && has_prefix(p, e, "   java.lang.Thread.State: ")) {
            r->state = intern_line(im, p + 27, (size_t)(e - p - 27));
            r->line_end = line_no;
            r->byte_end = (uint64_t)(e - text);
        } else if (r && e == p) {
            /* blank line: the record may continue with lock information */
        } else if (r && e - p > 3 && has_prefix(p, e, "   ")) {
            r->line_end = line_no;
            r->byte_end = (uint64_t)(e - text);
        } else if (e > p && line_no > 3) {
            if (r && !im->incomplete)
                im->record_count++;
            r = NULL;
            /* C05-R3: every prefix test is bounded by the line (a 1-byte final line
             * was read 15 bytes past the input end on R2). */
            if (!has_prefix(p, e, "JNI global refs") && !has_prefix(p, e, "Threads class SMR") &&
                *p != '_' && !has_prefix(p, e, "0x") && *p != '}') /* SMR info block */
                im->diag.unparsed_lines++;
        }
        p = nl ? nl + 1 : end;
    }
    if (r && !im->incomplete)
        im->record_count++;
    if (!im->dump_header)
        return fail(im, "not a jcmd Thread.print document (no 'Full thread dump' header)");
    return 0;
}
/* --- entry points --- */
static void free_parts(struct jvm_import *im)
{
    struct jvm_budget *b = im->budget;
    jvm_bfree(b, im->strings.data);
    jvm_bfree(b, im->strings.offsets);
    jvm_bfree(b, im->strings.slots);
    jvm_bfree(b, im->frames);
    jvm_bfree(b, im->frame_slots);
    jvm_bfree(b, im->stack);
    jvm_bfree(b, im->threads);
    jvm_bfree(b, im->records);
}
void jvm_import_free(struct jvm_import *im)
{
    if (!im)
        return;
    struct jvm_budget *b = im->budget;
    free_parts(im);
    jvm_bfree(b, (char *)im->path);
    jvm_bfree(b, im);
}
enum { READ_CHUNK = 1 << 20 };
struct source_sink {
    struct jvm_budget *b;
    uint64_t max_bytes;
    const char *path;
    char *text;
    size_t length;
    int rc;
};
/* Called by xlf_read_stable with the pinned regular file open (and leased when
 * possible): bound the size, allocate the copy and read it, polling cancel. */
static enum xlf_status read_into_budget(void *ctx, int fd, uint64_t size, struct xlf_error *err)
{
    struct source_sink *s = ctx;
    if (size > s->max_bytes) {
        snprintf(err->message, sizeof err->message, "input %llu bytes exceeds byte budget %llu",
                 (unsigned long long)size, (unsigned long long)s->max_bytes);
        s->rc = -4;
        return err->status = XLF_E_LIMIT;
    }
    size_t length = (size_t)size;
    s->text = jvm_balloc(s->b, length + 1);
    if (!s->text) {
        snprintf(err->message, sizeof err->message, "%s for the %zu-byte source copy",
                 s->b && s->b->exhausted ? "whole-operation budget exhausted" : "out of memory", length);
        s->rc = -3;
        return err->status = XLF_E_MEMORY;
    }
    size_t got = 0;
    while (got < length) {
        if (jvm_bcancelled(s->b)) {
            snprintf(err->message, sizeof err->message, "cancelled while reading %s", s->path);
            s->rc = -5;
            return err->status = XLF_E_CANCELLED;
        }
        size_t want = length - got < READ_CHUNK ? length - got : READ_CHUNK;
        ssize_t n = read(fd, s->text + got, want);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            snprintf(err->message, sizeof err->message, "short read of %s", s->path);
            s->rc = -2;
            return err->status = XLF_E_IO;
        }
        got += (size_t)n;
    }
    s->text[length] = 0;
    s->length = length;
    return XLF_OK;
}
/* C05-R3: read a regular file once into a budgeted, NUL-terminated buffer.
 * C05-R4: through the reader's xlf_read_stable (pin, regular file only, read
 * lease, change checks); see jvm_import.h. Cancellation is polled before any
 * access and per MiB. */
int jvm_read_source_labelled(const char *path, struct jvm_budget *b, uint64_t max_bytes, char **out,
                             size_t *out_len, enum xlf_stability *stability, char *error, size_t error_size)
{
    *out = NULL;
    *out_len = 0;
    enum xlf_stability ignored;
    if (!stability)
        stability = &ignored;
    *stability = XLF_STABILITY_UNVERIFIED;
    if (jvm_bcancelled(b)) {
        snprintf(error, error_size, "cancelled before reading %s", path);
        return -5;
    }
    struct source_sink s = {.b = b, .max_bytes = max_bytes, .path = path, .rc = -2};
    struct xlf_error err = {0};
    enum xlf_status st = xlf_read_stable(path, read_into_budget, &s, stability, &err);
    if (st) {
        jvm_bfree(b, s.text);
        snprintf(error, error_size, "%s", err.message);
        return s.rc; /* the sink's code, else -2: refused by the stable read */
    }
    *out = s.text;
    *out_len = s.length;
    return 0;
}
int jvm_read_source(const char *path, struct jvm_budget *b, uint64_t max_bytes, char **out, size_t *out_len,
                    char *error, size_t error_size)
{
    return jvm_read_source_labelled(path, b, max_bytes, out, out_len, NULL, error, error_size);
}
/* An import charged to budget, or (budget NULL) to its own unlimited one. */
static struct jvm_import *new_import(struct jvm_budget *budget)
{
    struct jvm_import *im = jvm_bcalloc(budget, 1, sizeof(*im));
    if (im && !budget) {
        im->budget = &im->own_budget;
        jvm_bcharge(im->budget, sizeof(*im) + JVM_BUDGET_HEADER);
    } else if (im)
        im->budget = budget;
    return im;
}
int jvm_import_bytes(const char *text, size_t length, const char *label, enum jvm_source source,
                     const struct jvm_limits *limits, struct jvm_budget *budget, struct jvm_import **out)
{
    struct jvm_import *im = new_import(budget);
    *out = im;
    if (!im)
        return -3;
    im->source = source;
    im->limits = *limits;
    im->path = jvm_bstrndup(im->budget, label ? label : "", label ? strlen(label) : 0);
    if (!im->path) {
        snprintf(im->error, sizeof(im->error), "%s for the source label",
                 im->budget->exhausted ? "whole-operation budget exhausted" : "out of memory");
        return -3;
    }
    if (jvm_bcancelled(im->budget)) {
        fail(im, "cancelled before import");
        return -5;
    }
    if ((uint64_t)length > limits->max_bytes) {
        im->bytes = length;
        fail(im, "input %llu bytes exceeds byte budget %llu", (unsigned long long)length,
             (unsigned long long)limits->max_bytes);
        return -4;
    }
    im->bytes = length;
    if (sha256_hex_cancellable(text, length, im->sha256, im->budget)) {
        fail(im, "cancelled while hashing the source");
        return -5;
    }
    int rc;
    switch (source) {
    case JVM_SOURCE_JFR_JSON: rc = import_jfr(im, text, length); break;
    case JVM_SOURCE_THREAD_DUMP_JSON: rc = import_thread_dump(im, text, length); break;
    case JVM_SOURCE_THREAD_PRINT: rc = import_thread_print(im, text, length); break;
    case JVM_SOURCE_COROUTINE_PROBES: rc = import_probes(im, text, length); break;
    default: rc = fail(im, "unknown source kind");
    }
    /* Sticky outcomes win: a failed allocation may have surfaced as an absent
     * string, so exhaustion or OOM anywhere fails the whole import. */
    if (im->budget->cancelled) {
        snprintf(im->error, sizeof(im->error), "cancelled during import");
        return -5;
    }
    if (import_broken(im)) {
        snprintf(im->error, sizeof(im->error), "%s during import",
                 im->budget->exhausted ? "whole-operation budget exhausted" : "out of memory");
        return -3;
    }
    return rc ? -1 : 0;
}
int jvm_import_file(const char *path, enum jvm_source source, const struct jvm_limits *limits,
                    struct jvm_import **out)
{
    char *text, error[256] = "";
    size_t length;
    *out = NULL;
    enum xlf_stability stability;
    int rc = jvm_read_source_labelled(path, NULL, limits->max_bytes, &text, &length, &stability, error, sizeof error);
    if (rc) {
        struct jvm_import *im = new_import(NULL);
        if (!im)
            return -3;
        im->path = jvm_bstrndup(im->budget, path, strlen(path));
        snprintf(im->error, sizeof(im->error), "%s", error);
        *out = im;
        return rc;
    }
    rc = jvm_import_bytes(text, length, path, source, limits, NULL, out);
    if (*out)
        (*out)->source_stability = (uint8_t)stability;
    jvm_bfree(NULL, text);
    return rc;
}
