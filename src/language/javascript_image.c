#include "javascript_image.h"
#include <elf.h>
#include <stdlib.h>
#include <string.h>

#define CONSTANTS (XJS_FIELD_COUNT + 4)
#define NAMES (CONSTANTS + 1)
static const char *const versions[] = {
    "_ZN2v88internal7Version6major_E", "_ZN2v88internal7Version6minor_E",
    "_ZN2v88internal7Version6build_E", "_ZN2v88internal7Version6patch_E",
    "_ZN2v88internal7Version15version_string_E"
};
struct constant { uint64_t address; unsigned char bytes[4]; size_t index; };
struct xjs_image {
    struct xbo_object *object;
    struct xbs_query *symbols;
    struct constant constants[CONSTANTS];
    struct xjs_layout layout;
    const struct xbo_section *note;
    unsigned char note_bytes[256];
    uint64_t version_pointer;
    size_t index, count, done;
    int stage, complete;
    enum xbo_status failure;
    const char *error;
};
static enum xbo_status fail(struct xjs_image *image, enum xbo_status status, const char *why) {
    image->failure = status;
    image->error = why;
    return status;
}
static uint64_t little(const unsigned char *bytes, size_t n) {
    uint64_t value = 0;
    for (size_t i = 0; i < n; ++i) value |= (uint64_t)bytes[i] << (i * 8);
    return value;
}
/* A link extent must belong to exactly one readable PT_LOAD. In particular,
 * a pointer to another image, a section-only address, or TLS is not accepted. */
