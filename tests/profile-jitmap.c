// Pure jitdump/perf-map decoder and time-aware resolver tests. Synthetic
// records cover both byte orders, malformed framing and lifetime ambiguity.
#define _GNU_SOURCE
#include "jitmap.h"
#include "jitmap_build.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures, checks;
#define CHECK(cond)                                                                 \
    do {                                                                            \
        checks++;                                                                   \
        if (!(cond)) {                                                              \
            failures++;                                                             \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                           \
    } while (0)

static const struct xodb_jit_clock mono = {XODB_JIT_CLOCK_MONOTONIC, 1, {1, 2, 3}};
static const struct xodb_jit_clock other_boot = {XODB_JIT_CLOCK_MONOTONIC, 1, {9, 9, 9}};
static const struct xodb_jit_clock arch_clock = {XODB_JIT_CLOCK_ARCH, 1, {4}};

static struct xodb_jit_process incarnation(uint32_t pid, uint64_t ticks)
{
    struct xodb_jit_process p = {pid, 1, ticks, {0}};
    p.boot_id[0] = 0xb0;
    return p;
}

static struct xodb_jit_source_meta meta_for(struct xodb_jit_process p, struct xodb_jit_clock clock)
{
    struct xodb_jit_source_meta m;
    memset(&m, 0, sizeof m);
    m.process = p;
    m.clock = clock;
    m.label = "synthetic";
    return m;
}

static void show(const struct xodb_jit_result *r, int line)
{
    if (getenv("JITMAP_TEST_VERBOSE"))
        fprintf(stderr, "line %d: outcome=%u reasons=%#x total=%zu\n", line, r->outcome, r->reasons, r->total);
}

static struct xodb_jit_result query(const struct xodb_jit_model *model, struct xodb_jit_process p, uint64_t address,
                                    int has_time, uint64_t time, struct xodb_jit_clock clock)
{
    struct xodb_jit_query q = {p, address, has_time, time, clock};
    struct xodb_jit_result r;
    int error = xodb_jit_resolve(model, &q, &r);
    CHECK(error == XODB_JIT_OK);
    show(&r, (int)(address & 0xffff));
    return r;
}

static const char *name_of(const struct xodb_jit_model *model, const struct xodb_jit_result *r, size_t i)
{
    static char text[256];
    const struct xodb_jit_version *v = &model->versions[r->candidates[i].version - 1];
    size_t n = v->name_len < sizeof text - 1 ? v->name_len : sizeof text - 1;
    memcpy(text, model->sources[v->source].bytes + v->name_offset, n);
    text[n] = 0;
    return text;
}

static int has_diag(const struct xodb_jit_model *model, uint32_t code)
{
    for (size_t i = 0; i < model->diag_count; ++i)
        if (model->diags[i].code == code)
            return 1;
    return 0;
}

#define A 0x7f0000001000ull
#define B 0x7f0000009000ull
#define PID 4242u

static void lifetime_case(int swap)
{
    struct jb b;
    jb_init(&b, swap);
    jb_header(&b, PID, 50, 0);
    jb_debug_begin(&b, 90, A, 2);
    jb_debug_entry(&b, A, 10, 0, "alpha.js");
    jb_debug_entry(&b, A + 4, 11, 0, "\xff");
    jb_load(&b, 100, PID, 1, A, 0x40, 1, "alpha", 0xcc);
    jb_move(&b, 200, PID, 1, A, B, 0x40, 1);
    jb_load(&b, 300, PID, 1, A, 0x20, 2, "beta \xce\xbb", 0x90); /* address reuse, Unicode name */
    jb_close(&b, 1000);
    struct xodb_jit_model m;
    xodb_jit_model_init(&m, NULL);
    struct xodb_jit_source_meta meta = meta_for(incarnation(PID, 7), mono);
    int sid;
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, &sid) == XODB_JIT_OK);
    CHECK(sid == 0 && m.sources[0].swapped == swap && m.sources[0].complete && m.sources[0].closed);
    CHECK(m.version_count == 3 && m.debug_count == 2);
    CHECK(m.versions[0].debug_count == 2 && m.debug[1].file_offset == m.debug[0].file_offset && m.debug[1].in_range);
    CHECK(m.versions[1].predecessor == 1 && m.versions[0].end.kind == XODB_JIT_BOUND_MOVE_OUT);
    CHECK(m.versions[0].flags & XODB_JIT_V_HAS_CODE);
    CHECK(m.sources[0].bytes[m.versions[0].code_offset] == 0xcc);
    struct xodb_jit_process p = incarnation(PID, 7);
    struct xodb_jit_result r;
    r = query(&m, p, A + 8, 1, 99, mono);
    CHECK(r.outcome == XODB_JIT_NO_MATCH);
    r = query(&m, p, A + 8, 1, 150, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED && r.count == 1 && !strcmp(name_of(&m, &r, 0), "alpha"));
    r = query(&m, p, B + 8, 1, 150, mono);
    CHECK(r.outcome == XODB_JIT_NO_MATCH);
    r = query(&m, p, A + 8, 1, 250, mono); /* moved away, not yet reused */
    CHECK(r.outcome == XODB_JIT_NO_MATCH);
    r = query(&m, p, B + 8, 1, 250, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED && !strcmp(name_of(&m, &r, 0), "alpha") &&
          m.versions[r.candidates[0].version - 1].predecessor == 1);
    r = query(&m, p, A + 8, 1, 350, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED && !strcmp(name_of(&m, &r, 0), "beta \xce\xbb"));
    r = query(&m, p, A + 0x30, 1, 350, mono); /* old alpha range beyond beta: alpha moved out */
    CHECK(r.outcome == XODB_JIT_NO_MATCH);
    r = query(&m, p, A + 8, 0, 0, mono); /* no observation time: alpha and beta both possible */
    CHECK(r.outcome == XODB_JIT_AMBIGUOUS && r.total == 2 && (r.reasons & XODB_JIT_R_NO_QUERY_TIME));
    r = query(&m, p, B + 8, 0, 0, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_NO_QUERY_TIME));
    r = query(&m, p, B + 8, 1, 1500, mono); /* after CODE_CLOSE */
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_AFTER_COVERAGE));
    r = query(&m, p, A + 8, 1, 40, mono); /* before the dump existed */
    CHECK(r.outcome == XODB_JIT_NO_MATCH && (r.reasons & XODB_JIT_R_BEFORE_COVERAGE));
    r = query(&m, p, A + 8, 1, 350, other_boot); /* same kind, different boot/timens scope */
    CHECK(r.outcome == XODB_JIT_AMBIGUOUS || r.outcome == XODB_JIT_UNAVAILABLE);
    CHECK(r.reasons & XODB_JIT_R_CLOCK_UNRELATED);
    r = query(&m, p, B + 8, 1, 350, other_boot);
    CHECK(r.outcome == XODB_JIT_UNAVAILABLE);
    r = query(&m, incarnation(PID, 8), B + 8, 1, 250, mono); /* PID reuse */
    CHECK(r.outcome == XODB_JIT_NO_MATCH && (r.reasons & XODB_JIT_R_IDENTITY_SKIPPED));
    struct xodb_jit_process pid_only = {PID, 0, 0, {0}};
    r = query(&m, pid_only, B + 8, 1, 250, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_IDENTITY_UNVERIFIED));
    xodb_jit_model_free(&m);

    /* Same records with a declared slack: times near boundaries become ambiguous. */
    xodb_jit_model_init(&m, NULL);
    meta.slack = 10;
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    r = query(&m, p, A + 8, 1, 105, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_BOUNDARY));
    r = query(&m, p, B + 8, 1, 195, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_BOUNDARY));
    r = query(&m, p, A + 8, 1, 120, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED);
    xodb_jit_model_free(&m);

    /* Declared clock relation: query domain = source + 1000 +- 5. */
    xodb_jit_model_init(&m, NULL);
    meta.slack = 0;
    meta.map = (struct xodb_jit_clock_map){XODB_JIT_MAP_OFFSET, other_boot, 1000, 0, 0, 0, 5, "test declaration"};
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    r = query(&m, p, B + 8, 1, 1250, other_boot);
    CHECK(r.outcome == XODB_JIT_RESOLVED && !strcmp(name_of(&m, &r, 0), "alpha"));
    r = query(&m, p, A + 8, 1, 1302, other_boot); /* within uncertainty of reuse */
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_BOUNDARY));
    r = query(&m, p, A + 8, 1, 1350, other_boot);
    CHECK(r.outcome == XODB_JIT_RESOLVED && !strcmp(name_of(&m, &r, 0), "beta \xce\xbb"));
    xodb_jit_model_free(&m);
    jb_free(&b);
}

