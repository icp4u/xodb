#include "placement.h"
#include <elf.h>

enum xbo_status xbo_mapping_bias(const struct xbo_object *object, uint64_t start,
        uint64_t end, uint64_t offset, uint64_t page, unsigned permissions, uint64_t *out) {
    if (!out) return XBO_MALFORMED;
    *out = 0;
    if (!xbo_identity(object) || end <= start || !page || (page & (page - 1)) ||
        start % page || offset % page || (permissions & ~(PF_W | PF_X))) return XBO_MALFORMED;
    int found = 0;
    uint64_t bias = 0;
    for (uint32_t i = 0; i < xbo_segment_count(object); ++i) {
        const struct xbo_segment *s = xbo_segment(object, i);
        if (s->type != PT_LOAD || !s->file_size || (s->flags & permissions) != permissions) continue;
        uint64_t low = s->offset - s->offset % page;
        if (s->file_size > UINT64_MAX - s->offset || s->offset + s->file_size > UINT64_MAX - (page - 1))
            return XBO_MALFORMED;
        uint64_t high = s->offset + s->file_size + page - 1;
        high -= high % page;
        if (offset < low || offset >= high || end - start > high - offset) continue;
        uint64_t delta = s->offset - low;
        if (s->address < delta || offset - low > UINT64_MAX - (s->address - delta)) return XBO_MALFORMED;
        uint64_t link = s->address - delta + (offset - low);
        if (start < link) continue;
        uint64_t candidate = start - link;
        if (found && candidate != bias) return XBO_MALFORMED;
        bias = candidate; found = 1;
    }
    if (!found) return XBO_NOT_FOUND;
    *out = bias; return XBO_OK;
}
