#ifndef XODB_CFI_IMAGE_H
#define XODB_CFI_IMAGE_H
#include "../binary/object.h"

#define XCF_MAX_BYTES (32u * 1024u * 1024u)
struct xcf_image;
struct xcf_progress {
    uint64_t source_bytes, retained_bytes;
    unsigned phase; /* header, allocation, frame, search header, validation, ready */
};
/* Borrows a prepared object. Copies only EH unwind sections into a bounded ELF
 * container, preserving their link addresses and bytes. This is exclusively
 * CFI input, never a complete module, executable image or source of code bytes.
 * Relocatable, compressed and sectionless inputs are not supported. */
enum xbo_status xcf_create(struct xbo_object *, struct xcf_image **);
void xcf_destroy(struct xcf_image *);
/* AGAIN/CANCELLED retain progress; identity changes permanently withdraw data. */
enum xbo_status xcf_step(struct xcf_image *, struct xbo_budget *);
/* Only after successful step. Storage is private and writable for libelf, and
 * borrowed until destroy. Revalidate the pinned source before each later use. */
enum xbo_status xcf_result(struct xcf_image *, unsigned char **, size_t *);
void xcf_progress(const struct xcf_image *, struct xcf_progress *);
#endif