/* CPython 3.14 writes the header timestamp in CLOCK_REALTIME microseconds;
 * only a declared header clock may define the reporting start. */
static void header_clock(void)
{
    struct jb b;
    jb_init(&b, 0);
    jb_header(&b, PID, 1791186794248963ull, 0);
    jb_load(&b, 1000, PID, 1, A, 0x40, 1, "py::foo", 0x90);
    struct xodb_jit_model m;
    xodb_jit_model_init(&m, NULL);
    struct xodb_jit_source_meta meta = meta_for(incarnation(PID, 7), mono);
    meta.has_coverage_end = 1;
    meta.coverage_end = 5000;
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    struct xodb_jit_result r = query(&m, incarnation(PID, 7), A, 1, 2000, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED && !(r.reasons & XODB_JIT_R_BEFORE_COVERAGE));
    r = query(&m, incarnation(PID, 7), A, 1, 500, mono); /* before the first record */
    CHECK(r.outcome == XODB_JIT_NO_MATCH && (r.reasons & XODB_JIT_R_BEFORE_COVERAGE));
    xodb_jit_model_free(&m);
    xodb_jit_model_init(&m, NULL);
    meta.header_time_in_clock = 1; /* a false declaration: everything precedes the header */
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    r = query(&m, incarnation(PID, 7), A, 1, 2000, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_BEFORE_COVERAGE));
    xodb_jit_model_free(&m);
    jb_free(&b);
}

