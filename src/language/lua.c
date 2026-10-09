#include "lua.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail(struct xl_reader *r, const char *why) {
    if (!r->error) r->error = why;
    return 0;
}
static uint64_t add(struct xl_reader *r, uint64_t base, uint64_t offset) {
    if (!base || base > UINT64_MAX - offset) { fail(r, "LuaAddressInvalid"); return 0; }
    return base + offset;
}
static int read_bytes(struct xl_reader *r, uint64_t at, void *out, size_t n) {
    if (r->error) return 0;
    if (!n) return 1;
    if (!at || at > UINT64_MAX - n) return fail(r, "LuaAddressInvalid");
    if (r->reads >= XL_READ_LIMIT || n > XL_BYTE_LIMIT || r->bytes > XL_BYTE_LIMIT - n) return fail(r, "LuaReadBudget");
    ++r->reads; r->bytes += n;
    if (!r->read || r->read(r->context, at, out, n)) return fail(r, "LuaMemoryUnavailable");
    return 1;
}
static uint64_t word(struct xl_reader *r, uint64_t at, size_t n) {
    unsigned char b[8]; uint64_t v = 0;
    if (!n || n > sizeof b) { fail(r, "LuaLayoutUnsupported"); return 0; }
    if (!read_bytes(r, at, b, n)) return 0;
    for (size_t i = 0; i < n; ++i) v |= (uint64_t)b[i] << (i * 8);
    return v;
}
static uint64_t field(const struct xl_layout *p, struct xl_reader *r, uint64_t at, enum xl_field f) {
    return word(r, add(r, at, p->fields[f].offset), p->fields[f].size);
}
static int header(const struct xl_layout *p, struct xl_reader *r, uint64_t at, unsigned tag) {
    if (!at || at & 7) return fail(r, "LuaObjectAddressInvalid");
    uint64_t got = field(p, r, at, XL_GC_TAG);
    if (r->error) return 0;
    if (got != tag) return fail(r, "LuaObjectTagMismatch");
    return 1;
}
static void copy(char *dst, size_t n, const char *src) {
    if (!n) return;
    size_t length = strlen(src), count = length < n ? length : n - 1;
    memcpy(dst, src, count); dst[count] = 0;
    if (length >= n && n > 4) memcpy(dst + n - 4, "...", 3);
}
/* Escaping every non-ASCII byte preserves arbitrary Lua byte strings without
 * guessing an encoding. Output is always terminated, including truncation. */
