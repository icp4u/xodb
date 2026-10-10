#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "xrt_files.h"
#include "elf_symbols.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

struct xrt_symbol_job {
    pthread_t thread;
    pthread_mutex_t mutex;
    struct xrt_file_view *view;
    int fd, joined;
    unsigned cancel;
    uint64_t bytes;
    enum xrt_status status;
};
struct local_symbols { struct xrt_file_view *view; uint64_t bytes; };
static enum xrt_status read_local_symbols(void *context, uint64_t offset, void *out, size_t size)
{
    struct local_symbols *local = context;
    enum xrt_status status = xrt_file_view_read(local->view, offset, out, size);
    if (status == XRT_OK) local->bytes += size;
    return status;
}
enum xrt_status xrt_local_symbol_file(struct xrt_file_view *view, int *out, uint64_t *resident)
{
    if (!view || !out || !resident) return XRT_INVALID_ARGUMENT;
    *out = -1;
    *resident = 0;
    const struct xrt_file_identity *id = xrt_file_view_identity(view);
    if (!id || id->size <= 0) return XRT_INVALID_ARGUMENT;
    if (xrt_file_view_remote(view) || id->size > INT64_C(256) * 1024 * 1024)
        return XRT_UNSUPPORTED_MODE;
    int fd = memfd_create("xodb-symbols", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) return XRT_FILE_UNAVAILABLE;
    struct local_symbols local = {.view = view};
    enum xrt_status status = ftruncate(fd, id->size) ? XRT_FILE_UNAVAILABLE :
        xrt_elf_symbols(read_local_symbols, &local, fd, (uint64_t)id->size);
    if (status == XRT_OK) status = xrt_file_view_validate(view);
    if (status == XRT_OK && fcntl(fd, F_ADD_SEALS,
            F_SEAL_SEAL | F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE) < 0)
        status = XRT_FILE_UNAVAILABLE;
    if (status != XRT_OK) { close(fd); return status; }
    *out = fd;
    *resident = local.bytes;
    return XRT_OK;
}
static enum xrt_status read_symbols(void *context, uint64_t offset, void *out, size_t size)
{
    struct xrt_symbol_job *job = context;
    if (__atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) return XRT_DISCOVERY_CANCELLED;
    enum xrt_status status = xrt_file_view_read(job->view, offset, out, size);
    if (status == XRT_OK) {
        pthread_mutex_lock(&job->mutex);
        job->bytes += size;
        pthread_mutex_unlock(&job->mutex);
    }
    return status;
}
static void *worker(void *context)
{
    struct xrt_symbol_job *job = context;
    const struct xrt_file_identity *id = xrt_file_view_identity(job->view);
    enum xrt_status status = xrt_elf_symbols(read_symbols, job, job->fd, (uint64_t)id->size);
    if (status == XRT_OK) status = xrt_file_view_validate(job->view);
    if (status == XRT_OK && fcntl(job->fd, F_ADD_SEALS,
            F_SEAL_SEAL | F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE) < 0)
        status = XRT_FILE_UNAVAILABLE;
    pthread_mutex_lock(&job->mutex);
    job->status = status;
    pthread_mutex_unlock(&job->mutex);
    return NULL;
}
enum xrt_status xrt_symbol_job_start(struct xrt_file_view *view, struct xrt_symbol_job **out)
{
    if (!view || !out) return XRT_INVALID_ARGUMENT;
    *out = NULL;
    const struct xrt_file_identity *id = xrt_file_view_identity(view);
    if (!id || id->size <= 0) return XRT_INVALID_ARGUMENT;
    struct xrt_symbol_job *job = calloc(1, sizeof *job);
    if (!job) return XRT_OUT_OF_MEMORY;
    job->fd = memfd_create("xodb-symbols", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (job->fd < 0 || ftruncate(job->fd, id->size)) {
        if (job->fd >= 0) close(job->fd);
        free(job); return XRT_FILE_UNAVAILABLE;
    }
    if (pthread_mutex_init(&job->mutex, NULL)) {
        close(job->fd); free(job); return XRT_OUT_OF_MEMORY;
    }
    job->view = view;
    job->status = XRT_DISCOVERY_PENDING;
    if (pthread_create(&job->thread, NULL, worker, job)) {
        pthread_mutex_destroy(&job->mutex); close(job->fd); free(job);
        return XRT_OUT_OF_MEMORY;
    }
    *out = job;
    return XRT_OK;
}
void xrt_symbol_job_cancel(struct xrt_symbol_job *job)
{
    if (job) __atomic_store_n(&job->cancel, 1, __ATOMIC_RELEASE);
}
enum xrt_status xrt_symbol_job_poll(struct xrt_symbol_job *job, int *out, uint64_t *resident)
{
    if (!job || !out || !resident) return XRT_INVALID_ARGUMENT;
    *out = -1;
    pthread_mutex_lock(&job->mutex);
    *resident = job->bytes;
    enum xrt_status status = job->status;
    pthread_mutex_unlock(&job->mutex);
    if (__atomic_load_n(&job->cancel, __ATOMIC_ACQUIRE)) return XRT_DISCOVERY_CANCELLED;
    if (status == XRT_DISCOVERY_PENDING) return status;
    if (!job->joined) {
        int error = pthread_tryjoin_np(job->thread, NULL);
        if (error == EBUSY) return XRT_DISCOVERY_PENDING;
        if (error) return XRT_FILE_UNAVAILABLE;
        job->joined = 1;
    }
    if (status == XRT_OK) {
        if (job->fd < 0) return XRT_INVALID_STATE;
        /* Refuse a changed original even after the worker finished. */
        status = xrt_file_view_validate(job->view);
        if (status == XRT_OK) { *out = job->fd; job->fd = -1; }
    }
    return status;
}
void xrt_symbol_job_destroy(struct xrt_symbol_job *job)
{
    if (!job) return;
    xrt_symbol_job_cancel(job);
    if (!job->joined) pthread_join(job->thread, NULL);
    if (job->fd >= 0) close(job->fd);
    (void)xrt_file_view_close(job->view);
    pthread_mutex_destroy(&job->mutex);
    free(job);
}
