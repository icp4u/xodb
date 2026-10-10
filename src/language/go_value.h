#ifndef XODB_LANGUAGE_GO_VALUE_H
#define XODB_LANGUAGE_GO_VALUE_H
#include "go.h"
enum xgv_type {
#define XGV_TYPE(key, name) XGV_T_##key,
#include "go_value_types.inc"
#undef XGV_TYPE
    XGV_TYPE_COUNT
};
enum xgv_field {
#define XGV_FIELD(key, owner, path, kind, width) XGV_##key,
#include "go_value_fields.inc"
#undef XGV_FIELD
    XGV_FIELD_COUNT
};
enum xgv_constant {
#define XGV_CONSTANT(key, name, value) XGV_C_##key,
#include "go_value_constants.inc"
#undef XGV_CONSTANT
    XGV_CONSTANT_COUNT
};
#define XGV_RECORD 4096
#define XGV_WAITERS 256
#define XGV_READ_LIMIT 8192
#define XGV_BYTE_LIMIT (1024 * 1024)
struct xgv_layout {
    struct xgo_field_info fields[XGV_FIELD_COUNT];
    uint32_t sizes[XGV_TYPE_COUNT];
    uint64_t constants[XGV_CONSTANT_COUNT];
    uint8_t build_id[64], build_id_len;
};
/* Independent value profile for Go 1.27.1, Linux/amd64. Callers must verify
 * the exact version, stopped generation, ELF identity and loaded placement. */
const char *xgv_layout_build(Dwarf *, const uint8_t *, size_t, struct xgv_layout *);
struct xgv_type_info {
    uint64_t address, size, pointer_bytes, section_start, section_end;
    uint32_t hash;
    uint8_t kind, direct;
    char name[XGO_NAME];
    const char *reason;
};
struct xgv_interface {
    int is_nil;
    uint64_t data, value_address; /* direct: address of data word, not pointee */
    struct xgv_type_info type;
    const char *reason;
};
struct xgv_channel {
    int is_nil, closed, header_valid, waits_complete;
    uint64_t length, capacity, buffer, send_index, receive_index;
    uint32_t send_entries, receive_entries, select_entries;
    struct xgv_type_info element;
    const char *reason;
};
/* Read-only; no reflection calls or target code. Dynamic reflect-created
 * types outside module type sections are explicitly unsupported for now. */
void xgv_type_read(const struct xgv_layout *, struct xgo_reader *, uint64_t module, uint64_t type, struct xgv_type_info *);
void xgv_interface_read(const struct xgv_layout *, struct xgo_reader *, uint64_t module, uint64_t address, int nonempty, struct xgv_interface *);
/* Register/composite interface header: no invented target address. Direct
 * storage is returned in data with value_address=0; indirect storage keeps
 * its actual target address. Caller checks capture validity/generation. */
void xgv_interface_from_bytes(const struct xgv_layout *, struct xgo_reader *, uint64_t module, const void *, size_t, int nonempty, struct xgv_interface *);
/* Queue entries, not unique goroutines: select may queue one g more than once.
 * A wait-limit result preserves the header and bounded lower counts. */
void xgv_channel_read(const struct xgv_layout *, struct xgo_reader *, uint64_t module, uint64_t address, struct xgv_channel *);
#endif