static void escape(char *out, size_t cap, const unsigned char *s, size_t n) {
    size_t k = 0;
    for (size_t i = 0; i < n; ++i) {
        unsigned c = s[i];
        if (c >= 32 && c < 127 && c != '\\' && c != '"') {
            if (k + 1 >= cap) break;
            out[k++] = (char)c;
        } else {
            if (k + 4 >= cap) break;
            snprintf(out + k, cap - k, "\\x%02x", c); k += 4;
        }
    }
    if (cap) out[k] = 0;
}
static int string_extent(const struct xl_layout *p, struct xl_reader *r, uint64_t at,
                         uint64_t *size, uint64_t *data) {
    unsigned tag = (unsigned)field(p, r, at, XL_GC_TAG);
    if (r->error) return 0;
    if ((tag != 4 && tag != 20) || !header(p, r, at, tag)) return fail(r, "LuaStringInvalid");
    uint64_t n, offset;
    if (p->version[1] == 4) {
        unsigned shortlen = (unsigned)field(p, r, at, XL_STR_SHORT);
        if ((tag == 4 && shortlen == 255) || (tag == 20 && shortlen != 255)) return fail(r, "LuaStringInvalid");
        n = tag == 4 ? shortlen : field(p, r, at, XL_STR_LEN);
        offset = p->fields[XL_STR_DATA].offset;
    } else {
        n = field(p, r, at, XL_STR_LEN); offset = p->sizes[XL_T_STRING];
    }
    // These profiles support x86-64 Linux. Even five-level paging has only
    // 56 positive user-address bits. Include the allocation header and NUL;
    // a plausible extent still does not prove the actual allocation's size.
    const uint64_t user_end = UINT64_C(1) << 56;
    if (r->error || offset >= INT64_MAX || n >= INT64_MAX - offset ||
        at >= user_end || offset >= user_end - at || n >= user_end - at - offset)
        return fail(r, "LuaStringLengthInvalid");
    *size = n; *data = add(r, at, offset); return !r->error;
}
static int string(const struct xl_layout *p, struct xl_reader *r, uint64_t at, char *out, size_t cap,
                  uint64_t *length, int *truncated) {
    uint64_t n, data;
    if (!string_extent(p, r, at, &n, &data)) return 0;
    unsigned char bytes[XL_STRING_BYTES]; size_t count = n > sizeof bytes ? sizeof bytes : (size_t)n;
    if (!read_bytes(r, data, bytes, count)) return 0;
    escape(out, cap, bytes, count); *length = n; *truncated = n > count;
    return 1;
}
static int nil(unsigned tag, unsigned version) { return tag == 0 || (version == 4 && (tag == 16 || tag == 32)); }
static void decode(const struct xl_layout *, struct xl_reader *, uint64_t, unsigned, struct xl_value *, unsigned);
static void value(const struct xl_layout *p, struct xl_reader *r, uint64_t at, struct xl_value *out, unsigned depth) {
    memset(out, 0, sizeof *out); out->address = at;
    uint64_t tag = field(p, r, at, XL_TAG);
    /* nil and tagged booleans need not have initialized payload bits. */
    uint64_t bits = 0;
    if (!nil((unsigned)tag, p->version[1]) && !(p->version[1] == 4 && (tag == 1 || tag == 17)))
        bits = field(p, r, at, XL_BITS);
    if (!r->error) decode(p, r, bits, (unsigned)tag, out, depth);
    if (r->error) { out->reason = r->error; out->advisory = 0; }
}
static void child(const struct xl_layout *p, struct xl_reader *r, uint64_t at, struct xl_item *out, unsigned depth) {
    struct xl_value v; value(p, r, at, &v, depth);
    out->address = at; copy(out->type, sizeof out->type, v.type); copy(out->display, sizeof out->display, v.display);
    out->reason = v.reason; out->advisory = v.advisory;
    if (r->error && strcmp(r->error, "LuaReadBudget")) r->error = NULL;
}
static void table(const struct xl_layout *p, struct xl_reader *r, uint64_t at, struct xl_value *out, unsigned depth) {
    uint64_t a = field(p, r, at, XL_TABLE_SIZE), log = field(p, r, at, XL_TABLE_LOG);
    uint64_t flags = field(p, r, at, XL_TABLE_FLAGS), arr = field(p, r, at, XL_TABLE_ARRAY);
    uint64_t nodes = field(p, r, at, XL_TABLE_NODE), free_node = field(p, r, at, XL_TABLE_FREE);
    if (r->error) return;
    if (a > INT32_MAX || log > 30 || !nodes || (a && !arr)) { fail(r, "LuaTableInvalid"); return; }
    if (p->version[1] == 4 && (flags & 128) && a) {
        uint64_t rounded = 1; while (rounded < a) rounded <<= 1;
        a = rounded;
    }
    uint64_t h = p->version[1] == 4 && !free_node ? 0 : UINT64_C(1) << log;
    /* 5.2's shared dummy node is included in the reported slot capacity; it
     * always contains nil. Occupied counts are only for inspected slots. */
    out->array_capacity = a; out->hash_capacity = h;
    copy(out->type, sizeof out->type, "table");
    snprintf(out->display, sizeof out->display, "table (%" PRIu64 " array slots, %" PRIu64 " hash slots)", a, h);
    if (depth >= 1) {
        out->truncated = a || h;
        if (out->truncated) { out->reason = "LuaTableExtentUnproved"; out->advisory = 1; }
        return;
    }
    uint64_t scanned = 0;
    for (uint64_t i = 0; i < a && scanned < 128 && out->item_count < XL_PREVIEW_ITEMS; ++i, ++scanned) {
        uint64_t slot = add(r, arr, i * p->sizes[XL_T_TVALUE]);
        unsigned tag = (unsigned)field(p, r, slot, XL_TAG);
        if (r->error) return;
        if (nil(tag, p->version[1])) continue;
        struct xl_item *item = &out->items[out->item_count++]; ++out->count;
        snprintf(item->key, sizeof item->key, "[%" PRIu64 "]", i + 1);
        child(p, r, slot, item, depth + 1);
        if (r->error) return;
    }
    uint64_t hs = 0;
    for (uint64_t i = 0; i < h && scanned + hs < 128 && out->item_count < XL_PREVIEW_ITEMS; ++i, ++hs) {
        uint64_t node = add(r, nodes, i * p->sizes[XL_T_NODE]);
        uint64_t slot = add(r, node, p->fields[XL_NODE_VALUE].offset);
        unsigned tag = (unsigned)field(p, r, slot, XL_TAG);
        if (r->error) return;
        if (nil(tag, p->version[1])) continue;
        unsigned kt = (unsigned)field(p, r, node, XL_NODE_KEY_TAG);
        uint64_t kb = field(p, r, node, XL_NODE_KEY_BITS);
        struct xl_value key = {0}; decode(p, r, kb, kt, &key, depth + 1);
        struct xl_item *item = &out->items[out->item_count++]; ++out->count;
        if (r->error) { item->reason = r->error; copy(item->key, sizeof item->key, "<key unavailable>"); }
        else copy(item->key, sizeof item->key, key.display);
        if (r->error && strcmp(r->error, "LuaReadBudget")) r->error = NULL;
        const char *key_error = item->reason ? item->reason : key.reason;
        const int key_advisory = item->reason ? 0 : key.advisory;
        child(p, r, slot, item, depth + 1);
        if (key_error && (!item->reason || (!key_advisory && item->advisory))) {
            item->reason = key_error; item->advisory = key_advisory;
        }
        if (r->error) return;
    }
    out->truncated = scanned < a || hs < h;
    if (out->truncated) { out->reason = "LuaTableExtentUnproved"; out->advisory = 1; }
    if (out->item_count) {
        copy(out->display, sizeof out->display, "table");
        size_t used = strlen(out->display);
        for (size_t i = 0; i < out->item_count && i < 4; ++i) {
            const struct xl_item *item = &out->items[i];
            const char *key = item->key, *shown = item->reason && !item->advisory ? item->reason : item->display;
            if (!strncmp(key, "string ", 7)) key += 7;
            if (!item->reason || item->advisory) {
                if (!strncmp(shown, "integer ", 8)) shown += 8;
                else if (!strncmp(shown, "number ", 7) || !strncmp(shown, "string ", 7)) shown += 7;
            }
            int n = snprintf(out->display + used, sizeof out->display - used, "%s%s: %s",
                             i ? ", " : " {", key, shown);
            if (n < 0 || (size_t)n >= sizeof out->display - used) {
                memcpy(out->display + sizeof out->display - 4, "...", 4); out->truncated = 1; return;
            }
            used += (size_t)n;
        }
        copy(out->display + used, sizeof out->display - used, out->item_count > 4 || out->truncated ? ", ...}" : "}");
    }
}
static void function(const struct xl_layout *p, struct xl_reader *r, uint64_t at, struct xl_value *out, unsigned depth) {
    uint64_t proto = field(p, r, at, XL_LC_PROTO);
    if (!header(p, r, proto, p->version[1] == 4 ? 10 : 9)) return;
    uint64_t source = field(p, r, proto, XL_PROTO_SOURCE);
    int32_t line = (int32_t)field(p, r, proto, XL_PROTO_LINE);
    uint64_t nup = field(p, r, at, XL_LC_NUP), pnup = field(p, r, proto, XL_PROTO_NUP);
    uint64_t names = field(p, r, proto, XL_PROTO_UP);
    if (r->error) return;
    if (nup != pnup || nup > 255 || line < 0 || (nup && !names)) { fail(r, "LuaFunctionInvalid"); return; }
    char file[544] = "<source unavailable>"; uint64_t n; int truncated = 0;
    if (source && !string(p, r, source, file, sizeof file, &n, &truncated)) return;
    snprintf(out->display, sizeof out->display, "function <%s:%" PRId32 ">%s", file, line, truncated ? "..." : "");
    out->count = nup;
    if (depth >= 1) { out->truncated = nup != 0; return; }
    for (uint64_t i = 0; i < nup && i < XL_PREVIEW_ITEMS; ++i) {
        struct xl_item *item = &out->items[out->item_count++];
        uint64_t uv = word(r, add(r, at, p->fields[XL_LC_UP].offset + i * 8), 8);
        if (!header(p, r, uv, p->version[1] == 4 ? 9 : 10)) {
            item->reason = r->error;
            if (r->error && !strcmp(r->error, "LuaReadBudget")) return;
            r->error = NULL;
            snprintf(item->key, sizeof item->key, "upvalue[%" PRIu64 "]", i + 1);
            continue;
        }
        uint64_t slot = field(p, r, uv, XL_UP_VALUE);
        uint64_t name = field(p, r, add(r, names, i * p->sizes[XL_T_UPDESC]), XL_UP_NAME);
        snprintf(item->key, sizeof item->key, "upvalue[%" PRIu64 "]", i + 1);
        if (name) {
            char full[544];
            if (string(p, r, name, full, sizeof full, &n, &truncated)) copy(item->key, sizeof item->key, full);
        }
        child(p, r, slot, item, depth + 1);
        if (r->error) return;
    }
    out->truncated = nup > XL_PREVIEW_ITEMS;
}
static void decode(const struct xl_layout *p, struct xl_reader *r, uint64_t bits, unsigned tag, struct xl_value *out, unsigned depth) {
    unsigned version = p->version[1]; out->tag = tag;
    if (nil(tag, version)) { copy(out->type, sizeof out->type, "nil"); copy(out->display, sizeof out->display, "nil"); return; }
    if (tag == 1 || (version == 4 && tag == 17)) {
        if (version == 2 && (uint32_t)bits > 1) { fail(r, "LuaBooleanInvalid"); return; }
        copy(out->type, sizeof out->type, "boolean");
        copy(out->display, sizeof out->display, (version == 4 ? tag == 17 : (uint32_t)bits != 0) ? "true" : "false"); return;
    }
    if (tag == 3 || (version == 4 && tag == 19)) {
        if (version == 4 && tag == 3) {
            copy(out->type, sizeof out->type, "integer"); snprintf(out->display, sizeof out->display, "integer %" PRId64, (int64_t)bits);
        } else {
            double v; memcpy(&v, &bits, sizeof v);
            copy(out->type, sizeof out->type, "number"); snprintf(out->display, sizeof out->display, "number %.17g", v);
        }
        return;
    }
    if (tag == 2 || tag == 22) {
        copy(out->type, sizeof out->type, tag == 2 ? "lightuserdata" : "C function");
        snprintf(out->display, sizeof out->display, "%s 0x%" PRIx64, out->type, bits); out->object = bits; return;
    }
    if (tag != 68 && tag != 84 && tag != 69 && tag != 70 && tag != 102 && tag != 71 && tag != 72) {
        fail(r, tag == 11 ? "LuaDeadKey" : "LuaTagUnsupported"); return;
    }
    if (!header(p, r, bits, tag & 63)) return;
    out->object = bits;
    switch (tag) {
    case 68: case 84: {
        char text[XL_STRING_BYTES * 4 + 1]; uint64_t length; int truncated;
        if (!string(p, r, bits, text, sizeof text, &length, &truncated)) return;
        copy(out->type, sizeof out->type, "string"); out->count = length; out->truncated = truncated;
        if (truncated) { out->reason = "LuaStringExtentUnproved"; out->advisory = 1; }
        snprintf(out->display, sizeof out->display, "string \"%s\"%s", text, truncated ? "..." : "");
        break;
    }
    case 69: table(p, r, bits, out, depth); break;
    case 70: copy(out->type, sizeof out->type, "function"); function(p, r, bits, out, depth); break;
    case 102: {
        uint64_t f = field(p, r, bits, XL_CC_FUNC);
        out->count = field(p, r, bits, XL_CC_NUP);
        copy(out->type, sizeof out->type, "C function");
        snprintf(out->display, sizeof out->display, "C function 0x%" PRIx64 " (%" PRIu64 " upvalues)", f, out->count); break;
    }
    case 71:
        out->count = field(p, r, bits, XL_UDATA_LEN); copy(out->type, sizeof out->type, "userdata");
        snprintf(out->display, sizeof out->display, "userdata (%" PRIu64 " bytes)", out->count); break;
    case 72:
        copy(out->type, sizeof out->type, "thread"); snprintf(out->display, sizeof out->display, "thread 0x%" PRIx64, bits); break;
    }
}
void xl_value_read(const struct xl_layout *p, struct xl_reader *r, uint64_t at, struct xl_value *out) {
    value(p, r, at, out, 0);
}
void xl_state_read(const struct xl_layout *p, struct xl_reader *r, uint64_t at, struct xl_value *out) {
    memset(out, 0, sizeof *out); out->address = at; out->object = at;
    if (!header(p, r, at, 8)) { out->reason = r->error; return; }
    uint64_t stack = field(p, r, at, XL_STATE_STACK), end = field(p, r, at, XL_STATE_END), top = field(p, r, at, XL_STATE_TOP);
    uint64_t stride = p->sizes[XL_T_STACK];
    if (!r->error && (!stride || !stack || stack > top || top > end || (top - stack) % stride || (end - stack) % stride || end - stack > UINT64_C(1) << 30)) fail(r, "LuaStackBoundsInvalid");
    if (r->error) { out->reason = r->error; return; }
    copy(out->type, sizeof out->type, "thread"); out->count = (top - stack) / stride;
    snprintf(out->display, sizeof out->display, "thread 0x%" PRIx64 " (%" PRIu64 " stack slots)", at, out->count);
    uint64_t first = out->count > XL_PREVIEW_ITEMS ? out->count - XL_PREVIEW_ITEMS : 0;
    for (uint64_t i = first; i < out->count; ++i) {
        struct xl_item *item = &out->items[out->item_count++];
        snprintf(item->key, sizeof item->key, "stack[%" PRIu64 "]", i);
        child(p, r, add(r, stack, i * stride), item, i + 1 == out->count ? 0 : 1);
        if (r->error) { out->reason = r->error; return; }
    }
    out->truncated = first != 0;
    if (out->item_count) {
        const struct xl_item *last = &out->items[out->item_count - 1];
        snprintf(out->display, sizeof out->display, "top: %s (Lua state, %" PRIu64 " stack slots)",
                 last->reason && !last->advisory ? last->reason : last->display, out->count);
    }
}

