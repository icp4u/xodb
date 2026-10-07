#include "javascript.h"
#include "../text.h"
#include "javascript_v8_14_6.h"
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

const char *const xjs_field_names[XJS_FIELD_COUNT] = {
#define XJS_FIELD(key, name) name,
#include "javascript_fields.inc"
#undef XJS_FIELD
};

const char *xjs_layout_check(const struct xjs_layout *l, const uint8_t *id, size_t n, const uint32_t version[4]) {
    if (!n || n > sizeof l->build_id || n != l->build_id_len || memcmp(id, l->build_id, n))
        return "JavaScriptBuildIdMismatch";
    if (memcmp(version, l->version, sizeof l->version)) return "JavaScriptVersionMismatch";
    if (version[0] != 14 || version[1] != 6 || version[2] != 202 || version[3] != 34)
        return "JavaScriptVersionUnsupported";
    const int required[] = {XJS_POINTER_SIZE, XJS_TAGGED_SIZE, XJS_HEAP_TAG, XJS_HEAP_MASK,
        XJS_SMI_TAG, XJS_SMI_MASK, XJS_SMI_SHIFT, XJS_SMI_TAG_SIZE, XJS_MAP, XJS_MAP_TYPE, XJS_TYPE_MAP};
    for (size_t i = 0; i < sizeof required / sizeof *required; ++i)
        if (!l->present[required[i]]) return "JavaScriptMetadataUnavailable";
    if (l->fields[XJS_POINTER_SIZE] != 8 || l->fields[XJS_TAGGED_SIZE] != 8)
        return "JavaScriptCompressedPointersUnsupported";
    if (l->fields[XJS_HEAP_TAG] != 1 || l->fields[XJS_HEAP_MASK] != 3 ||
        l->fields[XJS_SMI_TAG] != 0 || l->fields[XJS_SMI_MASK] != 1 ||
        l->fields[XJS_SMI_SHIFT] != 31 || l->fields[XJS_SMI_TAG_SIZE] != 1 ||
        l->fields[XJS_MAP] != 0 || l->fields[XJS_MAP_TYPE] != 12)
        return "JavaScriptMetadataInconsistent";
    for (size_t i = 0; i < XJS_FIELD_COUNT; ++i) {
        if (!l->present[i]) continue;
        if (!strncmp(xjs_field_names[i], "v8dbg_type_", 11) &&
            (l->fields[i] < 0 || l->fields[i] > UINT16_MAX)) return "JavaScriptMetadataInconsistent";
        if (strstr(xjs_field_names[i], "v8dbg_class_") &&
            (l->fields[i] < 0 || l->fields[i] > 4096)) return "JavaScriptMetadataInconsistent";
    }
    const int shifts[] = {XJS_DICTIONARY_SHIFT, XJS_OWN_SHIFT, XJS_PROP_LOCATION_SHIFT,
        XJS_PROP_INDEX_SHIFT, XJS_PROP_REPR_SHIFT, XJS_CODE_KIND_SHIFT};
    for (size_t i = 0; i < sizeof shifts / sizeof *shifts; ++i)
        if (l->present[shifts[i]] && (l->fields[shifts[i]] < 0 || l->fields[shifts[i]] > 31))
            return "JavaScriptMetadataInconsistent";
    const int indices[] = {XJS_DESC_SIZE, XJS_DESC_KEY, XJS_DESC_DETAILS, XJS_DESC_VALUE,
        XJS_SCOPE_PARAMS, XJS_SCOPE_LOCALS, XJS_SCOPE_VARS};
    for (size_t i = 0; i < sizeof indices / sizeof *indices; ++i)
        if (l->present[indices[i]] && (l->fields[indices[i]] < 0 || l->fields[indices[i]] > 64))
            return "JavaScriptMetadataInconsistent";
    if (l->present[XJS_DESC_SIZE] && l->fields[XJS_DESC_SIZE] != 3) return "JavaScriptMetadataInconsistent";
    return NULL;
}
static int fail(struct xjs_reader *r, const char *why) {
    if (!r->error) r->error = why;
    return 0;
}
static int field(const struct xjs_layout *l, struct xjs_reader *r, enum xjs_field f) {
    if (!l->present[f]) { fail(r, "JavaScriptMetadataFieldUnavailable"); return 0; }
    return l->fields[f];
}
static unsigned shift(const struct xjs_layout *l, struct xjs_reader *r, enum xjs_field f) {
    int n = field(l, r, f);
    if (n < 0 || n > 31) { fail(r, "JavaScriptMetadataInconsistent"); return 0; }
    return (unsigned)n;
}
static int supplement(const struct xjs_layout *l, struct xjs_reader *r) {
    if (memcmp(l->version_string, XJS_V8_VERSION, sizeof XJS_V8_VERSION))
        return fail(r, "JavaScriptSupplementVersionUnsupported");
    /* Code's raw instruction pointer is absent under the sandbox: the
     * wrapper/stream/start/flags offsets prove the unsandboxed layout. */
    static const struct { enum xjs_field field; int value; } checks[] = {
        {XJS_POINTER_SIZE, 8}, {XJS_TAGGED_SIZE, 8}, {XJS_SMI_SHIFT, 31},
        {XJS_MAP, 0}, {XJS_MAP_TYPE, 12}, {XJS_OBJECT_HEADER, 24},
        {XJS_FIXED_LENGTH, 8}, {XJS_FIXED_DATA, 16}, {XJS_STRING_LENGTH, 12},
        {XJS_SCOPE_PARAMS, 1}, {XJS_SCOPE_LOCALS, 2}, {XJS_SCOPE_VARS, 5},
        {XJS_SHARED_NAME, 24}, {XJS_SHARED_SCRIPT, 40},
        {XJS_BYTECODE_WRAPPER, 16}, {XJS_BYTECODE_DATA, 64}, {XJS_BYTECODE_LENGTH, 8},
        {XJS_CODE_WRAPPER, 24}, {XJS_CODE_STREAM, 32}, {XJS_CODE_START, 40},
        {XJS_CODE_FLAGS, 52}, {XJS_CODE_SIZE, 56}, {XJS_EXTERNAL_RESOURCE, 16}
    };
    for (size_t i = 0; i < sizeof checks / sizeof *checks; ++i)
        if (!l->present[checks[i].field] || l->fields[checks[i].field] != checks[i].value)
            return fail(r, "JavaScriptSupplementMetadataMismatch");
    r->version_table = 1;
    return 1;
}
static int read_bytes(struct xjs_reader *r, uint64_t a, void *out, size_t n) {
    if (r->error) return 0;
    if (a < 4096 || a >= (UINT64_C(1) << 63) || n > UINT64_MAX - a)
        return fail(r, "JavaScriptInvalidAddress");
    if (r->reads >= XJS_READ_LIMIT || r->bytes > XJS_BYTE_LIMIT || n > XJS_BYTE_LIMIT - r->bytes)
        return fail(r, "JavaScriptReadBudget");
    ++r->reads; r->bytes += n;
    if (r->read(r->context, a, out, n)) return fail(r, "JavaScriptMemoryUnavailable");
    return 1;
}
int xjs_read_memory(struct xjs_reader *r, uint64_t a, void *out, size_t n) {
    return read_bytes(r, a, out, n);
}
static uint64_t word(struct xjs_reader *r, uint64_t a, size_t n) {
    uint8_t bytes[8]; uint64_t out = 0;
    if (!n || n > sizeof bytes || !read_bytes(r, a, bytes, n)) return 0;
    for (size_t i = 0; i < n; ++i) out |= (uint64_t)bytes[i] << (i * 8);
    return out;
}
static uint64_t at(const struct xjs_layout *l, struct xjs_reader *r, uint64_t a, enum xjs_field f, size_t n) {
    int off = field(l, r, f);
    if (off < 0 || a > UINT64_MAX - (uint64_t)off) { fail(r, "JavaScriptInvalidAddress"); return 0; }
    return word(r, a + (uint64_t)off, n);
}
static int heap(uint64_t tagged) { return tagged > 4096 && (tagged & 7) == 1 && tagged < (UINT64_C(1) << 63); }
static int64_t smi(struct xjs_reader *r, uint64_t tagged) {
    if ((uint32_t)tagged != 0) { fail(r, "JavaScriptInvalidSmi"); return 0; }
    return (int32_t)(tagged >> 32);
}
struct head { uint64_t address, map; uint16_t type; };
static int head(const struct xjs_layout *l, struct xjs_reader *r, uint64_t tagged, struct head *h) {
    if (!heap(tagged)) return fail(r, "JavaScriptInvalidHeapTag");
    h->address = tagged - 1;
    h->map = at(l, r, h->address, XJS_MAP, 8);
    if (!heap(h->map)) return fail(r, "JavaScriptInvalidMap");
    uint64_t meta = at(l, r, h->map - 1, XJS_MAP, 8);
    if (!heap(meta)) return fail(r, "JavaScriptInvalidMap");
    if (at(l, r, meta - 1, XJS_MAP_TYPE, 2) != (uint64_t)field(l, r, XJS_TYPE_MAP))
        return fail(r, "JavaScriptInvalidMap");
    h->type = (uint16_t)at(l, r, h->map - 1, XJS_MAP_TYPE, 2);
    return r->error == NULL;
}
static int is(const struct xjs_layout *l, uint16_t type, enum xjs_field f) {
    return l->present[f] && type == l->fields[f];
}
static int string_head(const struct xjs_layout *l, struct xjs_reader *r, uint64_t tagged, struct head *h, uint32_t *length) {
    if (!head(l, r, tagged, h)) return 0;
    if (h->type >= field(l, r, XJS_FIRST_NONSTRING)) return fail(r, "JavaScriptExpectedString");
    uint64_t n = at(l, r, h->address, XJS_STRING_LENGTH, 4);
    if (n > (UINT64_C(1) << 28)) return fail(r, "JavaScriptInvalidStringLength");
    *length = (uint32_t)n;
    return r->error == NULL;
}
static int string_units(const struct xjs_layout *l, struct xjs_reader *r, uint64_t tagged,
                        uint32_t start, size_t count, uint16_t *out, unsigned depth) {
    if (depth >= 24) return fail(r, "JavaScriptStringDepthLimit");
    struct head h; uint32_t length;
    if (!string_head(l, r, tagged, &h, &length)) return 0;
    if (start > length || count > length - start) return fail(r, "JavaScriptStringRangeInvalid");
    unsigned repr = h.type & field(l, r, XJS_STRING_MASK);
    if (repr == (unsigned)field(l, r, XJS_SEQ)) {
        unsigned size = (h.type & field(l, r, XJS_ENCODING_MASK)) == field(l, r, XJS_ONE_BYTE) ? 1 : 2;
        int off = field(l, r, size == 1 ? XJS_ONE_CHARS : XJS_TWO_CHARS);
        uint8_t bytes[XJS_STRING_UNITS * 2];
        if (count > XJS_STRING_UNITS) return fail(r, "JavaScriptStringPreviewLimit");
        if (count && !read_bytes(r, h.address + (uint64_t)off + (uint64_t)start * size, bytes, count * size)) return 0;
        for (size_t i = 0; i < count; ++i) out[i] = bytes[i * size] | (size == 2 ? (uint16_t)bytes[i * 2 + 1] << 8 : 0);
        return r->error == NULL;
    }
    if (repr == (unsigned)field(l, r, XJS_CONS)) {
        uint64_t first = at(l, r, h.address, XJS_CONS_FIRST, 8), second = at(l, r, h.address, XJS_CONS_SECOND, 8);
        struct head child; uint32_t n, m;
        if (!string_head(l, r, first, &child, &n) || !string_head(l, r, second, &child, &m)) return 0;
        if ((uint64_t)n + m != length) return fail(r, "JavaScriptStringRangeInvalid");
        size_t left = start < n ? n - start : 0; if (left > count) left = count;
        if (left && !string_units(l, r, first, start, left, out, depth + 1)) return 0;
        return left == count || string_units(l, r, second, start < n ? 0 : start - n, count - left, out + left, depth + 1);
    }
    if (repr == (unsigned)field(l, r, XJS_SLICED) || repr == (unsigned)field(l, r, XJS_THIN)) {
        int sliced = repr == (unsigned)field(l, r, XJS_SLICED);
        uint64_t parent = at(l, r, h.address, sliced ? XJS_SLICED_PARENT : XJS_THIN_ACTUAL, 8);
        int64_t off = sliced ? smi(r, at(l, r, h.address, XJS_SLICED_OFFSET, 8)) : 0;
        struct head child; uint32_t n;
        if (!string_head(l, r, parent, &child, &n)) return 0;
        if (off < 0 || (uint64_t)off + length > n || (!sliced && length != n)) return fail(r, "JavaScriptStringRangeInvalid");
        return string_units(l, r, parent, (uint32_t)off + start, count, out, depth + 1);
    }
    if (repr == (unsigned)field(l, r, XJS_EXTERNAL)) {
        if (is(l, h.type, XJS_TYPE_UNCACHED_ONE) || is(l, h.type, XJS_TYPE_UNCACHED_TWO))
            return fail(r, "JavaScriptUncachedExternalStringNeedsCall");
        if (!supplement(l, r)) return 0;
        uint64_t data = word(r, h.address + XJS_V8_EXTERNAL_DATA, 8);
        unsigned size = (h.type & field(l, r, XJS_ENCODING_MASK)) == field(l, r, XJS_ONE_BYTE) ? 1 : 2;
        if (count > XJS_STRING_UNITS || data > UINT64_MAX - (uint64_t)length * size)
            return fail(r, "JavaScriptInvalidAddress");
        uint8_t bytes[XJS_STRING_UNITS * 2];
        if (count && !read_bytes(r, data + (uint64_t)start * size, bytes, count * size)) return 0;
        for (size_t i = 0; i < count; ++i) out[i] = bytes[i * size] | (size == 2 ? (uint16_t)bytes[i * 2 + 1] << 8 : 0);
        return r->error == NULL;
    }
    return fail(r, repr == (unsigned)field(l, r, XJS_EXTERNAL) ? "JavaScriptExternalStringDataUnavailable" : "JavaScriptStringRepresentationUnsupported");
}
/* Escape format controls and unpaired UTF-16 surrogates. Only complete UTF-8
 * sequences reach display buffers. */
