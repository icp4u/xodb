#define _GNU_SOURCE
#include "jitmap.h"
#include <stdlib.h>
#include <string.h>

/* Jitdump version 1 layout (all fields in the producer's byte order):
 *   header  u32 magic 'JiTD', u32 version, u32 total_size, u32 elf_mach,
 *           u32 pad1, u32 pid, u64 timestamp, u64 flags          (40 bytes)
 *   record  u32 id, u32 total_size, u64 timestamp                 (16 bytes)
 *   LOAD    u32 pid, u32 tid, u64 vma, u64 code_addr, u64 code_size,
 *           u64 code_index, char name[] NUL, u8 code[code_size]
 *   MOVE    u32 pid, u32 tid, u64 vma, u64 old_code_addr, u64 new_code_addr,
 *           u64 code_size, u64 code_index
 *   DEBUG   u64 code_addr, u64 nr_entry, { u64 addr, u32 line, u32 discrim,
 *           char name[] NUL ("\xff\0" repeats the previous name) }
 *   CLOSE   no body
 *   UNWIND  u64 unwinding_size, u64 eh_frame_hdr_size, u64 mapped_size,
 *           u8 data[unwinding_size]
 * total_size frames every record; trailing padding is permitted and counted.
 * No alignment is assumed: every field is loaded with memcpy.
 *
 * Work, memory and cancellation follow the C07-R2 contract, as amended by
 * C07-R3 (contract v3): every step is charged to a per-call meter before it
 * runs, all storage (scratch and metadata copies included) is charged to
 * model->memory before it is allocated, and failed or stopped adds roll back. */

#ifndef __SIZEOF_INT128__
#error "jitmap.c needs __int128 (GCC or Clang on a 64-bit host)"
#endif
typedef __int128 wide;

#ifdef XODB_JIT_FAULT_INJECTION
/* Test builds route every allocation through a countdown injector. */
void *xodb_jit_test_malloc(size_t size);
void *xodb_jit_test_realloc(void *ptr, size_t size);
#define malloc xodb_jit_test_malloc
#define realloc xodb_jit_test_realloc
#endif

#define JITDUMP_MAGIC 0x4A695444u
#define JITDUMP_MAGIC_SWAPPED 0x4454694Au
#define JITDUMP_HEADER 40u
#define JITDUMP_RECORD 16u
#define JITDUMP_FLAG_ARCH_TIMESTAMP 1ull
#define LOAD_FIXED (JITDUMP_RECORD + 40u)
#define MOVE_FIXED (JITDUMP_RECORD + 48u)
#define DEBUG_FIXED (JITDUMP_RECORD + 16u)
#define DEBUG_ENTRY_MIN 17u
#define UNWIND_FIXED (JITDUMP_RECORD + 24u)
#define SORT_CHUNK 4096u

void xodb_jit_limits_default(struct xodb_jit_limits *limits)
{
    limits->max_input_bytes = 256u << 20;
    limits->max_records = 4u << 20;
    limits->max_versions = 1u << 20;
    limits->max_debug_entries = 4u << 20;
    limits->max_name_bytes = 64u << 10;
    limits->max_line_bytes = 64u << 10;
    limits->max_diagnostics = 4096;
    limits->max_memory_bytes = 1024u << 20;
    limits->max_prepare_work = 1ull << 31;
    limits->max_query_work = 1u << 16;
}

void xodb_jit_model_init(struct xodb_jit_model *model, const struct xodb_jit_limits *limits)
{
    memset(model, 0, sizeof *model);
    if (limits)
        model->limits = *limits;
    else
        xodb_jit_limits_default(&model->limits);
}

static void free_meta(struct xodb_jit_source_meta *meta)
{
    free((char *)meta->artifact_sha256);
    free((char *)meta->label);
    free((char *)meta->map.measured_by);
}

static void free_source(struct xodb_jit_source *source)
{
    free(source->bytes);
    free_meta(&source->meta);
    free(source->index.coords);
    free(source->index.first);
    free(source->index.entries);
}

void xodb_jit_model_free(struct xodb_jit_model *model)
{
    for (size_t i = 0; i < model->source_count; ++i)
        free_source(&model->sources[i]);
    free(model->sources);
    free(model->versions);
    free(model->debug);
    free(model->unwinds);
    free(model->diags);
    memset(model, 0, sizeof *model);
}

/* ---- cancellation and work ---------------------------------------------- */

void xodb_jit_cancel_init(struct xodb_jit_cancel *cancel)
{
    __atomic_store_n(&cancel->requested, 0, __ATOMIC_RELEASE);
}

void xodb_jit_cancel_request(struct xodb_jit_cancel *cancel)
{
    __atomic_store_n(&cancel->requested, 1, __ATOMIC_RELEASE);
}

void xodb_jit_cancel_reset(struct xodb_jit_cancel *cancel)
{
    __atomic_store_n(&cancel->requested, 0, __ATOMIC_RELEASE);
}

int xodb_jit_cancel_requested(const struct xodb_jit_cancel *cancel)
{
    return __atomic_load_n(&cancel->requested, __ATOMIC_ACQUIRE) != 0;
}

struct meter {
    uint64_t used, limit;
    const struct xodb_jit_cancel *cancel;
    uint32_t stop;
};

static void meter_init(struct meter *m, const struct xodb_jit_control *control, uint64_t limit)
{
    m->used = 0;
    m->limit = control && control->work_limit && control->work_limit < limit ? control->work_limit : limit;
    m->cancel = control ? control->cancel : NULL;
    m->stop = XODB_JIT_STOP_NONE;
}

/* Charge units before the step they pay for; refuse once stopped. */
static int spend(struct meter *m, uint64_t units)
{
    if (m->stop == XODB_JIT_STOP_NONE && m->cancel && xodb_jit_cancel_requested(m->cancel))
        m->stop = XODB_JIT_STOP_CANCELLED;
    if (m->stop == XODB_JIT_STOP_NONE && units > m->limit - m->used)
        m->stop = XODB_JIT_STOP_WORK;
    if (m->stop == XODB_JIT_STOP_CANCELLED)
        return XODB_JIT_E_CANCELLED;
    if (m->stop == XODB_JIT_STOP_WORK)
        return XODB_JIT_E_WORK;
    m->used += units;
    return XODB_JIT_OK;
}

/* ---- memory ------------------------------------------------------------- */

static int charge(struct xodb_jit_model *model, size_t bytes)
{
    if (model->memory > model->limits.max_memory_bytes || bytes > model->limits.max_memory_bytes - model->memory)
        return XODB_JIT_E_BUDGET;
    model->memory += bytes;
    if (model->memory > model->memory_peak)
        model->memory_peak = model->memory;
    return XODB_JIT_OK;
}

/* Grow an array, charging the model's memory budget for the new capacity. */
static int grow(struct xodb_jit_model *model, void **items, size_t *cap, size_t size, size_t need)
{
    if (need <= *cap)
        return XODB_JIT_OK;
    size_t next = *cap ? *cap : 16;
    while (next < need) {
        if (next > SIZE_MAX / 2)
            return XODB_JIT_E_BUDGET;
        next *= 2;
    }
    if (next > SIZE_MAX / size)
        return XODB_JIT_E_BUDGET;
    size_t more = (next - *cap) * size;
    if (charge(model, more))
        return XODB_JIT_E_BUDGET;
    void *grown = realloc(*items, next * size);
    if (!grown) {
        model->memory -= more;
        return XODB_JIT_E_NOMEM;
    }
    *items = grown;
    *cap = next;
    return XODB_JIT_OK;
}

/* Charged allocation of count * size bytes (scratch or index storage). */
static void *charged_alloc(struct xodb_jit_model *model, size_t count, size_t size, int *error)
{
    if (count > SIZE_MAX / size) {
        *error = XODB_JIT_E_BUDGET;
        return NULL;
    }
    size_t bytes = count * size;
    if ((*error = charge(model, bytes ? bytes : 1)))
        return NULL;
    void *p = malloc(bytes ? bytes : 1);
    if (!p) {
        model->memory -= bytes ? bytes : 1;
        *error = XODB_JIT_E_NOMEM;
    }
    return p;
}

static void charged_free(struct xodb_jit_model *model, void *p, size_t count, size_t size)
{
    if (!p)
        return;
    free(p);
    model->memory -= count && size ? count * size : 1;
}

static void diag(struct xodb_jit_model *model, uint32_t source, uint32_t code, uint64_t ordinal,
                 uint64_t offset, uint64_t value)
{
    if (model->diag_count >= model->limits.max_diagnostics ||
        grow(model, (void **)&model->diags, &model->diag_cap, sizeof *model->diags, model->diag_count + 1)) {
        model->diags_dropped++;
        return;
    }
    model->diags[model->diag_count++] = (struct xodb_jit_diag){source, code, ordinal, offset, value};
}

/* Metadata strings are copied up to META_TEXT_MAX bytes. Their lengths are
 * measured first so the whole source charge is admitted before any copy. */
#define META_TEXT_MAX 4096u

static size_t text_cost(const char *text)
{
    return text ? strnlen(text, META_TEXT_MAX) + 1 : 0;
}

static char *copy_text(const char *text, size_t cost)
{
    if (!text)
        return NULL;
    char *copy = malloc(cost);
    if (copy) {
        memcpy(copy, text, cost - 1);
        copy[cost - 1] = 0;
    }
    return copy;
}

static int utf8_valid(const uint8_t *s, size_t n)
{
    size_t i = 0;
    while (i < n) {
        uint8_t c = s[i];
        size_t extra;
        uint32_t cp;
        if (c < 0x80) {
            ++i;
            continue;
        } else if ((c & 0xe0) == 0xc0) {
            extra = 1;
            cp = c & 0x1f;
        } else if ((c & 0xf0) == 0xe0) {
            extra = 2;
            cp = c & 0x0f;
        } else if ((c & 0xf8) == 0xf0) {
            extra = 3;
            cp = c & 0x07;
        } else {
            return 0;
        }
        if (extra > n - i - 1)
            return 0;
        for (size_t k = 1; k <= extra; ++k) {
            if ((s[i + k] & 0xc0) != 0x80)
                return 0;
            cp = cp << 6 | (s[i + k] & 0x3f);
        }
        if ((extra == 1 && cp < 0x80) || (extra == 2 && cp < 0x800) || (extra == 3 && cp < 0x10000) ||
            cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff))
            return 0;
        i += extra + 1;
    }
    return 1;
}

