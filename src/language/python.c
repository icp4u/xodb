#include "python.h"
#include "../text.h"
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* CPython 3.14/3.16 object.h, longintrepr.h, unicodeobject.h, pycore_dict.h
 * and pycore_stackref.h rules for GIL builds on LP64. Offsets come from the
 * verified layout; this file only encodes the documented macro meanings. */
enum {
    TPFLAGS_LONG = 1u << 24,
    TPFLAGS_LIST = 1u << 25,
    TPFLAGS_TUPLE = 1u << 26,
    TPFLAGS_BYTES = 1u << 27,
    TPFLAGS_UNICODE = 1u << 28,
    TPFLAGS_DICT = 1u << 29,
    TPFLAGS_TYPE = 1u << 31,
};
enum { STACKREF_TAG_BITS = 3, LONG_SHIFT = 30, DICT_GENERAL = 0, DICT_UNICODE = 1, DICT_SPLIT = 2 };
#define READ_LIMIT 16384
#define BYTE_LIMIT (2u * 1024 * 1024)

static int read_bytes(struct xpy_reader *r, uint64_t address, void *out, size_t n) {
    if (r->error)
        return 0;
    if (!address || address > UINT64_MAX - n) {
        r->error = "InvalidAddress";
        return 0;
    }
    if (r->reads >= READ_LIMIT || n > BYTE_LIMIT - r->bytes) {
        r->error = "PythonReadLimit";
        return 0;
    }
    ++r->reads;
    r->bytes += n;
    if (r->read(r->context, address, out, n)) {
        r->error = "MemoryUnreadable";
        return 0;
    }
    return 1;
}
static uint64_t le(const uint8_t *p, unsigned n) {
    uint64_t v = 0;
    for (unsigned i = 0; i < n; ++i)
        v |= (uint64_t)p[i] << (8 * i);
    return v;
}
static uint64_t number(struct xpy_reader *r, uint64_t address, unsigned n) {
    uint8_t bytes[8];
    return n && n <= 8 && read_bytes(r, address, bytes, n) ? le(bytes, n) : 0;
}
static uint64_t field(const struct xpy_layout *l, enum xpy_field f) {
    return l->fields[f];
}
static uint64_t at(const struct xpy_layout *l, struct xpy_reader *r, uint64_t base, enum xpy_field f, unsigned n) {
    if (!base || base > UINT64_MAX - field(l, f)) {
        r->error = "InvalidAddress";
        return 0;
    }
    return number(r, base + field(l, f), n);
}
static uint64_t pointer(const struct xpy_layout *l, struct xpy_reader *r, uint64_t base, enum xpy_field f) {
    return at(l, r, base, f, 8);
}

/* ---- strings ------------------------------------------------------- */
static size_t put_utf8(char *out, size_t pos, size_t cap, uint32_t cp) {
    char tmp[8];
    size_t n;
    if (cp < 0x80) {
        tmp[0] = (char)cp;
        n = 1;
    } else if (cp < 0x800) {
        tmp[0] = (char)(0xc0 | (cp >> 6));
        tmp[1] = (char)(0x80 | (cp & 63));
        n = 2;
    } else if (cp < 0x10000) {
        tmp[0] = (char)(0xe0 | (cp >> 12));
        tmp[1] = (char)(0x80 | ((cp >> 6) & 63));
        tmp[2] = (char)(0x80 | (cp & 63));
        n = 3;
    } else {
        tmp[0] = (char)(0xf0 | (cp >> 18));
        tmp[1] = (char)(0x80 | ((cp >> 12) & 63));
        tmp[2] = (char)(0x80 | ((cp >> 6) & 63));
        tmp[3] = (char)(0x80 | (cp & 63));
        n = 4;
    }
    if (pos + n >= cap)
        return 0;
    memcpy(out + pos, tmp, n);
    return n;
}
/* Appends one code point; repr mode follows str.__repr__ escaping for
 * quotes, backslash and non-printable ASCII. Surrogates are never emitted
 * as UTF-8. Returns 0 when the output is full. */
static size_t put_char(char *out, size_t pos, size_t cap, uint32_t cp, int repr, char quote) {
    char tmp[16];
    int n = 0;
    if (repr && (cp == (uint32_t)quote || cp == '\\'))
        n = snprintf(tmp, sizeof tmp, "\\%c", (char)cp);
    else if (repr && cp == '\n')
        n = snprintf(tmp, sizeof tmp, "\\n");
    else if (repr && cp == '\t')
        n = snprintf(tmp, sizeof tmp, "\\t");
    else if (repr && cp == '\r')
        n = snprintf(tmp, sizeof tmp, "\\r");
    else if (cp < 32 || cp == 127 || (cp >= 0x80 && cp < 0xa0))
        n = snprintf(tmp, sizeof tmp, "\\x%02x", cp);
    else if (cp == 0xa0 || cp == 0xad)
        n = snprintf(tmp, sizeof tmp, "\\x%02x", cp);
    else if ((cp >= 0xd800 && cp < 0xe000) || (cp < 0x10000 && xtext_invisible(cp)))
        n = snprintf(tmp, sizeof tmp, "\\u%04x", cp);
    else if (cp <= 0x10ffff && xtext_invisible(cp))
        n = snprintf(tmp, sizeof tmp, "\\U%08x", cp);
    else if (cp > 0x10ffff)
        n = snprintf(tmp, sizeof tmp, "\\U%08x", cp);
    if (n) {
        if (pos + (size_t)n >= cap)
            return 0;
        memcpy(out + pos, tmp, (size_t)n);
        return (size_t)n;
    }
    return put_utf8(out, pos, cap, cp);
}
static int type_is(const struct xpy_layout *l, uint64_t type, enum xpy_type t) {
    return type && type == l->types[t];
}
/* Reads a compact str. Writes NUL-terminated UTF-8 (repr-escaped when
 * requested) into out. Returns 1 when the full string fit. */
