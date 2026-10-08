#define _GNU_SOURCE 1
#include "xrt_memobserver.h"
#include "memstat_internal.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SECOND UINT64_C(1000000000)
#define DEMAND (3 * SECOND)
struct xrt_memobserver {
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t wake;
    int stop;
    struct xrt_mem_roots roots;
    struct xrt_mem_limits limits;
    struct xrt_mem_view view;
    uint64_t next_ticket, sequence, system_until, system_due, due[XRT_MEM_SCOPES];
    uint64_t existence_due[XRT_MEM_SCOPES];
};
uint64_t xrt_memobserver_period(uint64_t cpu_ns)
{
    /* Reserve most of a core-percent for collection, leaving room for the
     * client's renderer/serializer. Page-table walk cost depends strongly on
     * THP coverage; a 4 KiB map can be much dearer than the same huge map. */
    const uint64_t maximum = 60 * SECOND;
    if (cpu_ns > maximum / 125) return maximum;
    const uint64_t period = cpu_ns * 125;
    return period > SECOND ? period : SECOND;
}
static void *owner(void *opaque)
{
    struct xrt_memobserver *o = opaque;
    const uint64_t cpu_started = xrt_mem_clock(CLOCK_THREAD_CPUTIME_ID);
    pthread_mutex_lock(&o->lock);
    while (!o->stop) {
        uint64_t now = xrt_mem_clock(CLOCK_MONOTONIC), next = UINT64_MAX;
        int system = 0, slot = -1;
        if (now < o->system_until) {
            if (now >= o->system_due) system = 1;
            else next = o->system_due;
        }
        if (!system) for (uint32_t i = 0; i < XRT_MEM_SCOPES; ++i) {
            if (now >= o->view.scopes[i].demand_until) continue;
            if (now >= o->due[i]) { slot = (int)i; break; }
            if (o->due[i] < next) next = o->due[i];
        }
        if (!system && slot < 0) {
            if (next == UINT64_MAX) pthread_cond_wait(&o->wake, &o->lock);
            else {
                struct timespec until = {.tv_sec = (time_t)(next / SECOND), .tv_nsec = (long)(next % SECOND)};
                pthread_cond_timedwait(&o->wake, &o->lock, &until);
            }
            continue;
        }
        struct xrt_mem_request request = {0};
        if (slot >= 0) {
            struct xrt_mem_scope *scope = &o->view.scopes[slot];
            request = scope->request;
            request.start_ticks = scope->bound_start;
            scope->sampling = 1;
        }
        pthread_mutex_unlock(&o->lock);
        struct xrt_mem_system *sys = system ? xrt_mem_system_read(&o->roots, &o->limits) : NULL;
        struct xrt_mem_process *process = slot >= 0 ? xrt_mem_process_read(&o->roots, &o->limits, &request) : NULL;
        now = xrt_mem_clock(CLOCK_MONOTONIC);
        pthread_mutex_lock(&o->lock);
        if (system) {
            xrt_mem_system_delta(sys, o->view.system);
            xrt_mem_system_free((struct xrt_mem_system *)o->view.system);
            o->view.system = sys;
            o->view.system_error = sys ? 0 : ENOMEM;
            o->view.system_sequence = ++o->sequence;
            o->view.system_sampled_ns = now;
            o->view.system_refresh_ns = xrt_memobserver_period(sys ? sys->cpu_ns : 0);
            o->view.system_cost_limited = o->view.system_refresh_ns > SECOND;
            o->system_due = now + o->view.system_refresh_ns;
        } else {
            struct xrt_mem_scope *scope = &o->view.scopes[slot];
            xrt_mem_process_free((struct xrt_mem_process *)scope->previous);
            scope->previous = scope->snapshot;
            scope->snapshot = process;
            scope->delta_interval_ns = process && scope->previous && process->started_ns > scope->previous->started_ns ?
                process->started_ns - scope->previous->started_ns : 0;
            scope->error = process ? 0 : ENOMEM;
            scope->sequence = ++o->sequence;
            scope->sampled_ns = now;
            scope->sampling = 0;
            if (!scope->bound_start && process && process->start_ticks &&
                process->maps_status.state != XRT_MEM_IDENTITY_CHANGED && process->maps_status.state != XRT_MEM_EXITED)
                scope->bound_start = process->start_ticks;
            scope->refresh_ns = xrt_memobserver_period(process ? process->cpu_ns : 0);
            scope->cost_limited = scope->refresh_ns > SECOND;
            o->due[slot] = now + scope->refresh_ns;
            o->existence_due[slot] = now + SECOND;
        }
        o->view.owner_cpu_ns = xrt_mem_clock(CLOCK_THREAD_CPUTIME_ID) - cpu_started;
    }
    pthread_mutex_unlock(&o->lock);
    return NULL;
}
struct xrt_memobserver *xrt_memobserver_open(const struct xrt_mem_roots *roots,
    const struct xrt_mem_limits *limits)
{
    struct xrt_mem_limits defaults;
    if (!limits) { xrt_mem_limits_default(&defaults); limits = &defaults; }
    if (!xrt_mem_limits_valid(limits)) return NULL;
    struct xrt_memobserver *o = calloc(1, sizeof(*o));
    if (!o) return NULL;
    o->limits = *limits;
    if (roots && roots->proc) o->roots.proc = strdup(roots->proc);
    if (roots && roots->sys) o->roots.sys = strdup(roots->sys);
    if ((roots && roots->proc && !o->roots.proc) || (roots && roots->sys && !o->roots.sys)) goto fail;
    if (pthread_mutex_init(&o->lock, NULL)) goto fail;
    pthread_condattr_t attr;
    if (pthread_condattr_init(&attr)) goto mutex_fail;
    if (pthread_condattr_setclock(&attr, CLOCK_MONOTONIC)) { pthread_condattr_destroy(&attr); goto mutex_fail; }
    int error = pthread_cond_init(&o->wake, &attr);
    pthread_condattr_destroy(&attr);
    if (error) goto mutex_fail;
    if (pthread_create(&o->thread, NULL, owner, o)) { pthread_cond_destroy(&o->wake); goto mutex_fail; }
    return o;
mutex_fail:
    pthread_mutex_destroy(&o->lock);
fail:
    free((char *)o->roots.proc); free((char *)o->roots.sys); free(o);
    return NULL;
}
int xrt_memobserver_system(struct xrt_memobserver *o)
{
    if (!o || pthread_mutex_trylock(&o->lock)) return 0;
    uint64_t now = xrt_mem_clock(CLOCK_MONOTONIC);
    int wake = now >= o->system_until;
    o->system_until = now + DEMAND;
    if (wake) pthread_cond_signal(&o->wake);
    pthread_mutex_unlock(&o->lock);
    return 1;
}
static int identity_matches(const struct xrt_mem_scope *s, const struct xrt_mem_request *r)
{
    return s->ticket && s->request.pid == r->pid &&
        (!r->start_ticks || r->start_ticks == s->bound_start || r->start_ticks == s->request.start_ticks);
}
static int process_gone(const struct xrt_mem_roots *roots, int32_t pid)
{
    int root = open(roots->proc ? roots->proc : "/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (root < 0) return 0; /* A missing proc mount is not a target exit. */
    char name[32]; snprintf(name, sizeof(name), "%d", pid);
    struct stat st;
    int missing = fstatat(root, name, &st, 0) < 0 && (errno == ENOENT || errno == ESRCH);
    close(root);
    return missing;
}
uint64_t xrt_memobserver_process(struct xrt_memobserver *o, const struct xrt_mem_request *r)
{
    long page = sysconf(_SC_PAGESIZE);
    if (!o || !r || r->pid <= 0 || (r->flags & ~(XRT_MEM_SKIP_PAGES | XRT_MEM_NUMA)) || page <= 0 ||
        r->range_start % (uint64_t)page || r->range_end % (uint64_t)page ||
        ((r->range_start || r->range_end) && r->range_end <= r->range_start) || pthread_mutex_trylock(&o->lock)) return 0;
    uint64_t now = xrt_mem_clock(CLOCK_MONOTONIC);
    int found = -1, replace = -1;
    for (uint32_t i = 0; i < XRT_MEM_SCOPES; ++i) {
        const struct xrt_mem_scope *s = &o->view.scopes[i];
        if (identity_matches(s, r) && s->request.flags == r->flags &&
            s->request.range_start == r->range_start && s->request.range_end == r->range_end) found = (int)i;
        if (!s->sampling && now >= s->demand_until &&
            (replace < 0 || s->sampled_ns < o->view.scopes[replace].sampled_ns)) replace = (int)i;
    }
    /* A metadata reader should reuse an active full-page scope before a
     * metadata-only slot, avoiding a second smaps walk for the same process. */
    if (r->flags & XRT_MEM_SKIP_PAGES) for (uint32_t i = 0; i < XRT_MEM_SCOPES; ++i)
        if (identity_matches(&o->view.scopes[i], r) && !(o->view.scopes[i].request.flags & XRT_MEM_SKIP_PAGES) &&
            !(r->flags & XRT_MEM_NUMA & ~o->view.scopes[i].request.flags)) { found = (int)i; break; }
    int wake = now >= o->system_until;
    if (found < 0) {
        if (replace < 0) { pthread_mutex_unlock(&o->lock); return 0; }
        found = replace;
        struct xrt_mem_scope *s = &o->view.scopes[found];
        xrt_mem_process_free((struct xrt_mem_process *)s->snapshot);
        xrt_mem_process_free((struct xrt_mem_process *)s->previous);
        *s = (struct xrt_mem_scope){.ticket = ++o->next_ticket, .bound_start = r->start_ticks, .request = *r};
        o->due[found] = o->existence_due[found] = 0;
        wake = 1;
    }
    struct xrt_mem_scope *s = &o->view.scopes[found];
    /* A cost-limited map can have a long refresh period. Check only existence
     * at most once a second; the worker still owns identity and publication. */
    if (!s->sampling && s->snapshot && now < o->due[found] && now >= o->existence_due[found] &&
        s->snapshot->maps_status.state != XRT_MEM_EXITED &&
        s->snapshot->maps_status.state != XRT_MEM_IDENTITY_CHANGED) {
        o->existence_due[found] = now + SECOND;
        if (process_gone(&o->roots, r->pid)) { o->due[found] = 0; wake = 1; }
    }
    if (now >= s->demand_until) wake = 1;
    s->demand_until = o->system_until = now + DEMAND;
    uint64_t ticket = s->ticket;
    if (wake) pthread_cond_signal(&o->wake);
    pthread_mutex_unlock(&o->lock);
    return ticket;
}
int xrt_memobserver_acquire(struct xrt_memobserver *o, struct xrt_mem_view *view)
{
    if (!o || !view || pthread_mutex_trylock(&o->lock)) return 0;
    *view = o->view;
    return 1;
}
void xrt_memobserver_release(struct xrt_memobserver *o) { if (o) pthread_mutex_unlock(&o->lock); }
void xrt_memobserver_close(struct xrt_memobserver *o)
{
    if (!o) return;
    pthread_mutex_lock(&o->lock);
    o->stop = 1;
    pthread_cond_signal(&o->wake);
    pthread_mutex_unlock(&o->lock);
    pthread_join(o->thread, NULL);
    /* Synchronize with an already-entered reader before freeing publication.
     * The owner must prevent new callers once teardown starts. */
    pthread_mutex_lock(&o->lock);
    xrt_mem_system_free((struct xrt_mem_system *)o->view.system);
    for (uint32_t i = 0; i < XRT_MEM_SCOPES; ++i) {
        xrt_mem_process_free((struct xrt_mem_process *)o->view.scopes[i].snapshot);
        xrt_mem_process_free((struct xrt_mem_process *)o->view.scopes[i].previous);
    }
    pthread_mutex_unlock(&o->lock);
    pthread_cond_destroy(&o->wake); pthread_mutex_destroy(&o->lock);
    free((char *)o->roots.proc); free((char *)o->roots.sys); free(o);
}