static void ordering_and_overlap(void)
{
    struct jb b;
    jb_init(&b, 0);
    jb_header(&b, PID, 1, 0);
    jb_load(&b, 300, PID, 2, A, 0x40, 2, "late", 0x90); /* written first, newer timestamp */
    jb_load(&b, 100, PID, 2, A, 0x40, 1, "early", 0x90);
    jb_load(&b, 400, PID, 2, B, 0x40, 3, "left", 0x90);
    jb_load(&b, 400, PID, 3, B + 0x20, 0x40, 4, "right", 0x90); /* equal-time overlap */
    struct xodb_jit_model m;
    xodb_jit_model_init(&m, NULL);
    struct xodb_jit_source_meta meta = meta_for(incarnation(PID, 7), mono);
    meta.has_coverage_end = 1;
    meta.coverage_end = 10000;
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    CHECK(has_diag(&m, XODB_JIT_D_OUT_OF_ORDER));
    struct xodb_jit_process p = incarnation(PID, 7);
    struct xodb_jit_result r = query(&m, p, A, 1, 200, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED && !strcmp(name_of(&m, &r, 0), "early"));
    r = query(&m, p, A, 1, 500, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED && !strcmp(name_of(&m, &r, 0), "late"));
    r = query(&m, p, B + 0x30, 1, 500, mono);
    CHECK(r.outcome == XODB_JIT_AMBIGUOUS && (r.reasons & XODB_JIT_R_OVERLAP) && r.total == 2);
    r = query(&m, p, B + 0x10, 1, 500, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED && !strcmp(name_of(&m, &r, 0), "left"));
    xodb_jit_model_free(&m);
    jb_free(&b);
}

static void aslr_incarnations(void)
{
    struct jb one, two;
    jb_init(&one, 0);
    jb_header(&one, PID, 1, 0);
    jb_load(&one, 10, PID, 1, A, 0x40, 1, "same", 0x90);
    jb_init(&two, 0);
    jb_header(&two, PID, 1, 0); /* restarted process reused the PID */
    jb_load(&two, 10, PID, 1, B, 0x40, 1, "same", 0x90);
    struct xodb_jit_model m;
    xodb_jit_model_init(&m, NULL);
    struct xodb_jit_source_meta m1 = meta_for(incarnation(PID, 100), mono), m2 = meta_for(incarnation(PID, 200), mono);
    m1.has_coverage_end = m2.has_coverage_end = 1;
    m1.coverage_end = m2.coverage_end = 1000;
    CHECK(xodb_jit_add_jitdump(&m, &m1, one.bytes, one.len, NULL) == XODB_JIT_OK);
    CHECK(xodb_jit_add_jitdump(&m, &m2, two.bytes, two.len, NULL) == XODB_JIT_OK);
    struct xodb_jit_result r = query(&m, incarnation(PID, 100), A, 1, 20, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED && m.versions[r.candidates[0].version - 1].source == 0);
    r = query(&m, incarnation(PID, 100), B, 1, 20, mono);
    CHECK(r.outcome == XODB_JIT_NO_MATCH && (r.reasons & XODB_JIT_R_IDENTITY_SKIPPED));
    r = query(&m, incarnation(PID, 200), B, 1, 20, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED && m.versions[r.candidates[0].version - 1].source == 1);
    struct xodb_jit_process pid_only = {PID, 0, 0, {0}};
    r = query(&m, pid_only, B, 1, 20, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_IDENTITY_UNVERIFIED));
    xodb_jit_model_free(&m);
    jb_free(&one);
    jb_free(&two);
}

