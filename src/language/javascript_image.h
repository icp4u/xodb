#ifndef XODB_JAVASCRIPT_IMAGE_H
#define XODB_JAVASCRIPT_IMAGE_H
#include "javascript.h"
#include "../binary/symbol_query.h"

/* File-side metadata only. A prepared object is borrowed for this lifetime;
 * the result does not prove a runtime mapping or a stopped target. */
struct xjs_image;
struct xjs_image_progress { struct xbs_progress symbols; size_t constants; int complete; };
enum xbo_status xjs_image_create(struct xbo_object *, struct xjs_image **);
void xjs_image_destroy(struct xjs_image *);
enum xbo_status xjs_image_step(struct xjs_image *, struct xbo_budget *, uint64_t work);
void xjs_image_progress(const struct xjs_image *, struct xjs_image_progress *);
const char *xjs_image_error(const struct xjs_image *);
/* Owner thread, after file work has joined. Caller proves the load bias and
 * stopped generation, validates the pinned file around this call, and supplies
 * the completed DWARF cross-check separately. Loaded constants/build-id/version
 * are compared with file bytes. No result is exposed on a partial read. */
struct xjs_image_verifier;
enum xbo_status xjs_image_verifier_create(struct xjs_image *, uint64_t bias, struct xjs_image_verifier **);
void xjs_image_verifier_destroy(struct xjs_image_verifier *);
/* Each work unit performs at most one loaded-memory read. File progress also
 * survives AGAIN; the caller must discard this verifier if generation changes. */
enum xbo_status xjs_image_verifier_step(struct xjs_image_verifier *, struct xjs_reader *,
                                        struct xbo_budget *, uint64_t work);
enum xbo_status xjs_image_verifier_result(const struct xjs_image_verifier *, struct xjs_layout *, const char **reason);
#endif
