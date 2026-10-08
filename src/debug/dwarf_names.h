#ifndef XODB_DWARF_NAMES_H
#define XODB_DWARF_NAMES_H
#include "../binary/object.h"

/* Accelerator entries are candidates, not verified DIEs or proof that a name
 * is absent. Consumers must inspect the selected CU and validate its fields.
 * Compressed indexes and foreign type units require a separate provider. */
struct xdn_query;
struct xdn_hit {
    uint64_t unit, die, unit_size;
    uint32_t tag;
    unsigned has_die; /* .gdb_index identifies a CU, .debug_names also a DIE. */
};
enum xdn_kind { XDN_DEBUG_NAMES, XDN_GDB_INDEX };
enum xbo_status xdn_create(struct xbo_object *, const char *name, struct xdn_query **);
void xdn_destroy(struct xdn_query *);
/* OK yields one candidate. NOT_FOUND means the index query is exhausted, not
 * that the full DWARF has no matching definition. AGAIN/CANCELLED resume. */
enum xbo_status xdn_next(struct xdn_query *, struct xbo_budget *, uint64_t work,
                         struct xdn_hit *);
enum xdn_kind xdn_kind(const struct xdn_query *);
const char *xdn_error(const struct xdn_query *);
uint64_t xdn_memory_bytes(const struct xdn_query *);
#endif
