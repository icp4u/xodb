#ifndef XODB_JAVASCRIPT_RANGED_H
#define XODB_JAVASCRIPT_RANGED_H
#include "javascript_profile.h"
#include "../debug/dwarf_cursor.h"

/* One worker owns this resumable cross-check and its borrowed, prepared ELF.
 * A partial scan never publishes a layout. Cancellation preserves progress;
 * identity/parser failures are permanent. No libdw or full image mapping. */
struct xjs_ranged;
struct xjs_ranged_progress {
    struct xdw_progress dwarf;
    uint64_t observations, observed_fields;
    int complete;
};
enum xbo_status xjs_ranged_create(struct xbo_object *, struct xjs_ranged **);
/* Field-name projection for a complete direct-name fallback index. */
size_t xjs_ranged_names(const char **out, size_t capacity);
/* Copies a sorted, unique candidate CU list (max 16384). Only use after a
 * complete name-index query; accelerator exhaustion alone is insufficient.
 * Every selected CU still gets the normal namespace/owner/value checks. */
enum xbo_status xjs_ranged_create_units(struct xbo_object *, const uint64_t *units,
        size_t count, struct xjs_ranged **);
void xjs_ranged_destroy(struct xjs_ranged *);
enum xbo_status xjs_ranged_step(struct xjs_ranged *, struct xbo_budget *, uint64_t work);
/* Initializes out. AGAIN means no completed profile; failure has a reason. */
enum xbo_status xjs_ranged_result(const struct xjs_ranged *, struct xjs_dwarf_profile *);
void xjs_ranged_progress(const struct xjs_ranged *, struct xjs_ranged_progress *);
#endif
