#define _GNU_SOURCE 1
#include "metadata_job.h"
#include "../binary/object_cache.h"
#include "../binary/cache_pool.h"
#include "../binary/placement.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>

enum job_kind { JOB_DWARF, JOB_JAVASCRIPT, JOB_CFI };
struct xmd_job {
    pthread_t thread;
    pthread_mutex_t mutex;
    uint32_t cancel;
    int joined, cache_fd, managed, index_rebuilt;
    enum job_kind kind;
    uint64_t cache_limit, validate_after;
    struct xrt_file_view *view;
    struct xbo_object *object;
    struct xbc_cache *cache;
    struct xcp_entry *entry;
    struct xdi_index *index;
    struct xdi_query *query;
    struct xdn_query *accelerator;
    const char *names[64];
    size_t name_count, name_next, unit_count;
    uint64_t units[16384];
    unsigned lookup_stage;
    struct xjs_ranged *scan;
    struct xjs_image *image;
    struct xcf_image *unwind;
    struct xjs_image_verifier *verifier;
    uint64_t verify_bias, verify_generation;
    unsigned verify_stage;
    struct xmd_snapshot snapshot, working;
};
static int cancelled(void *context) {
    return __atomic_load_n(&((struct xmd_job *)context)->cancel, __ATOMIC_ACQUIRE) != 0;
}
static enum xbo_status runtime_status(struct xmd_job *job, enum xrt_status status) {
    job->working.runtime_status = status;
    if (status == XRT_OK) return XBO_OK;
    if (status == XRT_FILE_CHANGED) return XBO_CHANGED;
    if (status == XRT_DISCOVERY_PENDING || status == XRT_DISCOVERY_BUDGET) return XBO_AGAIN;
    if (status == XRT_DISCOVERY_CANCELLED) return XBO_CANCELLED;
    if (status == XRT_FILE_LIMIT) return XBO_LIMIT;
    if (status == XRT_OUT_OF_MEMORY) return XBO_NOMEM;
    return XBO_IO;
}
/* The view checks the actual source around every uncached read. Cached reads
 * use this immutable identity, with real revalidation on a 250 ms cadence between slices
 * and before publication, rather than one remote RPC per cached DIE. */
