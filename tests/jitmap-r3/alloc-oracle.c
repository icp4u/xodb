// C07-R3 independent allocation-accounting oracle. Linked with
// -Wl,--wrap=malloc,--wrap=realloc,--wrap=calloc,--wrap=free so every request
// made by the unmodified library is tracked here (no library hooks). The
// harness itself never allocates through these symbols. Live requested bytes
// are tracked per pointer; realloc replaces the old size (live-capacity
// contract). For every add call:
//   live peak during the call <= reported control.memory_peak <= budget,
//   model.memory == live requested bytes afterwards, 0 after model_free,
// across byte-exact budget sweeps, metadata-only pressure, sequential adds,
// injected allocation failure at every site, cancellation and work limits.
// Resolve calls must not allocate. Usage: alloc-oracle
#define _GNU_SOURCE
#include "jitmap.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void *__real_malloc(size_t);
void *__real_realloc(void *, size_t);
void *__real_calloc(size_t, size_t);
void __real_free(void *);

#define SLOTS (1u << 16)
static struct {
    void *p;
    size_t n;
} slot[SLOTS];
static size_t live, call_peak, allocations, tracked;
static unsigned long fail_at, requests;

static size_t hash(void *p)
{
    return (size_t)(((uintptr_t)p >> 4) * 0x9e3779b97f4a7c15ull >> 48) & (SLOTS - 1);
}

static void track(void *p, size_t n)
{
    if (tracked + 1 >= SLOTS / 2)
        abort();
    size_t i = hash(p);
    while (slot[i].p)
        i = (i + 1) & (SLOTS - 1);
    slot[i].p = p;
    slot[i].n = n;
    tracked++;
    live += n;
    if (live > call_peak)
        call_peak = live;
}

static size_t untrack(void *p)
{
    size_t i = hash(p);
    while (slot[i].p != p) {
        if (!slot[i].p)
            abort(); /* freeing an untracked pointer */
        i = (i + 1) & (SLOTS - 1);
    }
    size_t n = slot[i].n;
    slot[i].p = NULL;
    tracked--;
    live -= n;
    /* Re-insert the rest of the cluster (linear probing deletion). */
    for (size_t k = (i + 1) & (SLOTS - 1); slot[k].p; k = (k + 1) & (SLOTS - 1)) {
        void *q = slot[k].p;
        size_t m = slot[k].n;
        slot[k].p = NULL;
        tracked--;
        live -= m;
        size_t saved = call_peak;
        track(q, m);
        call_peak = saved;
    }
    return n;
}

static int injected(void)
{
    requests++;
    return fail_at && requests == fail_at;
}

void *__wrap_malloc(size_t n)
{
    if (injected())
        return NULL;
    void *p = __real_malloc(n);
    if (p) {
        allocations++;
        track(p, n);
    }
    return p;
}

void *__wrap_calloc(size_t k, size_t n)
{
    if (injected())
        return NULL;
    void *p = __real_calloc(k, n);
    if (p) {
        allocations++;
        track(p, k * n);
    }
    return p;
}

void *__wrap_realloc(void *old, size_t n)
{
    if (injected())
        return NULL;
    size_t before = old ? untrack(old) : 0;
    void *p = __real_realloc(old, n);
    if (p) {
        allocations++;
        track(p, n);
    } else if (old) {
        track(old, before);
    }
    return p;
}

void __wrap_free(void *p)
{
    if (p)
        untrack(p);
    __real_free(p);
}

/* ---- checks ------------------------------------------------------------- */

