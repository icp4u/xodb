#define _GNU_SOURCE 1
#include "logical_frames.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* ---- SHA-256 (FIPS 180-4) ---------------------------------------------- */
static const uint32_t sha_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
static void sha_block(uint32_t h[8], const uint8_t *p)
{
    uint32_t w[64];
    for (int i = 0; i < 16; ++i)
        w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 |
               p[4 * i + 3];
    for (int i = 16; i < 64; ++i) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7];
    for (int i = 0; i < 64; ++i) {
        uint32_t t1 = k + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + sha_k[i] + w[i];
        uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        k = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }
    h[0] += a, h[1] += b, h[2] += c, h[3] += d, h[4] += e, h[5] += f, h[6] += g, h[7] += k;
}
struct sha {
    uint32_t h[8];
    uint8_t buf[64];
    size_t used;
    uint64_t total;
};
static void sha_init(struct sha *c)
{
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(c->h, iv, sizeof iv);
    c->used = 0;
    c->total = 0;
}
static void sha_update(struct sha *c, const uint8_t *p, size_t n)
{
    c->total += n;
    if (c->used) {
        size_t take = 64 - c->used < n ? 64 - c->used : n;
        memcpy(c->buf + c->used, p, take);
        c->used += take, p += take, n -= take;
        if (c->used < 64)
            return;
        sha_block(c->h, c->buf);
        c->used = 0;
    }
    for (; n >= 64; p += 64, n -= 64)
        sha_block(c->h, p);
    memcpy(c->buf, p, n);
    c->used = n;
}
static void sha_final(struct sha *c, uint8_t out[32])
{
    uint8_t tail[128] = {0};
    memcpy(tail, c->buf, c->used);
    tail[c->used] = 0x80;
    size_t len = c->used < 56 ? 64 : 128;
    uint64_t bits = c->total * 8;
    for (int i = 0; i < 8; ++i)
        tail[len - 1 - i] = (uint8_t)(bits >> (8 * i));
    sha_block(c->h, tail);
    if (len == 128)
        sha_block(c->h, tail + 64);
    for (int i = 0; i < 8; ++i)
        for (int j = 0; j < 4; ++j)
            out[4 * i + j] = (uint8_t)(c->h[i] >> (24 - 8 * j));
}

/* ---- names --------------------------------------------------------------- */
static const char *const status_names[] = {
    "ok", "memory_limit", "input_limit", "invalid_utf8", "invalid_json", "schema", "version_unsupported",
    "duplicate_id", "bad_reference", "bad_identity", "clock", "order", "invented_pc", "address",
    "count_mismatch", "empty", "cancelled", "overflow", "invalid_argument", "io_error"};
const char *xlf_status_name(enum xlf_status s)
{
    return (unsigned)s < sizeof status_names / sizeof *status_names ? status_names[s] : "unknown";
}
static const char *const kind_names[] = {"interpreter", "native",  "native_transition", "jit",
                                         "logical",     "unknown", "unclassified"};
const char *xlf_kind_name(enum xlf_kind k)
{
    return (unsigned)k < 7 ? kind_names[k] : "?";
}
static const char *const prov_names[] = {"runtime", "cooperative_annotation", "external_read"};
const char *xlf_provenance_name(enum xlf_provenance p)
{
    return (unsigned)p < 3 ? prov_names[p] : "?";
}
static const char *const state_names[] = {"complete", "truncated", "partial"};
const char *xlf_state_name(enum xlf_state s)
{
    return (unsigned)s < 3 ? state_names[s] : "?";
}

void xlf_default_limits(struct xlf_limits *l)
{
    *l = (struct xlf_limits){
        .max_input_bytes = 256u << 20,
        .max_line_bytes = 4u << 20,
        .max_records = 4u << 20,
        .max_string_bytes = 16384,
        .max_frames_per_stack = 4096,
        .max_total_frames = 16u << 20,
        .max_entities = 1u << 20,
        .max_stacks = 4u << 20,
        .max_memory = 512u << 20,
        .max_depth = 8,
    };
}

void xlf_default_query_limits(struct xlf_query_limits *l)
{
    *l = (struct xlf_query_limits){.max_query_bytes = (size_t)256 << 20, .max_combined_bytes = (size_t)768 << 20};
}

/* ---- exact counters ------------------------------------------------------- */
bool xlf_count_add(struct xlf_count *c, uint64_t v)
{
    uint64_t lo = c->lo + v;
    uint64_t carry = lo < v;
    if (carry && c->hi == UINT64_MAX)
        return false;
    c->lo = lo;
    c->hi += carry;
    return true;
}
bool xlf_count_to_u64(struct xlf_count c, uint64_t *out)
{
    if (c.hi)
        return false;
    *out = c.lo;
    return true;
}
int xlf_count_cmp(struct xlf_count a, struct xlf_count b)
{
    if (a.hi != b.hi)
        return a.hi < b.hi ? -1 : 1;
    return a.lo < b.lo ? -1 : a.lo > b.lo;
}
size_t xlf_count_format(struct xlf_count c, char out[40])
{
    /* Repeated division of four 32-bit limbs by 10. */
    uint32_t limb[4] = {(uint32_t)(c.hi >> 32), (uint32_t)c.hi, (uint32_t)(c.lo >> 32), (uint32_t)c.lo};
    char rev[40];
    size_t n = 0;
    do {
        uint64_t rem = 0;
        bool nonzero = false;
        for (int i = 0; i < 4; ++i) {
            uint64_t cur = rem << 32 | limb[i];
            limb[i] = (uint32_t)(cur / 10);
            rem = cur % 10;
            nonzero |= limb[i] != 0;
        }
        rev[n++] = (char)('0' + rem);
        if (!nonzero)
            break;
    } while (n < 39);
    for (size_t i = 0; i < n; ++i)
        out[i] = rev[n - 1 - i];
    out[n] = 0;
    return n;
}

/* ---- cancellation ------------------------------------------------------- */
struct xlf_cancel {
    atomic_bool requested;
};
struct xlf_cancel *xlf_cancel_create(void)
{
    struct xlf_cancel *c = malloc(sizeof *c);
    if (c)
        atomic_init(&c->requested, false);
    return c;
}
void xlf_cancel_destroy(struct xlf_cancel *c)
{
    free(c);
}
void xlf_cancel_request(struct xlf_cancel *c)
{
    atomic_store_explicit(&c->requested, true, memory_order_release);
}
void xlf_cancel_reset(struct xlf_cancel *c)
{
    atomic_store_explicit(&c->requested, false, memory_order_release);
}
bool xlf_cancel_requested(const struct xlf_cancel *c)
{
    /* The object is never const at definition; the cast only reaches the atomic load. */
    return atomic_load_explicit(&((struct xlf_cancel *)(uintptr_t)c)->requested, memory_order_acquire);
}

/* ---- allocation accounting and test hooks ------------------------------- */
#ifdef XLF_TESTING
static uint64_t test_allocs, test_fail_at, test_polls, test_cancel_at;
static size_t test_live;
void xlf_test_fail_alloc_at(uint64_t n);
void xlf_test_cancel_at_poll(uint64_t n);
uint64_t xlf_test_allocs(void);
size_t xlf_test_live_bytes(void);
void xlf_test_fail_alloc_at(uint64_t n)
{
    test_fail_at = n;
    test_allocs = 0;
}
void xlf_test_cancel_at_poll(uint64_t n)
{
    test_cancel_at = n;
    test_polls = 0;
}
uint64_t xlf_test_allocs(void)
{
    return test_allocs;
}
size_t xlf_test_live_bytes(void)
{
    return test_live;
}
#define TEST_FAIL() (++test_allocs == test_fail_at)
#define TEST_LIVE(delta) (test_live += (delta))
#else
#define TEST_FAIL() 0
#define TEST_LIVE(delta) ((void)0)
#endif
static bool poll_cancel(const struct xlf_cancel *c)
{
#ifdef XLF_TESTING
    if (test_cancel_at && ++test_polls >= test_cancel_at)
        return true;
#endif
    return c && xlf_cancel_requested(c);
}

/* One accountant per operation: live and peak bytes against a limit. The
 * combined bound adds bytes already retained elsewhere (the document). */
struct acct {
    size_t live, peak, limit, base, combined_limit;
};
enum acct_fail { ACCT_OK, ACCT_BUDGET, ACCT_OOM };
static enum acct_fail acct_charge(struct acct *a, size_t n)
{
    if (n > a->limit || a->live > a->limit - n)
        return ACCT_BUDGET;
    if (a->combined_limit) {
        size_t after = a->live + n;
        if (a->base > a->combined_limit || after > a->combined_limit - a->base)
            return ACCT_BUDGET;
    }
    a->live += n;
    if (a->live > a->peak)
        a->peak = a->live;
    return ACCT_OK;
}
static void acct_uncharge(struct acct *a, size_t n)
{
    a->live -= n;
}
static void *acct_alloc(struct acct *a, size_t n, bool zero, enum acct_fail *why)
{
    *why = acct_charge(a, n);
    if (*why)
        return NULL;
    void *p = TEST_FAIL() ? NULL : zero ? calloc(1, n ? n : 1) : malloc(n ? n : 1);
    if (!p) {
        acct_uncharge(a, n);
        *why = ACCT_OOM;
        return NULL;
    }
    TEST_LIVE(n);
    return p;
}
static void *acct_realloc(struct acct *a, void *old, size_t old_n, size_t n, enum acct_fail *why)
{
    *why = acct_charge(a, n - old_n); /* growth only */
    if (*why)
        return NULL;
    void *p = TEST_FAIL() ? NULL : realloc(old, n);
    if (!p) {
        acct_uncharge(a, n - old_n);
        *why = ACCT_OOM;
        return NULL;
    }
    TEST_LIVE(n - old_n);
    return p;
}
static void acct_free(struct acct *a, void *p, size_t n)
{
    if (!p)
        return;
    free(p);
    if (a)
        acct_uncharge(a, n);
    TEST_LIVE(-n);
}

/* Limits are validated so that every 32-bit index and every size computation
 * derived from them is representable. */
static const char *limits_invalid(const struct xlf_limits *l)
{
    if (!l->max_input_bytes || !l->max_line_bytes || !l->max_records || !l->max_memory || !l->max_depth)
        return "zero limit";
    if (l->max_records > XLF_MAX_INDEX || l->max_entities > XLF_MAX_INDEX || l->max_stacks > XLF_MAX_INDEX ||
        l->max_total_frames > XLF_MAX_INDEX || l->max_frames_per_stack > XLF_MAX_INDEX)
        return "count limit above XLF_MAX_INDEX";
    if (l->max_frames_per_stack > (XLF_MAX_INDEX - 4096) / 16)
        return "max_frames_per_stack too large for the JSON value bound";
    if (l->max_line_bytes > (SIZE_MAX - 16) / 2 || l->max_line_bytes > UINT32_MAX)
        return "max_line_bytes too large";
    if (l->max_string_bytes > UINT32_MAX - 1 || l->max_depth > 64)
        return "string/depth limit too large";
    return NULL;
}

