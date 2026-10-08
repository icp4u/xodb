#include "cfi_image.h"
#include <stdlib.h>
#include <string.h>

struct xcf_image {
    struct xbo_object *object;
    struct xbo_section frame, header;
    uint32_t frame_index, header_index;
    unsigned char original[64], *bytes;
    size_t header_done, frame_done, search_done, size, frame_offset, search_offset;
    unsigned phase, wide, little;
    enum xbo_status failure;
};
static uint64_t get(const unsigned char *p, unsigned n, unsigned little) {
    uint64_t v = 0;
    for (unsigned i = 0; i < n; ++i) v |= (uint64_t)p[i] << (8 * (little ? i : n-1-i));
    return v;
}
static void put(unsigned char *p, unsigned n, uint64_t v, unsigned little) {
    for (unsigned i = 0; i < n; ++i) p[i] = (unsigned char)(v >> (8 * (little ? i : n-1-i)));
}
static enum xbo_status select_section(struct xcf_image *image, const char *name,
                                     uint32_t *index, struct xbo_section *section) {
    enum xbo_status s = xbo_find_section(image->object, name, index);
    if (s != XBO_OK) return s;
    *section = *xbo_section(image->object, *index);
    if (section->flags & 0x800) return XBO_LIMIT; /* SHF_COMPRESSED */
    if (!(section->flags & 2) || !section->size ||
        (section->type != 1 && !(section->type == 0x70000001 &&
                                xbo_machine(image->object) == 62)) ||
        section->address > UINT64_MAX - section->size) return XBO_MALFORMED;
    if (section->size > XCF_MAX_BYTES || section->alignment > XCF_MAX_BYTES) return XBO_LIMIT;
    if (section->alignment && (section->alignment & (section->alignment-1))) return XBO_MALFORMED;
    for (uint32_t i = 0; i < xbo_section_count(image->object); ++i) {
        const struct xbo_section *r = xbo_section(image->object, i);
        if ((r->type == 4 || r->type == 9) && r->info == *index && r->size) return XBO_LIMIT;
    }
    return XBO_OK;
}
enum xbo_status xcf_create(struct xbo_object *object, struct xcf_image **out) {
    if (!out) return XBO_MALFORMED;
    *out = NULL;
    if (!object) return XBO_MALFORMED;
    struct xbo_progress progress;
    xbo_progress(object, &progress);
    if (!progress.ready || progress.changed) return progress.changed ? XBO_CHANGED : XBO_AGAIN;
    struct xcf_image *image = calloc(1, sizeof *image);
    if (!image) return XBO_NOMEM;
    image->object = object;
    image->wide = xbo_address_size(object) == 8;
    image->little = xbo_little_endian(object);
    enum xbo_status status = select_section(image, ".eh_frame", &image->frame_index, &image->frame);
    if (status != XBO_OK) { free(image); return status; }
    status = select_section(image, ".eh_frame_hdr", &image->header_index, &image->header);
    if (status != XBO_OK && status != XBO_NOT_FOUND) { free(image); return status; }
    if (status == XBO_NOT_FOUND) image->header = (struct xbo_section){0};
    *out = image;
    return XBO_OK;
}
void xcf_destroy(struct xcf_image *image) {
    if (image) { free(image->bytes); free(image); }
}
static size_t align_offset(size_t n, uint64_t alignment) {
    size_t a = alignment > 8 ? (size_t)alignment : 8;
    return (n + a-1) & ~(a-1);
}
static void section(struct xcf_image *image, unsigned ordinal, unsigned name,
                    const struct xbo_section *source, size_t offset) {
    unsigned char *p = image->bytes + 64 + ordinal * (image->wide ? 64 : 40);
    unsigned width = image->wide ? 8 : 4, little = image->little;
    put(p, 4, name, little); put(p+4, 4, source->type, little); p += 8;
    put(p, width, source->flags, little); p += width;
    put(p, width, source->address, little); p += width;
    put(p, width, offset, little); p += width;
    put(p, width, source->size, little); p += width;
    /* This container has no relocation or symbol-table links. */
    p += 8;
    put(p, width, source->alignment, little);
}
static enum xbo_status allocate_image(struct xcf_image *image) {
    static const char names[] = "\0.shstrtab\0.eh_frame\0.eh_frame_hdr";
    unsigned width = image->wide ? 8 : 4;
    uint64_t type = get(image->original+16, 2, image->little);
    if (type != 2 && type != 3) return XBO_LIMIT;
    unsigned count = image->header.size ? 4 : 3;
    size_t strings = 64 + count * (image->wide ? 64 : 40);
    image->frame_offset = align_offset(strings + sizeof names, image->frame.alignment);
    image->search_offset = align_offset(image->frame_offset + (size_t)image->frame.size,
                                         image->header.alignment);
    image->size = image->header.size ? image->search_offset + (size_t)image->header.size :
                                      image->frame_offset + (size_t)image->frame.size;
    if (image->size > XCF_MAX_BYTES) return XBO_LIMIT;
    image->bytes = calloc(1, image->size);
    if (!image->bytes) return XBO_NOMEM;
    unsigned char *p = image->bytes;
    memcpy(p, image->original, 24); /* ident, type, machine, version */
    put(p + (image->wide ? 40 : 32), width, 64, image->little);
    memcpy(p + (image->wide ? 48 : 36), image->original + (image->wide ? 48 : 36), 4);
    put(p + (image->wide ? 52 : 40), 2, image->wide ? 64 : 52, image->little);
    put(p + (image->wide ? 58 : 46), 2, image->wide ? 64 : 40, image->little);
    put(p + (image->wide ? 60 : 48), 2, count, image->little);
    put(p + (image->wide ? 62 : 50), 2, 1, image->little);
    memcpy(p + strings, names, sizeof names);
    section(image, 1, 1, &(struct xbo_section){.type=3, .size=sizeof names, .alignment=1}, strings);
    section(image, 2, 11, &image->frame, image->frame_offset);
    if (image->header.size) section(image, 3, 21, &image->header, image->search_offset);
    return XBO_OK;
}
enum xbo_status xcf_step(struct xcf_image *image, struct xbo_budget *budget) {
    if (!image || !budget) return XBO_MALFORMED;
    if (image->failure != XBO_OK) return image->failure;
    enum xbo_status status;
    for (;;) {
        if (image->phase == 0) {
            status = xbo_read(image->object, 0, image->original, image->wide ? 64 : 52,
                              &image->header_done, budget);
        } else if (image->phase == 1) {
            status = allocate_image(image);
        } else if (image->phase == 2) {
            status = xbo_read(image->object, image->frame.offset,
                image->bytes+image->frame_offset, (size_t)image->frame.size, &image->frame_done, budget);
        } else if (image->phase == 3) {
            status = image->header.size ? xbo_read(image->object, image->header.offset,
                image->bytes+image->search_offset, (size_t)image->header.size, &image->search_done, budget) : XBO_OK;
        } else {
            status = xbo_validate(image->object, budget);
        }
        if (status != XBO_OK) {
            if (status != XBO_AGAIN && status != XBO_CANCELLED) image->failure = status;
            return status;
        }
        if (image->phase >= 4) { image->phase = 5; return XBO_OK; }
        ++image->phase;
    }
}
enum xbo_status xcf_result(struct xcf_image *image, unsigned char **out, size_t *size) {
    if (!out || !size) return XBO_MALFORMED;
    *out = NULL; *size = 0;
    if (!image) return XBO_MALFORMED;
    if (image->failure != XBO_OK) return image->failure;
    if (image->phase != 5) return XBO_AGAIN;
    *out = image->bytes; *size = image->size;
    return XBO_OK;
}
void xcf_progress(const struct xcf_image *image, struct xcf_progress *out) {
    if (!out) return;
    *out = (struct xcf_progress){0};
    if (image) *out = (struct xcf_progress){.source_bytes=image->header_done+image->frame_done+image->search_done,
        .retained_bytes=sizeof *image+(image->bytes ? image->size : 0), .phase=image->phase};
}
