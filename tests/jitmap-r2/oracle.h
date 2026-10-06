// Exhaustive reference resolver for tests and the fuzz harness. It restates
// the C07 definition directly: every version of a source is tested, and every
// containing version scans every other version for a later begin (the
// original nested scan, O(versions^2) per query). It shares only the decoded
// versions with the library, not the index or its search code, and counts
// its inner-loop visits so tests can show what the old scan would cost.
// Window bounds use exact 128-bit arithmetic (contract v1 section 5).
#ifndef XODB_JITMAP_ORACLE_H
#define XODB_JITMAP_ORACLE_H
#include "jitmap.h"
#include <stdlib.h>
#include <string.h>

typedef __int128 oracle_wide;

struct oracle_candidate {
    uint32_t version, state, reasons;
};

struct oracle_result {
    uint32_t outcome, reasons;
    size_t total, cap;
    struct oracle_candidate *candidates; /* all candidates, version order */
    uint64_t visits;
};

static int oracle_clock_equal(const struct xodb_jit_clock *a, const struct xodb_jit_clock *b)
{
    return a->kind != XODB_JIT_CLOCK_UNKNOWN && a->kind == b->kind && a->scope_known && b->scope_known &&
           !memcmp(a->scope, b->scope, 16);
}

/* 0: unrelated; 1: same clock; 2: declared map usable. */
static int oracle_relation(const struct xodb_jit_source *s, const struct xodb_jit_clock *q)
{
    if (oracle_clock_equal(&s->meta.clock, q))
        return 1;
    const struct xodb_jit_clock_map *m = &s->meta.map;
    if (m->method == XODB_JIT_MAP_OFFSET && oracle_clock_equal(&m->target, q))
        return 2;
    if (m->method == XODB_JIT_MAP_PERF_TSC && m->shift <= 63 && oracle_clock_equal(&m->target, q))
        return 2;
    return 0;
}

static oracle_wide oracle_map(const struct xodb_jit_source *s, int rel, uint64_t t)
{
    const struct xodb_jit_clock_map *m = &s->meta.map;
    if (rel == 1)
        return (oracle_wide)t;
    if (m->method == XODB_JIT_MAP_OFFSET)
        return (oracle_wide)t + (oracle_wide)m->offset;
    /* perf time_conv: zero + (t >> shift) * mult + (((t & mask) * mult) >> shift) */
    unsigned __int128 quot = t >> m->shift, rem = t & ((m->shift == 64 ? 0 : (1ull << m->shift)) - 1);
    return (oracle_wide)m->zero + (oracle_wide)(quot * m->mult) + (oracle_wide)((rem * m->mult) >> m->shift);
}

static oracle_wide oracle_lo(const struct xodb_jit_source *s, int rel, uint64_t t)
{
    uint64_t before = t > s->meta.slack ? t - s->meta.slack : 0;
    return oracle_map(s, rel, before) - (rel == 2 ? (oracle_wide)s->meta.map.uncertainty : 0);
}

static oracle_wide oracle_hi(const struct xodb_jit_source *s, int rel, uint64_t t)
{
    uint64_t after = s->meta.slack > UINT64_MAX - t ? UINT64_MAX : t + s->meta.slack;
    return oracle_map(s, rel, after) + (rel == 2 ? (oracle_wide)s->meta.map.uncertainty : 0);
}

static int oracle_contains(const struct xodb_jit_version *v, uint64_t a)
{
    return a >= v->start && a - v->start < v->size;
}

static void oracle_add(struct oracle_result *o, uint32_t version, uint32_t state, uint32_t reasons)
{
    if (o->total == o->cap) {
        o->cap = o->cap ? 2 * o->cap : 16;
        o->candidates = realloc(o->candidates, o->cap * sizeof *o->candidates);
        if (!o->candidates)
            abort();
    }
    o->candidates[o->total++] = (struct oracle_candidate){version, state, reasons};
    o->reasons |= reasons;
}

/* Contract v3 section 5 duplicate-evidence rule, restated independently:
 * build each side's identity as a list of (pointer, length) facts and
 * compare them pairwise. */
struct oracle_fact {
    const void *p;
    size_t n;
};