/* ---- state, budget and id maps ------------------------------------------ */
enum jtype { J_NULL, J_FALSE, J_TRUE, J_INT, J_STR, J_ARR, J_OBJ };
struct jnode {
    uint8_t type;
    uint32_t first, next, count;
    const char *key, *s;
    uint32_t key_len, len;
    int64_t i;
};
struct entry {
    const char *key;
    uint32_t len, value;
};
struct idmap {
    struct entry *slots;
    size_t cap, count;
};
struct chunk {
    struct chunk *next;
    size_t used, cap;
    char data[];
};
/* Retained bookkeeping, allocated together with the document. */
struct priv {
    struct chunk *chunks;
    size_t code_cap, function_cap, thread_cap, frame_cap, acquisition_cap, stack_cap, loss_cap;
};
struct box {
    struct xlf_doc doc;
    struct priv priv;
};
struct st {
    struct xlf_doc *doc;
    struct priv *priv;
    struct acct *acct;
    const struct xlf_cancel *cancel;
    const struct xlf_limits *lim;
    struct xlf_error *err;
    const uint8_t *line;
    size_t pos, len;
    uint64_t line_no, offset;
    struct jnode *nodes;
    size_t node_count, node_cap;
    char *scratch;
    size_t scratch_used, scratch_cap;
    struct idmap code_ids, function_ids, thread_ids, stack_ids, tids, code_paths;
    bool header_seen;
};

static bool fail(struct st *s, enum xlf_status status, const char *fmt, ...)
{
    if (s->err->status != XLF_OK)
        return false;
    s->err->status = status;
    s->err->line = s->line_no;
    s->err->offset = s->offset;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(s->err->message, sizeof s->err->message, fmt, ap);
    va_end(ap);
    return false;
}
#define TRY(x)                                                                                     \
    do {                                                                                           \
        if (!(x))                                                                                  \
            return false;                                                                          \
    } while (0)

static bool fail_alloc(struct st *s, enum acct_fail why)
{
    if (why == ACCT_BUDGET)
        return fail(s, XLF_E_MEMORY, "decode memory budget %zu exhausted", s->lim->max_memory);
    return fail(s, XLF_E_MEMORY, "out of memory");
}
static void *alloc(struct st *s, size_t n, bool zero)
{
    enum acct_fail why;
    void *p = acct_alloc(s->acct, n, zero, &why);
    if (!p)
        fail_alloc(s, why);
    return p;
}
static bool grow(struct st *s, void **array, size_t *cap, size_t need, size_t elem)
{
    if (need <= *cap)
        return true;
    size_t next = *cap ? *cap : 16;
    while (next < need) {
        if (next > SIZE_MAX / 2)
            return fail(s, XLF_E_MEMORY, "array size overflow");
        next *= 2;
    }
    if (next > SIZE_MAX / elem)
        return fail(s, XLF_E_MEMORY, "array size overflow");
    enum acct_fail why;
    void *p = acct_realloc(s->acct, *array, *cap * elem, next * elem, &why);
    if (!p)
        return fail_alloc(s, why);
    *array = p;
    *cap = next;
    return true;
}
static char *arena(struct st *s, size_t n)
{
    if (n > SIZE_MAX - 7 - sizeof(struct chunk)) {
        fail(s, XLF_E_MEMORY, "arena size overflow");
        return NULL;
    }
    n = (n + 7) & ~(size_t)7; /* keep every allocation pointer-aligned */
    struct chunk *c = s->priv->chunks;
    if (!c || c->cap - c->used < n) {
        size_t cap = n > 65536 ? n : 65536;
        c = alloc(s, sizeof *c + cap, false);
        if (!c)
            return NULL;
        c->next = s->priv->chunks;
        c->used = 0;
        c->cap = cap;
        s->priv->chunks = c;
    }
    char *p = c->data + c->used;
    c->used += n;
    return p;
}
static uint64_t hash_bytes(const char *p, size_t n)
{
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; ++i)
        h = (h ^ (uint8_t)p[i]) * 1099511628211ull;
    return h;
}
static struct entry *map_slot(struct idmap *m, const char *key, uint32_t len)
{
    size_t mask = m->cap - 1, i = (size_t)hash_bytes(key, len) & mask;
    while (m->slots[i].key && !(m->slots[i].len == len && !memcmp(m->slots[i].key, key, len)))
        i = (i + 1) & mask;
    return &m->slots[i];
}
static uint32_t map_get(struct idmap *m, const char *key, uint32_t len)
{
    if (!m->cap)
        return XLF_NONE;
    struct entry *e = map_slot(m, key, len);
    return e->key ? e->value : XLF_NONE;
}
/* Insert a key that must outlive the map (arena text). Returns false on duplicate. */
static bool map_put(struct st *s, struct idmap *m, const char *key, uint32_t len, uint32_t value,
                    bool *duplicate)
{
    *duplicate = false;
    if ((m->count + 1) * 2 > m->cap) {
        size_t cap = m->cap ? m->cap * 2 : 64;
        if (cap > SIZE_MAX / sizeof *m->slots)
            return fail(s, XLF_E_MEMORY, "map size overflow");
        struct entry *old = m->slots;
        size_t old_cap = m->cap;
        m->slots = alloc(s, cap * sizeof *m->slots, true);
        if (!m->slots) {
            m->slots = old;
            return false;
        }
        m->cap = cap;
        for (size_t i = 0; i < old_cap; ++i)
            if (old[i].key)
                *map_slot(m, old[i].key, old[i].len) = old[i];
        acct_free(s->acct, old, old_cap * sizeof *old);
    }
    struct entry *e = map_slot(m, key, len);
    if (e->key) {
        *duplicate = true;
        return true;
    }
    *e = (struct entry){key, len, value};
    m->count++;
    return true;
}

/* ---- UTF-8 and JSON ------------------------------------------------------ */
/* Strict UTF-8: no overlongs, no surrogates, no code points above U+10FFFF. */
static size_t utf8_invalid(const uint8_t *p, size_t n)
{
    size_t i = 0;
    while (i < n) {
        uint8_t c = p[i];
        if (c < 0x80) {
            ++i;
            continue;
        }
        size_t need;
        uint32_t cp, min;
        if (c >= 0xc2 && c <= 0xdf)
            need = 1, cp = c & 0x1f, min = 0x80;
        else if (c >= 0xe0 && c <= 0xef)
            need = 2, cp = c & 0x0f, min = 0x800;
        else if (c >= 0xf0 && c <= 0xf4)
            need = 3, cp = c & 0x07, min = 0x10000;
        else
            return i + 1;
        if (n - i <= need)
            return i + 1;
        for (size_t j = 1; j <= need; ++j) {
            if ((p[i + j] & 0xc0) != 0x80)
                return i + 1;
            cp = cp << 6 | (p[i + j] & 0x3f);
        }
        if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff))
            return i + 1;
        i += need + 1;
    }
    return 0;
}

static void ws(struct st *s)
{
    while (s->pos < s->len && (s->line[s->pos] == ' ' || s->line[s->pos] == '\t' || s->line[s->pos] == '\r'))
        ++s->pos;
}
static bool new_node(struct st *s, uint32_t *out)
{
    if (s->node_count >= s->lim->max_frames_per_stack * 16 + 4096)
        return fail(s, XLF_E_LIMIT, "record has too many JSON values");
    TRY(grow(s, (void **)&s->nodes, &s->node_cap, s->node_count + 1, sizeof *s->nodes));
    *out = (uint32_t)s->node_count;
    s->nodes[s->node_count++] = (struct jnode){.first = XLF_NONE, .next = XLF_NONE};
    return true;
}
static int hexval(uint8_t c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}
static bool hex4(struct st *s, uint32_t *v)
{
    if (s->len - s->pos < 4)
        return fail(s, XLF_E_JSON, "short \\u escape");
    *v = 0;
    for (int i = 0; i < 4; ++i) {
        int h = hexval(s->line[s->pos++]);
        if (h < 0)
            return fail(s, XLF_E_JSON, "bad \\u escape");
        *v = *v << 4 | (uint32_t)h;
    }
    return true;
}
/* Decode a JSON string into scratch (NUL terminated). Rejects NUL, lone surrogates. */
static bool jstring(struct st *s, const char **out, uint32_t *out_len)
{
    ++s->pos; /* opening quote */
    char *dst = s->scratch + s->scratch_used, *start = dst;
    for (;;) {
        if (s->pos >= s->len)
            return fail(s, XLF_E_JSON, "unterminated string");
        uint8_t c = s->line[s->pos++];
        if (c == '"')
            break;
        if (c < 0x20)
            return fail(s, XLF_E_JSON, "raw control character in string");
        if (c != '\\') {
            *dst++ = (char)c;
            continue;
        }
        if (s->pos >= s->len)
            return fail(s, XLF_E_JSON, "unterminated escape");
        c = s->line[s->pos++];
        switch (c) {
        case '"': *dst++ = '"'; break;
        case '\\': *dst++ = '\\'; break;
        case '/': *dst++ = '/'; break;
        case 'b': *dst++ = '\b'; break;
        case 'f': *dst++ = '\f'; break;
        case 'n': *dst++ = '\n'; break;
        case 'r': *dst++ = '\r'; break;
        case 't': *dst++ = '\t'; break;
        case 'u': {
            uint32_t cp;
            TRY(hex4(s, &cp));
            if (cp >= 0xdc00 && cp <= 0xdfff)
                return fail(s, XLF_E_UTF8, "lone low surrogate escape");
            if (cp >= 0xd800 && cp <= 0xdbff) {
                uint32_t lo;
                if (s->len - s->pos < 2 || s->line[s->pos] != '\\' || s->line[s->pos + 1] != 'u')
                    return fail(s, XLF_E_UTF8, "lone high surrogate escape");
                s->pos += 2;
                TRY(hex4(s, &lo));
                if (lo < 0xdc00 || lo > 0xdfff)
                    return fail(s, XLF_E_UTF8, "bad surrogate pair");
                cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
            }
            if (cp == 0)
                return fail(s, XLF_E_UTF8, "NUL is not permitted in text");
            /* An escape is at least 6 input bytes and at most 4 output bytes. */
            if (cp < 0x80)
                *dst++ = (char)cp;
            else if (cp < 0x800)
                *dst++ = (char)(0xc0 | cp >> 6), *dst++ = (char)(0x80 | (cp & 0x3f));
            else if (cp < 0x10000)
                *dst++ = (char)(0xe0 | cp >> 12), *dst++ = (char)(0x80 | ((cp >> 6) & 0x3f)),
                *dst++ = (char)(0x80 | (cp & 0x3f));
            else
                *dst++ = (char)(0xf0 | cp >> 18), *dst++ = (char)(0x80 | ((cp >> 12) & 0x3f)),
                *dst++ = (char)(0x80 | ((cp >> 6) & 0x3f)), *dst++ = (char)(0x80 | (cp & 0x3f));
            break;
        }
        default:
            return fail(s, XLF_E_JSON, "bad escape");
        }
    }
    size_t n = (size_t)(dst - start);
    if (n > s->lim->max_string_bytes)
        return fail(s, XLF_E_LIMIT, "string of %zu bytes exceeds %zu", n, s->lim->max_string_bytes);
    *dst++ = 0;
    s->scratch_used += n + 1;
    *out = start;
    *out_len = (uint32_t)n;
    return true;
}
static bool jvalue(struct st *s, uint32_t *out, unsigned depth)
{
    if (depth > s->lim->max_depth)
        return fail(s, XLF_E_LIMIT, "JSON nesting deeper than %u", s->lim->max_depth);
    ws(s);
    if (s->pos >= s->len)
        return fail(s, XLF_E_JSON, "unexpected end of record");
    uint32_t id = 0;
    TRY(new_node(s, &id));
    uint8_t c = s->line[s->pos];
    if (c == '"') {
        const char *p;
        uint32_t n;
        TRY(jstring(s, &p, &n));
        s->nodes[id].type = J_STR, s->nodes[id].s = p, s->nodes[id].len = n;
    } else if (c == '{' || c == '[') {
        bool object = c == '{';
        s->nodes[id].type = object ? J_OBJ : J_ARR;
        ++s->pos;
        ws(s);
        uint32_t last = XLF_NONE, count = 0;
        if (s->pos < s->len && s->line[s->pos] == (object ? '}' : ']')) {
            ++s->pos;
        } else
            for (;;) {
                const char *key = NULL;
                uint32_t key_len = 0, child;
                if (object) {
                    ws(s);
                    if (s->pos >= s->len || s->line[s->pos] != '"')
                        return fail(s, XLF_E_JSON, "expected object key");
                    TRY(jstring(s, &key, &key_len));
                    ws(s);
                    if (s->pos >= s->len || s->line[s->pos++] != ':')
                        return fail(s, XLF_E_JSON, "expected ':'");
                    if (count >= 64)
                        return fail(s, XLF_E_LIMIT, "object has more than 64 members");
                    for (uint32_t k = s->nodes[id].first; k != XLF_NONE; k = s->nodes[k].next)
                        if (s->nodes[k].key_len == key_len && !memcmp(s->nodes[k].key, key, key_len))
                            return fail(s, XLF_E_JSON, "duplicate key \"%.64s\"", key);
                }
                TRY(jvalue(s, &child, depth + 1));
                s->nodes[child].key = key, s->nodes[child].key_len = key_len;
                if (last == XLF_NONE)
                    s->nodes[id].first = child;
                else
                    s->nodes[last].next = child;
                last = child;
                ++count;
                ws(s);
                if (s->pos >= s->len)
                    return fail(s, XLF_E_JSON, "unterminated container");
                c = s->line[s->pos++];
                if (c == ',')
                    continue;
                if (c == (object ? '}' : ']'))
                    break;
                return fail(s, XLF_E_JSON, "expected ',' or close");
            }
        s->nodes[id].count = count;
    } else if (c == '-' || (c >= '0' && c <= '9')) {
        bool neg = c == '-';
        if (neg)
            ++s->pos;
        size_t start = s->pos;
        uint64_t v = 0;
        while (s->pos < s->len && s->line[s->pos] >= '0' && s->line[s->pos] <= '9') {
            if (s->pos - start >= 18)
                return fail(s, XLF_E_SCHEMA, "JSON integer too long; use a decimal string");
            v = v * 10 + (uint64_t)(s->line[s->pos++] - '0');
        }
        if (s->pos == start || (s->line[start] == '0' && s->pos - start > 1))
            return fail(s, XLF_E_JSON, "malformed number");
        if (s->pos < s->len && (s->line[s->pos] == '.' || s->line[s->pos] == 'e' || s->line[s->pos] == 'E'))
            return fail(s, XLF_E_SCHEMA, "non-integer numbers are not accepted");
        s->nodes[id].type = J_INT, s->nodes[id].i = neg ? -(int64_t)v : (int64_t)v;
    } else {
        static const struct {
            const char *word;
            uint8_t type;
        } words[] = {{"null", J_NULL}, {"true", J_TRUE}, {"false", J_FALSE}};
        size_t i = 0;
        for (; i < 3; ++i) {
            size_t n = strlen(words[i].word);
            if (s->len - s->pos >= n && !memcmp(s->line + s->pos, words[i].word, n)) {
                s->pos += n;
                s->nodes[id].type = words[i].type;
                break;
            }
        }
        if (i == 3)
            return fail(s, XLF_E_JSON, "unexpected character");
    }
    *out = id;
    return true;
}

