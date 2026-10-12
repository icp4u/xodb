#ifndef XODB_MACHO_UNWIND_H
#define XODB_MACHO_UNWIND_H
#include "../binary/macho.h"
/* Apple's version-1 __unwind_info, regular and compressed second-level
 * pages. Offsets are relative to __TEXT; no target/host addresses are read. */
struct xmu_row { uint32_t start, end, encoding; };
struct xmu_table;
enum xmo_status xmu_create(const unsigned char *, size_t, uint64_t allowance, struct xmu_table **);
void xmu_destroy(struct xmu_table *);
size_t xmu_bytes(const struct xmu_table *);
enum xmo_status xmu_lookup(const struct xmu_table *, uint64_t text_offset, struct xmu_row *);
#endif
