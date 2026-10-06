/* xsg v1 loader and validator. Every reference is resolved and checked before
 * a graph is returned; a rejected graph is never partially usable. */
#define _GNU_SOURCE 1
#include "xsq.h"
#include "xsq_internal.h"
#include "sha256.h"

#include <errno.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum width_rule {
    W_ANY, W_UNARY, W_BINARY, W_CMP, W_EXTEND, W_SHIFT, W_BOOL, W_FLAG, W_CONVERT, W_PHI,
    W_INDIRECT, W_PIECE, W_SUBPIECE, W_PTRADD, W_PTRSUB, W_LOAD, W_STORE, W_CBRANCH,
};

#define NAME(name, cls, width) #name,
static const char *const opcode_names[] = {XSQ_OPCODES(NAME) "UNKNOWN"};
#undef NAME
#define CLASS(name, cls, width) XSQ_CLASS_##cls,
static const unsigned char opcode_classes[] = {XSQ_OPCODES(CLASS) XSQ_CLASS_BARRIER};
#undef CLASS
#define WIDTH(name, cls, width) width,
static const unsigned char opcode_widths[] = {XSQ_OPCODES(WIDTH) W_ANY};
#undef WIDTH

static const char *const space_classes[] = {"constant", "ram", "register", "unique",
                                            "stack", "join", "other"};
static const char *const edge_kinds[] = {"fall", "true", "false", "jump", "switch"};

const char *xsq_status_name(enum xsq_status status)
{
    static const char *const names[] = {"ok", "partial", "cancelled", "unsupported",
                                        "not_found", "invalid_argument", "malformed",
                                        "limit", "no_memory", "io"};
    return (unsigned)status < sizeof names / sizeof *names ? names[status] : "invalid";
}

const char *xsq_edge_kind_name(unsigned kind)
{
    return kind < sizeof edge_kinds / sizeof *edge_kinds ? edge_kinds[kind] : "invalid";
}

enum xsq_op_class xsq_opcode_class(unsigned opcode)
{
    return opcode <= XSQ_OP_UNKNOWN ? (enum xsq_op_class)opcode_classes[opcode]
                                    : XSQ_CLASS_BARRIER;
}

const char *xsq_string(const struct xsq_graph *g, uint32_t offset)
{
    return g->strings && offset < g->strings_len ? g->strings + offset : "";
}

const char *xsq_opcode_name(const struct xsq_graph *g, const struct xsq_op *op)
{
    if (op->opcode == XSQ_OP_UNKNOWN && op->name)
        return xsq_string(g, op->name);
    return opcode_names[op->opcode <= XSQ_OP_UNKNOWN ? op->opcode : XSQ_OP_UNKNOWN];
}

/* ---- parsing helpers ---------------------------------------------------- */

struct parser {
    struct xsq_graph *g;
    uint32_t line;
    uint32_t func; /* current function index or XSQ_NONE */
    uint32_t space_cap, vn_cap, op_cap, block_cap, edge_cap, func_cap, ro_cap, call_cap,
        input_cap;
    uint32_t *edge_from_raw; /* raw block ids before resolution */
    uint32_t *edge_to_raw;
    struct xsq_cancel *cancel;
    uint8_t seen_header, seen_image, seen_spec, seen_producer, seen_source, seen_end, seen_qual;
};

static enum xsq_status fail(struct xsq_graph *g, uint32_t line, const char *format, ...)
{
    if (!g->error[0]) {
        va_list args;
        va_start(args, format);
        vsnprintf(g->error, sizeof g->error, format, args);
        va_end(args);
        g->error_line = line;
    }
    return XSQ_MALFORMED;
}

static enum xsq_status limit(struct xsq_graph *g, uint32_t line, const char *what)
{
    if (!g->error[0]) {
        snprintf(g->error, sizeof g->error, "limit exceeded: %s", what);
        g->error_line = line;
    }
    return XSQ_LIMIT;
}

/* Charge bytes to the load budget (cumulative; frees do not refund). */
static enum xsq_status charge(struct xsq_graph *g, uint32_t line, size_t bytes)
{
    if (bytes > g->load_max_bytes - g->load_bytes) {
        if (!g->error[0]) {
            snprintf(g->error, sizeof g->error, "load budget exceeded: %zu + %zu > %zu bytes",
                     g->load_bytes, bytes, g->load_max_bytes);
            g->error_line = line;
        }
        return XSQ_LIMIT;
    }
    g->load_bytes += bytes;
    return XSQ_OK;
}

static enum xsq_status no_memory(struct xsq_graph *g, uint32_t line)
{
    if (!g->error[0]) {
        snprintf(g->error, sizeof g->error, "allocation failed");
        g->error_line = line;
    }
    return XSQ_NO_MEMORY;
}

/* Charged, failure-checked resize of a loader array. */
static enum xsq_status resize(struct xsq_graph *g, uint32_t line, void **items, size_t old_bytes,
                              size_t new_bytes)
{
    enum xsq_status s;
    (void)old_bytes; /* charged as the allocator request: the full new size, no refunds */
    if ((s = charge(g, line, new_bytes)))
        return s;
    void *grown = xsq__realloc(*items, new_bytes);
    if (!grown)
        return no_memory(g, line);
    *items = grown;
    return XSQ_OK;
}

static enum xsq_status poll_cancel(struct parser *p)
{
    if (!xsq_cancel_requested(p->cancel))
        return XSQ_OK;
    if (!p->g->error[0]) {
        snprintf(p->g->error, sizeof p->g->error, "load cancelled");
        p->g->error_line = p->line;
    }
    return XSQ_CANCELLED;
}

static enum xsq_status grow(struct xsq_graph *g, uint32_t line, void **items, uint32_t *cap,
                           uint32_t count, size_t size, uint32_t max, const char *what)
{
    if (count < *cap)
        return XSQ_OK;
    if (count >= max)
        return limit(g, line, what);
    uint32_t next = *cap ? *cap : 64;
    while (next <= count)
        next = next > max / 2 ? max : next * 2;
    enum xsq_status s = resize(g, line, items, (size_t)*cap * size, (size_t)next * size);
    if (s)
        return s;
    *cap = next;
    return XSQ_OK;
}

static enum xsq_status add_string(struct xsq_graph *g, uint32_t line, const char *text,
                                  uint32_t *offset)
{
    size_t n = strlen(text) + 1;
    if (g->strings_len == 0)
        n += 1; /* offset 0 is the empty string */
    if (g->strings_len + n > XSQ_MAX_STRING_BYTES)
        return limit(g, line, "string bytes");
    if (g->strings_len + n > g->strings_cap) {
        size_t next = g->strings_cap ? g->strings_cap : 4096;
        while (next < g->strings_len + n)
            next *= 2;
        enum xsq_status s = resize(g, line, (void **)&g->strings, g->strings_cap, next);
        if (s)
            return s;
        g->strings_cap = next;
    }
    if (g->strings_len == 0) {
        g->strings[0] = 0;
        g->strings_len = 1;
        n -= 1;
    }
    memcpy(g->strings + g->strings_len, text, n);
    *offset = (uint32_t)g->strings_len;
    g->strings_len += n;
    return XSQ_OK;
}

static int parse_u32(const char *text, uint32_t *value)
{
    if (!text || !*text || *text == '-' || *text == '+')
        return 0;
    char *end;
    errno = 0;
    unsigned long long v = strtoull(text, &end, 10);
    if (errno || *end || v > UINT32_MAX - 1) /* UINT32_MAX is XSQ_NONE */
        return 0;
    *value = (uint32_t)v;
    return 1;
}