/* ---- preparation transaction -------------------------------------------- */

struct prep {
    struct xodb_jit_model *model;
    struct meter meter;
    size_t sources, versions, debug, unwinds, diags;
    uint64_t dropped;
};

static void prep_begin(struct prep *p, struct xodb_jit_model *model, const struct xodb_jit_control *control)
{
    p->model = model;
    meter_init(&p->meter, control, model->limits.max_prepare_work);
    p->sources = model->source_count;
    p->versions = model->version_count;
    p->debug = model->debug_count;
    p->unwinds = model->unwind_count;
    p->diags = model->diag_count;
    p->dropped = model->diags_dropped;
    model->memory_peak = model->memory;
}

/* Undo everything the call added except grown capacity, which stays charged. */
static void prep_rollback(struct prep *p)
{
    struct xodb_jit_model *model = p->model;
    while (model->source_count > p->sources) {
        struct xodb_jit_source *source = &model->sources[--model->source_count];
        model->memory -= source->charged;
        free_source(source);
        memset(source, 0, sizeof *source);
    }
    model->version_count = p->versions;
    model->debug_count = p->debug;
    model->unwind_count = p->unwinds;
    model->diag_count = p->diags;
    model->diags_dropped = p->dropped;
}

static int prep_end(struct prep *p, int error, int fatal, struct xodb_jit_control *control, int *source_index)
{
    if (fatal) {
        prep_rollback(p);
        if (source_index)
            *source_index = -1;
    } else if (p->model->source_count > p->sources) {
        p->model->sources[p->model->source_count - 1].build_work = p->meter.used;
    }
    if (control) {
        control->work = p->meter.used;
        control->memory_peak = p->model->memory_peak;
        control->stop = p->meter.stop;
    }
    return error;
}

/* Stable bottom-up merge sort of u32 keys, charged one unit per element per
 * pass in chunks of SORT_CHUNK; scratch is charged while it exists. */
typedef int (*less_fn)(const void *ctx, uint32_t a, uint32_t b);

static int sort_u32(struct prep *p, uint32_t *a, size_t n, less_fn less, const void *ctx)
{
    if (n < 2)
        return XODB_JIT_OK;
    int error;
    uint32_t *tmp = charged_alloc(p->model, n, sizeof *tmp, &error), *src = a, *dst = tmp;
    if (!tmp)
        return error;
    for (size_t width = 1; width < n; width *= 2) {
        size_t k = 0;
        for (size_t lo = 0; lo < n; lo += 2 * width) {
            size_t mid = lo + width < n ? lo + width : n, hi = lo + 2 * width < n ? lo + 2 * width : n;
            size_t i = lo, j = mid;
            while (k < hi) {
                if (k % SORT_CHUNK == 0 && (error = spend(&p->meter, n - k < SORT_CHUNK ? n - k : SORT_CHUNK)))
                    goto out;
                if (i < mid && (j >= hi || !less(ctx, src[j], src[i])))
                    dst[k++] = src[i++];
                else
                    dst[k++] = src[j++];
            }
        }
        uint32_t *swap = src;
        src = dst;
        dst = swap;
    }
    if (src != a)
        memcpy(a, src, n * sizeof *a);
out:
    charged_free(p->model, tmp, n, sizeof *tmp);
    return error;
}

/* Append a source holding a private copy of the input and metadata strings. */
static int add_source(struct prep *p, uint32_t kind, const struct xodb_jit_source_meta *meta, const uint8_t *bytes,
                      size_t len, struct xodb_jit_source **out)
{
    struct xodb_jit_model *model = p->model;
    if (len > model->limits.max_input_bytes)
        return XODB_JIT_E_BUDGET;
    int error = spend(&p->meter, len / 4096 + 1);
    if (error)
        return error;
    if (model->source_count >= UINT32_MAX)
        return XODB_JIT_E_BUDGET;
    if ((error = grow(model, (void **)&model->sources, &model->source_cap, sizeof *model->sources,
                      model->source_count + 1)))
        return error;
    /* Admit the input copy and every metadata copy before allocating any. */
    size_t sha = text_cost(meta->artifact_sha256), label = text_cost(meta->label),
           measured = text_cost(meta->map.measured_by), total = len ? len : 1;
    if (total > SIZE_MAX - sha - label - measured)
        return XODB_JIT_E_BUDGET;
    total += sha + label + measured;
    if ((error = charge(model, total)))
        return error;
    struct xodb_jit_source *source = &model->sources[model->source_count];
    memset(source, 0, sizeof *source);
    source->charged = total;
    source->kind = kind;
    source->meta = *meta;
    source->meta.artifact_sha256 = copy_text(meta->artifact_sha256, sha);
    source->meta.label = copy_text(meta->label, label);
    source->meta.map.measured_by = copy_text(meta->map.measured_by, measured);
    source->bytes = malloc(len ? len : 1);
    if (!source->bytes || (sha && !source->meta.artifact_sha256) || (label && !source->meta.label) ||
        (measured && !source->meta.map.measured_by)) {
        free_source(source);
        model->memory -= total;
        memset(source, 0, sizeof *source);
        return XODB_JIT_E_NOMEM;
    }
    if (len)
        memcpy(source->bytes, bytes, len);
    source->len = len;
    source->version_first = model->version_count;
    model->source_count++;
    *out = source;
    return XODB_JIT_OK;
}

static int new_version(struct xodb_jit_model *model, struct xodb_jit_version **out)
{
    if (model->version_count >= model->limits.max_versions || model->version_count >= UINT32_MAX - 1)
        return XODB_JIT_E_BUDGET;
    int error = grow(model, (void **)&model->versions, &model->version_cap, sizeof *model->versions,
                     model->version_count + 1);
    if (error)
        return error;
    struct xodb_jit_version *v = &model->versions[model->version_count];
    memset(v, 0, sizeof *v);
    v->id = (uint32_t)++model->version_count;
    v->unwind_record = -1;
    *out = v;
    return XODB_JIT_OK;
}

/* ---- index -------------------------------------------------------------- */

struct order_ctx {
    const struct xodb_jit_version *versions;
    size_t first;
};

/* Endpoint k of version (first + k / 2): its start when k is even, else its end. */
static uint64_t endpoint(const struct order_ctx *c, uint32_t k)
{
    const struct xodb_jit_version *v = &c->versions[c->first + k / 2];
    return k & 1 ? v->start + v->size : v->start;
}

static int endpoint_less(const void *ctx, uint32_t a, uint32_t b)
{
    return endpoint(ctx, a) < endpoint(ctx, b);
}

/* Index order: begin time ascending, then end descending with open ends
 * first, then version index. Begin windows are monotone in begin time and
 * end windows in end time, which is what the query's binary searches use. */
static int version_less(const void *ctx, uint32_t a, uint32_t b)
{
    const struct xodb_jit_version *va = &((const struct order_ctx *)ctx)->versions[a];
    const struct xodb_jit_version *vb = &((const struct order_ctx *)ctx)->versions[b];
    if (va->begin.time != vb->begin.time)
        return va->begin.time < vb->begin.time;
    int oa = !va->end.has_time, ob = !vb->end.has_time;
    if (oa != ob)
        return oa;
    if (!oa && va->end.time != vb->end.time)
        return va->end.time > vb->end.time;
    return a < b;
}

/* Visit the canonical segment-tree nodes of leaves [l, r): count or place. */
static int decompose(struct prep *p, size_t base, size_t l, size_t r, uint32_t *count, uint32_t *cursor,
                     uint32_t *entries, uint32_t value)
{
    int error;
#define PLACE(node)                                  \
    do {                                             \
        if ((error = spend(&p->meter, 1)))           \
            return error;                            \
        if (count)                                   \
            count[node]++;                           \
        else                                         \
            entries[cursor[node]++] = value;         \
    } while (0)
    for (l += base, r += base; l < r; l >>= 1, r >>= 1) {
        if ((error = spend(&p->meter, 1)))
            return error;
        if (l & 1) {
            PLACE(l);
            l++;
        }
        if (r & 1) {
            --r;
            PLACE(r);
        }
    }
#undef PLACE
    return XODB_JIT_OK;
}