static enum xbo_status source_identity(void *context, struct xbo_identity *out) {
    struct xmd_job *job = context;
    const struct xrt_file_identity *id = xrt_file_view_identity(job->view);
    if (!id || id->size <= 0 || id->mtime_ns < 0 || id->mtime_ns >= 1000000000 ||
        id->ctime_ns < 0 || id->ctime_ns >= 1000000000) return XBO_MALFORMED;
    *out = (struct xbo_identity){.device = id->device, .inode = id->inode,
        .size = (uint64_t)id->size, .mtime_sec = id->mtime_sec, .ctime_sec = id->ctime_sec,
        .mtime_nsec = (uint32_t)id->mtime_ns, .ctime_nsec = (uint32_t)id->ctime_ns};
    return XBO_OK;
}
static enum xbo_status source_read(void *context, uint64_t offset, void *out, size_t size) {
    struct xmd_job *job = context;
    if (cancelled(job)) return XBO_CANCELLED;
    enum xbo_status status = runtime_status(job, xrt_file_view_read(job->view, offset, out, size));
    if (status == XBO_OK) {
        ++job->working.source_reads;
        job->working.source_bytes += size;
    }
    return status;
}
static void publish(struct xmd_job *job) {
    if (job->object) xbo_progress(job->object, &job->working.object);
    if (job->scan) xjs_ranged_progress(job->scan, &job->working.scan);
    if (job->image) xjs_image_progress(job->image, &job->working.image);
    if (job->unwind) xcf_progress(job->unwind, &job->working.unwind);
    if (job->index) xdi_progress(job->index, &job->working.index);
    job->working.candidate_units = job->unit_count;
    if (job->cache) {
        struct xbc_progress progress;
        xbc_progress(job->cache, &progress);
        job->working.cache_bytes = progress.cache_bytes;
        job->working.cache_reads = progress.cache_reads;
    }
    pthread_mutex_lock(&job->mutex);
    job->snapshot = job->working;
    pthread_mutex_unlock(&job->mutex);
}
static void fail(struct xmd_job *job, enum xbo_status status, const char *reason) {
    job->working.status = status;
    job->working.state = status == XBO_CANCELLED ? XMD_CANCELLED : XMD_FAILED;
    job->working.reason = reason ? reason : status == XBO_CHANGED ? "DebugMetadataFileChanged" :
        status == XBO_CANCELLED ? "DebugMetadataCancelled" : status == XBO_LIMIT ? "DebugMetadataLimit" :
        status == XBO_NOMEM ? "DebugMetadataOutOfMemory" : "DebugMetadataUnavailable";
    memset(&job->working.profile, 0, sizeof job->working.profile);
    publish(job);
}
static struct xbo_budget budget(struct xmd_job *job) {
    return (struct xbo_budget){.bytes_left = 262144, .reads_left = 64,
        .deadline_ns = xbo_now_ns() + UINT64_C(15000000), .context = job, .cancelled = cancelled};
}
static int retry(struct xmd_job *job, enum xbo_status status) {
    if (status != XBO_AGAIN) return 0;
    publish(job);
    /* Avoid a busy loop while foreground RPCs own the connection. */
    if (job->working.runtime_status == XRT_DISCOVERY_PENDING) {
        struct timespec pause = {.tv_nsec = 1000000};
        nanosleep(&pause, NULL);
    }
    return 1;
}
static enum xbo_status index_start(struct xmd_job *job) {
    job->name_count = xjs_ranged_names(job->names, sizeof job->names / sizeof *job->names);
    if (job->name_count > sizeof job->names / sizeof *job->names) return XBO_LIMIT;
    int fd = xcp_index_fd(job->entry);
    enum xbo_status status = xdi_open_names(job->object, fd, xcp_index_limit(job->entry),
        job->names, job->name_count, &job->index);
    /* The pool lease proves no other managed builder uses this slot. A crash
     * leaves an incomplete index; preserve range data and rebuild only names. */
    if (status == XBO_AGAIN || status == XBO_MALFORMED || status == XBO_CHANGED) {
        if (flock(fd, LOCK_EX | LOCK_NB)) return XBO_IO;
        if (ftruncate(fd, 0)) return XBO_IO;
        status = xdi_open_names(job->object, fd, xcp_index_limit(job->entry),
            job->names, job->name_count, &job->index);
    }
    return status;
}
static enum xbo_status index_rebuild(struct xmd_job *job) {
    xdi_query_destroy(job->query); job->query = NULL;
    xdn_destroy(job->accelerator); job->accelerator = NULL;
    xdi_destroy(job->index); job->index = NULL;
    job->unit_count = job->name_next = 0;
    job->lookup_stage = 1;
    job->working.accelerator_hits = 0;
    int fd = xcp_index_fd(job->entry);
    if (flock(fd, LOCK_EX | LOCK_NB) || ftruncate(fd, 0)) return XBO_IO;
    enum xbo_status status = index_start(job);
    if (status == XBO_OK) job->working.state = XMD_INDEXING;
    return status;
}
static enum xbo_status candidate(struct xmd_job *job, uint64_t unit) {
    for (size_t n = 0; n < job->unit_count; ++n) if (job->units[n] == unit) return XBO_OK;
    if (job->unit_count == sizeof job->units / sizeof *job->units) return XBO_LIMIT;
    job->units[job->unit_count++] = unit;
    return XBO_OK;
}
static int unit_order(const void *left, const void *right) {
    uint64_t a = *(const uint64_t *)left, b = *(const uint64_t *)right;
    return a < b ? -1 : a > b;
}
/* Accelerators are hints. A complete projected fallback index supplies the
 * coverage proof, including static members omitted by producer indexes. */