static int parse_hex(const char *text, uint64_t *value)
{
    if (!text || text[0] != '0' || (text[1] != 'x' && text[1] != 'X') || !text[2])
        return 0;
    uint64_t v = 0;
    for (const char *p = text + 2; *p; ++p) {
        unsigned digit;
        if (*p >= '0' && *p <= '9')
            digit = (unsigned)(*p - '0');
        else if (*p >= 'a' && *p <= 'f')
            digit = (unsigned)(*p - 'a' + 10);
        else if (*p >= 'A' && *p <= 'F')
            digit = (unsigned)(*p - 'A' + 10);
        else
            return 0;
        if (v >> 60)
            return 0; /* overflow: more than 64 bits */
        v = v << 4 | digit;
    }
    *value = v;
    return 1;
}

static int valid_token(const char *text)
{
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p)
        if (*p < 0x21 || *p > 0x7e || *p == '"' || *p == '\\')
            return 0;
    return 1;
}

static const char *attribute(const char *token, const char *key)
{
    size_t n = strlen(key);
    return !strncmp(token, key, n) && token[n] == '=' ? token + n + 1 : NULL;
}

/* Parse key=value attributes common to identity lines. */
static enum xsq_status string_attr(struct parser *p, const char *token, const char *key,
                                   uint32_t *slot, int *matched)
{
    const char *value = attribute(token, key);
    if (!value)
        return XSQ_OK;
    *matched = 1;
    if (*slot)
        return fail(p->g, p->line, "duplicate attribute %s", key);
    if (!*value)
        return fail(p->g, p->line, "empty attribute %s", key);
    return add_string(p->g, p->line, value, slot);
}

static enum xsq_status need_function(struct parser *p, const char *what)
{
    if (p->func == XSQ_NONE)
        return fail(p->g, p->line, "%s outside a function", what);
    return XSQ_OK;
}

static unsigned lookup_opcode(const char *name)
{
    for (unsigned i = 0; i < XSQ_OP_UNKNOWN; ++i)
        if (!strcmp(opcode_names[i], name))
            return i;
    return XSQ_OP_UNKNOWN;
}

static enum xsq_status parse_line(struct parser *p, char **tok, unsigned n)
{
    struct xsq_graph *g = p->g;
    enum xsq_status s;
    const char *kind = tok[0];
    if (p->seen_end)
        return fail(g, p->line, "content after end");
    if (!p->seen_header) {
        if (n != 2 || strcmp(kind, "xsg"))
            return fail(g, p->line, "missing xsg header");
        uint32_t version;
        if (!parse_u32(tok[1], &version) || version != XSQ_FORMAT_VERSION)
            return fail(g, p->line, "unsupported xsg version %s", tok[1]);
        p->seen_header = 1;
        return XSQ_OK;
    }
    for (unsigned i = 0; i < n; ++i)
        if (!valid_token(tok[i]))
            return fail(g, p->line, "invalid token byte");
    int header_line = !strcmp(kind, "image") || !strcmp(kind, "spec") ||
                      !strcmp(kind, "producer") || !strcmp(kind, "source") ||
                      !strcmp(kind, "space") || !strcmp(kind, "readonly") ||
                      !strcmp(kind, "qualification");
    if (header_line && g->func_count)
        return fail(g, p->line, "%s after first function", kind);
    if (!strcmp(kind, "qualification")) {
        if (p->seen_qual)
            return fail(g, p->line, "duplicate qualification line");
        p->seen_qual = 1;
        for (unsigned i = 1; i < n; ++i) {
            int matched = 0;
            if ((s = string_attr(p, tok[i], "level", &g->qual_level, &matched)) ||
                (s = string_attr(p, tok[i], "reasons", &g->qual_reasons, &matched)) ||
                (s = string_attr(p, tok[i], "artifact", &g->artifact_id, &matched)))
                return s;
            if (!matched)
                return fail(g, p->line, "unknown qualification attribute");
        }
        const char *level = g->qual_level ? xsq_string(g, g->qual_level) : "";
        if (strcmp(level, "complete") && strcmp(level, "qualified") && strcmp(level, "unreliable") &&
            strcmp(level, "unknown"))
            return fail(g, p->line, "qualification needs level=complete|qualified|unreliable|unknown");
        return XSQ_OK;
    }