static int build_index(struct prep *p, struct xodb_jit_source *source)
{
    struct xodb_jit_model *model = p->model;
    size_t v = source->version_count;
    if (!v)
        return XODB_JIT_OK;
    if (v > UINT32_MAX / 2)
        return XODB_JIT_E_BUDGET;
    struct order_ctx ctx = {model->versions, source->version_first};
    int error = XODB_JIT_OK;
    uint32_t *ends = NULL, *pos = NULL, *order = NULL, *cursor = NULL;
    size_t n = 2 * v, base = 1, nodes = 0;
    if (!(ends = charged_alloc(model, n, sizeof *ends, &error)))
        goto out;
    for (uint32_t k = 0; k < n; ++k)
        ends[k] = k;
    if ((error = sort_u32(p, ends, n, endpoint_less, &ctx)))
        goto out;
    if ((error = spend(&p->meter, n)))
        goto out;
    size_t m = 0;
    for (size_t k = 0; k < n; ++k)
        if (!k || endpoint(&ctx, ends[k]) != endpoint(&ctx, ends[k - 1]))
            m++;
    if (!(source->index.coords = charged_alloc(model, m, sizeof *source->index.coords, &error)))
        goto out;
    source->charged += m * sizeof *source->index.coords;
    if (!(pos = charged_alloc(model, n, sizeof *pos, &error)))
        goto out;
    m = 0;
    for (size_t k = 0; k < n; ++k) {
        uint64_t x = endpoint(&ctx, ends[k]);
        if (!m || source->index.coords[m - 1] != x)
            source->index.coords[m++] = x;
        pos[ends[k]] = (uint32_t)(m - 1);
    }
    source->index.coord_count = m;
    charged_free(model, ends, n, sizeof *ends);
    ends = NULL;
    while (base < m - 1)
        base *= 2;
    nodes = 2 * base + 1;
    if (!(source->index.first = charged_alloc(model, nodes, sizeof *source->index.first, &error)))
        goto out;
    source->charged += nodes * sizeof *source->index.first;
    source->index.base = base;
    memset(source->index.first, 0, nodes * sizeof *source->index.first);
    if (!(order = charged_alloc(model, v, sizeof *order, &error)))
        goto out;
    for (uint32_t i = 0; i < v; ++i)
        order[i] = (uint32_t)(source->version_first + i);
    if ((error = sort_u32(p, order, v, version_less, &ctx)))
        goto out;
    /* Count pass: first[node + 1] accumulates, then becomes offsets. */
    uint32_t *count = source->index.first + 1;
    for (size_t i = 0; i < v; ++i) {
        size_t k = order[i] - source->version_first;
        if ((error = decompose(p, base, pos[2 * k], pos[2 * k + 1], count, NULL, NULL, 0)))
            goto out;
    }
    uint64_t total = 0;
    for (size_t node = 1; node < nodes; ++node) {
        total += source->index.first[node];
        if (total > UINT32_MAX) {
            error = XODB_JIT_E_BUDGET;
            goto out;
        }
        source->index.first[node] = (uint32_t)total;
    }
    if (!(source->index.entries = charged_alloc(model, (size_t)total, sizeof *source->index.entries, &error)))
        goto out;
    source->charged += total ? total * sizeof *source->index.entries : 1;
    source->index.entry_count = (size_t)total;
    if (!(cursor = charged_alloc(model, nodes, sizeof *cursor, &error)))
        goto out;
    memcpy(cursor, source->index.first, nodes * sizeof *cursor);
    for (size_t i = 0; i < v; ++i) {
        size_t k = order[i] - source->version_first;
        if ((error = decompose(p, base, pos[2 * k], pos[2 * k + 1], NULL, cursor, source->index.entries, order[i])))
            goto out;
    }
out:
    charged_free(model, ends, n, sizeof *ends);
    charged_free(model, pos, n, sizeof *pos);
    charged_free(model, order, v, sizeof *order);
    charged_free(model, cursor, nodes, sizeof *cursor);
    return error;
}

/* ---- jitdump ------------------------------------------------------------ */

struct reader {
    const uint8_t *bytes;
    int swapped;
};

static uint32_t rd32(const struct reader *r, size_t offset)
{
    uint32_t v;
    memcpy(&v, r->bytes + offset, 4);
    return r->swapped ? __builtin_bswap32(v) : v;
}

static uint64_t rd64(const struct reader *r, size_t offset)
{
    uint64_t v;
    memcpy(&v, r->bytes + offset, 8);
    return r->swapped ? __builtin_bswap64(v) : v;
}

/* Load/move evidence collected in file order, ordered by time afterwards. */
struct event {
    uint32_t kind;
    uint64_t ordinal, offset, time;
    uint32_t pid, tid;
    uint64_t vma, from, to, size, index;
    uint64_t name_offset;
    uint32_t name_len;
    int has_code, not_utf8;
    uint64_t code_offset;
    uint64_t debug_first, debug_ordinal;
    uint32_t debug_count;
    int64_t unwind;
};

struct pending_debug {
    int active;
    uint64_t code_addr, first, ordinal, offset;
    uint32_t count;
};

struct pending_unwind {
    int active;
    int64_t index;
    uint64_t ordinal, offset;
};

static int ends_wrap(uint64_t start, uint64_t size)
{
    /* end = start + size must be representable: [start, end) never wraps. */
    return size > UINT64_MAX - start;
}

/* Producers pad debug and unwinding records to 8 bytes (perf's JVMTI agent
 * does); padding to the next 8-byte record size is not a diagnostic. */
static int alignment_padding(size_t at, size_t end, size_t used)
{
    return end - used < 8 && (end - at) % 8 == 0;
}

static int parse_debug(struct prep *p, uint32_t sid, const struct reader *r, size_t at, size_t end, uint64_t ordinal,
                       struct pending_debug *pending)
{
    struct xodb_jit_model *model = p->model;
    struct xodb_jit_source *source = &model->sources[sid];
    if (end - at < DEBUG_FIXED) {
        diag(model, sid, XODB_JIT_D_RECORD_TOO_SMALL, ordinal, at, XODB_JIT_REC_DEBUG_INFO);
        source->malformed_records++;
        return XODB_JIT_OK;
    }
    uint64_t code_addr = rd64(r, at + 16), count = rd64(r, at + 24);
    if (count > (end - at - DEBUG_FIXED) / DEBUG_ENTRY_MIN) {
        diag(model, sid, XODB_JIT_D_DEBUG_MALFORMED, ordinal, at, count);
        source->malformed_records++;
        return XODB_JIT_OK;
    }
    int error = spend(&p->meter, count);
    if (error)
        return error;
    if (count > model->limits.max_debug_entries - model->debug_count)
        return XODB_JIT_E_BUDGET;
    if ((error = grow(model, (void **)&model->debug, &model->debug_cap, sizeof *model->debug,
                      model->debug_count + (size_t)count)))
        return error;
    size_t q = at + DEBUG_FIXED, first = model->debug_count;
    uint64_t previous_offset = 0;
    uint32_t previous_len = 0;
    int have_previous = 0;
    for (uint64_t i = 0; i < count; ++i) {
        if (end - q < DEBUG_ENTRY_MIN)
            goto malformed;
        struct xodb_jit_debug_entry *e = &model->debug[model->debug_count];
        e->address = rd64(r, q);
        e->line = rd32(r, q + 8);
        e->discriminator = rd32(r, q + 12);
        e->in_range = 0;
        const uint8_t *name = r->bytes + q + 16;
        const uint8_t *nul = memchr(name, 0, end - (q + 16));
        if (!nul)
            goto malformed;
        size_t n = (size_t)(nul - name);
        if (n > model->limits.max_name_bytes)
            goto malformed;
        if (n == 1 && name[0] == 0xff) {
            if (!have_previous)
                goto malformed;
            e->file_offset = previous_offset;
            e->file_len = previous_len;
        } else {
            e->file_offset = q + 16;
            e->file_len = (uint32_t)n;
            previous_offset = e->file_offset;
            previous_len = e->file_len;
            have_previous = 1;
        }
        model->debug_count++;
        q += 16 + n + 1;
    }
    if (q != end && !alignment_padding(at, end, q))
        diag(model, sid, XODB_JIT_D_TRAILING_BYTES, ordinal, at, end - q);
    if (pending->active)
        diag(model, sid, XODB_JIT_D_DEBUG_UNMATCHED, pending->ordinal, pending->offset, pending->code_addr);
    *pending = (struct pending_debug){1, code_addr, first, ordinal, at, (uint32_t)count};
    return XODB_JIT_OK;
malformed:
    model->debug_count = first;
    diag(model, sid, XODB_JIT_D_DEBUG_MALFORMED, ordinal, at, count);
    source->malformed_records++;
    return XODB_JIT_OK;
}

static int parse_unwind(struct xodb_jit_model *model, uint32_t sid, const struct reader *r, size_t at, size_t end,
                        uint64_t ordinal, struct pending_unwind *pending)
{
    struct xodb_jit_source *source = &model->sources[sid];
    if (end - at < UNWIND_FIXED) {
        diag(model, sid, XODB_JIT_D_RECORD_TOO_SMALL, ordinal, at, XODB_JIT_REC_UNWINDING_INFO);
        source->malformed_records++;
        return XODB_JIT_OK;
    }
    uint64_t size = rd64(r, at + 16), hdr = rd64(r, at + 24), mapped = rd64(r, at + 32);
    if (size > end - at - UNWIND_FIXED || hdr > size) {
        diag(model, sid, XODB_JIT_D_UNWIND_MALFORMED, ordinal, at, size);
        source->malformed_records++;
        return XODB_JIT_OK;
    }
    if (end - at - UNWIND_FIXED != size && !alignment_padding(at, end, at + UNWIND_FIXED + size))
        diag(model, sid, XODB_JIT_D_TRAILING_BYTES, ordinal, at, end - at - UNWIND_FIXED - size);
    int error = grow(model, (void **)&model->unwinds, &model->unwind_cap, sizeof *model->unwinds,
                     model->unwind_count + 1);
    if (error)
        return error;
    model->unwinds[model->unwind_count] =
        (struct xodb_jit_unwind){sid, ordinal, at, size, hdr, mapped, at + UNWIND_FIXED};
    if (pending->active)
        diag(model, sid, XODB_JIT_D_UNWIND_UNMATCHED, pending->ordinal, pending->offset, 0);
    *pending = (struct pending_unwind){1, (int64_t)model->unwind_count++, ordinal, at};
    return XODB_JIT_OK;
}

static int event_less(const void *ctx, uint32_t a, uint32_t b)
{
    const struct event *ea = &((const struct event *)ctx)[a], *eb = &((const struct event *)ctx)[b];
    return ea->time != eb->time ? ea->time < eb->time : ea->ordinal < eb->ordinal;
}

static int index_less(const void *ctx, uint32_t a, uint32_t b)
{
    return ((const struct event *)ctx)[a].index < ((const struct event *)ctx)[b].index;
}

/* Build versions in (time, file ordinal) order. Per code_index state (dense
 * rank from a sort, so no hashing and no adversarial collisions): the number
 * of open versions and the most recently created one. A version can only be
 * closed while it is the single open version of its code_index, so when the
 * count is 1 the most recent one is that version. Every earlier version began
 * no later than the current event, so the original "loaded no later" test is
 * implied by the order. */
