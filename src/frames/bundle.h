#ifndef XODB_FRAMES_BUNDLE_H
#define XODB_FRAMES_BUNDLE_H
#include "../profile/logical_frames.h"
#include <stddef.h>
#include <stdint.h>
#define XFB_MAX_SOURCES 8
#define XFB_MAX_INPUT (64u * 1024u * 1024u)
#define XFB_MAX_METADATA (32u * 1024u)
#define XFB_HEADER_BYTES 88u
#define XFB_MAX_BYTES (XFB_MAX_INPUT + XFB_MAX_SOURCES * (XFB_HEADER_BYTES + XFB_MAX_METADATA) + XFB_HEADER_BYTES)
enum xfb_kind { XFB_LOGICAL = 1, XFB_JFR, XFB_THREAD_DUMP, XFB_THREAD_PRINT, XFB_COROUTINES, XFB_JITDUMP, XFB_PERFMAP };
enum xfb_status { XFB_OK, XFB_MEMORY, XFB_LIMIT, XFB_FORMAT, XFB_VERSION, XFB_CHECKSUM, XFB_CANCELLED, XFB_IO };
/* An owning input copy. Never retains a path or follows recorded metadata. */
struct xfb_input { uint8_t *bytes; size_t size; enum xlf_stability stability; char sha256[65]; };
enum xfb_status xfb_read(const char *, size_t limit, const struct xlf_cancel *, struct xfb_input *);
void xfb_input_free(struct xfb_input *);
/* Views passed to encode, or views into caller-owned decoded bytes. Metadata
 * is UTF-8 JSON interpreted and bounded separately by the host schema. Views
 * cannot outlive their byte owner; consumers copy fields into owned results. */
struct xfb_source {
    uint32_t kind, stability;
    const uint8_t *metadata, *bytes;
    size_t metadata_size, size;
    char sha256[65];
};
struct xfb_view { struct xfb_source sources[XFB_MAX_SOURCES]; size_t count, input_bytes; };
/* Encoded bytes belong to caller (free). Decode allocates no storage. Both
 * count raw source bytes against one shared input limit before copying. */
enum xfb_status xfb_encode(const struct xfb_view *, const struct xlf_cancel *, uint8_t **, size_t *);
enum xfb_status xfb_decode(const uint8_t *, size_t, const struct xlf_cancel *, struct xfb_view *);
const char *xfb_status_name(enum xfb_status);
#endif
