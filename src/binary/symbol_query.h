#ifndef XODB_SYMBOL_QUERY_H
#define XODB_SYMBOL_QUERY_H
#include "object.h"

#define XBS_NAMES 256
#define XBS_NAME_BYTES 256
struct xbs_symbol {
    uint64_t address, size;
    uint32_t section;
    unsigned type, binding, present;
};
struct xbs_progress { uint64_t symbols, sections, memory_bytes; int complete; };
struct xbs_query;
/* Exact names are copied at creation. The prepared, pinned object is borrowed.
 * Only defined, address-bearing section symbols can match. Conflicting copies
 * in multiple tables refuse; identical dynsym/symtab entries are deduplicated.
 * TLS requires a separate address resolver and returns LIMIT. Extended section
 * indexes and compressed symbol tables likewise refuse explicitly.
 * Retained pages and requested names use less than 1280 KiB total. */
enum xbo_status xbs_create(struct xbo_object *, const char *const *, size_t, struct xbs_query **);
void xbs_destroy(struct xbs_query *);
enum xbo_status xbs_step(struct xbs_query *, struct xbo_budget *, uint64_t work);
/* No partial results: out is initialized, even on AGAIN or failure. */
enum xbo_status xbs_result(const struct xbs_query *, size_t, struct xbs_symbol *);
void xbs_progress(const struct xbs_query *, struct xbs_progress *);
const char *xbs_error(const struct xbs_query *);
#endif