static int build_versions(struct prep *p, uint32_t sid, struct event *events, size_t n)
{
    struct xodb_jit_model *model = p->model;
    if (!n)
        return XODB_JIT_OK;
    if (n > UINT32_MAX)
        return XODB_JIT_E_BUDGET;
    int error;
    uint32_t *order = NULL, *rank = NULL, *open = NULL, *last = NULL;
    size_t distinct = 0;
    if (!(order = charged_alloc(model, n, sizeof *order, &error)) ||
        !(rank = charged_alloc(model, n, sizeof *rank, &error)))
        goto out;
    for (uint32_t i = 0; i < n; ++i)
        rank[i] = i;
    if ((error = sort_u32(p, rank, n, index_less, events)) || (error = spend(&p->meter, n)))
        goto out;
    /* order[] temporarily holds ranks by event position. */
    for (size_t i = 0; i < n; ++i) {
        if (i && events[rank[i]].index != events[rank[i - 1]].index)
            distinct++;
        order[rank[i]] = (uint32_t)distinct;
    }
    distinct++;
    memcpy(rank, order, n * sizeof *rank);
    for (uint32_t i = 0; i < n; ++i)
        order[i] = i;
    if ((error = sort_u32(p, order, n, event_less, events)))
        goto out;
    if (!(open = charged_alloc(model, distinct, sizeof *open, &error)) ||
        !(last = charged_alloc(model, distinct, sizeof *last, &error)))
        goto out;
    memset(open, 0, distinct * sizeof *open);
    uint64_t bias = model->sources[sid].meta.debug_address_bias;
    for (size_t i = 0; i < n; ++i) {
        struct event *e = &events[order[i]];
        uint32_t r = rank[order[i]];
        struct xodb_jit_version *v;
        if ((error = spend(&p->meter, 1 + (e->kind == XODB_JIT_REC_LOAD ? e->debug_count : 0))))
            goto out;
        if (e->kind == XODB_JIT_REC_LOAD) {
            int duplicate = open[r] > 0;
            if ((error = new_version(model, &v)))
                goto out;
            open[r]++;
            last[r] = v->id - 1;
            v->source = sid;
            v->code_index = e->index;
            v->has_code_index = 1;
            v->pid = e->pid;
            v->tid = e->tid;
            v->start = e->from;
            v->size = e->size;
            v->vma = e->vma;
            v->begin = (struct xodb_jit_bound){XODB_JIT_BOUND_LOAD, 1, e->time, e->ordinal, e->offset};
            v->name_offset = e->name_offset;
            v->name_len = e->name_len;
            v->code_offset = e->code_offset;
            v->debug_first = e->debug_first;
            v->debug_count = e->debug_count;
            v->debug_record_ordinal = e->debug_ordinal;
            v->unwind_record = e->unwind;
            v->line_base = e->debug_count ? v->id : 0;
            v->flags = (e->has_code ? XODB_JIT_V_HAS_CODE : 0) | (e->vma != e->from ? XODB_JIT_V_VMA_DIFFERS : 0) |
                       (e->not_utf8 ? XODB_JIT_V_NAME_NOT_UTF8 : 0);
            if (duplicate) {
                v->flags |= XODB_JIT_V_DUPLICATE_INDEX;
                diag(model, sid, XODB_JIT_D_DUPLICATE_INDEX, e->ordinal, e->offset, e->index);
            }
            int reported = 0;
            for (uint32_t k = 0; k < v->debug_count; ++k) {
                struct xodb_jit_debug_entry *d = &model->debug[v->debug_first + k];
                d->in_range = d->address >= bias && d->address - bias >= v->start && d->address - bias - v->start <= v->size;
                if (!d->in_range && !reported) {
                    diag(model, sid, XODB_JIT_D_DEBUG_OUT_OF_RANGE, v->debug_record_ordinal, e->offset, d->address);
                    reported = 1;
                }
            }
            continue;
        }
        /* MOVE: exactly one open version of code_index (loaded no later). */
        size_t matches = open[r], found = last[r];
        uint32_t predecessor = 0;
        if (matches == 0) {
            diag(model, sid, XODB_JIT_D_MOVE_UNKNOWN_INDEX, e->ordinal, e->offset, e->index);
        } else if (matches > 1) {
            diag(model, sid, XODB_JIT_D_MOVE_AMBIGUOUS_INDEX, e->ordinal, e->offset, e->index);
        } else if (model->versions[found].start != e->from) {
            diag(model, sid, XODB_JIT_D_MOVE_ADDRESS_MISMATCH, e->ordinal, e->offset, e->from);
        } else {
            struct xodb_jit_version *o = &model->versions[found];
            if (o->size != e->size)
                diag(model, sid, XODB_JIT_D_MOVE_SIZE_MISMATCH, e->ordinal, e->offset, e->size);
            o->end = (struct xodb_jit_bound){XODB_JIT_BOUND_MOVE_OUT, 1, e->time, e->ordinal, e->offset};
            predecessor = o->id;
            open[r]--;
        }
        if ((error = new_version(model, &v)))
            goto out;
        open[r]++;
        last[r] = v->id - 1;
        const struct xodb_jit_version *o = predecessor ? &model->versions[predecessor - 1] : NULL;
        v->source = sid;
        v->code_index = e->index;
        v->has_code_index = 1;
        v->pid = e->pid;
        v->tid = e->tid;
        v->start = e->to;
        v->size = e->size;
        v->vma = e->vma;
        v->begin = (struct xodb_jit_bound){XODB_JIT_BOUND_MOVE_IN, 1, e->time, e->ordinal, e->offset};
        v->predecessor = predecessor;
        v->name_offset = o ? o->name_offset : 0;
        v->name_len = o ? o->name_len : 0;
        if (o) {
            v->line_base = o->debug_count ? o->id : o->line_base;
            v->line_delta = (o->debug_count ? 0 : o->line_delta) + (v->start - o->start);
        }
        v->flags = (predecessor ? 0 : XODB_JIT_V_ORPHAN_MOVE) | (o ? o->flags & XODB_JIT_V_NAME_NOT_UTF8 : 0) |
                   (e->vma != e->to ? XODB_JIT_V_VMA_DIFFERS : 0);
    }
    error = XODB_JIT_OK;
out:
    charged_free(model, order, n, sizeof *order);
    charged_free(model, rank, n, sizeof *rank);
    charged_free(model, open, distinct, sizeof *open);
    charged_free(model, last, distinct, sizeof *last);
    return error;
}

static void finish_coverage(struct xodb_jit_source *source)
{
    int has = source->meta.has_coverage_end;
    uint64_t end = source->meta.coverage_end;
    if (source->kind == XODB_JIT_SOURCE_JITDUMP && (!source->complete || !has) && source->has_last_time) {
        /* Without declared coverage, or after a stop, evidence ends at the last record. */
        if (!has || source->last_time < end)
            end = source->last_time;
        has = 1;
    }
    if (source->closed && (!has || source->close_time < end)) {
        end = source->close_time;
        has = 1;
    }
    source->has_coverage = has;
    source->coverage_end = end;
}

static int fatal_error(int error)
{
    return error == XODB_JIT_E_NOMEM || error == XODB_JIT_E_WORK || error == XODB_JIT_E_CANCELLED;
}

