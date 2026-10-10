#ifndef XODB_LANGUAGE_GO_VALUE_INTERNAL_H
#define XODB_LANGUAGE_GO_VALUE_INTERNAL_H
#include "go_value.h"
/* Common bounded I/O for value readers. Synthetic runtime group types need
 * their header/size checked even when their generated name is very long. */
int xgv_read_memory(struct xgo_reader *, uint64_t, void *, size_t);
void xgv_type_header_read(const struct xgv_layout *, struct xgo_reader *, uint64_t module, uint64_t type, struct xgv_type_info *);
#endif
