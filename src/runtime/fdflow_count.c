#define _GNU_SOURCE 1
#include "xrt_fdflow_count.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static uint64_t add(uint64_t a, uint64_t b) { return UINT64_MAX - a < b ? UINT64_MAX : a + b; }
static int same(const struct xrt_fdflow_binding *a, const struct xrt_fdflow_binding *b) {
    return a->pid == b->pid && a->fd == b->fd && a->start == b->start && a->device == b->device &&
           a->inode == b->inode && a->kind == b->kind;
}
static int compare(const struct xrt_fdflow_binding *a, const struct xrt_fdflow_binding *b) {
    if (a->pid != b->pid)
        return a->pid < b->pid ? -1 : 1;
    return a->fd < b->fd ? -1 : a->fd != b->fd;
}
void xrt_fdflow_bindings_free(struct xrt_fdflow_bindings *b) {
    if (b) {
        free(b->rows);
        free(b);
    }
}
enum xrt_status xrt_fdflow_bindings_create(const struct xrt_fd_snapshot *s,
                                           struct xrt_fdflow_bindings **out) {
    if (out)
        *out = NULL;
    if (!out || !s || s->process_count > 16384 || s->fd_count > 262144 ||
        (s->process_count && !s->processes) || (s->fd_count && !s->fds) || !s->taken_ns ||
        s->scan_ns > UINT64_MAX - s->taken_ns)
        return XRT_INVALID_ARGUMENT;
    struct xrt_fdflow_bindings *b = calloc(1, sizeof *b);
    if (!b)
        return XRT_OUT_OF_MEMORY;
    b->rows = calloc(s->fd_count ? s->fd_count : 1, sizeof *b->rows);
    if (!b->rows) {
        free(b);
        return XRT_OUT_OF_MEMORY;
    }
    b->sequence = s->sequence;
    b->started_ns = s->taken_ns;
    b->ready_ns = s->taken_ns + s->scan_ns;
    uint32_t end = 0;
    for (uint32_t i = 0; i < s->process_count; ++i) {
        const struct xrt_fd_process *p = &s->processes[i];
        if (p->pid <= 0 || !p->start || (i && p->pid <= s->processes[i - 1].pid) ||
            p->first != end || p->first > s->fd_count || p->count > s->fd_count - p->first)
            goto invalid;
        end = p->first + p->count;
        for (uint32_t j = 0; j < p->count; ++j) {
            const struct xrt_fd *f = &s->fds[p->first + j];
            if (f->fd < 0 || (j && f->fd <= s->fds[p->first + j - 1].fd))
                goto invalid;
            if (!xrt_fd_identity_current(s, p, f) || f->kind == XRT_FD_ANON ||
                f->kind == XRT_FD_OTHER || f->kind >= XRT_FD_KINDS)
                continue;
            b->rows[b->count++] = (struct xrt_fdflow_binding){.pid = p->pid,
                                                              .fd = f->fd,
                                                              .start = p->start,
                                                              .device = f->device,
                                                              .inode = f->inode,
                                                              .kind = f->kind,
                                                              .row = UINT32_MAX};
        }
    }
    if (end != s->fd_count)
        goto invalid;
    *out = b;
    return XRT_OK;
invalid:
    xrt_fdflow_bindings_free(b);
    return XRT_INVALID_ARGUMENT;
}
/* epoch makes clear_pending O(1): an entry from an older epoch has no pending
 * call, mutation or join. last_ns is the latest record time, for eviction. */
struct process {
    int32_t pid;
    uint32_t mutating;
    uint64_t cutoff, start, last_ns, epoch, async_ns; /* latest io_uring call */
    int asynchronous, pinned;
};
struct thread {
    int32_t tid, pid;
    uint32_t process, row;
    int have_entry, raw_exit, completed, mutation;
    int64_t number;
    uint64_t entered, cutoff, global_cutoff, last_named, last_ns, epoch;
};
/* Integer identity maps grow with observed processes/threads. Values index
 * dense arrays; zero in the hash table means empty, hence stored index+1. */