static int unicode(const struct xpy_layout *l, struct xpy_reader *r, uint64_t address, char *out, size_t cap,
                   size_t max_chars, int repr, uint64_t *length_out, const char **why) {
    out[0] = 0;
    uint8_t head[64];
    size_t need = field(l, XPY_STR_ASCII_SIZE);
    if (need > sizeof head || field(l, XPY_STR_STATE) + 4 > need || field(l, XPY_STR_LENGTH) + 8 > need) {
        *why = "PythonLayoutUnsupported";
        return 0;
    }
    if (!read_bytes(r, address, head, need)) {
        *why = r->error;
        return 0;
    }
    uint32_t state = (uint32_t)le(head + field(l, XPY_STR_STATE), 4);
    int64_t length = (int64_t)le(head + field(l, XPY_STR_LENGTH), 8);
    unsigned kind = (state >> 2) & 7, compact = (state >> 5) & 1, ascii = (state >> 6) & 1;
    if (length < 0 || length > (int64_t)1 << 40 || (kind != 1 && kind != 2 && kind != 4) || (ascii && kind != 1)) {
        *why = "InconsistentStr";
        return 0;
    }
    if (length_out)
        *length_out = (uint64_t)length;
    uint64_t data = address + (ascii ? field(l, XPY_STR_ASCII_SIZE) : field(l, XPY_STR_COMPACT_SIZE));
    if (!compact) {
        /* Non-compact strings (str subclass instances, ASCII or not) keep a
         * data pointer right after the compact header. */
        data = number(r, address + field(l, XPY_STR_COMPACT_SIZE), 8);
        if (r->error) {
            *why = r->error;
            return 0;
        }
        if (!data && length) {
            *why = "InconsistentStr";
            return 0;
        }
    }
    size_t chars = (uint64_t)length < max_chars ? (size_t)length : max_chars;
    uint8_t raw[1024 * 4];
    if (chars * kind > sizeof raw)
        chars = sizeof raw / kind;
    if (chars && !read_bytes(r, data, raw, chars * kind)) {
        *why = r->error;
        return 0;
    }
    size_t pos = 0, i = 0;
    for (; i < chars; ++i) {
        uint32_t cp = kind == 1 ? raw[i] : kind == 2 ? (uint32_t)le(raw + 2 * i, 2) : (uint32_t)le(raw + 4 * i, 4);
        if (ascii && cp > 127) {
            *why = "InconsistentStr";
            out[0] = 0;
            return 0;
        }
        size_t n = put_char(out, pos, cap, cp, repr, '\'');
        if (!n)
            break;
        pos += n;
    }
    out[pos] = 0;
    return i == (size_t)length;
}

/* ---- object headers ------------------------------------------------- */
struct head {
    uint64_t refcnt, type, type_flags;
    int immortal;
    char type_name[64];
};
/* Validates the object header and its type object without trusting either:
 * refcount, type pointer, the type's own type (metatype) and tp_name. */
static const char *object_head(const struct xpy_layout *l, struct xpy_reader *r, uint64_t address, struct head *h,
                               int want_name) {
    memset(h, 0, sizeof *h);
    uint8_t raw[16];
    if (!read_bytes(r, address, raw, 16))
        return r->error;
    h->refcnt = le(raw, 8);
    h->type = le(raw + field(l, XPY_OB_TYPE), 8);
    uint32_t low = (uint32_t)h->refcnt;
    h->immortal = (int32_t)low < 0;
    if (!low)
        return "FreedObject";
    /* ob_overflow is never incremented in GIL builds; non-zero means the
     * head was overwritten, e.g. by an allocator free-list pointer. */
    if ((h->refcnt >> 32) & 0xffff)
        return "ObjectHeaderInvalid";
    if (!h->type || (h->type & 7))
        return "ObjectTypeInvalid";
    uint64_t meta = number(r, h->type + field(l, XPY_OB_TYPE), 8);
    h->type_flags = at(l, r, h->type, XPY_TP_FLAGS, 8);
    uint64_t name = want_name ? pointer(l, r, h->type, XPY_TP_NAME) : 0;
    if (r->error)
        return "ObjectTypeUnreadable";
    if (!type_is(l, meta, XPY_TYPE_TYPE)) {
        uint64_t meta_flags = meta ? at(l, r, meta, XPY_TP_FLAGS, 8) : 0;
        if (r->error || !(meta_flags & TPFLAGS_TYPE))
            return "ObjectTypeInvalid";
    }
    /* tp_name is a C string; bounded and never shortened silently. */
    if (name) {
        size_t i = 0;
        for (; i + 1 < sizeof h->type_name; i += 16) {
            size_t n = 4096 - (size_t)((name + i) & 4095);
            if (n > 16)
                n = 16;
            if (n > sizeof h->type_name - 1 - i)
                n = sizeof h->type_name - 1 - i;
            if (!read_bytes(r, name + i, h->type_name + i, n))
                break;
            if (memchr(h->type_name + i, 0, n))
                break;
        }
        h->type_name[sizeof h->type_name - 1] = 0;
        if (r->error)
            return "TypeNameUnreadable";
    }
    if (!h->type_name[0])
        snprintf(h->type_name, sizeof h->type_name, "?");
    return NULL;
}

