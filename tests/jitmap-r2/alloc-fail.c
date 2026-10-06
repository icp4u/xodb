// Fails every allocation site in turn (jitmap.c built with
// -DXODB_JIT_FAULT_INJECTION). Each failed add must return out_of_memory and
// leave the model as before (counts, exact memory accounting); a failure that
// only drops a diagnostic may succeed. The same model must then accept the
// input and answer like a model that never saw a failure. Run under ASan to
// catch leaks and use-after-free on the rollback paths.
#define _GNU_SOURCE
#include "jitmap.h"
#include "adversary.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static long countdown = -1, calls;

void *xodb_jit_test_malloc(size_t size)
{
    calls++;
    if (countdown >= 0 && countdown-- == 0)
        return NULL;
    return malloc(size);
}

void *xodb_jit_test_realloc(void *ptr, size_t size)
{
    calls++;
    if (countdown >= 0 && countdown-- == 0)
        return NULL;
    return realloc(ptr, size);
}

static int failures, checks;
#define CHECK(cond)                                                                 \
    do {                                                                            \
        checks++;                                                                   \
        if (!(cond)) {                                                              \
            failures++;                                                             \
            if (failures < 30)                                                      \
                fprintf(stderr, "%s:%d: CHECK failed: %s (k=%ld)\n", __FILE__, __LINE__, #cond, k); \
        }                                                                           \
    } while (0)

static const struct xodb_jit_clock mono = {XODB_JIT_CLOCK_MONOTONIC, 1, {1, 2, 3}};

static size_t accounted(const struct xodb_jit_model *m)
{
    size_t total = m->source_cap * sizeof *m->sources + m->version_cap * sizeof *m->versions +
                   m->debug_cap * sizeof *m->debug + m->unwind_cap * sizeof *m->unwinds +
                   m->diag_cap * sizeof *m->diags;
    for (size_t i = 0; i < m->source_count; ++i)
        total += m->sources[i].charged;
    return total;
}

static void rich(struct jb *b)
{
    jb_init(b, 0);
    jb_header(b, ADV_PID, 50, 0);
    for (uint64_t i = 0; i < 40; ++i) {
        jb_debug_begin(b, 90 + i, ADV_A + 0x100 * i, 2);
        jb_debug_entry(b, ADV_A + 0x100 * i, 10, 0, "rich.js");
        jb_debug_entry(b, ADV_A + 0x100 * i + 4, 11, 0, "\xff");
        jb_unwind(b, 95 + i, 21, 8, 0x1000);
        jb_load(b, 100 + 3 * i, ADV_PID, 1, ADV_A + 0x100 * i, 0x40, i, "rich", 0x90);
        jb_move(b, 101 + 3 * i, ADV_PID, 1, ADV_A + 0x100 * i, ADV_B + 0x100 * i, 0x40, i);
        jb_load(b, 90 - i, ADV_PID, 1, ADV_A + 0x100 * i + 0x20, 0x40, 1000 + i, "ooo", 0x90); /* out of order */
    }
    jb_raw_record(b, 9, 24, 500);
    jb_close(b, 1000);
}

static const char perfmap[] = "7f0000100000 40 alpha\n7f0000100000 40 alpha\n7f0000100020 10 beta\nzz bad\n";

static void answers(const struct xodb_jit_model *m, struct xodb_jit_result *out, size_t *n)
{
    uint64_t times[] = {80, 100, 101, 150, 200, 2000};
    *n = 0;
    for (uint64_t i = 0; i < 40; i += 7)
        for (size_t t = 0; t < 6; ++t) {
            uint64_t addrs[] = {ADV_A + 0x100 * i + 8, ADV_B + 0x100 * i + 8, ADV_A + 0x100 * i + 0x30};
            for (int a = 0; a < 3; ++a) {
                struct xodb_jit_query q = {{ADV_PID, 1, 1, {0xb0}}, addrs[a], 1, times[t], mono};
                xodb_jit_resolve(m, &q, &out[(*n)++]);
            }
        }
}

static int same(const struct xodb_jit_result *a, const struct xodb_jit_result *b, size_t n)
{
    for (size_t i = 0; i < n; ++i) {
        if (a[i].outcome != b[i].outcome || a[i].total != b[i].total || a[i].count != b[i].count ||
            a[i].reasons != b[i].reasons)
            return 0;
        for (size_t k = 0; k < a[i].count; ++k)
            if (a[i].candidates[k].version != b[i].candidates[k].version ||
                a[i].candidates[k].state != b[i].candidates[k].state)
                return 0;
    }
    return 1;
}

int main(void)
{
    long k = -1;
    struct jb b;
    rich(&b);
    struct xodb_jit_source_meta meta;
    memset(&meta, 0, sizeof meta);
    meta.process = (struct xodb_jit_process){ADV_PID, 1, 1, {0xb0}};
    meta.clock = mono;
    meta.label = "alloc-fail";
    meta.artifact_sha256 = "00";
    meta.has_coverage_end = 1;
    meta.coverage_end = 5000;
    meta.map = (struct xodb_jit_clock_map){XODB_JIT_MAP_OFFSET, mono, 0, 0, 0, 0, 0, "declared"};

    /* Reference: perf map then jitdump, no failures. */
    struct xodb_jit_model ref;
    xodb_jit_model_init(&ref, NULL);
    CHECK(xodb_jit_add_perfmap(&ref, &meta, (const uint8_t *)perfmap, sizeof perfmap - 1, NULL) == XODB_JIT_OK);
    CHECK(xodb_jit_add_jitdump(&ref, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
    static struct xodb_jit_result want[512], got[512];
    size_t nwant, ngot;
    answers(&ref, want, &nwant);

    long sites = 0, nomem = 0, survived = 0;
    for (int target = 0; target < 2; ++target) /* 0: fail inside the jitdump add, 1: inside the perf-map add */
        for (k = 0;; ++k) {
            struct xodb_jit_model m;
            xodb_jit_model_init(&m, NULL);
            if (target == 0)
                CHECK(xodb_jit_add_perfmap(&m, &meta, (const uint8_t *)perfmap, sizeof perfmap - 1, NULL) ==
                      XODB_JIT_OK);
            size_t sources = m.source_count, versions = m.version_count, debug = m.debug_count,
                   unwinds = m.unwind_count;
            calls = 0;
            countdown = k;
            int index;
            int e = target == 0 ? xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, &index)
                                : xodb_jit_add_perfmap(&m, &meta, (const uint8_t *)perfmap, sizeof perfmap - 1, &index);
            int injected = countdown < 0;
            countdown = -1;
            if (!injected) {
                CHECK(e == XODB_JIT_OK);
                xodb_jit_model_free(&m);
                break;
            }
            sites++;
            CHECK(m.memory == accounted(&m) && m.memory <= m.limits.max_memory_bytes);
            if (e == XODB_JIT_E_NOMEM) {
                nomem++;
                CHECK(index == -1 && m.source_count == sources && m.version_count == versions &&
                      m.debug_count == debug && m.unwind_count == unwinds);
            } else {
                survived++; /* only a dropped diagnostic */
                CHECK(e == XODB_JIT_OK && m.diags_dropped > 0);
            }
            /* The model serves a successful request after the failure. */
            if (e == XODB_JIT_E_NOMEM) {
                int again = target == 0 ? xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL)
                                        : xodb_jit_add_perfmap(&m, &meta, (const uint8_t *)perfmap,
                                                               sizeof perfmap - 1, NULL);
                CHECK(again == XODB_JIT_OK);
            }
            if (target == 1)
                CHECK(xodb_jit_add_jitdump(&m, &meta, b.bytes, b.len, NULL) == XODB_JIT_OK);
            CHECK(m.memory == accounted(&m));
            answers(&m, got, &ngot);
            CHECK(ngot == nwant && same(want, got, nwant));
            xodb_jit_model_free(&m);
        }
    /* Failures inside resolve are impossible: it never allocates. */
    calls = 0;
    answers(&ref, got, &ngot);
    k = -1;
    CHECK(calls == 0);
    xodb_jit_model_free(&ref);
    jb_free(&b);
    printf("jitmap-alloc-fail: %ld allocation sites failed (%ld out_of_memory rollbacks, %ld diagnostic drops), "
           "%d checks, %d failures\n",
           sites, nomem, survived, checks, failures);
    return failures != 0;
}