static unsigned long checks, failures;
static int verbose_failures = 20;
#define CHECK(cond, ...)                                                    \
    do {                                                                    \
        checks++;                                                           \
        if (!(cond)) {                                                      \
            failures++;                                                     \
            if (verbose_failures-- > 0) {                                   \
                fprintf(stderr, "%s:%d: CHECK failed: %s: ", __FILE__, __LINE__, #cond); \
                fprintf(stderr, __VA_ARGS__);                               \
                fputc('\n', stderr);                                        \
            }                                                               \
        }                                                                   \
    } while (0)

/* ---- owned inputs (static storage; the harness does not allocate) -------- */

static uint8_t dump_small[4096], dump_header[40];
static size_t dump_small_len;
static char text_4095[4096], text_4096[4097], text_5000[5001], sha[65];
static const char perfmap[] = "7f0000001000 40 alpha\n7f0000002000 10 beta\nbad line\n7f0000003000 8 gamma\n";

static size_t put32(uint8_t *b, size_t at, uint32_t v)
{
    memcpy(b + at, &v, 4);
    return at + 4;
}

static size_t put64(uint8_t *b, size_t at, uint64_t v)
{
    memcpy(b + at, &v, 8);
    return at + 8;
}

static size_t header(uint8_t *b)
{
    size_t at = 0;
    at = put32(b, at, 0x4A695444u);
    at = put32(b, at, 1);
    at = put32(b, at, 40);
    at = put32(b, at, 62);
    at = put32(b, at, 0);
    at = put32(b, at, 31337);
    at = put64(b, at, 1);
    return put64(b, at, 0);
}

static size_t load(uint8_t *b, size_t at, uint64_t time, uint64_t addr, uint64_t index)
{
    static const char name[] = "owned";
    at = put32(b, at, 0);
    at = put32(b, at, 56 + sizeof name + 8);
    at = put64(b, at, time);
    at = put32(b, at, 31337);
    at = put32(b, at, 1);
    at = put64(b, at, addr);
    at = put64(b, at, addr);
    at = put64(b, at, 8);
    at = put64(b, at, index);
    memcpy(b + at, name, sizeof name);
    at += sizeof name;
    memset(b + at, 0x90, 8);
    return at + 8;
}

static void inputs(void)
{
    header(dump_header);
    size_t at = header(dump_small);
    /* Debug record for the first load, then loads, a move and an unknown record. */
    at = put32(dump_small, at, 2);
    at = put32(dump_small, at, 32 + 16 + 3);
    at = put64(dump_small, at, 100);
    at = put64(dump_small, at, 0x5000);
    at = put64(dump_small, at, 1);
    at = put64(dump_small, at, 0x5002);
    at = put32(dump_small, at, 9);
    at = put32(dump_small, at, 0);
    memcpy(dump_small + at, "f\0", 2);
    at += 2;
    dump_small[at++] = 0;
    for (uint64_t i = 0; i < 24; ++i)
        at = load(dump_small, at, 100 + i, 0x5000 + 16 * (i % 5), 1 + i % 3);
    at = put32(dump_small, at, 1);
    at = put32(dump_small, at, 64);
    at = put64(dump_small, at, 200);
    at = put32(dump_small, at, 31337);
    at = put32(dump_small, at, 1);
    at = put64(dump_small, at, 0x9000);
    at = put64(dump_small, at, 0x5000);
    at = put64(dump_small, at, 0x9000);
    at = put64(dump_small, at, 8);
    at = put64(dump_small, at, 1);
    at = put32(dump_small, at, 77);
    at = put32(dump_small, at, 24);
    at = put64(dump_small, at, 210);
    at = put64(dump_small, at, 0);
    dump_small_len = at;
    memset(text_4095, 'l', 4095);
    memset(text_4096, 'm', 4096);
    memset(text_5000, 'n', 5000);
    memset(sha, 'a', 64);
}

struct input {
    const char *name;
    int perfmap;
    const uint8_t *bytes;
    size_t len;
};

struct metas {
    const char *name;
    const char *sha, *label, *measured;
};

static struct xodb_jit_source_meta meta_of(const struct metas *x)
{
    struct xodb_jit_source_meta m;
    memset(&m, 0, sizeof m);
    m.process.pid = 31337;
    m.clock = (struct xodb_jit_clock){XODB_JIT_CLOCK_MONOTONIC, 1, {1}};
    m.has_coverage_end = 1;
    m.coverage_end = 1000;
    m.artifact_sha256 = x->sha;
    m.label = x->label;
    m.map.measured_by = x->measured;
    return m;
}

static int add(struct xodb_jit_model *m, const struct input *in, const struct xodb_jit_source_meta *meta,
               struct xodb_jit_control *c, int *index)
{
    return in->perfmap ? xodb_jit_add_perfmap_ctl(m, meta, in->bytes, in->len, c, index)
                       : xodb_jit_add_jitdump_ctl(m, meta, in->bytes, in->len, c, index);
}

/* One checked add: the oracle's live peak, the reported peak and the budget. */
static int checked_add(struct xodb_jit_model *m, const struct input *in, const struct metas *x,
                       struct xodb_jit_control *c, const char *what, size_t *peak_out)
{
    struct xodb_jit_source_meta meta = meta_of(x);
    size_t before = live;
    CHECK(m->memory == live, "%s %s %s: memory %zu live %zu before add", what, in->name, x->name, m->memory, live);
    call_peak = live;
    int index = -2;
    int e = add(m, in, &meta, c, &index);
    size_t budget = m->limits.max_memory_bytes;
    CHECK(call_peak <= budget, "%s %s %s budget %zu: live peak %zu above budget (result %s)", what, in->name,
          x->name, budget, call_peak, xodb_jit_error_name(e));
    CHECK(c->memory_peak >= call_peak && c->memory_peak <= budget,
          "%s %s %s budget %zu: reported peak %zu, live peak %zu", what, in->name, x->name, budget, c->memory_peak,
          call_peak);
    CHECK(m->memory == live, "%s %s %s budget %zu: memory %zu live %zu after %s", what, in->name, x->name, budget,
          m->memory, live, xodb_jit_error_name(e));
    CHECK(e == XODB_JIT_OK || e == XODB_JIT_E_BUDGET || e == XODB_JIT_E_NOMEM || e == XODB_JIT_E_WORK ||
              e == XODB_JIT_E_CANCELLED,
          "%s: unexpected %s", what, xodb_jit_error_name(e));
    if (e == XODB_JIT_E_NOMEM || e == XODB_JIT_E_WORK || e == XODB_JIT_E_CANCELLED)
        CHECK(index == -1 && live >= before, "%s: rollback index %d", what, index);
    if (peak_out)
        *peak_out = call_peak;
    return e;
}

static void no_query_allocations(const struct xodb_jit_model *m)
{
    size_t before = allocations;
    struct xodb_jit_query q;
    memset(&q, 0, sizeof q);
    q.process.pid = 31337;
    q.clock = (struct xodb_jit_clock){XODB_JIT_CLOCK_MONOTONIC, 1, {1}};
    q.has_time = 1;
    for (uint64_t a = 0x4ff8; a < 0x5060; a += 4)
        for (uint64_t t = 90; t < 230; t += 35) {
            q.address = a;
            q.time = t;
            struct xodb_jit_result r;
            xodb_jit_resolve(m, &q, &r);
        }
    CHECK(allocations == before, "resolve allocated %zu times", allocations - before);
}

static void model_with_budget(struct xodb_jit_model *m, size_t budget)
{
    struct xodb_jit_limits l;
    xodb_jit_limits_default(&l);
    l.max_memory_bytes = budget;
    xodb_jit_model_init(m, &l);
}

/* ---- scenarios ---------------------------------------------------------- */

/* Two 4,096-byte metadata strings, a valid
 * 40-byte header, budget = 16 source slots + 40 bytes. */
static int metadata_case(void)
{
    struct xodb_jit_model m;
    size_t budget = 16 * sizeof(struct xodb_jit_source) + 40;
    model_with_budget(&m, budget);
    struct input in = {"header-40", 0, dump_header, sizeof dump_header};
    struct metas x = {"label+measured-4096", NULL, text_4096, text_4096};
    struct xodb_jit_control c = {0};
    size_t peak = 0;
    unsigned long f = failures;
    int e = checked_add(&m, &in, &x, &c, "metadata", &peak);
    size_t retained = live;
    xodb_jit_model_free(&m);
    CHECK(live == 0, "metadata: %zu bytes live after free", live);
    printf("{\"case\":\"metadata-6952\",\"result\":\"%s\",\"budget\":%zu,\"reported_peak\":%zu,"
           "\"live_requested_peak\":%zu,\"retained_after_call\":%zu,\"pass\":%s}\n",
           xodb_jit_error_name(e), budget, c.memory_peak, peak, retained, failures == f ? "true" : "false");
    return failures == f;
}

static struct input all_inputs[] = {
    {"header-40", 0, dump_header, sizeof dump_header},
    {"jitdump-small", 0, dump_small, 0},
    {"perfmap", 1, (const uint8_t *)perfmap, sizeof perfmap - 1},
};

static const struct metas all_metas[] = {
    {"none", NULL, NULL, NULL},
    {"sha", sha, NULL, NULL},
    {"label-4095", NULL, text_4095, NULL},
    {"label-4096", NULL, text_4096, NULL},
    {"label-5000-truncated", NULL, text_5000, NULL},
    {"all-three-4096+", sha, text_4096, text_5000},
    {"measured-only-5000", NULL, NULL, text_5000},
};

#define COUNT(a) (sizeof(a) / sizeof *(a))

/* Every byte budget from 0 to the measured need (+64): single adds, then a
 * second add on the same model. */
static void budget_sweeps(void)
{
    unsigned long f = failures, adds = 0, rejected = 0;
    for (size_t i = 0; i < COUNT(all_inputs); ++i)
        for (size_t k = 0; k < COUNT(all_metas); ++k) {
            const struct input *in = &all_inputs[i];
            const struct metas *x = &all_metas[k];
            struct xodb_jit_model m;
            model_with_budget(&m, SIZE_MAX / 4);
            struct xodb_jit_control c = {0};
            size_t need = 0;
            CHECK(checked_add(&m, in, x, &c, "unlimited", &need) == XODB_JIT_OK, "unlimited add");
            CHECK(checked_add(&m, in, x, &c, "unlimited-second", NULL) == XODB_JIT_OK, "unlimited second add");
            size_t need2 = m.memory_peak;
            no_query_allocations(&m);
            xodb_jit_model_free(&m);
            CHECK(live == 0, "free left %zu", live);
            for (size_t budget = 0; budget <= need2 + 64; ++budget) {
                model_with_budget(&m, budget);
                struct xodb_jit_control c1 = {0}, c2 = {0};
                int e = checked_add(&m, in, x, &c1, "sweep", NULL);
                adds++;
                rejected += e != XODB_JIT_OK;
                if (budget >= need)
                    CHECK(e == XODB_JIT_OK, "budget %zu at or above need %zu rejected", budget, need);
                checked_add(&m, in, x, &c2, "sweep-second", NULL);
                adds++;
                xodb_jit_model_free(&m);
                CHECK(live == 0, "free left %zu", live);
            }
        }
    printf("{\"case\":\"budget-sweeps\",\"inputs\":%zu,\"metadata_variants\":%zu,\"adds\":%lu,\"rejected\":%lu,"
           "\"pass\":%s}\n",
           COUNT(all_inputs), COUNT(all_metas), adds, rejected, failures == f ? "true" : "false");
}

/* Fail the n-th allocation request of one add, for every n. */
static void failure_injection(void)
{
    unsigned long f = failures, sites = 0, nomem = 0;
    for (size_t i = 0; i < COUNT(all_inputs); ++i)
        for (size_t k = 0; k < COUNT(all_metas); k += 3) {
            for (unsigned long n = 1;; ++n) {
                struct xodb_jit_model m;
                model_with_budget(&m, 1u << 24);
                struct xodb_jit_control c = {0};
                requests = 0;
                fail_at = n;
                int e = checked_add(&m, &all_inputs[i], &all_metas[k], &c, "inject", NULL);
                unsigned long used = requests;
                fail_at = 0;
                nomem += e == XODB_JIT_E_NOMEM;
                if (e == XODB_JIT_E_NOMEM)
                    CHECK(m.source_count == 0 && m.version_count == 0, "nomem left sources");
                /* The same model accepts the input afterwards. */
                struct xodb_jit_control c2 = {0};
                if (e != XODB_JIT_OK)
                    CHECK(checked_add(&m, &all_inputs[i], &all_metas[k], &c2, "after-inject", NULL) == XODB_JIT_OK,
                          "retry after injected failure %lu", n);
                xodb_jit_model_free(&m);
                CHECK(live == 0, "free left %zu", live);
                if (used < n)
                    break;
                sites++;
            }
        }
    printf("{\"case\":\"allocation-failure\",\"sites\":%lu,\"out_of_memory_rollbacks\":%lu,\"pass\":%s}\n", sites,
           nomem, failures == f ? "true" : "false");
}

/* Cancellation before and work limits at every unit of the add. */
static void stops(void)
{
    unsigned long f = failures, limits = 0;
    struct xodb_jit_cancel cancel;
    xodb_jit_cancel_init(&cancel);
    xodb_jit_cancel_request(&cancel);
    for (size_t i = 0; i < COUNT(all_inputs); ++i)
        for (size_t k = 0; k < COUNT(all_metas); k += 2) {
            struct xodb_jit_model m;
            model_with_budget(&m, 1u << 24);
            struct xodb_jit_control cc = {0, &cancel, 0, 0, 0};
            CHECK(checked_add(&m, &all_inputs[i], &all_metas[k], &cc, "cancelled", NULL) == XODB_JIT_E_CANCELLED,
                  "pre-requested cancellation");
            CHECK(m.source_count == 0, "cancelled add kept a source");
            struct xodb_jit_control full = {0};
            CHECK(checked_add(&m, &all_inputs[i], &all_metas[k], &full, "full", NULL) == XODB_JIT_OK, "full add");
            xodb_jit_model_free(&m);
            for (uint64_t w = 1; w < full.work; ++w) {
                model_with_budget(&m, 1u << 24);
                struct xodb_jit_control lc = {w, NULL, 0, 0, 0};
                CHECK(checked_add(&m, &all_inputs[i], &all_metas[k], &lc, "work-limit", NULL) == XODB_JIT_E_WORK,
                      "work limit %llu of %llu", (unsigned long long)w, (unsigned long long)full.work);
                CHECK(m.source_count == 0 && m.version_count == 0 && m.diag_count == 0, "work limit kept state");
                xodb_jit_model_free(&m);
                CHECK(live == 0, "free left %zu", live);
                limits++;
            }
        }
    printf("{\"case\":\"cancellation-and-work-limits\",\"work_limits\":%lu,\"pass\":%s}\n", limits,
           failures == f ? "true" : "false");
}

int main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0); /* JSON lines stay whole beside stderr */
    inputs();
    all_inputs[1].len = dump_small_len;
    metadata_case();
    budget_sweeps();
    failure_injection();
    stops();
    printf("alloc-oracle: %lu checks, %lu failures\n", checks, failures);
    return failures != 0;
}
