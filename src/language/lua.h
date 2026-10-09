#ifndef XODB_LANGUAGE_LUA_H
#define XODB_LANGUAGE_LUA_H
#include <elfutils/libdw.h>
#include <stddef.h>
#include <stdint.h>

enum xl_type {
#define XL_TYPE(key, n52, n54) XL_T_##key,
#include "lua_types.inc"
#undef XL_TYPE
    XL_TYPE_COUNT
};
enum xl_field {
#define XL_FIELD(key, owner, p52, p54, kind, w52, w54) XL_##key,
#include "lua_fields.inc"
#undef XL_FIELD
    XL_FIELD_COUNT
};
struct xl_field_info { uint32_t offset, size; };
struct xl_layout {
    struct xl_field_info fields[XL_FIELD_COUNT];
    uint32_t sizes[XL_TYPE_COUNT];
    uint8_t build_id[64], build_id_len, version[3];
};
/* Only the documented exact semantic versions are supported. The caller
 * verifies the loaded identity and keeps every thread stopped. Offsets and
 * strides come exclusively from the identified image's DWARF. */
const char *xl_layout_build(Dwarf *, const uint8_t *, size_t, const uint8_t[3], struct xl_layout *);
const char *xl_layout_check(const struct xl_layout *, const uint8_t *, size_t, const uint8_t[3]);
typedef int (*xl_read_fn)(void *, uint64_t, void *, size_t);
struct xl_reader { void *context; xl_read_fn read; size_t reads, bytes; const char *error; };
#define XL_READ_LIMIT 8192
#define XL_BYTE_LIMIT (2 * 1024 * 1024)
#define XL_PREVIEW_ITEMS 8
#define XL_STRING_BYTES 128
#define XL_STACK_FRAMES 128
struct xl_item {
    uint64_t address;
    char key[160], type[24], display[384];
    const char *reason;
    int advisory;
};
struct xl_value {
    uint64_t address, object, count, array_capacity, hash_capacity;
    uint32_t tag;
    int truncated, advisory;
    char type[24], display[768];
    const char *reason;
    size_t item_count;
    struct xl_item items[XL_PREVIEW_ITEMS];
};
/* Reads TValue storage, including bounded children; no inferior functions,
 * coercions or metamethods. Consistency checks do not prove GC liveness. */
void xl_value_read(const struct xl_layout *, struct xl_reader *, uint64_t, struct xl_value *);
void xl_state_read(const struct xl_layout *, struct xl_reader *, uint64_t, struct xl_value *);
struct xl_frame {
    uint64_t ci, function, proto, native_function, saved_pc;
    int32_t line, defined_line;
    int is_c, tail_call, identity_proved;
    char name[160], file[544];
    const char *reason;
};
struct xl_stack {
    /* Complete CallInfo walk, independent of name/source availability. */
    int chain_complete;
    uint64_t state;
    size_t count;
    struct xl_frame frames[XL_STACK_FRAMES];
    const char *reason;
};
void xl_stack_read(const struct xl_layout *, struct xl_reader *, uint64_t, struct xl_stack *);
#define XL_LOCAL_ITEMS 32
enum xl_local_kind { XL_LOCAL, XL_UPVALUE, XL_VARARGS };
struct xl_local {
    enum xl_local_kind kind;
    uint32_t ordinal; /* 1-based within local or upvalue scope, as in Lua's API. */
    uint32_t declaration; /* 0-based LocVar/upvalue index within the prototype. */
    uint64_t address;
    char name[544]; /* Escaped bytes, with explicit truncation; never evaluated. */
    int name_truncated;
    int path_absent; /* A proved absent final raw-table key, whose value is nil. */
    const char *reason;
    struct xl_value value;
};
struct xl_locals {
    uint64_t state, call_info;
    size_t frame, start, total, count;
    int truncated;
    const char *reason;
    struct xl_local items[XL_LOCAL_ITEMS];
};
/* Reconstruct the CallInfo chain at this retained stop, then page named active
 * locals and closure upvalues. Addresses expire on resume/GC/stack relocation.
 * C temporaries are excluded. Extra varargs appear as one nameless count row
 * with no address; they cannot be resolved through named lookup. */
void xl_locals_read(const struct xl_layout *, struct xl_reader *, uint64_t state,
                    size_t frame, size_t start, size_t limit, struct xl_locals *);
/* ASCII local/upvalue name followed by at most four .identifier or [int32]
 * raw-table selectors (128 bytes total). Re-resolve every pointer at this stop.
 * Metatables, calls, operators and implicit globals are refused. Innermost
 * active locals shadow outer locals and upvalues. An absent final key is nil;
 * an absent intermediate key is not indexable. Hash scans are bounded. */
#define XL_PATH_DEPTH 4
#define XL_PATH_HASH_NODES 128
/* Pure syntax/bounds check; resolution can still be unavailable. */
int xl_expression_valid(const char *);
void xl_local_find(const struct xl_layout *, struct xl_reader *, uint64_t state,
                   size_t frame, const char *expression, struct xl_locals *);
/* Re-resolve an explicit displayed binding, distinct from lexical lookup.
 * kind/declaration come from a canonical row in the same prototype; the
 * adapter separately verifies the activation location/prototype each stop. */
void xl_local_binding(const struct xl_layout *, struct xl_reader *, uint64_t state,
                       size_t frame, enum xl_local_kind, uint32_t declaration, struct xl_locals *);
/* Full bounded comparison bytes, independent of preview truncation. Numeric
 * samples use exact little-endian representation (including IEEE float bits).
 * Call only on a freshly re-resolved binding at the current stopped generation.
 * Unsupported objects and over-cap strings return a reason, never equality. */
#define XL_SAMPLE_BYTES 4096
enum xl_sample_kind { XL_SAMPLE_NIL, XL_SAMPLE_BOOLEAN, XL_SAMPLE_INTEGER, XL_SAMPLE_NUMBER, XL_SAMPLE_STRING };
const char *xl_value_sample(const struct xl_layout *, struct xl_reader *, uint64_t,
                            unsigned char *, size_t, size_t *, enum xl_sample_kind *);
/* Samples either freshly resolved storage or a proved absent final path key. */
const char *xl_local_sample(const struct xl_layout *, struct xl_reader *, const struct xl_local *,
                            unsigned char *, size_t, size_t *, enum xl_sample_kind *);
#endif
