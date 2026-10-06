// libFuzzer harness for the jitdump and perf-map decoders and the resolver.
// First byte selects mode: 0 jitdump, 1 perf map, 2 both (split at byte 1),
// 3 jitdump under tiny budgets. Bits 2..7 of the first byte select a
// preparation work limit (C07-R2): a stopped add must roll back exactly.
// Checks structural invariants, exact memory accounting, the declared query
// bound, and agreement with the exhaustive oracle on small models. Bits 4 and 5
// of the second byte declare a known incarnation and add the jitdump twice.
#include "jitmap.h"
#include "oracle.h"
#include <stdlib.h>
#include <string.h>

#define REQUIRE(c)        \
    do {                  \
        if (!(c))         \
            abort();      \
    } while (0)

static size_t accounted(const struct xodb_jit_model *m)
{
    size_t total = m->source_cap * sizeof *m->sources + m->version_cap * sizeof *m->versions +
                   m->debug_cap * sizeof *m->debug + m->unwind_cap * sizeof *m->unwinds +
                   m->diag_cap * sizeof *m->diags;
    for (size_t i = 0; i < m->source_count; ++i)
        total += m->sources[i].charged;
    return total;
}

static uint64_t ceil_log2(uint64_t n)
{
    uint64_t k = 0;
    while (k < 64 && (1ull << k) < n)
        k++;
    return k;
}

static uint64_t query_bound(const struct xodb_jit_model *m)
{
    uint64_t bound = 16 + oracle_class_bound(m);
    for (size_t i = 0; i < m->source_count; ++i) {
        const struct xodb_jit_source *s = &m->sources[i];
        bound += 1;
        if (s->index.coord_count >= 2)
            bound += ceil_log2(s->index.coord_count) + 1 +
                     (ceil_log2(s->index.base) + 1) * (1 + 4 * (ceil_log2(s->version_count + 1) + 1));
    }
    return bound;
}

static struct oracle_result oracle;

static void invariants(const struct xodb_jit_model *m)
{
    REQUIRE(m->memory <= m->limits.max_memory_bytes);
    REQUIRE(m->memory == accounted(m));
    size_t versions = 0;
    for (size_t i = 0; i < m->source_count; ++i) {
        const struct xodb_jit_source *s = &m->sources[i];
        REQUIRE(s->version_first == versions);
        versions += s->version_count;
        for (size_t k = 0; k < s->index.entry_count; ++k)
            REQUIRE(s->index.entries[k] >= s->version_first && s->index.entries[k] < versions);
        for (size_t k = 1; k < s->index.coord_count; ++k)
            REQUIRE(s->index.coords[k - 1] < s->index.coords[k]);
    }
    REQUIRE(versions == m->version_count);
    REQUIRE(m->version_count <= m->limits.max_versions);
    for (size_t i = 0; i < m->source_count; ++i)
        REQUIRE(m->sources[i].decoded_bytes <= m->sources[i].len);
    for (size_t i = 0; i < m->version_count; ++i) {
        const struct xodb_jit_version *v = &m->versions[i];
        const struct xodb_jit_source *s = &m->sources[v->source];
        REQUIRE(v->id == i + 1 && v->size > 0 && v->size <= UINT64_MAX - v->start);
        REQUIRE(v->name_offset <= s->len && v->name_len <= s->len - v->name_offset);
        if (v->flags & XODB_JIT_V_HAS_CODE)
            REQUIRE(v->code_offset <= s->len && v->size <= s->len - v->code_offset);
        REQUIRE(v->predecessor < v->id);
        REQUIRE(v->debug_first + v->debug_count <= m->debug_count);
        for (uint32_t k = 0; k < v->debug_count; ++k) {
            const struct xodb_jit_debug_entry *d = &m->debug[v->debug_first + k];
            REQUIRE(d->file_offset <= s->len && d->file_len <= s->len - d->file_offset);
        }
        REQUIRE(v->unwind_record < (int64_t)m->unwind_count);
        if (v->end.kind != XODB_JIT_BOUND_NONE)
            REQUIRE(v->end.has_time && v->begin.has_time && v->begin.time <= v->end.time);
        REQUIRE(v->line_base <= v->id);
        if (v->line_base)
            REQUIRE(m->versions[v->line_base - 1].debug_count > 0);
    }
    for (size_t i = 0; i < m->unwind_count; ++i) {
        const struct xodb_jit_unwind *u = &m->unwinds[i];
        const struct xodb_jit_source *s = &m->sources[u->source];
        REQUIRE(u->data_offset <= s->len && u->unwind_size <= s->len - u->data_offset);
        REQUIRE(u->eh_frame_hdr_size <= u->unwind_size);
    }
}

