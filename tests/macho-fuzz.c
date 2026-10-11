/* libFuzzer target for src/binary/macho.c. The first byte selects the layout
 * and the wanted slice; the rest is the source. */
#include "../src/binary/macho.h"
#include <string.h>
struct input { const unsigned char *data; size_t size; };
static enum xmo_status bytes(void *user, uint64_t at, void *out, size_t size) {
    struct input *in = user;
    if (at > in->size || size > in->size-at) return XMO_IO;
    memcpy(out, in->data+(size_t)at, size);
    return XMO_OK;
}
int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size) {
    static char name[XMO_MAX_NAME+1];
    if (!size) return 0;
    struct input in = { data+1, size-1 };
    struct xmo_source source = { &in, in.size, (data[0]&1) ? XMO_MEMORY : XMO_FILE, bytes };
    struct xmo_options options = {
        .cputype = (data[0]&2) ? XMO_CPU_X86_64 : (data[0]&4) ? XMO_CPU_ARM64 : 0,
        .max_read_bytes = (data[0]&8) ? 4096 : 0,
        .cpusubtype = (data[0]&16) ? XMO_CPU_SUBTYPE_ARM64E : 0,
        .match_subtype = (data[0]&64) != 0,
        .max_retained_bytes = (data[0]&128) ? 4*1024*1024 : 0,
    };
    struct xmo_image *p = NULL;
    if (xmo_load(&source, &options, &p) != XMO_OK) return 0;
    const struct xmo_info *info = xmo_info(p);
    if (data[0]&32) (void)xmo_prepare_labels(p);
    const struct xmo_symbol *found;
    struct xmo_debug_map map;
    const uint64_t *starts;
    uint32_t count = 0;
    uint64_t extent;
    unsigned char block[64];
    for (unsigned i=0; i<info->section_count; ++i) {
        const struct xmo_section *s = xmo_section(p, i);
        struct xmo_range range;
        (void)xmo_find_section(p, s->segment, s->name);
        if (xmo_section_range(p, s, &range) != XMO_OK) continue;
        (void)xmo_read_section(p, s, 0, block, range.size < sizeof block ? (size_t)range.size : sizeof block);
        (void)xmo_read_section(p, s, range.size, block, 1);
    }
    for (unsigned i=0; i<info->dylib_count; ++i) (void)strlen(xmo_dylib(p, i)->name);
    (void)xmo_slide(p, 0x100000000, &extent);
    (void)xmo_function_starts(p, &starts, &count);
    if (xmo_symbols(p, &count) == XMO_OK) {
        for (uint32_t i=0; i<count; ++i) {
            const struct xmo_symbol *s = xmo_symbol(p, i);
            (void)xmo_symbol_flags(s);
            (void)xmo_symbol_at(p, s->value, &found, &extent);
            (void)xmo_symbol_at(p, s->value+1, &found, NULL);
            if (xmo_string(p, s->strx, name, sizeof name) == XMO_OK) (void)xmo_symbol_find(p, name, &found);
        }
    }
    (void)xmo_symbol_find(p, "_main", &found);
    if (xmo_debug_map(p, &map) == XMO_OK) {
        for (uint32_t i=0; i<map.object_count; ++i) (void)xmo_string(p, map.objects[i].path, name, 64);
        for (uint32_t i=0; i<map.function_count; ++i) if (map.functions[i].object != UINT32_MAX && map.functions[i].object >= map.object_count) __builtin_trap();
    }
    if (info->retained_bytes > XMO_MAX_RETAINED_BYTES || info->source_bytes > XMO_MAX_READ_BYTES) __builtin_trap();
    if (options.max_retained_bytes && info->retained_bytes > options.max_retained_bytes) __builtin_trap();
    xmo_destroy(p);
    return 0;
}
