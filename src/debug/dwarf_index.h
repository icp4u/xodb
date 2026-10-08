#ifndef XODB_DWARF_INDEX_H
#define XODB_DWARF_INDEX_H
#include "dwarf_cursor.h"
#include "dwarf_names.h"

/* Persistent direct-name fallback index. Caller supplies a private regular
 * cache fd and retains the checked object for its lifetime. Incomplete files
 * are never queryable; the bounded build resumes within this instance. */
struct xdi_index;
struct xdi_query;
struct xdi_progress {
    uint64_t units,dies,info_next,info_size,records,file_bytes,memory_bytes;
    int complete;
};
enum xbo_status xdi_open(struct xbo_object *,int cache_fd,uint64_t file_limit,struct xdi_index **);
/* Optional exact-name projection reduces persistent size for language readers.
 * Up to 64 names, each <=255 bytes, with <=3000 bytes including terminators.
 * The complete ordered list is part of the cache identity; it is copied.
 * Queries outside this projection return LIMIT, never an absence claim. */
enum xbo_status xdi_open_names(struct xbo_object *, int cache_fd, uint64_t file_limit,
        const char *const *names, size_t count, struct xdi_index **);
void xdi_destroy(struct xdi_index *);
/* A file-quota refusal can resume after increasing this bound. */
enum xbo_status xdi_set_file_limit(struct xdi_index *,uint64_t);
enum xbo_status xdi_build(struct xdi_index *,struct xbo_budget *,uint64_t work);
void xdi_progress(const struct xdi_index *,struct xdi_progress *);
/* Exact direct names, not abstract-origin inheritance or C++ canonical names.
 * A complete query returns candidates requiring normal CU/type validation. */
enum xbo_status xdi_query(struct xdi_index *,const char *name,struct xdi_query **);
void xdi_query_destroy(struct xdi_query *);
enum xbo_status xdi_next(struct xdi_query *,struct xbo_budget *,uint64_t work,struct xdn_hit *);
const char *xdi_error(const struct xdi_index *);
#endif