static void arch_timestamps(void)
{
    struct jb b;
    jb_init(&b, 0);
    jb_header(&b, PID, 1000, 1);
    jb_load(&b, 2000, PID, 1, A, 0x40, 1, "tsc", 0x90);
    struct xodb_jit_model m;
    xodb_jit_model_init(&m, NULL);
    struct xodb_jit_source_meta meta = meta_for(incarnation(PID, 7), mono);
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_E_CLOCK);
    meta.clock = arch_clock;
    meta.has_coverage_end = 1;
    meta.coverage_end = 1u << 30;
    /* perf time_conv: ns = zero + ticks * mult >> shift; here ns = ticks / 2 + 7 */
    meta.map = (struct xodb_jit_clock_map){XODB_JIT_MAP_PERF_TSC, mono, 0, 1u << 9, 10, 7, 0, "perf time_conv"};
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    struct xodb_jit_result r = query(&m, incarnation(PID, 7), A, 1, 1006, mono);
    CHECK(r.outcome == XODB_JIT_NO_MATCH);
    r = query(&m, incarnation(PID, 7), A, 1, 1007, mono); /* exactly at the boundary */
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_BOUNDARY));
    r = query(&m, incarnation(PID, 7), A, 1, 1008, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED);
    r = query(&m, incarnation(PID, 7), A, 1, 1007, arch_clock); /* raw ticks domain directly */
    CHECK(r.outcome == XODB_JIT_NO_MATCH);
    r = query(&m, incarnation(PID, 7), A, 1, 2001, arch_clock);
    CHECK(r.outcome == XODB_JIT_RESOLVED);
    xodb_jit_model_free(&m);
    jb_free(&b);
}