int xodb_jit_add_jitdump_ctl(struct xodb_jit_model *model, const struct xodb_jit_source_meta *meta,
                             const uint8_t *bytes, size_t len, struct xodb_jit_control *control, int *source_index)
{
    if (source_index)
        *source_index = -1;
    if (control) {
        control->work = 0;
        control->memory_peak = model ? model->memory : 0;
        control->stop = XODB_JIT_STOP_NONE;
    }
    if (!model || !meta || (!bytes && len))
        return XODB_JIT_E_ARGUMENT;
    if (len < JITDUMP_HEADER)
        return XODB_JIT_E_HEADER;
    struct reader r = {bytes, 0};
    uint32_t magic;
    memcpy(&magic, bytes, 4);
    if (magic == JITDUMP_MAGIC_SWAPPED)
        r.swapped = 1;
    else if (magic != JITDUMP_MAGIC)
        return XODB_JIT_E_MAGIC;
    uint32_t version = rd32(&r, 4), header_size = rd32(&r, 8);
    if (version != 1)
        return XODB_JIT_E_VERSION;
    if (header_size < JITDUMP_HEADER || header_size > len)
        return XODB_JIT_E_HEADER;
    uint64_t flags = rd64(&r, 32);
    if (flags & ~JITDUMP_FLAG_ARCH_TIMESTAMP)
        return XODB_JIT_E_FLAGS;
    uint32_t pid = rd32(&r, 20);
    if (meta->process.pid && meta->process.pid != pid)
        return XODB_JIT_E_IDENTITY;
    int arch = (flags & JITDUMP_FLAG_ARCH_TIMESTAMP) != 0;
    if ((arch && meta->clock.kind == XODB_JIT_CLOCK_MONOTONIC) || (!arch && meta->clock.kind == XODB_JIT_CLOCK_ARCH))
        return XODB_JIT_E_CLOCK;

    struct prep p;
    prep_begin(&p, model, control);
    struct xodb_jit_source *source;
    int error = add_source(&p, XODB_JIT_SOURCE_JITDUMP, meta, bytes, len, &source);
    if (error)
        return prep_end(&p, error, 1, control, source_index);
    uint32_t sid = (uint32_t)(model->source_count - 1);
    if (source_index)
        *source_index = (int)sid;
    r.bytes = source->bytes;
    if (!source->meta.process.pid) {
        source->meta.process.pid = pid;
        source->meta.process.known = 0;
    }
    uint16_t probe = 1;
    int host_little = *(uint8_t *)&probe == 1;
    source->swapped = r.swapped;
    source->big_endian = host_little == r.swapped;
    source->version = version;
    source->header_size = header_size;
    source->elf_mach = rd32(&r, 12);
    source->header_pid = pid;
    source->header_time = rd64(&r, 24);
    source->header_flags = flags;
    source->arch_timestamp = arch;
    if (header_size > JITDUMP_HEADER)
        diag(model, sid, XODB_JIT_D_HEADER_EXTRA, 0, JITDUMP_HEADER, header_size);

    struct event *events = NULL;
    size_t event_count = 0, event_cap = 0;
    struct pending_debug debug = {0};
    struct pending_unwind unwind = {0};
    size_t at = header_size;
    uint64_t ordinal = 0, previous_time = 0;
    int stopped = 0;
    while (at < len) {
        ordinal++;
        if (len - at < JITDUMP_RECORD) {
            diag(model, sid, XODB_JIT_D_TRUNCATED_RECORD, ordinal, at, len - at);
            source->tail_truncated = 1;
            stopped = 1;
            break;
        }
        uint32_t id = rd32(&r, at), size = rd32(&r, at + 4);
        uint64_t time = rd64(&r, at + 8);
        if (size < JITDUMP_RECORD) {
            /* Framing lost: nothing after this point can be trusted. */
            diag(model, sid, XODB_JIT_D_RECORD_TOO_SMALL, ordinal, at, size);
            source->partial = 1;
            stopped = 1;
            break;
        }
        if (size > len - at) {
            diag(model, sid, XODB_JIT_D_TRUNCATED_RECORD, ordinal, at, size);
            source->tail_truncated = 1;
            stopped = 1;
            break;
        }
        if ((error = spend(&p.meter, 1 + size / 4096)))
            break;
        if (source->records >= model->limits.max_records) {
            diag(model, sid, XODB_JIT_D_BUDGET, ordinal, at, 0);
            source->partial = 1;
            stopped = 1;
            error = XODB_JIT_E_BUDGET;
            break;
        }
        size_t end = at + size;
        source->records++;
        if (source->closed)
            diag(model, sid, XODB_JIT_D_AFTER_CLOSE, ordinal, at, id);
        if (!time)
            diag(model, sid, XODB_JIT_D_TIME_ZERO, ordinal, at, id);
        if (source->has_last_time && time < previous_time)
            diag(model, sid, XODB_JIT_D_OUT_OF_ORDER, ordinal, at, time);
        previous_time = time;
        if (!source->has_last_time || time > source->last_time)
            source->last_time = time;
        if (!source->has_last_time || time < source->first_time)
            source->first_time = time;
        source->has_last_time = 1;
        if (id == XODB_JIT_REC_LOAD || id == XODB_JIT_REC_MOVE) {
            uint32_t fixed = id == XODB_JIT_REC_LOAD ? LOAD_FIXED + 1 : MOVE_FIXED;
            if (size < fixed) {
                diag(model, sid, XODB_JIT_D_RECORD_TOO_SMALL, ordinal, at, id);
                source->malformed_records++;
                goto next;
            }
            struct event e = {0};
            e.kind = id;
            e.ordinal = ordinal;
            e.offset = at;
            e.time = time;
            e.pid = rd32(&r, at + 16);
            e.tid = rd32(&r, at + 20);
            e.vma = rd64(&r, at + 24);
            e.unwind = -1;
            if (id == XODB_JIT_REC_LOAD) {
                e.from = rd64(&r, at + 32);
                e.size = rd64(&r, at + 40);
                e.index = rd64(&r, at + 48);
                const uint8_t *name = r.bytes + at + LOAD_FIXED;
                const uint8_t *nul = memchr(name, 0, end - (at + LOAD_FIXED));
                if (!nul) {
                    diag(model, sid, XODB_JIT_D_NAME_UNTERMINATED, ordinal, at, 0);
                    source->malformed_records++;
                    goto next;
                }
                size_t n = (size_t)(nul - name);
                if (n > model->limits.max_name_bytes) {
                    diag(model, sid, XODB_JIT_D_NAME_TOO_LONG, ordinal, at, n);
                    source->malformed_records++;
                    goto next;
                }
                e.name_offset = at + LOAD_FIXED;
                e.name_len = (uint32_t)n;
                if (!utf8_valid(name, n)) {
                    e.not_utf8 = 1;
                    diag(model, sid, XODB_JIT_D_NAME_NOT_UTF8, ordinal, at, 0);
                }
                size_t code = at + LOAD_FIXED + n + 1;
                if (e.size <= end - code) {
                    e.has_code = 1;
                    e.code_offset = code;
                    if (end - code != e.size)
                        diag(model, sid, XODB_JIT_D_TRAILING_BYTES, ordinal, at, end - code - e.size);
                } else {
                    diag(model, sid, XODB_JIT_D_CODE_BYTES_SIZE, ordinal, at, e.size);
                }
                /* Attachments follow file order, as perf's jitdump reader does. */
                if (debug.active) {
                    if (debug.code_addr == e.from) {
                        e.debug_first = debug.first;
                        e.debug_count = debug.count;
                        e.debug_ordinal = debug.ordinal;
                    } else {
                        diag(model, sid, XODB_JIT_D_DEBUG_UNMATCHED, debug.ordinal, debug.offset, debug.code_addr);
                    }
                    debug.active = 0;
                }
                if (unwind.active) {
                    e.unwind = unwind.index;
                    unwind.active = 0;
                }
            } else {
                e.from = rd64(&r, at + 32);
                e.to = rd64(&r, at + 40);
                e.size = rd64(&r, at + 48);
                e.index = rd64(&r, at + 56);
                if (size != MOVE_FIXED)
                    diag(model, sid, XODB_JIT_D_TRAILING_BYTES, ordinal, at, size - MOVE_FIXED);
            }
            uint64_t start = id == XODB_JIT_REC_LOAD ? e.from : e.to;
            if (e.size == 0) {
                diag(model, sid, XODB_JIT_D_ZERO_SIZE, ordinal, at, start);
                source->malformed_records++;
                goto next;
            }
            if (ends_wrap(start, e.size) || (id == XODB_JIT_REC_MOVE && ends_wrap(e.from, e.size))) {
                diag(model, sid, XODB_JIT_D_RANGE_WRAPS, ordinal, at, start);
                source->malformed_records++;
                goto next;
            }
            if (e.pid != pid) {
                diag(model, sid, XODB_JIT_D_FOREIGN_PID, ordinal, at, e.pid);
                goto next;
            }
            if (e.vma != start)
                diag(model, sid, XODB_JIT_D_VMA_DIFFERS, ordinal, at, e.vma);
            if ((error = grow(model, (void **)&events, &event_cap, sizeof *events, event_count + 1))) {
                if (error == XODB_JIT_E_BUDGET) {
                    source->partial = 1;
                    stopped = 1;
                    diag(model, sid, XODB_JIT_D_BUDGET, ordinal, at, 1);
                }
                break;
            }
            events[event_count++] = e;
        } else if (id == XODB_JIT_REC_DEBUG_INFO) {
            if ((error = parse_debug(&p, sid, &r, at, end, ordinal, &debug))) {
                if (error == XODB_JIT_E_BUDGET) {
                    source->partial = 1;
                    stopped = 1;
                    diag(model, sid, XODB_JIT_D_BUDGET, ordinal, at, 2);
                }
                break;
            }
        } else if (id == XODB_JIT_REC_UNWINDING_INFO) {
            if ((error = parse_unwind(model, sid, &r, at, end, ordinal, &unwind))) {
                if (error == XODB_JIT_E_BUDGET) {
                    source->partial = 1;
                    stopped = 1;
                    diag(model, sid, XODB_JIT_D_BUDGET, ordinal, at, 4);
                }
                break;
            }
        } else if (id == XODB_JIT_REC_CLOSE) {
            if (!source->closed) {
                source->closed = 1;
                source->close_time = time;
            }
            if (size != JITDUMP_RECORD)
                diag(model, sid, XODB_JIT_D_TRAILING_BYTES, ordinal, at, size - JITDUMP_RECORD);
        } else {
            diag(model, sid, XODB_JIT_D_UNKNOWN_RECORD, ordinal, at, id);
            source->unknown_records++;
        }
    next:
        at = end;
    }
    if (fatal_error(error)) {
        charged_free(model, events, event_cap, sizeof *events);
        return prep_end(&p, error, 1, control, source_index);
    }
    source->decoded_bytes = stopped ? at : len;
    source->complete = !stopped;
    if (debug.active)
        diag(model, sid, XODB_JIT_D_DEBUG_UNMATCHED, debug.ordinal, debug.offset, debug.code_addr);
    if (unwind.active)
        diag(model, sid, XODB_JIT_D_UNWIND_UNMATCHED, unwind.ordinal, unwind.offset, 0);
    int built = build_versions(&p, sid, events, event_count);
    charged_free(model, events, event_cap, sizeof *events);
    source = &model->sources[sid];
    if (fatal_error(built))
        return prep_end(&p, built, 1, control, source_index);
    if (built) {
        source->partial = 1;
        source->complete = 0;
        diag(model, sid, XODB_JIT_D_BUDGET, 0, 0, 3);
        if (!error)
            error = built;
    }
    source->version_count = model->version_count - source->version_first;
    finish_coverage(source);
    int indexed = build_index(&p, source);
    if (indexed)
        return prep_end(&p, indexed, 1, control, source_index);
    return prep_end(&p, error, 0, control, source_index);
}

int xodb_jit_add_jitdump(struct xodb_jit_model *model, const struct xodb_jit_source_meta *meta,
                         const uint8_t *bytes, size_t len, int *source_index)
{
    return xodb_jit_add_jitdump_ctl(model, meta, bytes, len, NULL, source_index);
}

/* ---- perf map ----------------------------------------------------------- */

static int parse_hex(const uint8_t *s, size_t n, size_t *used, uint64_t *value, int *prefixed, int *overflow)
{
    size_t i = 0;
    *prefixed = 0;
    *overflow = 0;
    if (n >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        i = 2;
        *prefixed = 1;
    }
    size_t digits = 0;
    uint64_t v = 0;
    for (; i < n; ++i, ++digits) {
        uint8_t c = s[i];
        unsigned d;
        if (c >= '0' && c <= '9')
            d = c - '0';
        else if (c >= 'a' && c <= 'f')
            d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F')
            d = c - 'A' + 10;
        else
            break;
        if (v >> 60)
            *overflow = 1;
        v = v << 4 | d;
    }
    *used = i;
    *value = v;
    return digits > 0;
}