    if (!strcmp(kind, "image") || !strcmp(kind, "spec") || !strcmp(kind, "source")) {
        uint8_t *seen = kind[0] == 'i' ? &p->seen_image
                        : kind[1] == 'p' ? &p->seen_spec
                                         : &p->seen_source;
        if (*seen)
            return fail(g, p->line, "duplicate %s line", kind);
        *seen = 1;
        for (unsigned i = 1; i < n; ++i) {
            int matched = 0;
            if (kind[0] == 'i') {
                if ((s = string_attr(p, tok[i], "sha256", &g->image_sha256, &matched)) ||
                    (s = string_attr(p, tok[i], "build_id", &g->image_build_id, &matched)) ||
                    (s = string_attr(p, tok[i], "name", &g->image_name, &matched)))
                    return s;
            } else if (kind[1] == 'p') {
                const char *bytes = attribute(tok[i], "addr_bytes");
                if (bytes) {
                    matched = 1;
                    if (!parse_u32(bytes, &g->addr_bytes) || !g->addr_bytes ||
                        g->addr_bytes > 8)
                        return fail(g, p->line, "invalid addr_bytes");
                }
                if ((s = string_attr(p, tok[i], "language", &g->language, &matched)) ||
                    (s = string_attr(p, tok[i], "compiler", &g->compiler, &matched)))
                    return s;
            } else {
                if ((s = string_attr(p, tok[i], "kind", &g->source_kind, &matched)) ||
                    (s = string_attr(p, tok[i], "sha256", &g->source_sha256, &matched)))
                    return s;
            }
            if (!matched)
                return fail(g, p->line, "unknown %s attribute", kind);
        }
        if (kind[0] == 'i' && !g->image_sha256)
            return fail(g, p->line, "image needs sha256 (or sha256=unknown)");
        if (kind[1] == 'p' && (!g->language || !g->addr_bytes))
            return fail(g, p->line, "spec needs language and addr_bytes");
        if (kind[0] == 's' && kind[1] == 'o' && !g->source_kind)
            return fail(g, p->line, "source needs kind");
        return XSQ_OK;
    }
    if (!strcmp(kind, "producer")) {
        if (p->seen_producer || n != 3)
            return fail(g, p->line, "producer needs name and version once");
        p->seen_producer = 1;
        if ((s = add_string(g, p->line, tok[1], &g->producer)) ||
            (s = add_string(g, p->line, tok[2], &g->producer_version)))
            return s;
        return XSQ_OK;
    }
    if (!strcmp(kind, "space")) {
        if (n != 4)
            return fail(g, p->line, "space needs id name class");
        if ((s = grow(g, p->line, (void **)&g->spaces, &p->space_cap, g->space_count,
                      sizeof *g->spaces, XSQ_MAX_SPACES, "spaces")))
            return s;
        struct xsq_space *space = &g->spaces[g->space_count];
        memset(space, 0, sizeof *space);
        if (!parse_u32(tok[1], &space->id) || space->id > 0xffff)
            return fail(g, p->line, "invalid space id");
        for (uint32_t i = 0; i < g->space_count; ++i)
            if (g->spaces[i].id == space->id)
                return fail(g, p->line, "duplicate space id %u", space->id);
        unsigned c = 0;
        while (c < sizeof space_classes / sizeof *space_classes && strcmp(space_classes[c], tok[3]))
            ++c;
        if (c == sizeof space_classes / sizeof *space_classes)
            return fail(g, p->line, "unknown space class %s", tok[3]);
        space->cls = (uint8_t)c;
        if ((s = add_string(g, p->line, tok[2], &space->name)))
            return s;
        g->space_count++;
        return XSQ_OK;
    }
    if (!strcmp(kind, "readonly")) {
        if (n != 3)
            return fail(g, p->line, "readonly needs low high");
        if ((s = grow(g, p->line, (void **)&g->readonly, &p->ro_cap, g->readonly_count,
                      sizeof *g->readonly, XSQ_MAX_READONLY, "readonly ranges")))
            return s;
        struct xsq_range *r = &g->readonly[g->readonly_count];
        if (!parse_hex(tok[1], &r->low) || !parse_hex(tok[2], &r->high) || r->low >= r->high)
            return fail(g, p->line, "invalid readonly range");
        g->readonly_count++;
        return XSQ_OK;
    }
    if (!p->seen_image || !p->seen_spec || !p->seen_producer || !p->seen_source)
        return fail(g, p->line, "image/spec/producer/source must precede %s", kind);
    if (!strcmp(kind, "function")) {
        if (n != 4)
            return fail(g, p->line, "function needs id name entry=");
        if ((s = grow(g, p->line, (void **)&g->funcs, &p->func_cap, g->func_count,
                      sizeof *g->funcs, XSQ_MAX_FUNCTIONS, "functions")))
            return s;
        struct xsq_func *f = &g->funcs[g->func_count];
        memset(f, 0, sizeof *f);
        f->line = p->line;
        f->entry_block = XSQ_NONE;
        if (!parse_u32(tok[1], &f->id))
            return fail(g, p->line, "invalid function id");
        for (uint32_t i = 0; i < g->func_count; ++i)
            if (g->funcs[i].id == f->id)
                return fail(g, p->line, "duplicate function id %u", f->id);
        const char *entry = attribute(tok[3], "entry");
        if (!entry || !parse_hex(entry, &f->entry))
            return fail(g, p->line, "invalid function entry");
        if ((s = add_string(g, p->line, tok[2], &f->name)))
            return s;
        f->block_first = g->block_count;
        f->vn_first = g->vn_count;
        p->func = g->func_count++;
        return XSQ_OK;
    }
    if (!strcmp(kind, "block")) {
        if ((s = need_function(p, kind)))
            return s;
        if (n != 3)
            return fail(g, p->line, "block needs id start");
        if ((s = grow(g, p->line, (void **)&g->blocks, &p->block_cap, g->block_count,
                      sizeof *g->blocks, XSQ_MAX_BLOCKS, "blocks")))
            return s;
        struct xsq_block *b = &g->blocks[g->block_count];
        memset(b, 0, sizeof *b);
        b->func = p->func;
        b->line = p->line;
        if (!parse_u32(tok[1], &b->id) || !parse_hex(tok[2], &b->start))
            return fail(g, p->line, "invalid block");
        g->block_count++;
        g->funcs[p->func].block_count++;
        return XSQ_OK;
    }
    if (!strcmp(kind, "edge")) {
        if ((s = need_function(p, kind)))
            return s;
        if (n != 4)
            return fail(g, p->line, "edge needs from to kind");
        uint32_t cap = p->edge_cap;
        if ((s = grow(g, p->line, (void **)&g->edges, &p->edge_cap, g->edge_count,
                      sizeof *g->edges, XSQ_MAX_EDGES, "edges")))
            return s;
        if (cap != p->edge_cap) {
            size_t old = (size_t)cap * sizeof(uint32_t), now = (size_t)p->edge_cap * sizeof(uint32_t);
            if ((s = resize(g, p->line, (void **)&p->edge_from_raw, old, now)) ||
                (s = resize(g, p->line, (void **)&p->edge_to_raw, old, now)))
                return s;
        }
        struct xsq_edge *e = &g->edges[g->edge_count];
        memset(e, 0, sizeof *e);
        e->line = p->line;
        if (!parse_u32(tok[1], &p->edge_from_raw[g->edge_count]) ||
            !parse_u32(tok[2], &p->edge_to_raw[g->edge_count]))
            return fail(g, p->line, "invalid edge block id");
        unsigned k = 0;
        while (k < sizeof edge_kinds / sizeof *edge_kinds && strcmp(edge_kinds[k], tok[3]))
            ++k;
        if (k == sizeof edge_kinds / sizeof *edge_kinds)
            return fail(g, p->line, "unknown edge kind %s", tok[3]);
        e->kind = (uint8_t)k;
        e->from = p->func; /* function index until resolution */
        g->edge_count++;
        return XSQ_OK;
    }
    if (!strcmp(kind, "vn")) {
        if ((s = need_function(p, kind)))
            return s;
        if (n < 5)
            return fail(g, p->line, "vn needs id space offset size");
        if ((s = grow(g, p->line, (void **)&g->vns, &p->vn_cap, g->vn_count, sizeof *g->vns,
                      XSQ_MAX_VARNODES, "varnodes")))
            return s;
        struct xsq_vn *v = &g->vns[g->vn_count];
        memset(v, 0, sizeof *v);
        v->func = p->func;
        v->def = XSQ_NONE;
        v->param = -1;
        v->line = p->line;
        uint32_t space_id;
        if (!parse_u32(tok[1], &v->id) || !parse_u32(tok[2], &space_id) ||
            !parse_hex(tok[3], &v->offset) || !parse_u32(tok[4], &v->size))
            return fail(g, p->line, "invalid vn");
        uint32_t si = 0;
        while (si < g->space_count && g->spaces[si].id != space_id)
            ++si;
        if (si == g->space_count)
            return fail(g, p->line, "vn %u: undefined space %u", v->id, space_id);
        v->space = (uint16_t)si;
        if (v->size == 0 || v->size > XSQ_MAX_VARNODE_BYTES)
            return fail(g, p->line, "vn %u: width error: size %u", v->id, v->size);
        if (g->spaces[si].cls == XSQ_SPACE_CONSTANT && v->size < 8 &&
            v->offset >> (8 * v->size))
            return fail(g, p->line, "vn %u: width error: constant exceeds %u bytes", v->id,
                        v->size);
        for (unsigned i = 5; i < n; ++i) {
            const char *value;
            if (!strcmp(tok[i], "input"))
                v->flags |= XSQ_VN_INPUT;
            else if (!strcmp(tok[i], "spacebase"))
                v->flags |= XSQ_VN_SPACEBASE;
            else if (!strcmp(tok[i], "spacebase_heuristic"))
                v->flags |= XSQ_VN_SPACEBASE | XSQ_VN_SPACEBASE_HEURISTIC;
            else if (!strcmp(tok[i], "annotation"))
                v->flags |= XSQ_VN_ANNOTATION;
            else if (!strcmp(tok[i], "addrtied"))
                v->flags |= XSQ_VN_ADDRTIED;
            else if (!strcmp(tok[i], "persist"))
                v->flags |= XSQ_VN_PERSIST;
            else if ((value = attribute(tok[i], "param"))) {
                uint32_t index;
                if (!parse_u32(value, &index) || index > 4096)
                    return fail(g, p->line, "invalid param index");
                v->param = (int32_t)index;
                v->flags |= XSQ_VN_PARAM;
            } else if ((value = attribute(tok[i], "name"))) {
                if (v->name || !*value || (s = add_string(g, p->line, value, &v->name)))
                    return s ? s : fail(g, p->line, "invalid vn name");
            } else if ((value = attribute(tok[i], "origin"))) {
                if (v->origin || !*value || (s = add_string(g, p->line, value, &v->origin)))
                    return s ? s : fail(g, p->line, "invalid vn origin");
            } else
                return fail(g, p->line, "unknown vn attribute %s", tok[i]);
        }
        if ((v->flags & (XSQ_VN_PARAM | XSQ_VN_SPACEBASE)) && !(v->flags & XSQ_VN_INPUT))
            return fail(g, p->line, "vn %u: param/spacebase requires input", v->id);
        if ((v->flags & XSQ_VN_ANNOTATION) &&
            ((v->flags & XSQ_VN_INPUT) || g->spaces[si].cls == XSQ_SPACE_CONSTANT))
            return fail(g, p->line, "vn %u: annotation must be a non-input code address", v->id);
        if ((v->flags & XSQ_VN_INPUT) && g->spaces[si].cls == XSQ_SPACE_CONSTANT)
            return fail(g, p->line, "vn %u: constant cannot be an input", v->id);
        g->vn_count++;
        g->funcs[p->func].vn_count++;
        return XSQ_OK;
    }
    if (!strcmp(kind, "op")) {
        if ((s = need_function(p, kind)))
            return s;
        if (n < 7)
            return fail(g, p->line, "op needs id block address seq opcode out");
        if ((s = grow(g, p->line, (void **)&g->ops, &p->op_cap, g->op_count, sizeof *g->ops,
                      XSQ_MAX_OPS, "ops")))
            return s;
        struct xsq_op *op = &g->ops[g->op_count];
        memset(op, 0, sizeof *op);
        op->func = p->func;
        op->line = p->line;
        op->iop = XSQ_NONE;
        op->out = XSQ_NONE;
        if (!parse_u32(tok[1], &op->id) || !parse_u32(tok[2], &op->block) ||
            !parse_hex(tok[3], &op->address) || !parse_u32(tok[4], &op->seq))
            return fail(g, p->line, "invalid op");
        op->opcode = (uint16_t)lookup_opcode(tok[5]);
        if (op->opcode == XSQ_OP_UNKNOWN && (s = add_string(g, p->line, tok[5], &op->name)))
            return s;
        if (strcmp(tok[6], "-") && !parse_u32(tok[6], &op->out))
            return fail(g, p->line, "invalid op output");
        op->in_first = g->input_count;
        for (unsigned i = 7; i < n; ++i) {
            const char *value;
            if ((value = attribute(tok[i], "origin"))) {
                if (op->origin || !*value || (s = add_string(g, p->line, value, &op->origin)))
                    return s ? s : fail(g, p->line, "invalid op origin");
                continue;
            }
            if (strchr(tok[i], '='))
                return fail(g, p->line, "unknown op attribute %s", tok[i]);
            if (op->origin)
                return fail(g, p->line, "op input after attributes");
            if (tok[i][0] == '@') {
                if (op->opcode != XSQ_OP_INDIRECT || op->in_count != 1 ||
                    !parse_u32(tok[i] + 1, &op->iop))
                    return fail(g, p->line, "op %u: op reference only valid as INDIRECT input 1",
                                op->id);
                op->in_count++;
                if ((s = grow(g, p->line, (void **)&g->inputs, &p->input_cap, g->input_count,
                              sizeof *g->inputs, XSQ_MAX_INPUT_REFS, "input references")))
                    return s;
                g->inputs[g->input_count++] = XSQ_NONE;
                continue;
            }
            if (op->in_count >= XSQ_MAX_OP_INPUTS)
                return limit(g, p->line, "op inputs");
            if ((s = grow(g, p->line, (void **)&g->inputs, &p->input_cap, g->input_count,
                          sizeof *g->inputs, XSQ_MAX_INPUT_REFS, "input references")))
                return s;
            if (!parse_u32(tok[i], &g->inputs[g->input_count]))
                return fail(g, p->line, "invalid op input %s", tok[i]);
            g->input_count++;
            op->in_count++;
        }
        g->op_count++;
        return XSQ_OK;
    }
    if (!strcmp(kind, "call")) {
        if ((s = need_function(p, kind)))
            return s;
        if (n < 3 || n > 4)
            return fail(g, p->line, "call needs op target= [name=]");
        if ((s = grow(g, p->line, (void **)&g->calls, &p->call_cap, g->call_count,
                      sizeof *g->calls, XSQ_MAX_OPS, "calls")))
            return s;
        struct xsq_call *c = &g->calls[g->call_count];
        memset(c, 0, sizeof *c);
        const char *target = attribute(tok[2], "target");
        if (!parse_u32(tok[1], &c->op) || !target)
            return fail(g, p->line, "invalid call");
        if (strcmp(target, "unknown")) {
            if (!parse_hex(target, &c->target))
                return fail(g, p->line, "invalid call target");
            c->known = 1;
        }
        if (n == 4) {
            const char *name = attribute(tok[3], "name");
            if (!name || !*name)
                return fail(g, p->line, "invalid call name");
            if ((s = add_string(g, p->line, name, &c->name)))
                return s;
        }
        g->call_count++;
        return XSQ_OK;
    }
    if (!strcmp(kind, "end")) {
        if (n != 1)
            return fail(g, p->line, "end takes no arguments");
        p->seen_end = 1;
        return XSQ_OK;
    }
    return fail(g, p->line, "unknown directive %s", kind);
}