static const struct xbo_segment *segment(struct xjs_image *image, uint64_t address, size_t n) {
    const struct xbo_segment *found = NULL;
    for (uint32_t i = 0; i < xbo_segment_count(image->object); ++i) {
        const struct xbo_segment *s = xbo_segment(image->object, i);
        if (s->type != PT_LOAD || !(s->flags & PF_R) || address < s->address ||
            address - s->address > s->memory_size || n > s->memory_size - (address - s->address)) continue;
        if (found) return NULL;
        found = s;
    }
    return found;
}
static enum xbo_status file_bytes(struct xjs_image *image, uint64_t address,
        void *out, size_t n, size_t *done, struct xbo_budget *budget) {
    const struct xbo_segment *s = segment(image, address, n);
    if (!s || *done > n) return XBO_MALFORMED;
    uint64_t delta = address - s->address;
    size_t stored = delta >= s->file_size ? 0 : s->file_size - delta < n ? (size_t)(s->file_size - delta) : n;
    enum xbo_status status;
    if (*done < stored) {
        status = xbo_read(image->object, s->offset + delta, out, stored, done, budget);
        if (status != XBO_OK) return status;
    }
    status = xbo_validate(image->object, budget);
    if (status != XBO_OK) return status;
    memset((unsigned char *)out + stored, 0, n - stored); *done = n;
    return XBO_OK;
}
static int compare(const void *left, const void *right) {
    const struct constant *a = left, *b = right;
    return a->address < b->address ? -1 : a->address > b->address;
}
enum xbo_status xjs_image_create(struct xbo_object *object, struct xjs_image **out) {
    if (!out) return XBO_MALFORMED;
    *out = NULL;
    if (!object || !xbo_identity(object)) return XBO_MALFORMED;
    if (xbo_address_size(object) != 8 || !xbo_little_endian(object) || xbo_machine(object) != EM_X86_64)
        return XBO_LIMIT;
    struct xjs_image *image = calloc(1, sizeof *image);
    if (!image) return XBO_NOMEM;
    const char *names[NAMES];
    for (size_t i = 0; i < XJS_FIELD_COUNT; ++i) names[i] = xjs_field_names[i];
    for (size_t i = 0; i < 5; ++i) names[XJS_FIELD_COUNT + i] = versions[i];
    enum xbo_status status = xbs_create(object, names, NAMES, &image->symbols);
    if (status != XBO_OK) { free(image); return status; }
    image->object = object;
    *out = image; return XBO_OK;
}
void xjs_image_destroy(struct xjs_image *image) {
    if (image) { xbs_destroy(image->symbols); free(image); }
}
static enum xbo_status prepare(struct xjs_image *image, struct xbo_budget *budget, uint64_t work) {
    enum xbo_status status;
    if (!image->stage) {
        status = xbs_step(image->symbols, budget, work);
        if (status != XBO_OK) return status;
        struct xbs_symbol pointer;
        status = xbs_result(image->symbols, CONSTANTS, &pointer);
        if (status != XBO_OK) return fail(image, status, "JavaScriptRuntimeUnavailable");
        if (pointer.type != STT_OBJECT || pointer.size != 8 ||
            (xbo_section(image->object, pointer.section)->flags & SHF_TLS) || !segment(image, pointer.address, 8))
            return fail(image, XBO_MALFORMED, "JavaScriptVersionUnavailable");
        image->version_pointer = pointer.address;
        size_t size = 0;
        const unsigned char *id = xbo_build_id(image->object, &size);
        uint32_t section;
        if (!id || !size || size > sizeof image->layout.build_id ||
            xbo_find_section(image->object, ".note.gnu.build-id", &section) != XBO_OK)
            return fail(image, XBO_NOT_FOUND, "JavaScriptBuildIdUnavailable");
        image->note = xbo_section(image->object, section);
        if (image->note->type != SHT_NOTE || !(image->note->flags & SHF_ALLOC) ||
            image->note->size > sizeof image->note_bytes || !image->note->size ||
            !segment(image, image->note->address, (size_t)image->note->size))
            return fail(image, XBO_MALFORMED, "JavaScriptBuildIdUnavailable");
        image->layout.build_id_len = (uint8_t)size;
        memcpy(image->layout.build_id, id, size);
        image->stage = 1;
    }
    if (image->stage == 1) {
        status = xbo_read(image->object, image->note->offset, image->note_bytes,
            (size_t)image->note->size, &image->done, budget);
        if (status != XBO_OK) return status;
        /* Section and segment must describe the same file bytes. */
        const struct xbo_segment *s = segment(image, image->note->address, (size_t)image->note->size);
        uint64_t delta = image->note->address - s->address;
        if (delta > s->file_size || image->note->size > s->file_size - delta ||
            s->offset + delta != image->note->offset)
            return fail(image, XBO_MALFORMED, "JavaScriptBuildIdUnavailable");
        image->done = 0; image->stage = 2;
    }
    for (; image->index < CONSTANTS; ++image->index) {
        if (!work--) return XBO_AGAIN;
        struct xbs_symbol symbol;
        status = xbs_result(image->symbols, image->index, &symbol);
        if (status == XBO_NOT_FOUND && image->index < XJS_FIELD_COUNT) continue;
        if (status != XBO_OK) return fail(image, status, "JavaScriptVersionUnavailable");
        if (symbol.type != STT_OBJECT || symbol.size != 4 ||
            (xbo_section(image->object, symbol.section)->flags & SHF_TLS))
            return fail(image, XBO_MALFORMED, "JavaScriptMetadataInconsistent");
        struct constant *constant = &image->constants[image->count];
        status = file_bytes(image, symbol.address, constant->bytes, 4, &image->done, budget);
        if (status != XBO_OK) return status;
        constant->address = symbol.address; constant->index = image->index;
        int32_t value = (int32_t)(uint32_t)little(constant->bytes, 4);
        if (image->index < XJS_FIELD_COUNT) {
            image->layout.fields[image->index] = value;
            image->layout.present[image->index] = 1;
        } else {
            if (value < 0) return fail(image, XBO_MALFORMED, "JavaScriptVersionUnsupported");
            image->layout.version[image->index - XJS_FIELD_COUNT] = (uint32_t)value;
        }
        ++image->count; image->done = 0;
    }
    status = xbo_validate(image->object, budget);
    if (status != XBO_OK) return status;
    if (!image->complete) qsort(image->constants, image->count, sizeof *image->constants, compare);
    image->complete = 1;
    return XBO_OK;
}
enum xbo_status xjs_image_step(struct xjs_image *image, struct xbo_budget *budget, uint64_t work) {
    if (!image) return XBO_MALFORMED;
    if (image->failure) return image->failure;
    enum xbo_status status = xbo_validate(image->object, budget);
    if (status == XBO_OK) status = prepare(image, budget, work);
    if (status != XBO_OK && status != XBO_AGAIN && status != XBO_CANCELLED && !image->failure)
        return fail(image, status, status == XBO_CHANGED ? "JavaScriptMetadataFileChanged" : "JavaScriptMetadataUnavailable");
    return status;
}
void xjs_image_progress(const struct xjs_image *image, struct xjs_image_progress *out) {
    if (!out) return;
    memset(out, 0, sizeof *out);
    if (!image) return;
    xbs_progress(image->symbols, &out->symbols);
    out->constants = image->count;
    out->complete = image->complete && !image->failure;
}
const char *xjs_image_error(const struct xjs_image *image) { return image ? image->error : "JavaScriptMetadataUnavailable"; }
static int memory(struct xjs_reader *reader, uint64_t bias, uint64_t link, void *out, size_t n) {
    return link <= UINT64_MAX - bias && xjs_read_memory(reader, bias + link, out, n);
}
struct xjs_image_verifier {
    struct xjs_image *image;
    uint64_t bias, version_address;
    size_t index, done, length;
    unsigned stage;
    unsigned char expected[64];
    struct xjs_layout result;
    enum xbo_status failure;
    const char *error;
};
enum xbo_status xjs_image_verifier_create(struct xjs_image *image, uint64_t bias, struct xjs_image_verifier **out) {
    if (!out) return XBO_MALFORMED;
    *out = NULL;
    if (!image) return XBO_MALFORMED;
    if (image->failure) return image->failure;
    if (!image->complete) return XBO_AGAIN;
    struct xjs_image_verifier *v = calloc(1, sizeof *v);
    if (!v) return XBO_NOMEM;
    v->image = image; v->bias = bias;
    *out = v; return XBO_OK;
}
void xjs_image_verifier_destroy(struct xjs_image_verifier *v) { free(v); }
static enum xbo_status verify_fail(struct xjs_image_verifier *v, enum xbo_status status, const char *reason) {
    v->failure = status; v->error = reason;
    memset(&v->result, 0, sizeof v->result);
    return status;
}
static enum xbo_status verify(struct xjs_image_verifier *v, struct xjs_reader *reader,
                               struct xbo_budget *budget, uint64_t work) {
    struct xjs_image *image = v->image;
    unsigned char actual[4096];
    while (v->stage < 6) {
        enum xbo_status status = xbo_validate(image->object, budget);
        if (status != XBO_OK) return status;
        if (!work--) return XBO_AGAIN;
        switch (v->stage) {
        case 0:
            if (!memory(reader, v->bias, image->note->address, actual, (size_t)image->note->size)) goto unreadable;
            if (memcmp(actual, image->note_bytes, (size_t)image->note->size))
                return verify_fail(v, XBO_MALFORMED, "JavaScriptBuildIdMismatch");
            ++v->stage;
            break;
        case 1: {
            if (v->index == image->count) { ++v->stage; break; }
            size_t end = v->index + 1;
            uint64_t start = image->constants[v->index].address;
            size_t n = 4;
            while (end < image->count && image->constants[end].address - start <= sizeof actual - 4 &&
                   image->constants[end].address - image->constants[end - 1].address <= 64) {
                size_t span = (size_t)(image->constants[end].address - start) + 4;
                if (!segment(image, start, span)) break;
                n = span; ++end;
            }
            if (!memory(reader, v->bias, start, actual, n)) goto unreadable;
            for (; v->index < end; ++v->index) {
                const struct constant *constant = &image->constants[v->index];
                if (memcmp(actual + (constant->address - start), constant->bytes, 4))
                    return verify_fail(v, XBO_MALFORMED, "JavaScriptMetadataMismatch");
            }
            break;
        }
        case 2:
            if (!memory(reader, v->bias, image->version_pointer, actual, 8)) goto unreadable;
            v->version_address = little(actual, 8);
            if (v->version_address < v->bias)
                return verify_fail(v, XBO_MALFORMED, "JavaScriptVersionUnavailable");
            ++v->stage;
            break;
        case 3: {
            status = file_bytes(image, v->version_address - v->bias, v->expected, sizeof v->expected, &v->done, budget);
            if (status != XBO_OK) return status;
            const unsigned char *zero = memchr(v->expected, 0, sizeof v->expected);
            if (!zero) return verify_fail(v, XBO_MALFORMED, "JavaScriptVersionUnavailable");
            v->length = (size_t)(zero - v->expected) + 1;
            ++v->stage;
            break;
        }
        case 4:
            if (!memory(reader, v->bias, v->version_address - v->bias, actual, v->length)) goto unreadable;
            if (memcmp(actual, v->expected, v->length))
                return verify_fail(v, XBO_MALFORMED, "JavaScriptVersionMismatch");
            v->result = image->layout;
            memcpy(v->result.version_string, v->expected, v->length);
            const char *reason = xjs_layout_check(&v->result, v->result.build_id, v->result.build_id_len, v->result.version);
            if (reason) return verify_fail(v, XBO_MALFORMED, reason);
            ++v->stage;
            break;
        case 5:
            /* The loop's validation occurs after the final memory read. */
            ++v->stage;
            return XBO_OK;
        default: return XBO_MALFORMED;
        }
    }
    return xbo_validate(image->object, budget);
unreadable:
    return verify_fail(v, XBO_IO, reader->error ? reader->error : "JavaScriptInvalidAddress");
}
enum xbo_status xjs_image_verifier_step(struct xjs_image_verifier *v, struct xjs_reader *reader,
                                        struct xbo_budget *budget, uint64_t work) {
    if (!v || !reader) return XBO_MALFORMED;
    if (v->failure) return v->failure;
    if (v->image->failure) return verify_fail(v, v->image->failure, v->image->error);
    enum xbo_status status = verify(v, reader, budget, work);
    if (status != XBO_OK && status != XBO_AGAIN && status != XBO_CANCELLED && !v->failure) {
        const char *reason = status == XBO_CHANGED ? "JavaScriptMetadataFileChanged" : "JavaScriptMetadataUnavailable";
        if (status == XBO_CHANGED) fail(v->image, status, reason);
        return verify_fail(v, status, reason);
    }
    return status;
}
enum xbo_status xjs_image_verifier_result(const struct xjs_image_verifier *v, struct xjs_layout *out, const char **reason) {
    if (!out || !reason) return XBO_MALFORMED;
    memset(out, 0, sizeof *out); *reason = "JavaScriptMetadataUnavailable";
    if (!v) return XBO_MALFORMED;
    if (v->failure) { *reason = v->error; return v->failure; }
    if (v->image->failure) { *reason = v->image->error; return v->image->failure; }
    if (v->stage != 6) { *reason = "JavaScriptMetadataPending"; return XBO_AGAIN; }
    *out = v->result; *reason = NULL; return XBO_OK;
}
