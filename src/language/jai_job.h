#ifndef XODB_JAI_JOB_H
#define XODB_JAI_JOB_H
#include "jai.h"
struct xjai_job;
enum xjai_job_state { XJAI_JOB_PENDING, XJAI_JOB_READY, XJAI_JOB_FAILED };
struct xjai_job_snapshot { enum xjai_job_state state;const char *reason;const struct xjai_graph *graph; };
/* Copies immutable input before returning. No target/file IO in the worker.
 * At most2 workers,64MiB copied input and64MiB retained graphs process-wide.
 * The owner serializes poll/release. A polled graph is borrowed until release.
 * Releasing a pending job abandons publication without waiting for its worker;
 * that worker finishes its bounded parse and frees its own resources. */
const char *xjai_job_start(const struct xjai_image *,struct xjai_job **);
void xjai_job_poll(struct xjai_job *,struct xjai_job_snapshot *);
void xjai_job_release(struct xjai_job *);
struct xjai_job_usage { unsigned active;uint64_t input_bytes,result_bytes; };
void xjai_job_usage(struct xjai_job_usage *);
#endif