/* ---- resolution and validation ------------------------------------------ */


static int cmp_op_order(const void *a, const void *b)
{
    const struct xsq_op *x = a, *y = b;
    if (x->block != y->block)
        return x->block < y->block ? -1 : 1;
    if (x->seq != y->seq)
        return x->seq < y->seq ? -1 : 1;
    return x->line < y->line ? -1 : x->line > y->line;
}

#define ID_COMPARE(fn, field)                                                                    \
    static int fn(const void *a, const void *b, void *context)                                 \
    {                                                                                          \
        const struct xsq_graph *sort_graph = context; /* reentrant: no global state */        \
        uint32_t x = sort_graph->field[*(const uint32_t *)a].id;                               \
        uint32_t y = sort_graph->field[*(const uint32_t *)b].id;                               \
        return x < y ? -1 : x > y;                                                             \
    }
ID_COMPARE(cmp_op_id, ops)
ID_COMPARE(cmp_vn_id, vns)
ID_COMPARE(cmp_block_id, blocks)
#undef ID_COMPARE


static uint32_t search(const uint32_t *index, uint32_t count, uint32_t id, const void *items,
                       size_t stride)
{
    if (!index)
        return XSQ_NONE;
    uint32_t low = 0, high = count;
    while (low < high) {
        uint32_t mid = low + (high - low) / 2;
        uint32_t value = *(const uint32_t *)((const char *)items + (size_t)index[mid] * stride);
        if (value == id)
            return index[mid];
        if (value < id)
            low = mid + 1;
        else
            high = mid;
    }
    return XSQ_NONE;
}

/* The id field is first in each indexed struct. */
_Static_assert(offsetof(struct xsq_op, id) == 0, "op id first");
_Static_assert(offsetof(struct xsq_vn, id) == 0, "vn id first");
_Static_assert(offsetof(struct xsq_block, id) == 0, "block id first");

