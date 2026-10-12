#include "macho_object.h"
#include <stdlib.h>
#include <string.h>

struct range { uint64_t object, linked, size; unsigned code; };
struct xmo_object_map {
    struct range *ranges, *code;
    size_t count, code_count, capacity, bytes;
};
static int by_object(const void *a, const void *b) {
    const struct range *x=a,*y=b;
    return (x->object>y->object)-(x->object<y->object);
}
static int by_link(const void *a, const void *b) {
    const struct range *x=a,*y=b;
    return (x->linked>y->linked)-(x->linked<y->linked);
}
enum xmo_status xmo_object_external(void *unused, uint32_t symbol, uint64_t addend, uint64_t *token) {
    (void)unused;
    if (symbol>=XMO_MAX_OBJECT_SYMBOLS || addend>UINT32_MAX) return XMO_UNSUPPORTED;
    *token=UINT64_C(0x8000000000000000)+((uint64_t)symbol<<32)+addend;
    return XMO_OK;
}
void xmo_object_map_free(struct xmo_object_map *map) {
    if (map) { free(map->ranges);free(map->code);free(map); }
}
size_t xmo_object_map_bytes(const struct xmo_object_map *map) { return map ? map->bytes : 0; }
static enum xmo_status append(struct xmo_object_map *map, uint64_t object, uint64_t linked,
                              uint64_t size, unsigned code) {
    if (!size || size>UINT64_MAX-object || size>UINT64_MAX-linked) return XMO_MALFORMED;
    if (map->count==map->capacity) return XMO_LIMIT;
    map->ranges[map->count++]=(struct range){object,linked,size,code};
    if (code) map->code[map->code_count++]=(struct range){object,linked,size,code};
    return XMO_OK;
}
static enum xmo_status extent(struct xmo_image *image, const struct xmo_symbol *symbol, uint64_t *size) {
    if (!(xmo_symbol_flags(symbol)&XMO_SYMBOL_DEFINED)) return XMO_NOT_FOUND;
    const struct xmo_symbol *nearest=NULL;
    enum xmo_status status=xmo_symbol_at(image,symbol->value,&nearest,size);
    if (status!=XMO_OK) return status;
    if (!nearest || nearest->value!=symbol->value || nearest->sect!=symbol->sect || !*size) return XMO_UNAVAILABLE;
    return XMO_OK;
}
enum xmo_status xmo_object_map_create(struct xmo_image *linked, struct xmo_image *object,
    uint32_t object_index, uint64_t allowance, struct xmo_object_map **out) {
    if (!linked || !object || !out) return XMO_MALFORMED;
    *out=NULL;
    const struct xmo_info *oi=xmo_info(object), *li=xmo_info(linked);
    if (oi->filetype!=XMO_MH_OBJECT || oi->cputype!=li->cputype ||
        (oi->cpusubtype&XMO_CPU_SUBTYPE_MASK)!=(li->cpusubtype&XMO_CPU_SUBTYPE_MASK)) return XMO_UNSUPPORTED;
    /* The high half is reserved for private tokens for undefined symbols. */
    for (uint32_t i=0;i<oi->section_count;++i) {
        const struct xmo_section *s=xmo_section(object,i);
        if (s->address>UINT32_MAX || s->size>UINT32_MAX-s->address) return XMO_UNSUPPORTED;
    }
    uint32_t count=0;
    enum xmo_status status=xmo_symbols(object,&count);
    if (status!=XMO_OK) return status;
    if (count>XMO_MAX_OBJECT_SYMBOLS) return XMO_LIMIT;
    struct xmo_debug_map debug;
    status=xmo_debug_map(linked,&debug);
    if (status!=XMO_OK) return status;
    if (object_index>=debug.object_count) return XMO_MALFORMED;
    const struct xmo_debug_object *owner=&debug.objects[object_index];
    if (owner->function_count>XMO_MAX_OBJECT_SYMBOLS) return XMO_LIMIT;
    size_t capacity=(size_t)count+owner->function_count;
    uint64_t bytes=sizeof(struct xmo_object_map)+capacity*sizeof(struct range)+owner->function_count*sizeof(struct range);
    if (bytes>allowance) return XMO_LIMIT;
    struct xmo_object_map *map=calloc(1,sizeof *map);
    if (!map) return XMO_NOMEM;
    map->capacity=capacity;map->bytes=(size_t)bytes;
    map->ranges=calloc(capacity ? capacity : 1,sizeof *map->ranges);
    map->code=calloc(owner->function_count ? owner->function_count : 1,sizeof *map->code);
    if (!map->ranges || !map->code) { status=XMO_NOMEM;goto fail; }
    char name[XMO_MAX_NAME+1];
    for (uint32_t i=0;i<owner->function_count;++i) {
        const struct xmo_debug_function *function=&debug.functions[owner->first_function+i];
        if (function->object!=object_index || !function->size) { status=XMO_MALFORMED;goto fail; }
        status=xmo_string(linked,function->name,name,sizeof name);
        if (status!=XMO_OK) goto fail;
        const struct xmo_symbol *os=NULL,*ls=NULL;
        status=xmo_symbol_unique(object,name,&os);
        if (status!=XMO_OK) goto fail;
        status=xmo_symbol_unique(linked,name,&ls);
        if (status!=XMO_OK) goto fail;
        uint64_t object_size=0,linked_size=0;
        if (extent(object,os,&object_size)!=XMO_OK || extent(linked,ls,&linked_size)!=XMO_OK ||
            ls->value!=function->address || function->size>object_size || function->size>linked_size ||
            !(xmo_section(object,os->sect-1)->flags&0x80000400u) ||
            !(xmo_section(linked,ls->sect-1)->flags&0x80000400u)) { status=XMO_UNAVAILABLE;goto fail; }
        status=append(map,os->value,function->address,function->size,1);
        if (status!=XMO_OK) goto fail;
    }
    for (uint32_t i=0;i<count;++i) {
        const struct xmo_symbol *os=xmo_symbol(object,i);
        unsigned flags=xmo_symbol_flags(os);
        if (flags&XMO_SYMBOL_STAB) continue;
        if (!(flags&(XMO_SYMBOL_DEFINED|XMO_SYMBOL_UNDEFINED))) continue;
        if (flags&XMO_SYMBOL_DEFINED) {
            const struct xmo_section *section=xmo_section(object,os->sect-1);
            /* n_sect is a file byte: 0 or past the section table names no section. */
            if (!section) continue;
            if (section->flags&0x82000400u) continue; /* Code or DWARF. */
        }
        status=xmo_string(object,os->strx,name,sizeof name);
        if (status!=XMO_OK) goto fail;
        const struct xmo_symbol *unique=NULL,*ls=NULL;
        status=xmo_symbol_unique(object,name,&unique);
        if (status==XMO_UNAVAILABLE || status==XMO_NOT_FOUND) continue;
        if (status!=XMO_OK) goto fail;
        if (unique->value!=os->value || unique->sect!=os->sect) continue;
        status=xmo_symbol_unique(linked,name,&ls);
        if (status==XMO_UNAVAILABLE || status==XMO_NOT_FOUND) continue;
        if (status!=XMO_OK) goto fail;
        uint64_t size=0,object_size=0,object_address=os->value;
        if (extent(linked,ls,&size)!=XMO_OK) continue;
        if (flags&XMO_SYMBOL_DEFINED) {
            if (extent(object,os,&object_size)!=XMO_OK) continue;
            if (object_size<size) size=object_size;
        } else {
            status=xmo_object_external(NULL,i,0,&object_address);
            if (status!=XMO_OK) goto fail;
            if (size>UINT32_MAX) size=UINT32_MAX;
        }
        status=append(map,object_address,ls->value,size,0);
        if (status!=XMO_OK) goto fail;
    }
    qsort(map->ranges,map->count,sizeof *map->ranges,by_object);
    size_t kept=0;
    for (size_t i=0;i<map->count;++i) {
        struct range r=map->ranges[i];
        if (kept && r.object<map->ranges[kept-1].object+map->ranges[kept-1].size) {
            const struct range *previous=&map->ranges[kept-1];
            if (r.object==previous->object && r.linked==previous->linked && r.size==previous->size) continue;
            status=XMO_UNAVAILABLE;goto fail;
        }
        map->ranges[kept++]=r;
    }
    map->count=kept;
    qsort(map->code,map->code_count,sizeof *map->code,by_link);
    for (size_t i=1;i<map->code_count;++i)
        if (map->code[i].linked<map->code[i-1].linked+map->code[i-1].size) { status=XMO_UNAVAILABLE;goto fail; }
    *out=map;return XMO_OK;
fail:
    xmo_object_map_free(map);return status;
}
enum xmo_status xmo_object_pc(const struct xmo_object_map *map, uint64_t linked, uint64_t *object) {
    if (!map || !object) return XMO_MALFORMED;
    size_t lo=0,hi=map->code_count;
    while (lo<hi) { size_t mid=lo+(hi-lo)/2;if (map->code[mid].linked<=linked) lo=mid+1;else hi=mid; }
    if (!lo) return XMO_NOT_FOUND;
    const struct range *r=&map->code[lo-1];
    if (linked-r->linked>=r->size) return XMO_NOT_FOUND;
    *object=r->object+(linked-r->linked);return XMO_OK;
}
enum xmo_status xmo_object_address(const struct xmo_object_map *map, uint64_t object, uint64_t *linked) {
    if (!map || !linked) return XMO_MALFORMED;
    size_t lo=0,hi=map->count;
    while (lo<hi) { size_t mid=lo+(hi-lo)/2;if (map->ranges[mid].object<=object) lo=mid+1;else hi=mid; }
    if (!lo) return XMO_NOT_FOUND;
    const struct range *r=&map->ranges[lo-1];
    if (object-r->object>=r->size) return XMO_NOT_FOUND;
    *linked=r->linked+(object-r->object);return XMO_OK;
}
