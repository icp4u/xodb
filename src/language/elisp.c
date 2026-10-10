#include "elisp.h"
#include <stdio.h>
#include <string.h>

#define TAG_MASK (~XEL_C_VALMASK)
#define INT_MASK ((UINT64_C(1) << XEL_C_INTTYPEBITS) - 1)
#define PVEC_FLAGS (XEL_C_PSEUDOVECTOR_FLAG | XEL_C_PVEC_TYPE_MASK)

struct binding_history { uint64_t symbol, value, slot; uint32_t known; };

static int fail(struct xel_reader *r, const char *why) {
    if (!r->error) r->error = why;
    return 0;
}
static int read_bytes(struct xel_reader *r, uint64_t at, void *out, size_t n) {
    if (r->error) return 0;
    if (!n) return 1;
    if (!r->read || at < 4096 || n - 1 > UINT64_MAX - at)
        return fail(r, "ElispAddressInvalid");
    if (r->reads >= XEL_READ_LIMIT || r->bytes > XEL_BYTE_LIMIT || n > XEL_BYTE_LIMIT - r->bytes)
        return fail(r, "ElispReadLimit");
    ++r->reads; r->bytes += n;
    return !r->read(r->context, at, out, n) || fail(r, "ElispMemoryUnavailable");
}
static uint64_t word(struct xel_reader *r, uint64_t at, size_t n) {
    unsigned char bytes[8]; uint64_t value = 0;
    if (n > sizeof bytes || !read_bytes(r, at, bytes, n)) return 0;
    for (size_t i = 0; i < n; ++i) value |= (uint64_t)bytes[i] << (8 * i);
    return value;
}
static uint64_t field(const struct xel_layout *l, struct xel_reader *r, uint64_t at, unsigned f) {
    if (at < 4096 || at > UINT64_MAX - l->fields[f].offset) {
        fail(r, "ElispAddressInvalid"); return 0;
    }
    return word(r, at + l->fields[f].offset, l->fields[f].size);
}
static const char *layout_check(const struct xel_layout *l) {
    if (!l || !l->build_id_len || l->build_id_len > sizeof l->build_id) return "ElispLayoutInvalid";
    for (unsigned t = 0; t < XEL_TYPE_COUNT; ++t)
        if (!l->sizes[t] || l->sizes[t] > 65536) return "ElispLayoutInvalid";
#define XEL_FIELD(key, owner, path, kind, width) \
    if ((width && l->fields[XEL_##key].size != width) || l->fields[XEL_##key].offset > l->sizes[XEL_T_##owner] || \
        l->fields[XEL_##key].size > l->sizes[XEL_T_##owner] - l->fields[XEL_##key].offset) return "ElispLayoutInvalid";
#include "elisp_fields.inc"
#undef XEL_FIELD
    if (l->fields[XEL_MAIN_STATE].size != l->sizes[XEL_T_THREAD]) return "ElispLayoutInvalid";
    if (l->fields[XEL_VECTOR_CONTENTS].size || l->fields[XEL_BC_STACK].size) return "ElispLayoutInvalid";
    return NULL;
}
static int constants(struct xel_reader *r, const struct xel_context *c) {
    if (!c || c->lispsym < 4096 || (c->lispsym & 7)) return fail(r, "ElispSymbolsUnavailable");
#define XEL_GLOBAL(name, width, value) \
    if (word(r, c->globals[XEL_G_##name], width) != value || r->error) \
        return fail(r, "ElispTagConstantsMismatch");
#include "elisp_globals.inc"
#undef XEL_GLOBAL
    return 1;
}
/* Render bytes unambiguously without assuming that Emacs's internal multibyte
 * encoding is UTF-8. Names preserve printable ASCII and escape other bytes. */
static void name(const struct xel_layout *l, struct xel_reader *r, const struct xel_context *c,
                 struct xel_frame *f) {
    if ((f->function & TAG_MASK) != XEL_C_Lisp_Symbol) {
        snprintf(f->name, sizeof f->name, "<function object>");
        f->name_reason = "ElispFunctionNotSymbol"; return;
    }
    /* Symbol words are signed offsets represented modulo the target word size.
     * Addition here intentionally wraps; ordinary address additions do not. */
    uint64_t symbol = c->lispsym + f->function;
    uint64_t string = field(l, r, symbol, XEL_SYMBOL_NAME);
    if (r->error) return;
    if ((string & TAG_MASK) != XEL_C_Lisp_String) { f->name_reason = "ElispSymbolNameInvalid"; return; }
    uint64_t at = string & XEL_C_VALMASK;
    int64_t chars = (int64_t)field(l, r, at, XEL_STRING_CHARS);
    int64_t bytes = (int64_t)field(l, r, at, XEL_STRING_BYTES);
    uint64_t data = field(l, r, at, XEL_STRING_DATA);
    if (r->error) return;
    if (chars < 0 || bytes < -3 || (bytes >= 0 && chars > bytes)) {
        f->name_reason = "ElispStringHeaderInvalid"; return;
    }
    uint64_t length = bytes < 0 ? (uint64_t)chars : (uint64_t)bytes;
    unsigned char raw[192]; size_t n = length < sizeof raw ? (size_t)length : sizeof raw;
    if (!read_bytes(r, data, raw, n)) return;
    size_t used = 0, i = 0;
    for (; i < n; ++i) {
        unsigned ch = raw[i]; size_t need = ch >= 32 && ch < 127 && ch != '\\' ? 1 : 4;
        if (used + need >= sizeof f->name) break;
        if (need == 1) f->name[used++] = (char)ch;
        else { snprintf(f->name + used, sizeof f->name - used, "\\x%02x", ch); used += 4; }
    }
    f->name[used] = 0;
    if (i < length) f->name_reason = "ElispNameTruncated";
    else if (bytes >= 0 && chars != bytes) f->name_reason = "ElispNameEscapedBytes";
}
static int control(struct xel_stack *out, uint64_t at, uint64_t depth, unsigned kind, unsigned tag,
                   const char *reason) {
    if (out->control_count == XEL_STACK_CONTROLS) { out->reason = "ElispControlLimit"; return 0; }
    out->controls[out->control_count++] = (struct xel_control){
        .record = at, .depth = depth, .kind = kind, .runtime_kind = tag, .frame = SIZE_MAX, .reason = reason
    };
    return 1;
}
int xel_stack_frames_available(const struct xel_stack *out) {
    return out && (!out->reason || !strcmp(out->reason, "ElispFrameLimit") ||
        !strcmp(out->reason, "ElispControlLimit") || !strcmp(out->reason, "ElispHandlerLimit"));
}
void xel_stack_read(const struct xel_layout *l, struct xel_reader *r,
                    const struct xel_context *c, uint64_t thread, struct xel_stack *out) {
    memset(out, 0, sizeof *out); out->thread = thread;
    out->reason = layout_check(l);
    if (out->reason) return;
    if (!constants(r, c)) { out->reason = r->error; return; }
    uint64_t first = field(l, r, thread, XEL_THREAD_FIRST), top = field(l, r, thread, XEL_THREAD_TOP);
    uint64_t end = field(l, r, thread, XEL_THREAD_END), stride = l->sizes[XEL_T_SPEC];
    uint64_t handler = field(l, r, thread, XEL_THREAD_HANDLERS);
    uint64_t sentinel = field(l, r, thread, XEL_THREAD_SENTINEL);
    uint64_t first_handler = handler;
    out->first = first; out->top = top;
    if (r->error) { out->reason = r->error; return; }
    if (first < 4096 || (first & 7) || top < first || end < top ||
        (top - first) % stride || (end - first) % stride) { out->reason = "ElispSpecpdlInvalid"; return; }
    if (sentinel < 4096 || (sentinel & 7)) { out->reason = "ElispHandlerSentinelInvalid"; return; }
    if ((top - first) / stride > XEL_SPEC_LIMIT) { out->reason = "ElispSpecpdlLimit"; return; }
    const char *limit_reason = NULL;
    size_t unwind_count = 0;
    for (uint64_t at = top; at > first;) {
        at -= stride;
        uint64_t tag = field(l, r, at, XEL_SPEC_KIND);
        if (r->error) break;
        if (tag == XEL_C_SPECPDL_BACKTRACE) {
            if (out->count == XEL_STACK_FRAMES) { limit_reason = "ElispFrameLimit"; break; }
            struct xel_frame *f = &out->frames[out->count];
            f->record = at; f->depth = (at - first) / stride;
            f->function = field(l, r, at, XEL_SPEC_FUNCTION);
            f->args = field(l, r, at, XEL_SPEC_ARGS);
            f->nargs = (int64_t)field(l, r, at, XEL_SPEC_NARGS);
            if (r->error) break;
            if (f->nargs < -1 || f->nargs > 1048576 ||
                (f->nargs != 0 && (f->args < 4096 || (f->args & 7))) ||
                (f->nargs > 0 && (uint64_t)f->nargs > (UINT64_MAX - f->args) / 8)) {
                out->reason = "ElispArgumentsInvalid"; break;
            }
            f->kind_reason = "ElispFrameKindUnproved";
            name(l, r, c, f);
            if (r->error) break;
            ++out->count;
        } else if (tag <= XEL_C_SPECPDL_UNWIND_VOID) {
            if (unwind_count == XEL_CONTROL_LIMIT) {
                if (!limit_reason) limit_reason = "ElispControlLimit";
                continue;
            }
            if (!control(out, at, (at - first) / stride, XEL_UNWIND, (unsigned)tag,
                         "ElispUnwindCallbackNotEvaluated")) break;
            ++unwind_count;
        } else if (tag > XEL_C_SPECPDL_LET_DEFAULT) { out->reason = "ElispSpecpdlKindInvalid"; break; }
    }
    uint64_t seen[XEL_CONTROL_LIMIT]; size_t seen_count = 0;
    while (!r->error && handler != sentinel && !out->reason) {
        if (handler < 4096 || (handler & 7)) { out->reason = "ElispHandlerAddressInvalid"; break; }
        if (seen_count == XEL_CONTROL_LIMIT) {
            if (!limit_reason) limit_reason = "ElispHandlerLimit";
            break;
        }
        for (size_t i = 0; i < seen_count; ++i) if (seen[i] == handler) { out->reason = "ElispHandlerCycle"; break; }
        if (out->reason) break;
        seen[seen_count++] = handler;
        uint64_t tag = field(l, r, handler, XEL_HANDLER_KIND);
        uint64_t next = field(l, r, handler, XEL_HANDLER_NEXT);
        uint64_t depth_bytes = tag < XEL_C_HANDLER_BIND ? field(l, r, handler, XEL_HANDLER_DEPTH) : 0;
        if (r->error) break;
        if (tag > XEL_C_SKIP_CONDITIONS) { out->reason = "ElispHandlerKindInvalid"; break; }
        /* HANDLER_BIND and SKIP_CONDITIONS deliberately leave pdlcount unused. */
        const char *why = tag >= XEL_C_HANDLER_BIND ? "ElispHandlerDepthUnused" : NULL;
        if (!why && (depth_bytes > top - first || depth_bytes % stride)) { out->reason = "ElispHandlerDepthInvalid"; break; }
        if (!control(out, handler, why ? UINT64_MAX : depth_bytes / stride, XEL_HANDLER, (unsigned)tag, why)) break;
        handler = next;
    }
    for (size_t i = 0; i < out->control_count; ++i) {
        struct xel_control *v = &out->controls[i];
        if (v->depth == UINT64_MAX) continue;
        for (size_t j = 0; j < out->count; ++j) if (out->frames[j].depth < v->depth) { v->frame = j; break; }
    }
    if (r->error) out->reason = r->error;
    /* A second root snapshot catches changing storage in callers that fail to
     * retain the stop. The host generation check is still mandatory. */
    if (!out->reason && (field(l, r, thread, XEL_THREAD_FIRST) != first ||
        field(l, r, thread, XEL_THREAD_TOP) != top || field(l, r, thread, XEL_THREAD_END) != end ||
        field(l, r, thread, XEL_THREAD_HANDLERS) != first_handler ||
        field(l, r, thread, XEL_THREAD_SENTINEL) != sentinel)) {
        out->reason = "ElispStateChanged";
        out->count = out->control_count = 0;
    }
    if (r->error) out->reason = r->error;
    else if (!out->reason) out->reason = limit_reason;
}

void xel_stack_main(const struct xel_layout *l, struct xel_reader *r,
                    const struct xel_context *c, uint64_t current, uint64_t main,
                    int32_t pid, int32_t tid, struct xel_stack *out) {
    memset(out, 0, sizeof *out);
    out->reason = layout_check(l);
    if (out->reason) return;
    /* Linux's initial thread has TID == PID. pthread_t is not an OS TID. */
    if (pid <= 0 || tid != pid) { out->reason = "ElispThreadAssociationUnproved"; return; }
    if (main < 4096 || (main & 7) || main > UINT64_MAX - l->fields[XEL_MAIN_STATE].offset) {
        out->reason = "ElispAddressInvalid"; return;
    }
    uint64_t expected = main + l->fields[XEL_MAIN_STATE].offset;
    uint64_t thread = word(r, current, 8);
    if (r->error) { out->reason = r->error; return; }
    if (thread != expected) { out->reason = "ElispThreadAssociationUnproved"; return; }
    xel_stack_read(l, r, c, thread, out);
    if (xel_stack_frames_available(out) && word(r, current, 8) != thread) {
        out->reason = r->error ? r->error : "ElispStateChanged";
        out->count = out->control_count = 0;
    }
}

static unsigned function_kind(const struct xel_layout *l, struct xel_reader *r, uint64_t fun) {
    /* Only the proved closure representation is classified here. Native subrs,
     * cons-form lambdas and other callable objects remain explicitly unknown. */
    if ((fun & TAG_MASK) != XEL_C_Lisp_Vectorlike) return XEL_UNKNOWN;
    uint64_t at = fun & XEL_C_VALMASK;
    uint64_t header = field(l, r, at, XEL_VECTOR_HEADER);
    if ((header & PVEC_FLAGS) != (XEL_C_PSEUDOVECTOR_FLAG | (uint64_t)XEL_C_PVEC_CLOSURE << XEL_C_PSEUDOVECTOR_AREA_BITS) ||
        (header & XEL_C_PSEUDOVECTOR_SIZE_MASK) < 3 || (header & XEL_C_PSEUDOVECTOR_SIZE_MASK) > 6) return XEL_UNKNOWN;
    uint64_t offset = (uint64_t)l->fields[XEL_VECTOR_CONTENTS].offset + 8 * XEL_C_CLOSURE_CODE;
    if (at > UINT64_MAX - offset) { fail(r, "ElispAddressInvalid"); return XEL_UNKNOWN; }
    uint64_t code = word(r, at + offset, 8);
    if ((code & TAG_MASK) == XEL_C_Lisp_Cons && (code & XEL_C_VALMASK) >= 4096) return XEL_INTERPRETED;
    if ((code & TAG_MASK) == XEL_C_Lisp_String) {
        int64_t chars = (int64_t)field(l, r, code & XEL_C_VALMASK, XEL_STRING_CHARS);
        int64_t bytes = (int64_t)field(l, r, code & XEL_C_VALMASK, XEL_STRING_BYTES);
        uint64_t data = field(l, r, code & XEL_C_VALMASK, XEL_STRING_DATA);
        if (chars > 0 && bytes >= -3 && bytes < 0 && data >= 4096 && (uint64_t)chars <= UINT64_MAX - data)
            return XEL_BYTECODE;
    }
    return XEL_UNKNOWN;
}
static void clear_kinds(struct xel_stack *out) {
    for (size_t i = 0; i < out->count; ++i) {
        struct xel_frame *f = &out->frames[i];
        f->active_function = 0; f->native_frame = SIZE_MAX; f->execution_kind = XEL_UNKNOWN;
        f->kind_basis = NULL; f->kind_reason = "ElispFrameKindUnproved";
    }
}
static int bc_address(const struct xel_layout *l, uint64_t at, uint64_t start, uint64_t end) {
    return !(at & 7) && at >= start && at <= end && l->sizes[XEL_T_BC] <= end - at;
}
void xel_stack_kinds(const struct xel_layout *l, struct xel_reader *r,
                     const struct xel_context *c, const struct xel_activation *native, size_t count,
                     struct xel_stack *out) {
    if (out->count > XEL_STACK_FRAMES) { out->classification_reason = "ElispFrameLimit"; return; }
    clear_kinds(out); out->classification_reason = NULL;
    const char *why = layout_check(l);
    if (!why && (count > 64 || (count && !native))) why = "ElispNativeActivationLimit";
    if (!why && out->reason) why = "ElispPartialStack";
    if (why) { out->classification_reason = why; return; }
    if (!constants(r, c)) { out->classification_reason = r->error; return; }
    for (size_t i = 0; i < out->count && !r->error; ++i) {
        struct xel_frame *f = &out->frames[i]; const struct xel_activation *match = NULL;
        size_t matches = 0;
        if (f->nargs < 0) continue;
        for (size_t j = 0; j < count; ++j) {
            const struct xel_activation *v = &native[j];
            if (v->native_frame >= 64 || v->args < 4096 || (v->args & 7) ||
                v->nargs < 0 || v->nargs > 1048576 || v->args != f->args || v->nargs != f->nargs) continue;
            match = v; ++matches;
        }
        /* The storage must identify one logical frame as well as one native
         * offer. Zero-argument calls can otherwise share the same address. */
        size_t peers = 0;
        for (size_t j = 0; j < out->count; ++j)
            peers += out->frames[j].args == f->args && out->frames[j].nargs == f->nargs;
        if (matches != 1 || peers != 1) {
            if (matches > 1 || (matches && peers > 1)) f->kind_reason = "ElispActivationAmbiguous";
            continue;
        }
        unsigned kind = function_kind(l, r, match->function);
        if (kind != XEL_UNKNOWN && kind != match->execution_kind) {
            f->kind_reason = "ElispActivationKindMismatch";
            continue;
        }
        if (kind != XEL_UNKNOWN && !r->error) {
            f->execution_kind = kind; f->active_function = match->function;
            f->native_frame = match->native_frame; f->kind_reason = NULL;
            f->kind_basis = "live native evaluator path, unique arguments, and matching closure code kind";
        }
    }
    uint64_t fp = field(l, r, out->thread, XEL_THREAD_BC_FP);
    uint64_t start = field(l, r, out->thread, XEL_THREAD_BC_START);
    uint64_t end = field(l, r, out->thread, XEL_THREAD_BC_END);
    uint64_t original_fp = fp; size_t visited = 0;
    if (!r->error && (start < 4096 || (start & 7) || end < start || end - start > 128 * 1024 * 1024))
        why = "ElispBytecodeStackInvalid";
    while (!why && !r->error) {
        if (++visited > XEL_STACK_FRAMES) { why = "ElispBytecodeFrameLimit"; break; }
        if (!bc_address(l, fp, start, end)) { why = "ElispBytecodeFrameInvalid"; break; }
        uint64_t previous = field(l, r, fp, XEL_BC_PREVIOUS);
        uint64_t top = field(l, r, fp, XEL_BC_TOP);
        uint64_t fun = field(l, r, fp, XEL_BC_FUNCTION);
        if (r->error) break;
        if (!previous) {
            if (fp != start || fun || top) why = "ElispBytecodeSentinelInvalid";
            break;
        }
        if (previous >= fp || !bc_address(l, previous, start, end) ||
            l->sizes[XEL_T_BC] > fp - previous) { why = "ElispBytecodeChainInvalid"; break; }
        if (function_kind(l, r, fun) != XEL_BYTECODE) { why = "ElispBytecodeFunctionUnproved"; break; }
        if (top) {
            uint64_t grandparent = field(l, r, previous, XEL_BC_PREVIOUS);
            if (!bc_address(l, grandparent, start, end) || grandparent >= previous ||
                l->sizes[XEL_T_BC] > previous - grandparent || (top & 7) ||
                top < grandparent + l->fields[XEL_BC_STACK].offset || top >= previous || previous - top < 8) {
                why = "ElispBytecodeArgumentsInvalid"; break;
            }
            uint64_t stored = word(r, top, 8); size_t found = SIZE_MAX, matches = 0;
            for (size_t i = 0; i < out->count; ++i) {
                const struct xel_frame *f = &out->frames[i];
                if (f->args != top + 8 || f->nargs < 0) continue;
                if (f->function != stored) { why = "ElispBytecodeFunctionMismatch"; break; }
                if ((uint64_t)f->nargs > (previous - top - 8) / 8) { why = "ElispBytecodeArgumentsInvalid"; break; }
                found = i; ++matches;
            }
            if (why) break;
            if (matches == 1) {
                struct xel_frame *f = &out->frames[found];
                if (f->execution_kind != XEL_UNKNOWN && f->active_function != fun) { why = "ElispActivationConflict"; break; }
                f->execution_kind = XEL_BYTECODE; f->active_function = fun; f->kind_reason = NULL;
                f->kind_basis = "bytecode frame saved function + bounded caller slots + stored backtrace function";
            }
        }
        fp = previous;
    }
    if (!why && !r->error && (field(l, r, out->thread, XEL_THREAD_BC_FP) != original_fp ||
        field(l, r, out->thread, XEL_THREAD_BC_START) != start || field(l, r, out->thread, XEL_THREAD_BC_END) != end ||
        field(l, r, out->thread, XEL_THREAD_FIRST) != out->first || field(l, r, out->thread, XEL_THREAD_TOP) != out->top))
        why = "ElispStateChanged";
    out->classification_reason = r->error ? r->error : why;
    if (out->classification_reason) clear_kinds(out);
}

/* Value decoding stays here so stack names and values share the same bounded
 * memory reader. Output is a preview, never evidence of object liveness. */
#include <stdarg.h>
#include <math.h>
#include <stdlib.h>
struct value_node {
    char type[24], text[768];
    uint64_t count;
    const char *reason;
    unsigned truncated;
};
struct value_walk {
    const struct xel_layout *layout;
    struct xel_reader *reader;
    const struct xel_context *context;
    uint64_t path[XEL_VALUE_NODES];
    size_t path_count, nodes;
};
static void value_reason(struct value_node *n, const char *why) {
    if (!n->reason) n->reason = why;
}
static void value_text(struct value_node *n, const char *fmt, ...) {
    size_t used = strlen(n->text);
    va_list args; va_start(args, fmt);
    int count = vsnprintf(n->text + used, sizeof n->text - used, fmt, args);
    va_end(args);
    if (count < 0 || (size_t)count >= sizeof n->text - used) {
        /* A clipped formatted child can end inside UTF-8. Keep a valid prefix. */
        size_t end = strlen(n->text), start = end;
        while (start && ((unsigned char)n->text[start-1] & 0xc0) == 0x80) --start;
        if (start) {
            unsigned lead = (unsigned char)n->text[start-1];
            unsigned length = lead >= 0xf0 ? 4 : lead >= 0xe0 ? 3 : lead >= 0xc0 ? 2 : 1;
            if (end - (start-1) < length) n->text[start-1] = 0;
        }
        n->truncated = 1; value_reason(n, "ElispPreviewLimit");
    }
}
static void value_limit(struct value_node *n, const char *why) {
    value_reason(n, why); n->truncated = 1; value_text(n, "...");
}
static void value_type(struct value_node *n, const char *type) {
    snprintf(n->type, sizeof n->type, "%s", type);
}
static int value_enter(struct value_walk *w, uint64_t tagged, struct value_node *n) {
    for (size_t i = 0; i < w->path_count; ++i) if (w->path[i] == tagged) {
        value_reason(n, "ElispValueCycle"); value_text(n, "#<cycle>"); return 0;
    }
    if (w->path_count == XEL_VALUE_NODES) {
        value_limit(n, "ElispValueNodeLimit"); return 0;
    }
    w->path[w->path_count++] = tagged; return 1;
}
static uint64_t value_slot(struct value_walk *w, uint64_t at, uint64_t index) {
    if (index > (UINT64_MAX - at) / 8) { fail(w->reader, "ElispAddressInvalid"); return 0; }
    return word(w->reader, at + index * 8, 8);
}
static void value_string(struct value_walk *w, uint64_t at, struct value_node *n, int quoted) {
    const struct xel_layout *l = w->layout; struct xel_reader *r = w->reader;
    int64_t chars = (int64_t)field(l, r, at, XEL_STRING_CHARS);
    int64_t bytes = (int64_t)field(l, r, at, XEL_STRING_BYTES);
    uint64_t data = field(l, r, at, XEL_STRING_DATA);
    if (r->error) return;
    if (chars < 0 || bytes < -3 || (bytes >= 0 && (chars > bytes || (uint64_t)chars < ((uint64_t)bytes + 4) / 5))) {
        value_reason(n, "ElispStringHeaderInvalid"); return;
    }
    uint64_t length = bytes < 0 ? (uint64_t)chars : (uint64_t)bytes;
    if (data < 4096 || length > UINT64_MAX - data) { value_reason(n, "ElispStringHeaderInvalid"); return; }
    unsigned char raw[256]; size_t size = length < sizeof raw ? (size_t)length : sizeof raw;
    if (!read_bytes(r, data, raw, size)) return;
    n->count = (uint64_t)chars;
    if (quoted) value_text(n, "\"");
    size_t i = 0, characters = 0;
    while (i < size) {
        unsigned ch = raw[i], count = 1, code = ch;
        if (bytes >= 0 && ch >= 128) {
            if (ch >= 0xc0 && ch <= 0xdf) { count = 2; code = ch & 31; }
            else if (ch <= 0xef && ch >= 0xe0) { count = 3; code = ch & 15; }
            else if (ch <= 0xf7 && ch >= 0xf0) { count = 4; code = ch & 7; }
            else if (ch == 0xf8) { count = 5; code = 0; }
            else { value_reason(n, "ElispStringEncodingInvalid"); break; }
            if (count > size - i) {
                if (size == length) value_reason(n, "ElispStringEncodingInvalid");
                break;
            }
            int valid = 1;
            for (unsigned j = 1; j < count; ++j) {
                if ((raw[i+j] & 0xc0) != 0x80) valid = 0;
                code = (code << 6) | (raw[i+j] & 63);
            }
            if (count == 2 && ch < 0xc2) code += 0x3fff80;
            else if ((count == 2 && code < 128) || (count == 3 && code < 0x800) ||
                     (count == 4 && code < 0x10000) || (count == 5 && (code < 0x200000 || code > 0x3fff7f))) valid = 0;
            if (!valid) { value_reason(n, "ElispStringEncodingInvalid"); break; }
        }
        ++characters;
        if (code == '\\' || (quoted && code == '"')) value_text(n, "\\%c", code);
        else if (code == '\n') value_text(n, "\\n");
        else if (code == '\t') value_text(n, "\\t");
        else if (code == '\r') value_text(n, "\\r");
        else if (code < 32 || code == 127 || (bytes < 0 && code >= 128)) value_text(n, "\\%03o", code);
        else if (code > 0x3fff7f) value_text(n, "\\%03o", code - 0x3fff00);
        else if (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) value_text(n, "\\U%08x", code);
        else if (code >= 128) value_text(n, "%.*s", (int)count, (const char *)raw + i);
        else value_text(n, "%c", code);
        i += count;
    }
    if (size == length && i == size && characters != (uint64_t)chars) value_reason(n, "ElispStringLengthMismatch");
    if (length > i && !n->reason) value_limit(n, "ElispPreviewLimit");
    if (quoted) value_text(n, "\"");
}
static void value_decode(struct value_walk *, uint64_t, unsigned, struct value_node *, struct xel_value *);
static void value_child(struct value_walk *w, uint64_t tagged, unsigned depth, const char *key,
                        struct value_node *parent, struct value_node *child, struct xel_value *out) {
    value_decode(w, tagged, depth + 1, child, NULL);
    if (child->reason) value_reason(parent, child->reason);
    if (child->truncated) parent->truncated = 1;
    if (out && out->item_count < XEL_VALUE_ITEMS) {
        struct xel_value_item *item = &out->items[out->item_count++];
        item->tagged = tagged; item->reason = child->reason;
        size_t key_size = strlen(key);
        if (key_size >= sizeof item->key) {
            key_size = sizeof item->key - 1;
            while (key_size && ((unsigned char)key[key_size] & 0xc0) == 0x80) --key_size;
            item->reason = "ElispPreviewLimit"; parent->truncated = 1;
        }
        memcpy(item->key,key,key_size); item->key[key_size] = 0;
        snprintf(item->type, sizeof item->type, "%s", child->type);
        size_t size = strlen(child->text);
        if (size >= sizeof item->display) {
            size = sizeof item->display - 1;
            while (size && ((unsigned char)child->text[size] & 0xc0) == 0x80) --size;
            item->reason = "ElispPreviewLimit"; parent->truncated = 1;
        }
        memcpy(item->display, child->text, size); item->display[size] = 0;
    }
}
static int value_pvec(struct value_walk *w, uint64_t header, unsigned type, struct value_node *n) {
    uint64_t slots = (header & XEL_C_PSEUDOVECTOR_SIZE_MASK) + ((header & XEL_C_PSEUDOVECTOR_REST_MASK) >> XEL_C_PSEUDOVECTOR_SIZE_BITS);
    if (slots * 8 + 8 != w->layout->sizes[type]) {
        value_reason(n, "ElispPseudovectorSizeInvalid"); return 0;
    }
    return 1;
}
static void value_inner(struct value_walk *w, uint64_t tagged, unsigned depth,
                        struct value_node *n, struct xel_value *out) {
    const struct xel_layout *l = w->layout; struct xel_reader *r = w->reader;
    unsigned tag = tagged & TAG_MASK; uint64_t at = tagged & XEL_C_VALMASK;
    value_type(n, "unknown");
    if (++w->nodes > XEL_VALUE_NODES) { value_limit(n, "ElispValueNodeLimit"); return; }
    if ((tag & INT_MASK) == XEL_C_Lisp_Int0) {
        value_type(n, "fixnum"); value_text(n, "%lld", (long long)((int64_t)tagged >> XEL_C_INTTYPEBITS)); return;
    }
    if (depth > XEL_VALUE_DEPTH) { value_limit(n, "ElispValueDepthLimit"); return; }
    if (!value_enter(w, tagged, n)) return;
    if (tag == XEL_C_Lisp_Symbol) {
        value_type(n, "symbol");
        uint64_t str = field(l, r, w->context->lispsym + tagged, XEL_SYMBOL_NAME);
        if ((str & TAG_MASK) != XEL_C_Lisp_String) { value_reason(n, "ElispSymbolNameInvalid"); return; }
        value_string(w, str & XEL_C_VALMASK, n, 0); return;
    }
    if (at < 4096) { value_reason(n, "ElispAddressInvalid"); return; }
    if (tag == XEL_C_Lisp_Float) {
        value_type(n, "float"); uint64_t bits = field(l, r, at, XEL_FLOAT_DATA); double f;
        memcpy(&f, &bits, sizeof f);
        if (!isfinite(f)) { value_reason(n, "ElispFloatNonfinite"); value_text(n, "#<nonfinite float>"); return; }
        /* Keep the shortest host spelling that round-trips to these bits. */
        char number[64];
        for (unsigned digits = 1; digits <= 17; ++digits) {
            snprintf(number,sizeof number,"%.*g",(int)digits,f);
            double back = strtod(number,NULL); uint64_t back_bits;
            memcpy(&back_bits,&back,sizeof back_bits);
            if (back_bits == bits) break;
        }
        value_text(n, "%s", number);
        if (!strchr(n->text, '.') && !strchr(n->text, 'e')) value_text(n, ".0");
        return;
    }
    if (tag == XEL_C_Lisp_String) { value_type(n, "string"); value_string(w, at, n, 1); return; }
    if (tag == XEL_C_Lisp_Cons) {
        value_type(n, "list"); value_text(n, "(");
        uint64_t current = tagged;
        for (size_t i = 0; i < XEL_VALUE_ITEMS; ++i) {
            uint64_t cell = current & XEL_C_VALMASK;
            uint64_t car = field(l, r, cell, XEL_CONS_CAR), cdr = field(l, r, cell, XEL_CONS_CDR);
            if (r->error) break;
            struct value_node child; char key[32]; snprintf(key, sizeof key, "%zu", i);
            value_child(w, car, depth, key, n, &child, out);
            value_text(n, "%s", child.text); ++n->count;
            if (!cdr) break;
            if ((cdr & TAG_MASK) != XEL_C_Lisp_Cons) {
                value_child(w, cdr, depth, "cdr", n, &child, out); value_text(n, " . %s", child.text); break;
            }
            value_text(n, " ");
            if (!value_enter(w, cdr, n)) break;
            current = cdr;
            if (i + 1 == XEL_VALUE_ITEMS) value_limit(n, "ElispPreviewLimit");
        }
        value_text(n, ")"); return;
    }
    if (tag != XEL_C_Lisp_Vectorlike) { value_reason(n, "ElispTagUnsupported"); return; }
    uint64_t header = field(l, r, at, XEL_VECTOR_HEADER);
    if (r->error) return;
    uint64_t capacity = header & ~(XEL_C_PSEUDOVECTOR_FLAG | XEL_C_ARRAY_MARK_FLAG);
    unsigned pvec = 0;
    if (header & XEL_C_PSEUDOVECTOR_FLAG) {
        if (header & ~(XEL_C_PSEUDOVECTOR_FLAG | XEL_C_ARRAY_MARK_FLAG | XEL_C_PVEC_TYPE_MASK | XEL_C_PSEUDOVECTOR_SIZE_MASK | XEL_C_PSEUDOVECTOR_REST_MASK)) { value_reason(n, "ElispPseudovectorHeaderInvalid"); return; }
        pvec = (unsigned)((header & XEL_C_PVEC_TYPE_MASK) >> XEL_C_PSEUDOVECTOR_AREA_BITS); capacity = header & XEL_C_PSEUDOVECTOR_SIZE_MASK;
        if (!pvec) { value_reason(n, "ElispPseudovectorHeaderInvalid"); return; }
    }
    if (at > UINT64_MAX - l->fields[XEL_VECTOR_CONTENTS].offset) { value_reason(n, "ElispAddressInvalid"); return; }
    if (!pvec || pvec == XEL_C_PVEC_RECORD) {
        value_type(n, pvec ? "record" : "vector");
        if ((pvec && ((header & XEL_C_PSEUDOVECTOR_REST_MASK) || !capacity)) || capacity > (UINT64_MAX - at - l->fields[XEL_VECTOR_CONTENTS].offset) / 8) {
            value_reason(n, "ElispVectorHeaderInvalid"); return;
        }
        n->count = capacity; value_text(n, pvec ? "#s(" : "[");
        size_t size = capacity < XEL_VALUE_ITEMS ? (size_t)capacity : XEL_VALUE_ITEMS;
        for (size_t i = 0; i < size && !r->error; ++i) {
            struct value_node child; char key[32]; snprintf(key, sizeof key, "%zu", i);
            uint64_t v = value_slot(w, at + l->fields[XEL_VECTOR_CONTENTS].offset, i);
            value_child(w, v, depth, key, n, &child, out); value_text(n, "%s%s", i ? " " : "", child.text);
        }
        if (capacity > size) { value_text(n, " "); value_limit(n, "ElispPreviewLimit"); }
        value_text(n, pvec ? ")" : "]"); return;
    }
    struct value_node child;
    if (pvec == XEL_C_PVEC_HASH_TABLE) {
        value_type(n, "hash-table"); if (!value_pvec(w, header, XEL_T_HASH, n)) return;
        int64_t count = (int32_t)field(l, r, at, XEL_HASH_COUNT), size = (int32_t)field(l, r, at, XEL_HASH_CAPACITY);
        uint64_t pairs = field(l, r, at, XEL_HASH_PAIRS);
        if (count < 0 || size < count || (size && (pairs < 4096 || (pairs & 7))) || (uint64_t)size > (UINT64_MAX-pairs)/16) {
            value_reason(n, "ElispHashHeaderInvalid"); return;
        }
        n->count = (uint64_t)count; value_text(n, "#<hash-table %lld entries>", (long long)count);
        size_t used = 0, scanned = 0;
        for (; scanned < (uint64_t)size && scanned < 256 && used < XEL_VALUE_ITEMS && !r->error; ++scanned) {
            uint64_t key = value_slot(w, pairs, scanned * 2);
            if (key == XEL_C_Lisp_Float) continue; /* Runtime's invalid Lisp_Float null sentinel. */
            uint64_t val = value_slot(w, pairs, scanned * 2 + 1);
            struct value_node k; value_decode(w, key, depth + 1, &k, NULL);
            if (k.reason) value_reason(n, k.reason);
            if (k.truncated) n->truncated = 1;
            value_child(w, val, depth, k.text, n, &child, out); ++used;
        }
        if (used > (uint64_t)count || (scanned == (uint64_t)size && used != (uint64_t)count)) value_reason(n, "ElispHashCountMismatch");
        else if (scanned != (uint64_t)size) { n->truncated = 1; value_reason(n, "ElispPreviewLimit"); }
        return;
    }
    if (pvec == XEL_C_PVEC_BUFFER) {
        value_type(n, "buffer"); if (!value_pvec(w, header, XEL_T_BUFFER, n)) return;
        uint64_t name_ = field(l,r,at,XEL_BUFFER_NAME);
        if (!name_) { value_text(n, "#<killed buffer>"); return; }
        if ((name_ & TAG_MASK) != XEL_C_Lisp_String) { value_reason(n,"ElispBufferNameInvalid"); return; }
        int64_t point = (int64_t)field(l,r,at,XEL_BUFFER_POINT), beg = (int64_t)field(l,r,at,XEL_BUFFER_BEG), end = (int64_t)field(l,r,at,XEL_BUFFER_END);
        if (beg < 1 || point < beg || end < point) { value_reason(n,"ElispBufferBoundsInvalid"); return; }
        value_child(w,name_,depth,"name",n,&child,out); value_text(n,"#<buffer %s point=%lld>",child.text,(long long)point);
        uint64_t locals = field(l,r,at,XEL_BUFFER_LOCALS);
        value_child(w,locals,depth,"local_var_alist (explicit entries only)",n,&child,out);
        return;
    }
    if (pvec == XEL_C_PVEC_MARKER) {
        value_type(n,"marker"); if (!value_pvec(w,header,XEL_T_MARKER,n)) return;
        uint64_t buffer = field(l,r,at,XEL_MARKER_BUFFER);
        if (!buffer) { value_text(n,"#<marker in no buffer>"); return; }
        int64_t position = (int64_t)field(l,r,at,XEL_MARKER_POSITION);
        if (position < 1 || buffer < 4096 || (buffer & 7)) { value_reason(n,"ElispMarkerInvalid"); return; }
        uint64_t bh = field(l,r,buffer,XEL_BUFFER_HEADER);
        if ((bh & PVEC_FLAGS) != (XEL_C_PSEUDOVECTOR_FLAG | (uint64_t)XEL_C_PVEC_BUFFER << XEL_C_PSEUDOVECTOR_AREA_BITS)) { value_reason(n,"ElispMarkerBufferInvalid"); return; }
        value_child(w,buffer | XEL_C_Lisp_Vectorlike,depth,"buffer",n,&child,out); value_text(n,"#<marker %lld %s>",(long long)position,child.text); return;
    }
    if (pvec == XEL_C_PVEC_WINDOW) {
        value_type(n,"window"); if (!value_pvec(w,header,XEL_T_WINDOW,n)) return;
        uint64_t contents = field(l,r,at,XEL_WINDOW_CONTENTS);
        value_child(w,contents,depth,"contents",n,&child,out); value_text(n,"#<window %s>",child.text); return;
    }
    value_type(n,"pseudovector"); value_reason(n,"ElispPseudovectorUnsupported"); value_text(n,"#<pseudovector %u>",pvec);
}
static void value_decode(struct value_walk *w, uint64_t tagged, unsigned depth,
                         struct value_node *n, struct xel_value *out) {
    memset(n,0,sizeof *n); size_t path = w->path_count;
    value_inner(w,tagged,depth,n,out); w->path_count = path;
    if (w->reader->error) { n->reason = w->reader->error; n->text[0] = 0; }
    if (!n->text[0]) value_text(n,"#<%s>",n->reason ? n->reason : "unavailable");
}
void xel_value_read(const struct xel_layout *l, struct xel_reader *r,
                    const struct xel_context *c, uint64_t tagged, struct xel_value *out) {
    memset(out,0,sizeof *out); out->tagged = tagged;
    out->reason = layout_check(l);
    if (!out->reason && !constants(r,c)) out->reason = r->error;
    if (out->reason) {
        snprintf(out->type,sizeof out->type,"unavailable");
        snprintf(out->display,sizeof out->display,"#<%s>",out->reason);
        return;
    }
    struct value_walk w = {.layout=l,.reader=r,.context=c}; struct value_node n;
    value_decode(&w,tagged,0,&n,out);
    out->object = (tagged & INT_MASK) == XEL_C_Lisp_Int0 ? 0 : (tagged & TAG_MASK) == XEL_C_Lisp_Symbol ? c->lispsym+tagged : tagged & XEL_C_VALMASK;
    out->count = n.count; out->reason = n.reason; out->truncated = n.truncated;
    memcpy(out->type,n.type,sizeof out->type); memcpy(out->display,n.text,sizeof out->display);
    if (r->error) out->item_count = 0;
}

static struct xel_binding *binding_row(const struct xel_layout *l, struct xel_reader *r,
                                       const struct xel_context *c, struct xel_bindings *out,
                                       uint64_t symbol, uint64_t record, uint32_t scope) {
    if (out->count == XEL_BINDING_LIMIT) {
        out->truncated = 1; out->reason = "ElispBindingLimit"; return NULL;
    }
    struct xel_binding *row = &out->rows[out->count++];
    row->symbol = symbol; row->record = record; row->scope = scope;
    struct xel_frame f = {.function = symbol};
    name(l, r, c, &f);
    memcpy(row->name, f.name, sizeof row->name);
    row->reason = f.name_reason;
    return row;
}
static int binding_current(const struct xel_layout *l, struct xel_reader *r,
                           const struct xel_context *c, uint64_t symbol,
                           uint64_t *value, uint64_t *slot) {
    uint64_t object = c->lispsym + symbol;
    unsigned redirect = (unsigned)((field(l, r, object, XEL_SYMBOL_REDIRECT) >> 1) & 3);
    if (r->error) return 0;
    if (redirect == XEL_C_SYMBOL_PLAINVAL) {
        if (object > UINT64_MAX - l->fields[XEL_SYMBOL_VALUE].offset)
            return fail(r, "ElispAddressInvalid");
        *slot = object + l->fields[XEL_SYMBOL_VALUE].offset;
    } else if (redirect == XEL_C_SYMBOL_FORWARDED) {
        uint64_t fwd = field(l, r, object, XEL_SYMBOL_VALUE);
        if (field(l, r, fwd, XEL_FWD_KIND) != XEL_C_Lisp_Fwd_Obj || r->error) return 0;
        *slot = field(l, r, fwd, XEL_FWD_OBJECT);
    } else return 0;
    *value = word(r, *slot, 8);
    return !r->error;
}
static void lexical_bindings(const struct xel_layout *l, struct xel_reader *r,
                             const struct xel_context *c, uint64_t environment,
                             uint64_t previous, uint64_t record, struct xel_bindings *out) {
    uint64_t seen[XEL_BINDING_HISTORY]; size_t count = 0;
    for (uint64_t rest = environment; rest && rest != previous && !r->error;) {
        if ((rest & TAG_MASK) != XEL_C_Lisp_Cons) { out->reason = "ElispLexicalEnvironmentInvalid"; return; }
        if (count == XEL_BINDING_HISTORY) { out->reason = "ElispLexicalEnvironmentLimit"; out->truncated = 1; return; }
        for (size_t i = 0; i < count; ++i) if (seen[i] == rest) { out->reason = "ElispLexicalEnvironmentCycle"; return; }
        seen[count++] = rest;
        uint64_t cons = rest & XEL_C_VALMASK;
        uint64_t pair = field(l, r, cons, XEL_CONS_CAR);
        rest = field(l, r, cons, XEL_CONS_CDR);
        if (r->error) return;
        /* Bare symbols mark dynamic declarations in this environment. */
        if ((pair & TAG_MASK) == XEL_C_Lisp_Symbol) continue;
        if ((pair & TAG_MASK) != XEL_C_Lisp_Cons) { out->reason = "ElispLexicalBindingInvalid"; return; }
        pair &= XEL_C_VALMASK;
        uint64_t symbol = field(l, r, pair, XEL_CONS_CAR);
        uint64_t value = field(l, r, pair, XEL_CONS_CDR);
        if (r->error) return;
        if ((symbol & TAG_MASK) != XEL_C_Lisp_Symbol) { out->reason = "ElispBindingSymbolInvalid"; return; }
        struct xel_binding *row = binding_row(l, r, c, out, symbol, record, XEL_LEXICAL);
        if (!row) return;
        row->environment = environment; row->value = value; row->has_value = 1;
        row->slot = pair + l->fields[XEL_CONS_CDR].offset;
    }
}
void xel_bindings_read(const struct xel_layout *l, struct xel_reader *r,
                       const struct xel_context *c, const struct xel_stack *stack, size_t frame,
                       uint64_t environment_symbol_address, struct xel_bindings *out) {
    memset(out, 0, sizeof *out);
    out->reason = layout_check(l);
    if (out->reason) return;
    if (!xel_stack_frames_available(stack) || frame >= stack->count || stack->count > XEL_STACK_FRAMES) {
        out->reason = "ElispBindingFrameUnavailable"; return;
    }
    if (!constants(r, c)) { out->reason = r->error; return; }
    uint64_t first = field(l, r, stack->thread, XEL_THREAD_FIRST);
    uint64_t top = field(l, r, stack->thread, XEL_THREAD_TOP);
    uint64_t stride = l->sizes[XEL_T_SPEC], lower = stack->frames[frame].record;
    uint64_t upper = frame ? stack->frames[frame - 1].record : top;
    if (r->error) { out->reason = r->error; return; }
    if (first != stack->first || top != stack->top) { out->reason = "ElispStateChanged"; return; }
    if (top < first || (top - first) % stride || (top - first) / stride > XEL_SPEC_LIMIT ||
        lower < first || lower >= upper || upper > top || (lower - first) % stride || (upper - first) % stride) {
        out->reason = "ElispBindingFrameUnavailable"; return;
    }
    if (field(l, r, lower, XEL_SPEC_KIND) != XEL_C_SPECPDL_BACKTRACE ||
        field(l, r, lower, XEL_SPEC_FUNCTION) != stack->frames[frame].function) {
        out->reason = r->error ? r->error : "ElispStateChanged"; return;
    }
    uint64_t env_symbol = environment_symbol_address ? word(r, environment_symbol_address, 8) : UINT64_MAX;
    if (environment_symbol_address && ((env_symbol & TAG_MASK) != XEL_C_Lisp_Symbol)) { out->reason = "ElispEnvironmentSymbolInvalid"; return; }
    struct binding_history history[XEL_BINDING_HISTORY]; size_t history_count = 0;
    for (uint64_t at = top; at > lower + stride && !r->error && !out->reason;) {
        at -= stride;
        unsigned tag = (unsigned)field(l, r, at, XEL_SPEC_KIND);
        if (r->error) break;
        if (tag > XEL_C_SPECPDL_LET_DEFAULT) { out->reason = "ElispSpecpdlKindInvalid"; break; }
        if (tag < XEL_C_SPECPDL_LET) continue;
        uint64_t symbol = field(l, r, at, XEL_SPEC_SYMBOL);
        uint64_t old_value = field(l, r, at, XEL_SPEC_OLD_VALUE);
        if (r->error) break;
        if ((symbol & TAG_MASK) != XEL_C_Lisp_Symbol) { out->reason = "ElispBindingSymbolInvalid"; break; }
        size_t h = 0;
        while (h < history_count && history[h].symbol != symbol) ++h;
        if (h == XEL_BINDING_HISTORY) { out->reason = "ElispBindingHistoryLimit"; out->truncated = 1; break; }
        uint64_t current = 0, slot = 0;
        int known = 0;
        /* Only plain/global object slots are currently proved. Buffer-local,
         * localized and keyboard bindings keep a row with an explicit reason. */
        if (tag == XEL_C_SPECPDL_LET) {
            if (h < history_count) { current = history[h].value; slot = history[h].slot; known = history[h].known; }
            else known = binding_current(l, r, c, symbol, &current, &slot);
        }
        if (r->error) break;
        if (at < upper) {
            if (symbol == env_symbol && known) lexical_bindings(l, r, c, current, old_value, at, out);
            else {
                struct xel_binding *row = binding_row(l, r, c, out, symbol, at, XEL_DYNAMIC);
                if (!row) break;
                row->has_value = (uint32_t)known;
                if (known) { row->value = current; row->slot = slot; }
                else row->reason = "ElispBindingStorageUnproved";
            }
        }
        if (h == history_count) ++history_count;
        history[h] = (struct binding_history){symbol, old_value, at + l->fields[XEL_SPEC_OLD_VALUE].offset, (uint32_t)known};
    }
    if (!r->error && (field(l, r, stack->thread, XEL_THREAD_FIRST) != first ||
        field(l, r, stack->thread, XEL_THREAD_TOP) != top ||
        field(l, r, lower, XEL_SPEC_KIND) != XEL_C_SPECPDL_BACKTRACE ||
        field(l, r, lower, XEL_SPEC_FUNCTION) != stack->frames[frame].function)) {
        out->reason = "ElispStateChanged"; out->count = 0;
    }
    if (r->error) { out->reason = r->error; out->count = 0; }
}
