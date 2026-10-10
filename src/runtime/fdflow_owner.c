#define _GNU_SOURCE 1
#include "xrt_fdflow_owner.h"
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct publication {
    struct xrt_fdflow_count_row *rows;
    struct xrt_fdflow_rate *rates;
    struct xrt_fdflow_cpu *cpus;
    uint32_t row_capacity, cpu_capacity;
};
struct xrt_fdflow_owner {
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t wake;
    atomic_int stop;
    uint64_t wanted_until, requested_generation;
    int32_t pids[128];
    uint32_t pid_count;
    struct xrt_fdflow_bindings *pending;
    struct xrt_fdflow_live view;
    struct publication current;
};
static uint64_t clock_ns(clockid_t id) {
    struct timespec t;
    return clock_gettime(id, &t) ? 0 : (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
static void release_publication(struct publication *p) {
    free(p->rows);
    free(p->rates);
    free(p->cpus);
    memset(p, 0, sizeof *p);
}
static void failure(struct xrt_perf_failure *f, int error, const char *detail) {
    *f = (struct xrt_perf_failure){.kind =
                                       error == ENOMEM ? XRT_PERF_RESOURCE :
                                       error == EACCES || error == EPERM ? XRT_PERF_PERMISSION :
                                       XRT_PERF_CONFIGURATION,
                                   .error = error,
                                   .tid = -1,
                                   .syscall = "fd.flow.owner",
                                   .detail = detail};
}
static enum xrt_status tids(struct xrt_fdflow_owner *a, int32_t out[128], uint32_t *count,
                            struct xrt_perf_failure *f) {
    *count = 0;
    for (uint32_t i = 0; i < a->pid_count; ++i) {
        char path[80];
        snprintf(path, sizeof path, "/proc/%d/task", a->pids[i]);
        DIR *d = opendir(path);
        if (!d) {
            failure(f, errno, "explicit graph process scope unavailable");
            return XRT_FILE_UNAVAILABLE;
        }
        errno = 0;
        for (struct dirent *e; (e = readdir(d));) {
            if (e->d_name[0] == '.')
                continue;
            char *end = NULL;
            errno = 0;
            long id = strtol(e->d_name, &end, 10);
            if (errno || !end || *end || id <= 0 || id > INT_MAX) {
                closedir(d);
                failure(f, EINVAL, "invalid scoped thread identity");
                return XRT_INVALID_ARGUMENT;
            }
            if (*count == 128) {
                closedir(d);
                failure(f, E2BIG, "explicit graph scope exceeds 128 threads");
                return XRT_INVALID_ARGUMENT;
            }
            out[(*count)++] = (int32_t)id;
            errno = 0;
        }
        int error = errno;
        closedir(d);
        if (error) {
            failure(f, error, "explicit graph thread enumeration failed");
            return XRT_FILE_UNAVAILABLE;
        }
    }
    if (a->pid_count && !*count) {
        failure(f, ESRCH, "explicit graph scope has no live threads");
        return XRT_FILE_UNAVAILABLE;
    }
    return XRT_OK;
}
static int reserve_publication(struct publication *p, uint32_t rows, uint32_t cpus) {
    if (rows > p->row_capacity) {
        uint32_t n = p->row_capacity ? p->row_capacity : 64;
        while (n < rows)
            n *= 2;
        struct xrt_fdflow_count_row *r = malloc((size_t)n * sizeof *r);
        struct xrt_fdflow_rate *v = malloc((size_t)n * sizeof *v);
        if (!r || !v) {
            free(r);
            free(v);
            return 0;
        }
        free(p->rows);
        free(p->rates);
        p->rows = r;
        p->rates = v;
        p->row_capacity = n;
    }
    if (cpus > p->cpu_capacity) {
        struct xrt_fdflow_cpu *v = realloc(p->cpus, (size_t)cpus * sizeof *v);
        if (!v)
            return 0;
        p->cpus = v;
        p->cpu_capacity = cpus;
    }
    return 1;
}
/* The worker owns spare and all counter mutations. Readers only see current.
 * Preparing/copying the next publication never holds the publication lock. */
static int publish(struct xrt_fdflow_owner *a, struct publication *spare,
                   struct xrt_fdflow_counter *counter, const struct xrt_fdflow_snapshot *stream,
                   enum xrt_status status, const struct xrt_perf_failure *why, uint64_t generation,
                   uint64_t cpu_started) {
    struct xrt_fdflow_counts counts = {0};
    if (counter)
        xrt_fdflow_counter_view(counter, &counts);
    if (!reserve_publication(spare, counts.row_count, stream->cpu_count))
        return 0;
    if (counts.row_count)
        memcpy(spare->rows, counts.rows, counts.row_count * sizeof *spare->rows);
    if (stream->cpu_count)
        memcpy(spare->cpus, stream->cpus, stream->cpu_count * sizeof *spare->cpus);
    /* Only this worker writes view/current. Readers do not mutate them. */
    uint64_t previous =
        a->view.generation == generation ? a->view.stream.taken_ns : stream->started_ns;
    double seconds = stream->taken_ns > previous ? (double)(stream->taken_ns - previous) / 1e9 : 0;
    /* Rows keep ascending serials across compaction: merge by serial. */
    uint32_t before = a->view.generation == generation ? a->view.counts.row_count : 0, j = 0;
    for (uint32_t i = 0; i < counts.row_count; ++i) {
        uint64_t read = 0, write = 0;
        while (j < before && a->current.rows[j].serial < counts.rows[i].serial)
            ++j;
        if (j < before && a->current.rows[j].serial == counts.rows[i].serial) {
            read = a->current.rows[j].read_bytes;
            write = a->current.rows[j].write_bytes;
        }
        const struct xrt_fdflow_count_row *r = &counts.rows[i];
        spare->rates[i] = (struct xrt_fdflow_rate){
            .read =
                stream->running && seconds > 0 && r->read_bytes >= read
                    ? (double)(r->read_bytes - read) / seconds : 0,
            .write = stream->running && seconds > 0 && r->write_bytes >= write
                         ? (double)(r->write_bytes - write) / seconds
                         : 0};
    }
    struct xrt_fdflow_live v = {.stream = *stream,
                                .counts = counts,
                                .rates = spare->rates,
                                .failure = *why,
                                .status = status,
                                .generation = generation,
                                .owner_cpu_ns = clock_ns(CLOCK_THREAD_CPUTIME_ID) - cpu_started};
    v.stream.records = NULL;
    v.stream.record_count = 0;
    v.stream.cpus = spare->cpus;
    v.counts.rows = spare->rows;
    pthread_mutex_lock(&a->lock);
    v.requested = clock_ns(CLOCK_MONOTONIC) < a->wanted_until;
    v.sequence = a->view.sequence + 1;
    struct publication old = a->current;
    a->current = *spare;
    *spare = old;
    a->view = v;
    pthread_mutex_unlock(&a->lock);
    return 1;
}
static void *work(void *opaque) {
    struct xrt_fdflow_owner *a = opaque;
    struct xrt_fdflow *flow = NULL;
    struct xrt_fdflow_counter *counter = NULL;
    struct xrt_fdflow_snapshot stream = {0};
    struct xrt_perf_failure why = {0};
    enum xrt_status status = XRT_STALE_SNAPSHOT;
    uint64_t generation = 0, next_publish = 0, cpu_started = clock_ns(CLOCK_THREAD_CPUTIME_ID);
    struct publication spare = {0};
    while (!atomic_load(&a->stop)) {
        uint64_t now = clock_ns(CLOCK_MONOTONIC);
        pthread_mutex_lock(&a->lock);
        int wanted = now < a->wanted_until;
        uint64_t requested = a->requested_generation;
        struct xrt_fdflow_bindings *bindings = NULL;
        if (wanted) {
            bindings = a->pending;
            a->pending = NULL;
        }
        pthread_mutex_unlock(&a->lock);
        if (generation != requested || !wanted) {
            if (flow) {
                (void)xrt_fdflow_drain(flow, &stream);
                if (counter)
                    (void)xrt_fdflow_counter_feed(counter, &stream);
                xrt_fdflow_stop(flow);
                stream.running = 0;
                stream.pending = 0;
                (void)publish(a, &spare, counter, &stream, status, &why, generation, cpu_started);
                xrt_fdflow_close(flow);
                flow = NULL;
            }
            if (counter) {
                xrt_fdflow_counter_free(counter);
                counter = NULL;
            }
            if (generation != requested) {
                generation = requested;
                memset(&stream, 0, sizeof stream);
                stream.scoped = a->pid_count != 0;
                memset(&why, 0, sizeof why);
                status = XRT_STALE_SNAPSHOT;
                if (wanted) {
                    int32_t ids[128];
                    uint32_t count = 0;
                    status = tids(a, ids, &count, &why);
                    if (status == XRT_OK)
                        status = xrt_fdflow_counter_create(262144, 65536, 16384, &counter);
                    if (status == XRT_OK) {
                        struct xrt_fdflow_options options = {.scoped = a->pid_count != 0,
                                                             .tids = count ? ids : NULL,
                                                             .tid_count = count};
                        status = xrt_fdflow_open(&options, &flow, &why);
                        if (status == XRT_OK) {
                            status = xrt_fdflow_drain(flow, &stream);
                            if (status == XRT_OK)
                                status = xrt_fdflow_counter_feed(counter, &stream);
                        }
                    }
                    if (status != XRT_OK)
                        stream.reason = why.detail ? why.detail : "flow owner unavailable";
                    next_publish = 0;
                }
            }
        }
        if (bindings) {
            if (counter && flow && bindings->started_ns >= stream.started_ns &&
                xrt_fdflow_counter_bind(counter, bindings) == XRT_OK)
                bindings = NULL;
            xrt_fdflow_bindings_free(bindings);
        }
        if (flow && stream.running) {
            enum xrt_status drained = xrt_fdflow_drain(flow, &stream);
            enum xrt_status counted = xrt_fdflow_counter_feed(counter, &stream);
            status = drained != XRT_OK ? drained : counted;
        }
        now = clock_ns(CLOCK_MONOTONIC);
        if (wanted && now >= next_publish) {
            if (!publish(a, &spare, counter, &stream, status, &why, generation, cpu_started)) {
                pthread_mutex_lock(&a->lock);
                a->view.status = XRT_OUT_OF_MEMORY;
                pthread_mutex_unlock(&a->lock);
            }
            next_publish = now + 100000000u;
        }
        pthread_mutex_lock(&a->lock);
        if (!atomic_load(&a->stop)) {
            if (flow || clock_ns(CLOCK_MONOTONIC) < a->wanted_until) {
                uint64_t deadline =
                    clock_ns(CLOCK_MONOTONIC) + (flow && stream.running ? 10000000u : 100000000u);
                struct timespec until = {(time_t)(deadline / 1000000000u),
                                         (long)(deadline % 1000000000u)};
                (void)pthread_cond_timedwait(&a->wake, &a->lock, &until);
            } else
                (void)pthread_cond_wait(&a->wake, &a->lock);
        }
        pthread_mutex_unlock(&a->lock);
    }
    xrt_fdflow_close(flow);
    xrt_fdflow_counter_free(counter);
    release_publication(&spare);
    return NULL;
}
enum xrt_status xrt_fdflow_owner_create(const int32_t *pids, uint32_t count,
                                        struct xrt_fdflow_owner **out) {
    if (out)
        *out = NULL;
    if (!out || count > 128 || (count && !pids) || (!count && pids))
        return XRT_INVALID_ARGUMENT;
    for (uint32_t i = 0; i < count; ++i) {
        if (pids[i] <= 0)
            return XRT_INVALID_ARGUMENT;
        for (uint32_t j = 0; j < i; ++j)
            if (pids[j] == pids[i])
                return XRT_INVALID_ARGUMENT;
    }
    struct xrt_fdflow_owner *a = calloc(1, sizeof *a);
    if (!a)
        return XRT_OUT_OF_MEMORY;
    if (count)
        memcpy(a->pids, pids, count * sizeof *pids);
    a->pid_count = count;
    a->view.stream.scoped = count != 0;
    a->view.status = XRT_STALE_SNAPSHOT;
    atomic_init(&a->stop, 0);
    if (pthread_mutex_init(&a->lock, NULL)) {
        free(a);
        return XRT_OUT_OF_MEMORY;
    }
    pthread_condattr_t attr;
    int err = pthread_condattr_init(&attr);
    if (!err) {
        err = pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
        if (!err)
            err = pthread_cond_init(&a->wake, &attr);
        pthread_condattr_destroy(&attr);
    }
    if (err) {
        pthread_mutex_destroy(&a->lock);
        free(a);
        return XRT_OUT_OF_MEMORY;
    }
    if (pthread_create(&a->thread, NULL, work, a)) {
        pthread_cond_destroy(&a->wake);
        pthread_mutex_destroy(&a->lock);
        free(a);
        return XRT_OUT_OF_MEMORY;
    }
    *out = a;
    return XRT_OK;
}
void xrt_fdflow_owner_destroy(struct xrt_fdflow_owner *a) {
    if (!a)
        return;
    pthread_mutex_lock(&a->lock);
    atomic_store(&a->stop, 1);
    pthread_cond_signal(&a->wake);
    pthread_mutex_unlock(&a->lock);
    pthread_join(a->thread, NULL);
    xrt_fdflow_bindings_free(a->pending);
    release_publication(&a->current);
    pthread_cond_destroy(&a->wake);
    pthread_mutex_destroy(&a->lock);
    free(a);
}
enum xrt_status xrt_fdflow_owner_request(struct xrt_fdflow_owner *a, int enable) {
    if (!a || (enable != 0 && enable != 1))
        return XRT_INVALID_ARGUMENT;
    if (pthread_mutex_trylock(&a->lock))
        return XRT_STALE_SNAPSHOT;
    uint64_t now = clock_ns(CLOCK_MONOTONIC);
    if (enable) {
        if (now >= a->wanted_until)
            ++a->requested_generation;
        a->wanted_until = now + 3000000000u;
    } else
        a->wanted_until = 0;
    pthread_cond_signal(&a->wake);
    pthread_mutex_unlock(&a->lock);
    return XRT_OK;
}
enum xrt_status xrt_fdflow_owner_bind(struct xrt_fdflow_owner *a, struct xrt_fdflow_bindings *b) {
    if (!a || !b)
        return XRT_INVALID_ARGUMENT;
    if (pthread_mutex_trylock(&a->lock))
        return XRT_STALE_SNAPSHOT;
    if (a->pending && b->sequence <= a->pending->sequence) {
        pthread_mutex_unlock(&a->lock);
        return XRT_INVALID_ARGUMENT;
    }
    struct xrt_fdflow_bindings *old = a->pending;
    a->pending = b;
    pthread_cond_signal(&a->wake);
    pthread_mutex_unlock(&a->lock);
    xrt_fdflow_bindings_free(old);
    return XRT_OK;
}
int xrt_fdflow_owner_acquire(struct xrt_fdflow_owner *a, struct xrt_fdflow_live *v) {
    if (!a || !v || pthread_mutex_trylock(&a->lock))
        return 0;
    *v = a->view;
    v->requested = clock_ns(CLOCK_MONOTONIC) < a->wanted_until;
    return 1;
}
void xrt_fdflow_owner_release(struct xrt_fdflow_owner *a) {
    if (a)
        pthread_mutex_unlock(&a->lock);
}
struct xrt_fdflow_live *xrt_fdflow_live_copy(const struct xrt_fdflow_live *v) {
    if (!v || (v->counts.row_count && (!v->counts.rows || !v->rates)) ||
        (v->stream.cpu_count && !v->stream.cpus))
        return NULL;
    size_t rows = (size_t)v->counts.row_count, cpus = v->stream.cpu_count;
    struct xrt_fdflow_live *out = malloc(sizeof *out + rows * sizeof *v->counts.rows +
                                         rows * sizeof *v->rates + cpus * sizeof *v->stream.cpus);
    if (!out)
        return NULL;
    *out = *v;
    struct xrt_fdflow_count_row *r = (void *)(out + 1);
    struct xrt_fdflow_rate *rate = (void *)(r + rows);
    struct xrt_fdflow_cpu *cpu = (void *)(rate + rows);
    if (rows) {
        memcpy(r, v->counts.rows, rows * sizeof *r);
        memcpy(rate, v->rates, rows * sizeof *rate);
    }
    if (cpus)
        memcpy(cpu, v->stream.cpus, cpus * sizeof *cpu);
    out->counts.rows = r;
    out->rates = rate;
    out->stream.cpus = cpu;
    out->stream.records = NULL;
    out->stream.record_count = 0;
    return out;
}
void xrt_fdflow_live_free(struct xrt_fdflow_live *v) { free(v); }
