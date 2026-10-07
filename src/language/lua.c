#include "lua.h"
#include <inttypes.h>
#include <stdio.h>
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
static int string(const struct xl_layout *p, struct xl_reader *r, uint64_t at, char *out, size_t cap,
                  uint64_t *length, int *truncated) {
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
    if (r->error || n > INT64_MAX) return fail(r, "LuaStringLengthInvalid");
    unsigned char bytes[XL_STRING_BYTES]; size_t count = n > sizeof bytes ? sizeof bytes : (size_t)n;
    if (!read_bytes(r, add(r, at, offset), bytes, count)) return 0;
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
    if (r->error) out->reason = r->error;
}
static void child(const struct xl_layout *p, struct xl_reader *r, uint64_t at, struct xl_item *out, unsigned depth) {
    struct xl_value v; value(p, r, at, &v, depth);
    out->address = at; copy(out->type, sizeof out->type, v.type); copy(out->display, sizeof out->display, v.display);
    out->reason = v.reason;
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
    if (depth >= 1) { out->truncated = a || h; return; }
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
        const char *key_error = item->reason;
        child(p, r, slot, item, depth + 1);
        if (!item->reason) item->reason = key_error;
        if (r->error) return;
    }
    out->truncated = scanned < a || hs < h;
    if (out->item_count) {
        copy(out->display, sizeof out->display, "table");
        size_t used = strlen(out->display);
        for (size_t i = 0; i < out->item_count && i < 4; ++i) {
            const struct xl_item *item = &out->items[i];
            const char *key = item->key, *shown = item->reason ? item->reason : item->display;
            if (!strncmp(key, "string ", 7)) key += 7;
            if (!item->reason) {
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
        snprintf(out->display, sizeof out->display, "string \"%s\"%s", text, truncated ? "..." : ""); break;
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
                 last->reason ? last->reason : last->display, out->count);
    }
}

static int32_t line(const struct xl_layout *p, struct xl_reader *r, uint64_t proto, uint64_t savedpc) {
    uint64_t code = field(p, r, proto, XL_PROTO_CODE), count = field(p, r, proto, XL_PROTO_NCODE);
    uint64_t lines = field(p, r, proto, XL_PROTO_LINES), nlines = field(p, r, proto, XL_PROTO_NLINES);
    if (r->error) return -1;
    if (!code || !count || count > INT32_MAX || savedpc <= code || savedpc - code > count * 4 || (savedpc - code) % 4) {
        fail(r, "LuaSavedPcInvalid"); return -1;
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
            f->native_function = bits; copy(f->name, sizeof f->name, "<C function>");
        } else if (header(p, r, bits, 6)) {
            f->proto = field(p, r, bits, XL_LC_PROTO);
            if (header(p, r, f->proto, p->version[1] == 4 ? 10 : 9)) {
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
}