static void malformed_jitdump(void)
{
    struct xodb_jit_model m;
    struct xodb_jit_source_meta meta = meta_for(incarnation(PID, 7), mono);
    struct jb b;
    struct xodb_jit_process p = incarnation(PID, 7);

    /* Header rejections. */
    jb_init(&b, 0);
    jb_header(&b, PID, 1, 0);
    xodb_jit_model_init(&m, NULL);
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, 39, NULL) == XODB_JIT_E_HEADER);
    b.bytes[0] ^= 0xff;
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_E_MAGIC);
    b.bytes[0] ^= 0xff;
    jb_patch32(&b, 4, 2);
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_E_VERSION);
    jb_patch32(&b, 4, 1);
    jb_patch32(&b, 8, 32);
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_E_HEADER);
    jb_patch32(&b, 8, 41);
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_E_HEADER);
    jb_patch32(&b, 8, 40);
    jb_patch64(&b, 32, 2);
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_E_FLAGS);
    jb_patch64(&b, 32, 0);
    struct xodb_jit_source_meta wrong = meta_for(incarnation(PID + 1, 7), mono);
    CHECK(xodb_jit_add_jitdump(&m, &wrong, b.bytes, b.len, NULL) == XODB_JIT_E_IDENTITY);
    CHECK(m.source_count == 0);
    xodb_jit_model_free(&m);
    jb_free(&b);

    /* Record-level problems are preserved as diagnostics. */
    jb_init(&b, 1);
    jb_header(&b, PID, 1, 0);
    jb_raw_record(&b, 9, 24, 5); /* unknown id, preserved */
    jb_load(&b, 10, PID, 1, 0xfffffffffffff000ull, 0x2000, 1, "wraps", 0x90);
    jb_load(&b, 11, PID, 1, A, 0, 2, "zero", 0x90);
    jb_load(&b, 12, PID, 1, 0xffffffffff600000ull, 0x100, 3, "high", 0x90);
    jb_load_unterminated(&b, 13, PID, A + 0x100);
    jb_load(&b, 14, PID + 1, 1, A + 0x200, 0x10, 4, "foreign", 0x90);
    jb_move(&b, 15, PID, 1, A + 0x300, A + 0x400, 0x10, 77); /* unknown index: orphan */
    jb_load(&b, 16, PID, 1, A + 0x500, 0x10, 5, "five", 0x90);
    jb_move(&b, 17, PID, 1, A + 0x510, A + 0x600, 0x10, 5); /* address mismatch: orphan */
    jb_debug_begin(&b, 18, A + 0x700, 1);
    jb_debug_entry(&b, A + 0x700, 3, 0, "lost.c"); /* no matching load follows */
    jb_load(&b, 19, PID, 1, A + 0x800, 0x10, 6, "six", 0x90);
    jb_unwind(&b, 20, 21, 8, 0x1000); /* padded to 8: not a diagnostic */
    jb_load(&b, 21, PID, 1, A + 0x900, 0x10, 7, "seven", 0x90);
    size_t keep = b.len;
    jb_load(&b, 22, PID, 1, A + 0xa00, 0x10, 8, "cut", 0x90);
    xodb_jit_model_init(&m, NULL);
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len - 3, NULL) == XODB_JIT_OK);
    const struct xodb_jit_source *s = &m.sources[0];
    CHECK(s->swapped && s->unknown_records == 1 && s->tail_truncated && !s->partial && !s->complete);
    CHECK(s->decoded_bytes == keep && s->coverage_end == 21);
    CHECK(has_diag(&m, XODB_JIT_D_UNKNOWN_RECORD) && has_diag(&m, XODB_JIT_D_RANGE_WRAPS) &&
          has_diag(&m, XODB_JIT_D_ZERO_SIZE) && has_diag(&m, XODB_JIT_D_NAME_UNTERMINATED) &&
          has_diag(&m, XODB_JIT_D_FOREIGN_PID) && has_diag(&m, XODB_JIT_D_MOVE_UNKNOWN_INDEX) &&
          has_diag(&m, XODB_JIT_D_MOVE_ADDRESS_MISMATCH) && has_diag(&m, XODB_JIT_D_DEBUG_UNMATCHED) &&
          has_diag(&m, XODB_JIT_D_TRUNCATED_RECORD));
    struct xodb_jit_result r = query(&m, p, 0xffffffffff600080ull, 1, 20, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED && !strcmp(name_of(&m, &r, 0), "high"));
    r = query(&m, p, A + 0x200, 1, 20, mono);
    CHECK(r.outcome == XODB_JIT_NO_MATCH);
    r = query(&m, p, A + 0x400, 1, 20, mono);
    CHECK(r.outcome == XODB_JIT_RESOLVED && (m.versions[r.candidates[0].version - 1].flags & XODB_JIT_V_ORPHAN_MOVE));
    r = query(&m, p, A + 0x500, 1, 20, mono); /* mismatched move did not end "five" */
    CHECK(r.outcome == XODB_JIT_RESOLVED && !strcmp(name_of(&m, &r, 0), "five"));
    r = query(&m, p, A + 0x900, 1, 21, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_AFTER_COVERAGE));
    r = query(&m, p, A + 0x900, 1, 20, mono);
    CHECK(r.outcome == XODB_JIT_NO_MATCH);
    int found_unwind = 0;
    for (size_t i = 0; i < m.version_count; ++i)
        if (m.versions[i].unwind_record >= 0) {
            const struct xodb_jit_unwind *u = &m.unwinds[m.versions[i].unwind_record];
            found_unwind = m.versions[i].start == A + 0x900 && u->unwind_size == 21 && u->eh_frame_hdr_size == 8 &&
                           u->mapped_size == 0x1000;
        }
    CHECK(found_unwind);
    CHECK(!has_diag(&m, XODB_JIT_D_TRAILING_BYTES));
    xodb_jit_model_free(&m);

    jb_free(&b);

    /* Framing loss: total_size < 16 stops decoding and marks the source partial. */
    jb_init(&b, 0);
    jb_header(&b, PID, 1, 0);
    jb_load(&b, 10, PID, 1, A, 0x10, 1, "ok", 0x90);
    jb_raw_record(&b, 0, 8, 11);
    jb_load(&b, 12, PID, 1, B, 0x10, 2, "unseen", 0x90);
    xodb_jit_model_init(&m, NULL);
    meta.has_coverage_end = 1;
    meta.coverage_end = 100;
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    CHECK(m.sources[0].partial && m.version_count == 1);
    r = query(&m, p, A, 1, 10, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_PARTIAL_SOURCE));
    r = query(&m, p, B, 1, 50, mono);
    CHECK(r.outcome == XODB_JIT_NO_MATCH && (r.reasons & XODB_JIT_R_AFTER_COVERAGE));
    xodb_jit_model_free(&m);
    jb_free(&b);

    /* Budget exhaustion: record limit and memory limit. */
    jb_init(&b, 0);
    jb_header(&b, PID, 1, 0);
    for (int i = 0; i < 64; ++i)
        jb_load(&b, 10 + (uint64_t)i, PID, 1, A + 0x100 * (uint64_t)i, 0x10, (uint64_t)i, "many", 0x90);
    struct xodb_jit_limits limits;
    xodb_jit_limits_default(&limits);
    limits.max_records = 8;
    xodb_jit_model_init(&m, &limits);
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_E_BUDGET);
    CHECK(m.source_count == 1 && m.sources[0].partial && m.version_count == 8);
    r = query(&m, p, A, 1, 50, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_PARTIAL_SOURCE));
    r = query(&m, p, A + 0x100 * 20, 1, 50, mono);
    CHECK(r.outcome == XODB_JIT_NO_MATCH && (r.reasons & XODB_JIT_R_AFTER_COVERAGE));
    xodb_jit_model_free(&m);
    xodb_jit_limits_default(&limits);
    limits.max_memory_bytes = b.len + 2048;
    xodb_jit_model_init(&m, &limits);
    int e = xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL);
    CHECK(e == XODB_JIT_E_BUDGET && m.memory <= limits.max_memory_bytes);
    xodb_jit_model_free(&m);
    limits.max_input_bytes = 64;
    xodb_jit_model_init(&m, &limits);
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_E_BUDGET && m.source_count == 0);
    xodb_jit_model_free(&m);
    jb_free(&b);
}

