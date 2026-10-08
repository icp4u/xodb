#ifndef XODB_METADATA_JOB_H
#define XODB_METADATA_JOB_H
#include "../runtime/xrt_files.h"
#include "../language/javascript_ranged.h"
#include "../language/javascript_image.h"
#include "cfi_image.h"
#include "dwarf_index.h"

/* Session-owned metadata work. Open the pinned view on the target owner
 * thread. A successful start transfers it to the job; destroy joins before
 * closing it. The target must outlive the job. Poll/cancel do no target I/O. */
enum xmd_state { XMD_PREPARING, XMD_SYMBOLS, XMD_CHECKING, XMD_READY, XMD_CANCELLED, XMD_FAILED, XMD_UNWIND, XMD_INDEXING, XMD_LOOKUP };
struct xmd_snapshot {
    enum xmd_state state;
    enum xbo_status status;
    enum xrt_status runtime_status;
    struct xbo_progress object;
    struct xjs_ranged_progress scan;
    struct xjs_image_progress image;
    struct xcf_progress unwind;
    struct xdi_progress index;
    struct xjs_dwarf_profile profile; /* populated only in READY */
    struct xbo_identity identity;
    unsigned char build_id[64];
    size_t build_id_size;
    /* Successful provider reads; failed/in-flight transport bytes are unknown. */
    uint64_t slices, source_bytes, source_reads, cache_bytes, cache_reads;
    uint64_t candidate_units, accelerator_hits;
    unsigned machine, address_size, little_endian;
    const char *reason; /* static diagnostic, never borrowed parser storage */
};
struct xmd_job;
/* Optional range_cache_fd is borrowed and duplicated, or -1 for uncached.
 * The caller selects a private regular cache and grants a finite file quota.
 * Directory selection and aggregate cache reservation belong to the caller. */
enum xbo_status xmd_start_javascript(struct xrt_file_view *, int range_cache_fd,
                                    uint64_t cache_limit, struct xmd_job **);
/* Application entry point: bounded private cache pool, acquired by the worker. */
enum xbo_status xmd_start_javascript_cached(struct xrt_file_view *, struct xmd_job **);
/* Component-only DWARF scan for callers that already proved image metadata. */
enum xbo_status xmd_start_javascript_dwarf(struct xrt_file_view *, int range_cache_fd,
                                          uint64_t cache_limit, struct xmd_job **);
/* Owner thread, joined job. Caller proves bias, stopped state and generation.
 * Revalidates the pinned file before/after every loaded-image verification. */
enum xbo_status xmd_verify_javascript(struct xmd_job *, uint64_t bias, uint64_t generation,
        struct xjs_reader *, struct xjs_layout *, const char **reason);
/* Joined job; mapping identity was proved when opening the pinned view. */
enum xbo_status xmd_mapping_bias(struct xmd_job *, uint64_t start, uint64_t end,
        uint64_t offset, uint64_t page_size, unsigned write_execute, uint64_t *bias);
/* CFI-only worker. The caller owns the view until successful start. */
enum xbo_status xmd_start_cfi(struct xrt_file_view *, struct xmd_job **);
/* Joins nonblockingly and revalidates before lending the CFI-only ELF bytes.
 * Close all libelf/libdw handles borrowing these bytes before destroying job. */
enum xbo_status xmd_cfi_result(struct xmd_job *, unsigned char **, size_t *);
/* Cancelled means publication was withdrawn; join still determines whether
 * the worker has returned and its borrowed target may be released. */
void xmd_poll(struct xmd_job *, struct xmd_snapshot *);
void xmd_cancel(struct xmd_job *);
/* Nonblocking join. AGAIN means the worker has not returned yet. */
enum xbo_status xmd_join(struct xmd_job *);
/* Joined worker only. Revalidate before reusing a published profile. A failed
 * validation withdraws the profile, including when original bytes return. */
enum xbo_status xmd_validate(struct xmd_job *);
void xmd_destroy(struct xmd_job *);
#endif
