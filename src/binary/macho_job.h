#ifndef XODB_MACHO_JOB_H
#define XODB_MACHO_JOB_H
#include "macho.h"
#include "../debug/macho_dwarf.h"
#include "../debug/macho_object.h"
#include "../debug/macho_unwind.h"

/* Local, explicitly configured inputs only. The remote image path supplies
 * only a basename, never a host path. A file's UUID and selected architecture
 * must match before any symbol can be published. All strings are copied. */
struct xmo_job_options {
    const char *executable; /* Optional user-selected file for an executable. */
    const char *basename;
    const char *const *roots;
    size_t root_count;
    unsigned char uuid[16];
    uint32_t cputype, cpusubtype;
    uint64_t allowance;
};
struct xmo_job;
enum xmo_job_state { XMO_JOB_PENDING, XMO_JOB_READY, XMO_JOB_FAILED };
enum xmo_job_failure { XMO_JOB_NONE, XMO_JOB_MISSING, XMO_JOB_UUID,
    XMO_JOB_ARCH, XMO_JOB_FILE, XMO_JOB_CHANGED, XMO_JOB_PARSE };
struct xmo_job_snapshot {
    enum xmo_job_state state;
    enum xmo_job_failure failure;
    enum xmo_status status;
    uint64_t source_reads, source_bytes, retained_bytes;
};
enum xmo_status xmo_job_start(const struct xmo_job_options *, struct xmo_job **);
void xmo_job_poll(struct xmo_job *, struct xmo_job_snapshot *);
void xmo_job_cancel(struct xmo_job *);
/* Nonblocking: 0 pending, 1 joined, -1 join error. Destroy always waits for
 * worker completion before releasing its storage, including on join error. */
int xmo_job_join(struct xmo_job *);
/* Joined only. The pinned local file is revalidated before cached lookup;
 * no table read or pathname reopen occurs. Copy the name before destruction. */
enum xmo_status xmo_job_symbol(struct xmo_job *, uint64_t link_address,
    char *name, size_t capacity, uint64_t *value, uint64_t *size);
const struct xmo_info *xmo_job_info(struct xmo_job *);
enum xmo_debug_status { XMO_DEBUG_READY, XMO_DEBUG_MISSING, XMO_DEBUG_UUID,
    XMO_DEBUG_ARCH, XMO_DEBUG_REFUSED, XMO_DEBUG_LIMIT, XMO_DEBUG_CHANGED };
/* Joined only. Containers borrow worker storage; release all libdw handles
 * before destroying the job. Every retained companion remains pinned and
 * is revalidated along with the executable before a metadata query. */
enum xmo_debug_status xmo_job_debug(struct xmo_job *, const struct xmo_dwarf **);
enum xmo_status xmo_job_unwind(struct xmo_job *, const struct xmo_dwarf **);
enum xmo_status xmo_job_compact(struct xmo_job *, uint64_t linked_pc, struct xmu_row *);
enum xmo_status xmo_job_object(struct xmo_job *, uint64_t linked_pc, uint32_t *index,
                             uint64_t *object_pc, const struct xmo_dwarf **);
enum xmo_status xmo_job_object_address(struct xmo_job *, uint32_t index,
                                     uint64_t object, uint64_t *linked);
void xmo_job_destroy(struct xmo_job *);
#endif