static size_t oracle_facts(const struct xodb_jit_model *m, const struct xodb_jit_version *v, struct oracle_fact *f,
                           size_t cap, uint64_t *scalars)
{
    const struct xodb_jit_source *s = &m->sources[v->source];
    size_t k = 0;
    uint64_t *x = scalars;
    /* Process, clock, header. */
    x[0] = s->meta.process.pid;
    x[1] = s->meta.process.start_ticks;
    x[2] = s->meta.clock.kind;
    x[3] = s->version;
    x[4] = s->elf_mach;
    x[5] = s->header_pid;
    x[6] = s->header_time;
    x[7] = s->header_flags;
    /* LOAD fields and lifetime. */
    x[8] = v->code_index;
    x[9] = v->pid;
    x[10] = v->tid;
    x[11] = v->start;
    x[12] = v->size;
    x[13] = v->vma;
    x[14] = v->begin.time;
    x[15] = v->end.kind;
    x[16] = v->end.has_time ? v->end.time : 0;
    x[17] = v->end.has_time;
    x[18] = v->flags;
    x[19] = v->debug_count;
    x[20] = v->unwind_record >= 0;
    f[k++] = (struct oracle_fact){x, 21 * sizeof *x};
    f[k++] = (struct oracle_fact){s->meta.process.boot_id, 16};
    f[k++] = (struct oracle_fact){s->meta.clock.scope, 16};
    f[k++] = (struct oracle_fact){s->bytes + v->name_offset, v->name_len};
    f[k++] = (struct oracle_fact){s->bytes + v->code_offset, v->size};
    if (v->unwind_record >= 0) {
        const struct xodb_jit_unwind *u = &m->unwinds[v->unwind_record];
        f[k++] = (struct oracle_fact){&u->unwind_size, sizeof u->unwind_size};
        f[k++] = (struct oracle_fact){&u->eh_frame_hdr_size, sizeof u->eh_frame_hdr_size};
        f[k++] = (struct oracle_fact){&u->mapped_size, sizeof u->mapped_size};
        f[k++] = (struct oracle_fact){s->bytes + u->data_offset, u->unwind_size};
    }
    for (uint32_t i = 0; i < v->debug_count && k + 6 <= cap; ++i) {
        const struct xodb_jit_debug_entry *d = &m->debug[v->debug_first + i];
        f[k++] = (struct oracle_fact){&d->address, sizeof d->address};
        f[k++] = (struct oracle_fact){&d->line, sizeof d->line};
        f[k++] = (struct oracle_fact){&d->discriminator, sizeof d->discriminator};
        f[k++] = (struct oracle_fact){&d->in_range, sizeof d->in_range};
        f[k++] = (struct oracle_fact){s->bytes + d->file_offset, d->file_len};
    }
    return k;
}

static int oracle_equivalent(const struct xodb_jit_model *m, const struct xodb_jit_version *a,
                             const struct xodb_jit_version *b)
{
    if (a == b)
        return 1;
    const struct xodb_jit_source *sa = &m->sources[a->source], *sb = &m->sources[b->source];
    if (sa->kind == XODB_JIT_SOURCE_PERFMAP && sb->kind == XODB_JIT_SOURCE_PERFMAP)
        return a->source == b->source && a->start == b->start && a->size == b->size && a->name_len == b->name_len &&
               !memcmp(sa->bytes + a->name_offset, sb->bytes + b->name_offset, a->name_len);
    if (sa->kind != XODB_JIT_SOURCE_JITDUMP || sb->kind != XODB_JIT_SOURCE_JITDUMP || a->source == b->source)
        return 0;
    if (!sa->meta.process.known || !sb->meta.process.known || !sa->meta.clock.scope_known ||
        !sb->meta.clock.scope_known || sa->meta.clock.kind == XODB_JIT_CLOCK_UNKNOWN)
        return 0;
    if (a->begin.kind != XODB_JIT_BOUND_LOAD || b->begin.kind != XODB_JIT_BOUND_LOAD || a->predecessor ||
        b->predecessor || !(a->flags & XODB_JIT_V_HAS_CODE) || !a->has_code_index || !b->has_code_index)
        return 0;
    if (a->debug_count > 64 || b->debug_count > 64)
        abort(); /* oracle fact table size; generators stay far below */
    struct oracle_fact fa[9 + 5 * 64], fb[9 + 5 * 64];
    uint64_t xa[21], xb[21];
    size_t na = oracle_facts(m, a, fa, sizeof fa / sizeof *fa, xa), nb = oracle_facts(m, b, fb, sizeof fb / sizeof *fb, xb);
    if (na != nb)
        return 0;
    for (size_t i = 0; i < na; ++i)
        if (fa[i].n != fb[i].n || (fa[i].n && memcmp(fa[i].p, fb[i].p, fa[i].n)))
            return 0;
    return 1;
}

/* Contract v4 section 2: classification work C = 15 * max_v c(v) (at most 15
 * compared candidates). A perf-map line costs c(v) = floor(name/4096): two
 * lines of one perf map, whatever the number of jitdump sources. A jitdump
 * version costs c(v) = 1 + d + floor(name/4096) + floor(code/4096)
 * + floor(unwind/4096) + sum floor(file/4096) when the model has two or more
 * jitdump sources, else 0 (versions of one jitdump are never byte-compared). */