static void shortest_double(double d, char *out, size_t cap) {
    if (isnan(d)) {
        snprintf(out, cap, "nan");
        return;
    }
    if (isinf(d)) {
        snprintf(out, cap, d < 0 ? "-inf" : "inf");
        return;
    }
    for (int precision = 1; precision <= 17; ++precision) {
        snprintf(out, cap, "%.*g", precision, d);
        if (strtod(out, NULL) == d)
            break;
    }
    if (!strpbrk(out, ".en"))
        strncat(out, ".0", cap - strlen(out) - 1);
}
/* Exact decimal for up to 34 30-bit digits (1020 bits). */
static int long_decimal(const uint32_t *digits, size_t n, int negative, char *out, size_t cap) {
    uint32_t work[34], chunks[40];
    size_t count = 0;
    if (n > 34)
        return 0;
    memcpy(work, digits, n * sizeof *work);
    size_t used = n;
    while (used && !work[used - 1])
        --used;
    while (used) {
        uint64_t rem = 0;
        for (size_t i = used; i-- > 0;) {
            uint64_t cur = (rem << LONG_SHIFT) | work[i];
            work[i] = (uint32_t)(cur / 1000000000u);
            rem = cur % 1000000000u;
        }
        if (count == sizeof chunks / sizeof *chunks)
            return 0;
        chunks[count++] = (uint32_t)rem;
        while (used && !work[used - 1])
            --used;
    }
    int pos = snprintf(out, cap, "%s%" PRIu32, negative ? "-" : "", count ? chunks[count - 1] : 0);
    for (size_t i = count - 1; count && i-- > 0;) {
        if (pos < 0 || (size_t)pos >= cap)
            return 0;
        pos += snprintf(out + pos, cap - (size_t)pos, "%09" PRIu32, chunks[i]);
    }
    return pos > 0 && (size_t)pos < cap;
}

/* Copies src into dst; a string that does not fit is cut on a UTF-8
 * boundary and marked with "...". */
static void bounded_copy(char *dst, size_t cap, const char *src) {
    size_t n = strlen(src);
    if (n < cap) {
        memcpy(dst, src, n + 1);
        return;
    }
    n = cap - 4;
    while (n && ((unsigned char)src[n] & 0xc0) == 0x80)
        --n;
    memcpy(dst, src, n);
    memcpy(dst + n, "...", 4);
}
/* A child's read failure belongs to that child: the container and its other
 * children stay readable. Only the shared read budget stays exhausted. */