static int32_t line(const struct xl_layout *p, struct xl_reader *r, uint64_t proto, uint64_t savedpc) {
    uint64_t code = field(p, r, proto, XL_PROTO_CODE), count = field(p, r, proto, XL_PROTO_NCODE);
    uint64_t lines = field(p, r, proto, XL_PROTO_LINES), nlines = field(p, r, proto, XL_PROTO_NLINES);
    if (r->error) return -1;
    if (!code || !count || count > INT32_MAX || savedpc < code || savedpc - code > count * 4 || (savedpc - code) % 4) {
        fail(r, "LuaSavedPcInvalid"); return -1;
    }
    if (savedpc == code) {
        int32_t defined = (int32_t)field(p, r, proto, XL_PROTO_LINE);
        if (defined < 0) fail(r, "LuaLineInfoInvalid");
        else fail(r, "LuaFrameNotStarted");
        return defined < 0 ? -1 : defined;
    }
    uint64_t pc = (savedpc - code) / 4 - 1;
    if (!lines || !nlines) { fail(r, "LuaLineInfoUnavailable"); return -1; }
    if (nlines != count) { fail(r, "LuaLineInfoInvalid"); return -1; }
    if (p->version[1] == 2) {
        int32_t got = (int32_t)word(r, add(r, lines, pc * 4), 4);
        if (got <= 0) fail(r, "LuaLineInfoInvalid");
        return r->error ? -1 : got;
    }
    int64_t basepc = -1, baseline = (int32_t)field(p, r, proto, XL_PROTO_LINE);
    uint64_t abs = field(p, r, proto, XL_PROTO_ABS), nabs = field(p, r, proto, XL_PROTO_NABS);
    if (r->error) return -1;
    if (nabs > 2048) { fail(r, "LuaLineInfoBudget"); return -1; }
    if (nabs && !abs) { fail(r, "LuaLineInfoInvalid"); return -1; }
    int64_t previous = -1;
    for (uint64_t i = 0; i < nabs; ++i) {
        uint64_t at = add(r, abs, i * p->sizes[XL_T_ABS]);
        int32_t apos = (int32_t)field(p, r, at, XL_ABS_PC), aline = (int32_t)field(p, r, at, XL_ABS_LINE);
        if (r->error) return -1;
        if (apos <= previous || (uint64_t)apos >= count || aline <= 0) { fail(r, "LuaLineInfoInvalid"); return -1; }
        previous = apos;
        if (word(r, add(r, lines, (uint64_t)apos), 1) != 128) { fail(r, "LuaLineInfoInvalid"); return -1; }
        if ((uint64_t)apos <= pc) { basepc = apos; baseline = aline; }
    }
    if ((int64_t)pc - basepc > 4096) { fail(r, "LuaLineInfoBudget"); return -1; }
    unsigned char delta[4096]; size_t n = (size_t)((int64_t)pc - basepc);
    if (!read_bytes(r, add(r, lines, (uint64_t)(basepc + 1)), delta, n)) return -1;
    for (size_t i = 0; i < n; ++i) {
        if (delta[i] == 128) { fail(r, "LuaLineInfoInvalid"); return -1; }
        baseline += (int8_t)delta[i];
        if (baseline < 0 || baseline > INT32_MAX) { fail(r, "LuaLineInfoInvalid"); return -1; }
    }
    if (!baseline) { fail(r, "LuaLineInfoInvalid"); return -1; }
    return (int32_t)baseline;
}
void xl_stack_read(const struct xl_layout *p, struct xl_reader *r, uint64_t state, struct xl_stack *out) {
    memset(out, 0, sizeof *out); out->state = state;
    if (!header(p, r, state, 8)) { out->reason = r->error; return; }
    uint64_t ci = field(p, r, state, XL_STATE_CI), base = add(r, state, p->fields[XL_STATE_BASE].offset);
    uint64_t stack = field(p, r, state, XL_STATE_STACK), end = field(p, r, state, XL_STATE_END);
    uint64_t status = field(p, r, state, XL_STATE_STATUS), stride = p->sizes[XL_T_STACK];
    if (!r->error && (!stride || !stack || end <= stack || (end - stack) % stride || end - stack > (UINT64_C(1) << 30)))
        fail(r, "LuaStackBoundsInvalid");
    if (r->error) { out->reason = r->error; return; }
    if (status) out->reason = status == 1 ? "LuaCoroutineSuspended" : "LuaThreadErrorState";
    while (ci != base) {
        if (!ci || ci & 7) { out->reason = "LuaCallInfoInvalid"; return; }
        if (out->count == XL_STACK_FRAMES) { out->reason = "LuaStackFrameLimit"; return; }
        for (size_t i = 0; i < out->count; ++i) if (out->frames[i].ci == ci) { out->reason = "LuaCallInfoCycle"; return; }
        uint64_t func = field(p, r, ci, XL_CI_FUNC), top = field(p, r, ci, XL_CI_TOP);
        uint64_t flags = field(p, r, ci, XL_CI_STATUS), prev = field(p, r, ci, XL_CI_PREV);
        /* Lua 5.2 saves the top yielded function as a byte offset. Its debug
         * API temporarily swaps func/extra; an external reader must instead
         * interpret extra without writing either field. */
        if (p->version[1] == 2 && status == 1 && out->count == 0)
            func = add(r, stack, field(p, r, ci, XL_CI_EXTRA));
        if (!r->error && (func < stack || func >= end || top <= func || top > end || (func - stack) % stride || (top - stack) % stride))
            fail(r, "LuaCallInfoBoundsInvalid");
        if (r->error) { out->reason = r->error; return; }
        unsigned tag = (unsigned)field(p, r, func, XL_TAG); uint64_t bits = field(p, r, func, XL_BITS);
        int is_c = p->version[1] == 4 ? (flags & 2) != 0 : (flags & 1) == 0;
        if (!r->error && ((is_c && tag != 22 && tag != 102) || (!is_c && tag != 70))) fail(r, "LuaCallInfoFunctionMismatch");
        if (r->error) { out->reason = r->error; return; }
        struct xl_frame *f = &out->frames[out->count++];
        f->ci = ci; f->function = func; f->is_c = is_c; f->tail_call = (flags & (p->version[1] == 4 ? 32 : 64)) != 0;
        f->line = f->defined_line = -1;
        if (is_c) {
            if (tag == 102 && header(p, r, bits, 38)) bits = field(p, r, bits, XL_CC_FUNC);
            if (!r->error) f->identity_proved = 1;
            f->native_function = bits; copy(f->name, sizeof f->name, "<C function>");
        } else if (header(p, r, bits, 6)) {
            f->proto = field(p, r, bits, XL_LC_PROTO);
            if (header(p, r, f->proto, p->version[1] == 4 ? 10 : 9)) {
                f->identity_proved = 1;
                uint64_t source = field(p, r, f->proto, XL_PROTO_SOURCE); uint64_t n; int truncated = 0;
                f->defined_line = (int32_t)field(p, r, f->proto, XL_PROTO_LINE);
                if (source) string(p, r, source, f->file, sizeof f->file, &n, &truncated);
                if (!r->error && (!source || truncated)) f->reason = source ? "LuaSourceTruncated" : "LuaSourceUnavailable";
                f->saved_pc = field(p, r, ci, XL_CI_PC);
                f->line = line(p, r, f->proto, f->saved_pc);
                snprintf(f->name, sizeof f->name, "<Lua function:%" PRId32 ">", f->defined_line);
                if (!f->reason) f->reason = "LuaFunctionNameUnavailable";
            }
        }
        if (r->error) {
            f->reason = r->error; out->reason = r->error;
            if (!strcmp(r->error, "LuaReadBudget")) return;
            r->error = NULL;
        }
        if (f->reason && !out->reason) out->reason = f->reason;
        if (!prev || (prev & 7)) { out->reason = "LuaCallInfoInvalid"; return; }
        for (size_t i = 0; i < out->count; ++i) if (out->frames[i].ci == prev) { out->reason = "LuaCallInfoCycle"; return; }
        if (field(p, r, prev, XL_CI_NEXT) != ci) { out->reason = r->error ? r->error : "LuaCallInfoLinkMismatch"; return; }
        ci = prev;
    }
    out->chain_complete = 1;
}

