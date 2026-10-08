#ifndef XODB_BINARY_PLACEMENT_H
#define XODB_BINARY_PLACEMENT_H
#include "object.h"
/* The caller has already proved the mapping's file identity. The range and
 * file offset describe one VMA, not a coalesced image or a guessed filename. */
enum xbo_status xbo_mapping_bias(const struct xbo_object *, uint64_t start,
        uint64_t end, uint64_t offset, uint64_t page_size, unsigned write_execute,
        uint64_t *bias); /* write_execute: ELF PF_W/PF_X */
#endif