static void isolate(struct xpy_reader *r, const char **reason) {
    if (r->error && strcmp(r->error, "PythonReadLimit")) {
        if (!*reason)
            *reason = r->error;
        r->error = NULL;
    }
}
static void value(const struct xpy_layout *, struct xpy_reader *, uint64_t, struct xpy_value *, unsigned);
static void item(const struct xpy_layout *l, struct xpy_reader *r, uint64_t address, struct xpy_value_item *out) {
    out->address = address;
    if (!address) {
        snprintf(out->type, sizeof out->type, "NULL");
        snprintf(out->display, sizeof out->display, "NULL");
        return;
    }
    struct xpy_value child;
    value(l, r, address, &child, 1);
    bounded_copy(out->type, sizeof out->type, child.type);
    bounded_copy(out->display, sizeof out->display, child.display);
    out->reason = child.reason;
    isolate(r, &out->reason);
}
static void inconsistent(struct xpy_value *out, const char *why) {
    out->reason = why;
    snprintf(out->display, sizeof out->display, "inconsistent %.40s object (%s)", out->type, why);
}
/* Nested values (depth 1) use repr-like text without the type prefix. */
static void value(const struct xpy_layout *l, struct xpy_reader *r, uint64_t address, struct xpy_value *out,
                  unsigned depth) {
    memset(out, 0, sizeof *out);
    out->address = address;
    struct head h;
    const char *why = object_head(l, r, address, &h, 1);
    out->refcount = (uint32_t)h.refcnt;
    out->immortal = h.immortal;
    out->type_object = h.type;
    if (why) {
        snprintf(out->type, sizeof out->type, "%s", !strcmp(why, "FreedObject") ? "freed" : "invalid");
        out->reason = why;
        snprintf(out->display, sizeof out->display, "%s object (%s)", out->type, why);
        return;
    }
    snprintf(out->type, sizeof out->type, "%s", h.type_name);
    int exact = 0;
    for (unsigned t = XPY_TYPE_NONE; t < XPY_TYPE_COUNT; ++t)
        exact |= type_is(l, h.type, (enum xpy_type)t);
    /* A builtin type object must carry its own fast-subclass flag. */
    if ((type_is(l, h.type, XPY_TYPE_LONG) && !(h.type_flags & TPFLAGS_LONG)) ||
        (type_is(l, h.type, XPY_TYPE_BOOL) && !(h.type_flags & TPFLAGS_LONG)) ||
        (type_is(l, h.type, XPY_TYPE_LIST) && !(h.type_flags & TPFLAGS_LIST)) ||
        (type_is(l, h.type, XPY_TYPE_TUPLE) && !(h.type_flags & TPFLAGS_TUPLE)) ||
        (type_is(l, h.type, XPY_TYPE_BYTES) && !(h.type_flags & TPFLAGS_BYTES)) ||
        (type_is(l, h.type, XPY_TYPE_UNICODE) && !(h.type_flags & TPFLAGS_UNICODE)) ||
        (type_is(l, h.type, XPY_TYPE_DICT) && !(h.type_flags & TPFLAGS_DICT))) {
        inconsistent(out, "InconsistentTypeFlags");
        return;
    }
    if (type_is(l, h.type, XPY_TYPE_NONE)) {
        if (address != l->types[XPY_NONE_OBJECT]) {
            inconsistent(out, "NoneTypeInstanceIsNotNone");
            return;
        }
        snprintf(out->display, sizeof out->display, "None");
    } else if (type_is(l, h.type, XPY_TYPE_BOOL)) {
        if (address != l->types[XPY_TRUE_OBJECT] && address != l->types[XPY_FALSE_OBJECT]) {
            inconsistent(out, "BoolIsNeitherTrueNorFalse");
            return;
        }
        snprintf(out->display, sizeof out->display, "%s", address == l->types[XPY_TRUE_OBJECT] ? "True" : "False");
    } else if (h.type_flags & TPFLAGS_LONG) {
        uint64_t tag = at(l, r, address, XPY_LONG_TAG, 8);
        if (r->error)
            goto unreadable;
        unsigned sign = tag & 3;
        uint64_t ndigits = tag >> 3;
        if (sign == 3 || ndigits > (1u << 24) || (sign != 1 && !ndigits)) {
            inconsistent(out, "InconsistentInt");
            return;
        }
        char text[320];
        if (sign == 1) {
            snprintf(text, sizeof text, "0");
        } else if (ndigits <= 28) { /* <= 253 decimal digits */
            uint32_t digits[34];
            uint8_t raw[34 * 4];
            if (!read_bytes(r, address + field(l, XPY_LONG_DIGIT), raw, ndigits * 4))
                goto unreadable;
            for (size_t i = 0; i < ndigits; ++i) {
                digits[i] = (uint32_t)le(raw + 4 * i, 4);
                if (digits[i] >> LONG_SHIFT) {
                    inconsistent(out, "InconsistentIntDigit");
                    return;
                }
            }
            if (!long_decimal(digits, ndigits, sign == 2, text, sizeof text)) {
                inconsistent(out, "InconsistentInt");
                return;
            }
        } else {
            /* Exact bit length from the most significant digit. */
            uint32_t top = (uint32_t)number(r, address + field(l, XPY_LONG_DIGIT) + (ndigits - 1) * 4, 4);
            if (r->error)
                goto unreadable;
            if (!top || top >> LONG_SHIFT) {
                inconsistent(out, "InconsistentIntDigit");
                return;
            }
            unsigned bits = 0;
            while (top >> bits)
                ++bits;
            snprintf(text, sizeof text, "%s<%" PRIu64 " bits>", sign == 2 ? "-" : "", (ndigits - 1) * LONG_SHIFT + bits);
            out->truncated = 1;
        }
        out->count = ndigits;
        if (depth || type_is(l, h.type, XPY_TYPE_LONG))
            snprintf(out->display, sizeof out->display, "%s%.260s", depth ? "" : "int ", text);
        else
            snprintf(out->display, sizeof out->display, "%.40s(int) %.260s", h.type_name, text);
    } else if (type_is(l, h.type, XPY_TYPE_FLOAT)) {
        uint64_t bits = at(l, r, address, XPY_FLOAT_VALUE, 8);
        if (r->error)
            goto unreadable;
        double d;
        memcpy(&d, &bits, sizeof d);
        char text[40];
        shortest_double(d, text, sizeof text);
        snprintf(out->display, sizeof out->display, "%s%s", depth ? "" : "float ", text);
    } else if (h.type_flags & TPFLAGS_UNICODE) {
        char text[depth ? 160 : 260];
        uint64_t length = 0;
        const char *str_why = NULL;
        int complete = unicode(l, r, address, text, sizeof text, depth ? 48 : 96, 1, &length, &str_why);
        if (str_why) {
            if (r->error)
                goto unreadable;
            inconsistent(out, str_why);
            return;
        }
        out->count = length;
        out->truncated = !complete;
        char prefix[64];
        snprintf(prefix, sizeof prefix, "%.40s%s", depth ? "" : exact ? "str" : h.type_name, depth ? "" : exact ? " " : "(str) ");
        snprintf(out->display, sizeof out->display, "%s'%s'%s", prefix, text,
                 complete ? "" : "...");
        if (!complete && !depth) {
            size_t pos = strlen(out->display);
            snprintf(out->display + pos, sizeof out->display - pos, " (%" PRIu64 " chars)", length);
        }
    } else if (h.type_flags & TPFLAGS_BYTES) {
        int64_t size = (int64_t)at(l, r, address, XPY_BYTES_SIZE, 8);
        if (r->error)
            goto unreadable;
        if (size < 0 || size > (int64_t)1 << 40) {
            inconsistent(out, "InconsistentBytes");
            return;
        }
        uint8_t raw[128];
        size_t n = (size_t)size < (depth ? 48u : sizeof raw) ? (size_t)size : (depth ? 48u : sizeof raw);
        if (n && !read_bytes(r, address + field(l, XPY_BYTES_VALUE), raw, n))
            goto unreadable;
        out->count = (uint64_t)size;
        out->truncated = n < (size_t)size;
        size_t pos = (size_t)snprintf(out->display, sizeof out->display, "%.40s%sb'", depth ? "" : exact ? "bytes" : h.type_name,
                                      depth ? "" : exact ? " " : "(bytes) ");
        size_t i = 0;
        for (; i < n && pos + 8 < sizeof out->display; ++i) {
            unsigned c = raw[i];
            if (c == '\'' || c == '\\')
                pos += (size_t)snprintf(out->display + pos, sizeof out->display - pos, "\\%c", c);
            else if (c >= 32 && c < 127)
                out->display[pos++] = (char)c;
            else
                pos += (size_t)snprintf(out->display + pos, sizeof out->display - pos, "\\x%02x", c);
        }
        out->truncated |= i < n;
        snprintf(out->display + pos, sizeof out->display - pos, "'%s", out->truncated ? "..." : "");
        if (out->truncated && !depth) {
            pos = strlen(out->display);
            snprintf(out->display + pos, sizeof out->display - pos, " (%" PRIu64 " bytes)", (uint64_t)size);
        }
    } else if (h.type_flags & (TPFLAGS_LIST | TPFLAGS_TUPLE)) {
        int list = (h.type_flags & TPFLAGS_LIST) != 0;
        int64_t size = (int64_t)at(l, r, address, list ? XPY_LIST_SIZE : XPY_TUPLE_SIZE, 8);
        uint64_t items = list ? pointer(l, r, address, XPY_LIST_ITEM) : address + field(l, XPY_TUPLE_ITEM);
        if (r->error)
            goto unreadable;
        if (size < 0 || size > (int64_t)1 << 40 || (size && !items)) {
            inconsistent(out, list ? "InconsistentList" : "InconsistentTuple");
            return;
        }
        out->count = (uint64_t)size;
        const char *kind = list ? "list" : "tuple";
        if (exact)
            snprintf(out->display, sizeof out->display, "%s (%" PRIu64 " item%s)", kind, out->count,
                     out->count == 1 ? "" : "s");
        else
            snprintf(out->display, sizeof out->display, "%.40s(%s) (%" PRIu64 " item%s)", h.type_name, kind,
                     out->count, out->count == 1 ? "" : "s");
        if (!depth && size) {
            uint8_t raw[XPY_MAX_PREVIEW * 8];
            size_t n = (uint64_t)size < XPY_MAX_PREVIEW ? (size_t)size : XPY_MAX_PREVIEW;
            if (!read_bytes(r, items, raw, n * 8))
                goto unreadable;
            for (size_t i = 0; i < n && !r->error; ++i) {
                struct xpy_value_item *entry = &out->items[out->item_count++];
                item(l, r, le(raw + 8 * i, 8), entry);
                snprintf(entry->key, sizeof entry->key, "[%zu]", i);
            }
        }
        out->truncated = out->count > out->item_count;
    } else if (h.type_flags & TPFLAGS_DICT) {
        int64_t used = (int64_t)at(l, r, address, XPY_DICT_USED, 8);
        uint64_t keys = pointer(l, r, address, XPY_DICT_KEYS), values = pointer(l, r, address, XPY_DICT_VALUES);
        if (r->error)
            goto unreadable;
        if (used < 0 || !keys) {
            inconsistent(out, "InconsistentDict");
            return;
        }
        uint8_t kh[40];
        if (field(l, XPY_DK_NENTRIES) + 8 > sizeof kh || !read_bytes(r, keys, kh, field(l, XPY_DK_NENTRIES) + 8))
            goto unreadable;
        unsigned log2_size = kh[field(l, XPY_DK_LOG2_SIZE)], log2_index = kh[field(l, XPY_DK_LOG2_INDEX)];
        unsigned kind = kh[field(l, XPY_DK_KIND)];
        int64_t nentries = (int64_t)le(kh + field(l, XPY_DK_NENTRIES), 8);
        /* CPython's shared Py_EMPTY_KEYS: log2 size 0, no entries. */
        if (log2_size == 0 && nentries == 0 && used == 0 && !values && kind != DICT_SPLIT) {
            out->count = 0;
            snprintf(out->display, sizeof out->display, "%s%s (0 items)", exact ? "" : h.type_name, exact ? "dict" : "(dict)");
            return;
        }
        if (log2_size < 3 || log2_size > 40 || log2_index < log2_size || log2_index > log2_size + 3 || kind > 2 ||
            nentries < 0 || nentries > (int64_t)((((uint64_t)1 << log2_size) << 1) / 3) || used > nentries ||
            (values && kind != DICT_SPLIT) || (!values && kind == DICT_SPLIT)) {
            inconsistent(out, "InconsistentDict");
            return;
        }
        out->count = (uint64_t)used;
        snprintf(out->display, sizeof out->display, "%s%s (%" PRIu64 " item%s)", exact ? "" : h.type_name,
                 exact ? "dict" : "(dict)", out->count, out->count == 1 ? "" : "s");
        if (!depth && used) {
            size_t esize = kind == DICT_GENERAL ? 24 : 16, key_at = kind == DICT_GENERAL ? 8 : 0;
            size_t n = nentries < 64 ? (size_t)nentries : 64;
            uint64_t entries = keys + field(l, XPY_DK_INDICES) + ((uint64_t)1 << log2_index);
            uint8_t raw[64 * 24], vals[64 * 8];
            if (!read_bytes(r, entries, raw, n * esize))
                goto unreadable;
            if (values && !read_bytes(r, values + field(l, XPY_DV_VALUES), vals, n * 8))
                goto unreadable;
            for (size_t i = 0; i < n && out->item_count < XPY_MAX_PREVIEW && !r->error; ++i) {
                uint64_t key = le(raw + i * esize + key_at, 8);
                uint64_t val = values ? le(vals + 8 * i, 8) : le(raw + i * esize + key_at + 8, 8);
                if (!key || !val)
                    continue; /* deleted or not yet stored */
                struct xpy_value_item *entry = &out->items[out->item_count++];
                item(l, r, val, entry);
                struct xpy_value k;
                value(l, r, key, &k, 1);
                isolate(r, &k.reason);
                bounded_copy(entry->key, sizeof entry->key, k.display);
                if (k.reason && !entry->reason)
                    entry->reason = k.reason;
            }
        }
        out->truncated = out->count > out->item_count;
    } else if (type_is(l, h.type, XPY_TYPE_SET) || type_is(l, h.type, XPY_TYPE_FROZENSET)) {
        int64_t used = (int64_t)at(l, r, address, XPY_SET_USED, 8);
        if (r->error)
            goto unreadable;
        if (used < 0 || used > (int64_t)1 << 40) {
            inconsistent(out, "InconsistentSet");
            return;
        }
        out->count = (uint64_t)used;
        out->truncated = used > 0;
        snprintf(out->display, sizeof out->display, "%s (%" PRIu64 " item%s)", h.type_name, out->count,
                 out->count == 1 ? "" : "s");
    } else if (h.type_flags & TPFLAGS_TYPE) {
        char name[64];
        struct head th;
        /* The object is itself a type: show its tp_name. */
        uint64_t tp_name = pointer(l, r, address, XPY_TP_NAME);
        memset(&th, 0, sizeof th);
        name[0] = 0;
        if (tp_name) {
            for (size_t i = 0; i + 1 < sizeof name; i += 16) {
                size_t n = 4096 - (size_t)((tp_name + i) & 4095);
                if (n > 16)
                    n = 16;
                if (n > sizeof name - 1 - i)
                    n = sizeof name - 1 - i;
                if (!read_bytes(r, tp_name + i, name + i, n) || memchr(name + i, 0, n))
                    break;
            }
            name[sizeof name - 1] = 0;
        }
        if (r->error)
            goto unreadable;
        snprintf(out->display, sizeof out->display, "<class '%s'>", name[0] ? name : "?");
    } else if (type_is(l, h.type, XPY_TYPE_CODE)) {
        char name[160];
        const char *str_why = NULL;
        uint64_t qualname = pointer(l, r, address, XPY_CO_QUALNAME);
        if (r->error)
            goto unreadable;
        if (!qualname || !unicode(l, r, qualname, name, sizeof name, 120, 0, NULL, &str_why))
            snprintf(name, sizeof name, "?");
        snprintf(out->display, sizeof out->display, "<code %s>", name);
    } else {
        snprintf(out->display, sizeof out->display, "<%s object>", h.type_name);
    }
    if (r->error)
        goto unreadable;
    return;
unreadable:
    out->reason = r->error ? r->error : "MemoryUnreadable";
    snprintf(out->display, sizeof out->display, "%.40s object (%s)", out->type, out->reason);
}
void xpy_value_read(const struct xpy_layout *l, struct xpy_reader *r, uint64_t address, struct xpy_value *out) {
    value(l, r, address, out, 0);
}