static inline uint64_t oracle_class_bound(const struct xodb_jit_model *m)
{
    size_t dumps = 0;
    for (size_t i = 0; i < m->source_count; ++i)
        dumps += m->sources[i].kind == XODB_JIT_SOURCE_JITDUMP;
    uint64_t worst = 0;
    for (size_t i = 0; i < m->version_count; ++i) {
        const struct xodb_jit_version *v = &m->versions[i];
        uint64_t c = 0;
        if (m->sources[v->source].kind == XODB_JIT_SOURCE_PERFMAP) {
            c = v->name_len / 4096;
        } else if (dumps >= 2) {
            c = 1 + v->debug_count + v->name_len / 4096 + v->size / 4096;
            if (v->unwind_record >= 0)
                c += m->unwinds[v->unwind_record].unwind_size / 4096;
            for (uint32_t k = 0; k < v->debug_count; ++k)
                c += m->debug[v->debug_first + k].file_len / 4096;
        }
        if (c > worst)
            worst = c;
    }
    return (XODB_JIT_MAX_CANDIDATES - 1) * worst;
}

static void oracle_resolve(const struct xodb_jit_model *m, const struct xodb_jit_query *q, struct oracle_result *o)
{
    struct oracle_candidate *keep = o->candidates;
    size_t cap = o->cap;
    memset(o, 0, sizeof *o);
    o->candidates = keep;
    o->cap = cap;
    oracle_wide t = (oracle_wide)q->time;
    for (uint32_t si = 0; si < m->source_count; ++si) {
        const struct xodb_jit_source *s = &m->sources[si];
        const struct xodb_jit_process *sp = &s->meta.process, *qp = &q->process;
        if (sp->pid != qp->pid ||
            (sp->known && qp->known && (sp->start_ticks != qp->start_ticks || memcmp(sp->boot_id, qp->boot_id, 16)))) {
            o->reasons |= XODB_JIT_R_IDENTITY_SKIPPED;
            continue;
        }
        uint32_t base = (sp->known && qp->known ? 0 : XODB_JIT_R_IDENTITY_UNVERIFIED) |
                        (s->partial ? XODB_JIT_R_PARTIAL_SOURCE : 0);
        int rel = oracle_relation(s, &q->clock), timed = q->has_time && rel;
        if (s->kind == XODB_JIT_SOURCE_PERFMAP) {
            base |= XODB_JIT_R_UNTIMED_SNAPSHOT;
            if (q->has_time && s->has_coverage && rel && t >= oracle_lo(s, rel, s->coverage_end))
                base |= XODB_JIT_R_AFTER_COVERAGE;
            o->reasons |= base;
            for (size_t i = 0; i < m->version_count; ++i) {
                o->visits++;
                const struct xodb_jit_version *v = &m->versions[i];
                if (v->source == si && oracle_contains(v, q->address))
                    oracle_add(o, v->id, XODB_JIT_C_POSSIBLE, base | XODB_JIT_R_NO_END_EVIDENCE);
            }
            continue;
        }
        if (!q->has_time)
            base |= XODB_JIT_R_NO_QUERY_TIME;
        else if (!timed)
            base |= XODB_JIT_R_CLOCK_UNRELATED;
        if (timed) {
            int has_begin = s->meta.header_time_in_clock || s->has_last_time;
            uint64_t begin = s->meta.header_time_in_clock ? s->header_time : s->first_time;
            if (has_begin && t < oracle_lo(s, rel, begin))
                base |= XODB_JIT_R_BEFORE_COVERAGE;
            if (!s->has_coverage)
                base |= XODB_JIT_R_NO_COVERAGE;
            else if (t >= oracle_lo(s, rel, s->coverage_end))
                base |= XODB_JIT_R_AFTER_COVERAGE;
        }
        o->reasons |= base;
        for (size_t i = 0; i < m->version_count; ++i) {
            o->visits++;
            const struct xodb_jit_version *v = &m->versions[i];
            if (v->source != si || !oracle_contains(v, q->address))
                continue;
            uint32_t r = base | (v->end.kind == XODB_JIT_BOUND_NONE ? XODB_JIT_R_NO_END_EVIDENCE : 0);
            if (!timed) {
                oracle_add(o, v->id, XODB_JIT_C_POSSIBLE, r);
                continue;
            }
            uint32_t state = XODB_JIT_C_LIVE;
            if (t < oracle_lo(s, rel, v->begin.time))
                continue;
            if (t <= oracle_hi(s, rel, v->begin.time)) {
                state = XODB_JIT_C_POSSIBLE;
                r |= XODB_JIT_R_BOUNDARY;
            }
            if (v->end.has_time) {
                if (t > oracle_hi(s, rel, v->end.time))
                    continue;
                if (t >= oracle_lo(s, rel, v->end.time)) {
                    state = XODB_JIT_C_POSSIBLE;
                    r |= XODB_JIT_R_BOUNDARY;
                }
            }
            int superseded = 0;
            for (size_t k = 0; k < m->version_count && !superseded; ++k) {
                o->visits++;
                const struct xodb_jit_version *w = &m->versions[k];
                if (w == v || w->source != si || !oracle_contains(w, q->address) || w->begin.time <= v->begin.time)
                    continue;
                if (t > oracle_hi(s, rel, w->begin.time)) {
                    superseded = 1;
                } else if (t >= oracle_lo(s, rel, w->begin.time)) {
                    state = XODB_JIT_C_POSSIBLE;
                    r |= XODB_JIT_R_BOUNDARY;
                }
            }
            if (!superseded)
                oracle_add(o, v->id, state, r);
        }
    }
    if (!o->total) {
        o->outcome = XODB_JIT_NO_MATCH;
        return;
    }
    if (o->total > XODB_JIT_MAX_CANDIDATES) {
        o->reasons |= XODB_JIT_R_CANDIDATES_TRUNCATED;
        o->outcome = XODB_JIT_AMBIGUOUS;
        return;
    }
    const struct xodb_jit_version *first = &m->versions[o->candidates[0].version - 1];
    size_t live = 0, sources = 1;
    int unrelated_only = 1, ambiguous = 0;
    uint32_t live_reasons = 0;
    for (size_t i = 0; i < o->total; ++i) {
        const struct xodb_jit_version *v = &m->versions[o->candidates[i].version - 1];
        if (!oracle_equivalent(m, first, v))
            ambiguous = 1;
        if (v->source != first->source)
            sources++;
        if (o->candidates[i].state == XODB_JIT_C_LIVE) {
            live++;
            live_reasons |= o->candidates[i].reasons;
        }
        if (!(o->candidates[i].reasons & XODB_JIT_R_CLOCK_UNRELATED))
            unrelated_only = 0;
    }
    if (ambiguous) {
        if (live > 1)
            o->reasons |= XODB_JIT_R_OVERLAP;
        o->outcome = XODB_JIT_AMBIGUOUS;
        return;
    }
    if (sources > 1)
        o->reasons |= XODB_JIT_R_CORROBORATED;
    const uint32_t weak = XODB_JIT_R_IDENTITY_UNVERIFIED | XODB_JIT_R_AFTER_COVERAGE | XODB_JIT_R_PARTIAL_SOURCE |
                          XODB_JIT_R_NO_COVERAGE | XODB_JIT_R_BEFORE_COVERAGE;
    if (live && !(live_reasons & weak))
        o->outcome = XODB_JIT_RESOLVED;
    else if (!live && unrelated_only)
        o->outcome = XODB_JIT_UNAVAILABLE;
    else
        o->outcome = XODB_JIT_UNVERIFIED;
}