static int locals_stack_reason(const char *reason) {
    return !reason || !strcmp(reason, "LuaFunctionNameUnavailable") ||
        !strcmp(reason, "LuaSourceUnavailable") || !strcmp(reason, "LuaSourceTruncated") ||
        !strcmp(reason, "LuaLineInfoUnavailable") || !strcmp(reason, "LuaCoroutineSuspended");
}
static void local_name(const struct xl_layout *p, struct xl_reader *r, uint64_t name,
                       struct xl_local *out) {
    uint64_t length = 0;
    if (!name) { out->reason = "LuaLocalNameUnavailable"; return; }
    if (!string(p, r, name, out->name, sizeof out->name, &length, &out->name_truncated)) {
        out->reason = r->error; return;
    }
    if (!length) out->reason = "LuaLocalNameUnavailable";
    else if (out->name_truncated) out->reason = "LuaLocalNameTruncated";
}
struct local_selector { enum xl_local_kind kind; uint32_t declaration; };
static void locals(const struct xl_layout *p, struct xl_reader *r, uint64_t state,
                    size_t frame, size_t start, size_t limit, const char *expression, const struct local_selector *selector, int preview, struct xl_locals *out) {
    memset(out, 0, sizeof *out);
    out->state = state; out->frame = frame; out->start = start;
    if (expression) {
        size_t n = 0;
        while (n <= XL_STRING_BYTES && expression[n]) ++n;
        if (!n || n > XL_STRING_BYTES) { out->reason = "LuaExpressionUnsupported"; return; }
        for (size_t i = 0; i < n; ++i) {
            unsigned char c = (unsigned char)expression[i];
            if (!(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                (i && c >= '0' && c <= '9'))) { out->reason = "LuaExpressionUnsupported"; return; }
        }
    }
    if (frame >= XL_STACK_FRAMES || !limit || limit > XL_LOCAL_ITEMS) {
        out->reason = "LuaLocalsRequestInvalid"; return;
    }
    /* Fixed bounded scratch on the heap; neither the interpreter's frame count
     * nor a remote field can determine allocation size. */
    struct xl_stack *stack = calloc(1, sizeof *stack);
    if (!stack) { out->reason = "LuaLocalsAllocationFailed"; return; }
    xl_stack_read(p, r, state, stack);
    const char *why = !locals_stack_reason(stack->reason) ? stack->reason :
        frame >= stack->count ? "LuaFrameUnavailable" : NULL;
    if (why) { out->reason = why; free(stack); return; }
    struct xl_frame f = stack->frames[frame];
    free(stack);
    out->call_info = f.ci;
    if (f.is_c) { out->reason = "LuaCFrameLocalsUnavailable"; return; }
    if (!locals_stack_reason(f.reason)) { out->reason = f.reason; return; }
    uint64_t closure = field(p, r, f.function, XL_BITS);
    if (!header(p, r, closure, 6) || field(p, r, closure, XL_LC_PROTO) != f.proto) {
        out->reason = r->error ? r->error : "LuaFrameChanged"; return;
    }
    uint64_t code = field(p, r, f.proto, XL_PROTO_CODE), ncode = field(p, r, f.proto, XL_PROTO_NCODE);
    uint64_t saved = field(p, r, f.ci, XL_CI_PC), stride = p->sizes[XL_T_STACK];
    if (r->error) { out->reason = r->error; return; }
    if (!code || !ncode || ncode > INT32_MAX || saved <= code || saved - code > ncode * 4 || (saved - code) % 4) {
        out->reason = saved == code ? "LuaFrameNotStarted" : "LuaSavedPcInvalid"; return;
    }
    uint64_t pc = (saved - code) / 4 - 1;
    uint64_t bottom = field(p, r, state, XL_STATE_STACK), end = field(p, r, state, XL_STATE_END);
    uint64_t top = field(p, r, f.ci, XL_CI_TOP);
    uint64_t base = p->version[1] == 4 ? add(r, f.function, stride) : field(p, r, f.ci, XL_CI_BASE);
    if (r->error) { out->reason = r->error; return; }
    if (!stride || base < bottom || base >= end || top < base || top > end ||
        (base - bottom) % stride || (top - base) % stride) {
        out->reason = "LuaLocalStackBoundsInvalid"; return;
    }
    uint64_t varargs = 0;
    uint64_t is_vararg = field(p, r, f.proto, XL_PROTO_VARARG);
    if (is_vararg > 1) { out->reason = "LuaVarargMetadataInvalid"; return; }
    if (is_vararg) {
        if (p->version[1] == 4) {
            /* VARARGPREP must have completed before the relocated function
             * slot and nextraargs can describe this activation. */
            if (pc == 0) { out->reason = "LuaVarargsNotPrepared"; return; }
            varargs = field(p, r, f.ci, XL_CI_NEXTRA);
            if (varargs > 4096 || f.function < bottom || varargs > (f.function - bottom) / stride) {
                out->reason = "LuaVarargBoundsInvalid"; return;
            }
        } else {
            uint64_t params = field(p, r, f.proto, XL_PROTO_PARAMS);
            if (base <= f.function || (base - f.function) % stride ||
                (base - f.function) / stride < params + 1) {
                out->reason = "LuaVarargBoundsInvalid"; return;
            }
            varargs = (base - f.function) / stride - params - 1;
            if (varargs > 4096) { out->reason = "LuaVarargBoundsInvalid"; return; }
        }
    }
    if (r->error) { out->reason = r->error; return; }
    uint64_t table = field(p, r, f.proto, XL_PROTO_LOCALS), count = field(p, r, f.proto, XL_PROTO_NLOCALS);
    uint64_t up = field(p, r, f.proto, XL_PROTO_UP), nup = field(p, r, f.proto, XL_PROTO_NUP);
    uint64_t closure_nup = field(p, r, closure, XL_LC_NUP);
    if (r->error) { out->reason = r->error; return; }
    if (count > 4096) { out->reason = "LuaLocalsWorkLimit"; return; }
    if ((count && (!table || !p->sizes[XL_T_LOCVAR])) || nup != closure_nup || nup > 255 ||
        (nup && (!up || !p->sizes[XL_T_UPDESC]))) {
        out->reason = "LuaLocalsMetadataInvalid"; return;
    }
    uint64_t active[256]; size_t nactive = 0; int32_t previous = -1;
    for (uint64_t i = 0; i < count; ++i) {
        uint64_t at = add(r, table, i * p->sizes[XL_T_LOCVAR]);
        int32_t begin = (int32_t)field(p, r, at, XL_LOCAL_START);
        int32_t finish = (int32_t)field(p, r, at, XL_LOCAL_END);
        if (r->error) { out->reason = r->error; return; }
        if (begin < previous || begin < 0 || finish < begin || (uint64_t)finish > ncode) {
            out->reason = "LuaLocalScopeInvalid"; return;
        }
        previous = begin;
        if ((uint64_t)begin > pc) break;
        if (pc >= (uint64_t)finish) continue;
        if (nactive == sizeof active / sizeof *active) { out->reason = "LuaLocalsWorkLimit"; return; }
        active[nactive++] = at;
    }
    if (nactive > (top - base) / stride) { out->reason = "LuaLocalStackBoundsInvalid"; return; }
    if (!count) out->reason = "LuaLocalNamesUnavailable";
    const size_t named_count = nactive + (size_t)nup;
    out->total = named_count + (varargs != 0);
    if (expression) {
        if (out->reason) return; /* Missing names could hide a shadowing local. */
        size_t selected = SIZE_MAX;
        /* Later active locals shadow earlier locals and every upvalue. Scan
         * all names so missing/truncated names never become guessed absence. */
        struct xl_local binding;
        for (size_t i = 0; i < named_count; ++i) {
            memset(&binding, 0, sizeof binding);
            uint64_t name = i < nactive ? field(p, r, active[i], XL_LOCAL_NAME) :
                field(p, r, add(r, up, (i - nactive) * p->sizes[XL_T_UPDESC]), XL_UP_NAME);
            local_name(p, r, name, &binding);
            if (r->error || binding.reason) { out->reason = r->error ? r->error : binding.reason; return; }
            if (strcmp(binding.name, expression)) continue;
            if (i < nactive) selected = i;
            else if (selected == SIZE_MAX) selected = i;
            else if (selected >= nactive) { out->reason = "LuaBindingAmbiguous"; return; }
        }
        if (selected == SIZE_MAX) { out->reason = "LuaNameNotFound"; return; }
        start = selected; limit = 1; out->start = selected;
    }
    if (selector) {
        size_t selected = SIZE_MAX;
        if (selector->kind == XL_LOCAL) {
            for (size_t i=0; i<nactive; ++i)
                if ((active[i]-table)/p->sizes[XL_T_LOCVAR] == selector->declaration) { selected=i; break; }
        } else if (selector->kind == XL_UPVALUE && selector->declaration < nup) selected=nactive+selector->declaration;
        if (selected == SIZE_MAX) { out->reason="LuaWatchBindingNotActive"; return; }
        start=selected;limit=1;out->start=selected;
    }
    for (size_t i = start; i < out->total && out->count < limit; ++i) {
        struct xl_local *item = &out->items[out->count++];
        uint64_t name;
        if (i == named_count) {
            item->kind = XL_VARARGS;
            item->value.count = varargs;
            strcpy(item->value.type, "varargs");
            snprintf(item->value.display, sizeof item->value.display, "(vararg) ×%" PRIu64, varargs);
            continue;
        }
        if (i < nactive) {
            item->kind = XL_LOCAL; item->ordinal = (uint32_t)i + 1;
            item->declaration = (uint32_t)((active[i]-table)/p->sizes[XL_T_LOCVAR]);
            item->address = add(r, base, i * stride);
            name = field(p, r, active[i], XL_LOCAL_NAME);
        } else {
            size_t index = i - nactive;
            item->kind = XL_UPVALUE; item->ordinal = (uint32_t)index + 1; item->declaration = (uint32_t)index;
            uint64_t uv = word(r, add(r, closure, p->fields[XL_LC_UP].offset + index * 8), 8);
            if (!header(p, r, uv, p->version[1] == 4 ? 9 : 10)) {
                item->reason = r->error; out->reason = r->error; return;
            }
            item->address = field(p, r, uv, XL_UP_VALUE);
            name = field(p, r, add(r, up, index * p->sizes[XL_T_UPDESC]), XL_UP_NAME);
        }
        if (r->error) { item->reason = r->error; out->reason = r->error; return; }
        if (!item->address || item->address & 7) { item->reason = "LuaLocalSlotInvalid"; out->reason = item->reason; return; }
        local_name(p, r, name, item);
        if (r->error) { out->reason = r->error; return; }
        if (preview) value(p, r, item->address, &item->value, 0);
        if (r->error) {
            out->reason = r->error;
            if (!strcmp(r->error, "LuaReadBudget")) return;
            r->error = NULL;
        }
    }
    out->truncated = !expression && start < out->total && out->count < out->total - start;
}