struct index {
    uint32_t *slots, capacity;
};
struct xrt_fdflow_counter {
    struct xrt_fdflow_bindings *bindings;
    struct xrt_fdflow_count_row *rows;
    struct process *processes;
    struct thread *threads;
    struct index pindex, tindex;
    uint32_t row_capacity, thread_capacity, process_capacity;
    uint32_t max_rows, max_threads, max_processes;
    uint64_t global_cutoff, lost, invalid, late;
    uint64_t epoch, evicted_cutoff, serial;
    int evict_blocked; /* a pressure sweep freed too little; wait for the next bind */
    struct xrt_fdflow_counts view;
};
static uint32_t hash(uint32_t n) {
    n ^= n >> 16;
    n *= 0x7feb352du;
    n ^= n >> 15;
    n *= 0x846ca68bu;
    return n ^ (n >> 16);
}
static int grow(void **p, uint32_t *cap, uint32_t count, uint32_t limit, size_t size) {
    if (count < *cap)
        return 1;
    uint32_t n = *cap ? *cap * 2 : 64;
    if (n > limit)
        n = limit;
    if (n <= count)
        return 0;
    void *q = realloc(*p, (size_t)n * size);
    if (!q)
        return 0;
    *p = q;
    *cap = n;
    return 1;
}
static void insert(struct index *map, uint32_t key, uint32_t value) {
    uint32_t at = hash(key) & (map->capacity - 1);
    while (map->slots[at])
        at = (at + 1) & (map->capacity - 1);
    map->slots[at] = value + 1;
}
/* After compaction: same capacity, no allocation, so it cannot fail. */
static void rehash(struct xrt_fdflow_counter *c, struct index *map, int thread, uint32_t count) {
    if (!map->capacity)
        return;
    memset(map->slots, 0, (size_t)map->capacity * sizeof *map->slots);
    for (uint32_t i = 0; i < count; ++i)
        insert(map, (uint32_t)(thread ? c->threads[i].tid : c->processes[i].pid), i);
}
static int reindex(struct xrt_fdflow_counter *c, struct index *map, int thread, uint32_t count) {
    if (map->capacity && (uint64_t)(count + 1) * 2 < map->capacity)
        return 1;
    uint32_t cap = map->capacity ? map->capacity * 2 : 128;
    uint32_t *slots = calloc(cap, sizeof *slots);
    if (!slots)
        return 0;
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t key = (uint32_t)(thread ? c->threads[i].tid : c->processes[i].pid);
        uint32_t at = hash(key) & (cap - 1);
        while (slots[at])
            at = (at + 1) & (cap - 1);
        slots[at] = i + 1;
    }
    free(map->slots);
    map->slots = slots;
    map->capacity = cap;
    return 1;
}
static uint32_t lookup(struct xrt_fdflow_counter *c, int thread, int32_t key) {
    struct index *map = thread ? &c->tindex : &c->pindex;
    if (!map->capacity)
        return UINT32_MAX;
    uint32_t at = hash((uint32_t)key) & (map->capacity - 1);
    while (map->slots[at]) {
        uint32_t i = map->slots[at] - 1;
        if ((thread ? c->threads[i].tid : c->processes[i].pid) == key)
            return i;
        at = (at + 1) & (map->capacity - 1);
    }
    return UINT32_MAX;
}
static void capacity(struct xrt_fdflow_counter *c, int oom) {
    c->view.flags |= oom ? XRT_FDFLOW_COUNT_OOM : XRT_FDFLOW_COUNT_CAP;
    c->view.dropped = add(c->view.dropped, 1);
}
static struct thread *thread_at(struct xrt_fdflow_counter *c, uint32_t i) {
    struct thread *t = &c->threads[i];
    if (t->epoch != c->epoch) {
        t->have_entry = 0;
        t->mutation = 0;
        t->row = UINT32_MAX;
        t->epoch = c->epoch;
    }
    return t;
}
static struct process *process_at(struct xrt_fdflow_counter *c, uint32_t i) {
    struct process *p = &c->processes[i];
    if (p->epoch != c->epoch) {
        p->mutating = 0;
        p->epoch = c->epoch;
    }
    return p;
}
static int io_number(int64_t n);
/* A call still owes an exit. exit/exit_group never return. */
static int in_flight(const struct thread *t) {
    return t->have_entry && t->number != 60 && t->number != 231 &&
           !(t->raw_exit && (t->completed || !io_number(t->number)));
}
static int live(const struct xrt_fdflow_counter *c, int32_t pid) {
    if (!c->bindings)
        return 0;
    uint32_t lo = 0, hi = c->bindings->count;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        if (c->bindings->rows[mid].pid < pid)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < c->bindings->count && c->bindings->rows[lo].pid == pid;
}
/* Forget idle identities so tables track the live set, not every pid ever
 * seen. At a bind (pressure 0) the new poll is the live set: keep its
 * processes, their active threads, and anything mid-mutation or io_uring. Under
 * table pressure keep only mutations and io_uring. Each evicted cutoff is folded
 * into evicted_cutoff, which newly enrolled processes inherit, so forgetting a
 * mutation can only make later joins unknown, never wrong. An evicted in-flight
 * call's exit is unpaired, hence unknown. Returns the number of entries freed. */