/* ---- schema helpers ------------------------------------------------------ */
static struct jnode *N(struct st *s, uint32_t i)
{
    return &s->nodes[i];
}
static uint32_t field(struct st *s, uint32_t obj, const char *key)
{
    size_t n = strlen(key);
    for (uint32_t k = N(s, obj)->first; k != XLF_NONE; k = N(s, k)->next)
        if (N(s, k)->key_len == n && !memcmp(N(s, k)->key, key, n))
            return k;
    return XLF_NONE;
}
/* Reject members not in the allowed list; "x_" members are producer extensions. */
static bool only(struct st *s, uint32_t obj, const char *where, const char *const *keys)
{
    for (uint32_t k = N(s, obj)->first; k != XLF_NONE; k = N(s, k)->next) {
        const struct jnode *m = N(s, k);
        if (m->key_len > 2 && !memcmp(m->key, "x_", 2))
            continue;
        bool ok = false;
        for (const char *const *p = keys; *p && !ok; ++p)
            ok = strlen(*p) == m->key_len && !memcmp(*p, m->key, m->key_len);
        if (!ok)
            return fail(s, XLF_E_SCHEMA, "%s: unknown member \"%.64s\"", where, m->key);
    }
    return true;
}
static bool need(struct st *s, uint32_t obj, const char *key, uint32_t *out)
{
    *out = field(s, obj, key);
    if (*out == XLF_NONE)
        return fail(s, XLF_E_SCHEMA, "missing member \"%s\"", key);
    return true;
}
static bool copy_text(struct st *s, const char *p, uint32_t n, struct xlf_str *out)
{
    char *d = arena(s, (size_t)n + 1);
    if (!d)
        return false;
    memcpy(d, p, n);
    d[n] = 0;
    *out = (struct xlf_str){d, n};
    return true;
}
/* Text member. nullable: JSON null allowed. present: member must exist. */
static bool text(struct st *s, uint32_t obj, const char *key, struct xlf_str *out, bool nullable,
                 bool present)
{
    *out = (struct xlf_str){0};
    uint32_t k = field(s, obj, key);
    if (k == XLF_NONE)
        return present ? fail(s, XLF_E_SCHEMA, "missing member \"%s\"", key) : true;
    if (N(s, k)->type == J_NULL && nullable)
        return true;
    if (N(s, k)->type != J_STR)
        return fail(s, XLF_E_SCHEMA, "\"%s\" must be a string%s", key, nullable ? " or null" : "");
    if (!nullable && !N(s, k)->len)
        return fail(s, XLF_E_SCHEMA, "\"%s\" must not be empty", key);
    return copy_text(s, N(s, k)->s, N(s, k)->len, out);
}
static bool is_one(const struct xlf_str *v, const char *const *choices)
{
    for (; *choices; ++choices)
        if (v->ptr && !strcmp(v->ptr, *choices))
            return true;
    return false;
}
static bool choice(struct st *s, uint32_t obj, const char *key, struct xlf_str *out,
                   const char *const *choices)
{
    TRY(text(s, obj, key, out, false, true));
    if (!is_one(out, choices))
        return fail(s, XLF_E_SCHEMA, "\"%s\" has unsupported value \"%.64s\"", key, out->ptr);
    return true;
}
/* Small non-negative JSON integer, or null (-1) when nullable. */
static bool small(struct st *s, uint32_t obj, const char *key, int64_t max, bool nullable, int64_t *out)
{
    *out = -1;
    uint32_t k;
    TRY(need(s, obj, key, &k));
    if (N(s, k)->type == J_NULL && nullable)
        return true;
    if (N(s, k)->type != J_INT || N(s, k)->i < 0 || N(s, k)->i > max)
        return fail(s, XLF_E_SCHEMA, "\"%s\" must be an integer in 0..%lld%s", key, (long long)max,
                    nullable ? " or null" : "");
    *out = N(s, k)->i;
    return true;
}
/* Exact unsigned 64-bit decimal string ("0" or no leading zeros). */
static bool dec_u64(const char *p, size_t n, uint64_t *out)
{
    if (!n || n > 20 || (p[0] == '0' && n > 1))
        return false;
    uint64_t v = 0;
    for (size_t i = 0; i < n; ++i) {
        if (p[i] < '0' || p[i] > '9')
            return false;
        uint64_t d = (uint64_t)(p[i] - '0');
        if (v > (UINT64_MAX - d) / 10)
            return false;
        v = v * 10 + d;
    }
    *out = v;
    return true;
}
/* Canonical lowercase hexadecimal address "0x0".."0xffffffffffffffff". */
static bool hex_u64(const char *p, size_t n, uint64_t *out)
{
    if (n < 3 || n > 18 || p[0] != '0' || p[1] != 'x' || (p[2] == '0' && n > 3))
        return false;
    uint64_t v = 0;
    for (size_t i = 2; i < n; ++i) {
        int h = hexval((uint8_t)p[i]);
        if (h < 0 || (p[i] >= 'A' && p[i] <= 'F'))
            return false;
        v = v << 4 | (uint64_t)h;
    }
    *out = v;
    return true;
}
static bool u64_text(struct st *s, uint32_t obj, const char *key, bool nullable, bool hex,
                     struct xlf_opt_u64 *out)
{
    *out = (struct xlf_opt_u64){0};
    uint32_t k;
    TRY(need(s, obj, key, &k));
    if (N(s, k)->type == J_NULL && nullable)
        return true;
    if (N(s, k)->type != J_STR || !(hex ? hex_u64 : dec_u64)(N(s, k)->s, N(s, k)->len, &out->value))
        return fail(s, XLF_E_SCHEMA, "\"%s\" must be a canonical %s u64 string%s", key,
                    hex ? "0x-hexadecimal" : "decimal", nullable ? " or null" : "");
    out->known = true;
    return true;
}
static bool lower_hex(const struct xlf_str *v, size_t min, size_t max)
{
    if (v->len < min || v->len > max || v->len % 2)
        return false;
    for (size_t i = 0; i < v->len; ++i)
        if (!((v->ptr[i] >= '0' && v->ptr[i] <= '9') || (v->ptr[i] >= 'a' && v->ptr[i] <= 'f')))
            return false;
    return true;
}
/* A content digest: 64 lowercase hex or null; null requires a reason. */
static bool digest(struct st *s, uint32_t obj, const char *key, struct xlf_str *out)
{
    TRY(text(s, obj, key, out, true, true));
    if (out->ptr && !lower_hex(out, 64, 64))
        return fail(s, XLF_E_IDENTITY, "\"%s\" is not a lowercase SHA-256", key);
    return true;
}
static bool reason_if_null(struct st *s, const struct xlf_str *value, uint32_t obj, const char *key,
                           struct xlf_str *reason)
{
    TRY(text(s, obj, key, reason, true, false));
    if (!value->ptr && (!reason->ptr || !reason->len))
        return fail(s, XLF_E_IDENTITY, "absent identity requires \"%s\"", key);
    return true;
}
static bool object(struct st *s, uint32_t obj, const char *key, bool nullable, uint32_t *out)
{
    TRY(need(s, obj, key, out));
    if (N(s, *out)->type == J_NULL && nullable) {
        *out = XLF_NONE;
        return true;
    }
    if (N(s, *out)->type != J_OBJ)
        return fail(s, XLF_E_SCHEMA, "\"%s\" must be an object%s", key, nullable ? " or null" : "");
    return true;
}
static struct xlf_cite cite(struct st *s)
{
    return (struct xlf_cite){s->line_no, s->offset, s->len};
}
static bool ref(struct st *s, struct idmap *m, uint32_t obj, const char *key, bool nullable,
                uint32_t *out, const char *what)
{
    *out = XLF_NONE;
    uint32_t k;
    TRY(need(s, obj, key, &k));
    if (N(s, k)->type == J_NULL && nullable)
        return true;
    if (N(s, k)->type != J_STR)
        return fail(s, XLF_E_SCHEMA, "\"%s\" must be a %s id", key, what);
    *out = map_get(m, N(s, k)->s, N(s, k)->len);
    if (*out == XLF_NONE)
        return fail(s, XLF_E_REFERENCE, "%s \"%.64s\" is not defined earlier", what, N(s, k)->s);
    return true;
}
static bool define(struct st *s, struct idmap *m, uint32_t obj, struct xlf_str *id, size_t index,
                   const char *what)
{
    TRY(text(s, obj, "id", id, false, true));
    if (id->len > 256)
        return fail(s, XLF_E_LIMIT, "%s id longer than 256 bytes", what);
    bool dup;
    TRY(map_put(s, m, id->ptr, id->len, (uint32_t)index, &dup));
    if (dup)
        return fail(s, XLF_E_DUPLICATE, "duplicate %s id \"%.64s\"", what, id->ptr);
    return true;
}
static bool entity_room(struct st *s, size_t count, const char *what)
{
    if (count >= s->lim->max_entities)
        return fail(s, XLF_E_LIMIT, "more than %zu %s records", s->lim->max_entities, what);
    return true;
}
static const char *const kinds_all[] = {"interpreter", "native", "native_transition", "jit",
                                        "logical", "unknown", "unclassified", NULL};