/* 0 when an indexed result agrees with the oracle: identical outcome and
 * total; identical candidates and reasons when untruncated; otherwise every
 * stored candidate appears in the oracle set with the same state/reasons and
 * the reported reasons are a subset of the oracle's. Returns a line tag of
 * the first disagreement. */
static int oracle_compare(const struct xodb_jit_result *r, const struct oracle_result *o)
{
    if (r->outcome != o->outcome)
        return 1;
    if (!r->total_exact || r->total != o->total)
        return 2;
    if (o->total <= XODB_JIT_MAX_CANDIDATES) {
        if (r->count != o->total || r->reasons != o->reasons)
            return 3;
        for (size_t i = 0; i < r->count; ++i)
            if (r->candidates[i].version != o->candidates[i].version || r->candidates[i].state != o->candidates[i].state ||
                r->candidates[i].reasons != o->candidates[i].reasons)
                return 4;
        return 0;
    }
    if (r->count != XODB_JIT_MAX_CANDIDATES || (r->reasons & ~o->reasons))
        return 5;
    for (size_t i = 0; i < r->count; ++i) {
        size_t k = 0;
        while (k < o->total && o->candidates[k].version != r->candidates[i].version)
            k++;
        if (k == o->total || o->candidates[k].state != r->candidates[i].state ||
            o->candidates[k].reasons != r->candidates[i].reasons)
            return 6;
        if (i && r->candidates[i - 1].version >= r->candidates[i].version)
            return 7;
    }
    return 0;
}
#endif
