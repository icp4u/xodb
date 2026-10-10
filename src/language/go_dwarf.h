#ifndef XODB_LANGUAGE_GO_DWARF_H
#define XODB_LANGUAGE_GO_DWARF_H
#include "go.h"
/* Shared bounded DWARF walker; each feature supplies its own required types,
 * so absent value metadata cannot disable goroutine inspection. */
enum xgo_dwarf_kind { XGO_D_SIGNED, XGO_D_UNSIGNED, XGO_D_POINTER, XGO_D_BOOLEAN, XGO_D_WORD_ARRAY };
struct xgo_dwarf_field { unsigned owner; const char *path; enum xgo_dwarf_kind kind; unsigned width; };
struct xgo_dwarf_constant { const char *name; uint64_t value; };
struct xgo_dwarf_schema {
    const char *const *types;
    const struct xgo_dwarf_field *fields;
    const struct xgo_dwarf_constant *constants;
    size_t type_count, field_count, constant_count;
};
int xgo_dwarf_info_size(Dwarf *, uint64_t *);
const char *xgo_dwarf_layout_build(Dwarf *, const struct xgo_dwarf_schema *,
                                 struct xgo_field_info *, uint32_t *, uint64_t *);
#endif