int xodb_jit_add_perfmap_ctl(struct xodb_jit_model *model, const struct xodb_jit_source_meta *meta,
                             const uint8_t *bytes, size_t len, struct xodb_jit_control *control, int *source_index)
{
    if (source_index)
        *source_index = -1;
    if (control) {
        control->work = 0;
        control->memory_peak = model ? model->memory : 0;
        control->stop = XODB_JIT_STOP_NONE;
    }
    if (!model || !meta || (!bytes && len) || !meta->process.pid)
        return XODB_JIT_E_ARGUMENT;
    struct prep p;
    prep_begin(&p, model, control);
    struct xodb_jit_source *source;
    int error = add_source(&p, XODB_JIT_SOURCE_PERFMAP, meta, bytes, len, &source);
    if (error)
        return prep_end(&p, error, 1, control, source_index);
    uint32_t sid = (uint32_t)(model->source_count - 1);
    if (source_index)
        *source_index = (int)sid;
    const uint8_t *b = source->bytes;
    size_t at = 0;
    uint64_t line = 0;
    int stopped = 0;
    while (at < len) {
        line++;
        if ((error = spend(&p.meter, 1)))
            break;
        const uint8_t *nl = memchr(b + at, '\n', len - at);
        if (!nl) {
            /* A snapshot may cut the producer mid-line: size or name may be cut. */
            diag(model, sid, XODB_JIT_D_LINE_UNTERMINATED, line, at, len - at);
            source->tail_truncated = 1;
            stopped = 1;
            break;
        }
        size_t n = (size_t)(nl - (b + at)), next = at + n + 1;
        if (source->records >= model->limits.max_records) {
            diag(model, sid, XODB_JIT_D_BUDGET, line, at, 0);
            source->partial = 1;
            stopped = 1;
            error = XODB_JIT_E_BUDGET;
            break;
        }
        source->records++;
        if (n > model->limits.max_line_bytes) {
            diag(model, sid, XODB_JIT_D_LINE_TOO_LONG, line, at, n);
            source->malformed_records++;
            at = next;
            continue;
        }
        const uint8_t *s = b + at;
        size_t used, used2;
        uint64_t start, size;
        int prefix1, prefix2, over1, over2;
        if (!parse_hex(s, n, &used, &start, &prefix1, &over1) || used >= n || s[used] != ' ' ||
            !parse_hex(s + used + 1, n - used - 1, &used2, &size, &prefix2, &over2) ||
            used + 1 + used2 >= n || s[used + 1 + used2] != ' ' || used + 2 + used2 >= n) {
            diag(model, sid, XODB_JIT_D_LINE_MALFORMED, line, at, 0);
            source->malformed_records++;
            at = next;
            continue;
        }
        if (over1 || over2) {
            diag(model, sid, XODB_JIT_D_HEX_OVERFLOW, line, at, 0);
            source->malformed_records++;
            at = next;
            continue;
        }
        if (size == 0) {
            diag(model, sid, XODB_JIT_D_ZERO_SIZE, line, at, start);
            source->malformed_records++;
            at = next;
            continue;
        }
        if (ends_wrap(start, size)) {
            diag(model, sid, XODB_JIT_D_RANGE_WRAPS, line, at, start);
            source->malformed_records++;
            at = next;
            continue;
        }
        size_t name = used + 2 + used2, name_len = n - name;
        if (name_len > model->limits.max_name_bytes) {
            diag(model, sid, XODB_JIT_D_NAME_TOO_LONG, line, at, name_len);
            source->malformed_records++;
            at = next;
            continue;
        }
        struct xodb_jit_version *v;
        if ((error = new_version(model, &v))) {
            if (error == XODB_JIT_E_BUDGET) {
                diag(model, sid, XODB_JIT_D_BUDGET, line, at, 3);
                source->partial = 1;
                stopped = 1;
            }
            break;
        }
        v->source = sid;
        v->pid = source->meta.process.pid;
        v->start = start;
        v->size = size;
        v->vma = start;
        v->begin = (struct xodb_jit_bound){XODB_JIT_BOUND_SNAPSHOT, 0, 0, line, at};
        v->name_offset = at + name;
        v->name_len = (uint32_t)name_len;
        v->flags = (prefix1 || prefix2) ? XODB_JIT_V_HEX_PREFIX : 0;
        if (!utf8_valid(s + name, name_len)) {
            v->flags |= XODB_JIT_V_NAME_NOT_UTF8;
            diag(model, sid, XODB_JIT_D_NAME_NOT_UTF8, line, at, 0);
        }
        at = next;
    }
    if (fatal_error(error))
        return prep_end(&p, error, 1, control, source_index);
    source->decoded_bytes = stopped ? at : len;
    source->complete = !stopped;
    source->has_coverage = meta->has_coverage_end;
    source->coverage_end = meta->coverage_end;
    source->version_count = model->version_count - source->version_first;
    int indexed = build_index(&p, source);
    if (indexed)
        return prep_end(&p, indexed, 1, control, source_index);
    return prep_end(&p, error, 0, control, source_index);
}

int xodb_jit_add_perfmap(struct xodb_jit_model *model, const struct xodb_jit_source_meta *meta,
                         const uint8_t *bytes, size_t len, int *source_index)
{
    return xodb_jit_add_perfmap_ctl(model, meta, bytes, len, NULL, source_index);
}

/* ---- clocks ------------------------------------------------------------- */

int xodb_jit_clock_equal(const struct xodb_jit_clock *a, const struct xodb_jit_clock *b)
{
    return a->kind != XODB_JIT_CLOCK_UNKNOWN && a->kind == b->kind && a->scope_known && b->scope_known &&
           !memcmp(a->scope, b->scope, sizeof a->scope);
}

static int apply_map(const struct xodb_jit_clock_map *map, uint64_t time, uint64_t *out)
{
    if (map->method == XODB_JIT_MAP_OFFSET) {
        if (map->offset >= 0) {
            if ((uint64_t)map->offset > UINT64_MAX - time)
                return 0;
            *out = time + (uint64_t)map->offset;
        } else {
            uint64_t back = (uint64_t)(-(map->offset + 1)) + 1;
            if (back > time)
                return 0;
            *out = time - back;
        }
        return 1;
    }
    if (map->method == XODB_JIT_MAP_PERF_TSC) {
        if (map->shift > 63)
            return 0;
        uint64_t quot = time >> map->shift, rem = time & ((1ull << map->shift) - 1), whole, part, sum;
        if (__builtin_mul_overflow(quot, (uint64_t)map->mult, &whole) ||
            __builtin_mul_overflow(rem, (uint64_t)map->mult, &part) ||
            __builtin_add_overflow(whole, part >> map->shift, &sum) ||
            __builtin_add_overflow(sum, map->zero, out))
            return 0;
        return 1;
    }
    return 0;
}

int xodb_jit_source_time(const struct xodb_jit_source *source, const struct xodb_jit_clock *target,
                         uint64_t time, uint64_t *mapped, uint64_t *uncertainty)
{
    if (xodb_jit_clock_equal(&source->meta.clock, target)) {
        *mapped = time;
        *uncertainty = 0;
        return 1;
    }
    const struct xodb_jit_clock_map *map = &source->meta.map;
    if (map->method == XODB_JIT_MAP_NONE || !xodb_jit_clock_equal(&map->target, target))
        return 0;
    if (!apply_map(map, time, mapped))
        return 0;
    *uncertainty = map->uncertainty;
    return 1;
}

/* How a source's timestamps relate to the query clock. Windows are exact
 * (128-bit) and monotone non-decreasing in the source time. */
struct relation {
    int mode; /* 0 unrelated, 1 same clock, 2 declared map */
    const struct xodb_jit_source *source;
};

static struct relation relate(const struct xodb_jit_source *source, const struct xodb_jit_clock *target)
{
    struct relation rel = {0, source};
    const struct xodb_jit_clock_map *map = &source->meta.map;
    if (xodb_jit_clock_equal(&source->meta.clock, target))
        rel.mode = 1;
    else if (map->method != XODB_JIT_MAP_NONE && xodb_jit_clock_equal(&map->target, target) &&
             (map->method == XODB_JIT_MAP_OFFSET || (map->method == XODB_JIT_MAP_PERF_TSC && map->shift <= 63)))
        rel.mode = 2;
    return rel;
}

static wide map_exact(const struct relation *rel, uint64_t time)
{
    const struct xodb_jit_clock_map *map = &rel->source->meta.map;
    if (rel->mode == 1)
        return (wide)time;
    if (map->method == XODB_JIT_MAP_OFFSET)
        return (wide)time + map->offset;
    return (wide)map->zero + (wide)(((unsigned __int128)time * map->mult) >> map->shift);
}

/* Window [lo, hi] in query time that a source boundary may denote. */
static wide win_lo(const struct relation *rel, uint64_t time)
{
    uint64_t slack = rel->source->meta.slack;
    return map_exact(rel, time > slack ? time - slack : 0) - (rel->mode == 2 ? (wide)rel->source->meta.map.uncertainty : 0);
}

static wide win_hi(const struct relation *rel, uint64_t time)
{
    uint64_t slack = rel->source->meta.slack;
    return map_exact(rel, slack > UINT64_MAX - time ? UINT64_MAX : time + slack) +
           (rel->mode == 2 ? (wide)rel->source->meta.map.uncertainty : 0);
}

/* ---- resolution --------------------------------------------------------- */

static int process_match(const struct xodb_jit_process *source, const struct xodb_jit_process *query, int *verified)
{
    if (source->pid != query->pid)
        return 0;
    if (source->known && query->known) {
        if (source->start_ticks != query->start_ticks || memcmp(source->boot_id, query->boot_id, 16))
            return 0;
        *verified = 1;
    } else {
        *verified = 0;
    }
    return 1;
}

/* Charge floor(n / 4096) units, then compare n bytes. */
static int same_bytes(struct meter *m, const uint8_t *a, const uint8_t *b, uint64_t n, int *same)
{
    int error = spend(m, n / 4096);
    if (error)
        return error;
    *same = !n || !memcmp(a, b, (size_t)n);
    return XODB_JIT_OK;
}

/* Whether two candidates are evidence of one code object (contract v3 section 5).
 * Equal address range and name are never enough. Duplicate evidence is:
 *  - the same version;
 *  - two lines of one perf map with identical range and text (a repeated
 *    snapshot line adds nothing; perf maps never resolve);
 *  - two LOAD versions from different jitdump sources that agree on the
 *    process incarnation (both known), source clock, producer header,
 *    every decoded LOAD field, the record time, the end evidence, the name,
 *    the retained code bytes, the attached debug entries and the attached
 *    unwinding data.
 * Anything else - mixed perf-map/jitdump, two perf maps, moved or orphan
 * versions, code bytes not retained - is not shown to be one object and keeps
 * the result ambiguous. Scalar checks are free (at most 15 per query); byte
 * comparisons are charged by spend before they run, on both the perf-map and
 * the jitdump branch (bound: contract v4 section 2). */