void xl_locals_read(const struct xl_layout *p, struct xl_reader *r, uint64_t state,
                    size_t frame, size_t start, size_t limit, struct xl_locals *out) {
    locals(p, r, state, frame, start, limit, NULL, NULL, 1, out);
}

/* Canonical comparison reads are separate from the display's 128-byte string
 * preview. No object pointer or unused TValue padding enters the sample. */
const char *xl_value_sample(const struct xl_layout *p, struct xl_reader *r, uint64_t at,
                            unsigned char *bytes, size_t cap, size_t *size, enum xl_sample_kind *kind) {
    if (!bytes || !size || !kind || cap > XL_SAMPLE_BYTES) return "LuaWatchSampleArguments";
    *size = 0;
    unsigned tag = (unsigned)field(p, r, at, XL_TAG), version = p->version[1];
    if (r->error) return r->error;
    uint64_t bits = 0;
    if (nil(tag, version)) { *kind = XL_SAMPLE_NIL; return NULL; }
    if (tag == 1 || (version == 4 && tag == 17)) {
        if (!cap) return "LuaWatchSampleLimit";
        if (version == 2) {
            bits = field(p, r, at, XL_BITS);
            if (r->error) return r->error;
            if ((uint32_t)bits > 1) return "LuaBooleanInvalid";
        }
        *kind = XL_SAMPLE_BOOLEAN; *size = 1;
        bytes[0] = version == 4 ? tag == 17 : (uint32_t)bits != 0; return NULL;
    }
    if (tag == 3 || (version == 4 && tag == 19)) {
        if (cap < 8) return "LuaWatchSampleLimit";
        bits = field(p, r, at, XL_BITS); if (r->error) return r->error;
        *kind = version == 4 && tag == 3 ? XL_SAMPLE_INTEGER : XL_SAMPLE_NUMBER;
        *size = 8; for (unsigned i=0; i<8; ++i) bytes[i] = (unsigned char)(bits >> (8*i));
        return NULL;
    }
    if (tag == 68 || tag == 84) {
        bits = field(p, r, at, XL_BITS); if (r->error) return r->error;
        if (!header(p, r, bits, tag & 63)) return r->error;
        uint64_t length, data;
        if (!string_extent(p, r, bits, &length, &data)) return r->error;
        if (length > cap) return "LuaWatchSampleLimit";
        if (!read_bytes(r, data, bytes, (size_t)length)) return r->error;
        *kind = XL_SAMPLE_STRING; *size = (size_t)length; return NULL;
    }
    return "LuaWatchValueUnsupported";
}

