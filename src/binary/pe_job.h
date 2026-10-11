#ifndef XODB_PE_JOB_H
#define XODB_PE_JOB_H
#include "pe.h"
#include "pdb.h"
#include "../runtime/xrt_files.h"

/* A successful start transfers the pinned view. The target must outlive the
 * job. Only the worker touches the view until a successful nonblocking join.
 * Poll and cancel never perform target I/O. Parsed data remains job-owned. */
struct xpe_job;
enum xpe_job_state { XPE_JOB_PENDING, XPE_JOB_READY, XPE_JOB_FAILED };
struct xpe_job_snapshot {
    enum xpe_job_state state;
    enum xpe_status status;
    enum xrt_status runtime_status;
    uint64_t source_reads, source_bytes;
};
/* Peak allowance includes the PE parser plus a bounded PDB source and parser.
 * pid/path enable adjacent local PDB discovery; zero/null disable it. A smaller
 * allowance bounds all PE/PDB allocations and the PDB source buffer. Exhaustion
 * returns XPE_BUDGET from the joined job, without publishing partial metadata. */
#define XPE_JOB_MAX_BYTES (XPE_MAX_RETAINED_BYTES + XPDB_MAX_FILE_BYTES + XPDB_MAX_ALLOCATED_BYTES)
enum xpe_status xpe_job_start(struct xrt_file_view *, int32_t pid, const char *mapped_path,
    uint64_t allowance, struct xpe_job **);
void xpe_job_poll(struct xpe_job *, struct xpe_job_snapshot *);
void xpe_job_cancel(struct xpe_job *);
/* Returns zero while still running, one after join, minus one on join error. */
int xpe_job_join(struct xpe_job *);
/* Joined ready job only. No I/O; borrowed until destroy or cancellation. */
struct xpe_image *xpe_job_image(struct xpe_job *);
/* Joined ready job only. Revalidate the pinned PDB before returning symbols;
 * a changed or unavailable companion never invalidates PE unwind metadata. */
const struct xpdb *xpe_job_pdb(struct xpe_job *);
uint64_t xpe_job_retained_bytes(struct xpe_job *);
const char *xpe_job_pdb_status(struct xpe_job *);
/* Joined ready job only. Revalidates the pinned source before use, permanently
 * withdrawing publication on failure. May perform file/remote I/O. */
enum xpe_status xpe_job_validate(struct xpe_job *);
void xpe_job_destroy(struct xpe_job *);
#endif