static int equivalent(const struct xodb_jit_model *model, struct meter *m, const struct xodb_jit_version *a,
                      const struct xodb_jit_version *b, int *same)
{
    const struct xodb_jit_source *sa = &model->sources[a->source], *sb = &model->sources[b->source];
    const uint8_t *na = sa->bytes + a->name_offset, *nb = sb->bytes + b->name_offset;
    *same = 0;
    if (a == b) {
        *same = 1;
        return XODB_JIT_OK;
    }
    if (sa->kind == XODB_JIT_SOURCE_PERFMAP || sb->kind == XODB_JIT_SOURCE_PERFMAP) {
        if (a->source != b->source || sa->kind != XODB_JIT_SOURCE_PERFMAP || a->start != b->start ||
            a->size != b->size || a->name_len != b->name_len)
            return XODB_JIT_OK;
        return same_bytes(m, na, nb, a->name_len, same);
    }
    const struct xodb_jit_process *pa = &sa->meta.process, *pb = &sb->meta.process;
    const uint32_t need = XODB_JIT_V_HAS_CODE;
    if (a->source == b->source || !pa->known || !pb->known || pa->pid != pb->pid ||
        pa->start_ticks != pb->start_ticks || memcmp(pa->boot_id, pb->boot_id, sizeof pa->boot_id) ||
        !xodb_jit_clock_equal(&sa->meta.clock, &sb->meta.clock) || sa->version != sb->version ||
        sa->elf_mach != sb->elf_mach || sa->header_pid != sb->header_pid || sa->header_time != sb->header_time ||
        sa->header_flags != sb->header_flags)
        return XODB_JIT_OK;
    if ((a->flags & need) != need || a->flags != b->flags || a->begin.kind != XODB_JIT_BOUND_LOAD ||
        b->begin.kind != XODB_JIT_BOUND_LOAD || a->predecessor || b->predecessor || !a->has_code_index ||
        !b->has_code_index || a->code_index != b->code_index || a->pid != b->pid || a->tid != b->tid ||
        a->start != b->start || a->size != b->size || a->vma != b->vma || a->begin.time != b->begin.time ||
        a->end.kind != b->end.kind || a->end.has_time != b->end.has_time ||
        (a->end.has_time && a->end.time != b->end.time) || a->name_len != b->name_len ||
        a->debug_count != b->debug_count || (a->unwind_record < 0) != (b->unwind_record < 0))
        return XODB_JIT_OK;
    const struct xodb_jit_unwind *ua = a->unwind_record < 0 ? NULL : &model->unwinds[a->unwind_record];
    const struct xodb_jit_unwind *ub = b->unwind_record < 0 ? NULL : &model->unwinds[b->unwind_record];
    if (ua && (ua->unwind_size != ub->unwind_size || ua->eh_frame_hdr_size != ub->eh_frame_hdr_size ||
               ua->mapped_size != ub->mapped_size))
        return XODB_JIT_OK;
    int error = spend(m, 1 + (uint64_t)a->debug_count);
    if (error)
        return error;
    for (uint32_t k = 0; k < a->debug_count; ++k) {
        const struct xodb_jit_debug_entry *da = &model->debug[a->debug_first + k];
        const struct xodb_jit_debug_entry *db = &model->debug[b->debug_first + k];
        if (da->address != db->address || da->line != db->line || da->discriminator != db->discriminator ||
            da->in_range != db->in_range || da->file_len != db->file_len)
            return XODB_JIT_OK;
    }
    if ((error = same_bytes(m, na, nb, a->name_len, same)) || !*same ||
        (error = same_bytes(m, sa->bytes + a->code_offset, sb->bytes + b->code_offset, a->size, same)) || !*same ||
        (ua && ((error = same_bytes(m, sa->bytes + ua->data_offset, sb->bytes + ub->data_offset, ua->unwind_size,
                                    same)) ||
                !*same)))
        return error;
    for (uint32_t k = 0; k < a->debug_count && *same; ++k) {
        const struct xodb_jit_debug_entry *da = &model->debug[a->debug_first + k];
        const struct xodb_jit_debug_entry *db = &model->debug[b->debug_first + k];
        if ((error = same_bytes(m, sa->bytes + da->file_offset, sb->bytes + db->file_offset, da->file_len, same)))
            return error;
    }
    return XODB_JIT_OK;
}

static void store_candidate(struct xodb_jit_result *result, uint32_t version, uint32_t state, uint32_t reasons)
{
    result->reasons |= reasons;
    result->candidates[result->count++] = (struct xodb_jit_candidate){version, state, reasons};
}

/* Per path node: list bounds and the split points of the timed search. */
struct span {
    const uint32_t *list;
    size_t len, nh, nl, group, keep;
};

enum probe_kind { HI_BEGIN_BEFORE_T, LO_BEGIN_AT_OR_BEFORE_T, BEGIN_BEFORE_B, END_NOT_BEFORE_T };

/* Length of the prefix of list[0..n) satisfying a monotone predicate. */
static int prefix(const struct xodb_jit_model *model, const struct relation *rel, struct meter *m, const uint32_t *list,
                  size_t n, enum probe_kind kind, uint64_t t, uint64_t b, size_t *out)
{
    size_t lo = 0, hi = n;
    while (lo < hi) {
        int error = spend(m, 1);
        if (error)
            return error;
        size_t mid = lo + (hi - lo) / 2;
        const struct xodb_jit_version *v = &model->versions[list[mid]];
        int yes = 0;
        switch (kind) {
        case HI_BEGIN_BEFORE_T: yes = win_hi(rel, v->begin.time) < (wide)t; break;
        case LO_BEGIN_AT_OR_BEFORE_T: yes = win_lo(rel, v->begin.time) <= (wide)t; break;
        case BEGIN_BEFORE_B: yes = v->begin.time < b; break;
        case END_NOT_BEFORE_T: yes = !v->end.has_time || win_hi(rel, v->end.time) >= (wide)t; break;
        }
        if (yes)
            lo = mid + 1;
        else
            hi = mid;
    }
    *out = lo;
    return XODB_JIT_OK;
}

/* Candidates of one source at query->address. Timed jitdump semantics (the
 * same as the C07 nested scan, verified by the exhaustive oracle in tests):
 * a version is a candidate when lo(begin) <= t, its end window does not lie
 * before t, and no version covering the address has a later begin whose
 * whole window lies before t. It is boundary-uncertain when t is inside its
 * begin or end window or a later begin's window. */
static int resolve_source(const struct xodb_jit_model *model, const struct xodb_jit_source *source,
                          const struct xodb_jit_query *query, int timed, const struct relation *rel,
                          uint32_t source_reasons, uint32_t open_reasons, struct meter *m,
                          struct xodb_jit_result *result)
{
    const uint64_t *coords = source->index.coords;
    size_t count = source->index.coord_count, lo = 0, hi = count;
    int error;
    if (count < 2)
        return XODB_JIT_OK;
    while (lo < hi) { /* number of endpoints <= address */
        if ((error = spend(m, 1)))
            return error;
        size_t mid = lo + (hi - lo) / 2;
        if (coords[mid] <= query->address)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == 0 || lo >= count)
        return XODB_JIT_OK;
    struct span path[66];
    size_t depth = 0;
    for (size_t node = source->index.base + lo - 1; node >= 1; node >>= 1) {
        if ((error = spend(m, 1)))
            return error;
        const uint32_t *first = source->index.first;
        path[depth++] = (struct span){source->index.entries + first[node], first[node + 1] - first[node], 0, 0, 0, 0};
    }
    uint64_t t = query->time, b = 0, top = 0;
    int has_b = 0, has_top = 0;
    if (timed) {
        for (size_t i = 0; i < depth; ++i) {
            struct span *s = &path[i];
            if ((error = prefix(model, rel, m, s->list, s->len, HI_BEGIN_BEFORE_T, t, 0, &s->nh)) ||
                (error = prefix(model, rel, m, s->list, s->len, LO_BEGIN_AT_OR_BEFORE_T, t, 0, &s->nl)))
                return error;
            if (s->nh && (!has_b || model->versions[s->list[s->nh - 1]].begin.time > b)) {
                b = model->versions[s->list[s->nh - 1]].begin.time;
                has_b = 1;
            }
            if (s->nl && (!has_top || model->versions[s->list[s->nl - 1]].begin.time > top)) {
                top = model->versions[s->list[s->nl - 1]].begin.time;
                has_top = 1;
            }
        }
        for (size_t i = 0; i < depth; ++i) {
            struct span *s = &path[i];
            s->group = s->keep = s->nh;
            if (has_b && s->nh) {
                size_t survivors;
                if ((error = prefix(model, rel, m, s->list, s->nh, BEGIN_BEFORE_B, t, b, &s->group)) ||
                    (error = prefix(model, rel, m, s->list + s->group, s->nh - s->group, END_NOT_BEFORE_T, t, 0,
                                    &survivors)))
                    return error;
                s->keep = s->group + survivors;
            }
            result->total += (s->keep - s->group) + (s->nl - s->nh);
        }
    } else {
        for (size_t i = 0; i < depth; ++i)
            result->total += path[i].len;
    }
    for (size_t i = 0; i < depth && result->count < XODB_JIT_MAX_CANDIDATES; ++i) {
        const struct span *s = &path[i];
        for (int part = 0; part < 2 && result->count < XODB_JIT_MAX_CANDIDATES; ++part) {
            size_t from = timed ? (part ? s->nh : s->group) : (part ? 0 : s->len);
            size_t to = timed ? (part ? s->nl : s->keep) : s->len;
            for (size_t k = from; k < to && result->count < XODB_JIT_MAX_CANDIDATES; ++k) {
                if ((error = spend(m, 1)))
                    return error;
                const struct xodb_jit_version *v = &model->versions[s->list[k]];
                uint32_t reasons = source_reasons | (v->end.kind == XODB_JIT_BOUND_NONE ? open_reasons : 0);
                if (!timed) {
                    store_candidate(result, v->id, XODB_JIT_C_POSSIBLE, reasons);
                    continue;
                }
                int boundary = part == 1 || (has_top && v->begin.time < top) ||
                               (v->end.has_time && win_lo(rel, v->end.time) <= (wide)t);
                store_candidate(result, v->id, boundary ? XODB_JIT_C_POSSIBLE : XODB_JIT_C_LIVE,
                                reasons | (boundary ? XODB_JIT_R_BOUNDARY : 0));
            }
        }
    }
    return XODB_JIT_OK;
}