static enum xsq_status build_index(struct xsq_graph *g, uint32_t count, uint32_t **out,
                                   int (*cmp)(const void *, const void *, void *), const void *items,
                                   size_t stride, size_t line_offset, const char *what)
{
    enum xsq_status s = charge(g, 0, ((size_t)count + 1) * sizeof(uint32_t));
    if (s)
        return s;
    uint32_t *index = xsq__malloc(((size_t)count + 1) * sizeof *index);
    if (!index)
        return no_memory(g, 0);
    for (uint32_t i = 0; i < count; ++i)
        index[i] = i;
    qsort_r(index, count, sizeof *index, cmp, g);
    *out = index;
    for (uint32_t i = 1; i < count; ++i) {
        uint32_t a = *(const uint32_t *)((const char *)items + (size_t)index[i - 1] * stride);
        uint32_t b = *(const uint32_t *)((const char *)items + (size_t)index[i] * stride);
        if (a == b) {
            uint32_t x = *(const uint32_t *)((const char *)items + (size_t)index[i - 1] * stride +
                                             line_offset);
            uint32_t y = *(const uint32_t *)((const char *)items + (size_t)index[i] * stride +
                                             line_offset);
            return fail(g, x > y ? x : y, "duplicate %s id %u", what, a);
        }
    }
    return XSQ_OK;
}

uint32_t xsq_find_op(const struct xsq_graph *g, uint32_t id)
{
    return search(g->op_by_id, g->op_count, id, g->ops, sizeof *g->ops);
}

uint32_t xsq_find_vn(const struct xsq_graph *g, uint32_t id)
{
    return search(g->vn_by_id, g->vn_count, id, g->vns, sizeof *g->vns);
}

uint32_t xsq_find_op_origin(const struct xsq_graph *g, const char *origin)
{
    for (uint32_t i = 0; i < g->op_count; ++i)
        if (g->ops[i].origin && !strcmp(xsq_string(g, g->ops[i].origin), origin))
            return i;
    return XSQ_NONE;
}

uint32_t xsq_find_func(const struct xsq_graph *g, const char *name)
{
    for (uint32_t i = 0; i < g->func_count; ++i)
        if (!strcmp(xsq_string(g, g->funcs[i].name), name))
            return i;
    return XSQ_NONE;
}

static uint32_t in_vn(const struct xsq_graph *g, const struct xsq_op *op, uint32_t i)
{
    return g->inputs[op->in_first + i];
}

static uint32_t in_size(const struct xsq_graph *g, const struct xsq_op *op, uint32_t i)
{
    uint32_t v = in_vn(g, op, i);
    return v == XSQ_NONE ? 0 : g->vns[v].size;
}

static int is_constant(const struct xsq_graph *g, uint32_t vn)
{
    return vn != XSQ_NONE && g->spaces[g->vns[vn].space].cls == XSQ_SPACE_CONSTANT;
}

static enum xsq_status check_widths(struct xsq_graph *g, const struct xsq_op *op)
{
    const char *name = xsq_opcode_name(g, op);
    uint32_t out = op->out == XSQ_NONE ? 0 : g->vns[op->out].size;
    uint32_t n = op->in_count;
    unsigned rule = op->opcode <= XSQ_OP_UNKNOWN ? opcode_widths[op->opcode] : W_ANY;
    unsigned cls = xsq_opcode_class(op->opcode);
#define NEED(cond, what)                                                                          \
    do {                                                                                          \
        if (!(cond))                                                                              \
            return fail(g, op->line, "op %u %s: width error: %s", op->id, name, what);            \
    } while (0)
    if (cls == XSQ_CLASS_DATA || cls == XSQ_CLASS_PHI || cls == XSQ_CLASS_INDIRECT ||
        cls == XSQ_CLASS_LOAD)
        NEED(op->out != XSQ_NONE, "missing output");
    if (cls == XSQ_CLASS_STORE || cls == XSQ_CLASS_BRANCH || cls == XSQ_CLASS_CBRANCH ||
        cls == XSQ_CLASS_BRANCHIND || cls == XSQ_CLASS_RETURN)
        NEED(op->out == XSQ_NONE, "unexpected output");
    switch (rule) {
    case W_UNARY:
        NEED(n == 1 && in_size(g, op, 0) == out, "output size must equal input");
        break;
    case W_BINARY:
        NEED(n == 2 && in_size(g, op, 0) == out && in_size(g, op, 1) == out,
             "operands and output must have equal size");
        break;
    case W_CMP:
        NEED(n == 2 && out == 1 && in_size(g, op, 0) == in_size(g, op, 1),
             "comparison needs equal operands and 1-byte result");
        break;
    case W_EXTEND:
        NEED(n == 1 && out > in_size(g, op, 0), "extension must widen");
        break;
    case W_SHIFT:
        NEED(n == 2 && in_size(g, op, 0) == out, "shifted value size must equal output");
        break;
    case W_BOOL:
        NEED(out == 1 && n >= 1 && n <= 2 && (op->opcode == XSQ_OP_BOOL_NEGATE) == (n == 1),
             "boolean arity");
        for (uint32_t i = 0; i < n; ++i)
            NEED(in_size(g, op, i) == 1, "boolean operands are 1 byte");
        break;
    case W_FLAG:
        NEED(n == 1 && out == 1, "flag result is 1 byte");
        break;
    case W_CONVERT:
        NEED(n == 1, "conversion takes one input");
        break;
    case W_PHI:
        NEED(n >= 1, "MULTIEQUAL needs inputs");
        for (uint32_t i = 0; i < n; ++i)
            NEED(in_size(g, op, i) == out, "merge inputs must equal output size");
        break;
    case W_INDIRECT:
        NEED(n == 2 && in_size(g, op, 0) == out && op->iop != XSQ_NONE,
             "INDIRECT needs value and @op");
        break;
    case W_PIECE:
        NEED(n == 2 && out == in_size(g, op, 0) + in_size(g, op, 1), "concat size");
        break;
    case W_SUBPIECE: {
        NEED(n == 2 && is_constant(g, in_vn(g, op, 1)), "SUBPIECE offset must be constant");
        uint64_t offset = g->vns[in_vn(g, op, 1)].offset;
        NEED(offset < in_size(g, op, 0) && out + offset <= in_size(g, op, 0),
             "truncation exceeds input");
        break;
    }
    case W_PTRADD:
        NEED(n == 3 && in_size(g, op, 0) == out && is_constant(g, in_vn(g, op, 2)),
             "PTRADD needs base, index, constant element size");
        break;
    case W_PTRSUB:
        NEED(n == 2 && in_size(g, op, 0) == out, "PTRSUB size");
        break;
    case W_LOAD:
        NEED(n == 2 && is_constant(g, in_vn(g, op, 0)), "LOAD needs space constant, address");
        break;
    case W_STORE:
        NEED(n == 3 && is_constant(g, in_vn(g, op, 0)), "STORE needs space, address, value");
        break;
    case W_CBRANCH:
        NEED(n == 2 && in_size(g, op, 1) == 1, "CBRANCH needs target and 1-byte condition");
        break;
    default:
        break;
    }
    if (cls == XSQ_CLASS_CALL || cls == XSQ_CLASS_BRANCH || cls == XSQ_CLASS_BRANCHIND)
        NEED(n >= 1, "missing target");
    if (rule == W_LOAD || rule == W_STORE) {
        uint64_t space = g->vns[in_vn(g, op, 0)].offset;
        uint32_t i = 0;
        while (i < g->space_count && g->spaces[i].id != space)
            ++i;
        NEED(i < g->space_count, "memory op names an undefined space");
        NEED(g->spaces[i].cls != XSQ_SPACE_CONSTANT, "memory op on constant space");
    }
#undef NEED
    return XSQ_OK;
}