void xl_local_binding(const struct xl_layout *p, struct xl_reader *r, uint64_t state,
                       size_t frame, enum xl_local_kind kind, uint32_t declaration, struct xl_locals *out) {
    if ((kind != XL_LOCAL && kind != XL_UPVALUE) || declaration >= 4096) {
        memset(out,0,sizeof *out);out->reason="LuaWatchBindingInvalid";return;
    }
    struct local_selector selector={.kind=kind,.declaration=declaration};
    locals(p,r,state,frame,0,1,NULL,&selector,1,out);
}

struct path_key { char name[XL_STRING_BYTES + 1]; int32_t integer; int is_integer; };
struct path { char root[XL_STRING_BYTES + 1]; size_t count; struct path_key keys[XL_PATH_DEPTH]; };
static int identifier(unsigned c, int first) {
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (!first && c >= '0' && c <= '9');
}
static int path_parse(const char *text, struct path *out) {
    memset(out, 0, sizeof *out);
    if (!text) return 0;
    size_t n = 0;
    while (n <= XL_STRING_BYTES && text[n]) ++n;
    if (!n || n > XL_STRING_BYTES || !identifier((unsigned char)text[0], 1)) return 0;
    size_t i = 1;
    while (i < n && identifier((unsigned char)text[i], 0)) ++i;
    memcpy(out->root, text, i);
    while (i < n) {
        if (out->count == XL_PATH_DEPTH) return 0;
        struct path_key *key = &out->keys[out->count++];
        if (text[i] == '.') {
            size_t begin = ++i;
            if (i == n || !identifier((unsigned char)text[i], 1)) return 0;
            while (++i < n && identifier((unsigned char)text[i], 0)) {}
            memcpy(key->name, text + begin, i - begin);
        } else if (text[i] == '[') {
            ++i; int negative = i < n && text[i] == '-';
            if (negative) ++i;
            if (i == n || text[i] < '0' || text[i] > '9') return 0;
            uint64_t number = 0, limit = (uint64_t)INT32_MAX + negative;
            while (i < n && text[i] >= '0' && text[i] <= '9') {
                unsigned digit = (unsigned)(text[i++] - '0');
                if (number > (limit - digit) / 10) return 0;
                number = number * 10 + digit;
            }
            if (i == n || text[i++] != ']') return 0;
            key->is_integer = 1; key->integer = (int32_t)(negative ? -(int64_t)number : (int64_t)number);
        } else return 0;
    }
    return 1;
}