static uint32_t evict(struct xrt_fdflow_counter *c, int is_thread, uint64_t before, int pressure) {
    uint32_t kept = 0, n = is_thread ? c->view.thread_count : c->view.process_count;
    if (is_thread) {
        for (uint32_t i = 0; i < n; ++i) {
            struct thread *t = thread_at(c, i);
            int busy = in_flight(t);
            if ((busy && t->mutation) ||
                (!pressure && live(c, t->pid) && (busy || t->last_ns >= before)))
                c->threads[kept++] = *t;
        }
        c->view.thread_count = kept;
        rehash(c, &c->tindex, 1, kept);
        return n - kept;
    }
    for (uint32_t i = 0; i < n; ++i)
        process_at(c, i)->pinned = 0;
    for (uint32_t i = 0; i < c->view.thread_count; ++i) {
        struct thread *t = thread_at(c, i);
        uint32_t pi = in_flight(t) && t->mutation ? lookup(c, 0, t->pid) : UINT32_MAX;
        if (pi != UINT32_MAX)
            c->processes[pi].pinned = 1;
    }
    for (uint32_t i = 0; i < n; ++i) {
        struct process *p = &c->processes[i];
        if (p->pinned || p->mutating || p->asynchronous || (!pressure && live(c, p->pid)))
            c->processes[kept++] = *p;
        else if (p->cutoff > c->evicted_cutoff)
            c->evicted_cutoff = p->cutoff;
    }
    c->view.process_count = kept;
    rehash(c, &c->pindex, 0, kept);
    for (uint32_t i = 0; i < c->view.thread_count; ++i)
        c->threads[i].process = lookup(c, 0, c->threads[i].pid);
    return n - kept;
}
static uint32_t enroll(struct xrt_fdflow_counter *c, int is_thread, int32_t key, uint64_t time) {
    uint32_t existing = lookup(c, is_thread, key);
    if (existing != UINT32_MAX) {
        if (is_thread)
            thread_at(c, existing)->last_ns = time;
        else
            process_at(c, existing)->last_ns = time;
        return existing;
    }
    uint32_t n = is_thread ? c->view.thread_count : c->view.process_count;
    uint32_t limit = is_thread ? c->max_threads : c->max_processes;
    /* A sweep that frees a quarter of the table pays for the next quarter of
     * enrollments; one that frees less waits for the next bind. */
    if (n == limit && !c->evict_blocked) {
        if (evict(c, is_thread, time, 1) < limit / 4 + 1)
            c->evict_blocked = 1;
        n = is_thread ? c->view.thread_count : c->view.process_count;
    }
    if (n == limit) {
        capacity(c, 0);
        return UINT32_MAX;
    }
    int grown =
        is_thread
            ? grow((void **)&c->threads, &c->thread_capacity, n, limit, sizeof *c->threads)
            : grow((void **)&c->processes, &c->process_capacity, n, limit, sizeof *c->processes);
    struct index *map = is_thread ? &c->tindex : &c->pindex;
    if (!grown || !reindex(c, map, is_thread, n)) {
        capacity(c, 1);
        return UINT32_MAX;
    }
    if (is_thread) {
        c->threads[n] = (struct thread){
            .tid = key, .row = UINT32_MAX, .last_ns = time, .epoch = c->epoch};
        ++c->view.thread_count;
    } else {
        c->processes[n] = (struct process){
            .pid = key, .cutoff = c->evicted_cutoff, .last_ns = time, .epoch = c->epoch};
        ++c->view.process_count;
    }
    insert(map, (uint32_t)key, n);
    return n;
}
enum xrt_status xrt_fdflow_counter_create(uint32_t rows, uint32_t threads, uint32_t processes,
                                          struct xrt_fdflow_counter **out) {
    if (out)
        *out = NULL;
    if (!out || !rows || rows > 262144 || !threads || threads > 65536 || !processes ||
        processes > 16384)
        return XRT_INVALID_ARGUMENT;
    struct xrt_fdflow_counter *c = calloc(1, sizeof *c);
    if (!c)
        return XRT_OUT_OF_MEMORY;
    c->max_rows = rows;
    c->max_threads = threads;
    c->max_processes = processes;
    *out = c;
    return XRT_OK;
}
void xrt_fdflow_counter_free(struct xrt_fdflow_counter *c) {
    if (!c)
        return;
    xrt_fdflow_bindings_free(c->bindings);
    free(c->rows);
    free(c->threads);
    free(c->processes);
    free(c->pindex.slots);
    free(c->tindex.slots);
    free(c);
}
enum xrt_status xrt_fdflow_counter_bind(struct xrt_fdflow_counter *c,
                                        struct xrt_fdflow_bindings *b) {
    if (!c || !b || !b->started_ns || b->ready_ns < b->started_ns || (b->count && !b->rows) ||
        b->count > 262144 ||
        (c->bindings &&
         (b->sequence <= c->bindings->sequence || b->ready_ns < c->bindings->ready_ns)))
        return XRT_INVALID_ARGUMENT;
    for (uint32_t i = 0; i < b->count; ++i)
        if (b->rows[i].pid <= 0 || b->rows[i].fd < 0 || !b->rows[i].start || !b->rows[i].inode ||
            b->rows[i].kind >= XRT_FD_KINDS || b->rows[i].kind == XRT_FD_ANON ||
            b->rows[i].kind == XRT_FD_OTHER ||
            (i && b->rows[i - 1].pid == b->rows[i].pid &&
             b->rows[i - 1].start != b->rows[i].start) ||
            (i && compare(&b->rows[i - 1], &b->rows[i]) >= 0))
            return XRT_INVALID_ARGUMENT;
    for (uint32_t i = 0; i < c->view.row_count; ++i)
        c->rows[i].active = 0;
    /* old row -> compacted row; without it this bind keeps the inactive rows. */
    uint32_t *moved = c->view.row_count ? malloc(c->view.row_count * sizeof *moved) : NULL;
    uint32_t old = 0;
    for (uint32_t i = 0; i < b->count; ++i) {
        struct xrt_fdflow_binding *r = &b->rows[i];
        if (!i || b->rows[i - 1].pid != r->pid) {
            uint32_t pi = lookup(c, 0, r->pid);
            if (pi != UINT32_MAX) {
                struct process *p = process_at(c, pi);
                /* A reused pid keeps the cutoff, and an io_uring mark set since
                 * the last poll: records name only the pid, so either may be the
                 * new process's. An older mark was the old process's. */
                if (p->start && p->start != r->start) {
                    int keep = p->asynchronous && c->bindings && p->async_ns >= c->bindings->started_ns;
                    *p = (struct process){.pid = r->pid,
                                          .mutating = p->mutating,
                                          .cutoff = p->cutoff,
                                          .last_ns = p->last_ns,
                                          .epoch = c->epoch,
                                          .asynchronous = keep,
                                          .async_ns = keep ? p->async_ns : 0};
                }
                p->start = r->start;
            }
        }
        r->row = UINT32_MAX;
        if (!c->bindings)
            continue;
        while (old < c->bindings->count && compare(&c->bindings->rows[old], r) < 0)
            ++old;
        if (old < c->bindings->count && same(&c->bindings->rows[old], r)) {
            r->row = c->bindings->rows[old].row;
            if (r->row != UINT32_MAX)
                c->rows[r->row].active = 1;
        }
    }
    xrt_fdflow_bindings_free(c->bindings);
    c->bindings = b;
    c->view.sequence = b->sequence;
    /* Only rows of the current table can gain bytes: drop the rest, keeping
     * order (serials stay ascending), so rows track live descriptors. */
    if (moved) {
        uint32_t kept = 0;
        for (uint32_t i = 0; i < c->view.row_count; ++i) {
            moved[i] = c->rows[i].active ? kept : UINT32_MAX;
            if (c->rows[i].active)
                c->rows[kept++] = c->rows[i];
        }
        for (uint32_t i = 0; i < b->count; ++i)
            if (b->rows[i].row != UINT32_MAX)
                b->rows[i].row = moved[b->rows[i].row];
        for (uint32_t i = 0; i < c->view.thread_count; ++i)
            if (c->threads[i].row != UINT32_MAX)
                c->threads[i].row = moved[c->threads[i].row];
        c->view.row_count = kept;
        free(moved);
    }
    (void)evict(c, 1, b->started_ns, 0);
    (void)evict(c, 0, b->started_ns, 0);
    c->evict_blocked = 0;
    return XRT_OK;
}
static struct xrt_fdflow_binding *binding(struct xrt_fdflow_counter *c, int32_t pid, int32_t fd) {
    if (!c->bindings)
        return NULL;
    uint32_t lo = 0, hi = c->bindings->count;
    const struct xrt_fdflow_binding key = {.pid = pid, .fd = fd};
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        if (compare(&c->bindings->rows[mid], &key) < 0)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == c->bindings->count || compare(&c->bindings->rows[lo], &key))
        return NULL;
    return &c->bindings->rows[lo];
}
static uint32_t row(struct xrt_fdflow_counter *c, struct xrt_fdflow_binding *b) {
    if (b->row != UINT32_MAX)
        return b->row;
    uint32_t n = c->view.row_count;
    if (n == c->max_rows) {
        capacity(c, 0);
        return UINT32_MAX;
    }
    if (!grow((void **)&c->rows, &c->row_capacity, n, c->max_rows, sizeof *c->rows)) {
        capacity(c, 1);
        return UINT32_MAX;
    }
    c->rows[n] = (struct xrt_fdflow_count_row){.serial = ++c->serial,
                                               .pid = b->pid,
                                               .fd = b->fd,
                                               .start = b->start,
                                               .device = b->device,
                                               .inode = b->inode,
                                               .kind = b->kind,
                                               .active = 1};
    b->row = n;
    ++c->view.row_count;
    return n;
}
static void invalidate(struct xrt_fdflow_counter *c, struct process *p, uint64_t time) {
    if (time > p->cutoff)
        p->cutoff = time;
    c->view.invalidated = add(c->view.invalidated, 1);
}
/* Native x86-64 numbers only. Raw syscall tracepoints also fire for compat
 * (int $0x80) and x32 calls, with their own numbers, and the records carry no
 * ABI, so a compat close or dup2 of a joined fd is not seen as a mutation and
 * a later native IO on that fd can join the old inode. ABI-switching code is
 * outside coverage. Compat numbers alias common native calls (5 is fstat,
 * 8 lseek, 11 munmap), so they are not listed either.
 * Conservatively withdraw all this process's joins, then require a later poll.
 * Async io_uring may change descriptors after returning; stay unproved. */