static enum xlf_kind kind_of(const struct xlf_str *v)
{
    for (unsigned i = 0; kinds_all[i]; ++i)
        if (!strcmp(v->ptr, kinds_all[i]))
            return (enum xlf_kind)i;
    return XLF_KIND_UNKNOWN;
}

/* ---- records ------------------------------------------------------------- */
static bool header(struct st *s, uint32_t r)
{
    static const char *const keys[] = {"type", "format", "version", "draft", "producer", "source_kind",
                                       "runtime", "process", "clock", "clock_unavailable", "command",
                                       "collection", "frame_order", "weight_unit", "weight_semantics", NULL};
    TRY(only(s, r, "header", keys));
    struct xlf_header *h = &s->doc->header;
    struct xlf_str format, draft, order;
    int64_t version;
    TRY(text(s, r, "format", &format, false, true));
    TRY(small(s, r, "version", 1000000, false, &version));
    if (strcmp(format.ptr, XLF_FORMAT) || version != XLF_VERSION)
        return fail(s, XLF_E_VERSION, "unsupported format %.64s version %lld", format.ptr, (long long)version);
    TRY(text(s, r, "draft", &draft, false, true));
    if (strcmp(draft.ptr, XLF_DRAFT))
        return fail(s, XLF_E_VERSION, "unsupported draft %.64s", draft.ptr);

    uint32_t o;
    TRY(object(s, r, "producer", false, &o));
    static const char *const pkeys[] = {"name", "version", "kind", "sha256", NULL};
    static const char *const pkinds[] = {"cooperating_in_process", "external_reader", "report_converter", NULL};
    TRY(only(s, o, "producer", pkeys));
    TRY(text(s, o, "name", &h->producer_name, false, true));
    TRY(text(s, o, "version", &h->producer_version, false, true));
    TRY(choice(s, o, "kind", &h->producer_kind, pkinds));
    TRY(digest(s, o, "sha256", &h->producer_sha256));

    static const char *const sources[] = {"cooperative_sample", "cooperative_emit", "stopped_snapshot",
                                          "external_sample", "imported_report", NULL};
    TRY(choice(s, r, "source_kind", &h->source_kind, sources));

    TRY(object(s, r, "runtime", false, &o));
    static const char *const rkeys[] = {"language", "implementation", "version", "build", "executable", "library", NULL};
    static const char *const ikeys[] = {"path", "sha256", "gnu_build_id", "unavailable", NULL};
    TRY(only(s, o, "runtime", rkeys));
    TRY(text(s, o, "language", &h->language, false, true));
    TRY(text(s, o, "implementation", &h->implementation, false, true));
    TRY(text(s, o, "version", &h->runtime_version, false, true));
    TRY(text(s, o, "build", &h->runtime_build, true, true));
    for (int lib = 0; lib < 2; ++lib) {
        uint32_t e;
        TRY(object(s, o, lib ? "library" : "executable", lib, &e));
        if (e == XLF_NONE)
            continue;
        struct xlf_str path, sha, bid, why;
        TRY(only(s, e, lib ? "runtime.library" : "runtime.executable", ikeys));
        TRY(text(s, e, "path", &path, true, true));
        TRY(digest(s, e, "sha256", &sha));
        TRY(reason_if_null(s, &sha, e, "unavailable", &why));
        TRY(text(s, e, "gnu_build_id", &bid, true, true));
        if (bid.ptr && !lower_hex(&bid, 2, 128))
            return fail(s, XLF_E_IDENTITY, "gnu_build_id is not lowercase hexadecimal bytes");
        if (lib)
            h->library_path = path, h->library_sha256 = sha, h->library_build_id = bid;
        else
            h->executable_path = path, h->executable_sha256 = sha, h->executable_build_id = bid,
            h->executable_unavailable = why;
    }

    TRY(object(s, r, "process", false, &o));
    static const char *const prkeys[] = {"pid", "start_ticks", "boot_id", "unavailable", NULL};
    TRY(only(s, o, "process", prkeys));
    TRY(small(s, o, "pid", 0x7fffffff, true, &h->pid));
    if (h->pid == 0)
        return fail(s, XLF_E_IDENTITY, "pid 0 is not a process identity");
    TRY(u64_text(s, o, "start_ticks", true, false, &h->start_ticks));
    TRY(text(s, o, "boot_id", &h->boot_id, true, true));
    if (h->boot_id.ptr) {
        static const char pattern[] = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
        bool ok = h->boot_id.len == 36;
        for (size_t i = 0; ok && i < 36; ++i) {
            char c = h->boot_id.ptr[i];
            ok = pattern[i] == '-' ? c == '-' : ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'));
        }
        if (!ok)
            return fail(s, XLF_E_IDENTITY, "boot_id is not a lowercase UUID");
    }
    TRY(text(s, o, "unavailable", &h->process_unavailable, true, false));
    if ((h->pid < 0 || !h->start_ticks.known) && !h->process_unavailable.ptr)
        return fail(s, XLF_E_IDENTITY, "incomplete process instance requires \"unavailable\"");

    TRY(object(s, r, "clock", true, &o));
    if (o != XLF_NONE) {
        static const char *const ckeys[] = {"domain", "unit", NULL};
        static const char *const units[] = {"ns", NULL};
        struct xlf_str unit;
        TRY(only(s, o, "clock", ckeys));
        TRY(text(s, o, "domain", &h->clock_domain, false, true));
        TRY(choice(s, o, "unit", &unit, units));
        h->has_clock = true;
    } else {
        TRY(text(s, r, "clock_unavailable", &h->clock_unavailable, false, true));
        s->doc->warnings |= XLF_W_NO_CLOCK;
    }

    uint32_t c;
    TRY(need(s, r, "command", &c));
    if (N(s, c)->type == J_ARR) {
        if (N(s, c)->count > 4096)
            return fail(s, XLF_E_LIMIT, "command has more than 4096 arguments");
        h->command = (struct xlf_str *)(void *)arena(s, (N(s, c)->count + 1) * sizeof *h->command);
        if (!h->command)
            return false;
        for (uint32_t a = N(s, c)->first; a != XLF_NONE; a = N(s, a)->next) {
            if (N(s, a)->type != J_STR)
                return fail(s, XLF_E_SCHEMA, "command arguments must be strings");
            TRY(copy_text(s, N(s, a)->s, N(s, a)->len, &h->command[h->command_count++]));
        }
    } else if (N(s, c)->type != J_NULL)
        return fail(s, XLF_E_SCHEMA, "\"command\" must be an array or null");

    TRY(object(s, r, "collection", false, &o));
    static const char *const ckeys[] = {"method", "trigger", "interval_ns", "atomicity", "notes", NULL};
    static const char *const atom[] = {"all_threads_one_call", "per_thread_sequential", "process_stopped",
                                       "single_thread", "not_applicable", NULL};
    TRY(only(s, o, "collection", ckeys));
    TRY(text(s, o, "method", &h->method, false, true));
    TRY(text(s, o, "trigger", &h->trigger, false, true));
    TRY(u64_text(s, o, "interval_ns", true, false, &h->interval_ns));
    TRY(choice(s, o, "atomicity", &h->atomicity, atom));
    TRY(text(s, o, "notes", &h->notes, true, false));

    static const char *const orders[] = {"innermost_first", NULL};
    TRY(choice(s, r, "frame_order", &order, orders));
    TRY(text(s, r, "weight_unit", &h->weight_unit, false, true));
    TRY(text(s, r, "weight_semantics", &h->weight_semantics, false, true));
    return true;
}