int xl_expression_valid(const char *text) {
    struct path path;
    return path_parse(text, &path);
}

/* Batch only bytes within the proved Node stride; no speculative page reads.
 * All occupied hash slots are inspected before claiming a key is unique or
 * absent. A prefix match is not a complete lookup when the scan exceeds a cap. */
static uint64_t node_word(struct xl_reader *r, const unsigned char *node, size_t stride,
                          struct xl_field_info f) {
    if (!f.size || f.size > 8 || f.offset > stride || f.size > stride - f.offset) {
        fail(r, "LuaLayoutUnsupported"); return 0;
    }
    uint64_t result = 0;
    for (size_t i = 0; i < f.size; ++i) result |= (uint64_t)node[f.offset + i] << (8 * i);
    return result;
}
static int path_key_equal(const struct xl_layout *p, struct xl_reader *r, const struct path_key *key,
                           unsigned tag, uint64_t bits) {
    switch (tag) {
    case 1: case 2: case 3: case 22: case 68: case 84: case 69: case 70: case 102: case 71: case 72: break;
    case 17: case 19: if (p->version[1] == 4) break; /* fall through */
    default: return fail(r, "LuaTableKeyInvalid");
    }
    if (tag == (p->version[1] == 4 ? 19u : 3u) &&
        (bits & UINT64_C(0x7ff0000000000000)) == UINT64_C(0x7ff0000000000000) &&
        (bits & UINT64_C(0x000fffffffffffff))) return fail(r, "LuaTableKeyInvalid");
    if (key->is_integer) {
        if (p->version[1] == 4 && tag == 3) return (int64_t)bits == key->integer;
        if (tag == (p->version[1] == 4 ? 19u : 3u)) {
            double number; memcpy(&number, &bits, sizeof number);
            return number == (double)key->integer;
        }
        return 0;
    }
    if (tag != 68 && tag != 84) return 0;
    if (!header(p, r, bits, tag & 63)) return 0;
    uint64_t length, data;
    if (!string_extent(p, r, bits, &length, &data)) return 0;
    size_t wanted = strlen(key->name);
    if (length != wanted) return 0;
    unsigned char bytes[XL_STRING_BYTES];
    return read_bytes(r, data, bytes, wanted) && !memcmp(bytes, key->name, wanted);
}
static uint64_t path_lookup(const struct xl_layout *p, struct xl_reader *r, uint64_t slot,
                            const struct path_key *key) {
    if (field(p, r, slot, XL_TAG) != 69) { fail(r, "LuaPathNotTable"); return 0; }
    uint64_t at = field(p, r, slot, XL_BITS);
    if (!header(p, r, at, 5)) return 0;
    if (field(p, r, at, XL_TABLE_META)) { fail(r, "LuaPathMetatableUnsupported"); return 0; }
    uint64_t a = field(p, r, at, XL_TABLE_SIZE), log = field(p, r, at, XL_TABLE_LOG);
    uint64_t flags = field(p, r, at, XL_TABLE_FLAGS), arr = field(p, r, at, XL_TABLE_ARRAY);
    uint64_t nodes = field(p, r, at, XL_TABLE_NODE), free_node = field(p, r, at, XL_TABLE_FREE);
    if (r->error) return 0;
    if (!p->sizes[XL_T_TVALUE] || a > INT32_MAX || log > 30 || !nodes || (a && !arr) ||
        (p->version[1] == 4 && !free_node && log)) { fail(r, "LuaTableInvalid"); return 0; }
    /* Lua 5.4 ltable.c luaH_realasize: BITRAS means alimit is a non-real
     * boundary within the actual power-of-two allocation. */
    if (p->version[1] == 4 && (flags & 128) && a) {
        uint64_t rounded = 1; while (rounded < a) rounded <<= 1;
        a = rounded;
    }
    if (key->is_integer && key->integer > 0 && (uint64_t)key->integer <= a)
        return add(r, arr, ((uint64_t)key->integer - 1) * p->sizes[XL_T_TVALUE]);
    uint64_t count = p->version[1] == 4 && !free_node ? 0 : UINT64_C(1) << log;
    if (count > XL_PATH_HASH_NODES) { fail(r, "LuaPathWorkLimit"); return 0; }
    size_t stride = p->sizes[XL_T_NODE];
    if (!stride || stride > 256 || p->fields[XL_NODE_VALUE].offset > stride ||
        p->sizes[XL_T_TVALUE] > stride - p->fields[XL_NODE_VALUE].offset) {
        fail(r, "LuaLayoutUnsupported"); return 0;
    }
    struct xl_field_info value_tag = p->fields[XL_TAG];
    if (value_tag.offset > UINT32_MAX - p->fields[XL_NODE_VALUE].offset) {
        fail(r, "LuaLayoutUnsupported"); return 0;
    }
    value_tag.offset += p->fields[XL_NODE_VALUE].offset;
    unsigned char buffer[16 * 256]; uint64_t found = 0;
    for (uint64_t start = 0; start < count; start += 16) {
        size_t n = count - start > 16 ? 16 : (size_t)(count - start);
        if (!read_bytes(r, add(r, nodes, start * stride), buffer, n * stride)) return 0;
        for (size_t i = 0; i < n; ++i) {
            const unsigned char *node = buffer + i * stride;
            unsigned tag = (unsigned)node_word(r, node, stride, value_tag);
            if (r->error) return 0;
            /* Dead keys have no live value. Do not follow their stale bits. */
            if (nil(tag, p->version[1])) continue;
            unsigned kt = (unsigned)node_word(r, node, stride, p->fields[XL_NODE_KEY_TAG]);
            uint64_t kb = node_word(r, node, stride, p->fields[XL_NODE_KEY_BITS]);
            if (r->error) return 0;
            int equal = path_key_equal(p, r, key, kt, kb);
            if (r->error) return 0;
            if (!equal) continue;
            if (found) { fail(r, "LuaPathKeyAmbiguous"); return 0; }
            found = add(r, nodes, (start + i) * stride + p->fields[XL_NODE_VALUE].offset);
        }
    }
    return found;
}