/* ---- line table (Objects/locations.md, 3.11+) ------------------------ */
struct stream {
    const struct xpy_layout *l;
    struct xpy_reader *r;
    const uint8_t *memory; /* in-memory table (tests) or null */
    uint64_t address;
    size_t size, base, have, pos;
    uint8_t buffer[256];
};
static int next_byte(struct stream *s, uint8_t *out) {
    if (s->pos >= s->size)
        return 0;
    if (s->memory) {
        *out = s->memory[s->pos++];
        return 1;
    }
    if (s->pos >= s->base + s->have) {
        size_t n = s->size - s->pos < sizeof s->buffer ? s->size - s->pos : sizeof s->buffer;
        if (!read_bytes(s->r, s->address + s->pos, s->buffer, n))
            return 0;
        s->base = s->pos;
        s->have = n;
    }
    *out = s->buffer[s->pos++ - s->base];
    return 1;
}
static int varint(struct stream *s, uint64_t *out) {
    uint8_t b;
    unsigned shift = 0;
    *out = 0;
    do {
        if (shift > 60 || !next_byte(s, &b))
            return 0;
        *out |= (uint64_t)(b & 63) << shift;
        shift += 6;
    } while (b & 64);
    return 1;
}
/* Returns 1 when unit is covered: *line is the line or -1 (no location). */
static int line_for(struct stream *s, int first_line, uint64_t unit, int *line) {
    int64_t computed = first_line;
    uint64_t start = 0;
    uint8_t b;
    if (!next_byte(s, &b))
        return 0;
    for (unsigned entries = 0; entries < 1u << 20; ++entries) {
        if (!(b & 128))
            return 0;
        unsigned code = (b >> 3) & 15, length = (b & 7) + 1u;
        int64_t delta = 0;
        if (code == 14 || code == 13) {
            uint64_t raw;
            if (!varint(s, &raw))
                return 0;
            delta = (raw & 1) ? -(int64_t)(raw >> 1) : (int64_t)(raw >> 1);
        } else if (code >= 10 && code <= 12) {
            delta = code - 10;
        }
        computed += delta;
        if (computed < -1 || computed > INT32_MAX)
            return 0;
        if (unit >= start && unit < start + length) {
            *line = code == 15 ? -1 : (int)computed;
            return 1;
        }
        start += length;
        /* Skip the rest of this entry: the next entry byte has bit 7 set. */
        do {
            if (!next_byte(s, &b))
                return 0;
        } while (!(b & 128));
    }
    return 0;
}
int xpy_line_for(const uint8_t *table, size_t n, int first_line, uint64_t unit, int *line) {
    struct stream s;
    memset(&s, 0, sizeof s);
    s.memory = table;
    s.size = n;
    return line_for(&s, first_line, unit, line);
}