static bool code(struct st *s, uint32_t r)
{
    static const char *const keys[] = {"type", "id", "kind", "path", "sha256", "bytes", "unavailable", "range", NULL};
    static const char *const kinds[] = {"source_file", "builtin", "native_library", "jit", "generated", "unknown", NULL};
    TRY(only(s, r, "code", keys));
    struct xlf_doc *d = s->doc;
    TRY(entity_room(s, d->code_count, "code"));
    TRY(grow(s, (void **)&d->codes, &s->priv->code_cap, d->code_count + 1, sizeof *d->codes));
    struct xlf_code *c = &d->codes[d->code_count];
    *c = (struct xlf_code){.cite = cite(s)};
    TRY(define(s, &s->code_ids, r, &c->id, d->code_count, "code"));
    TRY(choice(s, r, "kind", &c->kind, kinds));
    TRY(text(s, r, "path", &c->path, true, true));
    TRY(digest(s, r, "sha256", &c->sha256));
    TRY(reason_if_null(s, &c->sha256, r, "unavailable", &c->unavailable));
    int64_t bytes;
    TRY(small(s, r, "bytes", INT64_MAX, true, &bytes));
    c->bytes = (struct xlf_opt_u64){bytes >= 0, bytes >= 0 ? (uint64_t)bytes : 0};
    uint32_t g = field(s, r, "range");
    if (g != XLF_NONE) {
        static const char *const gkeys[] = {"start", "end", "load_ns", "unload_ns", NULL};
        if (N(s, g)->type != J_OBJ)
            return fail(s, XLF_E_SCHEMA, "\"range\" must be an object");
        TRY(only(s, g, "range", gkeys));
        struct xlf_opt_u64 a, b;
        TRY(u64_text(s, g, "start", false, true, &a));
        TRY(u64_text(s, g, "end", false, true, &b));
        if (b.value <= a.value)
            return fail(s, XLF_E_ADDRESS, "code range end must exceed start");
        TRY(u64_text(s, g, "load_ns", true, false, &c->load_ns));
        TRY(u64_text(s, g, "unload_ns", true, false, &c->unload_ns));
        if (c->load_ns.known && c->unload_ns.known && c->unload_ns.value < c->load_ns.value)
            return fail(s, XLF_E_CLOCK, "code unloaded before it was loaded");
        c->has_range = true, c->start = a.value, c->end = b.value;
        /* Address reuse creates a new code identity. Overlap is only valid
         * when both lifetimes are known and disjoint. */
        for (size_t i = 0; i < d->code_count; ++i) {
            const struct xlf_code *o = &d->codes[i];
            if (!o->has_range || o->end <= c->start || c->end <= o->start)
                continue;
            if (o->unload_ns.known && c->load_ns.known && o->unload_ns.value <= c->load_ns.value)
                continue;
            if (c->unload_ns.known && o->load_ns.known && c->unload_ns.value <= o->load_ns.value)
                continue;
            /* Definite conflict: at one code's known load time the other is
             * known to be live (loaded no later, unload known and later). */
            if ((c->load_ns.known && o->load_ns.known && o->unload_ns.known &&
                 o->load_ns.value <= c->load_ns.value && c->load_ns.value < o->unload_ns.value) ||
                (o->load_ns.known && c->load_ns.known && c->unload_ns.known &&
                 c->load_ns.value <= o->load_ns.value && o->load_ns.value < c->unload_ns.value))
                return fail(s, XLF_E_ADDRESS, "code \"%.64s\" overlaps live code \"%.64s\"", c->id.ptr, o->id.ptr);
            d->warnings |= XLF_W_ADDRESS_REUSE;
        }
    }
    if (c->path.ptr && c->sha256.ptr) {
        bool dup;
        uint32_t prior = map_get(&s->code_paths, c->path.ptr, c->path.len);
        if (prior != XLF_NONE && strcmp(d->codes[prior].sha256.ptr, c->sha256.ptr))
            d->warnings |= XLF_W_CODE_PATH_REUSED;
        else if (prior == XLF_NONE)
            TRY(map_put(s, &s->code_paths, c->path.ptr, c->path.len, (uint32_t)d->code_count, &dup));
    }
    d->code_count++;
    return true;
}

static const char *const fn_kinds[] = {"interpreter", "native", "jit", "logical", "unclassified", NULL};
static bool function(struct st *s, uint32_t r)
{
    static const char *const keys[] = {"type", "id", "name", "qualified", "code", "first_line", "frame_kind", "runtime_id", NULL};
    TRY(only(s, r, "function", keys));
    struct xlf_doc *d = s->doc;
    TRY(entity_room(s, d->function_count, "function"));
    TRY(grow(s, (void **)&d->functions, &s->priv->function_cap, d->function_count + 1, sizeof *d->functions));
    struct xlf_function *f = &d->functions[d->function_count];
    *f = (struct xlf_function){.cite = cite(s)};
    TRY(define(s, &s->function_ids, r, &f->id, d->function_count, "function"));
    TRY(text(s, r, "name", &f->name, false, true));
    TRY(text(s, r, "qualified", &f->qualified, true, true));
    TRY(ref(s, &s->code_ids, r, "code", true, &f->code, "code"));
    TRY(small(s, r, "first_line", 0x7fffffff, true, &f->first_line));
    struct xlf_str kind;
    TRY(choice(s, r, "frame_kind", &kind, fn_kinds));
    f->kind = kind_of(&kind);
    TRY(text(s, r, "runtime_id", &f->runtime_id, true, false));
    d->function_count++;
    return true;
}

static bool thread(struct st *s, uint32_t r)
{
    static const char *const keys[] = {"type", "id", "language_id", "name", "os_tid", "os_tid_source", "os_tid_reason", "pid", NULL};
    TRY(only(s, r, "thread", keys));
    struct xlf_doc *d = s->doc;
    TRY(entity_room(s, d->thread_count, "thread"));
    TRY(grow(s, (void **)&d->threads, &s->priv->thread_cap, d->thread_count + 1, sizeof *d->threads));
    struct xlf_thread *t = &d->threads[d->thread_count];
    *t = (struct xlf_thread){.cite = cite(s)};
    TRY(define(s, &s->thread_ids, r, &t->id, d->thread_count, "thread"));
    TRY(text(s, r, "language_id", &t->language_id, true, true));
    TRY(text(s, r, "name", &t->name, true, true));
    TRY(small(s, r, "os_tid", 0x7fffffff, true, &t->os_tid));
    if (t->os_tid == 0)
        return fail(s, XLF_E_IDENTITY, "os_tid 0 is not a thread identity");
    TRY(text(s, r, "os_tid_source", &t->os_tid_source, true, false));
    TRY(text(s, r, "os_tid_reason", &t->os_tid_reason, true, false));
    if (t->os_tid < 0 && !t->os_tid_reason.ptr)
        return fail(s, XLF_E_IDENTITY, "unknown os_tid requires os_tid_reason");
    if (t->os_tid > 0 && !t->os_tid_source.ptr)
        return fail(s, XLF_E_IDENTITY, "os_tid requires os_tid_source");
    if (field(s, r, "pid") != XLF_NONE) {
        int64_t pid;
        TRY(small(s, r, "pid", 0x7fffffff, false, &pid));
        if (d->header.pid < 0 || pid != d->header.pid)
            return fail(s, XLF_E_IDENTITY, "thread pid %lld does not match the header process", (long long)pid);
    }
    if (t->os_tid > 0) {
        char key[8];
        memcpy(key, &t->os_tid, sizeof key);
        char *stable = arena(s, sizeof key);
        if (!stable)
            return false;
        memcpy(stable, key, sizeof key);
        uint32_t prior = map_get(&s->tids, stable, sizeof key);
        if (prior != XLF_NONE) {
            /* TID reuse after exit, or M:N scheduling: never merge the threads. */
            d->threads[prior].os_tid_shared = t->os_tid_shared = true;
            d->warnings |= XLF_W_OS_TID_SHARED;
        } else {
            bool dup;
            TRY(map_put(s, &s->tids, stable, sizeof key, (uint32_t)d->thread_count, &dup));
        }
    }
    d->thread_count++;
    return true;
}

static bool acquisition(struct st *s, uint32_t r)
{
    static const char *const keys[] = {"type", "seq", "start_ns", "end_ns", "stacks", NULL};
    TRY(only(s, r, "acquisition", keys));
    struct xlf_doc *d = s->doc;
    if (d->acquisition_count >= s->lim->max_stacks)
        return fail(s, XLF_E_LIMIT, "more than %zu acquisitions", s->lim->max_stacks);
    TRY(grow(s, (void **)&d->acquisitions, &s->priv->acquisition_cap, d->acquisition_count + 1, sizeof *d->acquisitions));
    struct xlf_acquisition *a = &d->acquisitions[d->acquisition_count];
    *a = (struct xlf_acquisition){.cite = cite(s)};
    int64_t seq, stacks;
    TRY(small(s, r, "seq", INT64_MAX, false, &seq));
    if (d->acquisition_count && (uint64_t)seq <= d->acquisitions[d->acquisition_count - 1].seq)
        return fail(s, XLF_E_DUPLICATE, "acquisition seq %lld is not strictly increasing", (long long)seq);
    a->seq = (uint64_t)seq;
    TRY(u64_text(s, r, "start_ns", true, false, &a->start_ns));
    TRY(u64_text(s, r, "end_ns", true, false, &a->end_ns));
    if (a->start_ns.known != a->end_ns.known)
        return fail(s, XLF_E_CLOCK, "acquisition interval must be fully known or fully unknown");
    if (a->start_ns.known && !d->header.has_clock)
        return fail(s, XLF_E_CLOCK, "time value without a declared clock");
    if (a->start_ns.known && a->end_ns.value < a->start_ns.value)
        return fail(s, XLF_E_CLOCK, "acquisition ends before it starts");
    TRY(small(s, r, "stacks", 1 << 20, false, &stacks));
    a->declared_stacks = (uint64_t)stacks;
    d->acquisition_count++;
    return true;
}

static bool frame(struct st *s, uint32_t f, struct xlf_frame *out)
{
    static const char *const keys[] = {"function", "kind", "line", "provenance", "label", "reason", "pc", NULL};
    static const char *const provs[] = {"runtime", "cooperative_annotation", "external_read", NULL};
    if (N(s, f)->type != J_OBJ)
        return fail(s, XLF_E_SCHEMA, "frames must be objects");
    TRY(only(s, f, "frame", keys));
    *out = (struct xlf_frame){0};
    TRY(ref(s, &s->function_ids, f, "function", true, &out->function, "function"));
    struct xlf_str kind, prov;
    TRY(choice(s, f, "kind", &kind, kinds_all));
    out->kind = kind_of(&kind);
    TRY(choice(s, f, "provenance", &prov, provs));
    out->provenance = !strcmp(prov.ptr, "runtime") ? XLF_PROV_RUNTIME
                      : !strcmp(prov.ptr, "external_read") ? XLF_PROV_EXTERNAL
                                                           : XLF_PROV_COOPERATIVE;
    TRY(small(s, f, "line", 0x7fffffff, true, &out->line));
    TRY(text(s, f, "label", &out->label, true, false));
    TRY(text(s, f, "reason", &out->reason, true, false));
    if (out->function != XLF_NONE) {
        if (s->doc->functions[out->function].kind != out->kind)
            return fail(s, XLF_E_SCHEMA, "frame kind %s differs from its function kind", kind.ptr);
    } else {
        if (out->kind != XLF_KIND_NATIVE_TRANSITION && out->kind != XLF_KIND_UNKNOWN)
            return fail(s, XLF_E_SCHEMA, "only native_transition/unknown marker frames may omit function");
        if (!out->label.ptr || !out->reason.ptr)
            return fail(s, XLF_E_SCHEMA, "marker frames require label and reason");
    }
    if (out->kind == XLF_KIND_NATIVE_TRANSITION && out->function != XLF_NONE)
        return fail(s, XLF_E_SCHEMA, "native_transition is a marker, not a function");
    if (out->line < 0 && out->kind == XLF_KIND_INTERPRETER && !out->reason.ptr)
        return fail(s, XLF_E_SCHEMA, "interpreter frame without line requires reason");
    uint32_t pc = field(s, f, "pc");
    if (pc != XLF_NONE) {
        /* Interpreter, logical and cooperative frames have no machine PC. */
        if ((out->kind != XLF_KIND_NATIVE && out->kind != XLF_KIND_JIT) || out->provenance == XLF_PROV_COOPERATIVE)
            return fail(s, XLF_E_INVENTED_PC, "a %s/%s frame cannot carry a native PC", kind.ptr, prov.ptr);
        struct xlf_opt_u64 v;
        TRY(u64_text(s, f, "pc", false, true, &v));
        out->has_pc = true, out->pc = v.value;
    }
    return true;
}

