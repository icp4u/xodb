#ifndef XODB_LANGUAGE_GO_MAP_H
#define XODB_LANGUAGE_GO_MAP_H
#include "go_value.h"
enum xgm_type {
#define XGM_TYPE(key, name) XGM_T_##key,
#include "go_map_types.inc"
#undef XGM_TYPE
    XGM_TYPE_COUNT
};
enum xgm_field {
#define XGM_FIELD(key, owner, path, kind, width) XGM_##key,
#include "go_map_fields.inc"
#undef XGM_FIELD
    XGM_FIELD_COUNT
};
enum xgm_constant {
#define XGM_CONSTANT(key, name, value) XGM_C_##key,
#include "go_map_constants.inc"
#undef XGM_CONSTANT
    XGM_CONSTANT_COUNT
};
#define XGM_DIRECTORY_LIMIT 2048
#define XGM_GROUP_LIMIT 2048
#define XGM_PAGE 64
struct xgm_layout {
    struct xgv_layout values;
    struct xgo_field_info fields[XGM_FIELD_COUNT];
    uint32_t sizes[XGM_TYPE_COUNT];
    uint64_t constants[XGM_CONSTANT_COUNT];
};
struct xgm_entry { uint64_t key, value; };
struct xgm_page {
    uint64_t total, start, next;
    uint32_t count, groups, tables, deleted;
    int is_nil, complete;
    struct xgv_type_info key_type, element_type;
    struct xgm_entry entries[XGM_PAGE];
    const char *reason;
};
const char *xgm_layout_build(Dwarf *, const uint8_t *, size_t, struct xgm_layout *);
/* Read-only enumeration of physical slots, never a target hash/equality call.
 * Addresses refer to typed value storage (after indirection when required).
 * start/next are physical-order entry indices within one stopped generation;
 * callers must reset pagination after any resume. A failure publishes no page. */
void xgm_map_read(const struct xgm_layout *, struct xgo_reader *, uint64_t module,
                  uint64_t runtime_type, uint64_t map, uint64_t start, unsigned limit, struct xgm_page *);
#endif