static int resolve_all(const struct xodb_jit_model *model, const struct xodb_jit_query *query, struct meter *m,
                       struct xodb_jit_result *result)
{
    int error;
    for (size_t s = 0; s < model->source_count; ++s) {
        if ((error = spend(m, 1)))
            return error;
        const struct xodb_jit_source *source = &model->sources[s];
        int verified = 0;
        if (!process_match(&source->meta.process, &query->process, &verified)) {
            result->reasons |= XODB_JIT_R_IDENTITY_SKIPPED;
            continue;
        }
        uint32_t reasons = (verified ? 0 : XODB_JIT_R_IDENTITY_UNVERIFIED) |
                           (source->partial ? XODB_JIT_R_PARTIAL_SOURCE : 0);
        struct relation rel = relate(source, &query->clock);
        int timed = query->has_time && rel.mode;
        wide t = (wide)query->time;
        if (source->kind == XODB_JIT_SOURCE_JITDUMP) {
            /* Reporting start: the header time only when declared to share the
             * record clock, else the earliest record (earlier code is never
             * reported). */
            int has_begin = source->meta.header_time_in_clock || source->has_last_time;
            uint64_t begin = source->meta.header_time_in_clock ? source->header_time : source->first_time;
            if (!query->has_time)
                reasons |= XODB_JIT_R_NO_QUERY_TIME;
            else if (!timed)
                reasons |= XODB_JIT_R_CLOCK_UNRELATED;
            if (timed) {
                if (has_begin && t < win_lo(&rel, begin))
                    reasons |= XODB_JIT_R_BEFORE_COVERAGE;
                if (!source->has_coverage)
                    reasons |= XODB_JIT_R_NO_COVERAGE;
                else if (t >= win_lo(&rel, source->coverage_end))
                    reasons |= XODB_JIT_R_AFTER_COVERAGE;
            }
            result->reasons |= reasons;
            if ((error = resolve_source(model, source, query, timed, &rel, reasons, XODB_JIT_R_NO_END_EVIDENCE, m,
                                        result)))
                return error;
            continue;
        }
        reasons |= XODB_JIT_R_UNTIMED_SNAPSHOT;
        if (query->has_time && source->has_coverage && rel.mode && t >= win_lo(&rel, source->coverage_end))
            reasons |= XODB_JIT_R_AFTER_COVERAGE;
        result->reasons |= reasons;
        if ((error = resolve_source(model, source, query, 0, &rel, reasons | XODB_JIT_R_NO_END_EVIDENCE, 0, m, result)))
            return error;
    }
    return XODB_JIT_OK;
}

static void sort_candidates(struct xodb_jit_result *result)
{
    for (size_t i = 1; i < result->count; ++i)
        for (size_t k = i; k > 0 && result->candidates[k - 1].version > result->candidates[k].version; --k) {
            struct xodb_jit_candidate c = result->candidates[k];
            result->candidates[k] = result->candidates[k - 1];
            result->candidates[k - 1] = c;
        }
}

int xodb_jit_resolve_ctl(const struct xodb_jit_model *model, const struct xodb_jit_query *query,
                         struct xodb_jit_control *control, struct xodb_jit_result *result)
{
    memset(result, 0, sizeof *result);
    if (control) {
        control->work = 0;
        control->memory_peak = model ? model->memory : 0;
        control->stop = XODB_JIT_STOP_NONE;
    }
    if (!model || !query || !query->process.pid)
        return XODB_JIT_E_ARGUMENT;
    struct meter m;
    meter_init(&m, control, model->limits.max_query_work);
    int error = resolve_all(model, query, &m, result);
    if (control) {
        control->work = m.used;
        control->stop = m.stop;
    }
    sort_candidates(result);
    if (error) {
        /* Stored candidates are individually valid; the set is not complete. */
        result->outcome = XODB_JIT_INCOMPLETE;
        result->reasons |= XODB_JIT_R_QUERY_STOPPED;
        result->total_exact = 0;
        if (result->total < result->count)
            result->total = result->count;
        return error;
    }
    result->total_exact = 1;
    if (!result->total) {
        result->outcome = XODB_JIT_NO_MATCH;
        return XODB_JIT_OK;
    }
    if (result->total > result->count) {
        result->reasons |= XODB_JIT_R_CANDIDATES_TRUNCATED;
        result->outcome = XODB_JIT_AMBIGUOUS;
        return XODB_JIT_OK;
    }
    /* All candidates must be one duplicate-evidence class to name one code object. */
    const struct xodb_jit_version *first = &model->versions[result->candidates[0].version - 1];
    size_t live = 0, sources = 1;
    int unrelated_only = 1, ambiguous = 0;
    uint32_t live_reasons = 0;
    for (size_t i = 0; i < result->count; ++i) {
        const struct xodb_jit_candidate *c = &result->candidates[i];
        const struct xodb_jit_version *v = &model->versions[c->version - 1];
        int same = 0;
        if (!ambiguous && (error = equivalent(model, &m, first, v, &same))) {
            if (control) {
                control->work = m.used;
                control->stop = m.stop;
            }
            result->outcome = XODB_JIT_INCOMPLETE;
            result->reasons |= XODB_JIT_R_QUERY_STOPPED;
            result->total_exact = 0;
            return error;
        }
        if (!same)
            ambiguous = 1;
        if (v->source != first->source)
            sources++;
        if (c->state == XODB_JIT_C_LIVE) {
            live++;
            live_reasons |= c->reasons;
        }
        if (!(c->reasons & XODB_JIT_R_CLOCK_UNRELATED))
            unrelated_only = 0;
    }
    if (control)
        control->work = m.used;
    if (ambiguous) {
        if (live > 1)
            result->reasons |= XODB_JIT_R_OVERLAP;
        result->outcome = XODB_JIT_AMBIGUOUS;
        return XODB_JIT_OK;
    }
    if (sources > 1)
        result->reasons |= XODB_JIT_R_CORROBORATED;
    const uint32_t weak = XODB_JIT_R_IDENTITY_UNVERIFIED | XODB_JIT_R_AFTER_COVERAGE | XODB_JIT_R_PARTIAL_SOURCE |
                          XODB_JIT_R_NO_COVERAGE | XODB_JIT_R_BEFORE_COVERAGE;
    if (live && !(live_reasons & weak))
        result->outcome = XODB_JIT_RESOLVED;
    else if (!live && unrelated_only)
        result->outcome = XODB_JIT_UNAVAILABLE;
    else
        result->outcome = XODB_JIT_UNVERIFIED;
    return XODB_JIT_OK;
}

int xodb_jit_resolve(const struct xodb_jit_model *model, const struct xodb_jit_query *query,
                     struct xodb_jit_result *result)
{
    return xodb_jit_resolve_ctl(model, query, NULL, result);
}

/* ---- names -------------------------------------------------------------- */

const char *xodb_jit_error_name(int error)
{
    switch (error) {
    case XODB_JIT_OK: return "ok";
    case XODB_JIT_E_NOMEM: return "out_of_memory";
    case XODB_JIT_E_BUDGET: return "budget_exhausted";
    case XODB_JIT_E_MAGIC: return "bad_magic";
    case XODB_JIT_E_VERSION: return "unsupported_version";
    case XODB_JIT_E_HEADER: return "bad_header";
    case XODB_JIT_E_FLAGS: return "unsupported_flags";
    case XODB_JIT_E_IDENTITY: return "identity_mismatch";
    case XODB_JIT_E_CLOCK: return "clock_mode_mismatch";
    case XODB_JIT_E_ARGUMENT: return "bad_argument";
    case XODB_JIT_E_WORK: return "work_limit";
    case XODB_JIT_E_CANCELLED: return "cancelled";
    }
    return "unknown_error";
}

const char *xodb_jit_diag_name(uint32_t code)
{
    static const char *const names[] = {
        "", "truncated_record", "record_too_small", "unknown_record", "name_unterminated", "name_too_long",
        "range_wraps", "zero_size", "code_bytes_size", "foreign_pid", "move_unknown_index",
        "move_address_mismatch", "move_size_mismatch", "move_ambiguous_index", "duplicate_index",
        "debug_unmatched", "debug_malformed", "debug_out_of_range", "unwind_unmatched", "unwind_malformed",
        "out_of_order", "after_close", "header_extra", "vma_differs", "trailing_bytes", "line_malformed",
        "line_too_long", "line_unterminated", "hex_overflow", "name_not_utf8", "budget", "time_zero",
    };
    return code < sizeof names / sizeof *names && code ? names[code] : "unknown";
}

const char *xodb_jit_outcome_name(uint32_t outcome)
{
    switch (outcome) {
    case XODB_JIT_RESOLVED: return "resolved";
    case XODB_JIT_UNVERIFIED: return "unverified";
    case XODB_JIT_AMBIGUOUS: return "ambiguous";
    case XODB_JIT_NO_MATCH: return "no_match";
    case XODB_JIT_UNAVAILABLE: return "unavailable";
    case XODB_JIT_INCOMPLETE: return "incomplete";
    }
    return "invalid";
}

const char *xodb_jit_bound_name(uint32_t kind)
{
    switch (kind) {
    case XODB_JIT_BOUND_NONE: return "not_observed";
    case XODB_JIT_BOUND_LOAD: return "load";
    case XODB_JIT_BOUND_MOVE_IN: return "move_in";
    case XODB_JIT_BOUND_MOVE_OUT: return "move_out";
    case XODB_JIT_BOUND_SNAPSHOT: return "snapshot_untimed";
    }
    return "invalid";
}
