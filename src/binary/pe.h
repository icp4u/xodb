#ifndef XODB_PE_H
#define XODB_PE_H
#include <stddef.h>
#include <stdint.h>

/* Read-only PE32+ x64 metadata. File offsets and loaded-image RVAs are
 * different input layouts. The source and its identity belong to the caller;
 * reads must be exact and the caller validates identity before publication. */
enum xpe_status { XPE_OK, XPE_NOT_PE, XPE_UNSUPPORTED, XPE_MALFORMED,
    XPE_LIMIT, XPE_IO, XPE_CHANGED, XPE_CANCELLED, XPE_NOMEM, XPE_NOT_FOUND };
enum xpe_layout { XPE_FILE, XPE_MEMORY };
struct xpe_source {
    void *context;
    uint64_t size;
    enum xpe_layout layout;
    enum xpe_status (*read)(void *, uint64_t offset, void *, size_t);
};
#define XPE_MAX_SECTIONS 96u
#define XPE_MAX_EXPORTS 65536u
#define XPE_MAX_IMPORTS 65536u
/* Large game executables carry millions of .pdata rows. Each retained row is
 * 16 bytes and is charged to the retained cap like every other allocation. */
#define XPE_MAX_FUNCTIONS 4194304u
#define XPE_MAX_READ_BYTES (UINT64_C(128) * 1024 * 1024)
#define XPE_MAX_READS 262144u
#define XPE_MAX_RETAINED_BYTES (UINT64_C(96) * 1024 * 1024)
struct xpe_section {
    char name[9];
    uint32_t rva, virtual_size, raw_offset, raw_size, characteristics;
};
struct xpe_export { uint32_t ordinal, rva; const char *forwarder; };
/* A separate name table preserves aliases and ordinal-only exports. */
struct xpe_export_name { const char *name; uint32_t export_index; };
struct xpe_import {
    const char *dll, *name;
    uint32_t iat_rva;
    uint16_t ordinal, hint;
    unsigned by_ordinal, lookup_unavailable;
};
struct xpe_function { uint32_t begin, end, unwind, record_rva; };
struct xpe_codeview { unsigned char guid[16]; uint32_t age; const char *path; };
struct xpe_info {
    uint64_t preferred_base, source_bytes, source_reads, retained_bytes;
    uint32_t image_size, headers_size, entry_rva, timestamp;
    uint32_t section_alignment, file_alignment;
    uint16_t machine, characteristics;
    unsigned section_count, export_count, export_name_count, import_count;
    /* function_skipped counts empty (begin >= end) .pdata rows left out. */
    unsigned function_count, function_skipped, codeview_count, unsupported_codeview;
    const char *module_name;
};
struct xpe_image;
enum xpe_status xpe_load(const struct xpe_source *, struct xpe_image **);
/* Compare loaded placement headers against parsed file metadata. The loaded
 * preferred base may be relocated; structural fields and directories must
 * agree. This does not prove map coverage or stopped-generation coherence. */
enum xpe_status xpe_validate_loaded_headers(const struct xpe_image *, const struct xpe_source *);
void xpe_destroy(struct xpe_image *);
const struct xpe_info *xpe_info(const struct xpe_image *);
const struct xpe_section *xpe_section(const struct xpe_image *, unsigned);
const struct xpe_export *xpe_export(const struct xpe_image *, unsigned);
const struct xpe_export_name *xpe_export_name(const struct xpe_image *, unsigned);
const struct xpe_import *xpe_import(const struct xpe_image *, unsigned);
const struct xpe_function *xpe_function(const struct xpe_image *, unsigned);
const struct xpe_codeview *xpe_codeview(const struct xpe_image *, unsigned);
const struct xpe_export *xpe_find_export(const struct xpe_image *, const char *);
const struct xpe_function *xpe_function_at(const struct xpe_image *, uint32_t rva);
/* First name, in name-table order, of a non-forwarded export at exactly rva. */
const char *xpe_export_name_at(const struct xpe_image *, uint32_t rva);
/* Bounded exact read through the retained source, for later unwind decoding.
 * Mutable sources still require caller-side generation/identity validation. */
enum xpe_status xpe_read_rva(struct xpe_image *, uint32_t, void *, size_t);
/* One bounded post-parse read, without spending the parser's lifetime budget.
 * Does not mutate the image; source coherence is still enforced by its reader. */
enum xpe_status xpe_read_range(const struct xpe_image *, uint32_t, void *, size_t);
#endif