/* ---- stacks --------------------------------------------------------- */
struct code_cache {
    uint64_t code, units, table;
    size_t frame, table_size;
    int32_t first;
    uint32_t flags;
};
static int exact_type(const struct xpy_layout *l, struct xpy_reader *r, uint64_t address, enum xpy_type t) {
    struct head h;
    return !object_head(l, r, address, &h, 0) && type_is(l, h.type, t);
}
static void frame_line(struct xpy_reader *r, const struct xpy_layout *l, struct xpy_frame *f, const struct code_cache *c) {
    uint64_t code_start = c->code + field(l, XPY_CO_CODE);
    if (f->instr < code_start || ((f->instr - code_start) & 1) || (f->instr - code_start) / 2 >= c->units) {
        if (!f->reason)
            f->reason = "InstructionOutsideCode";
        return;
    }
    struct stream s;
    memset(&s, 0, sizeof s);
    s.l = l;
    s.r = r;
    s.address = c->table;
    s.size = c->table_size;
    int line = -1;
    if (!line_for(&s, c->first, (f->instr - code_start) / 2, &line)) {
        if (!f->reason)
            f->reason = r->error ? r->error : "LineTableInvalid";
        return;
    }
    if (line > 0)
        f->line = (uint32_t)line;
    else if (!f->reason)
        f->reason = "LineUnavailable";
}
/* Code objects are validated once per read; a stopped process cannot change
 * them between frames, so recursion costs one header and one table read. */