static void probe(const struct xodb_jit_model *m, uint64_t address, int has_time, uint64_t time,
                  const struct xodb_jit_process *p, const struct xodb_jit_clock *c)
{
    struct xodb_jit_query q = {*p, address, has_time, time, *c};
    struct xodb_jit_result r;
    struct xodb_jit_control ctl = {0};
    REQUIRE(xodb_jit_resolve_ctl(m, &q, &ctl, &r) == XODB_JIT_OK);
    REQUIRE(r.outcome >= XODB_JIT_RESOLVED && r.outcome <= XODB_JIT_UNAVAILABLE && r.total_exact);
    REQUIRE(ctl.work <= query_bound(m));
    if (m->version_count <= 256) {
        oracle_resolve(m, &q, &oracle);
        REQUIRE(!oracle_compare(&r, &oracle));
    }
    if (ctl.work > 1) {
        /* One unit short: an explicit incomplete result, never a promoted one. */
        struct xodb_jit_control low = {ctl.work - 1, NULL, 0, 0, 0};
        struct xodb_jit_result s;
        REQUIRE(xodb_jit_resolve_ctl(m, &q, &low, &s) == XODB_JIT_E_WORK);
        REQUIRE(s.outcome == XODB_JIT_INCOMPLETE && !s.total_exact && s.count <= r.count);
    }
    REQUIRE(r.count <= r.total && r.count <= XODB_JIT_MAX_CANDIDATES);
    REQUIRE((r.total == 0) == (r.outcome == XODB_JIT_NO_MATCH));
    if (r.outcome == XODB_JIT_RESOLVED)
        REQUIRE(r.count >= 1);
    for (size_t i = 0; i < r.count; ++i) {
        const struct xodb_jit_version *v = &m->versions[r.candidates[i].version - 1];
        REQUIRE(address >= v->start && address - v->start < v->size);
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 2)
        return 0;
    unsigned mode = data[0] & 3;
    struct xodb_jit_limits limits;
    xodb_jit_limits_default(&limits);
    limits.max_input_bytes = 1u << 20;
    limits.max_memory_bytes = 8u << 20;
    limits.max_diagnostics = 64;
    if (mode == 3) {
        limits.max_records = 5;
        limits.max_versions = 4;
        limits.max_debug_entries = 8;
        limits.max_name_bytes = 16;
        limits.max_memory_bytes = 4096 + size;
    }
    struct xodb_jit_model m;
    xodb_jit_model_init(&m, &limits);
    static const struct xodb_jit_clock clock = {XODB_JIT_CLOCK_MONOTONIC, 1, {1}};
    struct xodb_jit_source_meta meta;
    memset(&meta, 0, sizeof meta);
    meta.clock = clock;
    meta.slack = data[1] & 7;
    const uint8_t *body = data + 2;
    size_t n = size - 2, split = mode == 2 ? n / 2 : n;
    struct xodb_jit_control ctl = {data[0] >> 2 ? (uint64_t)(data[0] >> 2) * (data[0] >> 2) : 0, NULL, 0, 0, 0};
    /* C07-R3: bit 4 of data[1] declares a known incarnation (header pid), bit 5
     * adds the same jitdump bytes a second time (explicit duplicate evidence). */
    if (mode != 1 && (data[1] & 0x10) && split >= 24) {
        uint32_t magic, pid;
        memcpy(&magic, body, 4);
        memcpy(&pid, body + 20, 4);
        meta.process = (struct xodb_jit_process){magic == 0x4454694Au ? __builtin_bswap32(pid) : pid, 1, 9, {0xb0}};
    }
    if (mode != 1) {
        int index;
        int e = xodb_jit_add_jitdump_ctl(&m, &meta, body, split, &ctl, &index);
        if (e == XODB_JIT_E_WORK)
            REQUIRE(index == -1 && m.source_count == 0 && m.version_count == 0 && m.diag_count == 0 &&
                    m.memory == accounted(&m));
        REQUIRE(ctl.memory_peak <= limits.max_memory_bytes && (!ctl.work_limit || ctl.work <= ctl.work_limit));
        if ((data[1] & 0x20) && m.source_count == 1)
            xodb_jit_add_jitdump(&m, &meta, body, split, NULL);
    }
    /* A query needs a nonzero pid; a header pid of 0 then matches nothing. */
    struct xodb_jit_process p = {m.source_count && m.sources[0].meta.process.pid ? m.sources[0].meta.process.pid : 1,
                                 0, 0, {0}};
    if (mode == 1 || mode == 2) {
        meta.process.pid = p.pid;
        meta.has_coverage_end = data[1] & 8;
        meta.coverage_end = 1000;
        xodb_jit_add_perfmap(&m, &meta, body + (mode == 2 ? split : 0), n - (mode == 2 ? split : 0), NULL);
    }
    invariants(&m);
    for (size_t i = 0; i < m.version_count && i < 8; ++i) {
        const struct xodb_jit_version *v = &m.versions[i];
        probe(&m, v->start, 0, 0, &p, &clock);
        probe(&m, v->start + v->size - 1, 1, v->begin.time, &p, &clock);
        probe(&m, v->start, 1, v->begin.time + 1, &p, &clock);
        if (v->end.has_time)
            probe(&m, v->start, 1, v->end.time, &p, &clock);
    }
    if (n >= 8) {
        uint64_t a;
        memcpy(&a, body + n - 8, 8);
        probe(&m, a, 1, a >> 3, &p, &clock);
    }
    xodb_jit_model_free(&m);
    return 0;
}

/* Exit hook for leak checking of the oracle's scratch. */
__attribute__((destructor)) static void release(void)
{
    free(oracle.candidates);
}
