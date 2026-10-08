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
    int is_c, tail_call;
    char name[160], file[544];
    const char *reason;
};
struct xl_stack {
    uint64_t state;
    size_t count;
    struct xl_frame frames[XL_STACK_FRAMES];
    const char *reason;
};
void xl_stack_read(const struct xl_layout *, struct xl_reader *, uint64_t, struct xl_stack *);
#endif
