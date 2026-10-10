#define _GNU_SOURCE 1
#include "pe_job.h"
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <time.h>

struct xpe_job {
    pthread_t thread;
    pthread_mutex_t mutex;
    struct xrt_file_view *view;
    struct xpe_image *image;
    struct xpe_job_snapshot snapshot;
    unsigned cancel;
    int joined;
    uint64_t deadline;
};
static uint64_t now(void) {
    struct timespec stamp;
    if (clock_gettime(CLOCK_MONOTONIC, &stamp)) return UINT64_MAX;
    return (uint64_t)stamp.tv_sec * UINT64_C(1000000000) + (uint64_t)stamp.tv_nsec;
}
static enum xpe_status converted(enum xrt_status status) {
    if (status == XRT_OK) return XPE_OK;
    if (status == XRT_FILE_CHANGED) return XPE_CHANGED;
    if (status == XRT_DISCOVERY_CANCELLED) return XPE_CANCELLED;
    if (status == XRT_FILE_LIMIT || status == XRT_DISCOVERY_BUDGET) return XPE_LIMIT;
    if (status == XRT_OUT_OF_MEMORY) return XPE_NOMEM;
    return XPE_IO;
}
static enum xpe_status operation(struct xpe_job *job, uint64_t at, void *out, size_t size, int validate) {
    for (;;) {
        if (__atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) return XPE_CANCELLED;
        if (now() >= job->deadline) return XPE_LIMIT;
        enum xrt_status runtime = validate ? xrt_file_view_validate(job->view) : xrt_file_view_read(job->view, at, out, size);
        pthread_mutex_lock(&job->mutex);
        job->snapshot.runtime_status = runtime;
        if (runtime == XRT_OK && !validate) {
            ++job->snapshot.source_reads;
            job->snapshot.source_bytes += size;
        }
        pthread_mutex_unlock(&job->mutex);
        if (runtime != XRT_DISCOVERY_PENDING) return converted(runtime);
        /* Foreground RPCs get priority. Retry on the worker only. */
        const struct timespec pause = {.tv_nsec = 1000000};
        nanosleep(&pause, NULL);
    }
}
static enum xpe_status read_source(void *context, uint64_t at, void *out, size_t size) {
    struct xpe_job *job = context;
    if (!job->joined) return operation(job, at, out, size, 0);
    if (__atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) return XPE_CANCELLED;
    if (job->snapshot.state != XPE_JOB_READY) return job->snapshot.status;
    /* Later unwind reads belong to the owner. Never spin behind a foreground
     * RPC, and never apply the construction deadline to cached metadata. */
    enum xrt_status runtime = xrt_file_view_read(job->view, at, out, size);
    enum xpe_status status = converted(runtime);
    if (status != XPE_OK && runtime != XRT_DISCOVERY_PENDING) {
        pthread_mutex_lock(&job->mutex);
        job->snapshot.state = XPE_JOB_FAILED;
        job->snapshot.status = status;
        job->snapshot.runtime_status = runtime;
        pthread_mutex_unlock(&job->mutex);
    }
    return status;
}
static void *worker(void *context) {
    struct xpe_job *job = context;
    const struct xrt_file_identity *identity = xrt_file_view_identity(job->view);
    const struct xpe_source source = {job, (uint64_t)identity->size, XPE_FILE, read_source};
    enum xpe_status status = xpe_load(&source, &job->image);
    if (status == XPE_OK) status = operation(job, 0, NULL, 0, 1);
    if (__atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) status = XPE_CANCELLED;
    pthread_mutex_lock(&job->mutex);
    job->snapshot.status = status;
    job->snapshot.state = status == XPE_OK ? XPE_JOB_READY : XPE_JOB_FAILED;
    pthread_mutex_unlock(&job->mutex);
    return NULL;
}
enum xpe_status xpe_job_start(struct xrt_file_view *view, struct xpe_job **out) {
    if (!out) return XPE_MALFORMED;
    *out = NULL;
    const struct xrt_file_identity *identity = xrt_file_view_identity(view);
    if (!view || !identity || identity->size <= 0) return XPE_MALFORMED;
    struct xpe_job *job = calloc(1, sizeof *job);
    if (!job) return XPE_NOMEM;
    if (pthread_mutex_init(&job->mutex, NULL)) { free(job); return XPE_NOMEM; }
    job->view = view;
    job->snapshot.state = XPE_JOB_PENDING;
    uint64_t start = now();
    if (start > UINT64_MAX-UINT64_C(30000000000)) {
        pthread_mutex_destroy(&job->mutex); free(job); return XPE_IO;
    }
    job->deadline = start + UINT64_C(30000000000);
    xrt_file_view_background(view);
    if (pthread_create(&job->thread, NULL, worker, job)) {
        pthread_mutex_destroy(&job->mutex); free(job); return XPE_NOMEM;
    }
    *out = job;
    return XPE_OK;
}
void xpe_job_poll(struct xpe_job *job, struct xpe_job_snapshot *out) {
    if (!out) return;
    if (!job) { *out = (struct xpe_job_snapshot){.state=XPE_JOB_FAILED,.status=XPE_MALFORMED}; return; }
    pthread_mutex_lock(&job->mutex);
    *out = job->snapshot;
    pthread_mutex_unlock(&job->mutex);
    if (__atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) {
        out->state = XPE_JOB_FAILED;
        out->status = XPE_CANCELLED;
    }
}
void xpe_job_cancel(struct xpe_job *job) {
    if (job) __atomic_store_n(&job->cancel, 1, __ATOMIC_RELEASE);
}
int xpe_job_join(struct xpe_job *job) {
    if (!job) return -1;
    if (job->joined) return 1;
    int status = pthread_tryjoin_np(job->thread, NULL);
    if (status == EBUSY) return 0;
    if (status) return -1;
    job->joined = 1;
    return 1;
}
struct xpe_image *xpe_job_image(struct xpe_job *job) {
    if (!job || !job->joined || __atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) return NULL;
    return job->snapshot.state == XPE_JOB_READY ? job->image : NULL;
}
enum xpe_status xpe_job_validate(struct xpe_job *job) {
    if (!job || !job->joined) return XPE_MALFORMED;
    if (__atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) return XPE_CANCELLED;
    if (job->snapshot.state != XPE_JOB_READY) return job->snapshot.status;
    /* A completed image can be reused later; the parse deadline only bounds
     * construction, not its lifetime. Validation performs one bounded call. */
    enum xrt_status runtime = xrt_file_view_validate(job->view);
    if (runtime == XRT_DISCOVERY_PENDING) return XPE_IO;
    enum xpe_status status = converted(runtime);
    if (status != XPE_OK) {
        pthread_mutex_lock(&job->mutex);
        job->snapshot.state = XPE_JOB_FAILED;
        job->snapshot.status = status;
        job->snapshot.runtime_status = runtime;
        pthread_mutex_unlock(&job->mutex);
    }
    return status;
}
void xpe_job_destroy(struct xpe_job *job) {
    if (!job) return;
    xpe_job_cancel(job);
    if (!job->joined) pthread_join(job->thread, NULL);
    xpe_destroy(job->image);
    (void)xrt_file_view_close(job->view);
    pthread_mutex_destroy(&job->mutex);
    free(job);
}
