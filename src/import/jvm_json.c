#include "jvm_json.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
struct jj_block {
    struct jj_block *next;
    size_t used, size;
    _Alignas(16) char data[];
};
/* C05-R4: blocks start at 4 KiB and double up to 1 MiB, so a small document
 * charges the whole-operation budget for what it needs, not for a fixed 1 MiB
 * block (which hid the adapt/decode budget windows of small JSON sources). */
enum { JJ_FIRST_BLOCK = 4 << 10, JJ_BLOCK = 1 << 20 };
static void *alloc(struct jj_parser *j, size_t size)
{
    struct jj_arena *a = j->arena;
    size = (size + 15) & ~(size_t)15;
    struct jj_block *b = a->head;
    if (!b || b->size - b->used < size) {
        size_t next = b ? (b->size < JJ_BLOCK / 2 ? b->size * 2 : JJ_BLOCK) : JJ_FIRST_BLOCK;
        size_t want = size > next ? size : next;
        if (a->used + want > a->limit) {
            jj_fail(j, "memory budget exhausted");
            return NULL;
        }
        b = jvm_balloc(a->budget, sizeof(*b) + want);
        if (!b) {
            jj_fail(j, a->budget && a->budget->exhausted ? "whole-operation budget exhausted" : "out of memory");
            return NULL;
        }
        b->next = a->head;
        b->used = 0;
        b->size = want;
        a->head = b;
        a->used += want;
    }
    void *out = b->data + b->used;
    b->used += size;
    return out;
}
void jj_arena_reset(struct jj_arena *a)
{
    /* Keep the newest (largest) block for the next record, free the rest. */
    struct jj_block *keep = a->head, *b = keep ? keep->next : NULL;
    while (b) {
        struct jj_block *next = b->next;
        a->used -= b->size;
        jvm_bfree(a->budget, b);
        b = next;
    }
    if (keep) {
        keep->next = NULL;
        keep->used = 0;
    }
}
void jj_arena_free(struct jj_arena *a)
{
    jj_arena_reset(a);
    jvm_bfree(a->budget, a->head);
    a->head = NULL;
    a->used = 0;
}
void jj_init(struct jj_parser *j, const char *text, size_t length, struct jj_arena *a,
             uint32_t max_depth, size_t max_string)
{
    memset(j, 0, sizeof(*j));
    j->start = j->p = text;
    j->end = text + length;
    j->arena = a;
    j->max_depth = max_depth;
    j->max_string = max_string;
}
int jj_fail(struct jj_parser *j, const char *why)
{
    if (!j->error) {
        j->error = why;
        j->error_offset = (size_t)(j->p - j->start);
    }
    return -1;
}
int jj_skip_space(struct jj_parser *j)
{
    while (j->p < j->end && (*j->p == ' ' || *j->p == '\t' || *j->p == '\n' || *j->p == '\r'))
        j->p++;
    return j->p < j->end ? (unsigned char)*j->p : -1;
}
int jj_expect(struct jj_parser *j, char c)
{
    if (jj_skip_space(j) != (unsigned char)c)
        return jj_fail(j, "unexpected token");
    j->p++;
    return 0;
}
/* Length of one valid UTF-8 sequence at s, or 0. Rejects overlongs and surrogates. */
size_t jj_utf8_one(const unsigned char *s, size_t n)
{
    if (s[0] < 0x80)
        return 1;
    if (s[0] >= 0xc2 && s[0] <= 0xdf)
        return n >= 2 && (s[1] & 0xc0) == 0x80 ? 2 : 0;
    if (s[0] >= 0xe0 && s[0] <= 0xef) {
        if (n < 3 || (s[1] & 0xc0) != 0x80 || (s[2] & 0xc0) != 0x80)
            return 0;
        if ((s[0] == 0xe0 && s[1] < 0xa0) || (s[0] == 0xed && s[1] >= 0xa0))
            return 0;
        return 3;
    }
    if (s[0] >= 0xf0 && s[0] <= 0xf4) {
        if (n < 4 || (s[1] & 0xc0) != 0x80 || (s[2] & 0xc0) != 0x80 || (s[3] & 0xc0) != 0x80)
            return 0;
        if ((s[0] == 0xf0 && s[1] < 0x90) || (s[0] == 0xf4 && s[1] >= 0x90))
            return 0;
        return 4;
    }
    return 0;
}
int jj_utf8_valid(const char *text, size_t length)
{
    const unsigned char *s = (const unsigned char *)text;
    for (size_t i = 0; i < length;) {
        size_t k = jj_utf8_one(s + i, length - i);
        if (!k)
            return 0;
        i += k;
    }
    return 1;
}
static int hex4(struct jj_parser *j, unsigned *out)
{
    if (j->end - j->p < 4)
        return jj_fail(j, "truncated escape");
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        char c = j->p[i];
        v <<= 4;
        if (c >= '0' && c <= '9')
            v |= (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f')
            v |= (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F')
            v |= (unsigned)(c - 'A' + 10);
        else
            return jj_fail(j, "invalid escape");
    }
    j->p += 4;
    *out = v;
    return 0;
}
static size_t put_utf8(char *o, unsigned c)
{
    if (c < 0x80) {
        o[0] = (char)c;
        return 1;
    }
    if (c < 0x800) {
        o[0] = (char)(0xc0 | c >> 6);
        o[1] = (char)(0x80 | (c & 0x3f));
        return 2;
    }
    if (c < 0x10000) {
        o[0] = (char)(0xe0 | c >> 12);
        o[1] = (char)(0x80 | ((c >> 6) & 0x3f));
        o[2] = (char)(0x80 | (c & 0x3f));
        return 3;
    }
    o[0] = (char)(0xf0 | c >> 18);
    o[1] = (char)(0x80 | ((c >> 12) & 0x3f));
    o[2] = (char)(0x80 | ((c >> 6) & 0x3f));
    o[3] = (char)(0x80 | (c & 0x3f));
    return 4;
}
int jj_string(struct jj_parser *j, const char **out, size_t *length)
{
    if (jj_expect(j, '"'))
        return -1;
    const char *s = j->p;
    while (s < j->end && *s != '"') /* decoded output is never longer than input */
        s += *s == '\\' && s + 1 < j->end ? 2 : 1;
    if (s >= j->end)
        return jj_fail(j, "unterminated string");
    if ((size_t)(s - j->p) > j->max_string)
        return jj_fail(j, "string budget exhausted");
    char *o = alloc(j, (size_t)(s - j->p) + 1);
    if (!o)
        return -1;
    size_t n = 0;
    while (j->p < s) {
        unsigned char c = (unsigned char)*j->p;
        if (c < 0x20)
            return jj_fail(j, "control character in string");
        if (c != '\\') {
            size_t k = jj_utf8_one((const unsigned char *)j->p, (size_t)(s - j->p));
            if (!k)
                return jj_fail(j, "invalid UTF-8");
            memcpy(o + n, j->p, k);
            n += k;
            j->p += k;
            continue;
        }
        j->p++;
        char e = *j->p++;
        unsigned cp;
        switch (e) {
        case '"': o[n++] = '"'; break;
        case '\\': o[n++] = '\\'; break;
        case '/': o[n++] = '/'; break;
        case 'b': o[n++] = '\b'; break;
        case 'f': o[n++] = '\f'; break;
        case 'n': o[n++] = '\n'; break;
        case 'r': o[n++] = '\r'; break;
        case 't': o[n++] = '\t'; break;
        case 'u':
            if (hex4(j, &cp))
                return -1;
            if (cp >= 0xd800 && cp <= 0xdbff && s - j->p >= 6 && j->p[0] == '\\' &&
                j->p[1] == 'u') {
                const char *save = j->p;
                unsigned low;
                j->p += 2;
                if (hex4(j, &low))
                    return -1;
                if (low >= 0xdc00 && low <= 0xdfff)
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                else
                    j->p = save;
            }
            if (cp >= 0xd800 && cp <= 0xdfff) {
                cp = 0xfffd;
                j->lossy++;
            }
            n += put_utf8(o + n, cp); /* a \u escape is 6 bytes; at most 4 written */
            break;
        default:
            return jj_fail(j, "invalid escape");
        }
    }
    j->p = s + 1;
    o[n] = 0;
    *out = o;
    *length = n;
    return 0;
}
static int number(struct jj_parser *j, struct jj_value *v)
{
    const char *s = j->p;
    if (s < j->end && *s == '-')
        s++;
    if (s >= j->end || *s < '0' || *s > '9')
        return jj_fail(j, "invalid number");
    if (*s == '0')
        s++;
    else
        while (s < j->end && *s >= '0' && *s <= '9')
            s++;
    if (s < j->end && *s == '.') {
        s++;
        if (s >= j->end || *s < '0' || *s > '9')
            return jj_fail(j, "invalid number");
        while (s < j->end && *s >= '0' && *s <= '9')
            s++;
    }
    if (s < j->end && (*s == 'e' || *s == 'E')) {
        s++;
        if (s < j->end && (*s == '+' || *s == '-'))
            s++;
        if (s >= j->end || *s < '0' || *s > '9')
            return jj_fail(j, "invalid number");
        while (s < j->end && *s >= '0' && *s <= '9')
            s++;
    }
    size_t n = (size_t)(s - j->p);
    if (n > 512)
        return jj_fail(j, "number too long");
    char *o = alloc(j, n + 1);
    if (!o)
        return -1;
    memcpy(o, j->p, n);
    o[n] = 0;
    v->type = JJ_NUMBER;
    v->text = o;
    v->length = n;
    j->p = s;
    return 0;
}
static int word(struct jj_parser *j, const char *w, enum jj_type t, struct jj_value *v)
{
    size_t n = strlen(w);
    if ((size_t)(j->end - j->p) < n || memcmp(j->p, w, n))
        return jj_fail(j, "invalid literal");
    j->p += n;
    v->type = t;
    return 0;
}
struct grow {
    struct jj_value *items;
    const char **keys;
    uint32_t count, cap;
};
static int push(struct jj_parser *j, struct grow *g, const char *key, const struct jj_value *v)
{
    if (g->count == g->cap) {
        if (g->cap >= (1u << 26))
            return jj_fail(j, "container too large");
        uint32_t cap = g->cap ? g->cap * 2 : 8;
        struct jvm_budget *b = j->arena->budget;
        struct jj_value *items = jvm_brealloc(b, g->items, cap * sizeof(*items));
        if (!items)
            return jj_fail(j, b && b->exhausted ? "whole-operation budget exhausted" : "out of memory");
        g->items = items;
        const char **keys = jvm_brealloc(b, g->keys, cap * sizeof(*keys));
        if (!keys)
            return jj_fail(j, b && b->exhausted ? "whole-operation budget exhausted" : "out of memory");
        g->keys = keys;
        g->cap = cap;
    }
    g->items[g->count] = *v;
    g->keys[g->count++] = key;
    return 0;
}
static int finish(struct jj_parser *j, struct grow *g, struct jj_value *v, int object)
{
    int rc = 0;
    if (object && g->count > 4096)
        rc = jj_fail(j, "object has too many members");
    for (uint32_t a = 0; object && !rc && a < g->count; a++) /* duplicate keys are ambiguous */
        for (uint32_t b = a + 1; b < g->count; b++)
            if (!strcmp(g->keys[a], g->keys[b])) {
                rc = jj_fail(j, "duplicate object key");
                break;
            }
    if (rc) {
        jvm_bfree(j->arena->budget, g->items);
        jvm_bfree(j->arena->budget, g->keys);
        return rc;
    }
    v->count = g->count;
    v->items = NULL;
    v->keys = NULL;
    if (g->count) {
        v->items = alloc(j, g->count * sizeof(*v->items));
        if (v->items)
            memcpy(v->items, g->items, g->count * sizeof(*v->items));
        if (v->items && object) {
            v->keys = alloc(j, g->count * sizeof(*v->keys));
            if (v->keys)
                memcpy(v->keys, g->keys, g->count * sizeof(*v->keys));
        }
        if (!v->items || (object && !v->keys))
            rc = -1;
    }
    jvm_bfree(j->arena->budget, g->items);
    jvm_bfree(j->arena->budget, g->keys);
    return rc;
}
static int value_inner(struct jj_parser *j, struct jj_value *v, int c);
int jj_value(struct jj_parser *j, struct jj_value *v)
{
    memset(v, 0, sizeof(*v));
    int c = jj_skip_space(j);
    size_t start = (size_t)(j->p - j->start);
    int rc = value_inner(j, v, c);
    v->start = start;
    v->end = (size_t)(j->p - j->start);
    return rc;
}
static int value_inner(struct jj_parser *j, struct jj_value *v, int c)
{
    if (c < 0)
        return jj_fail(j, "unexpected end of input");
    if (c == '"') {
        v->type = JJ_STRING;
        return jj_string(j, &v->text, &v->length);
    }
    if (c == '-' || (c >= '0' && c <= '9'))
        return number(j, v);
    if (c == 't')
        return word(j, "true", JJ_TRUE, v);
    if (c == 'f')
        return word(j, "false", JJ_FALSE, v);
    if (c == 'n')
        return word(j, "null", JJ_NULL, v);
    if (c != '[' && c != '{')
        return jj_fail(j, "unexpected character");
    if (++j->depth > j->max_depth)
        return jj_fail(j, "nesting budget exhausted");
    int object = c == '{';
    char close = object ? '}' : ']';
    struct grow g = {0};
    j->p++;
    v->type = object ? JJ_OBJECT : JJ_ARRAY;
    if (jj_skip_space(j) == close)
        j->p++;
    else
        for (;;) {
            const char *key = NULL;
            size_t key_length;
            struct jj_value item;
            if (object && (jj_string(j, &key, &key_length) || jj_expect(j, ':')))
                goto bad;
            if (jj_value(j, &item) || push(j, &g, key, &item))
                goto bad;
            c = jj_skip_space(j);
            if (c == ',') {
                j->p++;
                continue;
            }
            if (c == close) {
                j->p++;
                break;
            }
            jj_fail(j, "expected separator");
            goto bad;
        }
    j->depth--;
    return finish(j, &g, v, object);
bad:
    jvm_bfree(j->arena->budget, g.items);
    jvm_bfree(j->arena->budget, g.keys);
    return -1;
}
const struct jj_value *jj_get(const struct jj_value *o, const char *key)
{
    if (!o || o->type != JJ_OBJECT)
        return NULL;
    for (uint32_t i = 0; i < o->count; i++)
        if (!strcmp(o->keys[i], key))
            return &o->items[i];
    return NULL;
}
const char *jj_str(const struct jj_value *o, const char *key)
{
    const struct jj_value *v = jj_get(o, key);
    return v && v->type == JJ_STRING ? v->text : NULL;
}
int jj_i64(const struct jj_value *v, int64_t *out)
{
    const char *s;
    if (!v)
        return -1;
    if (v->type == JJ_NUMBER || v->type == JJ_STRING)
        s = v->text;
    else
        return -1;
    if (!*s || strpbrk(s, ".eE"))
        return -1;
    char *end;
    errno = 0;
    long long n = strtoll(s, &end, 10);
    if (errno || *end || end == s || (s[0] == '+') || (s[0] == '-' && s[1] == '0' && s[2]) ||
        (s[0] == '0' && s[1]) || (s[0] == ' '))
        return -1;
    *out = n;
    return 0;
}
