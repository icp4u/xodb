#ifndef XODB_LANGUAGE_JAVASCRIPT_H
#define XODB_LANGUAGE_JAVASCRIPT_H
#include <stddef.h>
#include <stdint.h>
#include <elfutils/libdw.h>

enum xjs_field {
#define XJS_FIELD(key, name) XJS_##key,
#include "javascript_fields.inc"
#undef XJS_FIELD
    XJS_FIELD_COUNT
};
extern const char *const xjs_field_names[XJS_FIELD_COUNT];
struct xjs_layout {
    int32_t fields[XJS_FIELD_COUNT];
    uint8_t present[XJS_FIELD_COUNT];
    uint32_t version[4];
    char version_string[64];
    uint8_t build_id[64], build_id_len;
    uint64_t dwarf_fields;
    int dwarf_frame_config;
};
struct xjs_dwarf_profile { uint64_t fields; int frame_config; const char *error; };
void xjs_dwarf_profile(Dwarf *, struct xjs_dwarf_profile *);
/* The caller verifies every loaded constant against the identified image.
 * Missing optional fields refuse only the operation that needs them. */
const char *xjs_layout_check(const struct xjs_layout *, const uint8_t *, size_t, const uint32_t[4]);
typedef int (*xjs_read_fn)(void *, uint64_t, void *, size_t);
struct xjs_reader {
    void *context;
    xjs_read_fn read;
    size_t reads, bytes;
    const char *error;
    int version_table;
};
int xjs_read_memory(struct xjs_reader *, uint64_t, void *, size_t);
#define XJS_READ_LIMIT 8192
#define XJS_BYTE_LIMIT (2 * 1024 * 1024)
#define XJS_PREVIEW_ITEMS 8
#define XJS_STRING_UNITS 128
struct xjs_item {
    uint64_t tagged;
    char key[96], type[32], display[192];
    const char *reason;
    int truncated;
    int extent_advisory;
    const char *name_reason;
};
struct xjs_value {
    uint64_t tagged, map, count;
    uint16_t instance_type;
    int truncated;
    int version_table;
    int extent_advisory;
    char type[64], display[512];
    const char *reason;
    const char *name_reason;
    size_t item_count;
    struct xjs_item items[XJS_PREVIEW_ITEMS];
};
/* The whole process stays stopped. These routines only use the read callback;
 * they never call target code, getters, constructors or coercion methods. */
void xjs_value_read(const struct xjs_layout *, struct xjs_reader *, uint64_t, struct xjs_value *);
#define XJS_STACK_FRAMES 64
struct xjs_frame {
    uint64_t fp, pc, function, shared, code;
    int32_t line, column;
    char name[192], file[384], kind[32];
    const char *reason;
};
struct xjs_stack {
    size_t count;
    struct xjs_frame frames[XJS_STACK_FRAMES];
    const char *reason;
    int version_table;
};
/* Start at a retained native-unwind frame with a V8 API exit marker. The
 * caller supplies the containing readable stack mapping and recovered R13.
 * Stops at the entry boundary: it does not invent cross-entry ordering. */
void xjs_stack_read(const struct xjs_layout *, struct xjs_reader *, uint64_t fp,
                    uint64_t pc, uint64_t root_register, uint64_t stack_lo,
                    uint64_t stack_hi, struct xjs_stack *);
/* A proved, single-word V8 C++ handle: 1 is a tagged value, 2 an indirect
 * handle slot. Zero means an unrelated or unsupported type. */
int xjs_dwarf_handle(Dwarf_Die *);
#endif