static void frame_detail(const struct xpy_layout *l, struct xpy_reader *r, const struct xpy_stack *stack,
                         struct xpy_frame *f, struct code_cache *cache, unsigned *cached) {
    for (unsigned i = 0; i < *cached; ++i)
        if (cache[i].code == f->code) {
            memcpy(f->name, stack->frames[cache[i].frame].name, sizeof f->name);
            memcpy(f->file, stack->frames[cache[i].frame].file, sizeof f->file);
            f->code_flags = cache[i].flags;
            frame_line(r, l, f, &cache[i]);
            return;
        }
    if (!f->code || !exact_type(l, r, f->code, XPY_TYPE_CODE)) {
        snprintf(f->name, sizeof f->name, "(non-code executable)");
        f->reason = r->error ? r->error : "ExecutableNotCode";
        return;
    }
    uint64_t base = f->code;
    uint64_t filename = pointer(l, r, base, XPY_CO_FILENAME), qualname = pointer(l, r, base, XPY_CO_QUALNAME);
    uint64_t table = pointer(l, r, base, XPY_CO_LINETABLE);
    struct code_cache c = {.code = base, .frame = (size_t)(f - stack->frames)};
    c.first = (int32_t)at(l, r, base, XPY_CO_FIRSTLINE, 4);
    c.flags = f->code_flags = (uint32_t)at(l, r, base, XPY_CO_FLAGS, 4);
    int64_t units = (int64_t)at(l, r, base, XPY_TUPLE_SIZE, 8); /* Py_SIZE(code): code units */
    if (r->error) {
        f->reason = r->error;
        return;
    }
    const char *why = NULL;
    if (!qualname || !unicode(l, r, qualname, f->name, sizeof f->name, 255, 0, NULL, &why)) {
        snprintf(f->name, sizeof f->name, "(unavailable code name)");
        f->reason = r->error ? r->error : why ? why : "CodeNameUnavailable";
    }
    why = NULL;
    if (!filename || !unicode(l, r, filename, f->file, sizeof f->file, 1023, 0, NULL, &why)) {
        f->file[0] = 0; /* never expose a shortened path */
        if (!f->reason)
            f->reason = r->error ? r->error : why ? why : "FileNameUnavailableOrTruncated";
    }
    if (r->error)
        return;
    if (units < 0 || units > 1 << 26) {
        if (!f->reason)
            f->reason = "CodeObjectInvalid";
        return;
    }
    c.units = (uint64_t)units;
    if (!table || !exact_type(l, r, table, XPY_TYPE_BYTES)) {
        if (!f->reason)
            f->reason = r->error ? r->error : "LineTableUnavailable";
        return;
    }
    int64_t size = (int64_t)at(l, r, table, XPY_BYTES_SIZE, 8);
    if (r->error || size < 0 || size > 1 << 24) {
        if (!f->reason)
            f->reason = r->error ? r->error : "LineTableInvalid";
        return;
    }
    c.table = table + field(l, XPY_BYTES_VALUE);
    c.table_size = (size_t)size;
    if (!f->reason && *cached < XPY_MAX_FRAMES)
        cache[(*cached)++] = c;
    frame_line(r, l, f, &c);
}
static int find_range(const struct xpy_range *ranges, size_t n, uint64_t address) {
    for (size_t i = 0; i < n; ++i)
        if (address >= ranges[i].low && address < ranges[i].high)
            return (int)i;
    return -1;
}
static struct xpy_segment *open_segment(struct xpy_stack *out, uint64_t ts, uint64_t interp, uint64_t id) {
    if (out->segment_count == sizeof out->segments / sizeof *out->segments)
        return NULL;
    struct xpy_segment *s = &out->segments[out->segment_count++];
    memset(s, 0, sizeof *s);
    s->thread_state = ts;
    s->interpreter = interp;
    s->interpreter_id = id;
    s->anchor = -1;
    s->first = out->count;
    return s;
}
/* Walks one thread state's frame chain. Frames between two entry frames
 * belong to the native activation whose [sp, cfa) holds the lower entry
 * frame; that containment is the proof of each anchor. */
/* Discards a closed segment's retained frames (and code-cache entries that
 * point at them) when its proven anchor lies before the caller's `first`. */
