#ifndef XODB_LANGUAGE_ELISP_H
#define XODB_LANGUAGE_ELISP_H
#include <elfutils/libdw.h>
#include <stddef.h>
#include <stdint.h>
#define XEL_VERSION "31.1"
enum xel_constant {
#define XEL_CONSTANT(name, value) XEL_C_##name = value,
#include "elisp_constants.inc"
#undef XEL_CONSTANT
};
#define XEL_GLOBAL(name, width, value) static const uint64_t XEL_C_##name = value;
#include "elisp_globals.inc"
#undef XEL_GLOBAL
enum xel_type {
#define XEL_TYPE(key, name) XEL_T_##key,
#include "elisp_types.inc"
#undef XEL_TYPE
    XEL_TYPE_COUNT
};
enum xel_field {
#define XEL_FIELD(key, owner, path, kind, width) XEL_##key,
#include "elisp_fields.inc"
#undef XEL_FIELD
    XEL_FIELD_COUNT
};
enum xel_global {
#define XEL_GLOBAL(name, width, value) XEL_G_##name,
#include "elisp_globals.inc"
#undef XEL_GLOBAL
    XEL_GLOBAL_COUNT
};
struct xel_field_info { uint32_t offset, size; };
struct xel_layout {
    struct xel_field_info fields[XEL_FIELD_COUNT];
    uint32_t sizes[XEL_TYPE_COUNT];
    uint8_t build_id[64], build_id_len;
};
/* Initial profile: GNU Emacs 31.1, LP64 little endian, modules enabled.
 * Caller proves the loaded build ID, version and retained stop. The layout is
 * derived from the same image's runtime CUs, never an unrelated host typedef. */
const char *xel_layout_build(Dwarf *, const uint8_t *, size_t, const char *, struct xel_layout *);
int xel_dwarf_object(Dwarf_Die *);
typedef int (*xel_read_fn)(void *, uint64_t, void *, size_t);
struct xel_reader { void *context; xel_read_fn read; size_t reads, bytes; const char *error; };
struct xel_context { uint64_t lispsym, globals[XEL_GLOBAL_COUNT]; };
#define XEL_READ_LIMIT 8192
#define XEL_BYTE_LIMIT (2 * 1024 * 1024)
#define XEL_SPEC_LIMIT 8192
#define XEL_STACK_FRAMES 128
#define XEL_CONTROL_LIMIT 128
#define XEL_STACK_CONTROLS (2 * XEL_CONTROL_LIMIT) /* Separate unwind/handler caps. */
enum xel_execution_kind { XEL_UNKNOWN, XEL_INTERPRETED, XEL_BYTECODE };
/* The host proves that these are live arguments/locals in a same-image
 * funcall_lambda or apply_lambda native activation, never a function cell.
 * execution_kind comes from its still-active child evaluator call path. */
struct xel_activation { uint64_t function, args; int64_t nargs; size_t native_frame; uint32_t execution_kind; };
struct xel_frame {
    uint64_t record, function, args, depth;
    int64_t nargs; /* -1 means unevaluated forms, not an argument count. */
    char name[192];
    const char *name_reason, *kind_reason;
    uint64_t active_function;
    size_t native_frame; /* SIZE_MAX unless uniquely proved by argument storage. */
    uint32_t execution_kind;
    const char *kind_basis;
};
enum xel_control_kind { XEL_UNWIND, XEL_HANDLER };
struct xel_control {
    uint64_t record, depth;
    uint32_t kind, runtime_kind;
    /* Index in frames, or SIZE_MAX if truncated, unused, or not provable. */
    size_t frame;
    const char *reason;
};
struct xel_stack {
    uint64_t thread, first, top;
    size_t count, control_count;
    struct xel_frame frames[XEL_STACK_FRAMES];
    struct xel_control controls[XEL_STACK_CONTROLS];
    const char *reason, *classification_reason;
};
/* Thread must already be associated with the selected native thread. No target
 * code is called. Results belong only to the retained stop; no function-cell
 * lookup is used to guess the active implementation of a recorded function. */
void xel_stack_read(const struct xel_layout *, struct xel_reader *,
                    const struct xel_context *, uint64_t thread, struct xel_stack *);
/* A storage cap preserves the validated inner frames. Other errors do not. */
int xel_stack_frames_available(const struct xel_stack *);
/* Initial Linux adapter: selected main native thread AND current_thread must
 * match the same-image main_thread.s. Other threads refuse before stack reads. */
void xel_stack_main(const struct xel_layout *, struct xel_reader *,
                    const struct xel_context *, uint64_t current, uint64_t main,
                    int32_t pid, int32_t tid, struct xel_stack *);
/* Optional classification; malformed evidence withdraws labels, not the saved
 * backtrace. The reader has the same retained stop and cumulative read budget. */
void xel_stack_kinds(const struct xel_layout *, struct xel_reader *,
                     const struct xel_context *, const struct xel_activation *, size_t,
                     struct xel_stack *);
#define XEL_VALUE_ITEMS 24
#define XEL_VALUE_NODES 128
#define XEL_VALUE_DEPTH 4
struct xel_value_item {
    uint64_t tagged;
    char key[128], type[24], display[256];
    const char *reason;
};
struct xel_value {
    uint64_t tagged, object, count;
    char type[24], display[768];
    const char *reason;
    uint32_t truncated;
    size_t item_count;
    struct xel_value_item items[XEL_VALUE_ITEMS];
};
/* Decode a typed Lisp_Object word, not a pointer to a Lisp_Object slot.
 * No function calls, property accessors or hash lookup. GC liveness and
 * allocation extents remain unproved. Host retains and checks the stop. */
void xel_value_read(const struct xel_layout *, struct xel_reader *,
                    const struct xel_context *, uint64_t tagged, struct xel_value *);
#define XEL_BINDING_LIMIT 128
#define XEL_BINDING_HISTORY 256
enum xel_binding_scope { XEL_DYNAMIC, XEL_LEXICAL };
struct xel_binding {
    uint64_t symbol, value, slot, record, environment;
    char name[192];
    uint32_t scope, has_value;
    const char *reason;
};
struct xel_bindings {
    size_t count;
    uint32_t truncated;
    const char *reason;
    struct xel_binding rows[XEL_BINDING_LIMIT];
};
/* One saved frame's bindings. Inner rebindings supply the older frame's
 * value; old_value is never mistaken for the value introduced by that let.
 * environment_symbol_address is the same-image Qinternal_interpreter_environment
 * word, or zero when unavailable. No interpreter evaluation or rewinding. */
void xel_bindings_read(const struct xel_layout *, struct xel_reader *,
                       const struct xel_context *, const struct xel_stack *, size_t frame,
                       uint64_t environment_symbol_address, struct xel_bindings *);
#endif