static int is_terminator(unsigned opcode)
{
    unsigned c = xsq_opcode_class(opcode);
    return c == XSQ_CLASS_BRANCH || c == XSQ_CLASS_CBRANCH || c == XSQ_CLASS_BRANCHIND ||
           c == XSQ_CLASS_RETURN;
}

static enum xsq_status check_block(struct xsq_graph *g, uint32_t bi)
{
    const struct xsq_block *b = &g->blocks[bi];
    struct xsq_func *f = &g->funcs[b->func];
    for (uint32_t i = 0; i + 1 < b->op_count; ++i)
        if (is_terminator(g->ops[b->op_first + i].opcode))
            return fail(g, g->ops[b->op_first + i].line,
                        "op %u: control transfer before end of block %u",
                        g->ops[b->op_first + i].id, b->id);
    unsigned last = b->op_count ? xsq_opcode_class(g->ops[b->op_first + b->op_count - 1].opcode)
                                : XSQ_CLASS_DATA;
    unsigned kinds[5] = {0};
    for (uint32_t i = 0; i < b->succ_count; ++i)
        kinds[g->edges[g->succ[b->succ_first + i]].kind]++;
    unsigned n = b->succ_count;
    switch (last) {
    case XSQ_CLASS_CBRANCH:
        if (n != 2 || kinds[XSQ_EDGE_TRUE] != 1 || kinds[XSQ_EDGE_FALSE] != 1)
            return fail(g, b->line, "block %u: CBRANCH needs one true and one false edge", b->id);
        break;
    case XSQ_CLASS_BRANCH:
        if (n != 1 || kinds[XSQ_EDGE_JUMP] + kinds[XSQ_EDGE_FALL] != 1)
            return fail(g, b->line, "block %u: BRANCH needs exactly one jump edge", b->id);
        break;
    case XSQ_CLASS_RETURN:
        if (n)
            return fail(g, b->line, "block %u: RETURN block has successors", b->id);
        break;
    case XSQ_CLASS_BRANCHIND:
        if (kinds[XSQ_EDGE_SWITCH] != n)
            return fail(g, b->line, "block %u: BRANCHIND successors must be switch edges", b->id);
        if (!n)
            f->cfg_incomplete = 1;
        break;
    default:
        /* Fallthrough or no successor (a call that does not return, or halt). */
        if (n > 1 || (n == 1 && kinds[XSQ_EDGE_FALL] + kinds[XSQ_EDGE_JUMP] != 1))
            return fail(g, b->line, "block %u: non-branch end needs at most one fall edge", b->id);
        break;
    }
    return XSQ_OK;
}

/* Def-use cycles are legal only through MULTIEQUAL/INDIRECT merges. Iterative
 * DFS over defining ops, so deep chains cannot exhaust the C stack. */
static enum xsq_status check_acyclic(struct xsq_graph *g, struct parser *p)
{
    uint8_t *color = NULL;
    uint32_t *stack = NULL, *next = NULL;
    enum xsq_status s = charge(g, 0, (size_t)(g->op_count ? g->op_count : 1) +
                                         2 * ((size_t)g->op_count + 1) * sizeof(uint32_t));
    if (s)
        return s;
    color = xsq__calloc(g->op_count ? g->op_count : 1, 1);
    stack = xsq__malloc(((size_t)g->op_count + 1) * sizeof *stack);
    next = xsq__malloc(((size_t)g->op_count + 1) * sizeof *next);
    if (!color || !stack || !next) {
        s = no_memory(g, 0);
        goto done;
    }
    for (uint32_t root = 0; root < g->op_count && !s; ++root) {
        if ((root & 4095) == 0 && (s = poll_cancel(p)))
            break;
        if (color[root])
            continue;
        uint32_t depth = 0;
        stack[depth] = root;
        next[depth++] = 0;
        color[root] = 1;
        while (depth) {
            uint32_t o = stack[depth - 1];
            const struct xsq_op *op = &g->ops[o];
            unsigned cls = xsq_opcode_class(op->opcode);
            uint32_t i = next[depth - 1]++;
            if (cls == XSQ_CLASS_PHI || cls == XSQ_CLASS_INDIRECT || i >= op->in_count) {
                color[o] = 2;
                depth--;
                continue;
            }
            uint32_t v = in_vn(g, op, i);
            if (v == XSQ_NONE || g->vns[v].def == XSQ_NONE)
                continue;
            uint32_t d = g->vns[v].def;
            if (color[d] == 1) {
                s = fail(g, op->line, "op %u: data-flow cycle without a merge (not SSA)", op->id);
                break;
            }
            if (!color[d]) {
                color[d] = 1;
                stack[depth] = d;
                next[depth++] = 0;
            }
        }
    }
done:
    xsq__free(color);
    xsq__free(stack);
    xsq__free(next);
    return s;
}

static enum xsq_status group_edges(struct xsq_graph *g, int by_target, uint32_t **out)
{
    enum xsq_status s = charge(g, 0, ((size_t)g->edge_count + 1) * sizeof(uint32_t));
    if (s)
        return s;
    uint32_t *list = xsq__malloc(((size_t)g->edge_count + 1) * sizeof *list);
    if (!list)
        return no_memory(g, 0);
    for (uint32_t b = 0; b < g->block_count; ++b) {
        if (by_target)
            g->blocks[b].pred_count = 0;
        else
            g->blocks[b].succ_count = 0;
    }
    for (uint32_t e = 0; e < g->edge_count; ++e) {
        struct xsq_block *b = &g->blocks[by_target ? g->edges[e].to : g->edges[e].from];
        if (by_target)
            b->pred_count++;
        else
            b->succ_count++;
    }
    uint32_t position = 0;
    for (uint32_t b = 0; b < g->block_count; ++b) {
        struct xsq_block *block = &g->blocks[b];
        uint32_t *first = by_target ? &block->pred_first : &block->succ_first;
        uint32_t count = by_target ? block->pred_count : block->succ_count;
        *first = position;
        position += count;
        if (by_target)
            block->pred_count = 0;
        else
            block->succ_count = 0;
    }
    for (uint32_t e = 0; e < g->edge_count; ++e) { /* file order within each block */
        struct xsq_block *b = &g->blocks[by_target ? g->edges[e].to : g->edges[e].from];
        if (by_target)
            list[b->pred_first + b->pred_count++] = e;
        else
            list[b->succ_first + b->succ_count++] = e;
    }
    *out = list;
    return XSQ_OK;
}