static int mutation(int64_t n) {
    switch (n) {
    case 2:   /* open */
    case 3:   /* close */
    case 22:  /* pipe */
    case 32:  /* dup */
    case 33:  /* dup2 */
    case 41:  /* socket */
    case 43:  /* accept */
    case 47:  /* recvmsg: SCM_RIGHTS */
    case 53:  /* socketpair */
    case 56:  /* clone */
    case 57:  /* fork */
    case 58:  /* vfork */
    case 59:  /* execve: close-on-exec */
    case 72:  /* fcntl: F_DUPFD */
    case 85:  /* creat */
    case 257: /* openat */
    case 288: /* accept4 */
    case 292: /* dup3 */
    case 293: /* pipe2 */
    case 299: /* recvmmsg: SCM_RIGHTS */
    case 322: /* execveat */
    case 425: /* io_uring_setup */
    case 426: /* io_uring_enter */
    case 427: /* io_uring_register */
    case 435: /* clone3 */
    case 436: /* close_range */
    case 437: /* openat2 */
    case 438: /* pidfd_getfd */
        return 1;
    default:
        return 0;
    }
}
static int io_number(int64_t n) {
    switch (n) {
    case 0:
    case 1:
    case 17:
    case 18:
    case 19:
    case 20:
    case 295:
    case 296:
    case 327:
    case 328:
    case 44:
    case 45:
    case 46:
    case 47:
        return 1;
    default:
        return 0;
    }
}
/* O(1): thread_at/process_at reset entries from an older epoch on access. */
static void clear_pending(struct xrt_fdflow_counter *c, uint64_t time) {
    if (time > c->global_cutoff)
        c->global_cutoff = time;
    ++c->epoch;
    c->view.flags |= XRT_FDFLOW_COUNT_INCOMPLETE;
}
static void count_exit(struct xrt_fdflow_counter *c, struct thread *t, struct process *p,
                       const struct xrt_fdflow_record *r, int eligible) {
    if (t && t->last_named == r->time_ns) {
        c->view.duplicates = add(c->view.duplicates, 1);
        return;
    }
    if (t)
        t->last_named = r->time_ns;
    int paired =
        t && t->have_entry && !t->completed && t->number == r->number && t->entered <= r->time_ns;
    if (!paired)
        c->view.unpaired = add(c->view.unpaired, 1);
    if (r->result <= 0) {
        if (r->result < 0)
            c->view.failed_calls = add(c->view.failed_calls, 1);
        if (t)
            t->completed = 1;
        return;
    }
    uint64_t n = (uint64_t)r->result;
    uint64_t *total = r->operation == XRT_FDFLOW_READ ? &c->view.read_bytes : &c->view.write_bytes;
    *total = add(*total, n);
    int known = eligible && paired && p && !p->mutating && !p->asynchronous &&
                t->row != UINT32_MAX && t->cutoff == p->cutoff &&
                t->global_cutoff == c->global_cutoff && c->rows[t->row].active;
    if (known) {
        struct xrt_fdflow_count_row *v = &c->rows[t->row];
        uint64_t *bytes = r->operation == XRT_FDFLOW_READ ? &v->read_bytes : &v->write_bytes;
        *bytes = add(*bytes, n);
        v->calls = add(v->calls, 1);
        v->last_ns = r->time_ns;
    } else {
        uint64_t *unknown =
            r->operation == XRT_FDFLOW_READ ? &c->view.unknown_read : &c->view.unknown_write;
        *unknown = add(*unknown, n);
    }
    if (t)
        t->completed = 1;
}
enum xrt_status xrt_fdflow_counter_feed(struct xrt_fdflow_counter *c,
                                        const struct xrt_fdflow_snapshot *s) {
    if (!c || !s || s->record_count > 262144 || (s->record_count && !s->records) || !s->taken_ns)
        return XRT_INVALID_ARGUMENT;
    if (s->lost > c->lost || s->invalid > c->invalid || s->late > c->late ||
        (s->flags & (XRT_FDFLOW_CPU_PARTIAL | XRT_FDFLOW_LOSS_UNKNOWN | XRT_FDFLOW_BAD_RECORD |
                     XRT_FDFLOW_THROTTLE)))
        clear_pending(c, s->taken_ns);
    c->lost = s->lost;
    c->invalid = s->invalid;
    c->late = s->late;
    int eligible = !(s->flags & (XRT_FDFLOW_CPU_PARTIAL | XRT_FDFLOW_LOSS_UNKNOWN |
                                 XRT_FDFLOW_BAD_RECORD | XRT_FDFLOW_THROTTLE));
    for (uint32_t i = 0; i < s->record_count; ++i) {
        const struct xrt_fdflow_record *r = &s->records[i];
        if (r->kind == XRT_FDFLOW_LOST || r->kind == XRT_FDFLOW_THROTTLED) {
            clear_pending(c, s->taken_ns);
            continue;
        }
        if (r->pid <= 0 || r->tid <= 0 || !r->time_ns || r->operation > XRT_FDFLOW_WRITE ||
            (r->kind != XRT_FDFLOW_ENTER && r->kind != XRT_FDFLOW_EXIT) ||
            (r->kind == XRT_FDFLOW_ENTER && r->operation != XRT_FDFLOW_RAW))
            return XRT_INVALID_ARGUMENT;
        /* Process first: its eviction remaps thread->process, not thread slots. */
        uint32_t pi = enroll(c, 0, r->pid, r->time_ns), ti = enroll(c, 1, r->tid, r->time_ns);
        struct process *p = pi == UINT32_MAX ? NULL : &c->processes[pi];
        struct thread *t = ti == UINT32_MAX ? NULL : &c->threads[ti];
        if (t && t->pid != r->pid) {
            if (t->mutation && t->process < c->view.process_count &&
                process_at(c, t->process)->mutating)
                --c->processes[t->process].mutating;
            *t = (struct thread){.tid = r->tid,
                                 .pid = r->pid,
                                 .process = pi,
                                 .row = UINT32_MAX,
                                 .last_ns = r->time_ns,
                                 .epoch = c->epoch};
        }
        if (r->kind == XRT_FDFLOW_ENTER) {
            /* An untracked call could be a mutation that never reports its
             * end here: withdraw every join (O(1)) rather than guess. */
            if (!p || !t) {
                clear_pending(c, s->taken_ns);
                continue;
            }
            if (t->have_entry && !t->raw_exit) {
                invalidate(c, p, r->time_ns);
                if (t->mutation && p->mutating)
                    --p->mutating;
            }
            uint64_t last = t->last_named;
            *t = (struct thread){.tid = r->tid,
                                 .pid = r->pid,
                                 .process = pi,
                                 .row = UINT32_MAX,
                                 .have_entry = 1,
                                 .entered = r->time_ns,
                                 .number = r->number,
                                 .last_named = last,
                                 .last_ns = r->time_ns,
                                 .epoch = c->epoch,
                                 .cutoff = p->cutoff,
                                 .global_cutoff = c->global_cutoff};
            if (mutation(r->number)) {
                invalidate(c, p, r->time_ns);
                ++p->mutating;
                t->mutation = 1;
                if (r->number >= 425 && r->number <= 427) {
                    p->asynchronous = 1;
                    p->async_ns = r->time_ns;
                }
            }
            if (eligible && io_number(r->number) && c->bindings &&
                c->bindings->ready_ns <= r->time_ns && c->bindings->started_ns > p->cutoff &&
                c->bindings->started_ns > c->global_cutoff && !p->mutating && !p->asynchronous &&
                r->args[0] <= INT_MAX) {
                struct xrt_fdflow_binding *b = binding(c, r->pid, (int32_t)r->args[0]);
                if (b) {
                    if (!p->start)
                        p->start = b->start;
                    t->row = row(c, b);
                }
            }
        } else if (r->operation != XRT_FDFLOW_RAW)
            count_exit(c, t, p, r, eligible);
        else if (p) {
            if (!t || !t->have_entry || t->number != r->number || t->entered > r->time_ns)
                invalidate(c, p, r->time_ns);
            else {
                t->raw_exit = 1;
                if (t->mutation) {
                    if (p->mutating)
                        --p->mutating;
                    t->mutation = 0;
                    invalidate(c, p, r->time_ns);
                }
            }
        }
    }
    c->view.taken_ns = s->taken_ns;
    return c->view.flags & XRT_FDFLOW_COUNT_OOM ? XRT_OUT_OF_MEMORY : XRT_OK;
}
void xrt_fdflow_counter_view(const struct xrt_fdflow_counter *c, struct xrt_fdflow_counts *out) {
    if (!c || !out)
        return;
    *out = c->view;
    out->rows = c->rows;
}