static bool stack(struct st *s, uint32_t r)
{
    static const char *const keys[] = {"type", "id", "acquisition", "thread", "start_ns", "end_ns", "trigger", "weight",
                                       "state", "omitted", "reason", "exception", "frames", NULL};
    static const char *const states[] = {"complete", "truncated", "partial", NULL};
    TRY(only(s, r, "stack", keys));
    struct xlf_doc *d = s->doc;
    if (d->stack_count >= s->lim->max_stacks)
        return fail(s, XLF_E_LIMIT, "more than %zu stacks", s->lim->max_stacks);
    TRY(grow(s, (void **)&d->stacks, &s->priv->stack_cap, d->stack_count + 1, sizeof *d->stacks));
    struct xlf_stack *k = &d->stacks[d->stack_count];
    *k = (struct xlf_stack){.cite = cite(s), .first_frame = (uint32_t)d->frame_count};
    TRY(define(s, &s->stack_ids, r, &k->id, d->stack_count, "stack"));
    int64_t seq;
    TRY(small(s, r, "acquisition", INT64_MAX, false, &seq));
    /* Acquisitions are strictly increasing: binary search. */
    size_t lo = 0, hi = d->acquisition_count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (d->acquisitions[mid].seq < (uint64_t)seq)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == d->acquisition_count || d->acquisitions[lo].seq != (uint64_t)seq)
        return fail(s, XLF_E_REFERENCE, "acquisition %lld is not defined earlier", (long long)seq);
    struct xlf_acquisition *a = &d->acquisitions[lo];
    k->acquisition = (uint32_t)lo;
    if (++a->seen_stacks > a->declared_stacks)
        return fail(s, XLF_E_COUNT, "acquisition %lld has more stacks than declared", (long long)seq);
    TRY(ref(s, &s->thread_ids, r, "thread", false, &k->thread, "thread"));
    TRY(u64_text(s, r, "start_ns", true, false, &k->start_ns));
    TRY(u64_text(s, r, "end_ns", true, false, &k->end_ns));
    if (k->start_ns.known != k->end_ns.known)
        return fail(s, XLF_E_CLOCK, "stack interval must be fully known or fully unknown");
    if (k->start_ns.known) {
        if (!d->header.has_clock)
            return fail(s, XLF_E_CLOCK, "time value without a declared clock");
        if (k->end_ns.value < k->start_ns.value)
            return fail(s, XLF_E_CLOCK, "stack acquisition ends before it starts");
        if (!a->start_ns.known || k->start_ns.value < a->start_ns.value || k->end_ns.value > a->end_ns.value)
            return fail(s, XLF_E_CLOCK, "stack interval is outside its acquisition interval");
    }
    TRY(text(s, r, "trigger", &k->trigger, false, true));
    struct xlf_opt_u64 w;
    TRY(u64_text(s, r, "weight", false, false, &w));
    if (!w.value)
        return fail(s, XLF_E_SCHEMA, "weight must be positive");
    k->weight = w.value;
    if (!xlf_count_add(&d->total_weight, w.value)) /* unreachable below 2^64 stacks */
        return fail(s, XLF_E_OVERFLOW, "total weight exceeds 128 bits");
    struct xlf_str state;
    TRY(choice(s, r, "state", &state, states));
    k->state = !strcmp(state.ptr, "complete") ? XLF_STACK_COMPLETE
               : !strcmp(state.ptr, "truncated") ? XLF_STACK_TRUNCATED
                                                 : XLF_STACK_PARTIAL;
    TRY(u64_text(s, r, "omitted", true, false, &k->omitted));
    TRY(text(s, r, "reason", &k->reason, true, true));
    if (k->state != XLF_STACK_COMPLETE) {
        if (!k->reason.ptr)
            return fail(s, XLF_E_SCHEMA, "%s stack requires reason", state.ptr);
        d->warnings |= XLF_W_PARTIAL_STACKS;
    } else if (k->omitted.known && k->omitted.value)
        return fail(s, XLF_E_SCHEMA, "complete stack cannot omit frames");
    uint32_t e = field(s, r, "exception");
    if (e != XLF_NONE && N(s, e)->type != J_NULL) {
        static const char *const ekeys[] = {"type", "message", NULL};
        struct xlf_str message;
        if (N(s, e)->type != J_OBJ)
            return fail(s, XLF_E_SCHEMA, "\"exception\" must be an object or null");
        TRY(only(s, e, "exception", ekeys));
        TRY(text(s, e, "type", &k->exception_type, false, true));
        TRY(text(s, e, "message", &message, true, true));
    }
    uint32_t fr;
    TRY(need(s, r, "frames", &fr));
    if (N(s, fr)->type != J_ARR)
        return fail(s, XLF_E_SCHEMA, "\"frames\" must be an array");
    if (N(s, fr)->count > s->lim->max_frames_per_stack)
        return fail(s, XLF_E_LIMIT, "stack has %u frames, limit %zu", N(s, fr)->count, s->lim->max_frames_per_stack);
    if (d->frame_count + N(s, fr)->count > s->lim->max_total_frames)
        return fail(s, XLF_E_LIMIT, "more than %zu frames in total", s->lim->max_total_frames);
    if (!N(s, fr)->count && k->state == XLF_STACK_COMPLETE)
        return fail(s, XLF_E_SCHEMA, "a complete stack needs at least one frame");
    TRY(grow(s, (void **)&d->frames, &s->priv->frame_cap, d->frame_count + N(s, fr)->count, sizeof *d->frames));
    for (uint32_t f = N(s, fr)->first; f != XLF_NONE; f = N(s, f)->next)
        TRY(frame(s, f, &d->frames[d->frame_count++]));
    k->frame_count = N(s, fr)->count;
    d->stack_count++;
    return true;
}

static bool loss(struct st *s, uint32_t r)
{
    static const char *const keys[] = {"type", "reason", "count", "acquisition", NULL};
    TRY(only(s, r, "loss", keys));
    struct xlf_doc *d = s->doc;
    TRY(entity_room(s, d->loss_count, "loss"));
    TRY(grow(s, (void **)&d->losses, &s->priv->loss_cap, d->loss_count + 1, sizeof *d->losses));
    struct xlf_loss *l = &d->losses[d->loss_count];
    *l = (struct xlf_loss){.cite = cite(s), .acquisition = XLF_NONE};
    TRY(text(s, r, "reason", &l->reason, false, true));
    struct xlf_opt_u64 n;
    TRY(u64_text(s, r, "count", false, false, &n));
    l->count = n.value;
    int64_t seq;
    TRY(small(s, r, "acquisition", INT64_MAX, true, &seq));
    if (seq >= 0) {
        for (size_t i = d->acquisition_count; i-- > 0;)
            if (d->acquisitions[i].seq == (uint64_t)seq)
                l->acquisition = (uint32_t)i;
        if (l->acquisition == XLF_NONE)
            return fail(s, XLF_E_REFERENCE, "loss cites undefined acquisition %lld", (long long)seq);
    }
    if (!xlf_count_add(&d->lost, n.value)) /* unreachable below 2^64 loss records */
        return fail(s, XLF_E_OVERFLOW, "loss total exceeds 128 bits");
    d->warnings |= XLF_W_LOSS;
    d->loss_count++;
    return true;
}

static bool end(struct st *s, uint32_t r)
{
    static const char *const keys[] = {"type", "records", "acquisitions", "stacks", "status", NULL};
    static const char *const statuses[] = {"complete", "interrupted", NULL};
    TRY(only(s, r, "end", keys));
    struct xlf_doc *d = s->doc;
    int64_t records, acquisitions, stacks;
    TRY(small(s, r, "records", INT64_MAX, false, &records));
    TRY(small(s, r, "acquisitions", INT64_MAX, false, &acquisitions));
    TRY(small(s, r, "stacks", INT64_MAX, false, &stacks));
    TRY(choice(s, r, "status", &d->end_status, statuses));
    if ((uint64_t)records != s->line_no - 1 || (uint64_t)acquisitions != d->acquisition_count ||
        (uint64_t)stacks != d->stack_count)
        return fail(s, XLF_E_COUNT, "end record counts (%lld/%lld/%lld) disagree with input (%llu/%zu/%zu)",
                    (long long)records, (long long)acquisitions, (long long)stacks,
                    (unsigned long long)(s->line_no - 1), d->acquisition_count, d->stack_count);
    for (size_t i = 0; i < d->acquisition_count; ++i)
        if (d->acquisitions[i].seen_stacks != d->acquisitions[i].declared_stacks)
            return fail(s, XLF_E_COUNT, "acquisition %llu declared %llu stacks, found %llu",
                        (unsigned long long)d->acquisitions[i].seq,
                        (unsigned long long)d->acquisitions[i].declared_stacks,
                        (unsigned long long)d->acquisitions[i].seen_stacks);
    if (!strcmp(d->end_status.ptr, "interrupted"))
        d->warnings |= XLF_W_INTERRUPTED;
    d->ended = true;
    return true;
}

static bool record(struct st *s)
{
    s->node_count = 0;
    s->scratch_used = 0;
    if (s->len > s->lim->max_line_bytes)
        return fail(s, XLF_E_LIMIT, "record of %zu bytes exceeds %zu", s->len, s->lim->max_line_bytes);
    if (s->len * 2 + 16 > s->scratch_cap) { /* bounded: max_line_bytes is validated */
        size_t cap = s->len * 2 + 16;
        acct_free(s->acct, s->scratch, s->scratch_cap);
        s->scratch_cap = 0;
        s->scratch = alloc(s, cap, false);
        if (!s->scratch)
            return false;
        s->scratch_cap = cap;
    }
    size_t bad = utf8_invalid(s->line, s->len);
    if (bad)
        return fail(s, XLF_E_UTF8, "invalid UTF-8 at record byte %zu", bad - 1);
    uint32_t root;
    TRY(jvalue(s, &root, 0));
    ws(s);
    if (s->pos != s->len)
        return fail(s, XLF_E_JSON, "trailing data after record");
    if (N(s, root)->type != J_OBJ)
        return fail(s, XLF_E_SCHEMA, "record must be an object");
    struct xlf_str type;
    TRY(text(s, root, "type", &type, false, true));
    if (s->doc->ended)
        return fail(s, XLF_E_ORDER, "record after end");
    if (!s->header_seen) {
        if (strcmp(type.ptr, "header"))
            return fail(s, XLF_E_ORDER, "first record must be the header");
        s->header_seen = true;
        return header(s, root);
    }
    static const struct {
        const char *name;
        bool (*fn)(struct st *, uint32_t);
    } handlers[] = {{"code", code},   {"function", function}, {"thread", thread}, {"acquisition", acquisition},
                    {"stack", stack}, {"loss", loss},         {"end", end}};
    for (size_t i = 0; i < sizeof handlers / sizeof *handlers; ++i)
        if (!strcmp(type.ptr, handlers[i].name))
            return handlers[i].fn(s, root);
    if (!strcmp(type.ptr, "header"))
        return fail(s, XLF_E_ORDER, "duplicate header");
    return fail(s, XLF_E_SCHEMA, "unknown record type \"%.64s\"", type.ptr);
}