static enum xsq_status resolve(struct xsq_graph *g, struct parser *p)
{
    enum xsq_status s;
    if ((s = poll_cancel(p)) ||
        (s = build_index(g, g->block_count, &g->block_by_id, cmp_block_id, g->blocks,
                         sizeof *g->blocks, offsetof(struct xsq_block, line), "block")))
        return s;
    if ((s = poll_cancel(p)) || (s = build_index(g, g->vn_count, &g->vn_by_id, cmp_vn_id, g->vns, sizeof *g->vns,
                         offsetof(struct xsq_vn, line), "varnode")))
        return s;
    for (uint32_t f = 0; f < g->func_count; ++f)
        if (!g->funcs[f].block_count)
            return fail(g, g->funcs[f].line, "function %u has no blocks", g->funcs[f].id);
    /* ops: block ids to indices, then group by block in sequence order */
    for (uint32_t i = 0; i < g->op_count; ++i) {
        struct xsq_op *op = &g->ops[i];
        uint32_t b = search(g->block_by_id, g->block_count, op->block, g->blocks,
                            sizeof *g->blocks);
        if (b == XSQ_NONE)
            return fail(g, op->line, "op %u: undefined block %u", op->id, op->block);
        if (g->blocks[b].func != op->func)
            return fail(g, op->line, "op %u: cross-function reference to block %u", op->id,
                        op->block);
        op->block = b;
    }
    if ((s = poll_cancel(p)))
        return s;
    qsort(g->ops, g->op_count, sizeof *g->ops, cmp_op_order);
    if ((s = poll_cancel(p)) || (s = build_index(g, g->op_count, &g->op_by_id, cmp_op_id, g->ops, sizeof *g->ops,
                         offsetof(struct xsq_op, line), "op")))
        return s;
    for (uint32_t f = 0; f < g->func_count; ++f)
        g->funcs[f].op_first = XSQ_NONE;
    for (uint32_t i = 0; i < g->op_count; ++i) {
        struct xsq_op *op = &g->ops[i];
        struct xsq_block *b = &g->blocks[op->block];
        struct xsq_func *f = &g->funcs[op->func];
        if (!b->op_count)
            b->op_first = i;
        else if (g->ops[i - 1].seq == op->seq)
            return fail(g, op->line, "op %u: duplicate sequence %u in block %u", op->id, op->seq,
                        b->id);
        b->op_count++;
        if (f->op_first == XSQ_NONE)
            f->op_first = i;
        f->op_count++;
    }
    for (uint32_t f = 0; f < g->func_count; ++f)
        if (g->funcs[f].op_first == XSQ_NONE)
            g->funcs[f].op_first = 0;
    /* operands and definitions */
    for (uint32_t i = 0; i < g->op_count; ++i) {
        struct xsq_op *op = &g->ops[i];
        if ((i & 4095) == 0 && (s = poll_cancel(p)))
            return s;
        for (uint32_t k = 0; k < op->in_count; ++k) {
            uint32_t *slot = &g->inputs[op->in_first + k];
            if (*slot == XSQ_NONE)
                continue; /* INDIRECT op reference */
            uint32_t raw = *slot;
            uint32_t v = xsq_find_vn(g, raw);
            if (v == XSQ_NONE)
                return fail(g, op->line, "op %u: undefined varnode %u", op->id, raw);
            if (g->vns[v].func != op->func)
                return fail(g, op->line, "op %u: cross-function reference to varnode %u",
                            op->id, raw);
            *slot = v;
        }
        if (op->out != XSQ_NONE) {
            uint32_t raw = op->out;
            uint32_t v = xsq_find_vn(g, raw);
            if (v == XSQ_NONE)
                return fail(g, op->line, "op %u: undefined output varnode %u", op->id, raw);
            if (g->vns[v].func != op->func)
                return fail(g, op->line, "op %u: cross-function output varnode %u", op->id, raw);
            struct xsq_vn *vn = &g->vns[v];
            if (vn->def != XSQ_NONE)
                return fail(g, op->line, "varnode %u defined twice (not SSA)", raw);
            if (vn->flags & (XSQ_VN_INPUT | XSQ_VN_ANNOTATION))
                return fail(g, op->line, "input/annotation varnode %u has a definition", raw);
            if (g->spaces[vn->space].cls == XSQ_SPACE_CONSTANT)
                return fail(g, op->line, "op %u writes a constant", op->id);
            vn->def = i;
            op->out = v;
        }
        if (op->iop != XSQ_NONE) {
            uint32_t raw = op->iop;
            uint32_t target = xsq_find_op(g, raw);
            if (target == XSQ_NONE)
                return fail(g, op->line, "op %u: undefined @op %u", op->id, raw);
            if (g->ops[target].func != op->func)
                return fail(g, op->line, "op %u: cross-function @op %u", op->id, raw);
            op->iop = target;
        }
    }
    for (uint32_t v = 0; v < g->vn_count; ++v) {
        const struct xsq_vn *vn = &g->vns[v];
        if ((v & 4095) == 0 && (s = poll_cancel(p)))
            return s;
        if (vn->def == XSQ_NONE && !(vn->flags & (XSQ_VN_INPUT | XSQ_VN_ANNOTATION)) &&
            g->spaces[vn->space].cls != XSQ_SPACE_CONSTANT)
            return fail(g, vn->line, "varnode %u has neither a definition nor input flag",
                        vn->id);
    }
    /* edges */
    for (uint32_t e = 0; e < g->edge_count; ++e) {
        struct xsq_edge *edge = &g->edges[e];
        uint32_t func = edge->from;
        if ((e & 4095) == 0 && (s = poll_cancel(p)))
            return s;
        uint32_t a = search(g->block_by_id, g->block_count, p->edge_from_raw[e], g->blocks,
                            sizeof *g->blocks);
        uint32_t b = search(g->block_by_id, g->block_count, p->edge_to_raw[e], g->blocks,
                            sizeof *g->blocks);
        if (a == XSQ_NONE || b == XSQ_NONE)
            return fail(g, edge->line, "edge references undefined block");
        if (g->blocks[a].func != func || g->blocks[b].func != func)
            return fail(g, edge->line, "edge: cross-function block reference");
        edge->from = a;
        edge->to = b;
    }
    if ((s = group_edges(g, 0, &g->succ)) || (s = group_edges(g, 1, &g->pred)))
        return s;
    if ((s = poll_cancel(p)))
        return s;
    for (uint32_t b = 0; b < g->block_count; ++b)
        for (uint32_t i = 0; i < g->blocks[b].succ_count; ++i)
            for (uint32_t j = i + 1; j < g->blocks[b].succ_count; ++j)
                if (g->edges[g->succ[g->blocks[b].succ_first + i]].kind ==
                        g->edges[g->succ[g->blocks[b].succ_first + j]].kind &&
                    g->edges[g->succ[g->blocks[b].succ_first + i]].kind != XSQ_EDGE_SWITCH)
                    return fail(g, g->blocks[b].line, "block %u: duplicate edge kind",
                                g->blocks[b].id);
    for (uint32_t f = 0; f < g->func_count; ++f) {
        struct xsq_func *fn = &g->funcs[f];
        for (uint32_t b = fn->block_first; b < fn->block_first + fn->block_count; ++b)
            if (g->blocks[b].start == fn->entry && fn->entry_block == XSQ_NONE)
                fn->entry_block = b;
        if (fn->entry_block == XSQ_NONE)
            return fail(g, fn->line, "function %u: no block starts at entry", fn->id);
    }
    for (uint32_t b = 0; b < g->block_count; ++b)
        if (((b & 4095) == 0 && (s = poll_cancel(p))) || (s = check_block(g, b)))
            return s;
    for (uint32_t i = 0; i < g->op_count; ++i) {
        struct xsq_op *op = &g->ops[i];
        if (((i & 4095) == 0 && (s = poll_cancel(p))) || (s = check_widths(g, op)))
            return s;
        if (op->opcode == XSQ_OP_MULTIEQUAL && op->in_count != g->blocks[op->block].pred_count)
            return fail(g, op->line, "op %u: MULTIEQUAL has %u inputs for %u predecessors",
                        op->id, op->in_count, g->blocks[op->block].pred_count);
    }
    for (uint32_t c = 0; c < g->call_count; ++c) {
        uint32_t o = xsq_find_op(g, g->calls[c].op);
        if (o == XSQ_NONE || xsq_opcode_class(g->ops[o].opcode) != XSQ_CLASS_CALL)
            return fail(g, 0, "call annotation for non-call op %u", g->calls[c].op);
        g->calls[c].op = o;
    }
    if ((s = poll_cancel(p)))
        return s;
    return check_acyclic(g, p);
}