static void perf_maps(void)
{
    static const char text[] =
        "7f0000001000 40 alpha with spaces\n"
        "0x7f0000001000 40 beta \xe2\x98\x83 snowman\n"  /* overlap, 0x prefix, Unicode */
        "7f0000005000 10 solo\n"
        "7f0000006000 10 dup\n"
        "7f0000006000 10 dup\n"
        "7f0000007000 0 zero\n"
        "ffffffffffffff00 200 wraps\n"
        "1ffffffffffffffff 10 overflow\n"
        "xyz 10 nothex\n"
        "7f0000008000 10\n"
        "7f0000008000  10 double space\n"
        "7f0000009000 10 bad \xff utf8\n"
        "7f000000a000 10 \n"
        "7f000000b000 10 ";
    char big[300];
    memset(big, 'x', sizeof big);
    struct xodb_jit_limits limits;
    xodb_jit_limits_default(&limits);
    limits.max_line_bytes = 200;
    struct xodb_jit_model m;
    xodb_jit_model_init(&m, &limits);
    struct xodb_jit_source_meta meta = meta_for(incarnation(PID, 7), mono);
    meta.has_coverage_end = 1;
    meta.coverage_end = 5000;
    size_t n = sizeof text - 1;
    uint8_t *buf = malloc(n + sizeof big + 1);
    memcpy(buf, big, sizeof big);
    buf[sizeof big] = '\n';
    memcpy(buf + sizeof big + 1, text, n);
    CHECK(xodb_jit_add_perfmap(&m, &meta, buf, n + sizeof big + 1, NULL) == XODB_JIT_OK);
    CHECK(has_diag(&m, XODB_JIT_D_LINE_TOO_LONG) && has_diag(&m, XODB_JIT_D_ZERO_SIZE) &&
          has_diag(&m, XODB_JIT_D_RANGE_WRAPS) && has_diag(&m, XODB_JIT_D_HEX_OVERFLOW) &&
          has_diag(&m, XODB_JIT_D_LINE_MALFORMED) && has_diag(&m, XODB_JIT_D_NAME_NOT_UTF8) &&
          has_diag(&m, XODB_JIT_D_LINE_UNTERMINATED));
    CHECK(m.sources[0].tail_truncated && !m.sources[0].complete);
    struct xodb_jit_process p = incarnation(PID, 7);
    struct xodb_jit_result r = query(&m, p, 0x7f0000001010ull, 1, 100, mono);
    CHECK(r.outcome == XODB_JIT_AMBIGUOUS && r.total == 2);
    r = query(&m, p, 0x7f0000005008ull, 1, 100, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_UNTIMED_SNAPSHOT) &&
          !strcmp(name_of(&m, &r, 0), "solo"));
    r = query(&m, p, 0x7f0000006000ull, 1, 100, mono); /* identical duplicate lines */
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && r.total == 2);
    r = query(&m, p, 0x7f0000005008ull, 1, 6000, mono);
    CHECK(r.outcome == XODB_JIT_UNVERIFIED && (r.reasons & XODB_JIT_R_AFTER_COVERAGE));
    r = query(&m, p, 0x7f0000008000ull, 1, 100, mono);
    CHECK(r.outcome == XODB_JIT_NO_MATCH); /* missing name and double separator both rejected */
    r = query(&m, p, 0x7f0000009000ull, 1, 100, mono); /* invalid UTF-8 preserved with a flag */
    CHECK(r.outcome == XODB_JIT_UNVERIFIED &&
          (m.versions[r.candidates[0].version - 1].flags & XODB_JIT_V_NAME_NOT_UTF8));
    r = query(&m, p, 0x7f000000a000ull, 1, 100, mono); /* empty name after separator */
    CHECK(r.outcome == XODB_JIT_NO_MATCH);
    r = query(&m, p, 0x7f000000b000ull, 1, 100, mono); /* unterminated final line rejected */
    CHECK(r.outcome == XODB_JIT_NO_MATCH);
    r = query(&m, incarnation(PID, 8), 0x7f0000005008ull, 1, 100, mono);
    CHECK(r.outcome == XODB_JIT_NO_MATCH);
    struct xodb_jit_source_meta nopid = meta;
    nopid.process.pid = 0;
    CHECK(xodb_jit_add_perfmap(&m, &nopid, buf, 4, NULL) == XODB_JIT_E_ARGUMENT);
    xodb_jit_model_free(&m);
    free(buf);
}