/* Transient parse storage: released before decode returns, on every path. */
static void release(struct st *s)
{
    struct acct *a = s->acct;
    acct_free(a, s->nodes, s->node_cap * sizeof *s->nodes);
    acct_free(a, s->scratch, s->scratch_cap);
    struct idmap *maps[] = {&s->code_ids, &s->function_ids, &s->thread_ids, &s->stack_ids, &s->tids, &s->code_paths};
    for (size_t i = 0; i < sizeof maps / sizeof *maps; ++i)
        acct_free(a, maps[i]->slots, maps[i]->cap * sizeof *maps[i]->slots);
}

/* Free a document's retained storage. a is the decode accountant while
 * decoding, NULL afterwards (the document's budget ended with its decode). */
static void destroy(struct box *b, struct acct *a)
{
    struct xlf_doc *d = &b->doc;
    struct priv *p = &b->priv;
    for (struct chunk *c = p->chunks, *n; c; c = n) {
        n = c->next;
        acct_free(a, c, sizeof *c + c->cap);
    }
    acct_free(a, d->codes, p->code_cap * sizeof *d->codes);
    acct_free(a, d->functions, p->function_cap * sizeof *d->functions);
    acct_free(a, d->threads, p->thread_cap * sizeof *d->threads);
    acct_free(a, d->frames, p->frame_cap * sizeof *d->frames);
    acct_free(a, d->acquisitions, p->acquisition_cap * sizeof *d->acquisitions);
    acct_free(a, d->stacks, p->stack_cap * sizeof *d->stacks);
    acct_free(a, d->losses, p->loss_cap * sizeof *d->losses);
    acct_free(a, b, sizeof *b);
}

void xlf_free(struct xlf_doc *d)
{
    if (d)
        destroy((struct box *)(void *)d, NULL);
}

static void set_error(struct xlf_error *err, enum xlf_status status, size_t peak, const char *fmt, ...)
{
    *err = (struct xlf_error){.status = status, .peak_bytes = peak};
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err->message, sizeof err->message, fmt, ap);
    va_end(ap);
}

enum { POLL_BYTES = 1u << 20 };

/* Decode with an existing accountant (which may already hold the input copy). */
static struct xlf_doc *decode(struct acct *a, const void *bytes, size_t size, const struct xlf_limits *limits,
                              const struct xlf_cancel *cancel, struct xlf_error *err)
{
    struct st s = {.lim = limits, .err = err, .acct = a, .cancel = cancel};
    if (size > limits->max_input_bytes) {
        fail(&s, XLF_E_LIMIT, "input of %zu bytes exceeds %zu", size, limits->max_input_bytes);
        return NULL;
    }
    struct box *b = alloc(&s, sizeof *b, true);
    if (!b)
        return NULL;
    struct xlf_doc *d = &b->doc;
    s.doc = d;
    s.priv = &b->priv;
    d->private_state = &b->priv;
    d->header.pid = -1;
    d->input_bytes = size;
    const uint8_t *p = bytes;
    bool ok = true;
    struct sha sha;
    sha_init(&sha);
    for (size_t at = 0; ok && at < size; at += POLL_BYTES) {
        if (poll_cancel(cancel))
            ok = fail(&s, XLF_E_CANCELLED, "cancelled while hashing input");
        else
            sha_update(&sha, p + at, size - at < POLL_BYTES ? size - at : POLL_BYTES);
    }
    sha_final(&sha, d->sha256);
    for (int i = 0; i < 32; ++i)
        snprintf(d->sha256_hex + 2 * i, 3, "%02x", d->sha256[i]);
    size_t at = 0;
    while (ok && at < size) {
        const uint8_t *nl = memchr(p + at, '\n', size - at);
        s.line_no++;
        s.offset = at;
        if (!nl) {
            /* A final line without newline is an interrupted write: cite and ignore it. */
            d->warnings |= XLF_W_TRUNCATED_TAIL;
            d->truncated_tail = (struct xlf_cite){s.line_no, at, size - at};
            s.line_no--;
            break;
        }
        if (s.line_no > limits->max_records) {
            ok = fail(&s, XLF_E_LIMIT, "more than %zu records", limits->max_records);
            break;
        }
        if (poll_cancel(cancel)) {
            ok = fail(&s, XLF_E_CANCELLED, "cancelled before record %llu", (unsigned long long)s.line_no);
            break;
        }
        s.line = p + at;
        s.len = (size_t)(nl - (p + at));
        s.pos = 0;
        at += s.len + 1;
        ok = record(&s);
    }
    d->records = s.line_no;
    if (ok && !s.header_seen)
        ok = fail(&s, XLF_E_EMPTY, "no header record");
    if (ok && !d->ended) {
        d->warnings |= XLF_W_NO_END;
        for (size_t i = 0; i < d->acquisition_count; ++i)
            if (d->acquisitions[i].seen_stacks != d->acquisitions[i].declared_stacks)
                d->warnings |= XLF_W_ACQ_INCOMPLETE;
    }
    release(&s);
    if (!ok) {
        destroy(b, a);
        return NULL;
    }
    return d;
}

static void finish(struct xlf_doc *d, struct acct *a, struct xlf_error *err, size_t external)
{
    if (d) {
        d->retained_bytes = a->live - external;
        d->decode_peak_bytes = a->peak;
    } else
        err->peak_bytes = a->peak;
}

struct xlf_doc *xlf_decode(const void *bytes, size_t size, const struct xlf_limits *limits,
                           const struct xlf_cancel *cancel, struct xlf_error *err)
{
    struct xlf_limits defaults;
    if (!limits) {
        xlf_default_limits(&defaults);
        limits = &defaults;
    }
    *err = (struct xlf_error){0};
    const char *bad = limits_invalid(limits);
    if (bad) {
        set_error(err, XLF_E_LIMIT, 0, "invalid limits: %s", bad);
        return NULL;
    }
    if (!bytes && size) {
        set_error(err, XLF_E_ARGUMENT, 0, "NULL input with nonzero size");
        return NULL;
    }
    struct acct a = {.limit = limits->max_memory};
    struct xlf_doc *d = decode(&a, bytes, size, limits, cancel, err);
    finish(d, &a, err, 0);
    return d;
}

/* ---- stable file input (C05-R4) -------------------------------------------
 * A read lease (F_SETLEASE, F_RDLCK) is granted only while no process has the
 * file open for writing (EAGAIN otherwise). While it is held, every open for
 * writing and every truncate waits in the kernel until the holder releases it
 * or lease-break-time expires (which removes the lease). If F_GETLEASE still
 * reports F_RDLCK after the last byte was read, no write can have happened
 * during the read. Comparing size, inode and times is kept as a second check
 * but proves nothing on its own (XFS same-size rewrites pass it).
 *
 * The kernel announces a lease break with a signal to the file's owner (SIGIO
 * by default, which terminates a process that does not handle it). The owner is
 * preset, before the lease is taken, to a helper thread that blocks every
 * signal; a thread-directed signal blocked by its target is never delivered to
 * another thread and is discarded when the helper exits after the lease has
 * been released, so the host process is never signalled. */
#ifdef XLF_TESTING
static bool test_no_lease;
void xlf_test_disable_lease(bool off);
void xlf_test_disable_lease(bool off)
{
    test_no_lease = off;
}
#endif
struct lease_helper {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    pid_t tid;
    int done;
    pthread_t thread;
};
static void *lease_helper_main(void *arg)
{
    struct lease_helper *h = arg;
    pthread_mutex_lock(&h->mu);
    h->tid = gettid();
    pthread_cond_broadcast(&h->cv);
    while (!h->done)
        pthread_cond_wait(&h->cv, &h->mu);
    pthread_mutex_unlock(&h->mu);
    return NULL;
}
static int lease_helper_start(struct lease_helper *h)
{
    pthread_mutex_init(&h->mu, NULL);
    pthread_cond_init(&h->cv, NULL);
    h->tid = 0;
    h->done = 0;
    sigset_t all, old;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, &old); /* inherited by the helper */
    int rc = pthread_create(&h->thread, NULL, lease_helper_main, h);
    pthread_sigmask(SIG_SETMASK, &old, NULL);
    if (rc) {
        pthread_cond_destroy(&h->cv);
        pthread_mutex_destroy(&h->mu);
        return -1;
    }
    pthread_mutex_lock(&h->mu);
    while (!h->tid)
        pthread_cond_wait(&h->cv, &h->mu);
    pthread_mutex_unlock(&h->mu);
    return 0;
}
static void lease_helper_stop(struct lease_helper *h)
{
    pthread_mutex_lock(&h->mu);
    h->done = 1;
    pthread_cond_broadcast(&h->cv);
    pthread_mutex_unlock(&h->mu);
    pthread_join(h->thread, NULL);
    pthread_cond_destroy(&h->cv);
    pthread_mutex_destroy(&h->mu);
}

const char *xlf_stability_name(enum xlf_stability s)
{
    switch (s) {
    case XLF_STABILITY_CALLER: return "caller_bytes";
    case XLF_STABILITY_LEASED: return "leased";
    case XLF_STABILITY_UNVERIFIED: return "unverified";
    }
    return "invalid";
}

enum xlf_status xlf_read_stable(const char *path, xlf_read_sink sink, void *ctx, enum xlf_stability *stability,
                                struct xlf_error *err)
{
    *stability = XLF_STABILITY_UNVERIFIED;
    /* C05-R3: O_PATH pins the inode
     * without FIFO/device open semantics, so no open(2) can block where
     * cancellation cannot reach it and no blocked FIFO writer is released. Only
     * a regular file is then reopened for reading, through the pinned inode. */
    int pinned = open(path, O_PATH | O_CLOEXEC);
    if (pinned < 0) {
        set_error(err, XLF_E_IO, 0, "%s: %s", path, strerror(errno));
        return XLF_E_IO;
    }
    struct stat st, pst;
    if (fstat(pinned, &pst) || !S_ISREG(pst.st_mode)) {
        set_error(err, XLF_E_IO, 0, "%s: not a regular file", path);
        close(pinned);
        return XLF_E_IO;
    }
    char reopen[64];
    snprintf(reopen, sizeof reopen, "/proc/self/fd/%d", pinned);
    int fd = open(reopen, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOCTTY);
    close(pinned);
    if (fd < 0) {
        set_error(err, XLF_E_IO, 0, "%s: reopen of the pinned file failed: %s", path, strerror(errno));
        return XLF_E_IO;
    }
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_dev != pst.st_dev || st.st_ino != pst.st_ino) {
        set_error(err, XLF_E_IO, 0, "%s: reopened object is not the pinned regular file", path);
        close(fd);
        return XLF_E_IO;
    }
    struct lease_helper h;
    bool helper = false, leased = false;
    enum xlf_status status = XLF_OK;