static size_t append_cp(char *out, size_t pos, size_t cap, uint32_t cp) {
    char bytes[16]; size_t n;
    if (cp == '"' || cp == '\\') { bytes[0] = '\\'; bytes[1] = (char)cp; n = 2; }
    else if (cp < 32 || (cp >= 0x7f && cp <= 0x9f) || xtext_invisible(cp) || (cp >= 0xd800 && cp <= 0xdfff))
        n = (size_t)snprintf(bytes, sizeof bytes, cp <= 0xffff ? "\\u%04x" : "\\u{%x}", cp);
    else if (cp < 128) { bytes[0] = (char)cp; n = 1; }
    else if (cp < 2048) { bytes[0] = (char)(0xc0 | (cp >> 6)); bytes[1] = (char)(0x80 | (cp & 63)); n = 2; }
    else if (cp < 65536) { bytes[0] = (char)(0xe0 | (cp >> 12)); bytes[1] = (char)(0x80 | ((cp >> 6) & 63)); bytes[2] = (char)(0x80 | (cp & 63)); n = 3; }
    else { bytes[0] = (char)(0xf0 | (cp >> 18)); bytes[1] = (char)(0x80 | ((cp >> 12) & 63)); bytes[2] = (char)(0x80 | ((cp >> 6) & 63)); bytes[3] = (char)(0x80 | (cp & 63)); n = 4; }
    if (pos >= cap || n >= cap - pos) return pos;
    memcpy(out + pos, bytes, n); out[pos + n] = 0; return pos + n;
}
static int string(const struct xjs_layout *l, struct xjs_reader *r, uint64_t tagged, char *out, size_t cap, uint64_t *total, int *truncated, int quoted, const char **diagnostic) {
    struct head h; uint32_t n;
    if (!string_head(l, r, tagged, &h, &n)) return 0;
    /* A missing following header is only advisory: valid large strings and
     * fresh allocations can have no following object. It is not evidence
     * that the claimed string length is wrong. All payload reads below are
     * bounded by both that length and the preview limit. */
    if (diagnostic && (h.type & field(l, r, XJS_STRING_MASK)) == (unsigned)field(l, r, XJS_SEQ)) {
        unsigned width = (h.type & field(l, r, XJS_ENCODING_MASK)) == field(l, r, XJS_ONE_BYTE) ? 1 : 2;
        uint64_t size = (uint64_t)field(l, r, width == 1 ? XJS_ONE_CHARS : XJS_TWO_CHARS) + (uint64_t)n * width;
        size = (size + 7) & ~UINT64_C(7);
        struct head next;
        if (r->error || h.address > UINT64_MAX - size - 1) return fail(r, "JavaScriptInvalidAddress");
        if (!head(l, r, h.address + size + 1, &next)) {
            if (r->error && !strcmp(r->error, "JavaScriptReadBudget")) return 0;
            *diagnostic = "JavaScriptStringExtentUnproved";
            r->error = NULL;
        }
    }
    *total = n; size_t count = n < XJS_STRING_UNITS ? n : XJS_STRING_UNITS;
    uint16_t units[XJS_STRING_UNITS];
    if (!string_units(l, r, tagged, 0, count, units, 0)) return 0;
    size_t pos = 0; out[0] = 0; if (quoted && cap > 1) {out[pos++] = '"'; out[pos] = 0;}
    *truncated = count < n;
    for (size_t i = 0; i < count; ++i) {
        uint32_t cp = units[i];
        if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < count && units[i + 1] >= 0xdc00 && units[i + 1] <= 0xdfff)
            cp = 0x10000 + ((cp - 0xd800) << 10) + (units[++i] - 0xdc00);
        size_t next = append_cp(out, pos, cap > 8 ? cap - 8 : cap, cp);
        if (next == pos) { *truncated = 1; break; } pos = next;
    }
    if (quoted && pos + 1 < cap) {out[pos++] = '"'; out[pos] = 0;}
    if (*truncated && pos + 3 < cap) memcpy(out + pos, "...", 4);
    return 1;
}
static void copy_text(char *out, size_t cap, const char *in) {
    size_t n = strlen(in);
    if (!cap) return;
    if (n >= cap) {
        n = cap - 1;
        while (n && ((unsigned char)in[n] & 0xc0) == 0x80) --n;
    }
    memcpy(out, in, n); out[n] = 0;
}
static void append_display(struct xjs_value *out, const char *in) {
    size_t pos = strlen(out->display), cap = sizeof out->display;
    if (strlen(in) >= cap - pos) out->truncated = 1;
    copy_text(out->display + pos, cap - pos, in);
}
static int function_name(const struct xjs_layout *l, struct xjs_reader *r, uint64_t function,
                         char *out, size_t cap, uint64_t *shared) {
    struct head h;
    if (!head(l, r, function, &h)) return 0;
    if (h.type < field(l, r, XJS_FIRST_FUNCTION) || h.type > field(l, r, XJS_LAST_FUNCTION))
        return fail(r, "JavaScriptExpectedFunction");
    *shared = at(l, r, h.address, XJS_FUNCTION_SHARED, 8);
    if (!head(l, r, *shared, &h) || !is(l, h.type, XJS_TYPE_SHARED)) return fail(r, "JavaScriptInvalidSharedFunction");
    uint64_t name = at(l, r, h.address, XJS_SHARED_NAME, 8), total = 0; int cut = 0;
    if (!heap(name)) { copy_text(out, cap, "(anonymous)"); return r->error == NULL; }
    if (!head(l, r, name, &h)) return 0;
    if (h.type < field(l, r, XJS_FIRST_NONSTRING)) {
        if (!string(l, r, name, out, cap, &total, &cut, 0, NULL)) return 0;
        if (cut) return fail(r, "JavaScriptFunctionNameTruncated");
        if (!out[0]) copy_text(out, cap, "(anonymous)");
        return 1;
    }
    if (!is(l, h.type, XJS_TYPE_SCOPE)) return fail(r, "JavaScriptFunctionNameUnavailable");
    if (!supplement(l, r)) return 0;
    uint32_t flags = (uint32_t)word(r, h.address + XJS_V8_SCOPE_FLAGS, 4);
    if (flags & XJS_V8_SCOPE_EMPTY) return fail(r, "JavaScriptEmptyFunctionScope");
    int64_t locals = smi(r, word(r, h.address + 8 + (uint64_t)field(l, r, XJS_SCOPE_LOCALS) * 8, 8));
    if (locals < 0 || locals > 65536) return fail(r, "JavaScriptScopeLocalLimit");
    uint64_t index = (uint64_t)field(l, r, XJS_SCOPE_VARS);
    if ((flags & XJS_V8_SCOPE_TYPE_MASK) == XJS_V8_SCOPE_MODULE) ++index;
    index += (locals < XJS_V8_SCOPE_INLINE_NAMES ? (uint64_t)locals : 1) + (uint64_t)locals;
    if (flags & XJS_V8_SCOPE_SAVED_CLASS) ++index;
    out[0] = 0;
    if (((flags >> XJS_V8_SCOPE_FUNCTION_SHIFT) & XJS_V8_SCOPE_FUNCTION_MASK) != 0) {
        name = word(r, h.address + 8 + index * 8, 8); index += 2;
        if (heap(name) && !string(l, r, name, out, cap, &total, &cut, 0, NULL)) return 0;
    }
    if (!out[0] && (flags & XJS_V8_SCOPE_INFERRED)) {
        name = word(r, h.address + 8 + index * 8, 8);
        struct head inferred;
        if (heap(name) && head(l, r, name, &inferred) && inferred.type < field(l, r, XJS_FIRST_NONSTRING))
            if (!string(l, r, name, out, cap, &total, &cut, 0, NULL)) return 0;
    }
    if (!out[0]) copy_text(out, cap, "(anonymous)");
    if (cut) return fail(r, "JavaScriptFunctionNameTruncated");
    return r->error == NULL;
}
static void value(const struct xjs_layout *, struct xjs_reader *, uint64_t, struct xjs_value *, unsigned);
static void number_text(char *out, size_t cap, double d) {
    if (isnan(d)) copy_text(out, cap, "number NaN");
    else if (isinf(d)) copy_text(out, cap, signbit(d) ? "number -Infinity" : "number Infinity");
    else snprintf(out, cap, "number %.17g", d);
}
static void child_value(const struct xjs_layout *l, struct xjs_reader *r, uint64_t tagged, struct xjs_item *item, unsigned depth) {
    struct xjs_value child;
    if (r->error) return;
    value(l, r, tagged, &child, depth + 1);
    item->tagged = tagged; item->reason = child.reason;
    if (!item->reason && (child.truncated || strlen(child.display) >= sizeof item->display))
        item->reason = "JavaScriptPreviewTruncated";
    copy_text(item->type, sizeof item->type, child.type);
    copy_text(item->display, sizeof item->display, child.display);
    /* A corrupt/unsupported child does not erase proved siblings. Resource
     * exhaustion remains fatal and the counters are never reset. */
    if (r->error && strcmp(r->error, "JavaScriptReadBudget")) r->error = NULL;
}
static int array(const struct xjs_layout *l, struct xjs_reader *r, const struct head *h, struct xjs_value *out, unsigned depth) {
    if (!supplement(l, r)) return 0;
    int64_t n = smi(r, word(r, h->address + XJS_V8_ARRAY_LENGTH, 8));
    if (n < 0) return fail(r, "JavaScriptInvalidArrayLength");
    out->count = (uint64_t)n; strcpy(out->type, "Array");
    snprintf(out->display, sizeof out->display, "Array(%" PRId64 ") [", n);
    uint64_t elements = at(l, r, h->address, XJS_ELEMENTS, 8); struct head e;
    if (!head(l, r, elements, &e)) return 0;
    int doubles = is(l, e.type, XJS_TYPE_DOUBLE_ARRAY);
    if (!doubles && !is(l, e.type, XJS_TYPE_FIXED)) return fail(r, "JavaScriptArrayElementsUnsupported");
    int64_t capacity = smi(r, at(l, r, e.address, XJS_FIXED_LENGTH, 8));
    if (capacity < n) return fail(r, "JavaScriptArrayCapacityMismatch");
    out->truncated = n > XJS_PREVIEW_ITEMS;
    size_t count = n < XJS_PREVIEW_ITEMS ? (size_t)n : XJS_PREVIEW_ITEMS;
    for (size_t i = 0; i < count; ++i) {
        struct xjs_item *item = &out->items[out->item_count++];
        snprintf(item->key, sizeof item->key, "[%zu]", i);
        uint64_t element = word(r, e.address + (uint64_t)field(l, r, XJS_FIXED_DATA) + i * 8, 8);
        if (doubles) {
            double d; memcpy(&d, &element, 8);
            if (element == XJS_V8_DOUBLE_HOLE) {
                strcpy(item->type, "hole"); strcpy(item->display, "<hole>");
            } else if (element == XJS_V8_DOUBLE_UNDEFINED) {
                strcpy(item->type, "unavailable"); strcpy(item->display, "<unproved double element>");
                item->reason = "JavaScriptDoubleEncodingUnproved";
            } else {
                number_text(item->display, sizeof item->display, d);
                strcpy(item->type, "number");
            }
        } else child_value(l, r, element, item, depth);
        if (r->error) return 0;
        if (item->reason && !out->reason) out->reason = item->reason;
        if (i) append_display(out, ", ");
        append_display(out, item->display);
    }
    append_display(out, out->truncated ? ", ...]" : "]");
    return r->error == NULL;
}
static int object_value(const struct xjs_layout *l, struct xjs_reader *r, const struct head *h, struct xjs_value *out, unsigned depth) {
    uint64_t flags = at(l, r, h->map - 1, XJS_MAP_FLAGS, 4);
    if (flags & (UINT64_C(1) << shift(l, r, XJS_DICTIONARY_SHIFT))) return fail(r, "JavaScriptDictionaryPropertiesUnsupported");
    uint64_t count = (flags & (uint32_t)field(l, r, XJS_OWN_MASK)) >> shift(l, r, XJS_OWN_SHIFT);
    out->count = count; out->truncated = count > XJS_PREVIEW_ITEMS;
    copy_text(out->type, sizeof out->type, "Object");
    uint64_t root = h->map;
    uint64_t ctor = at(l, r, root - 1, XJS_MAP_CONSTRUCTOR, 8);
    out->reason = "JavaScriptConstructorNameUnproved";
    for (unsigned i = 0; heap(ctor) && i < 16; ++i) {
        struct head c; if (!head(l, r, ctor, &c)) return 0;
        if (is(l, c.type, XJS_TYPE_MAP)) {
            if (i == 15) return fail(r, "JavaScriptConstructorChainLimit");
            root = ctor;
            ctor = at(l, r, c.address, XJS_MAP_CONSTRUCTOR, 8); continue;
        }
        if (c.type >= field(l, r, XJS_FIRST_FUNCTION) && c.type <= field(l, r, XJS_LAST_FUNCTION)) {
            /* Map::constructor can be a base constructor for derived and
             * Reflect.construct receivers. Only its own initial-map tree
             * proves that this is the receiver's constructor name. */
            if (l->present[XJS_FUNCTION_INITIAL_MAP] && l->present[XJS_MAP_PROTOTYPE]) {
                uint64_t initial = at(l, r, c.address, XJS_FUNCTION_INITIAL_MAP, 8);
                struct head initial_head;
                if (!head(l, r, initial, &initial_head)) return 0;
                if (is(l, initial_head.type, XJS_TYPE_MAP) &&
                    at(l, r, h->map - 1, XJS_MAP_PROTOTYPE, 8) ==
                    at(l, r, initial - 1, XJS_MAP_PROTOTYPE, 8)) {
                    uint64_t shared; char name[sizeof out->type];
                    if (!function_name(l, r, ctor, name, sizeof name, &shared)) return 0;
                    /* Literal maps are copies of Object's initial map. The
                     * generic Object name is also valid for those copies
                     * when their constructor and prototype still agree. */
                    if (initial == root || (!strcmp(name, "Object") &&
                        at(l, r, initial - 1, XJS_MAP_CONSTRUCTOR, 8) == ctor)) {
                        copy_text(out->type, sizeof out->type, name);
                        out->reason = NULL;
                    }
                }
            }
        }
        break;
    }
    copy_text(out->display, sizeof out->display, out->type); append_display(out, " {");
    if (!count) { append_display(out, "}"); return r->error == NULL; }
    uint64_t descriptors = at(l, r, h->map - 1, XJS_MAP_DESCRIPTORS, 8); struct head d;
    if (!head(l, r, descriptors, &d) || (!is(l, d.type, XJS_TYPE_DESCRIPTORS) && !is(l, d.type, XJS_TYPE_STRONG_DESCRIPTORS)))
        return fail(r, "JavaScriptInvalidDescriptors");
    uint64_t start = at(l, r, h->map - 1, XJS_MAP_INOBJECT, 1), size = at(l, r, h->map - 1, XJS_MAP_SIZE, 1);
    if (start > size) return fail(r, "JavaScriptInvalidObjectSize");
    size_t retain = count < XJS_PREVIEW_ITEMS ? (size_t)count : XJS_PREVIEW_ITEMS;
    for (size_t i = 0; i < retain; ++i) {
        struct xjs_item *item = &out->items[out->item_count++];
        uint64_t base = d.address + (uint64_t)field(l, r, XJS_DESC_DATA) + i * (uint64_t)field(l, r, XJS_DESC_SIZE) * 8;
        uint64_t key = word(r, base + (uint64_t)field(l, r, XJS_DESC_KEY) * 8, 8), total = 0; int cut = 0;
        if (!string(l, r, key, item->key, sizeof item->key, &total, &cut, 0, NULL)) return 0;
        uint64_t details = (uint64_t)smi(r, word(r, base + (uint64_t)field(l, r, XJS_DESC_DETAILS) * 8, 8));
        if ((details & (uint32_t)field(l, r, XJS_PROP_KIND_MASK)) != (uint64_t)field(l, r, XJS_PROP_DATA)) {
            strcpy(item->type, "accessor"); strcpy(item->display, "<accessor; not invoked>");
        } else if (((details & (uint32_t)field(l, r, XJS_PROP_LOCATION_MASK)) >> shift(l, r, XJS_PROP_LOCATION_SHIFT)) != (uint64_t)field(l, r, XJS_PROP_FIELD)) {
            child_value(l, r, word(r, base + (uint64_t)field(l, r, XJS_DESC_VALUE) * 8, 8), item, depth);
        } else {
            uint64_t index = (details & (uint32_t)field(l, r, XJS_PROP_INDEX_MASK)) >> shift(l, r, XJS_PROP_INDEX_SHIFT);
            if (index >= size - start) { item->reason = "JavaScriptOutOfObjectFieldUnsupported"; strcpy(item->display, "<out-of-object field unavailable>"); }
            else if (((details & (uint32_t)field(l, r, XJS_PROP_REPR_MASK)) >> shift(l, r, XJS_PROP_REPR_SHIFT)) == (uint64_t)field(l, r, XJS_PROP_DOUBLE)) {
                item->reason = "JavaScriptDoubleFieldUnsupported"; strcpy(item->display, "<double field unavailable>");
            } else child_value(l, r, word(r, h->address + (start + index) * 8, 8), item, depth);
        }
        if (r->error) return 0;
        if (item->reason && !out->reason) out->reason = item->reason;
        if (i) append_display(out, ", ");
        append_display(out, item->key); append_display(out, ": "); append_display(out, item->display);
    }
    append_display(out, out->truncated ? ", ...}" : "}");
    return r->error == NULL;
}
static void value(const struct xjs_layout *l, struct xjs_reader *r, uint64_t tagged, struct xjs_value *out, unsigned depth) {
    memset(out, 0, sizeof *out); out->tagged = tagged;
    if (!(tagged & 1)) {
        int64_t v = smi(r, tagged);
        if (!r->error) { strcpy(out->type, "smi"); snprintf(out->display, sizeof out->display, "smi %" PRId64, v); return; }
    } else {
        struct head h;
        if (head(l, r, tagged, &h)) {
            out->map = h.map; out->instance_type = h.type;
            if (h.type < field(l, r, XJS_FIRST_NONSTRING)) {
                strcpy(out->type, "string"); strcpy(out->display, "string ");
                if (string(l, r, tagged, out->display + 7, sizeof out->display - 7, &out->count, &out->truncated, 1, &out->reason)) return;
            } else if (is(l, h.type, XJS_TYPE_NUMBER)) {
                uint64_t bits = at(l, r, h.address, XJS_NUMBER, 8); double value; memcpy(&value, &bits, 8);
                if (!r->error) { strcpy(out->type, "number"); number_text(out->display, sizeof out->display, value); return; }
            } else if (is(l, h.type, XJS_TYPE_ODDBALL)) {
                int64_t kind = smi(r, at(l, r, h.address, XJS_ODDBALL_KIND, 8));
                const char *name = kind == field(l, r, XJS_FALSE) ? "false" : kind == field(l, r, XJS_TRUE) ? "true" :
                    kind == field(l, r, XJS_NULL) ? "null" : kind == field(l, r, XJS_UNDEFINED) ? "undefined" : NULL;
                if (!r->error && name) { strcpy(out->type, name); strcpy(out->display, name); return; }
                fail(r, "JavaScriptOddballUnsupported");
            } else if (is(l, h.type, XJS_TYPE_FREE) || is(l, h.type, XJS_TYPE_FILLER)) {
                fail(r, "JavaScriptFreedOrFillerObject");
            } else if (h.type >= field(l, r, XJS_FIRST_FUNCTION) && h.type <= field(l, r, XJS_LAST_FUNCTION)) {
                uint64_t shared; char name[256];
                if (function_name(l, r, tagged, name, sizeof name, &shared)) {
                    strcpy(out->type, "function"); snprintf(out->display, sizeof out->display, "function %s", name); return;
                }
            } else if (depth >= 3) {
                out->reason = "JavaScriptPreviewDepthLimit"; strcpy(out->type, "object"); strcpy(out->display, "<object; preview depth limit>"); return;
            } else if (is(l, h.type, XJS_TYPE_ARRAY)) {
                if (array(l, r, &h, out, depth)) return;
            } else if (is(l, h.type, XJS_TYPE_OBJECT)) {
                if (object_value(l, r, &h, out, depth)) return;
            } else fail(r, "JavaScriptObjectLayoutUnavailable");
        }
    }
    out->reason = r->error ? r->error : "JavaScriptValueUnavailable";
    strcpy(out->type, "unavailable"); snprintf(out->display, sizeof out->display, "unavailable (%s)", out->reason);
}
void xjs_value_read(const struct xjs_layout *l, struct xjs_reader *r, uint64_t tagged, struct xjs_value *out) {
    value(l, r, tagged, out, 0);
    out->version_table = r->version_table;
}

