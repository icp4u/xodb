#include "go_map.h"
#include "go_value_internal.h"
#include <stdlib.h>
#include <string.h>
static uint64_t word(const uint8_t *b, unsigned n) {
    uint64_t v = 0; for (unsigned i = 0; i < n; ++i) v |= (uint64_t)b[i] << (8 * i); return v;
}
static uint64_t get(const struct xgm_layout *l, const uint8_t *b, unsigned f) {
    return word(b + l->fields[f].offset, l->fields[f].size);
}
static const char *layout(const struct xgm_layout *l) {
    if (!l) return "GoMapLayoutInvalid";
    for (unsigned t = 0; t < XGM_TYPE_COUNT; ++t)
        if (!l->sizes[t] || l->sizes[t] > XGV_RECORD) return "GoMapLayoutInvalid";
#define XGM_FIELD(key, owner, path, kind, width) \
    if (l->fields[XGM_##key].size != width || l->fields[XGM_##key].offset > l->sizes[XGM_T_##owner] || \
        width > l->sizes[XGM_T_##owner] - l->fields[XGM_##key].offset) return "GoMapLayoutInvalid";
#include "go_map_fields.inc"
#undef XGM_FIELD
#define XGM_CONSTANT(key, name, value) if (l->constants[XGM_C_##key] != value) return "GoMapLayoutInvalid";
#include "go_map_constants.inc"
#undef XGM_CONSTANT
    return NULL;
}
struct scan {
    const struct xgm_layout *l;
    struct xgo_reader *r;
    struct xgm_page *out;
    uint64_t group_size, key_off, key_stride, elem_off, elem_stride, key_size, elem_size, observed;
    unsigned limit;
    int indirect_key, indirect_elem, tombstones;
};
static int range(uint64_t off, uint64_t stride, uint64_t size, uint64_t total) {
    return off >= 8 && off <= total && size <= total - off && stride <= (total - off - size) / 7 && (!size || stride >= size);
}
static int overlap(uint64_t a, uint64_t an, uint64_t b, uint64_t bn) {
    return an && bn && a < b + bn && b < a + an;
}
static const char *group(struct scan *s, uint64_t at, int small, uint64_t *used, uint64_t *deleted) {
    if (s->out->groups == XGM_GROUP_LIMIT) return "GoMapGroupLimit";
    ++s->out->groups;
    if (!at || s->group_size > UINT64_MAX - at) return "GoMapGroupInvalid";
    /* Go 1.27.1 groupReference.ctrls(): the eight control bytes prefix both
     * group layouts. The live oracle also checks this in each typed group DIE. */
    uint8_t ctrl[8], after[8];
    if (!xgv_read_memory(s->r, at, ctrl, sizeof ctrl)) return s->r->error;
    for (unsigned i = 0; i < 8; ++i) {
        if (ctrl[i] == s->l->constants[XGM_C_EMPTY]) continue;
        if (ctrl[i] == s->l->constants[XGM_C_DELETED]) {
            if (small || !s->tombstones) return "GoMapControlInvalid";
            ++*deleted; ++s->out->deleted; continue;
        }
        if (ctrl[i] & 128) return "GoMapControlInvalid";
        ++*used;
        uint64_t ordinal = s->observed++;
        if (ordinal < s->out->start || s->out->count == s->limit) continue;
        uint64_t key = at + s->key_off + i * s->key_stride;
        uint64_t value = at + s->elem_off + i * s->elem_stride;
        uint8_t pointer[8];
        if (s->indirect_key) {
            if (!xgv_read_memory(s->r, key, pointer, sizeof pointer)) return s->r->error;
            key = word(pointer, 8); if (!key) return "GoMapIndirectStorageInvalid";
        }
        if (s->indirect_elem) {
            if (!xgv_read_memory(s->r, value, pointer, sizeof pointer)) return s->r->error;
            value = word(pointer, 8); if (!value) return "GoMapIndirectStorageInvalid";
        }
        if (s->out->key_type.size > UINT64_MAX - key || s->out->element_type.size > UINT64_MAX - value)
            return "GoMapIndirectStorageInvalid";
        s->out->entries[s->out->count++] = (struct xgm_entry){key, value};
    }
    if (!xgv_read_memory(s->r, at, after, sizeof after)) return s->r->error;
    return memcmp(ctrl, after, sizeof ctrl) ? "GoValueChanged" : NULL;
}
static const char *scan_map(struct scan *s, uint64_t module, uint64_t type, uint64_t at) {
    const struct xgm_layout *l = s->l; struct xgo_reader *r = s->r; struct xgm_page *out = s->out;
    struct xgv_type_info info;
    xgv_type_header_read(&l->values, r, module, type, &info);
    if (info.reason) return info.reason;
    if (info.kind != l->constants[XGM_C_MAP] || info.size != 8 || !info.direct) return "GoMapTypeInvalid";
    uint8_t b[XGV_RECORD], map[XGV_RECORD], after[XGV_RECORD];
    if (!xgv_read_memory(r, type, b, l->sizes[XGM_T_TYPE])) return r->error;
    uint64_t flags = get(l, b, XGM_T_FLAGS);
    if (flags & ~UINT64_C(15)) return "GoMapTypeInvalid";
    xgv_type_read(&l->values, r, module, get(l, b, XGM_T_KEY), &out->key_type);
    if (out->key_type.reason) return out->key_type.reason;
    xgv_type_read(&l->values, r, module, get(l, b, XGM_T_ELEM), &out->element_type);
    if (out->element_type.reason) return out->element_type.reason;
    s->indirect_key = (flags & l->constants[XGM_C_INDIRECT_KEY]) != 0;
    s->indirect_elem = (flags & l->constants[XGM_C_INDIRECT_ELEM]) != 0;
    if (s->indirect_key != (out->key_type.size > l->constants[XGM_C_KEY_MAX]) ||
        s->indirect_elem != (out->element_type.size > l->constants[XGM_C_ELEM_MAX])) return "GoMapIndirectFlagMismatch";
    s->key_size = s->indirect_key ? 8 : out->key_type.size;
    s->elem_size = s->indirect_elem ? 8 : out->element_type.size;
    s->group_size = get(l, b, XGM_T_GROUP_SIZE);
    xgv_type_header_read(&l->values, r, module, get(l, b, XGM_T_GROUP), &info);
    if (info.reason) return info.reason;
    if (info.kind != l->constants[XGM_C_STRUCT] || info.size != s->group_size || s->group_size < 8 || s->group_size > XGV_RECORD)
        return "GoMapGroupSizeMismatch";
    s->key_off = get(l, b, XGM_T_KEYS_OFF); s->key_stride = get(l, b, XGM_T_KEY_STRIDE);
    s->elem_off = get(l, b, XGM_T_ELEMS_OFF); s->elem_stride = get(l, b, XGM_T_ELEM_STRIDE);
    if (!range(s->key_off,s->key_stride,s->key_size,s->group_size) || !range(s->elem_off,s->elem_stride,s->elem_size,s->group_size))
        return "GoMapSlotLayoutInvalid";
    /* Both split arrays and interleaved pairs are valid. Check all eight
     * spans so incorrect strides cannot alias unrelated keys and values. */
    for (unsigned i = 0; i < 8; ++i) for (unsigned j = 0; j < 8; ++j)
        if (overlap(s->key_off+i*s->key_stride,s->key_size,s->elem_off+j*s->elem_stride,s->elem_size)) return "GoMapSlotLayoutInvalid";
    if (!at) { out->is_nil = 1; out->complete = 1; return NULL; }
    if (!xgv_read_memory(r, at, map, l->sizes[XGM_T_MAP])) return r->error;
    if (get(l,map,XGM_M_WRITING)) return "GoMapBusy";
    uint64_t used = get(l,map,XGM_M_USED), dir = get(l,map,XGM_M_DIR), length = get(l,map,XGM_M_DIR_LEN);
    uint64_t depth = get(l,map,XGM_M_DEPTH), shift = get(l,map,XGM_M_SHIFT), tombstones = get(l,map,XGM_M_TOMBSTONES);
    if (used > INT64_MAX || tombstones > 1) return "GoMapHeaderInvalid";
    s->tombstones = (int)tombstones;
    const char *why = NULL;
    if (!length) {
        if (used > 8 || depth || (!dir && used)) return "GoMapHeaderInvalid";
        uint64_t got = 0, deleted = 0;
        if (dir && (why = group(s, dir, 1, &got, &deleted))) return why;
        if (got != used) return "GoMapCountMismatch";
    } else {
        if (length > XGM_DIRECTORY_LIMIT) return "GoMapDirectoryLimit";
        if (!dir || length > (UINT64_MAX-dir)/8 || depth >= 64 || length != (UINT64_C(1)<<depth) || shift != 64-depth)
            return "GoMapDirectoryInvalid";
        /* Allocate only the actual bounded directory, plus its final re-read. */
        size_t bytes = (size_t)length * 8;
        uint8_t *directory = malloc(bytes*2);
        if (!directory) return "GoMapOutOfMemory";
        if (!xgv_read_memory(r,dir,directory,bytes)) { free(directory); return r->error; }
        for (uint64_t i = 0; i < length && !why;) {
            uint64_t table = word(directory+i*8,8);
            if (!xgv_read_memory(r,table,b,l->sizes[XGM_T_TABLE])) { why=r->error; break; }
            uint64_t local = get(l,b,XGM_TB_DEPTH), index = get(l,b,XGM_TB_INDEX);
            uint64_t capacity = get(l,b,XGM_TB_CAP), mask = get(l,b,XGM_TB_MASK), groups = get(l,b,XGM_TB_GROUPS);
            uint64_t wanted = get(l,b,XGM_TB_USED), growth = get(l,b,XGM_TB_GROWTH);
            if (local > depth || index != i || mask >= l->constants[XGM_C_TABLE_CAP]/8 || (mask & (mask+1)) ||
                capacity != (mask+1)*8 || !groups || (mask+1) > (UINT64_MAX-groups)/s->group_size) {
                why="GoMapTableInvalid"; break;
            }
            uint64_t span = UINT64_C(1)<<(depth-local);
            if (i%span || span > length-i) { why="GoMapDirectoryInvalid"; break; }
            for (uint64_t j=0;j<span;++j) if (word(directory+(i+j)*8,8)!=table) { why="GoMapDirectoryInvalid"; break; }
            if (why) break;
            ++out->tables;
            uint64_t got = 0, deleted = 0;
            for (uint64_t g=0;g<=mask && !why;++g) why=group(s,groups+g*s->group_size,0,&got,&deleted);
            if (why) break;
            uint64_t max = capacity==8 ? capacity-1 : capacity*l->constants[XGM_C_LOAD]/8;
            if (got != wanted || got+deleted > max || growth != max-got-deleted) { why="GoMapCountMismatch"; break; }
            if (!xgv_read_memory(r,table,after,l->sizes[XGM_T_TABLE])) { why=r->error; break; }
            if (memcmp(b,after,l->sizes[XGM_T_TABLE])) { why="GoValueChanged"; break; }
            i += span;
        }
        if (!why && !xgv_read_memory(r,dir,directory+bytes,bytes)) why=r->error;
        if (!why && memcmp(directory,directory+bytes,bytes)) why="GoValueChanged";
        free(directory);
        if (why) return why;
        if (s->observed != used) return "GoMapCountMismatch";
    }
    if (!xgv_read_memory(r,at,after,l->sizes[XGM_T_MAP])) return r->error;
    if (memcmp(map,after,l->sizes[XGM_T_MAP])) return "GoValueChanged";
    out->total = used; out->next = out->count ? out->start + out->count : used;
    out->complete = out->next >= used;
    return NULL;
}
void xgm_map_read(const struct xgm_layout *l, struct xgo_reader *r, uint64_t module, uint64_t type, uint64_t at,
                  uint64_t start, unsigned limit, struct xgm_page *out) {
    memset(out,0,sizeof *out); out->start=start;
    out->reason = layout(l);
    if (out->reason) return;
    if (!limit || limit > XGM_PAGE) { out->reason="GoMapPageLimit"; return; }
    struct scan s = {.l=l,.r=r,.out=out,.limit=limit};
    out->reason = scan_map(&s,module,type,at);
    if (out->reason) { out->total=out->next=out->count=0; out->complete=0; memset(out->entries,0,sizeof out->entries); }
}