#ifdef XLF_TESTING
    if (!test_no_lease)
#endif
        helper = lease_helper_start(&h) == 0;
    if (helper) {
        struct f_owner_ex owner = {.type = F_OWNER_TID, .pid = h.tid};
        /* Without the preset owner the lease would signal this process. */
        if (!fcntl(fd, F_SETOWN_EX, &owner)) {
            if (!fcntl(fd, F_SETLEASE, F_RDLCK))
                leased = true;
            else if (errno == EAGAIN) {
                set_error(err, XLF_E_IO, 0,
                          "%s: open for writing by a process; refused, since it could be changed while it is read",
                          path);
                status = XLF_E_IO;
            }
        }
    }
    if (!status) {
        *stability = leased ? XLF_STABILITY_LEASED : XLF_STABILITY_UNVERIFIED;
        status = sink(ctx, fd, (uint64_t)st.st_size, err);
    }
    /* C05-R4: a pseudo-file (/proc, /sys: st_size 0 or smaller than
     * its content) or a file that grew is not read as a truncated copy. */
    char extra;
    if (!status && pread(fd, &extra, 1, (off_t)st.st_size) > 0) {
        set_error(err, XLF_E_IO, err->peak_bytes,
                  "%s: has more bytes than its size %ju (pseudo-file or growing file); copy it to a regular file first",
                  path, (uintmax_t)st.st_size);
        status = XLF_E_IO;
    }
    if (!status && leased && fcntl(fd, F_GETLEASE) != F_RDLCK) {
        set_error(err, XLF_E_IO, err->peak_bytes,
                  "%s: a writer opened the file while it was read (lease broken); it may have changed", path);
        status = XLF_E_IO;
    }
    struct stat after;
    if (!status && (fstat(fd, &after) || after.st_size != st.st_size || after.st_ino != st.st_ino ||
                    after.st_mtim.tv_sec != st.st_mtim.tv_sec || after.st_mtim.tv_nsec != st.st_mtim.tv_nsec ||
                    after.st_ctim.tv_sec != st.st_ctim.tv_sec || after.st_ctim.tv_nsec != st.st_ctim.tv_nsec)) {
        set_error(err, XLF_E_IO, err->peak_bytes, "%s: file changed while it was read", path);
        status = XLF_E_IO;
    }
    if (leased)
        fcntl(fd, F_SETLEASE, F_UNLCK);
    close(fd);
    if (helper)
        lease_helper_stop(&h); /* any blocked lease-break signal dies with it */
    return status;
}

struct file_sink {
    struct acct *a;
    const struct xlf_limits *limits;
    const struct xlf_cancel *cancel;
    const char *path;
    uint8_t *buf;
    size_t size;
};
static enum xlf_status read_into_acct(void *ctx, int fd, uint64_t file_size, struct xlf_error *err)
{
    struct file_sink *s = ctx;
    /* Refuse before reading: the input limit bounds the read itself. */
    if (file_size > s->limits->max_input_bytes) {
        set_error(err, XLF_E_LIMIT, 0, "input of %ju bytes exceeds %zu", (uintmax_t)file_size,
                  s->limits->max_input_bytes);
        return XLF_E_LIMIT;
    }
    size_t size = (size_t)file_size;
    enum acct_fail why;
    s->buf = acct_alloc(s->a, size, false, &why);
    if (!s->buf) {
        set_error(err, XLF_E_MEMORY, s->a->peak,
                  why == ACCT_BUDGET ? "decode memory budget %zu exhausted by the input copy"
                                     : "out of memory for the input copy (%zu)",
                  why == ACCT_BUDGET ? s->limits->max_memory : size);
        return XLF_E_MEMORY;
    }
    s->size = size;
    size_t got = 0;
    while (got < size) {
        if (poll_cancel(s->cancel)) {
            set_error(err, XLF_E_CANCELLED, s->a->peak, "cancelled while reading input");
            return XLF_E_CANCELLED;
        }
        size_t want = size - got < POLL_BYTES ? size - got : POLL_BYTES;
        ssize_t n = read(fd, s->buf + got, want);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            set_error(err, XLF_E_IO, s->a->peak, "%s: %s", s->path, n ? strerror(errno) : "file shrank while reading");
            return XLF_E_IO;
        }
        got += (size_t)n;
    }
    return XLF_OK;
}

struct xlf_doc *xlf_decode_file(const char *path, const struct xlf_limits *limits, const struct xlf_cancel *cancel,
                                struct xlf_error *err)
{
    struct xlf_limits defaults;
    if (!limits) {
        xlf_default_limits(&defaults);
        limits = &defaults;
    }
    *err = (struct xlf_error){0};
    const char *bad = limits_invalid(limits);
    if (bad) {
        set_error(err, XLF_E_LIMIT, 0, "invalid limits: %s", bad);
        return NULL;
    }
    if (poll_cancel(cancel)) {
        set_error(err, XLF_E_CANCELLED, 0, "cancelled before opening input");
        return NULL;
    }
    struct acct a = {.limit = limits->max_memory};
    struct file_sink s = {.a = &a, .limits = limits, .cancel = cancel, .path = path};
    enum xlf_stability stability;
    enum xlf_status status = xlf_read_stable(path, read_into_acct, &s, &stability, err);
    struct xlf_doc *d = NULL;
    if (status == XLF_OK)
        d = decode(&a, s.buf, s.size, limits, cancel, err);
    if (s.buf)
        acct_free(&a, s.buf, s.size);
    if (d) {
        d->input_charged = true;
        d->input_stability = stability;
        finish(d, &a, err, 0);
    } else
        err->peak_bytes = a.peak;
    return d;
}

/* ---- reference queries --------------------------------------------------- */
uint32_t xlf_find_thread(const struct xlf_doc *d, const char *key)
{
    uint32_t found = XLF_NONE;
    for (size_t i = 0; i < d->thread_count; ++i)
        if (!strcmp(d->threads[i].id.ptr, key))
            return (uint32_t)i;
    for (size_t i = 0; i < d->thread_count; ++i)
        if (d->threads[i].name.ptr && !strcmp(d->threads[i].name.ptr, key)) {
            if (found != XLF_NONE)
                return XLF_NONE - 1; /* ambiguous name */
            found = (uint32_t)i;
        }
    return found;
}

static enum xlf_status query_fail(struct xlf_error *err, struct acct *a, enum xlf_status status, const char *what)
{
    set_error(err, status, a->peak, "%s", what);
    return status;
}

enum xlf_status xlf_aggregate(const struct xlf_doc *d, uint32_t thread, const struct xlf_query_limits *limits,
                              const struct xlf_cancel *cancel, struct xlf_aggregate *out, struct xlf_error *err)
{
    struct xlf_query_limits defaults;
    if (!limits) {
        xlf_default_query_limits(&defaults);
        limits = &defaults;
    }
    *out = (struct xlf_aggregate){0};
    *err = (struct xlf_error){0};
    struct acct a = {.limit = limits->max_query_bytes, .base = d->retained_bytes,
                     .combined_limit = limits->max_combined_bytes};
    if (!limits->max_query_bytes || !limits->max_combined_bytes)
        return query_fail(err, &a, XLF_E_LIMIT, "invalid query limits: zero limit");
    if (thread != XLF_NONE && thread >= d->thread_count)
        return query_fail(err, &a, XLF_E_ARGUMENT, "thread index out of range");
    /* Admission (C05-R3): the retained document alone must fit the combined
     * budget. Charges below re-check it, but a document with no functions makes
     * no charge, so the check cannot be left to them. */
    if (d->retained_bytes > limits->max_combined_bytes)
        return query_fail(err, &a, XLF_E_MEMORY, "combined budget below the retained document");
    size_t n = d->function_count;
    struct xlf_count *counts = NULL;
    uint32_t *seen = NULL;
    enum acct_fail why = ACCT_OK;
    /* Result storage (self, inclusive) then scratch (stack stamp per function).
     * n < 2^32, so the sizes below cannot overflow size_t on LP64; checked anyway. */
    if (n > SIZE_MAX / (2 * sizeof *counts))
        return query_fail(err, &a, XLF_E_MEMORY, "aggregate size overflow");
    if (n) {
        counts = acct_alloc(&a, 2 * n * sizeof *counts, true, &why);
        if (counts)
            seen = acct_alloc(&a, n * sizeof *seen, true, &why);
        if (!seen) {
            acct_free(&a, counts, 2 * n * sizeof *counts);
            return query_fail(err, &a, XLF_E_MEMORY,
                              why == ACCT_BUDGET ? "query memory budget exhausted" : "out of memory");
        }
    }
    struct xlf_aggregate r = {.self = counts, .inclusive = counts ? counts + n : NULL, .function_count = n};
    enum xlf_status status = XLF_OK;
    const char *message = NULL;
    for (size_t i = 0; i < d->stack_count && status == XLF_OK; ++i) {
        if (poll_cancel(cancel)) {
            status = XLF_E_CANCELLED, message = "cancelled during aggregation";
            break;
        }
        const struct xlf_stack *k = &d->stacks[i];
        if (thread != XLF_NONE && k->thread != thread)
            continue;
        uint64_t w = k->weight;
        bool ok = xlf_count_add(&r.total_weight, w);
        r.stacks++;
        if (k->state != XLF_STACK_COMPLETE) {
            ok &= xlf_count_add(&r.partial_weight, w);
            r.partial_stacks++;
        }
        bool marker = false;
        uint32_t stamp = (uint32_t)i + 1; /* i < XLF_MAX_INDEX */
        for (uint32_t j = 0; j < k->frame_count; ++j) {
            const struct xlf_frame *f = &d->frames[k->first_frame + j];
            if (f->function == XLF_NONE) {
                marker = true;
                continue;
            }
            if (j == 0)
                ok &= xlf_count_add(&r.self[f->function], w);
            if (seen[f->function] != stamp) { /* recursion counts once per stack */
                seen[f->function] = stamp;
                ok &= xlf_count_add(&r.inclusive[f->function], w);
            }
        }
        if (marker)
            ok &= xlf_count_add(&r.marker_weight, w);
        if (!k->frame_count || d->frames[k->first_frame].function == XLF_NONE)
            ok &= xlf_count_add(&r.unknown_leaf_weight, w);
        if (!ok) /* unreachable: fewer than 2^32 terms below 2^64 each */
            status = XLF_E_OVERFLOW, message = "aggregate counter exceeds 128 bits";
    }
    acct_free(&a, seen, n * sizeof *seen);
    if (status != XLF_OK) {
        acct_free(&a, counts, 2 * n * sizeof *counts);
        return query_fail(err, &a, status, message);
    }
    r.input_incomplete = (d->warnings & XLF_W_INCOMPLETE) != 0;
    r.result_bytes = a.live;
    r.query_peak_bytes = a.peak;
    r.combined_peak_bytes = d->retained_bytes + a.peak;
    *out = r;
    return XLF_OK;
}

void xlf_aggregate_free(struct xlf_aggregate *r)
{
    if (r->self)
        acct_free(NULL, r->self, 2 * r->function_count * sizeof *r->self);
    *r = (struct xlf_aggregate){0};
}