void xl_local_find(const struct xl_layout *p, struct xl_reader *r, uint64_t state,
                   size_t frame, const char *expression, struct xl_locals *out) {
    struct path path;
    if (!path_parse(expression, &path)) {
        memset(out, 0, sizeof *out); out->reason = "LuaExpressionUnsupported"; return;
    }
    locals(p, r, state, frame, 0, 1, path.root, NULL, path.count == 0, out);
    if (!path.count || out->reason || out->count != 1 || out->items[0].reason) return;
    struct xl_local *item = &out->items[0];
    for (size_t i = 0; i < path.count; ++i) {
        uint64_t slot = path_lookup(p, r, item->address, &path.keys[i]);
        if (r->error) { out->count = 0; out->reason = r->error; return; }
        if (!slot && i + 1 != path.count) { out->count = 0; out->reason = "LuaPathNotTable"; return; }
        item->address = slot;
    }
    copy(item->name, sizeof item->name, expression);
    if (item->address) value(p, r, item->address, &item->value, 0);
    else {
        item->path_absent = 1;
        copy(item->value.type, sizeof item->value.type, "nil");
        copy(item->value.display, sizeof item->value.display, "nil");
    }
    if (r->error) { out->count = 0; out->reason = r->error; }
}

const char *xl_local_sample(const struct xl_layout *p, struct xl_reader *r, const struct xl_local *item,
                            unsigned char *bytes, size_t cap, size_t *size, enum xl_sample_kind *kind) {
    if (!item || !bytes || !size || !kind || cap > XL_SAMPLE_BYTES) return "LuaWatchSampleArguments";
    *size = 0;
    if (r->error) return r->error;
    if (item->reason) return item->reason;
    if (item->path_absent && !item->address) { *kind = XL_SAMPLE_NIL; return NULL; }
    return xl_value_sample(p, r, item->address, bytes, cap, size, kind);
}
