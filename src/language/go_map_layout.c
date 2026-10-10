#include "go_map.h"
#include "go_dwarf.h"
#include <string.h>
static const char *const types[] = {
#define XGM_TYPE(key, name) name,
#include "go_map_types.inc"
#undef XGM_TYPE
};
static const struct xgo_dwarf_field fields[] = {
#define XGM_FIELD(key, owner, path, kind, width) {XGM_T_##owner, path, XGO_D_##kind, width},
#include "go_map_fields.inc"
#undef XGM_FIELD
};
static const struct xgo_dwarf_constant constants[] = {
#define XGM_CONSTANT(key, name, value) {name, value},
#include "go_map_constants.inc"
#undef XGM_CONSTANT
};
const char *xgm_layout_build(Dwarf *dwarf, const uint8_t *id, size_t n, struct xgm_layout *out) {
    memset(out, 0, sizeof *out);
    const char *why = xgv_layout_build(dwarf, id, n, &out->values);
    if (why) return why;
    const struct xgo_dwarf_schema schema = {types, fields, constants, XGM_TYPE_COUNT, XGM_FIELD_COUNT, XGM_CONSTANT_COUNT};
    why = xgo_dwarf_layout_build(dwarf, &schema, out->fields, out->sizes, out->constants);
    if (why) return why;
    for (unsigned t = 0; t < XGM_TYPE_COUNT; ++t) if (out->sizes[t] > XGV_RECORD) return "GoMapLayoutTooLarge";
    return NULL;
}
