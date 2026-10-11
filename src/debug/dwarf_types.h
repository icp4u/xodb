#ifndef XODB_DWARF_TYPES_H
#define XODB_DWARF_TYPES_H
#include <elfutils/libdw.h>
#include <stdint.h>

/* Struct layouts by type name from every unit of one image. C++ compilers
 * emit a class's full definition only in some units (GCC: the key
 * function's), so a reader cannot ask one unit for it. A name is a path of
 * "::"-separated scopes ("Outer::Inner"); each scope may be a namespace,
 * class, struct or union. Only complete definitions count, and every
 * definition found must agree on the size and on each requested member.
 * The DWARF is the target's file: every walk is counted against `work`. */
#define XDT_MAX_TYPES 16
#define XDT_MAX_FIELDS 64
enum xdt_kind { XDT_ANY, XDT_POINTER, XDT_UNSIGNED, XDT_SIGNED, XDT_BOOLEAN };
struct xdt_field {
    uint8_t owner;    /* index into types */
    const char *name; /* a direct data member */
    uint8_t kind;     /* enum xdt_kind, after typedefs and qualifiers */
    uint8_t width;    /* required byte size; 0 accepts any */
    uint8_t optional; /* absent leaves present = 0 instead of failing */
};
struct xdt_slot { uint32_t offset, size; uint8_t present; };
struct xdt_schema {
    const char *const *types;
    const struct xdt_field *fields;
    unsigned type_count, field_count;
};
struct xdt_stats { uint64_t units, work; uint32_t definitions[XDT_MAX_TYPES]; };
/* NULL, or a static error name: DwarfTypesUnavailable (no DWARF),
 * DwarfTypesMalformed, DwarfTypesWorkLimit, DwarfTypesUnitLimit,
 * DwarfTypesSchemaLimit, DwarfTypeNotFound, DwarfTypeAmbiguous,
 * DwarfFieldNotFound, DwarfFieldMismatch. On failure the outputs are zero. */
const char *xdt_layout_build(Dwarf *, const struct xdt_schema *, uint64_t work,
                             struct xdt_slot *fields, uint32_t *sizes, struct xdt_stats *);
#endif