static void rewind_segment(struct xpy_stack *out, struct xpy_segment *s, struct code_cache *cache, unsigned *cached) {
    unsigned kept = 0;
    for (unsigned i = 0; i < *cached; ++i)
        if (cache[i].frame < s->first)
            cache[kept++] = cache[i];
    *cached = kept;
    out->count = s->first;
    s->count = 0;
    s->skipped = 1;
    if (s->reason && !strcmp(s->reason, "FrameLimit"))
        s->reason = NULL;
}
static void walk(const struct xpy_layout *l, struct xpy_reader *r, uint64_t ts, uint64_t interp, uint64_t id,
                 const struct xpy_range *ranges, size_t range_count, size_t first, struct xpy_stack *out,
                 struct code_cache *cache, unsigned *cached) {
    uint64_t frame = pointer(l, r, ts, XPY_TS_FRAME);
    if (r->error)
        return;
    struct xpy_segment *s = open_segment(out, ts, interp, id);
    if (!s) {
        out->reason = "SegmentLimit";
        return;
    }
    size_t examined = 0, pending = 0; /* Python frames in s, retained or not */
    int last_anchor = -1;
    uint64_t tortoise = frame, power = 1, lambda = 0;
    size_t header = field(l, XPY_FR_PREVIOUS) + 8;
    if (field(l, XPY_FR_EXECUTABLE) + 8 > header)
        header = field(l, XPY_FR_EXECUTABLE) + 8;
    if (field(l, XPY_FR_INSTR) + 8 > header)
        header = field(l, XPY_FR_INSTR) + 8;
    if (field(l, XPY_FR_OWNER) + 1 > header)
        header = field(l, XPY_FR_OWNER) + 1;
    while (frame) {
        if (examined == XPY_MAX_EXAMINED) {
            s->reason = "FrameExaminedLimit";
            break;
        }
        ++examined;
        uint8_t raw[256];
        if (header > sizeof raw || !read_bytes(r, frame, raw, header)) {
            s->reason = r->error ? r->error : "PythonLayoutUnsupported";
            break;
        }
        uint64_t previous = le(raw + field(l, XPY_FR_PREVIOUS), 8);
        uint8_t owner = raw[field(l, XPY_FR_OWNER)];
        /* 3.14 still defines FRAME_OWNED_BY_CSTACK; 3.16 stops at INTERPRETER. */
        if (owner > ((l->version >> 16) == 0x030e ? XPY_OWNED_BY_CSTACK : XPY_OWNED_BY_INTERPRETER)) {
            s->reason = "FrameOwnerInvalid";
            break;
        }
        if (owner >= XPY_OWNED_BY_INTERPRETER) {
            int k = find_range(ranges, range_count, frame);
            if (k >= 0)
                out->entry_found[k] = 1;
            if (pending) {
                if (k < 0) {
                    if (!s->reason)
                        s->reason = "EntryFrameOutsideNativeAnchors";
                } else if (k <= last_anchor) {
                    s->reason = "AnchorOrderInconsistent";
                } else {
                    s->anchor = k;
                    s->entry_frame = frame;
                    if ((size_t)k < first)
                        rewind_segment(out, s, cache, cached);
                }
                s->examined = examined;
                s = open_segment(out, ts, interp, id);
                if (!s) {
                    out->reason = "SegmentLimit";
                    return;
                }
                pending = examined = 0;
            }
            /* An entry frame with no frames above it is an activation that
             * has not started a Python frame yet; it still orders anchors. */
            if (k > last_anchor)
                last_anchor = k;
        } else {
            ++pending;
            if (out->count < XPY_MAX_FRAMES && out->count - s->first < XPY_SEGMENT_FRAMES) {
                struct xpy_frame *f = &out->frames[out->count++];
                memset(f, 0, sizeof *f);
                f->address = frame;
                f->owner = owner;
                f->code = le(raw + field(l, XPY_FR_EXECUTABLE), 8) & ~(uint64_t)STACKREF_TAG_BITS;
                f->instr = le(raw + field(l, XPY_FR_INSTR), 8);
                if (owner == XPY_OWNED_BY_FRAME_OBJECT)
                    f->reason = "FrameOwnedByFrameObject";
                frame_detail(l, r, out, f, cache, cached);
                s->count = out->count - s->first;
                if (r->error) {
                    s->reason = r->error;
                    break;
                }
                if (f->reason && !s->reason && strcmp(f->reason, "LineUnavailable"))
                    s->reason = "PartialFrames";
            } else if (!s->reason) {
                s->reason = "FrameLimit";
            }
        }
        /* Brent's cycle detection on frame addresses; no re-reads. */
        if (previous && (previous == frame || previous == tortoise)) {
            s->reason = "FrameCycle";
            break;
        }
        if (++lambda == power) {
            tortoise = previous;
            power <<= 1;
            lambda = 0;
        }
        frame = previous;
    }
    s->examined = examined;
    if (pending && s->anchor < 0 && !s->reason)
        s->reason = "EntryFrameUnavailable";
    /* The chain ended at its root: an empty trailing segment holds nothing. */
    if (!pending && !s->reason)
        --out->segment_count;
}
void xpy_stack_read(const struct xpy_layout *l, struct xpy_reader *r, uint32_t tid, const struct xpy_range *ranges,
                    size_t range_count, size_t first, struct xpy_stack *out) {
    memset(out, 0, sizeof *out);
    uint64_t interp = pointer(l, r, l->runtime, XPY_RT_INTERPRETERS);
    uint64_t seen_interp[64];
    unsigned interps = 0, states = 0;
    struct code_cache cache[XPY_MAX_FRAMES];
    unsigned cached = 0;
    struct {
        uint64_t ts, interp, id;
    } matches[XPY_MAX_THREAD_STATES];
    while (interp && !r->error) {
        for (unsigned i = 0; i < interps; ++i)
            if (seen_interp[i] == interp) {
                out->reason = "InterpreterCycle";
                return;
            }
        if (interps == 64) {
            out->reason = "InterpreterLimit";
            return;
        }
        seen_interp[interps++] = interp;
        uint64_t id = at(l, r, interp, XPY_IS_ID, 8);
        uint64_t ts = pointer(l, r, interp, XPY_IS_THREADS);
        uint64_t first = ts;
        while (ts && !r->error) {
            if (++states > 4096) {
                out->reason = "ThreadStateLimit";
                return;
            }
            uint64_t native = at(l, r, ts, XPY_TS_NATIVE_ID, 8), next = pointer(l, r, ts, XPY_TS_NEXT);
            uint64_t owner = pointer(l, r, ts, XPY_TS_INTERP);
            if (r->error)
                break;
            if (owner != interp) {
                out->reason = "ThreadStateInterpreterMismatch";
                return;
            }
            if (native == tid) {
                if (out->thread_states == XPY_MAX_THREAD_STATES) {
                    out->reason = "ThreadStateLimit";
                    return;
                }
                matches[out->thread_states].ts = ts;
                matches[out->thread_states].interp = interp;
                matches[out->thread_states].id = id;
                ++out->thread_states;
            }
            if (next == ts || next == first) {
                out->reason = "ThreadStateCycle";
                return;
            }
            ts = next;
        }
        interp = pointer(l, r, interp, XPY_IS_NEXT);
    }
    if (r->error) {
        out->reason = r->error;
        return;
    }
    for (size_t i = 0; i < out->thread_states && !r->error; ++i)
        walk(l, r, matches[i].ts, matches[i].interp, matches[i].id, ranges, range_count, first, out, cache, &cached);
    if (r->error && !out->reason)
        out->reason = r->error;
}