static enum xbo_status lookup(struct xmd_job *job, struct xbo_budget *slice) {
    if (job->lookup_stage == 1) {
        enum xbo_status status = xdi_build(job->index, slice, 4096);
        if (status != XBO_OK) return status;
        job->lookup_stage = 2; job->name_next = 0;
        job->working.state = XMD_LOOKUP;
        return XBO_AGAIN;
    }
    if (job->name_next == job->name_count) {
        if (!job->lookup_stage) {
            job->lookup_stage = 1; job->working.state = XMD_INDEXING;
            return XBO_AGAIN;
        }
        qsort(job->units, job->unit_count, sizeof *job->units, unit_order);
        return xjs_ranged_create_units(job->object, job->units, job->unit_count, &job->scan);
    }
    enum xbo_status status;
    struct xdn_hit hit;
    if (!job->lookup_stage) {
        if (!job->accelerator) {
            status = xdn_create(job->object, job->names[job->name_next], &job->accelerator);
            if (status == XBO_NOT_FOUND) { job->name_next = job->name_count; return XBO_AGAIN; }
            if (status != XBO_OK) return status;
        }
        status = xdn_next(job->accelerator, slice, 4096, &hit);
        if (status == XBO_NOT_FOUND) {
            xdn_destroy(job->accelerator); job->accelerator = NULL;
            ++job->name_next; return XBO_AGAIN;
        }
        if (status == XBO_OK) ++job->working.accelerator_hits;
    } else {
        if (!job->query) {
            status = xdi_query(job->index, job->names[job->name_next], &job->query);
            if (status != XBO_OK) return status;
        }
        status = xdi_next(job->query, slice, 4096, &hit);
        if (status == XBO_NOT_FOUND) {
            xdi_query_destroy(job->query); job->query = NULL;
            ++job->name_next; return XBO_AGAIN;
        }
    }
    if (status == XBO_OK) {
        status = candidate(job, hit.unit);
        if (status == XBO_OK) return XBO_AGAIN;
    }
    return status;
}
static void *worker(void *context) {
    struct xmd_job *job = context;
    xrt_file_view_background(job->view);
    struct xbo_source source = {job, source_identity, source_read};
    enum xbo_status status = xbo_create(&source, &job->object);
    if (status != XBO_OK) { fail(job, status, NULL); return NULL; }
    int cached = job->cache_fd < 0 && !job->managed;
    for (;;) {
        if (cancelled(job)) { fail(job, XBO_CANCELLED, NULL); return NULL; }
        ++job->working.slices;
        /* CPU/cache budget slices can last microseconds. Revalidating each
         * one would add hundreds of thousands of remote round trips. Actual
         * source reads still validate themselves; cached work gets a bounded
         * revalidation cadence and an unconditional check before publishing. */
        if (xbo_now_ns() >= job->validate_after) {
            status = runtime_status(job, xrt_file_view_validate(job->view));
            if (retry(job, status)) continue;
            if (status != XBO_OK) { fail(job, status, NULL); return NULL; }
            job->validate_after = xbo_now_ns() + UINT64_C(250000000);
        }
        struct xbo_budget slice = budget(job);
        if (job->working.state == XMD_PREPARING) {
            status = xbo_prepare(job->object, &slice);
            if (retry(job, status)) continue;
            if (status != XBO_OK) { fail(job, status, NULL); return NULL; }
            if (!cached) {
                cached = 1;
                size_t size = 0;
                const unsigned char *id = xbo_build_id(job->object, &size);
                if (job->managed) {
                    uint32_t section;
                    int remote = xrt_file_view_remote(job->view);
                    /* Local stripped images need no disk cache. Debug images
                     * retain only the name index; local reads use the source fd. */
                    if (size && (remote || xbo_find_section(job->object, ".debug_info", &section) == XBO_OK)) {
                        int dir = xcp_directory();
                        if (dir >= 0) {
                            (void)xcp_acquire(dir, xbo_identity(job->object), id, size, &job->entry);
                            close(dir);
                        }
                    }
                    if (job->entry && remote) {
                        job->cache_fd = fcntl(xcp_range_fd(job->entry), F_DUPFD_CLOEXEC, 3);
                        job->cache_limit = xcp_range_limit(job->entry);
                    }
                    /* Cache availability never determines whether an image is
                     * inspectable. Without a lease, the bounded direct scan works. */
                }
                if (job->cache_fd >= 0) {
                    if (!size) { fail(job, XBO_NOT_FOUND, "DebugMetadataBuildIdUnavailable"); return NULL; }
                    status = xbc_create(&source, xbo_identity(job->object), id, size,
                        job->cache_fd, job->cache_limit, &job->cache);
                    if (job->entry && (status == XBO_MALFORMED || status == XBO_CHANGED)) {
                        status = xcp_reset(job->entry);
                        if (status == XBO_OK) status = xbc_create(&source, xbo_identity(job->object), id, size,
                            job->cache_fd, job->cache_limit, &job->cache);
                    }
                    if (status != XBO_OK) {
                        if (!job->managed) {
                            fail(job, status == XBO_AGAIN ? XBO_IO : status,
                                status == XBO_AGAIN ? "DebugMetadataCacheBusy" : "DebugMetadataCacheUnavailable"); return NULL;
                        }
                        close(job->cache_fd); job->cache_fd = -1;
                        xcp_release(job->entry); job->entry = NULL;
                    } else {
                        xbo_destroy(job->object); job->object = NULL;
                        struct xbo_source cached_source = xbc_source(job->cache);
                        status = xbo_create(&cached_source, &job->object);
                        if (status != XBO_OK) { fail(job, status, NULL); return NULL; }
                        continue;
                    }
                }
            }
            job->working.identity = *xbo_identity(job->object);
            const unsigned char *id = xbo_build_id(job->object, &job->working.build_id_size);
            if (job->working.build_id_size > sizeof job->working.build_id) {
                fail(job, XBO_LIMIT, "DebugMetadataBuildIdLimit"); return NULL;
            }
            if (job->working.build_id_size) memcpy(job->working.build_id, id, job->working.build_id_size);
            job->working.machine = xbo_machine(job->object);
            job->working.address_size = xbo_address_size(job->object);
            job->working.little_endian = xbo_little_endian(job->object);
            if (job->kind == JOB_CFI) {
                status = xcf_create(job->object, &job->unwind);
                if (status != XBO_OK) { fail(job, status, status == XBO_NOT_FOUND ? "DebugUnwindUnavailable" : status == XBO_LIMIT ? "DebugUnwindLimit" : "DebugUnwindMalformed"); return NULL; }
                job->working.state = XMD_UNWIND;
            } else if (job->kind == JOB_JAVASCRIPT) {
                status = xjs_image_create(job->object, &job->image);
                if (status != XBO_OK) { fail(job, status, "JavaScriptImageUnsupported"); return NULL; }
                job->working.state = XMD_SYMBOLS;
            } else {
                status = xjs_ranged_create(job->object, &job->scan);
                if (status != XBO_OK) { fail(job, status, NULL); return NULL; }
                job->working.state = XMD_CHECKING;
            }
            publish(job);
            continue;
        }
        if (job->working.state == XMD_SYMBOLS) {
            status = xjs_image_step(job->image, &slice, 4096);
            if (retry(job, status)) continue;
            if (status != XBO_OK) { fail(job, status, xjs_image_error(job->image)); return NULL; }
            uint32_t section;
            if (job->entry && xbo_find_section(job->object, ".debug_info", &section) == XBO_OK) {
                status = index_start(job);
                if (status != XBO_OK) { fail(job, status == XBO_AGAIN ? XBO_IO : status, "DebugMetadataIndexUnavailable"); return NULL; }
                job->working.state = XMD_LOOKUP;
                publish(job); continue;
            }
            status = xjs_ranged_create(job->object, &job->scan);
            if (status != XBO_OK) { fail(job, status, NULL); return NULL; }
            job->working.state = XMD_CHECKING;
            publish(job);
            continue;
        }
        if (job->working.state == XMD_INDEXING || job->working.state == XMD_LOOKUP) {
            status = lookup(job, &slice);
            if (retry(job, status)) continue;
            if (status == XBO_MALFORMED && job->lookup_stage == 2 && !job->index_rebuilt) {
                job->index_rebuilt = 1;
                status = index_rebuild(job);
                if (status == XBO_OK) { publish(job); continue; }
            }
            if (status != XBO_OK) {
                fail(job, status, status == XBO_LIMIT ? "DebugMetadataIndexLimit" :
                    status == XBO_CHANGED ? "DebugMetadataFileChanged" :
                    status == XBO_CANCELLED ? NULL : "DebugMetadataIndexMalformed"); return NULL;
            }
            job->working.state = XMD_CHECKING;
            publish(job); continue;
        }
        status = job->kind == JOB_CFI ? xcf_step(job->unwind, &slice) :
                                      xjs_ranged_step(job->scan, &slice, 4096);
        if (retry(job, status)) continue;
        if (status != XBO_OK) {
            const char *reason = NULL;
            if (job->scan) {
                struct xjs_dwarf_profile result;
                (void)xjs_ranged_result(job->scan, &result);
                reason = status == XBO_CANCELLED ? NULL : result.error;
            }
            fail(job, status, reason); return NULL;
        }
        status = runtime_status(job, xrt_file_view_validate(job->view));
        if (retry(job, status)) continue;
        if (status != XBO_OK) { fail(job, status, NULL); return NULL; }
        if (cancelled(job)) { fail(job, XBO_CANCELLED, NULL); return NULL; }
        if (job->scan) {
            status = xjs_ranged_result(job->scan, &job->working.profile);
            if (status != XBO_OK) { fail(job, status, NULL); return NULL; }
        }
        job->working.state = XMD_READY;
        job->working.status = XBO_OK;
        publish(job);
        return NULL;
    }
}
static enum xbo_status start(struct xrt_file_view *view, int cache_fd,
                                    uint64_t cache_limit, enum job_kind kind, int managed, int immediate, struct xmd_job **out) {
    if (!view || !out || (cache_fd >= 0 && !cache_limit)) return XBO_MALFORMED;
    *out = NULL;
    struct xmd_job *job = calloc(1, sizeof *job);
    if (!job) return XBO_NOMEM;
    job->cache_fd = -1;
    if (cache_fd >= 0) {
        job->cache_fd = fcntl(cache_fd, F_DUPFD_CLOEXEC, 3);
        if (job->cache_fd < 0) { free(job); return XBO_IO; }
    }
    job->view = view;
    job->kind = kind;
    job->managed = managed;
    job->cache_limit = cache_limit;
    job->snapshot.state = job->working.state = XMD_PREPARING;
    job->snapshot.status = job->working.status = XBO_AGAIN;
    int error = pthread_mutex_init(&job->mutex, NULL);
    if (error) { if (job->cache_fd >= 0) close(job->cache_fd); free(job); return XBO_NOMEM; }
    if (immediate) {
        job->joined = 1;
        worker(job);
        *out = job;
        return XBO_OK;
    }
    pthread_attr_t attr;
    error = pthread_attr_init(&attr);
    if (!error) {
        error = pthread_attr_setstacksize(&attr, 1024 * 1024);
        if (!error) error = pthread_create(&job->thread, &attr, worker, job);
        pthread_attr_destroy(&attr);
    }
    if (error) {
        pthread_mutex_destroy(&job->mutex);
        if (job->cache_fd >= 0) close(job->cache_fd);
        free(job); return XBO_NOMEM;
    }
    *out = job; return XBO_OK;
}
enum xbo_status xmd_start_javascript(struct xrt_file_view *view, int cache_fd,
                                    uint64_t cache_limit, struct xmd_job **out) {
    return start(view, cache_fd, cache_limit, JOB_JAVASCRIPT, 0, 0, out);
}
enum xbo_status xmd_start_javascript_cached(struct xrt_file_view *view, struct xmd_job **out) {
    return start(view, -1, 0, JOB_JAVASCRIPT, 1, 0, out);
}
enum xbo_status xmd_start_javascript_dwarf(struct xrt_file_view *view, int cache_fd,
                                          uint64_t cache_limit, struct xmd_job **out) {
    return start(view, cache_fd, cache_limit, JOB_DWARF, 0, 0, out);
}
enum xbo_status xmd_start_cfi(struct xrt_file_view *view, struct xmd_job **out) {
    return start(view, -1, 0, JOB_CFI, 0, 0, out);
}
enum xbo_status xmd_start_cfi_local(struct xrt_file_view *view, struct xmd_job **out) {
    if (!view || !out) return XBO_MALFORMED;
    *out = NULL;
    const struct xrt_file_identity *identity = xrt_file_view_identity(view);
    if (!identity || identity->size <= 0) return XBO_MALFORMED;
    if (xrt_file_view_remote(view) || (uint64_t)identity->size > XMD_LOCAL_CFI_LIMIT) return XBO_LIMIT;
    return start(view, -1, 0, JOB_CFI, 0, 1, out);
}
enum xbo_status xmd_cfi_result(struct xmd_job *job, unsigned char **out, size_t *size) {
    if (!out || !size) return XBO_MALFORMED;
    *out = NULL; *size = 0;
    if (!job || job->kind != JOB_CFI) return XBO_MALFORMED;
    enum xbo_status status = xmd_join(job);
    if (status == XBO_OK) status = xmd_validate(job);
    if (status != XBO_OK) return status;
    return xcf_result(job->unwind, out, size);
}
void xmd_poll(struct xmd_job *job, struct xmd_snapshot *out) {
    pthread_mutex_lock(&job->mutex);
    *out = job->snapshot;
    pthread_mutex_unlock(&job->mutex);
    /* Cancellation also withdraws an already completed result. Do not mutate
     * worker storage here: poll/cancel may run before its final publication. */
    if (cancelled(job) && out->state != XMD_FAILED) {
        out->state = XMD_CANCELLED;
        out->status = XBO_CANCELLED;
        out->reason = "DebugMetadataCancelled";
        memset(&out->profile, 0, sizeof out->profile);
    }
}
void xmd_cancel(struct xmd_job *job) {
    if (job) __atomic_store_n(&job->cancel, 1, __ATOMIC_RELEASE);
}
enum xbo_status xmd_join(struct xmd_job *job) {
    if (!job) return XBO_MALFORMED;
    if (!job->joined) {
        int error = pthread_tryjoin_np(job->thread, NULL);
        if (error == EBUSY) return XBO_AGAIN;
        if (error) return XBO_IO;
        job->joined = 1;
    }
    return XBO_OK;
}
enum xbo_status xmd_validate(struct xmd_job *job) {
    if (!job || !job->joined) return XBO_AGAIN;
    if (job->working.state != XMD_READY) return job->working.status;
    if (cancelled(job)) { fail(job, XBO_CANCELLED, NULL); return XBO_CANCELLED; }
    enum xbo_status status = runtime_status(job, xrt_file_view_validate(job->view));
    if (status != XBO_OK && status != XBO_AGAIN) fail(job, status, NULL);
    return status;
}
enum xbo_status xmd_mapping_bias(struct xmd_job *job, uint64_t start, uint64_t end,
        uint64_t offset, uint64_t page, unsigned permissions, uint64_t *bias) {
    if (!bias) return XBO_MALFORMED;
    *bias = 0;
    if (!job || !job->joined) return XBO_AGAIN;
    if (job->working.state != XMD_READY) return job->working.status;
    return xbo_mapping_bias(job->object, start, end, offset, page, permissions, bias);
}
enum xbo_status xmd_verify_javascript(struct xmd_job *job, uint64_t bias, uint64_t generation,
        struct xjs_reader *reader, struct xjs_layout *out, const char **reason) {
    if (!out || !reason) return XBO_MALFORMED;
    memset(out, 0, sizeof *out); *reason = "JavaScriptMetadataPending";
    if (!job || job->kind != JOB_JAVASCRIPT || !reader) { *reason = "JavaScriptMetadataUnavailable"; return XBO_MALFORMED; }
    enum xbo_status status = xmd_join(job);
    if (status != XBO_OK) return status;
    if (job->working.state != XMD_READY) { *reason = job->working.reason; return job->working.status; }
    if (cancelled(job)) { fail(job, XBO_CANCELLED, NULL); *reason = job->working.reason; return XBO_CANCELLED; }
    if (job->verifier && (bias != job->verify_bias || generation != job->verify_generation)) {
        xjs_image_verifier_destroy(job->verifier); job->verifier = NULL;
    }
    if (!job->verifier) {
        status = xjs_image_verifier_create(job->image, bias, &job->verifier);
        if (status != XBO_OK) { *reason = "JavaScriptMetadataUnavailable"; return status; }
        job->verify_bias = bias; job->verify_generation = generation; job->verify_stage = 0;
    }
    if (!job->verify_stage || job->verify_stage >= 2) {
        status = xmd_validate(job);
        if (status != XBO_OK) { if (status != XBO_AGAIN) *reason = job->working.reason; return status; }
        if (!job->verify_stage) { job->verify_stage = 1; return XBO_AGAIN; }
        job->verify_stage = 3;
    } else {
        struct xbo_budget slice = budget(job);
        status = xjs_image_verifier_step(job->verifier, reader, &slice, 1);
        if (status == XBO_AGAIN) return status;
        if (status == XBO_CANCELLED) { *reason = "JavaScriptMetadataCancelled"; return status; }
        if (status != XBO_OK) {
            (void)xjs_image_verifier_result(job->verifier, out, reason);
            if (status == XBO_CHANGED) fail(job, status, *reason);
            return status;
        }
        job->verify_stage = 2;
        return XBO_AGAIN;
    }
    status = xjs_image_verifier_result(job->verifier, out, reason);
    if (status != XBO_OK) return status;
    out->dwarf_fields = job->working.profile.fields;
    out->dwarf_frame_config = job->working.profile.frame_config;
    return XBO_OK;
}
void xmd_destroy(struct xmd_job *job) {
    if (!job) return;
    xmd_cancel(job);
    if (!job->joined) pthread_join(job->thread, NULL);
    xjs_image_verifier_destroy(job->verifier);
    xjs_image_destroy(job->image);
    xcf_destroy(job->unwind);
    xjs_ranged_destroy(job->scan);
    xdn_destroy(job->accelerator);
    xdi_query_destroy(job->query);
    xdi_destroy(job->index);
    xbo_destroy(job->object);
    xbc_destroy(job->cache);
    if (job->cache_fd >= 0) close(job->cache_fd);
    xcp_release(job->entry);
    (void)xrt_file_view_close(job->view);
    pthread_mutex_destroy(&job->mutex);
    free(job);
}