void xsq_free(struct xsq_graph *g)
{
    free(g->spaces);
    free(g->vns);
    free(g->ops);
    free(g->blocks);
    free(g->edges);
    free(g->funcs);
    free(g->readonly);
    free(g->calls);
    free(g->inputs);
    free(g->succ);
    free(g->pred);
    free(g->op_by_id);
    free(g->vn_by_id);
    free(g->block_by_id);
    free(g->strings);
    char error[sizeof g->error];
    uint32_t line = g->error_line;
    memcpy(error, g->error, sizeof error);
    memset(g, 0, sizeof *g);
    memcpy(g->error, error, sizeof error);
    g->error_line = line;
}

/* Load with a budget; preload is the bytes already charged by the caller
 * (the file buffer) and counts toward the same budget. */
static enum xsq_status load(const char *bytes, size_t size, const struct xsq_load_budget *b,
                            struct xsq_graph *g, size_t preload)
{
    memset(g, 0, sizeof *g);
    g->load_max_bytes = b && b->max_bytes ? b->max_bytes : XSQ_LOAD_DEFAULT_BYTES;
    struct parser p = {.g = g, .func = XSQ_NONE, .cancel = b ? b->cancel : NULL};
    char *line = NULL, **tok = NULL;
    /* Cancellation and the size limit come before any size-dependent work;
     * the identity hash then runs in 1 MiB chunks, polling between chunks. */
    enum xsq_status s = poll_cancel(&p);
    if (s)
        goto done;
    if ((s = charge(g, 0, preload)))
        goto done;
    if (size > XSQ_MAX_FILE_BYTES) {
        s = limit(g, 0, "file bytes");
        goto done;
    }
    {
        struct xsq_sha256 h;
        xsq_sha256_init(&h);
        for (size_t at = 0; at < size;) {
            size_t n = size - at < ((size_t)1 << 20) ? size - at : (size_t)1 << 20;
            if ((s = poll_cancel(&p)))
                goto done;
            xsq_sha256_update(&h, bytes + at, n);
            xsq__count_hashed(n);
            at += n;
        }
        xsq_sha256_final(&h, g->input_sha256);
    }
    if ((s = charge(g, 0, XSQ_MAX_LINE_BYTES + 1 + XSQ_MAX_TOKENS * sizeof *tok)))
        goto done;
    line = xsq__malloc(XSQ_MAX_LINE_BYTES + 1);
    tok = xsq__malloc(XSQ_MAX_TOKENS * sizeof *tok);
    if (!line || !tok) {
        s = no_memory(g, 0);
        goto done;
    }
    size_t at = 0;
    while (at < size && !s) {
        p.line++;
        if ((p.line & 255) == 0 && (s = poll_cancel(&p)))
            break;
        size_t end = at;
        while (end < size && bytes[end] != '\n')
            ++end;
        if (end - at > XSQ_MAX_LINE_BYTES) {
            s = limit(g, p.line, "line bytes");
            break;
        }
        if (end == size) {
            s = fail(g, p.line, "truncated: last line has no newline");
            break;
        }
        size_t length = end - at;
        memcpy(line, bytes + at, length);
        line[length] = 0;
        at = end + 1;
        if (memchr(line, 0, length)) {
            s = fail(g, p.line, "NUL byte in line");
            break;
        }
        char *hash = strchr(line, '#');
        if (hash)
            *hash = 0;
        unsigned n = 0;
        for (char *q = line; *q;) {
            while (*q == ' ' || *q == '\t' || *q == '\r')
                *q++ = 0;
            if (!*q)
                break;
            if (n == XSQ_MAX_TOKENS) {
                s = limit(g, p.line, "tokens per line");
                break;
            }
            tok[n++] = q;
            while (*q && *q != ' ' && *q != '\t' && *q != '\r')
                ++q;
        }
        if (s || !n)
            continue;
        s = parse_line(&p, tok, n);
    }
    if (!s && !p.seen_end)
        s = fail(g, p.line, "truncated: missing end");
    if (!s && !g->func_count)
        s = fail(g, p.line, "no functions");
    if (!s)
        s = resolve(g, &p);
done:
    xsq__free(line);
    xsq__free(tok);
    xsq__free(p.edge_from_raw);
    xsq__free(p.edge_to_raw);
    if (s) {
        size_t used = g->load_bytes, max = g->load_max_bytes;
        xsq_free(g);
        g->load_bytes = used;
        g->load_max_bytes = max;
    }
    return s;
}

enum xsq_status xsq_load_buffer_budget(const char *bytes, size_t size,
                                       const struct xsq_load_budget *b, struct xsq_graph *g)
{
    return load(bytes, size, b, g, 0);
}

enum xsq_status xsq_load_buffer(const char *bytes, size_t size, struct xsq_graph *g)
{
    return load(bytes, size, NULL, g, 0);
}

enum xsq_status xsq_load_file_budget(const char *path, const struct xsq_load_budget *b,
                                     struct xsq_graph *g)
{
    memset(g, 0, sizeof *g);
    size_t max = b && b->max_bytes ? b->max_bytes : XSQ_LOAD_DEFAULT_BYTES;
    if (xsq_cancel_requested(b ? b->cancel : NULL)) {
        snprintf(g->error, sizeof g->error, "load cancelled");
        return XSQ_CANCELLED;
    }
    FILE *file = fopen(path, "rb");
    if (!file) {
        snprintf(g->error, sizeof g->error, "cannot open %s: %s", path, strerror(errno));
        return XSQ_IO;
    }
    struct stat st;
    if (fstat(fileno(file), &st) != 0 || !S_ISREG(st.st_mode)) {
        fclose(file);
        snprintf(g->error, sizeof g->error, "%s is not a regular file", path);
        return XSQ_IO;
    }
    if ((uint64_t)st.st_size > XSQ_MAX_FILE_BYTES) {
        fclose(file);
        return limit(g, 0, "file bytes");
    }
    size_t want = (size_t)st.st_size + 1; /* +1 detects growth while reading */
    if (want > max) {
        fclose(file);
        g->load_max_bytes = max;
        snprintf(g->error, sizeof g->error, "load budget exceeded: file buffer %zu > %zu bytes", want, max);
        return XSQ_LIMIT;
    }
    char *bytes = xsq__malloc(want);
    if (!bytes) {
        fclose(file);
        snprintf(g->error, sizeof g->error, "allocation failed");
        return XSQ_NO_MEMORY;
    }
    size_t size = fread(bytes, 1, want, file);
    int error = ferror(file);
    fclose(file);
    enum xsq_status s;
    if (error) {
        snprintf(g->error, sizeof g->error, "read error on %s", path);
        s = XSQ_IO;
    } else if (size != (size_t)st.st_size) {
        snprintf(g->error, sizeof g->error, "%s changed size while being read", path);
        s = XSQ_IO;
    } else {
        s = load(bytes, size, b, g, want);
    }
    xsq__free(bytes);
    return s;
}

enum xsq_status xsq_load_file(const char *path, struct xsq_graph *g)
{
    return xsq_load_file_budget(path, NULL, g);
}
