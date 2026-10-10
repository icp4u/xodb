#include "go_value.h"
#include "go_dwarf.h"
#include <string.h>
static const char *const types[] = {
#define XGV_TYPE(key, name) name,
#include "go_value_types.inc"
#undef XGV_TYPE
};
static const struct xgo_dwarf_field fields[] = {
#define XGV_FIELD(key, owner, path, kind, width) {XGV_T_##owner, path, XGO_D_##kind, width},
#include "go_value_fields.inc"
#undef XGV_FIELD
};
static const struct xgo_dwarf_constant constants[] = {
#define XGV_CONSTANT(key, name, value) {name, value},
#include "go_value_constants.inc"
#undef XGV_CONSTANT
};
const char *xgv_layout_build(Dwarf *dwarf, const uint8_t *id, size_t n, struct xgv_layout *out) {
    memset(out, 0, sizeof *out);
    if (!id || !n || n > sizeof out->build_id) return "GoBuildIdUnavailable";
    const struct xgo_dwarf_schema schema = {types, fields, constants, XGV_TYPE_COUNT, XGV_FIELD_COUNT, XGV_CONSTANT_COUNT};
    const char *why = xgo_dwarf_layout_build(dwarf, &schema, out->fields, out->sizes, out->constants);
    if (why) return why;
    for (unsigned t = 0; t < XGV_TYPE_COUNT; ++t) if (out->sizes[t] > XGV_RECORD) return "GoValueLayoutTooLarge";
    if (out->sizes[XGV_T_EFACE] != 16 || out->sizes[XGV_T_IFACE] != 16) return "GoDwarfTypesUnsupported";
    memcpy(out->build_id, id, n); out->build_id_len = (uint8_t)n;
    return NULL;
}