/* The stock Node 26.8.2 image whose build configuration was independently
 * checked with its public headers and cooperating fixtures. Version alone
 * cannot select TSAN/WASM-dependent builtin ids or dispatch-table limits.
 * Other builds can still use metadata-backed values; frame positions refuse
 * until their same-image layout/configuration has been established. */
static int frame_config(const struct xjs_layout *l) {
    static const uint8_t id[] = {0x93,0xf8,0x2a,0xf1,0xea,0xc2,0x4f,0xf5,0x12,0x35,
        0x95,0xe6,0x66,0x95,0x72,0xc9,0x34,0x21,0xc4,0x36};
    return l->dwarf_frame_config || (l->build_id_len == sizeof id && !memcmp(l->build_id, id, sizeof id));
}
static int leb(const uint8_t *bytes, size_t length, size_t *at, uint64_t *out) {
    *out = 0;
    for (unsigned bits = 0; bits < 64; bits += 7) {
        if (*at >= length) return 0;
        unsigned b = bytes[(*at)++];
        if (bits == 63 && (b & 126)) return 0;
        *out |= (uint64_t)(b & 127) << bits;
        if (!(b & 128)) return 1;
    }
    return 0;
}
static int source_offset(const struct xjs_layout *l, struct xjs_reader *r, uint64_t table,
                         uint64_t code_offset, uint32_t *position) {
    struct head h;
    if (!head(l, r, table, &h) || !is(l, h.type, XJS_TYPE_TRUSTED_BYTES))
        return fail(r, "JavaScriptSourceTableUnavailable");
    int64_t n = smi(r, word(r, h.address + XJS_V8_POSITION_LENGTH, 8));
    uint8_t bytes[16384];
    if (n < 0 || (uint64_t)n > sizeof bytes) return fail(r, "JavaScriptSourceTableLimit");
    if (!n) return fail(r, "JavaScriptSourceTableEmpty");
    if (!read_bytes(r, h.address + XJS_V8_POSITION_DATA, bytes, (size_t)n)) return 0;
    size_t at = 0; int64_t offset = -1, source = 0, selected = -1;
    while (at < (size_t)n) {
        uint64_t delta, encoded;
        if (!leb(bytes, (size_t)n, &at, &delta) || delta > INT32_MAX ||
            !leb(bytes, (size_t)n, &at, &encoded)) return fail(r, "JavaScriptSourceTableMalformed");
        offset += (int64_t)(delta >> XJS_V8_POSITION_CODE_SHIFT);
        if (offset > INT32_MAX) return fail(r, "JavaScriptSourceTableMalformed");
        int64_t change = (int64_t)(encoded >> 1);
        if (encoded & 1) change = -change - 1;
        if (change < -source || (change > 0 && source > INT64_MAX - change))
            return fail(r, "JavaScriptSourceTableMalformed");
        source += change;
        if (source < 0 || (uint64_t)source >> 47) return fail(r, "JavaScriptSourceTableMalformed");
        if (offset >= 0 && (uint64_t)offset <= code_offset) selected = source;
    }
    if (selected < 0) return fail(r, "JavaScriptSourcePositionUnavailable");
    if (selected & 1) return fail(r, "JavaScriptExternalSourcePositionUnsupported");
    if (((uint64_t)selected >> XJS_V8_POSITION_INLINE_SHIFT) & 65535)
        return fail(r, "JavaScriptInlinedSourcePositionUnresolved");
    uint32_t biased = ((uint64_t)selected >> 1) & XJS_V8_POSITION_SCRIPT_MASK;
    if (!biased) return fail(r, "JavaScriptSourcePositionUnavailable");
    *position = biased - 1; return 1;
}
static int script_position(const struct xjs_layout *l, struct xjs_reader *r,
                           uint64_t script, uint32_t position, struct xjs_frame *out) {
    uint64_t source = at(l, r, script - 1, XJS_SCRIPT_SOURCE, 8);
    struct head h; uint32_t length;
    if (!string_head(l, r, source, &h, &length)) return 0;
    if (position > length) return fail(r, "JavaScriptSourcePositionRange");
    if (position > 262144) return fail(r, "JavaScriptSourceScanLimit");
    int64_t line_offset = smi(r, word(r, script - 1 + XJS_V8_SCRIPT_LINE, 8));
    int64_t column_offset = smi(r, word(r, script - 1 + XJS_V8_SCRIPT_COLUMN, 8));
    if (line_offset < 0 || column_offset < 0 || line_offset > INT32_MAX / 2 || column_offset > INT32_MAX / 2)
        return fail(r, "JavaScriptScriptOriginUnsupported");
    uint32_t line = 0, column = 0; int previous_cr = 0;
    for (uint32_t i = 0; i < position;) {
        uint16_t units[XJS_STRING_UNITS];
        size_t n = position - i; if (n > XJS_STRING_UNITS) n = XJS_STRING_UNITS;
        if (!string_units(l, r, source, i, n, units, 0)) return 0;
        for (size_t j = 0; j < n; ++j) {
            uint16_t cp = units[j];
            if (previous_cr && cp != '\n') { ++line; column = 0; }
            if (cp == '\n' || cp == 0x2028 || cp == 0x2029) { ++line; column = 0; }
            else ++column;
            previous_cr = cp == '\r';
        }
        i += (uint32_t)n;
    }
    if (previous_cr) {
        uint16_t next = 0;
        if (position < length && !string_units(l, r, source, position, 1, &next, 0)) return 0;
        /* In CRLF the line ends at LF, including when the queried position
         * is exactly that LF. A lone CR ends the preceding line. */
        if (next != '\n') { ++line; column = 0; }
    }
    out->line = (int32_t)(line + line_offset + 1);
    out->column = (int32_t)(column + (line == 0 ? column_offset : 0) + 1);
    return r->error == NULL;
}
static int frame_code(const struct xjs_layout *l, struct xjs_reader *r, uint64_t root,
                      struct xjs_frame *out, unsigned *kind) {
    if (!frame_config(l)) return fail(r, "JavaScriptFrameConfigUnavailable");
    if (root < 4096 + XJS_V8_ROOT_BIAS || root & 7) return fail(r, "JavaScriptRootRegisterUnavailable");
    uint64_t table = word(r, root - XJS_V8_ROOT_BIAS + XJS_V8_DISPATCH_TABLE, 8);
    uint64_t handle = word(r, out->function - 1 + XJS_V8_FUNCTION_DISPATCH, 4);
    if (!handle || (handle & ((1u << XJS_V8_DISPATCH_SHIFT) - 1)) || table & 15)
        return fail(r, "JavaScriptDispatchHandleInvalid");
    uint64_t index = handle >> XJS_V8_DISPATCH_SHIFT;
    if (table > UINT64_MAX - index * XJS_V8_DISPATCH_ENTRY - 8) return fail(r, "JavaScriptInvalidAddress");
    uint64_t encoded = word(r, table + index * XJS_V8_DISPATCH_ENTRY + 8, 8);
    if ((encoded >> 48) == 65535) return fail(r, "JavaScriptDispatchEntryFreed");
    out->code = (encoded >> XJS_V8_DISPATCH_CODE_SHIFT) | 1;
    struct head h;
    if (!head(l, r, out->code, &h) || !is(l, h.type, XJS_TYPE_CODE)) return fail(r, "JavaScriptCodeIdentityUnavailable");
    uint64_t start = at(l, r, h.address, XJS_CODE_START, 8), size = at(l, r, h.address, XJS_CODE_SIZE, 4);
    if (!start || !size || size > 64 * 1024 * 1024 || out->pc <= start || out->pc - start > size)
        return fail(r, "JavaScriptActiveCodeChanged");
    uint64_t flags = at(l, r, h.address, XJS_CODE_FLAGS, 4);
    *kind = (unsigned)((flags & (uint32_t)field(l, r, XJS_CODE_KIND_MASK)) >> shift(l, r, XJS_CODE_KIND_SHIFT));
    return r->error == NULL;
}
static int frame_position(const struct xjs_layout *l, struct xjs_reader *r, uint64_t root,
                          uint64_t script, struct xjs_frame *out) {
    if (!supplement(l, r)) return 0;
    unsigned kind;
    if (!frame_code(l, r, root, out, &kind)) return 0;
    uint64_t table, offset;
    if (kind == XJS_V8_KIND_BUILTIN) {
        if (word(r, out->code - 1 + XJS_V8_CODE_BUILTIN_ID, 2) != XJS_V8_INTERPRETER_BUILTIN)
            return fail(r, "JavaScriptBuiltinFrameUnsupported");
        strcpy(out->kind, "interpreted");
        uint64_t bytecode = word(r, out->fp - 32, 8); struct head b;
        if (!head(l, r, bytecode, &b) || !is(l, b.type, XJS_TYPE_BYTECODE))
            return fail(r, "JavaScriptBytecodeUnavailable");
        uint64_t function_data = word(r, out->shared - 1 + XJS_V8_SHARED_DATA, 8);
        if (function_data != bytecode) return fail(r, "JavaScriptBytecodeIdentityMismatch");
        int64_t length = smi(r, at(l, r, b.address, XJS_BYTECODE_LENGTH, 8));
        int64_t raw_offset = smi(r, word(r, out->fp - 40, 8)) - field(l, r, XJS_BYTECODE_DATA) + 1;
        if (raw_offset < 0 || raw_offset >= length) return fail(r, "JavaScriptBytecodeOffsetInvalid");
        offset = (uint64_t)raw_offset;
        table = word(r, b.address + XJS_V8_BYTECODE_POSITIONS, 8);
    } else if (kind == XJS_V8_KIND_MAGLEV || kind == XJS_V8_KIND_TURBOFAN) {
        strcpy(out->kind, kind == XJS_V8_KIND_MAGLEV ? "maglev" : "turbofan");
        offset = out->pc - at(l, r, out->code - 1, XJS_CODE_START, 8) - 1;
        table = word(r, out->code - 1 + XJS_V8_CODE_POSITIONS, 8);
    } else {
        if (kind == (unsigned)field(l, r, XJS_CODE_BASELINE)) strcpy(out->kind, "baseline");
        return fail(r, "JavaScriptCodePositionUnsupported");
    }
    uint32_t position;
    return source_offset(l, r, table, offset, &position) && script_position(l, r, script, position, out);
}
void xjs_stack_read(const struct xjs_layout *l, struct xjs_reader *r, uint64_t fp,
                    uint64_t pc, uint64_t root, uint64_t lo, uint64_t hi, struct xjs_stack *out) {
    memset(out, 0, sizeof *out);
    if (!supplement(l, r)) { out->reason = r->error; return; }
    if (field(l, r, XJS_FP_CONTEXT) != -8 || field(l, r, XJS_FP_FUNCTION) != -16 ||
        field(l, r, XJS_FP_BYTECODE) != -32 || field(l, r, XJS_FP_BYTECODE_OFFSET) != -40 ||
        field(l, r, XJS_FP_ARGS) != 16) { out->reason = "JavaScriptFrameMetadataMismatch"; return; }
    for (unsigned visited = 0; visited < 256; ++visited) {
        if (lo > hi || hi - lo < 64 || fp < lo + 48 || fp > hi - 16 || fp & 7) {
            out->reason = "JavaScriptStackRangeInvalid"; break;
        }
        uint64_t marker = word(r, fp - 8, 8);
        if (!visited && marker != (uint64_t)field(l, r, XJS_FRAME_API_EXIT) * 2) {
            out->reason = "JavaScriptNativeAnchorUnavailable"; break;
        }
        if (visited && !(marker & 1)) {
            if (marker == (uint64_t)field(l, r, XJS_FRAME_ENTRY) * 2 ||
                marker == (uint64_t)field(l, r, XJS_FRAME_CONSTRUCT_ENTRY) * 2) {
                out->reason = "JavaScriptEntryBoundary"; break;
            }
            if (marker != (uint64_t)field(l, r, XJS_FRAME_INTERNAL) * 2 &&
                marker != (uint64_t)field(l, r, XJS_FRAME_CONSTRUCT) * 2 &&
                marker != (uint64_t)field(l, r, XJS_FRAME_FAST_CONSTRUCT) * 2) {
                out->reason = "JavaScriptFrameMarkerUnsupported"; break;
            }
        } else if (visited) {
            if (out->count == XJS_STACK_FRAMES) { out->reason = "JavaScriptFrameLimit"; break; }
            struct head context;
            if (!head(l, r, marker, &context) || context.type < field(l, r, XJS_FIRST_CONTEXT) ||
                context.type > field(l, r, XJS_LAST_CONTEXT)) { out->reason = "JavaScriptFrameContextInvalid"; break; }
            struct xjs_frame *f = &out->frames[out->count];
            f->fp = fp; f->pc = pc; f->function = word(r, fp - 16, 8);
            strcpy(f->kind, "javascript");
            if (!function_name(l, r, f->function, f->name, sizeof f->name, &f->shared)) { out->reason = r->error; break; }
            ++out->count;
            uint64_t script = at(l, r, f->shared - 1, XJS_SHARED_SCRIPT, 8); struct head s;
            if (!head(l, r, script, &s) || !is(l, s.type, XJS_TYPE_SCRIPT)) fail(r, "JavaScriptScriptUnavailable");
            uint64_t name = at(l, r, script - 1, XJS_SCRIPT_NAME, 8), length = 0; int cut = 0;
            struct head named;
            if (!r->error && heap(name) && head(l, r, name, &named) && named.type < field(l, r, XJS_FIRST_NONSTRING)) {
                if (!string(l, r, name, f->file, sizeof f->file, &length, &cut, 0, NULL)) f->file[0] = 0;
            }
            if (!r->error && !f->file[0]) f->reason = "JavaScriptScriptNameUnavailable";
            if (cut) fail(r, "JavaScriptScriptNameTruncated");
            if (!r->error) frame_position(l, r, root, script, f);
            if (r->error) {
                f->reason = r->error; f->line = f->column = 0;
                if (!out->reason) out->reason = f->reason;
                /* A missing position does not erase an independently proved
                 * function or the next standard frame-pointer link. Budgets
                 * persist across this local diagnostic. */
                r->error = NULL;
            }
        }
        uint64_t next = word(r, fp, 8), return_pc = word(r, fp + 8, 8);
        if (r->error) { out->reason = r->error; break; }
        if (next <= fp || next - fp > 1024 * 1024) { out->reason = "JavaScriptStackLinkInvalid"; break; }
        fp = next; pc = return_pc;
        if (visited == 255) out->reason = "JavaScriptStackWalkLimit";
    }
    out->version_table = r->version_table;
    if (r->error) out->reason = r->error;
}