static void mixed_sources(void)
{
    struct jb b;
    jb_init(&b, 0);
    jb_header(&b, PID, 1, 0);
    jb_load(&b, 100, PID, 1, A, 0x40, 1, "alpha", 0x90);
    static const char agree[] = "7f0000001000 40 alpha\n";
    static const char conflict[] = "7f0000001000 40 alpha\n7f0000001000 20 older\n";
    struct xodb_jit_model m;
    xodb_jit_model_init(&m, NULL);
    struct xodb_jit_source_meta meta = meta_for(incarnation(PID, 7), mono);
    meta.has_coverage_end = 1;
    meta.coverage_end = 1000;
    CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    CHECK(xodb_jit_add_perfmap(&m, &meta, (const uint8_t *)agree, sizeof agree - 1, NULL) == XODB_JIT_OK);
    struct xodb_jit_result r = query(&m, incarnation(PID, 7), A, 1, 200, mono);
    /* C07-R3 (contract v3 section 5): an untimed perf-map line with an equal
     * range and name is not shown to be the same code object; no corroboration. */
    CHECK(r.outcome == XODB_JIT_AMBIGUOUS && !(r.reasons & XODB_JIT_R_CORROBORATED) && r.total == 2);
    CHECK(xodb_jit_add_perfmap(&m, &meta, (const uint8_t *)conflict, sizeof conflict - 1, NULL) == XODB_JIT_OK);
    r = query(&m, incarnation(PID, 7), A, 1, 200, mono);
    CHECK(r.outcome == XODB_JIT_AMBIGUOUS);
    xodb_jit_model_free(&m);
    jb_free(&b);
}

int main(void)
{
    lifetime_case(0);
    lifetime_case(1);
    header_clock();
    ordering_and_overlap();
    aslr_incarnations();
    arch_timestamps();
    malformed_jitdump();
    perf_maps();
    mixed_sources();
    printf("profile-jitmap: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
